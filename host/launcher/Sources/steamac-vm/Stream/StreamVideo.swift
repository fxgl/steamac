import CoreMedia
import CoreVideo
import Darwin
import Foundation
import VideoToolbox

/// Hardware encoding, the GameStream packet format, and its authenticated UDP endpoint.
final class StreamVideoStream {
    private let config: StreamVideoConfig
    private let capture: StreamCapture
    private let encoder: StreamVideoEncoder
    private let queue = DispatchQueue(label: "steamac.stream.video")
    private let packetizer = StreamVideoPacketizer()
    private var source: DispatchSourceRead?
    private var socketClosed: DispatchGroup?
    private var fd: Int32 = -1
    private var peer = sockaddr_storage()
    private var peerLength: socklen_t = 0
    private var expected = Data()
    private var pingPayload = Data()
    private var running = false
    private var forceKeyFrame = true
    private var frameIndex: UInt32 = 1
    private var firstFrameTime: CMTime?
    private var lastSendErrorLog: UInt64?
    private var receiveBuffer = [UInt8](repeating: 0, count: 256)
    var onError: ((String) -> Void)?

    init(config: StreamVideoConfig, capture: StreamCapture) throws {
        self.config = config
        self.capture = capture
        encoder = try StreamVideoEncoder(config: config)
        encoder.output = { [weak self] result in
            self?.queue.async { [weak self] in self?.encoded(result) }
        }
        encoder.onForcedFrameDropped = { [weak self] in self?.requestKeyFrame() }
    }

    deinit {
        if fd >= 0 {
            source?.cancel()
            if Thread.isMainThread { capture.stop() }
            else { DispatchQueue.main.async { [capture] in capture.stop() } }
        }
    }

    func start(clientAddress: String, pingPayload: Data) throws {
        try queue.sync {
            guard !running else { return }
            guard pingPayload.count == 16 else { throw StreamError("Invalid video ping payload") }
            guard let normalized = StreamPeerAddress.normalized(clientAddress) else {
                throw StreamError("Invalid video client address")
            }
            expected = normalized
            let family = normalized.count == 4 ? AF_INET : AF_INET6
            let socketFD = socket(family, SOCK_DGRAM, IPPROTO_UDP)
            guard socketFD >= 0 else { throw StreamError("Video socket: \(String(cString: strerror(errno)))") }
            var local = sockaddr_storage()
            local.ss_family = sa_family_t(family)
            let length: socklen_t
            if family == AF_INET6 {
                length = socklen_t(MemoryLayout<sockaddr_in6>.size)
                withUnsafeMutablePointer(to: &local) {
                    $0.withMemoryRebound(to: sockaddr_in6.self, capacity: 1) {
                        $0.pointee.sin6_len = UInt8(length)
                        $0.pointee.sin6_port = StreamPorts.video.bigEndian
                    }
                }
            } else {
                length = socklen_t(MemoryLayout<sockaddr_in>.size)
                withUnsafeMutablePointer(to: &local) {
                    $0.withMemoryRebound(to: sockaddr_in.self, capacity: 1) {
                        $0.pointee.sin_len = UInt8(length)
                        $0.pointee.sin_port = StreamPorts.video.bigEndian
                    }
                }
            }
            let bound = withUnsafePointer(to: &local) {
                $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { bind(socketFD, $0, length) }
            }
            guard bound == 0, fcntl(socketFD, F_SETFL, O_NONBLOCK) == 0 else {
                let message = String(cString: strerror(errno)); close(socketFD)
                throw StreamError("Bind video UDP \(StreamPorts.video): \(message)")
            }
            // AF41 marks interactive video without competing with the audio voice class.
            var tos: Int32 = 34 << 2
            _ = setsockopt(socketFD, family == AF_INET6 ? IPPROTO_IPV6 : IPPROTO_IP,
                           family == AF_INET6 ? IPV6_TCLASS : IP_TOS, &tos, socklen_t(MemoryLayout.size(ofValue: tos)))
            var sendBuffer: Int32 = 1 << 20
            _ = setsockopt(socketFD, SOL_SOCKET, SO_SNDBUF, &sendBuffer, socklen_t(MemoryLayout.size(ofValue: sendBuffer)))
            fd = socketFD
            self.pingPayload = pingPayload
            running = true
            let source = DispatchSource.makeReadSource(fileDescriptor: socketFD, queue: queue)
            source.setEventHandler { [weak self] in self?.receivePing() }
            let closed = DispatchGroup()
            closed.enter()
            source.setCancelHandler { close(socketFD); closed.leave() }
            socketClosed = closed
            self.source = source
            source.resume()
        }
    }

