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

/// The `fx.pad` virtio-console port to the guest's root service fx-pad (`fx-progress-agent pad`,
/// guest/progress-agent/src/pad.rs), which owns the guest's gamepad as a uinput device or, for a
/// passed-through DualSense, a uhid device:
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

    init() throws {
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
        t.name = "fx.pad"
        t.start()
    }
}

/// Feeds the guest's gamepad (GuestPad over PadPort) from a GameController.framework extended
/// gamepad (Xbox, DualSense, DualShock, MFi, ...) and plays its rumble on that controller, or
/// passes a DualSense through as itself (HIDPassthrough): its raw reports both ways, so SteamOS
/// drives touchpad, motion sensors, lights, rumble and triggers itself.
/// Settings > Controller picks which controller (first connected by default), whether SteamOS
/// gets a pad and what kind ("Appears in SteamOS as"; Automatic = the controller's own kind),
/// whether a DualSense is passed through, swaps A/B and X/Y for Nintendo-style layouts and
/// applies a radial stick deadzone, all while the VM runs: the guest's pad comes and goes with
/// the controller and changes kind with it.
final class GamepadBridge {
    private let port: PadPort
    private let settings: LauncherSettings
    /// `--pad` for this run (wins over the setting).
    private let typeOverride: LauncherSettings.PadType?
    private var controller: GCController?
    /// The uinput pad the guest has (created over fx.pad), nil = none.
    private var guestPad: GuestPad?
    /// The DualSense the guest has as itself (a uhid device), nil = none.
    private var guestHID: HIDPassthrough.Device?
    /// What the guest last got (or, without a uinput pad, the controller's last state).
    private var state = PadState()
    /// The guest's fx-pad service said `hello`: it can create a pad.
    private var serviceReady = false
    /// ... and `caps hid`: it can create a uhid device.
    private var hidCapable = false
    /// --input-selftest, control `pad on`: a pad even without a controller.
    private var testPad = false
    private var paused = false
    private let rumble = Rumble()
    private let hid = HIDPassthrough()
    /// Input reports sent to the guest since the passed-through device was created.
    private var hidInputs = 0
    private var observers: [NSObjectProtocol] = []
    private var subscriptions: [AnyCancellable] = []
    /// While the VM is paused (suspended, guest asleep): called before anything is sent, with
    /// whether a button went down; true = keep it from the guest (a press may wake it).
    var intercept: ((_ buttonPressed: Bool) -> Bool)?

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

    struct PadState: Equatable {
        var buttons: [UInt16: Bool] = [:]
        var axes: [UInt16: Int32] = [:]
    }

    static let axisCodes: [UInt16] = GuestPad.axes.map(\.code)

