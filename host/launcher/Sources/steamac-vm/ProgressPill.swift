import AppKit
import QuartzCore

/// Compact boot / shutdown progress at the bottom centre of the VM picture (FX overlay colors):
/// spinner, stage text, percent, a thin bar and the detail line (e.g. "378 / 564 MB · 1.9 MB/s").
/// Shown before `ready` whenever the full overlay is not up (the first click / key collapses the
/// overlay into it, Settings > General turned the overlay off), and after `ready` for the
/// no-picture guard. Input passes through everywhere except on the pill itself, where a click
/// (when `clickable`) calls `onClick` (expand back to the full overlay). When hidden it is
/// `isHidden` with every animation removed.
final class ProgressPillView: NSView {
    struct Content: Equatable {
        var title: String
        var detail: String
        /// 0...1 bar and percent; nil = no bar.
        var fraction: Double?
        var indeterminate = false

        init(title: String, detail: String, fraction: Double?, indeterminate: Bool = false) {
            self.title = title
            self.detail = detail
            self.fraction = fraction
            self.indeterminate = indeterminate
        }

        init(_ s: ProgressState) {
            self.init(title: s.title, detail: s.detail, fraction: s.fraction, indeterminate: s.indeterminate)
        }

        var percentText: String {
            guard let fraction, !indeterminate else { return "" }
            return "\(Int((fraction * 100).rounded(.down)))%"
        }
    }

    private let card = CALayer()
    private let spinTrack = CAShapeLayer()
    private let arc = CAShapeLayer()
    private let titleLayer = CATextLayer()
    private let percentLayer = CATextLayer()
    private let detailLayer = CATextLayer()
    private let barTrack = CALayer()
    private let barFill = CAGradientLayer()
    private(set) var content = Content(title: "", detail: "", fraction: nil)
    private(set) var shown = false
    private var fading = false
    /// Click on the pill (only while `clickable` says so).
    var onClick: (() -> Void)?
    var clickable: () -> Bool = { false }

    /// The pill, in view coordinates (self-test pixel checks, control clicks).
    var cardFrame: CGRect { card.frame }
    /// The bar track, in view coordinates; empty without a bar.
    var barFrame: CGRect { barTrack.isHidden ? .zero : barTrack.frame.offsetBy(dx: card.frame.minX, dy: card.frame.minY) }

    override init(frame: NSRect) {
        super.init(frame: frame)
        wantsLayer = true
        layer = CALayer()
        autoresizingMask = [.width, .height]
        card.backgroundColor = OverlayView.color(0x171a21, 0.9)
        card.borderColor = OverlayView.color(0x66c0f4, 0.22)
        card.borderWidth = 1
        card.shadowColor = OverlayView.color(0x000000)
        card.shadowOpacity = 0.5
        card.shadowOffset = CGSize(width: 0, height: -2)
        spinTrack.fillColor = nil
        spinTrack.strokeColor = OverlayView.color(0xffffff, 0.1)
        arc.fillColor = nil
        arc.strokeColor = OverlayView.color(0x66c0f4)
        arc.lineCap = .round
        arc.strokeEnd = 0.7
        for t in [titleLayer, percentLayer, detailLayer] {
            t.alignmentMode = .left
            t.truncationMode = .end
            t.isWrapped = false
            card.addSublayer(t)
        }
        percentLayer.alignmentMode = .right
        barTrack.backgroundColor = OverlayView.color(0xffffff, 0.08)
        barTrack.masksToBounds = true
        barFill.colors = [OverlayView.color(0x1a9fff), OverlayView.color(0x66c0f4)]
        barFill.startPoint = CGPoint(x: 0, y: 0.5)
        barFill.endPoint = CGPoint(x: 1, y: 0.5)
        barFill.anchorPoint = CGPoint(x: 0, y: 0.5)
        barTrack.addSublayer(barFill)
        card.addSublayer(barTrack)
        card.addSublayer(spinTrack)
        card.addSublayer(arc)
        layer!.addSublayer(card)
        alphaValue = 0
        isHidden = true
    }

    required init?(coder: NSCoder) { fatalError() }

    override var isOpaque: Bool { false }

    private var acceptsClick: Bool { shown && onClick != nil && clickable() }

    /// The click that activates the window expands the pill too (as clicks reach the guest).
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    override func hitTest(_ point: NSPoint) -> NSView? {
        guard !isHidden, acceptsClick, let superview else { return nil }
        return card.frame.contains(convert(point, from: superview)) ? self : nil
    }

    override func mouseDown(with event: NSEvent) {
        guard acceptsClick, card.frame.contains(convert(event.locationInWindow, from: nil)) else { return }
        onClick?()
    }