    func requestKeyFrame() {
        queue.async { [weak self] in
            guard let self, self.running else { return }
            self.forceKeyFrame = true
            DispatchQueue.main.async { [weak self] in self?.capture.refresh() }
        }
    }

    func invalidateReferenceFrames(first: Int64, last: Int64) { requestKeyFrame() }

    func stop() {
        let closed: DispatchGroup? = queue.sync {
            running = false
            source?.cancel(); source = nil
            fd = -1; peerLength = 0
            let closed = socketClosed
            socketClosed = nil
            return closed
        }
        // The cancel handler owns close; wait outside its queue so /resume can rebind immediately.
        closed?.wait()
        if Thread.isMainThread { capture.stop() }
        else { DispatchQueue.main.async { [capture] in capture.stop() } }
        encoder.stop()
    }

    private func receivePing() {
        while running {
            var address = sockaddr_storage(), length = socklen_t(MemoryLayout<sockaddr_storage>.size)
            let count = withUnsafeMutablePointer(to: &address) {
                $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { recvfrom(fd, &receiveBuffer, receiveBuffer.count, 0, $0, &length) }
            }
            guard count >= 0 else { return }
            guard Self.sameAddress(address, expected),
                  count == 20 && receiveBuffer.prefix(16).elementsEqual(pingPayload) else { continue }
            let first = peerLength == 0
            peer = address; peerLength = length
            if first {
                DispatchQueue.main.async { [weak self] in
                    guard let self, self.queue.sync(execute: { self.running }) else { return }
                    self.capture.start(width: self.config.width, height: self.config.height, fps: self.config.fps) { [weak self] buffer, time in
                        self?.queue.async { [weak self] in
                            guard let self, self.running else { return }
                            let key = self.forceKeyFrame; self.forceKeyFrame = false
                            do { try self.encoder.encode(buffer, time: time, keyFrame: key) }
                            catch { self.fail(String(describing: error)) }
                        }
                    }
                }
            }
        }
    }

