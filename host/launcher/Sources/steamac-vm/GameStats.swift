import AppKit
import Foundation
import IOKit
import QuartzCore
import Synchronization
import os

/// Game statistics: how each Steam game runs in this VM on this Mac, so everyone can see which
/// games start and how fast they run on which Mac (the public page docs/games.html).
///
/// GameSessionTracker (VM process, main thread) turns the guest agent's game lifecycle
/// (`game-start` / `game-mem` / `game-proton` / `game-gfx` / `game-exit`, games.rs), its focus lines
/// and the guest's scanout flushes (FrameMeter) into one GameSessionReport per game run: how long
/// it ran and had focus, whether a window ever appeared, frame rate, memory peaks, the graphics
/// configuration and the Mac's chip and memory. GameStatsStore keeps every report on this Mac
/// (Settings > Games lists them, with the player's optional rating and a per-game sharing switch) and, only while
/// Settings `shareGameStats` is on, uploads them to the statistics service (Cloudflare Worker,
/// services/game-stats). Never sent: names, Steam account, IP address (the service does not
/// store it), files, or text other than sanitized graphics launch settings.

// MARK: - reports (schema v2; persisted v1 sessions remain readable, services/game-stats)

/// The player's own verdict on a game (Settings > Games), optional.
enum GameRating: String, Codable, CaseIterable, Identifiable {
    case well, issues, unplayable, noStart = "no_start"

    var id: String { rawValue }

    var title: String {
        switch self {
        case .well: return String(localized: "Runs well", comment: "Game rating")
        case .issues: return String(localized: "Playable with issues", comment: "Game rating")
        case .unplayable: return String(localized: "Starts, but unplayable", comment: "Game rating")
        case .noStart: return String(localized: "Does not start", comment: "Game rating")
        }
    }
}

/// The Mac a report comes from.
struct GameStatsMac: Codable, Equatable {
    var model: String
    var chip: String
    var pcores: Int?
    var cores: Int
    var gpuCores: Int?
    var ramGB: Int
    var macos: String

    enum CodingKeys: String, CodingKey {
        case model, chip, pcores, cores, gpuCores = "gpu_cores", ramGB = "ram_gb", macos
    }

    static let current: GameStatsMac = {
        let v = ProcessInfo.processInfo.operatingSystemVersion
        let host = VMSizing.Host.current
        return GameStatsMac(model: ReportBundle.sysctl("hw.model") ?? "unknown",
                            chip: ReportBundle.sysctl("machdep.cpu.brand_string") ?? "unknown",
                            pcores: host.perfCores, cores: host.cores, gpuCores: gpuCoreCount(),
                            ramGB: host.memGiB, macos: "\(v.majorVersion).\(v.minorVersion)")
    }()

    /// GPU cores of the Apple GPU (AGXAccelerator's `gpu-core-count`), nil when not published.
    private static func gpuCoreCount() -> Int? {
        let service = IOServiceGetMatchingService(kIOMainPortDefault, IOServiceMatching("AGXAccelerator"))
        guard service != 0 else { return nil }
        defer { IOObjectRelease(service) }
        let value = IORegistryEntryCreateCFProperty(service, "gpu-core-count" as CFString, kCFAllocatorDefault, 0)?
            .takeRetainedValue()
        return (value as? NSNumber)?.intValue
    }
}

/// The VM a report comes from. Ratings carry only `driver` and `wmtr`.
struct GameStatsVM: Codable, Equatable {
    var cpus: Int?
    var memMiB: Int?
    /// LauncherSettings.VulkanDriver raw value.
    var driver: String
    /// The experimental wmtr context type was offered to the guest.
    var wmtr: Bool
    /// Guest display refresh rate: the frame-rate cap.
    var hz: Int?
    var steamos: String?

    enum CodingKeys: String, CodingKey { case cpus, memMiB = "mem_mib", driver, wmtr, hz, steamos }
}

/// One game run: POST /v1/sessions.
struct GameSessionReport: Codable, Equatable {
    struct FPS: Codable, Equatable {
        var avg: Double
        var p50: Double
        var low1: Double
        var hitchesPerMin: Double

