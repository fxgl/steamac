import Foundation

/// The control stream already authenticated and decrypted these packets. InputDevice accepts
/// batches from any thread; only controller topology and PadPort traffic go to the main queue.
final class StreamInput {
    private enum Device: Equatable { case keyboard, mouse, tablet }
    private typealias Event = (UInt16, UInt16, Int32)
    private let send: (Device, [Event]) -> Void
    private weak var gamepads: GamepadBridge?
    private let lock = NSLock()
    private var active = false
    private var generation: UInt64 = 0
    private var keys: Set<UInt16> = []
    private var buttons: [UInt16: Device] = [:]
    private var absolute = false
    private var wheelRemainder: Int32 = 0
    private var horizontalRemainder: Int32 = 0
    private var pads: [UInt16: GamepadBridge.RemotePad] = [:]
    private var rumble: ((UInt16, UInt16, UInt16) -> Void)?
    private var inspectPads: (([UInt16: GamepadBridge.RemotePad]) -> Void)?
    private static let modifiers: [(UInt8, UInt16, UInt16)] = [
        (1, KEY.LEFTSHIFT, KEY.RIGHTSHIFT), (2, KEY.LEFTCTRL, KEY.RIGHTCTRL),
        (4, KEY.LEFTALT, KEY.RIGHTALT), (8, KEY.LEFTMETA, KEY.RIGHTMETA),
    ]

    init(inputs: VMInputs, gamepads: GamepadBridge?) {
        self.gamepads = gamepads
        send = { device, events in
            switch device {
            case .keyboard: inputs.keyboard.send(events)
            case .mouse: inputs.mouse.send(events)
            case .tablet: inputs.tablet.send(events)
            }
        }
    }

    private init(send: @escaping (Device, [Event]) -> Void,
                 inspectPads: @escaping ([UInt16: GamepadBridge.RemotePad]) -> Void) {
        self.send = send
        self.inspectPads = inspectPads
    }

    func begin(rumble: @escaping (_ controller: UInt16, _ lowFrequency: UInt16, _ highFrequency: UInt16) -> Void) {
        end()
        lock.lock()
        active = true
        self.rumble = rumble
        lock.unlock()
    }

    func end() {
        lock.lock()
        active = false
        generation &+= 1
        send(.keyboard, keys.sorted().map { (EV.KEY, $0, 0) })
        for device in [Device.mouse, .tablet] {
            send(device, buttons.filter { $0.value == device }.keys.sorted().map { (EV.KEY, $0, 0) })
        }
        keys.removeAll(); buttons.removeAll(); pads.removeAll()
        absolute = false; wheelRemainder = 0; horizontalRemainder = 0
        inspectPads?(pads)
        lock.unlock()
        gamepads?.removeRemotePads()
        rumble = nil
    }

