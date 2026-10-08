import AppKit
import CKrun
import Darwin
import Foundation
import QuartzCore

/// In-memory suspend of the running VM (Settings > General "When closing the window: Suspend",
/// menu Suspend / Ctrl+Cmd+S): krun_pause stops every vCPU and the guest's audio (libkrun patch
/// 0016), the window hides and a menu-bar item offers Resume / Shut Down SteamOS while the app
/// keeps running (Dock icon). Nothing is written to disk: the guest's memory and the host's GPU
/// state (virglrenderer, MoltenVK, Metal) cannot be saved, so the suspended state lives only as
/// long as this process. Resume (Dock icon, the menu-bar item, the app menu, opening the app
/// again) shows the window, continues the vCPUs and restores the mouse capture; a "Resuming…"
/// chip stays up until the guest's next frame, or 0.5 s if the guest does no GPU work (an idle
/// Steam UI draws nothing). The guest's monotonic clock does not see the
/// suspended time (libkrun shifts the virtual counter); its wall clock is set right after the
/// resume from this process's clock (ClockPort → fx-clock-sync.service in the guest), and also
/// when the Mac wakes from sleep while the VM runs (the guest's clock stood still meanwhile).
///
/// Guest sleep (Steam's Power > Sleep and idle auto-sleep, `systemctl suspend`): the guest's
/// systemd-suspend.service asks over `fx.sleep` (SleepPort) instead of suspending its kernel,
/// which nothing in a VM could wake. The VM is paused the same way, but the window stays up
/// with "SteamOS is sleeping"; a click, key, controller button or the Dock icon wakes it (the
/// guest gets `wake <token> <time>`, steps its wall clock and finishes its sleep job). Closing
/// the window while it sleeps follows closeAction (Suspend hides it; Resume later wakes the
/// guest too); a shutdown or restart wakes it first and presses the power key only once the
/// guest's sleep job is over (`awake`), since logind ignores the key while one runs.
final class SuspendController: NSObject, NSMenuDelegate {
    private let ctx: UInt32
    private let clock: ClockPort?
    private let sleepPort: SleepPort?
    private weak var window: WindowController?
    private let presenter: Presenter
    private let stall: StallMonitor
    private let gamePause: GamePause
    /// krun_gpu_get_activity (nil: no counters).
    private let gpuCounters: () -> StallMonitor.Counters?
    var onShutdown: (() -> Void)?
    /// The VM was paused (true: suspend or guest sleep) / runs again (false).
    var onPausedChange: ((Bool) -> Void)?
    /// Window hidden, menu-bar item up (menu Suspend, window close with closeAction suspend).
    private(set) var suspended = false
    /// The guest asked to sleep (`sleep` on fx.sleep): VM paused, "SteamOS is sleeping".
    private(set) var asleep = false
    /// krun_pause'd, for either reason.
    var paused: Bool { suspended || asleep }
    /// The menu-bar item's button and menu (control FIFO `status`).
    var statusButton: NSStatusBarButton? { statusItem?.button }
    var statusMenu: NSMenu? { statusItem?.menu }
    private var pausedAt: Date?
    private var wasCaptured = false
    private var wasFullScreen = false
    private var statusItem: NSStatusItem?
    private var memoryItem: NSMenuItem?
    private var chipTimers: [DispatchWorkItem] = []
    private var workspaceObservers: [NSObjectProtocol] = []
    private var chipShownAt: CFTimeInterval = 0
    /// The guest's sleep request being answered (`sleep <action> <token>`).
    private var sleepToken: String?
    /// Woken, its sleep job not over yet (`awake <token>` pending): actions that need logind.
    private var wakingToken: String?
    private var afterWake: [() -> Void] = []
    /// Longest the "Resuming…" chip waits for a guest frame.
    static let chipTimeout: TimeInterval = 2.5
    private var chipLogText = "Resuming…"
    /// Without GPU work by then the guest is idle (a still Steam UI draws nothing): hide.
    static let chipIdleCheck: TimeInterval = 0.5
    /// After `awake`: logind sees the sleep job end (JobRemoved) before it handles a key again.
    static let awakeSettle: TimeInterval = 1
    /// No `awake` by then (older guest, hooks hanging): run the waiting actions anyway.
    static let awakeTimeout: TimeInterval = 10

