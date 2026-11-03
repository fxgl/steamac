import Darwin
import Foundation

/// A point-in-time scheduler view, not a backtrace or proof of a GPU deadlock.
/// Captured only at a long GPU-idle stretch / missing-heartbeat report: totals alone
/// cannot tell a busy vCPU from a Venus ring waiting in the host driver (STEAMAC-8/7S).
enum StallThreadDiagnostics {
    static func selfCheck() -> String? {
        let ready = DispatchSemaphore(value: 0)
        let stop = DispatchSemaphore(value: 0)
        let done = DispatchSemaphore(value: 0)
        let worker = Thread {
            pthread_setname_np("vkr-stall-test")
            ready.signal()
            stop.wait()
            done.signal()
        }
        worker.start()
        guard ready.wait(timeout: .now() + 5) == .success else {
            stop.signal()
            return "diagnostic worker did not start"
        }
        let text = snapshot()
        stop.signal()
        guard done.wait(timeout: .now() + 5) == .success else {
            return "diagnostic worker did not stop"
        }
        guard text.contains("thread name=vkr-stall-test state="),
              text.contains("cpu-permille="), text.contains("time-ns=") else {
            return "named real thread missing from scheduler snapshot: \(text)"
        }
        guard text.split(separator: "\n").count <= 17 else {
            return "scheduler snapshot exceeded output bound"
        }
        return nil
    }

    static func snapshot() -> String {
        var threads: thread_act_array_t?
        var count: mach_msg_type_number_t = 0
        let result = task_threads(mach_task_self_, &threads, &count)
        guard result == KERN_SUCCESS, let threads else {
            return "Host thread snapshot: task-threads-error=\(result)"
        }
        defer {
            for i in 0..<Int(count) { mach_port_deallocate(mach_task_self_, threads[i]) }
            vm_deallocate(mach_task_self_, vm_address_t(UInt(bitPattern: threads)),
                          vm_size_t(Int(count) * MemoryLayout<thread_t>.stride))
        }
        struct Reading {
            let name: String
            let cpu: Int32
            let state: Int32
            let priority: Int32
            let time: UInt64
            var renderer: Bool {
                name.contains("vkr-") || name.contains("gpu worker") || name.contains("vcpu")
            }
        }
        var readings: [Reading] = []
        var failed = 0
        // Bound inspection as well as output; still release every port above.
        for i in 0..<min(Int(count), 512) {
            var info = thread_extended_info_data_t()
            var words = mach_msg_type_number_t(MemoryLayout.size(ofValue: info) / MemoryLayout<integer_t>.size)
            let status = withUnsafeMutablePointer(to: &info) {
                $0.withMemoryRebound(to: integer_t.self, capacity: Int(words)) {
                    thread_info(threads[i], thread_flavor_t(THREAD_EXTENDED_INFO), $0, &words)
                }
            }
            guard status == KERN_SUCCESS else { failed += 1; continue }
            let name = withUnsafeBytes(of: info.pth_name) { bytes in
                String(decoding: bytes.prefix { $0 != 0 }, as: UTF8.self)
            }.replacingOccurrences(of: "\n", with: " ")
            readings.append(Reading(name: name.isEmpty ? "unnamed" : name,
                                    cpu: info.pth_cpu_usage, state: info.pth_run_state,
                                    priority: info.pth_curpri,
                                    time: info.pth_user_time &+ info.pth_system_time))
        }
        readings.sort {
            if $0.renderer != $1.renderer { return $0.renderer }
            return $0.cpu > $1.cpu
        }
        let running = readings.filter { $0.state == TH_STATE_RUNNING }.count
        var lines = ["Host thread snapshot: total=\(count) inspected=\(readings.count) running=\(running) errors=\(failed); top 16 (renderer/vCPU first); CPU is scheduler estimate, time cumulative ns, not a stack"]
        for r in readings.prefix(16) {
            lines.append("thread name=\(r.name) state=\(r.state) cpu-permille=\(r.cpu) priority=\(r.priority) time-ns=\(r.time)")
        }
        return lines.joined(separator: "\n")
    }
}