    func handle(_ message: Data) {
        lock.lock()
        defer { lock.unlock() }
        guard active, message.count >= 8 else { return }
        message.withUnsafeBytes { (b: UnsafeRawBufferPointer) in
            func u16(_ i: Int, _ little: Bool = true) -> UInt16 {
                little ? UInt16(b[i]) | UInt16(b[i + 1]) << 8 : UInt16(b[i]) << 8 | UInt16(b[i + 1])
            }
            func s16(_ i: Int, _ little: Bool = true) -> Int32 { Int32(Int16(bitPattern: u16(i, little))) }
            func u32(_ i: Int, _ little: Bool = true) -> UInt32 {
                little ? UInt32(u16(i)) | UInt32(u16(i + 2)) << 16
                    : UInt32(u16(i, false)) << 16 | UInt32(u16(i + 2, false))
            }
            guard u32(0, false) == message.count - 4 else { return }
            let magic = u32(4)
            switch magic {
            case 3, 4:
                guard b.count == 14, let code = Keymap.windowsKey(u16(9), extended: b[11] & 0x10 != 0) else { return }
                keyboard(code, down: magic == 3, modifiers: b[11])
            case 0x17:
                guard b.count > 8, b.count <= 40 else { return }
                let bytes = b[8...].prefix { $0 != 0 }
                guard let text = String(bytes: bytes, encoding: .utf8) else { log("stream: invalid UTF-8 input ignored"); return }
                typeText(text)
            case 6, 7:
                guard b.count == 12 else { return }
                absolute = false
                send(.mouse, [(EV.REL, REL.X, s16(8, false)), (EV.REL, REL.Y, s16(10, false))])
            case 5:
                guard b.count == 18, u16(14, false) > 0, u16(16, false) > 0 else { return }
                absolute = true
                func scale(_ position: Int32, _ extent: UInt16) -> Int32 {
                    min(InputDevices.absMax, max(0, position) * InputDevices.absMax / Int32(extent))
                }
                send(.tablet, [(EV.ABS, ABS.X, scale(s16(8, false), u16(14, false))),
                               (EV.ABS, ABS.Y, scale(s16(10, false), u16(16, false)))])
            case 8:
                guard b.count == 9 else { return }
                mouseButton(b[8], down: true)
            case 9 where b.count == 9:
                mouseButton(b[8], down: false)
            case 9 where b.count == 14, 0x0a where b.count == 14:
                scroll(s16(8, false), horizontal: false)
            case 0x55000001:
                guard b.count == 10 else { return }
                scroll(s16(8, false), horizontal: true)
            case 0x55000004:
                guard b.count == 16, b[8] < 16 else { return }
                let n = UInt16(b[8])
                var pad = pads[n] ?? GamepadBridge.RemotePad(number: n)
                pad.kind = b[9] == 2 ? .dualShock4 : .xbox360
                pad.capabilities = u16(10)
                pad.supportedButtons = u32(12)
                pads[n] = pad
                deliverPads()
            case 0x0c where b.count == 34, 0x0d where b.count == 34:
                let n = u16(10), mask = u16(12)
                guard n < 16 else { return }
                pads = pads.filter { mask & (UInt16(1) << $0.key) != 0 }
                for i in UInt16(0)..<16 where mask & (UInt16(1) << i) != 0 && pads[i] == nil {
                    pads[i] = GamepadBridge.RemotePad(number: i)
                }
                if mask & (UInt16(1) << n) != 0 {
                    var pad = pads[n]!
                    pad.buttons = UInt32(u16(16)) | UInt32(u16(30)) << 16
                    pad.leftTrigger = b[18]; pad.rightTrigger = b[19]
                    pad.leftX = Int16(bitPattern: u16(20)); pad.leftY = Int16(bitPattern: u16(22))
                    pad.rightX = Int16(bitPattern: u16(24)); pad.rightY = Int16(bitPattern: u16(26))
                    pads[n] = pad
                }
                deliverPads()
            case 0x0a where b.count == 28:
                var pad = pads[0] ?? GamepadBridge.RemotePad(number: 0)
                pad.buttons = UInt32(u16(10)); pad.leftTrigger = b[12]; pad.rightTrigger = b[13]
                pad.leftX = Int16(bitPattern: u16(14)); pad.leftY = Int16(bitPattern: u16(16))
                pad.rightX = Int16(bitPattern: u16(18)); pad.rightY = Int16(bitPattern: u16(20))
                pads[0] = pad
                deliverPads()
            default:
                // Pen/touch, motion, battery and haptics enable have no advertised guest feature.
                break
            }
        }
    }

