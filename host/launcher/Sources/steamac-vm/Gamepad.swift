import Combine
import Darwin
import Foundation
import GameController

/// The gamepad SteamOS sees, created by the guest's fx-pad service as a uinput device (PadPort):
/// the identity and capabilities the real controller's kernel driver exposes, so SDL's GUID-based
/// mapping (bus, vendor, product, version) and Steam recognise it, plus FF_RUMBLE (Rumble):
/// - xbox360: drivers/input/joystick/xpad.c, XTYPE_XBOX360 (dpad as hat, triggers as axes);
/// - dualSense / dualShock4: hid-playstation / hid-sony for a USB pad (version 0x8111, face
///   buttons by position, digital L2/R2 besides ABS_Z/ABS_RZ) — SDL's
///   030000004c050000{e60c,cc09}000011810000 mappings; Steam shows PlayStation glyphs.
///   Touchpad, gyro, lightbar and adaptive triggers are HID features this evdev device lacks
///   (a DualSense passed through as itself has them: HIDPassthrough).
enum GuestPad: Equatable {
    case xbox360, dualSense, dualShock4

    var sony: Bool { self != .xbox360 }

    var title: String {
        switch self {
        case .xbox360: return String(localized: "Xbox 360 controller")
        case .dualSense: return "DualSense"
        case .dualShock4: return "DualShock 4"
        }
    }

    var logTitle: String {
        switch self {
        case .xbox360: return "Xbox 360 controller"
        case .dualSense: return "DualSense"
        case .dualShock4: return "DualShock 4"
        }
    }

    var identity: (name: String, bus: UInt16, vendor: UInt16, product: UInt16, version: UInt16) {
        switch self {
        case .xbox360: return ("Microsoft X-Box 360 pad", BUS.USB, 0x045e, 0x028e, 0x0114)
        case .dualSense: return ("Sony Interactive Entertainment DualSense Wireless Controller", BUS.USB, 0x054c, 0x0ce6, 0x8111)
        case .dualShock4: return ("Sony Interactive Entertainment Wireless Controller", BUS.USB, 0x054c, 0x09cc, 0x8111)
        }
    }

    /// Evdev key codes the device advertises. xpad: X/Y as BTN_X/BTN_Y. hid-playstation /
    /// hid-sony: the same codes by position (square BTN_WEST, triangle BTN_NORTH) plus digital
    /// L2/R2 next to the analog triggers.
    var buttonCodes: [UInt16] {
        let common = [BTN.SOUTH, BTN.EAST, BTN.NORTH, BTN.WEST, BTN.TL, BTN.TR,
                      BTN.SELECT, BTN.START, BTN.MODE, BTN.THUMBL, BTN.THUMBR]
        return sony ? common + [BTN.TL2, BTN.TR2] : common
    }

    /// Axes (the same for all three): sticks, analog triggers, the dpad as a hat.
    static let axes: [(code: UInt16, info: AbsAxis)] = {
        let stick = AbsAxis(min: -32768, max: 32767, fuzz: 16, flat: 128)
        let trigger = AbsAxis(min: 0, max: 255)
        let hat = AbsAxis(min: -1, max: 1)
        return [(ABS.X, stick), (ABS.Y, stick), (ABS.Z, trigger), (ABS.RX, stick), (ABS.RY, stick),
                (ABS.RZ, trigger), (ABS.HAT0X, hat), (ABS.HAT0Y, hat)]
    }()

    /// fx.pad `create <bus> <vendor> <product> <version> <keys> <axes> <name>`.
    var createLine: String {
        let id = identity
        let keys = buttonCodes.map(String.init).joined(separator: ",")
        let axes = GuestPad.axes.map { "\($0.code):\($0.info.min):\($0.info.max):\($0.info.fuzz):\($0.info.flat)" }
            .joined(separator: ",")
        return String(format: "create %04x %04x %04x %04x ", id.bus, id.vendor, id.product, id.version)
            + "\(keys) \(axes) \(id.name)"
    }

    /// Automatic: the same kind as the controller (its GameController profile).
    static func matching(_ c: GCController) -> GuestPad {
        switch c.extendedGamepad {
        case is GCDualSenseGamepad: return .dualSense
        case is GCDualShockGamepad: return .dualShock4
        default: return .xbox360
        }
    }
}

/// A player's virtio-console port (`fx.pad`, `fx.pad2`, …) to the guest's root service fx-pad
/// (`fx-progress-agent pad`, guest/progress-agent/src/pad.rs; fx-pad@ for the further players),
/// which owns that player's gamepad as a uinput device or, for a passed-through DualSense, a uhid
/// device:
///   host → guest  `create <bus> <vendor> <product> <version> <keys> <axes> <name>` (GuestPad),
///                 `hid-create <bus> <vendor> <product> <version> <country> <descriptor> <name>`
///                 (HIDPassthrough), `remove`, `ev <type>:<code>:<value> …` (one input frame),
///                 `hid-input <report>`, `hid-get-reply <id> <err> [<report>]`, `hid-set-reply <id> <err>`
///   guest → host  `hello` (the service started, without a pad), `caps hid` (it takes `hid-create`),
///                 `rumble <strong> <weak>` (0…65535), `hid-output <type> <report>`,
///                 `hid-get <id> <type> <rnum>`, `hid-set <id> <type> <report>`
/// Reports are hex, report ID first. Main thread only.
final class PadPort {
    static let name = "fx.pad"
    /// Player 1's is `fx.pad` (what guest layers with a single pad serve), the others' `fx.pad2`, ….
    static func name(player index: Int) -> String { index == 0 ? name : "\(name)\(index + 1)" }
    let name: String
    /// Handed to libkrun: guest → host data is written here.
    let guestOutputFd: Int32
    /// Handed to libkrun: host → guest data is read from here.
    let guestInputFd: Int32
    private let readFd: Int32
    private let writeFd: Int32
    /// Bytes the pipe has not taken yet, whole lines in order. Beyond `maxPending` (the guest
    /// stopped reading) everything waiting is dropped and lines start clean again.
    private var pending: [UInt8] = []
    private static let maxPending = 256 * 1024
    private var writable: DispatchSourceWrite?
    private var writableArmed = false

    init(player index: Int = 0) throws {
        name = PadPort.name(player: index)
        var out: [Int32] = [0, 0], inp: [Int32] = [0, 0]
        guard pipe(&out) == 0, pipe(&inp) == 0 else { throw OptionError("pipe: \(String(cString: strerror(errno)))") }
        readFd = out[0]; guestOutputFd = out[1]
        guestInputFd = inp[0]; writeFd = inp[1]
        for fd in out + inp { _ = fcntl(fd, F_SETFD, FD_CLOEXEC) }
        // Never block the main thread if the guest stops reading: unwritten bytes wait in
        // `pending` and go out when the pipe has room.
        _ = fcntl(writeFd, F_SETFL, fcntl(writeFd, F_GETFL) | O_NONBLOCK)
    }

    /// One host → guest line, after everything queued before it; false if it had to be dropped.
    @discardableResult
    func send(_ line: String) -> Bool {
        let bytes = Array((line + "\n").utf8)
        if pending.count + bytes.count > PadPort.maxPending {
            pending.removeAll()
            if bytes.count > PadPort.maxPending { return false }
            // A dropped partial line would merge with the next one: a newline ends it.
            pending.append(UInt8(ascii: "\n"))
        }
        pending += bytes
        flush()
        return true
    }

    /// A line that a newer one replaces (an input report: each carries the whole state): sent
    /// only if nothing older still waits, so a slow guest gets fewer, current reports.
    @discardableResult
    func sendLatest(_ line: String) -> Bool {
        guard pending.isEmpty else { return false }
        return send(line)
    }

    private func flush() {
        while !pending.isEmpty {
            let n = pending.withUnsafeBytes { Darwin.write(writeFd, $0.baseAddress, $0.count) }
            if n > 0 {
                pending.removeFirst(n)
            } else if n < 0 && errno == EINTR {
                continue
            } else {
                break
            }
        }
        armWritable(!pending.isEmpty)
    }

