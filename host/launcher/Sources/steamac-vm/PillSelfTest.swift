import AppKit
import Carbon.HIToolbox
import CKrun
import Foundation

/// `--selftest-pill`: a real window + Metal view + FX overlay + progress pill + GPU-idle card +
/// no-picture guard, wired like a VM boot (WindowController.attach(progress:/stall:/noPicture:)),
/// with real (inactive) virtio input devices so clicks and keys take the real input path. Guest
/// lines go through the real fx.progress pipe; frames, scanout resizes and scanout disables go
/// through the real display vtable. Steps: a click during the update check collapses the overlay
/// into the pill (window title), the download re-expands it, clicks / keys during the download
/// keep it up (live MB/s), a menu collapse during the download is respected, clicking the pill /
/// the menu expand and collapse it, a click while Steam starts collapses it, `ready` fades it;
/// then the no-picture guard (display off 2 s / 3.5 s, black
/// frames 4 s / 5.5 s, non-black frame, game focus, sleep, a resize without a frame) and the
/// shutdown overlay collapsing into the pill. Each step writes the composite at 2x and the
/// window as the window server shows it (title bar included) and checks state + pixels.
enum PillSelfTest {
    enum Frames { case none, black, pattern }

    struct Step {
        let name: String
        let action: () -> Void
        let wait: Double
        let check: () -> String?
    }

