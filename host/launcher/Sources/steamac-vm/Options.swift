import Foundation

struct DiskSpec {
    var path: String
    var readOnly: Bool
}

enum MouseMode: String {
    /// Default. The host pointer drives the guest cursor 1:1 through the relative mouse
    /// (gamescope ignores absolute pointer motion; Desktop Mode's Plasma runs inside it too); while
    /// a game is focused in the guest, a click captures the pointer (raw relative motion for
    /// mouse-look), Ctrl+Option releases.
    case auto
    /// Absolute virtio tablet, for a guest compositor that accepts absolute pointers (gamescope,
    /// and so both SteamOS modes, does not).
    case tablet
    /// Always click-to-capture (relative mouse only).
    case capture
}

struct Options {
    var kernel: String = ""
    var initrd: String?
    var cmdline = "console=hvc0 loglevel=4 rootwait"
    var disks: [DiskSpec] = []
    /// Settings > Advanced, --cpus / --mem, else automatic for this Mac (VMSizing; applySettings).
    var cpus = VMSizing.autoCPUs(.current)
    var memMiB = VMSizing.autoMemMiB(.current)
    var cpusSource = VMSizing.Source.auto
    var memSource = VMSizing.Source.auto
    /// Initial window content size in points (`--display`, Settings > Display window size).
    var displayWidth = 1280
    var displayHeight = 800
    /// Guest pixels per window point: the target screen's backing scale with Settings > Display >
    /// Retina resolution, else 1 (fixed for the boot, like the EDID DPI).
    var pixelScale = 1.0
    /// Guest display size at boot: the window size times `pixelScale` (WindowController.guestSize).
    var guestSize: (Int, Int) {
        WindowController.guestSize(points: CGSize(width: displayWidth, height: displayHeight), scale: pixelScale)
    }
    var refreshRate = 60
    var dpi: Int?
    var displayMM: (Int, Int)?
    var selftestOverlay = false
    var selftestStall = false
    var selftestPill = false
    var headless = false
    var logFile: String?
    var network = true
    var lanRemotePlay = false
    var selftestRemotePlay = false
    var sound = true
    var sshPort = 2222
    /// Steam client of this boot (kernel cmdline `steamac.steam_client=`).
    var steamClient = LauncherSettings.SteamClient.deck
    /// Settings > General "Use the Mac's time zone and clock format": MacTime kernel parameters.
    var macTime = true
    /// Host Vulkan driver of this boot (virglrenderer opens it; VM.start).
    var vulkanDriver = LauncherSettings.VulkanDriver.moltenvk
    var shmMiB = 8192
    var gpuFlags: UInt32? = nil
    var gvproxyPath: String?
    var frameDumpPath = "steamac-frame.png"
    var mouseMode: MouseMode = .auto
    var controlFifo: String?
    var autoCapture: Bool?
    /// The guest gets a gamepad over fx.pad (`--no-gamepad`: no port, no pad this run).
    var gamepad = true
    /// `--pad`: what the guest's gamepad is this run (instead of Settings > Controller).
    var padType: LauncherSettings.PadType?
    var krunLogLevel: UInt32 = 2
    var selftestDisplay = false
    var selftestOut: String?
    var inputSelftestDelay: Double?
    var resizeSelftestDelay: Double?
    var selftestSettings = false
    var perfStats = false
    /// Settings: enter fullscreen once the window is up.
    var fullscreen = false
    /// No main disk configured or found (app bundle launch): the first-run sheet asks for one.
    var needsDisk = false
    /// This boot attaches the first-boot provisioning payload (Provision.attachPending).
    var provisionPayload: String?
    /// This boot attaches the disk's pending generated guest password (Provision.attachConfig).
    var configPayload: Provision.ConfigPayload?
    /// --create-disk PATH (no VM): build a new SteamOS disk without Docker (DiskCreator).
    var createDisk: String?
    /// --grow-disk PATH --home-gib N (no VM): enlarge an existing disk, never shrink.
    var growDisk: String?
    var createBranch: String?
    var createHomeGiB = DiskLayout.defaultHomeGiB
    var createPassword: String?
    var keepCache = false
    /// --accept-eula: accept Valve's SteamOS EULA + Steam Subscriber Agreement (SteamOSLicense).
    var acceptLicense = false
    var selftestProvision = false
    var referenceDisk: String?
    /// --ssh-password DISK: print the disk's generated guest password (GuestPassword) and exit.
    var showSSHPassword: String?
    /// --no-crash-reports / STEAMAC_SENTRY=0: no Sentry for this run (CrashReporting).
    var noCrashReports = false
    /// Hidden --sentry-test-event / --sentry-test-crash MODE (CrashReporting.runTests).
    var sentryTestEvent = false
    var sentryTestCrash: String?
    /// Flags given on the command line (they override the saved settings for this run).
    var explicit: Set<String> = []

