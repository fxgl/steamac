import AppKit
import Carbon.HIToolbox
import Foundation

/// `--control-fifo PATH`: scripted window input for automated tests, on the main thread. Pointer
/// moves and buttons are synthesized NSEvents dispatched through NSApplication.sendEvent (the
/// same AppKit routing real mouse events take: window → first responder / hit-tested VMView);
/// wheel, `rel` and keys call the controller directly:
///   move UX UY            pointer to (UX, UY) in 0..1 picture coordinates (top-left origin)
///   button B down|up      B = left | right | middle (at the last `move` position)
///   click B               button down + up
///   wheel N               N wheel notches (positive = up)
///   rel DX DY             relative motion in points (as when the mouse is captured)
///   key KEYCODE           macOS virtual key code, press + release
///   chord KEYCODE MODS    the modifiers (ctrl+shift+opt+cmd) pressed in the guest, the key, the modifiers
///                         released (e.g. `chord 9 ctrl` = Ctrl+V in SteamOS)
///   grab | release        capture / release the mouse
///   menu game|global      toggle Mouse > Capture Mouse in This Game / Auto-Capture Mouse in Games
///   guest LINE            handle LINE as if the guest had sent it on fx.progress
///   dump PATH             frame + window dump (as SIGUSR1, to PATH)
///   settings TAB|close    open the Settings window at TAB (general, display, mouse, controller,
///                         sound, advanced) or close it
///   settings-dump PATH    PNG of the Settings window
///   restart               Restart VM (as the menu / Settings button)
///   activate              bring the app to the front (tests of the background mute / pause)
///   keepalive off|on      stop / resume the paused game's keepalives (guest auto-thaw test)
///   set KEY VALUE         change a setting as the Settings window would (LauncherSettings.Key names)
///   close                 the window's close button (Settings > General "When closing the window")
///   suspend | resume      menu Suspend / Resume (Resume also wakes a sleeping SteamOS)
///   wake                  as when the Mac wakes from sleep (the time goes to the guest on fx.clock,
///                         the GPU-idle / heartbeat timers start over)
///   reopen                Dock icon click / opening the app again (resumes, wakes a sleeping SteamOS)
///   quit                  Quit (Cmd+Q); while suspended this opens the "SteamOS is suspended" prompt
///   quit-prompt shutdown|cancel|dump PATH   press the prompt's button / PNG of the prompt
///   status open|close|dump PATH   open / close the menu-bar item's menu while suspended; log its
///                         items and write a PNG of its button
///   status item TITLE     choose the menu-bar item's menu entry TITLE (e.g. Resume)
///   report …              Report a Problem sheet (ReportControl: open, fill, include, preview, send,
///                         retry, close, dsn, dump)
///   update …              new-version check (UpdateChecker.control: check, startup, press
///                         download|skip|later|ok|releases, dump PATH, state)
///   pad on|off|test [N] | state  GamepadBridge.control: a guest pad for player N (1 if not
///                         given) without a controller (as --input-selftest) / follow the
///                         controller again; press A + push the left stick; log the guest pads
///                         and the guest's last rumble
enum DebugControl {
    nonisolated(unsafe) private static var settingsWindow: SettingsWindowController?
    nonisolated(unsafe) private static var gamepad: GamepadBridge?

    static func start(path: String, window wc: WindowController, progress: BootProgress,
                      settingsWindow: SettingsWindowController, gamepad: GamepadBridge?, dump: @escaping (String) -> Void) {
        self.settingsWindow = settingsWindow
        self.gamepad = gamepad
        unlink(path)
        guard mkfifo(path, 0o600) == 0 else {
            log("control: cannot create FIFO \(path): \(String(cString: strerror(errno)))")
            return
        }
        log("control: accepting commands on \(path)")
        let t = Thread {
            while true {
                // Re-open after each writer closes (echo cmd > fifo).
                guard let f = fopen(path, "r") else { return }
                var line: UnsafeMutablePointer<CChar>?
                var cap = 0
                while getline(&line, &cap, f) > 0 {
                    let cmd = String(cString: line!).trimmingCharacters(in: .whitespacesAndNewlines)
                    if !cmd.isEmpty {
                        DispatchQueue.main.sync { handle(cmd, wc, progress, dump) }
                    }
                }
                free(line)
                fclose(f)
            }
        }
        t.name = "control-fifo"
        t.start()
    }

