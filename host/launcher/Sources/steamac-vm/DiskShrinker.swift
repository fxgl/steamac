import Darwin
import Foundation

/// Shrink an existing SteamOS image's **home capacity** while the VM is stopped.
///
/// Grow only enlarges the image; the guest grows partition + ext4 on next boot. Shrink is the
/// reverse and must shrink the ext4 filesystem **first** (a one-shot guest boot,
/// `steamac.shrink-home=N` with `steamac.slot=stop`, runs e2fsck + resize2fs from the rootfs), then
/// this type rewrites the partition table and truncates the image. Truncating before the
/// filesystem fits destroys `/home`.
///
/// The operation survives the launcher going away at any point. Its state lives on the disk
/// image itself, in the unused sectors between the primary GPT and the first partition
/// (LBA 40-108): a journal with the target, the phase and the *finished* partition tables
/// (primary and backup), so that every launcher start can continue it without recomputing
/// anything from a half-written image.
///
/// ```
/// begin      blobs (new GPT) -> journal slot, phase = filesystem (or partition table when the
///            ext4 already fits)
/// filesystem guest pass; once ext4 is clean and fits: phase = partition table
/// partition  backup GPT at the new end -> ftruncate -> primary GPT -> journal cleared
/// table
/// ```
///
/// Each step of the last phase can be repeated. Between the truncation and the primary GPT the
/// headers and the file size disagree for a moment, which `GPT.readStrict` rejects; `GPT.read`
/// then returns the table from the journal (`interruptedTable`). The journal header exists
/// twice (alternating slots, sequence number, CRC), so a torn write cannot lose it.
enum DiskShrinker {
    /// Slack kept above used bytes so journal/metadata still fit after resize2fs.
    static let slackBytes: UInt64 = 1 << 30  // 1 GiB

