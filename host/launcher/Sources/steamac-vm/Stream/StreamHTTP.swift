import AppKit
import Foundation
import Network
import Security

struct StreamServerState { var busy: Bool; var clientFingerprint: String?; var appID: Int }
protocol StreamHTTPDelegate: AnyObject {
    func streamLaunch(_ launch: StreamLaunch, completion: @escaping (Result<Void, StreamError>) -> Void)
    func streamCancel()
    func streamPairingStarted(_ request: StreamPairingRequest)
    func streamPairingEnded(paired: StreamClient?)
}

final class StreamHTTPServer {
    weak var delegate: StreamHTTPDelegate?
    private let identity: StreamIdentity
    private let clients: StreamClientStore
    private let hostName: String
    private let queue = DispatchQueue(label: "steamac.stream.http")
    private var listeners = [NWListener]()
    private var connections = [UUID: Connection]()
    private var state = StreamServerState(busy: false, clientFingerprint: nil, appID: 0)
    private var running = false
    private let artwork: Data
    private lazy var pairing: StreamPairing = {
        let pairing = StreamPairing(identity: identity, clients: clients, queue: queue)
        pairing.started = { [weak self] request in DispatchQueue.main.async { [weak self] in self?.delegate?.streamPairingStarted(request) } }
        pairing.ended = { [weak self] client in DispatchQueue.main.async { [weak self] in self?.delegate?.streamPairingEnded(paired: client) } }
        return pairing
    }()

    init(identity: StreamIdentity, clients: StreamClientStore, hostName: String) {
        self.identity = identity; self.clients = clients; self.hostName = hostName
        artwork = Self.makeArtwork()
    }
    func start() throws {
        let plainParameters = NWParameters.tcp
        plainParameters.allowLocalEndpointReuse = true
        let plain = try NWListener(using: plainParameters, on: NWEndpoint.Port(rawValue: StreamPorts.http)!)
        plain.service = NWListener.Service(name: hostName, type: "_nvstream._tcp")
        let tls = NWProtocolTLS.Options()
        guard let localIdentity = sec_identity_create(identity.tlsIdentity) else { throw StreamError("Cannot create TLS identity") }
        sec_protocol_options_set_local_identity(tls.securityProtocolOptions, localIdentity)
        sec_protocol_options_set_min_tls_protocol_version(tls.securityProtocolOptions, .TLSv12)
        sec_protocol_options_set_peer_authentication_required(tls.securityProtocolOptions, true)
        sec_protocol_options_set_verify_block(tls.securityProtocolOptions, { _, _, complete in complete(true) }, queue)
        let secureParameters = NWParameters(tls: tls, tcp: NWProtocolTCP.Options())
        secureParameters.allowLocalEndpointReuse = true
        let secure = try NWListener(using: secureParameters, on: NWEndpoint.Port(rawValue: StreamPorts.https)!)
        let ready = DispatchSemaphore(value: 0)
        let lock = NSLock()
        var failure: NWError?
        queue.sync { running = true; listeners = [plain, secure] }
        for (listener, encrypted) in [(plain, false), (secure, true)] {
            var signaled = false
            listener.stateUpdateHandler = { state in
                switch state {
                case .ready:
                    if !signaled { signaled = true; ready.signal() }
                case .failed(let error):
                    lock.lock(); failure = error; lock.unlock()
                    if !signaled { signaled = true; ready.signal() }
                default: break
                }
            }
            listener.newConnectionHandler = { [weak self] connection in
                guard let self, self.running else { connection.cancel(); return }
                let peer = Connection(connection, secure: encrypted, server: self)
                self.connections[peer.id] = peer
                peer.start()
            }
            listener.start(queue: queue)
        }
        for _ in 0..<2 {
            if ready.wait(timeout: .now() + 5) == .timedOut { stop(); throw StreamError("Streaming listener startup timed out") }
        }
        lock.lock(); let error = failure; lock.unlock()
        if let error { stop(); throw StreamError("Cannot bind GameStream HTTP ports: \(error)") }
    }
    func stop() {
        queue.sync {
            running = false
            pairing.cancel()
            listeners.forEach { $0.cancel() }; listeners.removeAll()
            for peer in connections.values { peer.connection.cancel() }
            connections.removeAll()
        }
    }
    func update(_ state: StreamServerState) { queue.async { self.state = state } }

