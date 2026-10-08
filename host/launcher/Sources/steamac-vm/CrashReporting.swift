import Combine
import Darwin
import Foundation
import MachO
import Metal
import Sentry
import Security
import SystemConfiguration

/// Crash and error reporting through Sentry (self-hosted, sentry.fxgam.es). Opt-out: Settings >
/// General "Send crash reports and diagnostics" (`sendCrashReports`, on by default, also shown by
/// the first-run alert and the Create SteamOS Disk sheet); `--no-crash-reports` or
/// `STEAMAC_SENTRY=0` turn it off for one run. Off = the SDK is never started (no network).
///
/// Both processes report: the supervisor (launcher role) and every VM process (vm role; native
/// crashes there come from Metal/MoltenVK asserts, libkrun/virglrenderer aborts and panics that
/// cross libkrun's C API). Each role has its own SDK cache, so a VM-process crash is uploaded
/// when the next VM process starts. The supervisor routes stderr through a pipe (StderrTap): every
/// line of both processes (launcher log, MoltenVK, libkrun/virglrenderer) reaches the terminal or
/// log file unchanged and also becomes a scrubbed breadcrumb, and the few error patterns worth a
/// report (guest GPU context fatal, pipeline compile failures, Rust panics) are recognised there.
/// Volume is kept low: one event per fingerprint per process, a small per-kind and total budget,
/// and a persistent "already reported" list per fingerprint.
enum CrashReporting {
    static let dsn = "https://2af7807225b4fc150d9436d1f16165b8@sentry.fxgam.es/39"
    static let disableEnv = "STEAMAC_SENTRY"
    static let debugEnv = "STEAMAC_SENTRY_DEBUG"
    static let runIdEnv = "STEAMAC_RUN_ID"
    static let noFlag = "--no-crash-reports"

    /// Settings / first-run explanation (one line) and the "What is sent" list.
    static let summary = String(localized: "Crash reports and rare errors go to the FX Steam Launcher developers (Sentry). No personal data.")
    static let whatIsSent = [
        String(localized: "Crash reports of the launcher and the VM process: crash reason, stack traces, loaded libraries."),
        String(localized: "A few errors: guest GPU context lost, shader pipeline compile failures (with an excerpt of the failing Metal shader source), libkrun panics, failed disk creation or first-start setup, VM stopped unexpectedly or killed (with the Mac's memory use), SteamOS not responding."),
        String(localized: "The launcher's last ~200 log lines (launcher, MoltenVK, libkrun and virglrenderer messages; home folder paths shortened to ~) and the boot stages."),
        String(localized: "Versions and setup: app, macOS, libkrun/virglrenderer/MoltenVK builds, kernel, SteamOS build, Mac model, GPU, VM CPUs/RAM/display mode, game App IDs."),
        String(localized: "A random install ID (not linked to you) to count affected Macs."),
        String(localized: "Never: your name, user or computer name, IP address, Steam account, game titles, files, or the SteamOS console."),
    ]

    enum Role: String { case launcher, vm }

    enum Kind: String {
        case gpuContextFatal = "gpu-context-fatal"
        case pipelineCompile = "pipeline-compile-failed"
        case rustPanic = "rust-panic"
        case provisionFailed = "provision-failed"
        case diskCreationFailed = "disk-creation-failed"
        case vmExited = "vm-exited-unexpectedly"
        case vmKilled = "vm-killed"
        case notResponding = "steamos-not-responding"
        case test = "test-event"

        var title: String {
            switch self {
            case .gpuContextFatal: return "Guest GPU context fatal"
            case .pipelineCompile: return "Pipeline compile failed"
            case .rustPanic: return "Rust panic"
            case .provisionFailed: return "SteamOS first-start setup failed"
            case .diskCreationFailed: return "Disk creation failed"
            case .vmExited: return "VM exited unexpectedly"
            case .vmKilled: return "VM process killed"
            case .notResponding: return "SteamOS not responding"
            case .test: return "Sentry test event"
            }
        }

        /// The same fingerprint is reported again only after this long (persistent list).
        var quietPeriod: TimeInterval {
            switch self {
            case .pipelineCompile: return 30 * 86400   // first occurrence per shader message
            case .test: return 0
            default: return 86400
            }
        }

        /// Reports of this kind per process.
        var budget: Int {
            switch self {
            case .gpuContextFatal, .vmExited, .vmKilled, .notResponding, .provisionFailed, .diskCreationFailed: return 2
            default: return 5
            }
        }
    }

    // MARK: state

    private static let lock = NSLock()
    nonisolated(unsafe) private static var role = Role.launcher
    nonisolated(unsafe) private static var configured = false
    nonisolated(unsafe) private(set) static var running = false
    /// Why this run is off regardless of the setting (`--no-crash-reports`, STEAMAC_SENTRY=0).
    nonisolated(unsafe) private static var runOverride: String?
    nonisolated(unsafe) private static var test = false
    nonisolated(unsafe) private static var tags: [String: String] = [:]
    nonisolated(unsafe) private static var reportedThisProcess: Set<String> = []
    nonisolated(unsafe) private static var kindCounts: [Kind: Int] = [:]
    nonisolated(unsafe) private static var settingsSubscription: AnyCancellable?
    nonisolated(unsafe) private static var tap: StderrTap?
    /// Supervisor: run dir of the current boot (VM-process tags, user-exit marker).
    nonisolated(unsafe) private static var runDir: String?
    nonisolated(unsafe) private static var lineScanner = LineScanner()
    /// The open multi-line message a delayed report was scheduled for (LineScanner.pendingSerial).
    nonisolated(unsafe) private static var scheduledSerial: Int?
    /// Most recent event this process sent (Report a Problem associates its feedback with it).
    nonisolated(unsafe) private static var lastEvent: String?
    /// Supervisor: host memory pressure while the VM runs.
    private static let memoryWatch = MemoryWatch()

    private static func locked<T>(_ body: () -> T) -> T {
        lock.lock()
        defer { lock.unlock() }
        return body()
    }

    static var releaseName: String {
        let info = Bundle.main.infoDictionary ?? [:]
        let version = info["CFBundleShortVersionString"] as? String ?? "0"
        let commit = info["SteamacGitCommit"] as? String ?? "unknown"
        return "\(LauncherSettings.defaultDomain)@\(version)+\(commit)"
    }

    /// What kind of build this is (tag `build_kind`; the environment unless this is a test run).
    enum BuildKind: String {
        /// dist.sh: Developer ID signed by the team it recorded (SteamacDistTeamID) and notarized.
        case release
        /// Any other .app (bundle.sh, ad-hoc or re-signed copies, third-party builds).
        case sourceBuild = "source-build"
        /// The dev launcher work/out/steamac-vm (not a bundle).
        case development
    }

    static let buildKind: BuildKind = {
        guard AppBundle.releaseDefaults else { return .development }
        guard let team = Bundle.main.object(forInfoDictionaryKey: "SteamacDistTeamID") as? String,
              signedByDeveloperID(team: team) else { return .sourceBuild }
        return .release
    }()

    static var environment: String {
        test ? "development" : buildKind.rawValue
    }

    /// The running code's signature is valid and a Developer ID Application certificate of `team`
    /// signed it (Apple's Developer ID requirement). Ad-hoc re-signing drops the team; Info.plist
    /// is sealed by the signature, so the key cannot be added to a signed copy either.
    private static func signedByDeveloperID(team: String) -> Bool {
        guard team.count == 10, team.allSatisfy({ $0.isASCII && ($0.isUppercase || $0.isNumber) }) else { return false }
        let text = "anchor apple generic and certificate 1[field.1.2.840.113635.100.6.2.6] exists"
            + " and certificate leaf[field.1.2.840.113635.100.6.1.13] exists and certificate leaf[subject.OU] = \"\(team)\""
        var code: SecCode?
        var requirement: SecRequirement?
        guard SecCodeCopySelf([], &code) == errSecSuccess, let code,
              SecRequirementCreateWithString(text as CFString, [], &requirement) == errSecSuccess, let requirement
        else { return false }
        return SecCodeCheckValidity(code, [], requirement) == errSecSuccess
    }

    private static var cacheDir: String {
        NSHomeDirectory() + "/Library/Caches/" + LauncherSettings.defaultDomain + "/sentry/" + role.rawValue
    }

