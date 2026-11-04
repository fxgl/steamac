import AudioToolbox
import CNanors
import CommonCrypto
import Darwin
import Foundation

private func audioStatus(_ status: OSStatus, _ operation: String) throws {
    if status != noErr { throw StreamError("audio \(operation): OSStatus \(status)") }
}

private func audioPCM(_ rate: Double, _ channels: Int) -> AudioStreamBasicDescription {
    AudioStreamBasicDescription(mSampleRate: rate, mFormatID: kAudioFormatLinearPCM,
        mFormatFlags: kAudioFormatFlagIsFloat | kAudioFormatFlagIsPacked,
        mBytesPerPacket: UInt32(channels * 4), mFramesPerPacket: 1,
        mBytesPerFrame: UInt32(channels * 4), mChannelsPerFrame: UInt32(channels),
        mBitsPerChannel: 32, mReserved: 0)
}

/// Guest periods arrive in bursts, not in Opus-sized packets. Keep those intact; only a
/// sustained excess over one measured burst plus three packets indicates growing latency.
private final class StreamAudioRing {
    let lock = NSLock()
    let channels: Int
    let capacity: Int
    private let packetDurationMs: Int
    let samples: UnsafeMutablePointer<Float>
    var rate = 48_000
    private var positions: [UInt8] = []
    private var weights: [Float] = []
    private var readIndex = 0
    private var count = 0
    private var burstFrames = 0
    private var excessSince: UInt64?

    init(channels: Int, packetDurationMs: Int) {
        self.channels = channels
        self.packetDurationMs = packetDurationMs
        capacity = 24_000 * channels
        samples = .allocate(capacity: capacity)
        samples.initialize(repeating: 0, count: capacity)
    }
    deinit { samples.deinitialize(count: capacity); samples.deallocate() }

    func push(_ source: UnsafePointer<Float>, frames: Int, rate: Int, positions sourcePositions: UnsafeBufferPointer<UInt8>) {
        guard frames > 0, rate > 0, sourcePositions.count > 0, sourcePositions.count <= 12 else { return }
        lock.lock()
        defer { lock.unlock() }
        if self.rate != rate || !positions.elementsEqual(sourcePositions) {
            self.rate = rate
            positions = Array(sourcePositions)
            count = 0
            readIndex = 0
            burstFrames = 0
            excessSince = nil
            // VirtIO/ALSA speaker IDs -> Moonlight's FL FR C LFE RL RR SL SR order.
            let output: [UInt8] = channels == 2 ? [3, 4] : (channels == 6 ? [3, 4, 7, 8, 5, 6] : [3, 4, 7, 8, 5, 6, 9, 10])
            weights = [Float](repeating: 0, count: channels * positions.count)
            for (s, speaker) in positions.enumerated() {
                var target = output.firstIndex(of: speaker)
                if target == nil, speaker == 9 { target = output.firstIndex(of: 5) }
                if target == nil, speaker == 10 { target = output.firstIndex(of: 6) }
                if let target { weights[target * positions.count + s] = 1; continue }
                let left: Set<UInt8> = [3, 5, 9, 12, 22, 25, 30]
                let right: Set<UInt8> = [4, 6, 10, 13, 23, 26, 31]
                if !right.contains(speaker) { weights[s] = speaker == 2 ? 1 : (speaker == 8 ? 0.5 : 0.7071) }
                if !left.contains(speaker) { weights[positions.count + s] = speaker == 2 ? 1 : (speaker == 8 ? 0.5 : 0.7071) }
            }
            for d in 0..<channels {
                let start = d * positions.count
                let sum = weights[start..<(start + positions.count)].reduce(0, +)
                if sum > 1 { for s in 0..<positions.count { weights[start + s] /= sum } }
            }
        }
        burstFrames = max(burstFrames, min(frames, capacity / channels))
        let keep = min(frames, capacity / channels)
        let incoming = keep * channels
        if count + incoming > capacity {
            let discard = count + incoming - capacity
            readIndex = (readIndex + discard) % capacity
            count -= discard
        }
        var writeIndex = (readIndex + count) % capacity
        for f in (frames - keep)..<frames {
            for d in 0..<channels {
                var value: Float = 0
                for s in 0..<positions.count { value += source[f * positions.count + s] * weights[d * positions.count + s] }
                samples[writeIndex] = max(-1, min(1, value))
                writeIndex = (writeIndex + 1) % capacity
            }
        }
        count += incoming
    }

