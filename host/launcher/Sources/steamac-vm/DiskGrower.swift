import Darwin
import Foundation

/// Grow an existing image only while its VM is stopped. SteamOS's systemd-repart grows
/// the last (home) partition on the next boot; fstab's x-systemd.growfs grows ext4.
enum DiskGrower {
    struct Request: Codable {
        let path: String
        let homeGiB: Int
        let diskGUID: UUID
    }

    static func request(path: String, homeGiB: Int) throws -> Request {
        guard (8...4096).contains(homeGiB) else { throw OptionError("home size must be 8..4096 GiB", localized: String(localized: "home size must be 8..4096 GiB")) }
        let table = try GPT.read(path: path)
        guard let home = table.entries.last, home.name == "home", home.type == DiskLayout.typeHome,
              table.entries.dropLast().allSatisfy({ $0.lastLBA < home.firstLBA }) else {
            throw OptionError("\(path): not a SteamOS disk with home as its last partition", localized: String(localized: "\(path): not a SteamOS disk with home as its last partition"))
        }
        let target = UInt64(homeGiB) * (1 << 30)
        guard target > home.sectors * 512 else {
            let currentGiB = String(format: "%.1f", Double(home.sectors * 512) / Double(1 << 30))
            throw OptionError("the new home size must be larger than its current \(currentGiB) GiB (disks cannot be shrunk)",
                              localized: String(localized: "the new home size must be larger than its current \(currentGiB) GiB (disks cannot be shrunk)"))
        }
        let bytes = home.firstLBA * 512 + target + DiskLayout.mib
        guard bytes > table.sectors * 512 else { throw OptionError("this image already has room for that home size; start SteamOS to finish growing it", localized: String(localized: "this image already has room for that home size; start SteamOS to finish growing it")) }
        _ = try DiskCreationFilesystem.preflight(directory: URL(fileURLWithPath: path).deletingLastPathComponent().path,
                                                diskBytes: bytes, rootfsBytes: 0, existingBytes: table.sectors * 512)
        return Request(path: path, homeGiB: homeGiB, diskGUID: table.diskGUID)
    }

    static func grow(_ r: Request) throws {
        let fd = try DiskLock.lock(r.path, writable: true)
        defer { close(fd) }
        let checked = try request(path: r.path, homeGiB: r.homeGiB)
        guard checked.diskGUID == r.diskGUID else { throw OptionError("the selected SteamOS disk has changed; choose its size again", localized: String(localized: "the selected SteamOS disk has changed; choose its size again")) }
        var table = try GPT.read(path: r.path)
        let bytes = table.entries.last!.firstLBA * 512 + UInt64(r.homeGiB) * (1 << 30) + DiskLayout.mib
        guard ftruncate(fd, off_t(bytes)) == 0 else { throw OptionError("grow \(r.path): \(String(cString: strerror(errno)))") }
        table.sectors = bytes / 512
        // Retain all partition extents and GUIDs. Relocate the backup first, then publish
        // the primary header. The guest, not the host, owns partition/filesystem growth.
        try GPT.pwriteAll(fd, table.backupBytes(), at: (table.sectors - 1 - GPT.entryArraySectors) * 512)
        guard fsync(fd) == 0 else { throw OptionError("sync \(r.path): \(String(cString: strerror(errno)))") }
        try GPT.pwriteAll(fd, table.primaryBytes(), at: 0)
        guard fsync(fd) == 0 else { throw OptionError("sync \(r.path): \(String(cString: strerror(errno)))") }
        log("grow-disk: \(r.path), home target \(r.homeGiB) GiB; partition and filesystem grow on next boot")
    }

    /// A live VM queues this in its supervisor's private run directory, then shuts down
    /// normally. Never resize the image from the VM process, which already holds its lock.
    static func queue(_ request: Request, runDir: String) throws {
        try JSONEncoder().encode(request).write(to: URL(fileURLWithPath: runDir + "/grow-disk.json"), options: .atomic)
    }

    static func applyPending(runDir: String, disks: [DiskSpec]) throws {
        let url = URL(fileURLWithPath: runDir + "/grow-disk.json")
        guard FileManager.default.fileExists(atPath: url.path) else { return }
        let request = try JSONDecoder().decode(Request.self, from: Data(contentsOf: url))
        guard disks.contains(where: { !$0.readOnly && $0.path == request.path }) else {
            throw OptionError("the disk selected for growth is no longer the next boot's writable disk", localized: String(localized: "the disk selected for growth is no longer the next boot's writable disk"))
        }
        try grow(request)
        try FileManager.default.removeItem(at: url)
    }
}
