import AppKit
import Foundation
import Metal
import QuartzCore
import os

/// Main-thread side of the display path: takes frames from scanout 0, uploads them to the
/// renderer and redraws the view (if any). GPU-thread notifications are coalesced.
final class Presenter: DisplaySink {
    let display: DisplayBackend
    let renderer: Renderer
    weak var view: VMView?
    var onScanoutResize: ((Int, Int) -> Void)?
    private var lock = os_unfair_lock()
    private var pending = false
    private(set) var framesShown: UInt64 = 0
    /// Main thread, one-shot: runs after the next guest frame is on screen.
    var onNextFrame: (() -> Void)?
    /// Streaming observes uploads without replacing the window's one-shot frame callback.
    var onStreamFrame: (() -> Void)?

    init(display: DisplayBackend, renderer: Renderer) {
        self.display = display
        self.renderer = renderer
    }

    var scanout: Scanout { display.scanouts[0] }

    // DisplaySink (GPU thread)
    func scanoutConfigured(_ s: Scanout, changed: Bool) {
        guard s.id == 0, changed, let g = s.geometry else { return }
        DispatchQueue.main.async { [weak self] in self?.onScanoutResize?(g.width, g.height) }
    }

    /// A guest mode switch is disable_scanout (x2) followed by configure_scanout 10-80 ms later:
    /// keep showing the last frame (scaled) through it, and only blank if the scanout stays off.
    func scanoutDisabled(_ s: Scanout) {
        guard s.id == 0 else { return }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { [weak self] in
            guard let self, !self.scanout.enabled else { return }
            self.renderer.dropTexture()
            self.view?.redraw()
            self.onStreamFrame?()
        }
    }

    func framePresented(_ s: Scanout) {
        guard s.id == 0 else { return }
        os_unfair_lock_lock(&lock)
        let schedule = !pending
        pending = true
        os_unfair_lock_unlock(&lock)
        if schedule {
            DispatchQueue.main.async { [weak self] in self?.consume() }
        }
    }

    /// Main thread.
    func consume() {
        os_unfair_lock_lock(&lock)
        pending = false
        os_unfair_lock_unlock(&lock)
        guard let f = scanout.take() else { return }
        let perf = PerfStats.shared
        let flushedAt = perf?.frameTaken() ?? 0
        let t0 = perf != nil ? CACurrentMediaTime() : 0
        renderer.upload(f)
        onStreamFrame?()
        if let perf { perf.uploaded(ms: (CACurrentMediaTime() - t0) * 1000) }
        scanout.release(f)
        framesShown &+= 1
        view?.redraw(flushedAt: flushedAt)
        if let next = onNextFrame {
            onNextFrame = nil
            next()
        }
    }
}

/// NSView backed by a CAMetalLayer showing the guest scanout, aspect-fit and Retina-aware.
final class VMView: NSView {
    let renderer: Renderer
    let metalLayer = CAMetalLayer()
    /// Transparent image layer above remoted game layers (DXMT), carrying only the X cursor.
    /// Hidden on the Vulkan path and while the game hides its cursor.
    private let cursorLayer = CALayer()
    var onStreamChange: (() -> Void)?
    private var streamLayerPolicies: [CAMetalLayer: Bool] = [:]
    @objc dynamic var streamCaptureActive = false {
        didSet { updateStreamLayers() }
    }

    private func updateStreamLayers() {
        if streamCaptureActive {
            for (layer, policy) in streamLayerPolicies where layer.superlayer !== metalLayer {
                layer.framebufferOnly = policy
                streamLayerPolicies.removeValue(forKey: layer)
            }
            for case let game as CAMetalLayer in metalLayer.sublayers ?? [] {
                if streamLayerPolicies[game] == nil { streamLayerPolicies[game] = game.framebufferOnly }
                game.framebufferOnly = false
            }
        } else {
            for (layer, policy) in streamLayerPolicies { layer.framebufferOnly = policy }
            streamLayerPolicies.removeAll()
        }
    }

