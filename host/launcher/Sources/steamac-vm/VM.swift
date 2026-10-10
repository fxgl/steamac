import CKrun
import Darwin
import Foundation

struct KrunError: Error, CustomStringConvertible {
    let call: String
    let code: Int32
    var description: String { "\(call) failed: \(code) (\(String(cString: strerror(-code))))" }
}

@discardableResult
func krun(_ name: String, _ r: Int32) throws -> Int32 {
    if r < 0 { throw KrunError(call: name, code: r) }
    return r
}

/// Input devices handed to the window (nil in headless mode). The gamepad is not among them: the
/// guest creates it over fx.pad (PadPort, GamepadBridge).
struct VMInputs {
    let keyboard: InputDevice
    let tablet: InputDevice
    let mouse: InputDevice
}

/// libkrun context: configuration (boot contract) and the VMM thread.
final class VM {
    let ctx: UInt32
    private(set) var shutdownFd: Int32 = -1
    private(set) var running = false
    /// This boot has a virtio-snd device (runtime controls: SoundControl).
    private(set) var hasSound = false
    private let displayId: UInt32
    /// Boot EDID; its mm-per-pixel is reused for every resize (constant DPI).
    let edid: EdidSize.Result
    private var displaySize: (Int, Int, Int, Int)   // px w, h, mm w, h
    /// Largest guest display side libkrun's EDID detailed timing can describe.
    static let maxDisplaySide = 4095