    /// Random install ID shared by both processes (the SDK's own one is per cache directory):
    /// counts affected Macs, nothing else.
    static let installID: String = {
        let path = AppBundle.appSupportDir + "/crash-reports-install-id"
        if let s = try? String(contentsOfFile: path, encoding: .utf8), UUID(uuidString: s) != nil { return s }
        let id = UUID().uuidString
        try? FileManager.default.createDirectory(atPath: AppBundle.appSupportDir, withIntermediateDirectories: true)
        try? id.write(toFile: path, atomically: true, encoding: .utf8)
        return id
    }()

    /// The saved setting, read from the defaults store (the supervisor also sees changes the VM
    /// process's Settings window made).
    private static var settingAllows: Bool {
        LauncherSettings.shared.defaults.object(forKey: LauncherSettings.Key.sendCrashReports.rawValue) as? Bool ?? true
    }

    // MARK: setup

    /// Once per process, after the options are resolved. Self-tests never report (except the
    /// Sentry tests); `--create-disk` does.
    static func setUp(options: Options, settings: LauncherSettings) {
        let isTest = options.sentryTestEvent || options.sentryTestCrash != nil
        if options.isSelftest && options.createDisk == nil && !isTest { return }
        role = Supervisor.isChild ? .vm : .launcher
        test = isTest
        runOverride = options.noCrashReports
            ? (options.explicit.contains(noFlag) ? noFlag : "\(disableEnv)=0") : nil
        configured = true
        // Supervisor: tap stderr of both processes: the session log Report a Problem attaches
        // (always) and, while reporting is on, breadcrumbs and error patterns. Memory pressure
        // changes go to that log too (and into "VM process killed" reports).
        if role == .launcher && !options.isSelftest {
            tap = StderrTap.install { line in
                RollingLog.launcher.append(line)
                observe(line: line)
            }
            memoryWatch.start()
        }
        if let reason = runOverride {
            log("crash reporting: off for this run (\(reason))")
            return
        }
        if options.sentryTestCrash == "metal" { setenv("MTL_DEBUG_LAYER", "1", 1) }   // before Metal starts
        hostTags(options: options)
        if role == .vm {
            vmTags(options: options)
            // Settings window / first-run checkbox: apply right away in this process.
            settingsSubscription = settings.$sendCrashReports.dropFirst().removeDuplicates().sink { on in
                DispatchQueue.main.async { on ? start() : stop(reason: "turned off in Settings") }
            }
        }
        guard settings.sendCrashReports else {
            log("crash reporting: off (Settings > General)")
            return
        }
        start()
    }

    private static func start() {
        guard configured, runOverride == nil, !locked({ running }) else { return }
        prepareScrubber()
        try? FileManager.default.createDirectory(atPath: cacheDir, withIntermediateDirectories: true)
        let currentTags = locked { tags }
        SentrySDK.start { o in
            o.dsn = dsn
            o.releaseName = releaseName
            o.environment = environment
            o.debug = ProcessInfo.processInfo.environment[debugEnv] == "1"
            o.cacheDirectoryPath = cacheDir
            o.sendDefaultPii = false
            o.maxBreadcrumbs = 200
            o.attachStacktrace = false
            o.enableCrashHandler = true
            o.enableUncaughtNSExceptionReporting = true
            o.enableAutoSessionTracking = false
            o.enableAppHangTracking = false
            o.enableWatchdogTerminationTracking = false
            o.enableAutoBreadcrumbTracking = false
            o.enableNetworkBreadcrumbs = false
            o.enableNetworkTracking = false
            o.enableCaptureFailedRequests = false
            o.enableSwizzling = false
            o.enableAutoPerformanceTracing = false
            o.enableFileIOTracing = false
            o.enableCoreDataTracing = false
            o.enableMetricKit = false
            o.sendClientReports = false
            // A SIGPIPE kill is a lost output pipe, not a crash (reports saved by builds that did
            // not ignore SIGPIPE yet are sent at the next start: STEAMAC-10).
            o.beforeSend = { event in isSIGPIPE(event) ? nil : scrub(event: event) }
            o.beforeBreadcrumb = { crumb in
                crumb.message = crumb.message.map(scrub)
                return crumb
            }
            o.initialScope = { scope in
                scope.setTags(currentTags)
                scope.setUser(User(userId: installID))
                return scope
            }
        }
        locked { running = true }
        log("crash reporting: on (\(environment), build \(buildKind.rawValue), \(releaseName))")
    }

    private static func stop(reason: String) {
        guard locked({ running }) else { return }
        SentrySDK.close()
        locked { running = false }
        log("crash reporting: off (\(reason))")
    }

    /// For reports: on / off and why.
    static var statusSummary: String {
        if let r = runOverride { return "off for this run (\(r))" }
        return locked({ running }) ? "on" : "off (Settings > General)"
    }

    /// Tags of this process plus, in the supervisor, the VM process's (run dir file); scrubbed
    /// (only reports call this).
    static func tagSnapshot(runDir dir: String?) -> [String: String] {
        var t = locked { tags }
        if let dir, let data = FileManager.default.contents(atPath: dir + "/sentry-tags.json"),
           let vm = (try? JSONSerialization.jsonObject(with: data)) as? [String: String] {
            t.merge(vm) { old, _ in old }
        }
        return t.mapValues(scrub)
    }

    /// The last event either process of this session sent (run dir file), else this process's.
    static func lastEventId(runDir dir: String?) -> String? {
        if let dir, let s = try? String(contentsOfFile: dir + "/last-event-id", encoding: .utf8) {
            let id = s.trimmingCharacters(in: .whitespacesAndNewlines)
            if id.count == 32 { return id }
        }
        return locked { lastEvent }
    }

    /// The setting decides whether the SDK runs (supervisor, main thread only: before each boot
    /// and after the VM process ended). SentrySDK.start/close need the main thread, which waits
    /// in waitpid while a VM runs, so reports from the tap thread only check the setting.
    private static func followSetting() {
        guard configured, runOverride == nil, Thread.isMainThread else { return }
        if settingAllows { start() } else { stop(reason: "Settings > General") }
    }

    // MARK: tags

    /// Tags are kept as given (none carries user data by construction) and scrubbed where they
    /// leave the process: beforeSend (scope tags included), report() and tagSnapshot. Scrubbing
    /// here would build the identity patterns on every boot, reporting off included.
    private static func setTags(_ new: [String: String]) {
        let clean = new.filter { !$0.value.isEmpty }.mapValues { String($0.prefix(200)) }
        locked { tags.merge(clean) { $1 } }
        if locked({ running }) { SentrySDK.configureScope { $0.setTags(clean) } }
    }

    private static func hostTags(options: Options) {
        let v = ProcessInfo.processInfo.operatingSystemVersion
        var t = [
            "process": role.rawValue,
            "macos": "\(v.majorVersion).\(v.minorVersion).\(v.patchVersion)",
            "mac_model": sysctlString("hw.model") ?? "?",
            "host_cpus": String(ProcessInfo.processInfo.activeProcessorCount),
            "host_mem_gb": String(ProcessInfo.processInfo.physicalMemory >> 30),
            "gpu": MTLCreateSystemDefaultDevice()?.name ?? "none",
            "vm_cpus": String(options.cpus),
            "vm_mem_mib": String(options.memMiB),
            "vm_cpus_auto": String(options.cpusSource == .auto),
            "vm_mem_auto": String(options.memSource == .auto),
            "build_kind": buildKind.rawValue,
        ]
        if let rev = Bundle.main.object(forInfoDictionaryKey: "SteamacMVKPatchRevision") as? String { t["mvk_patch"] = rev }
        if let rev = Bundle.main.object(forInfoDictionaryKey: "SteamacKosmicKrispRevision") as? String { t["kk_patch"] = rev }
        t["vulkan_driver"] = options.vulkanDriver.rawValue
        for (tag, lib) in [("libkrun", "libkrun.1.dylib"), ("virglrenderer", "libvirglrenderer.1.dylib"),
                           ("moltenvk", "libMoltenVK.dylib"), ("kosmickrisp", "libvulkan_kosmickrisp.dylib")] {
            if let uuid = loadedImageUUID(suffix: "/" + lib) { t[tag] = uuid }
        }
        if let run = ProcessInfo.processInfo.environment[runIdEnv] { t["run"] = run }
        if test { t["test"] = "true" }
        locked { tags.merge(t) { $1 } }
    }

