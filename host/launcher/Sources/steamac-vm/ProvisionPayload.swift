import CryptoKit
import Darwin
import Foundation
import Security

/// The first-boot provisioning payload disk (local://provision-contract.md "Payload v1"): an
/// uncompressed cpio newc archive at byte 0, zero-padded to a 1 MiB multiple, members
/// `provision.env` (first: the guest detects the payload by magic + first name) and
/// `rootfs.caibx`. Attached read-only by the launcher with `steamac.provision=1` until the guest
/// reports `provision done` (see Provision).
enum ProvisionPayload {
    struct Values {
        var buildID: String
        var version: String
        var branch: String
        var rootfsSHA256: String
        var hostname = "steamos"
        var passwordHash: String
        var machineID: String
        var gpt: GPT
    }

    /// provision.env: shell-sourceable KEY='value' lines.
    static func env(_ v: Values) throws -> String {
        func uuid(_ name: String) throws -> String {
            guard let e = v.gpt.entry(name) else { throw OptionError("payload: no partition \(name)") }
            return e.uuid.uuidString.lowercased()
        }
        let pairs: [(String, String)] = [
            ("PROVISION_VERSION", "1"),
            ("STEAMOS_BUILDID", v.buildID),
            ("STEAMOS_VERSION", v.version),
            ("STEAMOS_BRANCH", v.branch),
            ("ROOTFS_SHA256", v.rootfsSHA256),
            ("HOSTNAME", v.hostname),
            ("PASSWORD_HASH", v.passwordHash),
            ("MACHINE_ID", v.machineID),
            ("DISK_GUID", v.gpt.diskGUID.uuidString.lowercased()),
            ("PARTUUID_ESP", try uuid("esp")),
            ("PARTUUID_EFI_A", try uuid("efi-A")),
            ("PARTUUID_EFI_B", try uuid("efi-B")),
            ("PARTUUID_ROOTFS_A", try uuid("rootfs-A")),
            ("PARTUUID_ROOTFS_B", try uuid("rootfs-B")),
            ("PARTUUID_VAR_A", try uuid("var-A")),
            ("PARTUUID_VAR_B", try uuid("var-B")),
            ("PARTUUID_HOME", try uuid("home")),
        ]
        for (k, val) in pairs where val.contains("'") || val.contains("\n") {
            throw OptionError("payload: \(k) contains a quote or newline")
        }
        return pairs.map { "\($0.0)='\($0.1)'\n" }.joined()
    }

    /// The whole payload image.
    static func image(env: String, caibx: [UInt8]) -> [UInt8] {
        var out = Cpio.archive([("provision.env", Array(env.utf8)), ("rootfs.caibx", caibx)])
        let mib = 1 << 20
        out += [UInt8](repeating: 0, count: (mib - out.count % mib) % mib)
        return out
    }

    /// 32 lowercase hex digits (systemd machine-id format).
    static func randomMachineID() -> String {
        UUID().uuidString.replacingOccurrences(of: "-", with: "").lowercased()
    }
}

/// cpio "newc" (SVR4 without CRC) writer: regular files, mode 0644, uid/gid 0, mtime 0.
enum Cpio {
    static func archive(_ files: [(String, [UInt8])]) -> [UInt8] {
        var out: [UInt8] = []
        for (i, f) in files.enumerated() {
            append(&out, name: f.0, mode: 0o100644, ino: UInt32(i + 1), data: f.1)
        }
        append(&out, name: "TRAILER!!!", mode: 0, ino: 0, data: [])
        return out
    }

    static func append(_ out: inout [UInt8], name: String, mode: UInt32, ino: UInt32, data: [UInt8]) {
        let fields: [UInt32] = [ino, mode, 0, 0, mode == 0 ? 0 : 1, 0, UInt32(data.count), 0, 0, 0, 0,
                                UInt32(name.utf8.count + 1), 0]
        out += Array("070701".utf8)
        for f in fields { out += Array(String(format: "%08X", f).utf8) }
        out += Array(name.utf8) + [0]
        pad(&out)
        out += data
        pad(&out)
    }

    private static func pad(_ out: inout [UInt8]) {
        while out.count % 4 != 0 { out.append(0) }
    }