    nonisolated(unsafe) private static var lastPoint = NSPoint.zero

    private static func windowPoint(_ ux: Double, _ uy: Double, _ wc: WindowController) -> NSPoint {
        let fit = wc.view.fitRect
        let p = NSPoint(x: fit.minX + CGFloat(ux) * fit.width, y: fit.maxY - CGFloat(uy) * fit.height)
        return wc.view.convert(p, to: nil)
    }

    private static func mouseEvent(_ type: NSEvent.EventType, _ wc: WindowController, button: Int = 0) -> NSEvent? {
        NSEvent.mouseEvent(with: type, location: lastPoint, modifierFlags: [], timestamp: ProcessInfo.processInfo.systemUptime,
                           windowNumber: wc.window.windowNumber, context: nil, eventNumber: 0, clickCount: 1,
                           pressure: type == .leftMouseDown ? 1 : 0)
    }

    private static func buttonEvent(_ name: String, down: Bool, _ wc: WindowController) {
        let type: NSEvent.EventType
        switch name {
        case "right": type = down ? .rightMouseDown : .rightMouseUp
        case "middle": type = down ? .otherMouseDown : .otherMouseUp
        default: type = down ? .leftMouseDown : .leftMouseUp
        }
        if let e = mouseEvent(type, wc) { NSApp.sendEvent(e) }
    }