    /// VM process: boot settings, kernel version (scanned from the Image in the background).
    private static func vmTags(options: Options) {
        vmContext([
            "boot": String(Supervisor.bootNumber),
            "display_mode": options.headless ? "headless"
                : "\(options.guestSize.0)x\(options.guestSize.1)@\(options.refreshRate) \(options.fullscreen ? "fullscreen" : "windowed")"
                    + (options.pixelScale > 1 ? " retina \(options.pixelScale)x" : ""),
            "mouse": options.mouseMode.rawValue,
            "network": options.network ? "on" : "off",
            "sound": options.sound ? "on" : "off",
        ])
        let kernel = options.kernel
        guard !kernel.isEmpty else { return }
        DispatchQueue.global(qos: .utility).async {
            if let k = kernelVersion(image: kernel) { vmContext(["kernel": k]) }
        }
    }

    /// VM-process tags the supervisor's reports carry too (run dir file, read at report time).
    private static func vmContext(_ new: [String: String], removing: String? = nil) {
        setTags(new)
        if let key = removing {
            let had = locked { tags.removeValue(forKey: key) != nil }
            if had && locked({ running }) { SentrySDK.configureScope { $0.removeTag(key: key) } }
        }
        guard role == .vm, let dir = Supervisor.runDir else { return }
        let keys = ["boot", "display_mode", "kernel", "steamos_build", "layer", "network", "sound", "mouse", "appid"]
        let snapshot = locked { tags.filter { keys.contains($0.key) } }
        if let data = try? JSONSerialization.data(withJSONObject: snapshot) {
            try? data.write(to: URL(fileURLWithPath: dir + "/sentry-tags.json"), options: .atomic)
        }
    }

    /// VM process: the game that has the guest's focus (`appid` tag of both processes' events
    /// while it has; Steam, the desktop or an unknown app id clear it).
    static func focusedGame(_ focus: GuestFocus) {
        guard configured, role == .vm else { return }
        if case .game(let id) = focus, id > 0 {
            vmContext(["appid": String(id)])
        } else {
            vmContext([:], removing: "appid")
        }
    }

    /// hvc0 lines of interest (the console itself is never reported): the initramfs names the
    /// SteamOS build it boots and the steamac layer release.
    static func consoleLine(_ raw: String) {
        guard configured, raw.contains("steamac-init: ") else { return }
        if let r = raw.range(of: "steamac-init: rootfs-"), let b = raw.range(of: "BUILD_ID=", range: r.upperBound..<raw.endIndex) {
            let id = raw[b.upperBound...].prefix { !$0.isWhitespace }
            if !id.isEmpty { vmContext(["steamos_build": String(id)]) }
        } else if let r = raw.range(of: "steamac-init: steamac layer "), let c = raw.range(of: ": ", range: r.upperBound..<raw.endIndex) {
            let release = raw[c.upperBound...].trimmingCharacters(in: .whitespacesAndNewlines)
            if !release.isEmpty { vmContext(["layer": release]) }
        }
    }

    // MARK: supervisor hooks

    /// Before each boot: follow the setting, remember the run dir, give the VM process the run id.
    static func supervisorBoot(_ o: Options, boot: Int, runDir dir: String, env: inout [String: String]) {
        guard configured, role == .launcher else { return }
        runDir = dir
        try? FileManager.default.removeItem(atPath: dir + "/user-exit")
        try? FileManager.default.removeItem(atPath: dir + "/sentry-tags.json")
        let run = locked { tags["run"] } ?? String(format: "%08x", arc4random())
        env[runIdEnv] = run
        setTags(["run": run, "boot": String(boot), "vm_cpus": String(o.cpus), "vm_mem_mib": String(o.memMiB),
                 "vm_cpus_auto": String(o.cpusSource == .auto), "vm_mem_auto": String(o.memSource == .auto),
                 "vulkan_driver": o.vulkanDriver.rawValue])
        memoryWatch.reset()
        followSetting()
    }

    /// VM process: the user asked the VM to stop (window close, menu, signal, restart).
    static func noteUserExit() {
        guard let dir = Supervisor.runDir else { return }
        FileManager.default.createFile(atPath: dir + "/user-exit", contents: nil)
    }

    /// Ways to ask a process to end (logout, `kill`, ^C, the terminal closing). The VM process
    /// handles them (guest power key); one that kills it came before its handlers were installed
    /// (first-run sheet, startup) and is no crash.
    static let terminationSignals: Set<Int32> = [SIGTERM, SIGINT, SIGHUP]

    /// The VM process ended in a way the user did not ask for: a crash signal, SIGKILL, or a
    /// non-zero exit without a user request (window close, menu, signal, restart; Force Quit in
    /// the app menu exits with status 1 after one). SIGPIPE (its output pipe closed; ignored since
    /// STEAMAC-10, see main.swift) is no crash either.
    static func unexpectedExit(status: Int32, runDir dir: String) -> Bool {
        guard status != 0 else { return false }
        let signal = status > 128 ? status - 128 : 0
        if terminationSignals.contains(signal) || signal == SIGPIPE { return false }
        let userExit = FileManager.default.fileExists(atPath: dir + "/user-exit")
        return !(userExit && (signal == 0 || signal == SIGKILL))
    }

    private static func isSIGPIPE(_ event: Event) -> Bool {
        event.exceptions?.contains { ($0.mechanism?.meta?.signal?["number"] as? NSNumber)?.int32Value == SIGPIPE } ?? false
    }

    static let killedSummary = "VM process killed (SIGKILL — memory pressure or force quit)"

    /// "VM process crashed (SIGABRT)" / "VM process killed (SIGKILL …)" / "VM process exited with status 1".
    static func exitSummary(status: Int32) -> String {
        guard status > 128 else { return "VM process exited with status \(status)" }
        let signal = status - 128
        return signal == SIGKILL ? killedSummary : "VM process crashed (\(signalName(signal)))"
    }

    /// UI counterpart; exitSummary stays English in reports and logs.
    static func localizedExitSummary(status: Int32) -> String {
        guard status > 128 else { return String(localized: "VM process exited with status \(status)") }
        let signal = status - 128
        return signal == SIGKILL
            ? String(localized: "VM process killed (SIGKILL — memory pressure or force quit)")
            : String(localized: "VM process crashed (\(signalName(signal)))")
    }

    /// Supervisor: the VM process ended. A multi-line message still collecting lines is reported
    /// whatever the exit; besides, non-zero exits the user did not ask for and every crash
    /// (signal) are. Flushes before the supervisor exits.
    static func vmExited(_ exit: VMExit) {
        guard configured, role == .launcher, let dir = runDir else { return }
        let unexpected = unexpectedExit(status: exit.status, runDir: dir)
        let userExit = FileManager.default.fileExists(atPath: dir + "/user-exit")
        let signal = exit.signal
        followSetting()
        tap?.waitIdle()   // the VM process's last lines are breadcrumbs of this report
        let (pending, last) = locked { (lineScanner.flushPending(), lineScanner.lastError) }
        for f in pending { report(f.kind, key: f.key, message: f.message, extra: f.extra) }
        guard unexpected else {
            if !pending.isEmpty { flush() }
            return
        }
        var exitTags = ["exit_status": String(exit.status), "signal": signal != 0 ? signalName(signal) : "none",
                        "user_exit": userExit ? "yes" : "no"]
        if signal == SIGKILL {
            // jetsam (the kernel's memory kill) or someone's SIGKILL: Force Quit in the Dock or
            // the Force Quit window, Activity Monitor, kill -9.
            let host = HostMemory.current()
            let pressure = memoryWatch.summary()
            let reason = exit.detail == nil ? "unknown" : exit.killedForMemory ? "jetsam" : "not-jetsam"
            let detail = exit.detail.map { " (exit detail 0x\(String($0, radix: 16)))" } ?? ""
            let lines = [
                killedSummary,
                "killed by the kernel for memory (jetsam): \(reason == "jetsam" ? "yes" : reason == "unknown" ? "unknown" : "no")\(detail)",
                "VM memory \(locked { tags["vm_mem_mib"] } ?? "?") MiB; VM process peak footprint "
                    + (exit.peakFootprint.map(gib) ?? "?"),
                host.summary,
                "memory pressure since the VM started: " + pressure.text,
            ]
            exitTags["kill_reason"] = reason
            exitTags["memory_pressure"] = host.pressure
            exitTags["memory_pressure_max"] = pressure.maxLevel
            if let pct = host.availablePercent { exitTags["host_mem_available_pct"] = String(pct) }
            report(.vmKilled, key: reason, message: lines.joined(separator: "\n"), level: .warning, tags: exitTags)
        } else {
            let lastError = last.map { ": \($0)" } ?? ""
            report(.vmExited, key: signal != 0 ? signalName(signal) : "status \(exit.status)",
                   message: exitSummary(status: exit.status) + lastError, tags: exitTags)
        }
        flush()
    }