    private static func xml(_ text: String) -> String {
        text.replacingOccurrences(of: "&", with: "&amp;").replacingOccurrences(of: "<", with: "&lt;").replacingOccurrences(of: ">", with: "&gt;").replacingOccurrences(of: "\"", with: "&quot;").replacingOccurrences(of: "'", with: "&apos;")
    }
    private static func root(_ body: String, code: Int = 200, message: String = "") -> String {
        "<?xml version=\"1.0\" encoding=\"utf-8\"?><root status_code=\"\(code)\" status_message=\"\(xml(message))\">\(body)</root>"
    }
    private func handle(path: String, params: [String: String], peer: Connection, reply: @escaping (Data, String, Int) -> Void) {
        func respond(_ body: String, code: Int = 200, message: String = "") { reply(Data(Self.root(body, code: code, message: message).utf8), "application/xml", code) }
        let client = peer.fingerprint.flatMap { clients.client(fingerprint: $0) }
        if path == "/serverinfo" {
            let hevc = StreamCodec.hardwareSupported.contains(.hevc)
            respond("<hostname>\(Self.xml(hostName))</hostname><appversion>7.1.431.-1</appversion><GfeVersion>3.23.0.74</GfeVersion><uniqueid>\(identity.uniqueID)</uniqueid><HttpsPort>\(StreamPorts.https)</HttpsPort><ExternalPort>\(StreamPorts.http)</ExternalPort><mac>00:00:00:00:00:00</mac><LocalIP>\(Self.xml(peer.localAddress))</LocalIP><ServerCodecModeSupport>\(hevc ? 257 : 1)</ServerCodecModeSupport><MaxLumaPixelsHEVC>\(hevc ? 1869449984 : 0)</MaxLumaPixelsHEVC><SupportedDisplayMode></SupportedDisplayMode><PairStatus>\(peer.secure && client != nil ? 1 : 0)</PairStatus><currentgame>\(state.busy ? state.appID : 0)</currentgame><state>\(state.busy ? "STEAMAC_SERVER_BUSY" : "STEAMAC_SERVER_FREE")</state>")
            return
        }
        if path == "/pair" {
            pairing.handle(params, address: peer.remoteAddress, fingerprint: peer.fingerprint) { xml in reply(Data(xml.utf8), "application/xml", 200) }
            return
        }
        if path == "/unpair", !peer.secure {
            pairing.cancel(id: params["uniqueid"], address: peer.remoteAddress)
            respond("<paired>0</paired>"); return
        }
        guard peer.secure, let client else { respond("", code: 401, message: "Client certificate is not paired"); return }
        switch path {
        case "/unpair":
            clients.remove(fingerprint: client.fingerprint)
            if state.clientFingerprint == client.fingerprint { DispatchQueue.main.async { [weak self] in self?.delegate?.streamCancel() } }
            respond("<paired>0</paired>")
        case "/applist": respond("<App><IsHdrSupported>0</IsHdrSupported><AppTitle>SteamOS</AppTitle><ID>1</ID></App>")
        case "/appasset": reply(artwork, "image/png", 200)
        case "/cancel":
            guard !state.busy || state.clientFingerprint == client.fingerprint else {
                respond("<cancel>0</cancel>", code: 403, message: "Session belongs to another client")
                return
            }
            DispatchQueue.main.async { [weak self] in
                guard let delegate = self?.delegate else { respond("<cancel>0</cancel>", code: 503, message: "Streaming is unavailable"); return }
                delegate.streamCancel()
                respond("<cancel>1</cancel>")
            }
        case "/launch", "/resume":
            let mode = (params["mode"] ?? "1920x1080x60").split(separator: "x").compactMap { Int($0) }
            guard mode.count == 3, (1...16384).contains(mode[0]), (1...16384).contains(mode[1]), (1...240).contains(mode[2]),
                  let key = params["rikey"].flatMap(StreamCrypto.unhex), key.count == 16,
                  let keyID = params["rikeyid"].flatMap(Int64.init), (-2147483648...4294967295).contains(keyID),
                  let appID = Int(params["appid"] ?? "1"), appID == 1,
                  let audio = UInt32(params["surroundAudioInfo"] ?? "196610"), let controllers = UInt16(params["remoteControllersBitmap"] ?? "0") else { respond("", code: 400, message: "Invalid launch parameters"); return }
            let launch = StreamLaunch(client: client, clientAddress: peer.remoteAddress, appID: appID, width: mode[0], height: mode[1], fps: mode[2], aesKey: key, aesKeyID: UInt32(truncatingIfNeeded: keyID), playAudioOnHost: params["localAudioPlayMode"] == "1", surroundAudioInfo: audio, remoteControllersBitmap: controllers, resume: path == "/resume")
            DispatchQueue.main.async { [weak self, weak peer] in
                guard let self, let peer, let delegate = self.delegate else { reply(Data(Self.root("", code: 503, message: "Streaming is unavailable").utf8), "application/xml", 503); return }
                delegate.streamLaunch(launch) { result in
                    self.queue.async {
                        switch result {
                        case .success:
                            let address = peer.localAddress.contains(":") ? "[\(peer.localAddress)]" : peer.localAddress
                            reply(Data(Self.root("<sessionUrl0>rtsp://\(Self.xml(address)):\(StreamPorts.rtsp)</sessionUrl0><gamesession>1</gamesession>").utf8), "application/xml", 200)
                        case .failure(let error): reply(Data(Self.root("<gamesession>0</gamesession>", code: 503, message: error.description).utf8), "application/xml", 503)
                        }
                    }
                }
            }
        default: respond("", code: 404, message: "Unknown endpoint")
        }
    }