    init(ctx: UInt32, clock: ClockPort?, sleepPort: SleepPort?, window: WindowController, presenter: Presenter,
         stall: StallMonitor, gamePause: GamePause, gpuCounters: @escaping () -> StallMonitor.Counters?) {
        self.ctx = ctx
        self.clock = clock
        self.sleepPort = sleepPort
        self.window = window
        self.presenter = presenter
        self.stall = stall
        self.gamePause = gamePause
        self.gpuCounters = gpuCounters
        super.init()
        let nc = NSWorkspace.shared.notificationCenter
        workspaceObservers.append(nc.addObserver(forName: NSWorkspace.willSleepNotification, object: nil, queue: .main) { [weak self] _ in
            self?.hostWillSleep()
        })
        workspaceObservers.append(nc.addObserver(forName: NSWorkspace.didWakeNotification, object: nil, queue: .main) { [weak self] _ in
            self?.hostDidWake(origin: "Mac woke from sleep")
        })
    }

    /// The Mac goes to sleep: no GPU-idle / heartbeat judgement across it (hostDidWake restarts).
    private func hostWillSleep() {
        guard !paused else { return }
        stall.stop()
        log("wake: Mac going to sleep; GPU-idle indicator stopped until it wakes")
    }

    /// The Mac woke from sleep: a running VM gets the host's time (a paused one gets it when it
    /// runs again) and the GPU-idle / heartbeat timers start over (the guest could not run while
    /// the Mac slept). Control FIFO `wake` calls this too.
    func hostDidWake(origin: String) {
        guard !paused else {
            log("wake: VM \(suspended ? "suspended" : "asleep"); the time goes to the guest when it runs again (\(origin))")
            return
        }
        stall.resumeAfterSuspend()
        guard let clock else { return }
        if clock.sendTime() { log("wake: sent the time to the guest (\(origin))") }
        else { log("wake: cannot send the time to the guest (fx.clock)") }
    }

    /// krun_pause with the window's input released, the GPU-idle indicator and game pause off.
    private func pauseVM(_ what: String, origin: String) -> Bool {
        guard let wc = window else { return false }
        wasCaptured = wc.pointerCaptured
        wc.releaseAll()   // key / button releases are queued before the guest stops
        gamePause.vmSuspended = true
        stall.stop()
        let t0 = CACurrentMediaTime()
        let r = krun_pause(ctx)
        guard r == 0 else {
            log("\(what): krun_pause failed: \(r) (\(String(cString: strerror(-r))))")
            gamePause.vmSuspended = false
            stall.resumeAfterSuspend()
            return false
        }
        pausedAt = Date()
        log("\(what): VM paused in \(String(format: "%.1f", (CACurrentMediaTime() - t0) * 1000)) ms (\(origin)); "
            + "\(SuspendController.englishMemoryText() ?? "memory unknown")")
        wc.holdGuestSize = true
        endChip(nil)
        onPausedChange?(true)
        return true
    }

    /// Freeze the VM (unless asleep: already paused) and hide the window. Returns false if it
    /// could not be paused.
    @discardableResult
    func suspend(origin: String) -> Bool {
        guard !suspended, let wc = window else { return false }
        if asleep {
            log("suspend: SteamOS is asleep; window hidden (\(origin))")
        } else {
            guard pauseVM("suspend", origin: origin) else { return false }
        }
        suspended = true
        wasFullScreen = wc.window.styleMask.contains(.fullScreen)
        if wasFullScreen {
            // An ordered-out full-screen window would leave its empty Space behind.
            wc.onDidExitFullScreen = { [weak self, weak wc] in
                guard let self, self.suspended else { return }
                wc?.window.orderOut(nil)
            }
            wc.window.toggleFullScreen(nil)
        } else {
            wc.window.orderOut(nil)
        }
        showStatusItem()
        return true
    }