    private func armWritable(_ on: Bool) {
        if writable == nil {
            let s = DispatchSource.makeWriteSource(fileDescriptor: writeFd, queue: .main)
            s.setEventHandler { [weak self] in self?.flush() }
            writable = s
        }
        guard on != writableArmed, let s = writable else { return }
        writableArmed = on
        if on { s.resume() } else { s.suspend() }
    }

    /// Reader thread: every complete line goes to `handler` on the main queue.
    func start(_ handler: @escaping (String) -> Void) {
        let t = Thread { [readFd] in
            var splitter = LineSplitter()
            var buf = [UInt8](repeating: 0, count: 512)
            while true {
                let n = Darwin.read(readFd, &buf, buf.count)
                if n < 0 && errno == EINTR { continue }
                if n <= 0 { break }
                buf.withUnsafeBytes { p in
                    splitter.feed(UnsafeRawBufferPointer(rebasing: p[0..<n])) { line in
                        let line = line.trimmingCharacters(in: .whitespacesAndNewlines)
                        if !line.isEmpty { DispatchQueue.main.async { handler(line) } }
                    }
                }
            }
        }
        t.name = name
        t.start()
    }
}

/// One of the guest's gamepads: player `index` + 1, over its own PadPort. Fed from the
/// GameController.framework extended gamepad GamepadBridge gave it (Xbox, DualSense, DualShock,
/// MFi, ...), whose actuators play its rumble; a DualSense (player 1) or a Steam Controller (any
/// usable player) can instead be passed through as itself (HIDPassthrough): its raw reports both
/// ways, so SteamOS drives touchpad, motion sensors, lights, rumble and triggers itself. The
/// guest's pad comes and goes with the controller and changes kind with it. Main thread only.
private final class PadSlot {
    let index: Int
    private let port: PadPort
    private let settings: LauncherSettings
    /// `--pad` for this run (wins over the setting).
    private let typeOverride: LauncherSettings.PadType?
    /// The Mac's supported raw HID controllers.
    private let hid: HIDPassthrough?
    private(set) var controller: GCController?
    private(set) var remote: GamepadBridge.RemotePad?
    var remoteRumble: ((_ lowFrequency: UInt16, _ highFrequency: UInt16) -> Void)?
    /// The uinput pad the guest has (created over the port), nil = none.
    private var guestPad: GuestPad?
    /// The controller the guest has as itself (a uhid device), nil = none.
    private var guestHID: HIDPassthrough.Device?
    /// What the guest last got (or, without a uinput pad, the controller's last state).
    private var state = GamepadBridge.PadState()
    /// The guest's service of this port said `hello`: it can create a pad.
    private(set) var serviceReady = false
    /// ... and `caps hid`: it can create a uhid device.
    private(set) var hidCapable = false
    /// --input-selftest, control `pad on`: a pad even without a controller.
    private var testPad = false
    private var paused = false
    private let rumble = Rumble()
    /// Input reports sent to the guest since the passed-through device was created.
    private var hidInputs = 0
    /// While the VM is paused (suspended, guest asleep): called before anything is sent, with
    /// whether a button went down; true = keep it from the guest (a press may wake it).
    var intercept: ((_ buttonPressed: Bool) -> Bool)?
    /// The guest's service said `hello` (GamepadBridge: the player can get a controller).
    var onHello: (() -> Void)?
    /// Whether a DualSense may be passed through now (GamepadBridge).
    var passthroughAllowed: () -> Bool = { true }
    /// The Steam Controller or generic HID assigned to this player by GamepadBridge.
    var rawControllerDevice: () -> HIDPassthrough.Device? = { nil }

    /// What the guest has (or should have) as its gamepad.
    private enum GuestDevice: Equatable {
        case pad(GuestPad)
        case hid(HIDPassthrough.Device)

        static func == (a: GuestDevice, b: GuestDevice) -> Bool {
            switch (a, b) {
            case let (.pad(x), .pad(y)): return x == y
            case let (.hid(x), .hid(y)): return x === y
            default: return false
            }
        }

        var title: String {
            switch self {
            case .pad(let p): return p.logTitle
            case .hid(let d): return "\(d.identity.name) (passed through)"
            }
        }
    }

    init(index: Int, port: PadPort, settings: LauncherSettings, typeOverride: LauncherSettings.PadType?, hid: HIDPassthrough?) {
        self.index = index
        self.port = port
        self.settings = settings
        self.typeOverride = typeOverride
        self.hid = hid
    }

    /// Log prefix: "gamepad" for player 1, "gamepad 2" ... for the others.
    private var tag: String { index == 0 ? "gamepad" : "gamepad \(index + 1)" }

    func start() {
        port.start { [weak self] line in self?.guestLine(line) }
    }

    /// The VM was paused (suspend, guest sleep) / runs again: no rumble or reports while nothing
    /// runs (a passed-through DualSense's next report carries its whole state again).
    func vmPaused(_ paused: Bool) {
        self.paused = paused
        rumble.paused = paused
        if paused && remote != nil { remoteRumble?(0, 0) }
    }

    func hidInput(_ report: UnsafeBufferPointer<UInt8>) {
        guard guestHID != nil, !paused else { return }
        if port.sendLatest("hid-input " + HIDPassthrough.hex(report)) {
            hidInputs += 1
            if hidInputs == 1 { log("\(tag): first input report to SteamOS: id 0x\(String(report[0], radix: 16)), \(report.count) bytes") }
        }
    }

    private func guestLine(_ line: String) {
        let w = line.split(separator: " ")
        if w == ["hello"] {
            // A (re)started service has no pad: create it again (`caps hid` follows a new one).
            log("\(tag): the guest's pad service is ready")
            serviceReady = true
            hidCapable = false
            if let d = guestHID { hid?.deactivate(d, owner: self) }
            guestPad = nil
            guestHID = nil
            rumble.set(strong: 0, weak: 0)
            onHello?()
            reconcile()
        } else if w == ["caps", "hid"] {
            hidCapable = true
            onHello?()
            reconcile()
        } else if w.count == 3, w[0] == "rumble", let strong = UInt16(w[1]), let weak = UInt16(w[2]) {
            if let remote {
                if !paused && remote.capabilities & 2 != 0 { remoteRumble?(strong, weak) }
            } else {
                rumble.set(strong: strong, weak: weak)
            }
        } else if w.count == 3, w[0] == "hid-output", let type = HIDPassthrough.ReportType(rawValue: String(w[1])),
                  let data = HIDPassthrough.unhex(w[2]) {
            if let d = guestHID { hid?.setReport(d, type: type, data: data) }
        } else if w.count == 4, w[0] == "hid-get", let id = UInt32(w[1]),
                  let type = HIDPassthrough.ReportType(rawValue: String(w[2])), let rnum = UInt8(w[3]) {
            // The guest's driver waits (up to 5 s) for an answer: always give one.
            guard let d = guestHID, let hid else { port.send("hid-get-reply \(id) \(ENODEV)"); return }
            hid.getReport(d, type: type, id: rnum) { [weak self, tag] r in
                switch r {
                case .success(let data): self?.port.send("hid-get-reply \(id) 0 \(HIDPassthrough.hex(data))")
                case .failure(let e):
                    log("\(tag): \(type.rawValue) report \(rnum) for SteamOS: \(HIDPassthrough.describe(e.code))")
                    self?.port.send("hid-get-reply \(id) \(EIO)")
                }
            }
        } else if w.count == 4, w[0] == "hid-set", let id = UInt32(w[1]),
                  let type = HIDPassthrough.ReportType(rawValue: String(w[2])), let data = HIDPassthrough.unhex(w[3]) {
            guard let d = guestHID, let hid else { port.send("hid-set-reply \(id) \(ENODEV)"); return }
            hid.setReport(d, type: type, data: data) { [weak self] r in
                self?.port.send("hid-set-reply \(id) \(r == kIOReturnSuccess ? 0 : EIO)")
            }
        } else {
            log("\(tag): unknown line \"\(line)\" on \(port.name)")
        }
    }

