import Darwin
import Foundation

/// What the overlay shows. `fraction` is overall progress 0...1 (monotonic within a phase).
struct ProgressState: Equatable {
    enum Phase: Equatable { case boot, running, shutdown(reboot: Bool) }
    var phase: Phase = .boot
    var stageId = "vm"
    var title = String(localized: "Starting virtual machine…")
    var logTitle = "Starting virtual machine…"
    var detail = ""
    var logDetail = ""
    var fraction = 0.0
    var indeterminate = false
}

/// What has input focus in the guest, as reported by the progress agent.
enum GuestFocus: Equatable {
    case steam
    case game(Int)
    /// Desktop Mode (`focus desktop <w>x<h>`): the Plasma desktop, one window of this size that
    /// gamescope scales into the display.
    case desktop(width: Int, height: Int)
    /// The gamescope session ended without a system shutdown (bare `focus desktop`: Switch to
    /// Desktop, Return to Gaming Mode, relogin); nothing reports until the next session's agent.
    case sessionEnded
}

/// Boot / shutdown progress model (local://overlay-contract.md). Fed with hvc0 console lines
/// (host-side stages, shutdown detection) and with fx.progress lines from the guest agent.
/// All methods run on the main thread.
final class BootProgress {
    /// Overall-bar segment for each stage: (start, weight) in percent.
    static let segments: [String: (Double, Double)] = [
        "vm": (0, 3), "kernel": (3, 7), "provision": (3, 7), "init": (10, 0), "systemd": (10, 20), "graphical": (30, 0),
        "session": (30, 5), "steam-check": (35, 5), "steam-download": (40, 45),
        "steam-install": (85, 10), "steam-start": (95, 5),
    ]
    static let guestStages: Set<String> = ["session", "steam-check", "steam-download", "steam-install", "steam-start"]

    /// The guest agent's fixed stage texts (guest/progress-agent/src/main.rs) in the UI language;
    /// any other text it sends is shown as sent.
    static func localizedGuestText(_ text: String) -> String {
        switch text {
        case "Session started": return String(localized: "Session started")
        case "Starting Steam client": return String(localized: "Starting Steam client")
        case "Starting Steam": return String(localized: "Starting Steam")
        case "Restarting Steam": return String(localized: "Restarting Steam")
        case "Verifying Steam installation": return String(localized: "Verifying Steam installation")
        case "Checking for Steam updates": return String(localized: "Checking for Steam updates")
        case "Downloading Steam update": return String(localized: "Downloading Steam update")
        case "Steam update downloaded": return String(localized: "Steam update downloaded")
        case "Extracting Steam update": return String(localized: "Extracting Steam update")
        case "Installing Steam update": return String(localized: "Installing Steam update")
        case "Steam update installed": return String(localized: "Steam update installed")
        case "Loading Steam UI": return String(localized: "Loading Steam UI")
        case "Opening Steam": return String(localized: "Opening Steam")
        case "Steam is ready": return String(localized: "Steam is ready")
        default: return text
        }
    }

    private(set) var state = ProgressState()
    /// State changed (overlay redraw / log line).
    var onChange: ((ProgressState) -> Void)?
    /// Steam UI is up (`ready`).
    var onReady: (() -> Void)?
    /// Shutdown started (phase switched to .shutdown).
    var onShutdown: ((_ reboot: Bool) -> Void)?
    /// The guest is going to reboot (and the host did not ask for a power-off).
    var onRebootIntent: (() -> Void)?
    /// Which guest app has focus (`focus steam` / `focus game <appid>` / `focus desktop [<w>x<h>]`).
    var onFocus: ((GuestFocus) -> Void)?
    /// `game <appid> <name>`: the display name of a game the guest focused.
    var onGameName: ((Int, String) -> Void)?
    /// `game-frozen <appid>` / `game-thawed <appid>`: the agent's confirmation of a pause (GamePause).
    var onGameFrozen: ((_ appid: Int, _ frozen: Bool) -> Void)?
    /// First-boot provisioning ended (`provision done` / `provision failed <reason>`, fx.progress
    /// or hvc0 `steamac-provision: …`); may be reported on both channels.
    var onProvision: ((_ ok: Bool, _ reason: String) -> Void)?
    /// Guest password payload: `config applied` / `config failed <reason>` (or hvc0 `steamac-config: …`).
    var onConfig: ((_ ok: Bool, _ reason: String) -> Void)?
    /// Guest agent heartbeat, once a second: `alive <uptime_ms> <loadavg1>`.
    var onAlive: ((_ uptimeMs: Int, _ load: Double) -> Void)?