    /// Before a deliberate exit right after a report.
    static func flush(timeout: TimeInterval = 5) {
        if locked({ running }) { SentrySDK.flush(timeout: timeout) }
    }

    /// Supervisor exit: the pipe's remaining lines go out before the process ends.
    static func finish() {
        tap?.drain(timeout: 2)
    }

    // MARK: VM-process hooks

    static func stallNotResponding(seconds: TimeInterval) {
        report(.notResponding, key: "not-responding", message: "SteamOS not responding (no GPU work for \(Int(seconds)) s)",
               tags: ["stall_seconds": String(Int(seconds))])
    }

    static func provisionFailed(reason: String) {
        report(.provisionFailed, key: normalize(reason), message: "Provisioning failed: \(reason.isEmpty ? "(no reason given)" : reason)")
    }

    /// Build the same report for capture and the provisioning self-test (which never sends).
    /// Foundation errors group by domain/code, not NSError's pointers, task UUIDs or URLs.
    /// OptionError has no meaningful numeric code: retain its normalised diagnostic so bugs
    /// such as failed publication and bundle verification do not collapse into one issue.
    static func diskCreationReport(_ error: Error) -> (key: String, message: String, extra: [String: String])? {
        guard !(error is DiskCreationFilesystem.Rejection), !(error is DiskCreator.Cancelled),
              !(error is RaucBundle.DevelopmentSignature) else { return nil }
        let e = error as NSError
        let diagnostic = error is OptionError ? normalize("\(error)") : "\(e.domain) \(e.code)"
        return (diagnostic, "Disk creation failed: \(diagnostic)", ["error_detail": "\(error)"])
    }

    static func diskCreationFailed(_ error: Error, branch: String) {
        guard let failure = diskCreationReport(error) else { return }
        report(.diskCreationFailed, key: failure.key, message: failure.message,
               tags: ["steamos_branch": branch], extra: failure.extra)
    }

    // MARK: log lines

    /// Every `log()` line of this process. In the supervisor the tap sees them (and the VM
    /// process's lines and stderr of the libraries) instead.
    static func logged(_ message: String) {
        guard locked({ running && tap == nil }) else { return }
        SentrySDK.addBreadcrumb(breadcrumb(for: "[steamac-vm] " + message))
    }

    private static func breadcrumb(for line: String) -> Breadcrumb {
        var level = SentryLevel.info
        var category = "stderr"
        if line.hasPrefix("[steamac-vm] ") {
            category = line.hasPrefix("[steamac-vm] progress: ") ? "boot" : "launcher"
            if line.contains("error") || line.contains("fail") { level = .warning }
        } else if line.hasPrefix("[mvk-") {
            category = "moltenvk"
            level = line.hasPrefix("[mvk-error]") ? .error : .warning
        } else if line.contains("virglrenderer") || line.contains("vkr:") {
            category = "virglrenderer"
            level = .warning
        } else if line.contains(" krun") || line.contains("WARN ") || line.contains("ERROR ") {
            category = "libkrun"
            level = line.contains("ERROR ") ? .error : .warning
        }
        let crumb = Breadcrumb(level: level, category: category)
        crumb.message = String(scrub(line).prefix(600))
        return crumb
    }

    /// Supervisor tap: one stderr line of either process. MSL source lines MoltenVK logs after a
    /// failed shader compile go into that report, not the breadcrumbs.
    private static func observe(line: String) {
        guard locked({ running }) else { return }
        if !line.hasPrefix(LineScanner.mslPrefix) { SentrySDK.addBreadcrumb(breadcrumb(for: line)) }
        let (found, serial) = locked { (lineScanner.feed(line), lineScanner.pendingSerial) }
        for f in found { report(f.kind, key: f.key, message: f.message, extra: f.extra) }
        // A multi-line message nothing followed yet: report it after a pause.
        guard let serial, locked({ scheduledSerial != serial }) else { return }
        locked { scheduledSerial = serial }
        DispatchQueue.global(qos: .utility).asyncAfter(deadline: .now() + 3) {
            for f in locked({ lineScanner.flushPending(serial: serial) }) {
                report(f.kind, key: f.key, message: f.message, extra: f.extra)
            }
        }
    }

    // MARK: reports

    /// Rate-limited, deduplicated report (no-op when reporting is off). `extra`: long scrubbed
    /// details (event extra data), `tags`: short searchable values.
    static func report(_ kind: Kind, key: String, message: String, level: SentryLevel = .error,
                       tags extraTags: [String: String] = [:], extra: [String: String] = [:]) {
        guard configured else { return }
        guard locked({ running }) else { return }
        // Supervisor: the VM process's Settings window may have turned reporting off meanwhile.
        if role == .launcher { guard settingAllows else { return } }
        let fingerprint = kind.rawValue + "|" + key
        let allowed: Bool = locked {
            guard !reportedThisProcess.contains(fingerprint), kindCounts[kind, default: 0] < kind.budget,
                  reportedThisProcess.count < 12 else { return false }
            reportedThisProcess.insert(fingerprint)
            kindCounts[kind, default: 0] += 1
            return true
        }
        guard allowed, test || ReportedStore.claim(fingerprint, quietPeriod: kind.quietPeriod) else { return }
        let event = Event(level: kind == .test ? .info : level)
        event.message = SentryMessage(formatted: String(scrub(message).prefix(2000)))
        event.fingerprint = [kind.rawValue, String(key.prefix(200))]
        if !extra.isEmpty { event.extra = extra.mapValues { String(scrub($0).prefix(8000)) } }
        var t = extraTags
        t["kind"] = kind.rawValue
        if role == .launcher, let dir = runDir,
           let data = FileManager.default.contents(atPath: dir + "/sentry-tags.json"),
           let vm = (try? JSONSerialization.jsonObject(with: data)) as? [String: String] {
            t.merge(vm) { old, _ in old }
        }
        let scoped = t.mapValues { String(scrub($0).prefix(200)) }
        let id = SentrySDK.capture(event: event) { scope in scope.setTags(scoped) }.sentryIdString
        locked { lastEvent = id }
        if let dir = role == .launcher ? runDir : Supervisor.runDir {
            try? id.write(toFile: dir + "/last-event-id", atomically: true, encoding: .utf8)
        }
        log("crash reporting: sent \(kind.rawValue) report (\(id.prefix(8)))")
    }

    // MARK: test flags

    /// `--sentry-test-event`: a test event from this process (VM process: then exit, after the
    /// SDK sent it and any crash report left by an earlier VM process). `--sentry-test-crash
    /// MODE`: the VM process crashes right away (abort | segv | metal), dies by SIGKILL (kill: a
    /// "VM process killed" report) or SIGTERM (term: none), logs a sample shader compile failure
    /// (shader) or a guest GPU teardown then one real device loss (gpu-teardown: one report, the
    /// device loss), or (panic) boots with a kernel command line longer than libkrun's 2048-byte
    /// limit: `Cmdline::insert_str().unwrap()` panics inside krun_start_enter, and a panic cannot
    /// unwind out of the extern "C" function, so Rust aborts the process.
    static func runTests(_ options: inout Options) {
        guard configured, options.sentryTestEvent || options.sentryTestCrash != nil else { return }
        if options.sentryTestEvent {
            guard locked({ running }) else {
                log("sentry test: crash reporting is off; nothing sent")
                if role == .vm { exit(0) }
                return
            }
            report(.test, key: role.rawValue, message: "Sentry test event (\(role.rawValue) process)")
            if role == .vm {
                // Crash reports of earlier VM processes are converted and queued after start.
                Thread.sleep(forTimeInterval: 3)
                SentrySDK.flush(timeout: 15)
                log("sentry test: flushed; exiting")
                exit(0)
            }
            SentrySDK.flush(timeout: 15)
        }
        guard role == .vm, let mode = options.sentryTestCrash else { return }
        if mode == "panic" {
            log("sentry test: booting with a 2100-byte kernel command line (libkrun panics in krun_start_enter)")
            options.cmdline += " steamac.sentrytest=" + String(repeating: "x", count: 2100)
            return
        }
        log("sentry test: crashing the VM process (\(mode))")
        Thread.sleep(forTimeInterval: 0.5)   // the log line reaches the supervisor's tap
        TestCrash.run(mode)
    }

    // MARK: scrubbing

