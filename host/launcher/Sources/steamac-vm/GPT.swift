import Darwin
import Foundation

/// The SteamOS disk layout of scripts/steps/40-disk.sh (sizes from scripts/config.env):
/// Valve's partition names, order and type GUIDs, 1 MiB alignment, 1 MiB in front (GPT) and
/// 1 MiB behind home (backup GPT), so systemd-repart can grow home when the image is enlarged.
enum DiskLayout {
    struct Part {
        let name: String
        let type: UUID
        let sizeMiB: UInt64
    }

    static let typeESP = UUID(uuidString: "C12A7328-F81F-11D2-BA4B-00A0C93EC93B")!
    static let typeEFI = UUID(uuidString: "EBD0A0A2-B9E5-4433-87C0-68B6B72699C7")!
    static let typeRoot = UUID(uuidString: "4F68BCE3-E8CD-4DB1-96E7-FBCAF984B709")!
    static let typeVar = UUID(uuidString: "4D21B016-B534-45C2-A9FB-5C16E091FD2D")!
    static let typeHome = UUID(uuidString: "933AC7E1-2EB4-4F13-B844-0E14E2AEF915")!

    /// PART_SIZE_* of scripts/config.env (MiB).
    static let espMiB: UInt64 = 256, efiMiB: UInt64 = 64, rootMiB: UInt64 = 10240, varMiB: UInt64 = 1024
    static let defaultHomeGiB = 64
    static let mib: UInt64 = 1 << 20
    static let sector: UInt64 = 512

    static func parts(homeGiB: Int) -> [Part] {
        [Part(name: "esp", type: typeESP, sizeMiB: espMiB),
         Part(name: "efi-A", type: typeEFI, sizeMiB: efiMiB),
         Part(name: "efi-B", type: typeEFI, sizeMiB: efiMiB),
         Part(name: "rootfs-A", type: typeRoot, sizeMiB: rootMiB),
         Part(name: "rootfs-B", type: typeRoot, sizeMiB: rootMiB),
         Part(name: "var-A", type: typeVar, sizeMiB: varMiB),
         Part(name: "var-B", type: typeVar, sizeMiB: varMiB),
         Part(name: "home", type: typeHome, sizeMiB: UInt64(homeGiB) * 1024)]
    }

    /// Partition table for a new disk: random disk GUID and PARTUUIDs (sgdisk -a 2048 placement).
    static func table(homeGiB: Int) -> GPT {
        let ps = parts(homeGiB: homeGiB)
        let totalMiB = 1 + ps.reduce(0) { $0 + $1.sizeMiB } + 1
        var lba = mib / sector
        var entries: [GPT.Entry] = []
        for p in ps {
            let n = p.sizeMiB * mib / sector
            entries.append(GPT.Entry(type: p.type, uuid: UUID(), firstLBA: lba, lastLBA: lba + n - 1, attributes: 0, name: p.name))
            lba += n
        }
        return GPT(diskGUID: UUID(), sectors: totalMiB * mib / sector, entries: entries)
    }
}

/// GUID partition table with a protective MBR (UEFI 2.x; 128 entries of 128 bytes, primary at
/// LBA 1-33, backup at the last 33 sectors), byte layout as sgdisk writes it.
struct GPT: Equatable {
    struct Entry: Equatable {
        var type: UUID
        var uuid: UUID
        var firstLBA: UInt64
        var lastLBA: UInt64
        var attributes: UInt64
        var name: String
        var sectors: UInt64 { lastLBA - firstLBA + 1 }
    }

    var diskGUID: UUID
    var sectors: UInt64
    var entries: [Entry]

    static let entryCount = 128, entrySize = 128
    static let entryArraySectors = UInt64(entryCount * entrySize) / 512   // 32
    var firstUsableLBA: UInt64 { 2 + GPT.entryArraySectors }
    var lastUsableLBA: UInt64 { sectors - 2 - GPT.entryArraySectors }

    func entry(_ name: String) -> Entry? { entries.first { $0.name == name } }

    // MARK: encode

