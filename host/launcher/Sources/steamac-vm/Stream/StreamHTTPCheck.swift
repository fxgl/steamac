import Foundation
import Network
import Security

// Real HTTP/TLS integration check. Separate client keys exercise certificate authentication too.
enum StreamHTTPCheck {
    private final class Delegate: StreamHTTPDelegate {
        weak var server: StreamHTTPServer?
        func streamLaunch(_ launch: StreamLaunch, completion: @escaping (Result<Void, StreamError>) -> Void) {
            guard launch.aesKeyID == 0x80000001, launch.clientAddress == "127.0.0.1" else {
                completion(.failure(StreamError("Incorrect signed rikeyid or launch address")))
                return
            }
            server?.update(StreamServerState(busy: true, clientFingerprint: launch.client.fingerprint, appID: launch.appID))
            completion(.success(()))
        }
        func streamCancel() { server?.update(StreamServerState(busy: false, clientFingerprint: nil, appID: 0)) }
        func streamPairingStarted(_ request: StreamPairingRequest) { request.submit(pin: "1234") }
        func streamPairingEnded(paired: StreamClient?) {}
    }
    static func run() -> [String] {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("steamac-http-check-" + UUID().uuidString).path
        defer { try? FileManager.default.removeItem(atPath: directory) }
        do {
            let identity = try StreamIdentity.loadOrCreate(directory: directory + "/host")
            let client = try StreamIdentity.loadOrCreate(directory: directory + "/client")
            let stranger = try StreamIdentity.loadOrCreate(directory: directory + "/stranger")
            let clients = StreamClientStore(directory: identity.directory)
            let server = StreamHTTPServer(identity: identity, clients: clients, hostName: "SteamAC self-check")
            let delegate = Delegate()
            delegate.server = server
            server.delegate = delegate
            do { try server.start() } catch { return ["HTTP pairing check skipped: standard ports could not be bound: \(error)"] }
            defer { server.stop(); withExtendedLifetime(delegate) {} }
            let done = DispatchSemaphore(value: 0)
            let lock = NSLock()
            var failures = [String]()
            DispatchQueue.global().async {
                var result = [String]()
                do {
                    try pair(client: client, pin: "1234", expected: true)
                    let list = try request("/applist", client: client)
                    guard list.status == 200, list.body.contains("SteamOS") else { throw StreamError("Paired HTTPS applist was rejected") }
                    let rejected = try request("/applist", client: stranger)
                    guard rejected.status == 401, rejected.body.contains("status_code=\"401\"") else { throw StreamError("Unpaired HTTPS applist was accepted") }
                    try pair(client: stranger, pin: "9999", expected: false)
                    guard StreamHTTPServer.normalizedAddress("::FFFF:192.0.2.1%lo0") == "192.0.2.1",
                          StreamHTTPServer.normalizedAddress("fe80:0:0:0:0:0:0:1%en0") == "fe80::1" else { throw StreamError("Client address normalization failed") }
                    try pair(client: stranger, pin: "1234", expected: true)
                    let launch = try request("/launch", params: ["appid": "1", "mode": "1280x720x60", "rikey": String(repeating: "01", count: 16), "rikeyid": "-2147483647"], client: client)
                    guard launch.status == 200, try field("gamesession", launch.body) == "1" else { throw StreamError("Negative rikeyid launch failed: \(launch.body)") }
                    let busy = try request("/serverinfo")
                    guard try field("currentgame", busy.body) == "1" else { throw StreamError("Launch did not publish currentgame") }
                    let denied = try request("/cancel", client: stranger)
                    guard denied.status == 403, try field("cancel", denied.body) == "0" else { throw StreamError("Non-owner cancelled the session") }
                    let stillBusy = try request("/serverinfo")
                    guard try field("currentgame", stillBusy.body) == "1" else { throw StreamError("Rejected cancel changed the session") }
                    let cancelled = try request("/cancel", client: client)
                    guard cancelled.status == 200, try field("cancel", cancelled.body) == "1" else { throw StreamError("Owner cancel failed") }
                    let idle = try request("/serverinfo")
                    guard try field("currentgame", idle.body) == "0" else { throw StreamError("Cancel replied before publishing currentgame=0") }
                } catch { result.append("HTTP pairing check: \(error)") }
                lock.lock(); failures = result; lock.unlock()
                done.signal()
            }
            while done.wait(timeout: .now() + 0.01) != .success {
                if Thread.isMainThread { RunLoop.current.run(until: Date(timeIntervalSinceNow: 0.01)) }
            }
            lock.lock(); let result = failures; lock.unlock()
            return result
        } catch { return ["HTTP identity check: \(error)"] }
    }