    private static let homeRegex = try! NSRegularExpression(pattern: "/Users/[^/\\s\"':,;)]+")
    /// Not systemd instance units (getty@tty1.service) in the guest console.
    private static let emailRegex = try! NSRegularExpression(
        pattern: "[A-Za-z0-9._%+-]+@[A-Za-z0-9.-]+\\.(?!(?:service|socket|target|mount|automount|timer|path|slice|scope|device|swap)\\b)[A-Za-z]{2,}")
    private static let ipv4Regex = try! NSRegularExpression(pattern: "(?<![\\w.~-])(?:\\d{1,3}\\.){3}\\d{1,3}(?![\\w.~-])")
    /// The Mac's time zone on the kernel cmdline (MacTime; the `booting …` log line): like the
    /// culture context, never sent.
    private static let timeZoneRegex = try! NSRegularExpression(pattern: "steamac\\.tz=[^\\s\"']*")
    /// Names that identify the user or the Mac (whole words, 4+ characters). Built once, on first
    /// use: a breadcrumb or report while reporting is on (start() builds them in the background)
    /// or a Report a Problem bundle (built off the main thread). Never touched otherwise.
    private static let identityRegexes: [NSRegularExpression] = identityNames.compactMap {
        try? NSRegularExpression(pattern: "\\b" + NSRegularExpression.escapedPattern(for: $0) + "\\b", options: .caseInsensitive)
    }

    /// User name, full name, host name (gethostname), computer name and Bonjour name (configd's
    /// dynamic store). Local sources only: ProcessInfo.hostName and Host.current() resolve the
    /// name through DNS and block for over a minute when the network's DNS server does not answer.
    static var identitySources: [(source: String, name: String)] {
        var sources = [("user", NSUserName()), ("full name", NSFullUserName())]
        var buf = [CChar](repeating: 0, count: Int(MAXHOSTNAMELEN) + 1)
        if gethostname(&buf, buf.count - 1) == 0 { sources.append(("host", String(cString: buf))) }
        if let computer = SCDynamicStoreCopyComputerName(nil, nil) { sources.append(("computer", computer as String)) }
        if let bonjour = SCDynamicStoreCopyLocalHostName(nil) { sources.append(("Bonjour", bonjour as String)) }
        return sources
    }

    /// The identity sources, each also without ".local".
    private static var identityNames: Set<String> {
        var names = identitySources.map(\.name)
        names += names.map { $0.replacingOccurrences(of: ".local", with: "") }
        return Set(names.filter { $0.count >= 4 })
    }

    /// Build the identity patterns on a background queue (reporting turned on).
    private static func prepareScrubber() {
        DispatchQueue.global(qos: .utility).async { _ = identityRegexes }
    }

    /// Settings self-test: the host, computer and Bonjour names are found and every identity name
    /// is redacted (alone, as `NAME.local`, upper case). Logs the sources, never the names.
    static func scrubSelfCheck() -> [String] {
        var failures: [String] = []
        let sources = identitySources
        for required in ["host", "computer", "Bonjour"] where !sources.contains(where: { $0.source == required && !$0.name.isEmpty }) {
            failures.append("scrub: no \(required) name")
        }
        var checked: [String] = []
        for (source, name) in sources {
            let bare = name.replacingOccurrences(of: ".local", with: "")
            guard bare.count >= 4 else { continue }   // too short to redact (whole words, 4+ characters)
            for text in ["host \(name) said", "smb://\(bare).local/share", "\"\(name.uppercased())\""]
                where scrub(text).range(of: bare, options: .caseInsensitive) != nil {
                failures.append("scrub: \(source) name (\(name.count) chars) not redacted")
            }
            checked.append(source)
        }
        if scrub("cmdline=\"rootwait steamac.tz=America/Argentina/Buenos_Aires steamac.ssh=0\"").contains("Buenos_Aires") {
            failures.append("scrub: steamac.tz not redacted")
        }
        log("selftest-settings: scrub check: \(checked.joined(separator: ", ")) names, steamac.tz: "
            + (failures.isEmpty ? "all redacted" : failures.joined(separator: "; ")))
        return failures
    }

    /// Settings self-test: a guest process's GPU teardown (STEAMAC-G) and the bystander lines after
    /// it produce no finding, also after a pause or the VM process's end; each real fatal line one.
    static func scannerSelfCheck() -> [String] {
        var failures: [String] = []
        var scanner = LineScanner()
        var found = LineScanner.teardownSample.flatMap { scanner.feed($0) }
        found += scanner.flushPending()
        if !found.isEmpty { failures.append("scanner: teardown reported: \(found.map(\.message))") }
        for line in LineScanner.fatalSample {
            var s = LineScanner()
            let f = (LineScanner.teardownSample + [line]).flatMap { s.feed($0) } + s.flushPending()
            if f.count != 1 || f.first?.kind != .gpuContextFatal || f.first?.message.hasSuffix(line) != true {
                failures.append("scanner: \(f.count) findings for \(line)")
            }
        }
        log("selftest-settings: scanner check: \(LineScanner.teardownSample.count) teardown lines → no report, "
            + "\(LineScanner.fatalSample.count) fatal lines → one report each: "
            + (failures.isEmpty ? "ok" : failures.joined(separator: "; ")))
        return failures
    }

    static func scrub(_ s: String) -> String {
        var out = s
        func replace(_ re: NSRegularExpression, _ with: (String) -> String) {
            let ns = out as NSString
            let matches = re.matches(in: out, range: NSRange(location: 0, length: ns.length))
            guard !matches.isEmpty else { return }
            let result = NSMutableString(string: out)
            for m in matches.reversed() { result.replaceCharacters(in: m.range, with: with(ns.substring(with: m.range))) }
            out = result as String
        }
        if out.contains("/Users/") { replace(homeRegex) { _ in "~" } }
        if out.contains("@") { replace(emailRegex) { m in m.hasPrefix(LauncherSettings.defaultDomain) ? m : "<email>" } }
        replace(ipv4Regex) { ip in ip.hasPrefix("127.") || ip.hasPrefix("192.168.127.") || ip == "0.0.0.0" ? ip : "<ip>" }
        if out.contains("steamac.tz=") { replace(timeZoneRegex) { _ in "steamac.tz=<redacted>" } }
        for re in identityRegexes { replace(re) { _ in "<redacted>" } }
        return out
    }

    private static func scrubAny(_ v: Any) -> Any {
        switch v {
        case let s as String: return scrub(s)
        case let d as [String: Any]: return d.mapValues(scrubAny)
        case let a as [Any]: return a.map(scrubAny)
        default: return v
        }
    }

    private static func scrub(frames: SentryStacktrace?) {
        for f in frames?.frames ?? [] {
            f.package = f.package.map(scrub)
            f.fileName = f.fileName.map(scrub)
        }
    }

    /// Last line of defence for every event (crash reports from earlier runs included).
    static func scrub(event e: Event) -> Event {
        e.serverName = nil
        if let m = e.message { e.message = SentryMessage(formatted: scrub(m.formatted)) }
        if let u = e.user {
            u.ipAddress = nil
            u.username = nil
            u.email = nil
            u.name = nil
        }
        for x in e.exceptions ?? [] {
            x.value = x.value.map(scrub)
            scrub(frames: x.stacktrace)
        }
        for t in e.threads ?? [] {
            t.name = t.name.map(scrub)
            scrub(frames: t.stacktrace)
        }
        scrub(frames: e.stacktrace)
        for d in e.debugMeta ?? [] { d.codeFile = d.codeFile.map(scrub) }
        for b in e.breadcrumbs ?? [] { b.message = b.message.map(scrub) }
        e.context = e.context.map { $0.mapValues { $0.mapValues(scrubAny) } }
        if var device = e.context?["device"] { device.removeValue(forKey: "name"); e.context?["device"] = device }
        e.context?.removeValue(forKey: "culture")   // locale and time zone
        e.extra = e.extra.map { $0.mapValues(scrubAny) }
        e.tags = e.tags.map { $0.mapValues(scrub) }
        return e
    }

    /// Normalised fingerprint text: digits and hex addresses removed, length capped.
    static func normalize(_ s: String) -> String {
        var out = ""
        var lastWasDigit = false
        for ch in scrub(s) {
            if ch.isNumber {
                if !lastWasDigit { out.append("#") }
                lastWasDigit = true
            } else {
                lastWasDigit = false
                out.append(ch)
            }
        }
        return String(out.replacingOccurrences(of: "0x#", with: "#").prefix(300))
    }

    // MARK: helpers