    override func resetCursorRects() {
        if acceptsClick { addCursorRect(card.frame, cursor: .pointingHand) }
    }

    // MARK: visibility

    /// Fade in (0.25 s) and start the spinner.
    func show() {
        guard !shown || fading else { return }
        shown = true
        fading = false
        isHidden = false
        needsLayout = true
        layoutSubtreeIfNeeded()
        startAnimations()
        window?.invalidateCursorRects(for: self)
        NSAnimationContext.runAnimationGroup { ctx in
            ctx.duration = 0.25
            animator().alphaValue = 1
        }
    }

    /// Fade out (0.5 s), then hide and drop every animation.
    func hide() {
        guard shown, !fading else { return }
        shown = false
        fading = true
        window?.invalidateCursorRects(for: self)
        NSAnimationContext.runAnimationGroup({ ctx in
            ctx.duration = 0.5
            animator().alphaValue = 0
        }, completionHandler: { [weak self] in
            guard let self else { return }
            self.fading = false
            guard !self.shown else { return }
            self.isHidden = true
            self.allLayers.forEach { $0.removeAllAnimations() }
        })
    }

    private var allLayers: [CALayer] { [layer!, card, spinTrack, arc, titleLayer, percentLayer, detailLayer, barTrack, barFill] }

    /// True when hidden and idle (no layer animations running).
    var isIdle: Bool { isHidden && allLayers.allSatisfy { ($0.animationKeys() ?? []).isEmpty } }

    private func startAnimations() {
        let a = CABasicAnimation(keyPath: "transform.rotation.z")
        a.fromValue = 0
        a.toValue = -2 * Double.pi
        a.duration = 0.9
        a.repeatCount = .infinity
        arc.add(a, forKey: "spin")
        updateIndeterminate()
    }

    // MARK: content

    func update(_ c: Content) {
        guard c != content else { return }
        let old = content
        content = c
        guard shown else { return }
        if (c.fraction == nil) != (old.fraction == nil) {
            needsLayout = true   // bar and percent come or go
            return
        }
        applyText()
        applyBar(animated: true)
        if c.indeterminate != old.indeterminate { updateIndeterminate() }
    }

    private var scaleFactor: CGFloat { max(0.85, min(1.5, min(bounds.width / 1280, bounds.height / 800))) }

    private func text(_ s: String, size: CGFloat, weight: NSFont.Weight, color: UInt32, digits: Bool = false) -> NSAttributedString {
        let font = digits ? NSFont.monospacedDigitSystemFont(ofSize: size, weight: weight) : NSFont.systemFont(ofSize: size, weight: weight)
        return NSAttributedString(string: s, attributes: [.font: font, .foregroundColor: OverlayView.color(color)])
    }

    private func applyText() {
        let k = scaleFactor
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        titleLayer.string = text(content.title, size: 13.5 * k, weight: .semibold, color: 0xc7d5e0)
        percentLayer.string = text(content.percentText, size: 13 * k, weight: .medium, color: 0x66c0f4, digits: true)
        detailLayer.string = text(content.detail, size: 12 * k, weight: .regular, color: 0x8f98a0, digits: true)
        CATransaction.commit()
    }

    private func applyBar(animated: Bool) {
        guard let f = content.fraction, !content.indeterminate else { return }
        CATransaction.begin()
        CATransaction.setDisableActions(!animated)
        CATransaction.setAnimationDuration(0.35)
        barFill.bounds.size.width = barTrack.bounds.width * CGFloat(max(0, min(1, f)))
        CATransaction.commit()
    }

