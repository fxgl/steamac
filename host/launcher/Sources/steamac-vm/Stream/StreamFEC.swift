import CNanors
import Foundation

enum StreamFEC {
    private static let initialized: Void = { reed_solomon_init() }()
    static func initialize() { _ = initialized }
}

/// GameStream protects complete datagrams, including RTP and NV headers, with nanors.
/// Parity headers are patched afterwards; the client restores those fields after recovery.
final class StreamVideoPacketizer {
    final class Block {
        let dataCount: Int
        let parityCount: Int
        let size: Int
        let stride: Int
        let bytes: UnsafeMutableRawPointer
        var count: Int { dataCount + parityCount }
        init(dataCount: Int, parityCount: Int, size: Int) {
            self.dataCount = dataCount; self.parityCount = parityCount; self.size = size
            stride = (size + 63) & ~63
            bytes = UnsafeMutableRawPointer.allocate(byteCount: stride * (dataCount + parityCount), alignment: 64)
            bytes.initializeMemory(as: UInt8.self, repeating: 0, count: stride * (dataCount + parityCount))
        }
        func pointer(_ index: Int) -> UnsafeMutablePointer<UInt8> {
            bytes.advanced(by: index * stride).assumingMemoryBound(to: UInt8.self)
        }
        deinit { bytes.deallocate() }
    }
    private var sequence: UInt32 = 0
    private var codecs: [Int: OpaquePointer] = [:]

    private func codec(data: Int, parity: Int) throws -> OpaquePointer {
        StreamFEC.initialize()
        let key = data << 8 | parity
        if let existing = codecs[key] { return existing }
        guard let created = reed_solomon_new(Int32(data), Int32(parity)) else {
            throw StreamError("Cannot create video Reed-Solomon codec (\(data)+\(parity))")
        }
        codecs[key] = created
        return created
    }
    deinit { for codec in codecs.values { reed_solomon_release(codec) } }

    private static func fecParameters(data: Int, minimum: Int) -> (parity: Int, percentage: Int) {
        let maximumParity = max(0, 255 - data)
        let minimum = min(minimum, maximumParity)
        let minimumPercentage = minimum > 0 ? ((minimum - 1) * 100 / data + 1) : 0
        let maximumPercentage = min(255, maximumParity * 100 / data)
        let percentage = min(max(20, minimumPercentage), maximumPercentage)
        return ((data * percentage + 99) / 100, percentage)
    }
    private static func little(_ value: UInt32, _ p: UnsafeMutablePointer<UInt8>) {
        p[0] = UInt8(truncatingIfNeeded: value); p[1] = UInt8(truncatingIfNeeded: value >> 8)
        p[2] = UInt8(truncatingIfNeeded: value >> 16); p[3] = UInt8(truncatingIfNeeded: value >> 24)
    }
    private static func big(_ value: UInt32, _ p: UnsafeMutablePointer<UInt8>) {
        p[0] = UInt8(truncatingIfNeeded: value >> 24); p[1] = UInt8(truncatingIfNeeded: value >> 16)
        p[2] = UInt8(truncatingIfNeeded: value >> 8); p[3] = UInt8(truncatingIfNeeded: value)
    }
    private static func readLittle(_ p: UnsafePointer<UInt8>) -> UInt32 {
        UInt32(p[0]) | UInt32(p[1]) << 8 | UInt32(p[2]) << 16 | UInt32(p[3]) << 24
    }

