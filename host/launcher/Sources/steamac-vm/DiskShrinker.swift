import Darwin
import Foundation

/// Shrink an existing SteamOS image's **home capacity** while the VM is stopped.
///
/// Grow only enlarges the image; the guest grows partition + ext4 on next boot. Shrink is the
/// reverse and must shrink the ext4 filesystem **first** (initramfs `steamac.shrink-home=`, via
/// the rootfs `resize2fs`), then this type rewrites GPT and truncates the image. Truncating
/// before the filesystem fits destroys `/home`.
enum DiskShrinker {
    /// Slack kept above used bytes so journal/metadata still fit after resize2fs.
    static let slackBytes: UInt64 = 1 << 30  // 1 GiB

    struct Request: Codable {
        let path: String
        let homeGiB: Int
        let diskGUID: UUID
        /// True when the ext4 already fits `homeGiB` and only GPT/truncate remains.
        let filesystemFits: Bool
    }

    static let cmdlineFlagPrefix = "steamac.shrink-home="
    static func cmdlineFlag(homeGiB: Int) -> String { "\(cmdlineFlagPrefix)\(homeGiB)" }

    static func request(path: String, homeGiB: Int) throws -> Request {
        guard (8...4096).contains(homeGiB) else {
            throw OptionError("home size must be 8..4096 GiB", localized: String(localized: "home size must be 8..4096 GiB"))
        }
        let table = try GPT.read(path: path)
        guard let home = table.entries.last, home.name == "home", home.type == DiskLayout.typeHome,
              table.entries.dropLast().allSatisfy({ $0.lastLBA < home.firstLBA }) else {
            throw OptionError("\(path): not a SteamOS disk with home as its last partition",
                              localized: String(localized: "\(path): not a SteamOS disk with home as its last partition"))
        }
        let target = UInt64(homeGiB) * (1 << 30)
        let current = home.sectors * 512
        guard target < current else {
            let currentGiB = String(format: "%.1f", Double(current) / Double(1 << 30))
            throw OptionError("the new home size must be smaller than its current \(currentGiB) GiB (use Grow Disk to enlarge)",
                              localized: String(localized: "the new home size must be smaller than its current \(currentGiB) GiB (use Grow Disk to enlarge)"))
        }
        let probe = try Ext4Probe.read(path: path, partitionOffset: home.firstLBA * 512)
        let need = probe.usedBytes + slackBytes
        guard need <= target else {
            let usedGiB = String(format: "%.1f", Double(probe.usedBytes) / Double(1 << 30))
            throw OptionError("home uses about \(usedGiB) GiB; free space inside SteamOS or pick a larger size",
                              localized: String(localized: "home uses about \(usedGiB) GiB; free space inside SteamOS or pick a larger size"))
        }
        let filesystemFits = probe.totalBytes <= target
        return Request(path: path, homeGiB: homeGiB, diskGUID: table.diskGUID, filesystemFits: filesystemFits)
    }

    /// GPT + truncate only. Caller must ensure the ext4 already fits `homeGiB` (initramfs pass
    /// or `filesystemFits` from `request`).
    static func shrinkGPT(_ r: Request) throws {
        let fd = try DiskLock.lock(r.path, writable: true)
        defer { close(fd) }
        let checked = try request(path: r.path, homeGiB: r.homeGiB)
        guard checked.diskGUID == r.diskGUID else {
            throw OptionError("the selected SteamOS disk has changed; choose its size again",
                              localized: String(localized: "the selected SteamOS disk has changed; choose its size again"))
        }
        guard checked.filesystemFits else {
            throw OptionError("home filesystem is still larger than \(r.homeGiB) GiB; run the shrink boot first",
                              localized: String(localized: "home filesystem is still larger than \(r.homeGiB) GiB; start the shrink boot first"))
        }
        var table = try GPT.read(path: r.path)
        let homeIdx = table.entries.count - 1
        let home = table.entries[homeIdx]
        let targetSectors = UInt64(r.homeGiB) * (1 << 30) / 512
        // 1 MiB alignment (sgdisk -a 2048).
        let aligned = (targetSectors + 2047) / 2048 * 2048
        guard aligned >= 2048, home.firstLBA + aligned - 1 < table.lastUsableLBA + 1 else {
            throw OptionError("\(r.path): cannot align a \(r.homeGiB) GiB home partition")
        }
        table.entries[homeIdx].lastLBA = home.firstLBA + aligned - 1
        let bytes = (table.entries[homeIdx].lastLBA + 1) * 512 + DiskLayout.mib
        table.sectors = bytes / 512
        // Backup header first at the new end, then primary — same order as DiskGrower.
        try GPT.pwriteAll(fd, table.backupBytes(), at: (table.sectors - 1 - GPT.entryArraySectors) * 512)
        guard fsync(fd) == 0 else { throw OptionError("sync \(r.path): \(String(cString: strerror(errno)))") }
        try GPT.pwriteAll(fd, table.primaryBytes(), at: 0)
        guard fsync(fd) == 0 else { throw OptionError("sync \(r.path): \(String(cString: strerror(errno)))") }
        guard ftruncate(fd, off_t(bytes)) == 0 else {
            throw OptionError("shrink \(r.path): \(String(cString: strerror(errno)))")
        }
        guard fsync(fd) == 0 else { throw OptionError("sync \(r.path): \(String(cString: strerror(errno)))") }
        log("shrink-disk: \(r.path), home \(r.homeGiB) GiB; GPT rewritten and image truncated")
    }

