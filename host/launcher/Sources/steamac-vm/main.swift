import AppKit
import CKrun
import Darwin
import Foundation

// Both processes: a write to a closed pipe or socket fails with EPIPE instead of killing the
// process (STEAMAC-10: the VM process died in log() once the supervisor's stderr tap was gone,
// in the middle of the guest's shutdown). Before CrashReporting.setUp: Sentry's crash handler
// leaves an ignored SIGPIPE alone. The VM process gets it ignored from the supervisor too.
signal(SIGPIPE, SIG_IGN)

// Finder / `open` launch of the .app: console + launcher log go to ~/Library/Logs/es.fxgam.steamac.
if !Supervisor.isChild { AppBundle.redirectOutputIfLaunchedFromFinder() }

let settings = LauncherSettings.shared
var options: Options
var settingsOverrides: [LauncherSettings.Key: String]
do {
    (options, settingsOverrides) = try Options.resolve(CommandLine.arguments, settings: settings)
} catch {
    FileHandle.standardError.write("steamac-vm: \(error)\n\n\(Options.usage)\n".data(using: .utf8)!)
    MainActor.assumeIsolated { AppBundle.alertIfLaunchedFromFinder("FX Steam Launcher cannot start", "\(error)") }
    exit(2)
}

if options.selftestMetalCache { MetalCompilerCache.selfTest() }
// Before CrashReporting's GPU tags, the window or either Vulkan driver can initialise Metal.
MetalCompilerCache.prepare()

// MoltenVK (loaded by virglrenderer in this process) logs every instance/device creation at info
// level, which buries the guest console. Errors only, unless the user asks for more.
setenv("MVK_CONFIG_LOG_LEVEL", "1", 0)
// Metal Performance HUD (Settings > Display, View menu, Ctrl+Cmd+P): loads libMTLHud for this VM
// process before Metal is first used; the window's layer then shows or hides it at runtime
// (developerHUDProperties `mode`, default "off" in WindowController). Without this variable
// macOS 15 ignores those properties. Command buffers that present nothing (MoltenVK's) get no HUD.
if Supervisor.isChild && !options.headless { setenv("MTL_HUD_ENABLED", "1", 1) }

// Crash reporting (Settings > General; both the supervisor and each VM process).
CrashReporting.setUp(options: options, settings: settings)
CrashReporting.runTests(&options)

if options.selftestDisplay { SelfTest.run(options) }
if options.selftestOverlay { OverlaySelfTest.run(options) }
if options.selftestStall { StallSelfTest.run(options) }
if options.selftestPill { PillSelfTest.run(options) }
if options.selftestSettings { SettingsSelfTest.run(options, overrides: settingsOverrides) }
if options.selftestProvision { ProvisionSelfTest.run(options) }
if options.selftestRemotePlay { RemotePlaySelfTest.run() }
if options.createDisk != nil { CreateDiskCLI.run(options, settings: settings) }
if let disk = options.growDisk {
    do {
        guard options.explicit.contains("--home-gib") else { throw OptionError("--grow-disk requires --home-gib N") }
        try DiskGrower.grow(DiskGrower.request(path: disk, homeGiB: options.createHomeGiB))
        print("Disk enlarged. Start SteamOS to grow home to \(options.createHomeGiB) GiB.")
        exit(0)
    } catch {
        FileHandle.standardError.write("grow-disk: \(error)\n".data(using: .utf8)!)
        exit(1)
    }
}
if let disk = options.showSSHPassword {
    guard let id = GuestPassword.identity(ofDisk: disk) else { fatal("\(disk): not a GPT disk image") }
    guard let state = GuestPassword.state(disk: id), let pw = GuestPassword.password(disk: id) else {
        fatal("no generated SSH password for \(disk) (disk \(id)); enable SSH in Settings > Advanced")
    }
    print("user \(GuestPassword.user)\npassword \(pw)\nstate \(state.rawValue)\ndisk \(id)")
    exit(0)
}
// The process the user runs supervises one VM process per boot (see Supervisor); it re-reads
// the settings before every boot.
if !Supervisor.isChild {
    Supervisor.run { try Options.resolve(CommandLine.arguments, settings: LauncherSettings()).0 }
}
if options.needsDisk { FirstRun.run(settings: settings) }
settings.noteBoot(overrides: settingsOverrides, autoCapture: options.autoCapture)