    private static func field(_ name: String, _ xml: String) throws -> String {
        guard let start = xml.range(of: "<\(name)>"), let end = xml.range(of: "</\(name)>", range: start.upperBound..<xml.endIndex) else { throw StreamError("Missing XML field \(name): \(xml)") }
        return String(xml[start.upperBound..<end.lowerBound])
    }
    private static func pair(client: StreamIdentity, pin: String, expected: Bool) throws {
        let id = UUID().uuidString
        let salt = try StreamCrypto.random(16)
        let key = Data(StreamCrypto.sha256(salt + Data(pin.utf8)).prefix(16))
        func step(_ params: [String: String], secure: Bool = false) throws -> String {
            var params = params; params["uniqueid"] = id
            return try request("/pair", params: params, client: secure ? client : nil).body
        }
        let first = try step(["phrase": "getservercert", "salt": StreamCrypto.hex(salt), "clientcert": StreamCrypto.hex(StreamCrypto.pem(client.certificateDER)), "devicename": "Self-check"])
        let serverCert = try StreamCrypto.certificateDER(StreamCrypto.unhex(field("plaincert", first)) ?? Data())
        let challenge = try StreamCrypto.random(16)
        let encrypted = try StreamCrypto.crypt(challenge, key: key, encrypt: true)
        let second = try step(["clientchallenge": StreamCrypto.hex(encrypted)])
        guard let response = StreamCrypto.unhex(try field("challengeresponse", second)) else { throw StreamError("Invalid server challenge") }
        let decoded = try StreamCrypto.crypt(response, key: key, encrypt: false)
        guard decoded.count == 48 else { throw StreamError("Invalid challenge length") }
        let secret = try StreamCrypto.random(16)
        let hash = StreamCrypto.sha256(Data(decoded.suffix(16)) + client.signature + secret)
        let third = try step(["serverchallengeresp": StreamCrypto.hex(try StreamCrypto.crypt(hash, key: key, encrypt: true))])
        guard let proof = StreamCrypto.unhex(try field("pairingsecret", third)), proof.count > 16 else { throw StreamError("Invalid server pairing secret") }
        if expected {
            guard StreamCrypto.verify(Data(proof.prefix(16)), signature: Data(proof.dropFirst(16)), certificate: serverCert),
                  StreamCrypto.sha256(challenge + (try StreamDER.certificateSignature(serverCert)) + proof.prefix(16)) == decoded.prefix(32) else { throw StreamError("Server pairing proof failed") }
        }
        let final = try step(["clientpairingsecret": StreamCrypto.hex(secret + StreamCrypto.sign(secret, key: client.privateKey))])
        guard (try field("paired", final) == "1") == expected else { throw StreamError("Wrong pairing result: \(final)") }
        if expected {
            let complete = try step(["phrase": "pairchallenge"], secure: true)
            guard try field("paired", complete) == "1" else { throw StreamError("HTTPS pairchallenge failed") }
        }
    }

    private struct Response { let status: Int; let body: String }
    private static func request(_ path: String, params: [String: String] = [:], client: StreamIdentity? = nil) throws -> Response {
        var url = URLComponents(); url.path = path; url.queryItems = params.sorted { $0.key < $1.key }.map { URLQueryItem(name: $0.key, value: $0.value) }
        let queue = DispatchQueue(label: "steamac.stream.check.client")
        let configuration: NWParameters
        if let client {
            let tls = NWProtocolTLS.Options()
            sec_protocol_options_set_local_identity(tls.securityProtocolOptions, sec_identity_create(client.tlsIdentity)!)
            sec_protocol_options_set_verify_block(tls.securityProtocolOptions, { _, _, complete in complete(true) }, queue)
            configuration = NWParameters(tls: tls, tcp: NWProtocolTCP.Options())
        } else { configuration = .tcp }
        let connection = NWConnection(host: "127.0.0.1", port: NWEndpoint.Port(rawValue: client == nil ? StreamPorts.http : StreamPorts.https)!, using: configuration)
        let done = DispatchSemaphore(value: 0)
        var received = Data()
        var failure: Error?
        var finished = false
        func finish(_ error: Error? = nil) { guard !finished else { return }; finished = true; failure = error; done.signal() }
        func receive() {
            connection.receive(minimumIncompleteLength: 1, maximumLength: 65536) { data, _, complete, error in
                if let data { received.append(data) }
                if let error { finish(error) }
                else if complete { finish() }
                else { receive() }
            }
        }
        connection.stateUpdateHandler = { state in
            switch state {
            case .ready:
                let request = "GET \(url.string!) HTTP/1.1\r\nHost: 127.0.0.1\r\nConnection: close\r\n\r\n"
                connection.send(content: Data(request.utf8), completion: .contentProcessed { error in if let error { finish(error) } else { receive() } })
            case .failed(let error): finish(error)
            default: break
            }
        }
        connection.start(queue: queue)
        let timedOut = done.wait(timeout: .now() + 10) != .success
        connection.cancel()
        if timedOut { throw StreamError("Self-check HTTP request timed out") }
        if let failure { throw failure }
        guard let response = String(data: received, encoding: .utf8), let separator = response.range(of: "\r\n\r\n"),
              let status = response.components(separatedBy: " ").dropFirst().first.flatMap(Int.init) else { throw StreamError("Invalid self-check HTTP response") }
        return Response(status: status, body: String(response[separator.upperBound...]))
    }
}