    static func queue(_ request: Request, runDir: String) throws {
        try JSONEncoder().encode(request).write(to: URL(fileURLWithPath: runDir + "/shrink-disk.json"), options: .atomic)
    }

    /// Options hook: a queued shrink runs a one-shot boot (`shrink-home` + `slot=stop`) so
    /// initramfs can resize2fs before the host truncates GPT on the next supervisor loop.
    /// Re-probes the live ext4: the JSON `filesystemFits` bit is stale after the guest pass.
    static func attachPending(_ o: inout Options) {
        guard let dir = Supervisor.runDir, let queued = pending(runDir: dir) else { return }
        guard let live = try? request(path: queued.path, homeGiB: queued.homeGiB),
              live.diskGUID == queued.diskGUID, !live.filesystemFits else { return }
        let flag = cmdlineFlag(homeGiB: live.homeGiB)
        if !o.cmdline.split(separator: " ").contains(where: { $0.hasPrefix("steamac.shrink-home=") }) {
            o.cmdline += " " + flag
        }
        if !o.cmdline.split(separator: " ").contains("steamac.slot=stop") {
            o.cmdline += " steamac.slot=stop"
        }
        log("shrink-disk: this boot will shrink home to \(live.homeGiB) GiB then power off")
    }

    static func pending(runDir: String) -> Request? {
        let url = URL(fileURLWithPath: runDir + "/shrink-disk.json")
        guard let data = try? Data(contentsOf: url) else { return nil }
        return try? JSONDecoder().decode(Request.self, from: data)
    }

    static func clearPending(runDir: String) {
        try? FileManager.default.removeItem(atPath: runDir + "/shrink-disk.json")
    }

    /// True when a queued shrink's ext4 already fits and only GPT/truncate remains.
    /// Used by the supervisor to continue after `steamac.slot=stop` without a reboot marker.
    static func pendingReadyForGPT(runDir: String) -> Bool {
        guard let queued = pending(runDir: runDir),
              let live = try? request(path: queued.path, homeGiB: queued.homeGiB) else { return false }
        return live.diskGUID == queued.diskGUID && live.filesystemFits
    }

    /// After a successful initramfs shrink boot (`steamac.slot=stop`), finish GPT/truncate.
    /// If the filesystem is still large, leave the queue for `attachPending` (do not error —
    /// that boot must run before truncate).
    static func applyPending(runDir: String, disks: [DiskSpec]) throws {
        guard let queued = pending(runDir: runDir) else { return }
        guard disks.contains(where: { !$0.readOnly && $0.path == queued.path }) else {
            throw OptionError("the disk selected for shrink is no longer the next boot's writable disk",
                              localized: String(localized: "the disk selected for shrink is no longer the next boot's writable disk"))
        }
        let live = try request(path: queued.path, homeGiB: queued.homeGiB)
        guard live.diskGUID == queued.diskGUID else {
            throw OptionError("the selected SteamOS disk has changed; choose its size again",
                              localized: String(localized: "the selected SteamOS disk has changed; choose its size again"))
        }
        guard live.filesystemFits else {
            log("shrink-disk: filesystem still larger than \(queued.homeGiB) GiB; one-shot shrink boot runs first")
            return
        }
        try shrinkGPT(live)
        clearPending(runDir: runDir)
    }