    static func run(_ o: Options) -> Never {
        let app = SteamacApplication.shared
        app.setActivationPolicy(.regular)
        let display = DisplayBackend()
        let renderer = Renderer()
        let presenter = Presenter(display: display, renderer: renderer)
        display.sink = presenter
        let W = o.displayWidth, H = o.displayHeight
        let inputs = VMInputs(keyboard: InputDevices.keyboard(), tablet: InputDevices.tablet(), mouse: InputDevices.mouse())
        let title = OverlaySelfTest.windowTitleForTest
        let wc = WindowController(title: title, width: W, height: H, renderer: renderer, inputs: inputs, mouseMode: .auto)
        presenter.view = wc.view
        wc.view.metalLayer.framebufferOnly = false
        presenter.onScanoutResize = { w, h in wc.scanoutResized(width: w, height: h) }
        wc.onCloseRequest = { exit(2) }
        let outDir = o.selftestOut ?? FileManager.default.currentDirectoryPath
        try? FileManager.default.createDirectory(atPath: outDir, withIntermediateDirectories: true)

        let progress = BootProgress()
        wc.attach(progress: progress)
        // Constant counters: the GPU is idle all the time (the GPU-idle card shows for games).
        let stall = StallMonitor(view: wc.stallView) { (0, 0) }
        wc.attach(stall: stall)
        stall.enabled = true
        let noPicture = NoPictureGuard { presenter.scanout.probe(sampleIfNewerThan: $0) }
        wc.attach(noPicture: noPicture)
        let port: ProgressPort
        do { port = try ProgressPort() } catch { fatal("\(error)") }
        port.start { progress.guestLine($0) }
        func guest(_ s: String) {
            _ = (s + "\n").withCString { Darwin.write(port.guestOutputFd, $0, strlen($0)) }
        }

        wc.show()
        if LauncherSettings.shared.showOverlay { wc.overlay.show(animated: false) }
        log("pill selftest: window \(wc.window.windowNumber) backingScale=\(wc.window.backingScaleFactor)")

        // Black-test cost on a full-size frame (Scanout.darkFraction): 200 runs.
        let costBuffer = FrameBuffer(width: W, height: H, format: UInt32(KRUN_DISPLAY_FORMAT_B8G8R8X8_UNORM))
        let t0 = CACurrentMediaTime()
        var sink = 0.0
        for _ in 0..<200 { sink += Scanout.darkFraction(costBuffer) }
        let costUs = (CACurrentMediaTime() - t0) / 200 * 1e6
        log(String(format: "pill selftest: black test %.1f µs per frame (%dx%d, %d points, dark %.3f)",
                   costUs, W, H, Scanout.sampleColumns * Scanout.sampleRows, sink / 200))

        func windowPoint(unit ux: Double, _ uy: Double) -> NSPoint {
            let fit = wc.view.fitRect
            return wc.view.convert(NSPoint(x: fit.minX + CGFloat(ux) * fit.width, y: fit.maxY - CGFloat(uy) * fit.height), to: nil)
        }
        func click(_ p: NSPoint) {
            for type in [NSEvent.EventType.leftMouseDown, .leftMouseUp] {
                if let e = NSEvent.mouseEvent(with: type, location: p, modifierFlags: [], timestamp: ProcessInfo.processInfo.systemUptime,
                                              windowNumber: wc.window.windowNumber, context: nil, eventNumber: 0, clickCount: 1,
                                              pressure: type == .leftMouseDown ? 1 : 0) {
                    NSApp.sendEvent(e)
                }
            }
        }
        func key(_ code: Int) {
            for type in [NSEvent.EventType.keyDown, .keyUp] {
                if let e = NSEvent.keyEvent(with: type, location: .zero, modifierFlags: [], timestamp: ProcessInfo.processInfo.systemUptime,
                                            windowNumber: wc.window.windowNumber, context: nil, characters: "",
                                            charactersIgnoringModifiers: "", isARepeat: false, keyCode: UInt16(code)) {
                    _ = wc.processKey(e)
                }
            }
        }
        let pill = wc.pill
        func pillCenter() -> NSPoint { wc.view.convert(NSPoint(x: pill.cardFrame.midX, y: pill.cardFrame.midY), to: nil) }
        func status(_ s: String?) -> String { s.map { String(localized: "\(title) — \($0)") } ?? title }
        func expectTitle(_ s: String?) -> String? {
            wc.window.title == status(s) ? nil : "window title \"\(wc.window.title)\", expected \"\(status(s))\""
        }
        func overallPercent() -> Int { Int((progress.state.fraction * 100).rounded(.down)) }
        let downloading = BootProgress.localizedGuestText("Downloading Steam update")
        let checking = BootProgress.localizedGuestText("Checking for Steam updates")
        let starting = BootProgress.localizedGuestText("Starting Steam")
        let sampleCPU = "CPUVALUE"
        let sampleSeconds = 987   // < 1000: no digit grouping in the localized template
        func containsDetail(_ text: String, _ template: String) -> Bool {
            let pattern = NSRegularExpression.escapedPattern(for: template)
                .replacingOccurrences(of: sampleCPU, with: "[0-9]+\\.[0-9]")
                .replacingOccurrences(of: "\(sampleSeconds)", with: "[0-9]+")
            return text.range(of: pattern, options: .regularExpression) != nil
        }
        func expectPill(_ t: String, detail: String, percent: Bool) -> String? {
            guard pill.shown, !wc.overlay.shown else { return "expected the pill (overlay \(wc.overlay.shown), pill \(pill.shown))" }
            let c = pill.content
            guard c.title == t else { return "pill title \"\(c.title)\", expected \"\(t)\"" }
            guard detail.isEmpty || containsDetail(c.detail, detail) else { return "pill detail \"\(c.detail)\" lacks \"\(detail)\"" }
            if percent && c.percentText != "\(overallPercent())%" { return "pill percent \"\(c.percentText)\", expected \(overallPercent())%" }
            return nil
        }
        func expectOverlay() -> String? {
            wc.overlay.shown && !pill.shown ? nil : "expected the full overlay (overlay \(wc.overlay.shown), pill \(pill.shown))"
        }
        func expectNoPill(_ what: String) -> String? {
            !pill.shown ? nil : "\(what): pill should be hidden, shows \"\(pill.content.title)\" / \"\(pill.content.detail)\""
        }
        let waiting = NoPictureGuard.title

        // Frames: the driver thread presents `frames` at 20 Hz while it waits, plus a heartbeat a second.
        nonisolated(unsafe) var frames = Frames.pattern
        nonisolated(unsafe) var configure: (Int, Int)?
        nonisolated(unsafe) var disable = false

        let steps: [Step] = [
            Step(name: "01-check-overlay", action: {
                guest("stage session 100 Starting Steam session")
                guest("stage steam-check -1 Checking for Steam updates")
            }, wait: 0.8) {
                expectOverlay() ?? expectNoPill("overlay up") ?? expectTitle(checking + "…")
            },
            Step(name: "02-click-during-check-collapses", action: { click(windowPoint(unit: 0.5, 0.4)) }, wait: 0.9) {
                expectPill(checking, detail: "", percent: false) ?? expectTitle(checking + "…")
            },
            Step(name: "03-download-re-expands", action: {
                guest("stage steam-download 0 Downloading Steam update")
                guest("log 129 / 564 MB · 7.3 MB/s")
            }, wait: 0.8) {
                expectOverlay() ?? expectTitle(String(localized: "\(downloading) \(overallPercent())%"))
            },
            Step(name: "04a-click-during-download-keeps-overlay", action: { click(windowPoint(unit: 0.5, 0.4)) }, wait: 0.9) {
                expectOverlay() ?? expectTitle(String(localized: "\(downloading) \(overallPercent())%"))
            },
            Step(name: "04b-key-during-download-keeps-overlay", action: { key(kVK_ANSI_A) }, wait: 0.7) {
                expectOverlay()
            },
            Step(name: "05-live-update-in-overlay", action: {
                guest("stage steam-download 67 Downloading Steam update")
                guest("log 378 / 564 MB · 1.9 MB/s")
            }, wait: 0.7) {
                expectOverlay() ?? expectTitle(String(localized: "\(downloading) \(overallPercent())%"))
                    ?? (progress.state.detail == "378 / 564 MB · 1.9 MB/s" ? nil : "detail \(progress.state.detail)")
            },
            Step(name: "06a-menu-collapses-during-download", action: { wc.toggleOverlay() }, wait: 0.7) {
                expectPill(downloading, detail: "378 / 564 MB · 1.9 MB/s", percent: true)
            },
            Step(name: "06b-menu-collapse-respected", action: {
                guest("stage steam-download 89 Downloading Steam update")
                guest("log 501 / 564 MB · 3.8 MB/s")
            }, wait: 0.7) {
                expectPill(downloading, detail: "501 / 564 MB · 3.8 MB/s", percent: true)
                    ?? expectTitle(String(localized: "\(downloading) \(overallPercent())%"))
            },
            Step(name: "07-pill-click-expands", action: { click(pillCenter()) }, wait: 0.7) {
                expectOverlay()
            },
            Step(name: "08-menu-collapses", action: { wc.toggleOverlay() }, wait: 0.7) {
                expectPill(downloading, detail: "501 / 564 MB", percent: true)
            },
            Step(name: "09a-starting-steam", action: {
                guest("stage steam-install 100 Installing Steam update")
                guest("stage steam-start -1 Starting Steam")
            }, wait: 0.7) {
                expectPill(starting, detail: "", percent: false) ?? expectTitle(starting + "…")
                    ?? (pill.content.indeterminate ? nil : "pill should be indeterminate")
            },
            Step(name: "09b-menu-expands-at-start", action: { wc.toggleOverlay() }, wait: 0.7) {
                expectOverlay()
            },
            Step(name: "09c-click-during-start-collapses", action: { click(windowPoint(unit: 0.5, 0.4)) }, wait: 0.9) {
                expectPill(starting, detail: "", percent: false) ?? expectTitle(starting + "…")
            },
            Step(name: "10-ready-fades", action: { guest("ready") }, wait: 1.0) {
                progress.state.phase == .running && pill.isIdle && !wc.overlay.shown
                    ? expectTitle(nil) : "expected running, pill hidden + idle, overlay hidden"
            },
            Step(name: "11-display-off-2s", action: { disable = true; frames = .none }, wait: 2.0) {
                expectNoPill("display off 2 s")
            },
            Step(name: "12-display-off-3.5s", action: {}, wait: 1.5) {
                expectPill(waiting, detail: String(localized: "display off \(sampleSeconds) s"), percent: false)
                    ?? (pill.content.detail.contains(String(localized: "guest alive"))
                        && containsDetail(pill.content.detail, String(localized: "VM CPU \(sampleCPU) cores"))
                        ? nil : "detail lacks heartbeat / CPU: \(pill.content.detail)")
                    ?? expectTitle(nil)
            },
            Step(name: "13-picture-back-hides", action: { configure = (W, H); frames = .pattern }, wait: 0.8) {
                expectNoPill("non-black frame after display off")
            },
            Step(name: "14-black-4s", action: { frames = .black }, wait: 4.0) {
                expectNoPill("black 4 s")
            },
            Step(name: "15-black-5.5s", action: {}, wait: 1.5) {
                expectPill(waiting, detail: String(localized: "black picture \(sampleSeconds) s"), percent: false)
            },
            Step(name: "16-non-black-hides", action: { frames = .pattern }, wait: 0.8) {
                expectNoPill("non-black frame")
            },
            Step(name: "17-game-black-6s-never", action: { guest("focus game 4242"); frames = .black }, wait: 6.0) {
                expectNoPill("game focused, black 6 s") ?? (wc.stallView.shown ? nil : "GPU-idle card should cover the game")
            },
            Step(name: "18-steam-black-5.5s", action: { guest("focus steam") }, wait: 5.5) {
                expectPill(waiting, detail: String(localized: "black picture \(sampleSeconds) s"), percent: false)
            },
            Step(name: "19-sleep-hides", action: { wc.guestSleeping(true); noPicture.vmPaused = true }, wait: 6.0) {
                expectNoPill("SteamOS asleep, black 6 s")
            },
            Step(name: "20-awake-black-2s", action: { wc.guestSleeping(false); noPicture.vmPaused = false }, wait: 2.0) {
                expectNoPill("awake again, black 2 s (clock restarted)")
            },
            Step(name: "21-resize-no-frame-3.5s", action: { frames = .none; configure = (W - 256, H - 160) }, wait: 3.5) {
                expectPill(waiting, detail: String(localized: "no frame \(sampleSeconds) s"), percent: false)
            },
            Step(name: "22-new-size-frame-hides", action: { frames = .pattern }, wait: 0.8) {
                expectNoPill("frame at the new size")
            },
            Step(name: "23-shutdown-overlay", action: { configure = (W, H); guest("shutdown poweroff") }, wait: 0.8) {
                expectOverlay() ?? expectTitle(String(localized: "Shutting down…"))
            },
            Step(name: "24-shutdown-click-collapses", action: { click(windowPoint(unit: 0.5, 0.4)) }, wait: 0.9) {
                expectPill(String(localized: "Shutting down…"), detail: "", percent: true) ?? expectTitle(String(localized: "Shutting down…"))
            },
        ]

        let driver = Thread {
            let cb = display.makeCBackend()
            var inst: UnsafeMutableRawPointer?
            _ = cb.create!(&inst, cb.create_userdata, nil)
            let fb = cb.vtable.basic_framebuffer
            let fmt = UInt32(KRUN_DISPLAY_FORMAT_B8G8R8X8_UNORM)
            var size = (W, H)
            _ = fb.configure_scanout!(inst, 0, UInt32(W), UInt32(H), UInt32(W), UInt32(H), fmt)
            func present(_ f: Frames) {
                var ptr: UnsafeMutablePointer<UInt8>?
                var len = 0
                let id = fb.alloc_frame!(inst, 0, &ptr, &len)
                guard id >= 0, let ptr else { return }
                if f == .black { memset(ptr, 0, len) } else { SelfTest.fill(ptr, width: size.0, height: size.1, format: fmt, square: true) }
                _ = fb.present_frame!(inst, 0, UInt32(id), nil)
            }
            var lastAlive = 0.0
            func idle(_ seconds: Double) {
                let end = CACurrentMediaTime() + seconds
                while CACurrentMediaTime() < end {
                    if disable {
                        disable = false
                        _ = fb.disable_scanout!(inst, 0)
                    }
                    if let c = configure {
                        configure = nil
                        size = c
                        _ = fb.configure_scanout!(inst, 0, UInt32(c.0), UInt32(c.1), UInt32(c.0), UInt32(c.1), fmt)
                    }
                    if frames != .none { present(frames) }
                    let now = CACurrentMediaTime()
                    if now - lastAlive >= 1 {
                        lastAlive = now
                        guest("alive \(Int(ProcessInfo.processInfo.systemUptime * 1000)) 1.25")
                    }
                    Thread.sleep(forTimeInterval: 0.05)
                }
            }
            idle(0.5)

            var failures: [String] = []
            if costUs > 100 { failures.append(String(format: "black test too slow: %.1f µs", costUs)) }
            for step in steps {
                DispatchQueue.main.sync { step.action() }
                idle(step.wait)
                let sem = DispatchSemaphore(value: 0)
                nonisolated(unsafe) var shot: (CGImage?, CGImage?) = (nil, nil)
                DispatchQueue.main.sync {
                    if let msg = step.check() { failures.append("\(step.name): \(msg)") }
                    if let screen = wc.windowServerImage() {
                        do { try PNG.write(screen, to: "\(outDir)/pill-\(step.name)-screen.png") }
                        catch { failures.append("\(step.name): \(error)") }
                    }
                    wc.captureWindow { drawable, composite in shot = (drawable, composite); sem.signal() }
                }
                guard sem.wait(timeout: .now() + 5) == .success, let img = shot.1 else {
                    failures.append("\(step.name): capture timed out")
                    continue
                }
                let path = "\(outDir)/pill-\(step.name).png"
                do { try PNG.write(img, to: path) } catch { failures.append("\(step.name): \(error)") }
                failures += DispatchQueue.main.sync { pixelChecks(step.name, img, wc, patternBehind: frames == .pattern) }
                DispatchQueue.main.sync {
                    log("pill selftest: \(step.name) overlay=\(wc.overlay.shown ? "shown" : "hidden") pill="
                        + (pill.shown ? "\"\(pill.content.title)\" / \"\(pill.content.detail)\" \(pill.content.percentText)" : "hidden")
                        + " title=\"\(wc.window.title)\" -> \(path)")
                }
            }
            if failures.isEmpty {
                log("pill selftest: PASS (\(steps.count) steps) -> \(outDir)")
            } else {
                failures.forEach { log("pill selftest: FAIL \($0)") }
            }
            exit(failures.isEmpty ? 0 : 1)
        }
        driver.name = "pill-selftest"
        driver.start()
        NSApp.run()
        exit(0)
    }