    func packetize(_ frame: Data, keyFrame: Bool, config: StreamVideoConfig,
                   frameIndex: UInt32, timestamp: UInt32) throws -> [Block] {
        let payloadSize = config.packetSize - 16
        guard payloadSize >= 9, config.packetSize <= 65_491,
              config.minRequiredFecPackets >= 0, config.minRequiredFecPackets <= 254 else {
            throw StreamError("Invalid video packet/FEC configuration")
        }
        let total = frame.count + 8
        // An eight-bit percentage cannot express four parity shards for one data shard.
        // Zero-padding an extra data shard keeps the negotiated minimum representable.
        let minimumData = config.minRequiredFecPackets > 0 ? (config.minRequiredFecPackets - 1) * 100 / 255 + 1 : 1
        let dataCount = max((total + payloadSize - 1) / payloadSize, minimumData)
        guard dataCount <= 4 * 1023 else {
            log("stream: dropping video frame \(frameIndex): \(dataCount) data shards exceeds the 4092-shard wire limit")
            return []
        }
        // Large frames retain four balanced blocks, reducing parity to the GF(256) limit.
        // With more than 255 data shards in a block, the client reassembles without FEC.
        let dataPerProtectedBlock = 255 * 100 / 120
        let blockCount = min(4, (dataCount + dataPerProtectedBlock - 1) / dataPerProtectedBlock)
        var header = [UInt8](repeating: 0, count: 8)
        header[0] = 1; header[3] = keyFrame ? 2 : 1
        let lastSize = (total - 1) % payloadSize + 1
        header.withUnsafeMutableBufferPointer { Self.little(UInt32(lastSize), $0.baseAddress!.advanced(by: 4)) }
        var blocks: [Block] = []; blocks.reserveCapacity(blockCount)
        var firstDataIndex = 0
        try frame.withUnsafeBytes { raw in
            let frameBytes = raw.bindMemory(to: UInt8.self)
            for blockIndex in 0..<blockCount {
                let count = dataCount / blockCount + (blockIndex < dataCount % blockCount ? 1 : 0)
                let fec = Self.fecParameters(data: count, minimum: config.minRequiredFecPackets)
                let block = Block(dataCount: count, parityCount: fec.parity, size: config.packetSize + 16)
                let multi = UInt8(blockIndex << 4 | (blockCount - 1) << 6)
                for index in 0..<count {
                    let p = block.pointer(index)
                    p[0] = 0x90
                    p[2] = UInt8(truncatingIfNeeded: sequence >> 8); p[3] = UInt8(truncatingIfNeeded: sequence)
                    Self.big(timestamp, p.advanced(by: 4))
                    Self.little(sequence << 8, p.advanced(by: 16))
                    Self.little(frameIndex, p.advanced(by: 20))
                    p[24] = 1 | (index == 0 ? 4 : 0) | (index == count - 1 ? 2 : 0)
                    p[26] = 0x10; p[27] = multi
                    Self.little(UInt32(index << 12 | count << 22 | fec.percentage << 4), p.advanced(by: 28))
                    let offset = (firstDataIndex + index) * payloadSize
                    let length = max(0, min(payloadSize, total - offset))
                    var written = 0
                    if offset < 8 {
                        let n = min(8 - offset, length)
                        header.withUnsafeBytes { h in
                            p.advanced(by: 32).update(from: h.bindMemory(to: UInt8.self).baseAddress!.advanced(by: offset), count: n)
                        }
                        written = n
                    }
                    if length > written {
                        p.advanced(by: 32 + written).update(from: frameBytes.baseAddress!.advanced(by: offset + written - 8), count: length - written)
                    }
                    sequence &+= 1
                }
                if fec.parity > 0 {
                    let rs = try codec(data: count, parity: fec.parity)
                    let status = withUnsafeTemporaryAllocation(of: UnsafeMutablePointer<UInt8>?.self, capacity: block.count) { pointers in
                        for index in 0..<block.count { pointers[index] = block.pointer(index) }
                        return reed_solomon_encode(rs, pointers.baseAddress!, Int32(block.count), Int32(block.size))
                    }
                    guard status == 0 else {
                        throw StreamError("Video FEC encoding failed")
                    }
                }
                for index in count..<block.count {
                    let p = block.pointer(index)
                    p[0] = 0x90; p[1] = 0
                    p[2] = UInt8(truncatingIfNeeded: sequence >> 8); p[3] = UInt8(truncatingIfNeeded: sequence)
                    Self.little(frameIndex, p.advanced(by: 20))
                    p[27] = multi
                    Self.little(UInt32(index << 12 | count << 22 | fec.percentage << 4), p.advanced(by: 28))
                    sequence &+= 1
                }
                blocks.append(block)
                firstDataIndex += count
            }
        }
        return blocks
    }

