import AppKit
import Darwin
import QuartzCore

/// "Still working" indicator (Settings > General). Shown after `ready`, never during the
/// boot/shutdown overlay, when the guest sends no GPU work for `idleThreshold` while a game has
/// focus (`focus game <appid>`; the idle Steam UI legitimately sends none for minutes), or —
/// whatever has focus — when the guest's heartbeat has also stopped for `heartbeatTimeout`.
/// Hidden as soon as GPU work arrives, the game loses focus or the guest answers again. No
/// heartbeat is expected between sessions (the agent ends with each gamescope session, gaming or
/// Desktop Mode), and both clocks start over after the VM was paused (suspend, guest sleep) or
/// the Mac slept.
///
/// GPU work = libkrun's krun_gpu_get_activity counters (libkrun patch 0015), sampled every
/// `tick`: virtio-gpu control-queue commands (SUBMIT_3D, RESOURCE_FLUSH, SET_SCANOUT*, …) and
/// Venus commands virglrenderer dispatched from its in-process rings (virglrenderer patch 0009).
/// The idle window starts at the latest of: last GPU work, gate opening (overlay gone, setting
/// on), the game getting focus — so stale idle time never fires at once. The wording comes from
/// the guest agent's heartbeat (`alive <uptime_ms> <loadavg1>` once a second over fx.progress)
/// and this process's CPU time (vCPU threads included): alive → "Still working…" + CPU, no
/// heartbeat for `heartbeatTimeout` → "SteamOS is not responding…". With perf stats on it also
/// logs the counter rates and the longest idle stretch every 5 s. Main thread only.
final class StallMonitor {
    typealias Counters = (ctrl: UInt64, ring: UInt64)

    static let idleThreshold: TimeInterval = 2
    static let heartbeatTimeout: TimeInterval = 5
    static let tick: TimeInterval = 0.25
    static let perfPeriod: TimeInterval = 5

    let view: StallIndicatorView
    /// nil = no counters (VM not running, no GPU): never shows.
    private let sample: () -> Counters?
    private var timer: DispatchSourceTimer?
    private var counters: Counters?
    private var countersAvailable = false
    private var lastActivity = CACurrentMediaTime()
    private var cpuAtActivity = StallMonitor.cpuSeconds()
    /// When the gate last opened (enabled, not suppressed, game focus): idle time counts from
    /// here at the earliest.
    private var gateOpenedAt = CACurrentMediaTime()
    private var lastAlive: CFTimeInterval = 0
    private var guestLoad = 0.0
    /// Per-second CPU readings while shown: (time, process CPU seconds).
    private var cpuSamples: [(CFTimeInterval, Double)] = []
    private var shownSince: (idleStart: CFTimeInterval, cpu: Double)?
    private var notRespondingReported = false
    // perf stats window
    private var perfStart: CFTimeInterval = 0
    private var perfCounters: Counters?
    private var perfLongestIdle: CFTimeInterval = 0

    /// Settings > General "Show indicator when the GPU goes idle".
    var enabled = true { didSet { if enabled != oldValue { gateChanged() } } }
    /// Before `ready`, boot / shutdown overlay on screen, or the guest is shutting down.
    var suppressed = true { didSet { if suppressed != oldValue { gateChanged() } } }
    /// A game has focus in the guest (`focus game <appid>`).
    var gameFocused = false { didSet { if gameFocused != oldValue { gateChanged() } } }
    /// The focused game is frozen (GamePause): an idle GPU is expected.
    var paused = false { didSet { if paused != oldValue { gateChanged() } } }
    /// The indicator is up (or about to fade in).
    var indicatorShown: Bool { shownSince != nil }
    /// Once per indicator stretch, when its wording turns to "SteamOS is not responding…"
    /// (argument: GPU idle seconds so far).
    var onNotResponding: ((TimeInterval) -> Void)?

    init(view: StallIndicatorView, sample: @escaping () -> Counters?) {
        self.view = view
        self.sample = sample
    }

    func start() {
        guard timer == nil else { return }
        let t = DispatchSource.makeTimerSource(queue: .main)
        t.schedule(deadline: .now() + StallMonitor.tick, repeating: StallMonitor.tick, leeway: .milliseconds(20))
        t.setEventHandler { [weak self] in self?.poll() }
        t.resume()
        timer = t
    }

    func stop() {
        timer?.cancel()
        timer = nil
        hide(reason: "stopped")
    }

