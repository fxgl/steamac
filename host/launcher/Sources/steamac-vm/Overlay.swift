import AppKit
import Metal
import QuartzCore

/// "FX STEAM LAUNCHER" boot / shutdown overlay: Core Animation layers over the Metal view.
/// Never takes mouse events (hitTest → nil); when hidden it is `isHidden` with every animation
/// removed, so it costs nothing per frame.
final class OverlayView: NSView {
    private let background = CAGradientLayer()
    private let glow = CAGradientLayer()
    private let sheen = CAGradientLayer()
    private let wordmark = CATextLayer()
    private let titleLayer = CATextLayer()
    private let percentLayer = CATextLayer()
    private let detailLayer = CATextLayer()
    private let footer = CATextLayer()
    private let track = CALayer()
    private let fill = CAGradientLayer()
    private var state = ProgressState()
    private(set) var shown = false
    private var fading = false
    /// Called with the new `shown` value when the overlay starts showing / starts fading out.
    var onVisibilityChange: ((Bool) -> Void)?
    /// Progress bar track, in view coordinates (self-test pixel checks).
    var barFrame: CGRect { track.frame }
    var currentTitle: String { state.title }

    static func color(_ hex: UInt32, _ alpha: CGFloat = 1) -> CGColor {
        CGColor(srgbRed: CGFloat((hex >> 16) & 0xff) / 255, green: CGFloat((hex >> 8) & 0xff) / 255,
                blue: CGFloat(hex & 0xff) / 255, alpha: alpha)
    }

    /// Host Vulkan driver of this boot (VM.start).
    static var vulkanDriver = LauncherSettings.VulkanDriver.moltenvk

    static var gpuFooter: String {
        let gpu = MTLCreateSystemDefaultDevice()?.name ?? "Apple GPU"
        let short = gpu.hasPrefix("Apple ") ? String(gpu.dropFirst(6)) : gpu
        return "SteamOS · Venus → \(vulkanDriver.name) · \(short)"
    }

    override init(frame: NSRect) {
        super.init(frame: frame)
        wantsLayer = true
        layer = CALayer()
        layer!.masksToBounds = true
        autoresizingMask = [.width, .height]

        background.colors = [OverlayView.color(0x171a21), OverlayView.color(0x0b0d12)]
        background.startPoint = CGPoint(x: 0.5, y: 1)
        background.endPoint = CGPoint(x: 0.5, y: 0)
        glow.type = .radial
        glow.colors = [OverlayView.color(0x66c0f4, 0.16), OverlayView.color(0x66c0f4, 0)]
        glow.startPoint = CGPoint(x: 0.5, y: 0.5)
        glow.endPoint = CGPoint(x: 1, y: 1)
        sheen.colors = [OverlayView.color(0xffffff, 0), OverlayView.color(0xc7e6ff, 0.05), OverlayView.color(0xffffff, 0)]
        sheen.startPoint = CGPoint(x: 0, y: 0.5)
        sheen.endPoint = CGPoint(x: 1, y: 0.5)
        sheen.transform = CATransform3DMakeRotation(-.pi / 9, 0, 0, 1)

        for t in [wordmark, titleLayer, percentLayer, detailLayer, footer] {
            t.alignmentMode = .center
            t.truncationMode = .end
            t.isWrapped = false
        }
        percentLayer.alignmentMode = .right
        wordmark.shadowColor = OverlayView.color(0x66c0f4)
        wordmark.shadowOpacity = 0.9
        wordmark.shadowOffset = .zero
        track.backgroundColor = OverlayView.color(0xffffff, 0.08)
        track.masksToBounds = true
        fill.colors = [OverlayView.color(0x1a9fff), OverlayView.color(0x66c0f4)]
        fill.startPoint = CGPoint(x: 0, y: 0.5)
        fill.endPoint = CGPoint(x: 1, y: 0.5)
        fill.anchorPoint = CGPoint(x: 0, y: 0.5)
        track.addSublayer(fill)
        for l in [background, glow, sheen, wordmark, titleLayer, track, percentLayer, detailLayer, footer] as [CALayer] {
            layer!.addSublayer(l)
        }
        alphaValue = 0
        isHidden = true
    }

    required init?(coder: NSCoder) { fatalError() }