    /// (name, data) of every member before the trailer (tests).
    static func parse(_ a: [UInt8]) throws -> [(String, [UInt8])] {
        var files: [(String, [UInt8])] = []
        var p = 0
        func hex(_ i: Int) throws -> Int {
            guard let v = Int(String(decoding: a[(p + 6 + 8 * i)..<(p + 14 + 8 * i)], as: UTF8.self), radix: 16) else {
                throw OptionError("cpio: bad header field")
            }
            return v
        }
        while true {
            guard p + 110 <= a.count, Array(a[p..<(p + 6)]) == Array("070701".utf8) else { throw OptionError("cpio: bad magic at \(p)") }
            let size = try hex(6), nameSize = try hex(11)
            let name = String(decoding: a[(p + 110)..<(p + 110 + nameSize - 1)], as: UTF8.self)
            var q = (p + 110 + nameSize + 3) & ~3
            if name == "TRAILER!!!" { return files }
            files.append((name, Array(a[q..<(q + size)])))
            q = (q + size + 3) & ~3
            p = q
        }
    }
}

/// SHA-512 crypt (`$6$`, Ulrich Drepper's specification), as `openssl passwd -6` / glibc crypt.
enum SHA512Crypt {
    private static let itoa64 = Array("./0123456789ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz".utf8)

    static func randomSalt() -> String {
        var bytes = [UInt8](repeating: 0, count: 16)
        _ = SecRandomCopyBytes(kSecRandomDefault, bytes.count, &bytes)
        return String(decoding: bytes.map { itoa64[Int($0) & 63] }, as: UTF8.self)
    }

    static func hash(_ password: String, salt saltText: String = randomSalt(), rounds: Int = 5000) -> String {
        let pw = Array(password.utf8)
        let salt = Array(saltText.utf8.prefix(16))
        func sha(_ parts: [UInt8]...) -> [UInt8] {
            var h = SHA512()
            for p in parts { h.update(data: p) }
            return Array(h.finalize())
        }
        let b = sha(pw, salt, pw)
        var a = SHA512()
        a.update(data: pw)
        a.update(data: salt)
        var n = pw.count
        while n > 64 { a.update(data: b); n -= 64 }
        a.update(data: Array(b[0..<n]))
        n = pw.count
        while n > 0 {
            a.update(data: n & 1 != 0 ? b : pw)
            n >>= 1
        }
        var c = Array(a.finalize())
        var dp = SHA512()
        for _ in 0..<pw.count { dp.update(data: pw) }
        let dpd = Array(dp.finalize())
        let p = (0..<pw.count).map { dpd[$0 % 64] }
        var ds = SHA512()
        for _ in 0..<(16 + Int(c[0])) { ds.update(data: salt) }
        let dsd = Array(ds.finalize())
        let s = (0..<salt.count).map { dsd[$0 % 64] }
        for i in 0..<rounds {
            var h = SHA512()
            h.update(data: i & 1 != 0 ? p : c)
            if i % 3 != 0 { h.update(data: s) }
            if i % 7 != 0 { h.update(data: p) }
            h.update(data: i & 1 != 0 ? c : p)
            c = Array(h.finalize())
        }
        let groups: [(Int, Int, Int)] = [
            (0, 21, 42), (22, 43, 1), (44, 2, 23), (3, 24, 45), (25, 46, 4), (47, 5, 26), (6, 27, 48),
            (28, 49, 7), (50, 8, 29), (9, 30, 51), (31, 52, 10), (53, 11, 32), (12, 33, 54), (34, 55, 13),
            (56, 14, 35), (15, 36, 57), (37, 58, 16), (59, 17, 38), (18, 39, 60), (40, 61, 19), (62, 20, 41),
        ]
        var out: [UInt8] = []
        func b64(_ w: UInt32, _ count: Int) {
            var w = w
            for _ in 0..<count { out.append(itoa64[Int(w & 0x3f)]); w >>= 6 }
        }
        for (x, y, z) in groups { b64(UInt32(c[x]) << 16 | UInt32(c[y]) << 8 | UInt32(c[z]), 4) }
        b64(UInt32(c[63]), 2)
        let prefix = rounds == 5000 ? "$6$" : "$6$rounds=\(rounds)$"
        return prefix + String(decoding: salt, as: UTF8.self) + "$" + String(decoding: out, as: UTF8.self)
    }
}
