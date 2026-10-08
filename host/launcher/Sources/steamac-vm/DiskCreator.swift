import CryptoKit
import Darwin
import Foundation

/// Docker-free creation of the SteamOS disk (local://provision-contract.md, host side):
///  1. atomupd metadata of the branch -> newest candidate (update_path, chunks_store_path);
///  2. download the signed RAUC bundle, verify its CMS signature against the pinned Valve CA
///     (RaucBundle), read manifest.raucm + rootfs.img.caibx from its squashfs (Squashfs);
///  3. rebuild rootfs.img with the bundled desync from Valve's chunk stores (chunk cache in
///     `cacheRoot(forDisk:)`: cancel + resume re-extracts from the cache);
///  4. sparse disk file with protective MBR + GPT of scripts/steps/40-disk.sh (GPT/DiskLayout),
///     rootfs.img copied into rootfs-A and rootfs-B (non-zero 16 KiB blocks only) while its
///     sha256 is checked against the signed manifest; everything else stays zero;
///  5. the first-boot payload disk (ProvisionPayload) next to it; the guest initramfs formats
///     and fills the other partitions on the first boot (Provision).
/// Synchronous: run off the main thread; `cancel()` from any thread.
final class DiskCreator {
    struct Request {
        var path: String
        var branch = "stable"
        var homeGiB = DiskLayout.defaultHomeGiB
        /// Password of the guest user steamos; nil = none (stock shadow field, the release
        /// default; Settings > Advanced "Enable SSH" sets one later). Dev default "steamos".
        var password: String? = AppBundle.releaseDefaults ? nil : "steamos"
        /// Keep the downloaded bundle and chunk cache after success (re-creating disks quickly).
        var keepCache = false
    }

    struct Status: Equatable {
        var title: String
        var detail = ""
        var localizedTitle: String
        var localizedDetail: String
        /// Overall 0...1.
        var fraction: Double
    }

    struct Result {
        let path: String
        let payload: String
        let buildID: String
        let version: String
        let gpt: GPT
    }

    struct Candidate {
        let buildID: String
        let version: String
        let updatePath: String
        let chunksStorePath: String
    }

    struct Cancelled: Error, CustomStringConvertible { var description: String { "cancelled" } }

    static let branches = ["stable", "rc"]
    static let metaURL = "https://steamdeck-atomupd.steamos.cloud/meta/holo/steamos/aarch64/vr/"
    static let imagesURL = "https://steamdeck-images.steamos.cloud/"
    /// Download caches (bundles/, desync/) and creation.lock for a disk at `path`: the user's
    /// Caches folder when the disk is on the home directory's volume, else next to the disk, like
    /// its other temporary files (a disk on an external drive needs no internal space for the
    /// ~1.3x-the-rootfs chunk cache). The disk's directory must exist.
    static func cacheRoot(forDisk path: String) -> String {
        let volume = { (p: String) in
            (try? URL(fileURLWithPath: p).resourceValues(forKeys: [.volumeIdentifierKey]))?.volumeIdentifier as? NSObject
        }
        if let home = volume(NSHomeDirectory()), let disk = volume((path as NSString).deletingLastPathComponent),
           home.isEqual(disk) {
            return NSHomeDirectory() + "/Library/Caches/" + LauncherSettings.defaultDomain
        }
        return path + ".cache"
    }
    static var defaultPath: String { AppBundle.appSupportDir + "/steamos.img" }
    /// Temporary rootfs.img (sparse desync output) and the disk while it is written.
    static func rootfsTemp(_ path: String) -> String { path + ".rootfs-tmp" }
    static func diskTemp(_ path: String) -> String { path + ".partial" }

    /// Overall-bar segments (start, weight) in percent.
    private static let segments: [String: (Double, Double)] = [
        "meta": (0, 1), "download": (1, 2), "verify": (3, 1), "reconstruct": (4, 70), "write": (74, 25), "payload": (99, 1),
    ]

    /// Called on the worker thread.
    var onStatus: ((Status) -> Void)?
    private let lock = NSLock()
    private var cancelledFlag = false
    private var task: URLSessionTask?
    private var process: Process?