    private var sawConsole = false
    private var okLines = 0
    private var stopLines = 0
    private var hostRequestedPowerOff = false
    private var rebootIntent = false

    init(restarting: Bool = false) {
        if restarting {
            state.title = String(localized: "Restarting SteamOS…")
            state.logTitle = "Restarting SteamOS…"
        }
    }

    // MARK: inputs

    func consoleLine(_ raw: String) {
        let line = BootProgress.stripKernelTimestamp(BootProgress.stripANSI(raw).trimmingCharacters(in: .whitespacesAndNewlines))
        guard !line.isEmpty else { return }
        if !sawConsole {
            sawConsole = true
            if state.phase == .boot && state.stageId == "vm" {
                set(stage: "kernel", title: "Booting Linux kernel…", localizedTitle: String(localized: "Booting Linux kernel…"), percent: 0)
            }
        }
        if case .shutdown = state.phase {
            shutdownConsoleLine(line)
            return
        }
        // Shutdown markers (only ever printed when the whole system goes down).
        if line.contains("Stopped target Graphical Interface") || line.contains("Stopped target Multi-User System")
            || BootProgress.shutdownTargets.contains(where: { line.contains("Reached target \($0)") })
            || line.hasPrefix("reboot: ") {
            beginShutdown(reboot: line.contains("System Reboot") || line.contains("reboot: Restarting"))
            shutdownConsoleLine(line)
            return
        }
        guard state.phase == .boot else { return }
        if let r = line.range(of: "steamac-provision: ") {
            provisionLine(String(line[r.upperBound...]))
        } else if let r = line.range(of: "steamac-config: ") {
            configLine(String(line[r.upperBound...]))
        } else if let r = line.range(of: "steamac-init: switching to rootfs-") {
            let slot = String(line[r.upperBound...].prefix(1))
            set(stage: "init", title: "Mounting SteamOS (slot \(slot))…",
                localizedTitle: String(localized: "Mounting SteamOS (slot \(slot))…"), percent: 100)
        } else if line.contains("Welcome to SteamOS") {
            okLines = 0
            set(stage: "systemd", title: "Starting SteamOS services…", localizedTitle: String(localized: "Starting SteamOS services…"), percent: 0)
        } else if line.contains("Reached target Graphical Interface") {
            set(stage: "graphical", title: "Starting Steam session…", localizedTitle: String(localized: "Starting Steam session…"), percent: 0, indeterminate: true)
        } else if state.stageId == "systemd", let text = BootProgress.okText(line) {
            okLines += 1
            // ~120 [ OK ] lines on a SteamOS boot; approach 95% of the stage asymptotically.
            let p = 95 * (1 - exp(-Double(okLines) / 45))
            set(stage: "systemd", title: state.logTitle, localizedTitle: state.title, percent: p, detail: text)
        }
    }