    /// Show the window (if suspended), wake a sleeping guest and let the VM run again.
    func resume(origin: String) {
        guard paused, let wc = window else { return }
        let seconds = pausedAt.map { Date().timeIntervalSince($0) } ?? 0
        let wasSuspended = suspended
        if suspended {
            if quitPrompt != nil {
                log("quit while suspended: prompt closed, SteamOS resumes (\(origin))")
                closeQuitPrompt()
            }
            removeStatusItem()
            wc.onDidExitFullScreen = nil
        }
        let wakeToken = asleep ? sleepToken : nil
        if asleep {
            asleep = false
            sleepToken = nil
            wc.guestSleeping(false)
        }
        endChip(nil)
        chipLogText = wakeToken != nil ? "Waking up…" : "Resuming…"
        wc.resumeChip.show(wakeToken != nil
            ? String(localized: "Waking up…", comment: "SteamOS is waking from guest sleep")
            : String(localized: "Resuming…", comment: "The whole VM is resuming after an in-memory suspend, not a paused game"))
        chipShownAt = CACurrentMediaTime()
        presenter.onNextFrame = { [weak self] in self?.endChip("first guest frame") }
        // The guest is still frozen: these are the counters it left off with.
        let before = gpuCounters()
        let idle = DispatchWorkItem { [weak self] in
            guard let self else { return }
            let now = self.gpuCounters()
            if before?.ctrl == now?.ctrl && before?.ring == now?.ring { self.endChip("guest GPU idle") }
        }
        let timeout = DispatchWorkItem { [weak self] in self?.endChip("timeout") }
        chipTimers = [idle, timeout]
        DispatchQueue.main.asyncAfter(deadline: .now() + SuspendController.chipIdleCheck, execute: idle)
        DispatchQueue.main.asyncAfter(deadline: .now() + SuspendController.chipTimeout, execute: timeout)
        if wasSuspended {
            wc.show()
            if wasFullScreen && !wc.window.styleMask.contains(.fullScreen) { wc.window.toggleFullScreen(nil) }
        }
        let r = krun_resume(ctx)
        if r != 0 {
            log("resume: krun_resume failed: \(r) (\(String(cString: strerror(-r))))")
        } else if let wakeToken {
            // The guest's sleep command steps the wall clock itself: no fx.clock line (two
            // services stepping by the same difference at once would double it).
            if sleepPort?.sendWake(token: wakeToken) == true { expectAwake(wakeToken) }
            else { log("sleep: cannot send the wake to the guest (fx.sleep)") }
        } else if let clock, !clock.sendTime() {
            log("resume: cannot send the time to the guest (fx.clock)")
        }
        suspended = false
        pausedAt = nil
        wc.holdGuestSize = false
        stall.resumeAfterSuspend()
        gamePause.vmSuspended = false
        if wasCaptured { wc.grabPointer() }
        if wakeToken != nil {
            log("sleep: SteamOS woke after \(String(format: "%.1f", seconds)) s asleep (\(origin))")
        } else {
            log("resume: VM running again after \(String(format: "%.1f", seconds)) s suspended (\(origin))")
        }
        onPausedChange?(false)
    }

    // MARK: Guest sleep

    /// One line from fx.sleep. `allowed` false (shutting down, restarting): answered at once.
    func sleepPortLine(_ line: String, allowed: Bool) {
        let w = line.split(separator: " ").map(String.init)
        switch w.first {
        case "sleep" where w.count >= 3:
            guestRequestedSleep(action: w[1], token: w[2], allowed: allowed)
        case "awake" where w.count >= 2:
            guard w[1] == wakingToken else { return log("sleep: stale \"\(line)\" ignored") }
            log("sleep: the guest finished its sleep job")
            wakingToken = nil
            DispatchQueue.main.asyncAfter(deadline: .now() + SuspendController.awakeSettle) { [weak self] in
                self?.runAfterWake()
            }
        default:
            log("sleep: unknown line \"\(line)\" on fx.sleep")
        }
    }

    private func guestRequestedSleep(action: String, token: String, allowed: Bool) {
        if asleep {
            // A new request while paused cannot happen (no vCPU runs); answer it with the next wake.
            sleepToken = token
            return
        }
        guard allowed, !suspended, let wc = window, pauseVM("sleep", origin: "guest \(action)") else {
            log("sleep: guest asked to \(action); not now, woken at once")
            if sleepPort?.sendWake(token: token) == true { expectAwake(token) }
            return
        }
        asleep = true
        sleepToken = token
        wc.guestSleeping(true)
        log("sleep: SteamOS is sleeping (\(action)); a click, key, controller button or the Dock icon wakes it")
    }

    private func expectAwake(_ token: String) {
        wakingToken = token
        DispatchQueue.main.asyncAfter(deadline: .now() + SuspendController.awakeTimeout) { [weak self] in
            guard let self, self.wakingToken == token else { return }
            log("sleep: no \"awake\" from the guest within \(Int(SuspendController.awakeTimeout)) s")
            self.wakingToken = nil
            self.runAfterWake()
        }
    }

