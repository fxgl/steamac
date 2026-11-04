import Darwin
import Foundation
import Metal

/// STEAMAC-2E: Metal's frontend cannot compile monolithic_metal.pcm in an inaccessible or
/// immutable cache. TMPDIR does not redirect confstr(_CS_DARWIN_USER_CACHE_DIR). Metal's
/// optional cache-path SPI must run before any device/library or cache getter is used.
enum MetalCompilerCache {
    private typealias SetPath = @convention(c) (UnsafeRawPointer) -> Void
    private(set) static var outcome = "unprepared"
    private static var startupDetail = ""

    private static func setPath(_ path: String) throws {
        guard let symbol = dlsym(UnsafeMutableRawPointer(bitPattern: -2), "MTLSetShaderCachePath") else {
            throw OptionError("Metal cache-path override is unavailable on this macOS")
        }
        // The SPI takes an NSString, not a C string; Metal copies its filesystem representation.
        let string = path as NSString
        withExtendedLifetime(string) {
            unsafeBitCast(symbol, to: SetPath.self)(Unmanaged.passUnretained(string).toOpaque())
        }
    }

    static func prepare() {
        var buffer = [CChar](repeating: 0, count: Int(PATH_MAX))
        let count = confstr(_CS_DARWIN_USER_CACHE_DIR, &buffer, buffer.count)
        guard count > 0, count <= buffer.count else {
            outcome = "cache-directory-unavailable"
            log("Metal compiler cache: cannot locate DARWIN_USER_CACHE_DIR (\(String(cString: strerror(errno))))")
            return
        }
        let bundle = Bundle.main.bundleIdentifier ?? LauncherSettings.defaultDomain
        let primary = String(cString: buffer) + bundle + "/com.apple.metalfe"
        let fallback = NSHomeDirectory() + "/Library/Caches/" + LauncherSettings.defaultDomain + "/metal-compiler"
        do { _ = try prepare(primary: primary, fallback: fallback) }
        catch {
            startupDetail = "\(error)"
            log("Metal compiler cache: cannot use a writable replacement: \(error)")
        }
    }

    /// Probe the existing module tree, not just its parent: one stale immutable .pcm or hash
    /// directory is enough to break compilation. Do not change ownership, ACLs or file flags,
    /// and never delete the original cache (another VM process may still be using it).
    @discardableResult
    static func prepare(primary: String, fallback: String) throws -> Bool {
        do {
            try checkWritableTree(primary)
            outcome = "primary"
            startupDetail = primary
            log("Metal compiler cache: primary writable at startup: \(primary)")
            return false
        } catch {
            let reason = "\(error)"
            startupDetail = "\(primary): \(reason)"
            outcome = "replacement-unwritable"
            try checkWritableTree(fallback)
            outcome = "override-unavailable"
            try setPath(fallback)
            outcome = "redirected"
            log("Metal compiler cache: \(primary) is not writable (\(reason)); using \(fallback) before Metal initialises")
            return true
        }
    }

    /// A startup probe cannot predict later filesystem/security-policy changes (STEAMAC-7W).
    /// Preserve the startup decision and the actual failed module's metadata in the next report.
    /// This is read-only: Metal chooses its cache once; never change it while compiles are running.
    static func failureDiagnostics(_ message: String) -> String? {
        guard message.contains("monolithic_metal.pcm"),
              let start = message.range(of: "unable to open output file '")?.upperBound,
              let end = message[start...].firstIndex(of: "'") else { return nil }
        let path = String(message[start..<end])
        guard path.contains("/com.apple.metalfe/"), path.hasSuffix("/monolithic_metal.pcm") else { return nil }
        let directory = (path as NSString).deletingLastPathComponent
        var lines = ["reporter-startup=\(outcome) reporter-detail=\(startupDetail); VM startup decision is the metal_cache tag"]
        for item in [(directory as NSString).deletingLastPathComponent, directory, path] {
            var info = stat()
            if lstat(item, &info) == 0 {
                lines.append("\(item): uid=\(info.st_uid) gid=\(info.st_gid) mode=\(String(info.st_mode, radix: 8)) flags=0x\(String(info.st_flags, radix: 16)) writable=\(access(item, W_OK) == 0)")
            } else {
                lines.append("\(item): lstat errno=\(errno) \(String(cString: strerror(errno)))")
            }
        }
        return lines.joined(separator: "\n")
    }