        enum CodingKeys: String, CodingKey { case avg, p50, low1, hitchesPerMin = "hitches_per_min" }
    }

    struct Memory: Codable, Equatable {
        var gameMiB: Int?
        var guestMiB: Int?
        var hostMiB: Int?

        enum CodingKeys: String, CodingKey { case gameMiB = "game_mib", guestMiB = "guest_mib", hostMiB = "host_mib" }
    }

    /// How a session ended.
    enum End: String, Codable {
        /// The game's last scope is gone (`game-exit`).
        case exit
        /// The VM shut down while it ran.
        case shutdown
        /// The gamescope session ended (Switch to Desktop, relogin).
        case session
        /// Another game took the focus and this one never reported its start/exit (an agent
        /// without game lifecycle lines).
        case replaced
    }

    var v = 2
    var sid: String
    var install: String
    var launcher: String
    var appid: Int
    var game: String?
    var mac: GameStatsMac
    var vm: GameStatsVM
    /// Actual graphics path reported by the guest, nil for an older agent.
    var gfx: String?
    /// Sanitized profile environment captured when this session started; nil when empty.
    var env: String?
    /// A window of the game had the guest's focus at least once.
    var launched: Bool
    var end: End
    var runS: Int
    var playS: Int
    var firstWindowS: Int?
    var proton: String?
    var res: String?
    var fps: FPS?
    var mem: Memory?

    enum CodingKeys: String, CodingKey {
        case v, sid, install, launcher, appid, game, mac, vm, gfx, env, launched, end, runS = "run_s", playS = "play_s",
             firstWindowS = "first_window_s", proton, res, fps, mem
    }
}

/// The player's rating of a game: POST /v1/ratings (`none` clears it on the service).
struct GameRatingReport: Encodable {
    var v = 2
    var install: String
    var launcher: String
    var appid: Int
    var game: String?
    var rating: String
    var mac: GameStatsMac
    var vm: GameStatsVM
    var gfx: String?
    var env: String?
}

// MARK: - frame meter

/// Guest scanout flush intervals while a game has focus: 0.25 ms buckets up to 1 s (longer gaps
/// are loading screens, menus without redraws or pauses and are left out).
struct FrameHistogram: Equatable {
    static let bucketMs = 0.25
    static let buckets = 4000
    /// Intervals over this are hitches (more than 3 frames at 60 Hz).
    static let hitchMs = 50.0
    /// Fewer intervals than this say nothing about the frame rate.
    static let minIntervals = 100

    private(set) var counts: [UInt32] = []
    private(set) var intervals = 0
    private(set) var sumMs = 0.0
    private(set) var hitches = 0

    mutating func add(ms: Double) {
        guard ms >= 0, ms <= Double(FrameHistogram.buckets) * FrameHistogram.bucketMs else { return }
        if counts.isEmpty { counts = [UInt32](repeating: 0, count: FrameHistogram.buckets) }
        counts[min(FrameHistogram.buckets - 1, Int(ms / FrameHistogram.bucketMs))] += 1
        intervals += 1
        sumMs += ms
        if ms > FrameHistogram.hitchMs { hitches += 1 }
    }

    mutating func merge(_ other: FrameHistogram) {
        guard other.intervals > 0 else { return }
        if counts.isEmpty { counts = [UInt32](repeating: 0, count: FrameHistogram.buckets) }
        for i in 0..<FrameHistogram.buckets where other.counts[i] > 0 { counts[i] += other.counts[i] }
        intervals += other.intervals
        sumMs += other.sumMs
        hitches += other.hitches
    }

    /// The interval (ms, bucket middle) that `p` percent of the intervals do not exceed.
    func percentile(_ p: Double) -> Double {
        guard intervals > 0 else { return 0 }
        let rank = max(1, Int((Double(intervals) * p / 100).rounded(.up)))
        var seen = 0
        for (i, c) in counts.enumerated() where c > 0 {
            seen += Int(c)
            if seen >= rank { return (Double(i) + 0.5) * FrameHistogram.bucketMs }
        }
        return (Double(FrameHistogram.buckets) - 0.5) * FrameHistogram.bucketMs
    }

