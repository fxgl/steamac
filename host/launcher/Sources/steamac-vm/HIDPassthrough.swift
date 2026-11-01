import Foundation
import IOKit.hid

/// The Mac's DualSense controllers as raw HID devices (IOHIDManager), for passing one through to
/// the guest as a uhid device (GamepadBridge, `hid-create` on fx.pad): the guest's hid-playstation
/// driver and Steam's own DualSense support then get the controller's real reports — touchpad,
/// motion sensors, mute button — and drive its lightbar, player and mute LEDs, rumble and
/// adaptive triggers with their own output reports.
///
/// GameController keeps the device too (it still picks the controller and wakes a sleeping
/// guest): both read the same input reports; the IOHIDManager is opened without seizing it.
/// Reports keep the HID convention on both sides: a numbered report starts with its ID.
/// Callbacks run on the main run loop; Get/SetReport block, so they run on a serial queue and
/// complete on the main queue.
final class HIDPassthrough {
    /// DualSense, DualSense Edge (the products hid-playstation binds to as a DualSense).
    static let dualSenses: [(vendor: Int, product: Int)] = [(0x054c, 0x0ce6), (0x054c, 0x0df2)]
    /// Steam Controller (2026) connected to the Mac directly (Bluetooth LE). Not its Puck
    /// dongle (28de:1304): SDL and Steam take the dongle's controllers only on USB interfaces
    /// 2-5, which a uhid device does not have; the controller itself they take by its IDs.
    static let steamControllers: [(vendor: Int, product: Int)] = [(0x28de, 0x1303)]
    /// The Steam Controller Puck: interfaces 2-5 are its controller slots, each with the
    /// controller's own descriptor and reports. A slot goes to SteamOS as a wired Steam
    /// Controller (28de:1302), which SDL and Steam take without a USB interface number, and only
    /// while a controller sends on it (an idle slot would be a phantom pad).
    static let puck = (vendor: 0x28de, product: 0x1304)
    static let puckSlots = 2...5
    static let wiredSteamController: UInt16 = 0x1302
    /// The controller-state report IDs: USB/dongle (0x42), BLE (0x45) and the newer "Ibex" with
    /// a trackpad timestamp (0x47). Only these keep a Puck slot alive: battery (0x43), wireless
    /// status (0x46/0x79) and lizard-mode keyboard/mouse reports do not
    /// (SDL_hidapi_steam_triton.c).
    static let stateReports: Set<UInt8> = [0x42, 0x45, 0x47]
    /// A slot without controller state for this long has no controller.
    static let puckSlotTimeout: TimeInterval = 2

    /// What the guest's uhid device is created with (`hid-create`).
    struct Identity: Equatable {
        /// Linux BUS_USB / BUS_BLUETOOTH: hid-playstation's report layouts depend on it.
        let bus: UInt16
        let vendor: UInt16
        let product: UInt16
        let version: UInt16
        let country: UInt32
        let descriptor: [UInt8]
        let name: String

        var createLine: String {
            String(format: "hid-create %04x %04x %04x %04x %x ", bus, vendor, product, version, country)
                + HIDPassthrough.hex(descriptor) + " " + name
        }
    }

    final class Device {
        let ref: IOHIDDevice
        let identity: Identity
        let maxInput: Int
        let maxFeature: Int
        /// Where IOKit copies the device's input reports, for as long as the device lives.
        /// IOHIDLib's device plugin keeps the buffer of the last input report callback
        /// registered and copies every report into it while the device is open, also after the
        /// callback is unregistered (a nil callback only drops it from IOHIDDevice's callback
        /// set): a buffer freed on deactivation took the next reports of a still connected
        /// controller (STEAMAC-35: a USB DualSense's 64-byte reports overwrote a freed 64-byte
        /// block that libobjc had reused for a GameController class's method cache, abort
        /// "Method cache corrupted").
        fileprivate let inputBuffer: UnsafeMutablePointer<UInt8>
        /// The Puck's USB interface (a controller slot), nil for a controller itself.
        let puckSlot: Int?
        /// When the slot last carried controller state (Puck slots only, monotonic clock).
        fileprivate var lastState: TimeInterval?
        fileprivate weak var owner: HIDPassthrough?

        var live: Bool {
            guard puckSlot != nil else { return true }
            guard let t = lastState else { return false }
            return ProcessInfo.processInfo.systemUptime - t < HIDPassthrough.puckSlotTimeout
        }

