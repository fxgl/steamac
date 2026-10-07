import AppKit
import Combine
import Foundation

/// The launcher's preferences (Settings window), persisted in the defaults domain
/// `es.fxgam.steamac` (~/Library/Preferences/es.fxgam.steamac.plist; STEAMAC_DEFAULTS_DOMAIN
/// overrides it, for tests). Command-line flags override "next start" values for one run without
/// persisting them (`overrides`). Live ("applies now") values are observed through the
/// `@Published` publishers by the window, the gamepad bridge, the sound control and PerfStats.
final class LauncherSettings: ObservableObject {
    /// This process's settings (the VM process's window, gamepad, sound and Settings window share it).
    static let shared = LauncherSettings()
    static let defaultDomain = "es.fxgam.steamac"
    /// Domain used before the bundle id change; copied once into the domain if that is still empty.
    static let legacyDomain = "dev.steamac.vm"
    static var domain: String {
        ProcessInfo.processInfo.environment["STEAMAC_DEFAULTS_DOMAIN"].flatMap { $0.isEmpty ? nil : $0 } ?? defaultDomain
    }

    /// Preference keys. `nextStart` keys are read once per boot (see Options.applySettings).
    enum Key: String, CaseIterable {
        // General
        case showOverlay, showStallIndicator, openFullscreen, perfStats, sendCrashReports, muteInBackground, pauseInBackground,
             closeAction, checkForUpdates, followMacTime, shareClipboard, shareConcealedClipboard
        // Display
        case dpiSource, fixedDPI, fixedWidthMM, fixedHeightMM, refreshRate, followWindowSize, windowWidth, windowHeight,
             windowSizePreset, retinaResolution, metalHUD, superResolution
        // Mouse
        case autoCaptureGames, gameNames
        // Controller
        case virtualPad, padType, dualSensePassthrough, controllerID, swapABXY, stickDeadzone
        // Sound
        case soundEnabled, soundOutputUID, soundVolume, soundMute, soundLatency
        // Advanced
        case cpus, memMiB, sshEnabled, sshPort, network, lanRemotePlay, diskImage, steamosBranch, steamClient, vulkanDriver

        var nextStart: Bool {
            switch self {
            case .openFullscreen, .dpiSource, .fixedDPI, .fixedWidthMM, .fixedHeightMM, .refreshRate,
                 .windowWidth, .windowHeight, .windowSizePreset, .retinaResolution, .soundEnabled, .cpus, .memMiB, .sshEnabled,
                 .sshPort, .network, .lanRemotePlay,
                 .diskImage, .steamClient, .followMacTime, .vulkanDriver:
                return true
            default:
                return false
            }
        }
    }

    enum DPISource: String, CaseIterable, Identifiable {
        case auto, dpi, mm
        var id: String { rawValue }
    }

    enum Latency: String, CaseIterable, Identifiable {
        case low, normal, safe
        var id: String { rawValue }
        /// Host playback buffer for krun_snd_set_buffer_ms.
        var bufferMs: UInt32 {
            switch self {
            case .low: return 10
            case .normal: return 20
            case .safe: return 60
            }
        }
    }

    /// What closing the VM window does (Settings > General).
    enum CloseAction: String, CaseIterable, Identifiable {
        /// Shut SteamOS down (guest power key).
        case shutDown = "shutdown"
        /// Suspend the VM in memory (SuspendController); the app keeps running.
        case suspend
        var id: String { rawValue }
    }

    /// Which gamepad SteamOS sees (GuestPad; the guest's pad is created over fx.pad and can
    /// change while the VM runs; Settings > Controller).
    enum PadType: String, CaseIterable, Identifiable {
        /// The same kind as the controller that drives it: DualSense, DualShock 4, else Xbox 360.
        case auto
        case xbox360
        case dualSense = "dualsense"
        case dualShock4 = "dualshock4"
        var id: String { rawValue }
    }

    /// Steam client SteamOS starts (kernel cmdline `steamac.steam_client=`, read by the layer's
    /// /usr/lib/steamac/steam-client on every Steam start).
    enum SteamClient: String, CaseIterable, Identifiable {
        /// Public ARM64 Steam Deck client (branch steamdeck_stable). Default.
        case deck
        /// Steam Deck client beta (branch steamdeck_publicbeta).
        case deckbeta
        /// Valve's Steam Frame client beta with -deckard -vrgamepadui (stock); the Steam Deck
        /// client is used for sign-in until an account is remembered (sign-in mode).
        case frame
        var id: String { rawValue }