    /// One line from /dev/virtio-ports/fx.progress.
    func guestLine(_ raw: String) {
        let line = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        let parts = line.split(separator: " ", maxSplits: 3, omittingEmptySubsequences: true).map(String.init)
        guard let verb = parts.first else { return }
        switch verb {
        case "stage":
            guard parts.count >= 3, BootProgress.guestStages.contains(parts[1]), let pct = Int(parts[2]),
                  state.phase == .boot else { return }
            let text = parts.count > 3 ? parts[3] : state.logTitle
            set(stage: parts[1], title: text, localizedTitle: parts.count > 3 ? BootProgress.localizedGuestText(text) : state.title,
                percent: Double(max(0, min(100, pct))), indeterminate: pct < 0,
                detail: parts[1] == state.stageId ? state.logDetail : "",
                localizedDetail: parts[1] == state.stageId ? state.detail : "")
        case "provision":
            provisionLine(parts.dropFirst().joined(separator: " "))
        case "config":
            configLine(parts.dropFirst().joined(separator: " "))
        case "log":
            guard line.count > 4 else { return }
            var s = state
            s.detail = String(line.dropFirst(4))
            s.logDetail = s.detail
            publish(s)
        case "ready":
            guard state.phase == .boot else { return }
            var s = state
            s.phase = .running
            s.stageId = "ready"
            s.title = String(localized: "Steam is ready")
            s.logTitle = "Steam is ready"
            s.fraction = 1
            s.indeterminate = false
            s.detail = ""
            s.logDetail = ""
            publish(s)
            onReady?()
        case "shutdown":
            guard parts.count >= 2 else { return }
            beginShutdown(reboot: parts[1] == "reboot")
        case "focus":
            guard parts.count >= 2 else { return }
            switch parts[1] {
            case "steam": onFocus?(.steam)
            case "desktop":
                let size = parts.count >= 3 ? parts[2].split(separator: "x").compactMap { Int($0) } : []
                if size.count == 2, size[0] > 0, size[1] > 0 {
                    onFocus?(.desktop(width: size[0], height: size[1]))
                } else {
                    onFocus?(.sessionEnded)
                }
            case "game": onFocus?(.game(parts.count >= 3 ? (Int(parts[2]) ?? 0) : 0))
            default: break
            }
        case "game-frozen", "game-thawed":
            guard parts.count >= 2, let id = Int(parts[1]) else { return }
            onGameFrozen?(id, verb == "game-frozen")
        case "game":   // game <appid> <name>: display name of a focused game (Settings > Mouse)
            guard parts.count >= 3, let id = Int(parts[1]), id > 0,
                  let r = line.range(of: parts[1], range: line.index(line.startIndex, offsetBy: 4)..<line.endIndex) else { return }
            let name = line[r.upperBound...].trimmingCharacters(in: .whitespaces)
            if !name.isEmpty { onGameName?(id, name) }
        case "alive":
            guard parts.count >= 3, let ms = Int(parts[1]), let load = Double(parts[2]) else { return }
            onAlive?(ms, load)
        default:
            break   // forward compatible
        }
    }

    /// The launcher pressed the guest power key (window close, menu, signal).
    func hostRequestedShutdown() {
        hostRequestedPowerOff = true
        if case .shutdown = state.phase {
            var s = state
            s.phase = .shutdown(reboot: false)
            s.title = String(localized: "Shutting down…")
            s.logTitle = "Shutting down…"
            publish(s)
        } else {
            beginShutdown(reboot: false)
        }
    }

    /// "Restart VM" (Settings / menu): the launcher pressed the power key and relaunches the VM
    /// once it is off (onRebootIntent writes the supervisor's reboot marker).
    func hostRequestedRestart() {
        guard !hostRequestedPowerOff else { return }
        beginShutdown(reboot: true)
        noteReboot()
    }

    /// "applied" | "failed <reason>" (Config payload v1).
    private func configLine(_ rest: String) {
        let words = rest.split(separator: " ", maxSplits: 1).map(String.init)
        if words.first == "applied" { onConfig?(true, "") }
        else if words.first == "failed" { onConfig?(false, words.count > 1 ? words[1] : "") }
    }

    /// "done" | "failed <reason>" | "<pct> <text>" (Payload v1, local://provision-contract.md).
    private func provisionLine(_ rest: String) {
        let words = rest.split(separator: " ", maxSplits: 1).map(String.init)
        guard let first = words.first else { return }
        if first == "done" {
            if state.phase == .boot { set(stage: "provision", title: "SteamOS set up", localizedTitle: String(localized: "SteamOS set up"), percent: 100) }
            onProvision?(true, "")
        } else if first == "failed" {
            onProvision?(false, words.count > 1 ? words[1] : "")
        } else if let pct = Int(first), state.phase == .boot {
            set(stage: "provision", title: "Setting up SteamOS (first start)…",
                localizedTitle: String(localized: "Setting up SteamOS (first start)…"), percent: Double(max(0, min(100, pct))),
                detail: words.count > 1 ? words[1] : "")
        }
    }

    // MARK: shutdown

    static let shutdownTargets = ["System Shutdown", "System Reboot", "System Power Off", "System Halt",
                                  "Final Step", "Late Shutdown Services"]