    private func runAfterWake() {
        guard wakingToken == nil, !asleep else { return }
        let actions = afterWake
        afterWake = []
        actions.forEach { $0() }
    }

    /// Run `action` once the guest is fully awake: right away unless it is still finishing a
    /// sleep (logind ignores the power key while the sleep job runs).
    func whenAwake(_ action: @escaping () -> Void) {
        guard wakingToken != nil || asleep else { return action() }
        log("sleep: waiting for the guest to finish waking up")
        afterWake.append(action)
    }

    /// Take the "Resuming…" chip down (`why` nil: without animation or log, e.g. on suspend).
    private func endChip(_ why: String?) {
        chipTimers.forEach { $0.cancel() }
        chipTimers = []
        presenter.onNextFrame = nil
        guard let wc = window else { return }
        guard let why else { return wc.resumeChip.hide(animated: false) }
        wc.resumeChip.hide()
        log("resume: \"\(chipLogText)\" chip hidden after \(Int((CACurrentMediaTime() - chipShownAt) * 1000)) ms (\(why))")
    }

    // MARK: Quit while suspended

    private var quitPrompt: NSAlert?
    private var quitConfirmed: (() -> Void)?

    /// Cmd+Q / Dock Quit while suspended: "SteamOS is suspended" with Shut Down SteamOS / Cancel.
    /// A regular window, not NSAlert.runModal: the main queue keeps running (signals, the
    /// supervisor's reopen, control FIFO), and a resume by any other path closes it.
    func askQuit(onConfirm: @escaping () -> Void) {
        quitConfirmed = onConfirm
        NSApp.activate()
        if let shown = quitPrompt { return shown.window.makeKeyAndOrderFront(nil) }
        let alert = NSAlert()
        alert.messageText = String(localized: "SteamOS is suspended", comment: "The whole VM is frozen in memory, not a paused game")
        alert.informativeText = String(localized: "Quitting FX Steam Launcher shuts SteamOS down: it resumes and shuts down cleanly. The suspended state (and a running game's unsaved progress) is not kept.")
        let shutdown = alert.addButton(withTitle: String(localized: "Shut Down SteamOS"))
        shutdown.target = self
        shutdown.action = #selector(quitPromptShutdown)
        let cancel = alert.addButton(withTitle: String(localized: "Cancel"))
        cancel.target = self
        cancel.action = #selector(quitPromptCancel)
        alert.layout()
        (alert.window as? NSPanel)?.hidesOnDeactivate = false
        alert.window.center()
        alert.window.makeKeyAndOrderFront(nil)
        quitPrompt = alert
        log("quit while suspended: asking (Shut Down SteamOS / Cancel)")
    }

    private func closeQuitPrompt() {
        quitPrompt?.window.orderOut(nil)
        quitPrompt = nil
        quitConfirmed = nil
    }

    @objc private func quitPromptShutdown() {
        let confirmed = quitConfirmed
        closeQuitPrompt()
        log("quit while suspended: shutting SteamOS down")
        confirmed?()
    }

    @objc private func quitPromptCancel() {
        closeQuitPrompt()
        log("quit while suspended: cancelled; SteamOS stays suspended")
    }

    /// Control FIFO `quit-prompt shutdown|cancel|dump PATH`: press a button / PNG of the prompt.
    func controlQuitPrompt(_ args: [String]) {
        guard let alert = quitPrompt else { return log("control: no quit prompt open") }
        switch args.first {
        case "shutdown": alert.buttons[0].performClick(nil)
        case "cancel": alert.buttons[1].performClick(nil)
        case "dump":
            let path = args.dropFirst().first ?? "quit-prompt.png"
            guard let view = alert.window.contentView?.superview ?? alert.window.contentView,
                  let rep = view.bitmapImageRepForCachingDisplay(in: view.bounds) else { return }
            view.cacheDisplay(in: view.bounds, to: rep)
            if let png = rep.representation(using: .png, properties: [:]), (try? png.write(to: URL(fileURLWithPath: path))) != nil {
                log("control: quit prompt dumped to \(path) (window \(alert.window.windowNumber), visible \(alert.window.isVisible))")
            }
        default: log("control: quit-prompt shutdown|cancel|dump PATH")
        }
    }

    // MARK: menu-bar item