// After a guest reboot, boot at the size the window had (the guest display followed it).
if let f = Supervisor.windowFrame, !f.isEmpty, !options.headless {
    let content = NSWindow.contentRect(forFrameRect: NSRectFromString(f), styleMask: [.titled, .closable, .miniaturizable, .resizable])
    let maxSide = VM.maxDisplaySide & ~1
    options.displayWidth = min(maxSide, max(Int(WindowController.minGuestSize.width), Int(content.width) & ~1))
    options.displayHeight = min(maxSide, max(Int(WindowController.minGuestSize.height), Int(content.height) & ~1))
}

// MARK: VM process (one boot)

let windowTitle = "FX Steam Launcher"

/// Graceful shutdown policy shared by window close, menu, signals and the console escape; window
/// close / menu Suspend / Dock click / Quit while suspended (SuspendController).
final class Lifecycle: NSObject, NSApplicationDelegate {
    /// Restored on our own exit() paths (libkrun's _exit skips atexit; the supervisor restores then).
    nonisolated(unsafe) static var console: Console?
    var vm: VM?
    var progress: BootProgress?
    weak var window: WindowController?
    var settingsWindow: SettingsWindowController?
    var settingsContext: SettingsContext?
    var suspender: SuspendController?
    /// Opens Report a Problem over the VM window.
    var report: (() -> Void)?
    private var requestedAt: Date?
    /// SteamOS can take ~2 min to stop (systemd stop-job timeouts) before libkrun exits.
    static let gracePeriod: TimeInterval = 180

    /// Force quit: no relaunch even if a restart was pending.
    private func forceQuit() -> Never {
        log("force quit")
        if let dir = Supervisor.runDir { try? FileManager.default.removeItem(atPath: Supervisor.rebootMarker(dir)) }
        exit(1)
    }

    func requestShutdown(force: Bool = false) {
        CrashReporting.noteUserExit()
        if let at = requestedAt {
            // A terminal ^C reaches both the supervisor and us; its forwarded copy is not a second request.
            if !force && Date().timeIntervalSince(at) < 1 { return }
            forceQuit()
        }
        if force { forceQuit() }
        requestedAt = Date()
        // A paused guest cannot see the power key: let it run (window back, shutdown overlay). One
        // that slept finishes its sleep job first (logind ignores the key while that runs).
        suspender?.resume(origin: "shutdown")
        let pressPowerKey = { [weak self] in
            guard let vm = self?.vm, vm.requestShutdown() else {
                log("no guest power key available; exiting")
                exit(0)
            }
            log("power key sent to guest; repeat the request to force quit")
        }
        progress?.hostRequestedShutdown()
        window?.setStatus("shutting down… (close again to force quit)")
        startGraceTimer()
        if let suspender { suspender.whenAwake(pressPowerKey) } else { pressPowerKey() }
    }

    /// The supervisor is gone (killed; gvproxy went with it): shut the guest down cleanly. Never a
    /// force quit: exiting cuts a shutdown already under way short (the guest's disk), so that one
    /// just continues.
    func supervisorExited() {
        guard requestedAt == nil else {
            log("launcher supervisor exited; the guest's shutdown continues")
            return
        }
        log("launcher supervisor exited; shutting the guest down")
        requestShutdown()
    }