    /// A period-sized peak is normal. Trim only after 100 ms continuously above the target,
    /// and cut complete source packets so a transient/coalesced timer never chops a burst.
    func trim(now: UInt64 = DispatchTime.now().uptimeNanoseconds) -> (rate: Int, frames: Int) {
        lock.lock()
        defer { lock.unlock() }
        let packetFrames = max(1, (rate * packetDurationMs + 999) / 1000)
        let targetFrames = burstFrames + packetFrames * 3
        let bufferedFrames = count / channels
        if bufferedFrames > targetFrames {
            if let since = excessSince {
                if now >= since, now - since >= 100_000_000 {
                    let drop = (bufferedFrames - targetFrames) / packetFrames * packetFrames * channels
                    readIndex = (readIndex + drop) % capacity
                    count -= drop
                    excessSince = nil
                }
            } else { excessSince = now }
        } else { excessSince = nil }
        return (rate, count / channels)
    }

    func discard() {
        lock.lock()
        count = 0
        readIndex = 0
        excessSince = nil
        lock.unlock()
    }

    func pull(_ destination: UnsafeMutablePointer<Float>, frames: Int) {
        lock.lock()
        defer { lock.unlock() }
        let wanted = frames * channels
        let available = min(count, wanted)
        for i in 0..<available { destination[i] = samples[(readIndex + i) % capacity] }
        if available < wanted { destination.advanced(by: available).update(repeating: 0, count: wanted - available) }
        readIndex = (readIndex + available) % capacity
        count -= available
    }
}

private final class StreamAudioResampler {
    let converter: AudioConverterRef
    let ring: StreamAudioRing
    let rate: Int
    let input: UnsafeMutablePointer<Float>
    let capacity = 8192
    init(ring: StreamAudioRing, rate: Int) throws {
        self.ring = ring
        self.rate = rate
        input = .allocate(capacity: capacity * ring.channels)
        var source = audioPCM(Double(rate), ring.channels)
        var dest = audioPCM(48_000, ring.channels)
        var created: AudioConverterRef?
        let status = AudioConverterNew(&source, &dest, &created)
        guard status == noErr, let created else { input.deallocate(); throw StreamError("audio resampler: \(status)") }
        converter = created
        var prime = UInt32(kConverterPrimeMethod_None)
        AudioConverterSetProperty(converter, kAudioConverterPrimeMethod, 4, &prime)
    }
    deinit { AudioConverterDispose(converter); input.deallocate() }
    func render(_ output: UnsafeMutablePointer<Float>, frames: Int) throws {
        var packets = UInt32(frames)
        var list = AudioBufferList(mNumberBuffers: 1, mBuffers: AudioBuffer(mNumberChannels: UInt32(ring.channels),
            mDataByteSize: UInt32(frames * ring.channels * 4), mData: output))
        try audioStatus(AudioConverterFillComplexBuffer(converter, { _, count, list, descriptions, context in
            let owner = Unmanaged<StreamAudioResampler>.fromOpaque(context!).takeUnretainedValue()
            let frames = min(Int(count.pointee), owner.capacity)
            owner.ring.pull(owner.input, frames: frames)
            count.pointee = UInt32(frames)
            list.pointee.mNumberBuffers = 1
            list.pointee.mBuffers = AudioBuffer(mNumberChannels: UInt32(owner.ring.channels),
                mDataByteSize: UInt32(frames * owner.ring.channels * 4), mData: owner.input)
            descriptions?.pointee = nil
            return noErr
        }, Unmanaged.passUnretained(self).toOpaque(), &packets, &list, nil), "resample")
        guard packets == frames else { throw StreamError("audio resampler returned \(packets) of \(frames) frames") }
    }
}

private final class StreamAudioCodec {
    let converter: AudioConverterRef
    let channels: Int
    let frames: Int
    let compressed: Bool
    private var input: UnsafeRawPointer?
    private var remaining = 0
    private var description = AudioStreamPacketDescription(mStartOffset: 0, mVariableFramesInPacket: 0, mDataByteSize: 0)
    private var borrowedDescription: UnsafeMutablePointer<AudioStreamPacketDescription>?
    private let output: UnsafeMutableRawPointer
    private let outputCapacity = 16_384