    private static func sysctlString(_ name: String) -> String? {
        var size = 0
        guard sysctlbyname(name, nil, &size, nil, 0) == 0, size > 0 else { return nil }
        var buf = [CChar](repeating: 0, count: size)
        guard sysctlbyname(name, &buf, &size, nil, 0) == 0 else { return nil }
        return String(cString: buf)
    }

    /// LC_UUID of a loaded image (matches its dSYM / the debug files dist.sh uploads).
    static func loadedImageUUID(suffix: String) -> String? {
        for i in 0..<_dyld_image_count() {
            guard let name = _dyld_get_image_name(i), String(cString: name).hasSuffix(suffix),
                  let header = _dyld_get_image_header(i) else { continue }
            var p = UnsafeRawPointer(header).advanced(by: MemoryLayout<mach_header_64>.size)
            for _ in 0..<header.pointee.ncmds {
                let cmd = p.load(as: load_command.self)
                if cmd.cmd == LC_UUID {
                    let u = p.load(as: uuid_command.self).uuid
                    return UUID(uuid: u).uuidString.lowercased()
                }
                p = p.advanced(by: Int(cmd.cmdsize))
            }
        }
        return nil
    }

    /// "7.2.9-steamac #1 SMP PREEMPT Sun Oct 4 11:27:59 UTC 2026" from a raw arm64 Image.
    static func kernelVersion(image path: String) -> String? {
        guard let data = try? Data(contentsOf: URL(fileURLWithPath: path), options: .alwaysMapped) else { return nil }
        let needle = Data("Linux version ".utf8)
        var from = data.startIndex
        while let r = data.range(of: needle, in: from..<data.endIndex) {
            let end = data[r.upperBound...].prefix(400).firstIndex { $0 == 0 || $0 == 10 } ?? min(data.endIndex, r.upperBound + 400)
            let text = String(decoding: data[r.upperBound..<end], as: UTF8.self)
            if let hash = text.range(of: " #"), text[hash.upperBound...].first?.isNumber == true {
                let release = text.prefix { $0 != " " }
                return (release + text[hash.lowerBound...]).split(whereSeparator: \.isWhitespace).joined(separator: " ")
            }
            from = r.upperBound
        }
        return nil
    }

    static func signalName(_ sig: Int32) -> String {
        switch sig {
        case SIGABRT: return "SIGABRT"
        case SIGSEGV: return "SIGSEGV"
        case SIGBUS: return "SIGBUS"
        case SIGILL: return "SIGILL"
        case SIGTRAP: return "SIGTRAP"
        case SIGFPE: return "SIGFPE"
        case SIGKILL: return "SIGKILL"
        case SIGTERM: return "SIGTERM"
        case SIGINT: return "SIGINT"
        case SIGHUP: return "SIGHUP"
        case SIGPIPE: return "SIGPIPE"
        case SIGSYS: return "SIGSYS"
        default: return "signal \(sig)"
        }
    }
}

/// Error patterns in the supervisor's stderr stream (both processes). Multi-line messages
/// (MoltenVK compile errors, Rust panics) collect their continuation lines first. virglrenderer's
/// "pipeline N creation failed on host" is no report of its own (a breadcrumb only): the
/// MoltenVK error before it carries the details. Neither are a guest process's teardown
/// (`isTeardown`) and the lines of other threads that stop after it (`isBystander`).
private struct LineScanner {
    struct Finding {
        let kind: CrashReporting.Kind
        let key: String
        let message: String
        var extra: [String: String] = [:]
    }

    /// MoltenVK (patch) logs the source of a shader library that failed to compile after the
    /// error: the first 40 lines, a "... (N lines total)" line, then "L: text" around each
    /// error location.
    static let mslPrefix = "[mvk-msl] "

    private var pending: (kind: CrashReporting.Kind, header: String, lines: [String], msl: [String])?
    private var multiSerial: Int?
    /// Newest multi-line message still open; CrashReporting reports it after a pause.
    var pendingSerial: Int? { multiSerial }
    private var serial = 0
    /// Last launcher error line (`[steamac-vm] error: …`), for VM exit reports.
    private(set) var lastError: String?

    mutating func feed(_ line: String) -> [Finding] {
        var out: [Finding] = []
        if var p = pending {
            if p.kind == .pipelineCompile && line.hasPrefix(Self.mslPrefix) {
                if p.msl.count < 120 { p.msl.append(String(line.dropFirst(Self.mslPrefix.count))) }
                pending = p
                return out
            }
            let continuation = !line.hasPrefix("[") && !line.hasPrefix("thread '")
            if continuation && p.lines.count >= 6 && p.kind == .pipelineCompile && p.msl.isEmpty {
                return out   // more compiler output than the report keeps; the source may follow
            }
            if continuation && p.lines.count < 6 && p.msl.isEmpty && !line.trimmingCharacters(in: .whitespaces).isEmpty {
                p.lines.append(line)
                pending = p
                if p.kind == .rustPanic { out.append(finish()) }
                return out
            }
            out.append(finish())
        }
        if line.hasPrefix("[steamac-vm] error: ") || line.hasPrefix("[steamac-vm] provision failed") {
            lastError = String(line.dropFirst("[steamac-vm] ".count).prefix(300))
        } else if line.contains("failed assertion") || line.contains("panicked at") || line.hasPrefix("Fatal error: ") {
            lastError = String(line.prefix(300))
        }
        if Self.isTeardown(line) || Self.isBystander(line) {
            // breadcrumb only
        } else if Self.isGPUFatal(line) {
            out.append(gpuFatal(line))
        } else if line.hasPrefix("[mvk-error]") && line.contains("compile failed") {
            begin(.pipelineCompile, line)
        } else if line.hasPrefix("thread '") && line.contains("panicked at") {
            begin(.rustPanic, line)
        }
        return out
    }

    /// The open multi-line message (the VM process ended), or only if `serial` names it (a pause
    /// after it).
    mutating func flushPending(serial only: Int? = nil) -> [Finding] {
        guard pending != nil, only == nil || only == multiSerial else { return [] }
        return [finish()]
    }

    private static func isGPUFatal(_ line: String) -> Bool {
        line.contains("fatal decoder state") || line.contains("vn_dispatch_command failed")
            || line.contains("hit device lost") || line.contains("CS error") || line.contains("Lost VkDevice")
            || line.contains("VK_ERROR_DEVICE_LOST")
    }

    /// virglrenderer (patch 0010): "resource N destroyed while ring R uses it (CS error)" /
    /// "… destroyed while the context replies into it (CS error)". Only a guest process tearing
    /// down frees a ring's or reply buffer's resource while the context still uses it: Steam's
    /// gldriverquery / d3ddriverquery probes on every start, a game exiting, fossilize_replay
    /// killed when the user skips Steam's shader processing (STEAMAC-G, 2026-10-05 16:09:54).
    /// The context dies with its process; nothing is lost for anyone else.
    static func isTeardown(_ line: String) -> Bool {
        line.contains("CS error")
            && (line.contains(" destroyed while ring ") || line.contains(" destroyed while the context replies into it"))
    }

    /// virglrenderer (patch 0010): another thread of a context that went fatal stops
    /// ("<command> stopped: the context went fatal on another thread", "…submit_cmd: stopping,
    /// the context went fatal on another thread"); the thread that raised it logs its own line.
    static func isBystander(_ line: String) -> Bool {
        line.contains("went fatal on another thread")
    }

    /// STEAMAC-G 2026-10-05 16:09:54: the user skipped Steam's shader processing (fossilize_replay
    /// killed), then a pipeline compile of the same context stopped; earlier, the driver probes
    /// exiting at Steam start. None of it is a report.
    static let teardownSample: [String] = [
        "vkr: resource 122 destroyed while ring 187651012771488 uses it (CS error)",
        "server: socket disconnected",
        "vkr: destroying context 17 (gldriverquery) with a valid instance",
        "vkr: destroying device with valid objects",
        "vkr: resource 416 destroyed while ring 187650921533472 uses it (CS error)",
        "vkr: resource 429 destroyed while ring 281472897937072 uses it (CS error)",
        "vkr: resource 77 destroyed while the context replies into it (CS error)",
        "vkr: vkCreateGraphicsPipelines stopped: the context went fatal on another thread",
        "vkr: ring_submit_cmd: stopping, the context went fatal on another thread",
    ].map(LineScanner.virglLine)