    init(options o: Options, display: DisplayBackend, console: Console, progressPort: ProgressPort?,
         clockPort: ClockPort?, sleepPort: SleepPort?, padPorts: [PadPort], clipboardPort: ClipboardPort?,
         inputs: VMInputs?, netSocket: String?) throws {
        VM.raiseFileLimit()
        try krun("krun_init_log", krun_init_log(KRUN_LOG_TARGET_DEFAULT, o.krunLogLevel, UInt32(KRUN_LOG_STYLE_AUTO), 0))
        ctx = UInt32(try krun("krun_create_ctx", krun_create_ctx()))
        try krun("krun_set_vm_config", krun_set_vm_config(ctx, UInt8(o.cpus), UInt32(o.memMiB)))

        // No TSI/vsock in this guest; hvc0 = our pty (explicit console instead of the implicit
        // stdio one, so console output also works when stdout is a pipe/file).
        try krun("krun_disable_implicit_vsock", krun_disable_implicit_vsock(ctx))
        try krun("krun_disable_implicit_console", krun_disable_implicit_console(ctx))
        let con = try krun("krun_add_virtio_console_multiport", krun_add_virtio_console_multiport(ctx))
        try krun("krun_add_console_port_tty", krun_add_console_port_tty(ctx, UInt32(con), "", console.slaveFd))
        // Guest -> host boot/shutdown progress (FX overlay): guest writes /dev/virtio-ports/fx.progress.
        if let p = progressPort {
            try krun("krun_add_console_port_inout(\(ProgressPort.name))",
                     krun_add_console_port_inout(ctx, UInt32(con), ProgressPort.name, p.guestInputFd, p.guestOutputFd))
        }
        // Host -> guest wall-clock time after a resume from suspend (fx-clock-sync.service).
        if let c = clockPort {
            try krun("krun_add_console_port_inout(\(ClockPort.name))",
                     krun_add_console_port_inout(ctx, UInt32(con), ClockPort.name, c.guestInputFd, c.guestOutputFd))
        }
        // Guest sleep requests (systemd-suspend.service) -> the launcher pauses the VM, and wakes.
        if let s = sleepPort {
            try krun("krun_add_console_port_inout(\(SleepPort.name))",
                     krun_add_console_port_inout(ctx, UInt32(con), SleepPort.name, s.guestInputFd, s.guestOutputFd))
        }
        // The Mac's controllers -> the guest's uinput gamepads (fx-pad.service, fx-pad@.service: one
        // port per player), their rumble back.
        for p in padPorts {
            try krun("krun_add_console_port_inout(\(p.name))",
                     krun_add_console_port_inout(ctx, UInt32(con), p.name, p.guestInputFd, p.guestOutputFd))
        }
        // The Mac's clipboard <-> SteamOS's (fx-clipboard-agent.service, ClipboardSync).
        if let c = clipboardPort {
            try krun("krun_add_console_port_inout(\(ClipboardPort.name))",
                     krun_add_console_port_inout(ctx, UInt32(con), ClipboardPort.name, c.guestInputFd, c.guestOutputFd))
        }

        try krun("krun_set_kernel", krun_set_kernel(ctx, o.kernel, STEAMAC_KERNEL_FORMAT_RAW, o.initrd, o.cmdline))

        for (i, d) in o.disks.enumerated() {
            let id = "vd" + String(UnicodeScalar(UInt8(97 + i)))
            if !d.readOnly { try DiskLock.hold(d.path) }
            try krun("krun_add_disk2(\(d.path))", krun_add_disk2(ctx, id, d.path, STEAMAC_DISK_FORMAT_RAW, d.readOnly))
            log("disk \(id): \(d.path)\(d.readOnly ? " (ro)" : "")")
        }

        // virtio-snd → CoreAudio default output (and default input while the guest records).
        if o.sound {
            if krun_has_feature(UInt64(KRUN_FEATURE_SND)) == 1 {
                try krun("krun_set_snd_device", krun_set_snd_device(ctx, true))
                hasSound = true
            } else {
                log("warning: this libkrun was built without SND=1; no guest audio")
            }
        }

        // GPU: Venus only (no virgl GL), host-visible shm window for blobs. virglrenderer (in this
        // process) opens the Vulkan driver named by VKR_VULKAN_DRIVER (its patch 0013).
        setenv("VKR_VULKAN_DRIVER", "@rpath/" + o.vulkanDriver.library, 1)
        setenv("VKR_GPU_BUDGET_MIB", String(o.gpuBudgetMiB), 1)
        OverlayView.vulkanDriver = o.vulkanDriver
        log("gpu: Venus → \(o.vulkanDriver.name), \(o.gpuBudgetMiB) MiB advertised memory budget")
        let flags = o.gpuFlags ?? (STEAMAC_VIRGL_VENUS | STEAMAC_VIRGL_NO_VIRGL)
        try krun("krun_set_gpu_options2", krun_set_gpu_options2(ctx, flags, UInt64(o.shmMiB) << 20))
        let (gw, gh) = o.guestSize
        displayId = UInt32(try krun("krun_add_display", krun_add_display(ctx, UInt32(gw), UInt32(gh))))
        let did = displayId
        try krun("krun_display_set_refresh_rate", krun_display_set_refresh_rate(ctx, did, UInt32(o.refreshRate)))
        // EDID physical size (drives the guest UI scale; libkrun's default of 300 DPI makes Steam ~2x).
        edid = EdidSize.resolve(o)
        try krun("krun_display_set_physical_size",
                 krun_display_set_physical_size(ctx, did, UInt16(clamping: edid.widthMM), UInt16(clamping: edid.heightMM)))
        displaySize = (gw, gh, edid.widthMM, edid.heightMM)
        log("display: \(gw)x\(gh) px" + (o.pixelScale > 1 ? " (window \(o.displayWidth)x\(o.displayHeight) pt, Retina \(o.pixelScale)x)" : "")
            + " → \(edid.widthMM)x\(edid.heightMM) mm (\(edid.source)); follows the window size at this DPI")
        var backend = display.makeCBackend()
        try krun("krun_set_display_backend", krun_set_display_backend(ctx, &backend, MemoryLayout<krun_display_backend>.size))

        if let inputs {
            guard krun_has_feature(UInt64(KRUN_FEATURE_INPUT)) == 1 else {
                throw OptionError("this libkrun was built without INPUT=1 (krun_has_feature(KRUN_FEATURE_INPUT) != 1); use --headless or the libkrun from work/out/host/lib")
            }
            try inputs.keyboard.attach(ctx: ctx)
            try inputs.tablet.attach(ctx: ctx)
            try inputs.mouse.attach(ctx: ctx)
        }

        if let netSocket { try Gvproxy.attach(ctx: ctx, socket: netSocket) }

        // macOS/aarch64: an eventfd wired to libkrun's gpio-keys device (graceful shutdown key).
        shutdownFd = krun_get_shutdown_eventfd(ctx)
        if shutdownFd < 0 { log("warning: krun_get_shutdown_eventfd: \(shutdownFd)"); shutdownFd = -1 }
    }