    static let usage = """
    usage: steamac-vm --kernel PATH [--initrd PATH] [--cmdline STR] --disk PATH[:ro] ...
                      [--cpus N] [--mem MiB] [--display WxH] [--refresh HZ] [--headless]
                      [--log FILE] [--no-net] [--no-sound] [--ssh-port PORT | --no-ssh] [--shm-mib MiB]
                      [--gpu-flags HEX] [--gvproxy PATH] [--frame-dump PNG]
                      [--mouse auto|tablet|capture] [--no-gamepad] [--pad auto|xbox360|dualsense|dualshock4]
                      [--krun-log-level 0-5] [--perf-stats]
                      [--no-crash-reports] [--steam-client frame|deck|deckbeta]
                      [--vulkan-driver moltenvk|kosmickrisp] [--lan-remote-play | --no-lan-remote-play]
           steamac-vm --selftest-display [--headless] [--selftest-out DIR] [--display WxH]
           steamac-vm --selftest-overlay [--selftest-out DIR] [--display WxH]
           steamac-vm --selftest-stall [--selftest-out DIR] [--display WxH]
           steamac-vm --selftest-pill [--selftest-out DIR] [--display WxH]
           steamac-vm --selftest-settings [--selftest-out DIR]
           steamac-vm --selftest-provision [--reference-disk IMG]
           steamac-vm --selftest-remote-play
           steamac-vm --create-disk PATH [--branch stable|rc] [--home-gib N]
                      [--password PW] [--keep-cache] [--accept-eula]
           steamac-vm --ssh-password DISK

    Without a flag, next-start values come from the Settings window (defaults domain es.fxgam.steamac):
    vCPUs, RAM, SSH port, network, sound, virtual pad, refresh, window size, physical size (DPI),
    fullscreen, perf stats, Steam client, Vulkan driver, Mac time zone and 12/24-hour format
    (Settings > General: adds steamac.tz= and steamac.clock24= unless --cmdline sets them).
    Inside FX Steam Launcher.app, --kernel/--initrd/--disk default to the bundled Image, initramfs and
    layer plus the disk image chosen in Settings > Advanced.

      --kernel PATH        raw arm64 Image (KRUN_KERNEL_FORMAT_RAW)
      --initrd PATH        initramfs
      --cmdline STR        kernel command line (default: "console=hvc0 loglevel=4 rootwait"; fsck.repair=yes,
                           steamac.ssh/steam_client/tz are added unless STR sets them)
      --disk PATH[:ro]     raw virtio-blk disk; repeatable, order = vda, vdb, ...
      --cpus N             vCPUs (default: Settings > Advanced, automatic = this Mac's performance
                           cores, 2..8)
      --mem MiB            guest RAM (default: Settings > Advanced, automatic = 75% of this Mac's RAM,
                           4096..16384; the GPU's memory comes from the same RAM)
      --display WxH        initial window size in points (default 1280x800); the guest display follows
                           the window: content size in points = guest pixels, x the screen's backing
                           scale with Settings > Display > Retina resolution (even, min 800x500, max
                           4094), applied when a resize / fullscreen switch ends
      --refresh HZ         EDID refresh rate (default 60)
      --dpi N              EDID pixel density instead of the default physical size (below)
      --display-mm WxH     EDID physical size in millimetres at the initial size (overrides --dpi)
                           Default: the window's real size on the host monitor (initial content size
                           in points x the screen's mm/point), so guest UIs come out at real-world size;
                           96 dpi-equivalent when headless or the monitor reports no size. Resizes keep
                           this DPI (physical size = new size x the same mm per pixel).
      --headless           no window and no input devices; SIGUSR1 dumps the latest frame
      --log FILE           also append the hvc0 console to FILE
      --no-net             no virtio-net / gvproxy
      --lan-remote-play    expose Steam Remote Play on the LAN (Settings > Advanced; off by default)
      --no-lan-remote-play disable the LAN discovery relay and Remote Play forwards for this boot
      --no-sound           no virtio-snd (default: guest audio plays on the Mac's default output
                           device and follows it when it changes; guest recording uses the default
                           input device, asking for microphone permission the first time)
      --ssh-port PORT      SSH on: host 127.0.0.1:PORT -> guest 192.168.127.2:22 (default 2222)
      --no-ssh             SSH off: no port forward, guest sshd masked (kernel cmdline steamac.ssh=0/1
                           is added on every boot; the default comes from Settings > Advanced "Enable
                           SSH": on for this dev launcher, off in the release .app)
      --shm-mib MiB        virtio-gpu host-visible shared memory window (default 8192)
      --gpu-flags HEX      virglrenderer flags (default VENUS|NO_VIRGL = 0xc0)
      --gvproxy PATH       gvproxy binary (default: <exe dir>/host/bin/gvproxy, Homebrew, PATH)
      --frame-dump PNG     where SIGUSR1 writes the current frame (default ./steamac-frame.png)
      --mouse MODE         auto (default): pointer follows the host cursor 1:1 (also in Desktop Mode);
                           while a game has focus a click captures the mouse (relative, for mouse-look),
                           Ctrl+Option releases. tablet: absolute virtio tablet (ignored by gamescope, so
                           only for other guest compositors). capture: always click-to-capture.
      --auto-capture on|off  auto mode: capture on click in games, for this run (default: the saved
                           setting, menu Mouse > Auto-Capture Mouse in Games; per-game overrides apply)
      --no-gamepad         no virtual gamepad this run (default: Settings > Controller "Virtual
                           controller", which applies while the VM runs)
      --pad TYPE           what the virtual gamepad is in SteamOS this run (default: Settings >
                           Controller): auto: the same kind as the controller that drives it
                           (DualSense, DualShock 4, else Xbox 360); xbox360: Microsoft X-Box 360 pad
                           (xpad); dualsense, dualshock4: Sony pad as the Linux hid-playstation /
                           hid-sony drivers expose it (PlayStation button glyphs in Steam). Any
                           connected controller drives it; its rumble plays on that controller.
      --krun-log-level N   libkrun log level 0=off .. 5=trace (default 2=warn)
      --steam-client C     Steam client SteamOS starts (kernel cmdline steamac.steam_client=C, added on
                           every boot; default: Settings > Advanced "Steam client", deck unless changed):
                           deck: public ARM64 Steam Deck client (steamdeck_stable);
                           deckbeta: Steam Deck client beta (steamdeck_publicbeta);
                           frame: Valve's Steam Frame client beta (stock; until an account is remembered
                           the Steam Deck client is used for its on-screen sign-in QR code).
                           Switching downloads the other client (~1 GB) when Steam starts.
      --vulkan-driver D    host Vulkan driver behind Venus (default: Settings > Advanced "Vulkan driver",
                           KosmicKrisp where available, else MoltenVK):
                           kosmickrisp: Mesa's KosmicKrisp on Metal 4 (macOS 26 or newer, builds that
                           include it: host/kosmickrisp);
                           moltenvk: MoltenVK with steamac's patches (every Mac).
                           Switching makes Steam and games rebuild their shader caches.

    Creating a SteamOS disk (no Docker; the same code as Settings > Advanced "Create New Disk…"):
      --create-disk PATH   download the signed SteamOS bundle of the branch (default: the saved setting,
                           else stable), verify it against Valve's CA, rebuild the rootfs with desync
                           (resumable; cache in ~/Library/Caches/es.fxgam.steamac when PATH is on the home
                           volume, else in PATH.cache), write a sparse GPT disk to PATH (never
                           overwritten) plus PATH's .provision.img payload, which the first boot uses to
                           format and fill the remaining partitions. One creation per cache at a time.
      --home-gib N         size of the home partition (default 64; sparse)
      --password PW        password of the guest user steamos (default: steamos for this dev launcher,
                           none in the release .app; "" = none)
      --keep-cache         keep the bundle and chunk cache after success
      --accept-eula        accept Valve's End User License Agreement for SteamOS and Steam Client Back-Up
                           Image (https://store.steampowered.com/steamos/download/?ver=steamframe) and the
                           Steam Subscriber Agreement; required unless they were already accepted (Create
                           SteamOS Disk window or an earlier --accept-eula), remembered afterwards
      --grow-disk PATH     grow an existing disk's home capacity to --home-gib N (grow only).
                           SteamOS must be stopped; partition and filesystem grow on its next boot.

    SSH: --ssh-password DISK prints user, generated password and state (pending / applied) of DISK
    (the password Settings > Advanced shows; it exists once SSH was enabled for that disk).

    Crash reports (Settings > General "Send crash reports and diagnostics", on by default):
      --no-crash-reports   no crash reports or diagnostics for this run (also STEAMAC_SENTRY=0);
                           STEAMAC_SENTRY_DEBUG=1 prints the Sentry SDK's debug log

    Updates (Settings > General "Check for updates at startup", on; never in the dev launcher
    work/out/steamac-vm): the first boot asks api.github.com for the latest fxgl/steamac release, at
    most every 6 h; menu FX Steam Launcher > Check for Updates… checks at any time. Test hooks:
    STEAMAC_UPDATE_URL (release JSON, http(s):// or file://; also enables the dev launcher's startup
    check), STEAMAC_FAKE_VERSION (the version this launcher compares as)

    Diagnostics:
      --perf-stats         every 5 s log frame pacing (also STEAMAC_PERF_STATS=1): guest flush and
                           on-screen frame intervals (p50/p95/p99/max, count > 25 / > 50 ms), libkrun's
                           per-flush copy, flush -> screen latency, dropped/replaced frames, upload time
      --selftest-display   feed synthetic frames (all formats) through the display backend vtable and
                           verify PNG dump, Metal render and (windowed) the presented drawable
      --input-selftest S   S seconds after boot, inject synthetic key/mouse/gamepad input, then
                           close the window (guest power key) 4 s later
      --selftest-overlay   drive the FX boot/shutdown overlay with synthetic console and fx.progress
                           input and write window captures at several progress points
      --selftest-stall     drive the GPU-idle indicator with synthetic GPU counters and heartbeats
                           and write window captures (indicator shown / hidden / not responding)
      --selftest-pill      boot overlay vs progress pill (click / key / menu collapse, download stages keep
                           or re-expand the overlay, live download progress, window title, fade at
                           ready), then the no-picture guard with synthetic scanout states; captures + checks
      --selftest-settings  open the Settings window and write a PNG of every tab to --selftest-out
      --selftest-provision unit tests of the disk creator: GPT writer vs the layout of --reference-disk
                           (default work/out/steamos.img, opened read-only), squashfs + CMS verification of
                           the cached bundle, cpio payload, SHA-512 crypt, desync progress parsing
      --resize-selftest S  S seconds after Steam is ready, resize the window 1600x1000 -> fullscreen ->
                           windowed -> 1280x800, wait for the guest's new scanout each time and dump
                           frames to <--frame-dump>-resize-N-*.png
      --control-fifo PATH  create a FIFO that accepts scripted window input, one command per line:
                           move UX UY (0..1 in the picture) | button left|right|middle down|up |
                           click left|right|middle | wheel NOTCHES | rel DX DY |
                           key KEYCODE [ctrl+cmd+opt+shift] (macOS virtual key code) |
                           grab | release | menu game|global (toggle the Mouse menu checkboxes) |
                           guest LINE (as if sent on fx.progress) | dump PNG (+ -window, -overlay,
                           -screen = as composited on screen, Metal HUD included) |
                           settings TAB|close | settings-dump PNG | set KEY VALUE | restart |
                           update check|startup|state | update press download|skip|later|ok |
                           update dump PNG (+ -with-vm = beside the VM window, as on screen)

    Window keys: Ctrl+Cmd+F fullscreen, Ctrl+Cmd+G capture/release the mouse, Ctrl+Option release,
    Ctrl+Cmd+P Metal Performance HUD on/off (Settings > Display).
    Closing the window (or SIGINT/SIGTERM) presses the guest power key; a second request force-quits.
    Console: hvc0 <-> this terminal (raw mode when stdin is a TTY; Ctrl+] twice force-quits).
    """