    /// Lines that stay reports (one each).
    static let fatalSample: [String] = [
        "[mvk-error] VK_ERROR_OUT_OF_DEVICE_MEMORY: Lost VkDevice after MTLCommandBuffer \"vkQueueSubmit MTLCommandBuffer on Queue 0-0\" "
            + "execution failed (code 8): Insufficient Memory (00000008:kIOGPUCommandBufferCallbackErrorOutOfMemory)",
        LineScanner.virglLine("vkr: vkFreeMemory resulted in CS error"),
        LineScanner.virglLine("vkr: ring_submit_cmd: vn_dispatch_command failed"),
        LineScanner.virglLine("vkr: fatal decoder state"),
    ]

    static func virglLine(_ text: String) -> String {
        "[2026-10-05T16:09:54.208470Z WARN  krun_rutabaga_gfx::virgl_renderer] virglrenderer: " + text
    }

    private func gpuFatal(_ line: String) -> Finding {
        Finding(kind: .gpuContextFatal, key: "boot \(ProcessInfo.processInfo.environment[Supervisor.bootEnv] ?? "")",
                message: "Guest GPU context fatal: \(line)")
    }

    private mutating func begin(_ kind: CrashReporting.Kind, _ header: String) {
        serial += 1
        multiSerial = serial
        pending = (kind, header, [], [])
    }

    private mutating func finish() -> Finding {
        let p = pending!
        pending = nil
        multiSerial = nil
        let detail = p.lines.joined(separator: "\n")
        switch p.kind {
        case .rustPanic:
            // thread 'name' panicked at src/x.rs:12:5:\n<message>
            let at = p.header.range(of: "panicked at ").map { String(p.header[$0.upperBound...]) } ?? p.header
            return Finding(kind: .rustPanic, key: CrashReporting.normalize(at), message: "Rust panic at \(at) \(detail)")
        default:
            var f = Finding(kind: p.kind, key: CrashReporting.normalize(p.header + "\n" + detail), message: "\(p.header)\n\(detail)")
            // Head ("<text>", "... (N lines total)") and error context ("L: <text>") are separate
            // extras, so long head lines never crowd out the lines around the error.
            let isContext = { (s: String) in s.firstIndex(of: ":").map { !s[..<$0].isEmpty && s[..<$0].allSatisfy(\.isNumber) } ?? false }
            let head = p.msl.filter { !isContext($0) }, context = p.msl.filter(isContext)
            if !head.isEmpty { f.extra["msl_source"] = head.joined(separator: "\n") }
            if !context.isEmpty { f.extra["msl_error_context"] = context.joined(separator: "\n") }
            return f
        }
    }
}

/// Fingerprints reported recently, shared by both processes
/// (~/Library/Caches/es.fxgam.steamac/sentry/reported.json).
private enum ReportedStore {
    private static let lock = NSLock()
    private static var path: String {
        NSHomeDirectory() + "/Library/Caches/" + LauncherSettings.defaultDomain + "/sentry/reported.json"
    }

    /// True (and recorded) unless the fingerprint was reported within `quietPeriod`.
    static func claim(_ fingerprint: String, quietPeriod: TimeInterval) -> Bool {
        guard quietPeriod > 0 else { return true }
        lock.lock()
        defer { lock.unlock() }
        let now = Date().timeIntervalSince1970
        var seen = (FileManager.default.contents(atPath: path)
            .flatMap { try? JSONSerialization.jsonObject(with: $0) } as? [String: Double]) ?? [:]
        if let last = seen[fingerprint], now - last < quietPeriod { return false }
        seen = seen.filter { now - $0.value < 60 * 86400 }
        if seen.count > 2000 { seen = Dictionary(uniqueKeysWithValues: seen.sorted { $0.value > $1.value }.prefix(1500).map { ($0.key, $0.value) }) }
        seen[fingerprint] = now
        try? FileManager.default.createDirectory(atPath: (path as NSString).deletingLastPathComponent, withIntermediateDirectories: true)
        if let data = try? JSONSerialization.data(withJSONObject: seen) {
            try? data.write(to: URL(fileURLWithPath: path), options: .atomic)
        }
        return true
    }
}

/// Supervisor stderr: fd 2 becomes a pipe; a reader thread copies everything to the original
/// stderr (terminal or log file) and hands complete lines to `onLine`. The VM process inherits
/// the pipe, so its output survives its crash (bytes already written stay in the pipe).
final class StderrTap {
    private let original: Int32
    private let readFD: Int32
    private let onLine: (String) -> Void
    private let done = DispatchSemaphore(value: 0)
    private let idle = NSCondition()
    private var busy = false
    /// FIONREAD = _IOR('f', 127, int) (the macro is not imported into Swift).
    private static let fionread: UInt = 0x4004_667f

    private init(original: Int32, readFD: Int32, onLine: @escaping (String) -> Void) {
        self.original = original
        self.readFD = readFD
        self.onLine = onLine
    }

    static func install(onLine: @escaping (String) -> Void) -> StderrTap? {
        var fds: [Int32] = [0, 0]
        let original = dup(STDERR_FILENO)
        guard original >= 0, pipe(&fds) == 0 else { return nil }
        _ = fcntl(original, F_SETFD, FD_CLOEXEC)
        _ = fcntl(fds[0], F_SETFD, FD_CLOEXEC)
        let tap = StderrTap(original: original, readFD: fds[0], onLine: onLine)
        guard dup2(fds[1], STDERR_FILENO) >= 0 else { return nil }
        close(fds[1])
        let t = Thread { tap.run() }
        t.name = "steamac.stderr-tap"
        t.qualityOfService = .utility
        t.start()
        atexit { CrashReporting.finish() }
        return tap
    }

    private func run() {
        var buf = [UInt8](repeating: 0, count: 65536)
        var partial = [UInt8]()
        while true {
            let n = buf.withUnsafeMutableBytes { read(readFD, $0.baseAddress, $0.count) }
            if n < 0 && errno == EINTR { continue }
            guard n > 0 else { break }
            idle.lock(); busy = true; idle.unlock()
            buf.withUnsafeBytes { p in
                var off = 0
                while off < n {
                    let w = write(original, p.baseAddress! + off, n - off)
                    if w < 0 && errno == EINTR { continue }
                    if w <= 0 { break }
                    off += w
                }
            }
            partial.append(contentsOf: buf[0..<n])
            while let nl = partial.firstIndex(of: 10) {
                let line = String(decoding: partial[..<nl].prefix(2000), as: UTF8.self)
                partial.removeSubrange(...nl)
                onLine(line)
            }
            if partial.count > 8192 { partial.removeAll() }
            var avail: Int32 = 0
            if ioctl(readFD, StderrTap.fionread, &avail) == 0 && avail == 0 {
                idle.lock(); busy = false; idle.broadcast(); idle.unlock()
            }
        }
        idle.lock(); busy = false; idle.broadcast(); idle.unlock()
        done.signal()
    }

    /// Until everything written so far was processed (or 1 s).
    func waitIdle() {
        idle.lock()
        defer { idle.unlock() }
        var avail: Int32 = 0
        let deadline = Date().addingTimeInterval(1)
        while busy || (ioctl(readFD, StderrTap.fionread, &avail) == 0 && avail > 0) {
            if !idle.wait(until: deadline) { break }
        }
    }

    /// Restore fd 2 and let the reader finish the pipe (other holders of the write end, e.g. a
    /// helper still running, cap the wait at `timeout`).
    func drain(timeout: TimeInterval) {
        guard dup2(original, STDERR_FILENO) >= 0 else { return }
        _ = done.wait(timeout: .now() + timeout)
    }
}

/// How the VM process ended (Supervisor.spawnAndWait reads the details from the zombie before it
/// reaps it).
struct VMExit {
    /// Exit status, or 128 + the signal that killed it.
    var status: Int32
    /// kevent NOTE_EXIT_DETAIL bits, nil when the exit was not observed.
    var detail: UInt32?
    /// Lifetime peak phys_footprint, bytes (a zombie's current footprint is already 0).
    var peakFootprint: UInt64?

    var signal: Int32 { status > 128 ? status - 128 : 0 }
    /// The kernel's memorystatus (jetsam) killed it.
    var killedForMemory: Bool { (detail ?? 0) & UInt32(NOTE_EXIT_MEMORY) != 0 }

    /// phys_footprint and its lifetime peak of a running or zombie process, bytes.
    static func footprint(pid: pid_t) -> (current: UInt64, peak: UInt64)? {
        var ri = rusage_info_v4()
        let rc = withUnsafeMutablePointer(to: &ri) {
            $0.withMemoryRebound(to: rusage_info_t?.self, capacity: 1) { proc_pid_rusage(pid, RUSAGE_INFO_V4, $0) }
        }
        return rc == 0 ? (ri.ri_phys_footprint, ri.ri_lifetime_max_phys_footprint) : nil
    }
}

