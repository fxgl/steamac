import Darwin
import Foundation

/// STEAMAC-S: footprint reached 59.7 GiB with stable Vulkan/shm/Metal totals. Numeric Mach
/// VM tags distinguish malloc, VM_ALLOCATE and driver mappings without recording addresses.
/// Called only by the serial memory-sampling timer; no additional thread or subprocess.
final class MemoryRegionDiagnostics {
    private var lastSample: TimeInterval?
    private var lastGrowthSample: TimeInterval?
    private var lastFootprint: UInt64?
    private var recent: [(time: TimeInterval, footprint: UInt64)] = []

    init() { recent.reserveCapacity(4) }

    static func shouldSample(footprint: UInt64, physical: UInt64, pressure: String,
                             now: TimeInterval, last: TimeInterval?) -> Bool {
        (footprint > physical || pressure == "warning" || pressure == "critical")
            && (last == nil || now - last! >= 60)
    }

    func sample(footprint: UInt64, hostPressure: String) -> String? {
        guard let reason = sampleReason(footprint: footprint, physical: ProcessInfo.processInfo.physicalMemory,
                                        pressure: hostPressure, now: ProcessInfo.processInfo.systemUptime) else { return nil }
        return reason + " " + Self.regions()
    }

    /// Four ten-second samples cover the preceding 30 seconds. A new physical-RAM crossing
    /// bypasses the periodic pressure gate; sustained rapid growth remains bounded to one
    /// breakdown a minute, not one expensive region walk per memory tick.
    func sampleReason(footprint: UInt64, physical: UInt64, pressure: String, now: TimeInterval) -> String? {
        recent.removeAll { now - $0.time > 30 || now < $0.time }
        let baseline = recent.reduce(footprint) { min($0, $1.footprint) }
        let growth = footprint - baseline
        let crossing = footprint > physical && (lastFootprint == nil || lastFootprint! <= physical)
        lastFootprint = footprint
        if recent.count == 4 { recent.removeFirst() }
        recent.append((now, footprint))
        let rapid = growth > 8 << 30
        guard crossing || Self.shouldSample(footprint: footprint, physical: physical, pressure: pressure,
                                            now: now, last: lastSample)
            || (rapid && (lastGrowthSample == nil || now - lastGrowthSample! >= 60)) else { return nil }
        lastSample = now
        if rapid { lastGrowthSample = now }
        return "vm-tags-trigger=\(crossing ? "physical-RAM-crossing" : rapid ? "rapid-growth" : "host-pressure/footprint") growth-30s-mib=\(growth >> 20)"
    }
    static func selfCheck() -> [String] {
        var failures: [String] = []
        if shouldSample(footprint: 16, physical: 16, pressure: "normal", now: 100, last: nil)
            || !shouldSample(footprint: 17, physical: 16, pressure: "normal", now: 100, last: nil)
            || shouldSample(footprint: 17, physical: 16, pressure: "normal", now: 159, last: 100)
            || !shouldSample(footprint: 17, physical: 16, pressure: "normal", now: 160, last: 100)
            || !shouldSample(footprint: 6, physical: 8, pressure: "warning", now: 100, last: nil)
            || !shouldSample(footprint: 31, physical: 36, pressure: "critical", now: 100, last: nil)
            || shouldSample(footprint: 6, physical: 8, pressure: "critical", now: 159, last: 100) {
            failures.append("memory-region threshold/rate gate")
        }
        let gib: UInt64 = 1 << 30
        let growth = MemoryRegionDiagnostics()
        if growth.sampleReason(footprint: 50 * gib, physical: 128 * gib, pressure: "normal", now: 0) != nil
            || growth.sampleReason(footprint: 55 * gib, physical: 128 * gib, pressure: "normal", now: 10) != nil
            || growth.sampleReason(footprint: 59 * gib, physical: 128 * gib, pressure: "normal", now: 20)?.contains("rapid-growth") != true
            || growth.sampleReason(footprint: 70 * gib, physical: 128 * gib, pressure: "normal", now: 30) != nil
            || growth.sampleReason(footprint: 75 * gib, physical: 128 * gib, pressure: "normal", now: 60) != nil
            || growth.sampleReason(footprint: 80 * gib, physical: 128 * gib, pressure: "normal", now: 70) != nil
            || growth.sampleReason(footprint: 95 * gib, physical: 128 * gib, pressure: "normal", now: 80)?.contains("rapid-growth") != true {
            failures.append("memory-region rapid-growth trigger/rate bound")
        }
        let crossing = MemoryRegionDiagnostics()
        if crossing.sampleReason(footprint: 7 * gib, physical: 8 * gib, pressure: "normal", now: 0) != nil
            || crossing.sampleReason(footprint: 9 * gib, physical: 8 * gib, pressure: "normal", now: 10)?.contains("physical-RAM-crossing") != true
            || crossing.sampleReason(footprint: 10 * gib, physical: 8 * gib, pressure: "normal", now: 20) != nil
            || crossing.sampleReason(footprint: 7 * gib, physical: 8 * gib, pressure: "normal", now: 30) != nil
            || crossing.sampleReason(footprint: 9 * gib, physical: 8 * gib, pressure: "normal", now: 40)?.contains("physical-RAM-crossing") != true {
            failures.append("memory-region physical crossing trigger/rearm")
        }
        let stale = MemoryRegionDiagnostics()
        if stale.sampleReason(footprint: gib, physical: 128 * gib, pressure: "normal", now: 0) != nil
            || stale.sampleReason(footprint: 10 * gib, physical: 128 * gib, pressure: "normal", now: 31) != nil {
            failures.append("memory-region growth must occur within 30 seconds")
        }
        let pressureThenGrowth = MemoryRegionDiagnostics()
        if pressureThenGrowth.sampleReason(footprint: gib, physical: 128 * gib, pressure: "warning", now: 0) == nil
            || pressureThenGrowth.sampleReason(footprint: 10 * gib, physical: 128 * gib, pressure: "normal", now: 10)?.contains("rapid-growth") != true {
            failures.append("memory-region new growth must not wait for the pressure rate gate")
        }
        var address: mach_vm_address_t = 0
        let size: mach_vm_size_t = 8 << 20
        // 240 is an application-specific VM tag, not an address or user identifier.
        guard mach_vm_allocate(mach_task_self_, &address, size, VM_FLAGS_ANYWHERE | Int32(bitPattern: 240 << 24)) == KERN_SUCCESS,
              let pointer = UnsafeMutableRawPointer(bitPattern: UInt(address)) else {
            return failures + ["memory-region test allocation failed"]
        }
        defer { mach_vm_deallocate(mach_task_self_, address, size) }
        memset(pointer, 1, Int(size))
        let result = regions()
        if !result.contains("240:8/") { failures.append("memory-region tagged resident allocation not found: \(result)") }
        if result.contains("0x") { failures.append("memory-region diagnostics contain addresses") }
        return failures
    }