        var title: String {
            switch self {
            case .frame: return "Steam Frame client"
            case .deck: return "Steam Deck client"
            case .deckbeta: return "Steam Deck client (beta)"
            }
        }

        var detail: String {
            switch self {
            case .frame:
                return "Valve's ARM64 client for Steam Frame (a beta for a headset not yet released). "
                    + "Until an account is signed in with Remember me, the Steam Deck client shows the sign-in QR code."
            case .deck:
                return "The public ARM64 Steam Deck client (steamdeck_stable). Standard sign-in with an on-screen QR code."
            case .deckbeta:
                return "The Steam Deck client beta (steamdeck_publicbeta). Standard sign-in with an on-screen QR code."
            }
        }

        /// Switching re-downloads the client (about 1 GB) on the next start.
        static let switchNote = "Switching downloads the other client (about 1 GB) when Steam starts."
    }

    /// Host Vulkan driver behind Venus: virglrenderer, in the VM process, opens its dylib
    /// (VKR_VULKAN_DRIVER, set by VM.start).
    enum VulkanDriver: String, CaseIterable, Identifiable {
        /// MoltenVK with steamac's patches (host/moltenvk): every supported Mac; the default without KosmicKrisp.
        case moltenvk
        /// KosmicKrisp, Mesa's driver on Metal 4 (host/kosmickrisp): macOS 26 or newer, the default there.
        case kosmickrisp
        var id: String { rawValue }

        /// Short name (boot overlay, logs, reports).
        var name: String {
            switch self {
            case .moltenvk: return "MoltenVK"
            case .kosmickrisp: return "KosmicKrisp"
            }
        }

        /// Main features and the oldest macOS it runs on (picker items).
        var summary: String {
            switch self {
            case .moltenvk: return "Metal 3 · macOS 15+"
            case .kosmickrisp: return "Metal 4 · macOS 26+"
            }
        }

        var title: String { name + " · " + summary }

        var detail: String {
            let text: String
            switch self {
            case .moltenvk:
                text = "Vulkan on Metal 3 through MoltenVK with steamac's patches (macOS 15 or newer)."
            case .kosmickrisp:
                text = "Mesa's Vulkan driver on Metal 4 (macOS 26 or newer). Faster than MoltenVK: Stellar Blade Demo "
                    + "runs at ~29 FPS instead of ~18 on an M1 Max."
            }
            return self == Self.preferred ? text + " Default on this Mac." : text
        }

        /// The default: KosmicKrisp where this Mac and build have it, else MoltenVK (fixed for the process).
        static let preferred: VulkanDriver = kosmickrisp.unavailableReason == nil ? .kosmickrisp : .moltenvk

        /// Switching changes the Venus driver identity: Steam and games rebuild their shader caches.
        static let switchNote = "Switching makes Steam and games rebuild their shader caches."

        /// The dylib virglrenderer opens through @rpath (the app's Frameworks, work/out/host/lib).
        var library: String {
            switch self {
            case .moltenvk: return "libMoltenVK.dylib"
            case .kosmickrisp: return "libvulkan_kosmickrisp.dylib"
            }
        }

        /// Why this Mac or this build cannot use the driver; nil if it can.
        var unavailableReason: String? {
            guard self == .kosmickrisp else { return nil }
            let tahoe = OperatingSystemVersion(majorVersion: 26, minorVersion: 0, patchVersion: 0)
            guard ProcessInfo.processInfo.isOperatingSystemAtLeast(tahoe) else { return "needs macOS 26 or newer (Metal 4)" }
            guard let handle = dlopen("@rpath/" + library, RTLD_LAZY | RTLD_LOCAL) else {
                return "not included in this build (\(library))"
            }
            dlclose(handle)
            return nil
        }
    }

    /// Default window size choices (window points = guest pixels).
    struct SizePreset: Identifiable {
        let width: Int, height: Int, label: String
        var id: String { "\(width)x\(height)" }
    }

