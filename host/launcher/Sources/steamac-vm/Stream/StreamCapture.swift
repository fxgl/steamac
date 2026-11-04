import AppKit
import CKrun
import CoreMedia
import CoreVideo
import Darwin
import MachO
import Metal
import MetalKit
import QuartzCore

private typealias StreamPresentCallback = @convention(c) (UnsafeMutableRawPointer?, UnsafeMutableRawPointer?, UnsafeMutableRawPointer?) -> Void
private typealias StreamPresentSetter = @convention(c) (StreamPresentCallback?, UnsafeMutableRawPointer?) -> Void

/// Main-thread compositor; only the pre-present copy runs on wmtr's executor thread.
final class StreamCapture {
    private let presenter: Presenter
    private let renderer: Renderer
    private let view: VMView
    private let deliveryQueue = DispatchQueue(label: "steamac.stream.capture")
    private let hookLock = NSLock()
    private var hookLayer: CAMetalLayer?
    private var hookInterval = 1.0 / 60
    private var hookNextTime = 0.0
    private var hookLinear = false
    private var hookGeneration: UInt64 = 0
    private var gamePool: CVPixelBufferPool?
    private var gameSize = CGSize.zero
    private var setter: StreamPresentSetter?
    private var hookContext: UnsafeMutableRawPointer?
    private var hookLibrary: UnsafeMutableRawPointer?
    private var lookupImageCount: UInt32?
    private var cache: CVMetalTextureCache?
    private var pipeline: MTLRenderPipelineState?
    private var srgbPipeline: MTLRenderPipelineState?
    private var cursorPipeline: MTLRenderPipelineState?
    private var sampler: MTLSamplerState?
    private var nearest: MTLSamplerState?
    private var pool: CVPixelBufferPool?
    private var timer: DispatchSourceTimer?
    private var deliver: ((CVPixelBuffer, CMTime) -> Void)?
    private var generation: UInt64 = 0
    private var width = 0, height = 0
    private var interval = 1.0 / 60
    private var lastTime = -Double.infinity
    private var nextTime = 0.0
    private var retryAfter = 0.0
    private var waitingForGameSince: Double?
    private var dirty = false
    private var gameFrame: (CVPixelBuffer, CVMetalTexture, MTLTexture, CAMetalLayer)?
    private var cursorImage: CGImage?
    private var cursorTexture: MTLTexture?

    init(presenter: Presenter, renderer: Renderer, view: VMView) {
        self.presenter = presenter
        self.renderer = renderer
        self.view = view
        CVMetalTextureCacheCreate(nil, nil, renderer.device, nil, &cache)
        do {
            let library = try renderer.device.makeLibrary(source: Self.shader, options: nil)
            let descriptor = MTLRenderPipelineDescriptor()
            descriptor.vertexFunction = library.makeFunction(name: "captureVertex")
            descriptor.fragmentFunction = library.makeFunction(name: "captureFragment")
            descriptor.colorAttachments[0].pixelFormat = .bgra8Unorm
            pipeline = try renderer.device.makeRenderPipelineState(descriptor: descriptor)
            descriptor.fragmentFunction = library.makeFunction(name: "captureSRGBFragment")
            srgbPipeline = try renderer.device.makeRenderPipelineState(descriptor: descriptor)
            descriptor.fragmentFunction = library.makeFunction(name: "cursorFragment")
            let color = descriptor.colorAttachments[0]!
            color.isBlendingEnabled = true
            color.sourceRGBBlendFactor = .one
            color.destinationRGBBlendFactor = .oneMinusSourceAlpha
            color.sourceAlphaBlendFactor = .one
            color.destinationAlphaBlendFactor = .oneMinusSourceAlpha
            cursorPipeline = try renderer.device.makeRenderPipelineState(descriptor: descriptor)
            let sd = MTLSamplerDescriptor()
            sd.minFilter = .linear; sd.magFilter = .linear
            sd.sAddressMode = .clampToEdge; sd.tAddressMode = .clampToEdge
            sampler = renderer.device.makeSamplerState(descriptor: sd)
            sd.minFilter = .nearest; sd.magFilter = .nearest
            nearest = renderer.device.makeSamplerState(descriptor: sd)
        } catch { log("stream: capture Metal pipeline: \(error)") }
    }