    /// DXMT can set its own framebuffer policy after a layer was attached during capture.
    @objc func streamLayerChanged(_ layer: CAMetalLayer, framebufferOnly requested: NSNumber?) {
        guard layer.superlayer === metalLayer else { return }
        if let requested {
            if streamCaptureActive { streamLayerPolicies[layer] = requested.boolValue }
            layer.framebufferOnly = streamCaptureActive ? false : requested.boolValue
        }
        onStreamChange?()
    }

    var streamCursor: (CGImage, CGRect)? {
        guard !cursorLayer.isHidden, let glyph = guestCursorGlyph else { return nil }
        return (glyph.image, cursorLayer.frame)
    }
    static let cursorLayerName = "steamac.cursor-overlay"
    private struct CursorGlyph {
        let image: CGImage
        let xhot: Int
        let yhot: Int
    }
    /// The focused game's cursor, forwarded by the progress agent (`cursor`, `cursor-image`,
    /// `cursor-pos`). Position and size are in the focused game's X window pixels.
    private var guestCursorVisible = false
    private var guestCursorPosition: (x: Int, y: Int)?
    private var guestCursorWindow: (width: Int, height: Int)?
    private var guestCursorGlyph: CursorGlyph?
    /// X cursor bitmaps are small; cap guest input before multiplying dimensions.
    private static let maxCursorDimension = 256
    /// Re-applied by wmtr on attach, first present and release through gameLayersVisible's KVC setter.
    var onCursorTrackingChange: ((Bool) -> Void)?
    private(set) var cursorTracking = false
    var cursorOverlayVisible: Bool { !cursorLayer.isHidden }
    /// Evaluated only when cursor presentation changes, not on pointer movement or each present.
    var cursorOverlayDiagnostic: String {
        guard let glyph = guestCursorGlyph, let window = guestCursorWindow else {
            return "tracking=\(cursorTracking) image=none frame-pt=\(cursorLayer.frame)"
        }
        let pixels = Self.cursorFrame(position: .zero,
                                      window: CGSize(width: window.width, height: window.height),
                                      image: CGSize(width: glyph.image.width, height: glyph.image.height),
                                      hotspot: CGPoint(x: glyph.xhot, y: glyph.yhot),
                                      shown: CGRect(x: 0, y: 0, width: window.width, height: window.height),
                                      parent: .zero, flipped: true)
        return "tracking=\(cursorTracking) image=\(glyph.image.width)x\(glyph.image.height)"
            + " hotspot=\(glyph.xhot),\(glyph.yhot) window=\(window.width)x\(window.height)"
            + " size-game-px=\(pixels.size) frame-pt=\(cursorLayer.frame)"
    }

    func guestCursorVisibility(_ visible: Bool) {
        guestCursorVisible = visible
        updateCursorLayer()
    }

    func guestCursorImage(width: Int, height: Int, xhot: Int, yhot: Int, bgra: Data) {
        guard width > 0, height > 0, width <= Self.maxCursorDimension, height <= Self.maxCursorDimension else { return }
        let (area, areaOverflow) = width.multipliedReportingOverflow(by: height)
        let (bytes, bytesOverflow) = area.multipliedReportingOverflow(by: 4)
        guard !areaOverflow, !bytesOverflow, bytes == bgra.count,
              let provider = CGDataProvider(data: bgra as CFData),
              let image = CGImage(width: width, height: height, bitsPerComponent: 8, bitsPerPixel: 32,
                                  bytesPerRow: width * 4, space: CGColorSpaceCreateDeviceRGB(),
                                  bitmapInfo: CGBitmapInfo.byteOrder32Little.union(
                                      CGBitmapInfo(rawValue: CGImageAlphaInfo.premultipliedFirst.rawValue)),
                                  provider: provider, decode: nil, shouldInterpolate: false,
                                  intent: .defaultIntent) else { return }
        guestCursorGlyph = CursorGlyph(image: image, xhot: max(0, min(xhot, width - 1)),
                                       yhot: max(0, min(yhot, height - 1)))
        updateCursorLayer()
    }

