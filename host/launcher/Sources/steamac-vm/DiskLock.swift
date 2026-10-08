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

    /// Locks `path` for the rest of this process: the descriptor stays open, exit releases it.
    static func hold(_ path: String) throws {
        _ = try lock(path)
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
        guard fd >= 0 else { throw OptionError("\(path): \(String(cString: strerror(errno)))") }
        guard flock(fd, LOCK_EX | LOCK_NB) == 0 else {
            let err = errno
            close(fd)
            if err == EWOULDBLOCK { throw InUse(path: path) }
            throw OptionError("cannot lock \(path): \(String(cString: strerror(err)))")
        }
        return fd
    }
}