    override func hitTest(_ point: NSPoint) -> NSView? { nil }
    override var isOpaque: Bool { false }

    // MARK: visibility

    /// Fade in (0.4 s) and start the ambient animations.
    func show(animated: Bool = true) {
        guard !shown || fading else { return }
        shown = true
        onVisibilityChange?(true)
        fading = false
        isHidden = false
        startAnimations()
        apply(state, animated: false)
        if animated {
            NSAnimationContext.runAnimationGroup { ctx in
                ctx.duration = 0.4
                animator().alphaValue = 1
            }
        } else {
            alphaValue = 1
        }
    }

    /// Fade out (0.6 s), then hide and drop every animation.
    func hide(animated: Bool = true, completion: (() -> Void)? = nil) {
        guard shown, !fading else { completion?(); return }
        let finish = { [weak self] in
            guard let self else { return }
            self.fading = false
            guard !self.shown else { return }
            self.isHidden = true
            self.stopAnimations()
            completion?()
        }
        shown = false
        onVisibilityChange?(false)
        if animated {
            fading = true
            NSAnimationContext.runAnimationGroup({ ctx in
                ctx.duration = 0.6
                animator().alphaValue = 0
            }, completionHandler: finish)
        } else {
            alphaValue = 0
            finish()
        }
    }

    /// True when hidden and idle (no layer animations running).
    var isIdle: Bool {
        isHidden && ([layer!] + layer!.sublayers! + track.sublayers!).allSatisfy { ($0.animationKeys() ?? []).isEmpty }
    }

    private func startAnimations() {
        let a = CABasicAnimation(keyPath: "position.x")
        a.fromValue = -bounds.width * 0.6
        a.toValue = bounds.width * 1.6
        a.duration = 7
        a.repeatCount = .infinity
        a.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
        sheen.add(a, forKey: "sheen")
        let g = CABasicAnimation(keyPath: "shadowRadius")
        g.fromValue = 12 * scaleFactor
        g.toValue = 22 * scaleFactor
        g.duration = 2.4
        g.autoreverses = true
        g.repeatCount = .infinity
        wordmark.add(g, forKey: "glow")
        updateIndeterminate()
    }

    private func stopAnimations() {
        sheen.removeAllAnimations()
        wordmark.removeAllAnimations()
        fill.removeAllAnimations()
        for l in [layer!] + layer!.sublayers! { l.removeAllAnimations() }
    }

    // MARK: content

    func update(_ s: ProgressState) {
        let wasIndeterminate = state.indeterminate
        state = s
        guard shown else { return }
        apply(s, animated: true)
        if wasIndeterminate != s.indeterminate { updateIndeterminate() }
    }

    private var scaleFactor: CGFloat { max(0.55, min(bounds.width / 1280, bounds.height / 800)) }

    private func attributed(_ text: String, size: CGFloat, weight: NSFont.Weight, color: CGColor, kern: CGFloat = 0,
                            monospacedDigits: Bool = false) -> NSAttributedString {
        let font = monospacedDigits ? NSFont.monospacedDigitSystemFont(ofSize: size, weight: weight)
                                    : NSFont.systemFont(ofSize: size, weight: weight)
        return NSAttributedString(string: text, attributes: [.font: font, .foregroundColor: color, .kern: kern])
    }

    private func apply(_ s: ProgressState, animated: Bool) {
        let k = scaleFactor
        CATransaction.begin()
        CATransaction.setDisableActions(!animated)
        CATransaction.setAnimationDuration(0.35)
        titleLayer.string = attributed(s.title, size: 19 * k, weight: .semibold, color: OverlayView.color(0xc7d5e0))
        detailLayer.string = attributed(s.detail, size: 12.5 * k, weight: .regular, color: OverlayView.color(0x8f98a0))
        track.isHidden = s.stageId == "boot-failed"
        percentLayer.string = attributed(s.indeterminate || s.stageId == "boot-failed" ? "" : "\(Int((s.fraction * 100).rounded(.down)))%",
                                         size: 13 * k, weight: .medium, color: OverlayView.color(0x66c0f4), monospacedDigits: true)
        if !s.indeterminate {
            fill.bounds.size.width = track.bounds.width * CGFloat(max(0, min(1, s.fraction)))
        }
        CATransaction.commit()
    }