        init(ref: IOHIDDevice, identity: Identity, maxInput: Int, maxFeature: Int, puckSlot: Int? = nil) {
            self.ref = ref
            self.identity = identity
            self.maxInput = maxInput
            self.maxFeature = maxFeature
            self.puckSlot = puckSlot
            inputBuffer = .allocate(capacity: maxInput)
        }

        /// Only on the main thread (HIDPassthrough keeps devices there): its reports are
        /// delivered on the main run loop, which this unschedules before the buffer goes.
        deinit {
            IOHIDDeviceUnscheduleFromRunLoop(ref, CFRunLoopGetMain(), CFRunLoopMode.defaultMode.rawValue)
            inputBuffer.deallocate()
        }
    }

    private var manager: IOHIDManager?
    /// Whether to match Valve's Steam Controllers (the BLE controller and its Puck): their
    /// descriptors have keyboard/mouse collections, so matching them triggers the Input
    /// Monitoring prompt. Only Auto / Steam Controller pass them through.
    var matchSteamControllers = false {
        didSet {
            guard matchSteamControllers != oldValue, let m = manager else { return }
            // Matching only: keep the open manager so a DualSense already passed through is not
            // dropped (a full recreate is for an Input Monitoring grant).
            IOHIDManagerSetDeviceMatchingMultiple(m, matching as CFArray)
            if !matchSteamControllers {
                // Narrowing matching may not remove already-matched Valve devices; drop them
                // ourselves. DualSenses stay open.
                let before = devices.count
                if let a = active, HIDPassthrough.isSteamController(a) { deactivate() }
                devices.removeAll { HIDPassthrough.isSteamController($0) }
                if !devices.contains(where: { $0.puckSlot != nil }) { stopPuckTimer() }
                if devices.count != before { onChange?() }
            }
        }
    }
    /// Connected supported devices in connection order.
    private(set) var devices: [Device] = []

    /// Devices to match: DualSenses always, Steam Controllers only in Auto / Steam Controller.
    private var matching: [CFDictionary] {
        let valve = matchSteamControllers ? HIDPassthrough.steamControllers + [HIDPassthrough.puck] : []
        return (HIDPassthrough.dualSenses + valve).map {
            [kIOHIDVendorIDKey: $0.vendor, kIOHIDProductIDKey: $0.product] as CFDictionary
        }
    }
    /// The device whose input reports go to `onInput`.
    private(set) var active: Device?
    /// Devices came or went.
    var onChange: (() -> Void)?
    /// An input report of the active device (main thread).
    var onInput: ((UnsafeBufferPointer<UInt8>) -> Void)?
    private let io = DispatchQueue(label: "es.fxgam.steamac.hid-passthrough")

    /// Start watching for supported devices; false if the IOHIDManager cannot be opened.
    @discardableResult
    func start() -> Bool {
        let m = IOHIDManagerCreate(kCFAllocatorDefault, IOOptionBits(kIOHIDOptionsTypeNone))
        IOHIDManagerSetDeviceMatchingMultiple(m, matching as CFArray)
        let ctx = Unmanaged.passUnretained(self).toOpaque()
        IOHIDManagerRegisterDeviceMatchingCallback(m, { ctx, result, _, device in
            guard let ctx else { return }
            Unmanaged<HIDPassthrough>.fromOpaque(ctx).takeUnretainedValue().added(device, result: result)
        }, ctx)
        IOHIDManagerRegisterDeviceRemovalCallback(m, { ctx, _, _, device in
            guard let ctx else { return }
            Unmanaged<HIDPassthrough>.fromOpaque(ctx).takeUnretainedValue().removed(device)
        }, ctx)
        IOHIDManagerScheduleWithRunLoop(m, CFRunLoopGetMain(), CFRunLoopMode.defaultMode.rawValue)
        let r = IOHIDManagerOpen(m, IOOptionBits(kIOHIDOptionsTypeNone))
        manager = m
        guard r == kIOReturnSuccess else {
            log("hid passthrough: cannot open the HID manager: \(HIDPassthrough.describe(r))")
            if r == kIOReturnNotPermitted { awaitPermission() }
            return false
        }
        return true
    }

    /// A grant is being waited for (the poll timer is running).
    private var waitingForPermission = false
    /// After Input Monitoring was granted we already recreated the manager once: further
    /// `kIOReturnNotPermitted` sometimes only clears on a relaunch (do not keep recreating a
    /// passed-through DualSense every 3 s).
    private var recreatedAfterGrant = false
    private var loggedRelaunchNeeded = false