    private func deliverPads() {
        if let inspectPads { inspectPads(pads); return }
        guard gamepads != nil else { return }
        let snapshot = pads, session = generation
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            self.lock.lock()
            let current = self.active && self.generation == session
            self.lock.unlock()
            guard current else { return }
            self.gamepads?.setRemotePads(snapshot) { [weak self] n, low, high in self?.rumble?(n, low, high) }
        }
    }

    private func keyboard(_ code: UInt16, down: Bool, modifiers: UInt8) {
        var events: [Event] = []
        // A modifier's own flags vary between clients. Trust its explicit down/up; use the
        // flags on other keys to recover modifiers whose original event was consumed locally.
        if !Self.modifiers.contains(where: { $0.1 == code || $0.2 == code }) {
            for (bit, left, right) in Self.modifiers {
                if modifiers & bit != 0 {
                    if !keys.contains(left) && !keys.contains(right) { keys.insert(left); events.append((EV.KEY, left, 1)) }
                } else {
                    for key in [left, right] where keys.remove(key) != nil { events.append((EV.KEY, key, 0)) }
                }
            }
        }
        if down {
            let inserted = keys.insert(code).inserted
            events.append((EV.KEY, code, inserted ? 1 : 2))
        } else if keys.remove(code) != nil { events.append((EV.KEY, code, 0)) }
        send(.keyboard, events)
    }

    private func mouseButton(_ number: UInt8, down: Bool) {
        let codes = [BTN.LEFT, BTN.MIDDLE, BTN.RIGHT, BTN.SIDE, BTN.EXTRA]
        guard number >= 1, number <= 5 else { return }
        let code = codes[Int(number) - 1]
        if down {
            guard buttons[code] == nil else { return }
            let device: Device = absolute && number <= 3 ? .tablet : .mouse
            buttons[code] = device
            send(device, [(EV.KEY, code, 1)])
        } else if let device = buttons.removeValue(forKey: code) {
            // Motion mode can change during a drag: release on the device that pressed it.
            send(device, [(EV.KEY, code, 0)])
        }
    }

    private func scroll(_ amount: Int32, horizontal: Bool) {
        var remainder = (horizontal ? horizontalRemainder : wheelRemainder) + amount
        var events: [Event] = [(EV.REL, horizontal ? REL.HWHEEL_HI_RES : REL.WHEEL_HI_RES, amount)]
        let steps = remainder / 120
        if steps != 0 { events.append((EV.REL, horizontal ? REL.HWHEEL : REL.WHEEL, steps)); remainder %= 120 }
        if horizontal { horizontalRemainder = remainder } else { wheelRemainder = remainder }
        send(absolute ? .tablet : .mouse, events)
    }

    private func typeText(_ text: String) {
        let held = keys
        let modifierCodes = Self.modifiers.flatMap { [$0.1, $0.2] }
        let heldModifiers = modifierCodes.filter { held.contains($0) }
        send(.keyboard, heldModifiers.map { (EV.KEY, $0, 0) })
        var ignored = false
        for scalar in text.unicodeScalars {
            guard let (vk, shift) = Self.ascii(scalar.value), let code = Keymap.windowsKey(vk, extended: false) else { ignored = true; continue }
            var events: [Event] = []
            if shift { events.append((EV.KEY, KEY.LEFTSHIFT, 1)) }
            if held.contains(code) { events.append((EV.KEY, code, 0)) }
            events.append((EV.KEY, code, 1)); events.append((EV.KEY, code, 0))
            if held.contains(code) { events.append((EV.KEY, code, 1)) }
            if shift { events.append((EV.KEY, KEY.LEFTSHIFT, 0)) }
            send(.keyboard, events)
        }
        send(.keyboard, heldModifiers.map { (EV.KEY, $0, 1) })
        if ignored { log("stream: non-ASCII text input ignored (guest keyboard layout applies)") }
    }

    private static func ascii(_ c: UInt32) -> (UInt16, Bool)? {
        switch c {
        case 65...90: return (UInt16(c), true)
        case 97...122: return (UInt16(c - 32), false)
        case 48...57: return (UInt16(c), false)
        case 8: return (0x08, false)
        case 9: return (0x09, false)
        case 10, 13: return (0x0d, false)
        case 32: return (0x20, false)
        default: return punctuation[c]
        }
    }

    private static let punctuation: [UInt32: (UInt16, Bool)] = {
        let plain = Array(";=,-./`[\\]'".unicodeScalars.map(\.value))
        let shifted = Array(":+<_>?~{|}\"".unicodeScalars.map(\.value))
        let vk: [UInt16] = [0xba, 0xbb, 0xbc, 0xbd, 0xbe, 0xbf, 0xc0, 0xdb, 0xdc, 0xdd, 0xde]
        var table: [UInt32: (UInt16, Bool)] = [:]
        for i in vk.indices {
            table[plain[i]] = (vk[i], false)
            table[shifted[i]] = (vk[i], true)
        }
        for (i, c) in ")!@#$%^&*(".unicodeScalars.enumerated() { table[c.value] = (0x30 + UInt16(i), true) }
        return table
    }()

    static func selfCheck() -> [String] {
        var failures = GamepadBridge.remoteRestorationSelfCheck()
        var events: [(Device, UInt16, UInt16, Int32)] = []
        var remote: [UInt16: GamepadBridge.RemotePad] = [:]
        let input = StreamInput(send: { device, batch in
            for e in batch { events.append((device, e.0, e.1, e.2)) }
        }, inspectPads: { remote = $0 })
        func check(_ ok: Bool, _ name: String) { if !ok { failures.append("input: " + name) } }
        func has(_ device: Device, _ type: UInt16, _ code: UInt16, _ value: Int32) -> Bool {
            events.contains { $0.0 == device && $0.1 == type && $0.2 == code && $0.3 == value }
        }
        func le(_ value: UInt16) -> [UInt8] { [UInt8(truncatingIfNeeded: value), UInt8(value >> 8)] }
        func be(_ value: UInt16) -> [UInt8] { le(value).reversed() }
        func packet(_ magic: UInt32, _ body: [UInt8]) -> Data {
            let size = UInt32(body.count + 4)
            return Data([UInt8(size >> 24), UInt8(truncatingIfNeeded: size >> 16), UInt8(truncatingIfNeeded: size >> 8), UInt8(truncatingIfNeeded: size),
                         UInt8(truncatingIfNeeded: magic), UInt8(truncatingIfNeeded: magic >> 8), UInt8(truncatingIfNeeded: magic >> 16), UInt8(magic >> 24)] + body)
        }
        func key(_ vk: UInt16, _ down: Bool, _ modifiers: UInt8 = 0) { input.handle(packet(down ? 3 : 4, [0] + le(vk) + [modifiers, 0, 0])) }
        input.begin { _, _, _ in }
        key(0x8041, true, 3)
        check(has(.keyboard, EV.KEY, KEY.A, 1) && has(.keyboard, EV.KEY, KEY.LEFTCTRL, 1)
              && has(.keyboard, EV.KEY, KEY.LEFTSHIFT, 1), "VK low byte + modifier flags")
        key(0x41, false); key(0xa3, true); key(0x42, true, 2)
        check(has(.keyboard, EV.KEY, KEY.RIGHTCTRL, 1) && !input.keys.contains(KEY.LEFTCTRL), "right modifier preserved")
        key(0xa3, false); key(0x0d, true, 0x10)
        check(has(.keyboard, EV.KEY, KEY.KPENTER, 1), "extended Enter")
        for code in Keymap.windows.values { check(Keymap.allCodes.contains(code), "VK advertised \(code)") }
        input.handle(packet(5, be(1920) + be(540) + [0, 0] + be(1920) + be(1080)))
        check(has(.tablet, EV.ABS, ABS.X, 32767) && has(.tablet, EV.ABS, ABS.Y, 16383), "absolute scaling")
        input.handle(packet(8, [1])); input.handle(packet(8, [4]))
        input.handle(packet(7, be(0xfffe) + be(3))); input.handle(packet(9, [1]))
        check(has(.mouse, EV.REL, REL.X, -2) && has(.tablet, EV.KEY, BTN.LEFT, 0)
              && has(.mouse, EV.KEY, BTN.SIDE, 1), "relative movement + drag device + extra button")
        input.handle(packet(0x0a, be(60) + be(60) + [0, 0]))
        input.handle(packet(0x0a, be(60) + be(60) + [0, 0]))
        input.handle(packet(0x55000001, be(0xff88)))
        check(has(.mouse, EV.REL, REL.WHEEL_HI_RES, 60) && has(.mouse, EV.REL, REL.WHEEL, 1)
              && has(.mouse, EV.REL, REL.HWHEEL, -1), "high-resolution vertical/horizontal wheel")
        input.handle(packet(0x17, Array("Az!?".utf8)))
        check(has(.keyboard, EV.KEY, KEY.Z, 1) && has(.keyboard, EV.KEY, KEY.SLASH, 1), "ASCII text")
        input.handle(packet(0x55000004, [2, 2] + le(3) + [0xff, 0xff, 0xff, 0xff]))
        check(remote[2]?.kind == .dualShock4 && remote[2]?.capabilities == 3, "controller arrival")
        let stateBody = le(0x1a) + le(2) + le(4) + le(0x14) + le(0x5405) + [128, 255]
            + le(32767) + le(32767) + le(0x8000) + le(0x8000) + le(0x9c) + le(0) + le(0x55)
        input.handle(packet(0x0c, stateBody))
        if let pad = remote[2] {
            let s = GamepadBridge.read(pad, as: pad.kind, swapABXY: false, deadzone: 0)
            check(s.buttons[BTN.SOUTH] == true && s.buttons[BTN.WEST] == true && s.buttons[BTN.MODE] == true,
                  "controller button positions")
            check(s.axes[ABS.Y] == -32767 && s.axes[ABS.RY] == 32767 && s.axes[ABS.Z] == 128
                  && s.axes[ABS.RZ] == 255 && s.axes[ABS.HAT0X] == -1 && s.axes[ABS.HAT0Y] == -1,
                  "controller axes + triggers + hat")
            let xbox = GamepadBridge.read(pad, as: .xbox360, swapABXY: false, deadzone: 0)
            check(xbox.buttons[BTN.NORTH] == true, "Xbox X position")
        } else { check(false, "controller state decoded") }
        var removal = stateBody; removal[4] = 0
        input.handle(packet(0x0c, removal))
        check(remote.isEmpty, "controller removal mask")
        let count = events.count
        input.handle(Data([0, 0, 0, 100, 3, 0, 0, 0]))
        input.handle(packet(0x55000002, [0]))
        check(events.count == count, "malformed and unadvertised touch ignored")
        input.end()
        check(has(.keyboard, EV.KEY, KEY.KPENTER, 0) && has(.mouse, EV.KEY, BTN.SIDE, 0)
              && input.keys.isEmpty && remote.isEmpty, "end releases held inputs")
        return failures
    }
}