    /// Aspect-fit BGRA IOSurfaces; changed frames are rate-limited, idle pictures repeat each second.
    /// Delivery runs off main and the consumer may retain the buffer through encoding.
    func start(width: Int, height: Int, fps: Int, deliver: @escaping (CVPixelBuffer, CMTime) -> Void) {
        stop()
        guard width > 0, height > 0, fps > 0, cache != nil, pipeline != nil,
              let pool = Self.makePool(width: width, height: height) else {
            log("stream: cannot allocate capture pool \(width)x\(height)")
            return
        }
        self.width = width; self.height = height
        interval = 1 / Double(fps)
        self.pool = pool
        self.deliver = deliver
        lastTime = -.infinity
        nextTime = CACurrentMediaTime()
        retryAfter = 0
        waitingForGameSince = nil
        dirty = true
        view.streamCaptureActive = true
        presenter.onStreamFrame = { [weak self] in self?.changed() }
        view.onStreamChange = { [weak self] in self?.changed() }
        hookLock.lock()
        hookGeneration = generation
        hookInterval = interval
        hookNextTime = nextTime
        hookLock.unlock()
        installHook()
        let timer = DispatchSource.makeTimerSource(queue: .main)
        timer.setEventHandler { [weak self] in self?.tick() }
        self.timer = timer
        timer.resume()
        tick()
    }

    func refresh() { changed() }

    func stop() {
        timer?.cancel(); timer = nil
        setter?(nil, nil)
        setter = nil
        if let context = hookContext {
            Unmanaged<StreamCapture>.fromOpaque(context).release()
            hookContext = nil
        }
        if let library = hookLibrary { dlclose(library); hookLibrary = nil }
        lookupImageCount = nil
        hookLock.lock()
        generation &+= 1
        hookGeneration = generation
        hookLayer = nil
        gamePool = nil
        gameSize = .zero
        waitingForGameSince = nil
        hookLock.unlock()
        presenter.onStreamFrame = nil
        view.onStreamChange = nil
        view.streamCaptureActive = false
        pool = nil
        deliver = nil
        gameFrame = nil
        cursorImage = nil
        cursorTexture = nil
        if let cache { CVMetalTextureCacheFlush(cache, 0) }
    }

    private func changed() {
        guard deliver != nil else { return }
        dirty = true
        tick()
    }

    private func installHook() {
        guard setter == nil else { return }
        let count = _dyld_image_count()
        guard lookupImageCount != count else { return }
        lookupImageCount = count
        var symbol = dlsym(UnsafeMutableRawPointer(bitPattern: -2), "wmtr_stream_capture_set")
        // libkrun uses RTLD_LOCAL. NOLOAD obtains its existing image without enabling DXMT.
        func loadedSymbol(_ path: String) -> UnsafeMutableRawPointer? {
            guard let library = dlopen(path, RTLD_NOW | RTLD_NOLOAD) else { return nil }
            guard let symbol = dlsym(library, "wmtr_stream_capture_set") else {
                dlclose(library)
                return nil
            }
            hookLibrary = library
            return symbol
        }
        if symbol == nil, let path = getenv("STEAMAC_WMTR_LIB") {
            symbol = loadedSymbol(String(cString: path))
        }
        if symbol == nil {
            for i in 0..<count {
                guard let name = _dyld_get_image_name(i) else { continue }
                let path = String(cString: name)
                if path.hasSuffix("/libwmtr_host.dylib") || path == "libwmtr_host.dylib" {
                    symbol = loadedSymbol(path)
                    if symbol != nil { break }
                }
            }
        }
        guard let symbol else { return }
        setter = unsafeBitCast(symbol, to: StreamPresentSetter.self)
        let context = Unmanaged.passRetained(self).toOpaque()
        hookContext = context
        setter?({ context, buffer, drawable in
            guard let context, let buffer, let drawable else { return }
            let capture = Unmanaged<StreamCapture>.fromOpaque(context).takeUnretainedValue()
            let cb = Unmanaged<AnyObject>.fromOpaque(buffer).takeUnretainedValue()
            let dr = Unmanaged<AnyObject>.fromOpaque(drawable).takeUnretainedValue()
            if let cb = cb as? MTLCommandBuffer, let dr = dr as? CAMetalDrawable {
                capture.copyGame(commandBuffer: cb, drawable: dr)
            }
        }, context)
    }