    var fps: GameSessionReport.FPS? {
        guard intervals >= FrameHistogram.minIntervals, sumMs > 0 else { return nil }
        func r(_ v: Double) -> Double { (v * 10).rounded() / 10 }
        return GameSessionReport.FPS(avg: r(Double(intervals) * 1000 / sumMs), p50: r(1000 / percentile(50)),
                                     low1: r(1000 / percentile(99)), hitchesPerMin: r(Double(hitches) * 60_000 / sumMs))
    }
}

/// Counts guest flushes of scanout 0 (libkrun present_frame, GPU worker thread) while a game is
/// active (GameSessionTracker). Off: one relaxed atomic load per flush.
final class FrameMeter: @unchecked Sendable {
    static let shared = FrameMeter()
    private static let active = Atomic<Bool>(false)

    private var lock = os_unfair_lock()
    private var histogram = FrameHistogram()
    private var last: CFTimeInterval = 0
    // DXMT (wmtr) games present on their own Metal layer, not through scanout 0, so their frames are
    // counted apart; scanout keeps flushing the Steam UI underneath at its own rate.
    private var wmtrHistogram = FrameHistogram()
    private var wmtrLast: CFTimeInterval = 0
    // Rolling 30 s window of DXMT frames, logged live so a session can be watched while it runs.
    private var windowHistogram = FrameHistogram()
    private var windowStart: CFTimeInterval = 0
    private var windowMaxMs = 0.0
    private static let clock: DateFormatter = { let f = DateFormatter(); f.dateFormat = "HH:mm:ss.SSS"; return f }()

    /// GPU worker thread: the guest flushed scanout 0.
    static func flushed() {
        guard active.load(ordering: .relaxed) else { return }
        shared.record(CACurrentMediaTime())
    }

    /// wmtr frame reader: a DXMT frame finished presenting at `seconds` (mach uptime, CACurrentMediaTime's clock).
    static func wmtrPresented(at seconds: CFTimeInterval) {
        guard active.load(ordering: .relaxed) else { return }
        shared.recordWmtr(seconds)
    }

    private func record(_ now: CFTimeInterval) {
        os_unfair_lock_lock(&lock)
        if last > 0 { histogram.add(ms: (now - last) * 1000) }
        last = now
        os_unfair_lock_unlock(&lock)
    }

    private func recordWmtr(_ now: CFTimeInterval) {
        os_unfair_lock_lock(&lock)
        var line: String?
        var long: String?
        if wmtrLast > 0, now > wmtrLast {
            let ms = (now - wmtrLast) * 1000
            wmtrHistogram.add(ms: ms)
            windowHistogram.add(ms: ms)
            windowMaxMs = max(windowMaxMs, ms)
            // Long frames with their wall-clock time, to line them up with other logs (pauses over 2 s are menus/loads).
            if ms > 150, ms < 2000 { long = String(format: "game frames: long frame %.0f ms ending at %@", ms, FrameMeter.clock.string(from: Date())) }
        }
        wmtrLast = now
        if windowStart == 0 { windowStart = now }
        if now - windowStart >= 30 {
            if let f = windowHistogram.fps {
                line = String(format: "game frames: %.0f s %.1f FPS avg, p50 %.1f, 1%% low %.1f, hitches>50ms %d, longest %.0f ms",
                              now - windowStart, f.avg, f.p50, f.low1, windowHistogram.hitches, windowMaxMs)
            }
            windowHistogram = FrameHistogram()
            windowStart = now
            windowMaxMs = 0
        }
        os_unfair_lock_unlock(&lock)
        if let long { log(long) }
        if let line { log(line) }
    }