    /// LBA 0-33 (protective MBR, primary header, entry array).
    func primaryBytes() -> [UInt8] {
        var out = [UInt8](repeating: 0, count: 512)
        // Protective MBR: one 0xEE partition from LBA 1 over the whole disk (capped at 32 bits).
        out[446 + 1] = 0x00; out[446 + 2] = 0x02; out[446 + 3] = 0x00   // CHS start 0/0/2
        out[446 + 4] = 0xEE
        out[446 + 5] = 0xFF; out[446 + 6] = 0xFF; out[446 + 7] = 0xFF
        GPT.put32(&out, 446 + 8, 1)
        GPT.put32(&out, 446 + 12, UInt32(min(sectors - 1, 0xFFFF_FFFF)))
        out[510] = 0x55; out[511] = 0xAA
        let array = entryArray()
        out += header(myLBA: 1, alternateLBA: sectors - 1, entriesLBA: 2, arrayCRC: GPT.crc32(array))
        out += array
        return out
    }

    /// The last 33 sectors (backup entry array, then the backup header in the last sector).
    func backupBytes() -> [UInt8] {
        let array = entryArray()
        return array + header(myLBA: sectors - 1, alternateLBA: 1, entriesLBA: sectors - 1 - GPT.entryArraySectors,
                              arrayCRC: GPT.crc32(array))
    }

    private func entryArray() -> [UInt8] {
        var a = [UInt8](repeating: 0, count: GPT.entryCount * GPT.entrySize)
        for (i, e) in entries.enumerated() {
            let o = i * GPT.entrySize
            GPT.putGUID(&a, o, e.type)
            GPT.putGUID(&a, o + 16, e.uuid)
            GPT.put64(&a, o + 32, e.firstLBA)
            GPT.put64(&a, o + 40, e.lastLBA)
            GPT.put64(&a, o + 48, e.attributes)
            for (j, u) in e.name.utf16.prefix(36).enumerated() {
                a[o + 56 + 2 * j] = UInt8(u & 0xff)
                a[o + 57 + 2 * j] = UInt8(u >> 8)
            }
        }
        return a
    }

    private func header(myLBA: UInt64, alternateLBA: UInt64, entriesLBA: UInt64, arrayCRC: UInt32) -> [UInt8] {
        var h = [UInt8](repeating: 0, count: 512)
        h.replaceSubrange(0..<8, with: Array("EFI PART".utf8))
        GPT.put32(&h, 8, 0x0001_0000)
        GPT.put32(&h, 12, 92)
        GPT.put64(&h, 24, myLBA)
        GPT.put64(&h, 32, alternateLBA)
        GPT.put64(&h, 40, firstUsableLBA)
        GPT.put64(&h, 48, lastUsableLBA)
        GPT.putGUID(&h, 56, diskGUID)
        GPT.put64(&h, 72, entriesLBA)
        GPT.put32(&h, 80, UInt32(GPT.entryCount))
        GPT.put32(&h, 84, UInt32(GPT.entrySize))
        GPT.put32(&h, 88, arrayCRC)
        GPT.put32(&h, 16, GPT.crc32(h[0..<92]))
        return h
    }

    /// Write MBR + both tables into an open (sized) disk image.
    func write(fd: Int32) throws {
        try GPT.pwriteAll(fd, primaryBytes(), at: 0)
        try GPT.pwriteAll(fd, backupBytes(), at: (sectors - 1 - GPT.entryArraySectors) * 512)
    }

    // MARK: decode

