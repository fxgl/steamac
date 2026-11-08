import AppKit
import SwiftUI

/// `--selftest-settings [--selftest-out DIR]`: open the Settings window without a VM, write
/// DIR/settings-<tab>.png for every tab (command-line overrides of this run are shown as in a
/// real run), then DIR/settings-create-disk.png of the "Create New Disk…" window,
/// DIR/settings-first-run.png of the first-run alert, DIR/settings-what-is-sent.png (the crash
/// reports popover), DIR/settings-display-presets.png (window size popup open; screen capture),
/// DIR/settings-display-custom.png (Custom… fields) and DIR/settings-advanced-custom.png (custom VM
/// size with its warnings), and check that each capture has content.
/// Also checks that crash-report scrubbing redacts the user, host, computer and Bonjour names,
/// that a guest process's GPU teardown is no crash report (LineScanner), and the automatic VM size
/// (VMSizing) on simulated Macs, the update check's version ordering and release selection,
/// the Mac time zone and clock format kernel parameters (MacTime), and the clipboard port's frame codec and
/// concealed-item filter (ClipboardSync), plus shared-library preferences and boot arguments.
enum SettingsSelfTest {
    /// Use a private preferences domain, like ProvisionSelfTest's disk-selection checks.
    private static func sharedLibrarySelfCheck() -> [String] {
        let domain = "es.fxgam.steamac.selftest-share-library-\(UUID().uuidString)"
        let previousDomain = getenv("STEAMAC_DEFAULTS_DOMAIN").map { String(cString: $0) }
        setenv("STEAMAC_DEFAULTS_DOMAIN", domain, 1)
        let settings = LauncherSettings()
        defer {
            settings.defaults.removePersistentDomain(forName: domain)
            if let previousDomain { setenv("STEAMAC_DEFAULTS_DOMAIN", previousDomain, 1) }
            else { unsetenv("STEAMAC_DEFAULTS_DOMAIN") }
        }
        var failures: [String] = []
        func check(_ ok: Bool, _ name: String) {
            if !ok { failures.append("shared library: \(name)") }
        }
        check(settings.sharedLibrary && Options().shareLibrary, "default is on")
        check(LauncherSettings.Key.sharedLibrary.nextStart, "key applies on next start")
        check(settings.set("sharedLibrary", "off") && !settings.sharedLibrary, "debug set off")
        check(settings.defaults.object(forKey: "sharedLibrary") as? Bool == false, "off is persisted")
        check(!LauncherSettings().sharedLibrary, "off is loaded")
        check(!settings.set("sharedLibrary", "invalid") && !settings.sharedLibrary, "invalid debug value rejected")
        check(settings.set("sharedLibrary", "on") && settings.sharedLibrary, "debug set on")
        check(LauncherSettings().sharedLibrary, "on is loaded")
        settings.noteBoot(overrides: [:], autoCapture: nil)
        check(!settings.restartPending, "initial boot snapshot")
        settings.sharedLibrary = false
        check(settings.restartPending, "changing the preference needs a restart")
        settings.sharedLibrary = true
        check(!settings.restartPending, "restoring the preference clears restart")
        settings.noteBoot(overrides: [.sharedLibrary: "--no-share-library"], autoCapture: nil)
        settings.sharedLibrary = false
        check(!settings.restartPending, "CLI override is excluded from restart tracking")
        settings.resetAll()
        check(settings.sharedLibrary && LauncherSettings().sharedLibrary, "reset restores default")
        check(settings.defaults.object(forKey: "sharedLibrary") == nil, "reset removes saved key")
        let folder = NSTemporaryDirectory() + "steamac-share-library-\(UUID().uuidString)"
        do {
            try FileManager.default.createDirectory(atPath: folder, withIntermediateDirectories: false)
            defer { try? FileManager.default.removeItem(atPath: folder) }
            let boot = folder + "/boot"
            try Data().write(to: URL(fileURLWithPath: boot))
            let base = ["steamac-vm", "--kernel", boot, "--disk", boot, "--no-ssh",
                        "--headless", "--frame-dump", "/dev/null", "--vulkan-driver", "moltenvk"]
            let cases: [(String, String, Bool, [String], [String], String?)] = [
                ("no folder", "", true, [], [], nil),
                ("folder enabled", folder, true, [], ["1"], nil),
                ("folder disabled", folder, false, [], [], nil),
                ("missing saved folder", folder + "/missing", true, [], [], nil),
                ("no share", folder, true, ["--no-share"], [], nil),
                ("CLI folder", "", true, ["--share", folder], ["1"], nil),
                ("CLI on", folder, false, ["--share-library"], ["1"], "--share-library"),
                ("CLI off", folder, true, ["--no-share-library"], [], "--no-share-library"),
                ("CLI on without folder", "", false, ["--share-library"], [], "--share-library"),
                ("CLI last on", folder, false, ["--no-share-library", "--share-library"], ["1"], "--share-library"),
                ("CLI last off", folder, true, ["--share-library", "--no-share-library"], [], "--no-share-library"),
                ("cmdline off", folder, true, ["--cmdline", "steamac.share_library=0"], ["0"], nil),
                ("cmdline on", folder, false, ["--cmdline", "steamac.share_library=1"], ["1"], nil),
            ]
            for (name, path, enabled, flags, expected, override) in cases {
                settings.sharedFolder = path
                settings.sharedLibrary = enabled
                let (options, overrides) = try Options.resolve(base + flags, settings: settings)
                let prefix = "steamac.share_library="
                let values = options.cmdline.split(separator: " ").filter { $0.hasPrefix(prefix) }
                    .map { String($0.dropFirst(prefix.count)) }
                check(values == expected, "\(name): boot argument \(values), expected \(expected)")
                check(overrides[.sharedLibrary] == override, "\(name): CLI override note")
                check(options.shareLibrary == (override.map { $0 == "--share-library" } ?? enabled),
                      "\(name): effective option")
                check(settings.sharedLibrary == enabled && LauncherSettings().sharedLibrary == enabled,
                      "\(name): one-run override did not change saved preference")
            }
            settings.sharedFolder = folder
            settings.sharedLibrary = true
            let mount = "/home/steamos/OtherShare"
            let (options, _) = try Options.resolve(base + ["--cmdline", "steamac.share=\(mount)"], settings: settings)
            let mounts = options.cmdline.split(separator: " ").filter { $0.hasPrefix("steamac.share=") }
            check(mounts == [Substring("steamac.share=\(mount)")], "explicit share mount is preserved")
            check(options.cmdline.split(separator: " ").contains("steamac.share_library=1"),
                  "library enabled with an explicit share mount")
        } catch {
            failures.append("shared library: \(error)")
        }
        log("selftest-settings: shared library: \(failures.isEmpty ? "ok" : "FAIL: \(failures.joined(separator: "; "))")")
        return failures
    }

