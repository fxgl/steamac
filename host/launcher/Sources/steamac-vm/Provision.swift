import Foundation
import Security

/// First boot of a disk made by DiskCreator: while `<disk stem>.provision.img` exists next to the
/// main disk, every boot attaches it read-only after the other disks (vdc in the standard
/// layout) and adds `steamac.provision=1`; the guest initramfs formats and fills the blank
/// partitions from it and reports `provision done` (fx.progress or hvc0), after which the payload
/// is deleted and later boots run without it. The guest checks the payload's GUIDs against vda's
/// GPT and is idempotent, so a boot interrupted before `done` simply provisions again.
enum Provision {
    static let cmdlineFlag = "steamac.provision=1"

    /// `/x/steamos.img` -> `/x/steamos.provision.img`.
    static func payloadPath(forDisk disk: String) -> String {
        ((disk as NSString).deletingPathExtension) + ".provision.img"
    }

    /// Options hook (every boot, VM processes only).
    static func attachPending(_ o: inout Options) {
        guard let main = o.disks.first else { return }
        let payload = payloadPath(forDisk: main.path)
        guard FileManager.default.isReadableFile(atPath: payload) else { return }
        guard !o.disks.contains(where: { $0.path == payload }) else { return }
        o.disks.append(DiskSpec(path: payload, readOnly: true))
        if !o.cmdline.split(separator: " ").contains(Substring(cmdlineFlag)) { o.cmdline += " " + cmdlineFlag }
        o.provisionPayload = payload
    }

    /// The guest reported the end of provisioning (main thread of the VM process).
    static func finished(ok: Bool, reason: String, payload: String?) {
        guard let payload else {
            log("provision: guest reported \(ok ? "done" : "failed \(reason)") but this boot has no payload attached")
            return
        }
        guard ok else {
            log("provision failed: \(reason.isEmpty ? "(no reason given)" : reason); \(payload) is kept for the next boot")
            CrashReporting.provisionFailed(reason: reason)
            return
        }
        guard FileManager.default.fileExists(atPath: payload) else { return }   // second report (port + console)
        do {
            try FileManager.default.removeItem(atPath: payload)
            log("provision done: removed \(payload); later boots run without it")
        } catch {
            log("provision done, but removing \(payload) failed: \(error)")
        }
    }

    // MARK: config payload (SSH password)

    static let configFlag = "steamac.config=1"

    /// The guest password of this disk waits to be applied (GuestPassword, generated when SSH is
    /// enabled): this boot (VM process only; the supervisor has no run dir) attaches
    /// `<run dir>/config.img` (Config payload v1: cpio newc, `config.env` with the disk GUID and the
    /// SHA-512-crypt hash) read-only after the other disks, with `steamac.config=1`. A release
    /// launcher with SSH on and no password for the disk yet generates one first.
    static func attachConfig(_ o: inout Options) {
        guard let dir = Supervisor.runDir, let main = o.disks.first, let gpt = try? GPT.read(path: main.path) else { return }
        let disk = GuestPassword.identity(gpt)
        if o.sshPort != 0 && AppBundle.releaseDefaults && GuestPassword.state(disk: disk) == nil {
            do { try GuestPassword.generate(disk: disk) } catch { log("config: \(error)") }
        }
        guard GuestPassword.state(disk: disk) == .pending, let password = GuestPassword.password(disk: disk) else { return }
        do {
            let env = "CONFIG_VERSION='1'\nDISK_GUID='\(disk)'\nPASSWORD_HASH='\(SHA512Crypt.hash(password))'\n"
            var image = Cpio.archive([("config.env", Array(env.utf8))])
            image += [UInt8](repeating: 0, count: ((1 << 20) - image.count % (1 << 20)) % (1 << 20))
            let path = dir + "/config.img"
            try Data(image).write(to: URL(fileURLWithPath: path))
            o.disks.append(DiskSpec(path: path, readOnly: true))
            o.cmdline += " " + configFlag
            o.configPayload = ConfigPayload(path: path, disk: disk, password: password)
        } catch {
            log("config: cannot prepare the password payload for \(main.path): \(error)")
        }
    }

    struct ConfigPayload {
        let path: String
        let disk: String
        let password: String
    }

