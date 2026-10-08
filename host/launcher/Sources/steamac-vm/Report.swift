import AppKit
import CryptoKit
import Darwin
import Foundation
import Metal
import Sentry

/// "Report a Problem" (Help menu, Settings > General, the stall card, the offer after an unexpected
/// VM exit): the user's email and description plus a bundle of logs go to the developers' Sentry
/// as User Feedback (ReportWindow.swift has the dialog). This file: the per-session logs the
/// bundle draws on, the guest log request, collection into a report folder
/// (~/Library/Logs/es.fxgam.steamac/reports/<date>-<id>/, which is exactly what is sent and stays
/// there when sending fails) and the upload.

// MARK: - session logs

/// Per-session logs in the supervisor's run dir (/tmp/steamac-<pid>, removed when the launcher
/// exits): `launcher.log` = every stderr line of both processes (the supervisor's stderr tap:
/// launcher, libkrun, virglrenderer, MoltenVK), `console.log` = the hvc0 console (VM process).
/// Lines get the local time in front; a file over `limit` becomes `<name>.1`.
final class RollingLog: @unchecked Sendable {
    static let launcher = RollingLog(name: "launcher.log")
    static let console = RollingLog(name: "console.log")
    static let limit = 4 << 20

    let name: String
    private let lock = NSLock()
    private var path: String?
    private var fd: Int32 = -1
    private var size = 0
    /// Lines appended before `open` (supervisor start-up), written once it is.
    private var early = Data()

    private init(name: String) { self.name = name }

    func open(dir: String) {
        lock.lock()
        defer { lock.unlock() }
        guard fd < 0 else { return }
        let p = dir + "/" + name
        fd = Darwin.open(p, O_WRONLY | O_CREAT | O_APPEND | O_CLOEXEC, 0o600)
        guard fd >= 0 else { return }
        path = p
        var st = stat()
        size = fstat(fd, &st) == 0 ? Int(st.st_size) : 0
        let stamp = ISO8601DateFormatter.string(from: Date(), timeZone: .current, formatOptions: [.withInternetDateTime])
        write(Data("---- \(stamp) pid \(getpid())\n".utf8) + early)
        early = Data()
    }

    func append(_ line: String) {
        var tv = timeval()
        gettimeofday(&tv, nil)
        var t = tv.tv_sec
        var parts = tm()
        localtime_r(&t, &parts)
        let stamped = String(format: "%02d:%02d:%02d.%03d ", parts.tm_hour, parts.tm_min, parts.tm_sec, Int(tv.tv_usec) / 1000)
            + line + "\n"
        lock.lock()
        defer { lock.unlock() }
        if fd < 0 {
            if early.count < 512 << 10 { early.append(Data(stamped.utf8)) }
            return
        }
        write(Data(stamped.utf8))
    }

    /// Locked.
    private func write(_ data: Data) {
        data.withUnsafeBytes { p in
            var off = 0
            while off < p.count {
                let n = Darwin.write(fd, p.baseAddress! + off, p.count - off)
                if n < 0 && errno == EINTR { continue }
                if n <= 0 { return }
                off += n
            }
        }
        size += data.count
        guard size > RollingLog.limit, let path else { return }
        close(fd)
        rename(path, path + ".1")
        fd = Darwin.open(path, O_WRONLY | O_CREAT | O_APPEND | O_CLOEXEC, 0o600)
        size = 0
    }

    /// The newest `maxBytes` of `<dir>/<name>` (with `.1` before it), starting at a line.
    static func tail(dir: String, name: String, maxBytes: Int) -> Data? {
        let path = dir + "/" + name
        let current = FileManager.default.contents(atPath: path)
        guard current != nil || FileManager.default.fileExists(atPath: path + ".1") else { return nil }
        var data = current ?? Data()
        if data.count < maxBytes, let older = FileManager.default.contents(atPath: path + ".1") {
            data = older.suffix(maxBytes - data.count) + data
        }
        return ReportBundle.lineTail(data, maxBytes: maxBytes)
    }
}

// MARK: - guest logs

/// VM process: asks the guest agent for its log bundle over fx.progress (host writes
/// `collect-logs <id>`, the agent answers `logs-begin <id> <size>`, base64 `logs <id> <chunk>`
/// lines and `logs-end <id> <sha256>`, or `logs-failed <id> <reason>`; see
/// guest/progress-agent/src/collect.rs). Main thread only.
final class GuestLogs {
    private let port: ProgressPort
    private var lastAlive: CFTimeInterval = 0
    private var pending: (id: String, size: Int?, data: Data, done: (Result<Data, OptionError>) -> Void)?

