import CEnet
import CryptoKit
import Darwin
import Foundation

/// ENet and its cipher state belong exclusively to queue. Main only synchronizes start/stop.
final class StreamControl {
    private static let initialized = enet_initialize()
    private let queue = DispatchQueue(label: "stream.control", qos: .userInteractive)
    private let key: SymmetricKey
    private let clientAddress: String
    private let connectData: UInt32
    private let onInput: (Data) -> Void
    private let onKeyFrame: () -> Void
    private let onInvalidate: (Int64, Int64) -> Void
    private let onEnd: (String) -> Void
    private var host: UnsafeMutablePointer<ENetHost>?
    private var peer: UnsafeMutablePointer<ENetPeer>?
    private var sequence: UInt32 = 0
    private var receivedSequences: [UInt8: UInt32] = [:]
    private var deadline: UInt64 = 0

    init(key: Data, clientAddress: String, connectData: UInt32,
         onInput: @escaping (Data) -> Void, onKeyFrame: @escaping () -> Void,
         onInvalidate: @escaping (Int64, Int64) -> Void, onEnd: @escaping (String) -> Void) throws {
        guard key.count == 16 else { throw StreamError("Invalid control key") }
        self.key = SymmetricKey(data: key)
        self.clientAddress = clientAddress
        self.connectData = connectData
        self.onInput = onInput
        self.onKeyFrame = onKeyFrame
        self.onInvalidate = onInvalidate
        self.onEnd = onEnd
    }

    func start() throws {
        try queue.sync {
            guard host == nil else { return }
            guard Self.initialized == 0 else { throw StreamError("ENet initialization failed") }
            let family = clientAddress.contains(":") ? AF_INET6 : AF_INET
            var address = ENetAddress()
            let wildcard = family == AF_INET6 ? "::" : "0.0.0.0"
            guard enet_address_set_host(&address, wildcard) == 0,
                  enet_address_set_port(&address, StreamPorts.control) == 0,
                  let h = enet_host_create(family, &address, 8, 48, 0, 0) else {
                throw StreamError("Cannot bind control UDP port \(StreamPorts.control): \(String(cString: strerror(errno)))")
            }
            host = h
            deadline = DispatchTime.now().uptimeNanoseconds + 15_000_000_000
            queue.async { [weak self] in self?.service() }
        }
    }

    func rumble(controller: UInt16, lowFrequency: UInt16, highFrequency: UInt16) {
        queue.async { [weak self] in
            var body = Data(repeating: 0, count: 4)
            body.appendLE(controller)
            body.appendLE(lowFrequency)
            body.appendLE(highFrequency)
            self?.send(type: 0x010b, payload: body)
        }
    }

    func stop(reason: UInt32 = 0x80030023) {
        queue.sync { close(reason: reason) }
    }

    private func close(reason: UInt32?) {
        guard let h = host else { return }
        if let reason, let p = peer {
            var body = Data()
            var big = reason.bigEndian
            withUnsafeBytes(of: &big) { body.append(contentsOf: $0) }
            send(type: 0x0109, payload: body)
            enet_host_flush(h)
            enet_peer_disconnect_later(p, 0)
            // Service acknowledgments briefly so a reliable termination can leave before destruction.
            let until = DispatchTime.now().uptimeNanoseconds + 100_000_000
            while DispatchTime.now().uptimeNanoseconds < until {
                var event = ENetEvent()
                if enet_host_service(h, &event, 5) > 0, let packet = event.packet {
                    enet_packet_destroy(packet)
                }
            }
        }
        peer = nil
        host = nil
        enet_host_destroy(h)
    }

    private func fail(_ message: String) {
        close(reason: nil)
        DispatchQueue.main.async { [onEnd] in onEnd(message) }
    }

