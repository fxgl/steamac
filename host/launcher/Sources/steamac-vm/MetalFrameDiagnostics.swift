import Foundation
import Darwin
import Metal
import QuartzCore

/// Bounded local diagnostics; owns the capture hook only when streaming is disabled.
final class MetalFrameDiagnostics: @unchecked Sendable {
    static let shared = MetalFrameDiagnostics()
    private typealias Callback = @convention(c) (UnsafeMutableRawPointer?, UnsafeMutableRawPointer?, UnsafeMutableRawPointer?) -> Void
    private typealias Setter = @convention(c) (Callback?, UnsafeMutableRawPointer?) -> Void
    private var timer: Timer?
    private var library: UnsafeMutableRawPointer?
    private let lock = NSLock()
    private var nextSample = 0.0
    private var samples = 0

    func start(libraryPath: String) {
        guard timer == nil, library == nil else { return }
        timer = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { [self] timer in
            guard let handle = dlopen(libraryPath, RTLD_NOW | RTLD_NOLOAD) else { return }
            guard let symbol = dlsym(handle, "wmtr_stream_capture_set") else { dlclose(handle); return }
            library = handle
            let setter = unsafeBitCast(symbol, to: Setter.self)
            setter({ _, buffer, drawable in
                guard let buffer, let drawable,
                      let cb = Unmanaged<AnyObject>.fromOpaque(buffer).takeUnretainedValue() as? MTLCommandBuffer,
                      let dr = Unmanaged<AnyObject>.fromOpaque(drawable).takeUnretainedValue() as? CAMetalDrawable else { return }
                MetalFrameDiagnostics.shared.sample(cb, dr)
            }, nil)
            log("metal-diagnostic: installed pre-present sampling hook")
            timer.invalidate()
        }
    }

    func stop() {
        timer?.invalidate()
        timer = nil
        if let library, let symbol = dlsym(library, "wmtr_stream_capture_set") {
            unsafeBitCast(symbol, to: Setter.self)(nil, nil)
        }
        // Keep the loaded image retained for any in-flight completion handlers.
    }

    private func sample(_ cb: MTLCommandBuffer, _ drawable: CAMetalDrawable) {
        lock.lock()
        let now = CACurrentMediaTime()
        guard now >= nextSample, samples < 120 else { lock.unlock(); return }
        samples += 1
        let number = samples
        nextSample = now + 5
        lock.unlock()
        let texture = drawable.texture
        let width = texture.width, height = texture.height
        let format = texture.pixelFormat
        log("metal-diagnostic: frame=\(number) submitted size=\(width)x\(height) format=\(format.rawValue) framebufferOnly=\(texture.isFramebufferOnly)")
        drawable.addPresentedHandler { shown in
            log("metal-diagnostic: frame=\(number) presentedTime=\(shown.presentedTime)")
        }
        var readback: MTLBuffer?
        let stride = ((width * 4 + 255) / 256) * 256
        if !texture.isFramebufferOnly, width > 0, height > 0, width <= 8192, height <= 8192,
           [.bgra8Unorm, .bgra8Unorm_srgb, .rgba8Unorm, .rgba8Unorm_srgb].contains(format),
           let buffer = texture.device.makeBuffer(length: stride * height, options: .storageModeShared),
           let blit = cb.makeBlitCommandEncoder() {
            blit.copy(from: texture, sourceSlice: 0, sourceLevel: 0, sourceOrigin: MTLOrigin(x: 0, y: 0, z: 0),
                      sourceSize: MTLSize(width: width, height: height, depth: 1), to: buffer,
                      destinationOffset: 0, destinationBytesPerRow: stride, destinationBytesPerImage: stride * height)
            blit.endEncoding()
            readback = buffer
        }
        let pixels = readback
        cb.addCompletedHandler { command in
            log("metal-diagnostic: frame=\(number) status=\(command.status.rawValue) gpuMs=\((command.gpuEndTime - command.gpuStartTime) * 1000) error=\(String(describing: command.error))")
            guard command.status == .completed, let pixels else {
                log("metal-diagnostic: frame=\(number) pixels unavailable")
                return
            }
            let bytes = pixels.contents().assumingMemoryBound(to: UInt8.self)
            var nonblack = 0, total = 0, peak: UInt8 = 0
            for y in Swift.stride(from: 0, to: height, by: max(1, height / 128)) {
                for x in Swift.stride(from: 0, to: width, by: max(1, width / 128)) {
                    let i = y * stride + x * 4
                    let value = max(bytes[i], bytes[i + 1], bytes[i + 2])
                    peak = max(peak, value)
                    nonblack += value > 2 ? 1 : 0
                    total += 1
                }
            }
            log("metal-diagnostic: frame=\(number) sampledNonblack=\(nonblack)/\(total) peakRGB=\(peak)")
        }
    }
}