    init(port: ProgressPort) { self.port = port }

    /// The agent's heartbeat arrived recently (it can answer a request).
    var agentRunning: Bool { lastAlive > 0 && CACurrentMediaTime() - lastAlive < 10 }

    /// One fx.progress line; true if it belonged to a log transfer (not for BootProgress).
    func handle(_ line: String) -> Bool {
        if line.hasPrefix("alive ") {
            lastAlive = CACurrentMediaTime()
            return false
        }
        guard line.hasPrefix("logs") else { return false }
        let parts = line.split(separator: " ", maxSplits: 2, omittingEmptySubsequences: true).map(String.init)
        guard ["logs-begin", "logs", "logs-end", "logs-failed"].contains(parts[0]) else { return false }
        guard parts.count >= 2, var p = pending, p.id == parts[1] else { return true }   // stale or foreign transfer
        let rest = parts.count > 2 ? parts[2] : ""
        switch parts[0] {
        case "logs-begin":
            p.size = Int(rest)
            p.data.reserveCapacity(p.size ?? 0)
            pending = p
        case "logs":
            guard let chunk = Data(base64Encoded: rest) else { finish(.failure(OptionError("corrupt chunk"))); return true }
            pending?.data.append(chunk)
        case "logs-end":
            let digest = SHA256.hash(data: p.data).map { String(format: "%02x", $0) }.joined()
            if p.size != p.data.count {
                finish(.failure(OptionError("incomplete bundle (\(p.data.count) of \(p.size.map(String.init) ?? "?") bytes)")))
            } else if digest != rest.trimmingCharacters(in: .whitespaces) {
                finish(.failure(OptionError("checksum mismatch")))
            } else {
                finish(.success(p.data))
            }
        default:
            finish(.failure(OptionError("SteamOS agent: \(rest.isEmpty ? "failed" : rest)")))
        }
        return true
    }

    func request(timeout: TimeInterval, done: @escaping (Result<Data, OptionError>) -> Void) {
        if pending != nil { finish(.failure(OptionError("superseded"))) }
        let id = String(format: "%08x", arc4random())
        guard port.send("collect-logs \(id)") else {
            done(.failure(OptionError("cannot write to the fx.progress port")))
            return
        }
        log("report: asked the guest for its logs (request \(id))")
        pending = (id, nil, Data(), done)
        DispatchQueue.main.asyncAfter(deadline: .now() + timeout) { [weak self] in
            guard let self, self.pending?.id == id else { return }
            self.finish(.failure(OptionError("no answer from SteamOS within \(Int(timeout)) s")))
        }
    }

    private func finish(_ r: Result<Data, OptionError>) {
        guard let p = pending else { return }
        pending = nil
        switch r {
        case .success(let d): log("report: guest log bundle \(p.id): \(d.count) bytes, sha256 verified")
        case .failure(let e): log("report: guest log bundle \(p.id): \(e)")
        }
        p.done(r)
    }
}

// MARK: - collection

/// What the user chose to include (the dialog's checkboxes).
struct ReportChoices: Equatable {
    var launcherLogs = true
    var guestLogs = true
    var screenshot = false
}

/// Where the report is made: the VM process (window, running guest) or the supervisor after the
/// VM process ended (no guest, no window).
struct ReportContext {
    /// menu | settings | stall | crash | control
    var origin: String
    var options: Options?
    var runDir: String?
    var guest: GuestLogs?
    /// The VM window's picture (nil without a window).
    var captureScreenshot: ((@escaping (CGImage?) -> Void) -> Void)?
    /// After an unexpected VM exit: what happened ("VM process crashed (SIGABRT)").
    var exitSummary: String?
}

/// One report folder: ~/Library/Logs/es.fxgam.steamac/reports/<yyyy-MM-dd-HHmmss>-<id>/.
final class ReportBundle: @unchecked Sendable {
    static var reportsDir: String {
        NSHomeDirectory() + "/Library/Logs/" + LauncherSettings.defaultDomain + "/reports"
    }
    static let logTail = 2 << 20
    static let guestTimeout: TimeInterval = 20

    /// Sentry event id of the feedback (32 hex digits); the first 8 are the report ID shown.
    let eventId: String
    let dir: String
    let choices: ReportChoices
    let context: ReportContext
    private(set) var notes: [String] = []