    /// The controller that drives this player's pad from now on (nil: none).
    func setController(_ next: GCController?) {
        if next === controller { return }
        controller?.extendedGamepad?.valueChangedHandler = nil
        controller?.extendedGamepad?.buttonHome?.pressedChangedHandler = nil
        controller = next
        rumble.attach(next)
        if let c = next, let pad = c.extendedGamepad {
            log("\(tag) active: \(GamepadBridge.logDisplayName(of: c))")
            // Keep the Home/PS button for the guest (Steam button) instead of macOS.
            pad.buttonHome?.preferredSystemGestureState = .disabled
            pad.buttonOptions?.preferredSystemGestureState = .disabled
            pad.buttonMenu.preferredSystemGestureState = .disabled
            // STEAMAC-4Y: distinguish a missing/consumed Home input from a profile callback
            // or guest delivery problem. The reported pad is a DualShock 4, not passthrough.
            log("\(tag): Home/PS \(GamepadBridge.homeDiagnostic(pad.buttonHome))")
            pad.buttonHome?.pressedChangedHandler = { [weak self] button, _, pressed in
                guard let self else { return }
                log("\(self.tag): Home/PS button callback \(pressed ? "pressed" : "released"), "
                    + GamepadBridge.homeDiagnostic(button))
            }
            pad.valueChangedHandler = { [weak self] pad, element in
                guard let self else { return }
                if element === pad.buttonHome {
                    log("\(self.tag): Home/PS profile callback, \(GamepadBridge.homeDiagnostic(pad.buttonHome)); "
                        + self.stateLine)
                }
                self.update(from: pad)
            }
        } else {
            log("\(tag): none connected")
        }
        // GamepadBridge.reconcileAll() after every assignment creates/releases pads: doing it
        // here per slot would briefly put one Steam Controller on two players while it moves.
        if let pad = guestPad {
            // Same pad, another controller: release what the previous one held.
            apply(GamepadBridge.rest(pad))
            refresh()
        }
    }

    func setRemote(_ next: GamepadBridge.RemotePad?) {
        let changed = remote?.number != next?.number || remote?.kind != next?.kind
        if changed, let pad = guestPad { apply(GamepadBridge.rest(pad)) }
        remote = next
        refresh()
    }

    /// What the guest should have: nothing without a controller or with "Virtual controller"
    /// off; the DualSense itself while it drives a DualSense pad and "Pass the DualSense through"
    /// is on (and the guest's service takes uhid devices); else a uinput pad of the kind from
    /// "Appears in SteamOS as" (`--pad`), Automatic = the controller's.
    private func wanted() -> (device: GuestDevice, why: String)? {
        guard settings.virtualPad else { return nil }
        if let remote { return (.pad(remote.kind), "Moonlight controller \(remote.number + 1)") }
        let type = typeOverride ?? settings.padType
        // A Steam Controller goes through in Automatic / Steam Controller; a generic HID that
        // GameController does not publish goes through in Automatic only. Puck slots follow an
        // unambiguous GameController player; BLE and generic devices reserve free players.
        if hidCapable, let d = rawControllerDevice(),
           type == .auto || (type == .steamController && !d.generic) {
            return (.hid(d), type == .auto ? "automatic, \(d.generic ? "generic HID controller" : "Steam Controller")" : (typeOverride == nil ? "setting" : "--pad"))
        }
        guard controller != nil || testPad else { return nil }
        let pad: GuestPad, why: String
        switch type {
        case .steamController: (pad, why) = (.xbox360, "no Steam Controller, another controller")
        case .xbox360: (pad, why) = (.xbox360, typeOverride == nil ? "setting" : "--pad")
        case .dualSense: (pad, why) = (.dualSense, typeOverride == nil ? "setting" : "--pad")
        case .dualShock4: (pad, why) = (.dualShock4, typeOverride == nil ? "setting" : "--pad")
        case .auto:
            guard let c = controller else { return (.pad(.xbox360), "automatic, no controller") }
            (pad, why) = (GuestPad.matching(c), "automatic, like \(GamepadBridge.logDisplayName(of: c))")
        }
        // GameController does not say which HID device a controller is: with several DualSenses
        // connected, the first one found is passed through, and none once two players have one
        // (`passthroughAllowed`: the device could be the other player's).
        if index == 0, pad == .dualSense, settings.dualSensePassthrough, hidCapable, passthroughAllowed(),
           controller?.extendedGamepad is GCDualSenseGamepad, let d = hid?.devices.first(where: { !$0.generic && !HIDPassthrough.isSteamController($0) }) {
            return (.hid(d), why)
        }
        return (.pad(pad), why)
    }

    private var current: GuestDevice? {
        guestHID.map { .hid($0) } ?? guestPad.map { .pad($0) }
    }

    /// Release the guest's current pad/device when it is no longer what `wanted()` asks for.
    /// GamepadBridge runs this on every slot before `reconcile()` so a Steam Controller moving to
    /// a lower player is removed once before the new slot creates it (no two uhid copies).
    func releaseIfUnwanted() {
        guard serviceReady else { return }
        let want = wanted()
        guard want?.device != current else { return }
        if let old = current {
            port.send("remove")
            log("\(tag): removed the \(old.title) from SteamOS")
        }
        if let d = guestHID { hid?.deactivate(d, owner: self) }
        guestPad = nil
        guestHID = nil
        rumble.set(strong: 0, weak: 0)
    }

    /// Create the guest's pad to match `wanted()` (call `releaseIfUnwanted()` first when several
    /// slots may shuffle one HID device between them).
    func reconcile() {
        guard serviceReady else { return }
        let want = wanted()
        guard want?.device != current else { return }
        releaseIfUnwanted()
        guard let want else { return }
        switch want.device {
        case .pad(let pad):
            guard port.send(pad.createLine) else {
                log("\(tag): cannot write to \(port.name)")
                return
            }
            guestPad = pad
            log("\(tag): SteamOS sees a \(pad.logTitle) (\(want.why))")
            // The new device is at rest; send the controller's current state.
            state = GamepadBridge.rest(pad)
            refresh()
        case .hid(let d):
            guard port.send(d.identity.createLine) else {
                log("\(tag): cannot write to \(port.name)")
                return
            }
            guestHID = d
            hidInputs = 0
            hid?.activate(d, owner: self) { [weak self] report in self?.hidInput(report) }
            log("\(tag): SteamOS sees the \(d.identity.name) itself, passed through (\(want.why))")
        }
    }

    /// Swap / deadzone changed, new pad: resend the current state with the current mapping.
    func refresh() {
        if let remote {
            apply(GamepadBridge.read(remote, as: guestPad ?? remote.kind, swapABXY: settings.swapABXY,
                                     deadzone: Float(settings.stickDeadzone) / 100))
        } else if let pad = controller?.extendedGamepad {
            update(from: pad)
        }
    }

    private func update(from pad: GCExtendedGamepad) {
        apply(GamepadBridge.read(pad, as: guestPad ?? .xbox360, swapABXY: settings.swapABXY,
                                 deadzone: Float(settings.stickDeadzone) / 100))
    }

    private func apply(_ next: GamepadBridge.PadState) {
        let pressed = next.buttons.contains { $0.value && state.buttons[$0.key] != true }
        if let intercept, intercept(pressed) {
            // Nothing is queued for the paused guest; `state` stays what the guest last got, so
            // the first change after the wake sends the difference (a tapped wake button: none).
            return
        }
        guard let pad = guestPad else {
            state = next
            return
        }
        var events: [String] = []
        for c in pad.buttonCodes where next.buttons[c] != state.buttons[c] {
            events.append("\(EV.KEY):\(c):\(next.buttons[c] == true ? 1 : 0)")
        }
        for a in GamepadBridge.axisCodes where next.axes[a] != state.axes[a] {
            events.append("\(EV.ABS):\(a):\(next.axes[a] ?? 0)")
        }
        let homeChanged = next.buttons[BTN.MODE] != state.buttons[BTN.MODE]
        state = next
        if !events.isEmpty {
            let accepted = port.send("ev " + events.joined(separator: " "))
            if homeChanged {
                log("\(tag): Home/PS \(next.buttons[BTN.MODE] == true ? "pressed" : "released") "
                    + (accepted ? "queued for SteamOS" : "dropped before pad port"))
            }
        }
    }

