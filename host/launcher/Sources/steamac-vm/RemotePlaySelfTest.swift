import Darwin
import Foundation

enum RemotePlaySelfTest {
    static func run() -> Never {
        var failures = 0, checks = 0
        func check(_ success: Bool, _ name: String) {
            checks += 1
            if !success { failures += 1 }
            print("remote-play selftest: \(success ? "PASS" : "FAIL") \(name)")
        }
        let header = Data([0x08, 0x7b, 0x10, 1, 0x18, 0x2a])
        func string(_ field: UInt64, _ text: String) -> Data {
            var data = RemotePlayPacket.varint(field << 3 | 2)
            let value = Data(text.utf8)
            data.append(RemotePlayPacket.varint(UInt64(value.count))); data.append(value)
            return data
        }
        var body = Data([0x08, 1, 0x18, 0x9c, 0xd3, 1]) // connect_port = 27036
        body.append(string(4, "SteamOS"))
        body.append(string(20, "192.168.127.2"))
        body.append(string(20, "fe80::1234"))
        body.append(string(21, "203.0.113.1"))
        let unknown = Data([0xa8, 0x06, 0xff, 0x01]) // future varint field 101
        body.append(unknown)
        let wire = RemotePlayPacket.envelope(header: header, body: body)
        let packet = RemotePlayPacket(wire)
        check(packet?.type == 1, "decode real remote-client framing")
        let rewritten = packet.map { $0.advertised(on: "10.20.30.40") }.flatMap(RemotePlayPacket.init)
        check(rewritten?.header == header, "preserve identity and message type")
        let fields = rewritten.flatMap { RemotePlayPacket.fields($0.body) } ?? []
        let addresses = fields.filter { $0.number == 20 || $0.number == 21 }.map {
            String(decoding: rewritten!.body.subdata(in: $0.value), as: UTF8.self)
        }
        check(addresses == ["10.20.30.40", "10.20.30.40"], "replace all guest/public addresses with Mac LAN address")
        check(fields.first { $0.number == 3 }?.integer == 27036, "retain same-port TCP control forward")
        check(rewritten?.body.suffix(unknown.count) == unknown, "preserve unknown fields")
        let legacy = RemotePlayPacket(RemotePlayPacket.envelope(header: header, body: Data([0x18, 0x9c, 0xd3, 1])))!
        let legacyRewrite = RemotePlayPacket(legacy.advertised(on: "10.20.30.40"))!
        check(RemotePlayPacket.fields(legacyRewrite.body)?.contains { $0.number == 20 } == true,
              "add host address for older status schema")
        let discovery = RemotePlayPacket.discovery(clientID: UInt64.max, sequence: 1)
        check(RemotePlayPacket(discovery)?.advertised(on: "10.20.30.40") == discovery,
              "leave client discovery untouched")
        check(RemotePlayPacket(Data(wire.dropLast())) == nil, "reject truncated body")
        var badLength = wire; badLength[8] = 0xff; badLength[9] = 0xff
        check(RemotePlayPacket(badLength) == nil, "reject oversized header length")
        var badMagic = wire; badMagic[0] = 0
        check(RemotePlayPacket(badMagic) == nil, "reject non-Steam datagrams")
        check(RemotePlayPacket.fields(Data([8] + [UInt8](repeating: 0xff, count: 10))) == nil,
              "reject overflowing protobuf varint")
        check(RemotePlayPacket.fields(Data([0x22, 0xff, 0xff, 0x7f])) == nil,
              "reject oversized protobuf string")
        check(RemotePlayPacket.fields(Data([0])) == nil, "reject protobuf field zero")
        let now = Date(timeIntervalSince1970: 100)
        var health = RemotePlayRelay.Health()
        check(health.text(now: now).contains("guest Steam statuses received: 0; last never"),
              "do not invent guest discovery health before a reply")
        health.guestPackets = 3; health.lastGuestPacket = now.addingTimeInterval(-5)
        health.guestStatuses = 1; health.lastGuestStatus = now.addingTimeInterval(-30)
        health.sendFailures = 1; health.lastSendError = "Network is down"
        let status = health.text(now: now)
        check(status.contains("guest packets received: 3; last 5.0 s ago")
              && status.contains("guest Steam statuses received: 1; last 30.0 s ago"),
              "distinguish recent transport replies from stale Steam discovery status")
        check(status.contains("send failures: 1; last Network is down"),
              "retain relay send failure diagnostics")
        // Hold the production discovery port so startup fails before any gvproxy API call.
        // An existing Steam/launcher listener is already a valid conflict; never share it.
        let reservation = socket(AF_INET, SOCK_DGRAM, 0)
        var occupied = sockaddr_in()
        occupied.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
        occupied.sin_family = sa_family_t(AF_INET)
        occupied.sin_port = UInt16(27036).bigEndian
        let bindResult = withUnsafePointer(to: &occupied) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                bind(reservation, $0, socklen_t(MemoryLayout<sockaddr_in>.size))
            }
        }
        let conflictReady = bindResult == 0 || errno == EADDRINUSE
        check(conflictReady, "reserve discovery port without sharing another listener")
        if conflictReady {
            let dir = FileManager.default.temporaryDirectory.appendingPathComponent("steamac-relay-\(UUID().uuidString)")
            do {
                try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: false)
                let relay = RemotePlayRelay(proxy: Gvproxy(runDir: dir.path))
                var rejected = false
                do { try relay.start(); relay.stop() } catch { rejected = true }
                check(rejected, "reject discovery port conflict before exposing forwards")
                let snapshot = (try? String(contentsOf: dir.appendingPathComponent("remote-play-status.txt"), encoding: .utf8)) ?? ""
                check(snapshot.contains("relay: disabled:") && snapshot.contains("discovery listener open: false"),
                      "retain a diagnostic snapshot when discovery cannot start")
                try? FileManager.default.removeItem(at: dir)
            } catch { check(false, "create diagnostic regression directory: \(error)") }
        }
        if reservation >= 0 { close(reservation) }
        print("remote-play selftest: \(checks) checks, \(failures) failures")
        exit(failures == 0 ? 0 : 1)
    }
}