    /// `config applied` / `config failed <reason>` from the guest.
    static func configFinished(ok: Bool, reason: String, payload: ConfigPayload?) {
        guard let payload else {
            log("config: guest reported \(ok ? "applied" : "failed \(reason)") but this boot has no config payload")
            return
        }
        guard ok else {
            log("config failed: \(reason.isEmpty ? "(no reason given)" : reason); the password is applied again next start")
            return
        }
        guard FileManager.default.fileExists(atPath: payload.path) else { return }   // second report (port + console)
        try? FileManager.default.removeItem(atPath: payload.path)
        // Regenerated meanwhile (Settings)? Then the newer one stays pending.
        if GuestPassword.password(disk: payload.disk) == payload.password { GuestPassword.markApplied(disk: payload.disk) }
        log("config applied: the SteamOS password shown in Settings > Advanced is active")
    }
}

/// Generated password of the guest user steamos, one per disk (Keychain generic password,
/// service es.fxgam.steamac.guest-password, account = the disk's GPT GUID). The plaintext is
/// kept so Settings can show it; the guest only ever gets its SHA-512-crypt hash. State in the
/// item's generic attribute: "pending" until a boot reports `config applied`, then "applied".
enum GuestPassword {
    enum State: String { case pending, applied }

    private static let service = LauncherSettings.defaultDomain + ".guest-password"
    static let user = "steamos"
    /// No 0/O, 1/l/I: readable when typed from the Settings window.
    private static let alphabet = Array("abcdefghijkmnopqrstuvwxyzABCDEFGHJKLMNPQRSTUVWXYZ23456789")

    static func identity(_ gpt: GPT) -> String { gpt.diskGUID.uuidString.lowercased() }

    /// The disk the next start uses (Settings / default), as a Keychain identity.
    static func identity(ofDisk path: String) -> String? { (try? GPT.read(path: path)).map(identity) }

    private static func query(_ disk: String) -> [String: Any] {
        [kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: service, kSecAttrAccount as String: disk]
    }

    /// Attributes only (no Keychain access prompt for a rebuilt, re-signed launcher).
    static func state(disk: String) -> State? {
        var q = query(disk)
        q[kSecReturnAttributes as String] = true
        q[kSecMatchLimit as String] = kSecMatchLimitOne
        var out: CFTypeRef?
        guard SecItemCopyMatching(q as CFDictionary, &out) == errSecSuccess, let attrs = out as? [String: Any] else { return nil }
        return (attrs[kSecAttrGeneric as String] as? Data).flatMap { State(rawValue: String(decoding: $0, as: UTF8.self)) } ?? .pending
    }

    static func password(disk: String) -> String? {
        var q = query(disk)
        q[kSecReturnData as String] = true
        q[kSecMatchLimit as String] = kSecMatchLimitOne
        var out: CFTypeRef?
        guard SecItemCopyMatching(q as CFDictionary, &out) == errSecSuccess, let data = out as? Data else { return nil }
        return String(data: data, encoding: .utf8)
    }

    /// 20 characters, ~117 bits (SecRandomCopyBytes, rejection sampling for a uniform pick).
    static func random() throws -> String {
        var out = ""
        let limit = UInt8(256 - 256 % alphabet.count)
        while out.count < 20 {
            var bytes = [UInt8](repeating: 0, count: 32)
            guard SecRandomCopyBytes(kSecRandomDefault, bytes.count, &bytes) == errSecSuccess else {
                throw OptionError("SecRandomCopyBytes failed")
            }
            for b in bytes where b < limit && out.count < 20 { out.append(alphabet[Int(b) % alphabet.count]) }
        }
        return out
    }

    /// New random password for the disk, applied on its next start.
    @discardableResult
    static func generate(disk: String) throws -> String {
        let pw = try random()
        SecItemDelete(query(disk) as CFDictionary)
        var q = query(disk)
        q[kSecValueData as String] = Data(pw.utf8)
        q[kSecAttrGeneric as String] = Data(State.pending.rawValue.utf8)
        q[kSecAttrLabel as String] = String(localized: "FX Steam Launcher: SteamOS user steamos (disk \(disk))")
        let status = SecItemAdd(q as CFDictionary, nil)
        guard status == errSecSuccess else {
            let detail = SecCopyErrorMessageString(status, nil) as String? ?? "error \(status)"
            throw OptionError("Keychain: \(detail)", localized: String(localized: "Keychain: \(detail)"))
        }
        log("config: generated a new SteamOS password for disk \(disk) (Keychain; shown in Settings > Advanced), applied on the next start")
        return pw
    }

    static func markApplied(disk: String) {
        SecItemUpdate(query(disk) as CFDictionary, [kSecAttrGeneric as String: Data(State.applied.rawValue.utf8)] as CFDictionary)
    }
}