    func guestCursorPosition(x: Int, y: Int, windowWidth: Int, windowHeight: Int) {
        guestCursorPosition = (x, y)
        guestCursorWindow = (windowWidth, windowHeight)
        updateCursorLayer()
    }
    /// Fallback geometry for pointer mapping before the first frame.
    var contentPixelSize: CGSize
    weak var controller: WindowController?
    private var displayDiagnosticTimer: Timer?

    init(frame: NSRect, renderer: Renderer, contentPixelSize: CGSize) {
        self.renderer = renderer
        self.contentPixelSize = contentPixelSize
        super.init(frame: frame)
        metalLayer.device = renderer.device
        metalLayer.pixelFormat = Renderer.layerFormat
        metalLayer.framebufferOnly = true
        metalLayer.isOpaque = true
        metalLayer.colorspace = CGColorSpace(name: CGColorSpace.sRGB)
        metalLayer.maximumDrawableCount = 3
        metalLayer.displaySyncEnabled = true
        metalLayer.allowsNextDrawableTimeout = true
        metalLayer.backgroundColor = NSColor.black.cgColor
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        cursorLayer.isOpaque = false
        cursorLayer.backgroundColor = NSColor.clear.cgColor
        cursorLayer.name = Self.cursorLayerName
        cursorLayer.zPosition = 1000   // above the remoted game CAMetalLayers, whatever their order
        cursorLayer.isHidden = true
        cursorLayer.contentsGravity = .resize
        cursorLayer.magnificationFilter = .nearest
        cursorLayer.minificationFilter = .nearest
        cursorLayer.contentsScale = NSScreen.main?.backingScaleFactor ?? 2
        metalLayer.addSublayer(cursorLayer)
        CATransaction.commit()
        wantsLayer = true
        layerContentsRedrawPolicy = .never
        renderer.onFirstOnScreen = { [weak self] in
            guard let self, MetalHUD.loaded else { return }
            self.hudAttached = true
            // "default" first, so that "off" is a change.
            self.metalLayer.developerHUDProperties = ["mode": "default"]
            Self.applyHUD(self.metalHUD, gameVisible: self.gameLayersVisible, main: self.metalLayer, mainAttached: true)
        }
    }

    required init?(coder: NSCoder) { fatalError() }

    deinit {
        displayDiagnosticTimer?.invalidate()
        NotificationCenter.default.removeObserver(self)
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        displayDiagnosticTimer?.invalidate()
        displayDiagnosticTimer = nil
        let nc = NotificationCenter.default
        nc.removeObserver(self)
        guard let window else { return }
        nc.addObserver(self, selector: #selector(displayConfigurationChanged(_:)),
                       name: NSWindow.didChangeScreenNotification, object: window)
        nc.addObserver(self, selector: #selector(displayConfigurationChanged(_:)),
                       name: NSApplication.didChangeScreenParametersNotification, object: nil)
        logDisplayConfiguration(reason: "window attached")
        // DXMT's game layer bypasses Renderer. Sample its actual policy, not the main
        // scanout layer's policy, so a report can distinguish unsynced presents from
        // a mismatched host mode. This does not drive rendering or change its cadence.
        let timer = Timer(timeInterval: PerfStats.period, repeats: true) { [weak self] _ in
            guard PerfStats.shared != nil else { return }
            self?.logDisplayConfiguration(reason: "perf sample")
        }
        RunLoop.main.add(timer, forMode: .common)
        displayDiagnosticTimer = timer
    }

    @objc private func displayConfigurationChanged(_ notification: Notification) {
        logDisplayConfiguration(reason: notification.name.rawValue)
    }