    private static func sameAddress(_ address: sockaddr_storage, _ expected: Data) -> Bool {
        var address = address
        var text = [CChar](repeating: 0, count: Int(NI_MAXHOST))
        let length = socklen_t(address.ss_family == AF_INET6 ? MemoryLayout<sockaddr_in6>.size : MemoryLayout<sockaddr_in>.size)
        let result = withUnsafePointer(to: &address) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                getnameinfo($0, length, &text, socklen_t(text.count), nil, 0, NI_NUMERICHOST)
            }
        }
        return result == 0 && StreamPeerAddress.normalized(String(cString: text)) == expected
    }

    private static func timestamp(_ time: CMTime, since origin: CMTime) -> UInt32 {
        let relative = CMTimeConvertScale(CMTimeSubtract(time, origin), timescale: 90_000, method: .default)
        return UInt32(truncatingIfNeeded: max(0, relative.value))
    }

    private func encoded(_ result: Result<StreamVideoEncoder.Frame, Error>) {
        guard running, peerLength > 0 else { return }
        do {
            let frame = try result.get()
            if firstFrameTime == nil { firstFrameTime = frame.time }
            let timestamp = Self.timestamp(frame.time, since: firstFrameTime!)
            let blocks = try packetizer.packetize(frame.bytes, keyFrame: frame.keyFrame, config: config,
                                                  frameIndex: frameIndex, timestamp: timestamp)
            frameIndex &+= 1
            let started = DispatchTime.now().uptimeNanoseconds
            var sentBytes = 0
            // Spread a large IDR across at most half a frame instead of overflowing a Wi-Fi queue.
            let bytesPerSecond = max(Double(config.bitrateKbps) * 125 * 2, 1_000_000)
            let maxDelay = 0.5 / Double(config.fps)
            for block in blocks {
                for index in 0..<block.count {
                    if index % 16 == 0 {
                        let target = min(Double(sentBytes) / bytesPerSecond, maxDelay)
                        let elapsed = Double(DispatchTime.now().uptimeNanoseconds - started) / 1_000_000_000
                        if target > elapsed { usleep(useconds_t((target - elapsed) * 1_000_000)) }
                    }
                    let data = block.pointer(index)
                    let sent = withUnsafePointer(to: &peer) {
                        $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { sendto(fd, data, block.size, 0, $0, peerLength) }
                    }
                    if sent < 0 {
                        let error = errno
                        if error == EBADF || error == ENOTSOCK {
                            throw StreamError("Video socket unavailable: \(String(cString: strerror(error)))")
                        }
                        let now = DispatchTime.now().uptimeNanoseconds
                        if lastSendErrorLog == nil || now - lastSendErrorLog! >= 5_000_000_000 {
                            log("stream: dropping video datagram: \(String(cString: strerror(error)))")
                            lastSendErrorLog = now
                        }
                    }
                    sentBytes += block.size
                }
            }
        } catch { fail(String(describing: error)) }
    }

    private func fail(_ message: String) {
        guard running else { return }
        running = false
        log("stream: video: \(message)")
        let callback = onError
        DispatchQueue.main.async { callback?(message) }
    }

    static func selfCheck() -> [String] {
        var failures = StreamVideoPacketizer.selfCheck()
        let origin = CMTime(value: 60_000_000, timescale: 60)
        if timestamp(origin, since: origin) != 0
            || timestamp(CMTimeAdd(origin, CMTime(value: 1, timescale: 60)), since: origin) != 1500 {
            failures.append("video RTP timestamp is not relative to the first frame")
        }
        for codec in [StreamCodec.h264, .hevc] {
            for (fullRange, colorspace) in [(false, 0), (false, 1), (true, 1), (true, 2)] {
                do { try StreamVideoEncoder.selfCheck(codec: codec, fullRange: fullRange, colorspace: colorspace) }
                catch { failures.append("video \(codec.rawValue) range=\(fullRange) color=\(colorspace): \(error)") }
            }
        }
        return failures
    }
}

private final class StreamVideoEncoder {
    struct Frame {
        let bytes: Data
        let keyFrame: Bool
        let time: CMTime
    }
    let config: StreamVideoConfig
    private var session: VTCompressionSession?
    private var transfer: VTPixelTransferSession?
    var output: ((Result<Frame, Error>) -> Void)?
    var onForcedFrameDropped: (() -> Void)?
    // Opaque per-frame context, never dereferenced or retained; no per-frame allocation.
    private static let forcedFrame = UnsafeMutableRawPointer(bitPattern: 1)!