    /// The VM ran again after a pause (suspend, guest sleep) or the Mac woke from sleep (stopped
    /// meanwhile): the guest could neither send GPU work nor heartbeats, so idle time and
    /// heartbeat age start over.
    func resumeAfterSuspend() {
        let now = CACurrentMediaTime()
        lastActivity = now
        cpuAtActivity = StallMonitor.cpuSeconds()
        gateOpenedAt = now
        if lastAlive > 0 { lastAlive = now }
        counters = nil
        start()
    }

    /// Guest heartbeat (`alive <uptime_ms> <loadavg1>`).
    func alive(uptimeMs: Int, load: Double) {
        lastAlive = CACurrentMediaTime()
        guestLoad = load
    }

    /// The agent ended with the gamescope session (bare `focus desktop`: Switch to Desktop, Return
    /// to Gaming Mode, relogin): no heartbeat is expected until the next session's agent sends one.
    func heartbeatsEnded() {
        guard lastAlive > 0 else { return }
        lastAlive = 0
        log("stall: guest agent ended with its session; no heartbeat expected until it is back")
        evaluate(CACurrentMediaTime())
    }

    private var gateOpen: Bool { enabled && !suppressed && !paused }

    /// Any gate input changed: a newly opened window starts now; a closed one hides at once.
    private func gateChanged() {
        let now = CACurrentMediaTime()
        if gateOpen { gateOpenedAt = now }
        evaluate(now)
    }

    // MARK: sampling

    private func poll() {
        let now = CACurrentMediaTime()
        let c = sample()
        let active: Bool
        if let c, let prev = counters { active = c != prev } else { active = false }
        if let c { counters = c }
        perfNote(now: now, counters: c, active: active)
        if active {
            hide(reason: nil, now: now)
            lastActivity = now
            cpuAtActivity = StallMonitor.cpuSeconds()
            return
        }
        countersAvailable = c != nil
        evaluate(now)
    }

    /// Show / refresh / hide the indicator for the current state (no GPU work since `lastActivity`).
    private func evaluate(_ now: CFTimeInterval) {
        let dead = notResponding()
        // Durations shown and logged are the GPU's whole idle time.
        guard countersAvailable, gateOpen, gameFocused || dead,
              now - max(lastActivity, gateOpenedAt) >= StallMonitor.idleThreshold else {
            if shownSince != nil {
                hide(reason: !enabled ? "setting off" : suppressed ? "overlay"
                     : notRespondingReported && !dead ? "guest responding again" : "game focus lost", now: now)
            }
            return
        }
        noteCPU(now)
        let starting = shownSince == nil
        if starting { shownSince = (lastActivity, cpuAtActivity) }
        let (title, detail) = text(now: now, idle: now - lastActivity)
        view.showsReportLink = dead
        view.update(title: title, detail: detail)
        if starting {
            view.show()
            log("stall: gpu idle \(String(format: "%.1f", now - lastActivity)) s, indicator shown (\(status(now)))")
        }
        if !notRespondingReported && dead {
            notRespondingReported = true
            log("stall: guest not responding (no heartbeat for \(Int(heartbeatAge ?? 0)) s, gpu idle \(Int(now - lastActivity)) s)")
            onNotResponding?(now - lastActivity)
        }
    }

    private func hide(reason: String?, now: CFTimeInterval = CACurrentMediaTime()) {
        guard let since = shownSince else { return }
        shownSince = nil
        notRespondingReported = false
        let duration = now - since.idleStart
        let cpu = duration > 0 ? (StallMonitor.cpuSeconds() - since.cpu) / duration : 0
        log("stall: gpu idle \(String(format: "%.1f", duration)) s (\(status(now, cpu: cpu)))"
            + (reason.map { ", ended by \($0)" } ?? ""))
        cpuSamples.removeAll()
        view.hide()
    }

    // MARK: wording

    private var heartbeatAge: CFTimeInterval? { lastAlive > 0 ? CACurrentMediaTime() - lastAlive : nil }

    private func notResponding() -> Bool { (heartbeatAge ?? 0) > StallMonitor.heartbeatTimeout }