    static func parse(_ argv: [String]) throws -> Options {
        var o = Options()
        var i = 1
        func value(_ name: String) throws -> String {
            i += 1
            guard i < argv.count else { throw OptionError("\(name) needs a value") }
            return argv[i]
        }
        func int(_ name: String) throws -> Int {
            let v = try value(name)
            guard let n = Int(v) else { throw OptionError("\(name): not an integer: \(v)") }
            return n
        }
        while i < argv.count {
            let a = argv[i]
            if a.hasPrefix("-psn_") { i += 1; continue }   // old Finder process serial number
            o.explicit.insert(a)
            switch a {
            case "--kernel": o.kernel = try value(a)
            case "--initrd": o.initrd = try value(a)
            case "--cmdline": o.cmdline = try value(a)
            case "--disk":
                var p = try value(a)
                var ro = false
                if p.hasSuffix(":ro") { ro = true; p.removeLast(3) }
                else if p.hasSuffix(":rw") { p.removeLast(3) }
                o.disks.append(DiskSpec(path: p, readOnly: ro))
            case "--cpus": o.cpus = try int(a)
            case "--mem": o.memMiB = try int(a)
            case "--display":
                let v = try value(a)
                let parts = v.lowercased().split(separator: "x").compactMap { Int($0) }
                guard parts.count == 2, parts[0] > 0, parts[1] > 0 else { throw OptionError("--display: expected WxH, got \(v)") }
                o.displayWidth = parts[0]; o.displayHeight = parts[1]
            case "--refresh": o.refreshRate = try int(a)
            case "--dpi":
                let d = try int(a)
                guard (50...600).contains(d) else { throw OptionError("--dpi must be 50..600") }
                o.dpi = d
            case "--display-mm":
                let v = try value(a)
                let parts = v.lowercased().split(separator: "x").compactMap { Int($0) }
                guard parts.count == 2, (10...5000).contains(parts[0]), (10...5000).contains(parts[1]) else {
                    throw OptionError("--display-mm: expected WxH in millimetres, got \(v)")
                }
                o.displayMM = (parts[0], parts[1])
            case "--headless": o.headless = true
            case "--log": o.logFile = try value(a)
            case "--no-net": o.network = false
            case "--lan-remote-play": o.lanRemotePlay = true
            case "--no-lan-remote-play": o.lanRemotePlay = false
            case "--no-sound": o.sound = false
            case "--ssh-port": o.sshPort = try int(a)
            case "--no-ssh": o.sshPort = 0
            case "--steam-client":
                let v = try value(a)
                guard let c = LauncherSettings.SteamClient(rawValue: v) else {
                    throw OptionError("--steam-client: frame, deck or deckbeta")
                }
                o.steamClient = c
            case "--vulkan-driver":
                let v = try value(a)
                guard let d = LauncherSettings.VulkanDriver(rawValue: v) else {
                    throw OptionError("--vulkan-driver: moltenvk or kosmickrisp")
                }
                o.vulkanDriver = d
            case "--shm-mib": o.shmMiB = try int(a)
            case "--gpu-flags":
                let v = try value(a)
                let s = v.hasPrefix("0x") ? String(v.dropFirst(2)) : v
                guard let f = UInt32(s, radix: 16) else { throw OptionError("--gpu-flags: not hex: \(v)") }
                o.gpuFlags = f
            case "--gvproxy": o.gvproxyPath = try value(a)
            case "--frame-dump": o.frameDumpPath = try value(a)
            case "--mouse":
                let v = try value(a)
                guard let m = MouseMode(rawValue: v) else { throw OptionError("--mouse: auto, tablet or capture") }
                o.mouseMode = m
            case "--control-fifo": o.controlFifo = try value(a)
            case "--auto-capture":
                let v = try value(a)
                guard v == "on" || v == "off" else { throw OptionError("--auto-capture: on or off") }
                o.autoCapture = v == "on"
            case "--no-gamepad": o.gamepad = false
            case "--pad":
                let v = try value(a)
                guard let t = LauncherSettings.PadType(rawValue: v) else {
                    throw OptionError("--pad: auto, xbox360, dualsense or dualshock4")
                }
                o.padType = t
            case "--krun-log-level": o.krunLogLevel = UInt32(clamping: try int(a))
            case "--perf-stats": o.perfStats = true
            case "--no-crash-reports": o.noCrashReports = true
            case "--sentry-test-event": o.sentryTestEvent = true
            case "--sentry-test-crash":
                let v = try value(a)
                guard ["abort", "segv", "metal", "panic", "kill", "term", "shader", "gpu-teardown"].contains(v) else {
                    throw OptionError("--sentry-test-crash: abort, segv, metal, panic, kill, term, shader or gpu-teardown")
                }
                o.sentryTestCrash = v
            case "--selftest-display": o.selftestDisplay = true
            case "--selftest-out": o.selftestOut = try value(a)
            case "--selftest-overlay": o.selftestOverlay = true
            case "--selftest-stall": o.selftestStall = true
            case "--selftest-pill": o.selftestPill = true
            case "--selftest-settings": o.selftestSettings = true
            case "--selftest-remote-play": o.selftestRemotePlay = true
            case "--selftest-provision": o.selftestProvision = true
            case "--reference-disk": o.referenceDisk = try value(a)
            case "--create-disk": o.createDisk = try value(a)
            case "--grow-disk": o.growDisk = try value(a)
            case "--branch":
                let v = try value(a)
                guard DiskCreator.branches.contains(v) else { throw OptionError("--branch: stable or rc") }
                o.createBranch = v
            case "--home-gib": o.createHomeGiB = try int(a)
            case "--password": o.createPassword = try value(a)
            case "--keep-cache": o.keepCache = true
            case "--accept-eula": o.acceptLicense = true
            case "--ssh-password": o.showSSHPassword = try value(a)
            case "--resize-selftest":
                let v = try value(a)
                guard let d = Double(v), d >= 0 else { throw OptionError("--resize-selftest: seconds") }
                o.resizeSelftestDelay = d
            case "--input-selftest":
                let v = try value(a)
                guard let d = Double(v), d >= 0 else { throw OptionError("--input-selftest: seconds") }
                o.inputSelftestDelay = d
            case "-h", "--help":
                print(usage)
                exit(0)
            default:
                throw OptionError("unknown argument: \(a)")
            }
            i += 1
        }
        if ProcessInfo.processInfo.environment["STEAMAC_PERF_STATS"] == "1" {
            o.perfStats = true
            o.explicit.insert("STEAMAC_PERF_STATS=1")
        }
        if ProcessInfo.processInfo.environment[CrashReporting.disableEnv] == "0" {
            o.noCrashReports = true
            o.explicit.insert("\(CrashReporting.disableEnv)=0")
        }
        return o
    }