    /// What the user asked for (kept in the run directory only until the VM has stopped and the
    /// journal is on the disk).
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
        let fd = open(path, O_RDONLY)
        guard fd >= 0 else { throw OptionError("\(path): \(String(cString: strerror(errno)))") }
        defer { close(fd) }
        return try request(fd: fd, table: GPT.readStrict(fd: fd, path: path), path: path, homeGiB: homeGiB)
    }

    private static func request(fd: Int32, table: GPT, path: String, homeGiB: Int) throws -> Request {
        guard (8...4096).contains(homeGiB) else {
            throw OptionError("home size must be 8..4096 GiB", localized: String(localized: "home size must be 8..4096 GiB"))
        }
        guard let home = table.entries.last, home.name == "home", home.type == DiskLayout.typeHome,
              table.entries.dropLast().allSatisfy({ $0.lastLBA < home.firstLBA }) else {
            throw OptionError("\(path): not a SteamOS disk with home as its last partition",
                              localized: String(localized: "\(path): not a SteamOS disk with home as its last partition"))
        }
        try requireJournalSpace(table)
        let target = UInt64(homeGiB) * (1 << 30)
        let current = home.sectors * 512
        guard target < current else {
            let currentGiB = String(format: "%.1f", Double(current) / Double(1 << 30))
            throw OptionError("the new home size must be smaller than its current \(currentGiB) GiB (use Grow Disk to enlarge)",
                              localized: String(localized: "the new home size must be smaller than its current \(currentGiB) GiB (use Grow Disk to enlarge)"))
        }
        let probe = try Ext4Probe.read(fd: fd, path: path, partitionOffset: home.firstLBA * 512)
        guard probe.usedBytes <= target - slackBytes else {
            let usedGiB = String(format: "%.1f", Double(probe.usedBytes) / Double(1 << 30))
            throw OptionError("home uses about \(usedGiB) GiB; free space inside SteamOS or pick a larger size",
                              localized: String(localized: "home uses about \(usedGiB) GiB; free space inside SteamOS or pick a larger size"))
        }
        return Request(path: path, homeGiB: homeGiB, diskGUID: table.diskGUID, filesystemFits: fits(probe, homeGiB: homeGiB))
    }

    /// The filesystem must be clean and at most `homeGiB` before any partition changes.
    static func fits(_ probe: Ext4Probe.Info, homeGiB: Int) -> Bool {
        probe.isClean && probe.totalBytes <= UInt64(homeGiB) << 30
    }

    // MARK: journal

    struct Journal: Equatable {
        enum Phase: UInt32 { case filesystem = 1, partitionTable = 2, repairRequired = 3 }
        var phase: Phase
        var sequence: UInt64
        let homeGiB: Int
        let diskGUID: UUID
        let homeFirstLBA: UInt64
        /// Image size before and after, in sectors: the only two sizes the operation accepts.
        let oldSectors: UInt64
        let newSectors: UInt64
        /// The finished tables: LBA 0-33 and the last 33 sectors of the shrunk image.
        let primary: [UInt8]
        let backup: [UInt8]
    }

    static let slotLBAs: [UInt64] = [40, 41]
    static let primaryLBA: UInt64 = 42
    static let primarySectors: UInt64 = 34
    static let backupLBA: UInt64 = 76
    static let backupSectors: UInt64 = 33

    private static func requireJournalSpace(_ table: GPT) throws {
        let firstAllowed = backupLBA + backupSectors
        guard table.entries.allSatisfy({ $0.firstLBA >= firstAllowed }) else {
            throw OptionError("the disk's first partition overlaps the Shrink Disk journal (LBA 40–108)",
                              localized: String(localized: "The disk's first partition overlaps the sectors Shrink Disk needs for its recovery journal."))
        }
        guard table.entries.allSatisfy({ $0.firstLBA <= $0.lastLBA && $0.lastLBA <= table.lastUsableLBA }) else {
            throw diskChanged
        }
    }
    private static let magic = Array("STEAMACSHRINK\0\0\0".utf8)

    private static func header(_ j: Journal) -> [UInt8] {
        var h = [UInt8](repeating: 0, count: 512)
        h.replaceSubrange(0..<16, with: magic)
        GPT.put32(&h, 16, 1)
        GPT.put32(&h, 20, j.phase.rawValue)
        GPT.put32(&h, 24, UInt32(j.homeGiB))
        GPT.put64(&h, 28, j.sequence)
        GPT.put64(&h, 36, j.oldSectors)
        GPT.put64(&h, 44, j.newSectors)
        GPT.put64(&h, 52, j.homeFirstLBA)
        GPT.putGUID(&h, 60, j.diskGUID)
        GPT.put32(&h, 76, GPT.crc32(j.primary + j.backup))
        GPT.put32(&h, 508, GPT.crc32(h[0..<508]))
        return h
    }

    /// The header fields when `h` is an intact journal header, else nil.
    private static func decode(_ h: [UInt8]) -> (phase: Journal.Phase, sequence: UInt64, homeGiB: Int, old: UInt64, new: UInt64,
                                                  firstLBA: UInt64, guid: UUID, blobCRC: UInt32)? {
        guard h.count == 512, Array(h[0..<16]) == magic, GPT.get32(h, 16) == 1,
              GPT.crc32(h[0..<508]) == GPT.get32(h, 508),
              let phase = Journal.Phase(rawValue: GPT.get32(h, 20)) else { return nil }
        guard (8...4096).contains(GPT.get32(h, 24)) else { return nil }
        return (phase, GPT.get64(h, 28), Int(GPT.get32(h, 24)), GPT.get64(h, 36), GPT.get64(h, 44), GPT.get64(h, 52),
                GPT.getGUID(h, 60), GPT.get32(h, 76))
    }

    /// The newest intact header slot and the blobs it describes; nil when no operation is on the disk.
    static func readJournal(fd: Int32) -> Journal? {
        var best: (phase: Journal.Phase, sequence: UInt64, homeGiB: Int, old: UInt64, new: UInt64,
                   firstLBA: UInt64, guid: UUID, blobCRC: UInt32)?
        for lba in slotLBAs {
            guard let h = try? GPT.preadAll(fd, 512, at: lba * 512), let d = decode(h) else { continue }
            if best == nil || d.sequence > best!.sequence { best = d }
        }
        guard let b = best,
              b.old <= UInt64(Int64.max) / 512, b.new < b.old,
              b.firstLBA >= backupLBA + backupSectors, b.new > b.firstLBA,
              b.new - b.firstLBA == (UInt64(b.homeGiB) << 30) / 512 + DiskLayout.mib / 512,
              let primary = try? GPT.preadAll(fd, Int(primarySectors) * 512, at: primaryLBA * 512),
              let backup = try? GPT.preadAll(fd, Int(backupSectors) * 512, at: backupLBA * 512),
              GPT.crc32(primary + backup) == b.blobCRC else { return nil }
        return Journal(phase: b.phase, sequence: b.sequence, homeGiB: b.homeGiB, diskGUID: b.guid, homeFirstLBA: b.firstLBA,
                       oldSectors: b.old, newSectors: b.new, primary: primary, backup: backup)
    }

    static func readJournal(path: String) -> Journal? {
        let fd = open(path, O_RDONLY)
        guard fd >= 0 else { return nil }
        defer { close(fd) }
        return readJournal(fd: fd)
    }

    private static func syncDisk(_ fd: Int32, _ path: String) throws {
        guard fsync(fd) == 0 else { throw OptionError("sync \(path): \(String(cString: strerror(errno)))") }
    }

    private static func writeSlot(_ j: Journal, fd: Int32, path: String) throws {
        try GPT.pwriteAll(fd, header(j), at: slotLBAs[Int(j.sequence % 2)] * 512)
        try syncDisk(fd, path)
    }

    private static func clearJournal(_ j: Journal, fd: Int32, path: String) throws {
        let zero = [UInt8](repeating: 0, count: 512)
        let latest = Int(j.sequence % 2)
        // Do not expose an older filesystem phase after the image has already been truncated.
        try GPT.pwriteAll(fd, zero, at: slotLBAs[1 - latest] * 512)
        try syncDisk(fd, path)
        try point("clear-half")
        try GPT.pwriteAll(fd, zero, at: slotLBAs[latest] * 512)
        try syncDisk(fd, path)
    }

    /// Self-checks only: fail once at the named step to prove the operation survives it.
    nonisolated(unsafe) static var failAt: String?
    private static func point(_ name: String) throws {
        if failAt == name {
            failAt = nil
            throw OptionError("injected failure at \(name)")
        }
    }

    private static var diskChanged: OptionError {
        OptionError("the selected SteamOS disk has changed; choose its size again",
                    localized: String(localized: "the selected SteamOS disk has changed; choose its size again"))
    }

    // MARK: operation

    /// Write the journal (VM stopped, disk lock taken). Nothing else on the disk changes yet.
    private static func begin(_ r: Request, fd: Int32, allowGuestPass: Bool = true) throws -> Journal {
        guard readJournal(fd: fd) == nil else {
            throw OptionError("an earlier Shrink Disk is unfinished; start SteamOS to finish it first",
                              localized: String(localized: "an earlier Shrink Disk is unfinished; start SteamOS to finish it first"))
        }
        var table = try GPT.readStrict(fd: fd, path: r.path)
        let checked = try request(fd: fd, table: table, path: r.path, homeGiB: r.homeGiB)
        guard checked.diskGUID == r.diskGUID else { throw diskChanged }
        guard allowGuestPass || checked.filesystemFits else {
            throw OptionError("home must be clean and fit within \(r.homeGiB) GiB; use Settings → Advanced → Shrink Disk… for the one-shot shrink boot")
        }
        let homeIdx = table.entries.count - 1
        let home = table.entries[homeIdx]
        let targetSectors = UInt64(r.homeGiB) * (1 << 30) / 512
        // 1 MiB alignment (sgdisk -a 2048).
        let aligned = (targetSectors + 2047) / 2048 * 2048
        let newLast = home.firstLBA + aligned - 1
        guard aligned >= 2048, newLast < home.lastLBA else {
            throw OptionError("\(r.path): cannot align a \(r.homeGiB) GiB home partition")
        }
        let oldSectors = table.sectors
        table.entries[homeIdx].lastLBA = newLast
        table.sectors = ((newLast + 1) * 512 + DiskLayout.mib) / 512
        guard table.sectors < oldSectors else { throw diskChanged }
        let journal = Journal(phase: checked.filesystemFits ? .partitionTable : .filesystem, sequence: 1,
                              homeGiB: r.homeGiB, diskGUID: table.diskGUID, homeFirstLBA: home.firstLBA,
                              oldSectors: oldSectors, newSectors: table.sectors,
                              primary: table.primaryBytes(), backup: table.backupBytes())
        // The blobs first, the header last: without a header they are unreferenced bytes in unused sectors.
        try GPT.pwriteAll(fd, journal.primary, at: primaryLBA * 512)
        try GPT.pwriteAll(fd, journal.backup, at: backupLBA * 512)
        try syncDisk(fd, r.path)
        try point("begin-blobs")
        try writeSlot(journal, fd: fd, path: r.path)
        return journal
    }

    /// Phase partition table: every step can be repeated, in this order. Backup GPT at the new
    /// end (inside the old image, over space the shrunk filesystem no longer uses), truncation,
    /// primary GPT, journal cleared.
    private static func complete(_ j: Journal, fd: Int32, path: String, probe: Ext4Probe.Info) throws {
        // A different launcher may have booted the old GPT and run growfs after the journal
        // advanced to this phase. Check the live superblock before even writing the backup.
        guard fits(probe, homeGiB: j.homeGiB) else {
            throw OptionError("home no longer fits cleanly; refusing to finish the partition table",
                              localized: String(localized: "Home is not clean or no longer fits the shrink target. The partition table and image size were not changed on this attempt."))
        }
        var st = stat()
        guard fstat(fd, &st) == 0 else { throw OptionError("\(path): \(String(cString: strerror(errno)))") }
        let size = UInt64(st.st_size)
        guard size / 512 == j.oldSectors || size / 512 == j.newSectors, size % 512 == 0 else {
            throw diskChanged
        }
        if size / 512 == j.oldSectors {
            _ = try originalHome(j, fd: fd, path: path)
            try GPT.pwriteAll(fd, j.backup, at: (j.newSectors - backupSectors) * 512)
            try syncDisk(fd, path)
            try point("complete-backup")
        } else {
            // The backup was synced before the file was shortened; this is the disk we can redo.
            guard try GPT.preadAll(fd, j.backup.count, at: (j.newSectors - backupSectors) * 512) == j.backup else {
                throw diskChanged
            }
        }
        if size != j.newSectors * 512 {
            guard ftruncate(fd, off_t(j.newSectors * 512)) == 0 else {
                throw OptionError("shrink \(path): \(String(cString: strerror(errno)))")
            }
            try syncDisk(fd, path)
        }
        try point("complete-truncate")
        try GPT.pwriteAll(fd, j.primary, at: 0)
        try syncDisk(fd, path)
        try point("complete-primary")
        let table = try GPT.readStrict(fd: fd, path: path)
        guard table == (try plannedTable(j)) else { throw diskChanged }
        try clearJournal(j, fd: fd, path: path)
        log("shrink-disk: \(path), home \(j.homeGiB) GiB; GPT rewritten and image truncated")
    }

    enum Outcome: Equatable {
        case idle
        /// The filesystem still has to shrink: run the guest pass.
        case guestPass
        case completed
    }

    private static func plannedTable(_ j: Journal) throws -> GPT {
        try GPT.parse(header: Array(j.primary[512..<1024]), array: Array(j.primary[1024...]),
                      myLBA: 1, sectors: j.newSectors)
    }

    private static func originalHome(_ j: Journal, fd: Int32, path: String) throws -> GPT.Entry {
        var table = try GPT.readStrict(fd: fd, path: path)
        try requireJournalSpace(table)
        guard table.diskGUID == j.diskGUID, table.sectors == j.oldSectors,
              let home = table.entries.last, home.name == "home", home.type == DiskLayout.typeHome,
              home.firstLBA == j.homeFirstLBA else { throw diskChanged }
        let newHomeLast = j.newSectors - DiskLayout.mib / 512 - 1
        guard newHomeLast < home.lastLBA else { throw diskChanged }
        table.entries[table.entries.count - 1].lastLBA = newHomeLast
        table.sectors = j.newSectors
        guard table == (try plannedTable(j)) else { throw diskChanged }
        return home
    }

    /// Only a clean filesystem that fits can advance or finish the partition-table phase.
    private static func finish(_ j: Journal, fd: Int32, path: String, checkedByGuest: Bool = false) throws -> Outcome {
        var journal = j
        let probe = try? Ext4Probe.read(fd: fd, path: path, partitionOffset: journal.homeFirstLBA * 512)
        if journal.phase != .partitionTable {
            guard (journal.phase != .repairRequired || checkedByGuest), let probe, fits(probe, homeGiB: journal.homeGiB) else {
                _ = try originalHome(journal, fd: fd, path: path)
                return .guestPass
            }
            journal.phase = .partitionTable
            journal.sequence += 1
            try writeSlot(journal, fd: fd, path: path)
        }
        guard let probe else {
            throw OptionError("unreadable home superblock; refusing to finish the partition table",
                              localized: String(localized: "Home is not clean or no longer fits the shrink target. The partition table and image size were not changed on this attempt."))
        }
        try complete(journal, fd: fd, path: path, probe: probe)
        return .completed
    }

    /// Begin the operation now (VM stopped) and go as far as possible: with the ext4 already
    /// fitting that is all of it, otherwise the guest pass is next.
    static func apply(_ r: Request, allowGuestPass: Bool = true) throws -> Outcome {
        let fd = try DiskLock.lock(r.path, writable: true)
        defer { close(fd) }
        let journal = try begin(r, fd: fd, allowGuestPass: allowGuestPass)
        return try finish(journal, fd: fd, path: r.path)
    }

    // MARK: queue (VM running)

    /// The run directory holds the request only until the VM has stopped: `resume` then puts
    /// the journal on the disk. A launcher that goes away before that has changed nothing.
    static func queue(_ request: Request, runDir: String) throws {
        try JSONEncoder().encode(request).write(to: URL(fileURLWithPath: runDir + "/shrink-disk.json"), options: .atomic)
    }

    static func pending(runDir: String) -> Request? {
        let url = URL(fileURLWithPath: runDir + "/shrink-disk.json")
        guard let data = try? Data(contentsOf: url) else { return nil }
        return try? JSONDecoder().decode(Request.self, from: data)
    }

    static func clearPending(runDir: String) {
        try? FileManager.default.removeItem(atPath: runDir + "/shrink-disk.json")
    }

    // MARK: launcher start

    /// Called with the VM stopped before every boot: adopt a queued request, then continue an
    /// operation found on any writable disk. `.guestPass` means this boot must be the one-shot
    /// shrink boot (`attachPending` adds its flags in the VM process).
    static func resume(runDir: String, disks: [DiskSpec]) throws -> Outcome {
        let writable = disks.filter { !$0.readOnly }
        if let queued = pending(runDir: runDir) {
            clearPending(runDir: runDir)
            guard writable.contains(where: { $0.path == queued.path }) else {
                throw OptionError("the disk selected for shrink is no longer the next boot's writable disk",
                                  localized: String(localized: "the disk selected for shrink is no longer the next boot's writable disk"))
            }
            let fd = try DiskLock.lock(queued.path, writable: true)
            defer { close(fd) }
            _ = try begin(queued, fd: fd)
        }
        var outcome = Outcome.idle
        for disk in writable {
            // Most starts have no operation: look first, lock only a disk that carries a journal.
            guard readJournal(path: disk.path) != nil else { continue }
            let fd = try DiskLock.lock(disk.path, writable: true)
            defer { close(fd) }
            guard let journal = readJournal(fd: fd) else { continue }
            log("shrink-disk: continuing the operation on \(disk.path) (phase \(journal.phase == .filesystem ? "filesystem" : "partition table"), home \(journal.homeGiB) GiB)")
            outcome = try finish(journal, fd: fd, path: disk.path)
            if outcome == .guestPass {
                guard disks.first?.path == disk.path else {
                    throw OptionError("the shrink boot requires the image to be the first disk",
                                      localized: String(localized: "Attach the SteamOS image as the first disk to run the shrink boot."))
                }
                break
            }
        }
        return outcome
    }

    /// A clean, fitting ext4 can be committed after the resize. On failure, only abandon the
    /// journal if the original GPT is intact and home is still safe to boot at its old size.
    static let repairRequiredPrefix = "needs-repair: "

    static func displayFailure(_ reason: String) -> String {
        reason.hasPrefix(repairRequiredPrefix) ? String(reason.dropFirst(repairRequiredPrefix.count)) : reason
    }

    static func finishGuestPass(disks: [DiskSpec], checkedByGuest: Bool, failure: String?) throws -> Outcome {
        guard let disk = disks.first, !disk.readOnly else { throw diskChanged }
        let fd = try DiskLock.lock(disk.path, writable: true)
        defer { close(fd) }
        guard var journal = readJournal(fd: fd), journal.phase != .partitionTable else { throw diskChanged }
        if checkedByGuest, try finish(journal, fd: fd, path: disk.path, checkedByGuest: true) == .completed { return .completed }
        let home = try originalHome(journal, fd: fd, path: disk.path)
        let safe = (try? Ext4Probe.read(fd: fd, path: disk.path, partitionOffset: home.firstLBA * 512))
            .map { $0.isClean && $0.totalBytes <= home.sectors * 512 } ?? false
        let needsRepair = failure?.hasPrefix(repairRequiredPrefix) == true || !safe
            || (journal.phase == .repairRequired && !checkedByGuest)
        if needsRepair {
            if journal.phase != .repairRequired {
                journal.phase = .repairRequired
                journal.sequence += 1
                try writeSlot(journal, fd: fd, path: disk.path)
            }
            throw OptionError("home is not safe to mount after the shrink boot; keeping the recovery journal",
                              localized: String(localized: "SteamOS was not started because home still needs repair. The shrink journal was kept for recovery on the next launch."))
        }
        try clearJournal(journal, fd: fd, path: disk.path)
        log("shrink-disk: operation on \(disk.path) abandoned; its partition table was not changed")
        return .idle
    }

    /// Only the supervisor can authorize a one-shot boot, after checking the journal and GPT.
    static func attachPending(_ o: inout Options) throws {
        guard let disk = o.disks.first, !disk.readOnly,
              let journal = readJournal(path: disk.path), journal.phase != .partitionTable else { throw diskChanged }
        guard let home = try plannedTable(journal).entries.last else { throw diskChanged }
        // initramfs uses the last occurrence before "--"; the journal owns both switches.
        var words = o.cmdline.split(separator: " ")
        let end = words.firstIndex(of: "--") ?? words.endIndex
        words.insert(contentsOf: [Substring(cmdlineFlag(homeGiB: journal.homeGiB)), "steamac.slot=stop",
                                  Substring("steamac.shrink-home-partuuid=\(home.uuid.uuidString.lowercased())")], at: end)
        o.cmdline = words.joined(separator: " ")
        log("shrink-disk: this boot will shrink home to \(journal.homeGiB) GiB then power off")
    }

    /// `GPT.read` of an image caught between the truncation and the primary GPT: the table the
    /// journal is finishing, only while the file has one of the two sizes of the operation.
    static func interruptedTable(path: String) -> GPT? {
        let fd = open(path, O_RDONLY)
        guard fd >= 0 else { return nil }
        defer { close(fd) }
        var st = stat()
        guard fstat(fd, &st) == 0, let j = readJournal(fd: fd), j.phase == .partitionTable,
              UInt64(st.st_size) == j.oldSectors * 512 || UInt64(st.st_size) == j.newSectors * 512 else { return nil }
        return try? plannedTable(j)
    }

    // MARK: self-check

    static func selfCheck() -> [String] {
        var failures: [String] = []
        var checks = 0
        func check(_ ok: Bool, _ name: String) {
            checks += 1
            if !ok { failures.append("disk shrink: \(name)") }
        }
        check(cmdlineFlag(homeGiB: 192) == "steamac.shrink-home=192", "cmdline flag")
        check(slackBytes == 1 << 30, "1 GiB slack")

        let progress = BootProgress(shrinking: true)
        var results: [String] = []
        progress.onShrink = { ok, reason in results.append(ok ? "done" : reason) }
        progress.consoleLine("Booting Linux")
        check(progress.state.stageId == "shrink" && progress.state.indeterminate, "kernel output does not hide the shrink overlay")
        progress.guestLine("shrink failed needs-repair: e2fsck failed (exit 4)")
        progress.consoleLine("[ 1.23] steamac-shrink: failed needs-repair: e2fsck failed (exit 4)")
        check(progress.state.detail == "e2fsck failed (exit 4)" && results.count == 1, "guest reason is displayed once across both channels")
        let success = BootProgress(shrinking: true)
        success.onShrink = progress.onShrink
        success.consoleLine("steamac-shrink: done 8")
        check(results.last == "done" && success.state.stageId == "shrink", "console success is parsed without leaving the protected stage")

        // Sparse SteamOS GPT (16 GiB home) + synthetic ext4 superblock in home.
        let table = DiskLayout.table(homeGiB: 16)
        let home = table.entries.last!
        let homeOff = home.firstLBA * 512
        let tmp = NSTemporaryDirectory() + "steamac-shrink-\(getpid()).img"
        let run = NSTemporaryDirectory() + "steamac-shrink-run-\(getpid())"
        defer { unlink(tmp); try? FileManager.default.removeItem(atPath: run) }
        let disks = [DiskSpec(path: tmp, readOnly: false)]

        /// A fresh 16 GiB-home image whose ext4 has `blocks` 4 KiB blocks, `free` of them free.
        func makeImage(blocks: UInt64 = 1_048_576, free: UInt64 = 524_288, state: UInt16 = 1, is64Bit: Bool = true) throws {
            unlink(tmp)
            let fd = open(tmp, O_RDWR | O_CREAT | O_TRUNC, 0o600)
            guard fd >= 0 else { throw OptionError("open \(tmp)") }
            defer { close(fd) }
            guard ftruncate(fd, off_t(table.sectors * 512)) == 0 else { throw OptionError("ftruncate") }
            try table.write(fd: fd)
            try setSuper(fd, blocks: blocks, free: free, state: state, is64Bit: is64Bit)
        }
        func setSuper(_ fd: Int32, blocks: UInt64, free: UInt64, state: UInt16 = 1,
                      is64Bit: Bool = true, needsRecovery: Bool = false) throws {
            try GPT.pwriteAll(fd, Ext4Probe.superblock(blocks: blocks, free: free, state: state,
                                                     is64Bit: is64Bit, needsRecovery: needsRecovery),
                              at: homeOff + Ext4Probe.superOffset)
            guard fsync(fd) == 0 else { throw OptionError("fsync") }
        }
        func withImage<T>(_ body: (Int32) throws -> T) throws -> T {
            let fd = open(tmp, O_RDWR)
            guard fd >= 0 else { throw OptionError("open \(tmp)") }
            defer { close(fd) }
            return try body(fd)
        }
        func fileSize() -> UInt64 {
            var st = stat()
            return stat(tmp, &st) == 0 ? UInt64(st.st_size) : 0
        }
        func throwsError(_ body: () throws -> Void) -> Bool {
            do { try body() } catch { return true }
            return false
        }

        do {
            try FileManager.default.createDirectory(atPath: run, withIntermediateDirectories: true)
            unlink(tmp)
            let blank = open(tmp, O_RDWR | O_CREAT | O_TRUNC, 0o600)
            guard blank >= 0 else { throw OptionError("open \(tmp)") }
            guard ftruncate(blank, off_t(table.sectors * 512)) == 0 else { throw OptionError("ftruncate") }
            try table.write(fd: blank)
            close(blank)
            check(throwsError { _ = try request(path: tmp, homeGiB: 8) }, "rejects disk without ext4 home")

            for start in [UInt64(108), 109] {
                try makeImage()
                var layout = table
                layout.entries[0].firstLBA = start
                try withImage { try layout.write(fd: $0) }
                if start == 108 {
                    let sentinel = [UInt8](repeating: 0xa5, count: 512)
                    try withImage { try GPT.pwriteAll($0, sentinel, at: start * 512) }
                    let forged = Request(path: tmp, homeGiB: 8, diskGUID: layout.diskGUID, filesystemFits: true)
                    check(throwsError { _ = try apply(forged) }, "journal does not write over a partition at LBA 108")
                    check(try withImage { try GPT.preadAll($0, 512, at: start * 512) } == sentinel, "overlapping partition is untouched")
                } else {
                    check(try apply(try request(path: tmp, homeGiB: 8)) == .completed, "LBA 109 leaves exactly enough room for the journal")
                }
            }

            // A clean UI/CLI probe is only advisory: use the latest state under the writing lock.
            try makeImage()
            let assessed = try request(path: tmp, homeGiB: 8)
            try withImage { try setSuper($0, blocks: 1_048_576, free: 524_288, needsRecovery: true) }
            let dirty = try request(path: tmp, homeGiB: 8)
            check(assessed.filesystemFits && !dirty.filesystemFits, "journal replay prevents the fast path")
            check(throwsError { _ = try apply(assessed, allowGuestPass: false) } && readJournal(path: tmp) == nil,
                  "CLI rechecks clean state before writing anything")
            check(try apply(assessed) == .guestPass, "Settings starts a guest pass for dirty ext4, even if it fits")
            check(try GPT.readStrict(path: tmp) == table, "dirty ext4 leaves the original GPT")

            // 4 GiB of the 16 GiB filesystem used (512k blocks used of 1M), slack 1 GiB: the range is fine.
            try makeImage()
            check(throwsError { _ = try request(path: tmp, homeGiB: 8) } == false, "8 GiB holds 4 GiB used plus slack")
            // Used ≈ 12.2 GiB (4194304 blocks, 1000000 free): 8 GiB is a valid size, but too small.
            try makeImage(blocks: 4_194_304, free: 1_000_000)
            var message = ""
            do { _ = try request(path: tmp, homeGiB: 8) } catch { message = "\(error)" }
            check(message.contains("home uses about"), "rejects a target below used + slack (free-space check, not the range check)")
            try makeImage()
            check(throwsError { _ = try request(path: tmp, homeGiB: 16) }, "rejects same size / grow via shrink")
            check(throwsError { _ = try request(path: tmp, homeGiB: 2) }, "rejects sizes below 8 GiB")

            // ext4 already 4 GiB: the partition table is all that remains.
            try makeImage(blocks: 1_048_576, free: 524_288)
            let ready = try request(path: tmp, homeGiB: 8)
            check(ready.filesystemFits && ready.homeGiB == 8, "filesystemFits when ext4 ≤ target")
            check(try apply(ready) == .completed, "a fitting filesystem finishes in one step")
            let after = try GPT.readStrict(path: tmp)
            let newHome = after.entries.last!
            check(after.diskGUID == table.diskGUID, "shrink keeps disk GUID")
            check(newHome.name == "home" && newHome.firstLBA == home.firstLBA, "home start retained")
            check(newHome.sectors * 512 == 8 * (1 << 30), "home is 8 GiB after shrink")
            check(after.sectors == (newHome.lastLBA + 1) + DiskLayout.mib / 512, "backup GPT behind home")
            check(AppBundle.isDiskImage(tmp), "shrunk GPT still selectable")
            check(readJournal(path: tmp) == nil, "journal cleared when the operation is done")
            check(try resume(runDir: run, disks: disks) == .idle, "nothing to resume afterwards")

            // 64bit ext4 as SteamOS creates it, still 16 GiB: the guest pass is needed first.
            try makeImage(blocks: 4_194_304, free: 4_000_000)
            let large = try request(path: tmp, homeGiB: 8)
            check(!large.filesystemFits, "a 16 GiB filesystem needs the guest pass before the partition table changes")
            check(try apply(large) == .guestPass, "begin leaves the table alone and asks for the guest pass")
            let untouched = try GPT.readStrict(path: tmp)
            check(fileSize() == table.sectors * 512 && untouched == table, "image untouched before the guest pass")
            check(readJournal(path: tmp)?.phase == .filesystem, "journal records phase filesystem")
            var options = Options()
            options.disks = disks
            options.cmdline = "steamac.slot=A steamac.shrink-home=12 -- init-arg"
            try attachPending(&options)
            check(options.cmdline.hasSuffix("steamac.shrink-home=8 steamac.slot=stop steamac.shrink-home-partuuid=\(home.uuid.uuidString.lowercased()) -- init-arg"),
                  "the journal target, slot and partition UUID take precedence before the kernel argument separator")
            check(try resume(runDir: run, disks: disks) == .guestPass, "resume asks for the guest pass again after a restart")
            let lockFD = try DiskLock.lock(tmp, writable: true)
            check(throwsError { _ = try begin(large, fd: lockFD) }, "a second operation is refused while one is on the disk")
            close(lockFD)
            // The guest pass starts: resize2fs flags the filesystem with errors until it is done.
            try withImage { try setSuper($0, blocks: 4_194_304, free: 4_000_000, state: 3) }
            check(try resume(runDir: run, disks: disks) == .guestPass, "an interrupted resize2fs is not a fitting filesystem")
            // Smaller block count but the error flag still set: interrupted, not done.
            try withImage { try setSuper($0, blocks: 2_097_152, free: 2_000_000, state: 3) }
            check(try resume(runDir: run, disks: disks) == .guestPass, "error flag outweighs a small block count")
            // The pass finishes.
            try withImage { try setSuper($0, blocks: 2_097_152, free: 2_000_000, state: 1) }
            check(try resume(runDir: run, disks: disks) == .completed, "finished guest pass completes the operation")
            check((try GPT.readStrict(path: tmp)).entries.last!.sectors * 512 == 8 * (1 << 30), "home is 8 GiB after the resumed shrink")

            // Crash at every step of the partition-table phase: the image stays readable and resume finishes.
            for step in ["complete-backup", "complete-truncate", "complete-primary", "clear-half"] {
                try makeImage(blocks: 1_048_576, free: 524_288)
                failAt = step
                check(throwsError { _ = try apply(try request(path: tmp, homeGiB: 8)) }, "injected failure at \(step) surfaces")
                let readable = try? GPT.read(path: tmp)
                check(readable != nil && [home.sectors, 8 * (1 << 30) / 512].contains(readable!.entries.last!.sectors),
                      "GPT.read accepts the image after a crash at \(step)")
                check(AppBundle.isDiskImage(tmp), "the image stays selectable after a crash at \(step)")
                check(try resume(runDir: run, disks: disks) == .completed, "resume finishes after a crash at \(step)")
                let done = try GPT.readStrict(path: tmp)
                check(done.entries.last!.sectors * 512 == 8 * (1 << 30) && done.sectors == (done.entries.last!.lastLBA + 1) + DiskLayout.mib / 512,
                      "strict GPT after resuming from \(step)")
                check(readJournal(path: tmp) == nil, "journal cleared after resuming from \(step)")
            }
            // Between truncation and primary GPT, strict reading fails and the journal answers.
            try makeImage(blocks: 1_048_576, free: 524_288)
            failAt = "complete-truncate"
            _ = try? apply(try request(path: tmp, homeGiB: 8))
            check(throwsError { _ = try GPT.readStrict(path: tmp) }, "headers and file size disagree between truncation and primary GPT")
            let finishing = try GPT.read(path: tmp)
            check(finishing.sectors == readJournal(path: tmp)?.newSectors, "GPT.read returns the journal's table then")
            _ = try resume(runDir: run, disks: disks)

            // Crash while beginning: before the header exists nothing is on the disk.
            try makeImage(blocks: 4_194_304, free: 4_000_000)
            failAt = "begin-blobs"
            check(throwsError { _ = try apply(try request(path: tmp, homeGiB: 8)) }, "injected failure at begin-blobs surfaces")
            let beginCrash = try GPT.readStrict(path: tmp)
            check(readJournal(path: tmp) == nil && beginCrash == table, "no journal and an untouched image after a crash in begin")
            check(try resume(runDir: run, disks: disks) == .idle, "nothing to resume after a crash in begin")

            // A torn newest header slot: the older slot (phase filesystem) takes over.
            try makeImage(blocks: 1_048_576, free: 524_288)
            failAt = "complete-backup"
            _ = try? apply(try request(path: tmp, homeGiB: 8))
            try withImage { fd in
                let slot = slotLBAs[Int(readJournal(fd: fd)!.sequence % 2)]
                try GPT.pwriteAll(fd, [UInt8](repeating: 0xA5, count: 512), at: slot * 512)
            }
            check(readJournal(path: tmp) == nil, "a lone torn slot of a one-slot journal leaves no journal")
            try makeImage(blocks: 4_194_304, free: 4_000_000)
            _ = try apply(try request(path: tmp, homeGiB: 8))
            try withImage { try setSuper($0, blocks: 2_097_152, free: 2_000_000, state: 1) }
            try withImage { fd in
                var j = readJournal(fd: fd)!
                j.phase = .partitionTable
                j.sequence += 1
                try writeSlot(j, fd: fd, path: tmp)
                try GPT.pwriteAll(fd, [UInt8](repeating: 0xA5, count: 512), at: slotLBAs[Int(j.sequence % 2)] * 512)
            }
            check(readJournal(path: tmp)?.phase == .filesystem, "a torn slot falls back to the previous header")
            check(try resume(runDir: run, disks: disks) == .completed, "the previous header is enough to finish")

            // An external change to the image refuses recovery without touching the journal.
            try makeImage(blocks: 1_048_576, free: 524_288)
            failAt = "complete-backup"
            _ = try? apply(try request(path: tmp, homeGiB: 8))
            try withImage { check(ftruncate($0, off_t(table.sectors * 512 + 4096)) == 0, "grow the fixture image") }
            check(throwsError { _ = try resume(runDir: run, disks: disks) }, "an image of another size is refused")
            check(readJournal(path: tmp) != nil, "an image that changed is not written during recovery")

            // Older launcher ran growfs after we reached the partition-table phase. The bytes
            // at the proposed backup GPT may again belong to the filesystem: do not touch them.
            try makeImage()
            failAt = "complete-backup"
            _ = try? apply(try request(path: tmp, homeGiB: 8))
            let grown = readJournal(path: tmp)!
            let backupOffset = (grown.newSectors - backupSectors) * 512
            let fileData = [UInt8](repeating: 0x5a, count: 512)
            try withImage { fd in
                try setSuper(fd, blocks: 4_194_304, free: 4_000_000)
                try GPT.pwriteAll(fd, fileData, at: backupOffset)
            }
            check(throwsError { _ = try resume(runDir: run, disks: disks) }, "partition-table resume rejects a regrown filesystem")
            check(try withImage { try GPT.preadAll($0, 512, at: backupOffset) } == fileData, "does not write the backup GPT over regrown home")
            check(fileSize() == table.sectors * 512 && readJournal(path: tmp) == grown, "regrown disk and journal remain unchanged")

            // Failed guest pass, clean original home: boot as usual, without changing GPT.
            try makeImage(blocks: 4_194_304, free: 4_000_000)
            _ = try apply(try request(path: tmp, homeGiB: 8))
            check(try finishGuestPass(disks: disks, checkedByGuest: false, failure: "target too small") == .idle,
                  "safe guest failure allows normal boot")
            let abandoned = try GPT.readStrict(path: tmp)
            check(readJournal(path: tmp) == nil && abandoned == table, "abandon clears the journal, the table is unchanged")
            try makeImage(blocks: 4_194_304, free: 4_000_000)
            _ = try apply(try request(path: tmp, homeGiB: 8))
            try withImage { try setSuper($0, blocks: 1_048_576, free: 524_288) }
            check(throwsError { _ = try finishGuestPass(disks: disks, checkedByGuest: false, failure: "needs-repair: e2fsck failed") },
                  "failed fsck is not safe to boot even if superblock appears clean")
            check(try readJournal(path: tmp)?.phase == .repairRequired && GPT.readStrict(path: tmp) == table,
                  "retain journal requiring a new offline check")
            check(try resume(runDir: run, disks: disks) == .guestPass, "filesystem size alone cannot advance a failed fsck")
            check(try finishGuestPass(disks: disks, checkedByGuest: true, failure: nil) == .completed,
                  "a verified guest retry can finally complete the shrink")

            // Queue while the VM runs: only the request is stored; resume puts the journal on the disk.
            try makeImage(blocks: 1_048_576, free: 524_288)
            try queue(try request(path: tmp, homeGiB: 8), runDir: run)
            check(readJournal(path: tmp) == nil, "queueing writes nothing to the disk")
            check(try resume(runDir: run, disks: disks) == .completed && pending(runDir: run) == nil, "resume adopts a queued request")
            // A queued request for a disk this boot does not write is refused.
            try makeImage(blocks: 1_048_576, free: 524_288)
            try queue(try request(path: tmp, homeGiB: 8), runDir: run)
            check(throwsError { _ = try resume(runDir: run, disks: [DiskSpec(path: tmp, readOnly: true)]) },
                  "a queued request needs the disk to be writable")
            clearPending(runDir: run)

            if let mke2fs = ProcessInfo.processInfo.environment["STEAMAC_SELFTEST_MKE2FS"] {
                try makeImage()
                let mkfs = Process()
                mkfs.executableURL = URL(fileURLWithPath: mke2fs)
                mkfs.arguments = ["-q", "-F", "-t", "ext4", "-b", "4096", "-O", "64bit,flex_bg,casefold",
                                  "-E", "offset=\(homeOff)", tmp, "16384"] // a real 64 MiB ext4 in the sparse GPT image
                try mkfs.run()
                mkfs.waitUntilExit()
                guard mkfs.terminationStatus == 0 else { throw OptionError("mke2fs failed (\(mkfs.terminationStatus))") }
                let ext4 = try Ext4Probe.read(path: tmp, partitionOffset: homeOff)
                check(ext4.isClean && ext4.blockCount == 16_384 && ext4.blockSize == 4096, "real ext4 superblock at home offset")
                failAt = "complete-truncate"
                check(throwsError { _ = try apply(try request(path: tmp, homeGiB: 8), allowGuestPass: false) }, "inject interruption with real ext4")
                check(try GPT.read(path: tmp).sectors == readJournal(path: tmp)?.newSectors, "journal recovers real ext4's interrupted GPT")
                check(try resume(runDir: run, disks: disks) == .completed, "resume real ext4 image shrink")
                check(try Ext4Probe.read(path: tmp, partitionOffset: homeOff) == ext4, "real filesystem unchanged by GPT/truncate")
                check(try readJournal(path: tmp) == nil && GPT.readStrict(path: tmp).entries.last?.sectors == 8 * (1 << 30) / 512,
                      "real ext4 has strict GPT and no journal after recovery")
                log("selftest-settings: real ext4 shrink fixture exercised")
            }
        } catch {
            failures.append("disk shrink: \(error)")
        }
        failAt = nil
        log("selftest-settings: disk shrink: \(checks) checks, \(failures.isEmpty ? "PASS" : failures.joined(separator: "; "))")
        return failures
    }
}
