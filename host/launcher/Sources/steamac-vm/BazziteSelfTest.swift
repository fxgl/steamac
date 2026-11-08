import Darwin
import Foundation

/// Tests the release trust boundary, bounded sparse extraction and backend routing.
enum BazziteSelfTest {
    static func run() -> Never {
        var failures = 0
        func check(_ name: String, _ body: () throws -> Bool) {
            do {
                if try body() { log("bazzite-test: PASS \(name)") }
                else { failures += 1; log("bazzite-test: FAIL \(name)") }
            } catch { failures += 1; log("bazzite-test: FAIL \(name): \(error)") }
        }
        func rejects(_ body: () throws -> Void) -> Bool {
            do { try body(); return false } catch { return true }
        }
        let fm = FileManager.default
        let dir = fm.temporaryDirectory.appendingPathComponent("bazzite-test-" + UUID().uuidString)
        try! fm.createDirectory(at: dir, withIntermediateDirectories: false)
        defer { try? fm.removeItem(at: dir) }
        check("owner release URL allowed") {
            try BazziteRelease.validateAssetURL(URL(string: "https://github.com/Naozumi520/bazzite/releases/download/v1/Image")!); return true
        }
        for value in ["http://github.com/Naozumi520/bazzite/releases/download/v1/Image",
                      "https://github.com/other/bazzite/releases/download/v1/Image",
                      "https://github.com.example.org/Naozumi520/bazzite/releases/download/v1/Image",
                      "https://user@github.com/Naozumi520/bazzite/releases/download/v1/Image"] {
            check("untrusted URL rejected: \(value)") { rejects { try BazziteRelease.validateAssetURL(URL(string: value)!) } }
        }
        let blank = dir.appendingPathComponent("blank")
        try! Data(count: 2 << 20).write(to: blank)
        check("streaming SHA256") { try BazziteDiskCreator.sha256(blank) == "5647f05ec18958947d32874eeb788fa396a05d0bab7c1b71f112ceb7e9b31eee" }
        let archive = dir.appendingPathComponent("disk.gz")
        let gzip = Process(), pipe = Pipe()
        gzip.executableURL = URL(fileURLWithPath: "/usr/bin/gzip")
        gzip.arguments = ["-c", blank.path]
        gzip.standardOutput = pipe
        try! gzip.run()
        let compressed = pipe.fileHandleForReading.readDataToEndOfFile()
        gzip.waitUntilExit()
        try! compressed.write(to: archive)
        check("bounded sparse extraction") {
            let target = dir.appendingPathComponent("disk")
            try BazziteDiskCreator().extract(archive, to: target, expectedBytes: 2 << 20)
            return try Data(contentsOf: target) == Data(count: 2 << 20)
        }
        check("oversized decompression rejected") {
            rejects { try BazziteDiskCreator().extract(archive, to: dir.appendingPathComponent("too-big"), expectedBytes: 100) }
        }
        check("truncated decompression rejected") {
            rejects { try BazziteDiskCreator().extract(archive, to: dir.appendingPathComponent("short"), expectedBytes: 3 << 20) }
        }
        check("cancelled extraction rejected") {
            let creator = BazziteDiskCreator(); creator.cancel()
            return rejects { try creator.extract(archive, to: dir.appendingPathComponent("cancel"), expectedBytes: 2 << 20) }
        }
        check("existing destination preserved") {
            rejects { try BazziteDiskCreator().extract(archive, to: blank, expectedBytes: 2 << 20) }
                && (try? Data(contentsOf: blank)) == Data(count: 2 << 20)
        }
        check("Fedora aligned GPT and invalid ranges") {
            let target = dir.appendingPathComponent("fedora.img")
            let table = GPT(diskGUID: UUID(), sectors: 8192, entries: [
                .init(type: DiskLayout.typeRoot, uuid: UUID(), firstLBA: 2048,
                      lastLBA: 6143, attributes: 0, name: "root")])
            let fd = open(target.path, O_RDWR | O_CREAT | O_EXCL, 0o600)
            guard fd >= 0 else { return false }
            defer { close(fd) }
            guard ftruncate(fd, off_t(table.sectors * 512)) == 0 else { return false }
            func write(_ first: UInt64, _ last: UInt64) throws {
                var primary = table.primaryBytes(), backup = table.backupBytes()
                for (isPrimary, offset) in [(true, 512), (false, 32 * 512)] {
                    var h = Array((isPrimary ? primary : backup)[offset..<(offset + 512)])
                    GPT.put64(&h, 40, first); GPT.put64(&h, 48, last)
                    GPT.put32(&h, 16, 0); GPT.put32(&h, 16, GPT.crc32(h[0..<92]))
                    if isPrimary { primary.replaceSubrange(offset..<(offset + 512), with: h) }
                    else { backup.replaceSubrange(offset..<(offset + 512), with: h) }
                }
                try GPT.pwriteAll(fd, primary, at: 0)
                try GPT.pwriteAll(fd, backup, at: (table.sectors - 33) * 512)
            }
            try write(2048, 8158)
            guard try GPT.read(path: target.path, allowAlignedUsableRange: true) == table,
                  rejects({ _ = try GPT.read(path: target.path) }) else { return false }
            try write(4096, 8158)
            guard rejects({ _ = try GPT.read(path: target.path, allowAlignedUsableRange: true) }) else { return false }
            try write(2048, 8191)
            return rejects { _ = try GPT.read(path: target.path, allowAlignedUsableRange: true) }
        }
        let asset = BazziteGuest.Asset(name: "disk.gz", sha256: String(repeating: "a", count: 64), bytes: 100)
        let guest = BazziteGuest(schema: 1, build: "test", sourceRevision: "test", diskBytes: 40 << 30,
                                commandLine: "root=UUID=123 ostree=/ostree/test selinux=0", disk: asset,
                                kernel: .init(name: "Image", sha256: asset.sha256, bytes: 50),
                                initrd: .init(name: "initrd", sha256: asset.sha256, bytes: 50))
        check("manifest and boot routing") {
            try guest.validate()
            var o = Options()
            guest.apply(&o, diskPath: "/tmp/test.img")
            return o.kernel == "/tmp/test.img.bazzite/Image" && o.initrd == "/tmp/test.img.bazzite/initrd"
                && o.cmdline == guest.commandLine && o.wmtrLibrary == nil && o.mouseMode == .tablet
        }
        check("explicit boot arguments preserved") {
            var o = Options(); o.explicit = ["--cmdline"]; o.cmdline = "custom"
            guest.apply(&o, diskPath: "/tmp/test.img")
            return o.cmdline == "custom"
        }
        try? fm.removeItem(at: dir)
        log("bazzite-test: \(failures == 0 ? "PASS" : "FAIL") (\(failures) failures)")
        exit(failures == 0 ? 0 : 1)
    }
}