    var shortId: String { String(eventId.prefix(8)) }

    private init(context: ReportContext, choices: ReportChoices) throws {
        eventId = UUID().uuidString.replacingOccurrences(of: "-", with: "").lowercased()
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.dateFormat = "yyyy-MM-dd-HHmmss"
        dir = ReportBundle.reportsDir + "/" + f.string(from: Date()) + "-" + String(eventId.prefix(8))
        self.choices = choices
        self.context = context
        try FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true,
                                                attributes: [.posixPermissions: 0o700])
    }

    func delete() {
        try? FileManager.default.removeItem(atPath: dir)
    }

    /// Collect everything chosen (main actor: the screenshot and the guest request run there).
    @MainActor
    static func collect(context: ReportContext, choices: ReportChoices, status: (String) -> Void) async throws -> ReportBundle {
        let b = try ReportBundle(context: context, choices: choices)
        status(choices.launcherLogs ? String(localized: "Collecting launcher logs…") : String(localized: "Collecting system information…"))
        await Task.detached { b.writeHostFiles() }.value
        if choices.screenshot {
            if let capture = context.captureScreenshot {
                status(String(localized: "Taking a screenshot of the VM window…"))
                let image: CGImage? = await withCheckedContinuation { c in
                    var resumed = false
                    let once = { (img: CGImage?) in
                        guard !resumed else { return }
                        resumed = true
                        c.resume(returning: img)
                    }
                    capture { img in DispatchQueue.main.async { once(img) } }
                    DispatchQueue.main.asyncAfter(deadline: .now() + 3) { once(nil) }
                }
                if let image, (try? PNG.write(image, to: b.dir + "/screenshot.png")) != nil {
                    b.notes.append("screenshot: \(image.width)x\(image.height)")
                } else {
                    b.notes.append("screenshot: the VM window did not draw within 3 s; none included")
                }
            } else {
                b.notes.append("screenshot: no VM window")
            }
        }
        if choices.guestLogs {
            if let guest = context.guest, guest.agentRunning {
                status(String(localized: "Asking SteamOS for its logs (up to \(Int(guestTimeout)) s)…"))
                let r: Result<Data, OptionError> = await withCheckedContinuation { c in
                    guest.request(timeout: guestTimeout) { c.resume(returning: $0) }
                }
                switch r {
                case .success(let data):
                    do {
                        try data.write(to: URL(fileURLWithPath: b.dir + "/steamos-logs.tar.gz"))
                        b.notes.append("SteamOS logs: \(data.count) bytes from the guest agent")
                    } catch {
                        b.notes.append("SteamOS logs: cannot save (\(error))")
                    }
                case .failure(let e):
                    b.notes.append("SteamOS logs: not included (\(e))")
                }
            } else {
                b.notes.append("SteamOS logs: not included (" + (context.guest == nil ? "the VM is not running"
                    : "the SteamOS agent is not running or not responding") + ")")
            }
        }
        status(String(localized: "Collecting system information…"))
        await Task.detached { b.writeSystemInfo() }.value
        log("report: collected \(b.shortId) in \((b.dir as NSString).abbreviatingWithTildeInPath)")
        return b
    }

    // MARK: files

    private func write(_ name: String, _ text: String) {
        try? text.write(toFile: dir + "/" + name, atomically: true, encoding: .utf8)
    }

    private func writeHostFiles() {
        write("settings.txt", settingsDump())
        guard let runDir = context.runDir else {
            notes.append("launcher and console logs: no run directory (launcher started without its supervisor)")
            return
        }
        if choices.launcherLogs {
            if let data = RollingLog.tail(dir: runDir, name: RollingLog.launcher.name, maxBytes: ReportBundle.logTail) {
                write("launcher.log", ReportBundle.scrub(String(decoding: data, as: UTF8.self)))
            } else {
                notes.append("launcher log: none recorded this session")
            }
            // Perf and stall lines of the whole session (the log above is only its tail).
            if let all = RollingLog.tail(dir: runDir, name: RollingLog.launcher.name, maxBytes: 8 * RollingLog.limit) {
                let lines = String(decoding: all, as: UTF8.self).split(separator: "\n")
                    .filter { $0.contains("] perf: ") || $0.contains("] stall: ") }
                if !lines.isEmpty { write("perf-stall.log", ReportBundle.scrub(lines.suffix(3000).joined(separator: "\n") + "\n")) }
            }
        }
        // The hvc0 console is the guest's: only with "Include SteamOS logs".
        if choices.guestLogs {
            if let data = RollingLog.tail(dir: runDir, name: RollingLog.console.name, maxBytes: ReportBundle.logTail) {
                write("console.log", ReportBundle.scrub(String(decoding: data, as: UTF8.self)))
            } else {
                notes.append("SteamOS console log: none recorded this session")
            }
        }
    }

    /// Saved preferences (never the SSH password: that lives in the Keychain and is not a
    /// preference; game names are left out), command-line overrides of this run.
    private func settingsDump() -> String {
        let s = LauncherSettings.shared
        var out = "# Saved settings (\(LauncherSettings.domain)); '-' = default\n"
        for key in LauncherSettings.Key.allCases where key != .gameNames {
            let v = s.defaults.object(forKey: key.rawValue).map { "\($0)" } ?? "-"
            out += "\(key.rawValue) = \(v)\n"
        }
        let perGame = s.defaults.dictionaryRepresentation().filter { $0.key.hasPrefix("autoCapture.") }
        for (k, v) in perGame.sorted(by: { $0.key < $1.key }) { out += "\(k) = \(v)\n" }
        if !s.overrides.isEmpty {
            out += "\n# Overridden by the command line for this run\n"
            for (k, flag) in s.overrides.sorted(by: { $0.key.rawValue < $1.key.rawValue }) { out += "\(k.rawValue): \(flag)\n" }
        }
        return CrashReporting.scrub(out)
    }

    private func writeSystemInfo() {
        var lines: [String] = []
        func add(_ k: String, _ v: String?) { if let v, !v.isEmpty { lines.append("\(k): \(v)") } }
        let info = Bundle.main.infoDictionary ?? [:]
        let v = ProcessInfo.processInfo.operatingSystemVersion
        add("report", "\(eventId) (ID \(shortId))")
        add("created", ISO8601DateFormatter().string(from: Date()))
        add("origin", context.origin)
        add("app", "\(CrashReporting.releaseName) (\(CrashReporting.environment)), version \(info["CFBundleShortVersionString"] as? String ?? "?")"
            + " build \(info["CFBundleVersion"] as? String ?? "?")")
        add("app path", Bundle.main.bundlePath)
        add("macOS", "\(v.majorVersion).\(v.minorVersion).\(v.patchVersion) (\(ReportBundle.sysctl("kern.osversion") ?? "?"))")
        add("mac", "\(ReportBundle.sysctl("hw.model") ?? "?"), \(ReportBundle.sysctl("machdep.cpu.brand_string") ?? "?"), "
            + "\(ProcessInfo.processInfo.activeProcessorCount) cores, \(ProcessInfo.processInfo.physicalMemory >> 30) GB")
        add("gpu", MTLCreateSystemDefaultDevice()?.name ?? "none")
        for (label, lib) in [("libkrun", "libkrun.1.dylib"), ("virglrenderer", "libvirglrenderer.1.dylib"), ("MoltenVK", "libMoltenVK.dylib"),
                             ("KosmicKrisp", "libvulkan_kosmickrisp.dylib")] {
            add(label, ReportBundle.libraryIdentity(lib))
        }
        add("MoltenVK patch", info["SteamacMVKPatchRevision"] as? String)
        add("KosmicKrisp patch", info["SteamacKosmicKrispRevision"] as? String)
        let tags = CrashReporting.tagSnapshot(runDir: context.runDir)
        if let o = context.options {
            add("kernel", (CrashReporting.kernelVersion(image: o.kernel) ?? "?") + " (\(o.kernel))")
            add("initramfs", o.initrd)
            for (i, d) in o.disks.enumerated() { add("disk \(i)", ReportBundle.diskInfo(d.path) + (d.readOnly ? " (ro)" : "")) }
            add("vm", "cpus \(o.cpus) (\(o.cpusSource.rawValue)), memory \(o.memMiB) MiB (\(o.memSource.rawValue)), "
                + "display \(o.guestSize.0)x\(o.guestSize.1)@\(o.refreshRate)" + (o.pixelScale > 1 ? " retina \(o.pixelScale)x" : "")
                + (o.headless ? " headless" : o.fullscreen ? " fullscreen" : " windowed")
                + ", mouse \(o.mouseMode.rawValue), network \(o.network ? "on" : "off"), sound \(o.sound ? "on" : "off"), gamepad \(o.gamepad ? "on" : "off")"
                + ", vulkan \(o.vulkanDriver.rawValue)")
            add("cmdline", o.cmdline)
        }
        var build = tags["steamos_build"], layer = tags["layer"]
        if (build == nil || layer == nil), let dir = context.runDir,
           let console = RollingLog.tail(dir: dir, name: RollingLog.console.name, maxBytes: 8 * RollingLog.limit) {
            for line in String(decoding: console, as: UTF8.self).split(separator: "\n") {
                if build == nil, line.contains("steamac-init: rootfs-"), let r = line.range(of: "BUILD_ID=") {
                    build = String(line[r.upperBound...].prefix { !$0.isWhitespace })
                } else if layer == nil, let r = line.range(of: "steamac-init: steamac layer "),
                          let c = line.range(of: ": ", range: r.upperBound..<line.endIndex) {
                    layer = line[c.upperBound...].trimmingCharacters(in: .whitespaces)
                }
            }
        }
        add("SteamOS BUILD_ID", build)
        add("steamac layer", layer)
        add("boot", tags["boot"])
        add("run", tags["run"])
        add("crash reporting", CrashReporting.statusSummary)
        add("last error event", CrashReporting.lastEventId(runDir: context.runDir))
        add("exit", context.exitSummary)
        var text = "# FX Steam Launcher problem report\n" + lines.joined(separator: "\n") + "\n"
        if !notes.isEmpty { text += "\n# Collection notes\n" + notes.map { "- " + $0 }.joined(separator: "\n") + "\n" }
        let other = tags.filter { !["steamos_build", "layer", "boot", "run"].contains($0.key) }
        if !other.isEmpty {
            text += "\n# Crash-report tags\n" + other.sorted { $0.key < $1.key }.map { "\($0.key) = \($0.value)" }.joined(separator: "\n") + "\n"
        }
        write("system-info.txt", CrashReporting.scrub(text))
    }

    // MARK: report.json / helpers

    /// The user's part (kept with the files so a saved report can be sent by hand).
    func writeReport(email: String, description: String) {
        let obj: [String: Any] = [
            "report_id": shortId, "event_id": eventId, "email": email, "description": description,
            "origin": context.origin, "created": ISO8601DateFormatter().string(from: Date()),
            "included": ["launcher_logs": choices.launcherLogs, "steamos_logs": choices.guestLogs, "screenshot": choices.screenshot],
            "notes": notes,
        ]
        if let data = try? JSONSerialization.data(withJSONObject: obj, options: [.prettyPrinted, .sortedKeys]) {
            try? data.write(to: URL(fileURLWithPath: dir + "/report.json"))
        }
    }

    /// Launcher log scrubbing (home folder, emails, IPs, user/computer names) plus Steam IDs,
    /// which the guest console may print.
    static func scrub(_ text: String) -> String {
        var out = CrashReporting.scrub(text)
        for (re, with) in steamIDRegexes {
            out = re.stringByReplacingMatches(in: out, range: NSRange(out.startIndex..., in: out), withTemplate: with)
        }
        return out
    }

    private static let steamIDRegexes: [(NSRegularExpression, String)] = [
        (try! NSRegularExpression(pattern: "\\[U:1:\\d+\\]"), "[U:1:<id>]"),
        (try! NSRegularExpression(pattern: "(?<!\\d)7656119\\d{10}(?!\\d)"), "<steamid>"),
    ]

    /// The last `maxBytes` of `data`, starting after a newline.
    static func lineTail(_ data: Data, maxBytes: Int) -> Data {
        guard data.count > maxBytes else { return data }
        let tail = data.suffix(maxBytes)
        guard let nl = tail.firstIndex(of: 10) else { return Data(tail) }
        return Data(tail[tail.index(after: nl)...])
    }

    static func sysctl(_ name: String) -> String? {
        var size = 0
        guard sysctlbyname(name, nil, &size, nil, 0) == 0, size > 0 else { return nil }
        var buf = [CChar](repeating: 0, count: size)
        guard sysctlbyname(name, &buf, &size, nil, 0) == 0 else { return nil }
        return String(cString: buf)
    }

    /// "<uuid> (<path>)": LC_UUID of the loaded image, else of the file next to the loaded libkrun.
    static func libraryIdentity(_ lib: String) -> String? {
        if let uuid = CrashReporting.loadedImageUUID(suffix: "/" + lib) { return uuid + " (loaded)" }
        var dir: String?
        for i in 0..<_dyld_image_count() {
            guard let n = _dyld_get_image_name(i) else { continue }
            let name = String(cString: n)
            if name.hasSuffix("/libkrun.1.dylib") || name.hasSuffix("/libkrun.dylib") { dir = (name as NSString).deletingLastPathComponent }
        }
        guard let dir else { return nil }
        let path = dir + "/" + lib
        return fileUUID(path).map { "\($0) (\(path))" }
    }

    /// LC_UUID of a Mach-O file (thin, or the arm64 slice of a universal one).
    static func fileUUID(_ path: String) -> String? {
        guard let data = try? Data(contentsOf: URL(fileURLWithPath: path), options: .alwaysMapped), data.count > 64 else { return nil }
        return data.withUnsafeBytes { raw -> String? in
            func u32(_ o: Int) -> UInt32 { o + 4 <= raw.count ? raw.loadUnaligned(fromByteOffset: o, as: UInt32.self) : 0 }
            var base = 0
            if u32(0) == 0xbebafeca {   // FAT_MAGIC, big-endian
                for i in 0..<Int(UInt32(bigEndian: u32(4))) where UInt32(bigEndian: u32(8 + i * 20)) == 0x0100000c {   // CPU_TYPE_ARM64
                    base = Int(UInt32(bigEndian: u32(8 + i * 20 + 8)))
                }
            }
            guard u32(base) == 0xfeedfacf else { return nil }   // MH_MAGIC_64
            var p = base + 32
            for _ in 0..<u32(base + 16) {
                let cmd = u32(p), size = Int(u32(p + 4))
                if cmd == 0x1b, p + 24 <= raw.count {   // LC_UUID
                    let bytes = (0..<16).map { raw[p + 8 + $0] }
                    return UUID(uuid: (bytes[0], bytes[1], bytes[2], bytes[3], bytes[4], bytes[5], bytes[6], bytes[7], bytes[8],
                                       bytes[9], bytes[10], bytes[11], bytes[12], bytes[13], bytes[14], bytes[15])).uuidString.lowercased()
                }
                guard size > 0 else { return nil }
                p += size
            }
            return nil
        }
    }

    /// "<path>: 87.0 GB, 31.2 GB allocated; 412 GB free on the volume"
    static func diskInfo(_ path: String) -> String {
        var st = stat()
        guard stat(path, &st) == 0 else { return path + ": not readable" }
        let gb = { (n: Int64) in n < 1_000_000_000 ? String(format: "%.1f MB", Double(n) / 1e6) : String(format: "%.1f GB", Double(n) / 1e9) }
        var s = "\(path): \(gb(Int64(st.st_size))), \(gb(Int64(st.st_blocks) * 512)) allocated"
        if let free = (try? URL(fileURLWithPath: path).resourceValues(forKeys: [.volumeAvailableCapacityForImportantUsageKey]))?
            .volumeAvailableCapacityForImportantUsage {
            s += "; \(gb(free)) free on the volume"
        }
        return s
    }
}