    /// A pad even without a controller (--input-selftest, control `pad on`) / only with one again.
    func setTestPad(_ on: Bool) {
        testPad = on
        reconcile()
    }

    /// --input-selftest: a pad even without a controller, press/release A and push the left stick
    /// right, then return to rest.
    func injectTestSequence() {
        setTestPad(true)
        guard guestPad != nil else {
            log("input selftest: no guest pad (the guest's \(port.name) service has not said hello)")
            return
        }
        var s = state
        s.buttons[BTN.SOUTH] = true
        s.axes[ABS.X] = 32767
        apply(s)
        s.buttons[BTN.SOUTH] = false
        s.axes[ABS.X] = 0
        apply(s)
    }

    /// control `pad state`: the guest pad, its service, the controller and the last rumble.
    var stateLine: String {
        "pad \(index == 0 ? "" : "\(index + 1) ")\(current?.title ?? "none"), service \(serviceReady ? "ready" : "not ready")\(hidCapable ? " (hid)" : ""), "
            + "controller \(controller.map(GamepadBridge.logDisplayName(of:)) ?? "none"), rumble \(rumble.level.strong) \(rumble.level.weak)"
            + ", Home/PS \(GamepadBridge.homeDiagnostic(controller?.extendedGamepad?.buttonHome))"
            + ", hid inputs \(hidInputs)"
    }
}

/// HID routing policy, independent of GameController and IOKit for the settings selftest.
enum SteamControllerRouting {
    /// GameController cannot identify which live Puck slot belongs to which controller.
    static func puckPlayer(_ steamPlayers: [Int], liveSlots: Int) -> Int? {
        steamPlayers.count == 1 && liveSlots == 1 ? steamPlayers[0] : nil
    }

    /// BLE reservations stay sticky. Generic reservations stay sticky only while their player
    /// is free of GameController controllers and the guest can create HID devices there.
    static func rawPlayers(previous: [UInt64: Int], devices: [UInt64], available: [Int],
                           genericDevices: [UInt64] = [], hidCapable: [Int] = []) -> [UInt64: Int] {
        func accepts(_ id: UInt64, _ player: Int) -> Bool {
            available.contains(player) && (!genericDevices.contains(id) || hidCapable.contains(player))
        }
        var next = previous.filter { devices.contains($0.key) && accepts($0.key, $0.value) }
        for id in devices where next[id] == nil {
            if let player = available.first(where: { accepts(id, $0) && !next.values.contains($0) }) { next[id] = player }
        }
        return next
    }

    static func selfCheck() -> [String] {
        var failures: [String] = []
        var checks = 0
        func check(_ ok: Bool, _ name: String) {
            checks += 1
            if !ok { failures.append("Steam Controller routing: \(name)") }
        }
        check(puckPlayer([1], liveSlots: 1) == 1, "one Puck")
        check(puckPlayer([0, 1], liveSlots: 1) == nil, "two GameController Steam Controllers")
        check(puckPlayer([0], liveSlots: 2) == nil, "two live Puck slots")
        check(puckPlayer([], liveSlots: 1) == nil, "no GameController Steam Controller")
        check(puckPlayer([0], liveSlots: 0) == nil, "no live Puck")
        let initial = rawPlayers(previous: [:], devices: [10], available: [1, 2, 3])
        check(initial == [10: 1], "BLE takes lowest free player")
        let sticky = rawPlayers(previous: initial, devices: [10], available: [0, 1, 2, 3])
        check(sticky == initial, "player 1 disconnect does not move BLE up")
        check(!availableControllerPlayer(1, rawPlayers: sticky), "new GameController cannot take raw HID player")
        check(availableControllerPlayer(0, rawPlayers: sticky), "new GameController may take lower free player")
        let disconnected = rawPlayers(previous: sticky, devices: [], available: [0, 1, 2, 3])
        check(disconnected.isEmpty, "BLE disconnect frees player")
        check(rawPlayers(previous: disconnected, devices: [11], available: [0, 1, 2, 3]) == [11: 0],
              "BLE reconnect takes lowest free player")
        check(rawPlayers(previous: sticky, devices: [10], available: []).isEmpty, "unusable players excluded")
        check(rawPlayers(previous: sticky, devices: [10, 20], available: [0, 1, 2, 3]) == [10: 1, 20: 0],
              "second BLE does not displace first")
        check(rawPlayers(previous: [:], devices: [10], available: []).isEmpty, "no free player")
        check(rawPlayers(previous: [:], devices: [10, 10, 20], available: [0, 1]) == [10: 0, 20: 1],
              "registry-ID duplicates never take two players")
        check(rawPlayers(previous: [10: 1, 20: 0], devices: [10], available: [0, 1]) == [10: 1],
              "generic disconnect frees only its player, BLE stays sticky")
        log("selftest-settings: Steam Controller routing: \(checks) checks, \(failures.isEmpty ? "PASS" : failures.joined(separator: "; "))")
        return failures
    }

    static func availableControllerPlayer(_ index: Int, rawPlayers: [UInt64: Int], genericDevices: [UInt64] = []) -> Bool {
        !rawPlayers.contains { $0.value == index && !genericDevices.contains($0.key) }
    }
}

/// Generic Desktop HID policy, without IOKit or live GameController state.
enum GenericHIDRouting {
    static let usages = [4, 5] // Joystick and Game Pad; Multi-axis (8), e.g. SpaceMouse, is excluded.

    static func enabled(automatic: Bool, virtualPad: Bool) -> Bool {
        automatic && virtualPad
    }

    static func accepts(usagePage: Int, usage: Int, knownController: Bool) -> Bool {
        usagePage == 1 && usages.contains(usage) && !knownController
    }

    static let publicationGrace: TimeInterval = 2
    enum Ownership: Equatable { case held, generic, gameController }

    /// There is no public GCController -> IOHIDDevice link. Require advertised HID support
    /// AND an actually published controller with an exact, case/whitespace-normalized name:
    /// vendorName or productCategory equals product, manufacturer, or "manufacturer product".
    /// Do not use substrings or VID-only guesses (unrelated controllers can coexist).
    static func matchesController(product: String?, manufacturer: String?, vendorName: String?, productCategory: String) -> Bool {
        func normalized(_ value: String?) -> String {
            (value ?? "").split(whereSeparator: \.isWhitespace).joined(separator: " ").lowercased()
        }
        let product = normalized(product), manufacturer = normalized(manufacturer)
        let names = [product, manufacturer, [manufacturer, product].filter { !$0.isEmpty }.joined(separator: " ")]
        return [normalized(vendorName), normalized(productCategory)].contains { name in
            !name.isEmpty && names.contains(name)
        }
    }

    /// GameController publishes asynchronously. Hold supported devices without opening them
    /// for two seconds, then permit generic HID unless a matching controller really exists.
    /// The same decision applies on later GC connect/disconnect (including after acceptance).
    static func ownership(supported: Bool, matchingController: Bool, elapsed: TimeInterval) -> Ownership {
        guard supported else { return .generic }
        if matchingController { return .gameController }
        return elapsed < publicationGrace ? .held : .generic
    }

    static func reportID(numbered: Bool, firstByte: UInt8) -> UInt8 {
        numbered ? firstByte : 0
    }

