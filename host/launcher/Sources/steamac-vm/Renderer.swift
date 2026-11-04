import CKrun
import Foundation
import Metal
import MetalFX
import QuartzCore

/// Uploads guest frames into an MTLTexture (swizzled per virtio-gpu format) and draws them
/// aspect-fit into a CAMetalLayer, optionally upscaled by MetalFX (`superResolution`).
final class Renderer {
    let device: MTLDevice
    private let queue: MTLCommandQueue
    private let pipeline: MTLRenderPipelineState
    private let linear: MTLSamplerState
    private let nearest: MTLSamplerState
    private(set) var texture: MTLTexture?
    /// Self-test hook: copy the next presented drawable (requires layer.framebufferOnly = false)
    /// and hand back BGRA bytes + size on a Metal completion thread.
    var captureNextDraw: (([UInt8], Int, Int) -> Void)?
    /// Called once, on the main queue, after a drawable has actually reached the screen.
    var onFirstOnScreen: (() -> Void)?
    private var textureGeneration = -1
    private var lastCommandBuffer: MTLCommandBuffer?
    static let layerFormat: MTLPixelFormat = .bgra8Unorm

    /// MetalFX spatial upscaling of the guest frame to its on-screen pixel size whenever that is
    /// larger (Settings > Display, "MetalFX super resolution"); otherwise the plain linear/nearest draw.
    var superResolution = false {
        didSet { if !superResolution { releaseScaler() } }
    }
    /// The MetalFX spatial scaler runs on this Mac's GPU (every Apple silicon Mac).
    static let superResolutionSupported: Bool =
        MTLCreateSystemDefaultDevice().map { MTLFXSpatialScalerDescriptor.supportsDevice($0) } ?? false
    /// Scaler + its output texture for the current input format/size -> output size.
    private var scaler: MTLFXSpatialScaler?
    private var upscaled: MTLTexture?
    /// Set after a scaler could not be made (logged once); super resolution then stays off.
    private var scalerFailed = false

    private static let shaderSource = """
    #include <metal_stdlib>
    using namespace metal;
    struct VOut { float4 pos [[position]]; float2 uv; };
    vertex VOut vmain(uint vid [[vertex_id]]) {
        const float2 p[4] = { float2(-1, -1), float2(1, -1), float2(-1, 1), float2(1, 1) };
        const float2 t[4] = { float2(0, 1), float2(1, 1), float2(0, 0), float2(1, 0) };
        VOut o;
        o.pos = float4(p[vid], 0, 1);
        o.uv = t[vid];
        return o;
    }
    fragment float4 fmain(VOut in [[stage_in]], texture2d<float> tex [[texture(0)]], sampler s [[sampler(0)]]) {
        return float4(tex.sample(s, in.uv).rgb, 1.0);
    }
    """

    init() {
        guard let device = MTLCreateSystemDefaultDevice() else { fatal("no Metal device") }
        self.device = device
        queue = device.makeCommandQueue()!
        do {
            let lib = try device.makeLibrary(source: Renderer.shaderSource, options: nil)
            let desc = MTLRenderPipelineDescriptor()
            desc.vertexFunction = lib.makeFunction(name: "vmain")
            desc.fragmentFunction = lib.makeFunction(name: "fmain")
            desc.colorAttachments[0].pixelFormat = Renderer.layerFormat
            pipeline = try device.makeRenderPipelineState(descriptor: desc)
        } catch {
            fatal("Metal pipeline: \(error)")
        }
        let sd = MTLSamplerDescriptor()
        sd.minFilter = .linear; sd.magFilter = .linear
        sd.sAddressMode = .clampToEdge; sd.tAddressMode = .clampToEdge
        linear = device.makeSamplerState(descriptor: sd)!
        sd.minFilter = .nearest; sd.magFilter = .nearest
        nearest = device.makeSamplerState(descriptor: sd)!
    }

    /// Texture pixel format + swizzle presenting the frame bytes as RGB.
    static func textureLayout(for format: UInt32) -> (MTLPixelFormat, MTLTextureSwizzleChannels) {
        switch Int32(format) {
        case KRUN_DISPLAY_FORMAT_B8G8R8A8_UNORM, KRUN_DISPLAY_FORMAT_B8G8R8X8_UNORM:
            return (.bgra8Unorm, MTLTextureSwizzleChannels(red: .red, green: .green, blue: .blue, alpha: .one))
        case KRUN_DISPLAY_FORMAT_A8R8G8B8_UNORM, KRUN_DISPLAY_FORMAT_X8R8G8B8_UNORM:
            // bytes A R G B -> rgba8 channels r=A g=R b=G a=B
            return (.rgba8Unorm, MTLTextureSwizzleChannels(red: .green, green: .blue, blue: .alpha, alpha: .one))
        case KRUN_DISPLAY_FORMAT_X8B8G8R8_UNORM, KRUN_DISPLAY_FORMAT_A8B8G8R8_UNORM:
            // bytes X B G R -> r=X g=B b=G a=R
            return (.rgba8Unorm, MTLTextureSwizzleChannels(red: .alpha, green: .blue, blue: .green, alpha: .one))
        default: // R8G8B8A8 / R8G8B8X8
            return (.rgba8Unorm, MTLTextureSwizzleChannels(red: .red, green: .green, blue: .blue, alpha: .one))
        }
    }