    /// "Restart VM" (menu / Settings): power the guest off cleanly, then the supervisor boots it
    /// again with the current settings.
    func requestRestart() {
        CrashReporting.noteUserExit()
        guard requestedAt == nil, let vm, let progress else { return }
        requestedAt = Date()
        suspender?.resume(origin: "restart")
        progress.hostRequestedRestart()   // onRebootIntent writes the supervisor's reboot marker
        settingsContext?.restartRequested = true
        window?.setStatus("restarting… (close to force quit)")
        startGraceTimer()
        let pressPowerKey = {
            guard vm.requestShutdown() else {
                log("no guest power key available; restarting the VM process")
                exit(0)
            }
            log("restart: power key sent to guest; the VM starts again once it is off")
        }
        if let suspender { suspender.whenAwake(pressPowerKey) } else { pressPowerKey() }
    }

    private func startGraceTimer() {
        DispatchQueue.main.asyncAfter(deadline: .now() + Lifecycle.gracePeriod) {
            log("guest did not power off within \(Int(Lifecycle.gracePeriod)) s; forcing exit")
            exit(1)
        }
    }

    /// Window close button / Cmd+W: Settings > General "When closing the window" (also while
    /// SteamOS sleeps: Suspend hides the window, Shut Down wakes it to power off). Closing again
    /// while SteamOS shuts down force-quits (requestShutdown).
    func windowCloseRequested() {
        if requestedAt == nil, LauncherSettings.shared.closeAction == .suspend, suspend(origin: "window close") { return }
        requestShutdown()
    }

    /// The VM may be paused (suspend, guest sleep): not while SteamOS shuts down or restarts (it
    /// must run to finish).
    var canPause: Bool {
        requestedAt == nil && (progress.map { if case .shutdown = $0.state.phase { return false } else { return true } } ?? true)
    }

    @discardableResult
    func suspend(origin: String) -> Bool {
        guard canPause, let suspender else { return false }
        return suspender.suspend(origin: origin)
    }

    /// Dock icon click / opening the app again: resume a suspended VM (its window comes back
    /// with it), wake a sleeping one (AppKit's default then brings a minimized window back).
    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        guard let suspender, suspender.paused else { return true }
        let hidden = suspender.suspended
        suspender.resume(origin: "reopen: Dock icon or opening the app")
        return !hidden
    }

    /// Dock "Quit" / Cmd+Q / logout: shut the guest down instead of killing it. While suspended
    /// a user's Quit asks first (the suspended state is lost; SuspendController.askQuit, answered
    /// later without a modal loop); logout / restart / shutdown of the Mac does not.
    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        if requestedAt == nil, let suspender, suspender.suspended, !Lifecycle.quitBySystem {
            suspender.askQuit { [weak self] in self?.requestShutdown() }
            return .terminateCancel
        }
        requestShutdown()
        return .terminateCancel
    }

    /// The quit Apple event comes from a logout, restart or shutdown of the Mac.
    private static var quitBySystem: Bool {
        guard let event = NSAppleEventManager.shared().currentAppleEvent,
              let reason = event.attributeDescriptor(forKeyword: AEKeyword(kAEQuitReason))?.enumCodeValue else { return false }
        return [kAELogOut, kAEReallyLogOut, kAEShowRestartDialog, kAEShowShutdownDialog, kAERestart, kAEShutDown]
            .map { OSType($0) }.contains(reason)
    }

    @objc func menuSuspend() {
        if let suspender, suspender.suspended { suspender.resume(origin: "menu") } else { suspend(origin: "menu") }
    }
    @objc func menuShutdown() { requestShutdown() }
    @objc func menuRestart() { requestRestart() }
    @objc func menuForceQuit() { requestShutdown(force: true) }
    @objc func menuFullscreen() { window?.window.toggleFullScreen(nil) }
    @objc func menuGrab() { window?.grabPointer() }
    @objc func menuOverlay() { window?.toggleOverlay() }
    @objc func menuMetalHUD() { window?.toggleMetalHUD() }
    @objc func menuSettings() { settingsWindow?.show() }
    @objc func menuReport() { report?() }
    @objc func menuCheckForUpdates() { UpdateChecker.shared.menuAction() }
}