    static func regions() -> String {
        struct Totals { var resident: UInt64 = 0; var swapped: UInt64 = 0 }
        var totals: [UInt32: Totals] = [:]
        var address: mach_vm_address_t = 0
        var depth: natural_t = 0
        var complete = false
        let page = UInt64(vm_kernel_page_size)
        for _ in 0..<8192 {
            var size: mach_vm_size_t = 0
            var info = vm_region_submap_info_data_64_t()
            var count = mach_msg_type_number_t(MemoryLayout<vm_region_submap_info_data_64_t>.size / MemoryLayout<integer_t>.size)
            let result = withUnsafeMutablePointer(to: &info) {
                $0.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
                    mach_vm_region_recurse(mach_task_self_, &address, &size, &depth, $0, &count)
                }
            }
            if result == KERN_INVALID_ADDRESS { complete = true; break }
            guard result == KERN_SUCCESS, size > 0 else { break }
            if info.is_submap != 0 { depth += 1; continue }
            var total = totals[info.user_tag, default: Totals()]
            total.resident += UInt64(info.pages_resident) * page
            total.swapped += UInt64(info.pages_swapped_out) * page
            totals[info.user_tag] = total
            guard address <= UInt64.max - size else { break }
            address += size
        }
        let largest = totals.sorted {
            let a = $0.value.resident + $0.value.swapped, b = $1.value.resident + $1.value.swapped
            return a == b ? $0.key < $1.key : a > b
        }.prefix(8).map { "\($0.key):\($0.value.resident >> 20)/\($0.value.swapped >> 20)" }
        return "vm-tags-resident/swapped=\(largest.joined(separator: ",")) vm-tags-complete=\(complete)"
    }
}
