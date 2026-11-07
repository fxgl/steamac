import Darwin
import Foundation

/// Owns UDP 27036 exclusively (never SO_REUSEPORT). gvproxy handles TCP and the other
/// streaming UDP ports; a private loopback forward lets this relay rewrite discovery status.
/// Periodic discovery queries turn guest status replies into LAN announcements: gvproxy's
/// user-mode NAT cannot deliver unsolicited guest subnet broadcasts to the physical LAN.
final class RemotePlayRelay {
    /// Supervisor-owned snapshots survive guest sleep and are opt-in report attachments.
    struct Health {
        var lanPackets: UInt64 = 0
        var guestPackets: UInt64 = 0
        var guestStatuses: UInt64 = 0
        var lastLANPacket: Date?
        var lastGuestPacket: Date?
        var lastGuestStatus: Date?
        var sendFailures: UInt64 = 0
        var lastSendError = "none"

        func text(now: Date) -> String {
            func age(_ date: Date?) -> String {
                date.map { String(format: "%.1f s ago", max(0, now.timeIntervalSince($0))) } ?? "never"
            }
            return """
            LAN packet forward attempts: \(lanPackets); last \(age(lastLANPacket))
            guest packets received: \(guestPackets); last \(age(lastGuestPacket))
            guest Steam statuses received: \(guestStatuses); last \(age(lastGuestStatus))
            send failures: \(sendFailures); last \(lastSendError)
            """
        }
    }
    private struct Interface {
        let address: UInt32
        let mask: UInt32
        var broadcast: UInt32 { address | ~mask }
        var text: String { RemotePlayRelay.text(address) }
    }
    private struct PeerKey: Hashable {
        let address: UInt32
        let port: UInt16
    }
    private final class Session {
        let fd: Int32
        let source: DispatchSourceRead
        let peer: sockaddr_in?
        var touched = Date()
        init(fd: Int32, source: DispatchSourceRead, peer: sockaddr_in?) {
            self.fd = fd; self.source = source; self.peer = peer
        }
        func stop() { source.cancel() }
    }
    private let proxy: Gvproxy
    private let queue = DispatchQueue(label: "steamac.remote-play")
    private var listener: Int32 = -1
    private var readSource: DispatchSourceRead?
    private var timer: DispatchSourceTimer?
    private var upstream = sockaddr_in()
    private var interfaces: [Interface] = []
    private var localAddresses: Set<UInt32> = []
    private var buffer = [UInt8](repeating: 0, count: 65_535)
    private var sessions: [PeerKey: Session] = [:]
    private var poll: Session?
    private var forwards: [(String, String)] = []
    private let clientID = UInt64.random(in: 1...UInt64.max)
    private var sequence: UInt64 = 0
    private var loggedRequest = false
    private var loggedReply = false
    private var health = Health()

    init(proxy: Gvproxy) { self.proxy = proxy }