    static let sizePresets: [SizePreset] = [
        .init(width: 1280, height: 800, label: "Steam Deck, 16:10"), .init(width: 1280, height: 720, label: "16:9"),
        .init(width: 1440, height: 900, label: "16:10"), .init(width: 1600, height: 900, label: "16:9"),
        .init(width: 1680, height: 1050, label: "16:10"), .init(width: 1920, height: 1080, label: "Full HD, 16:9"),
        .init(width: 1920, height: 1200, label: "16:10"), .init(width: 2560, height: 1440, label: "QHD, 16:9"),
        .init(width: 2560, height: 1600, label: "16:10"), .init(width: 3440, height: 1440, label: "21:9"),
        .init(width: 3840, height: 2160, label: "4K, 16:9"),
    ]
    /// `windowSizePreset` values besides "<W>x<H>": the largest size that fits the screen
    /// (re-evaluated at every start) and free W/H.
    static let fitPreset = "fit", customPreset = "custom"

    /// Largest window content size (even, >= the 800x500 minimum) that fits the visible frame of
    /// the screen the VM window opens on (the one under the pointer), below the title bar.
    static func fitToScreenSize() -> (Int, Int) {
        let style: NSWindow.StyleMask = [.titled, .closable, .miniaturizable, .resizable]
        guard let vf = WindowController.targetScreen()?.visibleFrame else { return (1280, 800) }
        let chrome = NSWindow.frameRect(forContentRect: NSRect(x: 0, y: 0, width: 100, height: 100), styleMask: style).height - 100
        let maxSide = VM.maxDisplaySide & ~1
        let w = min(maxSide, max(Int(WindowController.minGuestSize.width), Int(vf.width) & ~1))
        let h = min(maxSide, max(Int(WindowController.minGuestSize.height), Int(vf.height - chrome) & ~1))
        return (w, h)
    }

    struct Game: Identifiable, Equatable {
        let appid: Int
        var name: String?
        /// nil = follows the global auto-capture setting.
        var autoCapture: Bool?
        var id: Int { appid }
    }

    let defaults: UserDefaults
    /// Command-line flags that override a key for this run: key -> flag as typed.
    private(set) var overrides: [Key: String] = [:]
    /// `--auto-capture on|off` for this run (overrides `autoCaptureGames`, not persisted).
    private(set) var autoCaptureOverride: Bool?
    /// Next-start values this VM booted with (Restart VM to apply when they differ).
    private var bootSnapshot: [Key: String] = [:]
    private var loading = false