    init(config: StreamVideoConfig) throws {
        guard config.width > 0, config.height > 0, config.fps > 0, config.bitrateKbps > 0,
              config.packetSize > 24, config.packetSize <= 65_491 else { throw StreamError("Invalid video configuration") }
        self.config = config
        let specification = [kVTVideoEncoderSpecification_RequireHardwareAcceleratedVideoEncoder: true,
                             kVTVideoEncoderSpecification_EnableLowLatencyRateControl: true] as CFDictionary
        let format = config.fullRange ? kCVPixelFormatType_420YpCbCr8BiPlanarFullRange : kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange
        let attributes: [CFString: Any] = [kCVPixelBufferPixelFormatTypeKey: format,
            kCVPixelBufferWidthKey: config.width, kCVPixelBufferHeightKey: config.height,
            kCVPixelBufferIOSurfacePropertiesKey: [:] as CFDictionary]
        var created: VTCompressionSession?
        try Self.check(VTCompressionSessionCreate(allocator: kCFAllocatorDefault, width: Int32(config.width), height: Int32(config.height),
            codecType: config.codec == .h264 ? kCMVideoCodecType_H264 : kCMVideoCodecType_HEVC,
            encoderSpecification: specification, imageBufferAttributes: attributes as CFDictionary, compressedDataAllocator: nil,
            outputCallback: { context, sourceFrame, status, flags, sample in
                guard let context else { return }
                let encoder = Unmanaged<StreamVideoEncoder>.fromOpaque(context).takeUnretainedValue()
                encoder.didEncode(sourceFrame: sourceFrame, status: status, flags: flags, sample: sample)
            }, refcon: Unmanaged.passUnretained(self).toOpaque(), compressionSessionOut: &created), "create hardware encoder")
        session = created
        do {
            try property(kVTCompressionPropertyKey_RealTime, kCFBooleanTrue)
            try property(kVTCompressionPropertyKey_AllowFrameReordering, kCFBooleanFalse)
            try property(kVTCompressionPropertyKey_ExpectedFrameRate, config.fps as CFNumber)
            try property(kVTCompressionPropertyKey_AverageBitRate, (config.bitrateKbps * 1000) as CFNumber)
            try property(kVTCompressionPropertyKey_MaxKeyFrameInterval, Int32.max as CFNumber)
            try property(kVTCompressionPropertyKey_MaxKeyFrameIntervalDuration, Double(Int32.max) as CFNumber)
            try property(kVTCompressionPropertyKey_ProfileLevel,
                         config.codec == .h264 ? kVTProfileLevel_H264_High_AutoLevel : kVTProfileLevel_HEVC_Main_AutoLevel)
            try property(kVTCompressionPropertyKey_ColorPrimaries, colorPrimaries)
            try property(kVTCompressionPropertyKey_TransferFunction, colorTransfer)
            try property(kVTCompressionPropertyKey_YCbCrMatrix, colorMatrix)
            optionalProperty(kVTCompressionPropertyKey_MaxFrameDelayCount, 0 as CFNumber)
            optionalProperty(kVTCompressionPropertyKey_PrioritizeEncodingSpeedOverQuality, kCFBooleanTrue)
            if config.maxReferenceFrames > 0 {
                optionalProperty(kVTCompressionPropertyKey_ReferenceBufferCount, config.maxReferenceFrames as CFNumber)
            }
            if config.slicesPerFrame > 1 && config.codec == .h264 {
                let sliceBytes = max(128, config.bitrateKbps * 125 / config.fps / config.slicesPerFrame)
                optionalProperty(kVTCompressionPropertyKey_MaxH264SliceBytes, sliceBytes as CFNumber)
            }
            try Self.check(VTPixelTransferSessionCreate(allocator: kCFAllocatorDefault, pixelTransferSessionOut: &transfer), "create video color converter")
            if let transfer {
                try Self.check(VTSessionSetProperty(transfer, key: kVTPixelTransferPropertyKey_DestinationColorPrimaries, value: colorPrimaries), "set converter primaries")
                try Self.check(VTSessionSetProperty(transfer, key: kVTPixelTransferPropertyKey_DestinationTransferFunction, value: colorTransfer), "set converter transfer")
                try Self.check(VTSessionSetProperty(transfer, key: kVTPixelTransferPropertyKey_DestinationYCbCrMatrix, value: colorMatrix), "set converter matrix")
            }
            try Self.check(VTCompressionSessionPrepareToEncodeFrames(created!), "prepare encoder")
        } catch { stop(); throw error }
    }

    private func didEncode(sourceFrame: UnsafeMutableRawPointer?, status: OSStatus,
                           flags: VTEncodeInfoFlags, sample: CMSampleBuffer?) {
        if status == noErr && flags.contains(.frameDropped) {
            if sourceFrame == Self.forcedFrame { onForcedFrameDropped?() }
            return
        }
        guard status == noErr, let sample else {
            output?(.failure(StreamError("Video encoder callback: \(status)"))); return
        }
        do { output?(.success(try annexB(sample))) }
        catch { output?(.failure(error)) }
    }