    static func productName(_ name: String?, fallback: String) -> String {
        guard let name, !name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return fallback }
        return name
    }

    static func selfCheck() -> [String] {
        var failures: [String] = []
        var checks = 0
        func check(_ ok: Bool, _ name: String) {
            checks += 1
            if !ok { failures.append("Generic HID routing: \(name)") }
        }
        func accepts(_ page: Int, _ usage: Int, known: Bool = false) -> Bool {
            Self.accepts(usagePage: page, usage: usage, knownController: known)
        }
        check(accepts(1, 5), "DJI / Spektrum gamepad")
        check(accepts(1, 4), "joystick")
        check(!accepts(1, 8), "not multi-axis / SpaceMouse")
        for usage in [1, 2, 6, 7] { check(!accepts(1, usage), "not pointer/mouse/keyboard/keypad \(usage)") }
        check(!accepts(0x0d, 5), "not digitizer/trackpad")
        check(!accepts(0xff00, 5), "not vendor-defined/internal collection")
        check(!accepts(1, 5, known: true), "DualSense/Valve use their existing path")
        check(ownership(supported: true, matchingController: false, elapsed: 0) == .held, "supported HID waits for publication")
        check(ownership(supported: true, matchingController: false, elapsed: 1.999) == .held, "full publication grace")
        check(ownership(supported: true, matchingController: false, elapsed: 2) == .generic, "support alone does not claim HID")
        check(ownership(supported: true, matchingController: true, elapsed: 1) == .gameController, "publication during grace claims HID")
        check(ownership(supported: true, matchingController: true, elapsed: 3) == .gameController, "late publication claims HID")
        check(ownership(supported: true, matchingController: false, elapsed: 3) == .generic, "GC disappearance re-offers HID")
        check(ownership(supported: false, matchingController: true, elapsed: 0) == .generic, "name alone never claims unsupported HID")
        func matches(_ vendor: String?, _ category: String = "", product: String? = "C5", manufacturer: String? = "DJI") -> Bool {
            matchesController(product: product, manufacturer: manufacturer, vendorName: vendor, productCategory: category)
        }
        check(matches(" c5\n"), "product match ignores case and surrounding whitespace")
        check(matches(" dJi "), "manufacturer matches vendorName")
        check(matches(" DJI \n C5 "), "combined name collapses internal whitespace")
        check(matches(nil, " c5 "), "productCategory can identify a published controller")
        check(!matches("C50"), "no product substring match")
        check(!matches("DJI Other"), "manufacturer prefix alone does not match")
        check(!matches(nil, "", product: nil, manufacturer: " \n"), "missing/blank names do not match")
        check(!matches("Xbox Wireless Controller", "Xbox One"), "unrelated published controller does not claim DJI")
        check(enabled(automatic: true, virtualPad: true), "Automatic permits generic HID")
        check(!enabled(automatic: true, virtualPad: false), "Virtual controller off excludes generic matching")
        check(!enabled(automatic: false, virtualPad: true), "explicit pad kinds exclude generic matching")
        check(reportID(numbered: false, firstByte: 0x81) == 0, "unnumbered payload is not a report ID")
        check(reportID(numbered: true, firstByte: 0x81) == 0x81, "numbered output preserves report ID")
        check(productName(nil, fallback: "HID 2ca3:1020") == "HID 2ca3:1020", "missing product name")
        check(productName("", fallback: "HID 2ca3:1020") == "HID 2ca3:1020", "empty product name")
        check(productName(" \n", fallback: "HID 2ca3:1020") == "HID 2ca3:1020", "blank product name")
        check(productName("C5", fallback: "HID 2ca3:1020") == "C5", "preserve actual product name")
        let initial: [UInt64: Int] = [10: 0]
        let generic: [UInt64] = [10]
        check(SteamControllerRouting.availableControllerPlayer(0, rawPlayers: initial, genericDevices: generic),
              "generic yields player 1 to a newly connected GameController")
        check(!SteamControllerRouting.availableControllerPlayer(0, rawPlayers: initial),
              "BLE Steam Controller still blocks new GameController on its sticky player")
        func routed(previous: [UInt64: Int], available: [Int], capable: [Int], devices: [UInt64] = [10]) -> [UInt64: Int] {
            SteamControllerRouting.rawPlayers(previous: previous, devices: devices, available: available,
                                               genericDevices: generic, hidCapable: capable)
        }
        check(routed(previous: initial, available: [1, 2, 3], capable: [0, 1, 2, 3]) == [10: 1],
              "generic moves to lowest free player after GameController takes player 1")
        check(routed(previous: initial, available: [], capable: [0]).isEmpty,
              "single-player generic releases reservation when GameController connects")
        check(routed(previous: [10: 1], available: [0, 1, 2], capable: [0, 1, 2]) == [10: 1],
              "generic remains sticky when a lower player becomes free")
        check(routed(previous: initial, available: [0, 1], capable: []).isEmpty,
              "old guest without caps hid gets no generic reservation")
        check(routed(previous: initial, available: [0, 1, 2], capable: [2]) == [10: 2],
              "generic skips players whose service lacks HID support")
        check(routed(previous: [10: 0, 20: 1], available: [1, 2], capable: [1, 2], devices: [10, 20]) == [10: 2, 20: 1],
              "generic moves without displacing a sticky BLE Steam Controller")
        check(routed(previous: [10: 2], available: [0, 1, 2], capable: [0, 1, 2], devices: []).isEmpty,
              "generic disconnect frees its reservation")
        log("selftest-settings: generic HID routing: \(checks) checks, \(failures.isEmpty ? "PASS" : failures.joined(separator: "; "))")
        return failures
    }
}

/// Feeds the guest's gamepads (GuestPad over PadPort, one PadSlot per player) from the Mac's
/// GameController.framework controllers, or passes a DualSense (player 1) / Steam Controller
/// (any usable player) through as itself. Settings > Controller picks which controller is player
/// 1 (first connected by default), whether SteamOS gets a pad and what kind ("Appears in SteamOS
/// as"; Automatic = the controller's own kind), whether a DualSense is passed through, swaps A/B
/// and X/Y for Nintendo-style layouts and applies a radial stick deadzone, all while the VM runs.
///
/// Further controllers are players 2…`maxPads` ("Additional controllers"), each on a port of its
/// own (`fx.pad2`, …) once the guest's service of that port said `hello`: a guest layer without
/// those services keeps the one pad, driven as before. A player keeps their controller until it
/// disconnects (the others do not move up), and a reconnected controller takes the first free
/// player. A Steam Controller on a free usable player is passed through the same way (Puck slot
/// → that player's GameController controller when unambiguous; Bluetooth LE → sticky free player).
final class GamepadBridge {
    /// Players at most: one PadPort each.
    static let maxPads = 4
    /// The player (1…) each controller drives, for Settings > Controller (main thread; posts
    /// `.gamepadPlayersChanged` when it changes).
    nonisolated(unsafe) private(set) static var players: [ObjectIdentifier: Int] = [:]

    private let slots: [PadSlot]
    private let settings: LauncherSettings
    private let typeOverride: LauncherSettings.PadType?
    private let hid: HIDPassthrough
    /// Controllers without a GameController object share sticky reservations (BLE and generic).
    private var rawPlayers: [UInt64: Int] = [:]
    private var localPlayersBeforeStream: (controllers: [GCController?], raw: [UInt64: Int])?
    private var remotePads: [UInt16: RemotePad] = [:]
    private var remotePlayers: [UInt16: Int] = [:]
    private var remoteRumble: ((_ controller: UInt16, _ lowFrequency: UInt16, _ highFrequency: UInt16) -> Void)?
    private var observers: [NSObjectProtocol] = []
    private var subscriptions: [AnyCancellable] = []
    /// While the VM is paused (suspended, guest asleep): called before anything is sent, with
    /// whether a button went down; true = keep it from the guest (a press may wake it).
    var intercept: ((_ buttonPressed: Bool) -> Bool)? {
        didSet { for s in slots { s.intercept = intercept } }
    }
    /// Settings > Controller: Input Monitoring is required for a matched Steam Controller / composite HID device.
    var onInputMonitoringNeeded: ((Bool) -> Void)? {
        didSet {
            hid.onPermissionNeededChange = onInputMonitoringNeeded
            onInputMonitoringNeeded?(hid.needsInputMonitoring)
        }
    }

    /// Settings > Controller button: ask macOS again and reopen HID once granted.
    func requestInputMonitoring() {
        hid.requestInputMonitoring()
    }

