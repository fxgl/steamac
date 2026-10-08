import AppKit
import QuartzCore

/// "Game paused" over the VM picture while GamePause has the focused game frozen (the launcher
/// is in the background): the last frame dimmed to 65 % plus a card in the FX overlay style with
/// a pause icon, the game's name (if known) and "Click to resume". Input passes through to the
/// window controller, which swallows the resuming click (WindowController.pointerButton).
/// Style `.sleeping`: "SteamOS is sleeping" with a moon while the guest sleeps (the VM is paused,
/// SuspendController); the controller turns the first click, key or controller button into a wake.
final class PauseOverlayView: NSView {
    enum Style { case gamePaused, sleeping }

    let style: Style
    private let dim = CALayer()
    private let card = CALayer()
    private let barLeft = CALayer()
    private let barRight = CALayer()
    private let moon = CAShapeLayer()
    private let titleLayer = CATextLayer()
    private let nameLayer = CATextLayer()
    private let detailLayer = CATextLayer()
    private var name: String?
    private(set) var shown = false
    private var fading = false

    static let dimAlpha: CGFloat = 0.35
    /// Steam has usually dimmed its UI already; the frame stays recognisable but clearly asleep.
    static let sleepDimAlpha: CGFloat = 0.55

    init(frame: NSRect, style: Style = .gamePaused) {
        self.style = style
        super.init(frame: frame)
        wantsLayer = true
        layer = CALayer()
        autoresizingMask = [.width, .height]
        dim.backgroundColor = OverlayView.color(0x000000, style == .sleeping ? PauseOverlayView.sleepDimAlpha : PauseOverlayView.dimAlpha)
        card.backgroundColor = OverlayView.color(0x171a21, 0.88)
        card.borderColor = OverlayView.color(0x66c0f4, 0.22)
        card.borderWidth = 1
        card.shadowColor = OverlayView.color(0x000000)
        card.shadowOpacity = 0.5
        card.shadowOffset = CGSize(width: 0, height: -2)
        switch style {
        case .gamePaused:
            for b in [barLeft, barRight] {
                b.backgroundColor = OverlayView.color(0x66c0f4)
                card.addSublayer(b)
            }
        case .sleeping:
            moon.fillColor = OverlayView.color(0x66c0f4)
            moon.fillRule = .evenOdd
            card.addSublayer(moon)
        }
        for t in [titleLayer, nameLayer, detailLayer] {
            t.alignmentMode = .center
            t.truncationMode = .end
            t.isWrapped = false
            card.addSublayer(t)
        }
        layer!.addSublayer(dim)
        layer!.addSublayer(card)
        alphaValue = 0
        isHidden = true
    }

    required init?(coder: NSCoder) { fatalError() }

    /// Clicks go to the VM view (the controller decides what to swallow).
    override func hitTest(_ point: NSPoint) -> NSView? { nil }
    override var isOpaque: Bool { false }

    /// The card, in view coordinates (self-test pixel checks).
    var cardFrame: CGRect { card.frame }
    var currentName: String? { name }

    func show(gameName: String?) {
        if gameName != name {
            name = gameName
            needsLayout = true
        }
        guard !shown || fading else { return }
        shown = true
        fading = false
        isHidden = false
        needsLayout = true
        layoutSubtreeIfNeeded()
        NSAnimationContext.runAnimationGroup { ctx in
            ctx.duration = 0.2
            animator().alphaValue = 1
        }
    }

    /// Fade out (0.25 s), then hide.
    func hide(animated: Bool = true) {
        guard shown else { return }
        shown = false
        guard animated else {
            fading = false
            alphaValue = 0
            isHidden = true
            return
        }
        fading = true
        NSAnimationContext.runAnimationGroup({ ctx in
            ctx.duration = 0.25
            animator().alphaValue = 0
        }, completionHandler: { [weak self] in
            guard let self else { return }
            self.fading = false
            if !self.shown { self.isHidden = true }
        })
    }

    private var scaleFactor: CGFloat { max(0.85, min(1.6, min(bounds.width / 1280, bounds.height / 800))) }

    private func text(_ s: String, size: CGFloat, weight: NSFont.Weight, color: UInt32) -> NSAttributedString {
        NSAttributedString(string: s, attributes: [
            .font: NSFont.systemFont(ofSize: size * scaleFactor, weight: weight),
            .foregroundColor: OverlayView.color(color)])
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
        let s = scaleFactor
        let scale = window?.backingScaleFactor ?? 2
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        dim.frame = bounds
        let title, detail: NSAttributedString
        switch style {
        case .gamePaused:
            title = text(tr("Game paused"), size: 20, weight: .semibold, color: 0xc7d5e0)
            detail = text(tr("Click to resume"), size: 12, weight: .regular, color: 0x8f98a0)
        case .sleeping:
            title = text(tr("SteamOS is sleeping"), size: 20, weight: .semibold, color: 0xc7d5e0)
            detail = text(tr("Click or press a key or controller button to wake it"), size: 12, weight: .regular, color: 0x8f98a0)
        }
        let nameText = name.map { text($0, size: 13, weight: .regular, color: 0xc7d5e0) }
        let pad = 22 * s, iconH = 34 * s, gap = 12 * s
        let lines = [title, nameText, detail].compactMap { $0 }
        let maxTextW = min(bounds.width * 0.6, lines.map { ceil($0.size().width) }.max() ?? 0)
        let width = max(220 * s, maxTextW + 2 * pad)
        let height = pad + iconH + gap + lines.reduce(0) { $0 + ceil($1.size().height) + 4 * s } + pad - 4 * s
        card.frame = CGRect(x: (bounds.width - width) / 2, y: (bounds.height - height) / 2, width: width, height: height)
        card.cornerRadius = 12 * s
        card.shadowRadius = 16 * s
        switch style {
        case .gamePaused:
            // Pause icon: two rounded bars, centred at the top.
            let barW = 9 * s
            for (i, b) in [barLeft, barRight].enumerated() {
                b.frame = CGRect(x: width / 2 + (i == 0 ? -barW - 4 * s : 4 * s), y: height - pad - iconH, width: barW, height: iconH)
                b.cornerRadius = 3 * s
            }
        case .sleeping:
            // Crescent moon: a disc minus a smaller disc offset to the upper right.
            moon.frame = CGRect(x: (width - iconH) / 2, y: height - pad - iconH, width: iconH, height: iconH)
            let disc = CGPath(ellipseIn: CGRect(x: 0, y: 0, width: iconH, height: iconH), transform: nil)
            let bite = CGPath(ellipseIn: CGRect(x: iconH * 0.32, y: iconH * 0.26, width: iconH * 0.84, height: iconH * 0.84), transform: nil)
            moon.path = disc.subtracting(bite)
        }
        var y = height - pad - iconH - gap
        for (layer, string) in [(titleLayer, title), (nameLayer, nameText), (detailLayer, detail)] {
            guard let string else {
                layer.string = nil
                layer.frame = .zero
                continue
            }
            let h = ceil(string.size().height)
            y -= h
            layer.string = string
            layer.contentsScale = scale
            layer.frame = CGRect(x: pad, y: y, width: width - 2 * pad, height: h)
            y -= 4 * s
        }
        CATransaction.commit()
    }
}