    /// Mode refresh can be zero on variable-refresh screens: retain the AppKit interval
    /// range and granularity rather than substituting an assumed 60/120 Hz clock.
    private func logDisplayConfiguration(reason: String) {
        guard let window, let screen = window.screen,
              let number = screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber else { return }
        let id = CGDirectDisplayID(number.uint32Value)
        let mode = CGDisplayCopyDisplayMode(id)
        let hostMode = mode.map {
            "\($0.pixelWidth)x\($0.pixelHeight)@\(String(format: "%.3f", $0.refreshRate)) Hz"
        } ?? "unavailable"
        func policy(_ layer: CAMetalLayer) -> String {
            "\(ObjectIdentifier(layer)) \(Int(layer.drawableSize.width))x\(Int(layer.drawableSize.height))"
                + " hidden=\(layer.isHidden) sync=\(layer.displaySyncEnabled)"
                + " drawables=\(layer.maximumDrawableCount) timeout=\(layer.allowsNextDrawableTimeout)"
        }
        let games = (metalLayer.sublayers ?? []).compactMap { $0 as? CAMetalLayer }
        log("display pacing: \(reason); host \"\(screen.localizedName)\" id=\(id) builtin=\(CGDisplayIsBuiltin(id) != 0)"
            + " mode=\(hostMode) max-fps=\(screen.maximumFramesPerSecond)"
            + " refresh-ms min/max/granularity="
            + String(format: "%.3f/%.3f/%.3f", screen.minimumRefreshInterval * 1000,
                     screen.maximumRefreshInterval * 1000, screen.displayUpdateGranularity * 1000)
            + " backing-scale=\(window.backingScaleFactor) fullscreen=\(window.styleMask.contains(.fullScreen))"
            + " guest-layer={\(policy(metalLayer))} game-visible=\(gameLayersVisible)"
            + " game-layers=[\(games.map { policy($0) }.joined(separator: "; "))]"
            + "; scanout perf shown is estimated, not DXMT game presentation timing")
    }

    override func makeBackingLayer() -> CALayer { metalLayer }
    override var isOpaque: Bool { true }
    override var acceptsFirstResponder: Bool { true }
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    override func viewDidChangeBackingProperties() {
        super.viewDidChangeBackingProperties()
        updateDrawableSize()
        logDisplayConfiguration(reason: "backing properties changed")
    }

    override func setFrameSize(_ newSize: NSSize) {
        super.setFrameSize(newSize)
        updateDrawableSize()
    }

    // Mouse events go to the controller (window.acceptsMouseMovedEvents delivers mouseMoved here).
    override func mouseMoved(with e: NSEvent) { controller?.pointerMoved(e) }
    override func mouseDragged(with e: NSEvent) { controller?.pointerMoved(e) }
    override func rightMouseDragged(with e: NSEvent) { controller?.pointerMoved(e) }
    override func otherMouseDragged(with e: NSEvent) { controller?.pointerMoved(e) }
    override func mouseDown(with e: NSEvent) { controller?.pointerButton(e, down: true) }
    override func mouseUp(with e: NSEvent) { controller?.pointerButton(e, down: false) }
    override func rightMouseDown(with e: NSEvent) { controller?.pointerButton(e, down: true) }
    override func rightMouseUp(with e: NSEvent) { controller?.pointerButton(e, down: false) }
    override func otherMouseDown(with e: NSEvent) { controller?.pointerButton(e, down: true) }
    override func otherMouseUp(with e: NSEvent) { controller?.pointerButton(e, down: false) }
    override func scrollWheel(with e: NSEvent) { controller?.scroll(e) }