    func cancel() {
        lock.lock()
        cancelledFlag = true
        let t = task, p = process
        lock.unlock()
        t?.cancel()
        if let p, p.isRunning { p.interrupt() }
    }

    private var cancelled: Bool {
        lock.lock(); defer { lock.unlock() }
        return cancelledFlag
    }

    private func checkCancel() throws { if cancelled { throw Cancelled() } }

    private func status(_ stage: String, _ title: LocalizedStringResource, _ detail: String = "", _ fraction: Double = 0,
                        localizedDetail: String? = nil) {
        let (start, weight) = DiskCreator.segments[stage] ?? (0, 0)
        var englishTitle = title
        englishTitle.locale = Locale(identifier: "en")
        onStatus?(Status(title: String(localized: englishTitle), detail: detail,
                         localizedTitle: String(localized: title), localizedDetail: localizedDetail ?? detail,
                         fraction: (start + weight * max(0, min(1, fraction))) / 100))
    }

    // MARK: tools

    /// A bundled file (Contents/Resources) or its location in the build tree (work/out next to
    /// the dev binary, scripts/keys in the repo).
    static func locate(_ name: String, dev: [String]) -> String? {
        if let res = AppBundle.resources { return FileManager.default.fileExists(atPath: res + "/" + name) ? res + "/" + name : nil }
        let exe = Bundle.main.executableURL ?? URL(fileURLWithPath: CommandLine.arguments[0])
        let dir = exe.resolvingSymlinksInPath().deletingLastPathComponent().path
        return dev.map { dir + "/" + $0 }.first { FileManager.default.fileExists(atPath: $0) }
    }

    static var desyncPath: String? { locate("desync", dev: ["host/bin/desync"]) }
    static var caPath: String? { locate("steamdeck-images.pem", dev: ["../../scripts/keys/steamdeck-images.pem"]) }

    /// Caller closes the returned descriptor only after all creation work finishes.
    static func acquireCreationLock(cacheRoot: String) throws -> Int32 {
        let lockPath = cacheRoot + "/creation.lock"
        let fd = open(lockPath, O_RDWR | O_CREAT | O_CLOEXEC, 0o644)
        guard fd >= 0 else { throw OptionError("\(lockPath): \(String(cString: strerror(errno)))") }
        guard flock(fd, LOCK_EX | LOCK_NB) == 0 else {
            let error = errno
            close(fd)
            if error == EWOULDBLOCK {
                throw DiskCreationFilesystem.Rejection("another SteamOS disk is being created with the download cache \(cacheRoot): wait for it to finish or cancel it",
                    localized: String(localized: "another SteamOS disk is being created with the download cache \(cacheRoot): wait for it to finish or cancel it"))
            }
            throw OptionError("\(lockPath): \(String(cString: strerror(error)))")
        }
        return fd
    }

    // MARK: run