    static func selfCheck() -> [String] {
        var failures: [String] = []
        var checks = 0
        func check(_ ok: Bool, _ name: String) {
            checks += 1
            if !ok { failures.append("disk shrink: \(name)") }
        }
        check(cmdlineFlag(homeGiB: 192) == "steamac.shrink-home=192", "cmdline flag")
        check(slackBytes == 1 << 30, "1 GiB slack")

        // Sparse SteamOS GPT (16 GiB home) + synthetic ext4 superblock in home.
        let table = DiskLayout.table(homeGiB: 16)
        let tmp = NSTemporaryDirectory() + "steamac-shrink-\(getpid()).img"
        defer { unlink(tmp) }
        do {
            let fd = open(tmp, O_RDWR | O_CREAT | O_TRUNC, 0o600)
            guard fd >= 0 else { throw OptionError("open \(tmp)") }
            defer { close(fd) }
            guard ftruncate(fd, off_t(table.sectors * 512)) == 0 else { throw OptionError("ftruncate") }
            try table.write(fd: fd)
            let home = table.entries.last!
            let homeOff = home.firstLBA * 512

            func writeSuper(blocks: UInt32, free: UInt32) throws {
                var sb = [UInt8](repeating: 0, count: 256)
                put32(&sb, 0x04, blocks)
                put32(&sb, 0x0C, free)
                put32(&sb, 0x18, 2)  // 4 KiB
                put16(&sb, 0x38, Ext4Probe.magic)
                try GPT.pwriteAll(fd, sb, at: homeOff + Ext4Probe.superOffset)
                guard fsync(fd) == 0 else { throw OptionError("fsync") }
            }

            // No ext4 yet → reject.
            var noFS = false
            do { _ = try request(path: tmp, homeGiB: 8) } catch { noFS = true }
            check(noFS, "rejects disk without ext4 home")

            // 2 GiB used (512k blocks free of 1M → used 512k * 4 KiB), slack 1 GiB → needs ≥3 GiB.
            try writeSuper(blocks: 1_048_576, free: 524_288)
            var tooSmall = false
            do { _ = try request(path: tmp, homeGiB: 2) } catch { tooSmall = true }
            check(tooSmall, "rejects target below used+slack")

            var sameSize = false
            do { _ = try request(path: tmp, homeGiB: 16) } catch { sameSize = true }
            check(sameSize, "rejects same-size / grow via shrink")

            // Filesystem already 4 GiB total → shrink to 8 fits without guest pass.
            try writeSuper(blocks: 1_048_576, free: 524_288)  // total 4 GiB
            let ready = try request(path: tmp, homeGiB: 8)
            check(ready.filesystemFits && ready.homeGiB == 8, "filesystemFits when ext4 ≤ target")
            try shrinkGPT(ready)
            let after = try GPT.read(path: tmp)
            let newHome = after.entries.last!
            check(after.diskGUID == table.diskGUID, "shrink keeps disk GUID")
            check(newHome.name == "home" && newHome.firstLBA == home.firstLBA, "home start retained")
            check(newHome.sectors * 512 == 8 * (1 << 30), "home is 8 GiB after shrink")
            check(after.sectors == (newHome.lastLBA + 1) + DiskLayout.mib / 512, "backup GPT behind home")
            check(AppBundle.isDiskImage(tmp), "shrunk GPT still selectable")

            // Still-large FS (16 GiB worth of blocks) → needs guest pass.
            // Recreate a 16 GiB home image for this case.
            unlink(tmp)
            let fd2 = open(tmp, O_RDWR | O_CREAT | O_TRUNC, 0o600)
            guard fd2 >= 0 else { throw OptionError("reopen") }
            defer { close(fd2) }
            guard ftruncate(fd2, off_t(table.sectors * 512)) == 0 else { throw OptionError("ftruncate2") }
            try table.write(fd: fd2)
            // 16 GiB of 4 KiB blocks, almost empty used.
            try writeSuperOnto(fd2, offset: homeOff, blocks: 4_194_304, free: 4_000_000)
            let pendingReq = try request(path: tmp, homeGiB: 8)
            check(!pendingReq.filesystemFits, "large FS needs shrink boot before GPT truncate")
            var refused = false
            do { try shrinkGPT(pendingReq) } catch { refused = true }
            check(refused, "shrinkGPT refuses while filesystem still large")

            let run = NSTemporaryDirectory() + "steamac-shrink-run-\(getpid())"
            try FileManager.default.createDirectory(atPath: run, withIntermediateDirectories: true)
            defer { try? FileManager.default.removeItem(atPath: run) }
            try queue(pendingReq, runDir: run)
            // applyPending must not error while the guest pass is still required.
            try applyPending(runDir: run, disks: [DiskSpec(path: tmp, readOnly: false)])
            check(pending(runDir: run) != nil, "applyPending keeps queue until FS fits")
            check(!pendingReadyForGPT(runDir: run), "pendingReadyForGPT false while FS large")
        } catch {
            failures.append("disk shrink: \(error)")
        }
        log("selftest-settings: disk shrink: \(checks) checks, \(failures.isEmpty ? "PASS" : failures.joined(separator: "; "))")
        return failures
    }

    private static func writeSuperOnto(_ fd: Int32, offset: UInt64, blocks: UInt32, free: UInt32) throws {
        var sb = [UInt8](repeating: 0, count: 256)
        put32(&sb, 0x04, blocks)
        put32(&sb, 0x0C, free)
        put32(&sb, 0x18, 2)
        put16(&sb, 0x38, Ext4Probe.magic)
        try GPT.pwriteAll(fd, sb, at: offset + Ext4Probe.superOffset)
        guard fsync(fd) == 0 else { throw OptionError("fsync") }
    }
    private static func put16(_ a: inout [UInt8], _ o: Int, _ v: UInt16) {
        a[o] = UInt8(truncatingIfNeeded: v); a[o + 1] = UInt8(truncatingIfNeeded: v >> 8)
    }
    private static func put32(_ a: inout [UInt8], _ o: Int, _ v: UInt32) {
        for i in 0..<4 { a[o + i] = UInt8(truncatingIfNeeded: v >> (8 * i)) }
    }
}