    // General
    @Published var showOverlay = true { didSet { save(.showOverlay, showOverlay) } }
    @Published var showStallIndicator = true { didSet { save(.showStallIndicator, showStallIndicator) } }
    @Published var openFullscreen = false { didSet { save(.openFullscreen, openFullscreen) } }
    @Published var perfStats = false { didSet { save(.perfStats, perfStats) } }
    /// Crash reports and diagnostics through Sentry (CrashReporting); applies now.
    @Published var sendCrashReports = true { didSet { save(.sendCrashReports, sendCrashReports) } }
    /// While the app is not active: mute the guest's sound / freeze the focused game.
    @Published var muteInBackground = true { didSet { save(.muteInBackground, muteInBackground) } }
    @Published var pauseInBackground = false { didSet { save(.pauseInBackground, pauseInBackground) } }
    /// The Mac's clipboard ↔ SteamOS's (ClipboardSync); concealed (password manager) items only
    /// with the second switch. Both apply now.
    @Published var shareClipboard = true { didSet { save(.shareClipboard, shareClipboard) } }
    @Published var shareConcealedClipboard = false { didSet { save(.shareConcealedClipboard, shareConcealedClipboard) } }
    @Published var closeAction = CloseAction.shutDown { didSet { save(.closeAction, closeAction.rawValue) } }
    /// New-version check when the app starts (UpdateChecker; never in development builds); applies now.
    @Published var checkForUpdates = true { didSet { save(.checkForUpdates, checkForUpdates) } }
    /// The guest's time zone and 12/24-hour format follow the Mac (MacTime kernel parameters)
    /// until each is changed inside SteamOS; next start.
    @Published var followMacTime = true { didSet { save(.followMacTime, followMacTime) } }
    // Display
    @Published var dpiSource = DPISource.auto { didSet { save(.dpiSource, dpiSource.rawValue) } }
    @Published var fixedDPI = 110 { didSet { save(.fixedDPI, fixedDPI) } }
    @Published var fixedWidthMM = 300 { didSet { save(.fixedWidthMM, fixedWidthMM) } }
    @Published var fixedHeightMM = 188 { didSet { save(.fixedHeightMM, fixedHeightMM) } }
    @Published var refreshRate = 60 { didSet { save(.refreshRate, refreshRate) } }
    @Published var followWindowSize = true { didSet { save(.followWindowSize, followWindowSize) } }
    @Published var windowWidth = 1280 { didSet { save(.windowWidth, windowWidth) } }
    @Published var windowHeight = 800 { didSet { save(.windowHeight, windowHeight) } }
    /// "<W>x<H>" (a sizePresets entry), `fitPreset` or `customPreset`; W/H always hold the size.
    @Published var windowSizePreset = "1280x800" { didSet { save(.windowSizePreset, windowSizePreset) } }
    /// The guest display gets the screen's pixel density (backing scale guest pixels per window
    /// point, Options.pixelScale) instead of one pixel per point; next start.
    @Published var retinaResolution = false { didSet { save(.retinaResolution, retinaResolution) } }
    /// Apple's Metal Performance HUD on the VM window (FPS, frame interval, GPU time, memory); applies now.
    @Published var metalHUD = false { didSet { save(.metalHUD, metalHUD) } }
    /// MetalFX spatial upscaling of the guest picture to the window's pixel size (Renderer); applies now.
    @Published var superResolution = false { didSet { save(.superResolution, superResolution) } }
    // Mouse
    @Published var autoCaptureGames = true { didSet { save(.autoCaptureGames, autoCaptureGames) } }
    @Published private(set) var games: [Game] = []
    // Controller
    /// SteamOS gets a gamepad while a controller is connected.
    @Published var virtualPad = true { didSet { save(.virtualPad, virtualPad) } }
    @Published var padType = PadType.auto { didSet { save(.padType, padType.rawValue) } }
    /// A DualSense that SteamOS gets as a DualSense is passed through as itself (HIDPassthrough):
    /// touchpad, motion, lights, mute button, rumble and triggers handled in SteamOS.
    @Published var dualSensePassthrough = true { didSet { save(.dualSensePassthrough, dualSensePassthrough) } }
    /// "" = first connected controller, else GamepadBridge.identifier(of:).
    @Published var controllerID = "" { didSet { save(.controllerID, controllerID) } }
    @Published var swapABXY = false { didSet { save(.swapABXY, swapABXY) } }
    /// Radial stick deadzone in percent (0 = GameController's own only).
    @Published var stickDeadzone = 0 { didSet { save(.stickDeadzone, stickDeadzone) } }
    // Sound
    @Published var soundEnabled = true { didSet { save(.soundEnabled, soundEnabled) } }
    /// "" = system default output (follows changes), else a CoreAudio device UID.
    @Published var soundOutputUID = "" { didSet { save(.soundOutputUID, soundOutputUID) } }
    @Published var soundVolume = 1.0 { didSet { save(.soundVolume, soundVolume) } }
    @Published var soundMute = false { didSet { save(.soundMute, soundMute) } }
    @Published var soundLatency = Latency.normal { didSet { save(.soundLatency, soundLatency.rawValue) } }
    // Advanced
    /// 0 = automatic (VMSizing: this Mac's performance cores / 75% of its RAM); the key is then absent.
    @Published var cpus = 0 { didSet { saveSize(.cpus, cpus) } }
    @Published var memMiB = 0 { didSet { saveSize(.memMiB, memMiB) } }
    /// SSH into the guest (gvproxy forward + guest sshd; `steamac.ssh=0|1`). Off by default in
    /// release bundles (Info.plist SteamacReleaseDefaults), on for the dev launcher.
    @Published var sshEnabled = !AppBundle.releaseDefaults { didSet { save(.sshEnabled, sshEnabled) } }
    @Published var sshPort = 2222 { didSet { save(.sshPort, sshPort) } }
    @Published var network = true { didSet { save(.network, network) } }
    /// Opt-in: exposes Remote Play to the local network, unlike ordinary user-mode NAT.
    @Published var lanRemotePlay = false { didSet { save(.lanRemotePlay, lanRemotePlay) } }
    /// "" = default (see AppBundle.defaultDisk()).
    @Published var diskImage = "" { didSet { save(.diskImage, diskImage) } }
    /// SteamOS update branch "Create New Disk…" installs (atomupd vr/<branch>.json).
    @Published var steamosBranch = "stable" { didSet { save(.steamosBranch, steamosBranch) } }
    /// Steam client of the next start (`steamac.steam_client=`).
    @Published var steamClient = SteamClient.deck { didSet { save(.steamClient, steamClient.rawValue) } }
    /// Host Vulkan driver of the next start (VulkanDriver).
    @Published var vulkanDriver = VulkanDriver.preferred { didSet { save(.vulkanDriver, vulkanDriver.rawValue) } }