    private func updateIndeterminate() {
        barFill.removeAnimation(forKey: "indeterminate")
        let w = barTrack.bounds.width
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        barFill.position = CGPoint(x: 0, y: barTrack.bounds.midY)
        if content.indeterminate {
            barFill.bounds.size.width = w * 0.28
            if shown {
                let a = CABasicAnimation(keyPath: "position.x")
                a.fromValue = -w * 0.28
                a.toValue = w
                a.duration = 1.4
                a.repeatCount = .infinity
                a.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
                barFill.add(a, forKey: "indeterminate")
            }
        } else {
            barFill.bounds.size.width = w * CGFloat(max(0, min(1, content.fraction ?? 0)))
        }
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
        // Fixed width: live MB/s updates never make the pill jump.
        let width = min(b.width - 32, (460 * k).rounded())
        let height = (64 * k).rounded()
        let pad = 16 * k, spin = 22 * k, gap = 13 * k
        let textX = pad + spin + gap
        let textW = max(0, width - textX - pad)
        let percentW = 52 * k
        let barH = max(2, (3 * k).rounded())
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        allLayers.forEach { $0.contentsScale = scale }
        card.frame = CGRect(x: ((b.width - width) / 2).rounded(), y: (22 * k).rounded(), width: width, height: height)
        card.cornerRadius = 14 * k
        card.shadowRadius = 16 * k
        card.shadowPath = CGPath(roundedRect: card.bounds, cornerWidth: card.cornerRadius, cornerHeight: card.cornerRadius, transform: nil)
        let line = max(2, 2.4 * k)
        let circle = CGPath(ellipseIn: CGRect(x: line / 2, y: line / 2, width: spin - line, height: spin - line), transform: nil)
        for s in [spinTrack, arc] {
            s.frame = CGRect(x: pad, y: ((height - spin) / 2).rounded(), width: spin, height: spin)
            s.path = circle
            s.lineWidth = line
        }
        let hasBar = content.fraction != nil
        let titleH = 18 * k, detailH = 16 * k
        let titleY = hasBar ? height - 10 * k - titleH : height / 2 + 1 * k
        titleLayer.frame = CGRect(x: textX, y: titleY, width: textW - (hasBar ? percentW : 0), height: titleH).integral
        percentLayer.frame = CGRect(x: textX + textW - percentW, y: titleY, width: percentW, height: titleH).integral
        percentLayer.isHidden = !hasBar
        barTrack.isHidden = !hasBar
        barTrack.frame = CGRect(x: textX, y: titleY - 6 * k - barH, width: textW, height: barH).integral
        barTrack.cornerRadius = barH / 2
        barFill.cornerRadius = barH / 2
        barFill.bounds = CGRect(x: 0, y: 0, width: barFill.bounds.width, height: barTrack.bounds.height)
        let detailY = hasBar ? 8 * k : height / 2 - 1 * k - detailH
        detailLayer.frame = CGRect(x: textX, y: detailY, width: textW, height: detailH).integral
        CATransaction.commit()
        applyText()
        updateIndeterminate()
        window?.invalidateCursorRects(for: self)
    }
}

/// "Waiting for SteamOS to draw…" after `ready`: the window has had no guest picture at all for
/// `missingThreshold` (scanout off, or no frame since the last scanout set / resize) or the
/// presented picture has been black for `blackThreshold`, while Steam or the desktop has focus
/// and SteamOS neither sleeps nor is paused / suspended (a game's idle GPU is the GPU-idle card's
/// job). The report says what is known: a guest detail line received after `ready` if any, why
/// (display off / no frame / black picture), the heartbeat and the VM's CPU. It ends with the
/// first non-black frame. Black = at least `blackFraction` of Scanout's sparse sample points
/// below its luma threshold; a frame is sampled only when a newer one was presented, at most
/// once per `tick`. Main thread only.
final class NoPictureGuard {
    struct Report: Equatable {
        var title: String
        var detail: String
    }

    static let tick: TimeInterval = 0.25
    static let missingThreshold: TimeInterval = 3
    static let blackThreshold: TimeInterval = 5
    static let blackFraction = 0.995
    static let title = String(localized: "Waiting for SteamOS to draw…")

    private let probe: (UInt64) -> Scanout.Probe
    private var timer: DispatchSourceTimer?
    /// `presented` of the last sampled frame (`.max`: sample the current one).
    private var seen = UInt64.max
    /// Darkness of the latest sampled frame of the current picture.
    private var lastDark: Double?
    /// No picture since (scanout off, or no frame since the last set / resize).
    private var missingSince: CFTimeInterval?
    /// No picture or a black one since; a non-black frame resets it.
    private var darkSince: CFTimeInterval?
    private var shownSince: CFTimeInterval?
    private var lastAlive: CFTimeInterval = 0
    private var cpuSamples: [(CFTimeInterval, Double)] = []

    /// Steam is ready (the boot overlay / pill is gone; the guest is not shutting down).
    var ready = false { didSet { if ready != oldValue { gateChanged("not ready") } } }
    /// A game has focus: the GPU-idle card covers games.
    var gameFocused = false { didSet { if gameFocused != oldValue { gateChanged("game focused") } } }
    /// "Game paused" (GamePause confirmed a frozen game).
    var gamePaused = false { didSet { if gamePaused != oldValue { gateChanged("game paused") } } }
    /// SteamOS sleeps.
    var asleep = false { didSet { if asleep != oldValue { gateChanged("SteamOS asleep") } } }
    /// The VM is paused (suspend, guest sleep).
    var vmPaused = false { didSet { if vmPaused != oldValue { gateChanged("VM paused") } } }
    /// A guest detail line received after `ready` (`log …`), if any.
    var lastKnown: () -> String? = { nil }
    /// Report to show, or nil to hide.
    var onChange: ((Report?) -> Void)?
    private(set) var report: Report?