    private static func checkWritableTree(_ path: String) throws {
        let fm = FileManager.default
        try fm.createDirectory(atPath: path, withIntermediateDirectories: true,
                               attributes: [.posixPermissions: 0o700])
        try probeDirectory(path)
        var enumerationError: Error?
        guard let entries = fm.enumerator(at: URL(fileURLWithPath: path),
                                          includingPropertiesForKeys: [.isDirectoryKey, .isSymbolicLinkKey],
                                          errorHandler: { _, error in enumerationError = error; return false }) else {
            throw OptionError("\(path): cannot enumerate module cache")
        }
        for case let url as URL in entries {
            let values = try url.resourceValues(forKeys: [.isDirectoryKey, .isSymbolicLinkKey])
            guard values.isSymbolicLink != true else {
                throw OptionError("\(url.path): symbolic link in module cache")
            }
            if values.isDirectory == true {
                try probeDirectory(url.path)
            } else if url.pathExtension == "pcm" {
                let fd = open(url.path, O_RDWR | O_CLOEXEC | O_NOFOLLOW)
                guard fd >= 0 else { throw OptionError("\(url.path): \(String(cString: strerror(errno)))") }
                close(fd)
            }
        }
        if let enumerationError { throw enumerationError }
    }

    private static func probeDirectory(_ path: String) throws {
        let probe = path + "/.steamac-write-probe-" + UUID().uuidString
        let fd = open(probe, O_WRONLY | O_CREAT | O_EXCL | O_CLOEXEC | O_NOFOLLOW, 0o600)
        guard fd >= 0 else { throw OptionError("\(path): \(String(cString: strerror(errno)))") }
        defer { close(fd); unlink(probe) }
        var byte: UInt8 = 0
        guard Darwin.write(fd, &byte, 1) == 1 else {
            throw OptionError("\(path): \(String(cString: strerror(errno)))")
        }
    }