    private func text(now: CFTimeInterval, idle: CFTimeInterval) -> (String, String) {
        if notResponding() {
            return (tr("SteamOS is not responding…"), tr("waiting (%@ s)", "\(Int(idle))"))
        }
        let title = tr("Still working — loading or compiling shaders…")
        var detail = tr("VM CPU %@ cores", String(format: "%.1f", currentCPU()))
        if lastAlive > 0 { detail += " · " + tr("guest alive") }
        return (title, detail)
    }

    /// For the log: "guest alive, CPU 2.9 cores".
    private func status(_ now: CFTimeInterval, cpu: Double? = nil) -> String {
        let guest: String
        if let age = heartbeatAge {
            guest = age > StallMonitor.heartbeatTimeout ? "guest not responding for \(Int(age)) s"
                                                        : "guest alive, load \(String(format: "%.2f", guestLoad))"
        } else {
            guest = "no guest heartbeat"
        }
        return "\(guest), CPU \(String(format: "%.1f", cpu ?? currentCPU())) cores"
    }

    // MARK: CPU

    /// User + system CPU time of this process (all threads: vCPUs, GPU worker, renderer).
    static func cpuSeconds() -> Double {
        var ru = rusage()
        getrusage(RUSAGE_SELF, &ru)
        return Double(ru.ru_utime.tv_sec + ru.ru_stime.tv_sec) + Double(ru.ru_utime.tv_usec + ru.ru_stime.tv_usec) / 1e6
    }

    private func noteCPU(_ now: CFTimeInterval) {
        cpuSamples.append((now, StallMonitor.cpuSeconds()))
        // Keep ~1 s of readings (one per tick).
        while let first = cpuSamples.first, now - first.0 > 1.01, cpuSamples.count > 2 { cpuSamples.removeFirst() }
    }

    /// Cores busy over the last second (since the idle start until a second of readings exists).
    private func currentCPU() -> Double {
        if cpuSamples.count >= 2, let a = cpuSamples.first, let b = cpuSamples.last, b.0 - a.0 >= 0.5 {
            return max(0, (b.1 - a.1) / (b.0 - a.0))
        }
        guard let since = shownSince else { return 0 }
        let dt = CACurrentMediaTime() - since.idleStart
        return dt > 0 ? max(0, (StallMonitor.cpuSeconds() - since.cpu) / dt) : 0
    }

    // MARK: perf stats

    private func perfNote(now: CFTimeInterval, counters c: Counters?, active: Bool) {
        guard PerfStats.shared != nil else { perfStart = 0; return }
        if perfStart == 0 {
            perfStart = now
            perfCounters = c
            perfLongestIdle = 0
        }
        if !active { perfLongestIdle = max(perfLongestIdle, now - max(lastActivity, perfStart)) }
        guard now - perfStart >= StallMonitor.perfPeriod - StallMonitor.tick / 2 else { return }
        let dt = now - perfStart
        if let c, let p = perfCounters {
            log(String(format: "perf: gpu ctrl/s=%.1f ring/s=%.1f longest-idle=%.2f s",
                       Double(c.ctrl &- p.ctrl) / dt, Double(c.ring &- p.ring) / dt, perfLongestIdle))
        } else {
            log("perf: gpu counters unavailable")
        }
        perfStart = now
        perfCounters = c
        perfLongestIdle = 0
    }
}

/// The indicator: a translucent card in the lower third with a spinner and two lines of text,
/// over the last guest frame (FX overlay colors). Never takes mouse events, except on its
/// "Report…" link while it says SteamOS is not responding; when hidden it is `isHidden` with
/// every animation removed.
final class StallIndicatorView: NSView {
    private let card = CALayer()
    private let track = CAShapeLayer()
    private let arc = CAShapeLayer()
    private let titleLayer = CATextLayer()
    private let detailLayer = CATextLayer()
    private let linkLayer = CATextLayer()
    private var title = ""
    private var detail = ""
    private(set) var shown = false
    private var fading = false

    var currentTitle: String { title }
    var currentDetail: String { detail }
    /// The card and the spinner, in view coordinates (self-test pixel checks).
    var cardFrame: CGRect { card.frame }
    var spinnerFrame: CGRect { arc.frame.offsetBy(dx: card.frame.minX, dy: card.frame.minY) }
    /// "Report…" on the card (Report a Problem), in view coordinates; empty when not shown.
    var reportLinkFrame: CGRect {
        showsReportLink && onReport != nil ? linkLayer.frame.offsetBy(dx: card.frame.minX, dy: card.frame.minY) : .zero
    }
    /// Opens Report a Problem (the link is shown only when this is set).
    var onReport: (() -> Void)?
    /// The "not responding" wording: show the link.
    var showsReportLink = false {
        didSet {
            guard showsReportLink != oldValue else { return }
            needsLayout = true
            window?.invalidateCursorRects(for: self)
        }
    }