    private static func makeArtwork() -> Data {
        let bitmap = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: 600, pixelsHigh: 801, bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: bitmap)
        NSColor(calibratedRed: 0.07, green: 0.09, blue: 0.13, alpha: 1).setFill()
        NSBezierPath(rect: NSRect(x: 0, y: 0, width: 600, height: 801)).fill()
        let image = NSImage(named: NSImage.applicationIconName) ?? NSWorkspace.shared.icon(forFile: Bundle.main.bundlePath)
        image.draw(in: NSRect(x: 44, y: 145, width: 512, height: 512), from: .zero, operation: .sourceOver, fraction: 1)
        NSGraphicsContext.restoreGraphicsState()
        return bitmap.representation(using: .png, properties: [:])!
    }

    static func normalizedAddress(_ string: String) -> String {
        let address = string.components(separatedBy: "%")[0]
        if let ipv6 = IPv6Address(address) {
            let bytes = ipv6.rawValue
            if bytes.prefix(10).allSatisfy({ $0 == 0 }), bytes[10] == 0xff, bytes[11] == 0xff,
               let ipv4 = IPv4Address(Data(bytes.suffix(4))) { return "\(ipv4)" }
            return "\(ipv6)"
        }
        if let ipv4 = IPv4Address(address) { return "\(ipv4)" }
        return address
    }

    private final class Connection {
        let id = UUID()
        let connection: NWConnection
        let secure: Bool
        weak var server: StreamHTTPServer?
        var fingerprint: String?
        var buffer = Data()
        var responding = false
        var closeAfterResponse = false
        var remoteAddress: String { Self.address(connection.endpoint) }
        var localAddress: String { connection.currentPath?.localEndpoint.map(Self.address) ?? "127.0.0.1" }
        init(_ connection: NWConnection, secure: Bool, server: StreamHTTPServer) { self.connection = connection; self.secure = secure; self.server = server }
        static func address(_ endpoint: NWEndpoint) -> String {
            if case .hostPort(let host, _) = endpoint { return StreamHTTPServer.normalizedAddress("\(host)") }
            return "127.0.0.1"
        }
        func start() {
            guard let server else { return }
            connection.stateUpdateHandler = { [weak self] state in
                guard let self else { return }
                switch state {
                case .ready:
                    if let metadata = self.connection.metadata(definition: NWProtocolTLS.definition) as? NWProtocolTLS.Metadata {
                        sec_protocol_metadata_access_peer_certificate_chain(metadata.securityProtocolMetadata) { cert in
                            if self.fingerprint == nil {
                                let ref = sec_certificate_copy_ref(cert).takeRetainedValue()
                                self.fingerprint = StreamCrypto.hex(StreamCrypto.sha256(SecCertificateCopyData(ref) as Data))
                            }
                        }
                    }
                    self.receive()
                case .failed:
                    self.connection.cancel()
                    self.server?.connections.removeValue(forKey: self.id)
                case .cancelled: self.server?.connections.removeValue(forKey: self.id)
                default: break
                }
            }
            connection.start(queue: server.queue)
            server.queue.asyncAfter(deadline: .now() + 90) { [weak self] in self?.connection.cancel() }
        }
        func receive() {
            connection.receive(minimumIncompleteLength: 1, maximumLength: 16384) { [weak self] data, _, complete, error in
                guard let self else { return }
                if let data { self.buffer.append(data) }
                if error != nil { self.connection.cancel(); return }
                self.closeAfterResponse = self.closeAfterResponse || complete
                self.process()
                if complete && !self.responding { self.connection.cancel() }
                else if !self.responding { self.receive() }
            }
        }
        func process() {
            guard !responding, let server else { return }
            guard buffer.count <= 262144 else { connection.cancel(); return }
            guard let end = buffer.range(of: Data("\r\n\r\n".utf8)) else { return }
            guard let header = String(data: buffer[..<end.lowerBound], encoding: .utf8) else { connection.cancel(); return }
            buffer.removeSubrange(..<end.upperBound)
            let lines = header.components(separatedBy: "\r\n")
            let first = (lines.first ?? "").split(separator: " ")
            guard first.count == 3, first[0] == "GET", ["HTTP/1.0", "HTTP/1.1"].contains(first[2]),
                  let url = URLComponents(string: String(first[1])), url.path.first == "/" else { connection.cancel(); return }
            if first[2] == "HTTP/1.0" { closeAfterResponse = true }
            for line in lines.dropFirst() {
                let pair = line.split(separator: ":", maxSplits: 1)
                guard pair.count == 2 else { connection.cancel(); return }
                let name = pair[0].lowercased(), value = pair[1].trimmingCharacters(in: .whitespaces).lowercased()
                if name == "connection", value == "close" { closeAfterResponse = true }
                if name == "transfer-encoding" || (name == "content-length" && value != "0") { connection.cancel(); return }
            }
            var params = [String: String]()
            for item in url.queryItems ?? [] { params[item.name] = item.value ?? "" }
            responding = true
            server.handle(path: url.path, params: params, peer: self) { [weak self] data, type, status in
                guard let self, let server = self.server else { return }
                server.queue.async {
                    let reason = status == 200 ? "OK" : (status == 401 ? "Unauthorized" : "Error")
                    let header = "HTTP/1.1 \(status) \(reason)\r\nContent-Type: \(type)\r\nContent-Length: \(data.count)\r\nConnection: \(self.closeAfterResponse ? "close" : "keep-alive")\r\n\r\n"
                    self.connection.send(content: Data(header.utf8) + data, completion: .contentProcessed { error in
                        self.responding = false
                        if error != nil || self.closeAfterResponse { self.connection.cancel() }
                        else if !self.buffer.isEmpty { self.process(); if !self.responding { self.receive() } }
                        else { self.receive() }
                    })
                }
            }
        }
    }

    static func selfCheck() -> [String] { StreamHTTPCheck.run() }
}