    private static func makePool(width: Int, height: Int) -> CVPixelBufferPool? {
        let attributes: [String: Any] = [
            kCVPixelBufferWidthKey as String: width, kCVPixelBufferHeightKey as String: height,
            kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA,
            kCVPixelBufferMetalCompatibilityKey as String: true,
            kCVPixelBufferIOSurfacePropertiesKey as String: [:]
        ]
        var pool: CVPixelBufferPool?
        CVPixelBufferPoolCreate(nil, [kCVPixelBufferPoolMinimumBufferCountKey as String: 3] as CFDictionary,
                                attributes as CFDictionary, &pool)
        return pool
    }

    private func allocate(_ pool: CVPixelBufferPool) -> (CVPixelBuffer, CVMetalTexture, MTLTexture)? {
        var buffer: CVPixelBuffer?
        let limit = [kCVPixelBufferPoolAllocationThresholdKey as String: 6] as CFDictionary
        guard CVPixelBufferPoolCreatePixelBufferWithAuxAttributes(nil, pool, limit, &buffer) == kCVReturnSuccess,
              let buffer, let cache else { return nil }
        var image: CVMetalTexture?
        guard CVMetalTextureCacheCreateTextureFromImage(nil, cache, buffer, nil, .bgra8Unorm,
                                                       CVPixelBufferGetWidth(buffer), CVPixelBufferGetHeight(buffer), 0,
                                                       &image) == kCVReturnSuccess,
              let image, let texture = CVMetalTextureGetTexture(image) else { return nil }
        return (buffer, image, texture)
    }

    /// The drawable must be sampled before present, on the game's command buffer, not from main.
    private func copyGame(commandBuffer cb: MTLCommandBuffer, drawable: CAMetalDrawable) {
        hookLock.lock()
        defer { hookLock.unlock() }
        let now = CACurrentMediaTime()
        guard let layer = hookLayer, drawable.layer === layer,
              !drawable.texture.isFramebufferOnly, now >= hookNextTime - hookInterval / 4,
              drawable.texture.device.registryID == renderer.device.registryID else { return }
        let size = CGSize(width: drawable.texture.width, height: drawable.texture.height)
        if gameSize != size {
            gamePool = Self.makePool(width: drawable.texture.width, height: drawable.texture.height)
            gameSize = size
        }
        guard let pool = gamePool, let (buffer, image, target) = allocate(pool),
              encode(target: target, cb: cb, pictures: [(drawable.texture, CGRect(origin: .zero, size: size), false)],
                     linear: hookLinear) else { return }
        hookNextTime = max(hookNextTime + hookInterval, now)
        let session = hookGeneration
        cb.addCompletedHandler { [weak self] command in
            guard command.status == .completed else { return }
            DispatchQueue.main.async { [weak self] in
                guard let self, self.generation == session, self.deliver != nil,
                      self.view.activeGameLayer === layer else { return }
                self.gameFrame = (buffer, image, target, layer)
                self.waitingForGameSince = nil
                self.changed()
            }
        }
    }

    private func scheduleTick() {
        var due = dirty ? nextTime : lastTime + max(1, interval)
        if let waitingForGameSince { due = max(due, max(lastTime, waitingForGameSince) + 1) }
        due = max(due, retryAfter)
        timer?.schedule(deadline: .now() + max(0.001, min(0.1, due - CACurrentMediaTime())),
                        leeway: .milliseconds(1))
    }