    private var colorPrimaries: CFString {
        config.colorspace == 2 ? kCVImageBufferColorPrimaries_ITU_R_2020 :
            (config.colorspace == 0 ? kCVImageBufferColorPrimaries_SMPTE_C : kCVImageBufferColorPrimaries_ITU_R_709_2)
    }
    // CoreVideo defines the SDR Rec.2020 transfer as equivalent to, and prefers, Rec.709.
    private var colorTransfer: CFString { kCVImageBufferTransferFunction_ITU_R_709_2 }
    private var colorMatrix: CFString {
        config.colorspace == 2 ? kCVImageBufferYCbCrMatrix_ITU_R_2020 :
            (config.colorspace == 0 ? kCVImageBufferYCbCrMatrix_ITU_R_601_4 : kCVImageBufferYCbCrMatrix_ITU_R_709_2)
    }
    private func property(_ key: CFString, _ value: CFTypeRef) throws {
        try Self.check(VTSessionSetProperty(session!, key: key, value: value), "set \(key)")
    }
    private func optionalProperty(_ key: CFString, _ value: CFTypeRef) {
        let result = VTSessionSetProperty(session!, key: key, value: value)
        if result != noErr { log("stream: encoder does not support \(key) (\(result))") }
    }
    private static func check(_ status: OSStatus, _ operation: String) throws {
        guard status == noErr else { throw StreamError("\(operation): \(status)") }
    }

    func encode(_ image: CVPixelBuffer, time: CMTime, keyFrame: Bool) throws {
        guard let session, let transfer, let pool = VTCompressionSessionGetPixelBufferPool(session) else {
            throw StreamError("Video encoder stopped or has no pixel buffer pool")
        }
        var converted: CVPixelBuffer?
        try Self.check(CVPixelBufferPoolCreatePixelBuffer(kCFAllocatorDefault, pool, &converted), "allocate encoder surface")
        guard let converted else { throw StreamError("No encoder surface") }
        try Self.check(VTPixelTransferSessionTransferImage(transfer, from: image, to: converted), "convert captured image")
        CVBufferSetAttachment(converted, kCVImageBufferColorPrimariesKey, colorPrimaries, .shouldPropagate)
        CVBufferSetAttachment(converted, kCVImageBufferTransferFunctionKey, colorTransfer, .shouldPropagate)
        CVBufferSetAttachment(converted, kCVImageBufferYCbCrMatrixKey, colorMatrix, .shouldPropagate)
        let options = keyFrame ? [kVTEncodeFrameOptionKey_ForceKeyFrame: true] as CFDictionary : nil
        try Self.check(VTCompressionSessionEncodeFrame(session, imageBuffer: converted, presentationTimeStamp: time,
            duration: CMTime(value: 1, timescale: Int32(config.fps)), frameProperties: options,
            sourceFrameRefcon: keyFrame ? Self.forcedFrame : nil, infoFlagsOut: nil), "encode video frame")
    }

    func complete() throws {
        if let session { try Self.check(VTCompressionSessionCompleteFrames(session, untilPresentationTimeStamp: .invalid), "flush video encoder") }
    }
    func stop() {
        if let session {
            _ = VTCompressionSessionCompleteFrames(session, untilPresentationTimeStamp: .invalid)
            VTCompressionSessionInvalidate(session)
            self.session = nil
        }
        if let transfer { VTPixelTransferSessionInvalidate(transfer); self.transfer = nil }
    }
    deinit { stop() }