    // Leaving the view shows the Mac cursor again (it is hidden over the picture, see
    // WindowController.updateHostCursor): no mouseMoved arrives once the pointer is elsewhere.
    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if trackingAreas.isEmpty {
            addTrackingArea(NSTrackingArea(rect: .zero, options: [.mouseEnteredAndExited, .activeInKeyWindow, .inVisibleRect],
                                           owner: self))
        }
    }
    override func mouseExited(with e: NSEvent) { controller?.pointerExited() }

    private func updateDrawableSize() {
        let scale = window?.backingScaleFactor ?? NSScreen.main?.backingScaleFactor ?? 2
        metalLayer.contentsScale = scale
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        cursorLayer.contentsScale = scale
        CATransaction.commit()
        let size = CGSize(width: (bounds.width * scale).rounded(), height: (bounds.height * scale).rounded())
        if size != metalLayer.drawableSize && size.width > 0 && size.height > 0 {
            metalLayer.drawableSize = size
            redraw()
        }
    }

    /// The topmost remoted game layer (DXMT): it would cover the guest's cursor.
    var activeGameLayer: CAMetalLayer? {
        (metalLayer.sublayers ?? [])
            .compactMap { $0 as? CAMetalLayer }
            .last { !$0.isHidden }
    }

    /// gamescope's GetDesiredSize clamps 36 * floor(H / 720) to 36...256. getTexture
    /// first shrinks oversized images to that square (integer hotspots); paint then enlarges
    /// smaller images by desired/contentHeight. Apply that rule in game pixels before view mapping.
    static func cursorFrame(position: CGPoint, window: CGSize, image: CGSize, hotspot: CGPoint,
                            shown: CGRect, parent: CGRect, flipped: Bool) -> CGRect {
        let desired = min(256, max(36, 36 * floor(window.height / 720)))
        let shrink = image.width > desired || image.height > desired
        let size = shrink ? CGSize(width: desired, height: desired)
                          : CGSize(width: image.width * desired / image.height, height: desired)
        let hot = shrink
            ? CGPoint(x: floor(hotspot.x * desired / image.width), y: floor(hotspot.y * desired / image.height))
            : CGPoint(x: hotspot.x * desired / image.height, y: hotspot.y * desired / image.height)
        let sx = shown.width / window.width, sy = shown.height / window.height
        let w = size.width * sx, h = size.height * sy
        let left = shown.minX + (position.x - hot.x) * sx
        let top = shown.minY + (position.y - hot.y) * sy
        let y = flipped ? top : parent.minY + parent.maxY - top - h
        return CGRect(x: left.rounded(), y: y.rounded(), width: w.rounded(), height: h.rounded())
    }

    private func updateCursorLayer() {
        guard cursorTracking, guestCursorVisible,
              let position = guestCursorPosition,
              let window = guestCursorWindow, window.width > 0, window.height > 0,
              let glyph = guestCursorGlyph,
              let game = activeGameLayer,
              game.drawableSize.width > 0, game.drawableSize.height > 0 else {
            guard !cursorLayer.isHidden else { return }
            CATransaction.begin()
            CATransaction.setDisableActions(true)
            cursorLayer.isHidden = true
            CATransaction.commit()
            controller?.refreshHostCursor()
            onStreamChange?()
            return
        }
        // wmtr uses resizeAspect; map the window-relative hotspot through the actual drawable.
        let shown = game.convert(Renderer.fit(content: game.drawableSize, in: game.bounds), to: metalLayer)
        let frame = Self.cursorFrame(position: CGPoint(x: position.x, y: position.y),
                                     window: CGSize(width: window.width, height: window.height),
                                     image: CGSize(width: glyph.image.width, height: glyph.image.height),
                                     hotspot: CGPoint(x: glyph.xhot, y: glyph.yhot), shown: shown,
                                     parent: metalLayer.bounds, flipped: metalLayer.isGeometryFlipped)
        guard cursorLayer.isHidden || cursorLayer.superlayer !== metalLayer
                || cursorLayer.frame != frame || (cursorLayer.contents as AnyObject?) !== glyph.image else { return }
        let wasHidden = cursorLayer.isHidden
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        if cursorLayer.superlayer !== metalLayer { metalLayer.addSublayer(cursorLayer) }
        cursorLayer.frame = frame
        cursorLayer.contents = glyph.image
        cursorLayer.isHidden = false
        CATransaction.commit()
        if wasHidden { controller?.refreshHostCursor() }
        onStreamChange?()
    }

    /// `flushedAt`: the guest flush time of a new frame (perf stats), 0 for a plain redraw.
    func redraw(flushedAt: CFTimeInterval = 0) {
        renderer.draw(to: metalLayer, flushedAt: flushedAt)
        updateCursorLayer()
    }

    /// Remoted game layers (wmtr with WMTR_PRESENT=overlay) cover the guest picture only while a
    /// game has the guest's focus, leaving Steam and the desktop visible otherwise. The executor
    /// reads this through KVC for layers added later and re-applies it after their first presents.
    @objc dynamic var gameLayersVisible = false {
        didSet {
            Self.applyGameLayers(visible: gameLayersVisible, in: metalLayer)
            updateStreamLayers()
            Self.applyHUD(metalHUD, gameVisible: gameLayersVisible, main: metalLayer, mainAttached: hudAttached)
            let tracking = gameLayersVisible && activeGameLayer != nil
            if cursorTracking != tracking {
                cursorTracking = tracking
                // Never flash cached state when another game takes over.
                guestCursorVisible = false
                guestCursorPosition = nil
                guestCursorGlyph = nil
                onCursorTrackingChange?(tracking)
            }
            controller?.refreshHostCursor()
            updateCursorLayer()
            if oldValue != gameLayersVisible { onStreamChange?() }
        }
    }

    static func applyGameLayers(visible: Bool, in parent: CALayer) {
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        for layer in parent.sublayers ?? [] where layer is CAMetalLayer {
            layer.isHidden = !visible
        }
        CATransaction.commit()
    }

    /// Metal Performance HUD shown (WindowController). libMTLHud attaches to the layer once a
    /// drawable has reached the screen, starts shown (MTL_HUD_ENABLED) and then acts only on
    /// changes of developerHUDProperties["mode"]; the setting applies from then on. The executor
    /// can re-apply this policy through KVC when its game layer starts presenting.
    @objc dynamic var metalHUD = false {
        didSet { Self.applyHUD(metalHUD, gameVisible: gameLayersVisible, main: metalLayer, mainAttached: hudAttached) }
    }
    private var hudAttached = false

    /// Keep the HUD on the game layers while shown, otherwise on the guest picture. Game layers
    /// get "default" first so "off" is a change even when libMTLHud attached with its HUD showing.
    static func applyHUD(_ on: Bool, gameVisible: Bool, main: CAMetalLayer, mainAttached: Bool,
                         injected: Bool = MetalHUD.loaded) {
        guard injected else { return }
        let game = (main.sublayers ?? []).compactMap { $0 as? CAMetalLayer }
        let onGame = on && gameVisible && !game.isEmpty
        if mainAttached { main.developerHUDProperties = ["mode": on && !onGame ? "default" : "off"] }
        for layer in game {
            layer.developerHUDProperties = ["mode": "default"]
            if !onGame { layer.developerHUDProperties = ["mode": "off"] }
        }
    }

    /// The guest picture's rect in view points (same fit as the renderer).
    var fitRect: CGRect {
        let content = renderer.texture.map { CGSize(width: $0.width, height: $0.height) } ?? contentPixelSize
        return Renderer.fit(content: content, in: bounds)
    }

    /// Event location -> unit coordinates (top-left origin), clamped to the picture.
    func unitPoint(for event: NSEvent) -> (Double, Double) {
        let p = convert(event.locationInWindow, from: nil)
        let f = fitRect
        guard f.width > 0, f.height > 0 else { return (0, 0) }
        let ux = Double((p.x - f.minX) / f.width)
        let uy = 1 - Double((p.y - f.minY) / f.height)   // AppKit views are bottom-left origin
        return (min(1, max(0, ux)), min(1, max(0, uy)))
    }
}
