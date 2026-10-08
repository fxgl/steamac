import Combine
import AppKit
import Carbon.HIToolbox
import CoreGraphics
import Foundation

/// Routes key events to the guest before AppKit's key-equivalent/menu machinery (which would
/// otherwise swallow Cmd-combos and their keyUps).
final class SteamacApplication: NSApplication {
    weak var router: WindowController?

    override func sendEvent(_ event: NSEvent) {
        if let router, router.handleKeyEvent(event) { return }
        super.sendEvent(event)
    }
}

final class WindowController: NSObject, NSWindowDelegate {
    let window: NSWindow
    let view: VMView
    private let inputs: VMInputs?
    private let mouseMode: MouseMode
    private let baseTitle: String
    var onCloseRequest: (() -> Void)?
    /// Ctrl+Cmd+S while the VM window has the keyboard (the menu's Suspend).
    var onSuspendRequest: (() -> Void)?
    /// Cmd+, while the VM window has the keyboard (keys otherwise all go to the guest).
    var onOpenSettings: (() -> Void)?
    /// Launcher settings (live values: overlay, follow window size, mouse auto-capture).
    let settings: LauncherSettings
    private var subscriptions: [AnyCancellable] = []
    /// FX boot/shutdown overlay, layered over the Metal view.
    let overlay: OverlayView
    /// "Still working" card shown when the guest GPU goes idle (StallMonitor), above the overlay.
    let stallView: StallIndicatorView
    private var stall: StallMonitor?
    /// Compact boot / shutdown progress while the full overlay is not up before `ready`, and the
    /// no-picture guard's report after it (bottom centre, above the GPU-idle card).
    let pill: ProgressPillView
    private var noPicture: NoPictureGuard?
    private var noPictureReport: NoPictureGuard.Report?
    /// "Game paused" (GamePause confirmed a frozen game), above everything else.
    let pauseView: PauseOverlayView
    /// App id shown as paused (nil = not paused).
    private(set) var pausedGame: Int?
    /// "SteamOS is sleeping" (the guest went to sleep, SuspendController paused the VM).
    let sleepView: PauseOverlayView
    /// The guest sleeps: nothing reaches it; the first click, key or controller button wakes it.
    private(set) var guestAsleep = false
    /// A click / key while the guest sleeps (argument: what it was, for the log).
    var onWakeRequest: ((String) -> Void)?
    /// "Resuming…" chip after a suspend, until the guest's next frame.
    let resumeChip: ResumeChipView
    /// Buttons whose press was swallowed (it resumed a paused game or woke the guest): their
    /// release is too.
    private var swallowedButtons = Set<UInt16>()
    /// Same for keys (macOS key codes) that woke the guest.
    private var swallowedKeys = Set<UInt16>()
    private var progress: BootProgress?
    /// The boot / shutdown overlay is collapsed into the pill (click / key, menu, 15 min); a new
    /// shutdown, the pill or the menu expands it again.
    private var overlayCollapsed = false
    /// Collapsed by View → Show Boot Progress or the 15-minute timeout: download-type stages do
    /// not re-expand it (a click / key collapse is undone when one starts).
    private var collapseIsSticky = false

    private var pressedKeys = Set<UInt16>()
    private var tabletButtons = Set<UInt16>()
    private var mouseButtons = Set<UInt16>()
    private var lastAbs: (Int32, Int32) = (-1, -1)
    private var captured = false
    private var relRemainder = (0.0, 0.0)
    /// Auto mode: where the guest cursor is (guest pixels); nil = unknown, re-anchor first.
    private var guestCursor: (Int, Int)?
    private var lastPointerMotion = Date.distantPast
    /// What the guest says has focus (progress agent `focus …`); Steam until told otherwise.
    private(set) var guestFocus: GuestFocus = .steam
    private var wheelHiRemainder = (0.0, 0.0)   // (vertical, horizontal) in 1/120 notch units
    private var wheelLoAccum: (Int32, Int32) = (0, 0)
    private var scanoutSize: (Int, Int)
    /// Guest display should become (width, height) px: the window's content size in points times
    /// `pixelScale`.
    var onGuestSizeRequest: ((Int, Int) -> Void)?
    private var requestedGuestSize: (Int, Int)
    private var guestResizeWork: DispatchWorkItem?
    private var inFullScreenTransition = false
    static let minGuestSize = NSSize(width: 800, height: 500)
    /// Guest pixels per window point for this session (Settings > Display > Retina resolution:
    /// the screen's backing scale at boot, else 1).
    let pixelScale: Double
    /// Settle time after the last size change before the guest is asked to switch modes.
    static let guestResizeDebounce: TimeInterval = 0.25