    struct PadState: Equatable {
        var buttons: [UInt16: Bool] = [:]
        var axes: [UInt16: Int32] = [:]
    }

    struct RemotePad: Equatable {
        let number: UInt16
        var kind: GuestPad = .xbox360
        var capabilities: UInt16 = 3
        var supportedButtons: UInt32 = 0xffff
        var buttons: UInt32 = 0
        var leftTrigger: UInt8 = 0
        var rightTrigger: UInt8 = 0
        var leftX: Int16 = 0
        var leftY: Int16 = 0
        var rightX: Int16 = 0
        var rightY: Int16 = 0
    }

    /// Moonlight's controllers (by controller number). They take the first usable players ahead of
    /// the Mac's controllers and keep them while present (sticky). Removing the last remote pad
    /// restores pre-stream local players; newly connected controllers fill the remaining players.
    func setRemotePads(_ pads: [UInt16: RemotePad],
                       rumble: @escaping (_ controller: UInt16, _ lowFrequency: UInt16, _ highFrequency: UInt16) -> Void) {
        remoteRumble = rumble
        if !pads.isEmpty && localPlayersBeforeStream == nil { saveLocalPlayers() }
        let topologyChanged = remotePads.count != pads.count
            || pads.contains { remotePads[$0.key]?.kind != $0.value.kind }
        remotePads = pads
        if pads.isEmpty { restoreLocalPlayers(connected: GamepadBridge.connected) }
        if topologyChanged {
            assignControllers()
        } else {
            for (number, player) in remotePlayers { slots[player].setRemote(pads[number]) }
        }
    }

    func removeRemotePads() {
        remotePads.removeAll()
        restoreLocalPlayers(connected: GamepadBridge.connected)
        assignControllers()
        remoteRumble = nil
    }

    private func saveLocalPlayers() {
        localPlayersBeforeStream = (slots.map(\.controller), rawPlayers)
    }

    private func restoreLocalPlayers(connected: [GCController]) {
        guard let saved = localPlayersBeforeStream else { return }
        localPlayersBeforeStream = nil
        remotePlayers.removeAll()
        // Clear displaced owners before restoring: a controller has only one profile callback.
        for slot in slots { slot.setRemote(nil); slot.remoteRumble = nil }
        for slot in slots { slot.setController(nil) }
        rawPlayers = saved.raw
        for (i, controller) in saved.controllers.enumerated() where usable(i) {
            if let controller, connected.contains(where: { $0 === controller }) {
                slots[i].setController(controller)
            }
        }
        // assignControllers() filters disconnected HID reservations and fills free players with
        // controllers connected during the stream, without retaining their temporary player.
    }

    static func remoteRestorationSelfCheck() -> [String] {
        var failures: [String] = []
        do {
            let ports = try [PadPort(), PadPort(player: 1)]
            let bridge = GamepadBridge(ports: ports, settings: LauncherSettings.shared, typeOverride: nil)
            let original = GCController.withExtendedGamepad()
            let newcomer = GCController.withExtendedGamepad()
            bridge.slots[0].setController(original)
            bridge.rawPlayers = [10: 1]
            bridge.saveLocalPlayers()
            bridge.slots[0].setController(nil)
            bridge.slots[1].setController(original)
            bridge.rawPlayers = [10: 0, 20: 1]
            bridge.restoreLocalPlayers(connected: [original, newcomer])
            if bridge.slots[0].controller !== original || bridge.slots[1].controller != nil {
                failures.append("input: restore Mac controller to pre-stream player")
            }
            if bridge.rawPlayers != [10: 1] {
                failures.append("input: restore pre-stream raw HID reservations")
            }
            bridge.saveLocalPlayers()
            bridge.slots[0].setController(nil)
            bridge.slots[1].setController(newcomer)
            bridge.restoreLocalPlayers(connected: [newcomer])
            if bridge.slots.contains(where: { $0.controller != nil }) {
                failures.append("input: disconnected pre-stream controllers are not restored")
            }
            bridge.slots[0].setController(newcomer)
            bridge.restoreLocalPlayers(connected: [newcomer])
            if bridge.slots[0].controller !== newcomer {
                failures.append("input: no-stream restoration leaves local players unchanged")
            }
        } catch {
            failures.append("input: remote restoration test ports: \(error)")
        }
        return failures
    }

    static let axisCodes: [UInt16] = GuestPad.axes.map(\.code)

    /// `ports`: player 1's first (at least one).
    init(ports: [PadPort], settings: LauncherSettings, typeOverride: LauncherSettings.PadType?) {
        let hid = HIDPassthrough()
        self.hid = hid
        self.settings = settings
        self.typeOverride = typeOverride
        slots = ports.enumerated().map { i, port in
            PadSlot(index: i, port: port, settings: settings, typeOverride: typeOverride, hid: hid)
        }
    }

    /// Everything released, sticks centred.
    static func rest(_ pad: GuestPad) -> PadState {
        PadState(buttons: Dictionary(uniqueKeysWithValues: pad.buttonCodes.map { ($0, false) }),
                 axes: Dictionary(uniqueKeysWithValues: axisCodes.map { ($0, 0) }))
    }

    /// Settings identifier of a controller: "<vendorName>|<productCategory>".
    static func identifier(of c: GCController) -> String {
        "\(c.vendorName ?? "?")|\(c.productCategory)"
    }

    /// The Steam Controller as GameController shows it: the Puck is "Steam Controller Puck
    /// (Steam Controller)" (all its slots are one GameController controller); a controller on
    /// Bluetooth LE is not shown at all. GameController does not expose HID vendor/product, so
    /// it is matched by vendorName / productCategory.
    static func isSteamController(_ c: GCController) -> Bool {
        c.vendorName == "Steam Controller Puck" || c.productCategory == "Steam Controller"
    }

    static func displayName(of c: GCController) -> String {
        let vendor = c.vendorName ?? String(localized: "Controller", comment: "Unnamed game controller")
        return vendor == c.productCategory ? vendor : "\(vendor) (\(c.productCategory))"
    }

    static func logDisplayName(of c: GCController) -> String {
        let vendor = c.vendorName ?? "Controller"
        return vendor == c.productCategory ? vendor : "\(vendor) (\(c.productCategory))"
    }

    /// Connection/report diagnostics only: a preferred disabled gesture is not a guarantee
    /// that macOS honors it (GCControllerElement); do not infer that a missing input was sent.
    static func homeDiagnostic(_ button: GCControllerButtonInput?) -> String {
        guard let button else { return "unavailable in GameController" }
        return "\(button.isPressed ? "pressed" : "released"), system-bound=\(button.isBoundToSystemGesture), "
            + "preferred-gesture=\(button.preferredSystemGestureState.rawValue)"
    }

    /// Extended gamepads in connection order.
    static var connected: [GCController] {
        GCController.controllers().filter { $0.extendedGamepad != nil }
    }

