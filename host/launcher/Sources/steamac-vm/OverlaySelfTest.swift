import AppKit
import CKrun
import Foundation

/// `--selftest-overlay`: a real window + Metal view + FX overlay, driven exactly like a boot:
/// console bytes go through LineSplitter → BootProgress.consoleLine, guest lines are written into
/// the real fx.progress pipe (the fd libkrun would write) and read back by ProgressPort's thread.
/// At each step it captures the presented drawable with the overlay composited at 2x, writes a
/// PNG and checks state + pixels (overlay visible/hidden, bar fill position).
enum OverlaySelfTest {
    struct Step {
        let name: String
        let console: String
        let guest: String
        let wait: Double
        let check: (BootProgress, OverlayView) -> String?
    }

    static func run(_ o: Options) -> Never {
        let app = SteamacApplication.shared
        app.setActivationPolicy(.regular)
        let display = DisplayBackend()
        let renderer = Renderer()
        let presenter = Presenter(display: display, renderer: renderer)
        display.sink = presenter
        let W = o.displayWidth, H = o.displayHeight
        let wc = WindowController(title: windowTitleForTest, width: W, height: H, renderer: renderer, inputs: nil, mouseMode: .auto)
        presenter.view = wc.view
        wc.view.metalLayer.framebufferOnly = false
        presenter.onScanoutResize = { w, h in wc.scanoutResized(width: w, height: h) }
        wc.onCloseRequest = { exit(2) }
        let outDir = o.selftestOut ?? FileManager.default.currentDirectoryPath
        try? FileManager.default.createDirectory(atPath: outDir, withIntermediateDirectories: true)

        let progress = BootProgress()
        var rebootIntents = 0
        progress.onRebootIntent = { rebootIntents += 1 }
        wc.attach(progress: progress)
        let port: ProgressPort
        do { port = try ProgressPort() } catch { fatal("\(error)") }
        port.start { progress.guestLine($0) }
        var splitter = LineSplitter()
        func console(_ s: String) {
            var bytes = Array(s.utf8)
            bytes.withUnsafeMutableBytes { p in splitter.feed(UnsafeRawBufferPointer(p)) { progress.consoleLine($0) } }
        }
        func guest(_ s: String) {
            _ = s.withCString { Darwin.write(port.guestOutputFd, $0, strlen($0)) }
        }

        wc.show()
        wc.overlay.show(animated: false)
        log("overlay selftest: window \(wc.window.windowNumber) backingScale=\(wc.window.backingScaleFactor)")

        let ok = "[\u{1b}[0;32m  OK  \u{1b}[0m] "
        let startedLines = (1...40).map { "\(ok)Started Example Service \($0).\r\n" }.joined()
        let stoppedLines = (1...30).map { "\(ok)Stopped Example Service \($0).\r\n" }.joined()
        func near(_ a: Double, _ b: Double) -> Bool { abs(a - b) < 0.005 }
        let steps: [Step] = [
            Step(name: "01-vm", console: "", guest: "", wait: 0.8) { p, ov in
                p.state.stageId == "vm" && ov.shown ? nil : "expected vm stage, overlay shown" },
            Step(name: "02-kernel", console: "[    0.000000] Booting Linux on physical CPU 0x0000000000 [0x610f0000]\n",
                 guest: "", wait: 0.6) { p, _ in
                p.state.stageId == "kernel" && near(p.state.fraction, 0.03) ? nil : "expected kernel 3%, got \(p.state)" },
            Step(name: "03-systemd", console: "steamac-init: switching to rootfs-A (/dev/vda4), init /sbin/init\r\n\r\nWelcome to \u{1b}[1mSteamOS\u{1b}[0m!\r\n" + startedLines,
                 guest: "", wait: 0.8) { p, _ in
                p.state.stageId == "systemd" && p.state.fraction > 0.2 && p.state.fraction < 0.3
                    && p.state.detail == "Started Example Service 40" ? nil : "expected systemd 20-30%, got \(p.state)" },
            Step(name: "04-download", console: "\(ok)Reached target \u{1b}[0;1;39mGraphical Interface\u{1b}[0m.\r\n",
                 guest: "stage session 100 Starting Steam session\nstage steam-check 100 Checking for Steam updates\n"
                    + "stage steam-download 37 Downloading Steam update\nlog 245 / 662 MB · 12.4 MB/s\n", wait: 0.8) { p, _ in
                p.state.stageId == "steam-download" && near(p.state.fraction, 0.40 + 0.45 * 0.37)
                    && p.state.detail == "245 / 662 MB · 12.4 MB/s" ? nil : "expected download 56.65%, got \(p.state)" },
            Step(name: "05-starting", console: "", guest: "stage steam-install 100 Installing\nstage steam-start -1 Starting Steam\n",
                 wait: 0.9) { p, _ in
                p.state.stageId == "steam-start" && p.state.indeterminate && near(p.state.fraction, 0.95)
                    ? nil : "expected indeterminate steam-start, got \(p.state)" },
            Step(name: "06-ready-hidden", console: "", guest: "ready\n", wait: 1.4) { p, ov in
                p.state.phase == .running && ov.isIdle ? nil : "expected running + overlay hidden and idle (hidden=\(ov.isHidden))" },
            Step(name: "07-shutting-down", console: "         Stopping Session 2 of User steamos...\r\n\(ok)Stopped target Graphical Interface.\r\n" + stoppedLines,
                 guest: "", wait: 1.0) { p, ov in
                p.state.phase == .shutdown(reboot: false) && ov.shown && p.state.fraction > 0.4 && p.state.fraction < 0.9
                    ? nil : "expected shutdown in progress with overlay shown, got \(p.state)" },
            Step(name: "08-final-step", console: "\(ok)Reached target \u{1b}[0;1;39mFinal Step\u{1b}[0m.\r\n", guest: "", wait: 0.6) { p, _ in
                near(p.state.fraction, 0.95) ? nil : "expected 95% at Final Step, got \(p.state)" },
            Step(name: "09-restarting", console: "", guest: "shutdown reboot\n", wait: 0.6) { p, ov in
                p.state.phase == .shutdown(reboot: true) && ov.currentTitle == String(localized: "Restarting…") && rebootIntents == 1
                    ? nil : "expected Restarting… + one reboot intent, got \(p.state) intents=\(rebootIntents)" },
            Step(name: "10-power-down", console: "[  123.456789] reboot: Restarting system\r\n", guest: "", wait: 0.6) { p, _ in
                near(p.state.fraction, 1) ? nil : "expected 100%, got \(p.state)" },
        ]

        let driver = Thread {
            // Guest picture behind the overlay (quadrants), through the real display vtable.
            let cb = display.makeCBackend()
            var inst: UnsafeMutableRawPointer?
            _ = cb.create!(&inst, cb.create_userdata, nil)
            let fb = cb.vtable.basic_framebuffer
            let fmt = UInt32(KRUN_DISPLAY_FORMAT_B8G8R8X8_UNORM)
            _ = fb.configure_scanout!(inst, 0, UInt32(W), UInt32(H), UInt32(W), UInt32(H), fmt)
            var ptr: UnsafeMutablePointer<UInt8>?
            var size = 0
            let id = fb.alloc_frame!(inst, 0, &ptr, &size)
            SelfTest.fill(ptr!, width: W, height: H, format: fmt, square: true)
            _ = fb.present_frame!(inst, 0, UInt32(id), nil)

            var failures: [String] = []
            for step in steps {
                DispatchQueue.main.sync {
                    if !step.console.isEmpty { console(step.console) }
                    if !step.guest.isEmpty { guest(step.guest) }
                }
                Thread.sleep(forTimeInterval: step.wait)
                let sem = DispatchSemaphore(value: 0)
                nonisolated(unsafe) var shot: CGImage?
                DispatchQueue.main.sync {
                    if let msg = step.check(progress, wc.overlay) { failures.append("\(step.name): \(msg)") }
                    wc.captureWindow { _, composite in shot = composite; sem.signal() }
                }
                guard sem.wait(timeout: .now() + 5) == .success, let img = shot else {
                    failures.append("\(step.name): capture timed out")
                    continue
                }
                let path = "\(outDir)/overlay-\(step.name).png"
                do { try PNG.write(img, to: path) } catch { failures.append("\(step.name): \(error)") }
                failures += DispatchQueue.main.sync { pixelChecks(step.name, img, wc, progress.state) }
                log("overlay selftest: \(step.name) \(progress.state.stageId) \(Int(progress.state.fraction * 100))% "
                    + "overlay=\(wc.overlay.shown ? "shown" : "hidden") -> \(path)")
            }
            // Host-requested power-off must never be mistaken for a reboot (libkrun's power key is KEY_RESTART).
            DispatchQueue.main.sync {
                let p2 = BootProgress()
                var intents = 0
                p2.onRebootIntent = { intents += 1 }
                p2.consoleLine("Welcome to SteamOS!")
                p2.hostRequestedShutdown()
                p2.consoleLine("[  OK  ] Reached target System Reboot.")
                p2.consoleLine("reboot: Restarting system")
                if intents != 0 || p2.state.phase != .shutdown(reboot: false) {
                    failures.append("host power-off was treated as reboot: \(p2.state) intents=\(intents)")
                }
            }
            if failures.isEmpty {
                log("overlay selftest: PASS (\(steps.count) steps) -> \(outDir)")
            } else {
                failures.forEach { log("overlay selftest: FAIL \($0)") }
            }
            exit(failures.isEmpty ? 0 : 1)
        }
        driver.name = "overlay-selftest"
        driver.start()
        NSApp.run()
        exit(0)
    }

