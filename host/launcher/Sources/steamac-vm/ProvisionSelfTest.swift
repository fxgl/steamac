import CryptoKit
import Darwin
import Foundation

/// `--selftest-provision`: unit tests of the Docker-free disk creator's parts. The reference disk
/// (Docker-built work/out/steamos.img unless --reference-disk) is only ever opened O_RDONLY.
enum ProvisionSelfTest {
    static func run(_ o: Options) -> Never {
        var failures = 0
        func check(_ ok: Bool, _ what: String) {
            log("selftest-provision: \(ok ? "PASS" : "FAIL") \(what)")
            if !ok { failures += 1 }
        }
        func attempt(_ what: String, _ body: () throws -> Void) {
            do { try body() } catch { check(false, "\(what): \(error)") }
        }
        let memoryFailures = MemoryRegionDiagnostics.selfCheck()
        check(memoryFailures.isEmpty, "host memory-region diagnostics: \(memoryFailures)")

        // CRC32 (GPT) and SHA-512 crypt reference vectors (Drepper's specification).
        check(GPT.crc32(Array("123456789".utf8)) == 0xCBF4_3926, "crc32 check value")
        check(SHA512Crypt.hash("Hello world!", salt: "saltstring")
              == "$6$saltstring$svn8UoSVapNtMuq1ukKS4tPQd8iKwSMHWjl/O817G3uBnIFNjnQJuesI68u4OTLiBFdcbYEdFCoEOfaS35inz1",
              "sha512-crypt vector 1")
        check(SHA512Crypt.hash("Hello world!", salt: "saltstringsaltstring", rounds: 10000)
              == "$6$rounds=10000$saltstringsaltst$OW1/O6BYHV6BcXZu8QVeXbDWra3Oeqh0sbHbbMCVNSnCM/UrjmM0Dp8vOuZeHBy/YTBmSK6H9qs/y3RnOaw5v.",
              "sha512-crypt vector 2 (rounds, salt truncated to 16)")
        let salt = SHA512Crypt.randomSalt()
        check(salt.count == 16 && SHA512Crypt.hash("steamos", salt: salt).hasPrefix("$6$\(salt)$"), "random salt")

        // desync progress lines.
        check(DiskCreator.percent(in: "Attempt 1: Assembling   32.27% 1m2s") == 32.27, "desync progress parse")
        check(DiskCreator.percent(in: "Attempt 1: Validating ") == nil, "desync non-progress line")
        // desync's pty output as read when a chunk download fails (desync 1.1.4, store
        // unreachable): "\r\n" ends the progress line before "Error: …" (STEAMAC-2J).
        let chunk = "aefdae76bcb0938909114209683c1932cd522da1d0bfeb4d7bdde5ef4746a318"
        let failedOutput = "\rAttempt 1: Validating \rAttempt 1: Validating  0s\r\n\rAttempt 1: Assembling    0.00%"
            + "\rAttempt 1: Assembling   61.04% 8m57s\r\nError: http://127.0.0.1:1/: http://127.0.0.1:1/aefd/\(chunk).cacnk: "
            + "Get \"http://127.0.0.1:1/aefd/\(chunk).cacnk\": dial tcp 127.0.0.1:1: connect: connection refused\r\n"
        // One read (the failing case), and reads split between "\r" and "\n".
        let bytes = Array(failedOutput.utf8)
        let crlf = bytes.indices.dropLast().filter { bytes[$0] == 13 && bytes[$0 + 1] == 10 }
        var lines: [String] = []
        for cuts in [[], crlf.map { $0 + 1 }] {
            var pending = "", got: [String] = [], from = 0
            for cut in cuts + [bytes.count] {
                pending += String(decoding: bytes[from..<cut], as: UTF8.self)
                got += DiskCreator.terminalLines(&pending)
                from = cut
            }
            got += DiskCreator.terminalLines(&pending, final: true)
            let errorLine = got.first { $0.hasPrefix("Error: ") }
            check(got.contains("Attempt 1: Assembling   61.04% 8m57s") && errorLine != nil && DiskCreator.percent(in: errorLine!) == nil
                  && got.allSatisfy { !$0.contains("\r") && !$0.contains("\n") },
                  "desync \"\\r\\n\" ends the progress line: the Error line is its own non-progress line, \(cuts.count + 1) read(s) (STEAMAC-2J)")
            lines = got
        }
        var unterminated = "Attempt 1: Assembling   1.00%\rError: last words"
        check(DiskCreator.terminalLines(&unterminated) == ["Attempt 1: Assembling   1.00%"] && unterminated == "Error: last words"
              && DiskCreator.terminalLines(&unterminated, final: true) == ["Error: last words"], "unterminated last desync line kept")
        let network = DiskCreator.desyncFailure(status: 1, output: lines.filter { DiskCreator.percent(in: $0) == nil && !$0.hasPrefix("Attempt ") })
        check(network is DiskCreationFilesystem.Rejection && "\(network)".contains("connection refused") && !"\(network)".contains(chunk),
              "desync download failure: log-only rejection with desync's error, chunk ids left out")
        let full = DiskCreator.desyncFailure(status: 1, output: ["Error: write /Volumes/Untitled/steamos.img.rootfs-tmp: no space left on device"])
        check(full is DiskCreationFilesystem.Rejection && CrashReporting.diskCreationReport(full) == nil, "desync out of space is log-only")
        let other = [DiskCreator.desyncFailure(status: 1, output: ["Error: chunk \(chunk) missing from store"]),
                     DiskCreator.desyncFailure(status: 1, output: ["Error: chunk 4bbce92bb44181499e4dec8c0872563475175cbce8cf5f50cbd6b33812a61246 missing from store"])]
        check(other.allSatisfy { $0 is OptionError && "\($0)" == "desync extract failed (exit 1): chunk <chunk> missing from store" }
              && CrashReporting.diskCreationReport(other[0])?.key == CrashReporting.diskCreationReport(other[1])?.key,
              "other desync failures are reported with desync's error, grouped across chunks")
        // SteamOS 20261007's index: 63188 unique chunks, 4402745357 bytes. On exFAT with 128 KiB
        // clusters (a 2 TB drive) the chunk cache took 28032630784 bytes (STEAMAC-30).
        check(DiskCreator.chunkCacheBytes(dataBytes: 4_402_745_357, chunks: 63188, blockSize: 128 << 10) >= 28_032_630_784,
              "exFAT chunk cache estimate covers per-file and per-directory cluster slack (STEAMAC-30)")
        check(DiskCreator.sparseWorkingBytes(rootBytes: 10 << 30, dataBytes: 4_402_745_357)
              == 19_542_908_954, "space includes desync's fully preallocated 10 GiB temporary rootfs (STEAMAC-48)")

        check(DiskCreator.branches == ["stable", "rc"], "stable and rc branches offered")
        for branch in DiskCreator.branches {
            attempt("branch \(branch)") {
                check(try Options.parse(["steamac-vm", "--create-disk", "/tmp/steamac-branch.img", "--branch", branch]).createBranch == branch,
                      "CLI accepts branch \(branch)")
            }
        }
        for branch in ["beta", "preview", "main", "unknown"] {
            var rejected = false
            do { _ = try Options.parse(["steamac-vm", "--create-disk", "/tmp/steamac-branch.img", "--branch", branch]) }
            catch { rejected = true }
            check(rejected, "CLI rejects branch \(branch)")
        }

        // NSError descriptions include pointer addresses and URLSession task UUIDs. Neither
        // belongs in a title/fingerprint; keep the full diagnostic as scrubbed event details.
        let tlsA = NSError(domain: NSURLErrorDomain, code: NSURLErrorSecureConnectionFailed,
                           userInfo: [NSLocalizedDescriptionKey: "TLS failed, task <\(UUID().uuidString)>",
                                      NSUnderlyingErrorKey: NSError(domain: "kCFErrorDomainCFNetwork", code: -1200,
                                                                    userInfo: ["_kCFStreamErrorCodeKey": -9816])])
        let tlsB = NSError(domain: NSURLErrorDomain, code: NSURLErrorSecureConnectionFailed,
                           userInfo: [NSLocalizedDescriptionKey: "TLS failed, task <\(UUID().uuidString)>"])
        check(CrashReporting.diskCreationReport(tlsA) == nil && CrashReporting.diskCreationReport(tlsB) == nil,
              "system TLS failures are log-only without changing certificate validation")
        let tlsMessage = NetworkFailure.message(tlsA, server: .valve)
        check(tlsMessage.contains("Valve's servers securely") && tlsMessage.contains("VPN, proxy, or network filter"),
              "disk TLS message explains possible network interference")
        check(NetworkFailure.message(tlsA, server: .updates).contains("update server (GitHub) securely"),
              "update TLS message identifies the correct server")
        let offline = NSError(domain: NSURLErrorDomain, code: NSURLErrorNotConnectedToInternet)
        check(NetworkFailure.message(offline, server: .valve).contains("Check your internet connection"),
              "offline download message")
        for code in [NSURLErrorTimedOut, NSURLErrorNotConnectedToInternet, NSURLErrorCannotFindHost,
                     NSURLErrorNetworkConnectionLost, NSURLErrorSecureConnectionFailed] {
            check(CrashReporting.diskCreationReport(NSError(domain: NSURLErrorDomain, code: code)) == nil,
                  "expected URLSession connectivity failure is log-only: \(code)")
        }
        check(CrashReporting.diskCreationReport(NSError(domain: NSURLErrorDomain, code: NSURLErrorCannotParseResponse)) != nil,
              "unexpected URLSession protocol failure remains reportable")
        for code in [EROFS, EACCES, EPERM, ENOSPC, EDQUOT, ENXIO, ENODEV, EIO, ENOENT] {
            let detail = "write /Volumes/test/steamos.img: \(String(cString: strerror(code)))"
            let posix = NSError(domain: NSPOSIXErrorDomain, code: Int(code))
            let cocoa = NSError(domain: NSCocoaErrorDomain, code: NSFileWriteUnknownError,
                                userInfo: [NSUnderlyingErrorKey: posix])
            check([posix as Error, cocoa as Error, OptionError(detail)].allSatisfy {
                DiskCreationFilesystem.rejection($0) != nil && CrashReporting.diskCreationReport($0) == nil
            }, "filesystem condition at any creation stage is log-only: \(code)")
            let desync = DiskCreator.desyncFailure(status: 1, output: ["Error: failed to store in local cache: \(detail.lowercased())"])
            check(desync is DiskCreationFilesystem.Rejection && CrashReporting.diskCreationReport(desync) == nil,
                  "desync filesystem condition is log-only: \(code)")
        }
        attempt("removed download-cache directory (STEAMAC-5D)") {
            let fm = FileManager.default
            let dir = NSTemporaryDirectory() + "steamac-removed-cache-\(UUID().uuidString)"
            try fm.createDirectory(atPath: dir, withIntermediateDirectories: true)
            try fm.removeItem(atPath: dir)
            do {
                try Data([1, 2, 3]).write(to: URL(fileURLWithPath: dir + "/rootfs.img.caibx"))
                check(false, "writing into a removed cache must fail")
            } catch {
                check(DiskCreationFilesystem.rejection(error) != nil && CrashReporting.diskCreationReport(error) == nil,
                      "removed cache/drive while extracting the index is explained and log-only")
            }
        }
        check(DiskCreator.cacheRenameCollision(output: ["Error: failed to store in local cache: rename /cache/.tmp-cacnk.1 /cache/chunk.cacnk: file exists"])
              && !DiskCreator.cacheRenameCollision(output: ["Error: rename /rootfs /output: file exists"]),
              "only chunk-cache rename collisions trigger uncached serial recovery")
        for reason in ["not enough free space", "FAT32/MS-DOS volume", "read-only volume", "already exists"] {
            check(CrashReporting.diskCreationReport(DiskCreationFilesystem.Rejection(reason)) == nil,
                  "expected location rejection is log-only: \(reason)")
        }
        check(CrashReporting.diskCreationReport(DiskCreator.Cancelled()) == nil, "cancelled disk creation is log-only")
        let publication = CrashReporting.diskCreationReport(OptionError("rename /Volumes/disk: Operation not supported"))
        let signature = CrashReporting.diskCreationReport(OptionError("bundle signature: certificate chain not trusted"))
        check(publication != nil && signature != nil && publication?.key != signature?.key,
              "unexpected filesystem and signature failures remain distinct reports")
        let development = RaucBundle.trustFailure(signer: "steamos-dev-images", detail: "untrusted")
        check(development is RaucBundle.DevelopmentSignature && CrashReporting.diskCreationReport(development) == nil,
              "development trust rejection is log-only")
        for signer in ["frame-images", "", "steamos-dev-images-other"] {
            check(CrashReporting.diskCreationReport(RaucBundle.trustFailure(signer: signer, detail: "steamos-dev-images")) != nil,
                  "other trust failures stay reportable: \(signer)")
        }
        attempt("concurrent disk creation") {
            let dir = NSTemporaryDirectory() + "steamac-lock-\(UUID().uuidString)"
            try FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
            defer { try? FileManager.default.removeItem(atPath: dir) }
            let first = try DiskCreator.acquireCreationLock(cacheRoot: dir)
            defer { close(first) }
            do {
                let second = try DiskCreator.acquireCreationLock(cacheRoot: dir)
                close(second)
                check(false, "second disk creation must be rejected")
            } catch {
                check("\(error)".contains("wait for it to finish or cancel it"), "concurrent creation explains how to proceed")
                check(CrashReporting.diskCreationReport(error) == nil, "concurrent creation guard is log-only")
            }
            do {
                let fd = try DiskCreator.acquireCreationLock(cacheRoot: dir + "/missing")
                close(fd)
                check(false, "missing cache must fail")
            } catch {
                check(CrashReporting.diskCreationReport(error) == nil, "removed cache while acquiring its lock is log-only")
            }
        }

        // Optional real development-signed Valve bundle; never accepted or reported.
        if let path = ProcessInfo.processInfo.environment["STEAMAC_PROVISION_TEST_DEV_BUNDLE"] {
            attempt("development bundle") {
                guard let caPath = DiskCreator.caPath else { throw OptionError("Valve CA not found") }
                var bundle = try RaucBundle(contentsOf: path)
                do {
                    try bundle.verify(ca: RaucBundle.loadCA(caPath))
                    check(false, "development-signed bundle must not verify")
                } catch {
                    check(CrashReporting.diskCreationReport(error) == nil, "Valve development signer is log-only")
                    check("\(error)".contains("Valve's development key") && "\(error)".contains("choose stable or try again later"),
                          "development signer message explains how to proceed")
                }
            }
        }

        // Optional live TLS rejection using the exact metadata fetch path; no SDK setup or
        // capture occurs in this self-test. Point at a local server with an untrusted cert.
        if let value = ProcessInfo.processInfo.environment["STEAMAC_PROVISION_TEST_TLS_URL"] {
            if let url = URL(string: value), url.scheme == "https" {
                do {
                    _ = try DiskCreator().fetch(url)
                    check(false, "forced TLS failure unexpectedly succeeded")
                } catch {
                    let e = error as NSError
                    check(e.domain == NSURLErrorDomain && (-1206 ... -1200).contains(e.code),
                          "live downloader rejects untrusted TLS")
                    log("selftest-provision: TLS details: \(error)")
                    log("selftest-provision: TLS message: \(NetworkFailure.message(error, server: .valve))")
                    check(CrashReporting.diskCreationReport(error) == nil, "live TLS failure is log-only")
                    check(NetworkFailure.isExpected(error), "live TLS failure is an expected connectivity condition")
                }
            } else {
                check(false, "STEAMAC_PROVISION_TEST_TLS_URL must be an HTTPS URL")
            }
        }

        attempt("disk publication") {
            let fm = FileManager.default
            let dir = NSTemporaryDirectory() + "steamac-publish-\(UUID().uuidString)"
            try fm.createDirectory(atPath: dir, withIntermediateDirectories: true)
            defer { try? fm.removeItem(atPath: dir) }
            let lock = open(dir + "/creation.lock", O_RDWR | O_CREAT | O_CLOEXEC, 0o600)
            guard lock >= 0 else { throw OptionError("open creation.lock") }
            defer { close(lock) }
            guard flock(lock, LOCK_EX | LOCK_NB) == 0 else { throw OptionError("flock creation.lock") }
            _ = try DiskCreationFilesystem.preflight(directory: dir, diskBytes: 1 << 20, rootfsBytes: 1 << 20)
            let partial = dir + "/disk.partial", final = dir + "/disk"
            let original = Data("original disk".utf8), replacement = Data("replacement disk".utf8)
            try original.write(to: URL(fileURLWithPath: partial))
            try DiskCreationFilesystem.publish(partial: partial, destination: final)
            check(try Data(contentsOf: URL(fileURLWithPath: final)) == original
                  && !fm.fileExists(atPath: partial), "disk published without a partial file")
            try replacement.write(to: URL(fileURLWithPath: partial))
            var rejected = false
            do { try DiskCreationFilesystem.publish(partial: partial, destination: final) }
            catch {
                rejected = error is DiskCreationFilesystem.Rejection && CrashReporting.diskCreationReport(error) == nil
            }
            let preserved = try Data(contentsOf: URL(fileURLWithPath: final))
            check(rejected && preserved == original, "existing disk never replaced")
            // Filesystems such as exFAT cannot create symlinks.
            let link = dir + "/dangling-link"
            if symlink(dir + "/missing", link) == 0 {
                rejected = false
                do { try DiskCreationFilesystem.publish(partial: partial, destination: link) }
                catch {
                    rejected = error is DiskCreationFilesystem.Rejection && CrashReporting.diskCreationReport(error) == nil
                }
                var info = stat()
                check(rejected && lstat(link, &info) == 0 && info.st_mode & S_IFMT == S_IFLNK,
                      "dangling destination symlink never replaced")
            }
        }

        attempt("disk folder without write permission") {
            let fm = FileManager.default
            let dir = NSTemporaryDirectory() + "steamac-readonly-\(UUID().uuidString)"
            try fm.createDirectory(atPath: dir, withIntermediateDirectories: true)
            defer { chmod(dir, 0o755); try? fm.removeItem(atPath: dir) }
            try DiskCreationFilesystem.requireWritable(directory: dir)
            check((try? fm.contentsOfDirectory(atPath: dir))?.isEmpty == true, "write probe leaves nothing behind")
            chmod(dir, 0o555)
            var rejected = false
            do { try DiskCreationFilesystem.requireWritable(directory: dir) }
            catch { rejected = error is DiskCreationFilesystem.Rejection && CrashReporting.diskCreationReport(error) == nil }
            check(rejected, "unwritable folder rejected before download, log-only (STEAMAC-2H)")
        }

        attempt("sparse rootfs copy and integrity") {
            let fm = FileManager.default
            let dir = NSTemporaryDirectory() + "steamac-rootfs-\(UUID().uuidString)"
            try fm.createDirectory(atPath: dir, withIntermediateDirectories: true)
            defer { try? fm.removeItem(atPath: dir) }
            let size = 2 << 20
            var data = Data(count: size)
            data.replaceSubrange(123..<40000, with: repeatElement(UInt8(0x5a), count: 40000 - 123))
            data.replaceSubrange((size - 40000)..<(size - 123), with: repeatElement(UInt8(0xa5), count: 40000 - 123))
            let source = dir + "/rootfs"
            let input = open(source, O_RDWR | O_CREAT | O_EXCL, 0o600)
            guard input >= 0 else { throw OptionError("open test rootfs") }
            defer { close(input) }
            guard ftruncate(input, off_t(size)) == 0 else { throw OptionError("truncate test rootfs") }
            try data.withUnsafeBytes {
                try GPT.pwriteAll(input, UnsafeRawBufferPointer(rebasing: $0[0..<65536]), at: 0)
                try GPT.pwriteAll(input, UnsafeRawBufferPointer(rebasing: $0[(size - 65536)..<size]), at: UInt64(size - 65536))
            }
            let expected = SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
            for sparse in [true, false] {
                let target = dir + "/copy-\(sparse)"
                let output = open(target, O_RDWR | O_CREAT | O_EXCL, 0o600)
                guard output >= 0 else { throw OptionError("open test copy") }
                defer { close(output) }
                guard ftruncate(output, off_t(2 * size)) == 0 else { throw OptionError("truncate test copy") }
                try DiskCreator().copyRootfs(source, size: UInt64(size), into: output,
                                             offsets: [0, UInt64(size)], sha256: expected, sparse: sparse)
                check(try Data(contentsOf: URL(fileURLWithPath: target)) == data + data,
                      "rootfs hash and both slots match with sparse=\(sparse)")
                do {
                    try DiskCreator().copyRootfs(source, size: UInt64(size), into: output,
                                                 offsets: [], sha256: String(repeating: "0", count: 64), sparse: sparse)
                    check(false, "incorrect rootfs hash must fail")
                } catch is DiskCreator.IntegrityFailure {
                    check(fm.fileExists(atPath: source), "failed rootfs kept until recovery can diagnose its bytes")
                }
            }
            if let desync = DiskCreator.desyncPath {
                let store = dir + "/store", cache = dir + "/cache", index = dir + "/rootfs.caibx"
                try fm.createDirectory(atPath: store, withIntermediateDirectories: true)
                try fm.createDirectory(atPath: cache, withIntermediateDirectories: true)
                let make = Process(), output = Pipe()
                make.executableURL = URL(fileURLWithPath: desync)
                make.arguments = ["make", "--store", store, index, source]
                make.standardOutput = output; make.standardError = output
                try make.run()
                let diagnostic = output.fileHandleForReading.readDataToEndOfFile()
                make.waitUntilExit()
                guard make.terminationStatus == 0 else { throw OptionError("desync fixture: \(String(decoding: diagnostic, as: UTF8.self))") }
                let creator = DiskCreator()
                let info = try creator.desyncInfo(desync, index)
                check(info.bytes > 0 && info.chunks > 0, "desync info parses real signed-index format")
                for (name, useCache) in [("cached", true), ("repaired", true), ("uncached", false)] {
                    if name == "repaired", let chunk = (fm.enumerator(atPath: cache)?.allObjects as? [String])?.first(where: { $0.hasSuffix(".cacnk") }) {
                        try Data("broken cache chunk".utf8).write(to: URL(fileURLWithPath: cache + "/" + chunk))
                    }
                    let extracted = dir + "/" + name
                    try creator.reconstruct(desync, index, extracted, stores: [store], cache: useCache ? cache : nil,
                                            dataBytes: info.bytes, concurrency: useCache ? 16 : 1)
                    check(try Data(contentsOf: URL(fileURLWithPath: extracted)) == data,
                          "real desync extraction matches original: \(name)")
                }
                let invalid = dir + "/invalid.caibx"
                try Data("invalid index".utf8).write(to: URL(fileURLWithPath: invalid))
                do {
                    _ = try creator.desyncInfo(desync, invalid)
                    check(false, "invalid desync index must fail")
                } catch {
                    check("\(error)".contains("exit 1") && "\(error)".contains("Error:"),
                          "desync info preserves its actual stderr instead of hiding it (STEAMAC-40)")
                }
            } else {
                log("selftest-provision: SKIP real desync fixture (desync not found)")
            }
        }

        // GPT: writer -> reader round trip on a sparse temp file.
        let table = DiskLayout.table(homeGiB: DiskLayout.defaultHomeGiB)
        attempt("GPT round trip") {
            let tmp = NSTemporaryDirectory() + "steamac-gpt-\(getpid()).img"
            defer { unlink(tmp) }
            let fd = open(tmp, O_RDWR | O_CREAT | O_TRUNC, 0o600)
            guard fd >= 0 else { throw OptionError("open \(tmp)") }
            defer { close(fd) }
            guard ftruncate(fd, off_t(table.sectors * 512)) == 0 else { throw OptionError("ftruncate") }
            try table.write(fd: fd)
            let back = try GPT.read(path: tmp)
            check(back == table, "GPT write/read round trip (CRCs, backup = primary)")
            check(try DiskCreator.verifyGPT(path: tmp, expected: table) == table,
                  "private disk GPT verification succeeds")
            var wrong = table
            wrong.entries[0].uuid = UUID()
            do {
                _ = try DiskCreator.verifyGPT(path: tmp, expected: wrong)
                check(false, "different valid GPT must fail before publication")
            } catch {
                check("\(error)".contains("Check the drive") && CrashReporting.diskCreationReport(error) != nil,
                      "unexplained valid GPT mismatch remains reportable, with recovery advice")
            }
            do {
                try DiskCreator.requireRootfs(tmp + ".missing", size: 512)
                check(false, "missing reconstructed rootfs must fail")
            } catch {
                check("\(error)".contains("drive is connected") && CrashReporting.diskCreationReport(error) != nil,
                      "unexplained missing rootfs remains reportable, with recovery advice")
            }
            check(table.entries.allSatisfy { $0.firstLBA % 2048 == 0 && $0.sectors % 2048 == 0 }, "1 MiB alignment")
            check(table.entries.last!.lastLBA + 1 + 2048 == table.sectors, "1 MiB free behind home")
            check(Set(table.entries.map(\.uuid)).count == 8 && !table.entries.contains { $0.uuid == table.diskGUID },
                  "unique random PARTUUIDs / disk GUID")
            var rejected = false
            do { _ = try DiskGrower.request(path: tmp, homeGiB: DiskLayout.defaultHomeGiB) }
            catch { rejected = true }
            check(rejected, "disk growth rejects same size / shrinking")
            try DiskGrower.grow(DiskGrower.request(path: tmp, homeGiB: DiskLayout.defaultHomeGiB + 16))
            let grown = try GPT.read(path: tmp)
            check(grown.diskGUID == table.diskGUID && grown.entries == table.entries,
                  "disk growth retains GUIDs and partition extents for guest repart")
            check(grown.sectors == table.sectors + 16 * 1024 * 1024 * 1024 / 512,
                  "disk growth extends image and relocates both GPT headers")
        }

        // GPT vs the Docker-built disk (scripts/steps/40-disk.sh + sgdisk).
        let reference = o.referenceDisk ?? (DiskCreator.locate("steamos.img", dev: ["steamos.img"]) ?? "")
        if FileManager.default.isReadableFile(atPath: reference) {
            attempt("reference GPT \(reference)") {
                let ref = try GPT.read(path: reference)
                // Reference disks may use a non-default home size; match that request while
                // still comparing every extent/header/MBR against the independent sgdisk image.
                guard let referenceHome = ref.entry("home") else { throw OptionError("reference has no home partition") }
                let homeGiB = Int(referenceHome.sectors * DiskLayout.sector / (1 << 30))
                let table = DiskLayout.table(homeGiB: homeGiB)
                log("selftest-provision: reference \(reference):\n" + ref.dump())
                log("selftest-provision: new table (home \(homeGiB) GiB):\n" + table.dump())
                check(ref.entries.map(\.name) == table.entries.map(\.name), "partition names/order")
                check(ref.entries.map(\.type) == table.entries.map(\.type), "partition type GUIDs")
                check(ref.entries.map(\.firstLBA) == table.entries.map(\.firstLBA), "partition start sectors")
                check(ref.entries.map(\.attributes) == table.entries.map(\.attributes), "attributes")
                check(Array(ref.entries.dropLast().map(\.lastLBA)) == Array(table.entries.dropLast().map(\.lastLBA)),
                      "sizes esp..var-B")
                let home = ref.entries.last!, newHome = table.entries.last!
                // The VM's systemd-repart (90-home.conf) may have grown home to the end of the image.
                check(home.lastLBA == newHome.lastLBA || (ref.sectors == table.sectors && home.lastLBA <= ref.lastUsableLBA),
                      "home size (\(home.sectors / 2048) MiB vs \(newHome.sectors / 2048) MiB, repart growth allowed)")
                check(ref.sectors == table.sectors, "disk size \(ref.sectors) sectors")
                check(ref.firstUsableLBA == table.firstUsableLBA && ref.lastUsableLBA == table.lastUsableLBA, "usable LBA range")
                let fd = open(reference, O_RDONLY)
                defer { close(fd) }
                let mbr = try GPT.preadAll(fd, 512, at: 0)
                check(Array(mbr[446..<512]) == Array(table.primaryBytes()[446..<512]), "protective MBR bytes identical to sgdisk's")
            }
        } else {
            log("selftest-provision: SKIP reference GPT (no readable \(reference.isEmpty ? "work/out/steamos.img" : reference))")
        }

        // Payload: cpio newc with provision.env first, 1 MiB padded.
        attempt("payload") {
            let v = ProvisionPayload.Values(buildID: "20260922.6101926", version: "0.3.0", branch: "stable",
                                            rootfsSHA256: String(repeating: "a", count: 64),
                                            passwordHash: SHA512Crypt.hash("steamos"), machineID: ProvisionPayload.randomMachineID(), gpt: table)
            let env = try ProvisionPayload.env(v)
            let caibx = (0..<100_003).map { UInt8(truncatingIfNeeded: $0 &* 31) }
            let img = ProvisionPayload.image(env: env, caibx: caibx)
            check(img.count % (1 << 20) == 0, "payload padded to 1 MiB")
            let files = try Cpio.parse(img)
            check(files.map(\.0) == ["provision.env", "rootfs.caibx"], "cpio members in order")
            check(files.first?.1 == Array(env.utf8) && files.last?.1 == caibx, "cpio contents")
            check(env.contains("PARTUUID_ROOTFS_B='\(table.entry("rootfs-B")!.uuid.uuidString.lowercased())'")
                  && env.contains("DISK_GUID='\(table.diskGUID.uuidString.lowercased())'"), "provision.env GUIDs lowercase")
            check(Provision.payloadPath(forDisk: "/x/steamos.img") == "/x/steamos.provision.img", "payload path")
        }

        // Bundle: CMS signature (pinned CA only), squashfs (zstd), manifest; against the Docker
        // build's cache (work/cache/rootfs/<buildid>: .raucb + unsquashfs'd bundle/).
        if let caPath = DiskCreator.caPath, let dir = cachedBundleDir() {
            attempt("bundle \(dir)") {
                let ca = try RaucBundle.loadCA(caPath)
                let raucb = try FileManager.default.contentsOfDirectory(atPath: dir).first { $0.hasSuffix(".raucb") }!
                var b = try RaucBundle(contentsOf: dir + "/" + raucb)
                try b.verify(ca: ca)
                check(b.signer == "frame-images", "CMS signature verifies (signer \(b.signer))")
                var tampered = try tamper(dir + "/" + raucb)
                check((try? tampered.verify(ca: ca)) == nil, "tampered squashfs rejected")
                let fs = try Squashfs(b.squashfs)
                check(Set(try fs.rootFiles()) == ["UUID", "manifest.raucm", "rootfs.img.caibx"], "squashfs root listing")
                for name in ["UUID", "manifest.raucm", "rootfs.img.caibx"] {
                    let ours = try fs.file(name)
                    let theirs = try [UInt8](Data(contentsOf: URL(fileURLWithPath: dir + "/bundle/" + name)))
                    check(ours == theirs, "squashfs \(name) == unsquashfs (\(ours.count) bytes)")
                }
                let m = try RaucBundle.parseManifest(String(decoding: try fs.file("manifest.raucm"), as: UTF8.self))
                check(m.compatible == "steamos-aarch64" && m.rootfsSize == DiskLayout.rootMiB << 20 && m.rootfsSHA256.count == 64,
                      "manifest \(m.version) sha256 \(m.rootfsSHA256)")
                // Another real Valve certificate (the bundle's signer leaf) must not pass as the anchor.
                if FileManager.default.fileExists(atPath: dir + "/signer.pem") {
                    check((try? RaucBundle.loadCA(dir + "/signer.pem")) == nil, "non-pinned certificate refused as CA")
                }
            }
        } else {
            log("selftest-provision: SKIP bundle (no Valve CA or no cached bundle in work/cache/rootfs)")
        }

        log("selftest-provision: \(failures == 0 ? "all passed" : "\(failures) failure(s)")")
        exit(failures == 0 ? 0 : 1)
    }

    private static func cachedBundleDir() -> String? {
        guard let out = DiskCreator.locate("Image", dev: ["Image"]).map({ ($0 as NSString).deletingLastPathComponent }) else { return nil }
        let root = ((out as NSString).deletingLastPathComponent as NSString).appendingPathComponent("cache/rootfs")
        let ids = (try? FileManager.default.contentsOfDirectory(atPath: root))?.sorted() ?? []
        return ids.reversed().map { root + "/" + $0 }.first {
            FileManager.default.fileExists(atPath: $0 + "/bundle/manifest.raucm")
                && ((try? FileManager.default.contentsOfDirectory(atPath: $0))?.contains { $0.hasSuffix(".raucb") } ?? false)
        }
    }

    /// The bundle with one squashfs byte flipped.
    private static func tamper(_ path: String) throws -> RaucBundle {
        var d = try [UInt8](Data(contentsOf: URL(fileURLWithPath: path)))
        d[4096] ^= 0x01
        let tmp = NSTemporaryDirectory() + "steamac-tampered-\(getpid()).raucb"
        defer { unlink(tmp) }
        try Data(d).write(to: URL(fileURLWithPath: tmp))
        return try RaucBundle(contentsOf: tmp)
    }
}