    var isSelftest: Bool {
        selftestDisplay || selftestOverlay || selftestStall || selftestPill || selftestSettings || selftestProvision || selftestRemotePlay
            || createDisk != nil || growDisk != nil
            || showSSHPassword != nil
    }

    /// Command line + saved settings (+ app bundle resources): what this boot runs with, and which
    /// settings keys the command line overrides.
    static func resolve(_ argv: [String], settings: LauncherSettings) throws -> (Options, [LauncherSettings.Key: String]) {
        var o = try parse(argv)
        var overrides = o.applySettings(settings)
        if !o.isSelftest, let reason = o.vulkanDriver.unavailableReason {
            guard !o.explicit.contains("--vulkan-driver") else {
                throw OptionError("--vulkan-driver \(o.vulkanDriver.rawValue): \(o.vulkanDriver.name) \(reason)")
            }
            log("gpu: \(o.vulkanDriver.name) \(reason); using MoltenVK")
            o.vulkanDriver = .moltenvk
        }
        if !o.isSelftest {
            AppBundle.fill(&o, settings: settings, overrides: &overrides)
            Provision.attachPending(&o)
            Provision.attachConfig(&o)
            let words = o.cmdline.split(separator: " ")
            func add(_ key: String, _ value: @autoclosure () -> String?) {
                guard !words.contains(where: { $0.hasPrefix(key + "=") }), let v = value() else { return }
                o.cmdline += " \(key)=\(v)"
            }
            add("steamac.ssh", o.sshPort == 0 ? "0" : "1")
            add("steamac.steam_client", o.steamClient.rawValue)
            if o.macTime {
                add("steamac.tz", MacTime.zone)
                add("steamac.clock24", MacTime.clock24.map { $0 ? "1" : "0" })
            }
            // systemd-fsck answers yes to e2fsck's questions instead of only preening: a /home with errors
            // preen cannot fix (a VM killed mid-write, two VMs on one disk) is repaired at boot instead of
            // failing /home and every unit after it (boot stuck at "Starting SteamOS services").
            add("fsck.repair", "yes")
        }
        try o.validate()
        return (o, overrides)
    }

