import Foundation

final class StreamClientStore {
    private let lock = NSLock()
    private let path: String
    private var saved = [StreamClient]()
    private var changed: (() -> Void)?

    init(directory: String) {
        path = directory + "/clients.json"
        if FileManager.default.fileExists(atPath: path) {
            do {
                try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: path)
                saved = try JSONDecoder().decode([StreamClient].self, from: Data(contentsOf: URL(fileURLWithPath: path)))
            } catch { log("stream: cannot read paired clients: \(error)") }
        }
    }
    var clients: [StreamClient] {
        lock.lock(); defer { lock.unlock() }
        return saved
    }
    var onChange: (() -> Void)? {
        get { lock.lock(); defer { lock.unlock() }; return changed }
        set { lock.lock(); changed = newValue; lock.unlock() }
    }
    func client(fingerprint: String) -> StreamClient? {
        lock.lock(); defer { lock.unlock() }
        return saved.first { $0.fingerprint == fingerprint }
    }
    func add(_ client: StreamClient) { mutate { list in list.removeAll { $0.fingerprint == client.fingerprint }; list.append(client) } }
    func remove(fingerprint: String) { mutate { $0.removeAll { $0.fingerprint == fingerprint } } }
    private func mutate(_ body: (inout [StreamClient]) -> Void) {
        lock.lock()
        var next = saved
        body(&next)
        do {
            try StreamIdentity.protectedWrite(JSONEncoder().encode(next), to: path)
            saved = next
            let callback = changed
            lock.unlock()
            if let callback { DispatchQueue.main.async(execute: callback) }
        } catch {
            lock.unlock()
            log("stream: cannot save paired clients: \(error)")
        }
    }
}