    /// A Steam Controller's descriptor has keyboard and mouse collections, so macOS opens it only
    /// with Input Monitoring: ask for it, then recreate the manager once it is granted.
    private func awaitPermission() {
        _ = IOHIDRequestAccess(kIOHIDRequestTypeListenEvent)
        // Already recreated after a grant and devices still fail: only a relaunch helps.
        if recreatedAfterGrant {
            if !loggedRelaunchNeeded {
                loggedRelaunchNeeded = true
                log("hid passthrough: a device is still not permitted after Input Monitoring was granted; restart the launcher")
            }
            return
        }
        // Re-opening the manager cannot pick up a grant: IOHIDManagerOpen on an already-open
        // manager returns success without touching its devices, and the TCC denial is cached per
        // device. Poll TCC and, once granted, recreate the manager so the devices open.
        guard !waitingForPermission else { return }
        waitingForPermission = true
        Timer.scheduledTimer(withTimeInterval: 3, repeats: true) { [weak self] t in
            guard let self else { t.invalidate(); return }
            guard IOHIDCheckAccess(kIOHIDRequestTypeListenEvent) == kIOHIDAccessTypeGranted else { return }
            t.invalidate()
            self.waitingForPermission = false
            self.recreatedAfterGrant = true
            log("hid passthrough: Input Monitoring granted, reopening the HID manager")
            self.restart()
        }
    }

    /// Close the current manager and start a fresh one, so its devices open now after an Input
    /// Monitoring grant. The matching callback re-finds the devices.
    private func restart() {
        deactivate()
        devices.removeAll()
        stopPuckTimer()
        if let m = manager {
            IOHIDManagerClose(m, IOOptionBits(kIOHIDOptionsTypeNone))
            IOHIDManagerUnscheduleFromRunLoop(m, CFRunLoopGetMain(), CFRunLoopMode.defaultMode.rawValue)
        }
        manager = nil
        _ = start()
    }

    private func added(_ ref: IOHIDDevice, result: IOReturn) {
        guard !devices.contains(where: { $0.ref == ref }) else { return }
        // A device that did not open cannot be passed through (its reports are unavailable): a
        // Steam Controller opens only with Input Monitoring. Skip it; a grant recreates the
        // manager and this callback fires again with success.
        guard result == kIOReturnSuccess else {
            log("hid passthrough: a device did not open: \(HIDPassthrough.describe(result))")
            // A device that appeared after start (e.g. a Steam Controller connected later) never
            // reopens on its own: request access and recreate the manager once it is granted.
            if result == kIOReturnNotPermitted { awaitPermission() }
            return
        }
        guard let d = HIDPassthrough.device(ref) else { return }
        devices.append(d)
        if d.puckSlot != nil {
            d.owner = self
            watch(d)
            startPuckTimer()
        }
        log("hid passthrough: found \(d.identity.name) (\(d.identity.bus == HIDPassthrough.busBluetooth ? "Bluetooth" : "USB"), "
            + "\(d.identity.descriptor.count)-byte descriptor, input reports up to \(d.maxInput) bytes)")
        onChange?()
    }

    private func removed(_ ref: IOHIDDevice) {
        guard let i = devices.firstIndex(where: { $0.ref == ref }) else { return }
        let d = devices.remove(at: i)
        if active === d { deactivate() }
        if !devices.contains(where: { $0.puckSlot != nil }) { stopPuckTimer() }
        log("hid passthrough: \(d.identity.name) disconnected")
        onChange?()
    }

    /// A Puck slot's input reports, for as long as it is connected: liveness from controller
    /// state, and its reports to `onInput` while it is the active device.
    private func watch(_ d: Device) {
        let ctx = Unmanaged.passUnretained(d).toOpaque()
        IOHIDDeviceRegisterInputReportCallback(d.ref, d.inputBuffer, d.maxInput, { ctx, result, _, _, _, report, length in
            guard let ctx, result == kIOReturnSuccess, length > 0 else { return }
            let d = Unmanaged<Device>.fromOpaque(ctx).takeUnretainedValue()
            guard let me = d.owner else { return }
            let reportID = report[0]
            if HIDPassthrough.stateReports.contains(reportID) {
                let wasLive = d.live
                d.lastState = ProcessInfo.processInfo.systemUptime
                if !wasLive {
                    log("hid passthrough: Puck slot \(d.puckSlot ?? 0): controller state (report 0x\(String(reportID, radix: 16)), \(length) bytes)")
                    me.onChange?()
                }
            }
            // While active, every report goes to SteamOS (state, battery, wireless status, ...).
            if me.active === d { me.onInput?(UnsafeBufferPointer(start: report, count: length)) }
        }, ctx)
    }

    private var puckTimer: Timer?