    private func annexB(_ sample: CMSampleBuffer) throws -> Frame {
        guard let format = CMSampleBufferGetFormatDescription(sample), let block = CMSampleBufferGetDataBuffer(sample) else {
            throw StreamError("Encoder returned no bitstream")
        }
        let attachments = CMSampleBufferGetSampleAttachmentsArray(sample, createIfNecessary: false) as? [[CFString: Any]]
        let keyFrame = attachments?.first?[kCMSampleAttachmentKey_NotSync] as? Bool != true
        var parameterCount = 0, lengthBytes: Int32 = 0
        if config.codec == .h264 {
            try Self.check(CMVideoFormatDescriptionGetH264ParameterSetAtIndex(format, parameterSetIndex: 0,
                parameterSetPointerOut: nil, parameterSetSizeOut: nil, parameterSetCountOut: &parameterCount, nalUnitHeaderLengthOut: &lengthBytes), "read H264 format")
        } else {
            try Self.check(CMVideoFormatDescriptionGetHEVCParameterSetAtIndex(format, parameterSetIndex: 0,
                parameterSetPointerOut: nil, parameterSetSizeOut: nil, parameterSetCountOut: &parameterCount, nalUnitHeaderLengthOut: &lengthBytes), "read HEVC format")
        }
        let startCode: [UInt8] = [0, 0, 0, 1]
        let total = CMBlockBufferGetDataLength(block)
        var result = Data(); result.reserveCapacity(total + 256)
        if keyFrame {
            for index in 0..<parameterCount {
                var pointer: UnsafePointer<UInt8>?, size = 0
                let status = config.codec == .h264
                    ? CMVideoFormatDescriptionGetH264ParameterSetAtIndex(format, parameterSetIndex: index, parameterSetPointerOut: &pointer, parameterSetSizeOut: &size, parameterSetCountOut: nil, nalUnitHeaderLengthOut: nil)
                    : CMVideoFormatDescriptionGetHEVCParameterSetAtIndex(format, parameterSetIndex: index, parameterSetPointerOut: &pointer, parameterSetSizeOut: &size, parameterSetCountOut: nil, nalUnitHeaderLengthOut: nil)
                try Self.check(status, "read codec parameter set")
                guard let pointer else { throw StreamError("Missing codec parameter set") }
                result.append(contentsOf: startCode); result.append(pointer, count: size)
            }
        }
        var contiguous: CMBlockBuffer?
        try Self.check(CMBlockBufferCreateContiguous(allocator: kCFAllocatorDefault, sourceBuffer: block, blockAllocator: kCFAllocatorDefault,
            customBlockSource: nil, offsetToData: 0, dataLength: 0, flags: 0, blockBufferOut: &contiguous), "read encoded sample")
        var bytes: UnsafeMutablePointer<Int8>?
        try Self.check(CMBlockBufferGetDataPointer(contiguous!, atOffset: 0, lengthAtOffsetOut: nil, totalLengthOut: nil, dataPointerOut: &bytes), "read NAL bytes")
        guard let bytes, (1...4).contains(Int(lengthBytes)) else { throw StreamError("Invalid NAL length prefix") }
        let pointer = UnsafeRawPointer(bytes).assumingMemoryBound(to: UInt8.self)
        var offset = 0
        while offset < total {
            guard offset + Int(lengthBytes) <= total else { throw StreamError("Truncated NAL length") }
            var size = 0
            for i in 0..<Int(lengthBytes) { size = size << 8 | Int(pointer[offset + i]) }
            offset += Int(lengthBytes)
            guard size > 0, size <= total - offset else { throw StreamError("Truncated NAL unit") }
            result.append(contentsOf: startCode); result.append(pointer.advanced(by: offset), count: size)
            offset += size
        }
        return Frame(bytes: result, keyFrame: keyFrame, time: CMSampleBufferGetPresentationTimeStamp(sample))
    }

