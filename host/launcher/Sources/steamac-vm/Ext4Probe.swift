import Darwin
import Foundation

/// Read-only probe of an unmounted ext4 filesystem inside a raw disk image (SteamOS `home`).
/// Used to refuse Shrink Disk when used data would not fit the target capacity — without
/// mounting the volume on macOS.
enum Ext4Probe {
    struct Info: Equatable {
        let blockSize: UInt64
        let blockCount: UInt64
        let freeBlocks: UInt64
        var totalBytes: UInt64 { blockSize * blockCount }
        var freeBytes: UInt64 { blockSize * freeBlocks }
        var usedBytes: UInt64 { totalBytes &- freeBytes }
    }

    /// Superblock starts 1024 bytes into the filesystem; magic `0xEF53` at offset 0x38.
    static let superOffset: UInt64 = 1024
    static let magic: UInt16 = 0xEF53

    /// `partitionOffset` = home `firstLBA * 512` within `path`.
    static func read(path: String, partitionOffset: UInt64) throws -> Info {
        let fd = open(path, O_RDONLY)
        guard fd >= 0 else { throw OptionError("\(path): \(String(cString: strerror(errno)))") }
        defer { close(fd) }
        let sb = try GPT.preadAll(fd, 256, at: partitionOffset + superOffset)
        let magic = u16(sb, 0x38)
        guard magic == Ext4Probe.magic else {
            throw OptionError("\(path): home is not an ext4 filesystem (magic 0x\(String(magic, radix: 16)))",
                              localized: String(localized: "\(path): home is not an ext4 filesystem"))
        }
        let logBlockSize = u32(sb, 0x18)
        guard logBlockSize <= 6 else {
            throw OptionError("\(path): unsupported ext4 block size shift \(logBlockSize)")
        }
        let blockSize = UInt64(1024) << logBlockSize
        let featureIncompat = u32(sb, 0x60)
        let blocks64 = (featureIncompat & 0x80) != 0  // EXT4_FEATURE_INCOMPAT_64BIT
        let blockCount = UInt64(u32(sb, 0x04)) | (blocks64 ? UInt64(u32(sb, 0x150)) << 32 : 0)
        let freeBlocks = UInt64(u32(sb, 0x0C)) | (blocks64 ? UInt64(u32(sb, 0x158)) << 32 : 0)
        guard blockCount > 0, freeBlocks <= blockCount else {
            throw OptionError("\(path): invalid ext4 block counts (total \(blockCount), free \(freeBlocks))")
        }
        return Info(blockSize: blockSize, blockCount: blockCount, freeBlocks: freeBlocks)
    }

    /// Host-side self-check with a synthetic superblock buffer written into a temp file.
    static func selfCheck() -> [String] {
        var failures: [String] = []
        var checks = 0
        func check(_ ok: Bool, _ name: String) {
            checks += 1
            if !ok { failures.append("ext4 probe: \(name)") }
        }
        let tmp = NSTemporaryDirectory() + "steamac-ext4-probe-\(getpid()).img"
        defer { try? FileManager.default.removeItem(atPath: tmp) }
        do {
            // 2 MiB file; filesystem at LBA 0. Block size 4 KiB, 256 blocks, 100 free → used 156*4096.
            var img = [UInt8](repeating: 0, count: 2 << 20)
            var sb = [UInt8](repeating: 0, count: 256)
            put32(&sb, 0x04, 256)       // s_blocks_count_lo
            put32(&sb, 0x0C, 100)       // s_free_blocks_count_lo
            put32(&sb, 0x18, 2)         // s_log_block_size → 4096
            put16(&sb, 0x38, magic)
            img.replaceSubrange(Int(superOffset)..<Int(superOffset) + sb.count, with: sb)
            try Data(img).write(to: URL(fileURLWithPath: tmp))
            let info = try read(path: tmp, partitionOffset: 0)
            check(info.blockSize == 4096, "4 KiB blocks")
            check(info.blockCount == 256 && info.freeBlocks == 100, "block counts")
            check(info.usedBytes == 156 * 4096, "used bytes")
            // Wrong magic
            put16(&sb, 0x38, 0x1234)
            img.replaceSubrange(Int(superOffset)..<Int(superOffset) + sb.count, with: sb)
            try Data(img).write(to: URL(fileURLWithPath: tmp))
            var rejected = false
            do { _ = try read(path: tmp, partitionOffset: 0) } catch { rejected = true }
            check(rejected, "rejects non-ext4 magic")
        } catch {
            failures.append("ext4 probe: \(error)")
        }
        log("selftest-settings: ext4 probe: \(checks) checks, \(failures.isEmpty ? "PASS" : failures.joined(separator: "; "))")
        return failures
    }

    private static func u16(_ a: [UInt8], _ o: Int) -> UInt16 {
        UInt16(a[o]) | UInt16(a[o + 1]) << 8
    }
    private static func u32(_ a: [UInt8], _ o: Int) -> UInt32 {
        (0..<4).reduce(UInt32(0)) { $0 | UInt32(a[o + Int($1)]) << (8 * $1) }
    }
    private static func put16(_ a: inout [UInt8], _ o: Int, _ v: UInt16) {
        a[o] = UInt8(truncatingIfNeeded: v); a[o + 1] = UInt8(truncatingIfNeeded: v >> 8)
    }
    private static func put32(_ a: inout [UInt8], _ o: Int, _ v: UInt32) {
        for i in 0..<4 { a[o + i] = UInt8(truncatingIfNeeded: v >> (8 * i)) }
    }
}
