import AppKit
import Carbon.HIToolbox

/// `--input-selftest SECONDS`: after the delay, synthesize AppKit key/mouse events and route them
/// through the normal NSApplication.sendEvent path (no Accessibility permission needed), and
/// feed a scripted state into the virtual gamepads of players 1 and 2 (pads without a controller,
/// over fx.pad and fx.pad2). The smoke initramfs prints what the guest receives ("input[<device>]
/// type= code= value=" for the virtio-input devices, "pad[<line>]" for fx.pad, "pad2[<line>]" for
/// fx.pad2). Finally it closes the window via
/// performClose (the real close-button path -> guest power key) a few seconds later.
enum InputSelfTest {
    static func schedule(after seconds: Double, window wc: WindowController, gamepad: GamepadBridge?) {
        DispatchQueue.main.asyncAfter(deadline: .now() + seconds) {
            log("input selftest: injecting key 'a', Shift+'b', pointer move/click/scroll, gamepad A + left stick")
            let w = wc.window
            // Keys go through processKey (sendEvent's focus gate is skipped: the window may not be
            // key when the user is busy in another app).
            func key(_ type: NSEvent.EventType, _ code: Int, _ chars: String, _ flags: NSEvent.ModifierFlags = []) {
                if let e = NSEvent.keyEvent(with: type, location: .zero, modifierFlags: flags, timestamp: ProcessInfo.processInfo.systemUptime,
                                            windowNumber: w.windowNumber, context: nil, characters: chars,
                                            charactersIgnoringModifiers: chars, isARepeat: false, keyCode: UInt16(code)) {
                    _ = wc.processKey(e)
                }
            }
            func mouse(_ type: NSEvent.EventType, _ p: NSPoint) {
                if let e = NSEvent.mouseEvent(with: type, location: p, modifierFlags: [], timestamp: ProcessInfo.processInfo.systemUptime,
                                              windowNumber: w.windowNumber, context: nil, eventNumber: 0, clickCount: 1, pressure: 1) {
                    NSApp.sendEvent(e)
                }
            }
            // Keyboard ('a', then Shift down/'b'/Shift up via flagsChanged with device-dependent bits).
            key(.keyDown, kVK_ANSI_A, "a"); key(.keyUp, kVK_ANSI_A, "a")
            let shift = NSEvent.ModifierFlags(rawValue: NSEvent.ModifierFlags.shift.rawValue | 0x2)
            key(.flagsChanged, kVK_Shift, "", shift)
            key(.keyDown, kVK_ANSI_B, "B", shift); key(.keyUp, kVK_ANSI_B, "B", shift)
            key(.flagsChanged, kVK_Shift, "", [])
            // Pointer: center of the content view, left click.
            let c = wc.view.convert(NSPoint(x: wc.view.bounds.midX, y: wc.view.bounds.midY), to: nil)
            mouse(.mouseMoved, c)
            mouse(.leftMouseDown, c)
            mouse(.leftMouseUp, c)
            wc.sendWheel(hiResY: 120, hiResX: -60)   // one notch up, half a notch left
            gamepad?.injectTestSequence()
            DispatchQueue.main.asyncAfter(deadline: .now() + 4) {
                log("input selftest: closing the window (performClose)")
                w.performClose(nil)
            }
        }
    }
}