    func run(_ r: Request) throws -> Result {
        let fm = FileManager.default
        guard let desync = DiskCreator.desyncPath else { throw OptionError("desync not found (bundle Contents/Resources/desync or work/out/host/bin/desync: host/launcher/fetch-desync.sh)") }
        guard let caPath = DiskCreator.caPath else { throw OptionError("Valve RAUC CA steamdeck-images.pem not found") }
        guard DiskCreator.branches.contains(r.branch) else { throw OptionError("unknown branch \(r.branch) (\(DiskCreator.branches.joined(separator: ", ")))") }
        guard (8...4096).contains(r.homeGiB) else { throw OptionError("home size must be 8..4096 GiB", localized: String(localized: "home size must be 8..4096 GiB")) }
        let path = (r.path as NSString).standardizingPath
        let dir = (path as NSString).deletingLastPathComponent
        do {
            try fm.createDirectory(atPath: dir, withIntermediateDirectories: true)
        } catch let e as CocoaError where e.code == .fileWriteNoPermission {
            throw DiskCreationFilesystem.Rejection("no permission to create \(dir): choose a folder you can write to",
                localized: String(localized: "no permission to create \(dir): choose a folder you can write to"))
        }
        try DiskCreationFilesystem.requireWritable(directory: dir)
        let gpt = DiskLayout.table(homeGiB: r.homeGiB)
        let diskBytes = gpt.sectors * DiskLayout.sector
        let rootBytes = DiskLayout.rootMiB * DiskLayout.mib
        let denseFiles = try DiskCreationFilesystem.preflight(directory: dir, diskBytes: diskBytes, rootfsBytes: rootBytes)
        // One creator per cache: another one would delete or extend the same chunk cache and
        // temporary files. Held until this function returns; the lock file stays while the cache
        // does (all creators must lock the same inode), a per-disk cache directory goes away after
        // its disk was created.
        let cacheRoot = DiskCreator.cacheRoot(forDisk: path)
        let chunkCache = cacheRoot + "/desync"
        try fm.createDirectory(atPath: cacheRoot, withIntermediateDirectories: true)
        let lockFD = try DiskCreator.acquireCreationLock(cacheRoot: cacheRoot)
        defer { close(lockFD) }
        guard !fm.fileExists(atPath: path) else {
            throw DiskCreationFilesystem.Rejection("\(path) already exists (never overwritten; delete it or choose another path)",
                localized: String(localized: "\(path) already exists (never overwritten; delete it or choose another path)"))
        }
        let ca = try RaucBundle.loadCA(caPath)

        // 1. metadata
        status("meta", "Looking up SteamOS \(r.branch)…")
        let c = try candidate(branch: r.branch)
        log("create-disk: branch \(r.branch): SteamOS \(c.buildID) (\(c.version)), \(c.updatePath), store \(c.chunksStorePath)")
        try checkCancel()

        // 2. bundle
        let work = cacheRoot + "/bundles/" + c.buildID
        try fm.createDirectory(atPath: work, withIntermediateDirectories: true)
        let bundlePath = work + "/" + (c.updatePath as NSString).lastPathComponent
        var bundle: RaucBundle
        if fm.fileExists(atPath: bundlePath), var b = try? RaucBundle(contentsOf: bundlePath), (try? b.verify(ca: ca)) != nil {
            bundle = b
            log("create-disk: using the cached bundle \(bundlePath)")
        } else {
            try download(URL(string: DiskCreator.imagesURL + c.updatePath)!, to: bundlePath)
            status("verify", "Verifying the signed bundle…")
            bundle = try RaucBundle(contentsOf: bundlePath)
            try bundle.verify(ca: ca)
        }
        log("create-disk: bundle signature verify OK (signer CN=\(bundle.signer), anchored at the pinned Valve CA CN=steamdeck-images)")
        status("verify", "Reading the bundle manifest…", "", 0.5)
        let fs = try Squashfs(bundle.squashfs)
        let manifest = try RaucBundle.parseManifest(String(decoding: try fs.file("manifest.raucm"), as: UTF8.self))
        guard manifest.compatible == "steamos-aarch64" else { throw OptionError("manifest: compatible=\(manifest.compatible), expected steamos-aarch64") }
        guard manifest.version == c.buildID else { throw OptionError("manifest: version \(manifest.version) != atomupd buildid \(c.buildID)") }
        guard manifest.rootfsSize == rootBytes else { throw OptionError("manifest: rootfs size \(manifest.rootfsSize) != slot size \(rootBytes)") }
        let caibx = try fs.file(manifest.rootfsFilename)
        let caibxPath = work + "/rootfs.img.caibx"
        try Data(caibx).write(to: URL(fileURLWithPath: caibxPath))
        log("create-disk: manifest OK: compatible=\(manifest.compatible) version=\(manifest.version) rootfs sha256=\(manifest.rootfsSHA256) size=\(manifest.rootfsSize), index \(caibx.count) bytes")
        try checkCancel()

        // Sparse volumes use rootfs data ~3x (temp + both slots); exFAT allocates the whole
        // disk and temporary rootfs. The compressed chunk cache is additional on either FS.
        let dataBytes = try desyncDataSize(desync, caibxPath)
        try checkSpace(disk: dir, need: denseFiles ? diskBytes + rootBytes : 3 * dataBytes,
                       cache: cacheRoot, cacheNeed: dataBytes * 13 / 10)

        // 3. reconstruct
        let tmp = DiskCreator.rootfsTemp(path)
        try fm.createDirectory(atPath: chunkCache, withIntermediateDirectories: true)
        let stores = [DiskCreator.imagesURL + (c.updatePath as NSString).deletingPathExtension + ".castr/",
                      DiskCreator.imagesURL + c.chunksStorePath + "/"]
        log("create-disk: desync extract -> \(tmp) (stores: \(stores.joined(separator: ", ")); cache \(chunkCache))")
        try reconstruct(desync, caibxPath, tmp, stores: stores, cache: chunkCache, dataBytes: dataBytes)
        try checkCancel()

        // 4. disk
        let partial = DiskCreator.diskTemp(path)
        try? fm.removeItem(atPath: partial)
        let fd = open(partial, O_RDWR | O_CREAT | O_EXCL, 0o644)
        guard fd >= 0 else { throw OptionError("\(partial): \(String(cString: strerror(errno)))") }
        var keep = false
        defer {
            close(fd)
            if !keep { try? fm.removeItem(atPath: partial) }
        }
        guard ftruncate(fd, off_t(diskBytes)) == 0 else { throw OptionError("ftruncate \(partial): \(String(cString: strerror(errno)))") }
        try gpt.write(fd: fd)
        let a = gpt.entry("rootfs-A")!, b = gpt.entry("rootfs-B")!
        guard a.sectors * 512 == rootBytes, b.sectors * 512 == rootBytes else { throw OptionError("layout: rootfs slot size") }
        status("write", "Writing rootfs-A and rootfs-B…")
        try copyRootfs(tmp, size: rootBytes, into: fd, offsets: [a.firstLBA * 512, b.firstLBA * 512],
                       sha256: manifest.rootfsSHA256)
        log("create-disk: rootfs sha256 OK: \(manifest.rootfsSHA256) == manifest; written to rootfs-A (LBA \(a.firstLBA)) and rootfs-B (LBA \(b.firstLBA))")
        guard fsync(fd) == 0 else { throw OptionError("fsync \(partial): \(String(cString: strerror(errno)))") }

        // 5. payload, then the disk under its final name (never replacing an existing file)
        status("payload", "Writing the first-boot payload…")
        let values = ProvisionPayload.Values(buildID: c.buildID, version: c.version, branch: r.branch,
                                             rootfsSHA256: manifest.rootfsSHA256,
                                             passwordHash: r.password.map { SHA512Crypt.hash($0) } ?? "",
                                             machineID: ProvisionPayload.randomMachineID(), gpt: gpt)
        let payload = Provision.payloadPath(forDisk: path)
        let payloadTmp = payload + ".partial"
        try Data(ProvisionPayload.image(env: try ProvisionPayload.env(values), caibx: caibx))
            .write(to: URL(fileURLWithPath: payloadTmp))
        guard rename(payloadTmp, payload) == 0 else { throw OptionError("rename \(payloadTmp): \(String(cString: strerror(errno)))") }
        try DiskCreationFilesystem.publish(partial: partial, destination: path)
        keep = true
        try? fm.removeItem(atPath: tmp)
        if !r.keepCache {
            if cacheRoot == path + ".cache" {
                try? fm.removeItem(atPath: cacheRoot)
            } else {
                try? fm.removeItem(atPath: chunkCache)
                try? fm.removeItem(atPath: work)
            }
        }
        let check = try GPT.read(path: path)
        guard check == gpt else { throw OptionError("\(path): GPT read back differs from what was written") }
        log("create-disk: GPT of \(path):\n" + check.dump())
        log("create-disk: payload \(payload) (\(c.buildID), attached read-only on the first boot with \(Provision.cmdlineFlag))")
        status("payload", "Done", "", 1)
        return Result(path: path, payload: payload, buildID: c.buildID, version: c.version, gpt: gpt)
    }