    /// A Finder launch starts with a soft RLIMIT_NOFILE of 256. virglrenderer runs in this process
    /// (render server and workers are threads) and every host-visible guest allocation is a POSIX
    /// shm: about four descriptors per mapped allocation (the memory's shm, the blob, the blob's
    /// resource, libkrun's export). A game past a few dozen of them ran out: the blob export failed
    /// ("proxy: invalid reply for blob"), then shm_open in vkAllocateMemory, and the guest's Venus
    /// context died at the memory's first use (STEAMAC-G). The soft limit goes to the most the
    /// kernel allows a process (kern.maxfilesperproc, at most the hard limit).
    static func raiseFileLimit() {
        var rl = rlimit()
        var perProc: Int32 = 0
        var size = MemoryLayout<Int32>.size
        guard getrlimit(RLIMIT_NOFILE, &rl) == 0,
              sysctlbyname("kern.maxfilesperproc", &perProc, &size, nil, 0) == 0, perProc > 0 else {
            log("warning: RLIMIT_NOFILE / kern.maxfilesperproc unreadable: \(String(cString: strerror(errno)))")
            return
        }
        let want = min(rl.rlim_max, rlim_t(perProc))
        guard rl.rlim_cur < want else { return }
        let was = rl.rlim_cur
        rl.rlim_cur = want
        if setrlimit(RLIMIT_NOFILE, &rl) == 0 {
            log("file descriptors: soft limit \(was) → \(want)")
        } else {
            log("warning: setrlimit(RLIMIT_NOFILE, \(want)): \(String(cString: strerror(errno))); soft limit stays \(was)")
        }
    }

    /// Runs the VMM on a dedicated thread. libkrun exit()s the process when the guest stops.
    func start() {
        running = true
        let t = Thread { [ctx] in
            let r = krun_start_enter(ctx)
            fatal("krun_start_enter failed: \(r) (\(String(cString: strerror(-r))))")
        }
        t.name = "krun-vmm"
        t.stackSize = 16 << 20
        t.qualityOfService = .userInteractive
        t.start()
    }

    /// Ask the guest to switch its display to `width`x`height` px at the boot DPI (any thread;
    /// libkrun regenerates the EDID and sends a display-change notification). No-op if unchanged.
    func resizeDisplay(width: Int, height: Int) {
        let (wmm, hmm) = edid.millimetres(width, height)
        guard (width, height, wmm, hmm) != displaySize else { return }
        let r = krun_display_resize(ctx, displayId, UInt32(width), UInt32(height), UInt16(clamping: wmm), UInt16(clamping: hmm))
        if r < 0 {
            log("display: resize to \(width)x\(height) failed: \(r) (\(String(cString: strerror(-r))))")
            return
        }
        displaySize = (width, height, wmm, hmm)
        log("display: resized to \(width)x\(height) px (\(wmm)×\(hmm) mm, same DPI)")
    }

    /// Press the guest power key (gpio-keys, KEY_RESTART in libkrun 1.19.6's FDT; systemd-logind
    /// shuts down and libkrun exits on PSCI SYSTEM_OFF/RESET). Returns false if unavailable.
    @discardableResult
    func requestShutdown() -> Bool {
        guard shutdownFd >= 0 else { return false }
        var one: UInt64 = 1
        return Darwin.write(shutdownFd, &one, 8) == 8
    }
}