    private func showStatusItem() {
        let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        if let button = item.button {
            let image = NSImage(systemSymbolName: "pause.circle", accessibilityDescription: String(localized: "SteamOS suspended", comment: "The whole VM is frozen in memory, not a paused game"))
            image?.isTemplate = true
            button.image = image
            button.toolTip = String(localized: "SteamOS suspended — FX Steam Launcher")
        }
        let menu = NSMenu()
        menu.delegate = self
        menu.autoenablesItems = false
        let title = NSMenuItem(title: String(localized: "SteamOS suspended", comment: "The whole VM is frozen in memory, not a paused game"), action: nil, keyEquivalent: "")
        title.identifier = NSUserInterfaceItemIdentifier("SteamOS suspended")
        title.isEnabled = false
        menu.addItem(title)
        let memory = NSMenuItem(title: "", action: nil, keyEquivalent: "")
        memory.identifier = NSUserInterfaceItemIdentifier("")
        memory.isEnabled = false
        menu.addItem(memory)
        memoryItem = memory
        menu.addItem(.separator())
        let resume = NSMenuItem(title: String(localized: "Resume", comment: "Status menu: resume the whole VM after an in-memory suspend, not a paused game"), action: #selector(menuResume), keyEquivalent: "")
        resume.identifier = NSUserInterfaceItemIdentifier("Resume")
        resume.target = self
        menu.addItem(resume)
        let shutdown = NSMenuItem(title: String(localized: "Shut Down SteamOS"), action: #selector(menuShutdown), keyEquivalent: "")
        shutdown.identifier = NSUserInterfaceItemIdentifier("Shut Down SteamOS")
        shutdown.target = self
        menu.addItem(shutdown)
        menu.addItem(.separator())
        let note = NSMenuItem(title: "", action: nil, keyEquivalent: "")
        note.identifier = NSUserInterfaceItemIdentifier("Suspended state is kept while FX Steam Launcher is running.")
        note.attributedTitle = NSAttributedString(
            string: String(localized: "Suspended state is kept while FX Steam Launcher is running."),
            attributes: [.font: NSFont.menuFont(ofSize: NSFont.smallSystemFontSize), .foregroundColor: NSColor.secondaryLabelColor])
        note.isEnabled = false
        menu.addItem(note)
        item.menu = menu
        statusItem = item
        updateMemoryItem()
    }

    private func removeStatusItem() {
        if let statusItem { NSStatusBar.system.removeStatusItem(statusItem) }
        statusItem = nil
        memoryItem = nil
    }

    private func updateMemoryItem() {
        let since = pausedAt.map { DateFormatter.localizedString(from: $0, dateStyle: .none, timeStyle: .short) } ?? "?"
        let memory = SuspendController.memoryText() ?? String(localized: "memory unknown")
        memoryItem?.title = String(localized: "Since \(since) · \(memory)")
    }

    func menuWillOpen(_ menu: NSMenu) { updateMemoryItem() }

    @objc private func menuResume() { resume(origin: "menu bar") }
    @objc private func menuShutdown() { onShutdown?() }

    /// Control FIFO `status dump PATH`: the menu's items (logged) and the menu-bar button (PNG).
    func dumpStatusItem(to path: String) {
        guard let item = statusItem else { return log("control: no menu-bar item (not suspended)") }
        updateMemoryItem()
        let titles = item.menu?.items.map { i -> String in
            if i.isSeparatorItem { return "—" }
            let title = i === memoryItem
                ? "Since \(pausedAt.map { ISO8601DateFormatter().string(from: $0) } ?? "?") · \(SuspendController.englishMemoryText() ?? "memory unknown")"
                : i.identifier?.rawValue ?? ""
            return title + (i.isEnabled ? "" : " (disabled)")
        } ?? []
        log("control: menu-bar item: SteamOS suspended — FX Steam Launcher — menu: " + titles.joined(separator: " | "))
        guard let button = item.button, let rep = button.bitmapImageRepForCachingDisplay(in: button.bounds) else { return }
        button.cacheDisplay(in: button.bounds, to: rep)
        if let png = rep.representation(using: .png, properties: [:]), (try? png.write(to: URL(fileURLWithPath: path))) != nil {
            log("control: menu-bar button dumped to \(path)")
        }
    }

    /// "12.4 GB of memory in use" (this process's physical footprint: guest RAM touched so
    /// far plus the host GPU state).
    static func memoryText() -> String? {
        guard let bytes = footprint() else { return nil }
        let size = ByteCountFormatter.string(fromByteCount: Int64(bytes), countStyle: .memory)
        return String(localized: "\(size) of memory in use")
    }

    private static func englishMemoryText() -> String? {
        footprint().map { "\($0) bytes of memory in use" }
    }

    static func footprint() -> UInt64? {
        var info = task_vm_info_data_t()
        var count = mach_msg_type_number_t(MemoryLayout<task_vm_info_data_t>.size / MemoryLayout<integer_t>.size)
        let kr = withUnsafeMutablePointer(to: &info) {
            $0.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
                task_info(mach_task_self_, task_flavor_t(TASK_VM_INFO), $0, &count)
            }
        }
        return kr == KERN_SUCCESS ? info.phys_footprint : nil
    }
}

/// The `fx.clock` virtio-console port (host → guest only): `time <unix_ns>` after every resume
/// and every Mac wake while the VM runs.
/// The guest's root service fx-clock-sync (guest/progress-agent/src/clock.rs) steps its wall
/// clock forward to it; the monotonic clock keeps hiding the suspended time.
final class ClockPort {
    static let name = "fx.clock"
    /// Handed to libkrun: host → guest data is read from here.
    let guestInputFd: Int32
    /// Handed to libkrun: the guest never writes; /dev/null.
    let guestOutputFd: Int32
    private let writeFd: Int32