    private func beginShutdown(reboot: Bool) {
        let reboot = reboot && !hostRequestedPowerOff
        if case .shutdown(let wasReboot) = state.phase {
            if reboot && !wasReboot {
                var s = state
                s.phase = .shutdown(reboot: true)
                s.title = String(localized: "Restarting…")
                s.logTitle = "Restarting…"
                publish(s)
                noteReboot()
            }
            return
        }
        stopLines = 0
        var s = state
        s.phase = .shutdown(reboot: reboot)
        s.stageId = "shutdown"
        s.title = reboot ? String(localized: "Restarting…") : String(localized: "Shutting down…")
        s.logTitle = reboot ? "Restarting…" : "Shutting down…"
        s.detail = ""
        s.logDetail = ""
        s.fraction = 0
        s.indeterminate = false
        publish(s)
        if reboot { noteReboot() }
        onShutdown?(reboot)
    }

    private func noteReboot() {
        guard !rebootIntent, !hostRequestedPowerOff else { return }
        rebootIntent = true
        onRebootIntent?()
    }

    private func shutdownConsoleLine(_ line: String) {
        var s = state
        if line.contains("Reached target System Reboot") || line.hasPrefix("reboot: Restarting") {
            beginShutdown(reboot: true)
            s = state
        }
        if line.contains("Reached target Final Step") || line.contains("Reached target Late Shutdown Services") {
            s.fraction = max(s.fraction, 0.95)
            s.detail = String(localized: "Finishing…")
            s.logDetail = "Finishing…"
        } else if line.hasPrefix("reboot: Power down") || line.hasPrefix("reboot: Restarting") {
            s.fraction = 1
            s.detail = line.hasPrefix("reboot: Power down") ? String(localized: "Powered off") : String(localized: "Restarting")
            s.logDetail = line.hasPrefix("reboot: Power down") ? "Powered off" : "Restarting"
        } else if let text = BootProgress.okText(line), text.hasPrefix("Stopped") || text.hasPrefix("Unmounted") {
            stopLines += 1
            s.fraction = max(s.fraction, 0.9 * (1 - exp(-Double(stopLines) / 40)))
            s.detail = text
            s.logDetail = text
        } else if line.hasPrefix("Stopping ") || line.hasPrefix("Unmounting ") {
            s.detail = line
            s.logDetail = line
        } else if line.contains("A stop job is running for") {
            s.detail = String(line[line.range(of: "A stop job")!.lowerBound...])
            s.logDetail = s.detail
        } else {
            return
        }
        publish(s)
    }

    // MARK: helpers

    private func set(stage id: String, title: String, localizedTitle: String? = nil, percent: Double,
                     indeterminate: Bool = false, detail: String? = nil, localizedDetail: String? = nil) {
        guard let (start, weight) = BootProgress.segments[id] else { return }
        var s = state
        s.stageId = id
        s.title = localizedTitle ?? title
        s.logTitle = title
        s.indeterminate = indeterminate
        s.fraction = max(s.fraction, (start + weight * (indeterminate ? 0 : percent) / 100) / 100)
        if let detail {
            s.detail = localizedDetail ?? detail
            s.logDetail = detail
        } else if id != state.stageId {
            s.detail = ""
            s.logDetail = ""
        }
        publish(s)
    }

    private func publish(_ s: ProgressState) {
        guard s != state else { return }
        let old = state
        state = s
        // Stage/phase changes and 10% steps (guest titles can flip rapidly within a stage).
        if s.stageId != old.stageId || s.phase != old.phase
            || Int(s.fraction * 10) != Int(old.fraction * 10) {
            log("progress: \(s.stageId) \(Int((s.fraction * 100).rounded()))%\(s.indeterminate ? " (…)" : "") \(s.logTitle)"
                + (s.logDetail.isEmpty ? "" : " · \(s.logDetail)"))
        }
        onChange?(s)
    }

    /// "[  OK  ] Started Foo." -> "Started Foo"
    static func okText(_ line: String) -> String? {
        guard line.hasPrefix("[  OK  ] ") else { return nil }
        var t = line.dropFirst(9)
        if t.hasSuffix(".") { t = t.dropLast() }
        return String(t)
    }