    /// Notice slots that went quiet (controller off, moved to another slot or to Bluetooth).
    private func startPuckTimer() {
        guard puckTimer == nil else { return }
        var wasLive: Set<ObjectIdentifier> = []
        puckTimer = Timer.scheduledTimer(withTimeInterval: 0.5, repeats: true) { [weak self] _ in
            guard let self else { return }
            let live = Set(self.devices.filter { $0.puckSlot != nil && $0.live }.map(ObjectIdentifier.init))
            if !wasLive.subtracting(live).isEmpty {
                log("hid passthrough: a Puck slot went quiet")
                self.onChange?()
            }
            wasLive = live
        }
    }

    /// No Puck device left: stop watching for quiet slots.
    private func stopPuckTimer() {
        puckTimer?.invalidate()
        puckTimer = nil
    }

    static let busUSB: UInt16 = 0x03
    static let busBluetooth: UInt16 = 0x05

    /// A Steam Controller (itself, or a Puck slot) — whether or not it can be passed through now.
    static func isSteamController(_ d: Device) -> Bool {
        d.puckSlot != nil || steamControllers.contains { $0.vendor == Int(d.identity.vendor) && $0.product == Int(d.identity.product) }
    }

    /// A Steam Controller to pass through now: connected, and for a Puck slot, sending state.
    static func isLiveSteamController(_ d: Device) -> Bool {
        isSteamController(d) && d.live
    }

    private static func device(_ ref: IOHIDDevice) -> Device? {
        func int(_ key: String) -> Int? { (IOHIDDeviceGetProperty(ref, key as CFString) as? NSNumber)?.intValue }
        func string(_ key: String) -> String? { IOHIDDeviceGetProperty(ref, key as CFString) as? String }
        let transport = string(kIOHIDTransportKey) ?? "?"
        let bus: UInt16
        switch transport {
        case kIOHIDTransportUSBValue: bus = busUSB
        case kIOHIDTransportBluetoothValue, kIOHIDTransportBluetoothLowEnergyValue, "Bluetooth Low Energy": bus = busBluetooth
        default:
            log("hid passthrough: skipping a controller on transport \(transport)")
            return nil
        }
        var puckSlot: Int?
        if int(kIOHIDVendorIDKey) == puck.vendor, int(kIOHIDProductIDKey) == puck.product {
            guard let i = int("bInterfaceNumber"), puckSlots.contains(i) else { return nil }
            puckSlot = i
        }
        guard let vendor = int(kIOHIDVendorIDKey), let product = int(kIOHIDProductIDKey),
              let descriptor = IOHIDDeviceGetProperty(ref, kIOHIDReportDescriptorKey as CFString) as? Data,
              !descriptor.isEmpty, descriptor.count <= 4096 else {
            log("hid passthrough: skipping a controller without a usable report descriptor")
            return nil
        }
        // The names Linux gives the controller (hid-playstation does not depend on them).
        let valve = vendor == 0x28de
        let productName = string(kIOHIDProductKey) ?? (valve ? "Steam Controller" : "DualSense Wireless Controller")
        let manufacturer = string(kIOHIDManufacturerKey) ?? (valve ? "Valve" : "Sony Interactive Entertainment")
        let name = bus == busUSB ? "\(manufacturer) \(productName)" : productName
        let identity = Identity(bus: bus, vendor: UInt16(truncatingIfNeeded: vendor),
                                product: puckSlot != nil ? wiredSteamController : UInt16(truncatingIfNeeded: product),
                                version: UInt16(truncatingIfNeeded: int(kIOHIDVersionNumberKey) ?? 0),
                                country: UInt32(truncatingIfNeeded: int(kIOHIDCountryCodeKey) ?? 0),
                                descriptor: [UInt8](descriptor), name: puckSlot != nil ? "Valve Steam Controller" : name)
        return Device(ref: ref, identity: identity,
                      maxInput: max(64, int(kIOHIDMaxInputReportSizeKey) ?? 0),
                      maxFeature: max(64, int(kIOHIDMaxFeatureReportSizeKey) ?? 0), puckSlot: puckSlot)
    }

    /// Input reports of `d` go to `onInput` from now on (none of any other device).
    func activate(_ d: Device) {
        guard active !== d else { return }
        deactivate()
        active = d
        // A Puck slot's callback stays registered (`watch`) and forwards while it is active.
        guard d.puckSlot == nil else { return }
        let ctx = Unmanaged.passUnretained(self).toOpaque()
        IOHIDDeviceRegisterInputReportCallback(d.ref, d.inputBuffer, d.maxInput, { ctx, result, _, _, _, report, length in
            guard let ctx, result == kIOReturnSuccess, length > 0 else { return }
            let me = Unmanaged<HIDPassthrough>.fromOpaque(ctx).takeUnretainedValue()
            me.onInput?(UnsafeBufferPointer(start: report, count: length))
        }, ctx)
    }