// MARK: - upload

/// Sends a report folder as Sentry User Feedback: one envelope with a `feedback` item (the
/// sentry-cocoa SentryFeedback payload: message, contact email, associated event) and the
/// folder's files as attachments, POSTed to the project's envelope endpoint. Sent directly (not
/// through the SDK's queue) so the result is known: HTTP 200 = accepted; anything else leaves the
/// folder on disk for a retry. Independent of the crash-reporting setting (an explicit user
/// action; no SDK, no crash handler is started for it). Attachments are capped at
/// `budget` (20 MB): the oldest parts of the logs are cut first, then the screenshot and the
/// SteamOS bundle are dropped; a 413 from the server halves the cap and sends again.
enum FeedbackSender {
    static let budget = 20_000_000
    /// Control FIFO `report dsn …` / STEAMAC_REPORT_DSN (failure-path tests).
    nonisolated(unsafe) static var dsnOverride: String? = ProcessInfo.processInfo.environment["STEAMAC_REPORT_DSN"]

    struct Item {
        let filename: String
        var data: Data
        let contentType: String
    }

    /// Returns the event id Sentry accepted.
    static func send(_ b: ReportBundle, email: String, description: String, test: Bool,
                     progress: @escaping @Sendable (Double) -> Void) async throws -> String {
        let dsn = dsnOverride ?? CrashReporting.dsn
        guard let url = URL(string: dsn), let host = url.host, let key = url.user, let scheme = url.scheme else {
            throw OptionError("bad DSN \(dsn)", localized: String(localized: "Invalid report server address: \(dsn)"))
        }
        let project = url.lastPathComponent
        let port = url.port.map { ":\($0)" } ?? ""
        guard let endpoint = URL(string: "\(scheme)://\(host)\(port)/api/\(project)/envelope/") else {
            throw OptionError("bad DSN \(dsn)", localized: String(localized: "Invalid report server address: \(dsn)"))
        }
        var items = loadItems(b.dir)
        var cap = budget
        for attempt in 1...4 {
            let notes = fit(&items, budget: cap)
            let body = envelope(b, items: items, notes: notes, email: email, description: description, test: test, dsn: dsn)
            var req = URLRequest(url: endpoint, cachePolicy: .reloadIgnoringLocalCacheData, timeoutInterval: 60)
            req.httpMethod = "POST"
            req.setValue("application/x-sentry-envelope", forHTTPHeaderField: "Content-Type")
            req.setValue("Sentry sentry_version=7, sentry_client=\(sdk["name"]!)/\(sdk["version"]!), sentry_key=\(key)",
                         forHTTPHeaderField: "X-Sentry-Auth")
            log("report: sending \(b.shortId) to \(host): \(body.count) bytes, \(items.count) attachment(s)"
                + (notes.isEmpty ? "" : " (\(notes.joined(separator: "; ")))"))
            let (data, response) = try await URLSession.shared.upload(for: req, from: body, delegate: UploadProgress(progress))
            let status = (response as? HTTPURLResponse)?.statusCode ?? 0
            let text = String(decoding: data.prefix(500), as: UTF8.self)
            if ProcessInfo.processInfo.environment[CrashReporting.debugEnv] == "1" {
                log("report: HTTP \(status) from \(endpoint.absoluteString): \(text)")
            }
            switch status {
            case 200:
                let id = ((try? JSONSerialization.jsonObject(with: data)) as? [String: Any])?["id"] as? String ?? b.eventId
                log("report: accepted by Sentry (HTTP 200, id \(id))")
                return id
            case 413 where attempt < 4:
                let total = items.reduce(0) { $0 + $1.data.count }
                cap = max(1_000_000, min(cap, total) / 2)
                log("report: HTTP 413 (too large: \(text.isEmpty ? "no detail" : text)); retrying with attachments capped at \(cap) bytes")
            case 429:
                let after = (response as? HTTPURLResponse)?.value(forHTTPHeaderField: "Retry-After") ?? "later"
                let localized = after == "later"
                    ? String(localized: "The server is busy (HTTP 429); try again later.")
                    : String(localized: "The server is busy (HTTP 429); try again in \(after) s.")
                throw OptionError("the server is busy (HTTP 429); try again \(after == "later" ? "later" : "in \(after) s")",
                                  localized: localized)
            default:
                let localized = text.isEmpty
                    ? String(localized: "The server answered HTTP \(status).")
                    : String(localized: "The server answered HTTP \(status): \(String(text.prefix(200)))")
                throw OptionError("the server answered HTTP \(status)" + (text.isEmpty ? "" : ": \(text.prefix(200))"),
                                  localized: localized)
            }
        }
        throw OptionError("the report is too large for the server even after shrinking it",
                          localized: String(localized: "The report is too large for the server even after shrinking it."))
    }

