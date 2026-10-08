import Darwin
import Foundation

/// Filesystem-specific checks and publication for the SteamOS disk creator.
enum DiskCreationFilesystem {
    /// An expected rejection of the chosen location/capacity or busy cache, not a launcher defect.
    struct Rejection: LocalizedError, CustomStringConvertible {
        let description: String
        let localized: String?
        init(_ description: String, localized: String? = nil) {
            self.description = description
            self.localized = localized
        }
        var errorDescription: String? { localized ?? description }
    }

    /// Before downloading: reject volumes that cannot hold the disk. Returns whether files
    /// occupy their full logical size (exFAT does not support sparse files).
    static func preflight(directory: String, diskBytes: UInt64, rootfsBytes: UInt64, existingBytes: UInt64 = 0) throws -> Bool {
        var fs = statfs()
        guard statfs(directory, &fs) == 0 else {
            throw OptionError("\(directory): \(String(cString: strerror(errno)))")
        }
        guard fs.f_flags & UInt32(MNT_RDONLY) == 0 else {
            throw Rejection("\(directory) is on a read-only volume: choose a writable location for the SteamOS disk",
                            localized: String(localized: "\(directory) is on a read-only volume: choose a writable location for the SteamOS disk"))
        }
        let type = withUnsafePointer(to: &fs.f_fstypename) {
            $0.withMemoryRebound(to: CChar.self, capacity: Int(MFSTYPENAMELEN)) { String(cString: $0) }
        }
        guard type != "msdos" || max(diskBytes, rootfsBytes) <= UInt64(UInt32.max) else {
            throw Rejection("\(directory) is on a FAT32/MS-DOS volume, which cannot store files of 4 GiB or larger. "
                + "The SteamOS disk and its 10 GiB rootfs exceed this limit: choose an APFS, Mac OS Extended, or exFAT volume",
                localized: String(localized: "\(directory) is on a FAT32/MS-DOS volume, which cannot store files of 4 GiB or larger. The SteamOS disk and its 10 GiB rootfs exceed this limit: choose an APFS, Mac OS Extended, or exFAT volume"))
        }
        let dense = type == "exfat"
        if dense {
            let need = diskBytes - min(existingBytes, diskBytes) + rootfsBytes + (1 << 30)
            let free = UInt64(fs.f_bavail) * UInt64(fs.f_bsize)
            guard free >= need else {
                let needed = String(format: "%.1f", Double(need) / 1e9)
                let available = String(format: "%.1f", Double(free) / 1e9)
                throw Rejection(String(format: "not enough free space on exFAT: %.1f GB needed on %@, %.1f GB free. "
                    + "exFAT stores the full disk size (no sparse files); choose a smaller home size or an APFS volume",
                    Double(need) / 1e9, directory, Double(free) / 1e9),
                    localized: String(localized: "not enough free space on exFAT: \(needed) GB needed on \(directory), \(available) GB free. exFAT stores the full disk size (no sparse files); choose a smaller home size or an APFS volume"))
            }
        }
        return dense
    }

    /// Before downloading: the folder must accept new files (the cache folder, the partial disk).
    /// Volumes that honour ownership can hold folders the user may not write to (STEAMAC-2H).
    static func requireWritable(directory: String) throws {
        let probe = directory + "/.steamac-write-probe-\(getpid())"
        let fd = open(probe, O_WRONLY | O_CREAT | O_EXCL | O_CLOEXEC, 0o600)
        guard fd < 0 else {
            close(fd)
            unlink(probe)
            return
        }
        let error = errno
        switch error {
        case EACCES, EPERM:
            throw Rejection("no permission to write in \(directory): choose a folder you can write to, "
                + "or allow writing in Finder → Get Info → Sharing & Permissions",
                localized: String(localized: "no permission to write in \(directory): choose a folder you can write to, or allow writing in Finder → Get Info → Sharing & Permissions"))
        case EEXIST:
            return
        default:
            throw OptionError("\(directory): \(String(cString: strerror(error)))")
        }
    }

    /// The caller must hold creation.lock until publication is complete.
    static func publish(partial: String, destination: String) throws {
        if renamex_np(partial, destination, UInt32(RENAME_EXCL)) == 0 { return }
        let error = errno
        if error == EEXIST {
            throw Rejection("\(destination) already exists (never overwritten; delete it or choose another path)",
                            localized: String(localized: "\(destination) already exists (never overwritten; delete it or choose another path)"))
        }
        guard error == ENOTSUP || error == EINVAL else {
            throw OptionError("rename \(partial) -> \(destination): \(String(cString: strerror(error)))")
        }
        // exFAT does not implement RENAME_EXCL. All launcher creators serialize on
        // creation.lock; lstat also rejects dangling symlinks. The check + ordinary rename
        // is not atomic against non-launcher programs creating the destination concurrently.
        var existing = stat()
        if lstat(destination, &existing) == 0 {
            throw Rejection("\(destination) already exists (never overwritten; delete it or choose another path)",
                            localized: String(localized: "\(destination) already exists (never overwritten; delete it or choose another path)"))
        }
        let statError = errno
        guard statError == ENOENT else {
            throw OptionError("\(destination): \(String(cString: strerror(statError)))")
        }
        guard rename(partial, destination) == 0 else {
            throw OptionError("rename \(partial) -> \(destination): \(String(cString: strerror(errno)))")
        }
    }
}