    // MARK: metadata

    func candidate(branch: String) throws -> Candidate {
        let url = URL(string: DiskCreator.metaURL + branch + ".json")!
        let data = try fetch(url)
        guard let root = try JSONSerialization.jsonObject(with: data) as? [String: Any] else { throw OptionError("\(url): not a JSON object") }
        var found: [Candidate] = []
        for key in ["minor", "major"] {
            guard let part = root[key] as? [String: Any], let list = part["candidates"] as? [[String: Any]] else { continue }
            for c in list {
                guard let image = c["image"] as? [String: Any], let id = image["buildid"] as? String,
                      let path = c["update_path"] as? String, let store = c["chunks_store_path"] as? String,
                      (image["arch"] as? String) == "aarch64", path.hasSuffix(".raucb"),
                      !path.contains(".."), !store.contains("..") else { continue }
                found.append(Candidate(buildID: id, version: image["version"] as? String ?? "", updatePath: path, chunksStorePath: store))
            }
        }
        guard let newest = found.max(by: { $0.buildID < $1.buildID }) else { throw OptionError("\(url): no aarch64 candidate") }
        return newest
    }

    // MARK: HTTP

    private func setTask(_ t: URLSessionTask?) {
        lock.lock(); task = t; lock.unlock()
    }

    func fetch(_ url: URL) throws -> Data {
        let sem = DispatchSemaphore(value: 0)
        var result: Swift.Result<Data, Error> = .failure(Cancelled())
        let t = URLSession.shared.dataTask(with: url) { d, resp, err in
            if let err { result = .failure(err) }
            else if let code = (resp as? HTTPURLResponse)?.statusCode, code != 200 { result = .failure(OptionError("\(url): HTTP \(code)")) }
            else { result = .success(d ?? Data()) }
            sem.signal()
        }
        setTask(t)
        t.resume()
        sem.wait()
        setTask(nil)
        try checkCancel()
        return try result.get()
    }