    init(channels: Int, frames: Int, bitrate: Int, decode: Bool = false) throws {
        self.channels = channels; self.frames = frames; compressed = decode
        output = .allocate(byteCount: outputCapacity, alignment: 16)
        var pcm = audioPCM(48_000, channels)
        var opus = AudioStreamBasicDescription(mSampleRate: 48_000, mFormatID: kAudioFormatOpus,
            mFormatFlags: 0, mBytesPerPacket: 0, mFramesPerPacket: UInt32(frames), mBytesPerFrame: 0,
            mChannelsPerFrame: UInt32(channels), mBitsPerChannel: 0, mReserved: 0)
        var created: AudioConverterRef?
        let status = decode ? AudioConverterNew(&opus, &pcm, &created) : AudioConverterNew(&pcm, &opus, &created)
        guard status == noErr, let created else { output.deallocate(); throw StreamError("audio Opus converter: \(status)") }
        converter = created
        if decode {
            // Raw GameStream Opus has no container pre-skip; do not trim the first packet.
            var prime = AudioConverterPrimeInfo(leadingFrames: 0, trailingFrames: 0)
            try audioStatus(AudioConverterSetProperty(converter, kAudioConverterPrimeInfo,
                UInt32(MemoryLayout.size(ofValue: prime)), &prime), "Opus decoder priming")
        } else {
            var rate = UInt32(bitrate)
            try audioStatus(AudioConverterSetProperty(converter, kAudioConverterEncodeBitRate, 4, &rate), "Opus bitrate")
            var mode = UInt32(kAudioCodecBitRateControlMode_Constant)
            try audioStatus(AudioConverterSetProperty(converter, kAudioCodecPropertyBitRateControlMode, 4, &mode), "Opus CBR")
        }
    }
    deinit { AudioConverterDispose(converter); output.deallocate() }

    func convert(_ data: UnsafeRawPointer, bytes: Int) throws -> Data {
        input = data; remaining = compressed ? 1 : bytes / (channels * 4)
        description.mDataByteSize = UInt32(bytes)
        var packets: UInt32 = compressed ? UInt32(frames) : 1
        var list = AudioBufferList(mNumberBuffers: 1, mBuffers: AudioBuffer(mNumberChannels: UInt32(channels),
            mDataByteSize: UInt32(outputCapacity), mData: output))
        var packet = AudioStreamPacketDescription()
        let status = withUnsafeMutablePointer(to: &description) { description in
            borrowedDescription = description
            return AudioConverterFillComplexBuffer(converter, { _, requested, list, descriptions, context in
                let owner = Unmanaged<StreamAudioCodec>.fromOpaque(context!).takeUnretainedValue()
                let supplied = min(Int(requested.pointee), owner.remaining)
                requested.pointee = UInt32(supplied)
                if supplied == 0 { return 1 }
                let bytes = owner.compressed ? Int(owner.borrowedDescription!.pointee.mDataByteSize) : supplied * owner.channels * 4
                list.pointee.mNumberBuffers = 1
                list.pointee.mBuffers = AudioBuffer(mNumberChannels: UInt32(owner.channels), mDataByteSize: UInt32(bytes),
                    mData: UnsafeMutableRawPointer(mutating: owner.input))
                if owner.compressed { descriptions?.pointee = owner.borrowedDescription }
                else { descriptions?.pointee = nil }
                owner.input = owner.input?.advanced(by: bytes)
                owner.remaining -= supplied
                return noErr
            }, Unmanaged.passUnretained(self).toOpaque(), &packets, &list, &packet)
        }
        borrowedDescription = nil
        guard status == noErr || (status == 1 && packets > 0) else { throw StreamError("audio Opus conversion: \(status)") }
        guard packets == (compressed ? UInt32(frames) : 1) else { throw StreamError("audio Opus returned \(packets) packets") }
        return Data(bytes: output, count: Int(list.mBuffers.mDataByteSize))
    }
}