    private func service() {
        guard let h = host else { return }
        var event = ENetEvent()
        let result = enet_host_service(h, &event, 10)
        if result < 0 { fail("Control socket failed"); return }
        if result > 0 {
            switch event.type {
            case ENET_EVENT_TYPE_CONNECT:
                guard let p = event.peer else { break }
                var address = p.pointee.address.address
                var text = [CChar](repeating: 0, count: Int(NI_MAXHOST))
                let status = withUnsafePointer(to: &address) {
                    $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                        getnameinfo($0, p.pointee.address.addressLength, &text, socklen_t(text.count), nil, 0, NI_NUMERICHOST)
                    }
                }
                guard status == 0, StreamPeerAddress.matches(String(cString: text), clientAddress),
                      event.data == connectData, peer == nil else {
                    enet_peer_disconnect_now(p, 0)
                    break
                }
                peer = p
                enet_peer_ping_interval(p, 500)
                enet_peer_timeout(p, 5, 5_000, 10_000)
            case ENET_EVENT_TYPE_DISCONNECT:
                if event.peer == peer { fail("Client disconnected"); return }
            case ENET_EVENT_TYPE_RECEIVE:
                if let packet = event.packet {
                    defer { enet_packet_destroy(packet) }
                    if event.peer == peer, packet.pointee.dataLength <= 65_539 {
                        let bytes = Data(bytes: packet.pointee.data, count: packet.pointee.dataLength)
                        do {
                            let (seq, plain) = try Self.open(bytes, key: key, hostOrigin: false)
                            if let previous = receivedSequences[event.channelID], seq <= previous { break }
                            receivedSequences[event.channelID] = seq
                            deadline = DispatchTime.now().uptimeNanoseconds + 10_000_000_000
                            handle(plain)
                        } catch { /* Unauthenticated messages cannot affect the session. */ }
                    }
                }
            default: break
            }
        }
        guard host != nil else { return }
        if DispatchTime.now().uptimeNanoseconds >= deadline { fail("Control connection timed out"); return }
        queue.async { [weak self] in self?.service() }
    }

    private func handle(_ message: Data) {
        guard message.count >= 4, Int(message.le16(2)) == message.count - 4 else { return }
        let payload = Data(message.dropFirst(4))
        switch message.le16(0) {
        case 0x0206: onInput(payload)
        case 0x0302: onKeyFrame()
        case 0x0301:
            guard payload.count >= 24 else { return }
            onInvalidate(Int64(bitPattern: payload.le64(0)), Int64(bitPattern: payload.le64(8)))
        case 0x0109, 0x0100: fail("Client ended the session")
        case 0x0200, 0x0201, 0x0204, 0x0305, 0x0307: break // Keepalive / statistics / start.
        default: break
        }
    }

    private func send(type: UInt16, payload: Data) {
        guard let p = peer, let h = host, sequence != UInt32.max else { return }
        do {
            let bytes = try Self.seal(type: type, payload: payload, sequence: sequence, key: key, hostOrigin: true)
            sequence += 1
            let packet = bytes.withUnsafeBytes { enet_packet_create($0.baseAddress, $0.count, UInt32(ENET_PACKET_FLAG_RELIABLE.rawValue)) }
            if let packet, enet_peer_send(p, 0, packet) != 0 { enet_packet_destroy(packet) }
            enet_host_flush(h)
        } catch { fail("Control encryption failed") }
    }


    private static func nonce(_ sequence: UInt32, hostOrigin: Bool) throws -> AES.GCM.Nonce {
        var iv = Data()
        iv.appendLE(sequence)
        iv.append(contentsOf: [0, 0, 0, 0, 0, 0, hostOrigin ? 72 : 67, 67])
        return try AES.GCM.Nonce(data: iv)
    }

    static func seal(type: UInt16, payload: Data, sequence: UInt32, key: SymmetricKey, hostOrigin: Bool) throws -> Data {
        guard payload.count <= 65_511 else { throw StreamError("Control message too large") }
        var plain = Data()
        plain.appendLE(type)
        plain.appendLE(UInt16(payload.count))
        plain.append(payload)
        let box = try AES.GCM.seal(plain, using: key, nonce: nonce(sequence, hostOrigin: hostOrigin))
        var packet = Data()
        packet.appendLE(UInt16(1))
        packet.appendLE(UInt16(20 + plain.count))
        packet.appendLE(sequence)
        packet.append(box.tag)
        packet.append(box.ciphertext)
        return packet
    }

    static func open(_ packet: Data, key: SymmetricKey, hostOrigin: Bool) throws -> (UInt32, Data) {
        guard packet.count >= 28, packet.le16(0) == 1, Int(packet.le16(2)) == packet.count - 4 else {
            throw StreamError("Invalid encrypted control frame")
        }
        let sequence = packet.le32(4)
        let box = try AES.GCM.SealedBox(nonce: nonce(sequence, hostOrigin: hostOrigin),
                                      ciphertext: packet.dropFirst(24), tag: packet[8..<24])
        let plain = try AES.GCM.open(box, using: key)
        guard plain.count >= 4, Int(plain.le16(2)) == plain.count - 4 else { throw StreamError("Invalid control payload") }
        return (sequence, plain)
    }

    static func selfCheck() -> [String] {
        guard StreamPeerAddress.selfCheck() else { return ["Control peer address normalization mismatch"] }
        do {
            let key = SymmetricKey(data: Data(0..<16))
            let body = Data([0, 0, 0, 0, 1, 0, 2, 0, 3, 0])
            for host in [false, true] {
                let packet = try seal(type: 0x010b, payload: body, sequence: 0x12345678, key: key, hostOrigin: host)
                let (seq, plain) = try open(packet, key: key, hostOrigin: host)
                guard packet.prefix(8) == Data([1, 0, 34, 0, 0x78, 0x56, 0x34, 0x12]),
                      seq == 0x12345678, plain.le16(0) == 0x010b, plain.dropFirst(4) == body else { return ["Control framing mismatch"] }
                var damaged = packet
                damaged[8] ^= 1
                do { _ = try open(damaged, key: key, hostOrigin: host); return ["Control accepted bad tag"] } catch {}
                do { _ = try open(packet, key: key, hostOrigin: !host); return ["Control accepted wrong IV direction"] } catch {}
            }
            return []
        } catch { return ["Control crypto: \(error)"] }
    }
}

