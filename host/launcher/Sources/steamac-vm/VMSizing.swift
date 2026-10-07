import Foundation

/// VM size this Mac gets when the user has not chosen one (Settings > Advanced "Automatic"; a
/// saved custom value or --cpus / --mem wins). Apple silicon's GPU has no memory of its own:
/// MoltenVK's device memory is the Mac's RAM, so guest RAM taken from an 8 GB Mac is GPU memory a
/// game no longer gets (STEAMAC-G: a MacBook Air M1 with 8 GB ran a 16 GB VM and the game lost its
/// device with kIOGPUCommandBufferCallbackErrorOutOfMemory).
enum VMSizing {
    /// What the automatic sizes are computed from.
    struct Host: Equatable {
        /// Physical RAM, bytes (hw.memsize).
        var memBytes: UInt64
        /// Performance cores (hw.perflevel0.physicalcpu; nil when the sysctl is missing).
        var perfCores: Int?
        /// All cores (activeProcessorCount).
        var cores: Int

        static let current = Host(memBytes: ProcessInfo.processInfo.physicalMemory,
                                  perfCores: sysctlInt("hw.perflevel0.physicalcpu"),
                                  cores: ProcessInfo.processInfo.activeProcessorCount)

        var memGiB: Int { Int((memBytes + (1 << 29)) >> 30) }
        /// Cores a vCPU runs at full speed on.
        var fastCores: Int { perfCores ?? cores }
    }

    /// Where a boot's size came from.
    enum Source: String {
        case auto = "automatic", settings = "Settings", flag = "command line"
    }

    static let minAutoMemMiB = 4096, maxAutoMemMiB = 16384
    static let minAutoCPUs = 2, maxAutoCPUs = 8
    /// Custom memory above this share of the Mac's RAM gets a warning in Settings.
    static let memWarnShare = 0.6

    /// Three quarters of the Mac's RAM, rounded to whole GiB, 4...16 GiB:
    /// 8 GB Mac → 6 GiB, 16 → 12, 24 and up → 16. This gives games enough guest
    /// address space while retaining at least a quarter of RAM for macOS and the
    /// shared GPU (MoltenVK device memory, Metal heaps and virtio-gpu blobs).
    static func autoMemMiB(_ host: Host) -> Int {
        let hostMiB = host.memBytes >> 20
        let threeQuarterMiB = Int(hostMiB / 4 * 3)
        let rounded = (threeQuarterMiB + 512) / 1024 * 1024
        return min(maxAutoMemMiB, max(minAutoMemMiB, rounded))
    }

    /// One vCPU per performance core, 2...8: M1 / M2 / M3 / M4 (4 P) → 4, Pro chips → 6-8, Max → 8.
    /// The vCPU threads run at user-interactive QoS (libkrun patch 0013), so macOS keeps them on
    /// P-cores; more vCPUs than P-cores puts guest threads on efficiency cores (a fraction of the
    /// speed), where a lock holder or a FEX JIT thread stalls the vCPUs waiting for it. Past 8,
    /// Steam, Proton and FEX gain little, while the host's own frame-path threads (virglrenderer
    /// rings, MoltenVK pipeline compiles, the renderer) need cores too.
    static func autoCPUs(_ host: Host) -> Int {
        min(maxAutoCPUs, max(minAutoCPUs, host.fastCores))
    }

    /// Settings > Advanced: why a custom memory size is risky on this Mac, or nil.
    static func memWarning(memMiB: Int, host: Host) -> String? {
        guard Double(memMiB) > Double(host.memBytes >> 20) * memWarnShare else { return nil }
        return "More than 60% of this Mac's \(host.memGiB) GB. The Mac's GPU memory comes from the same RAM: "
            + "with too little left, games can lose their GPU device (out of memory) and macOS starts swapping."
    }