    func start() {
        GCController.shouldMonitorBackgroundEvents = true
        let nc = NotificationCenter.default
        observers.append(nc.addObserver(forName: .GCControllerDidConnect, object: nil, queue: .main) { [weak self] n in
            if let c = n.object as? GCController { log("gamepad connected: \(c.vendorName ?? "?") (\(c.productCategory))") }
            self?.hid.gameControllersChanged()
            self?.assignControllers()
        })
        observers.append(nc.addObserver(forName: .GCControllerDidDisconnect, object: nil, queue: .main) { [weak self] n in
            if let c = n.object as? GCController { log("gamepad disconnected: \(c.vendorName ?? "?")") }
            self?.hid.gameControllersChanged()
            self?.assignControllers()
        })
        observers.append(nc.addObserver(forName: .GCControllerDidBecomeCurrent, object: nil, queue: .main) { [weak self] _ in
            self?.assignControllers()
        })
        // @Published emits before the property changes: re-read on the next main-queue turn.
        for p in [settings.$controllerID.map { _ in () }.eraseToAnyPublisher(), settings.$additionalPads.map { _ in () }.eraseToAnyPublisher()] {
            subscriptions.append(p.dropFirst().receive(on: DispatchQueue.main).sink { [weak self] in self?.assignControllers() })
        }
        for p in [settings.$padType.map { _ in () }.eraseToAnyPublisher(), settings.$virtualPad.map { _ in () }.eraseToAnyPublisher()] {
            subscriptions.append(p.dropFirst().receive(on: DispatchQueue.main).sink { [weak self] _ in
                guard let self else { return }
                self.hid.matchSteamControllers = self.matchesValveControllers
                self.hid.matchGenericControllers = self.matchesGenericControllers
                self.assignControllers()
            })
        }
        for p in [settings.$virtualPad.map { _ in () }.eraseToAnyPublisher(), settings.$padType.map { _ in () }.eraseToAnyPublisher(),
                  settings.$dualSensePassthrough.map { _ in () }.eraseToAnyPublisher()] {
            subscriptions.append(p.dropFirst().receive(on: DispatchQueue.main).sink { [weak self] in
                self?.reconcileAll()
            })
        }
        for p in [settings.$swapABXY.map { _ in () }.eraseToAnyPublisher(), settings.$stickDeadzone.map { _ in () }.eraseToAnyPublisher()] {
            subscriptions.append(p.dropFirst().receive(on: DispatchQueue.main).sink { [weak self] in
                for s in self?.slots ?? [] { s.refresh() }
            })
        }
        for s in slots {
            s.onHello = { [weak self] in self?.assignControllers() }
            s.start()
        }
        // The HID device could be another player's DualSense: none is passed through then.
        slots[0].passthroughAllowed = { [weak self] in
            !(self?.slots.dropFirst().contains { $0.controller?.extendedGamepad is GCDualSenseGamepad } ?? false)
        }
        // Each player's raw controller: an unambiguous Puck slot follows GameController,
        // while BLE and generic devices keep their reserved players.
        for s in slots {
            let playerIndex = s.index
            s.rawControllerDevice = { [weak self] in self?.assignedRawDevice(for: playerIndex) }
        }
        hid.matchSteamControllers = matchesValveControllers
        hid.matchGenericControllers = matchesGenericControllers
        hid.onChange = { [weak self] in
            self?.assignControllers()
        }
        // Give already-connected GameController controllers players before discovering raw HID.
        assignControllers()
        hid.start()
        GCController.startWirelessControllerDiscovery(completionHandler: nil)
        assignControllers()
    }

    /// The VM was paused (suspend, guest sleep) / runs again.
    func vmPaused(_ paused: Bool) {
        for s in slots { s.vmPaused(paused) }
    }

    /// Player `i` can have a controller: player 1 always (before the guest runs too: a button
    /// wakes it), the others with "Additional controllers" on and their guest service up.
    private func usable(_ i: Int) -> Bool {
        i == 0 || (settings.additionalPads && slots[i].serviceReady)
    }

    /// Whether Valve's Steam Controllers are matched (and passed through as themselves).
    private var matchesValveControllers: Bool {
        let t = typeOverride ?? settings.padType
        return t == .auto || t == .steamController
    }

    private var matchesGenericControllers: Bool {
        GenericHIDRouting.enabled(automatic: (typeOverride ?? settings.padType) == .auto, virtualPad: settings.virtualPad)
    }

    /// Reconcile raw HID reservations only on topology/settings changes, never while querying a slot.
    private func updateRawPlayers() {
        let devices = hid.devices.filter {
            $0.generic ? matchesGenericControllers
                : (matchesValveControllers && HIDPassthrough.isLiveSteamController($0) && $0.puckSlot == nil)
        }.map(\.registryID)
        let available = slots.indices.filter { usable($0) && slots[$0].controller == nil && slots[$0].remote == nil }
        rawPlayers = SteamControllerRouting.rawPlayers(previous: rawPlayers, devices: devices, available: available,
            genericDevices: hid.devices.filter(\.generic).map(\.registryID),
            hidCapable: slots.indices.filter { slots[$0].hidCapable })
    }

    /// A Puck slot is safe only with exactly one GameController Steam Controller and one live
    /// Puck slot; ambiguous setups retain their GameController/uinput pads. BLE/generic reserve players.
    private func assignedRawDevice(for index: Int) -> HIDPassthrough.Device? {
        guard usable(index), slots[index].remote == nil else { return nil }
        let steamPlayers = matchesValveControllers
            ? slots.indices.filter { slots[$0].controller.map(GamepadBridge.isSteamController) ?? false } : []
        let livePuckSlots = hid.devices.filter { $0.puckSlot != nil && HIDPassthrough.isLiveSteamController($0) }
        if SteamControllerRouting.puckPlayer(steamPlayers, liveSlots: livePuckSlots.count) == index {
            return livePuckSlots.first
        }
        return hid.devices.first { rawPlayers[$0.registryID] == index }
    }

    /// Release then create across every slot so one Steam Controller moving between players never
    /// briefly exists twice in the guest, and the old slot cannot clear the new slot's handler.
    private func reconcileAll() {
        updateRawPlayers()
        for s in slots { s.releaseIfUnwanted() }
        for s in slots { s.reconcile() }
    }

    /// Give the players their controllers. One player: the controller chosen in Settings, else
    /// the first connected (the chosen one is not connected: fall back to it as well). Several:
    /// everybody keeps theirs while it is connected, the chosen one is player 1 when it is there,
    /// and free players get the remaining controllers in connection order.
    private func assignControllers() {
        let candidates = GamepadBridge.connected
        // Moonlight controllers come first: the remote player is the one using SteamOS during a
        // stream (with one usable player, a Mac controller waits until the stream ends).
        remotePlayers = remotePlayers.filter { remotePads[$0.key] != nil && usable($0.value) }
        for number in remotePads.keys.sorted() where remotePlayers[number] == nil {
            if let player = slots.indices.first(where: { usable($0) && !remotePlayers.values.contains($0) }) {
                remotePlayers[number] = player
            }
        }
        for slot in slots {
            let number = remotePlayers.first { $0.value == slot.index }?.key
            slot.setRemote(number.flatMap { remotePads[$0] })
            slot.remoteRumble = { [weak self] low, high in
                if let number { self?.remoteRumble?(number, low, high) }
            }
        }
        updateRawPlayers()
        let genericDevices = hid.devices.filter(\.generic).map(\.registryID)
        func available(_ index: Int) -> Bool {
            !remotePlayers.values.contains(index)
                && SteamControllerRouting.availableControllerPlayer(index, rawPlayers: rawPlayers, genericDevices: genericDevices)
        }
        let chosen = settings.controllerID.isEmpty ? nil
            : candidates.first { GamepadBridge.identifier(of: $0) == settings.controllerID }
        var next = [GCController?](repeating: nil, count: slots.count)
        if !slots.indices.dropFirst().contains(where: usable) {
            if available(0) { next[0] = chosen ?? candidates.first }
        } else {
            for (i, s) in slots.enumerated() where usable(i) && available(i) {
                if let c = s.controller, candidates.contains(where: { $0 === c }) { next[i] = c }
            }
            // Two controllers of one model have the same identifier: player 1 keeps a matching one.
            if let chosen, available(0), next[0].map(GamepadBridge.identifier(of:)) != settings.controllerID {
                if let j = next.firstIndex(where: { $0 === chosen }) { next[j] = next[0] }
                next[0] = chosen
            }
            for i in slots.indices where usable(i) && available(i) && next[i] == nil {
                next[i] = candidates.first { c in !next.contains { $0 === c } }
            }
        }
        // A controller that changes players leaves the old one first (one input handler each).
        for (i, s) in slots.enumerated() where s.controller != nil && s.controller !== next[i]
            && next.contains(where: { $0 === s.controller }) {
            s.setController(nil)
        }
        for (i, s) in slots.enumerated() { s.setController(next[i]) }
        // Preserve raw HID reservations while filling free players, then route every HID kind.
        reconcileAll()
        let players = Dictionary(uniqueKeysWithValues: slots.compactMap { s in s.controller.map { (ObjectIdentifier($0), s.index + 1) } })
        if players != GamepadBridge.players {
            GamepadBridge.players = players
            NotificationCenter.default.post(name: .gamepadPlayersChanged, object: nil)
        }
    }