    /// Main thread: start / stop counting; returns what was counted since the last call (the
    /// interval across a stop and the next start is never counted). A span with enough DXMT frames
    /// reports those; otherwise the scanout flushes.
    func set(active on: Bool) -> FrameHistogram {
        FrameMeter.active.store(on, ordering: .relaxed)
        os_unfair_lock_lock(&lock)
        defer { os_unfair_lock_unlock(&lock) }
        let taken = wmtrHistogram.intervals >= FrameHistogram.minIntervals ? wmtrHistogram : histogram
        histogram = FrameHistogram()
        wmtrHistogram = FrameHistogram()
        windowHistogram = FrameHistogram()
        windowStart = 0
        windowMaxMs = 0
        last = 0
        wmtrLast = 0
        return taken
    }
}

/// Reads wmtr's per-frame export (WMTR_FRAMES, one `t_ns,...` line per presented DXMT frame) from a
/// FIFO this process owns and feeds FrameMeter. Not started when WMTR_FRAMES is already set (a
/// developer's own capture file wins).
enum WmtrFrameFeed {
    private static var source: DispatchSourceRead?
    private static var pending = Data()

    static func start() {
        guard source == nil, getenv("WMTR_FRAMES") == nil else { return }
        let path = NSTemporaryDirectory() + "steamac-wmtr-frames-\(getpid())"
        unlink(path)
        guard mkfifo(path, 0o600) == 0 else { return }
        // Read end first and non-blocking, so wmtr's fopen(path, "a") never waits for a reader.
        let fd = open(path, O_RDONLY | O_NONBLOCK)
        guard fd >= 0 else { unlink(path); return }
        // A write end held here keeps the FIFO from reporting EOF between wmtr clients.
        let keep = open(path, O_WRONLY | O_NONBLOCK)
        let s = DispatchSource.makeReadSource(fileDescriptor: fd, queue: DispatchQueue(label: "wmtr-frames", qos: .userInitiated))
        s.setEventHandler {
            var buf = [UInt8](repeating: 0, count: 16384)
            while true {
                let n = read(fd, &buf, buf.count)
                if n <= 0 { break }
                pending.append(contentsOf: buf[0..<n])
            }
            while let nl = pending.firstIndex(of: UInt8(ascii: "\n")) {
                let line = pending[pending.startIndex..<nl]
                pending.removeSubrange(pending.startIndex...nl)
                if let t = WmtrFrameFeed.timestamp(line) { FrameMeter.wmtrPresented(at: t) }
            }
        }
        s.setCancelHandler { close(fd); if keep >= 0 { close(keep) }; unlink(path) }
        s.resume()
        source = s
        setenv("WMTR_FRAMES", path, 1)
    }

    /// Seconds from a `t_ns,0,0,0,0,0` line (wmtr writes one per completed present); nil for anything else.
    static func timestamp<S: Sequence>(_ line: S) -> CFTimeInterval? where S.Element == UInt8 {
        var ns: UInt64 = 0
        var digits = 0
        for c in line {
            if c == UInt8(ascii: ",") { break }
            guard c >= 48, c <= 57 else { return nil }
            ns = ns &* 10 &+ UInt64(c - 48)
            digits += 1
        }
        return digits > 0 ? CFTimeInterval(ns) / 1e9 : nil
    }
}

// MARK: - tracker

/// One GameSessionReport per game run (VM process, main thread). A session starts with
/// `game-start` (Steam launched the game) or, failing that, the game's first focus; it ends with
/// `game-exit`, the end of the gamescope session or the VM's shutdown. Play time, frames and the
/// window resolution count only while the game has focus and is neither paused (GamePause) nor
/// suspended with the VM.
final class GameSessionTracker {
    private struct Live {
        let appid: Int
        let sid = UUID().uuidString
        let started = Date()
        /// Opened by `game-start` (else by the first focus).
        var fromGameStart: Bool
        let env: String?
        var firstWindow: Date?
        var playS = 0.0
        var proton: String?
        var gfx: String?
        var res: String?
        var frames = FrameHistogram()
        var anonPeakKiB = 0
        var guestPeakKiB = 0
        var hostPeak: UInt64 = 0