    /// Read and validate the table of a disk image (protective MBR, primary + backup header and
    /// entry CRCs, backup = primary). Never writes.
    static func read(path: String, allowAlignedUsableRange: Bool = false) throws -> GPT {
        let fd = open(path, O_RDONLY)
        guard fd >= 0 else { throw OptionError("\(path): \(String(cString: strerror(errno)))") }
        defer { close(fd) }
        var st = stat()
        guard fstat(fd, &st) == 0, st.st_size >= 68 * 512 else { throw OptionError("\(path): too small for a GPT") }
        let sectors = UInt64(st.st_size) / 512
        let head = try preadAll(fd, 34 * 512, at: 0)
        guard head[510] == 0x55, head[511] == 0xAA, head[446 + 4] == 0xEE else { throw OptionError("\(path): no protective MBR") }
        let primary = try parse(header: Array(head[512..<1024]), array: Array(head[1024...]), myLBA: 1, sectors: sectors, allowAlignedUsableRange: allowAlignedUsableRange)
        let tail = try preadAll(fd, 33 * 512, at: (sectors - 33) * 512)
        let backup = try parse(header: Array(tail[(32 * 512)...]), array: Array(tail[0..<(32 * 512)]), myLBA: sectors - 1, sectors: sectors, allowAlignedUsableRange: allowAlignedUsableRange)
        guard get64(head, 512 + 40) == get64(tail, 32 * 512 + 40),
              get64(head, 512 + 48) == get64(tail, 32 * 512 + 48) else {
            throw OptionError("GPT backup usable range differs")
        }
        guard backup == primary else { throw OptionError("\(path): backup GPT differs from the primary") }
        return primary
    }

    private static func parse(header h: [UInt8], array a: [UInt8], myLBA: UInt64, sectors: UInt64, allowAlignedUsableRange: Bool) throws -> GPT {
        guard Array(h[0..<8]) == Array("EFI PART".utf8), get32(h, 12) == 92 else { throw OptionError("GPT header signature") }
        var z = Array(h[0..<92])
        z[16] = 0; z[17] = 0; z[18] = 0; z[19] = 0
        guard crc32(z[0..<92]) == get32(h, 16) else { throw OptionError("GPT header CRC (LBA \(myLBA))") }
        guard get64(h, 24) == myLBA, get64(h, 32) == (myLBA == 1 ? sectors - 1 : 1) else { throw OptionError("GPT header LBAs") }
        guard get32(h, 80) == UInt32(entryCount), get32(h, 84) == UInt32(entrySize) else { throw OptionError("GPT entry geometry") }
        guard crc32(a[0..<(entryCount * entrySize)]) == get32(h, 88) else { throw OptionError("GPT entry array CRC") }
        var g = GPT(diskGUID: getGUID(h, 56), sectors: sectors, entries: [])
        let first = get64(h, 40), last = get64(h, 48)
        guard first >= g.firstUsableLBA, last <= g.lastUsableLBA, first <= last,
              allowAlignedUsableRange || (first == g.firstUsableLBA && last == g.lastUsableLBA),
              get64(h, 72) == (myLBA == 1 ? 2 : sectors - 33) else { throw OptionError("GPT usable range") }
        for i in 0..<entryCount {
            let o = i * entrySize
            let type = getGUID(a, o)
            if type == UUID(uuid: (0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0)) { continue }
            var units: [UInt16] = []
            for j in 0..<36 {
                let u = UInt16(a[o + 56 + 2 * j]) | UInt16(a[o + 57 + 2 * j]) << 8
                if u == 0 { break }
                units.append(u)
            }
            g.entries.append(Entry(type: type, uuid: getGUID(a, o + 16), firstLBA: get64(a, o + 32), lastLBA: get64(a, o + 40),
                                   attributes: get64(a, o + 48), name: String(decoding: units, as: UTF16.self)))
        }
        var end = first - 1
        for entry in g.entries.sorted(by: { $0.firstLBA < $1.firstLBA }) {
            guard entry.firstLBA >= first, entry.lastLBA <= last,
                  entry.firstLBA <= entry.lastLBA, entry.firstLBA > end else {
                throw OptionError("GPT partition range")
            }
            end = entry.lastLBA
        }
        return g
    }

    // MARK: helpers

