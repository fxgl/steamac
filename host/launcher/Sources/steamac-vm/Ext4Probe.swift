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
        /// `s_state`: bit 0 cleanly unmounted, bit 1 errors; resize2fs sets bit 1 until a resize is complete.
        var state: UInt16 = 0
        var totalBytes: UInt64 { blockSize * blockCount }
        var freeBytes: UInt64 { blockSize * freeBlocks }
        var usedBytes: UInt64 { totalBytes &- freeBytes }
        /// An interrupted resize2fs (or any error) leaves this bit set: the sizes are not final.
        var hasErrors: Bool { state & 0x2 != 0 }
    }

    /// The whole superblock: the 64-bit counts live at 0x150 and 0x158, past its first 256 bytes.
    static let superSize = 1024

    /// Superblock starts 1024 bytes into the filesystem; magic `0xEF53` at offset 0x38.
    static let superOffset: UInt64 = 1024
    static let magic: UInt16 = 0xEF53

    /// `partitionOffset` = home `firstLBA * 512` within `path`.
    static func read(path: String, partitionOffset: UInt64) throws -> Info {
        let fd = open(path, O_RDONLY)
        guard fd >= 0 else { throw OptionError("\(path): \(String(cString: strerror(errno)))") }
        defer { close(fd) }
        let sb = try GPT.preadAll(fd, superSize, at: partitionOffset + superOffset)
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
        return Info(blockSize: blockSize, blockCount: blockCount, freeBlocks: freeBlocks, state: u16(sb, 0x3A))
    }

    /// A synthetic superblock (self-checks): 4 KiB blocks unless `blockSizeShift` says otherwise.
    static func superblock(blocks: UInt64, free: UInt64, blockSizeShift: UInt32 = 2, state: UInt16 = 1,
                           is64Bit: Bool = false) -> [UInt8] {
        var sb = [UInt8](repeating: 0, count: superSize)
        put32(&sb, 0x04, UInt32(truncatingIfNeeded: blocks))       // s_blocks_count_lo
        put32(&sb, 0x0C, UInt32(truncatingIfNeeded: free))         // s_free_blocks_count_lo
        put32(&sb, 0x18, blockSizeShift)                           // s_log_block_size
        put16(&sb, 0x38, magic)
        put16(&sb, 0x3A, state)                                    // s_state
        if is64Bit {
            put32(&sb, 0x60, 0x80)                                 // INCOMPAT_64BIT
            put32(&sb, 0x150, UInt32(truncatingIfNeeded: blocks >> 32))
            put32(&sb, 0x158, UInt32(truncatingIfNeeded: free >> 32))
        }
        return sb
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
            func install(_ sb: [UInt8]) throws {
                img.replaceSubrange(Int(superOffset)..<Int(superOffset) + sb.count, with: sb)
                try Data(img).write(to: URL(fileURLWithPath: tmp))
            }
            try install(superblock(blocks: 256, free: 100))
            let info = try read(path: tmp, partitionOffset: 0)
            check(info.blockSize == 4096, "4 KiB blocks")
            check(info.blockCount == 256 && info.freeBlocks == 100, "block counts")
            check(info.usedBytes == 156 * 4096, "used bytes")
            check(!info.hasErrors, "a clean filesystem has no error state")
            // SteamOS home: ext4 with 64bit. The high halves live past the first 256 bytes.
            let big: UInt64 = (3 << 32) + 1000
            try install(superblock(blocks: big, free: (1 << 32) + 5, is64Bit: true))
            let wide = try read(path: tmp, partitionOffset: 0)
            check(wide.blockCount == big && wide.freeBlocks == (1 << 32) + 5, "64bit block counts include the high halves")
            check(wide.usedBytes == (big - (1 << 32) - 5) * 4096, "64bit used bytes")
            // Without 64bit the high halves are ignored even when the bytes are not zero.
            var narrow = superblock(blocks: 256, free: 100)
            put32(&narrow, 0x150, 7)
            try install(narrow)
            check(try read(path: tmp, partitionOffset: 0).blockCount == 256, "high halves ignored without 64bit")
            // resize2fs marks the filesystem with errors until a resize is complete.
            try install(superblock(blocks: 256, free: 100, state: 3))
            check(try read(path: tmp, partitionOffset: 0).hasErrors, "error state reported")
            // Wrong magic
            var bad = superblock(blocks: 256, free: 100)
            put16(&bad, 0x38, 0x1234)
            try install(bad)
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