    /// Each compilation runs in a fresh process so Metal's dispatch_once cache-path selection
    /// cannot hide a bad override. Only private temporary caches are touched, never the VM cache.
    static func selfTest() -> Never {
        let environment = ProcessInfo.processInfo.environment
        if let root = environment["STEAMAC_METAL_CACHE_SELFTEST_ROOT"],
           let mode = environment["STEAMAC_METAL_CACHE_SELFTEST_MODE"] {
            do {
                let primary = root + (mode == "late-blocked" ? "/late-primary/com.apple.metalfe" : "/blocked"), fallback = root + "/replacement"
                if mode == "blocked" {
                    try setPath(primary)
                } else if mode == "late-blocked" {
                    guard try !prepare(primary: primary, fallback: fallback), outcome == "primary" else {
                        throw OptionError("healthy startup cache was not recorded")
                    }
                    try setPath(primary)
                    guard chflags(primary, UInt32(UF_IMMUTABLE)) == 0 else { throw OptionError("chflags late cache") }
                } else {
                    guard try prepare(primary: primary, fallback: fallback) else {
                        throw OptionError("blocked module cache was not detected")
                    }
                }
                guard let device = MTLCreateSystemDefaultDevice() else { throw OptionError("no Metal device") }
                let options = MTLCompileOptions()
                options.languageVersion = .version3_0
                let source = "#include <metal_stdlib>\nusing namespace metal; kernel void cacheProbe\(UUID().uuidString.replacingOccurrences(of: "-", with: ""))(device float* output [[buffer(0)]], uint tid [[thread_position_in_grid]]) { output[tid] = sin(float(tid)); }"
                do {
                    _ = try device.makeLibrary(source: source, options: options)
                    guard mode == "repaired" else { throw OptionError("blocked cache unexpectedly compiled") }
                    log("selftest-metal-cache: PASS Metal source compiles with replacement cache")
                } catch {
                    let detail = "\(error)"
                    guard mode == "blocked" || mode == "late-blocked", detail.contains("monolithic_metal.pcm"),
                          detail.contains("Operation not permitted"), detail.contains("could not build module") else { throw error }
                    if mode == "late-blocked" {
                        guard let diagnostics = failureDiagnostics(detail),
                              diagnostics.contains("startup=primary"), diagnostics.contains("flags=0x2") else {
                            throw OptionError("runtime cache failure lost startup outcome or immutable flag")
                        }
                        chflags(primary, 0)
                    }
                    log("selftest-metal-cache: PASS reproduced \(mode) module-cache failure: \(detail)")
                }
                exit(0)
            } catch {
                log("selftest-metal-cache: FAIL \(error)")
                exit(1)
            }
        }
        let root = NSTemporaryDirectory() + "steamac-metal-cache-" + UUID().uuidString
        let blocked = root + "/blocked"
        do {
            try FileManager.default.createDirectory(atPath: blocked, withIntermediateDirectories: true)
            guard chflags(blocked, UInt32(UF_IMMUTABLE)) == 0 else { throw OptionError("chflags: \(String(cString: strerror(errno)))") }
            for mode in ["blocked", "repaired", "late-blocked"] {
                let process = Process()
                process.executableURL = Bundle.main.executableURL
                process.arguments = ["--selftest-metal-cache"]
                var childEnvironment = environment
                childEnvironment["STEAMAC_METAL_CACHE_SELFTEST_ROOT"] = root
                childEnvironment["STEAMAC_METAL_CACHE_SELFTEST_MODE"] = mode
                process.environment = childEnvironment
                try process.run()
                process.waitUntilExit()
                guard process.terminationReason == .exit, process.terminationStatus == 0 else {
                    throw OptionError("\(mode) child failed: \(process.terminationStatus)")
                }
            }
            guard try !prepare(primary: root + "/healthy", fallback: root + "/unused"), outcome == "primary" else {
                throw OptionError("healthy cache must not be redirected")
            }
            guard !FileManager.default.fileExists(atPath: root + "/unused") else {
                throw OptionError("healthy cache created an unnecessary replacement")
            }
            let nested = root + "/nested/hash"
            try FileManager.default.createDirectory(atPath: nested, withIntermediateDirectories: true)
            guard chmod(nested, 0o500) == 0 else { throw OptionError("chmod nested cache") }
            var rejected = false
            do { try checkWritableTree(root + "/nested") } catch { rejected = true }
            chmod(nested, 0o700)
            guard rejected else { throw OptionError("unwritable hash directory was not detected") }
            let pcm = nested + "/monolithic_metal.pcm"
            try Data([0]).write(to: URL(fileURLWithPath: pcm))
            guard chflags(pcm, UInt32(UF_IMMUTABLE)) == 0 else { throw OptionError("chflags module") }
            rejected = false
            do { try checkWritableTree(root + "/nested") } catch { rejected = true }
            chflags(pcm, 0)
            guard rejected else { throw OptionError("immutable existing module was not detected") }
            log("selftest-metal-cache: PASS inaccessible hash directory and immutable existing module detected")
            chflags(blocked, 0)
            try FileManager.default.removeItem(atPath: root)
            log("selftest-metal-cache: PASS healthy cache is unchanged; all passed")
            exit(0)
        } catch {
            chflags(blocked, 0)
            chflags(root + "/late-primary/com.apple.metalfe", 0)
            chmod(root + "/nested/hash", 0o700)
            chflags(root + "/nested/hash/monolithic_metal.pcm", 0)
            try? FileManager.default.removeItem(atPath: root)
            log("selftest-metal-cache: FAIL \(error)")
            exit(1)
        }
    }
}