    /// Fill every value the command line did not set from the saved settings.
    mutating func applySettings(_ s: LauncherSettings) -> [LauncherSettings.Key: String] {
        var ov: [LauncherSettings.Key: String] = [:]
        func given(_ flag: String) -> Bool { explicit.contains(flag) }
        if given("--cpus") {
            ov[.cpus] = "--cpus \(cpus)"
            cpusSource = .flag
        } else if s.cpus > 0 {
            cpus = min(255, s.cpus)
            cpusSource = .settings
        } else {
            cpus = VMSizing.autoCPUs(.current)
            cpusSource = .auto
        }
        if given("--mem") {
            ov[.memMiB] = "--mem \(memMiB)"
            memSource = .flag
        } else if s.memMiB > 0 {
            memMiB = max(1024, s.memMiB)
            memSource = .settings
        } else {
            memMiB = VMSizing.autoMemMiB(.current)
            memSource = .auto
        }
        if given("--no-ssh") {
            ov[.sshEnabled] = "--no-ssh"
            ov[.sshPort] = "--no-ssh"
        } else if given("--ssh-port") {
            ov[.sshPort] = "--ssh-port \(sshPort)"
            ov[.sshEnabled] = ov[.sshPort]
        } else {
            sshPort = !s.sshEnabled || s.sshPort == 0 ? 0 : (1024...65535).contains(s.sshPort) ? s.sshPort : 2222
        }
        if given("--no-net") { ov[.network] = "--no-net" } else { network = s.network }
        if given("--lan-remote-play") || given("--no-lan-remote-play") {
            ov[.lanRemotePlay] = lanRemotePlay ? "--lan-remote-play" : "--no-lan-remote-play"
        } else { lanRemotePlay = s.lanRemotePlay }
        macTime = s.followMacTime
        if given("--steam-client") { ov[.steamClient] = "--steam-client \(steamClient.rawValue)" } else { steamClient = s.steamClient }
        if given("--vulkan-driver") { ov[.vulkanDriver] = "--vulkan-driver \(vulkanDriver.rawValue)" } else { vulkanDriver = s.vulkanDriver }
        if given("--no-sound") { ov[.soundEnabled] = "--no-sound" } else { sound = s.soundEnabled }
        if given("--no-gamepad") { ov[.virtualPad] = "--no-gamepad" }
        if let padType { ov[.padType] = "--pad \(padType.rawValue)" }
        if given("--refresh") { ov[.refreshRate] = "--refresh \(refreshRate)" } else { refreshRate = min(240, max(24, s.refreshRate)) }
        if given("--display") {
            ov[.windowWidth] = "--display \(displayWidth)x\(displayHeight)"
            ov[.windowHeight] = ov[.windowWidth]
            ov[.windowSizePreset] = ov[.windowWidth]
        } else {
            // "Fit to screen" is re-evaluated at every start (the screen may have changed).
            let (w, h) = s.windowSizePreset == LauncherSettings.fitPreset && !headless
                ? LauncherSettings.fitToScreenSize() : (s.windowWidth, s.windowHeight)
            displayWidth = min(VM.maxDisplaySide & ~1, max(Int(WindowController.minGuestSize.width), w & ~1))
            displayHeight = min(VM.maxDisplaySide & ~1, max(Int(WindowController.minGuestSize.height), h & ~1))
        }
        if s.retinaResolution && !headless {
            pixelScale = max(1, WindowController.targetScreen()?.backingScaleFactor ?? 1)
        }
        if given("--dpi") || given("--display-mm") {
            let flag = displayMM.map { "--display-mm \($0.0)x\($0.1)" } ?? "--dpi \(dpi ?? 0)"
            for k in [LauncherSettings.Key.dpiSource, .fixedDPI, .fixedWidthMM, .fixedHeightMM] { ov[k] = flag }
        } else {
            switch s.dpiSource {
            case .auto: break
            case .dpi: dpi = min(600, max(50, s.fixedDPI))
            case .mm: displayMM = (min(5000, max(10, s.fixedWidthMM)), min(5000, max(10, s.fixedHeightMM)))
            }
        }
        if perfStats { ov[.perfStats] = explicit.contains("--perf-stats") ? "--perf-stats" : "STEAMAC_PERF_STATS=1" }
        else { perfStats = s.perfStats }
        fullscreen = s.openFullscreen
        if noCrashReports {
            ov[.sendCrashReports] = explicit.contains(CrashReporting.noFlag) ? CrashReporting.noFlag : "\(CrashReporting.disableEnv)=0"
        }
        if !disks.isEmpty { ov[.diskImage] = "--disk \(disks[0].path)" }
        return ov
    }