    static func selfCheck(codec: StreamCodec, fullRange: Bool, colorspace: Int) throws {
        let config = StreamVideoConfig(width: 320, height: 180, fps: 60, bitrateKbps: 2000, packetSize: 1024,
            minRequiredFecPackets: 2, codec: codec, fullRange: fullRange, colorspace: colorspace, maxReferenceFrames: 1, slicesPerFrame: 2)
        let encoder = try StreamVideoEncoder(config: config)
        defer { encoder.stop() }
        let lock = NSLock()
        var frames: [Frame] = [], errors: [String] = []
        encoder.output = { result in
            lock.lock(); defer { lock.unlock() }
            switch result { case .success(let frame): frames.append(frame); case .failure(let error): errors.append(String(describing: error)) }
        }
        var forcedDrops = 0
        encoder.onForcedFrameDropped = { forcedDrops += 1 }
        encoder.didEncode(sourceFrame: nil, status: noErr, flags: .frameDropped, sample: nil)
        encoder.didEncode(sourceFrame: Self.forcedFrame, status: noErr, flags: .frameDropped, sample: nil)
        guard forcedDrops == 1, errors.isEmpty else { throw StreamError("Dropped forced frame did not request exactly one replacement") }
        encoder.onForcedFrameDropped = nil
        var pool: CVPixelBufferPool?
        try check(CVPixelBufferPoolCreate(kCFAllocatorDefault, nil, [kCVPixelBufferPixelFormatTypeKey: kCVPixelFormatType_32BGRA,
            kCVPixelBufferWidthKey: config.width, kCVPixelBufferHeightKey: config.height,
            kCVPixelBufferIOSurfacePropertiesKey: [:]] as CFDictionary, &pool), "create test IOSurface pool")
        for index in 0..<4 {
            var buffer: CVPixelBuffer?
            try check(CVPixelBufferPoolCreatePixelBuffer(kCFAllocatorDefault, pool!, &buffer), "create test frame")
            CVPixelBufferLockBaseAddress(buffer!, [])
            let base = CVPixelBufferGetBaseAddress(buffer!)!.assumingMemoryBound(to: UInt8.self)
            let stride = CVPixelBufferGetBytesPerRow(buffer!)
            for y in 0..<config.height {
                for x in 0..<config.width {
                    let p = base.advanced(by: y * stride + x * 4)
                    p[0] = UInt8(truncatingIfNeeded: x + index * 20); p[1] = UInt8(truncatingIfNeeded: y)
                    p[2] = 120; p[3] = 255
                }
            }
            CVPixelBufferUnlockBaseAddress(buffer!, [])
            try encoder.encode(buffer!, time: CMTime(value: Int64(index), timescale: 60), keyFrame: index == 0 || index == 2)
        }
        try encoder.complete()
        guard errors.isEmpty, frames.count == 4, frames[0].keyFrame, frames[2].keyFrame,
              !frames[1].keyFrame, !frames[3].keyFrame else { throw StreamError("Encoder frame/IDR check failed: \(errors), \(frames.map(\.keyFrame))") }
        for frame in frames {
            guard frame.bytes.prefix(4).elementsEqual([0, 0, 0, 1]) else { throw StreamError("Missing Annex-B start code") }
            if frame.keyFrame {
                let type = codec == .h264 ? frame.bytes[4] & 31 : (frame.bytes[4] >> 1) & 63
                guard type == (codec == .h264 ? 7 : 32) else { throw StreamError("Missing IDR parameter sets") }
            }
        }
        var format: CMVideoFormatDescription?
        let samples = try frames.map { try sampleFromAnnexB($0, codec: codec, format: &format) }
        guard let format else { throw StreamError("No test format") }
        let extensions = CMFormatDescriptionGetExtensions(format) as NSDictionary?
        guard (extensions?[kCMFormatDescriptionExtension_FullRangeVideo] as? Bool ?? false) == config.fullRange else {
            throw StreamError("Encoded range does not match requested range")
        }
        guard extensions?[kCMFormatDescriptionExtension_ColorPrimaries] as? String == encoder.colorPrimaries as String,
              extensions?[kCMFormatDescriptionExtension_TransferFunction] as? String == encoder.colorTransfer as String,
              extensions?[kCMFormatDescriptionExtension_YCbCrMatrix] as? String == encoder.colorMatrix as String else {
            throw StreamError("Encoded color metadata differs: \(String(describing: extensions))")
        }
        final class DecodeState {
            let lock = NSLock()
            var count = 0
            var failed = false
        }
        let state = DecodeState()
        var callback = VTDecompressionOutputCallbackRecord(decompressionOutputCallback: { context, _, status, _, image, _, _ in
            let state = Unmanaged<DecodeState>.fromOpaque(context!).takeUnretainedValue()
            state.lock.lock(); defer { state.lock.unlock() }
            if status == noErr && image != nil { state.count += 1 } else { state.failed = true }
        }, decompressionOutputRefCon: Unmanaged.passUnretained(state).toOpaque())
        var decoder: VTDecompressionSession?
        try check(VTDecompressionSessionCreate(allocator: kCFAllocatorDefault, formatDescription: format,
            decoderSpecification: nil, imageBufferAttributes: nil, outputCallback: &callback, decompressionSessionOut: &decoder), "create test decoder")
        defer { VTDecompressionSessionInvalidate(decoder!) }
        for sample in samples {
            try check(VTDecompressionSessionDecodeFrame(decoder!, sampleBuffer: sample, flags: [], frameRefcon: nil, infoFlagsOut: nil), "decode test frame")
        }
        try check(VTDecompressionSessionWaitForAsynchronousFrames(decoder!), "wait for test decoder")
        guard !state.failed, state.count == 4 else { throw StreamError("Decoder output check: \(state.count) frames") }
    }