/// RFC 6716 packet framing: make each stream self-delimited except the last one, and pad
/// every packet to a constant length so all four encrypted audio-FEC data shards match.
private enum StreamOpusFraming {
    static func size(_ n: Int) -> [UInt8] {
        n < 252 ? [UInt8(n)] : [UInt8(252 + (n & 3)), UInt8((n - 252 - (n & 3)) / 4)]
    }
    static func packet(_ packet: Data, selfDelimited: Bool, paddedSize: Int) throws -> Data {
        let b = [UInt8](packet)
        guard b.count >= 2 else { throw StreamError("audio empty Opus packet") }
        // 5/10 ms encoders produce a single CELT frame; accepting another packet structure
        // would require changing the self-delimited size position, not just prefixing a length.
        guard b[0] & 3 == 0 else { throw StreamError("audio Opus encoder did not produce a single frame") }
        let length = b.count - 1
        guard length <= 1275 else { throw StreamError("audio oversized Opus frame") }
        var prefix: [UInt8] = [(b[0] & 0xfc) | 3, 0x41]
        let delim = selfDelimited ? size(length) : []
        let budget = paddedSize - prefix.count - delim.count - length
        guard budget >= 1 else { throw StreamError("audio Opus frame exceeds CBR packet budget") }
        // A padding length octet of 255 contributes 254 padding bytes (RFC 6716 §3.2.1).
        var padding = budget - 1
        while padding >= 255 { prefix.append(255); padding -= 255 }
        prefix.append(UInt8(padding))
        prefix += delim
        var result = Data(prefix)
        result.append(contentsOf: b.dropFirst())
        result.append(Data(repeating: 0, count: paddedSize - result.count))
        return result
    }
}

private enum StreamAudioCrypto {
    static func crypt(_ data: Data, key: Data, keyID: UInt32, sequence: UInt16, decrypt: Bool = false) throws -> Data {
        guard key.count == kCCKeySizeAES128 else { throw StreamError("audio requires a 128-bit key") }
        var iv = Data(repeating: 0, count: kCCBlockSizeAES128)
        var counter = (keyID &+ UInt32(sequence)).bigEndian
        withUnsafeBytes(of: &counter) { iv.replaceSubrange(0..<4, with: $0) }
        var output = Data(count: data.count + kCCBlockSizeAES128)
        var written = 0
        let capacity = output.count
        let result = output.withUnsafeMutableBytes { dest in data.withUnsafeBytes { source in key.withUnsafeBytes { keyBytes in iv.withUnsafeBytes { ivBytes in
            CCCrypt(CCOperation(decrypt ? kCCDecrypt : kCCEncrypt), CCAlgorithm(kCCAlgorithmAES), CCOptions(kCCOptionPKCS7Padding),
                keyBytes.baseAddress, key.count, ivBytes.baseAddress, source.baseAddress, data.count,
                dest.baseAddress, capacity, &written)
        } } } }
        guard result == kCCSuccess else { throw StreamError("audio AES-CBC: \(result)") }
        output.count = written
        return output
    }
}

private final class StreamAudioFEC {
    let codec: OpaquePointer
    let shards: [UnsafeMutablePointer<UInt8>?]
    let capacity = 4096
    init() throws {
        StreamFEC.initialize()
        guard let codec = reed_solomon_new(4, 2), let matrix = cnanors_parity_matrix(codec) else { throw StreamError("audio FEC allocation failed") }
        self.codec = codec
        let parity: [UInt8] = [0x77, 0x40, 0x38, 0x0e, 0xc7, 0xa7, 0x0d, 0x6c]
        for i in parity.indices { matrix[i] = parity[i] }
        shards = (0..<6).map { _ in UnsafeMutablePointer<UInt8>.allocate(capacity: 4096) }
    }
    deinit { reed_solomon_release(codec); for shard in shards { shard?.deallocate() } }
    func store(_ data: Data, index: Int) throws {
        guard data.count <= capacity else { throw StreamError("audio FEC shard too large") }
        data.copyBytes(to: shards[index]!, count: data.count)
    }
    func encode(bytes: Int) throws {
        var pointers = shards
        guard reed_solomon_encode(codec, &pointers, 6, Int32(bytes)) == 0 else { throw StreamError("audio FEC encoding failed") }
    }
}