    func validate() throws {
        guard !isSelftest, !needsDisk, !sentryTestEvent, sentryTestCrash == nil else { return }
        guard !kernel.isEmpty else { throw OptionError("--kernel is required") }
        guard (1...255).contains(cpus) else { throw OptionError("--cpus must be 1..255") }
        guard memMiB >= 256 else { throw OptionError("--mem must be >= 256") }
        guard sshPort == 0 || (1024...65535).contains(sshPort) else {
            throw OptionError("--ssh-port must be 0 or 1024..65535")
        }
        for path in [kernel] + (initrd.map { [$0] } ?? []) + disks.map(\.path) {
            guard FileManager.default.isReadableFile(atPath: path) else {
                throw OptionError("not readable: \(path)")
            }
        }
        if disks.count > 26 { throw OptionError("at most 26 disks") }
    }
}

/// The Mac's time zone and 12/24-hour format, read at every VM start. The guest follows
/// steamac.tz= and steamac.clock24= until the corresponding setting is changed in SteamOS.
enum MacTime {
    /// IANA identifier (e.g. Europe/Moscow); nil when it cannot be a kernel parameter.
    static var zone: String? {
        let id = TimeZone.current.identifier
        return isZone(id) ? id : nil
    }

    /// The "j" template honors macOS's 24-hour override, unlike a locale's default format.
    static var clock24: Bool? {
        DateFormatter.dateFormat(fromTemplate: "j", options: 0, locale: .current).map(is24Hour)
    }