    func start() throws {
        // Reserve before exposing anything. A running Mac Steam client normally owns this
        // socket; fail closed, log the conflict, and leave that client's ports alone.
        do {
            listener = try Self.socket(address: INADDR_ANY, port: 27036)
            var yes: Int32 = 1
            guard setsockopt(listener, SOL_SOCKET, SO_BROADCAST, &yes, socklen_t(MemoryLayout.size(ofValue: yes))) == 0 else {
                throw Self.error("enable LAN broadcast")
            }
            let reservation = try Self.socket(address: inet_addr("127.0.0.1"), port: 0)
            var local = sockaddr_in(), length = socklen_t(MemoryLayout<sockaddr_in>.size)
            let result = withUnsafeMutablePointer(to: &local) {
                $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { getsockname(reservation, $0, &length) }
            }
            close(reservation)
            guard result == 0 else { throw Self.error("choose private discovery port") }
            let privatePort = UInt16(bigEndian: local.sin_port)
            try expose("udp", "127.0.0.1:\(privatePort)", guestPort: 27036)
            upstream = Self.address(inet_addr("127.0.0.1"), privatePort)
            for port in 27031...27035 { try expose("udp", "0.0.0.0:\(port)", guestPort: port) }
            for port in 27036...27037 { try expose("tcp", "0.0.0.0:\(port)", guestPort: port) }
            interfaces = Self.lanInterfaces()
            localAddresses = Self.hostAddresses()
            let source = DispatchSource.makeReadSource(fileDescriptor: listener, queue: queue)
            source.setEventHandler { [weak self] in self?.receiveLAN() }
            // Cancellation owns the descriptor: no close/reuse race with an in-flight handler.
            let fd = listener
            source.setCancelHandler { close(fd) }
            readSource = source
            source.resume()
            poll = try makeSession(peer: nil)
            let timer = DispatchSource.makeTimerSource(queue: queue)
            timer.schedule(deadline: .now(), repeating: 5)
            timer.setEventHandler { [weak self] in self?.tick() }
            self.timer = timer
            timer.resume()
            log("remote-play: LAN relay on, UDP 27031–27036 / TCP 27036–27037 → 192.168.127.2; allow Local Network access")
        } catch {
            stop()
            writeStatus(state: "disabled: \(error)")
            throw error
        }
    }

    private func expose(_ proto: String, _ local: String, guestPort: Int) throws {
        try proxy.forward(protocol: proto, local: local, remote: "192.168.127.2:\(guestPort)")
        forwards.append((proto, local))
    }

    func stop() {
        queue.sync {
            timer?.cancel(); timer = nil
            poll?.stop(); poll = nil
            for session in sessions.values { session.stop() }
            sessions.removeAll()
            if let source = readSource { source.cancel(); readSource = nil }
            else if listener >= 0 { close(listener) }
            listener = -1
            writeStatus(state: "stopped")
        }
        for (proto, local) in forwards.reversed() {
            try? proxy.forward(protocol: proto, local: local, remote: nil)
        }
        forwards.removeAll()
    }

    private func writeStatus(state: String) {
        let now = Date()
        let text = """
        checked at: \(ISO8601DateFormatter.string(from: now, timeZone: .gmt, formatOptions: [.withInternetDateTime]))
        relay: \(state)
        discovery listener open: \(listener >= 0)
        configured forwards: \(forwards.count) (see gvproxy-forwards.txt for the live API table)
        LAN IPv4 interfaces: \(interfaces.count)
        client sessions: \(sessions.count)
        guest discovery query attempts: \(sequence)
        \(health.text(now: now))

        """
        try? text.write(toFile: proxy.runDir + "/remote-play-status.txt", atomically: true, encoding: .utf8)
    }

    private func sent(_ result: Int) {
        if result < 0 {
            health.sendFailures &+= 1
            health.lastSendError = String(cString: strerror(errno))
        }
    }

    private func tick() {
        interfaces = Self.lanInterfaces() // Wi-Fi/Ethernet may change while the VM is up.
        localAddresses = Self.hostAddresses()
        let expired = sessions.filter { Date().timeIntervalSince($0.value.touched) > 120 }.map(\.key)
        for key in expired { sessions.removeValue(forKey: key)?.stop() }
        sequence &+= 1
        if let poll {
            sendConnected(RemotePlayPacket.discovery(clientID: clientID, sequence: sequence), fd: poll.fd)
        }
        writeStatus(state: "running")
    }