extension CrashReporting {
    static func gib(_ bytes: UInt64) -> String {
        bytes < 1 << 30 ? "\(bytes >> 20) MiB" : String(format: "%.1f GiB", Double(bytes) / 1_073_741_824)
    }

    /// The host's memory right now (vm_stat numbers, swap, the kernel's pressure level).
    struct HostMemory {
        /// normal / warning / critical (kern.memorystatus_vm_pressure_level).
        var pressure: String
        /// kern.memorystatus_level: memory available to apps, percent.
        var availablePercent: Int?
        var summary: String

        static func pressureLevel() -> String {
            switch sysctlInt("kern.memorystatus_vm_pressure_level") {
            case 1: return "normal"
            case 2: return "warning"
            case 4: return "critical"
            default: return "unknown"
            }
        }

        static func current() -> HostMemory {
            let pressure = pressureLevel()
            let available = sysctlInt("kern.memorystatus_level")
            var parts = ["host: \(gib(ProcessInfo.processInfo.physicalMemory)) RAM"]
            var vm = vm_statistics64()
            var count = mach_msg_type_number_t(MemoryLayout<vm_statistics64>.size / MemoryLayout<integer_t>.size)
            let kr = withUnsafeMutablePointer(to: &vm) {
                $0.withMemoryRebound(to: integer_t.self, capacity: Int(count)) { host_statistics64(mach_host_self(), HOST_VM_INFO64, $0, &count) }
            }
            if kr == KERN_SUCCESS {
                let page = UInt64(vm_kernel_page_size)
                parts.append("free \(gib(UInt64(vm.free_count) * page))")
                parts.append("active \(gib(UInt64(vm.active_count) * page))")
                parts.append("inactive \(gib(UInt64(vm.inactive_count) * page))")
                parts.append("wired \(gib(UInt64(vm.wire_count) * page))")
                parts.append("compressed \(gib(UInt64(vm.compressor_page_count) * page))")
            }
            var swap = xsw_usage()
            var size = MemoryLayout<xsw_usage>.size
            if sysctlbyname("vm.swapusage", &swap, &size, nil, 0) == 0 {
                parts.append("swap used \(gib(swap.xsu_used)) of \(gib(swap.xsu_total))")
            }
            parts.append("available \(available.map { "\($0) %" } ?? "?")")
            parts.append("pressure \(pressure)")
            return HostMemory(pressure: pressure, availablePercent: available, summary: parts.joined(separator: ", "))
        }

        private static func sysctlInt(_ name: String) -> Int? {
            var value: Int32 = 0
            var size = MemoryLayout<Int32>.size
            return sysctlbyname(name, &value, &size, nil, 0) == 0 ? Int(value) : nil
        }
    }
}

/// Supervisor: the host's memory pressure changes (DispatchSource) while a VM process runs,
/// with that process's footprint at each, for "VM process killed" reports; each change is
/// also logged (launcher log, breadcrumbs).
private final class MemoryWatch: @unchecked Sendable {
    private let lock = NSLock()
    private var source: DispatchSourceMemoryPressure?
    private var started = Date()
    private var events: [(at: Date, level: String, footprint: UInt64?)] = []

    func start() {
        guard source == nil else { return }
        let s = DispatchSource.makeMemoryPressureSource(eventMask: [.normal, .warning, .critical], queue: .global(qos: .utility))
        s.setEventHandler { [weak self, weak s] in
            guard let e = s?.data else { return }
            self?.record(e.contains(.critical) ? "critical" : e.contains(.warning) ? "warning" : "normal")
        }
        s.resume()
        source = s
    }

    /// A new VM process: the history starts with the current level.
    func reset() {
        let level = CrashReporting.HostMemory.pressureLevel()
        lock.withLock {
            started = Date()
            events = [(started, level, nil)]
        }
    }

    private func record(_ level: String) {
        let pid = Supervisor.vmPid
        let footprint = pid > 0 ? VMExit.footprint(pid: pid)?.current : nil
        lock.withLock {
            events.append((Date(), level, footprint))
            if events.count > 24 { events.removeSubrange(1..<(events.count - 23)) }   // keep the start
        }
        log("memory pressure: \(level)" + (footprint.map { " (VM process footprint \(CrashReporting.gib($0)))" } ?? ""))
    }

    /// "normal at start; warning 5m12s ago (VM 14.2 GiB); critical 40s ago (VM 15.1 GiB)" and the
    /// highest level seen.
    func summary() -> (text: String, maxLevel: String) {
        let rank = ["normal": 1, "warning": 2, "critical": 3]
        return lock.withLock {
            let now = Date()
            var max = "unknown"
            var parts: [String] = []
            for (i, e) in events.enumerated() {
                if rank[e.level, default: 0] > rank[max, default: 0] { max = e.level }
                let age = Int(now.timeIntervalSince(e.at))
                let when = i == 0 ? "at start (\(age / 60)m\(age % 60)s ago)" : "\(age / 60)m\(age % 60)s ago"
                parts.append("\(e.level) \(when)" + (e.footprint.map { " (VM \(CrashReporting.gib($0)))" } ?? ""))
            }
            return (parts.isEmpty ? "not watched" : parts.joined(separator: "; "), max)
        }
    }
}

/// `--sentry-test-crash MODE` (VM process): crash inside C / Metal / libkrun code, die by a signal
/// (kill: SIGKILL, term: SIGTERM, no report), (shader) log a MoltenVK shader compile failure
/// with its MSL source and vkr's pipeline line, or (gpu-teardown) log STEAMAC-G's guest process
/// teardown, wait past the supervisor's pause flush, then log an out-of-memory device loss: the
/// teardown must stay breadcrumbs, the device loss is the run's only report. Then exit normally.
private enum TestCrash {
    static func run(_ mode: String) -> Never {
        switch mode {
        case "kill":
            kill(getpid(), SIGKILL)
        case "term":
            signal(SIGTERM, SIG_DFL)
            kill(getpid(), SIGTERM)
            Thread.sleep(forTimeInterval: 1)
        case "gpu-teardown":
            func emit(_ lines: [String]) {
                let text = lines.joined(separator: "\n") + "\n"
                text.withCString { _ = write(STDERR_FILENO, $0, strlen($0)) }
            }
            emit(LineScanner.teardownSample)
            Thread.sleep(forTimeInterval: 4.5)   // past the 3 s pause after which open messages are reported
            emit([LineScanner.fatalSample[0] + " (sentry test)"])
            Thread.sleep(forTimeInterval: 0.5)
            exit(0)
        case "shader":
            let source = (1...60).map { "[mvk-msl] // sentry test MSL line \($0)" }
                + ["[mvk-msl] ... (60 lines total)", "[mvk-msl] 12: // sentry test MSL line 12"]
            let text = """
                [mvk-error] VK_ERROR_INITIALIZATION_FAILED: Shader library compile failed (Error code 3):
                program_source:12:66: error: member reference base type 'void' is not a structure or union (sentry test)
                                        spvDescriptorSet0.u0.atomic_store(3u, 0u).x;
                                        ~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~^~
                .
                \(source.joined(separator: "\n"))
                [2026-01-01T00:00:00.000000Z WARN  krun_rutabaga_gfx::virgl_renderer] virglrenderer: vkr: pipeline 1 creation failed on host; draws using it will be skipped

                """
            text.withCString { _ = write(STDERR_FILENO, $0, strlen($0)) }
            Thread.sleep(forTimeInterval: 0.5)
            exit(0)
        case "segv":
            // EXC_BAD_ACCESS inside libsystem's memset.
            memset(UnsafeMutableRawPointer(bitPattern: 16), 0, 64)
        case "metal":
            // Metal API assertion (MTL_DEBUG_LAYER set before the device was created): an encoder
            // released without endEncoding.
            if let dev = MTLCreateSystemDefaultDevice(), let q = dev.makeCommandQueue(), let cb = q.makeCommandBuffer() {
                _ = cb.makeComputeCommandEncoder()
                cb.commit()
            }
        default:
            // abort() from a callback inside a C library call (qsort).
            var values: [Int32] = [3, 1, 2]
            qsort(&values, values.count, MemoryLayout<Int32>.size) { _, _ in abort() }
        }
        abort()
    }
}