    private func download(_ url: URL, to path: String) throws {
        log("create-disk: downloading \(url)")
        status("download", "Downloading the SteamOS bundle…")
        let tmp = path + ".part"
        try? FileManager.default.removeItem(atPath: tmp)
        let d = Downloader(path: tmp) { [weak self] got, total, rate in
            let mb = Double(got) / 1e6
            let detail = total > 0 ? String(format: "%.1f / %.1f MB · %.1f MB/s", mb, Double(total) / 1e6, rate / 1e6)
                : String(format: "%.1f MB · %.1f MB/s", mb, rate / 1e6)
            let received = String(format: "%.1f", mb), speed = String(format: "%.1f", rate / 1e6)
            let expected = String(format: "%.1f", Double(total) / 1e6)
            let localizedDetail = total > 0
                ? String(localized: "\(received) / \(expected) MB · \(speed) MB/s")
                : String(localized: "\(received) MB · \(speed) MB/s")
            self?.status("download", "Downloading the SteamOS bundle…", detail, total > 0 ? Double(got) / Double(total) : 0,
                         localizedDetail: localizedDetail)
        }
        let session = URLSession(configuration: .ephemeral, delegate: d, delegateQueue: nil)
        defer { session.finishTasksAndInvalidate() }
        let t = session.dataTask(with: url)
        setTask(t)
        t.resume()
        d.done.wait()
        setTask(nil)
        try checkCancel()
        if let e = d.error { throw e }
        guard rename(tmp, path) == 0 else { throw OptionError("rename \(tmp): \(String(cString: strerror(errno)))") }
        log(String(format: "create-disk: downloaded %.1f MB (%.1f MB/s)", Double(d.received) / 1e6, d.averageRate / 1e6))
    }

    // MARK: desync