    init() {
        let domain = LauncherSettings.domain
        // The embedded/bundled Info.plist makes es.fxgam.steamac our own identifier: that domain is
        // .standard (UserDefaults refuses it as a suite name).
        defaults = domain == Bundle.main.bundleIdentifier ? .standard : (UserDefaults(suiteName: domain) ?? .standard)
        if domain == LauncherSettings.defaultDomain { LauncherSettings.migrateLegacy(into: defaults) }
        load()
    }

    private static func migrateLegacy(into defaults: UserDefaults) {
        guard defaults.persistentDomain(forName: defaultDomain)?.isEmpty ?? true,
              let old = defaults.persistentDomain(forName: legacyDomain), !old.isEmpty else { return }
        defaults.setPersistentDomain(old, forName: defaultDomain)
        log("settings: copied \(old.count) preference(s) from \(legacyDomain) to \(defaultDomain)")
    }

    private func load() {
        loading = true
        defer { loading = false }
        let d = defaults
        func bool(_ k: Key, _ v: inout Bool) { if let b = d.object(forKey: k.rawValue) as? Bool { v = b } }
        func int(_ k: Key, _ v: inout Int) { if let n = d.object(forKey: k.rawValue) as? Int { v = n } }
        func string(_ k: Key, _ v: inout String) { if let s = d.string(forKey: k.rawValue) { v = s } }
        bool(.showOverlay, &showOverlay)
        bool(.showStallIndicator, &showStallIndicator)
        bool(.openFullscreen, &openFullscreen)
        bool(.perfStats, &perfStats)
        bool(.sendCrashReports, &sendCrashReports)
        bool(.muteInBackground, &muteInBackground)
        bool(.pauseInBackground, &pauseInBackground)
        bool(.shareClipboard, &shareClipboard)
        bool(.shareConcealedClipboard, &shareConcealedClipboard)
        if let s = d.string(forKey: Key.closeAction.rawValue).flatMap(CloseAction.init(rawValue:)) { closeAction = s }
        bool(.checkForUpdates, &checkForUpdates)
        bool(.followMacTime, &followMacTime)
        if let s = d.string(forKey: Key.dpiSource.rawValue).flatMap(DPISource.init(rawValue:)) { dpiSource = s }
        int(.fixedDPI, &fixedDPI)
        int(.fixedWidthMM, &fixedWidthMM)
        int(.fixedHeightMM, &fixedHeightMM)
        int(.refreshRate, &refreshRate)
        bool(.followWindowSize, &followWindowSize)
        int(.windowWidth, &windowWidth)
        int(.windowHeight, &windowHeight)
        if let p = d.string(forKey: Key.windowSizePreset.rawValue) {
            windowSizePreset = p
        } else {
            // Saved before presets existed: the matching preset, else custom.
            let id = "\(windowWidth)x\(windowHeight)"
            windowSizePreset = LauncherSettings.sizePresets.contains { $0.id == id } ? id : LauncherSettings.customPreset
        }
        bool(.retinaResolution, &retinaResolution)
        bool(.metalHUD, &metalHUD)
        bool(.superResolution, &superResolution)
        bool(.autoCaptureGames, &autoCaptureGames)
        bool(.virtualPad, &virtualPad)
        if let s = d.string(forKey: Key.padType.rawValue).flatMap(PadType.init(rawValue:)) { padType = s }
        bool(.dualSensePassthrough, &dualSensePassthrough)
        string(.controllerID, &controllerID)
        bool(.swapABXY, &swapABXY)
        int(.stickDeadzone, &stickDeadzone)
        bool(.soundEnabled, &soundEnabled)
        string(.soundOutputUID, &soundOutputUID)
        if let v = d.object(forKey: Key.soundVolume.rawValue) as? Double { soundVolume = v }
        bool(.soundMute, &soundMute)
        if let s = d.string(forKey: Key.soundLatency.rawValue).flatMap(Latency.init(rawValue:)) { soundLatency = s }
        int(.cpus, &cpus)
        int(.memMiB, &memMiB)
        bool(.sshEnabled, &sshEnabled)
        int(.sshPort, &sshPort)
        bool(.network, &network)
        bool(.lanRemotePlay, &lanRemotePlay)
        string(.diskImage, &diskImage)
        string(.steamosBranch, &steamosBranch)
        if !DiskCreator.branches.contains(steamosBranch) {
            log("settings: SteamOS branch \(steamosBranch) is not offered; falling back to stable")
            steamosBranch = "stable"
        }
        if let s = d.string(forKey: Key.steamClient.rawValue).flatMap(SteamClient.init(rawValue:)) { steamClient = s }
        if let v = d.string(forKey: Key.vulkanDriver.rawValue).flatMap(VulkanDriver.init(rawValue:)) { vulkanDriver = v }
        reloadGames()
    }