    static func run(_ o: Options, overrides: [LauncherSettings.Key: String]) -> Never {
        let settings = LauncherSettings.shared
        let profileID = 2147483646
        let profileTestEnv = "STEAMAC_SELFTEST=\(profileID)"
        let savedProfile = settings.profile(for: profileID)
        let savedName = settings.gameName(profileID)
        settings.setGameName("A Profile self-test", for: profileID)
        settings.setProfile(GameProfile(gfx: "dxmt", driver: LauncherSettings.VulkanDriver.preferred.rawValue,
                                        env: profileTestEnv), for: profileID)
        settings.noteBoot(overrides: overrides, autoCapture: o.autoCapture)
        let app = NSApplication.shared
        app.setActivationPolicy(.regular)
        let context = SettingsContext(settings: settings, sound: nil, restart: { log("selftest: Restart VM pressed") },
                                      vmHasPad: o.gamepad, vmHasSound: o.sound)
        let sw = SettingsWindowController(context: context)
        final class Target: NSObject { var sw: SettingsWindowController?; @objc func open() { sw?.show() } }
        let target = Target()
        target.sw = sw
        MainMenu.installMinimal(settings: (#selector(Target.open), target))
        let dir = o.selftestOut ?? "."
        try? FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
        // Crash-report scrubbing: the user, host, computer and Bonjour names never leave the Mac.
        var failures = CrashReporting.scrubSelfCheck() + CrashReporting.scannerSelfCheck() + CrashReporting.exitSelfCheck()
            + VMSizing.selfCheck()
            + UpdateChecker.selfCheck() + MacTime.selfCheck() + Options.shareMountSelfCheck() + KeyboardLayoutSync.selfCheck() + ClipboardSync.selfCheck() + GameProfile.selfCheck()
            + SteamControllerRouting.selfCheck() + GenericHIDRouting.selfCheck()
            + sharedLibrarySelfCheck()
        let savedVirtualPad = settings.virtualPad
        let savedPadType = settings.padType
        context.needsInputMonitoring = true
        settings.virtualPad = true
        for type in [LauncherSettings.PadType.auto, .steamController, .dualSense, .dualShock4, .xbox360] {
            settings.padType = type
            let expected = type == .auto || type == .steamController
            if context.showsInputMonitoringWarning != expected {
                failures.append("Input Monitoring warning: wrong visibility for \(type)")
            }
        }
        settings.padType = .auto
        settings.virtualPad = false
        if context.showsInputMonitoringWarning { failures.append("Input Monitoring warning: passthrough disabled") }
        settings.virtualPad = true
        context.needsInputMonitoring = false
        if context.showsInputMonitoringWarning { failures.append("Input Monitoring warning: permission not needed") }
        settings.virtualPad = savedVirtualPad
        settings.padType = savedPadType
        var tabs = SettingsWindowController.Tab.allCases[...]

        func capture(_ name: String, _ rep: NSBitmapImageRep?) {
            let path = "\(dir)/settings-\(name).png"
            guard let rep, let png = rep.representation(using: .png, properties: [:]) else {
                failures.append("\(name): no capture")
                return
            }
            do {
                try png.write(to: URL(fileURLWithPath: path))
                // Text and controls: a dense sample grid over the content area must find many colours.
                let n = 48
                let distinct = Set((0..<(n * n)).map { i -> UInt32 in
                    let c = rep.colorAt(x: (i % n) * rep.pixelsWide / n, y: (i / n) * rep.pixelsHigh / n)
                    return c.map { UInt32(($0.redComponent * 255).rounded()) << 16 | UInt32(($0.greenComponent * 255).rounded()) << 8
                        | UInt32(($0.blueComponent * 255).rounded()) } ?? 0
                })
                log("selftest-settings: \(path) \(rep.pixelsWide)x\(rep.pixelsHigh), \(distinct.count) distinct sample colours")
                if distinct.count < 8 { failures.append("\(name): blank capture") }
            } catch {
                failures.append("\(name): \(error)")
            }
        }

        func finish() {
            settings.removeGame(profileID)
            if settings.profile(for: profileID) != GameProfile() { failures.append("profiles: removeGame retained profile") }
            if let savedName { settings.setGameName(savedName, for: profileID) }
            settings.setProfile(savedProfile, for: profileID)
            log("selftest-settings: \(failures.isEmpty ? "PASS" : "FAIL: " + failures.joined(separator: ", "))")
            exit(failures.isEmpty ? 0 : 1)
        }

        /// SwiftUI menu pickers (SwiftUIPopupButton, an NSButton with a menu).
        func popups(in view: NSView?) -> [NSButton] {
            guard let view else { return [] }
            if let b = view as? NSButton, "\(type(of: b))".contains("Popup") { return [b] }
            return view.subviews.flatMap { popups(in: $0) }
        }

        /// The Display tab with the real window-size popup items drawn next to it (a popup menu is
        /// its own window, which cacheDisplay cannot draw and screen capture needs permission for).
        func withMenuItems(_ tab: NSBitmapImageRep, _ items: [String], selected: String) -> NSBitmapImageRep? {
            let font = NSFont.menuFont(ofSize: 13), rowH: CGFloat = 22, pad: CGFloat = 6
            let attrs: [NSAttributedString.Key: Any] = [.font: font, .foregroundColor: NSColor.labelColor]
            let menuW = (items.map { ($0 as NSString).size(withAttributes: attrs).width }.max() ?? 100) + 44
            let menuH = items.reduce(pad * 2) { $0 + ($1 == "----" ? 11 : rowH) }
            let size = NSSize(width: tab.size.width + menuW + 24, height: max(tab.size.height, menuH + 40))
            let scale = CGFloat(tab.pixelsWide) / tab.size.width
            guard let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: Int(size.width * scale), pixelsHigh: Int(size.height * scale),
                                             bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
                                             colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0) else { return nil }
            rep.size = size
            NSGraphicsContext.saveGraphicsState()
            NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
            NSColor.windowBackgroundColor.setFill()
            NSRect(origin: .zero, size: size).fill()
            tab.draw(in: NSRect(x: 0, y: size.height - tab.size.height, width: tab.size.width, height: tab.size.height))
            let menuRect = NSRect(x: tab.size.width + 12, y: size.height - 30 - menuH, width: menuW, height: menuH)
            NSColor.controlBackgroundColor.setFill()
            NSColor.separatorColor.setStroke()
            let path = NSBezierPath(roundedRect: menuRect, xRadius: 6, yRadius: 6)
            path.fill()
            path.stroke()
            ("Window size popup (items read from the live menu)" as NSString)
                .draw(at: NSPoint(x: menuRect.minX, y: menuRect.maxY + 8),
                      withAttributes: [.font: NSFont.systemFont(ofSize: 11), .foregroundColor: NSColor.secondaryLabelColor])
            var y = menuRect.maxY - pad
            for item in items {
                if item == "----" {
                    y -= 11
                    NSColor.separatorColor.setFill()
                    NSRect(x: menuRect.minX + 10, y: y + 5, width: menuW - 20, height: 1).fill()
                    continue
                }
                y -= rowH
                if item == selected { ("✓" as NSString).draw(at: NSPoint(x: menuRect.minX + 10, y: y + 3), withAttributes: attrs) }
                (item as NSString).draw(at: NSPoint(x: menuRect.minX + 28, y: y + 3), withAttributes: attrs)
            }
            NSGraphicsContext.restoreGraphicsState()
            return rep
        }

        /// Background mute: a SoundControl with a recording krun_snd_set_volume shim, driven by
        /// simulated NSApplication resign/become-active notifications and user mute changes.
        func backgroundMute(then done: @escaping () -> Void) {
            var calls: [(Float, Bool)] = []
            let sound = SoundControl(volumeShim: { _, g, m in calls.append((g, m)); return 0 })
            let nc = NotificationCenter.default
            var steps: [(String, () -> Void, ([(Float, Bool)]) -> Bool)] = [
                ("attach", { sound.attach(ctx: 7, volume: 0.8, mute: false, muteInBackground: true) },
                 { $0.count == 1 && $0[0] == (0.8, false) }),
                ("resign active: fade out + mute", { nc.post(name: NSApplication.didResignActiveNotification, object: nil) },
                 { c in c.last! == (0.8, true) && c.count >= 3 && c.dropLast().allSatisfy { !$0.1 }
                     && zip(c.dropLast(), c.dropLast().dropFirst()).allSatisfy { $0.0 > $1.0 } }),
                ("become active: unmute + fade in", { nc.post(name: NSApplication.didBecomeActiveNotification, object: nil) },
                 { c in c.first! == (0, false) && c.last! == (0.8, false) && c.allSatisfy { !$0.1 } }),
                ("user mute", { sound.setUser(volume: 0.8, mute: true) }, { $0.count == 1 && $0[0] == (0.8, true) }),
                ("resign while user-muted", { nc.post(name: NSApplication.didResignActiveNotification, object: nil) }, { $0.isEmpty }),
                ("become active while user-muted", { nc.post(name: NSApplication.didBecomeActiveNotification, object: nil) }, { $0.isEmpty }),
                ("user unmute", { sound.setUser(volume: 0.8, mute: false) }, { $0.count == 1 && $0[0] == (0.8, false) }),
                ("option off", { sound.setMuteInBackground(false) }, { $0.isEmpty }),
                ("resign with option off", { nc.post(name: NSApplication.didResignActiveNotification, object: nil) }, { $0.isEmpty }),
                ("option on while inactive: fade out + mute", { sound.setMuteInBackground(true) }, { $0.last.map { $0 == (0.8, true) } ?? false }),
                ("become active", { nc.post(name: NSApplication.didBecomeActiveNotification, object: nil) }, { $0.last.map { $0 == (0.8, false) } ?? false }),
            ]
            func step() {
                guard !steps.isEmpty else {
                    sound.detach(reason: "selftest done")
                    return done()
                }
                let (name, action, check) = steps.removeFirst()
                calls.removeAll()
                action()
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.4) {
                    let text = calls.map { "(\(String(format: "%.2f", $0.0)), \($0.1 ? "mute" : "on"))" }.joined(separator: " ")
                    let ok = check(calls)
                    log("selftest-settings: background mute: \(name): \(ok ? "ok" : "FAIL") \(text)")
                    if !ok { failures.append("background mute: \(name): \(text)") }
                    step()
                }
            }
            step()
        }

        /// Display tab: open the real window-size popup, check its items (every size preset, Fit to screen,
        /// Custom…) → DIR/settings-display-presets.{txt,png}, then reveal "Custom…"
        /// (settings-display-custom.png). The saved window size is restored afterwards.
        func displayPresets(then done: @escaping () -> Void) {
            let saved = (settings.windowSizePreset, settings.windowWidth, settings.windowHeight)
            let customTitle = String(localized: "Custom…")
            let fit = LauncherSettings.fitToScreenSize()
            let fitTitle = String(localized: "Fit to screen (\(String(fit.0)) × \(String(fit.1)))")
            let presetTitles = LauncherSettings.sizePresets.map { p in
                String(localized: "\(String(p.width)) × \(String(p.height)) (\(p.label))")
            }
            let largerPresetTitles = LauncherSettings.sizePresets.map { p in
                String(localized: "\(String(p.width)) × \(String(p.height)) (\(p.label)) — larger than this screen")
            }
            sw.show(tab: .display)
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.8) {
                guard let popup = popups(in: sw.window.contentView)
                    .first(where: { presetTitles.contains($0.title) || largerPresetTitles.contains($0.title)
                        || $0.title == fitTitle || $0.title == customTitle }) else {
                    failures.append("display-presets: no window size popup")
                    return done()
                }
                let selected = popup.title
                let tabShot = sw.snapshot()
                func itemTitles() -> [String] { popup.menu?.items.map { $0.isSeparatorItem ? "----" : $0.title } ?? [] }
                // SwiftUI fills the picker's menu only when it opens. Read the items the moment
                // tracking begins, then close it. While another app is frontmost (the Mac in use)
                // an open can fail — tracking never starts, or ends at once when the other app
                // takes activation — so re-activate and retry a few times.
                var titles: [String] = []
                var attempts = 0
                let nc = NotificationCenter.default
                let began = nc.addObserver(forName: NSMenu.didBeginTrackingNotification, object: nil, queue: nil) { n in
                    guard let menu = n.object as? NSMenu, menu === popup.menu else { return }
                    titles = itemTitles()
                    DispatchQueue.main.async { menu.cancelTracking() }
                }
                DispatchQueue.main.async {
                    while titles.isEmpty && attempts < 4 {
                        attempts += 1
                        NSApp.activate()
                        sw.window.makeKeyAndOrderFront(nil)
                        // Safety net: never leave the menu open if the notification was missed.
                        let timer = Timer(timeInterval: 1, repeats: false) { _ in
                            if titles.isEmpty { titles = itemTitles() }
                            popup.menu?.cancelTracking()
                        }
                        RunLoop.main.add(timer, forMode: .common)
                        popup.performClick(nil)   // returns when the menu closes (or at once if it did not open)
                        timer.invalidate()
                        if titles.isEmpty {
                            log("selftest-settings: window size popup did not open (attempt \(attempts), app active: \(NSApp.isActive))")
                            RunLoop.main.run(until: Date().addingTimeInterval(0.5))
                        }
                    }
                    nc.removeObserver(began)
                    let path = "\(dir)/settings-display-presets.txt"
                    try? (titles.joined(separator: "\n") + "\n").write(toFile: path, atomically: true, encoding: .utf8)
                    let presets = titles.filter { presetTitles.contains($0) || largerPresetTitles.contains($0) }
                    log("selftest-settings: \(path): \(titles.count) items, \(presets.count) presets,"
                        + " \(titles.filter { largerPresetTitles.contains($0) }.count) larger than this screen")
                    if presets.count != LauncherSettings.sizePresets.count || !titles.contains(customTitle)
                        || !titles.contains(fitTitle) {
                        failures.append("display-presets: unexpected items \(titles)")
                    }
                    capture("display-presets", tabShot.flatMap { withMenuItems($0, titles, selected: selected) })
                    settings.windowSizePreset = LauncherSettings.customPreset
                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.8) {
                        capture("display-custom", sw.snapshot())
                        (settings.windowSizePreset, settings.windowWidth, settings.windowHeight) = saved
                        done()
                    }
                }
            }
        }

        /// Advanced tab with a custom VM size above this Mac's limits (all cores, all the RAM the
        /// stepper allows): both orange warnings (settings-advanced-custom.png). Restored afterwards.
        func advancedCustom(then done: @escaping () -> Void) {
            let saved = (settings.cpus, settings.memMiB)
            settings.cpus = ProcessInfo.processInfo.activeProcessorCount
            settings.memMiB = max(4, Int(ProcessInfo.processInfo.physicalMemory >> 30) - 4) * 1024
            let host = VMSizing.Host.current
            log("selftest-settings: advanced custom: \(settings.cpus) vCPUs (warning: \(VMSizing.cpuWarning(cpus: settings.cpus, host: host) != nil)), "
                + "\(settings.memMiB) MiB (warning: \(VMSizing.memWarning(memMiB: settings.memMiB, host: host) != nil))")
            sw.show(tab: .advanced)
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.8) {
                capture("advanced-custom", sw.snapshot())
                (settings.cpus, settings.memMiB) = saved
                done()
            }
        }

        /// Exercise the real SwiftUI field, including clearing and reopening it: an example
        /// assignment in the empty-field prompt looked like a forced title default (STEAMAC-8X).
        func profileLaunchOptions(then done: @escaping () -> Void) {
            func fields(_ view: NSView) -> [NSTextField] {
                (view as? NSTextField).map { [$0] } ?? view.subviews.flatMap(fields)
            }
            // Find the fixture by its unique initial value, not by the user's game-name order.
            let initialFields = sw.window.contentView.map { fields($0).filter(\.isEditable) } ?? []
            guard let fieldIndex = initialFields.firstIndex(where: { $0.stringValue == profileTestEnv }) else {
                failures.append("profiles: launch options fixture field missing")
                return done()
            }
            func launchField() -> NSTextField? {
                let current = sw.window.contentView.map { fields($0).filter(\.isEditable) } ?? []
                return current.indices.contains(fieldIndex) ? current[fieldIndex] : nil
            }
            var values = ["", "VKD3D_CONFIG=dxr", "", "PROTON_LOG=1", ""]
            func step() {
                guard let field = launchField() else {
                    failures.append("profiles: launch options field missing")
                    return done()
                }
                if field.placeholderString?.contains("VKD3D_CONFIG=dxr") == true {
                    failures.append("profiles: empty launch options look like a forced DXR assignment")
                }
                guard !values.isEmpty else {
                    sw.show(tab: .general)
                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.2) {
                        sw.show(tab: .games)
                        DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) {
                            let reopened = launchField()
                            if reopened?.stringValue != "" || settings.profile(for: profileID).env != "" {
                                failures.append("profiles: cleared launch options changed after reopening Games")
                            }
                            done()
                        }
                    }
                    return
                }
                let value = values.removeFirst()
                field.selectText(nil)
                guard let editor = field.currentEditor() as? NSTextView else {
                    failures.append("profiles: launch options field editor missing")
                    return done()
                }
                editor.selectAll(nil)
                editor.insertText(value, replacementRange: editor.selectedRange())
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.2) {
                    // The normal domain is Bundle.main's identifier and uses .standard;
                    // reopening it as a suite is rejected by UserDefaults.
                    let data = settings.defaults.data(forKey: "profile.\(profileID)")
                    let stored = data.flatMap { try? JSONDecoder().decode(GameProfile.self, from: $0) }
                    if settings.profile(for: profileID).env != value || stored?.env != value {
                        failures.append("profiles: launch options edit did not persist: \(value) (model=\(settings.profile(for: profileID).env), stored=\(stored?.env ?? "<missing>"))")
                    }
                    step()
                }
            }
            step()
        }

        func next() {
            guard let tab = tabs.popFirst() else {
                CreateDiskWindowController.show(settings: settings)
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.8) {
                    capture("create-disk", CreateDiskWindowController.visibleWindow.flatMap(SettingsWindowController.snapshot))
                    CreateDiskWindowController.visibleWindow?.close()
                    let alert = FirstRun.makeAlert(settings: settings)
                    alert.layout()
                    alert.window.center()
                    alert.window.makeKeyAndOrderFront(nil)
                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.8) {
                        capture("first-run", SettingsWindowController.snapshot(alert.window))
                        alert.window.orderOut(nil)
                        // The "What is sent" popover content, in a plain window.
                        let host = NSHostingView(rootView: WhatIsSentView())
                        let w = NSWindow(contentRect: NSRect(origin: .zero, size: host.fittingSize), styleMask: [.titled],
                                         backing: .buffered, defer: false)
                        w.title = String(localized: "What is sent")
                        w.contentView = host
                        w.isReleasedWhenClosed = false
                        w.center()
                        w.makeKeyAndOrderFront(nil)
                        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) {
                            capture("what-is-sent", SettingsWindowController.snapshot(w))
                            w.orderOut(nil)
                            displayPresets { advancedCustom { backgroundMute(then: finish) } }
                        }
                    }
                }
                return
            }
            sw.show(tab: tab)
            // Let the tab switch animation and SwiftUI layout settle.
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.8) {
                capture(tab.name, sw.snapshot())
                if tab == .games && popups(in: sw.window.contentView).count < 3 {
                    failures.append("profiles: graphics/driver/rating pickers not rendered")
                }
                if tab == .games { profileLaunchOptions(then: next) }
                else { next() }
            }
        }
        DispatchQueue.main.async { app.activate(); next() }
        app.run()
        exit(0)
    }
}
