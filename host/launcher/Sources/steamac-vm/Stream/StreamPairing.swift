import Foundation

// Confined to the HTTP server's serial queue, including PIN answers and timeouts.
final class StreamPairing {
    private final class Attempt {
        let id: String
        let address: String
        let name: String
        let certificate: Data
        let salt: Data
        var key: Data?
        var secret: Data?
        var challenge: Data?
        var clientHash: Data?
        var waiting: ((String) -> Void)?
        init(id: String, address: String, name: String, certificate: Data, salt: Data, waiting: @escaping (String) -> Void) {
            self.id = id; self.address = address; self.name = name; self.certificate = certificate; self.salt = salt; self.waiting = waiting
        }
    }
    let identity: StreamIdentity
    let clients: StreamClientStore
    let queue: DispatchQueue
    var started: ((StreamPairingRequest) -> Void)?
    var ended: ((StreamClient?) -> Void)?
    private var attempt: Attempt?

    init(identity: StreamIdentity, clients: StreamClientStore, queue: DispatchQueue) {
        self.identity = identity; self.clients = clients; self.queue = queue
    }
    private func response(_ body: String = "", paired: Bool = true) -> String { "<root status_code=\"200\"><paired>\(paired ? 1 : 0)</paired>\(body)</root>" }
    func cancel() {
        guard let current = attempt else { return }
        attempt = nil
        current.waiting?(response(paired: false))
        ended?(nil)
    }
    func cancel(id: String?, address: String) {
        if let current = attempt, current.id == id, current.address == address { cancel() }
    }
    func handle(_ params: [String: String], address: String, fingerprint: String?, reply: @escaping (String) -> Void) {
        do {
            guard let id = params["uniqueid"], !id.isEmpty, id.count <= 256 else { throw StreamError("Missing pairing id") }
            if params["phrase"] == "getservercert" {
                guard attempt == nil else { reply(response(paired: false)); return }
                guard let encoded = params["clientcert"].flatMap(StreamCrypto.unhex),
                      let salt = params["salt"].flatMap(StreamCrypto.unhex), salt.count == 16 else { throw StreamError("Invalid pairing certificate or salt") }
                let cert = try StreamCrypto.certificateDER(encoded)
                let name = String((params["devicename"] ?? "Moonlight").prefix(256))
                let current = Attempt(id: id, address: address, name: name, certificate: cert, salt: salt, waiting: reply)
                attempt = current
                let request = StreamPairingRequest(clientName: name) { [weak self, weak current] pin in
                    guard let self, let current else { return }
                    self.queue.async { [weak self, weak current] in
                        guard let self, let current, self.attempt === current else { return }
                        guard let pin, pin.count == 4, pin.utf8.allSatisfy({ (48...57).contains($0) }) else { self.cancel(); return }
                        current.key = Data(StreamCrypto.sha256(current.salt + Data(pin.utf8)).prefix(16))
                        let callback = current.waiting; current.waiting = nil
                        callback?(self.response("<plaincert>\(StreamCrypto.hex(StreamCrypto.pem(self.identity.certificateDER)))</plaincert>"))
                    }
                }
                started?(request)
                queue.asyncAfter(deadline: .now() + 60) { [weak self, weak current] in
                    guard let self, let current, self.attempt === current else { return }
                    self.cancel()
                }
                return
            }
            if params["phrase"] == "pairchallenge", let fingerprint, clients.client(fingerprint: fingerprint) != nil {
                reply(response()); return
            }
            guard let current = attempt, current.id == id, current.address == address, let key = current.key else { throw StreamError("No matching pairing attempt") }
            if let challenge = params["clientchallenge"].flatMap(StreamCrypto.unhex), challenge.count == 16, current.secret == nil {
                let plain = try StreamCrypto.crypt(challenge, key: key, encrypt: false)
                let secret = try StreamCrypto.random(16)
                let serverChallenge = try StreamCrypto.random(16)
                current.secret = secret; current.challenge = serverChallenge
                let hash = StreamCrypto.sha256(plain + identity.signature + secret)
                let encrypted = try StreamCrypto.crypt(hash + serverChallenge, key: key, encrypt: true)
                reply(response("<challengeresponse>\(StreamCrypto.hex(encrypted))</challengeresponse>"))
            } else if let hash = params["serverchallengeresp"].flatMap(StreamCrypto.unhex), hash.count == 32, let secret = current.secret, current.clientHash == nil {
                current.clientHash = try StreamCrypto.crypt(hash, key: key, encrypt: false)
                let signature = try StreamCrypto.sign(secret, key: identity.privateKey)
                reply(response("<pairingsecret>\(StreamCrypto.hex(secret + signature))</pairingsecret>"))
            } else if let proof = params["clientpairingsecret"].flatMap(StreamCrypto.unhex), proof.count > 16,
                      let challenge = current.challenge, let hash = current.clientHash {
                let secret = Data(proof.prefix(16))
                let expected = StreamCrypto.sha256(challenge + (try StreamDER.certificateSignature(current.certificate)) + secret)
                guard expected == hash, StreamCrypto.verify(secret, signature: Data(proof.dropFirst(16)), certificate: current.certificate) else { throw StreamError("Pairing PIN or client signature is incorrect") }
                let client = StreamClient(fingerprint: StreamCrypto.hex(StreamCrypto.sha256(current.certificate)), name: current.name, certificate: current.certificate, pairedAt: Date())
                clients.add(client)
                guard clients.client(fingerprint: client.fingerprint) != nil else { throw StreamError("Cannot persist paired client") }
                attempt = nil
                ended?(client)
                reply(response())
            } else if params["phrase"] == "pairchallenge", current.clientHash != nil {
                reply(response())
            } else { throw StreamError("Invalid pairing sequence") }
        } catch {
            log("stream: pairing failed: \(error)")
            if attempt?.address == address, attempt?.id == params["uniqueid"] { cancel() }
            reply(response(paired: false))
        }
    }
}