    init() throws {
        var p: [Int32] = [0, 0]
        guard pipe(&p) == 0 else { throw OptionError("pipe: \(String(cString: strerror(errno)))") }
        guestInputFd = p[0]; writeFd = p[1]
        guestOutputFd = open("/dev/null", O_WRONLY | O_CLOEXEC)
        guard guestOutputFd >= 0 else { throw OptionError("/dev/null: \(String(cString: strerror(errno)))") }
        for fd in p { _ = fcntl(fd, F_SETFD, FD_CLOEXEC) }
        // Never block the main thread if the guest does not read (no service, older layer).
        _ = fcntl(writeFd, F_SETFL, fcntl(writeFd, F_GETFL) | O_NONBLOCK)
    }

    /// This process's wall clock, taken right before the write; false if the pipe did not take it.
    func sendTime() -> Bool {
        ClockPort.write(writeFd, "time \(ClockPort.nowNs())")
    }

    /// CLOCK_REALTIME in unix ns.
    static func nowNs() -> Int64 {
        var ts = timespec()
        clock_gettime(CLOCK_REALTIME, &ts)
        return Int64(ts.tv_sec) * 1_000_000_000 + Int64(ts.tv_nsec)
    }

    /// One line to a non-blocking pipe; false if it did not take it whole.
    static func write(_ fd: Int32, _ line: String) -> Bool {
        let bytes = Array((line + "\n").utf8)
        var n: Int
        repeat { n = Darwin.write(fd, bytes, bytes.count) } while n < 0 && errno == EINTR
        return n == bytes.count
    }
}

/// The `fx.sleep` virtio-console port, opened by the guest's systemd-suspend.service
/// (`fx-progress-agent sleep`, guest/progress-agent/src/sleep.rs) instead of a kernel suspend:
///   guest → host  `sleep <action> <token>`   SteamOS goes to sleep: pause the VM
///                 `awake <token>`            its sleep job is over (post-sleep hooks ran)
///   host → guest  `wake <token> <unix_ns>`   the VM runs again; the guest steps its wall clock
final class SleepPort {
    static let name = "fx.sleep"
    /// Handed to libkrun: guest → host data is written here.
    let guestOutputFd: Int32
    /// Handed to libkrun: host → guest data is read from here.
    let guestInputFd: Int32
    private let readFd: Int32
    private let writeFd: Int32

    init() throws {
        var out: [Int32] = [0, 0], inp: [Int32] = [0, 0]
        guard pipe(&out) == 0, pipe(&inp) == 0 else { throw OptionError("pipe: \(String(cString: strerror(errno)))") }
        readFd = out[0]; guestOutputFd = out[1]
        guestInputFd = inp[0]; writeFd = inp[1]
        for fd in out + inp { _ = fcntl(fd, F_SETFD, FD_CLOEXEC) }
        _ = fcntl(writeFd, F_SETFL, fcntl(writeFd, F_GETFL) | O_NONBLOCK)
    }

    /// `wake <token> <now>`, the wall clock taken right before the write.
    func sendWake(token: String) -> Bool {
        ClockPort.write(writeFd, "wake \(token) \(ClockPort.nowNs())")
    }