    private static func loadItems(_ dir: String) -> [Item] {
        let order = ["system-info.txt", "settings.txt", "launcher.log", "perf-stall.log", "console.log",
                     "steamos-logs.tar.gz", "screenshot.png"]
        let names = ((try? FileManager.default.contentsOfDirectory(atPath: dir)) ?? [])
            .filter { $0 != "report.json" && !$0.hasPrefix(".") }
            .sorted { (order.firstIndex(of: $0) ?? 99, $0) < (order.firstIndex(of: $1) ?? 99, $1) }
        return names.compactMap { name in
            guard let data = FileManager.default.contents(atPath: dir + "/" + name) else { return nil }
            let type = name.hasSuffix(".png") ? "image/png" : name.hasSuffix(".gz") ? "application/gzip" : "text/plain"
            return Item(filename: name, data: data, contentType: type)
        }
    }

    /// Shrink `items` to `budget` bytes; returns what was cut.
    static func fit(_ items: inout [Item], budget: Int) -> [String] {
        var notes: [String] = []
        func total() -> Int { items.reduce(0) { $0 + $1.data.count } }
        let logs = ["launcher.log", "console.log", "perf-stall.log"]
        for floor in [256 << 10, 32 << 10] {
            while total() > budget,
                  let i = items.indices.filter({ logs.contains(items[$0].filename) && items[$0].data.count > floor + 4096 })
                      .max(by: { items[$0].data.count < items[$1].data.count }) {
                let keep = max(floor, items[i].data.count - (total() - budget))
                items[i].data = Data("[… older part cut to fit the report size limit …]\n".utf8)
                    + ReportBundle.lineTail(items[i].data, maxBytes: keep)
                notes.append("\(items[i].filename) cut to its last \(keep >> 10) KiB")
            }
            for name in ["screenshot.png", "steamos-logs.tar.gz"] where total() > budget {
                if let i = items.firstIndex(where: { $0.filename == name }) {
                    notes.append("\(name) left out (\(items[i].data.count >> 10) KiB)")
                    items.remove(at: i)
                }
            }
        }
        return notes
    }