        init(appid: Int, fromGameStart: Bool) {
            self.appid = appid
            self.fromGameStart = fromGameStart
            let env = GameProfile.sanitizedEnv(LauncherSettings.shared.profile(for: appid).env)
            self.env = env.isEmpty ? nil : env
        }
    }

    /// The SteamOS build the initramfs announced on hvc0 (`steamac-init: rootfs-… BUILD_ID=…`).
    nonisolated(unsafe) static var steamosBuild: String?

    /// Main thread: an hvc0 console line.
    static func consoleLine(_ raw: String) {
        guard let r = raw.range(of: "steamac-init: rootfs-"),
              let b = raw.range(of: "BUILD_ID=", range: r.upperBound..<raw.endIndex) else { return }
        let id = raw[b.upperBound...].prefix { !$0.isWhitespace }
        if !id.isEmpty { steamosBuild = String(id) }
    }

    private let options: Options
    private let store: GameStatsStore
    private let vmWindow: () -> NSWindow?
    private var live: [Int: Live] = [:]
    private var focused: Int?
    private var frozen: Int?
    /// The game frames and play time are counted for, and since when (CACurrentMediaTime).
    private var activeGame: Int?
    private var activeSince: CFTimeInterval = 0
    /// The whole VM is paused (suspend, guest sleep).
    var vmPaused = false { didSet { if vmPaused != oldValue { updateActivity() } } }

    init(options: Options, progress: BootProgress, store: GameStatsStore = .shared, vmWindow: @escaping () -> NSWindow?) {
        self.options = options
        self.store = store
        self.vmWindow = vmWindow
        let previousFocus = progress.onFocus
        progress.onFocus = { [weak self] f in previousFocus?(f); self?.focus(f) }
        let previousSurface = progress.onFocusSurface
        progress.onFocusSurface = { [weak self] s in previousSurface?(s); self?.surface(s) }
        let previousEvent = progress.onGameEvent
        progress.onGameEvent = { [weak self] e in previousEvent?(e); self?.event(e) }
        let previousShutdown = progress.onShutdown
        progress.onShutdown = { [weak self] reboot in previousShutdown?(reboot); self?.endAll(.shutdown) }
        let previousReady = progress.onReady
        progress.onReady = { [weak self] in previousReady?(); self?.store.flush() }
    }

    /// GamePause: the game the guest confirmed frozen (nil = running).
    func gamePaused(_ appid: Int?) {
        frozen = appid
        updateActivity()
    }

    private func focus(_ f: GuestFocus) {
        switch f {
        case .game(let id) where GameSessionTracker.isSteamApp(id):
            // An agent without lifecycle lines: a game focused after another one replaced it.
            if let previous = focused, previous != id, live[previous]?.fromGameStart == false {
                end(previous, .replaced)
            }
            if live[id] == nil {
                live[id] = Live(appid: id, fromGameStart: false)
                log("game stats: \(id) started (first focus)")
            }
            if live[id]?.firstWindow == nil { live[id]?.firstWindow = Date() }
            focused = id
        case .sessionEnded:
            focused = nil
            endAll(.session)
        default:
            focused = nil
        }
        updateActivity()
    }

    private func surface(_ size: (Int, Int)?) {
        guard let id = focused, let (w, h) = size, w > 0, h > 0 else { return }
        live[id]?.res = "\(w)x\(h)"
    }

    /// Steam app ids. Non-Steam shortcuts added to the library get ids with the top bit set,
    /// meaningful only on this Mac: they are not tracked.
    static func isSteamApp(_ id: Int) -> Bool { id > 0 && id <= Int(Int32.max) }

    private func event(_ e: GuestGameEvent) {
        guard GameSessionTracker.isSteamApp(e.appid) else { return }
        switch e {
        case .start(let id):
            if live[id] == nil {
                live[id] = Live(appid: id, fromGameStart: true)
                log("game stats: \(id) started")
            } else {
                live[id]?.fromGameStart = true
            }
        case .memory(let id, let anon, let used):
            guard var s = live[id] else { return }
            s.anonPeakKiB = max(s.anonPeakKiB, anon)
            s.guestPeakKiB = max(s.guestPeakKiB, used)
            if let fp = SuspendController.footprint() { s.hostPeak = max(s.hostPeak, fp) }
            live[id] = s
        case .proton(let id, let version):
            live[id]?.proton = String(version.prefix(64))
        case .gfx(let id, let gfx):
            live[id]?.gfx = gfx
        case .exit(let id):
            end(id, .exit)
        }
    }