final class StreamAudioStream {
    private typealias Tap = @convention(c) (UnsafePointer<Float>?, UInt32, UInt32, UInt32, UnsafePointer<UInt8>?, UnsafeMutableRawPointer?) -> Void
    private typealias SetTap = @convention(c) (UInt32, Tap?, UnsafeMutableRawPointer?) -> Int32
    private let ctx: UInt32
    private let sound: SoundControl
    private let config: StreamAudioConfig
    private let launch: StreamLaunch
    private let setTap: SetTap?
    private let ring: StreamAudioRing
    private let queue = DispatchQueue(label: "steamac.stream.audio", qos: .userInteractive)
    private let queueKey = DispatchSpecificKey<Bool>()
    private let fec: StreamAudioFEC
    private var resampler: StreamAudioResampler?
    private var encoders: [StreamAudioCodec] = []
    private let pcm: UnsafeMutablePointer<Float>
    private let pair: UnsafeMutablePointer<Float>
    private var source: DispatchSourceRead?
    private var timer: DispatchSourceTimer?
    private let socketLifetime = DispatchGroup()
    private var socket: Int32 = -1
    private var peer = sockaddr_storage()
    private var peerLength: socklen_t = 0
    private var expectedAddress = ""
    private var pingPayload = Data()
    private var sequence: UInt16 = 0
    private var timestamp: UInt32 = 0
    private var fecSize = 0
    private var running = false
    private var didStart = false
    private var tapped = false
    private var stopped = false
    private let packetBytes: Int
    private var frames: Int { config.packetDurationMs * 48 }

    init(ctx: UInt32, sound: SoundControl, config: StreamAudioConfig, launch: StreamLaunch) throws {
        guard [2, 6, 8].contains(config.channels), config.streams == config.channels / 2,
              config.coupledStreams == config.streams, config.mapping == (0..<config.channels).map(UInt8.init),
              [5, 10].contains(config.packetDurationMs) else { throw StreamError("unsupported audio configuration") }
        self.ctx = ctx; self.sound = sound; self.config = config; self.launch = launch
        setTap = dlsym(UnsafeMutableRawPointer(bitPattern: -2), "krun_snd_set_playback_tap").map { unsafeBitCast($0, to: SetTap.self) }
        ring = StreamAudioRing(channels: config.channels, packetDurationMs: config.packetDurationMs)
        fec = try StreamAudioFEC()
        pcm = .allocate(capacity: config.packetDurationMs * 48 * config.channels)
        pair = .allocate(capacity: config.packetDurationMs * 48 * 2)
        // Four HQ stereo pairs, CBC and FEC must fit Moonlight's 1400-byte receive buffer.
        packetBytes = (config.highQuality ? 224_000 : 96_000) * config.packetDurationMs / 8000 + 32
        for _ in 0..<config.streams {
            encoders.append(try StreamAudioCodec(channels: 2, frames: config.packetDurationMs * 48,
                bitrate: config.highQuality ? 224_000 : 96_000))
        }
        if config.encrypted, launch.aesKey.count != 16 { throw StreamError("audio requires a 128-bit key") }
        queue.setSpecific(key: queueKey, value: true)
    }
    deinit { stop(); pcm.deallocate(); pair.deallocate() }

