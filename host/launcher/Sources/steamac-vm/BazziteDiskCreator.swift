import CryptoKit
import Darwin
import Foundation

/// The GitHub manifest supplies SHA-256 hashes over HTTPS. This is integrity
/// checking against the owner's release, not an independent code signature.
final class BazziteDiskCreator {
    var onStatus: ((DiskCreator.Status) -> Void)?
    private let lock = NSLock()
    private var cancelled = false
    private var task: URLSessionTask?
    private var process: Process?

    func cancel() {
        lock.lock(); cancelled = true; let t = task, p = process; lock.unlock()
        t?.cancel()
        if let p, p.isRunning { p.terminate() }
    }
    private func checkCancel() throws {
        lock.lock(); let stop = cancelled; lock.unlock()
        if stop { throw DiskCreator.Cancelled() }
    }
    private func report(_ title: String, _ detail: String = "", _ fraction: Double) {
        onStatus?(.init(title: title, detail: detail, localizedTitle: title, localizedDetail: detail, fraction: fraction))
    }
    func fetch(_ url: URL) throws -> Data {
        try checkCancel()
        let semaphore = DispatchSemaphore(value: 0)
        var result: Swift.Result<Data, Error> = .failure(OptionError("No GitHub response"))
        var request = URLRequest(url: url, cachePolicy: .reloadIgnoringLocalCacheData, timeoutInterval: 60)
        request.setValue("no-cache", forHTTPHeaderField: "Cache-Control")
        request.setValue("steamac-bazzite", forHTTPHeaderField: "User-Agent")
        let t = URLSession.shared.dataTask(with: request) { data, response, error in
            defer { semaphore.signal() }
            if let error { result = .failure(error); return }
            guard (response as? HTTPURLResponse)?.statusCode == 200, let data, data.count <= 4_000_000 else {
                result = .failure(OptionError("GitHub metadata unavailable (HTTP \((response as? HTTPURLResponse)?.statusCode ?? 0))")); return
            }
            result = .success(data)
        }
        lock.lock(); task = t; let stop = cancelled; lock.unlock()
        t.resume(); if stop { t.cancel() }; semaphore.wait()
        lock.lock(); task = nil; lock.unlock()
        try checkCancel()
        return try result.get()
    }
    func releases() throws -> [BazziteRelease] {
        try JSONDecoder().decode([BazziteRelease].self, from: fetch(BazziteRelease.api))
            .filter { !$0.draft && $0.manifestURL != nil }
    }
    private func download(_ url: URL, asset: BazziteGuest.Asset, to destination: URL, index: Int) throws {
        try checkCancel()
        try BazziteRelease.validateAssetURL(url)
        let d = BazziteDownload(destination: destination, expectedBytes: asset.bytes) { [weak self] fraction in
            self?.report("Downloading Bazzite…", asset.name, 0.05 + (Double(index) + fraction) * 0.23)
        }
        let session = URLSession(configuration: .ephemeral, delegate: d, delegateQueue: nil)
        defer { session.invalidateAndCancel() }
        let t = session.downloadTask(with: url)
        lock.lock(); task = t; let stop = cancelled; lock.unlock()
        t.resume(); if stop { t.cancel() }; d.done.wait()
        lock.lock(); task = nil; lock.unlock()
        try checkCancel()
        if let error = d.error { throw error }
        guard try Self.sha256(destination) == asset.sha256 else { throw OptionError("SHA-256 mismatch: \(asset.name)") }
    }
    static func sha256(_ url: URL) throws -> String {
        let file = try FileHandle(forReadingFrom: url)
        defer { try? file.close() }
        var hash = SHA256()
        while let data = try file.read(upToCount: 1 << 20), !data.isEmpty { hash.update(data: data) }
        return hash.finalize().map { String(format: "%02x", $0) }.joined()
    }
    func run(path: String, release: BazziteRelease) throws -> DiskCreator.Result {
        let fm = FileManager.default
        let path = (path as NSString).standardizingPath
        guard !fm.fileExists(atPath: path), !fm.fileExists(atPath: BazziteGuest.directory(path)),
              let manifestURL = release.manifestURL else { throw OptionError("Choose a new disk path and a Bazzite release") }
        try BazziteRelease.validateAssetURL(manifestURL)
        report("Reading Bazzite release…", release.title, 0)
        let data = try fetch(manifestURL)
        let manifest = try JSONDecoder().decode(BazziteGuest.self, from: data)
        try manifest.validate()
        let parent = URL(fileURLWithPath: path).deletingLastPathComponent()
        try fm.createDirectory(at: parent, withIntermediateDirectories: true)
        let stage = parent.appendingPathComponent(".bazzite-" + UUID().uuidString)
        try fm.createDirectory(at: stage, withIntermediateDirectories: false)
        defer { try? fm.removeItem(at: stage) }
        // Unique staging means cancellation never overwrites a user's disk.
        for (index, asset) in [manifest.disk, manifest.kernel, manifest.initrd].enumerated() {
            guard let entry = release.assets.first(where: { $0.name == asset.name }) else { throw OptionError("Missing GitHub asset: \(asset.name)") }
            try download(entry.browser_download_url, asset: asset, to: stage.appendingPathComponent(asset.name), index: index)
        }
        report("Preparing Bazzite disk…", "Sparse disk; empty blocks use no storage", 0.75)
        let disk = stage.appendingPathComponent("disk.img")
        try extract(stage.appendingPathComponent(manifest.disk.name), to: disk, expectedBytes: manifest.diskBytes)
        let gpt = try GPT.read(path: disk.path)
        guard gpt.sectors * 512 == UInt64(manifest.diskBytes) else { throw OptionError("Bazzite disk GPT size mismatch") }
        try checkCancel()
        let sidecar = stage.appendingPathComponent("boot")
        try fm.createDirectory(at: sidecar, withIntermediateDirectories: false)
        for name in [manifest.kernel.name, manifest.initrd.name] {
            try fm.moveItem(at: stage.appendingPathComponent(name), to: sidecar.appendingPathComponent(name))
        }
        try data.write(to: sidecar.appendingPathComponent("bazzite-steamac.json"))
        try fm.moveItem(atPath: sidecar.path, toPath: BazziteGuest.directory(path))
        do { try fm.moveItem(atPath: disk.path, toPath: path) }
        catch { try? fm.removeItem(atPath: BazziteGuest.directory(path)); throw error }
        report("Bazzite disk ready", manifest.build, 1)
        return .init(path: path, payload: "", buildID: manifest.build, version: "Bazzite ARM64 experimental", gpt: gpt)
    }
    /// Bound decompression by the manifest, preserve holes and reject truncated gzip.
    func extract(_ archive: URL, to disk: URL, expectedBytes: Int64) throws {
        let fd = open(disk.path, O_WRONLY | O_CREAT | O_EXCL | O_CLOEXEC, 0o600)
        guard fd >= 0 else { throw OptionError("Cannot create a new Bazzite disk: \(disk.path)") }
        let output = FileHandle(fileDescriptor: fd, closeOnDealloc: true)
        defer { try? output.close() }
        let p = Process(), pipe = Pipe()
        p.executableURL = URL(fileURLWithPath: "/usr/bin/gzip")
        p.arguments = ["-dc", archive.path]
        p.standardOutput = pipe
        p.standardError = FileHandle.nullDevice
        try checkCancel()
        try p.run()
        lock.lock(); process = p; let stop = cancelled; lock.unlock()
        if stop { p.terminate() }
        defer {
            if p.isRunning { p.terminate() }
            try? pipe.fileHandleForReading.close()
            p.waitUntilExit()
            lock.lock(); process = nil; lock.unlock()
        }
        var bytes: Int64 = 0
        while let data = try pipe.fileHandleForReading.read(upToCount: 1 << 20), !data.isEmpty {
            try checkCancel()
            bytes += Int64(data.count)
            guard bytes <= expectedBytes else { throw OptionError("Bazzite disk exceeds manifest size") }
            if data.allSatisfy({ $0 == 0 }) { try output.seek(toOffset: UInt64(bytes)) }
            else { try output.write(contentsOf: data) }
            report("Preparing Bazzite disk…", "", 0.75 + Double(bytes) / Double(expectedBytes) * 0.24)
        }
        p.waitUntilExit()
        try checkCancel()
        guard p.terminationStatus == 0, bytes == expectedBytes else { throw OptionError("Bazzite disk decompression failed or size mismatch") }
        try output.truncate(atOffset: UInt64(bytes))
        try output.synchronize()
    }
}