    private static func axis(_ v: Float) -> Int32 {
        Int32((max(-1, min(1, v)) * 32767).rounded())
    }

    /// Radial deadzone `dz` (0..1), rescaled so the stick still reaches full deflection.
    static func deadzoned(_ x: Float, _ y: Float, _ dz: Float) -> (Float, Float) {
        guard dz > 0 else { return (x, y) }
        let m = (x * x + y * y).squareRoot()
        guard m > dz else { return (0, 0) }
        let scale = min(1, (m - dz) / (1 - dz)) / m
        return (x * scale, y * scale)
    }

    /// The guest pad's state for this controller state. GameController names the face buttons
    /// by position (A south, B east, X west, Y north), like the guest's codes for a Sony pad; xpad
    /// reports Xbox X (west) as BTN_X (= BTN_NORTH's code) and Y (north) as BTN_Y (= BTN_WEST's).
    static func read(_ p: GCExtendedGamepad, as pad: GuestPad, swapABXY: Bool, deadzone: Float) -> PadState {
        var s = PadState()
        let (south, east) = swapABXY ? (p.buttonB, p.buttonA) : (p.buttonA, p.buttonB)
        let (west, north) = swapABXY ? (p.buttonY, p.buttonX) : (p.buttonX, p.buttonY)
        s.buttons[BTN.SOUTH] = south.isPressed
        s.buttons[BTN.EAST] = east.isPressed
        if pad.sony {
            s.buttons[BTN.WEST] = west.isPressed
            s.buttons[BTN.NORTH] = north.isPressed
            s.buttons[BTN.TL2] = p.leftTrigger.isPressed
            s.buttons[BTN.TR2] = p.rightTrigger.isPressed
        } else {
            s.buttons[BTN.NORTH] = west.isPressed
            s.buttons[BTN.WEST] = north.isPressed
        }
        s.buttons[BTN.TL] = p.leftShoulder.isPressed
        s.buttons[BTN.TR] = p.rightShoulder.isPressed
        s.buttons[BTN.SELECT] = p.buttonOptions?.isPressed ?? false
        s.buttons[BTN.START] = p.buttonMenu.isPressed
        s.buttons[BTN.MODE] = p.buttonHome?.isPressed ?? false
        s.buttons[BTN.THUMBL] = p.leftThumbstickButton?.isPressed ?? false
        s.buttons[BTN.THUMBR] = p.rightThumbstickButton?.isPressed ?? false
        // xpad and hid-playstation report Y axes inverted relative to GameController (up = negative).
        let l = deadzoned(p.leftThumbstick.xAxis.value, p.leftThumbstick.yAxis.value, deadzone)
        let r = deadzoned(p.rightThumbstick.xAxis.value, p.rightThumbstick.yAxis.value, deadzone)
        s.axes[ABS.X] = axis(l.0)
        s.axes[ABS.Y] = -axis(l.1)
        s.axes[ABS.RX] = axis(r.0)
        s.axes[ABS.RY] = -axis(r.1)
        s.axes[ABS.Z] = Int32((max(0, min(1, p.leftTrigger.value)) * 255).rounded())
        s.axes[ABS.RZ] = Int32((max(0, min(1, p.rightTrigger.value)) * 255).rounded())
        let d = p.dpad
        s.axes[ABS.HAT0X] = d.left.isPressed ? -1 : (d.right.isPressed ? 1 : 0)
        s.axes[ABS.HAT0Y] = d.up.isPressed ? -1 : (d.down.isPressed ? 1 : 0)
        return s
    }

    static func read(_ p: RemotePad, as pad: GuestPad, swapABXY: Bool, deadzone: Float) -> PadState {
        var s = rest(pad)
        let flags = p.buttons & p.supportedButtons
        func down(_ bit: UInt32) -> Bool { flags & bit != 0 }
        s.buttons[BTN.SOUTH] = down(swapABXY ? 0x2000 : 0x1000)
        s.buttons[BTN.EAST] = down(swapABXY ? 0x1000 : 0x2000)
        s.buttons[pad.sony ? BTN.WEST : BTN.NORTH] = down(swapABXY ? 0x8000 : 0x4000)
        s.buttons[pad.sony ? BTN.NORTH : BTN.WEST] = down(swapABXY ? 0x4000 : 0x8000)
        for (code, bit): (UInt16, UInt32) in [(BTN.TL, 0x100), (BTN.TR, 0x200), (BTN.SELECT, 0x20),
                                            (BTN.START, 0x10), (BTN.MODE, 0x400),
                                            (BTN.THUMBL, 0x40), (BTN.THUMBR, 0x80)] {
            s.buttons[code] = down(bit)
        }
        if pad.sony {
            s.buttons[BTN.TL2] = p.leftTrigger > 0
            s.buttons[BTN.TR2] = p.rightTrigger > 0
        }
        let l = deadzoned(max(-1, Float(p.leftX) / 32767), max(-1, Float(p.leftY) / 32767), deadzone)
        let r = deadzoned(max(-1, Float(p.rightX) / 32767), max(-1, Float(p.rightY) / 32767), deadzone)
        s.axes[ABS.X] = axis(l.0); s.axes[ABS.Y] = -axis(l.1)
        s.axes[ABS.RX] = axis(r.0); s.axes[ABS.RY] = -axis(r.1)
        s.axes[ABS.Z] = Int32(p.leftTrigger); s.axes[ABS.RZ] = Int32(p.rightTrigger)
        s.axes[ABS.HAT0X] = down(4) ? -1 : (down(8) ? 1 : 0)
        s.axes[ABS.HAT0Y] = down(1) ? -1 : (down(2) ? 1 : 0)
        return s
    }

    /// --input-selftest: pads for players 1 and 2 even without controllers (player 2 if the guest
    /// serves its port), each presses/releases A and pushes the left stick right, then returns to
    /// rest.
    func injectTestSequence() {
        for s in slots.prefix(2) where s.index == 0 || s.serviceReady { s.injectTestSequence() }
    }

    /// Shared by `pad state` and the opt-in launcher-log attachment. Main thread only.
    func diagnosticLines() -> [String] {
        var lines = ["Controller settings: pad=\((typeOverride ?? settings.padType).rawValue), "
            + "virtual=\(settings.virtualPad), DualSense passthrough=\(settings.dualSensePassthrough), "
            + "stick deadzone=\(settings.stickDeadzone)% (uinput only)"]
        for s in slots where s.index == 0 || s.serviceReady || s.controller != nil { lines.append(s.stateLine) }
        let steam = hid.devices.filter(HIDPassthrough.isSteamController).count
        let generic = hid.devices.filter(\.generic).count
        lines.append("HID DualSenses \(hid.devices.count - steam - generic), Steam Controllers \(steam), generic controllers \(generic)")
        for d in hid.devices where d.generic {
            let player = rawPlayers[d.registryID].map { String($0 + 1) } ?? "none (no usable free player)"
            lines.append(String(format: "generic HID %04x:%04x", d.identity.vendor, d.identity.product)
                + " \(d.identity.name), registry \(d.registryID), player \(player)")
        }
        lines += hid.diagnosticLines()
        return lines
    }

    /// --control-fifo `pad on|off|test [<player>]`, `pad state` (DebugControl).
    func control(_ args: [String]) {
        let usage = "control: pad on|off|test [1…\(slots.count)] | state"
        guard let player = args.count > 1 ? Int(args[1]) : 1, slots.indices.contains(player - 1) else { log(usage); return }
        let slot = slots[player - 1]
        switch args.first {
        case "on", "off":
            slot.setTestPad(args.first == "on")
        case "test":
            slot.injectTestSequence()
        case "state":
            for line in diagnosticLines() { log("control: \(line)") }
        default:
            log(usage)
        }
    }
}

extension Notification.Name {
    /// GamepadBridge.players changed.
    static let gamepadPlayersChanged = Notification.Name("GamepadBridgePlayersChanged")
}
