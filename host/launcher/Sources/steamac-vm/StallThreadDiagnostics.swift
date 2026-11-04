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
        // More idle renderer threads than output slots used to hide the
        // heartbeat/device worker completely (STEAMAC-8).
        let names = (0..<20).map { "vkr-stall-\($0)" } + ["vsock muxer"]
        for name in names {
            let worker = Thread {
                name.withCString { _ = pthread_setname_np($0) }
                ready.signal()
                stop.wait()
                done.signal()
            }
            worker.start()
        }
        defer {
            for _ in names { stop.signal() }
            for _ in names { _ = done.wait(timeout: .now() + 5) }
        }
        for _ in names {
            guard ready.wait(timeout: .now() + 5) == .success else {
                return "diagnostic worker did not start"
            }
        }
        let text = snapshot()
        guard text.contains("thread name=vsock muxer state="),
              text.contains("idle-renderer-waiting="),
              text.contains("cpu-permille="), text.contains("user-ns="),
              text.contains("system-ns="), text.contains("omitted-cpu-permille=") else {
            return "device worker missing behind idle renderer threads: \(text)"
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
        let reportingThread = pthread_mach_thread_np(pthread_self())
        struct Reading {
            let name: String
            let cpu: Int32
            let state: Int32
            let priority: Int32
            let userTime: UInt64
            let systemTime: UInt64
            let reporting: Bool
            var renderer: Bool {
                name.contains("vkr-") || name.contains("gpu worker")
            }
            var idleRenderer: Bool {
                renderer && state == TH_STATE_WAITING && cpu == 0
            }
            var priorityGroup: Int {
                if reporting { return 0 }
                switch name {
                case "block worker", "fs worker", "vsock muxer", "vmm worker", "virtio-net worker":
                    return 1
                default:
                    return name.contains("vcpu") ? 2 : 3
                }
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
                                    userTime: info.pth_user_time, systemTime: info.pth_system_time,
                                    reporting: threads[i] == reportingThread))
        }
        let idleRenderers = readings.filter(\.idleRenderer).count
        let relevant = readings.filter { !$0.idleRenderer }.sorted {
            if $0.priorityGroup != $1.priorityGroup { return $0.priorityGroup < $1.priorityGroup }
            return $0.cpu > $1.cpu
        }
        let shown = relevant.prefix(16)
        let shownCPU = shown.reduce(Int64(0)) { $0 + Int64($1.cpu) }
        let totalCPU = readings.reduce(Int64(0)) { $0 + Int64($1.cpu) }
        let running = readings.filter { $0.state == TH_STATE_RUNNING }.count
        var lines = ["Host thread snapshot: total=\(count) inspected=\(readings.count) running=\(running) errors=\(failed) idle-renderer-waiting=\(idleRenderers) omitted-cpu-permille=\(totalCPU - shownCPU); top 16 (reporting/device/vCPU first); CPU scheduler estimate, user/system cumulative ns, not a stack"]
        for r in shown {
            lines.append("thread name=\(r.name) state=\(r.state) cpu-permille=\(r.cpu) priority=\(r.priority) user-ns=\(r.userTime) system-ns=\(r.systemTime)")
        }
        return lines.joined(separator: "\n")
    }
}