    init(port: PadPort, settings: LauncherSettings, typeOverride: LauncherSettings.PadType?) {
        self.port = port
        self.settings = settings
        self.typeOverride = typeOverride
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

    static func displayName(of c: GCController) -> String {
        let vendor = c.vendorName ?? String(localized: "Controller", comment: "Unnamed game controller")
        return vendor == c.productCategory ? vendor : "\(vendor) (\(c.productCategory))"
    }

    static func logDisplayName(of c: GCController) -> String {
        let vendor = c.vendorName ?? "Controller"
        return vendor == c.productCategory ? vendor : "\(vendor) (\(c.productCategory))"
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
            self?.selectController()
        })
        observers.append(nc.addObserver(forName: .GCControllerDidDisconnect, object: nil, queue: .main) { [weak self] n in
            if let c = n.object as? GCController { log("gamepad disconnected: \(c.vendorName ?? "?")") }
            self?.selectController()
        })
        observers.append(nc.addObserver(forName: .GCControllerDidBecomeCurrent, object: nil, queue: .main) { [weak self] _ in
            self?.selectController()
        })
        // @Published emits before the property changes: re-read on the next main-queue turn.
        subscriptions.append(settings.$controllerID.dropFirst().receive(on: DispatchQueue.main).sink { [weak self] _ in
            self?.selectController()
        })
        for p in [settings.$virtualPad.map { _ in () }.eraseToAnyPublisher(), settings.$padType.map { _ in () }.eraseToAnyPublisher(),
                  settings.$dualSensePassthrough.map { _ in () }.eraseToAnyPublisher()] {
            subscriptions.append(p.dropFirst().receive(on: DispatchQueue.main).sink { [weak self] in self?.reconcile() })
        }
        subscriptions.append(settings.$swapABXY.dropFirst().receive(on: DispatchQueue.main).sink { [weak self] _ in self?.refresh() })
        subscriptions.append(settings.$stickDeadzone.dropFirst().receive(on: DispatchQueue.main).sink { [weak self] _ in self?.refresh() })
        port.start { [weak self] line in self?.guestLine(line) }
        hid.onChange = { [weak self] in self?.reconcile() }
        hid.onInput = { [weak self] report in self?.hidInput(report) }
        hid.start()
        GCController.startWirelessControllerDiscovery(completionHandler: nil)
        selectController()
    }

    /// The VM was paused (suspend, guest sleep) / runs again: no rumble or reports while nothing
    /// runs (a passed-through DualSense's next report carries its whole state again).
    func vmPaused(_ paused: Bool) {
        self.paused = paused
        rumble.paused = paused
    }

    private func hidInput(_ report: UnsafeBufferPointer<UInt8>) {
        guard guestHID != nil, !paused else { return }
        if port.sendLatest("hid-input " + HIDPassthrough.hex(report)) {
            hidInputs += 1
            if hidInputs == 1 { log("gamepad: first input report to SteamOS: id 0x\(String(report[0], radix: 16)), \(report.count) bytes") }
        }
    }

    private func guestLine(_ line: String) {
        let w = line.split(separator: " ")
        if w == ["hello"] {
            // A (re)started service has no pad: create it again (`caps hid` follows a new one).
            log("gamepad: the guest's pad service is ready")
            serviceReady = true
            hidCapable = false
            guestPad = nil
            guestHID = nil
            hid.deactivate()
            rumble.set(strong: 0, weak: 0)
            reconcile()
        } else if w == ["caps", "hid"] {
            hidCapable = true
            reconcile()
        } else if w.count == 3, w[0] == "rumble", let strong = UInt16(w[1]), let weak = UInt16(w[2]) {
            rumble.set(strong: strong, weak: weak)
        } else if w.count == 3, w[0] == "hid-output", let type = HIDPassthrough.ReportType(rawValue: String(w[1])),
                  let data = HIDPassthrough.unhex(w[2]) {
            if let d = guestHID { hid.setReport(d, type: type, data: data) }
        } else if w.count == 4, w[0] == "hid-get", let id = UInt32(w[1]),
                  let type = HIDPassthrough.ReportType(rawValue: String(w[2])), let rnum = UInt8(w[3]) {
            // The guest's driver waits (up to 5 s) for an answer: always give one.
            guard let d = guestHID else { port.send("hid-get-reply \(id) \(ENODEV)"); return }
            hid.getReport(d, type: type, id: rnum) { [weak self] r in
                switch r {
                case .success(let data): self?.port.send("hid-get-reply \(id) 0 \(HIDPassthrough.hex(data))")
                case .failure(let e):
                    log("gamepad: \(type.rawValue) report \(rnum) for SteamOS: \(HIDPassthrough.describe(e.code))")
                    self?.port.send("hid-get-reply \(id) \(EIO)")
                }
            }
        } else if w.count == 4, w[0] == "hid-set", let id = UInt32(w[1]),
                  let type = HIDPassthrough.ReportType(rawValue: String(w[2])), let data = HIDPassthrough.unhex(w[3]) {
            guard let d = guestHID else { port.send("hid-set-reply \(id) \(ENODEV)"); return }
            hid.setReport(d, type: type, data: data) { [weak self] r in
                self?.port.send("hid-set-reply \(id) \(r == kIOReturnSuccess ? 0 : EIO)")
            }
        } else {
            log("gamepad: unknown line \"\(line)\" on \(PadPort.name)")
        }
    }

    private func selectController() {
        let candidates = GamepadBridge.connected
        let next: GCController?
        if !settings.controllerID.isEmpty,
           let chosen = candidates.first(where: { GamepadBridge.identifier(of: $0) == settings.controllerID }) {
            next = chosen
        } else {
            // First connected (the chosen one is not connected: fall back to it as well).
            next = candidates.first
        }
        if next === controller { return }
        controller?.extendedGamepad?.valueChangedHandler = nil
        controller = next
        rumble.attach(next)
        if let c = next, let pad = c.extendedGamepad {
            log("gamepad active: \(GamepadBridge.logDisplayName(of: c))")
            // Keep the Home/PS button for the guest (Steam button) instead of macOS.
            pad.buttonHome?.preferredSystemGestureState = .disabled
            pad.buttonOptions?.preferredSystemGestureState = .disabled
            pad.buttonMenu.preferredSystemGestureState = .disabled
            pad.valueChangedHandler = { [weak self] pad, _ in self?.update(from: pad) }
        } else {
            log("gamepad: none connected")
        }
        let before = guestPad
        reconcile()
        if let pad = guestPad, pad == before {
            // Same pad, another controller: release what the previous one held.
            apply(GamepadBridge.rest(pad))
            refresh()
        }
    }

    /// What the guest should have: nothing without a controller or with "Virtual controller"
    /// off; the DualSense itself while it drives a DualSense pad and "Pass the DualSense through"
    /// is on (and the guest's service takes uhid devices); else a uinput pad of the kind from
    /// "Appears in SteamOS as" (`--pad`), Automatic = the controller's.
    private func wanted() -> (device: GuestDevice, why: String)? {
        guard settings.virtualPad, controller != nil || testPad else { return nil }
        let pad: GuestPad, why: String
        switch typeOverride ?? settings.padType {
        case .xbox360: (pad, why) = (.xbox360, typeOverride == nil ? "setting" : "--pad")
        case .dualSense: (pad, why) = (.dualSense, typeOverride == nil ? "setting" : "--pad")
        case .dualShock4: (pad, why) = (.dualShock4, typeOverride == nil ? "setting" : "--pad")
        case .auto:
            guard let c = controller else { return (.pad(.xbox360), "automatic, no controller") }
            (pad, why) = (GuestPad.matching(c), "automatic, like \(GamepadBridge.logDisplayName(of: c))")
        }
        // GameController does not say which HID device a controller is: with several DualSenses
        // connected, the first one found is passed through.
        if pad == .dualSense, settings.dualSensePassthrough, hidCapable,
           controller?.extendedGamepad is GCDualSenseGamepad, let d = hid.devices.first {
            return (.hid(d), why)
        }
        return (.pad(pad), why)
    }

    private var current: GuestDevice? {
        guestHID.map { .hid($0) } ?? guestPad.map { .pad($0) }
    }

    /// Create, replace or remove the guest's pad to match `wanted()`.
    private func reconcile() {
        guard serviceReady else { return }
        let want = wanted()
        guard want?.device != current else { return }
        if let old = current {
            port.send("remove")
            log("gamepad: removed the \(old.title) from SteamOS")
        }
        guestPad = nil
        guestHID = nil
        hid.deactivate()
        rumble.set(strong: 0, weak: 0)
        guard let want else { return }
        switch want.device {
        case .pad(let pad):
            guard port.send(pad.createLine) else {
                log("gamepad: cannot write to \(PadPort.name)")
                return
            }
            guestPad = pad
            log("gamepad: SteamOS sees a \(pad.logTitle) (\(want.why))")
            // The new device is at rest; send the controller's current state.
            state = GamepadBridge.rest(pad)
            refresh()
        case .hid(let d):
            guard port.send(d.identity.createLine) else {
                log("gamepad: cannot write to \(PadPort.name)")
                return
            }
            guestHID = d
            hidInputs = 0
            hid.activate(d)
            log("gamepad: SteamOS sees the \(d.identity.name) itself, passed through (\(want.why))")
        }
    }

    /// Swap / deadzone changed, new pad: resend the current state with the current mapping.
    private func refresh() {
        if let pad = controller?.extendedGamepad { update(from: pad) }
    }

    private func update(from pad: GCExtendedGamepad) {
        apply(GamepadBridge.read(pad, as: guestPad ?? .xbox360, swapABXY: settings.swapABXY,
                                 deadzone: Float(settings.stickDeadzone) / 100))
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

    private func apply(_ next: PadState) {
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
        state = next
        if !events.isEmpty { _ = port.send("ev " + events.joined(separator: " ")) }
    }

    /// --input-selftest: a pad even without a controller, press/release A and push the left stick
    /// right, then return to rest.
    func injectTestSequence() {
        testPad = true
        reconcile()
        guard guestPad != nil else {
            log("input selftest: no guest pad (the guest's \(PadPort.name) service has not said hello)")
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

    /// --control-fifo `pad on|off|test|state` (DebugControl).
    func control(_ args: [String]) {
        switch args.first {
        case "on", "off":
            testPad = args.first == "on"
            reconcile()
        case "test":
            injectTestSequence()
        case "state":
            log("control: pad \(current?.title ?? "none"), service \(serviceReady ? "ready" : "not ready")\(hidCapable ? " (hid)" : ""), "
                + "controller \(controller.map(GamepadBridge.logDisplayName(of:)) ?? "none"), rumble \(rumble.level.strong) \(rumble.level.weak), "
                + "HID DualSenses \(hid.devices.count), hid inputs \(hidInputs)")
        default:
            log("control: pad on|off|test|state")
        }
    }
}