    /// `width` x `height`: initial content size in points; the guest display is that times `pixelScale`.
    init(title: String, width: Int, height: Int, pixelScale: Double = 1, renderer: Renderer, inputs: VMInputs?,
         mouseMode: MouseMode) {
        self.inputs = inputs
        self.mouseMode = mouseMode
        self.baseTitle = title
        self.pixelScale = pixelScale
        let guest = WindowController.guestSize(points: CGSize(width: width, height: height), scale: pixelScale)
        self.scanoutSize = guest
        self.requestedGuestSize = guest
        let rect = NSRect(x: 0, y: 0, width: width, height: height)
        let screen = WindowController.targetScreen()
        window = NSWindow(contentRect: rect, styleMask: [.titled, .closable, .miniaturizable, .resizable],
                          backing: .buffered, defer: false, screen: screen)
        view = VMView(frame: rect, renderer: renderer, contentPixelSize: CGSize(width: guest.0, height: guest.1))
        overlay = OverlayView(frame: rect)
        stallView = StallIndicatorView(frame: rect)
        pill = ProgressPillView(frame: rect)
        pauseView = PauseOverlayView(frame: rect)
        sleepView = PauseOverlayView(frame: rect, style: .sleeping)
        resumeChip = ResumeChipView(frame: rect)
        settings = LauncherSettings.shared
        super.init()
        window.title = title
        window.contentView = view
        window.delegate = self
        window.collectionBehavior = [.fullScreenPrimary, .managed]
        window.acceptsMouseMovedEvents = true
        window.isReleasedWhenClosed = false
        window.backgroundColor = .black
        window.contentMinSize = WindowController.minGuestSize
        fitToScreen(width: width, height: height)
        window.center()
        view.controller = self
        overlay.frame = view.bounds
        view.addSubview(overlay)
        stallView.frame = view.bounds
        view.addSubview(stallView)
        pill.frame = view.bounds
        view.addSubview(pill)
        pill.onClick = { [weak self] in self?.expandPill() }
        pill.clickable = { [weak self] in self.map { $0.bootOrShutdown && !$0.captured } ?? false }
        overlay.onVisibilityChange = { [weak self] _ in
            self?.updateStallGate()
            self?.updatePill()
        }
        pauseView.frame = view.bounds
        view.addSubview(pauseView)
        sleepView.frame = view.bounds
        view.addSubview(sleepView)
        resumeChip.frame = view.bounds
        view.addSubview(resumeChip)
        updateTitle()
        // @Published fires before the change: evaluate on the next main-queue turn.
        subscriptions.append(settings.$followWindowSize.dropFirst().receive(on: DispatchQueue.main).sink { [weak self] on in
            log("display: follow window size \(on ? "on" : "off")")
            if on { self?.scheduleGuestResize() }
        })
        subscriptions.append(settings.$showOverlay.dropFirst().receive(on: DispatchQueue.main).sink { [weak self] on in
            guard let self else { return }
            if !on { self.overlay.hide() }
            else if self.bootOrShutdown, !self.overlayCollapsed { self.overlay.show() }
        })
        subscriptions.append(settings.objectWillChange.receive(on: DispatchQueue.main).sink { [weak self] _ in
            guard let self else { return }
            if self.captured && self.mouseMode == .auto && !self.clickCaptures { self.releasePointer() }
            self.updateTitle()
        })
        // Metal Performance HUD (libMTLHud, loaded by MTL_HUD_ENABLED=1, see main.swift), shown and
        // hidden at runtime through the layer (VMView.metalHUD).
        applyMetalHUD(settings.metalHUD)
        subscriptions.append(settings.$metalHUD.dropFirst().removeDuplicates().receive(on: DispatchQueue.main).sink { [weak self] on in
            self?.applyMetalHUD(on)
        })
        applySuperResolution(settings.superResolution)
        subscriptions.append(settings.$superResolution.dropFirst().removeDuplicates().receive(on: DispatchQueue.main).sink { [weak self] on in
            self?.applySuperResolution(on)
        })
    }

    func show() {
        window.makeKeyAndOrderFront(nil)
        window.makeFirstResponder(self.view)
        NSApp.activate()
    }

    /// The screen the window opens on: the one under the mouse pointer, else the main screen.
    static func targetScreen() -> NSScreen? {
        let mouse = NSEvent.mouseLocation
        return NSScreen.screens.first { NSMouseInRect(mouse, $0.frame, false) } ?? NSScreen.main
    }

    /// Initial content size: the requested size in points (Retina: 2x2 physical pixels each), shrunk
    /// to fit the screen's visible area below the title bar. Also the basis of the default EDID size.
    static func initialContentSize(width: Int, height: Int, screen: NSScreen?) -> NSSize {
        var size = NSSize(width: width, height: height)
        if let vf = screen?.visibleFrame {
            let chrome = NSWindow.frameRect(forContentRect: NSRect(origin: .zero, size: size),
                                            styleMask: [.titled, .closable, .miniaturizable, .resizable]).height - size.height
            let s = min(1, vf.width / size.width, (vf.height - chrome) / size.height)
            size = NSSize(width: (size.width * s).rounded(.down), height: (size.height * s).rounded(.down))
        }
        return size
    }

    private func fitToScreen(width: Int, height: Int) {
        window.setContentSize(WindowController.initialContentSize(width: width, height: height,
                                                                  screen: window.screen ?? NSScreen.main))
    }

    /// The guest switched its scanout size. The window does not follow (the guest follows the
    /// window); frames of any size are scaled to fit, so old-size frames bridge the switch.
    func scanoutResized(width: Int, height: Int) {
        view.contentPixelSize = CGSize(width: width, height: height)
        scanoutSize = (width, height)
        view.redraw()
    }

    /// Guest size for the current window: content size in points times `pixelScale`.
    func guestSizeForWindow() -> (Int, Int) {
        WindowController.guestSize(points: view.bounds.size, scale: pixelScale)
    }

    /// Guest display size for a content size in points at `scale` guest pixels per point: rounded
    /// down to even, at least `minGuestSize`, at most VM.maxDisplaySide per side (a scale above 1
    /// is lowered, keeping the aspect, until the longer side fits).
    static func guestSize(points: CGSize, scale: Double) -> (Int, Int) {
        let maxSide = VM.maxDisplaySide & ~1
        let pw = max(minGuestSize.width, points.width), ph = max(minGuestSize.height, points.height)
        let s = max(1, min(scale, Double(maxSide) / Double(max(pw, ph))))
        return (min(maxSide, Int(Double(pw) * s) & ~1), min(maxSide, Int(Double(ph) * s) & ~1))
    }

    /// Set while the VM is paused (suspended, guest asleep): window size changes (leaving full
    /// screen before the window hides, resizes while it sleeps) do not resize the guest until it
    /// runs again.
    var holdGuestSize = false { didSet { if oldValue && !holdGuestSize { scheduleGuestResize() } } }
    /// One-shot: the window has left full screen.
    var onDidExitFullScreen: (() -> Void)?