    /// A nil callback unregisters ours (callbacks run on this, the main thread). IOKit keeps
    /// copying the device's reports into its buffer, which lives as long as the Device.
    func deactivate() {
        guard let d = active else { return }
        active = nil
        guard d.puckSlot == nil else { return }
        IOHIDDeviceRegisterInputReportCallback(d.ref, d.inputBuffer, d.maxInput, nil, nil)
    }

    enum ReportType: String {
        case feature, output, input

        var io: IOHIDReportType {
            switch self {
            case .feature: return kIOHIDReportTypeFeature
            case .output: return kIOHIDReportTypeOutput
            case .input: return kIOHIDReportTypeInput
            }
        }
    }

    /// GET_REPORT of report `id`: the report (ID first) or an error, on the main queue.
    func getReport(_ d: Device, type: ReportType, id: UInt8, done: @escaping (Result<[UInt8], IOReturnError>) -> Void) {
        // The IOHIDDevice, not the Device: a Device is released on the main thread only (deinit).
        // Headroom over the descriptor's size: macOS returns a Bluetooth LE Steam Controller's
        // 64-byte feature report 1 as 65 bytes and fails a 64-byte buffer (kIOReturnNoSpace).
        let ref = d.ref, size = (type == .input ? d.maxInput : d.maxFeature) + 64
        io.async {
            var buf = [UInt8](repeating: 0, count: size)
            buf[0] = id
            var len = CFIndex(size)
            let r = buf.withUnsafeMutableBufferPointer {
                IOHIDDeviceGetReport(ref, type.io, CFIndex(id), $0.baseAddress!, &len)
            }
            let result: Result<[UInt8], IOReturnError> =
                r == kIOReturnSuccess ? .success(Array(buf.prefix(len))) : .failure(IOReturnError(code: r))
            DispatchQueue.main.async { done(result) }
        }
    }

    /// SET_REPORT / an output report (ID first, as the guest sends it), done on the main queue.
    func setReport(_ d: Device, type: ReportType, data: [UInt8], done: ((IOReturn) -> Void)? = nil) {
        guard !data.isEmpty else { done?(kIOReturnBadArgument); return }
        let ref = d.ref
        io.async {
            let r = data.withUnsafeBufferPointer {
                IOHIDDeviceSetReport(ref, type.io, CFIndex(data[0]), $0.baseAddress!, data.count)
            }
            if r != kIOReturnSuccess { log("hid passthrough: \(type.rawValue) report \(data[0]): \(HIDPassthrough.describe(r))") }
            if let done { DispatchQueue.main.async { done(r) } }
        }
    }

    struct IOReturnError: Error {
        let code: IOReturn
    }

    static func describe(_ r: IOReturn) -> String {
        if r == kIOReturnNotPermitted {
            return "not permitted (System Settings > Privacy & Security > Input Monitoring)"
        }
        return String(format: "IOReturn 0x%08x", UInt32(bitPattern: r))
    }

    static func hex(_ bytes: UnsafeBufferPointer<UInt8>) -> String {
        let digits = Array("0123456789abcdef".utf8)
        var out = [UInt8](repeating: 0, count: bytes.count * 2)
        for (i, b) in bytes.enumerated() {
            out[2 * i] = digits[Int(b >> 4)]
            out[2 * i + 1] = digits[Int(b & 15)]
        }
        return String(decoding: out, as: UTF8.self)
    }

    static func hex(_ bytes: [UInt8]) -> String {
        bytes.withUnsafeBufferPointer { hex($0) }
    }

    /// Lowercase or uppercase hex to bytes; nil for an odd length or a non-hex digit.
    static func unhex(_ s: Substring) -> [UInt8]? {
        let u = Array(s.utf8)
        guard u.count % 2 == 0 else { return nil }
        func digit(_ c: UInt8) -> UInt8? {
            switch c {
            case 0x30...0x39: return c - 0x30
            case 0x61...0x66: return c - 0x61 + 10
            case 0x41...0x46: return c - 0x41 + 10
            default: return nil
            }
        }
        var out = [UInt8]()
        out.reserveCapacity(u.count / 2)
        var i = 0
        while i < u.count {
            guard let hi = digit(u[i]), let lo = digit(u[i + 1]) else { return nil }
            out.append(hi << 4 | lo)
            i += 2
        }
        return out
    }
}