    static func selfCheck() -> [String] {
        do {
            var config = StreamVideoConfig(width: 1920, height: 1080, fps: 60, bitrateKbps: 20000, packetSize: 1024,
                minRequiredFecPackets: 3, codec: .h264, fullRange: false, colorspace: 1, maxReferenceFrames: 1, slicesPerFrame: 1)
            let packetizer = StreamVideoPacketizer()
            // Exercise every block count, a short last packet, and RTP sequence wrap.
            packetizer.sequence = 65_530
            for (size, minimum) in [(1, 0), (1, 3), (1, 4), (1, 12), (1, 183), (999, 3), (1000, 3),
                                     (210_000, 3), (300_000, 3), (510_000, 3), (800_000, 3),
                                     (950_000, 3), (1_100_000, 3), (4 * 1023 * 1008 - 8, 3)] {
                config.minRequiredFecPackets = minimum
                var frame = Data((0..<size).map { UInt8(truncatingIfNeeded: $0 * 37 + 11) })
                if size >= 5 { frame.replaceSubrange(0..<5, with: [0, 0, 0, 1, 0x65]) }
                let blocks = try packetizer.packetize(frame, keyFrame: true, config: config, frameIndex: 3, timestamp: 90_000)
                guard blocks.count <= 4 else { throw StreamError("Too many FEC blocks") }
                guard blocks.allSatisfy({
                    let parameters = fecParameters(data: $0.dataCount, minimum: minimum)
                    let wireInfo = readLittle($0.pointer(0).advanced(by: 28))
                    return $0.dataCount <= 1023 && $0.parityCount == parameters.parity
                        && ($0.parityCount == 0 || $0.count <= 255)
                        && Int(wireInfo >> 22) == $0.dataCount
                        && Int((wireInfo >> 4) & 255) == parameters.percentage
                }) else { throw StreamError("Invalid video FEC shard limits or wire metadata") }
                for loss in [0, 1, 2] {
                    var rebuilt = Data()
                    for (blockIndex, original) in blocks.enumerated() {
                        let block = Block(dataCount: original.dataCount, parityCount: original.parityCount, size: original.size)
                        block.bytes.copyMemory(from: original.bytes, byteCount: original.stride * original.count)
                        var marks = [UInt8](repeating: 0, count: block.count)
                        let drops = block.parityCount == 0 || loss == 0 ? 0 : (loss == 1 ? 1 : block.parityCount)
                        // Spread losses over data and parity, including the first data packet.
                        let order = Array(stride(from: 0, to: block.count, by: 2)) + Array(stride(from: 1, to: block.count, by: 2))
                        let indices = order.prefix(drops)
                        for index in indices {
                            marks[index] = 1
                            block.pointer(index).initialize(repeating: 0, count: block.size)
                        }
                        // The client converts the RTP sequence to host order before FEC.
                        for index in 0..<block.count where marks[index] == 0 {
                            let p = block.pointer(index)
                            let first = p[2]; p[2] = p[3]; p[3] = first
                        }
                        if drops > 0 {
                            let rs = try packetizer.codec(data: block.dataCount, parity: block.parityCount)
                            var pointers: [UnsafeMutablePointer<UInt8>?] = (0..<block.count).map { block.pointer($0) }
                            guard reed_solomon_decode(rs, &pointers, &marks, Int32(block.count), Int32(block.size)) == 0 else {
                                throw StreamError("Video FEC recovery failed")
                            }
                        }
                        for index in 0..<block.dataCount {
                            let p = block.pointer(index)
                            if marks[index] != 0 {
                                // Like RtpVideoQueue: these fields were overwritten on parity packets.
                                Self.little(3, p.advanced(by: 20))
                                p[27] = UInt8(blockIndex << 4 | (blocks.count - 1) << 6)
                            }
                            guard p[24] == original.pointer(index)[24],
                                  readLittle(p.advanced(by: 16)) == readLittle(original.pointer(index).advanced(by: 16)),
                                  p[27] == UInt8(blockIndex << 4 | (blocks.count - 1) << 6) else {
                                throw StreamError("Recovered video packet headers differ")
                            }
                            rebuilt.append(p.advanced(by: 32), count: config.packetSize - 16)
                        }
                    }
                    let lastPayloadSize = rebuilt.withUnsafeBytes { readLittle($0.bindMemory(to: UInt8.self).baseAddress!.advanced(by: 4)) }
                    guard rebuilt[0] == 1, rebuilt[3] == 2,
                          lastPayloadSize == UInt32((frame.count + 7) % (config.packetSize - 16) + 1),
                          rebuilt.subdata(in: 8..<(8 + frame.count)) == frame else {
                        throw StreamError("Recovered video frame differs (\(size) bytes, loss case \(loss))")
                    }
                }
            }
            let oversized = Data(repeating: 0, count: 4 * 1023 * 1008 - 7)
            guard try packetizer.packetize(oversized, keyFrame: true, config: config, frameIndex: 4, timestamp: 90_000).isEmpty else {
                throw StreamError("Oversized video frame was not dropped")
            }
            let smallFrame = Data([0, 0, 0, 1, 0x41] + (0..<635).map { UInt8(truncatingIfNeeded: $0 * 29) })
            for size in [25, 127, 1023, 1408, 1409, 65_491] {
                config.packetSize = size
                let blocks = try packetizer.packetize(smallFrame, keyFrame: false, config: config, frameIndex: 5, timestamp: 0)
                var rebuilt = Data()
                for block in blocks {
                    guard block.size == size + 16, block.size <= 65_507 else { throw StreamError("Invalid video datagram size") }
                    let rs = try packetizer.codec(data: block.dataCount, parity: block.parityCount)
                    var pointers: [UnsafeMutablePointer<UInt8>?] = (0..<block.count).map { block.pointer($0) }
                    var marks = [UInt8](repeating: 0, count: block.count)
                    marks[0] = 1
                    block.pointer(0).initialize(repeating: 0, count: block.size)
                    guard reed_solomon_decode(rs, &pointers, &marks, Int32(block.count), Int32(block.size)) == 0 else {
                        throw StreamError("Video FEC recovery failed at packetSize \(size)")
                    }
                    for index in 0..<block.dataCount { rebuilt.append(block.pointer(index).advanced(by: 32), count: size - 16) }
                }
                guard rebuilt[3] == 1, rebuilt.subdata(in: 8..<(8 + smallFrame.count)) == smallFrame else {
                    throw StreamError("Video frame differs at packetSize \(size)")
                }
            }
            return []
        } catch { return [String(describing: error)] }
    }
}