    /// Settings > Advanced: why a custom vCPU count is risky on this Mac, or nil.
    static func cpuWarning(cpus: Int, host: Host) -> String? {
        guard let p = host.perfCores, cpus > p else { return nil }
        return "More than this Mac's \(p) performance cores. The extra vCPUs run on efficiency cores, "
            + "which slows the guest down and leaves fewer cores for the Mac's GPU work."
    }

    /// Boot log: the size and where it came from.
    static func describe(cpus: Int, cpusSource: Source, memMiB: Int, memSource: Source, host: Host = .current) -> String {
        let cores = host.perfCores.map { "\($0) performance cores of \(host.cores)" } ?? "\(host.cores) cores"
        let cpuWhy = cpusSource == .auto ? "automatic: \(cores), \(minAutoCPUs)-\(maxAutoCPUs)" : cpusSource.rawValue
        let memWhy = memSource == .auto
            ? "automatic: 75% of \(host.memGiB) GB RAM, \(minAutoMemMiB / 1024)-\(maxAutoMemMiB / 1024) GB" : memSource.rawValue
        return "\(cpus) vCPUs (\(cpuWhy)), \(memMiB) MiB memory (\(memWhy))"
    }

    /// Settings self-test: the formulas on simulated Macs, and the warnings.
    static func selfCheck() -> [String] {
        let gib: UInt64 = 1 << 30
        var failures: [String] = []
        func host(_ gb: UInt64, _ p: Int?, _ cores: Int) -> Host { Host(memBytes: gb * gib, perfCores: p, cores: cores) }
        let mem: [(UInt64, Int)] = [(8, 6144), (16, 12288), (18, 14336), (24, 16384), (32, 16384), (36, 16384),
                                    (64, 16384), (128, 16384)]
        for (gb, want) in mem where autoMemMiB(host(gb, 4, 8)) != want {
            failures.append("sizing: \(gb) GB → \(autoMemMiB(host(gb, 4, 8))) MiB, want \(want)")
        }
        // (P, all cores, want): M1 4+4, M4 4+6, M2 Pro 6+4, M1 Pro 8+2, M3 Max 12+4 (14-core: 10+4), 1 P, no perflevel sysctl.
        let cpus: [(Int?, Int, Int)] = [(4, 8, 4), (4, 10, 4), (6, 10, 6), (8, 10, 8), (12, 16, 8), (10, 14, 8), (1, 4, 2),
                                        (nil, 8, 8), (nil, 1, 2)]
        for (p, n, want) in cpus where autoCPUs(host(16, p, n)) != want {
            failures.append("sizing: \(p.map(String.init) ?? "-")P/\(n) cores → \(autoCPUs(host(16, p, n))) vCPUs, want \(want)")
        }
        let air = host(8, 4, 8)
        if memWarning(memMiB: 4096, host: air) != nil { failures.append("sizing: 4 GB on an 8 GB Mac warned") }
        if memWarning(memMiB: 5120, host: air) == nil { failures.append("sizing: 5 GB on an 8 GB Mac not warned") }
        if memWarning(memMiB: 16384, host: host(36, 10, 14)) != nil { failures.append("sizing: 16 GB on a 36 GB Mac warned") }
        if cpuWarning(cpus: 4, host: air) != nil { failures.append("sizing: 4 vCPUs on 4 P-cores warned") }
        if cpuWarning(cpus: 8, host: air) == nil { failures.append("sizing: 8 vCPUs on 4 P-cores not warned") }
        let here = Host.current
        log("selftest-settings: sizing check: \(failures.isEmpty ? "ok" : failures.joined(separator: "; ")) "
            + "(this Mac: \(here.memGiB) GB, \(here.perfCores.map(String.init) ?? "?") P of \(here.cores) cores → "
            + "\(autoMemMiB(here)) MiB, \(autoCPUs(here)) vCPUs)")
        return failures
    }

    private static func sysctlInt(_ name: String) -> Int? {
        var value: Int32 = 0
        var size = MemoryLayout<Int32>.size
        return sysctlbyname(name, &value, &size, nil, 0) == 0 && value > 0 ? Int(value) : nil
    }
}
