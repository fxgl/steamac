import Darwin
import Foundation
import QuartzCore

/// VM process: ask SteamOS to fstrim free blocks so virtio-blk DISCARD punches holes in the
/// sparse steamos.img (`compact-disk <id>` → `compact-disk-ok|failed <id> …`; see
/// guest/progress-agent/src/compact.rs). Main thread only. Does not shrink capacity — only
/// allocated size on APFS. Clones and snapshots may retain the freed extents.
final class DiskCompact {
    static let timeout: TimeInterval = 16 * 60

    private let port: ProgressPort
    private var lastAlive: CFTimeInterval = 0
    private var pending: (id: String, path: String, before: UInt64, done: (Result<Outcome, OptionError>) -> Void)?

    struct Outcome {
        let path: String
        let beforeAllocated: UInt64
        let afterAllocated: UInt64
        let detail: String
        var reclaimed: Int64 { Int64(beforeAllocated) - Int64(afterAllocated) }
    }

    init(port: ProgressPort) { self.port = port }

    /// The agent's heartbeat arrived recently (it can answer a request).
    var agentRunning: Bool { lastAlive > 0 && CACurrentMediaTime() - lastAlive < 10 }

    /// One fx.progress line; true if it belonged to a compact transfer.
    func handle(_ line: String) -> Bool {
        if line.hasPrefix("alive ") {
            lastAlive = CACurrentMediaTime()
            return false
        }
        guard line.hasPrefix("compact-disk-") else { return false }
        let parts = line.split(separator: " ", maxSplits: 2, omittingEmptySubsequences: true).map(String.init)
        guard parts.count >= 2, let p = pending, p.id == parts[1] else { return true }
        let rest = parts.count > 2 ? parts[2] : ""
        switch parts[0] {
        case "compact-disk-ok":
            // Give the host filesystem a moment to settle punch-hole extents.
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.4) { [weak self] in
                guard let self, self.pending?.id == p.id else { return }
                let after = Self.allocatedBytes(p.path) ?? p.before
                self.finish(.success(Outcome(path: p.path, beforeAllocated: p.before, afterAllocated: after, detail: rest)))
            }
        case "compact-disk-failed":
            log("compact-disk: guest failure: \(rest)")
            finish(.failure(OptionError("fstrim failed", localized: String(localized: "SteamOS could not trim free blocks. See the log for details."))))
        default:
            return false
        }
        return true
    }

    /// `path` is the running writable disk image (the one virtio-blk backs).
    func request(path: String, done: @escaping (Result<Outcome, OptionError>) -> Void) {
        if pending != nil { finish(.failure(OptionError("superseded"))) }
        if let error = Self.filesystemError(path) {
            done(.failure(error))
            return
        }
        guard agentRunning else {
            done(.failure(OptionError("SteamOS is not ready yet; wait until Steam has started",
                                      localized: String(localized: "SteamOS is not ready yet; wait until Steam has started"))))
            return
        }
        guard let before = Self.allocatedBytes(path) else {
            done(.failure(OptionError("cannot read \(path)", localized: String(localized: "cannot read \(path)"))))
            return
        }
        let id = String(format: "%08x", arc4random())
        guard port.send("compact-disk \(id)") else {
            done(.failure(OptionError("cannot write to the fx.progress port")))
            return
        }
        log("compact-disk: asked the guest to fstrim (request \(id), \(Self.gb(before)) allocated)")
        pending = (id, path, before, done)
        DispatchQueue.main.asyncAfter(deadline: .now() + Self.timeout) { [weak self] in
            guard let self, self.pending?.id == id else { return }
            self.finish(.failure(OptionError("no answer from SteamOS within \(Int(Self.timeout)) s",
                                             localized: String(localized: "no answer from SteamOS within \(Int(Self.timeout)) s"))))
        }
    }

    /// Check the image's actual volume, not the user's home or the bundle volume.
    static func filesystemError(_ path: String) -> OptionError? {
        var fs = statfs()
        guard statfs(path, &fs) == 0 else {
            return OptionError("cannot read filesystem for \(path)", localized: String(localized: "cannot read \(path)"))
        }
        let name = withUnsafePointer(to: &fs.f_fstypename) {
            $0.withMemoryRebound(to: CChar.self, capacity: Int(MFSTYPENAMELEN)) { String(cString: $0) }
        }
        guard name == "apfs" else {
            return OptionError("Reclaim Disk Space requires APFS", localized: String(localized: "Reclaim Disk Space requires the disk image to be on an APFS volume. HFS+, exFAT and other filesystems cannot reclaim space this way."))
        }
        return nil
    }

    static func allocatedBytes(_ path: String) -> UInt64? {
        var st = stat()
        guard stat(path, &st) == 0 else { return nil }
        return UInt64(st.st_blocks) * 512
    }

    static func gb(_ n: UInt64) -> String {
        n < 1_000_000_000
            ? String(format: "%.1f MB", Double(n) / 1e6)
            : String(format: "%.1f GB", Double(n) / 1e9)
    }

    private func finish(_ r: Result<Outcome, OptionError>) {
        guard let p = pending else { return }
        pending = nil
        switch r {
        case .success(let o):
            let delta = o.reclaimed
            let signed = delta >= 0
                ? "reclaimed \(Self.gb(UInt64(delta)))"
                : "allocated grew by \(Self.gb(UInt64(-delta)))"
            log("compact-disk: \(p.id): \(Self.gb(o.beforeAllocated)) → \(Self.gb(o.afterAllocated)) (\(signed)); \(o.detail)")
        case .failure(let e):
            log("compact-disk: \(p.id): \(e)")
        }
        p.done(r)
    }
}