    private static func handle(_ cmd: String, _ wc: WindowController, _ progress: BootProgress, _ dump: (String) -> Void) {
        let p = cmd.split(separator: " ", maxSplits: 1).map(String.init)
        let args = p.count > 1 ? p[1].split(separator: " ").map(String.init) : []
        log("control: \(cmd)")
        switch p[0] {
        case "move":
            guard args.count == 2, let ux = Double(args[0]), let uy = Double(args[1]) else { break }
            lastPoint = windowPoint(ux, uy, wc)
            if let e = mouseEvent(.mouseMoved, wc) { NSApp.sendEvent(e) }
        case "button":
            guard args.count == 2 else { break }
            buttonEvent(args[0], down: args[1] == "down", wc)
        case "click":
            buttonEvent(args.first ?? "left", down: true, wc)
            buttonEvent(args.first ?? "left", down: false, wc)
        case "wheel":
            guard let n = Double(args.first ?? "") else { break }
            if let e = mouseEvent(.mouseMoved, wc) { NSApp.sendEvent(e) }
            wc.sendWheel(hiResY: n * 120, hiResX: 0)
        case "rel":
            guard args.count == 2, let dx = Double(args[0]), let dy = Double(args[1]) else { break }
            wc.moveRelative(dx: dx, dy: dy)
        case "key":   // key KEYCODE [ctrl+cmd+opt+shift]
            guard let code = UInt16(args.first ?? "") else { break }
            var mods: NSEvent.ModifierFlags = []
            for m in (args.count > 1 ? args[1] : "").split(separator: "+") {
                switch m {
                case "ctrl": mods.insert(.control)
                case "cmd": mods.insert(.command)
                case "opt": mods.insert(.option)
                case "shift": mods.insert(.shift)
                default: break
                }
            }
            for type in [NSEvent.EventType.keyDown, .keyUp] {
                if let e = NSEvent.keyEvent(with: type, location: .zero, modifierFlags: mods, timestamp: ProcessInfo.processInfo.systemUptime,
                                            windowNumber: wc.window.windowNumber, context: nil, characters: "",
                                            charactersIgnoringModifiers: "", isARepeat: false, keyCode: code) {
                    _ = wc.processKey(e)
                }
            }
        case "chord":
            guard let code = UInt16(args.first ?? "") else { break }
            let table: [String: (Int, NSEvent.ModifierFlags)] = [
                "ctrl": (kVK_Control, .control), "shift": (kVK_Shift, .shift), "opt": (kVK_Option, .option), "cmd": (kVK_Command, .command),
            ]
            let held = (args.count > 1 ? args[1] : "").split(separator: "+").compactMap { table[String($0)] }
            func send(_ type: NSEvent.EventType, _ key: Int, _ flags: UInt) {
                if let e = NSEvent.keyEvent(with: type, location: .zero, modifierFlags: NSEvent.ModifierFlags(rawValue: flags),
                                            timestamp: ProcessInfo.processInfo.systemUptime, windowNumber: wc.window.windowNumber,
                                            context: nil, characters: "", charactersIgnoringModifiers: "", isARepeat: false,
                                            keyCode: UInt16(key)) {
                    _ = wc.processKey(e)
                }
            }
            var flags: UInt = 0
            for (key, f) in held {
                flags |= f.rawValue | (Keymap.modifierMask(UInt16(key)) ?? 0)
                send(.flagsChanged, key, flags)
            }
            send(.keyDown, Int(code), flags)
            send(.keyUp, Int(code), flags)
            for (key, f) in held.reversed() {
                flags &= ~(f.rawValue | (Keymap.modifierMask(UInt16(key)) ?? 0))
                send(.flagsChanged, key, flags)
            }
        case "grab": wc.grabPointer()
        case "menu":   // menu game | menu global: toggle like the Mouse menu items
            if args.first == "game" { wc.toggleGameAutoCapture(nil) } else { wc.toggleGlobalAutoCapture(nil) }
        case "release": wc.releasePointer()
        case "guest": progress.guestLine(p.count > 1 ? p[1] : "")
        case "dump": dump(args.first ?? "control-dump.png")
        case "settings":
            guard let sw = settingsWindow else { break }
            if args.first == "close" { sw.window.close(); break }
            let tab = SettingsWindowController.Tab.allCases.first { $0.name == (args.first ?? "general") }
            sw.show(tab: tab ?? .general)
        case "settings-dump":
            guard let sw = settingsWindow, let rep = sw.snapshot(),
                  let png = rep.representation(using: .png, properties: [:]) else { log("control: settings dump failed"); break }
            let out = args.first ?? "settings.png"
            do { try png.write(to: URL(fileURLWithPath: out)); log("control: settings window dumped to \(out)") }
            catch { log("control: settings dump failed: \(error)") }
        case "restart": lifecycle.requestRestart()
        case "close": wc.window.performClose(nil)
        case "suspend": if !(lifecycle.suspender?.suspended ?? true) { lifecycle.menuSuspend() }
        case "resume": lifecycle.suspender?.resume(origin: "control")
        case "reopen": _ = lifecycle.applicationShouldHandleReopen(NSApp, hasVisibleWindows: wc.window.isVisible)
        case "wake": lifecycle.suspender?.hostDidWake(origin: "control")
        case "quit":
            DispatchQueue.main.async { NSApp.terminate(nil) }
        case "quit-prompt": lifecycle.suspender?.controlQuitPrompt(args)
        case "status":
            if args.first == "close" { lifecycle.suspender?.statusMenu?.cancelTracking() }
            else if args.first == "item" {
                let title = args.dropFirst().joined(separator: " ")
                guard let menu = lifecycle.suspender?.statusMenu, let i = menu.items.firstIndex(where: { $0.identifier?.rawValue == title }) else {
                    log("control: no menu-bar item entry \"\(title)\""); break
                }
                menu.performActionForItem(at: i)
            }
            else if args.first == "dump" { lifecycle.suspender?.dumpStatusItem(to: args.dropFirst().first ?? "status-item.png") }
            // Async: the menu tracks in a modal loop.
            else { DispatchQueue.main.async { lifecycle.suspender?.statusButton?.performClick(nil) } }
        case "activate": NSApp.activate(ignoringOtherApps: true)
        case "keepalive": GamePause.keepaliveSuppressed = args.first == "off"
        case "set":
            guard args.count >= 2 else { break }
            let value = args.dropFirst().joined(separator: " ")
            if !LauncherSettings.shared.set(args[0], value) { log("control: set: unknown key or bad value") }
        case "report": MainActor.assumeIsolated { ReportControl.handle(args) }
        case "update": UpdateChecker.shared.control(args)
        case "pad":
            guard let gamepad else { log("control: no gamepad bridge (--no-gamepad)"); break }
            gamepad.control(args)
        default: log("control: unknown command")
        }
    }
}