enum StreamPeerAddress {
    static func normalized(_ address: String) -> Data? {
        let host = String(address.prefix { $0 != "%" })
        var ipv4 = in_addr()
        if inet_pton(AF_INET, host, &ipv4) == 1 {
            return withUnsafeBytes(of: &ipv4) { Data($0) }
        }
        var ipv6 = in6_addr()
        guard inet_pton(AF_INET6, host, &ipv6) == 1 else { return nil }
        return withUnsafeBytes(of: &ipv6) { bytes in
            if bytes.prefix(10).allSatisfy({ $0 == 0 }), bytes[10] == 255, bytes[11] == 255 {
                return Data(bytes.suffix(4))
            }
            return Data(bytes)
        }
    }

    static func matches(_ lhs: String, _ rhs: String) -> Bool {
        guard let left = normalized(lhs), let right = normalized(rhs) else { return false }
        return left == right
    }

    static func selfCheck() -> Bool {
        matches("fe80::1%en0", "fe80:0:0:0:0:0:0:1%4")
            && matches("::ffff:192.0.2.4", "192.0.2.4")
            && matches("0:0:0:0:0:ffff:c000:204", "192.0.2.4")
            && !matches("fe80::1%en0", "fe80::2%en0")
            && !matches("192.0.2.4", "192.0.2.5")
            && !matches("invalid", "invalid")
    }
}

private extension Data {
    mutating func appendLE<T: FixedWidthInteger>(_ value: T) {
        var little = value.littleEndian
        Swift.withUnsafeBytes(of: &little) { append(contentsOf: $0) }
    }
    func le16(_ offset: Int) -> UInt16 { UInt16(self[offset]) | UInt16(self[offset + 1]) << 8 }
    func le32(_ offset: Int) -> UInt32 { (0..<4).reduce(0) { $0 | UInt32(self[offset + $1]) << ($1 * 8) } }
    func le64(_ offset: Int) -> UInt64 { (0..<8).reduce(0) { $0 | UInt64(self[offset + $1]) << ($1 * 8) } }
}