    override init(frame: NSRect) {
        super.init(frame: frame)
        wantsLayer = true
        layer = CALayer()
        autoresizingMask = [.width, .height]
        card.backgroundColor = OverlayView.color(0x171a21, 0.86)
        card.borderColor = OverlayView.color(0x66c0f4, 0.22)
        card.borderWidth = 1
        card.shadowColor = OverlayView.color(0x000000)
        card.shadowOpacity = 0.5
        card.shadowOffset = CGSize(width: 0, height: -2)
        track.fillColor = nil
        track.strokeColor = OverlayView.color(0xffffff, 0.1)
        arc.fillColor = nil
        arc.strokeColor = OverlayView.color(0x66c0f4)
        arc.lineCap = .round
        arc.strokeEnd = 0.7
        for t in [titleLayer, detailLayer, linkLayer] {
            t.alignmentMode = .left
            t.truncationMode = .end
            t.isWrapped = false
            card.addSublayer(t)
        }
        card.addSublayer(track)
        card.addSublayer(arc)
        layer!.addSublayer(card)
        alphaValue = 0
        isHidden = true
    }

    required init?(coder: NSCoder) { fatalError() }

    override func hitTest(_ point: NSPoint) -> NSView? {
        guard !isHidden, alphaValue > 0, let superview else { return nil }
        return reportLinkFrame.contains(convert(point, from: superview)) ? self : nil
    }

    override func mouseDown(with event: NSEvent) {
        guard reportLinkFrame.contains(convert(event.locationInWindow, from: nil)) else { return }
        log("stall: Report… clicked")
        onReport?()
    }

    override func resetCursorRects() {
        if !reportLinkFrame.isEmpty { addCursorRect(reportLinkFrame, cursor: .pointingHand) }
    }

    override var isOpaque: Bool { false }

    // MARK: visibility

    /// Fade in (0.25 s) and start the spinner.
    func show() {
        guard !shown || fading else { return }
        shown = true
        fading = false
        isHidden = false
        needsLayout = true
        layoutSubtreeIfNeeded()
        startSpinner()
        NSAnimationContext.runAnimationGroup { ctx in
            ctx.duration = 0.25
            animator().alphaValue = 1
        }
    }

    /// Fade out (0.2 s), then hide and drop every animation.
    func hide() {
        guard shown, !fading else { return }
        shown = false
        fading = true
        NSAnimationContext.runAnimationGroup({ ctx in
            ctx.duration = 0.2
            animator().alphaValue = 0
        }, completionHandler: { [weak self] in
            guard let self else { return }
            self.fading = false
            guard !self.shown else { return }
            self.isHidden = true
            for l in [self.layer!, self.card, self.track, self.arc, self.titleLayer, self.detailLayer, self.linkLayer] { l.removeAllAnimations() }
        })
    }

    /// True when hidden and idle (no layer animations running).
    var isIdle: Bool {
        isHidden && [layer!, card, track, arc, titleLayer, detailLayer, linkLayer].allSatisfy { ($0.animationKeys() ?? []).isEmpty }
    }

    private func startSpinner() {
        let a = CABasicAnimation(keyPath: "transform.rotation.z")
        a.fromValue = 0
        a.toValue = -2 * Double.pi
        a.duration = 0.9
        a.repeatCount = .infinity
        arc.add(a, forKey: "spin")
    }

    // MARK: content

    func update(title: String, detail: String) {
        guard title != self.title || detail != self.detail else { return }
        // Same-length details (monospaced digits) keep the card's width: no relayout.
        let resize = title != self.title || detail.count != self.detail.count
        self.title = title
        self.detail = detail
        if resize { needsLayout = true } else { applyText() }
    }

    private var scaleFactor: CGFloat { max(0.85, min(1.6, min(bounds.width / 1280, bounds.height / 800))) }

    private var titleString: NSAttributedString {
        NSAttributedString(string: title, attributes: [
            .font: NSFont.systemFont(ofSize: 15 * scaleFactor, weight: .semibold),
            .foregroundColor: OverlayView.color(0xc7d5e0)])
    }