    /// Debounced: never during a live drag or a fullscreen transition (the last frame is scaled
    /// meanwhile); fires once the size has been stable for `guestResizeDebounce`.
    private func scheduleGuestResize() {
        guestResizeWork?.cancel()
        guard settings.followWindowSize else { return }
        let work = DispatchWorkItem { [weak self] in
            guard let self, !self.window.inLiveResize, !self.inFullScreenTransition, !self.holdGuestSize else { return }
            let size = self.guestSizeForWindow()
            guard size != self.requestedGuestSize else { return }
            self.requestedGuestSize = size
            self.onGuestSizeRequest?(size.0, size.1)
        }
        guestResizeWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + WindowController.guestResizeDebounce, execute: work)
    }

    func windowDidEndLiveResize(_ notification: Notification) { scheduleGuestResize() }

    /// Programmatic / zoom-button resizes (no live resize session).
    func windowDidResize(_ notification: Notification) {
        if !window.inLiveResize && !inFullScreenTransition { scheduleGuestResize() }
    }

    func windowWillEnterFullScreen(_ notification: Notification) { inFullScreenTransition = true }
    func windowWillExitFullScreen(_ notification: Notification) { inFullScreenTransition = true }
    func windowDidEnterFullScreen(_ notification: Notification) { inFullScreenTransition = false; scheduleGuestResize() }
    func windowDidExitFullScreen(_ notification: Notification) {
        inFullScreenTransition = false
        scheduleGuestResize()
        if let done = onDidExitFullScreen {
            onDidExitFullScreen = nil
            done()
        }
    }
    func windowDidFailToEnterFullScreen(_ window: NSWindow) { inFullScreenTransition = false }
    func windowDidFailToExitFullScreen(_ window: NSWindow) { inFullScreenTransition = false }

    func setStatus(_ status: String?) {
        let title = status.map { "\(baseTitle) — \($0)" } ?? baseTitle
        if window.title != title { window.title = title }
    }

    /// Before `ready` and during shutdown / reboot the title mirrors the progress
    /// ("Downloading Steam update 70%", "Starting Steam…", "Shutting down…").
    private func updateTitle() {
        if guestAsleep {
            setStatus(tr("sleeping — click to wake"))
        } else if pausedGame != nil {
            setStatus(tr("paused"))
        } else if let s = progress.flatMap({ WindowController.progressStatus($0.state) }) {
            setStatus(captured ? "\(s) — " + tr("mouse captured — Ctrl+Option releases") : s)
        } else if captured {
            setStatus(tr("mouse captured — Ctrl+Option releases"))
        } else if inputs != nil && clickCaptures {
            setStatus(tr("click to capture the mouse"))
        } else {
            setStatus(nil)
        }
    }

    /// Window-title status for a boot / shutdown progress state; nil once Steam is ready.
    static func progressStatus(_ s: ProgressState) -> String? {
        let ellipsized = s.title.hasSuffix("…") || s.title.hasSuffix(".") ? s.title : s.title + "…"
        switch s.phase {
        case .running: return nil
        case .shutdown: return ellipsized
        case .boot:
            guard !s.indeterminate, s.fraction > 0 else { return ellipsized }
            let t = s.title.hasSuffix("…") ? String(s.title.dropLast()) : s.title
            return "\(t) \(Int((s.fraction * 100).rounded(.down)))%"
        }
    }

    /// GamePause: the guest confirmed `appid` frozen (nil: running again). The card stays off
    /// while the boot/shutdown overlay is up or the guest sleeps.
    func gamePaused(_ appid: Int?) {
        pausedGame = appid
        if let appid, !overlay.shown, !guestAsleep {
            pauseView.show(gameName: settings.gameName(appid))
        } else {
            pauseView.hide()
        }
        updateTitle()
        updateNoPictureGate()
    }

    /// SuspendController: the guest went to sleep (VM paused) / woke up. "Game paused" gives way
    /// to "SteamOS is sleeping" (GamePause freezes the game again after the wake if it still should).
    func guestSleeping(_ asleep: Bool) {
        guestAsleep = asleep
        if asleep {
            pauseView.hide(animated: false)
            sleepView.show(gameName: nil)
        } else {
            sleepView.hide()
        }
        updateTitle()
        updateNoPictureGate()
    }

    /// First click / key while the guest sleeps: wake it (the event itself is swallowed).
    private func wakeGuest(_ what: String) {
        log("input: \(what) wakes SteamOS (not sent to the guest)")
        onWakeRequest?(what)
    }

    // MARK: overlay

    /// Boot / shutdown progress always stays on screen until `ready`: the full overlay, or the
    /// compact pill once the user clicked / pressed a key in the window (or after 15 minutes, or
    /// with Settings > General's overlay off). Clicking the pill or View > Show Boot Progress
    /// expands it again; a shutdown / reboot starts with the full overlay again. Provisioning and
    /// the Steam client download / install keep the full overlay up (`keepOverlayStages`).
    func attach(progress: BootProgress) {
        self.progress = progress
        overlay.update(progress.state)
        let previous = progress.onChange
        progress.onChange = { [weak self] s in previous?(s); self?.progressChanged(s) }
        let previousFocus = progress.onFocus
        progress.onFocus = { [weak self] f in previousFocus?(f); self?.guestFocusChanged(f) }
        let previousReady = progress.onReady
        progress.onReady = { [weak self] in previousReady?(); self?.overlay.hide() }
        let previousShutdown = progress.onShutdown
        progress.onShutdown = { [weak self] reboot in
            previousShutdown?(reboot)
            guard let self else { return }
            self.overlayCollapsed = false
            self.collapseIsSticky = false
            if self.settings.showOverlay { self.overlay.show() }
            self.pauseView.hide(animated: false)
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 15 * 60) { [weak self] in
            guard let self, let p = self.progress, p.state.phase == .boot, self.overlay.shown else { return }
            self.collapseOverlay("still booting after 15 min", sticky: true)
        }
        updatePill()
        updateTitle()
    }

    private func progressChanged(_ s: ProgressState) {
        overlay.update(s)
        // Entering a download-type stage after a click / key collapsed the overlay: full overlay again.
        if s.phase == .boot, Self.keepOverlayStages.contains(s.stageId), overlayCollapsed, !collapseIsSticky,
           settings.showOverlay, !overlay.shown {
            overlayCollapsed = false
            log("overlay: expanded for \(s.stageId)")
            overlay.show()
        }
        updatePill()
        updateTitle()
        updateNoPictureGate()
    }

    /// Booting or shutting down (not `ready` yet, or no longer).
    private var bootOrShutdown: Bool { progress.map { $0.state.phase != .running } ?? false }

    /// The pill shows the boot / shutdown progress whenever the full overlay is not up, else the
    /// no-picture guard's report (after `ready`); hidden (fading) otherwise.
    private func updatePill() {
        let content: ProgressPillView.Content?
        if overlay.shown {
            content = nil
        } else if let p = progress?.state, p.phase != .running {
            content = ProgressPillView.Content(p)
        } else if let r = noPictureReport {
            content = ProgressPillView.Content(title: r.title, detail: r.detail, fraction: nil)
        } else {
            content = nil
        }
        if let content {
            pill.update(content)
            pill.show()
        } else {
            pill.hide()
        }
    }

    /// Full overlay → pill (the progress stays on screen; input goes through). `sticky`: the menu
    /// or the timeout, which download-type stages respect until `ready`.
    private func collapseOverlay(_ why: String, sticky: Bool = false) {
        guard overlay.shown else { return }
        if bootOrShutdown {
            overlayCollapsed = true
            collapseIsSticky = sticky
            log("overlay: collapsed to pill (\(why))")
        }
        overlay.hide()
    }

    /// Click on the pill: back to the full overlay.
    private func expandPill() {
        guard bootOrShutdown, !overlay.shown else { return }
        overlayCollapsed = false
        collapseIsSticky = false
        log("overlay: expanded from pill (click)")
        overlay.show()
    }

    /// Menu "Show Boot Progress": expand the pill / collapse the overlay (after `ready`: show / hide
    /// the overlay).
    func toggleOverlay() {
        if overlay.shown {
            collapseOverlay("menu", sticky: true)
        } else {
            if bootOrShutdown { log("overlay: expanded from pill (menu)") }
            overlayCollapsed = false
            collapseIsSticky = false
            overlay.show()
        }
    }

    /// Menu "Show Metal Performance HUD" / Ctrl+Cmd+P: flips the setting (persisted, Settings > Display).
    func toggleMetalHUD() {
        settings.metalHUD.toggle()
    }

    private func applyMetalHUD(_ on: Bool) {
        view.metalHUD = on
        log("display: Metal Performance HUD \(on ? "on" : "off")")
        view.redraw()   // the HUD changes with the next present; an idle guest sends none
    }

    private func applySuperResolution(_ on: Bool) {
        view.renderer.superResolution = on
        log("display: MetalFX super resolution \(on ? "on" : "off")"
            + (on && !Renderer.superResolutionSupported ? " (not supported on this GPU)" : ""))
        view.redraw()   // an idle guest sends no new frame
    }

    /// The GPU-idle indicator follows `ready`, the overlay (never while it is up or the guest shuts
    /// down), game focus, the guest heartbeat and Settings > General.
    func attach(stall: StallMonitor) {
        self.stall = stall
        stall.enabled = settings.showStallIndicator
        stall.gameFocused = focusedGame != nil
        if let progress {
            let previous = progress.onChange
            progress.onChange = { [weak self] s in previous?(s); self?.updateStallGate() }
            let previousAlive = progress.onAlive
            progress.onAlive = { [weak stall] ms, load in previousAlive?(ms, load); stall?.alive(uptimeMs: ms, load: load) }
        }
        subscriptions.append(settings.$showStallIndicator.dropFirst().receive(on: DispatchQueue.main).sink { [weak stall] on in
            log("stall: indicator \(on ? "on" : "off")")
            stall?.enabled = on
        })
        updateStallGate()
        stall.start()
    }

    private func updateStallGate() {
        guard let stall else { return }
        stall.suppressed = overlay.shown || bootOrShutdown
    }

    /// "Waiting for SteamOS to draw…" in the pill after `ready` (never during game focus, sleep,
    /// a paused game or a paused VM; `vmPaused` is set by the owner).
    func attach(noPicture: NoPictureGuard) {
        self.noPicture = noPicture
        if let progress {
            let previousAlive = progress.onAlive
            progress.onAlive = { [weak noPicture] ms, load in previousAlive?(ms, load); noPicture?.alive() }
            noPicture.lastKnown = { [weak progress] in
                progress.flatMap { $0.state.phase == .running ? $0.state.detail : nil }
            }
        }
        noPicture.onChange = { [weak self] report in
            self?.noPictureReport = report
            self?.updatePill()
        }
        updateNoPictureGate()
        noPicture.start()
    }

    private func updateNoPictureGate() {
        guard let noPicture else { return }
        noPicture.ready = progress.map { $0.state.phase == .running } ?? false
        noPicture.gameFocused = focusedGame != nil
        noPicture.gamePaused = pausedGame != nil
        noPicture.asleep = guestAsleep
    }

    /// The user interacted with the guest: a visible overlay gets out of the way (input still goes
    /// through); before `ready` the progress stays on screen as the pill. While the guest downloads
    /// or installs the Steam client or provisions a new disk the overlay stays up: the guest shows
    /// nothing to interact with then (View → Show Boot Progress still collapses it).
    private func userInput(_ what: String) {
        guard overlay.shown else { return }
        if let p = progress?.state, p.phase == .boot, Self.keepOverlayStages.contains(p.stageId) { return }
        collapseOverlay(what)
    }

    /// Boot stages during which input does not collapse the overlay.
    private static let keepOverlayStages: Set<String> = ["provision", "steam-download", "steam-install"]

    /// Read back the next presented drawable; `composite` = drawable with the overlay, the
    /// GPU-idle indicator, the progress pill, the "Game paused" / "SteamOS is sleeping" cards and
    /// the "Resuming…" chip on top, at 2x.
    func captureWindow(_ done: @escaping (_ drawable: CGImage?, _ composite: CGImage?) -> Void) {
        view.renderer.captureNextDraw = { [weak self] bytes, w, h in
            DispatchQueue.main.async {
                let drawable = PNG.image(bgra: bytes, width: w, height: h)
                guard let self else { return done(drawable, nil) }
                var composite = self.overlay.renderImage(scale: 2, under: drawable)
                composite = self.stallView.renderImage(scale: 2, under: composite)
                composite = self.pill.renderLayerImage(scale: 2, under: composite)
                for v in [self.pauseView, self.sleepView, self.resumeChip] as [NSView] {
                    composite = v.renderLayerImage(scale: 2, under: composite)
                }
                done(drawable, composite)
            }
        }
        view.redraw()
    }

    /// The window as the window server composites it, Metal HUD included (the HUD is not part of
    /// the drawable). CGWindowListCreateImage is unavailable in the macOS 15 SDK but still captures
    /// the process's own windows without Screen Recording permission; looked up at run time.
    func windowServerImage() -> CGImage? {
        typealias CreateImage = @convention(c) (CGRect, UInt32, UInt32, UInt32) -> Unmanaged<CGImage>?
        guard let sym = dlsym(UnsafeMutableRawPointer(bitPattern: -2), "CGWindowListCreateImage") else { return nil }   // RTLD_DEFAULT
        let create = unsafeBitCast(sym, to: CreateImage.self)
        // kCGWindowListOptionIncludingWindow, kCGWindowImageBoundsIgnoreFraming
        return create(.null, 1 << 3, UInt32(window.windowNumber), 1 << 0)?.takeRetainedValue()
    }

    // MARK: NSWindowDelegate

    func windowShouldClose(_ sender: NSWindow) -> Bool {
        onCloseRequest?()
        return false
    }

    func windowDidResignKey(_ notification: Notification) { releaseAll() }
    func windowDidMiniaturize(_ notification: Notification) { releaseAll() }

    // MARK: keyboard

    /// Returns true if the event was consumed (only while our window is key).
    func handleKeyEvent(_ e: NSEvent) -> Bool {
        guard e.type == .keyDown || e.type == .keyUp || e.type == .flagsChanged,
              e.window === window || (e.window == nil && window.isKeyWindow), window.isKeyWindow else { return false }
        return processKey(e)
    }

    /// Key/flags event -> host shortcut or guest evdev key.
    func processKey(_ e: NSEvent) -> Bool {
        let mods = e.modifierFlags.intersection(.deviceIndependentFlagsMask)

        switch e.type {
        case .keyDown:
            userInput("key")
            if mods.contains([.control, .command]) {
                switch Int(e.keyCode) {
                case kVK_ANSI_F: toggleFullScreen(); return true
                case kVK_ANSI_G: captured ? releasePointer() : grabPointer(); return true
                case kVK_ANSI_P: toggleMetalHUD(); return true
                case kVK_ANSI_S:
                    guard let onSuspendRequest else { break }
                    onSuspendRequest()
                    return true
                default: break
                }
            }
            if mods == .command && Int(e.keyCode) == kVK_ANSI_Comma, let onOpenSettings {
                releaseAll()
                onOpenSettings()
                return true
            }
            if e.isARepeat { return true }   // guest does autorepeat
            if guestAsleep {
                swallowedKeys.insert(e.keyCode)
                wakeGuest("key")
                return true
            }
            guard let code = Keymap.linuxKey(e.keyCode) else { return true }
            if pressedKeys.insert(code).inserted { sendKey(code, true) }
            return true
        case .keyUp:
            if swallowedKeys.remove(e.keyCode) != nil || guestAsleep { return true }
            guard let code = Keymap.linuxKey(e.keyCode) else { return true }
            if pressedKeys.remove(code) != nil { sendKey(code, false) }
            return true
        default: // flagsChanged
            if guestAsleep { return true }   // modifiers alone do not wake it
            if Int(e.keyCode) == kVK_CapsLock {
                // macOS reports the lock *state*; evdev wants a key press each time.
                sendKey(KEY.CAPSLOCK, true)
                sendKey(KEY.CAPSLOCK, false)
            } else if let mask = Keymap.modifierMask(e.keyCode), let code = Keymap.linuxKey(e.keyCode) {
                let down = (UInt(e.modifierFlags.rawValue) & mask) != 0
                if down, pressedKeys.insert(code).inserted { sendKey(code, true) }
                if !down, pressedKeys.remove(code) != nil { sendKey(code, false) }
            }
            if captured && mods.contains([.control, .option]) { releasePointer() }
            return true
        }
    }

    private func sendKey(_ code: UInt16, _ down: Bool) {
        inputs?.keyboard.send([(EV.KEY, code, down ? 1 : 0)])
    }

    private func toggleFullScreen() {
        window.toggleFullScreen(nil)
    }

    // MARK: pointer
    //
    // gamescope (SteamOS gaming mode) ignores absolute pointer motion: wlserver only handles
    // wlr_pointer `motion` (relative), never `motion_absolute`, so a virtio tablet's ABS_X/ABS_Y
    // never moves its cursor. It applies relative motion *unaccelerated* (unaccel_dx/dy) in the
    // focused surface's pixels and clamps the cursor to that surface. So in `auto` mode the host
    // pointer is mirrored with exact relative deltas through the virtio mouse, after anchoring the
    // guest cursor at the top-left corner with one large negative delta whenever its position is
    // unknown (pointer entered the picture, idle, after a capture). Desktop Mode runs inside the
    // same gamescope (Plasma is one KWin window, `focus desktop <w>x<h>`), so it takes the same
    // path, mapped onto that window as gamescope shows it. The absolute tablet is used only in
    // `tablet` mode.

    /// Idle time after which the guest cursor may have been moved by the guest (warps, a game's
    /// smaller surface clamping); the next motion re-anchors.
    static let reanchorAfterIdle: TimeInterval = 1.5
    /// gamescope's `--max-scale` (guest/layer/usr/lib/steamos/gamescope-session): a smaller
    /// surface is shown at most this many times its size.
    static let gamescopeMaxScale = 2.0

    private var usesTablet: Bool {
        mouseMode == .tablet
    }

    /// The surface relative motion lands on, in its pixels: the Desktop Mode desktop window, else
    /// the display (Steam's UI and games fill it).
    private var pointerSurface: (Int, Int) {
        if case .desktop(let w, let h) = guestFocus { return (w, h) }
        return scanoutSize
    }

    /// Where `pointerSurface` appears in the view: gamescope fits it into the display (aspect kept,
    /// centred, upscaled at most `gamescopeMaxScale` times).
    private var pointerRect: CGRect {
        let fit = view.fitRect
        let (w, h) = pointerSurface, (sw, sh) = scanoutSize
        guard (w, h) != (sw, sh), w > 0, h > 0, sw > 0, sh > 0 else { return fit }
        let scale = min(Double(sw) / Double(w), Double(sh) / Double(h), WindowController.gamescopeMaxScale)
        let pw = fit.width * CGFloat(Double(w) * scale / Double(sw))
        let ph = fit.height * CGFloat(Double(h) * scale / Double(sh))
        return CGRect(x: fit.midX - pw / 2, y: fit.midY - ph / 2, width: pw, height: ph)
    }

    /// "Name (appid)" when the guest told us the game's name.
    private func gameLabel(_ id: Int) -> String {
        settings.gameName(id).map { "\($0) (\(id))" } ?? tr("game %@", "\(id)")
    }

    private var focusedGame: Int? {
        if case .game(let id) = guestFocus { return id } else { return nil }
    }

    /// A click in the picture captures the mouse instead of being forwarded.
    private var clickCaptures: Bool {
        switch mouseMode {
        case .capture: return true
        case .tablet: return false
        case .auto: return focusedGame.map { settings.autoCapture(for: $0) } ?? false
        }
    }

    func guestFocusChanged(_ f: GuestFocus) {
        // The agent ended with the gamescope session: no heartbeats until the next session's agent.
        if f == .sessionEnded {
            stall?.heartbeatsEnded()
            noPicture?.heartbeatsEnded()
        }
        guard f != guestFocus else { return }
        guestFocus = f
        stall?.gameFocused = focusedGame != nil
        updateNoPictureGate()
        log("input: guest focus \(f)")
        guestCursor = nil
        // Back in Steam / desktop (or a game without auto-capture): give the pointer back.
        if captured && mouseMode == .auto && !clickCaptures { releasePointer() }
        updateTitle()
        if let id = focusedGame, mouseMode == .auto {
            flashStatus(settings.autoCapture(for: id) ? tr("click to capture the mouse (Ctrl+Option releases)")
                                                      : tr("auto-capture off for %@ (Ctrl+Cmd+G captures)", gameLabel(id)))
        }
    }

    /// Window-title hint for a few seconds, then back to the regular status.
    private var statusFlashWork: DispatchWorkItem?
    private func flashStatus(_ text: String) {
        statusFlashWork?.cancel()
        setStatus(text)
        let work = DispatchWorkItem { [weak self] in self?.updateTitle() }
        statusFlashWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 4, execute: work)
    }

    // Mouse menu actions.
    @objc func toggleGameAutoCapture(_ sender: Any?) {
        guard let id = focusedGame else { return }
        let on = !settings.autoCapture(for: id)
        settings.setAutoCapture(on, for: id)
        if !on && captured { releasePointer() }
        updateTitle()
        flashStatus(on ? tr("auto-capture on for %@", gameLabel(id)) : tr("auto-capture off for %@", gameLabel(id)))
    }

    @objc func toggleGlobalAutoCapture(_ sender: Any?) {
        let on = !settings.globalAutoCapture
        settings.autoCaptureGames = on
        log("input: auto-capture in games \(on ? "on" : "off") (saved)"
            + (settings.autoCaptureOverride != nil ? "; --auto-capture still applies to this run" : ""))
        if captured && !clickCaptures { releasePointer() }
        updateTitle()
        flashStatus(tr(settings.globalAutoCapture ? "auto-capture in games on" : "auto-capture in games off"))
    }

    @objc func toggleCaptureNow(_ sender: Any?) { captured ? releasePointer() : grabPointer() }

    /// Adds the "Mouse" menu (validated against the current focus each time it opens).
    func installMouseMenu() {
        guard let main = NSApp.mainMenu else { return }
        let item = NSMenuItem()
        let menu = NSMenu(title: tr("Mouse"))
        menu.autoenablesItems = true
        for (title, action) in [(tr("Capture Mouse in This Game"), #selector(toggleGameAutoCapture(_:))),
                                (tr("Auto-Capture Mouse in Games"), #selector(toggleGlobalAutoCapture(_:))),
                                (tr("Capture / Release Mouse Now (Ctrl+Cmd+G)"), #selector(toggleCaptureNow(_:)))] {
            let i = NSMenuItem(title: title, action: action, keyEquivalent: "")
            i.target = self
            menu.addItem(i)
        }
        item.submenu = menu
        main.addItem(item)
    }
}

extension WindowController: NSMenuItemValidation {
    func validateMenuItem(_ item: NSMenuItem) -> Bool {
        switch item.action {
        case #selector(toggleGameAutoCapture(_:)):
            if let id = focusedGame {
                item.title = tr("Capture Mouse in This Game (%@)", gameLabel(id))
                item.state = settings.autoCapture(for: id) ? .on : .off
                return mouseMode == .auto
            }
            item.title = tr("Capture Mouse in This Game")
            item.state = .off
            return false
        case #selector(toggleGlobalAutoCapture(_:)):
            item.state = settings.globalAutoCapture ? .on : .off
            return mouseMode == .auto
        default:
            return inputs != nil
        }
    }
}

extension WindowController {

    /// The mouse is captured (relative mode, cursor hidden).
    var pointerCaptured: Bool { captured }

    func grabPointer() {
        guard inputs != nil, !captured else { return }
        releaseButtons()
        captured = true
        relRemainder = (0, 0)
        CGAssociateMouseAndMouseCursorPosition(0)
        NSCursor.hide()
        log("input: mouse captured")
        updateTitle()
        window.invalidateCursorRects(for: pill)
    }

    func releasePointer() {
        guard captured else { return }
        releaseButtons()
        captured = false
        CGAssociateMouseAndMouseCursorPosition(1)
        NSCursor.unhide()
        lastAbs = (-1, -1)
        guestCursor = nil
        log("input: mouse released")
        updateTitle()
        window.invalidateCursorRects(for: pill)
    }

    private func releaseButtons() {
        for b in tabletButtons { inputs?.tablet.send([(EV.KEY, b, 0)]) }
        for b in mouseButtons { inputs?.mouse.send([(EV.KEY, b, 0)]) }
        tabletButtons.removeAll()
        mouseButtons.removeAll()
    }

    func releaseAll() {
        for k in pressedKeys { sendKey(k, false) }
        pressedKeys.removeAll()
        releasePointer()
        releaseButtons()
        guestCursor = nil
    }

    private func button(for e: NSEvent) -> UInt16 {
        switch e.type {
        case .leftMouseDown, .leftMouseUp: return BTN.LEFT
        case .rightMouseDown, .rightMouseUp: return BTN.RIGHT
        default:
            switch e.buttonNumber {
            case 2: return BTN.MIDDLE
            case 3: return BTN.SIDE
            default: return BTN.EXTRA
            }
        }
    }

    private func inPicture(_ e: NSEvent) -> Bool {
        (usesTablet ? view.fitRect : pointerRect).contains(view.convert(e.locationInWindow, from: nil))
    }

    /// Host pointer position in pixels of `pointerSurface`, clamped to it.
    private func guestPoint(_ e: NSEvent) -> (Int, Int) {
        let p = view.convert(e.locationInWindow, from: nil)
        let r = pointerRect
        guard r.width > 0, r.height > 0 else { return (0, 0) }
        let ux = Double((p.x - r.minX) / r.width)
        let uy = 1 - Double((p.y - r.minY) / r.height)   // AppKit views are bottom-left origin
        let (w, h) = pointerSurface
        return (min(w - 1, max(0, Int(ux * Double(w)))), min(h - 1, max(0, Int(uy * Double(h)))))
    }

    private func moveTablet(_ e: NSEvent) {
        guard let inputs else { return }
        let (ux, uy) = view.unitPoint(for: e)
        let x = Int32((ux * Double(InputDevices.absMax)).rounded())
        let y = Int32((uy * Double(InputDevices.absMax)).rounded())
        guard (x, y) != lastAbs else { return }
        lastAbs = (x, y)
        inputs.tablet.send([(EV.ABS, ABS.X, x), (EV.ABS, ABS.Y, y)])
    }

    /// Auto mode: steer the guest cursor onto the host pointer with relative motion.
    private func moveEmulated(_ e: NSEvent) {
        guard let inputs else { return }
        let target = guestPoint(e)
        let now = Date()
        if guestCursor == nil || now.timeIntervalSince(lastPointerMotion) > WindowController.reanchorAfterIdle {
            let far = -Int32(4 * (scanoutSize.0 + scanoutSize.1))
            inputs.mouse.send([(EV.REL, REL.X, far), (EV.REL, REL.Y, far)])
            guestCursor = (0, 0)
        }
        lastPointerMotion = now
        let (cx, cy) = guestCursor!
        let dx = Int32(target.0 - cx), dy = Int32(target.1 - cy)
        guard dx != 0 || dy != 0 else { return }
        var ev: [(UInt16, UInt16, Int32)] = []
        if dx != 0 { ev.append((EV.REL, REL.X, dx)) }
        if dy != 0 { ev.append((EV.REL, REL.Y, dy)) }
        inputs.mouse.send(ev)
        guestCursor = target
    }

    /// Captured: raw relative motion, one count per host point (also with Retina resolution: games
    /// keep their mouse sensitivity; no acceleration in gamescope).
    func moveRelative(dx: Double, dy: Double) {
        guard let inputs else { return }
        let fx = dx + relRemainder.0
        let fy = dy + relRemainder.1
        let ix = Int32(fx.rounded(.towardZero)), iy = Int32(fy.rounded(.towardZero))
        relRemainder = (fx - Double(ix), fy - Double(iy))
        var ev: [(UInt16, UInt16, Int32)] = []
        if ix != 0 { ev.append((EV.REL, REL.X, ix)) }
        if iy != 0 { ev.append((EV.REL, REL.Y, iy)) }
        inputs.mouse.send(ev)
    }

    func pointerMoved(_ e: NSEvent) {
        if pauseView.shown || guestAsleep { return }   // nothing reaches a frozen game / sleeping guest
        if captured {
            moveRelative(dx: Double(e.deltaX), dy: Double(e.deltaY))
        } else if inPicture(e) || NSEvent.pressedMouseButtons != 0 {
            if usesTablet { moveTablet(e) } else { moveEmulated(e) }
        } else {
            guestCursor = nil   // left the picture: re-anchor on the way back in
        }
    }

    func pointerButton(_ e: NSEvent, down: Bool) {
        guard let inputs else { return }
        let b = button(for: e)
        // "Game paused": the click resumes (activates the app → GamePause thaws); it must not
        // also click into the game. Its release is swallowed too.
        if down && pauseView.shown {
            swallowedButtons.insert(b)
            log("input: click resumes the paused game (not sent to the guest)")
            NSApp.activate()
            return
        }
        if down && guestAsleep {
            swallowedButtons.insert(b)
            wakeGuest("click")
            return
        }
        if !down && swallowedButtons.remove(b) != nil { return }
        if down { userInput("click") }
        if captured {
            if down ? mouseButtons.insert(b).inserted : mouseButtons.remove(b) != nil {
                inputs.mouse.send([(EV.KEY, b, down ? 1 : 0)])
            }
            return
        }
        if down {
            guard inPicture(e) else { return }
            if clickCaptures {
                grabPointer()   // the capturing click itself is not forwarded
                return
            }
        }
        // The tablet only advertises LEFT/RIGHT/MIDDLE (see InputDevices); other buttons and the
        // auto mode use the relative mouse.
        if usesTablet && InputDevices.tabletButtons.contains(b) {
            if down {
                moveTablet(e)
                if tabletButtons.insert(b).inserted { inputs.tablet.send([(EV.KEY, b, 1)]) }
            } else if tabletButtons.remove(b) != nil {
                inputs.tablet.send([(EV.KEY, b, 0)])
            }
            return
        }
        if down {
            if !usesTablet { moveEmulated(e) }
            if mouseButtons.insert(b).inserted { inputs.mouse.send([(EV.KEY, b, 1)]) }
        } else if mouseButtons.remove(b) != nil {
            inputs.mouse.send([(EV.KEY, b, 0)])
        }
    }

    func scroll(_ e: NSEvent) {
        guard inputs != nil, !pauseView.shown, !guestAsleep else { return }
        if !captured {
            guard inPicture(e) else { return }
            if usesTablet { moveTablet(e) } else { moveEmulated(e) }
        }
        // 120 = one wheel notch. Precise (trackpad) deltas are points: ~30 pt per notch.
        let scale = e.hasPreciseScrollingDeltas ? 4.0 : 120.0
        sendWheel(hiResY: Double(e.scrollingDeltaY) * scale, hiResX: -Double(e.scrollingDeltaX) * scale)
    }

    /// Wheel motion in 1/120-notch units (positive y = up, positive x = right), emitted as
    /// REL_*_HI_RES plus whole REL_WHEEL/REL_HWHEEL notches.
    func sendWheel(hiResY: Double, hiResX: Double) {
        guard let inputs else { return }
        let vy = hiResY + wheelHiRemainder.0
        let vx = hiResX + wheelHiRemainder.1
        let hy = Int32(vy.rounded(.towardZero)), hx = Int32(vx.rounded(.towardZero))
        wheelHiRemainder = (vy - Double(hy), vx - Double(hx))
        wheelLoAccum.0 += hy
        wheelLoAccum.1 += hx
        let ly = wheelLoAccum.0 / 120, lx = wheelLoAccum.1 / 120
        wheelLoAccum.0 -= ly * 120
        wheelLoAccum.1 -= lx * 120
        var ev: [(UInt16, UInt16, Int32)] = []
        if hy != 0 { ev.append((EV.REL, REL.WHEEL_HI_RES, hy)) }
        if hx != 0 { ev.append((EV.REL, REL.HWHEEL_HI_RES, hx)) }
        if ly != 0 { ev.append((EV.REL, REL.WHEEL, ly)) }
        if lx != 0 { ev.append((EV.REL, REL.HWHEEL, lx)) }
        (!captured && usesTablet ? inputs.tablet : inputs.mouse).send(ev)
    }
}

enum MainMenu {
    static func install(target: AnyObject, settings: Selector, report: Selector, checkForUpdates: Selector, restart: Selector,
                        suspend: Selector, shutdown: Selector, forceQuit: Selector, fullscreen: Selector, grab: Selector,
                        overlay: Selector, metalHUD: Selector) {
        let main = NSMenu()
        let appItem = NSMenuItem()
        main.addItem(appItem)
        let appMenu = NSMenu()
        appItem.submenu = appMenu
        // Titled by the target's validateMenuItem ("Update Available: X.Y…" once one was found).
        appMenu.addItem(item("Check for Updates…", checkForUpdates, target))
        appMenu.addItem(.separator())
        appMenu.addItem(item("Settings…", settings, target, key: ","))
        appMenu.addItem(item("Report a Problem…", report, target))
        appMenu.addItem(.separator())
        // Ctrl+Cmd+S also works while the VM window has the keyboard (WindowController.processKey).
        let suspendItem = item("Suspend", suspend, target, key: "s")
        suspendItem.keyEquivalentModifierMask = [.command, .control]
        appMenu.addItem(suspendItem)
        appMenu.addItem(item("Restart VM", restart, target))
        appMenu.addItem(item("Shut Down SteamOS", shutdown, target))
        appMenu.addItem(item("Force Quit", forceQuit, target))
        appMenu.addItem(.separator())
        // Lifecycle.applicationShouldTerminate decides (shut down; asks first while suspended).
        // While the VM window has the keyboard, Cmd+Q goes to the guest like every key.
        appMenu.addItem(NSMenuItem(title: tr("Quit FX Steam Launcher"), action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q"))
        addEditAndWindowMenus(main)
        let viewItem = NSMenuItem()
        main.insertItem(viewItem, at: 2)
        let viewMenu = NSMenu(title: tr("View"))
        viewItem.submenu = viewMenu
        viewMenu.addItem(item("Toggle Full Screen (Ctrl+Cmd+F)", fullscreen, target))
        viewMenu.addItem(item("Grab Pointer (Ctrl+Cmd+G; Ctrl+Option releases)", grab, target))
        viewMenu.addItem(item("Show Boot Progress", overlay, target))
        // Ticked by the target's validateMenuItem (follows Settings > Display and Ctrl+Cmd+P).
        viewMenu.addItem(item("Show Metal Performance HUD (Ctrl+Cmd+P)", metalHUD, target))
        let help = NSMenu(title: tr("Help"))
        help.addItem(item("Report a Problem…", report, target))
        let helpItem = NSMenuItem()
        helpItem.submenu = help
        main.addItem(helpItem)
        NSApp.mainMenu = main
        NSApp.helpMenu = help
    }

    /// App menu with Settings… and Quit only (first-run sheet, --selftest-settings).
    static func installMinimal(settings: (Selector, AnyObject)? = nil) {
        let main = NSMenu()
        let appItem = NSMenuItem()
        main.addItem(appItem)
        let appMenu = NSMenu()
        appItem.submenu = appMenu
        if let (action, target) = settings { appMenu.addItem(item("Settings…", action, target, key: ",")) }
        appMenu.addItem(NSMenuItem(title: tr("Quit FX Steam Launcher"), action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q"))
        addEditAndWindowMenus(main)
        NSApp.mainMenu = main
    }

    /// Standard Edit (text fields in Settings) and Window (Cmd+W closes Settings) menus.
    private static func addEditAndWindowMenus(_ main: NSMenu) {
        let edit = NSMenu(title: tr("Edit"))
        for (title, action, key) in [(tr("Undo"), Selector(("undo:")), "z"), (tr("Redo"), Selector(("redo:")), "Z"),
                                     (tr("Cut"), #selector(NSText.cut(_:)), "x"), (tr("Copy"), #selector(NSText.copy(_:)), "c"),
                                     (tr("Paste"), #selector(NSText.paste(_:)), "v"),
                                     (tr("Select All"), #selector(NSText.selectAll(_:)), "a")] {
            edit.addItem(NSMenuItem(title: title, action: action, keyEquivalent: key))
        }
        let editItem = NSMenuItem()
        editItem.submenu = edit
        main.addItem(editItem)
        let window = NSMenu(title: tr("Window"))
        window.addItem(NSMenuItem(title: tr("Close"), action: #selector(NSWindow.performClose(_:)), keyEquivalent: "w"))
        window.addItem(NSMenuItem(title: tr("Minimize"), action: #selector(NSWindow.performMiniaturize(_:)), keyEquivalent: "m"))
        let windowItem = NSMenuItem()
        windowItem.submenu = window
        main.addItem(windowItem)
        NSApp.windowsMenu = window
    }

    private static func item(_ title: String, _ action: Selector, _ target: AnyObject, key: String = "") -> NSMenuItem {
        let i = NSMenuItem(title: tr(title), action: action, keyEquivalent: key)
        i.target = target
        return i
    }
}
