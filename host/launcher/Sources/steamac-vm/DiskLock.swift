import Darwin
import Foundation

/// Exclusive lock (flock) on the writable disk images of a running VM. libkrun does not lock them,
/// and two VMs writing one image (two launcher copies, e.g. a source build and /Applications)
/// mount the same ext4 file systems twice and corrupt them. The VM process takes the lock before
/// attaching a disk and holds it until it exits, also while the guest shuts down after the
/// supervisor was killed; the supervisor checks before each boot to refuse with an alert.
enum DiskLock {
    struct InUse: LocalizedError, CustomStringConvertible {
        let path: String
        var description: String {
            "the SteamOS disk \(path) is in use by another FX Steam Launcher (or steamac-vm). "
                + "Quit it first: two VMs writing one disk corrupt its file systems."
        }
        var errorDescription: String? {
            String(localized: "the SteamOS disk \(path) is in use by another FX Steam Launcher (or steamac-vm). Quit it first: two VMs writing one disk corrupt its file systems.")
        }
    }

    /// Expected host permission refusal, not a launcher crash (STEAMAC-15).
    struct AccessDenied: LocalizedError, CustomStringConvertible {
        let path: String
        var description: String {
            "Cannot open or lock the SteamOS disk \(path): permission denied. In Finder > Get Info, check that you have Read & Write access to the file and its volume. In System Settings > Privacy & Security, allow FX Steam Launcher access to removable volumes (or Full Disk Access if needed), then try again. You can also move the disk to a writable local folder and select it again in Settings."
        }
        var errorDescription: String? {
            String(localized: "Cannot open or lock the SteamOS disk \(path): permission denied. In Finder > Get Info, check that you have Read & Write access to the file and its volume. In System Settings > Privacy & Security, allow FX Steam Launcher access to removable volumes (or Full Disk Access if needed), then try again. You can also move the disk to a writable local folder and select it again in Settings.")
        }
    }

    static func failure(path: String, code: Int32, locking: Bool) -> Error {
        if code == EACCES || code == EPERM { return AccessDenied(path: path) }
        if locking && code == EWOULDBLOCK { return InUse(path: path) }
        return OptionError("\(locking ? "cannot lock " : "")\(path): \(String(cString: strerror(code)))")
    }

    /// Locks `path` for the rest of this process: the descriptor stays open, exit releases it.
    static func hold(_ path: String) throws {
        _ = try lock(path, writable: true)
    }

    /// Whether another process holds the lock (taken and released at once). Other errors are not
    /// reported here: attaching the disk reports them.
    static func inUse(_ path: String) -> Bool {
        do {
            close(try lock(path))
            return false
        } catch is InUse {
            return true
        } catch {
            return false
        }
    }

    /// A scoped operation (e.g. growth) closes the returned descriptor to release its lock.
    static func lock(_ path: String, writable: Bool = false) throws -> Int32 {
        let fd = open(path, (writable ? O_RDWR : O_RDONLY) | O_CLOEXEC)
        guard fd >= 0 else { throw failure(path: path, code: errno, locking: false) }
        guard flock(fd, LOCK_EX | LOCK_NB) == 0 else {
            let err = errno
            close(fd)
            throw failure(path: path, code: err, locking: true)
        }
        return fd
    }
}
