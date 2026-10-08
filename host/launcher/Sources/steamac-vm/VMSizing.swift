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
    /// macOS, the launcher, driver-internal allocations and other apps need room besides
    /// guest RAM and Vulkan heaps. Keep at least 3 GiB, or a quarter of a larger Mac.
    static func hostReserveMiB(_ host: Host) -> Int {
        max(3072, Int(host.memBytes >> 22))
    }

    /// Shared by both host Vulkan drivers and the guest's VRAM reporting layer. This is
    /// an advertised working-set budget, not an allocation cap: Venus allocations are
    /// asynchronous, so rejecting them here would kill the guest context, not return OOM.
    static func gpuBudgetMiB(memMiB: Int, host: Host = .current) -> Int {
        let remaining = Int(host.memBytes >> 20) - memMiB - hostReserveMiB(host)
        return min(16384, max(256, remaining / 256 * 256))
    }

    /// Half the Mac's RAM, rounded to whole GiB, 4...16 GiB: 8 GB Mac → 4 GiB, 16 → 8, 32 and up → 16.
    /// The other half stays with macOS and the GPU (MoltenVK device memory, Metal heaps, the
    /// virtio-gpu blobs the guest maps).
    static func autoMemMiB(_ host: Host) -> Int {
        let halfMiB = Int(host.memBytes >> 21)
        let rounded = (halfMiB + 512) / 1024 * 1024
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
        let gpu = gpuBudgetMiB(memMiB: memMiB, host: host)
        let reserve = hostReserveMiB(host)
        guard memMiB + gpu + reserve > Int(host.memBytes >> 20) || gpu < 2048 else { return nil }
        return tr("%@ MiB VM RAM + %@ MiB GPU budget + %@ MiB reserved for macOS on this %@ GB Mac. Too little GPU memory remains: lower VM memory or graphics settings to avoid swapping, out-of-memory errors or the VM being killed.", "\(memMiB)", "\(gpu)", "\(reserve)", "\(host.memGiB)")
    }

    /// Settings > Advanced: why a custom vCPU count is risky on this Mac, or nil.
    static func cpuWarning(cpus: Int, host: Host) -> String? {
        guard let p = host.perfCores, cpus > p else { return nil }
        return tr("More than this Mac's %@ performance cores. The extra vCPUs run on efficiency cores, "
            + "which slows the guest down and leaves fewer cores for the Mac's GPU work.", "\(p)")
    }

    /// Boot log: the size and where it came from.
    static func describe(cpus: Int, cpusSource: Source, memMiB: Int, memSource: Source,
                         gpuMiB: Int? = nil, host: Host = .current) -> String {
        let cores = host.perfCores.map { "\($0) performance cores of \(host.cores)" } ?? "\(host.cores) cores"
        let cpuWhy = cpusSource == .auto ? "automatic: \(cores), \(minAutoCPUs)-\(maxAutoCPUs)" : cpusSource.rawValue
        let memWhy = memSource == .auto
            ? "automatic: half of \(host.memGiB) GB RAM, \(minAutoMemMiB / 1024)-\(maxAutoMemMiB / 1024) GB" : memSource.rawValue
        return "\(cpus) vCPUs (\(cpuWhy)), \(memMiB) MiB memory (\(memWhy)), "
            + "\(gpuMiB ?? gpuBudgetMiB(memMiB: memMiB, host: host)) MiB GPU budget, \(hostReserveMiB(host)) MiB host reserve"
    }

    /// Settings self-test: the formulas on simulated Macs, and the warnings.
    static func selfCheck() -> [String] {
        let gib: UInt64 = 1 << 30
        var failures: [String] = []
        func host(_ gb: UInt64, _ p: Int?, _ cores: Int) -> Host { Host(memBytes: gb * gib, perfCores: p, cores: cores) }
        let mem: [(UInt64, Int)] = [(8, 4096), (16, 8192), (18, 9216), (24, 12288), (32, 16384), (36, 16384),
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
        if memWarning(memMiB: 4096, host: air) == nil { failures.append("sizing: 1 GiB GPU budget on an 8 GB Mac not warned") }
        if memWarning(memMiB: 5120, host: air) == nil { failures.append("sizing: 5 GB on an 8 GB Mac not warned") }
        if memWarning(memMiB: 16384, host: host(36, 10, 14)) != nil { failures.append("sizing: 16 GB on a 36 GB Mac warned") }
        let budgets: [(UInt64, Int, Int)] = [(8, 4096, 1024), (16, 8192, 4096), (16, 9216, 3072),
                                            (16, 12288, 256), (32, 16384, 8192), (64, 16384, 16384),
                                            (8, 16384, 256)]
        for (gb, vm, want) in budgets where gpuBudgetMiB(memMiB: vm, host: host(gb, 4, 8)) != want {
            failures.append("sizing: GPU budget \(gb) GB / \(vm) MiB VM, want \(want)")
        }
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