    /// Unique non-null data in the index (what the chunk store delivers and the disk stores).
    private func desyncDataSize(_ desync: String, _ caibx: String) throws -> UInt64 {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: desync)
        p.arguments = ["info", caibx]
        let out = Pipe()
        p.standardOutput = out
        p.standardError = FileHandle.nullDevice
        try p.run()
        let data = out.fileHandleForReading.readDataToEndOfFile()
        p.waitUntilExit()
        guard p.terminationStatus == 0, let j = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let n = (j["dedup-size-not-in-seed"] as? NSNumber)?.uint64Value else {
            throw OptionError("desync info \(caibx) failed")
        }
        return n
    }

    private func reconstruct(_ desync: String, _ caibx: String, _ out: String, stores: [String], cache: String, dataBytes: UInt64) throws {
        status("reconstruct", "Downloading SteamOS…", "starting desync", localizedDetail: "")
        // No --in-place: that preallocates all 10 GiB; a fresh extract keeps the null chunks as holes.
        var args = ["extract", "--concurrency", "16", "--error-retry", "10", "--cache", cache]
        for s in stores { args += ["--store", s] }
        args += [caibx, out]
        // desync draws its progress bar only on a terminal: give it a pty and parse "NN.NN%".
        var master: Int32 = -1, slave: Int32 = -1
        var ws = winsize(ws_row: 24, ws_col: 160, ws_xpixel: 0, ws_ypixel: 0)
        guard openpty(&master, &slave, nil, nil, &ws) == 0 else { throw OptionError("openpty: \(String(cString: strerror(errno)))") }
        let p = Process()
        p.executableURL = URL(fileURLWithPath: desync)
        p.arguments = args
        p.standardInput = FileHandle.nullDevice
        let slaveHandle = FileHandle(fileDescriptor: slave, closeOnDealloc: false)
        p.standardOutput = slaveHandle
        p.standardError = slaveHandle
        do { try p.run() } catch { close(master); close(slave); throw error }
        close(slave)
        lock.lock(); process = p; let stop = cancelledFlag; lock.unlock()
        if stop { p.interrupt() }
        let start = Date()
        var lastLogged = -1
        var text = ""
        var recent: [String] = []
        var buf = [UInt8](repeating: 0, count: 8192)
        while true {
            let n = read(master, &buf, buf.count)
            if n < 0 && errno == EINTR { continue }
            if n <= 0 { break }   // EIO once desync and the pty are gone
            text += String(decoding: buf[0..<n], as: UTF8.self)
            let pieces = text.split(omittingEmptySubsequences: false, whereSeparator: { $0 == "\r" || $0 == "\n" })
            text = String(pieces.last ?? "")
            for raw in pieces.dropLast() {
                let piece = BootProgress.stripANSI(String(raw)).trimmingCharacters(in: .whitespaces)
                guard !piece.isEmpty else { continue }
                if let pct = DiskCreator.percent(in: piece) {
                    let elapsed = max(1, Date().timeIntervalSince(start))
                    let rate = Double(dataBytes) * pct / 100 / elapsed
                    let phase = piece.contains("Assembling") ? "" : "validating "
                    let percent = String(format: "%.1f", pct)
                    let received = String(format: "%.1f", Double(dataBytes) * pct / 100 / 1e9)
                    let total = String(format: "%.1f", Double(dataBytes) / 1e9)
                    let speed = String(format: "%.0f", rate / 1e6)
                    let localizedDetail = piece.contains("Assembling")
                        ? String(localized: "\(percent)% · \(received) of \(total) GB · \(speed) MB/s")
                        : String(localized: "validating \(percent)% · \(received) of \(total) GB · \(speed) MB/s")
                    status("reconstruct", "Downloading SteamOS…",
                           String(format: "%@%.1f%% · %.1f of %.1f GB · %.0f MB/s", phase, pct, Double(dataBytes) * pct / 100 / 1e9,
                                  Double(dataBytes) / 1e9, rate / 1e6), pct / 100, localizedDetail: localizedDetail)
                    if piece.contains("Assembling"), Int(pct) / 10 > lastLogged {
                        lastLogged = Int(pct) / 10
                        log(String(format: "create-disk: desync %.0f%% (%.0f MB/s)", pct, rate / 1e6))
                    }
                } else {
                    recent.append(piece)
                    if recent.count > 8 { recent.removeFirst() }
                }
            }
        }
        p.waitUntilExit()
        close(master)
        lock.lock(); process = nil; lock.unlock()
        try checkCancel()
        guard p.terminationStatus == 0 else {
            throw OptionError("desync extract failed (exit \(p.terminationStatus)): " + recent.suffix(3).joined(separator: " | "))
        }
        log(String(format: "create-disk: desync done in %.0f s", Date().timeIntervalSince(start)))
    }

    /// "Attempt 1: Assembling   32.27% 1m2s" -> 32.27
    static func percent(in s: String) -> Double? {
        guard let pctIdx = s.firstIndex(of: "%") else { return nil }
        var start = pctIdx
        while start > s.startIndex, let c = s[s.index(before: start)].asciiValue, c == 46 || (48...57).contains(c) {
            start = s.index(before: start)
        }
        return Double(s[start..<pctIdx])
    }

    // MARK: copy

    /// One pass over rootfs.img: sha256 of all 10 GiB (holes hashed as zeros) and every non-zero
    /// 16 KiB block written at each offset of `fd` (the zero rest stays sparse).
    private func copyRootfs(_ path: String, size: UInt64, into fd: Int32, offsets: [UInt64], sha256 expected: String) throws {
        let src = open(path, O_RDONLY)
        guard src >= 0 else { throw OptionError("\(path): \(String(cString: strerror(errno)))") }
        defer { close(src) }
        var st = stat()
        guard fstat(src, &st) == 0, UInt64(st.st_size) == size else { throw OptionError("\(path): size is not \(size)") }
        _ = fcntl(src, F_NOCACHE, 1)
        let chunk = 8 << 20, block = 16 << 10
        let buf = UnsafeMutableRawPointer.allocate(byteCount: chunk, alignment: block)
        let zeros = UnsafeMutableRawPointer.allocate(byteCount: chunk, alignment: block)
        defer { buf.deallocate(); zeros.deallocate() }
        memset(zeros, 0, chunk)
        var hasher = SHA256()
        var off: UInt64 = 0
        var written: UInt64 = 0
        let start = Date()
        func hashZeros(_ n: UInt64) {
            var left = n
            while left > 0 {
                let k = Int(min(left, UInt64(chunk)))
                hasher.update(bufferPointer: UnsafeRawBufferPointer(start: zeros, count: k))
                left -= UInt64(k)
            }
        }
        func report() {
            let mbps = Double(written) / 1e6 / max(0.001, Date().timeIntervalSince(start))
            let percent = String(format: "%.0f", Double(off) * 100 / Double(size))
            let gigabytes = String(format: "%.1f", Double(written) / 1e9)
            let speed = String(format: "%.0f", mbps)
            status("write", "Writing rootfs-A and rootfs-B…",
                   String(format: "%.0f%% · %.1f GB data · %.0f MB/s", Double(off) * 100 / Double(size), Double(written) / 1e9, mbps),
                   Double(off) / Double(size),
                   localizedDetail: String(localized: "\(percent)% · \(gigabytes) GB data · \(speed) MB/s"))
        }
        while off < size {
            try checkCancel()
            // Next data extent (SEEK_DATA/SEEK_HOLE; without support the whole file is data).
            let ds = lseek(src, off_t(off), SEEK_DATA)
            let dataStart = ds >= 0 ? UInt64(ds) : (errno == ENXIO ? size : off)
            if dataStart > off {
                let end = min(size, dataStart)
                hashZeros(end - off)
                off = end
                report()
                continue
            }
            let de = lseek(src, off_t(off), SEEK_HOLE)
            var dataEnd = de >= 0 ? UInt64(de) : size
            dataEnd = min(size, max(dataEnd, off + 1))
            while off < dataEnd {
                let n = Int(min(UInt64(chunk), dataEnd - off))
                var got = 0
                while got < n {
                    let k = pread(src, buf + got, n - got, off_t(off) + off_t(got))
                    if k < 0 && errno == EINTR { continue }
                    guard k > 0 else { throw OptionError("read \(path): \(k < 0 ? String(cString: strerror(errno)) : "EOF")") }
                    got += k
                }
                hasher.update(bufferPointer: UnsafeRawBufferPointer(start: buf, count: n))
                var i = 0
                while i < n {
                    let b = min(block, n - i)
                    if memcmp(buf + i, zeros, b) == 0 { i += b; continue }
                    var j = i + b
                    while j < n {
                        let b2 = min(block, n - j)
                        if memcmp(buf + j, zeros, b2) == 0 { break }
                        j += b2
                    }
                    for base in offsets {
                        try GPT.pwriteAll(fd, UnsafeRawBufferPointer(start: buf + i, count: j - i), at: base + off + UInt64(i))
                    }
                    written += UInt64(j - i)
                    i = j
                }
                off += UInt64(n)
                report()
                try checkCancel()
            }
        }
        let got = hasher.finalize().map { String(format: "%02x", $0) }.joined()
        guard got == expected else {
            try? FileManager.default.removeItem(atPath: path)
            throw OptionError("rootfs sha256 \(got) != manifest \(expected) (temporary rootfs deleted; try again)")
        }
    }

    // MARK: disk space

    private func checkSpace(disk: String, need: UInt64, cache: String, cacheNeed: UInt64) throws {
        try FileManager.default.createDirectory(atPath: cache, withIntermediateDirectories: true)
        var a = statfs(), b = statfs()
        guard statfs(disk, &a) == 0, statfs(cache, &b) == 0 else { return }
        let freeDisk = UInt64(a.f_bavail) * UInt64(a.f_bsize)
        let freeCache = UInt64(b.f_bavail) * UInt64(b.f_bsize)
        let margin: UInt64 = 1 << 30
        let sameVolume = a.f_fsid.val.0 == b.f_fsid.val.0 && a.f_fsid.val.1 == b.f_fsid.val.1
        let needDisk = need + (sameVolume ? cacheNeed : 0) + margin
        let gb = { (n: UInt64) in String(format: "%.1f GB", Double(n) / 1e9) }
        log("create-disk: space: need ~\(gb(needDisk)) on \(disk) (free \(gb(freeDisk)))"
            + (sameVolume ? "" : ", ~\(gb(cacheNeed + margin)) for the chunk cache on \(cache) (free \(gb(freeCache)))"))
        guard freeDisk >= needDisk else {
            let needed = String(format: "%.1f", Double(needDisk) / 1e9)
            let available = String(format: "%.1f", Double(freeDisk) / 1e9)
            throw DiskCreationFilesystem.Rejection("not enough free space: \(gb(needDisk)) needed on the volume of \(disk), \(gb(freeDisk)) free",
                localized: String(localized: "not enough free space: \(needed) GB needed on the volume of \(disk), \(available) GB free"))
        }
        guard sameVolume || freeCache >= cacheNeed + margin else {
            let needed = String(format: "%.1f", Double(cacheNeed + margin) / 1e9)
            let available = String(format: "%.1f", Double(freeCache) / 1e9)
            throw DiskCreationFilesystem.Rejection("not enough free space for the download cache: \(gb(cacheNeed + margin)) needed in \(cache), \(gb(freeCache)) free",
                localized: String(localized: "not enough free space for the download cache: \(needed) GB needed in \(cache), \(available) GB free"))
        }
    }
}