    func start(clientAddress: String, pingPayload: Data) throws {
        guard pingPayload.count == 16 else { throw StreamError("audio ping payload must contain 16 bytes") }
        try queue.sync {
            guard !running, !stopped else { throw StreamError("audio stream already started or stopped") }
            var hints = addrinfo()
            hints.ai_family = AF_UNSPEC; hints.ai_socktype = SOCK_DGRAM; hints.ai_flags = AI_NUMERICHOST
            var address: UnsafeMutablePointer<addrinfo>?
            guard getaddrinfo(clientAddress, nil, &hints, &address) == 0, let address else { throw StreamError("invalid audio client address") }
            defer { freeaddrinfo(address) }
            let fd = Darwin.socket(address.pointee.ai_family, SOCK_DGRAM, 0)
            guard fd >= 0 else { throw StreamError("audio socket: \(String(cString: strerror(errno)))") }
            var local = sockaddr_storage()
            let length: socklen_t
            if address.pointee.ai_family == AF_INET6 {
                length = socklen_t(MemoryLayout<sockaddr_in6>.size)
                withUnsafeMutablePointer(to: &local) { $0.withMemoryRebound(to: sockaddr_in6.self, capacity: 1) {
                    $0.pointee.sin6_len = UInt8(length); $0.pointee.sin6_family = sa_family_t(AF_INET6); $0.pointee.sin6_port = StreamPorts.audio.bigEndian
                } }
            } else {
                length = socklen_t(MemoryLayout<sockaddr_in>.size)
                withUnsafeMutablePointer(to: &local) { $0.withMemoryRebound(to: sockaddr_in.self, capacity: 1) {
                    $0.pointee.sin_len = UInt8(length); $0.pointee.sin_family = sa_family_t(AF_INET); $0.pointee.sin_port = StreamPorts.audio.bigEndian
                } }
            }
            let bound = withUnsafePointer(to: &local) { $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { Darwin.bind(fd, $0, length) } }
            guard bound == 0 else { let error = errno; close(fd); throw StreamError("audio bind: \(String(cString: strerror(error)))") }
            _ = fcntl(fd, F_SETFL, O_NONBLOCK)
            socket = fd
            expectedAddress = Self.numericAddress(address.pointee.ai_addr, length: address.pointee.ai_addrlen)
            self.pingPayload = pingPayload
            running = true
            didStart = true
            let reader = DispatchSource.makeReadSource(fileDescriptor: fd, queue: queue)
            reader.setEventHandler { [weak self] in self?.receivePing() }
            socketLifetime.enter()
            reader.setCancelHandler { [socketLifetime] in
                close(fd)
                socketLifetime.leave()
            }
            source = reader; reader.resume()
            let clock = DispatchSource.makeTimerSource(queue: queue)
            clock.schedule(deadline: .now(), repeating: .milliseconds(config.packetDurationMs), leeway: .microseconds(300))
            clock.setEventHandler { [weak self] in self?.tick() }
            timer = clock; clock.resume()
            if let setTap {
                let result = setTap(ctx, { samples, frames, rate, channels, positions, context in
                    guard let samples, let positions, let context else { return }
                    let ring = Unmanaged<StreamAudioRing>.fromOpaque(context).takeUnretainedValue()
                    ring.push(samples, frames: Int(frames), rate: Int(rate), positions: UnsafeBufferPointer(start: positions, count: Int(channels)))
                }, Unmanaged.passUnretained(ring).toOpaque())
                tapped = result == 0
                if !tapped { log("stream: guest playback tap unavailable (\(result)); streaming silent audio") }
            } else { log("stream: libkrun has no krun_snd_set_playback_tap; streaming silent audio (rebuild host/libkrun)") }
            DispatchQueue.main.async { [sound, launch] in sound.setStreamingMuted(!launch.playAudioOnHost) }
        }
    }

    func stop() {
        let finish = {
            guard !self.stopped else { return }
            if self.tapped { _ = self.setTap?(self.ctx, nil, nil); self.tapped = false }
            self.stopped = true; self.running = false
            self.timer?.cancel(); self.timer = nil
            self.source?.cancel(); self.source = nil
            self.socket = -1
            if self.didStart {
                DispatchQueue.main.async { [sound = self.sound] in sound.setStreamingMuted(false) }
            }
        }
        if DispatchQueue.getSpecific(key: queueKey) == true { finish() }
        else {
            queue.sync(execute: finish)
            // The cancel handler owns close; an immediate replacement can safely bind.
            socketLifetime.wait()
        }
    }