    private func tick() {
        guard let deliver, let pool else { return }
        defer { scheduleTick() }
        let layer = view.activeGameLayer
        let now = CACurrentMediaTime()
        if layer != nil { installHook() } // wmtr is loaded lazily, before its first layer.
        hookLock.lock()
        if hookLayer !== layer {
            hookLayer = layer
            hookNextTime = now
            waitingForGameSince = layer == nil ? nil : now
            gameFrame = nil
            dirty = true
        }
        let colorSpace = layer?.colorspace?.name
        hookLinear = colorSpace == CGColorSpace.linearSRGB || colorSpace == CGColorSpace.extendedLinearSRGB
            || colorSpace == CGColorSpace.genericRGBLinear
        hookLock.unlock()
        guard now >= retryAfter, now >= nextTime - interval / 4, dirty || now - lastTime >= 1 else { return }
        if let waitingForGameSince, now - max(lastTime, waitingForGameSince) < 1 { return }
        guard let (buffer, image, target) = allocate(pool) else {
            retryAfter = now + interval
            return
        }
        let bounds = CGRect(x: 0, y: 0, width: width, height: height)
        let parent = view.metalLayer.bounds
        let canvas = bounds
        var pictures: [(MTLTexture, CGRect, Bool)] = []
        if let texture = renderer.texture {
            pictures.append((texture, Renderer.fit(content: CGSize(width: texture.width, height: texture.height), in: canvas), false))
        }
        func mapped(_ rect: CGRect) -> CGRect {
            guard parent.width > 0, parent.height > 0 else { return canvas }
            let y = view.metalLayer.isGeometryFlipped ? rect.minY - parent.minY : parent.maxY - rect.maxY
            return CGRect(x: canvas.minX + (rect.minX - parent.minX) * canvas.width / parent.width,
                          y: canvas.minY + y * canvas.height / parent.height,
                          width: rect.width * canvas.width / parent.width, height: rect.height * canvas.height / parent.height)
        }
        var retainedGame: CVPixelBuffer?
        var retainedGameImage: CVMetalTexture?
        if let layer, let gameFrame, gameFrame.3 === layer {
            let size = CGSize(width: gameFrame.2.width, height: gameFrame.2.height)
            let shown = mapped(layer.convert(Renderer.fit(content: size, in: layer.bounds), to: view.metalLayer))
            let gameBounds = mapped(layer.convert(layer.bounds, to: view.metalLayer))
            let streamShown = Renderer.fit(content: size, in: gameBounds)
            pictures.append((gameFrame.2, streamShown, false))
            retainedGame = gameFrame.0
            retainedGameImage = gameFrame.1
            if let (glyph, frame) = view.streamCursor {
                if cursorImage !== glyph {
                    cursorImage = glyph
                    cursorTexture = try? MTKTextureLoader(device: renderer.device).newTexture(cgImage: glyph, options: [.SRGB: false])
                }
                if let cursorTexture, shown.width > 0, shown.height > 0 {
                    let old = mapped(frame)
                    let rect = CGRect(x: streamShown.minX + (old.minX - shown.minX) * streamShown.width / shown.width,
                                      y: streamShown.minY + (old.minY - shown.minY) * streamShown.height / shown.height,
                                      width: old.width * streamShown.width / shown.width,
                                      height: old.height * streamShown.height / shown.height)
                    pictures.append((cursorTexture, rect, true))
                }
            }
        }
        let session = generation
        let pts = CMTime(seconds: now, preferredTimescale: 1_000_000)
        dirty = false
        lastTime = now
        nextTime = max(nextTime + interval, now)
        renderer.submitCapture { cb in
            guard encode(target: target, cb: cb, pictures: pictures) else { dirty = true; return }
            cb.addCompletedHandler { [weak self, image, retainedGame, retainedGameImage] command in
                _ = image; _ = retainedGame; _ = retainedGameImage
                guard command.status == .completed else { return }
                self?.deliveryQueue.async { [weak self] in
                    guard let self else { return }
                    self.hookLock.lock()
                    let current = self.hookGeneration == session
                    self.hookLock.unlock()
                    if current { deliver(buffer, pts) }
                }
            }
        }
    }