    private var detailString: NSAttributedString {
        NSAttributedString(string: detail, attributes: [
            .font: NSFont.monospacedDigitSystemFont(ofSize: 12 * scaleFactor, weight: .regular),
            .foregroundColor: OverlayView.color(0x8f98a0)])
    }

    private var linkString: NSAttributedString {
        NSAttributedString(string: tr("Report…"), attributes: [
            .font: NSFont.systemFont(ofSize: 13 * scaleFactor, weight: .semibold),
            .foregroundColor: OverlayView.color(0x66c0f4),
            .underlineStyle: NSUnderlineStyle.single.rawValue])
    }

    private func applyText() {
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        titleLayer.string = titleString
        detailLayer.string = detailString
        CATransaction.commit()
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
        let b = bounds
        let k = scaleFactor
        let scale = window?.backingScaleFactor ?? NSScreen.main?.backingScaleFactor ?? 2
        let t = titleString, d = detailString
        let link = showsReportLink && onReport != nil ? linkString : nil
        let pad = 18 * k, spin = 26 * k, gap = 14 * k
        let textWidth = ceil(max(t.size().width, d.size().width)) + 2
        let linkWidth = link.map { ceil($0.size().width) + 2 } ?? 0
        let linkSpace = link == nil ? 0 : gap + linkWidth
        let width = min(b.width - 32, pad + spin + gap + textWidth + linkSpace + pad + 4 * k)
        let height = 62 * k
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        for l in [layer!, card, track, arc, titleLayer, detailLayer, linkLayer] { l.contentsScale = scale }
        card.frame = CGRect(x: (b.width - width) / 2, y: (b.height * 0.26 - height / 2).rounded(), width: width, height: height).integral
        card.cornerRadius = 14 * k
        card.shadowRadius = 18 * k
        card.shadowPath = CGPath(roundedRect: card.bounds, cornerWidth: card.cornerRadius, cornerHeight: card.cornerRadius, transform: nil)
        let spinFrame = CGRect(x: pad, y: (height - spin) / 2, width: spin, height: spin)
        let line = max(2, 2.6 * k)
        let circle = CGPath(ellipseIn: CGRect(x: line / 2, y: line / 2, width: spin - line, height: spin - line), transform: nil)
        for s in [track, arc] {
            s.frame = spinFrame
            s.path = circle
            s.lineWidth = line
        }
        let textX = pad + spin + gap
        let textW = max(0, width - textX - pad - linkSpace)
        titleLayer.frame = CGRect(x: textX, y: height / 2 + 1 * k, width: textW, height: 20 * k)
        detailLayer.frame = CGRect(x: textX, y: height / 2 - 18 * k, width: textW, height: 16 * k)
        linkLayer.frame = link == nil ? .zero : CGRect(x: width - pad - linkWidth, y: (height - 18 * k) / 2, width: linkWidth, height: 18 * k)
        titleLayer.string = t
        detailLayer.string = d
        linkLayer.string = link
        linkLayer.isHidden = link == nil
        CATransaction.commit()
        window?.invalidateCursorRects(for: self)
    }

    /// Render the indicator (model values) over `background` at `scale` pixels per point.
    func renderImage(scale: CGFloat, under background: CGImage?) -> CGImage? {
        renderLayerImage(scale: scale, under: background)
    }
}

extension NSView {
    /// This layer-backed view (if shown) over `background` at `scale` pixels per point: window
    /// dumps of the cards over the guest frame. A hidden view returns a `background` of that size
    /// as is (no copy on the main thread).
    func renderLayerImage(scale: CGFloat, under background: CGImage?) -> CGImage? {
        let w = Int(bounds.width * scale), h = Int(bounds.height * scale)
        let visible = !isHidden && alphaValue > 0
        if !visible, let background, background.width == w, background.height == h { return background }
        guard let ctx = CGContext(data: nil, width: w, height: h, bitsPerComponent: 8, bytesPerRow: w * 4,
                                  space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                  bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return nil }
        if let background { ctx.draw(background, in: CGRect(x: 0, y: 0, width: w, height: h)) }
        if visible, let layer {
            ctx.saveGState()
            ctx.setAlpha(alphaValue)
            ctx.scaleBy(x: scale, y: scale)
            layer.render(in: ctx)
            ctx.restoreGState()
        }
        return ctx.makeImage()
    }
}