    static let windowTitleForTest = "FX Steam Launcher"

    /// Overlay visible → background is the dark gradient where the guest frame is red;
    /// hidden → the guest frame shows. Determinate bar: blue fill left of the fraction, track right of it.
    static func pixelChecks(_ name: String, _ img: CGImage, _ wc: WindowController, _ s: ProgressState) -> [String] {
        guard let px = pixels(img) else { return ["\(name): cannot read pixels"] }
        let scale = CGFloat(img.width) / wc.overlay.bounds.width
        func at(_ p: CGPoint) -> (Int, Int, Int) {
            let x = min(img.width - 1, Int(p.x * scale)), y = min(img.height - 1, Int((wc.overlay.bounds.height - p.y) * scale))
            let i = (y * img.width + x) * 4
            return (Int(px[i]), Int(px[i + 1]), Int(px[i + 2]))
        }
        var f: [String] = []
        let b = wc.overlay.bounds
        let probe = at(CGPoint(x: b.width * 0.08, y: b.height * 0.85))   // guest frame: red quadrant
        if wc.overlay.shown {
            if probe.0 > 60 { f.append("\(name): overlay should cover the guest frame, got \(probe)") }
            if !s.indeterminate && s.fraction > 0.1 && s.fraction < 0.9 {
                let bar = wc.overlay.barFrame
                let filled = at(CGPoint(x: bar.minX + bar.width * CGFloat(s.fraction) * 0.5, y: bar.midY))
                let empty = at(CGPoint(x: bar.minX + bar.width * (CGFloat(s.fraction) + 1) / 2, y: bar.midY))
                if filled.2 < 150 { f.append("\(name): bar fill not blue at \(Int(s.fraction * 50))%: \(filled)") }
                if empty.2 > 120 { f.append("\(name): bar should be empty past the fraction: \(empty)") }
            }
        } else if probe.0 < 200 || probe.1 > 60 {
            f.append("\(name): hidden overlay should reveal the guest frame (red), got \(probe)")
        }
        return f
    }

    static func pixels(_ img: CGImage) -> [UInt8]? {
        var buf = [UInt8](repeating: 0, count: img.width * img.height * 4)
        let ok = buf.withUnsafeMutableBytes { p -> Bool in
            guard let ctx = CGContext(data: p.baseAddress, width: img.width, height: img.height, bitsPerComponent: 8,
                                      bytesPerRow: img.width * 4, space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                      bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue) else { return false }
            ctx.draw(img, in: CGRect(x: 0, y: 0, width: img.width, height: img.height))
            return true
        }
        return ok ? buf : nil
    }
}