    init(probe: @escaping (UInt64) -> Scanout.Probe) {
        self.probe = probe
    }

    private var gateOpen: Bool { ready && !gameFocused && !gamePaused && !asleep && !vmPaused }

    func start() {
        guard timer == nil else { return }
        let t = DispatchSource.makeTimerSource(queue: .main)
        t.schedule(deadline: .now() + NoPictureGuard.tick, repeating: NoPictureGuard.tick, leeway: .milliseconds(20))
        t.setEventHandler { [weak self] in self?.poll() }
        t.resume()
        timer = t
    }

    /// Guest heartbeat (`alive <uptime_ms> <loadavg1>`).
    func alive() { lastAlive = CACurrentMediaTime() }

    /// The agent ended with the gamescope session (bare `focus desktop`): no heartbeat is expected.
    func heartbeatsEnded() { lastAlive = 0 }

    /// Closed: hide at once. Opened: the clocks start now (stale dark time never counts).
    private func gateChanged(_ closedBy: String) {
        missingSince = nil
        darkSince = nil
        lastDark = nil
        seen = .max
        cpuSamples.removeAll()
        if !gateOpen { hide(closedBy) }
    }

    private func poll() {
        guard gateOpen else { return }
        let now = CACurrentMediaTime()
        let p = probe(seen)
        if let d = p.dark {
            seen = p.presented
            lastDark = d
        }
        let missing = !p.enabled || !p.hasPicture
        if missing {
            lastDark = nil
            if missingSince == nil { missingSince = now }
            if darkSince == nil { darkSince = now }
        } else {
            missingSince = nil
            if let d = lastDark {
                if d >= NoPictureGuard.blackFraction {
                    if darkSince == nil { darkSince = now }
                } else if darkSince != nil {
                    darkSince = nil
                    hide("first non-black frame")
                }
            }
        }
        noteCPU(now)
        let reason = missing ? (p.enabled ? "no frame" : "display off") : "black picture"
        if shownSince == nil {
            let due = missing ? now - (missingSince ?? now) >= NoPictureGuard.missingThreshold
                              : now - (darkSince ?? now) >= NoPictureGuard.blackThreshold
            guard due, let since = darkSince else { return }
            shownSince = since
            log("no-picture: shown after \(String(format: "%.1f", now - since)) s (\(reason)"
                + (missing ? "" : String(format: " %.1f%%", (lastDark ?? 1) * 100)) + "; \(status(now)))")
        }
        guard let since = shownSince else { return }
        var parts: [String] = []
        if let known = lastKnown(), !known.isEmpty { parts.append(known) }
        let seconds = Int(now - since)
        parts.append(missing
            ? (p.enabled ? String(localized: "no frame \(seconds) s") : String(localized: "display off \(seconds) s"))
            : String(localized: "black picture \(seconds) s"))
        if let guest = guestText(now) { parts.append(guest) }
        let cores = String(format: "%.1f", cpu())
        parts.append(String(localized: "VM CPU \(cores) cores"))
        let r = Report(title: NoPictureGuard.title, detail: parts.joined(separator: " · "))
        if r != report {
            report = r
            onChange?(r)
        }
    }

    private func hide(_ why: String) {
        guard let since = shownSince else { return }
        shownSince = nil
        report = nil
        log("no-picture: hidden after \(String(format: "%.1f", CACurrentMediaTime() - since)) s (\(why))")
        onChange?(nil)
    }

    // MARK: wording

    private func guestText(_ now: CFTimeInterval) -> String? {
        guard lastAlive > 0 else { return nil }
        let age = now - lastAlive
        return age > StallMonitor.heartbeatTimeout
            ? String(localized: "guest not responding for \(Int(age)) s")
            : String(localized: "guest alive")
    }

    private func status(_ now: CFTimeInterval) -> String {
        let guest: String
        if lastAlive > 0 {
            let age = now - lastAlive
            guest = age > StallMonitor.heartbeatTimeout ? "guest not responding for \(Int(age)) s" : "guest alive"
        } else {
            guest = "no guest heartbeat"
        }
        return guest + ", CPU \(String(format: "%.1f", cpu())) cores"
    }

    private func noteCPU(_ now: CFTimeInterval) {
        cpuSamples.append((now, StallMonitor.cpuSeconds()))
        while let first = cpuSamples.first, now - first.0 > 1.01, cpuSamples.count > 2 { cpuSamples.removeFirst() }
    }

    /// Cores this process (vCPUs included) kept busy over the last second.
    private func cpu() -> Double {
        guard cpuSamples.count >= 2, let a = cpuSamples.first, let b = cpuSamples.last, b.0 > a.0 else { return 0 }
        return max(0, (b.1 - a.1) / (b.0 - a.0))
    }
}
