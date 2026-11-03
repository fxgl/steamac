import Darwin
import Foundation

/// STEAMAC-S: footprint reached 59.7 GiB with stable Vulkan/shm/Metal totals. Numeric Mach
/// VM tags distinguish malloc, VM_ALLOCATE and driver mappings without recording addresses.
/// Called only by the serial memory-sampling timer; no additional thread or subprocess.
final class MemoryRegionDiagnostics {
    private var lastSample: TimeInterval?

    static func shouldSample(footprint: UInt64, physical: UInt64, now: TimeInterval, last: TimeInterval?) -> Bool {
        footprint > physical && (last == nil || now - last! >= 60)
    }

    func sample(footprint: UInt64) -> String? {
        let now = ProcessInfo.processInfo.systemUptime
        guard Self.shouldSample(footprint: footprint, physical: ProcessInfo.processInfo.physicalMemory,
                                now: now, last: lastSample) else { return nil }
        lastSample = now
        return Self.regions()
    }
    static func selfCheck() -> [String] {
        var failures: [String] = []
        if shouldSample(footprint: 16, physical: 16, now: 100, last: nil)
            || !shouldSample(footprint: 17, physical: 16, now: 100, last: nil)
            || shouldSample(footprint: 17, physical: 16, now: 159, last: 100)
            || !shouldSample(footprint: 17, physical: 16, now: 160, last: 100) {
            failures.append("memory-region threshold/rate gate")
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