    private static func envelope(_ b: ReportBundle, items: [Item], notes: [String], email: String, description: String,
                                 test: Bool, dsn: String) -> Data {
        let assoc = CrashReporting.lastEventId(runDir: b.context.runDir).map { SentryId(uuidString: $0) }
        let feedback = SentryFeedback(message: description, name: nil, email: email, source: .custom, associatedEventId: assoc)
        let v = ProcessInfo.processInfo.operatingSystemVersion
        var tags = CrashReporting.tagSnapshot(runDir: b.context.runDir)
        tags["report_origin"] = b.context.origin
        tags["report_id"] = b.shortId
        tags["steamos_logs"] = b.choices.guestLogs ? (items.contains { $0.filename == "steamos-logs.tar.gz" } ? "yes" : "unavailable") : "no"
        if test { tags["test"] = "true" }
        let event: [String: Any] = [
            "event_id": b.eventId,
            "timestamp": Date().timeIntervalSince1970,
            "platform": "cocoa",
            "level": "info",
            "release": CrashReporting.releaseName,
            "environment": test ? "development" : CrashReporting.environment,
            "user": ["id": CrashReporting.installID],
            "tags": tags,
            "contexts": [
                "feedback": feedback.serialize(),
                "os": ["name": "macOS", "version": "\(v.majorVersion).\(v.minorVersion).\(v.patchVersion)",
                       "build": ReportBundle.sysctl("kern.osversion") ?? ""],
                "device": ["model": ReportBundle.sysctl("hw.model") ?? "", "arch": "arm64"],
            ],
            "extra": ["report_notes": b.notes + notes, "attachments": items.map { "\($0.filename) (\($0.data.count) bytes)" }],
            "sdk": sdk,
        ]
        let header: [String: Any] = [
            "event_id": b.eventId, "dsn": dsn, "sent_at": ISO8601DateFormatter().string(from: Date()),
            "sdk": sdk,
        ]
        var body = Data()
        func json(_ o: Any) -> Data { (try? JSONSerialization.data(withJSONObject: o)) ?? Data("{}".utf8) }
        let payload = json(event)
        body += json(header) + Data("\n".utf8)
        body += json(["type": "feedback", "length": payload.count, "content_type": "application/json"]) + Data("\n".utf8)
        body += payload + Data("\n".utf8)
        for item in items {
            body += json(["type": "attachment", "length": item.data.count, "filename": item.filename,
                          "content_type": item.contentType, "attachment_type": "event.attachment"]) + Data("\n".utf8)
            body += item.data + Data("\n".utf8)
        }
        return body
    }

    /// The sentry-cocoa SDK identity (sentry.cocoa / 9.30.0) the payload is made with.
    private static var sdk: [String: String] {
        ["name": SentrySDK.internal.sdk.name, "version": SentrySDK.internal.sdk.versionString]
    }

    private final class UploadProgress: NSObject, URLSessionTaskDelegate {
        let onProgress: @Sendable (Double) -> Void
        init(_ p: @escaping @Sendable (Double) -> Void) { onProgress = p }
        func urlSession(_ session: URLSession, task: URLSessionTask, didSendBodyData bytesSent: Int64,
                        totalBytesSent: Int64, totalBytesExpectedToSend: Int64) {
            onProgress(Double(totalBytesSent) / Double(max(1, totalBytesExpectedToSend)))
        }
    }
}