    static func stripANSI(_ s: String) -> String {
        guard s.contains("\u{1b}") || s.contains("\r") else { return s }
        var out = ""
        var it = s.unicodeScalars.makeIterator()
        while let c = it.next() {
            if c == "\u{1b}" {
                // CSI: ESC [ params final(0x40-0x7e); other escapes: skip one char.
                guard let n = it.next() else { break }
                if n == "[" {
                    while let p = it.next(), !(0x40...0x7e).contains(p.value) {}
                }
            } else if c != "\r" {
                out.unicodeScalars.append(c)
            }
        }
        return out
    }

    /// "[  123.456789] reboot: Power down" -> "reboot: Power down"
    static func stripKernelTimestamp(_ s: String) -> String {
        guard s.hasPrefix("["), let close = s.firstIndex(of: "]") else { return s }
        let inner = s[s.index(after: s.startIndex)..<close].trimmingCharacters(in: .whitespaces)
        guard !inner.isEmpty, inner.allSatisfy({ $0.isNumber || $0 == "." }), inner.contains(".") else { return s }
        return s[s.index(after: close)...].trimmingCharacters(in: .whitespaces)
    }
}

/// Splits a byte stream into lines (no allocation per byte; partial lines kept between reads).
struct LineSplitter {
    private var pending: [UInt8] = []

    mutating func feed(_ bytes: UnsafeRawBufferPointer, _ emit: (String) -> Void) {
        var start = 0
        for (i, b) in bytes.enumerated() where b == 0x0a {
            pending.append(contentsOf: bytes[start..<i])
            emit(String(decoding: pending, as: UTF8.self))
            pending.removeAll(keepingCapacity: true)
            start = i + 1
        }
        pending.append(contentsOf: bytes[start...])
        if pending.count > 16384 {   // a runaway line without newline: flush it
            emit(String(decoding: pending, as: UTF8.self))
            pending.removeAll(keepingCapacity: true)
        }
    }
}

/// The `fx.progress` virtio-console port: guest writes lines, the launcher reads them; the
/// launcher writes requests the other way (`collect-logs <id>`, GuestLogs).
final class ProgressPort {
    static let name = "fx.progress"
    /// Handed to libkrun: guest -> host data is written here.
    let guestOutputFd: Int32
    /// Handed to libkrun: host -> guest data is read from here.
    let guestInputFd: Int32
    private let readFd: Int32
    private let inputWriteFd: Int32

    init() throws {
        var out: [Int32] = [0, 0], inp: [Int32] = [0, 0]
        guard pipe(&out) == 0, pipe(&inp) == 0 else { throw OptionError("pipe: \(String(cString: strerror(errno)))") }
        readFd = out[0]; guestOutputFd = out[1]
        guestInputFd = inp[0]; inputWriteFd = inp[1]
        for fd in out + inp { _ = fcntl(fd, F_SETFD, FD_CLOEXEC) }
        // Requests are tiny; never block the main thread if libkrun stops draining the pipe.
        _ = fcntl(inputWriteFd, F_SETFL, fcntl(inputWriteFd, F_GETFL) | O_NONBLOCK)
    }

    /// One host -> guest line; false if the pipe did not take it whole.
    func send(_ line: String) -> Bool {
        let bytes = Array((line + "\n").utf8)
        var n: Int
        repeat { n = Darwin.write(inputWriteFd, bytes, bytes.count) } while n < 0 && errno == EINTR
        return n == bytes.count
    }

    /// Reader thread: every complete line goes to `handler` on the main queue.
    func start(_ handler: @escaping (String) -> Void) {
        let t = Thread { [readFd] in
            var splitter = LineSplitter()
            var buf = [UInt8](repeating: 0, count: 4096)
            while true {
                let n = Darwin.read(readFd, &buf, buf.count)
                if n < 0 && errno == EINTR { continue }
                if n <= 0 { break }
                buf.withUnsafeBytes { p in
                    splitter.feed(UnsafeRawBufferPointer(rebasing: p[0..<n])) { line in
                        DispatchQueue.main.async { handler(line) }
                    }
                }
            }
        }
        t.name = "fx.progress"
        t.start()
    }
}
