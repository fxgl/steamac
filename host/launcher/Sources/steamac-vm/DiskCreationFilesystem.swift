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

    /// Includes failures after preflight: a drive or cache directory can disappear, fill up,
    /// or change permissions while desync or the disk writer runs. Match errno only at the suffix.
    static func rejection(_ error: Error) -> Rejection? {
        if let rejection = error as? Rejection { return rejection }
        let e = error as NSError
        if e.domain == NSPOSIXErrorDomain { return rejection(errno: Int32(e.code), detail: "\(error)") }
        if let underlying = e.userInfo[NSUnderlyingErrorKey] as? NSError,
           let rejection = rejection(underlying) { return rejection }
        if e.domain == NSCocoaErrorDomain {
            switch e.code {
            case NSFileWriteNoPermissionError, NSFileReadNoPermissionError:
                return rejection(errno: EACCES, detail: "\(error)")
            case NSFileWriteVolumeReadOnlyError:
                return rejection(errno: EROFS, detail: "\(error)")
            case NSFileWriteOutOfSpaceError:
                return rejection(errno: ENOSPC, detail: "\(error)")
            case NSFileNoSuchFileError, NSFileReadNoSuchFileError:
                return rejection(errno: ENOENT, detail: "\(error)")
            default: break
            }
        }
        guard error is OptionError else { return nil }
        let detail = "\(error)"
        for code in [EROFS, EACCES, EPERM, ENOSPC, EDQUOT, EFBIG, ENXIO, ENODEV, EIO, ENOENT] {
            if detail.lowercased().hasSuffix(": " + String(cString: strerror(code)).lowercased()) {
                return rejection(errno: code, detail: detail)
            }
        }
        return nil
    }

    static func rejection(errno code: Int32, detail: String) -> Rejection? {
        let advice: String
        switch code {
        case EROFS:
            advice = String(localized: "The location is read-only. Choose a writable folder, not the mounted FX Steam Launcher installer.")
        case EACCES, EPERM:
            advice = String(localized: "There is no permission to write to the disk or download cache. Choose a writable folder or check Finder → Get Info → Sharing & Permissions.")
        case ENOSPC, EDQUOT:
            advice = String(localized: "The volume ran out of space while creating SteamOS. Free some space or choose another volume, then try again.")
        case EFBIG:
            advice = String(localized: "The filesystem or its driver cannot create a file as large as the SteamOS disk. Choose an APFS, Mac OS Extended, or exFAT volume; APFS is recommended.")
        case ENXIO, ENODEV, EIO:
            advice = String(localized: "The drive disconnected or reported an I/O error. Check its connection and run Disk Utility First Aid, then try again; use another drive if the error continues.")
        case ENOENT:
            advice = String(localized: "A disk-creation file or folder is no longer available. Reconnect the drive and check that the destination and download cache have not been moved or deleted, then try again.")
        default: return nil
        }
        return Rejection("\(advice) (\(detail))", localized: "\(advice)\n\n\(detail)")
    }

    static func diagnostic(directory: String) -> String {
        var fs = statfs()
        guard statfs(directory, &fs) == 0 else { return "statfs \(directory): \(String(cString: strerror(errno)))" }
        let type = withUnsafePointer(to: &fs.f_fstypename) {
            $0.withMemoryRebound(to: CChar.self, capacity: Int(MFSTYPENAMELEN)) { String(cString: $0) }
        }
        return "filesystem=\(type), block=\(fs.f_bsize), flags=0x\(String(fs.f_flags, radix: 16)), free=\(UInt64(fs.f_bavail) * UInt64(fs.f_bsize))"
    }

    /// Identity and allocation, not file contents: distinguish a removed/replaced output from
    /// bad bytes on the same file and a disconnected parent volume.
    static func fileDiagnostic(_ path: String) -> String {
        var st = stat()
        guard lstat(path, &st) == 0 else { return "\(path): lstat: \(String(cString: strerror(errno)))" }
        let identity = "\(path): dev=\(st.st_dev), inode=\(st.st_ino), mode=\(String(st.st_mode, radix: 8)), size=\(st.st_size), allocated=\(st.st_blocks * 512), links=\(st.st_nlink)"
        guard st.st_mode & S_IFMT == S_IFDIR else { return identity }
        return identity + ", name-max=\(pathconf(path, _PC_NAME_MAX)), " + directoryDiagnostic(path)
    }

    /// Bounded metadata only: a broken cache shard can fail while its parent volume is writable.
    /// Do not read chunks, enumerate the whole cache, or include unrelated filenames.
    private static func directoryDiagnostic(_ path: String) -> String {
        guard let dir = opendir(path) else { return "opendir errno=\(errno)" }
        defer { closedir(dir) }
        var entries = 0, temporary = 0, chunks = 0
        while true {
            errno = 0
            guard let entry = readdir(dir) else {
                return "entries=\(entries), temporary=\(temporary), chunks=\(chunks), readdir errno=\(errno), truncated=false"
            }
            let name = withUnsafePointer(to: &entry.pointee.d_name) {
                $0.withMemoryRebound(to: CChar.self, capacity: Int(MAXNAMLEN) + 1) { String(cString: $0) }
            }
            if name == "." || name == ".." { continue }
            if entries == 64 {
                return "entries=\(entries), temporary=\(temporary), chunks=\(chunks), truncated=true"
            }
            entries += 1
            if name.hasPrefix(".tmp-cacnk.") { temporary += 1 }
            if name.hasSuffix(".cacnk") { chunks += 1 }
        }
    }

    /// Before downloading: reject volumes that cannot hold the disk. Returns whether files
    /// occupy their full logical size (exFAT does not support sparse files).
    static func preflight(directory: String, diskBytes: UInt64, rootfsBytes: UInt64, existingBytes: UInt64 = 0) throws -> Bool {
        var fs = statfs()
        guard statfs(directory, &fs) == 0 else {
            throw OptionError("\(directory): \(String(cString: strerror(errno)))")
        }
        let type = withUnsafePointer(to: &fs.f_fstypename) {
            $0.withMemoryRebound(to: CChar.self, capacity: Int(MFSTYPENAMELEN)) { String(cString: $0) }
        }
        return try preflight(directory: directory, type: type, flags: fs.f_flags,
                             free: UInt64(fs.f_bavail) * UInt64(fs.f_bsize),
                             diskBytes: diskBytes, rootfsBytes: rootfsBytes, existingBytes: existingBytes)
    }

    /// The statfs snapshot is separate so driver names and capacity limits can be regression-tested
    /// without mounting or allocating a multi-gigabyte disk.
    static func preflight(directory: String, type: String, flags: UInt32, free: UInt64,
                          diskBytes: UInt64, rootfsBytes: UInt64, existingBytes: UInt64 = 0) throws -> Bool {
        guard flags & UInt32(MNT_RDONLY) == 0 else {
            throw Rejection("\(directory) is on a read-only volume: choose a writable location for the SteamOS disk",
                            localized: String(localized: "\(directory) is on a read-only volume: choose a writable location for the SteamOS disk"))
        }
        guard type != "msdos" || max(diskBytes, rootfsBytes) <= UInt64(UInt32.max) else {
            throw Rejection("\(directory) is on a FAT32/MS-DOS volume, which cannot store files of 4 GiB or larger. "
                + "The SteamOS disk and its 10 GiB rootfs exceed this limit: choose an APFS, Mac OS Extended, or exFAT volume",
                localized: String(localized: "\(directory) is on a FAT32/MS-DOS volume, which cannot store files of 4 GiB or larger. The SteamOS disk and its 10 GiB rootfs exceed this limit: choose an APFS, Mac OS Extended, or exFAT volume"))
        }
        // Only these filesystems have supported allocation semantics. In particular, do not
        // assume an unknown driver supports sparse files: ufsd_NTFS accepted the 10 GiB
        // temporary rootfs but rejected a 92.7 GB ftruncate after an hour's download (8S).
        guard ["apfs", "hfs", "exfat", "msdos"].contains(type) else {
            throw Rejection("\(directory) uses the unsupported filesystem \(type). Choose an APFS, Mac OS Extended, or exFAT volume for the SteamOS disk; APFS is recommended.",
                localized: String(localized: "\(directory) uses the unsupported filesystem \(type). Choose an APFS, Mac OS Extended, or exFAT volume for the SteamOS disk; APFS is recommended."))
        }
        let dense = type == "exfat"
        if dense {
            let need = diskBytes - min(existingBytes, diskBytes) + rootfsBytes + (1 << 30)
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

    /// The volume of `directory` cannot hold `needed` more bytes (free space as it is now).
    static func notEnoughSpace(needed: UInt64, directory: String) -> Rejection {
        var fs = statfs()
        let free = statfs(directory, &fs) == 0 ? UInt64(fs.f_bavail) * UInt64(fs.f_bsize) : 0
        let gb = { (n: UInt64) in String(format: "%.1f GB", Double(n) / 1e9) }
        let neededText = String(format: "%.1f", Double(needed) / 1e9)
        let available = String(format: "%.1f", Double(free) / 1e9)
        return Rejection("not enough free space: \(gb(needed)) needed on the volume of \(directory), \(gb(free)) free",
            localized: String(localized: "not enough free space: \(neededText) GB needed on the volume of \(directory), \(available) GB free"))
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
        if error == EEXIST { return }
        let detail = "\(directory): \(String(cString: strerror(error)))"
        if let rejection = rejection(errno: error, detail: detail) { throw rejection }
        throw OptionError(detail)
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