    private func updateIndeterminate() {
        fill.removeAnimation(forKey: "indeterminate")
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        if state.indeterminate {
            fill.bounds.size.width = track.bounds.width * 0.28
            if shown {
                let a = CABasicAnimation(keyPath: "position.x")
                a.fromValue = -track.bounds.width * 0.28
                a.toValue = track.bounds.width
                a.duration = 1.4
                a.repeatCount = .infinity
                a.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
                fill.add(a, forKey: "indeterminate")
            }
        } else {
            fill.position = CGPoint(x: 0, y: track.bounds.midY)
            fill.bounds.size.width = track.bounds.width * CGFloat(max(0, min(1, state.fraction)))
        }
        CATransaction.commit()
    }

    override func viewDidChangeBackingProperties() {
        super.viewDidChangeBackingProperties()
        needsLayout = true
    }

    override func layout() {
        super.layout()
        let b = bounds
        let k = scaleFactor
        let scale = window?.backingScaleFactor ?? NSScreen.main?.backingScaleFactor ?? 2
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        for l in [layer!] + layer!.sublayers! + [fill] { l.contentsScale = scale }
        background.frame = b
        let glowSize = CGSize(width: 900 * k, height: 520 * k)
        glow.frame = CGRect(x: b.midX - glowSize.width / 2, y: b.midY + 40 * k - glowSize.height / 2,
                            width: glowSize.width, height: glowSize.height)
        sheen.bounds = CGRect(x: 0, y: 0, width: b.width * 0.35, height: b.height * 2.2)
        sheen.position = CGPoint(x: -b.width, y: b.midY)

        let wmHeight = 64 * k
        wordmark.string = attributed("FX STEAM LAUNCHER", size: 46 * k, weight: .heavy, color: OverlayView.color(0xffffff), kern: 9 * k)
        wordmark.frame = CGRect(x: 0, y: b.midY + 46 * k, width: b.width, height: wmHeight)
        wordmark.shadowRadius = 16 * k
        titleLayer.frame = CGRect(x: 40 * k, y: b.midY + 4 * k, width: b.width - 80 * k, height: 28 * k)
        let barWidth = min(560 * k, b.width * 0.72)
        let barHeight = max(4, 6 * k)
        track.frame = CGRect(x: b.midX - barWidth / 2, y: b.midY - 26 * k, width: barWidth, height: barHeight)
        track.cornerRadius = barHeight / 2
        fill.cornerRadius = barHeight / 2
        fill.bounds = CGRect(x: 0, y: 0, width: fill.bounds.width, height: barHeight)
        fill.position = CGPoint(x: 0, y: barHeight / 2)
        percentLayer.frame = CGRect(x: track.frame.maxX - 120 * k, y: track.frame.maxY + 6 * k, width: 120 * k, height: 18 * k)
        detailLayer.frame = CGRect(x: 40 * k, y: track.frame.minY - 30 * k, width: b.width - 80 * k, height: 18 * k)
        footer.string = attributed(OverlayView.gpuFooter, size: 11.5 * k, weight: .regular,
                                   color: OverlayView.color(0x5c6670), kern: 0.6 * k)
        footer.frame = CGRect(x: 0, y: 22 * k, width: b.width, height: 18 * k)
        CATransaction.commit()
        apply(state, animated: false)
        if shown { startAnimations() }
    }

    /// Render the overlay (model values) into a context at `scale` pixels per point.
    func renderImage(scale: CGFloat, under background: CGImage?) -> CGImage? {
        let w = Int(bounds.width * scale), h = Int(bounds.height * scale)
        guard let ctx = CGContext(data: nil, width: w, height: h, bitsPerComponent: 8, bytesPerRow: w * 4,
                                  space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                  bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return nil }
        if let background { ctx.draw(background, in: CGRect(x: 0, y: 0, width: w, height: h)) }
        if !isHidden && alphaValue > 0 {
            ctx.saveGState()
            ctx.setAlpha(alphaValue)
            ctx.scaleBy(x: scale, y: scale)
            layer!.render(in: ctx)
            ctx.restoreGState()
        }
        return ctx.makeImage()
    }
}