    @discardableResult
    private func encode(target: MTLTexture, cb: MTLCommandBuffer, pictures: [(MTLTexture, CGRect, Bool)],
                        linear: Bool = false) -> Bool {
        guard let pipeline, let srgbPipeline, let cursorPipeline, let sampler, let nearest else { return false }
        let pass = MTLRenderPassDescriptor()
        pass.colorAttachments[0].texture = target
        pass.colorAttachments[0].loadAction = .clear
        pass.colorAttachments[0].storeAction = .store
        pass.colorAttachments[0].clearColor = MTLClearColorMake(0, 0, 0, 1)
        guard let encoder = cb.makeRenderCommandEncoder(descriptor: pass) else { return false }
        for (texture, rect, cursor) in pictures where rect.width > 0 && rect.height > 0 {
            let srgb = linear || texture.pixelFormat == .bgra8Unorm_srgb || texture.pixelFormat == .rgba8Unorm_srgb
                || texture.pixelFormat == .rgba16Float || texture.pixelFormat == .rgba32Float
                || texture.pixelFormat == .rg11b10Float || texture.pixelFormat == .rgb9e5Float
            encoder.setRenderPipelineState(cursor ? cursorPipeline : srgb ? srgbPipeline : pipeline)
            // Vertex positions permit clipped cursors without a negative Metal viewport.
            var geometry = SIMD4<Float>(Float(rect.minX / Double(target.width) * 2 - 1),
                                        Float(1 - rect.maxY / Double(target.height) * 2),
                                        Float(rect.width / Double(target.width) * 2),
                                        Float(rect.height / Double(target.height) * 2))
            encoder.setVertexBytes(&geometry, length: MemoryLayout<SIMD4<Float>>.size, index: 0)
            encoder.setFragmentTexture(texture, index: 0)
            let scale = rect.width / Double(texture.width)
            let integral = scale >= 1 && abs(scale - scale.rounded()) < 0.001
                && abs(rect.height / Double(texture.height) - scale) < 0.001
            encoder.setFragmentSamplerState(cursor || integral ? nearest : sampler, index: 0)
            encoder.drawPrimitives(type: .triangleStrip, vertexStart: 0, vertexCount: 4)
        }
        encoder.endEncoding()
        return true
    }

    private static let shader = """
    #include <metal_stdlib>
    using namespace metal;
    struct CaptureVertex { float4 position [[position]]; float2 uv; };
    vertex CaptureVertex captureVertex(uint id [[vertex_id]], constant float4 &rect [[buffer(0)]]) {
        const float2 p[4] = {float2(0,0), float2(1,0), float2(0,1), float2(1,1)};
        CaptureVertex v;
        v.position = float4(rect.xy + p[id] * rect.zw, 0, 1);
        v.uv = float2(p[id].x, 1 - p[id].y);
        return v;
    }
    fragment float4 captureFragment(CaptureVertex v [[stage_in]], texture2d<float> t [[texture(0)]], sampler s [[sampler(0)]]) {
        return float4(t.sample(s, v.uv).rgb, 1.0);
    }
    // Float/linear drawables and sRGB texture samples need transfer encoding for the SDR BGRA buffer.
    fragment float4 captureSRGBFragment(CaptureVertex v [[stage_in]], texture2d<float> t [[texture(0)]], sampler s [[sampler(0)]]) {
        float3 c = t.sample(s, v.uv).rgb;
        return float4(select(12.92 * c, 1.055 * pow(c, float3(1.0 / 2.4)) - 0.055, c > 0.0031308), 1.0);
    }
    fragment float4 cursorFragment(CaptureVertex v [[stage_in]], texture2d<float> t [[texture(0)]], sampler s [[sampler(0)]]) {
        return t.sample(s, v.uv);
    }
    """