/// URLSession data delegate writing the body to a file, with progress and average rate.
private final class Downloader: NSObject, URLSessionDataDelegate {
    let done = DispatchSemaphore(value: 0)
    private(set) var error: Error?
    private(set) var received: Int64 = 0
    private var total: Int64 = 0
    private let path: String
    private var handle: FileHandle?
    private let progress: (Int64, Int64, Double) -> Void
    private let start = Date()
    private var lastReport = Date.distantPast

    var averageRate: Double { Double(received) / max(0.001, Date().timeIntervalSince(start)) }

    init(path: String, progress: @escaping (Int64, Int64, Double) -> Void) {
        self.path = path
        self.progress = progress
    }

    func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive response: URLResponse,
                    completionHandler: @escaping (URLSession.ResponseDisposition) -> Void) {
        guard let http = response as? HTTPURLResponse, http.statusCode == 200 else {
            error = OptionError("\(response.url?.absoluteString ?? "?"): HTTP \((response as? HTTPURLResponse)?.statusCode ?? 0)")
            completionHandler(.cancel)
            return
        }
        total = response.expectedContentLength
        FileManager.default.createFile(atPath: path, contents: nil)
        handle = FileHandle(forWritingAtPath: path)
        completionHandler(handle == nil ? .cancel : .allow)
    }

    func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive data: Data) {
        do { try handle?.write(contentsOf: data) } catch { self.error = error; dataTask.cancel(); return }
        received += Int64(data.count)
        if Date().timeIntervalSince(lastReport) > 0.25 || received == total {
            lastReport = Date()
            progress(received, total, averageRate)
        }
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        try? handle?.close()
        if self.error == nil, let error { self.error = error }
        done.signal()
    }
}