    /// Upload the damaged part of `frame` (everything if the texture is new).
    func upload(_ frame: TakenFrame) {
        let b = frame.buffer
        var full = frame.damage == nil
        if texture == nil || textureGeneration != frame.generation
            || texture!.width != b.width || texture!.height != b.height {
            let (pf, swizzle) = Renderer.textureLayout(for: b.format)
            let td = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: pf, width: b.width, height: b.height, mipmapped: false)
            td.usage = .shaderRead
            td.storageMode = .shared
            td.swizzle = swizzle
            texture = device.makeTexture(descriptor: td)
            textureGeneration = frame.generation
            full = true
        }
        guard let texture else { return }
        let rect: DamageRect
        if full {
            rect = DamageRect(x0: 0, y0: 0, x1: b.width, y1: b.height)
        } else if let r = frame.damage!.clamped(width: b.width, height: b.height) {
            rect = r
        } else {
            return
        }
        // Don't overwrite texels a previous command buffer may still be sampling.
        lastCommandBuffer?.waitUntilCompleted()
        let src = b.ptr.advanced(by: rect.y0 * b.stride + rect.x0 * 4)
        texture.replace(region: MTLRegionMake2D(rect.x0, rect.y0, rect.x1 - rect.x0, rect.y1 - rect.y0),
                        mipmapLevel: 0, withBytes: src, bytesPerRow: b.stride)
    }

    /// Use the window queue so the next upload waits for every reader of the shared scanout.
    func submitCapture(_ encode: (MTLCommandBuffer) -> Void) {
        guard let cb = queue.makeCommandBuffer() else { return }
        encode(cb)
        cb.commit()
        lastCommandBuffer = cb
    }

    func dropTexture() {
        texture = nil
        textureGeneration = -1
        releaseScaler()
    }

    /// Aspect-fit rect of the texture inside a target of `size` (pixels).
    func fitRect(in size: CGSize) -> CGRect {
        guard let t = texture, size.width > 0, size.height > 0 else { return .zero }
        return Renderer.fit(content: CGSize(width: t.width, height: t.height), in: CGRect(origin: .zero, size: size))
    }

    static func fit(content: CGSize, in bounds: CGRect) -> CGRect {
        guard content.width > 0, content.height > 0 else { return bounds }
        let s = min(bounds.width / content.width, bounds.height / content.height)
        let w = content.width * s, h = content.height * s
        return CGRect(x: bounds.minX + (bounds.width - w) / 2, y: bounds.minY + (bounds.height - h) / 2, width: w, height: h)
    }

    private func releaseScaler() {
        scaler = nil
        upscaled = nil
    }

    /// A scaler (and output texture) from `texture` to `width` x `height`, reused while those match.
    private func scaler(for texture: MTLTexture, width: Int, height: Int) -> (MTLFXSpatialScaler, MTLTexture)? {
        if let s = scaler, let out = upscaled, s.inputWidth == texture.width, s.inputHeight == texture.height,
           s.colorTextureFormat == texture.pixelFormat, s.outputWidth == width, s.outputHeight == height {
            return (s, out)
        }
        releaseScaler()
        guard !scalerFailed else { return nil }
        let sd = MTLFXSpatialScalerDescriptor()
        sd.inputWidth = texture.width
        sd.inputHeight = texture.height
        sd.outputWidth = width
        sd.outputHeight = height
        sd.colorTextureFormat = texture.pixelFormat
        sd.outputTextureFormat = Renderer.layerFormat
        sd.colorProcessingMode = .perceptual   // guest scanouts hold sRGB-encoded 8-bit values
        guard Renderer.superResolutionSupported, let s = sd.makeSpatialScaler(device: device) else {
            log("display: MetalFX spatial scaler unavailable on \(device.name); drawing without super resolution")
            scalerFailed = true
            return nil
        }
        guard texture.usage.contains(s.colorTextureUsage) else {
            log("display: MetalFX needs input usage \(s.colorTextureUsage.rawValue), the frame texture has "
                + "\(texture.usage.rawValue); drawing without super resolution")
            scalerFailed = true
            return nil
        }
        let td = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: Renderer.layerFormat, width: width, height: height, mipmapped: false)
        td.usage = s.outputTextureUsage.union(.shaderRead)
        td.storageMode = .private
        guard let out = device.makeTexture(descriptor: td) else { return nil }
        s.outputTexture = out
        s.inputContentWidth = texture.width
        s.inputContentHeight = texture.height
        scaler = s
        upscaled = out
        log("display: MetalFX super resolution \(texture.width)x\(texture.height) -> \(width)x\(height)")
        return (s, out)
    }

    private func encode(into target: MTLTexture, commandBuffer cb: MTLCommandBuffer) {
        // Snap to whole pixels; nearest sampling for exact integer scale factors and for the
        // MetalFX output (already at the viewport's size).
        var source = texture, vp = MTLViewport(), nearestSampling = false
        if let texture {
            let fit = fitRect(in: CGSize(width: target.width, height: target.height))
            vp = MTLViewport(originX: Double(fit.minX.rounded()), originY: Double(fit.minY.rounded()),
                             width: Double(fit.width.rounded()), height: Double(fit.height.rounded()), znear: 0, zfar: 1)
            let sx = vp.width / Double(texture.width), sy = vp.height / Double(texture.height)
            nearestSampling = sx >= 1 && abs(sx - sx.rounded()) < 0.001 && abs(sy - sx) < 0.001
            if superResolution, sx > 1, sy > 1,
               case let (s, out)? = scaler(for: texture, width: Int(vp.width), height: Int(vp.height)) {
                s.colorTexture = texture   // a new frame texture of the same size reuses the scaler
                s.encode(commandBuffer: cb)
                source = out
                nearestSampling = true
            }
        }
        let rp = MTLRenderPassDescriptor()
        rp.colorAttachments[0].texture = target
        rp.colorAttachments[0].loadAction = .clear
        rp.colorAttachments[0].clearColor = MTLClearColor(red: 0, green: 0, blue: 0, alpha: 1)
        rp.colorAttachments[0].storeAction = .store
        guard let enc = cb.makeRenderCommandEncoder(descriptor: rp) else { return }
        if let source {
            enc.setViewport(vp)
            enc.setRenderPipelineState(pipeline)
            enc.setFragmentTexture(source, index: 0)
            enc.setFragmentSamplerState(nearestSampling ? nearest : linear, index: 0)
            enc.drawPrimitives(type: .triangleStrip, vertexStart: 0, vertexCount: 4)
        }
        enc.endEncoding()
    }

    /// `flushedAt` > 0 marks a new guest frame for the perf stats (on-screen time and latency).
    func draw(to layer: CAMetalLayer, flushedAt: CFTimeInterval = 0) {
        let perf = flushedAt > 0 ? PerfStats.shared : nil
        let t0 = perf != nil ? CACurrentMediaTime() : 0
        guard layer.drawableSize.width >= 1, layer.drawableSize.height >= 1,
              let drawable = layer.nextDrawable(),
              let cb = queue.makeCommandBuffer() else { return }
        if onFirstOnScreen != nil {
            drawable.addPresentedHandler { [weak self] d in
                guard d.presentedTime > 0 else { return }   // dropped, or the window is not on screen yet
                DispatchQueue.main.async {
                    guard let self, let f = self.onFirstOnScreen else { return }
                    self.onFirstOnScreen = nil
                    f()
                }
            }
        }
        if let perf {
            perf.waitedForDrawable(ms: (CACurrentMediaTime() - t0) * 1000)
            cb.addCompletedHandler { _ in perf.rendered(flushedAt: flushedAt) }
        }
        encode(into: drawable.texture, commandBuffer: cb)
        if let capture = captureNextDraw, !layer.framebufferOnly {
            captureNextDraw = nil
            let t = drawable.texture
            let w = t.width, h = t.height
            if let buf = device.makeBuffer(length: w * h * 4, options: .storageModeShared),
               let blit = cb.makeBlitCommandEncoder() {
                blit.copy(from: t, sourceSlice: 0, sourceLevel: 0, sourceOrigin: MTLOrigin(x: 0, y: 0, z: 0),
                          sourceSize: MTLSize(width: w, height: h, depth: 1), to: buf, destinationOffset: 0,
                          destinationBytesPerRow: w * 4, destinationBytesPerImage: w * h * 4)
                blit.endEncoding()
                cb.addCompletedHandler { _ in
                    capture(Array(UnsafeBufferPointer(start: buf.contents().assumingMemoryBound(to: UInt8.self), count: w * h * 4)), w, h)
                }
            }
        }
        cb.present(drawable)
        cb.commit()
        lastCommandBuffer = cb
    }

    /// Render exactly like `draw(to:)` into an offscreen BGRA texture and read it back
    /// (used by the display self-test to verify swizzles/scaling without screen capture).
    func renderOffscreen(width: Int, height: Int) -> [UInt8] {
        let td = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: Renderer.layerFormat, width: width, height: height, mipmapped: false)
        td.usage = [.renderTarget, .shaderRead]
        td.storageMode = .shared
        let target = device.makeTexture(descriptor: td)!
        let cb = queue.makeCommandBuffer()!
        encode(into: target, commandBuffer: cb)
        cb.commit()
        cb.waitUntilCompleted()
        var out = [UInt8](repeating: 0, count: width * height * 4)
        out.withUnsafeMutableBytes { p in
            target.getBytes(p.baseAddress!, bytesPerRow: width * 4, from: MTLRegionMake2D(0, 0, width, height), mipmapLevel: 0)
        }
        return out
    }
}