    private func save(_ key: Key, _ value: Any) {
        guard !loading else { return }
        defaults.set(value, forKey: key.rawValue)
    }

    /// vCPUs / memory: automatic (0) removes the key, so the size keeps following the Mac.
    private func saveSize(_ key: Key, _ value: Int) {
        guard !loading else { return }
        if value <= 0 { defaults.removeObject(forKey: key.rawValue) } else { defaults.set(value, forKey: key.rawValue) }
    }

    /// Control FIFO `set KEY VALUE`: change a setting exactly as the Settings window does (same
    /// property setters: persisted, live-applied). Returns false for an unknown key / bad value.
    func set(_ name: String, _ text: String) -> Bool {
        guard let key = Key(rawValue: name) else { return false }
        let b = ["1", "true", "on", "yes"].contains(text.lowercased()) ? true
            : ["0", "false", "off", "no"].contains(text.lowercased()) ? false : nil
        let i = Int(text), d = Double(text)
        switch key {
        case .showOverlay: guard let b else { return false }; showOverlay = b
        case .showStallIndicator: guard let b else { return false }; showStallIndicator = b
        case .openFullscreen: guard let b else { return false }; openFullscreen = b
        case .perfStats: guard let b else { return false }; perfStats = b
        case .sendCrashReports: guard let b else { return false }; sendCrashReports = b
        case .muteInBackground: guard let b else { return false }; muteInBackground = b
        case .pauseInBackground: guard let b else { return false }; pauseInBackground = b
        case .shareClipboard: guard let b else { return false }; shareClipboard = b
        case .shareConcealedClipboard: guard let b else { return false }; shareConcealedClipboard = b
        case .closeAction: guard let v = CloseAction(rawValue: text) else { return false }; closeAction = v
        case .checkForUpdates: guard let b else { return false }; checkForUpdates = b
        case .followMacTime: guard let b else { return false }; followMacTime = b
        case .dpiSource: guard let v = DPISource(rawValue: text) else { return false }; dpiSource = v
        case .fixedDPI: guard let i else { return false }; fixedDPI = i
        case .fixedWidthMM: guard let i else { return false }; fixedWidthMM = i
        case .fixedHeightMM: guard let i else { return false }; fixedHeightMM = i
        case .refreshRate: guard let i else { return false }; refreshRate = i
        case .followWindowSize: guard let b else { return false }; followWindowSize = b
        case .windowWidth: guard let i else { return false }; windowWidth = i
        case .windowHeight: guard let i else { return false }; windowHeight = i
        case .windowSizePreset:
            guard text == LauncherSettings.fitPreset || text == LauncherSettings.customPreset
                || LauncherSettings.sizePresets.contains(where: { $0.id == text }) else { return false }
            windowSizePreset = text
        case .retinaResolution: guard let b else { return false }; retinaResolution = b
        case .metalHUD: guard let b else { return false }; metalHUD = b
        case .superResolution: guard let b else { return false }; superResolution = b
        case .autoCaptureGames: guard let b else { return false }; autoCaptureGames = b
        case .gameNames: return false
        case .virtualPad: guard let b else { return false }; virtualPad = b
        case .padType: guard let v = PadType(rawValue: text) else { return false }; padType = v
        case .dualSensePassthrough: guard let b else { return false }; dualSensePassthrough = b
        case .controllerID: controllerID = text
        case .swapABXY: guard let b else { return false }; swapABXY = b
        case .stickDeadzone: guard let i else { return false }; stickDeadzone = i
        case .soundEnabled: guard let b else { return false }; soundEnabled = b
        case .soundOutputUID: soundOutputUID = text == "default" ? "" : text
        case .soundVolume: guard let d else { return false }; soundVolume = d
        case .soundMute: guard let b else { return false }; soundMute = b
        case .soundLatency: guard let v = Latency(rawValue: text) else { return false }; soundLatency = v
        case .cpus: guard let n = text == "auto" ? 0 : i, n >= 0 else { return false }; cpus = n
        case .memMiB: guard let n = text == "auto" ? 0 : i, n >= 0 else { return false }; memMiB = n
        case .sshEnabled: guard let b else { return false }; sshEnabled = b
        case .sshPort: guard let i else { return false }; sshPort = i
        case .network: guard let b else { return false }; network = b
        case .lanRemotePlay: guard let b else { return false }; lanRemotePlay = b
        case .diskImage: diskImage = text == "default" ? "" : text
        case .steamosBranch: guard DiskCreator.branches.contains(text) else { return false }; steamosBranch = text
        case .steamClient: guard let v = SteamClient(rawValue: text) else { return false }; steamClient = v
        case .vulkanDriver: guard let v = VulkanDriver(rawValue: text) else { return false }; vulkanDriver = v
        }
        return true
    }