    private static func sampleFromAnnexB(_ frame: Frame, codec: StreamCodec,
                                        format: inout CMVideoFormatDescription?) throws -> CMSampleBuffer {
        let bytes = [UInt8](frame.bytes)
        var units: [Data] = []
        var start = 4, index = 4
        while index + 3 < bytes.count {
            if bytes[index] == 0 && bytes[index + 1] == 0 && bytes[index + 2] == 0 && bytes[index + 3] == 1 {
                units.append(Data(bytes[start..<index]))
                index += 4; start = index
            } else { index += 1 }
        }
        units.append(Data(bytes[start...]))
        func isParameter(_ unit: Data) -> Bool {
            guard let first = unit.first else { return false }
            let type = codec == .h264 ? first & 31 : first >> 1 & 63
            return codec == .h264 ? (type == 7 || type == 8) : (32...34).contains(type)
        }
        let containsIDR = units.contains { unit in
            guard let first = unit.first else { return false }
            let type = codec == .h264 ? first & 31 : first >> 1 & 63
            return codec == .h264 ? type == 5 : (type == 19 || type == 20)
        }
        guard containsIDR == frame.keyFrame else { throw StreamError("Annex-B IDR NAL does not match key-frame request") }
        if frame.keyFrame {
            let parameters = units.filter(isParameter).map { $0 as NSData }
            guard parameters.count == (codec == .h264 ? 2 : 3) else { throw StreamError("Incomplete Annex-B parameter sets") }
            let pointers = parameters.map { $0.bytes.assumingMemoryBound(to: UInt8.self) }
            let sizes = parameters.map { $0.length }
            let status = codec == .h264
                ? CMVideoFormatDescriptionCreateFromH264ParameterSets(allocator: kCFAllocatorDefault, parameterSetCount: pointers.count,
                    parameterSetPointers: pointers, parameterSetSizes: sizes, nalUnitHeaderLength: 4, formatDescriptionOut: &format)
                : CMVideoFormatDescriptionCreateFromHEVCParameterSets(allocator: kCFAllocatorDefault, parameterSetCount: pointers.count,
                    parameterSetPointers: pointers, parameterSetSizes: sizes, nalUnitHeaderLength: 4, extensions: nil, formatDescriptionOut: &format)
            try check(status, "parse Annex-B codec configuration")
        }
        guard let format else { throw StreamError("Annex-B picture before configuration") }
        var compressed = Data()
        for unit in units where !isParameter(unit) {
            var length = UInt32(unit.count).bigEndian
            withUnsafeBytes(of: &length) { compressed.append(contentsOf: $0) }
            compressed.append(unit)
        }
        var block: CMBlockBuffer?
        try check(CMBlockBufferCreateWithMemoryBlock(allocator: kCFAllocatorDefault, memoryBlock: nil, blockLength: compressed.count,
            blockAllocator: kCFAllocatorDefault, customBlockSource: nil, offsetToData: 0, dataLength: compressed.count,
            flags: 0, blockBufferOut: &block), "allocate Annex-B decoder sample")
        try compressed.withUnsafeBytes {
            try check(CMBlockBufferReplaceDataBytes(with: $0.baseAddress!, blockBuffer: block!, offsetIntoDestination: 0,
                dataLength: compressed.count), "copy Annex-B decoder sample")
        }
        var sample: CMSampleBuffer?
        var timing = CMSampleTimingInfo(duration: .invalid, presentationTimeStamp: frame.time, decodeTimeStamp: .invalid)
        var size = compressed.count
        try check(CMSampleBufferCreateReady(allocator: kCFAllocatorDefault, dataBuffer: block, formatDescription: format,
            sampleCount: 1, sampleTimingEntryCount: 1, sampleTimingArray: &timing, sampleSizeEntryCount: 1,
            sampleSizeArray: &size, sampleBufferOut: &sample), "create Annex-B decoder sample")
        return sample!
    }
}