    private func updateActivity() {
        let now = CACurrentMediaTime()
        let want = focused.flatMap { id in id != frozen && !vmPaused && live[id] != nil ? id : nil }
        guard want != activeGame else { return }
        let counted = FrameMeter.shared.set(active: want != nil)
        if let id = activeGame, live[id] != nil {
            live[id]?.frames.merge(counted)
            live[id]?.playS += now - activeSince
        }
        activeGame = want
        activeSince = now
    }

    private func endAll(_ how: GameSessionReport.End) {
        for id in live.keys.sorted() { end(id, how) }
    }

    private func end(_ id: Int, _ how: GameSessionReport.End) {
        // Close the counting period first (activeGame == id only while it is focused).
        if focused == id { focused = nil }
        updateActivity()
        guard let s = live.removeValue(forKey: id) else { return }
        let report = makeReport(s, end: how)
        log("game stats: \(id) ended (\(how.rawValue)): ran \(report.runS) s, played \(report.playS) s, "
            + "window \(report.launched ? "yes" : "no")"
            + (report.fps.map { String(format: ", %.1f FPS avg, 1%% low %.1f", $0.avg, $0.low1) } ?? "")
            + (report.mem?.hostMiB.map { ", host peak \($0) MiB" } ?? ""))
        store.record(report)
        // Offer sharing once, after a game the player saw (never while the VM shuts down).
        if how != .shutdown && report.launched { store.offerSharingIfNeeded(beside: vmWindow()) }
    }

    private func makeReport(_ s: Live, end: GameSessionReport.End) -> GameSessionReport {
        let mib = { (kib: Int) -> Int? in kib > 0 ? (kib + 512) / 1024 : nil }
        let host = s.hostPeak > 0 ? Int((s.hostPeak + (1 << 19)) >> 20) : nil
        let mem = GameSessionReport.Memory(gameMiB: mib(s.anonPeakKiB), guestMiB: mib(s.guestPeakKiB), hostMiB: host)
        let firstWindow = s.fromGameStart ? s.firstWindow.map { Int($0.timeIntervalSince(s.started).rounded()) } : nil
        return GameSessionReport(
            sid: s.sid, install: store.install, launcher: GameStatsStore.launcherVersion, appid: s.appid,
            game: LauncherSettings.shared.gameName(s.appid), mac: .current,
            vm: GameStatsVM(cpus: options.cpus, memMiB: options.memMiB, driver: options.vulkanDriver.rawValue,
                            wmtr: options.wmtrLibrary != nil, hz: options.refreshRate, steamos: GameSessionTracker.steamosBuild),
            gfx: s.gfx, env: s.env,
            launched: s.firstWindow != nil, end: end, runS: max(0, Int(Date().timeIntervalSince(s.started).rounded())),
            playS: Int(s.playS.rounded()), firstWindowS: firstWindow, proton: s.proton, res: s.res, fps: s.frames.fps,
            mem: mem.gameMiB == nil && mem.guestMiB == nil && mem.hostMiB == nil ? nil : mem)
    }

    /// Control FIFO `stats state`.
    func describe() -> String {
        live.values.sorted { $0.appid < $1.appid }.map { s in
            "\(s.appid)\(s.appid == activeGame ? " (active)" : "")\(s.appid == focused ? " (focused)" : ""): "
                + "\(Int(Date().timeIntervalSince(s.started))) s, \(s.frames.intervals) intervals counted, "
                + "window \(s.firstWindow != nil ? "yes" : "no"), anon peak \(s.anonPeakKiB) KiB"
        }.joined(separator: "; ")
    }
}