extension Lifecycle: NSMenuItemValidation {
    func validateMenuItem(_ item: NSMenuItem) -> Bool {
        if item.action == #selector(menuMetalHUD) { item.state = LauncherSettings.shared.metalHUD ? .on : .off }
        if item.action == #selector(menuCheckForUpdates) {
            item.title = UpdateChecker.shared.menuTitle
            item.badge = UpdateChecker.shared.available != nil ? NSMenuItemBadge(string: "New") : nil
        }
        if item.action == #selector(menuSuspend) {
            let suspended = suspender?.suspended ?? false
            item.title = tr(suspended ? "Resume" : "Suspend")
            return suspender != nil && requestedAt == nil
        }
        return true
    }
}

let lifecycle = Lifecycle()
let display = DisplayBackend()
var signalSources: [DispatchSourceSignal] = []

func onSignal(_ sig: Int32, _ handler: @escaping () -> Void) {
    signal(sig, SIG_IGN)
    let s = DispatchSource.makeSignalSource(signal: sig, queue: .main)
    s.setEventHandler(handler: handler)
    s.resume()
    signalSources.append(s)
}

do {
    let console = try Console(logPath: options.logFile)
    console.onEscape = { force in DispatchQueue.main.async { lifecycle.requestShutdown(force: force) } }
    atexit { Lifecycle.console?.restoreTerminal() }
    Lifecycle.console = console

    let progress = BootProgress(restarting: Supervisor.bootNumber > 1)
    lifecycle.progress = progress
    // Session console log for Report a Problem (run dir, removed when the launcher exits).
    if let dir = Supervisor.runDir { RollingLog.console.open(dir: dir) }
    console.onLine = { line in
        RollingLog.console.append(BootProgress.stripANSI(line))
        progress.consoleLine(line)
        CrashReporting.consoleLine(line)
    }
    let progressPort = try ProgressPort()
    // Log bundles requested by Report a Problem arrive on the same port.
    let guestLogs = GuestLogs(port: progressPort)
    progressPort.start { line in if !guestLogs.handle(line) { progress.guestLine(line) } }
    progress.onRebootIntent = {
        // Tell the supervisor to boot again once libkrun exits; remember where the window was
        // (unless Settings changed the default window size: then the next boot opens at that).
        guard let dir = Supervisor.runDir else { return }
        let frame = settings.windowSizeChanged ? "" : (lifecycle.window.map { NSStringFromRect($0.window.frame) } ?? "")
        FileManager.default.createFile(atPath: Supervisor.rebootMarker(dir), contents: Data(frame.utf8))
        log("guest is rebooting: the VM will be restarted")
    }
    progress.onGameName = { id, name in settings.setGameName(name, for: id) }
    // `appid` tag of crash/error reports (the window and GamePause chain their handlers after this).
    progress.onFocus = { CrashReporting.focusedGame($0) }
    progress.onProvision = { ok, reason in Provision.finished(ok: ok, reason: reason, payload: options.provisionPayload) }
    if let p = options.provisionPayload { log("provision: first boot of this disk: payload \(p) attached read-only, \(Provision.cmdlineFlag)") }
    progress.onConfig = { ok, reason in Provision.configFinished(ok: ok, reason: reason, payload: options.configPayload) }
    if let c = options.configPayload { log("config: new SteamOS password pending: \(c.path) attached read-only, \(Provision.configFlag)") }

    var inputs: VMInputs?
    if !options.headless {
        inputs = VMInputs(keyboard: InputDevices.keyboard(), tablet: InputDevices.tablet(), mouse: InputDevices.mouse())
    }

    let clockPort = try ClockPort()
    // Guest sleep needs the window (overlay, wake input): headless, the guest's sleep fails instead.
    let sleepPort = options.headless ? nil : try SleepPort()
    // The guest's gamepad follows the Mac's controller (GamepadBridge): needs the window too.
    let padPort = options.headless || !options.gamepad ? nil : try PadPort()
    // Clipboard sharing follows the app's activation (ClipboardSync): window only.
    let clipboardPort = options.headless ? nil : try ClipboardPort()
    let vm = try VM(options: options, display: display, console: console, progressPort: progressPort,
                    clockPort: clockPort, sleepPort: sleepPort, padPort: padPort, clipboardPort: clipboardPort,
                    inputs: inputs, netSocket: Supervisor.netSocket)
    lifecycle.vm = vm
    let gamepad = padPort.map { GamepadBridge(port: $0, settings: settings, typeOverride: options.padType) }
    let sound = SoundControl()
    if vm.hasSound {
        sound.attach(ctx: vm.ctx, settings: settings)
        if let missing = sound.missingAPIReason { log("sound: live controls unavailable: \(missing)") }
    } else {
        sound.detach(reason: options.sound ? "This libkrun has no sound support (SND=1)." : "Sound was off when this VM started.")
    }

    for sig in [SIGINT, SIGTERM, SIGHUP] {
        onSignal(sig) { lifecycle.requestShutdown() }
    }
    // SIGUSR1: dump the guest's last frame (and, with a window, what the window shows:
    // <name>-window.png = Metal drawable, <name>-overlay.png = drawable + overlay at 2x,
    // <name>-screen.png = the window as composited on screen, Metal Performance HUD included).
    var windowController: WindowController?
    func dumpFrames(to path: String, done: (() -> Void)? = nil) {
        do {
            try display.dumpPNG(to: path)
            log("frame dumped to \(path)")
        } catch {
            log("frame dump failed: \(error)")
        }
        guard let wc = windowController else { done?(); return }
        let base = (path as NSString).deletingPathExtension
        if let screen = wc.windowServerImage() {
            do { try PNG.write(screen, to: base + "-screen.png") } catch { log("window screen dump failed: \(error)") }
        }
        wc.captureWindow { drawable, composite in
            do {
                if let drawable { try PNG.write(drawable, to: base + "-window.png") }
                if let composite { try PNG.write(composite, to: base + "-overlay.png") }
                log("window dumped to \(base)-window.png, \(base)-overlay.png, \(base)-screen.png"
                    + " (overlay \(wc.overlay.shown ? "shown" : "hidden"), pill "
                    + (wc.pill.shown ? "\"\(wc.pill.content.title)\" / \"\(wc.pill.content.detail)\" \(wc.pill.content.percentText)" : "hidden")
                    + ", title \"\(wc.window.title)\", Metal HUD \(settings.metalHUD ? "on" : "off")"
                    + ", MetalFX super resolution \(settings.superResolution ? "on" : "off"))")
            } catch {
                log("window dump failed: \(error)")
            }
            done?()
        }
    }
    onSignal(SIGUSR1) { dumpFrames(to: options.frameDumpPath) }
    // If the supervisor dies (e.g. SIGKILL), gvproxy goes with it: shut the guest down cleanly
    // instead of leaving an orphaned VM without networking.
    let supervisorWatch = DispatchSource.makeProcessSource(identifier: getppid(), eventMask: .exit, queue: .main)
    supervisorWatch.setEventHandler { lifecycle.supervisorExited() }
    supervisorWatch.resume()

    log("booting \(options.kernel) cpus=\(options.cpus) mem=\(options.memMiB)MiB display=\(options.guestSize.0)x\(options.guestSize.1)"
        + " cmdline=\"\(options.cmdline)\"" + (Supervisor.bootNumber > 1 ? " (boot #\(Supervisor.bootNumber))" : ""))
    log("vm size: " + VMSizing.describe(cpus: options.cpus, cpusSource: options.cpusSource,
                                        memMiB: options.memMiB, memSource: options.memSource,
                                        gpuMiB: options.gpuBudgetMiB))
    PerfStats.setEnabled(options.perfStats)
    // Settings > General toggles the stats live unless --perf-stats / STEAMAC_PERF_STATS fixed them.
    let perfSubscription = settings.$perfStats.dropFirst().sink { on in
        if settingsOverrides[.perfStats] == nil { DispatchQueue.main.async { PerfStats.setEnabled(on) } }
    }

    if options.headless {
        console.start()
        vm.start()
        dispatchMain()
    }

    let app = SteamacApplication.shared as! SteamacApplication
    app.setActivationPolicy(.regular)
    // Keeps the Mac awake while the VM runs (not while it is suspended: SuspendController).
    func beginVMActivity() -> NSObjectProtocol {
        ProcessInfo.processInfo.beginActivity(
            options: [.userInitiated, .latencyCritical, .idleSystemSleepDisabled], reason: "virtual machine running")
    }
    var activity: NSObjectProtocol? = beginVMActivity()
    app.delegate = lifecycle
    let renderer = Renderer()
    let presenter = Presenter(display: display, renderer: renderer)
    let wc = WindowController(title: windowTitle, width: options.displayWidth, height: options.displayHeight,
                              pixelScale: options.pixelScale, renderer: renderer, inputs: inputs, mouseMode: options.mouseMode)
    if let f = Supervisor.windowFrame, !f.isEmpty { wc.window.setFrame(NSRectFromString(f), display: false) }
    presenter.view = wc.view
    PerfStats.instance.attach(view: wc.view)
    wc.view.metalLayer.framebufferOnly = false   // SIGUSR1 can read back the presented drawable
    windowController = wc
    presenter.onScanoutResize = { [weak wc] w, h in wc?.scanoutResized(width: w, height: h) }
    display.sink = presenter
    app.router = wc
    lifecycle.window = wc
    wc.onCloseRequest = { lifecycle.windowCloseRequested() }
    wc.onSuspendRequest = { lifecycle.menuSuspend() }
    wc.attach(progress: progress)
    let ctxId = vm.ctx
    let gpuCounters: () -> StallMonitor.Counters? = {
        var ctrl: UInt64 = 0, ring: UInt64 = 0
        let r = krun_gpu_get_activity(ctxId, &ctrl, &ring)
        return r == 0 || r == -ENOTSUP ? (ctrl, ring) : nil
    }
    let stall = StallMonitor(view: wc.stallView, sample: gpuCounters)
    stall.onNotResponding = { CrashReporting.stallNotResponding(seconds: $0) }
    wc.attach(stall: stall)
    // After `ready`: "Waiting for SteamOS to draw…" when the window shows no / a black picture.
    let noPicture = NoPictureGuard { presenter.scanout.probe(sampleIfNewerThan: $0) }
    wc.attach(noPicture: noPicture)
    // Settings > General "Pause the game" in the background; no GPU-idle card while frozen.
    let gamePause = GamePause(settings: settings, progress: progress) { progressPort.send($0) }
    gamePause.onChange = { stall.paused = $0 }
    gamePause.onConfirmedChange = { [weak wc] in wc?.gamePaused($0) }
    // Settings > General "Share clipboard with SteamOS" (fx.clipboard).
    let clipboard = clipboardPort.map { ClipboardSync(port: $0, settings: settings) }
    let suspender = SuspendController(ctx: vm.ctx, clock: clockPort, sleepPort: sleepPort, window: wc, presenter: presenter,
                                      stall: stall, gamePause: gamePause, gpuCounters: gpuCounters)
    suspender.onShutdown = { lifecycle.requestShutdown() }
    // Suspended or asleep: the Mac may sleep.
    suspender.onPausedChange = { paused in
        noPicture.vmPaused = paused
        gamepad?.vmPaused(paused)
        clipboard?.vmPaused = paused
        if paused {
            activity.map(ProcessInfo.processInfo.endActivity)
            activity = nil
        } else if activity == nil {
            activity = beginVMActivity()
        }
    }
    lifecycle.suspender = suspender
    sleepPort?.start { line in suspender.sleepPortLine(line, allowed: lifecycle.canPause) }
    wc.onWakeRequest = { what in suspender.resume(origin: what) }
    wc.onGuestSizeRequest = { w, h in vm.resizeDisplay(width: w, height: h) }
    let settingsContext = SettingsContext(settings: settings, sound: sound, restart: { lifecycle.requestRestart() },
                                          vmHasPad: gamepad != nil, vmHasSound: vm.hasSound,
                                          diskPath: options.disks.first?.path)
    let settingsWindow = SettingsWindowController(context: settingsContext)
    lifecycle.settingsContext = settingsContext
    lifecycle.settingsWindow = settingsWindow
    wc.onOpenSettings = { settingsWindow.show() }
    func openReport(_ origin: String, on parent: NSWindow) {
        wc.releasePointer()
        let context = ReportContext(origin: origin, options: options, runDir: Supervisor.runDir, guest: guestLogs,
                                    captureScreenshot: { done in wc.captureWindow { drawable, _ in done(drawable) } })
        MainActor.assumeIsolated { _ = ReportSheet.present(on: parent, context: context) }
    }
    lifecycle.report = { openReport("menu", on: wc.window) }
    settingsContext.reportProblem = { openReport("settings", on: settingsWindow.window) }
    wc.stallView.onReport = { openReport("stall", on: wc.window) }
    MainActor.assumeIsolated { ReportControl.open = { openReport("control", on: wc.window) } }
    MainMenu.install(target: lifecycle, settings: #selector(Lifecycle.menuSettings), report: #selector(Lifecycle.menuReport),
                     checkForUpdates: #selector(Lifecycle.menuCheckForUpdates),
                     restart: #selector(Lifecycle.menuRestart), suspend: #selector(Lifecycle.menuSuspend),
                     shutdown: #selector(Lifecycle.menuShutdown), forceQuit: #selector(Lifecycle.menuForceQuit),
                     fullscreen: #selector(Lifecycle.menuFullscreen), grab: #selector(Lifecycle.menuGrab),
                     overlay: #selector(Lifecycle.menuOverlay), metalHUD: #selector(Lifecycle.menuMetalHUD))
    wc.installMouseMenu()
    log("input: mouse \(options.mouseMode.rawValue), \(settings.mouseSummary)")
    // Nothing reaches a paused VM; while SteamOS sleeps (window up) a button press wakes it.
    gamepad?.intercept = { pressed in
        guard suspender.paused else { return false }
        if pressed && suspender.asleep && !suspender.suspended { suspender.resume(origin: "controller button") }
        return true
    }
    wc.show()
    // Not active after all (launched in the background): start muted / paused; the activation
    // notifications take over from here.
    DispatchQueue.main.async {
        sound.setAppActive(NSApp.isActive)
        gamePause.setAppActive(NSApp.isActive)
        clipboard?.setAppActive(NSApp.isActive)
    }
    if settings.showOverlay { wc.overlay.show() }
    if options.fullscreen && !wc.window.styleMask.contains(.fullScreen) { wc.window.toggleFullScreen(nil) }
    gamepad?.start()
    // New-version check (first boot of this launch; Settings > General), after the window is up.
    UpdateChecker.shared.start { [weak wc] in wc?.window }
    if let d = options.inputSelftestDelay { InputSelfTest.schedule(after: d, window: wc, gamepad: gamepad) }
    if let d = options.resizeSelftestDelay {
        ResizeSelfTest.start(after: d, window: wc, display: display, progress: progress,
                             base: (options.frameDumpPath as NSString).deletingPathExtension, dump: dumpFrames)
    }
    if let path = options.controlFifo {
        DebugControl.start(path: path, window: wc, progress: progress, settingsWindow: settingsWindow, gamepad: gamepad) { dumpFrames(to: $0) }
    }
    console.start()
    vm.start()
    withExtendedLifetime((presenter, gamepad, progressPort, supervisorWatch, perfSubscription, gamePause, suspender, clipboard)) {
        app.run()
    }
} catch {
    fatal("\(error)")
}