    private static func numericAddress(_ address: UnsafePointer<sockaddr>?, length: socklen_t) -> String {
        guard let address else { return "" }
        var name = [CChar](repeating: 0, count: Int(NI_MAXHOST))
        guard getnameinfo(address, length, &name, socklen_t(name.count), nil, 0, NI_NUMERICHOST) == 0 else { return "" }
        return String(cString: name)
    }
    private func receivePing() {
        var buffer = [UInt8](repeating: 0, count: 2048)
        while running {
            var address = sockaddr_storage()
            var length = socklen_t(MemoryLayout<sockaddr_storage>.size)
            let n = withUnsafeMutablePointer(to: &address) { $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                recvfrom(socket, &buffer, buffer.count, 0, $0, &length)
            } }
            if n < 0 { return }
            guard (n == 16 || n == 20), buffer.prefix(16).elementsEqual(pingPayload) else { continue }
            let name = withUnsafePointer(to: &address) { $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { Self.numericAddress($0, length: length) } }
            guard StreamPeerAddress.matches(name, expectedAddress) else { continue }
            peer = address; peerLength = length
        }
    }
    private func send(_ packet: Data) {
        packet.withUnsafeBytes { bytes in withUnsafePointer(to: &peer) { $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
            _ = sendto(socket, bytes.baseAddress, packet.count, 0, $0, peerLength)
        } } }
    }
    private static func header(type: UInt8, sequence: UInt16, timestamp: UInt32) -> Data {
        Data([0x80, type, UInt8(sequence >> 8), UInt8(truncatingIfNeeded: sequence),
              UInt8(timestamp >> 24), UInt8(truncatingIfNeeded: timestamp >> 16), UInt8(truncatingIfNeeded: timestamp >> 8), UInt8(truncatingIfNeeded: timestamp), 0, 0, 0, 0])
    }
    private func tick() {
        guard running else { return }
        guard peerLength != 0 else {
            ring.discard()
            resampler = nil
            return
        }
        do {
            let rate = ring.trim().rate
            if resampler?.rate != rate { resampler = try StreamAudioResampler(ring: ring, rate: rate) }
            let owed = max(1, Int(timer?.data ?? 1))
            for _ in 0..<owed {
                try resampler!.render(pcm, frames: frames)
                var payload = Data()
                for stream in encoders.indices {
                    for frame in 0..<frames {
                        pair[frame * 2] = pcm[frame * config.channels + stream * 2]
                        pair[frame * 2 + 1] = pcm[frame * config.channels + stream * 2 + 1]
                    }
                    let encoded = try encoders[stream].convert(pair, bytes: frames * 8)
                    payload.append(try StreamOpusFraming.packet(encoded, selfDelimited: stream != encoders.count - 1, paddedSize: packetBytes))
                }
                if config.encrypted { payload = try StreamAudioCrypto.crypt(payload, key: launch.aesKey, keyID: launch.aesKeyID, sequence: sequence) }
                let shard = Int(sequence % 4)
                try fec.store(payload, index: shard)
                fecSize = payload.count
                var packet = Self.header(type: 97, sequence: sequence, timestamp: timestamp)
                packet.append(payload); send(packet)
                sequence &+= 1
                timestamp &+= UInt32(config.packetDurationMs)
                if shard == 3 {
                    try fec.encode(bytes: fecSize)
                    for i in 0..<2 {
                        var parity = Self.header(type: 127, sequence: sequence &+ UInt16(i), timestamp: 0)
                        var description = Self.header(type: 97, sequence: sequence &- 4, timestamp: timestamp &- UInt32(config.packetDurationMs * 4))
                        description[0] = UInt8(i)
                        parity.append(description)
                        parity.append(fec.shards[4 + i]!, count: fecSize)
                        send(parity)
                    }
                }
            }
        } catch {
            stop()
            log("stream: audio stopped: \(error)")
        }
    }

    static func sdpAttributes() -> [String] {
        // Normal quality SDP uses GFE order (LFE last); HQ uses the client's WAVE order.
        ["a=rtpmap:97 opus/48000/2", "a=fmtp:97 surround-params=633012453",
         "a=fmtp:97 surround-params=633012345", "a=fmtp:97 surround-params=84401245673",
         "a=fmtp:97 surround-params=84401234567"]
    }
    static func config(channels: Int, channelMask: UInt32, highQuality: Bool, packetDurationMs: Int, encrypted: Bool) -> StreamAudioConfig {
        let count = [6, 8].contains(channels) ? channels : 2
        return StreamAudioConfig(channels: count, streams: count / 2, coupledStreams: count / 2,
            mapping: (0..<count).map(UInt8.init), packetDurationMs: packetDurationMs == 10 ? 10 : 5,
            highQuality: highQuality, encrypted: encrypted)
    }

    static func selfCheck() -> [String] {
        var failures: [String] = []
        for duration in [5, 10] {
            let ring = StreamAudioRing(channels: 2, packetDurationMs: duration)
            let samples = [Float](repeating: 0.5, count: 1440 * 2)
            let positions: [UInt8] = [3, 4]
            let output = UnsafeMutablePointer<Float>.allocate(capacity: duration * 48 * 2)
            var clock: UInt64 = 0
            for _ in 0..<50 {
                samples.withUnsafeBufferPointer { samples in
                    positions.withUnsafeBufferPointer { ring.push(samples.baseAddress!, frames: 1440, rate: 48_000, positions: $0) }
                }
                for packet in 0..<(30 / duration) {
                    if ring.trim(now: clock).frames != 1440 - packet * duration * 48 {
                        failures.append("audio latency control dropped a normal 30 ms burst")
                    }
                    ring.pull(output, frames: duration * 48)
                    if UnsafeBufferPointer(start: output, count: duration * 48 * 2).contains(where: { $0 != 0.5 }) {
                        failures.append("audio latency control inserted silence in a normal burst")
                    }
                    clock += UInt64(duration) * 1_000_000
                }
            }
            output.deallocate()
            ring.discard()
            if ring.trim().frames != 0 { failures.append("audio waiting-for-peer discard failed") }
            do {
                let frames = duration * 48
                let encoder = try StreamAudioCodec(channels: 2, frames: frames, bitrate: 96_000)
                let decoder = try StreamAudioCodec(channels: 2, frames: frames, bitrate: 0, decode: true)
                let samples = (0..<(frames * 2)).map { Float(sin(Double($0 / 2) * 0.05) * 0.2) }
                let encoded = try samples.withUnsafeBytes { try encoder.convert($0.baseAddress!, bytes: $0.count) }
                let padded = try StreamOpusFraming.packet(encoded, selfDelimited: false, paddedSize: 96_000 * duration / 8000 + 32)
                let decoded = try padded.withUnsafeBytes { try decoder.convert($0.baseAddress!, bytes: $0.count) }
                if decoded.count != frames * 8 { failures.append("audio Opus \(duration) ms decoded wrong frame count") }
            } catch { failures.append("audio Opus \(duration) ms: \(error)") }
        }
        for (speaker, side) in [(UInt8(12), 0), (13, 1), (30, 0), (31, 1)] {
            let ring = StreamAudioRing(channels: 2, packetDurationMs: 5)
            var sample: Float = 0.5
            var position = speaker
            withUnsafePointer(to: &sample) { sample in
                withUnsafePointer(to: &position) { ring.push(sample, frames: 1, rate: 48_000, positions: UnsafeBufferPointer(start: $0, count: 1)) }
            }
            let output = UnsafeMutablePointer<Float>.allocate(capacity: 2)
            ring.pull(output, frames: 1)
            if output[side] <= 0 || output[1 - side] != 0 { failures.append("audio downmix routes speaker \(speaker) to the wrong side") }
            output.deallocate()
        }
        do {
            let fec = try StreamAudioFEC()
            let original = (0..<4).map { shard in Data((0..<128).map { UInt8(truncatingIfNeeded: shard * 63 + $0) }) }
            for i in 0..<4 { try fec.store(original[i], index: i) }
            try fec.encode(bytes: 128)
            fec.shards[0]!.update(repeating: 0, count: 128); fec.shards[2]!.update(repeating: 0, count: 128)
            var marks: [UInt8] = [1, 0, 1, 0, 0, 0]
            var pointers = fec.shards
            if reed_solomon_decode(fec.codec, &pointers, &marks, 6, 128) != 0 { failures.append("audio FEC decode failed") }
            for i in 0..<4 where Data(bytes: fec.shards[i]!, count: 128) != original[i] { failures.append("audio FEC recovered incorrect shard \(i)") }
            let key = Data(0..<16)
            for sequence: UInt16 in [0, 1, 65535] {
                let encrypted = try StreamAudioCrypto.crypt(original[0], key: key, keyID: 0xffff_fffe, sequence: sequence)
                let decrypted = try StreamAudioCrypto.crypt(encrypted, key: key, keyID: 0xffff_fffe, sequence: sequence, decrypt: true)
                if decrypted != original[0] { failures.append("audio AES-CBC round trip failed") }
            }
        } catch { failures.append("audio FEC/crypto: \(error)") }
        return failures
    }
}