    /// Reader thread: every complete line goes to `handler` on the main queue.
    func start(_ handler: @escaping (String) -> Void) {
        let t = Thread { [readFd] in
            var splitter = LineSplitter()
            var buf = [UInt8](repeating: 0, count: 512)
            while true {
                let n = Darwin.read(readFd, &buf, buf.count)
                if n < 0 && errno == EINTR { continue }
                if n <= 0 { break }
                buf.withUnsafeBytes { p in
                    splitter.feed(UnsafeRawBufferPointer(rebasing: p[0..<n])) { line in
                        let line = line.trimmingCharacters(in: .whitespacesAndNewlines)
                        if !line.isEmpty { DispatchQueue.main.async { handler(line) } }
                    }
                }
            }
        }
        t.name = "fx.sleep"
        t.start()
    }
}

/// "Resuming…" ("Waking up…" after a guest sleep) chip at the top of the VM picture (FX overlay
/// style), from Resume until the guest's next frame (0.5 s while the guest's GPU is idle, 2.5 s
/// at most).
final class ResumeChipView: NSView {
    private let chip = CALayer()
    private let dot = CALayer()
    private let label = CATextLayer()
    private(set) var shown = false
    private(set) var text = String(localized: "Resuming…", comment: "The whole VM is resuming after an in-memory suspend, not a paused game")

    override init(frame: NSRect) {
        super.init(frame: frame)
        wantsLayer = true
        layer = CALayer()
        autoresizingMask = [.width, .height]
        chip.backgroundColor = OverlayView.color(0x171a21, 0.88)
        chip.borderColor = OverlayView.color(0x66c0f4, 0.22)
        chip.borderWidth = 1
        dot.backgroundColor = OverlayView.color(0x66c0f4)
        label.alignmentMode = .left
        label.truncationMode = .end
        chip.addSublayer(dot)
        chip.addSublayer(label)
        layer!.addSublayer(chip)
        alphaValue = 0
        isHidden = true
    }

    required init?(coder: NSCoder) { fatalError() }

    override func hitTest(_ point: NSPoint) -> NSView? { nil }
    override var isOpaque: Bool { false }

    func show(_ text: String) {
        self.text = text
        shown = true
        isHidden = false
        needsLayout = true
        layoutSubtreeIfNeeded()
        alphaValue = 1
        let pulse = CABasicAnimation(keyPath: "opacity")
        pulse.fromValue = 1
        pulse.toValue = 0.25
        pulse.duration = 0.6
        pulse.autoreverses = true
        pulse.repeatCount = .infinity
        dot.add(pulse, forKey: "pulse")
    }

    func hide(animated: Bool = true) {
        guard shown else { return }
        shown = false
        let done = { [weak self] in
            guard let self, !self.shown else { return }
            self.isHidden = true
            self.dot.removeAllAnimations()
        }
        guard animated else {
            alphaValue = 0
            done()
            return
        }
        NSAnimationContext.runAnimationGroup({ ctx in
            ctx.duration = 0.25
            animator().alphaValue = 0
        }, completionHandler: done)
    }

    override func viewDidChangeBackingProperties() {
        super.viewDidChangeBackingProperties()
        needsLayout = true
    }

    override func setFrameSize(_ newSize: NSSize) {
        super.setFrameSize(newSize)
        needsLayout = true
    }

    override func layout() {
        super.layout()
        let s = max(0.85, min(1.6, min(bounds.width / 1280, bounds.height / 800)))
        let text = NSAttributedString(string: self.text, attributes: [
            .font: NSFont.systemFont(ofSize: 13 * s, weight: .medium),
            .foregroundColor: OverlayView.color(0xc7d5e0)])
        let size = text.size()
        let padX = 14 * s, dotD = 8 * s, gap = 8 * s, h = ceil(size.height) + 12 * s
        let w = padX + dotD + gap + ceil(size.width) + padX
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        chip.frame = CGRect(x: (bounds.width - w) / 2, y: bounds.height - h - 18 * s, width: w, height: h)
        chip.cornerRadius = h / 2
        dot.frame = CGRect(x: padX, y: (h - dotD) / 2, width: dotD, height: dotD)
        dot.cornerRadius = dotD / 2
        label.string = text
        label.contentsScale = window?.backingScaleFactor ?? 2
        label.frame = CGRect(x: padX + dotD + gap, y: (h - ceil(size.height)) / 2, width: ceil(size.width) + 2, height: ceil(size.height))
        CATransaction.commit()
    }
}