    /// Restore every preference to its default (per-game entries included).
    func resetAll() {
        for k in defaults.dictionaryRepresentation().keys
        where Key(rawValue: k) != nil || k.hasPrefix("autoCapture.") {
            defaults.removeObject(forKey: k)
        }
        let fresh = LauncherSettings(blank: ())
        loading = true
        showOverlay = fresh.showOverlay; showStallIndicator = fresh.showStallIndicator
        openFullscreen = fresh.openFullscreen; perfStats = fresh.perfStats; sendCrashReports = fresh.sendCrashReports
        muteInBackground = fresh.muteInBackground; pauseInBackground = fresh.pauseInBackground
        shareClipboard = fresh.shareClipboard; shareConcealedClipboard = fresh.shareConcealedClipboard
        closeAction = fresh.closeAction; checkForUpdates = fresh.checkForUpdates; followMacTime = fresh.followMacTime
        dpiSource = fresh.dpiSource; fixedDPI = fresh.fixedDPI; fixedWidthMM = fresh.fixedWidthMM
        fixedHeightMM = fresh.fixedHeightMM; refreshRate = fresh.refreshRate; followWindowSize = fresh.followWindowSize
        windowWidth = fresh.windowWidth; windowHeight = fresh.windowHeight; windowSizePreset = fresh.windowSizePreset
        retinaResolution = fresh.retinaResolution
        metalHUD = fresh.metalHUD; superResolution = fresh.superResolution
        autoCaptureGames = fresh.autoCaptureGames
        virtualPad = fresh.virtualPad; padType = fresh.padType; dualSensePassthrough = fresh.dualSensePassthrough
        controllerID = fresh.controllerID; swapABXY = fresh.swapABXY
        stickDeadzone = fresh.stickDeadzone; soundEnabled = fresh.soundEnabled; soundOutputUID = fresh.soundOutputUID
        soundVolume = fresh.soundVolume; soundMute = fresh.soundMute; soundLatency = fresh.soundLatency
        cpus = fresh.cpus; memMiB = fresh.memMiB; sshEnabled = fresh.sshEnabled; sshPort = fresh.sshPort; network = fresh.network
        lanRemotePlay = fresh.lanRemotePlay
        diskImage = fresh.diskImage; steamosBranch = fresh.steamosBranch; steamClient = fresh.steamClient
        vulkanDriver = fresh.vulkanDriver
        loading = false
        reloadGames()
        log("settings: reset to defaults")
    }

    /// Property defaults only (resetAll); never loads or saves.
    private init(blank: ()) {
        defaults = .standard
        loading = true
    }

    // MARK: command-line overrides / restart tracking

    /// Called once per process after Options were resolved: remembers which keys the command line
    /// overrides and the next-start values this boot uses.
    func noteBoot(overrides: [Key: String], autoCapture: Bool?) {
        self.overrides = overrides
        autoCaptureOverride = autoCapture
        if autoCapture != nil { self.overrides[.autoCaptureGames] = "--auto-capture \(autoCapture! ? "on" : "off")" }
        bootSnapshot = nextStartSnapshot()
    }