    private func receiveLAN() {
        while true {
            var peer = sockaddr_in(), length = socklen_t(MemoryLayout<sockaddr_in>.size)
            let count = withUnsafeMutablePointer(to: &peer) {
                $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                    recvfrom(listener, &buffer, buffer.count, 0, $0, &length)
                }
            }
            guard count >= 0 else { return }
            let ip = peer.sin_addr.s_addr
            // Steam and our announcements use source port 27036. Ignore host-origin
            // broadcasts from that socket, but permit an ephemeral local diagnostic client.
            guard !(localAddresses.contains(ip) && UInt16(bigEndian: peer.sin_port) == 27036),
                  let network = interfaces.first(where: {
                ip & $0.mask == $0.address & $0.mask && ip != $0.broadcast
            }) else { continue }
            let isDiscovery = count >= 8 && buffer.prefix(8).elementsEqual(RemotePlayPacket.magic)
            let packet = isDiscovery ? RemotePlayPacket(Data(buffer.prefix(count))) : nil
            if isDiscovery && packet == nil { continue }
            let key = PeerKey(address: ip, port: peer.sin_port)
            do {
                let session: Session
                if let existing = sessions[key] { session = existing }
                else {
                    guard sessions.count < 64 else { continue }
                    session = try makeSession(peer: peer); sessions[key] = session
                }
                session.touched = Date()
                // Streaming traffic takes the allocation-free path through the shared buffer.
                health.lanPackets &+= 1
                health.lastLANPacket = Date()
                buffer.withUnsafeBytes { bytes in sent(send(session.fd, bytes.baseAddress, count, 0)) }
                if !loggedRequest, packet?.type == 0 {
                    loggedRequest = true
                    log("remote-play: LAN discovery from \(Self.text(ip)):\(UInt16(bigEndian: peer.sin_port)) forwarded to guest via \(network.text)")
                }
            } catch { log("remote-play: \(error)") }
        }
    }

    private func makeSession(peer: sockaddr_in?) throws -> Session {
        let fd = try Self.socket(address: inet_addr("127.0.0.1"), port: 0)
        let result = withUnsafePointer(to: &upstream) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { connect(fd, $0, socklen_t(MemoryLayout<sockaddr_in>.size)) }
        }
        guard result == 0 else { close(fd); throw Self.error("connect discovery forward") }
        let source = DispatchSource.makeReadSource(fileDescriptor: fd, queue: queue)
        let session = Session(fd: fd, source: source, peer: peer)
        source.setEventHandler { [weak self, weak session] in
            guard let self, let session else { return }
            self.receiveGuest(session)
        }
        source.setCancelHandler { close(fd) }
        source.resume()
        return session
    }

    private func receiveGuest(_ session: Session) {
        while true {
            let count = recv(session.fd, &buffer, buffer.count, 0)
            guard count >= 0 else { return }
            health.guestPackets &+= 1
            health.lastGuestPacket = Date()
            let isDiscovery = count >= 8 && buffer.prefix(8).elementsEqual(RemotePlayPacket.magic)
            let packet = isDiscovery ? RemotePlayPacket(Data(buffer.prefix(count))) : nil
            if isDiscovery && packet == nil { continue }
            if packet?.type == 1 {
                health.guestStatuses &+= 1
                health.lastGuestStatus = Date()
            }
            if let peer = session.peer {
                guard let network = interfaces.first(where: {
                    peer.sin_addr.s_addr & $0.mask == $0.address & $0.mask
                }) else { continue }
                if let packet, packet.type == 1 {
                    sendLAN(packet.advertised(on: network.text), to: peer)
                } else {
                    buffer.withUnsafeBytes { sendLAN($0.baseAddress, count: count, to: peer) }
                }
                if !loggedReply, packet?.type == 1 {
                    loggedReply = true
                    log("remote-play: guest discovery status relayed to LAN client \(Self.text(peer.sin_addr.s_addr)) (advertised \(network.text))")
                }
            } else if packet?.type == 1 {
                // Only actual Steam status is announced. No synthetic hosts when Steam is
                // not running, signed out, or has Remote Play disabled.
                for network in interfaces {
                    sendLAN(packet!.advertised(on: network.text), to: Self.address(network.broadcast, 27036))
                }
            }
        }
    }

    private func sendConnected(_ data: Data, fd: Int32) {
        data.withUnsafeBytes { bytes in sent(send(fd, bytes.baseAddress, bytes.count, 0)) }
    }

    private func sendLAN(_ data: Data, to peer: sockaddr_in) {
        data.withUnsafeBytes { sendLAN($0.baseAddress, count: $0.count, to: peer) }
    }

    private func sendLAN(_ bytes: UnsafeRawPointer?, count: Int, to peer: sockaddr_in) {
        var peer = peer
        withUnsafePointer(to: &peer) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                sent(sendto(listener, bytes, count, 0, $0, socklen_t(MemoryLayout<sockaddr_in>.size)))
            }
        }
    }

    private static func error(_ action: String) -> OptionError {
        OptionError("Remote Play \(action): \(String(cString: strerror(errno)))")
    }

    private static func address(_ ip: UInt32, _ port: UInt16) -> sockaddr_in {
        var address = sockaddr_in()
        address.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
        address.sin_family = sa_family_t(AF_INET)
        address.sin_addr.s_addr = ip; address.sin_port = port.bigEndian
        return address
    }

    private static func socket(address ip: UInt32, port: UInt16) throws -> Int32 {
        let fd = Darwin.socket(AF_INET, SOCK_DGRAM, 0)
        guard fd >= 0 else { throw error("create UDP socket") }
        var address = address(ip, port)
        let result = withUnsafePointer(to: &address) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { bind(fd, $0, socklen_t(MemoryLayout<sockaddr_in>.size)) }
        }
        guard result == 0 else { let e = error("bind UDP \(port) (quit Mac Steam if it owns 27036)"); close(fd); throw e }
        _ = fcntl(fd, F_SETFD, FD_CLOEXEC)
        _ = fcntl(fd, F_SETFL, O_NONBLOCK)
        return fd
    }

    private static func text(_ ip: UInt32) -> String {
        var address = in_addr(s_addr: ip), buffer = [CChar](repeating: 0, count: Int(INET_ADDRSTRLEN))
        _ = inet_ntop(AF_INET, &address, &buffer, socklen_t(buffer.count))
        return String(cString: buffer)
    }

    private static func lanInterfaces() -> [Interface] {
        var first: UnsafeMutablePointer<ifaddrs>?
        guard getifaddrs(&first) == 0 else { return [] }
        defer { freeifaddrs(first) }
        var result: [Interface] = [], current = first
        while let pointer = current {
            let item = pointer.pointee; current = item.ifa_next
            let flags = Int32(bitPattern: item.ifa_flags)
            guard flags & IFF_UP != 0, flags & IFF_BROADCAST != 0,
                  flags & (IFF_LOOPBACK | IFF_POINTOPOINT) == 0,
                  let address = item.ifa_addr, address.pointee.sa_family == AF_INET,
                  let mask = item.ifa_netmask else { continue }
            let ip = UnsafeRawPointer(address).assumingMemoryBound(to: sockaddr_in.self).pointee.sin_addr.s_addr
            let netmask = UnsafeRawPointer(mask).assumingMemoryBound(to: sockaddr_in.self).pointee.sin_addr.s_addr
            result.append(Interface(address: ip, mask: netmask))
        }
        return result
    }

    private static func hostAddresses() -> Set<UInt32> {
        var first: UnsafeMutablePointer<ifaddrs>?
        guard getifaddrs(&first) == 0 else { return [] }
        defer { freeifaddrs(first) }
        var result: Set<UInt32> = [inet_addr("127.0.0.1")], current = first
        while let pointer = current {
            let item = pointer.pointee; current = item.ifa_next
            guard let address = item.ifa_addr, address.pointee.sa_family == AF_INET else { continue }
            result.insert(UnsafeRawPointer(address).assumingMemoryBound(to: sockaddr_in.self).pointee.sin_addr.s_addr)
        }
        return result
    }
}