    static func selfCheck() -> [String] {
        guard Thread.isMainThread else { return ["capture self-check requires main thread"] }
        let renderer = Renderer()
        let display = DisplayBackend()
        let presenter = Presenter(display: display, renderer: renderer)
        let view = VMView(frame: CGRect(x: 0, y: 0, width: 8, height: 8), renderer: renderer,
                          contentPixelSize: CGSize(width: 4, height: 2))
        let capture = StreamCapture(presenter: presenter, renderer: renderer, view: view)
        let scanout = presenter.scanout
        _ = scanout.configure(width: 4, height: 2, format: UInt32(KRUN_DISPLAY_FORMAT_X8R8G8B8_UNORM))
        guard let (id, pointer, _) = scanout.alloc() else { return ["capture synthetic scanout allocation"] }
        let bytes = pointer.assumingMemoryBound(to: UInt8.self)
        for y in 0..<2 {
            for x in 0..<4 {
                let p = (y * 4 + x) * 4
                bytes[p] = 0
                bytes[p + 1] = (x < 2) == (y == 0) ? 255 : 0
                bytes[p + 2] = x < 2 ? 0 : 255
                bytes[p + 3] = y == 0 ? 0 : 255
            }
        }
        _ = scanout.present(frameId: id, rect: nil)
        presenter.consume()
        let lock = NSLock()
        var failures: [String] = []
        var timestamps: [Double] = []
        capture.start(width: 8, height: 8, fps: 10) { buffer, pts in
            lock.lock()
            defer { lock.unlock() }
            timestamps.append(CMTimeGetSeconds(pts))
            guard CVPixelBufferGetWidth(buffer) == 8, CVPixelBufferGetHeight(buffer) == 8,
                  CVPixelBufferGetIOSurface(buffer) != nil else { failures.append("capture size/IOSurface"); return }
            CVPixelBufferLockBaseAddress(buffer, .readOnly)
            defer { CVPixelBufferUnlockBaseAddress(buffer, .readOnly) }
            let data = CVPixelBufferGetBaseAddress(buffer)!.assumingMemoryBound(to: UInt8.self)
            let stride = CVPixelBufferGetBytesPerRow(buffer)
            for (x, y, expected) in [(1, 0, [0, 0, 0, 255]), (1, 3, [0, 0, 255, 255]),
                                      (6, 3, [0, 255, 0, 255]), (1, 5, [255, 0, 0, 255]),
                                      (6, 5, [255, 255, 255, 255]), (1, 7, [0, 0, 0, 255])] {
                let p = y * stride + x * 4
                let got = (0..<4).map { Int(data[p + $0]) }
                if got != expected { failures.append("capture (\(x),\(y)) BGRA \(got) != \(expected)") }
            }
        }
        let end = CACurrentMediaTime() + 0.45
        while CACurrentMediaTime() < end {
            capture.refresh()
            RunLoop.main.run(until: Date(timeIntervalSinceNow: 0.005))
        }
        capture.stop()
        capture.deliveryQueue.sync {}
        lock.lock()
        defer { lock.unlock() }
        if timestamps.count < 3 { failures.append("capture pacing delivered only \(timestamps.count) frames") }
        // Deadlines are phase-locked and accept a quarter frame early, and the first frame may land
        // anywhere in its period: over the run, at most half a frame more than fps × span.
        if let first = timestamps.first, let last = timestamps.last,
           Double(timestamps.count - 1) > (last - first) * 10 + 0.5 + 0.01 {
            failures.append("capture pacing exceeded 10 fps beyond the quarter-frame tolerance")
        }
        // 0.075 s is the earliest accepted gap; the frame time is stamped a moment after the
        // deadline check, so allow 1 ms of stamping jitter.
        for (a, b) in zip(timestamps, timestamps.dropFirst()) where b - a < 0.074 {
            failures.append("capture pacing interval \(b - a) < 0.074")
        }
        return failures
    }
}