    static func is24Hour(_ pattern: String) -> Bool {
        pattern.contains("H") || pattern.contains("k")
    }

    /// The same check as the initramfs: zoneinfo-relative path characters only.
    static func isZone(_ s: String) -> Bool {
        !s.isEmpty && !s.hasPrefix("/") && !s.contains("..")
            && s.unicodeScalars.allSatisfy { $0.isASCII && (CharacterSet.alphanumerics.contains($0) || "_+-/".unicodeScalars.contains($0)) }
    }

    /// --selftest-settings: zone validation, clock patterns and this Mac's values.
    static func selfCheck() -> [String] {
        var failures: [String] = []
        for good in ["Europe/Moscow", "America/Argentina/Buenos_Aires", "Etc/GMT+3", "UTC"] where !isZone(good) {
            failures.append("mac time: \(good) rejected")
        }
        for bad in ["", "/etc/passwd", "Europe/../../x", "Europe/Moscow x", "Europe/Moskva\u{0301}"] where isZone(bad) {
            failures.append("mac time: \(bad) accepted")
        }
        if zone == nil { failures.append("mac time: time zone \(TimeZone.current.identifier) is no kernel parameter") }
        for pattern in ["H", "HH", "k", "kk"] where !is24Hour(pattern) {
            failures.append("mac time: 24-hour pattern \(pattern) rejected")
        }
        for pattern in ["h a", "hh a", "K a"] where is24Hour(pattern) {
            failures.append("mac time: 12-hour pattern \(pattern) accepted")
        }
        if clock24 == nil { failures.append("mac time: no localized hour pattern") }
        log("selftest-settings: mac time: steamac.tz=\(zone ?? "-") steamac.clock24=\(clock24.map { $0 ? "1" : "0" } ?? "-")")
        return failures
    }
}

struct OptionError: Error, CustomStringConvertible {
    let description: String
    init(_ d: String) { description = d }
}