    /// Effective next-start values (keys the command line overrides do not count).
    private func nextStartSnapshot() -> [Key: String] {
        let values: [Key: Any] = [
            .openFullscreen: openFullscreen, .dpiSource: dpiSource.rawValue,
            .fixedDPI: dpiSource == .dpi ? fixedDPI : 0,
            .fixedWidthMM: dpiSource == .mm ? fixedWidthMM : 0, .fixedHeightMM: dpiSource == .mm ? fixedHeightMM : 0,
            .refreshRate: refreshRate, .windowWidth: windowWidth, .windowHeight: windowHeight,
            .windowSizePreset: windowSizePreset, .retinaResolution: retinaResolution,
            .soundEnabled: soundEnabled, .cpus: cpus, .memMiB: memMiB, .sshEnabled: sshEnabled, .sshPort: sshPort,
            .network: network, .lanRemotePlay: lanRemotePlay,
            .diskImage: diskImage, .steamClient: steamClient.rawValue, .followMacTime: followMacTime,
            .vulkanDriver: vulkanDriver.rawValue,
        ]
        var s: [Key: String] = [:]
        for (k, v) in values where k.nextStart && overrides[k] == nil { s[k] = "\(v)" }
        return s
    }

    /// A next-start setting differs from what the running VM booted with.
    var restartPending: Bool { !bootSnapshot.isEmpty && nextStartSnapshot() != bootSnapshot }

    /// Window size the next boot opens at changed (a restart must not keep the current frame).
    var windowSizeChanged: Bool {
        let now = nextStartSnapshot()
        return now[.windowWidth] != bootSnapshot[.windowWidth] || now[.windowHeight] != bootSnapshot[.windowHeight]
            || now[.windowSizePreset] != bootSnapshot[.windowSizePreset]
    }

    // MARK: mouse auto-capture

    /// Global auto-capture in games for this run (`--auto-capture` wins over the saved value).
    var globalAutoCapture: Bool { autoCaptureOverride ?? autoCaptureGames }

    /// Per-game override, nil = follow the global default.
    func override(for appid: Int) -> Bool? {
        defaults.object(forKey: "autoCapture.\(appid)") as? Bool
    }

    func autoCapture(for appid: Int) -> Bool {
        override(for: appid) ?? globalAutoCapture
    }

    /// nil removes the per-game override (the game follows the global setting).
    func setAutoCapture(_ on: Bool?, for appid: Int) {
        if let on {
            defaults.set(on, forKey: "autoCapture.\(appid)")
            log("input: auto-capture for game \(appid) \(on ? "on" : "off") (saved)")
        } else {
            defaults.removeObject(forKey: "autoCapture.\(appid)")
            log("input: auto-capture for game \(appid) follows the global setting (saved)")
        }
        reloadGames()
    }

    /// `game <appid> <name>` from the guest agent.
    func setGameName(_ name: String, for appid: Int) {
        var names = defaults.dictionary(forKey: Key.gameNames.rawValue) as? [String: String] ?? [:]
        guard names[String(appid)] != name else { return }
        names[String(appid)] = name
        defaults.set(names, forKey: Key.gameNames.rawValue)
        reloadGames()
    }

    /// Forget a game (name and per-game setting).
    func removeGame(_ appid: Int) {
        defaults.removeObject(forKey: "autoCapture.\(appid)")
        var names = defaults.dictionary(forKey: Key.gameNames.rawValue) as? [String: String] ?? [:]
        names.removeValue(forKey: String(appid))
        defaults.set(names, forKey: Key.gameNames.rawValue)
        reloadGames()
    }

    func gameName(_ appid: Int) -> String? {
        (defaults.dictionary(forKey: Key.gameNames.rawValue) as? [String: String])?[String(appid)]
    }

    private func reloadGames() {
        let names = defaults.dictionary(forKey: Key.gameNames.rawValue) as? [String: String] ?? [:]
        var byId: [Int: Game] = [:]
        for (k, v) in names { if let id = Int(k) { byId[id] = Game(appid: id, name: v, autoCapture: nil) } }
        for (k, v) in defaults.dictionaryRepresentation() where k.hasPrefix("autoCapture.") {
            guard let id = Int(k.dropFirst("autoCapture.".count)), let b = v as? Bool else { continue }
            byId[id, default: Game(appid: id, name: nil, autoCapture: nil)].autoCapture = b
        }
        let list = byId.values.sorted { ($0.name ?? "~\($0.appid)").localizedCaseInsensitiveCompare($1.name ?? "~\($1.appid)") == .orderedAscending }
        if list != games { games = list }
    }

    var mouseSummary: String {
        let overrides = games.compactMap { g in g.autoCapture.map { "\(g.appid)=\($0 ? "on" : "off")" } }
        return "auto-capture in games \(globalAutoCapture ? "on" : "off")"
            + (autoCaptureOverride != nil ? " (--auto-capture)" : "")
            + (overrides.isEmpty ? "" : ", per game: " + overrides.joined(separator: " "))
    }
}
