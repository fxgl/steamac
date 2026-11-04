import Combine
import Foundation

final class GameStreamHost: ObservableObject, StreamHTTPDelegate {
    enum Status: Equatable {
        case off
        case listening
        case failed(String)
        case streaming(StreamSessionInfo)
    }

    @Published private(set) var status: Status = .off
    @Published private(set) var clients: [StreamClient] = []
    @Published private(set) var pairing: StreamPairingRequest?
    private let environment: StreamEnvironment
    private let hostName: String
    private var identity: StreamIdentity?
    private let store: StreamClientStore
    private var http: StreamHTTPServer?
    private var session: StreamSession?
    private var enabled = false

    init(environment: StreamEnvironment, hostName: String) {
        self.environment = environment
        self.hostName = hostName
        // Paired clients stay listed (and revocable) while the host is off; the host key and
        // certificate are only created once streaming is enabled.
        let store = StreamClientStore(directory: StreamIdentity.defaultDirectory)
        self.store = store
        clients = store.clients
        store.onChange = { [weak self, weak store] in self?.clients = store?.clients ?? [] }
    }

    private func prepare() throws {
        guard http == nil else { return }
        let identity = try StreamIdentity.loadOrCreate()
        let server = StreamHTTPServer(identity: identity, clients: store, hostName: hostName)
        server.delegate = self
        self.identity = identity
        http = server
    }

    func setEnabled(_ on: Bool) {
        if !on {
            enabled = false
            pairing?.cancel()
            pairing = nil
            endSession()
            http?.stop()
            status = .off
            return
        }
        if enabled { return }
        do {
            try prepare()
            try http?.start()
            enabled = true
            status = .listening
            updateServerState()
        } catch {
            http?.stop()
            enabled = false
            status = .failed(String(describing: error))
            log("stream: listener startup failed: \(error)")
        }
    }

    func revoke(fingerprint: String) {
        if session?.launch.client.fingerprint == fingerprint { endSession() }
        store.remove(fingerprint: fingerprint)
        clients = store.clients
    }

    func endSession() {
        guard let active = session else { return }
        session = nil
        active.stop()
        environment.display.end()
        status = enabled ? .listening : .off
        updateServerState()
    }

    func streamLaunch(_ launch: StreamLaunch, completion: @escaping (Result<Void, StreamError>) -> Void) {
        guard enabled else { completion(.failure(StreamError("Streaming is disabled"))); return }
        guard launch.appID == 1, (320...8192).contains(launch.width), (200...8192).contains(launch.height),
              (1...240).contains(launch.fps), launch.aesKey.count == 16 else {
            completion(.failure(StreamError("Invalid launch configuration"))); return
        }
        if let active = session {
            guard active.launch.client.fingerprint == launch.client.fingerprint, launch.resume else {
                completion(.failure(StreamError("A client is already streaming"))); return
            }
            endSession()
        }
        let active = StreamSession(launch: launch, environment: environment)
        session = active
        active.onStarted = { [weak self, weak active] info in
            guard let self, let active, self.session === active else { return }
            self.status = .streaming(info)
        }
        active.onEnded = { [weak self, weak active] message in
            guard let self, let active, self.session === active else { return }
            if let message { log("stream: session ended: \(message)") }
            self.endSession()
        }
        environment.display.begin(launch.width, launch.height)
        do {
            try active.start()
            updateServerState()
            completion(.success(()))
        } catch {
            endSession()
            completion(.failure(StreamError(String(describing: error))))
        }
    }

    func streamCancel() { endSession() }

    func streamPairingStarted(_ request: StreamPairingRequest) {
        guard enabled else { request.cancel(); return }
        pairing?.cancel()
        pairing = request
    }

    func streamPairingEnded(paired: StreamClient?) {
        pairing = nil
        clients = store.clients
    }

    private func updateServerState() {
        http?.update(StreamServerState(busy: session != nil, clientFingerprint: session?.launch.client.fingerprint, appID: session == nil ? 0 : 1))
    }
}
