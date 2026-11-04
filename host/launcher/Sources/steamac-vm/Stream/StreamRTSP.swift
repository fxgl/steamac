import Darwin
import Foundation

final class StreamRTSP {
    private let queue = DispatchQueue(label: "stream.rtsp")
    private let launch: StreamLaunch
    private let secrets: StreamSessionSecrets
    private let announce: (StreamVideoConfig, StreamAudioConfig) throws -> Void
    private let play: () throws -> Void
    private var listener: DispatchSourceRead?
    private var connections: [Int32: Connection] = [:]

    init(launch: StreamLaunch, secrets: StreamSessionSecrets,
         announce: @escaping (StreamVideoConfig, StreamAudioConfig) throws -> Void,
         play: @escaping () throws -> Void) {
        self.launch = launch
        self.secrets = secrets
        self.announce = announce
        self.play = play
    }

    func start() throws {
        let family = launch.clientAddress.contains(":") ? AF_INET6 : AF_INET
        let fd = socket(family, SOCK_STREAM, 0)
        guard fd >= 0 else { throw StreamError("Cannot create RTSP socket") }
        var one: Int32 = 1
        setsockopt(fd, SOL_SOCKET, SO_REUSEADDR, &one, socklen_t(MemoryLayout.size(ofValue: one)))
        setsockopt(fd, SOL_SOCKET, SO_NOSIGPIPE, &one, socklen_t(MemoryLayout.size(ofValue: one)))
        var address = sockaddr_in6()
        address.sin6_len = UInt8(MemoryLayout<sockaddr_in6>.size)
        address.sin6_family = sa_family_t(AF_INET6)
        address.sin6_port = StreamPorts.rtsp.bigEndian
        var address4 = sockaddr_in()
        address4.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
        address4.sin_family = sa_family_t(AF_INET)
        address4.sin_port = StreamPorts.rtsp.bigEndian
        let result = family == AF_INET6 ? withUnsafePointer(to: &address) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { bind(fd, $0, socklen_t(MemoryLayout<sockaddr_in6>.size)) }
        } : withUnsafePointer(to: &address4) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { bind(fd, $0, socklen_t(MemoryLayout<sockaddr_in>.size)) }
        }
        guard result == 0, listen(fd, 8) == 0 else {
            let message = String(cString: strerror(errno))
            Darwin.close(fd)
            throw StreamError("Cannot bind RTSP TCP port \(StreamPorts.rtsp): \(message)")
        }
        _ = fcntl(fd, F_SETFL, O_NONBLOCK)
        let source = DispatchSource.makeReadSource(fileDescriptor: fd, queue: queue)
        source.setCancelHandler { Darwin.close(fd) }
        source.setEventHandler { [weak self] in self?.acceptConnections(fd) }
        listener = source
        source.resume()
    }

    func stop() {
        let cancelled: DispatchGroup? = queue.sync {
            var cancelled: DispatchGroup?
            if let listener {
                let group = DispatchGroup()
                group.enter()
                let fd = Int32(listener.handle)
                listener.setCancelHandler { Darwin.close(fd); group.leave() }
                listener.cancel()
                cancelled = group
            }
            listener = nil
            let active = Array(connections.values)
            for connection in active { connection.close() }
            connections.removeAll()
            return cancelled
        }
        // A resumed client may bind this port again immediately.
        cancelled?.wait()
    }

    private func acceptConnections(_ fd: Int32) {
        while true {
            var address = sockaddr_storage()
            var size = socklen_t(MemoryLayout.size(ofValue: address))
            let client = withUnsafeMutablePointer(to: &address) {
                $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { accept(fd, $0, &size) }
            }
            guard client >= 0 else { return }
            var text = [CChar](repeating: 0, count: Int(NI_MAXHOST))
            let status = withUnsafePointer(to: &address) {
                $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { getnameinfo($0, size, &text, socklen_t(text.count), nil, 0, NI_NUMERICHOST) }
            }
            guard status == 0, StreamPeerAddress.matches(String(cString: text), launch.clientAddress),
                  connections.count < 16 else { Darwin.close(client); continue }
            let connection = Connection(fd: client, queue: queue, request: { [weak self] request, reply in
                self?.handle(request, reply: reply)
            }, ended: { [weak self] in self?.connections.removeValue(forKey: client) })
            connections[client] = connection
            connection.start()
        }
    }

    private func handle(_ request: Request, reply: @escaping (Int, [String: String], String) -> Void) {
        switch request.method {
        case "OPTIONS": reply(200, ["Public": "OPTIONS, DESCRIBE, SETUP, ANNOUNCE, PLAY"], "")
        case "DESCRIBE":
            var lines = ["v=0", "o=- 0 0 IN IPv4 127.0.0.1", "s=SteamOS", "t=0 0",
                         "a=x-ss-general.featureFlags:0", "a=x-ss-general.encryptionSupported:5",
                         "a=x-ss-general.encryptionRequested:1", "m=video 0 RTP/AVP 96",
                         "a=rtpmap:96 H264/90000", "a=fmtp:96 packetization-mode=1",
                         "a=x-nv-video[0].refPicInvalidation:0"]
            if StreamCodec.hardwareSupported.contains(.hevc) { lines.append("a=fmtp:96 sprop-parameter-sets=AAAAAU") }
            lines += ["m=audio 0 RTP/AVP 97", "a=rtpmap:97 opus/48000/2"]
            lines += StreamAudioStream.sdpAttributes()
            reply(200, ["Content-Type": "application/sdp"], lines.joined(separator: "\r\n") + "\r\n")
        case "SETUP":
            var headers = ["Session": "steamac;timeout=90"]
            if request.uri.contains("streamid=video") {
                headers["Transport"] = "server_port=\(StreamPorts.video)"
                headers["X-SS-Ping-Payload"] = String(decoding: secrets.videoPingPayload, as: UTF8.self)
            } else if request.uri.contains("streamid=audio") {
                headers["Transport"] = "server_port=\(StreamPorts.audio)"
                headers["X-SS-Ping-Payload"] = String(decoding: secrets.audioPingPayload, as: UTF8.self)
            } else if request.uri.contains("streamid=control") {
                headers["Transport"] = "server_port=\(StreamPorts.control)"
                headers["X-SS-Connect-Data"] = String(secrets.controlConnectData)
            } else { reply(404, [:], ""); return }
            reply(200, headers, "")
        case "ANNOUNCE":
            do {
                let (video, audio) = try Self.parseAnnounce(request.body, launch: launch)
                DispatchQueue.main.async { [announce] in
                    do { try announce(video, audio); reply(200, ["Session": "steamac"], "") }
                    catch { log("stream: ANNOUNCE failed: \(error)"); reply(400, [:], "") }
                }
            } catch { reply(400, [:], "") }
        case "PLAY":
            DispatchQueue.main.async { [play] in
                do { try play(); reply(200, ["Session": "steamac"], "") }
                catch { log("stream: PLAY failed: \(error)"); reply(500, [:], "") }
            }
        default: reply(405, [:], "")
        }
    }

    static func parseAnnounce(_ body: String, launch: StreamLaunch) throws -> (StreamVideoConfig, StreamAudioConfig) {
        var values: [String: String] = [:]
        for line in body.components(separatedBy: .newlines) where line.hasPrefix("a=") {
            let attribute = line.dropFirst(2)
            guard let colon = attribute.firstIndex(of: ":") else { continue }
            values[String(attribute[..<colon])] = attribute[attribute.index(after: colon)...].trimmingCharacters(in: .whitespaces)
        }
        func number(_ name: String, _ fallback: Int) -> Int { values[name].flatMap(Int.init) ?? fallback }
        let width = number("x-nv-video[0].clientViewportWd", launch.width)
        let height = number("x-nv-video[0].clientViewportHt", launch.height)
        let fps = max(1, min(240, number("x-nv-video[0].maxFPS", launch.fps)))
        let format = number("x-nv-vqos[0].bitStreamFormat", 0)
        let encryption = number("x-ss-general.encryptionEnabled", 0)
        let packetSize = number("x-nv-video[0].packetSize", 1024)
        // The encoder needs >24 bytes; RTP/NV adds 16 bytes to the requested size.
        guard (25...65_491).contains(packetSize) else { throw StreamError("Invalid video packet size") }
        guard width == launch.width, height == launch.height,
              (0...1).contains(format), encryption & 1 != 0, encryption & 2 == 0,
              number("x-nv-video[0].dynamicRangeMode", 0) == 0,
              number("x-ss-video[0].chromaSamplingType", 0) == 0 else { throw StreamError("Unsupported stream configuration") }
        let codec: StreamCodec = format == 1 ? .hevc : .h264
        guard StreamCodec.hardwareSupported.contains(codec) else { throw StreamError("Codec unavailable") }
        let csc = number("x-nv-video[0].encoderCscMode", 2)
        let video = StreamVideoConfig(width: width, height: height, fps: fps,
            bitrateKbps: max(500, min(150_000, number("x-nv-vqos[0].bw.maximumBitrateKbps", number("x-nv-video[0].initialBitrateKbps", 20_000)))),
            packetSize: packetSize,
            minRequiredFecPackets: max(0, min(16, number("x-nv-vqos[0].fec.minRequiredFecPackets", 2))),
            codec: codec, fullRange: csc & 1 != 0, colorspace: max(0, min(2, csc >> 1)),
            maxReferenceFrames: max(0, min(16, number("x-nv-video[0].maxNumReferenceFrames", 1))),
            slicesPerFrame: max(1, min(16, number("x-nv-video[0].videoEncoderSlicesPerFrame", 1))))
        let channels = number("x-nv-audio.surround.numChannels", Int(launch.surroundAudioInfo & 0xffff))
        let mask = UInt32(clamping: number("x-nv-audio.surround.channelMask", Int(launch.surroundAudioInfo >> 16)))
        let audio = StreamAudioStream.config(channels: channels, channelMask: mask,
            highQuality: number("x-nv-audio.surround.AudioQuality", 0) != 0,
            packetDurationMs: number("x-nv-aqos.packetDuration", 5), encrypted: encryption & 4 != 0)
        return (video, audio)
    }

    static func selfCheck() -> [String] {
        let client = StreamClient(fingerprint: "test", name: "test", certificate: Data(), pairedAt: Date())
        let launch = StreamLaunch(client: client, clientAddress: "127.0.0.1", appID: 1, width: 1920, height: 1080, fps: 60,
            aesKey: Data(repeating: 0, count: 16), aesKeyID: 1, playAudioOnHost: false,
            surroundAudioInfo: 0x00030002, remoteControllersBitmap: 0, resume: false)
        let sdp = """
        v=0
        s=NVIDIA Streaming Client
        a=x-ss-general.encryptionEnabled:5
        a=x-nv-video[0].clientViewportWd:1920
        a=x-nv-video[0].clientViewportHt:1080
        a=x-nv-video[0].maxFPS:60
        a=x-nv-video[0].packetSize:1392
        a=x-nv-video[0].initialBitrateKbps:16000
        a=x-nv-vqos[0].bw.maximumBitrateKbps:16000
        a=x-nv-vqos[0].fec.minRequiredFecPackets:2
        a=x-nv-vqos[0].bitStreamFormat:1
        a=x-nv-video[0].encoderCscMode:3
        a=x-nv-video[0].maxNumReferenceFrames:1
        a=x-nv-video[0].videoEncoderSlicesPerFrame:1
        a=x-nv-audio.surround.numChannels:2
        a=x-nv-audio.surround.channelMask:3
        a=x-nv-audio.surround.AudioQuality:1
        a=x-nv-aqos.packetDuration:5
        """
        do {
            let (v, a) = try parseAnnounce(sdp, launch: launch)
            guard v.width == 1920, v.height == 1080, v.fps == 60, v.codec == .hevc,
                  v.packetSize == 1392, v.bitrateKbps == 16000, v.fullRange, v.colorspace == 1,
                  a.channels == 2, a.packetDurationMs == 5, a.encrypted, a.highQuality else { return ["RTSP ANNOUNCE mismatch"] }
            for (requested, expected) in [(90, 90), (0, 1), (300, 240)] {
                let changed = sdp.replacingOccurrences(of: "maxFPS:60", with: "maxFPS:\(requested)")
                guard try parseAnnounce(changed, launch: launch).0.fps == expected else { return ["RTSP ANNOUNCE fps mismatch"] }
            }
            for size in [32, 768, 1500, 65_491] {
                let changed = sdp.replacingOccurrences(of: "packetSize:1392", with: "packetSize:\(size)")
                guard try parseAnnounce(changed, launch: launch).0.packetSize == size else { return ["RTSP ANNOUNCE packet size changed"] }
            }
            for size in [0, 24, 65_492] {
                let changed = sdp.replacingOccurrences(of: "packetSize:1392", with: "packetSize:\(size)")
                do { _ = try parseAnnounce(changed, launch: launch); return ["RTSP ANNOUNCE accepted invalid packet size"] }
                catch {}
            }
            return []
        } catch { return ["RTSP ANNOUNCE: \(error)"] }
    }

    private struct Request {
        let method: String
        let uri: String
        let cseq: String
        let body: String
    }

    private final class Connection {
        let fd: Int32
        let queue: DispatchQueue
        let request: (Request, @escaping (Int, [String: String], String) -> Void) -> Void
        let ended: () -> Void
        var readSource: DispatchSourceRead?
        var writeSource: DispatchSourceWrite?
        var timer: DispatchSourceTimer?
        var input = Data()
        var output = Data()
        var sent = 0
        var dispatched = false
        var closed = false

        init(fd: Int32, queue: DispatchQueue,
             request: @escaping (Request, @escaping (Int, [String: String], String) -> Void) -> Void,
             ended: @escaping () -> Void) {
            self.fd = fd; self.queue = queue; self.request = request; self.ended = ended
        }
        func start() {
            _ = fcntl(fd, F_SETFL, O_NONBLOCK)
            var one: Int32 = 1
            setsockopt(fd, SOL_SOCKET, SO_NOSIGPIPE, &one, 4)
            let read = DispatchSource.makeReadSource(fileDescriptor: fd, queue: queue)
            read.setEventHandler { [weak self] in self?.receive() }
            readSource = read
            read.resume()
            let timeout = DispatchSource.makeTimerSource(queue: queue)
            timeout.schedule(deadline: .now() + 15)
            timeout.setEventHandler { [weak self] in self?.close() }
            timer = timeout
            timeout.resume()
        }
        func receive() {
            guard !dispatched, !closed else { return }
            var bytes = [UInt8](repeating: 0, count: 8192)
            while true {
                let count = recv(fd, &bytes, bytes.count, 0)
                if count < 0 { if errno != EAGAIN && errno != EWOULDBLOCK { close() }; break }
                if count == 0 { close(); return }
                input.append(contentsOf: bytes.prefix(count))
                if input.count > 65_536 { close(); return }
                guard let end = input.range(of: Data([13, 10, 13, 10])) else { continue }
                let header = String(decoding: input[..<end.lowerBound], as: UTF8.self).components(separatedBy: "\r\n")
                let first = header[0].split(separator: " ")
                guard first.count == 3, first[2] == "RTSP/1.0" else { close(); return }
                var headers: [String: String] = [:]
                for line in header.dropFirst() {
                    guard let colon = line.firstIndex(of: ":") else { close(); return }
                    headers[String(line[..<colon]).lowercased()] = line[line.index(after: colon)...].trimmingCharacters(in: .whitespaces)
                }
                guard let length = Int(headers["content-length"] ?? "0"), (0...60_000).contains(length) else { close(); return }
                guard input.count >= end.upperBound + length else { continue }
                let body = String(decoding: input[end.upperBound..<(end.upperBound + length)], as: UTF8.self)
                dispatched = true
                readSource?.cancel()
                request(Request(method: String(first[0]), uri: String(first[1]), cseq: headers["cseq"] ?? "0", body: body)) { [weak self] code, headers, body in
                    guard let self else { return }
                    self.queue.async { self.respond(code, headers: headers, body: body, cseq: headersValue(header, "cseq") ?? "0") }
                }
                return
            }
        }
        func respond(_ code: Int, headers: [String: String], body: String, cseq: String) {
            guard !closed else { return }
            let reason = code == 200 ? "OK" : code == 400 ? "Bad Request" : code == 404 ? "Not Found" : code == 405 ? "Method Not Allowed" : "Internal Server Error"
            var response = "RTSP/1.0 \(code) \(reason)\r\nCSeq: \(cseq)\r\nContent-Length: \(body.utf8.count)\r\n"
            for (name, value) in headers { response += "\(name): \(value)\r\n" }
            output = Data((response + "\r\n" + body).utf8)
            let write = DispatchSource.makeWriteSource(fileDescriptor: fd, queue: queue)
            write.setEventHandler { [weak self] in self?.flush() }
            writeSource = write
            write.resume()
        }
        func flush() {
            guard !closed else { return }
            let count = output.withUnsafeBytes { send(fd, $0.baseAddress!.advanced(by: sent), output.count - sent, 0) }
            if count < 0 { if errno != EAGAIN && errno != EWOULDBLOCK { close() }; return }
            sent += count
            if sent == output.count { close() }
        }
        func close() {
            guard !closed else { return }
            closed = true
            readSource?.cancel(); writeSource?.cancel(); timer?.cancel()
            // Cancellation handlers have no fd work; sources run on this same serial queue.
            Darwin.close(fd)
            ended()
        }
    }
}

private func headersValue(_ lines: [String], _ name: String) -> String? {
    for line in lines.dropFirst() {
        guard let colon = line.firstIndex(of: ":"), line[..<colon].lowercased() == name else { continue }
        return line[line.index(after: colon)...].trimmingCharacters(in: .whitespaces)
    }
    return nil
}