    /// Pill shown: its padding is dark, the spinner has blue pixels, a determinate bar is blue left
    /// of the fraction and dark right of it, and (over the test pattern) the guest frame stays
    /// visible above the pill (top-left red quadrant). Hidden: nothing drawn at the pill's place
    /// beyond the guest frame (pattern: blue bottom-left quadrant left of centre).
    static func pixelChecks(_ name: String, _ img: CGImage, _ wc: WindowController, patternBehind: Bool) -> [String] {
        guard let px = OverlaySelfTest.pixels(img) else { return ["\(name): cannot read pixels"] }
        let view = wc.pill
        let scale = CGFloat(img.width) / view.bounds.width
        func at(_ p: CGPoint) -> (Int, Int, Int) {
            let x = max(0, min(img.width - 1, Int(p.x * scale))), y = max(0, min(img.height - 1, Int((view.bounds.height - p.y) * scale)))
            let i = (y * img.width + x) * 4
            return (Int(px[i]), Int(px[i + 1]), Int(px[i + 2]))
        }
        var f: [String] = []
        let card = view.cardFrame
        let pad = at(CGPoint(x: card.minX + 6, y: card.midY))
        if view.shown {
            if pad.0 > 75 || pad.1 > 80 || pad.2 > 90 { f.append("\(name): pill padding should be dark, got \(pad)") }
            var blue = 0
            for yi in 0..<Int(card.height) {
                let p = at(CGPoint(x: card.minX + 16 + 11, y: card.minY + CGFloat(yi)))
                if p.2 > 180 && p.0 < 160 { blue += 1 }
            }
            for xi in 0..<30 {
                let p = at(CGPoint(x: card.minX + 16 + CGFloat(xi), y: card.midY))
                if p.2 > 180 && p.0 < 160 { blue += 1 }
            }
            if blue < 2 { f.append("\(name): spinner not drawn") }
            let bar = view.barFrame
            if let fr = view.content.fraction, !view.content.indeterminate, !bar.isEmpty, fr > 0.1, fr < 0.9 {
                let filled = at(CGPoint(x: bar.minX + bar.width * CGFloat(fr) * 0.5, y: bar.midY))
                let empty = at(CGPoint(x: bar.minX + bar.width * (CGFloat(fr) + 1) / 2, y: bar.midY))
                if filled.2 < 150 { f.append("\(name): pill bar not blue left of \(Int(fr * 100))%: \(filled)") }
                if empty.2 > 120 { f.append("\(name): pill bar should be empty right of \(Int(fr * 100))%: \(empty)") }
            }
            if patternBehind && !wc.overlay.shown {
                let b = view.bounds
                let probe = at(CGPoint(x: b.width * 0.08, y: b.height * 0.85))
                if probe.0 < 200 || probe.1 > 60 { f.append("\(name): guest frame should stay visible above the pill, got \(probe)") }
            }
        } else if !view.isHidden && view.alphaValue > 0.01 {
            f.append("\(name): hidden pill should be isHidden (alpha \(view.alphaValue))")
        } else if patternBehind && !wc.overlay.shown && wc.view.fitRect.width >= view.bounds.width - 1 {
            if pad.2 < 150 || pad.0 > 100 { f.append("\(name): guest frame (blue quadrant) should show where the pill was, got \(pad)") }
        }
        return f
    }
}