    /// `sgdisk -p`-style dump (sizes in MiB).
    func dump() -> String {
        var s = "Disk: \(sectors) sectors (\(sectors / 2048) MiB), GUID \(diskGUID.uuidString)\n"
        s += "Usable LBAs \(firstUsableLBA)-\(lastUsableLBA)\n"
        s += "Number  Start (sector)    End (sector)  Size (MiB)  Type GUID                             Name\n"
        for (i, e) in entries.enumerated() {
            s += String(format: "%4d  %14llu  %14llu  %10llu  ", i + 1, e.firstLBA, e.lastLBA, e.sectors / 2048)
                + e.type.uuidString + "  " + e.name + "\n"
        }
        return s
    }

    static func crc32<C: Collection>(_ bytes: C) -> UInt32 where C.Element == UInt8 {
        var c: UInt32 = 0xFFFF_FFFF
        for b in bytes { c = crcTable[Int((c ^ UInt32(b)) & 0xff)] ^ (c >> 8) }
        return c ^ 0xFFFF_FFFF
    }

    private static let crcTable: [UInt32] = (0..<256).map { n -> UInt32 in
        var c = UInt32(n)
        for _ in 0..<8 { c = c & 1 != 0 ? 0xEDB8_8320 ^ (c >> 1) : c >> 1 }
        return c
    }

    static func put32(_ a: inout [UInt8], _ o: Int, _ v: UInt32) { for i in 0..<4 { a[o + i] = UInt8(truncatingIfNeeded: v >> (8 * i)) } }
    static func put64(_ a: inout [UInt8], _ o: Int, _ v: UInt64) { for i in 0..<8 { a[o + i] = UInt8(truncatingIfNeeded: v >> (8 * i)) } }
    static func get32(_ a: [UInt8], _ o: Int) -> UInt32 { (0..<4).reduce(0) { $0 | UInt32(a[o + $1]) << (8 * $1) } }
    static func get64(_ a: [UInt8], _ o: Int) -> UInt64 { (0..<8).reduce(0) { $0 | UInt64(a[o + $1]) << (8 * $1) } }

    /// GUIDs are stored mixed-endian: the first three fields little-endian.
    static func putGUID(_ a: inout [UInt8], _ o: Int, _ u: UUID) {
        let b = withUnsafeBytes(of: u.uuid) { Array($0) }
        let order = [3, 2, 1, 0, 5, 4, 7, 6, 8, 9, 10, 11, 12, 13, 14, 15]
        for i in 0..<16 { a[o + i] = b[order[i]] }
    }

    static func getGUID(_ a: [UInt8], _ o: Int) -> UUID {
        let order = [3, 2, 1, 0, 5, 4, 7, 6, 8, 9, 10, 11, 12, 13, 14, 15]
        var b = [UInt8](repeating: 0, count: 16)
        for i in 0..<16 { b[order[i]] = a[o + i] }
        return UUID(uuid: (b[0], b[1], b[2], b[3], b[4], b[5], b[6], b[7], b[8], b[9], b[10], b[11], b[12], b[13], b[14], b[15]))
    }

    static func pwriteAll(_ fd: Int32, _ bytes: [UInt8], at offset: UInt64) throws {
        try bytes.withUnsafeBytes { try pwriteAll(fd, $0, at: offset) }
    }

    static func pwriteAll(_ fd: Int32, _ buf: UnsafeRawBufferPointer, at offset: UInt64) throws {
        var done = 0
        while done < buf.count {
            let n = pwrite(fd, buf.baseAddress! + done, buf.count - done, off_t(offset) + off_t(done))
            if n < 0 {
                if errno == EINTR { continue }
                throw OptionError("write: \(String(cString: strerror(errno)))")
            }
            done += n
        }
    }

    static func preadAll(_ fd: Int32, _ count: Int, at offset: UInt64) throws -> [UInt8] {
        var out = [UInt8](repeating: 0, count: count)
        var done = 0
        while done < count {
            let n = out.withUnsafeMutableBytes { pread(fd, $0.baseAddress! + done, count - done, off_t(offset) + off_t(done)) }
            if n < 0 {
                if errno == EINTR { continue }
                throw OptionError("read: \(String(cString: strerror(errno)))")
            }
            if n == 0 { throw OptionError("read: unexpected end of file at \(offset + UInt64(done))") }
            done += n
        }
        return out
    }
}
