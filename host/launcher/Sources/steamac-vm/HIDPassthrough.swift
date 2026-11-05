import Foundation
import IOKit.hid
import GameController

/// Raw HID controllers passed through to the guest as uhid devices (GamepadBridge, `hid-create`
/// on fx.pad): DualSense, Steam Controller, and generic joysticks/gamepads not supported by
/// GameController. The guest gets their own descriptors and reports, including output reports.
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
        /// Stable across IOHIDManager re-matching, unlike the newly created IOHIDDevice refs.
        let registryID: UInt64
        let identity: Identity
        let maxInput: Int
        /// Generic Desktop controller not supported by GameController (not a DualSense/Valve).
        let generic: Bool
        let maxFeature: Int
        /// Report IDs apply device-wide, including requests for undeclared report types.
        let numbered: Bool
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
        /// Where this device's input reports go while it is passed through (nil = not passed
        /// through). Set by `activate` / `deactivate`.
        fileprivate var onInput: ((UnsafeBufferPointer<UInt8>) -> Void)?
        /// Which PadSlot last activated this device: `deactivate` from another slot must not
        /// clear a handler the new owner just set (device moving to a lower player).
        fileprivate var inputOwner: ObjectIdentifier?
        /// Diagnostic snapshot uses IOKit's existing callback buffer; no report copy or
        /// per-input allocation. Only read on the main thread, like the callback itself.
        fileprivate var lastInputLength = 0
        fileprivate var lastInputTime: TimeInterval = 0

        var live: Bool {
            guard puckSlot != nil else { return true }
            guard let t = lastState else { return false }
            return ProcessInfo.processInfo.systemUptime - t < HIDPassthrough.puckSlotTimeout
        }

        init(ref: IOHIDDevice, registryID: UInt64, identity: Identity, maxInput: Int, maxFeature: Int, puckSlot: Int? = nil, generic: Bool = false) {
            self.ref = ref
            self.registryID = registryID
            self.identity = identity
            self.maxInput = maxInput
            self.maxFeature = maxFeature
            self.puckSlot = puckSlot
            self.generic = generic
            let elements = IOHIDDeviceCopyMatchingElements(ref, nil, IOOptionBits(kIOHIDOptionsTypeNone)) as? [IOHIDElement] ?? []
            numbered = elements.contains { IOHIDElementGetReportID($0) != 0 }
            inputBuffer = .allocate(capacity: maxInput)
        }

        /// Only on the main thread (HIDPassthrough keeps devices there): its reports are
        /// delivered on the main run loop, which this unschedules before the buffer goes.
        deinit {
            IOHIDDeviceUnscheduleFromRunLoop(ref, CFRunLoopGetMain(), CFRunLoopMode.defaultMode.rawValue)
            IOHIDDeviceClose(ref, IOOptionBits(kIOHIDOptionsTypeNone))
            inputBuffer.deallocate()
        }
    }

    private var manager: IOHIDManager?
    /// Whether to match Valve's Steam Controllers (the BLE controller and its Puck): their
    /// descriptors have keyboard/mouse collections, so matching them triggers the Input
    /// Monitoring prompt. Only Auto / Steam Controller pass them through.
    var matchSteamControllers = false {
        didSet { if matchSteamControllers != oldValue { rematch() } }
    }
    /// Generic controllers use Automatic and the existing Virtual controller off switch.
    var matchGenericControllers = false {
        didSet { if matchGenericControllers != oldValue { rematch() } }
    }

    private func rematch() {
        if !matchSteamControllers && !matchGenericControllers {
            needsInputMonitoring = false
            permissionTimer?.invalidate()
            permissionTimer = nil
            waitingForPermission = false
        }
        guard let m = manager else { return }
        IOHIDManagerSetDeviceMatchingMultiple(m, matching as CFArray)
        let excluded = devices.filter {
            $0.generic ? !matchGenericControllers : (HIDPassthrough.isSteamController($0) && !matchSteamControllers)
        }
        for d in excluded {
            d.onInput = nil
            d.inputOwner = nil
        }
        devices.removeAll { d in excluded.contains { $0 === d } }
        if !devices.contains(where: { $0.puckSlot != nil }) { stopPuckTimer() }
        if !excluded.isEmpty { onChange?() }
    }
    /// Connected supported devices in connection order.
    private(set) var devices: [Device] = []

    /// Usage matching discovers controllers, but does not open them: the independent-devices
    /// manager lets `added` exclude GameController devices before opening any HID reports.
    private var matching: [CFDictionary] {
        let valve = matchSteamControllers ? HIDPassthrough.steamControllers + [HIDPassthrough.puck] : []
        let known = (HIDPassthrough.dualSenses + valve).map {
            [kIOHIDVendorIDKey: $0.vendor, kIOHIDProductIDKey: $0.product] as CFDictionary
        }
        return known + (matchGenericControllers ? GenericHIDRouting.usages.map {
            [kIOHIDDeviceUsagePageKey: 1, kIOHIDDeviceUsageKey: $0] as CFDictionary
        } : [])
    }
    /// supportsHIDDevice is expensive; a registry entry's support does not change on re-match.
    private var gameControllerSupport: [UInt64: Bool] = [:]
    /// Devices came or went.
    var onChange: (() -> Void)?
    /// Settings > Controller shows a warning while Input Monitoring is still required for a
    /// matched Steam Controller / composite HID device.
    private(set) var needsInputMonitoring = false {
        didSet { if needsInputMonitoring != oldValue { onPermissionNeededChange?(needsInputMonitoring) } }
    }
    var onPermissionNeededChange: ((Bool) -> Void)?
    private let io = DispatchQueue(label: "es.fxgam.steamac.hid-passthrough")
    private var failedOpenCount = 0
    private var loggedOpenFailures = false

    /// Start watching for supported devices; false if the IOHIDManager cannot be opened.
    @discardableResult
    func start() -> Bool {
        failedOpenCount = 0
        loggedOpenFailures = false
        let m = IOHIDManagerCreate(kCFAllocatorDefault, IOHIDManagerOptions.independentDevices.rawValue)
        IOHIDManagerSetDeviceMatchingMultiple(m, matching as CFArray)
        let ctx = Unmanaged.passUnretained(self).toOpaque()
        IOHIDManagerRegisterDeviceMatchingCallback(m, { ctx, result, _, device in
            guard let ctx else { return }
            Unmanaged<HIDPassthrough>.fromOpaque(ctx).takeUnretainedValue().added(device, result: result)
        }, ctx)
        IOHIDManagerScheduleWithRunLoop(m, CFRunLoopGetMain(), CFRunLoopMode.defaultMode.rawValue)
        let r = IOHIDManagerOpen(m, IOOptionBits(kIOHIDOptionsTypeNone))
        guard r == kIOReturnSuccess else {
            log("hid passthrough: cannot open the HID manager: \(HIDPassthrough.describe(r))")
            return false
        }
        manager = m
        needsInputMonitoring = false
        return true
    }

    /// A grant is being waited for (the poll timer is running).
    private var waitingForPermission = false
    private var permissionTimer: Timer?
    /// After Input Monitoring was granted we already recreated the manager once: further
    /// `kIOReturnNotPermitted` sometimes only clears on a relaunch (do not keep recreating a
    /// passed-through DualSense every 3 s).
    private var recreatedAfterGrant = false
    private var loggedRelaunchNeeded = false

    /// Settings > Controller "Enable Input Monitoring…": request access again and keep polling.
    func requestInputMonitoring() {
        awaitPermission()
    }

    /// Steam Controllers and generic composite controllers can have keyboard/mouse collections:
    /// ask for Input Monitoring, then recreate the manager once it is granted.
    private func awaitPermission() {
        needsInputMonitoring = true
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
        permissionTimer = Timer.scheduledTimer(withTimeInterval: 3, repeats: true) { [weak self] t in
            guard let self else { t.invalidate(); return }
            guard IOHIDCheckAccess(kIOHIDRequestTypeListenEvent) == kIOHIDAccessTypeGranted else { return }
            t.invalidate()
            self.waitingForPermission = false
            self.permissionTimer = nil
            self.recreatedAfterGrant = true
            log("hid passthrough: Input Monitoring granted, reopening the HID manager")
            self.restart()
        }
    }

    /// Close the current manager and start a fresh one, so its devices open now after an Input
    /// Monitoring grant. The matching callback re-finds the devices.
    private func restart() {
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
        guard let id = HIDPassthrough.registryID(ref),
              (matchSteamControllers || !HIDPassthrough.isValve(ref)),
              !devices.contains(where: { $0.registryID == id }) else { return }
        if let vendor = (IOHIDDeviceGetProperty(ref, kIOHIDVendorIDKey as CFString) as? NSNumber)?.intValue,
           let product = (IOHIDDeviceGetProperty(ref, kIOHIDProductIDKey as CFString) as? NSNumber)?.intValue,
           vendor == HIDPassthrough.puck.vendor, product == HIDPassthrough.puck.product {
            guard let interface = (IOHIDDeviceGetProperty(ref, "bInterfaceNumber" as CFString) as? NSNumber)?.intValue,
                  HIDPassthrough.puckSlots.contains(interface) else { return }
        }
        let generic = !HIDPassthrough.isKnownController(ref)
        if generic {
            guard matchGenericControllers else { return }
            let supported: Bool
            if let cached = gameControllerSupport[id] { supported = cached }
            else {
                supported = GCController.supportsHIDDevice(ref)
                gameControllerSupport[id] = supported
            }
            guard GenericHIDRouting.usages.contains(where: {
                IOHIDDeviceConformsTo(ref, 1, UInt32($0)) && GenericHIDRouting.accepts(
                    usagePage: 1, usage: $0, knownController: false, gameControllerSupported: supported)
            }) else { return }
        }
        // Opening only accepted devices avoids requesting Input Monitoring for unrelated HID
        // devices. Ordinary gamepad/joystick collections do not require it; composite controllers
        // with keyboard/mouse collections can require it, just like a Steam Controller.
        let result = result == kIOReturnSuccess ? IOHIDDeviceOpen(ref, IOOptionBits(kIOHIDOptionsTypeNone)) : result
        // A device that did not open cannot be passed through (its reports are unavailable): a
        // Steam Controller opens only with Input Monitoring. Skip it; a grant recreates the
        // manager and this callback fires again with success.
        guard result == kIOReturnSuccess else {
            failedOpenCount += 1
            if failedOpenCount == 1 {
                // Matching callbacks arrive together; summarize all denied Puck interfaces once
                // per manager start, rather than logging each interface separately.
                DispatchQueue.main.async { [weak self] in
                    guard let self, !self.loggedOpenFailures else { return }
                    self.loggedOpenFailures = true
                    log("hid passthrough: \(self.failedOpenCount) devices did not open: \(HIDPassthrough.describe(result))")
                }
            }
            // A device that appeared after start (e.g. a Steam Controller connected later) never
            // reopens on its own: request access and recreate the manager once it is granted.
            if result == kIOReturnNotPermitted { awaitPermission() }
            return
        }
        guard let d = HIDPassthrough.device(ref, registryID: id, generic: generic) else {
            IOHIDDeviceClose(ref, IOOptionBits(kIOHIDOptionsTypeNone))
            return
        }
        devices.append(d)
        d.owner = self
        watch(d)
        if d.puckSlot != nil { startPuckTimer() }
        log("hid passthrough: found \(d.identity.name) (\(d.identity.bus == HIDPassthrough.busBluetooth ? "Bluetooth" : "USB"), "
            + "\(d.identity.descriptor.count)-byte descriptor, input reports up to \(d.maxInput) bytes)")
        onChange?()
    }

    private func removed(_ ref: IOHIDDevice) {
        // The device-level callback gives us the retained ref, even after a manager re-match.
        // Do not query the terminated service's registry ID: keeping a dead Device here would
        // route every reconnect to that controller (STEAMAC-84).
        guard let i = devices.firstIndex(where: { $0.ref == ref }) else { return }
        let d = devices.remove(at: i)
        gameControllerSupport.removeValue(forKey: d.registryID)
        if !devices.contains(where: { $0.puckSlot != nil }) { stopPuckTimer() }
        log("hid passthrough: \(d.identity.name) disconnected")
        onChange?()
    }

    /// A device's input reports for as long as it is connected: Puck-slot liveness from
    /// controller-state reports, and delivery to `onInput` while some PadSlot has activated it.
    /// Registered for every matched device (DualSenses included); with passthrough off the
    /// handler is nil and the callback only updates Puck liveness when relevant.
    private func watch(_ d: Device) {
        let ctx = Unmanaged.passUnretained(d).toOpaque()
        // The manager's removal lookup also queries IORegistry. Watch the retained device
        // itself instead, so neither re-matching nor an unavailable service loses its removal.
        IOHIDDeviceRegisterRemovalCallback(d.ref, { ctx, _, _ in
            guard let ctx else { return }
            let d = Unmanaged<Device>.fromOpaque(ctx).takeUnretainedValue()
            d.owner?.removed(d.ref)
        }, ctx)
        IOHIDDeviceScheduleWithRunLoop(d.ref, CFRunLoopGetMain(), CFRunLoopMode.defaultMode.rawValue)
        IOHIDDeviceRegisterInputReportCallback(d.ref, d.inputBuffer, d.maxInput, { ctx, result, _, _, _, report, length in
            guard let ctx, result == kIOReturnSuccess, length > 0 else { return }
            let d = Unmanaged<Device>.fromOpaque(ctx).takeUnretainedValue()
            guard let me = d.owner else { return }
            d.lastInputLength = length
            d.lastInputTime = ProcessInfo.processInfo.systemUptime
            let reportID = report[0]
            if d.puckSlot != nil, HIDPassthrough.stateReports.contains(reportID) {
                let wasLive = d.live
                d.lastState = ProcessInfo.processInfo.systemUptime
                if !wasLive {
                    log("hid passthrough: Puck slot \(d.puckSlot ?? 0): controller state (report 0x\(String(reportID, radix: 16)), \(length) bytes)")
                    me.onChange?()
                }
            }
            // While passed through, every report goes to SteamOS (state, battery, wireless, ...).
            d.onInput?(UnsafeBufferPointer(start: report, count: length))
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
    /// On-demand inventory for `pad state` and problem reports (STEAMAC-8V). An
    /// independent manager enumerates *all* usages without opening any HID device,
    /// scheduling callbacks, seizing it or asking for Input Monitoring. In particular,
    /// show devices the routing manager never matched, rather than only accepted pads.
    func diagnosticLines() -> [String] {
        var lines = ["HID routing: generic=\(matchGenericControllers), Valve=\(matchSteamControllers)"]
        for d in devices {
            let route = d.onInput == nil ? "not forwarding" : "forwarding"
            var line = String(format: "HID %04x:%04x", d.identity.vendor, d.identity.product)
                + " \(d.identity.name), registry=\(d.registryID), \(route)"
            if d.lastInputLength > 0 {
                let report = UnsafeBufferPointer(start: d.inputBuffer, count: min(d.lastInputLength, d.maxInput))
                line += String(format: ", input=%d bytes age=%.3fs", report.count,
                               ProcessInfo.processInfo.systemUptime - d.lastInputTime)
                if Self.dualSenses.contains(where: { $0.vendor == Int(d.identity.vendor) && $0.product == Int(d.identity.product) }),
                   let decoded = Self.dualSenseDiagnostic(report, bus: d.identity.bus) {
                    line += ", " + decoded
                }
            } else { line += ", no input reports" }
            lines.append(line)
        }
        let census = IOHIDManagerCreate(kCFAllocatorDefault, IOHIDManagerOptions.independentDevices.rawValue)
        IOHIDManagerSetDeviceMatching(census, nil)
        let result = IOHIDManagerOpen(census, IOOptionBits(kIOHIDOptionsTypeNone))
        defer { IOHIDManagerClose(census, IOOptionBits(kIOHIDOptionsTypeNone)) }
        guard result == kIOReturnSuccess else {
            lines.append("HID inventory unavailable: \(Self.describe(result))")
            return lines
        }
        let refs = IOHIDManagerCopyDevices(census) as? Set<IOHIDDevice> ?? []
        if refs.isEmpty { lines.append("HID inventory: no HID devices") }
        for ref in refs.sorted(by: { (Self.registryID($0) ?? 0) < (Self.registryID($1) ?? 0) }) {
            func int(_ key: String) -> Int { (IOHIDDeviceGetProperty(ref, key as CFString) as? NSNumber)?.intValue ?? 0 }
            func string(_ key: String) -> String { (IOHIDDeviceGetProperty(ref, key as CFString) as? String) ?? "?" }
            let id = Self.registryID(ref)
            let controller = GenericHIDRouting.usages.contains { IOHIDDeviceConformsTo(ref, 1, UInt32($0)) }
            let multiAxis = IOHIDDeviceConformsTo(ref, 1, 8)
            let known = Self.isKnownController(ref)
            let route: String
            if devices.contains(where: { $0.registryID == id }) { route = "passed through (see forwarding state above)" }
            else if known { route = "known controller, not opened (see settings/open errors)" }
            else if !controller { route = "excluded usage" }
            else if GCController.supportsHIDDevice(ref) { route = "GameController-supported (not opened as generic HID)" }
            else if !matchGenericControllers { route = "generic routing disabled" }
            else { route = "eligible generic HID, not opened (see matching/open errors)" }
            var line = String(format: "HID inventory: %04x:%04x", int(kIOHIDVendorIDKey), int(kIOHIDProductIDKey))
                + " \(string(kIOHIDProductKey)), transport=\(string(kIOHIDTransportKey)), registry=\(id.map(String.init) ?? "?")"
                + ", primary=\(int(kIOHIDPrimaryUsagePageKey))/\(int(kIOHIDPrimaryUsageKey))"
            if let pairs = IOHIDDeviceGetProperty(ref, kIOHIDDeviceUsagePairsKey as CFString) as? [[String: NSNumber]] {
                line += ", usages=" + pairs.map {
                    "\($0[kIOHIDDeviceUsagePageKey]?.intValue ?? 0)/\($0[kIOHIDDeviceUsageKey]?.intValue ?? 0)"
                }.joined(separator: ",")
            }
            line += ", \(route)"
            // Descriptor bytes describe layout, not input values; do not dump keyboard,
            // mouse or other unrelated HID reports/descriptors, nor any serial numbers.
            if controller || multiAxis || known,
               let descriptor = IOHIDDeviceGetProperty(ref, kIOHIDReportDescriptorKey as CFString) as? Data,
               descriptor.count <= 4096 {
                line += ", descriptor=" + Self.hex([UInt8](descriptor))
            }
            lines.append(line)
        }
        return lines
    }

    /// Diagnostic-only decoding; never changes forwarded bytes or applies a deadzone.
    /// Layout/offsets: Linux hid-playstation.c, dualsense_input_report and
    /// dualsense_parse_report (USB data[1], Bluetooth data[2]). Motion is raw signed
    /// sensor counts, not calibrated evdev units; touch coordinates are valid only
    /// for active contacts. This separates the candidate inputs in STEAMAC-8R.
    static func dualSenseDiagnostic(_ report: UnsafeBufferPointer<UInt8>, bus: UInt16) -> String? {
        let base: Int
        if bus == busUSB, report.count == 64, report[0] == 1 { base = 1 }
        else if bus == busBluetooth, report.count == 78, report[0] == 0x31 { base = 2 }
        else { return nil }
        func signed(_ offset: Int) -> Int16 {
            Int16(bitPattern: UInt16(report[base + offset]) | UInt16(report[base + offset + 1]) << 8)
        }
        func touch(_ index: Int) -> String {
            let offset = base + 32 + index * 4
            guard report[offset] & 0x80 == 0 else { return "inactive" }
            let x = Int(report[offset + 1]) | Int(report[offset + 2] & 0x0f) << 8
            let y = Int(report[offset + 2] >> 4) | Int(report[offset + 3]) << 4
            return "\(x),\(y)"
        }
        return "sticks L=\(report[base]),\(report[base + 1]) R=\(report[base + 2]),\(report[base + 3])"
            + " (center 127/128; passthrough has no launcher deadzone), triggers=\(report[base + 4]),\(report[base + 5])"
            + ", gyro=\(signed(15)),\(signed(17)),\(signed(19)) raw"
            + ", accel=\(signed(21)),\(signed(23)),\(signed(25)) raw"
            + ", touch0=\(touch(0)), touch1=\(touch(1))"
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
    private static func isValve(_ ref: IOHIDDevice) -> Bool {
        let vendor = (IOHIDDeviceGetProperty(ref, kIOHIDVendorIDKey as CFString) as? NSNumber)?.intValue
        let product = (IOHIDDeviceGetProperty(ref, kIOHIDProductIDKey as CFString) as? NSNumber)?.intValue
        return (steamControllers + [puck]).contains { $0.vendor == vendor && $0.product == product }
    }

    private static func isKnownController(_ ref: IOHIDDevice) -> Bool {
        let vendor = (IOHIDDeviceGetProperty(ref, kIOHIDVendorIDKey as CFString) as? NSNumber)?.intValue
        let product = (IOHIDDeviceGetProperty(ref, kIOHIDProductIDKey as CFString) as? NSNumber)?.intValue
        return (dualSenses + steamControllers + [puck]).contains { $0.vendor == vendor && $0.product == product }
    }

    /// Registry identity while matching a live service, for de-duplicating re-matches. Removal
    /// uses the retained device's callback instead: terminated services need not answer queries.
    static func registryID(_ ref: IOHIDDevice) -> UInt64? {
        var id: UInt64 = 0
        guard IORegistryEntryGetRegistryEntryID(IOHIDDeviceGetService(ref), &id) == kIOReturnSuccess else { return nil }
        return id
    }

    private static func device(_ ref: IOHIDDevice, registryID: UInt64, generic: Bool) -> Device? {
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
        let sony = dualSenses.contains { $0.vendor == vendor && $0.product == product }
        let fallback = valve ? "Steam Controller" : (sony ? "DualSense Wireless Controller" : String(format: "HID %04x:%04x", vendor, product))
        let productName = GenericHIDRouting.productName(string(kIOHIDProductKey), fallback: fallback)
        let manufacturer = string(kIOHIDManufacturerKey) ?? (valve ? "Valve" : (sony ? "Sony Interactive Entertainment" : ""))
        let name = bus == busUSB && !manufacturer.isEmpty ? "\(manufacturer) \(productName)" : productName
        let identity = Identity(bus: bus, vendor: UInt16(truncatingIfNeeded: vendor),
                                product: puckSlot != nil ? wiredSteamController : UInt16(truncatingIfNeeded: product),
                                version: UInt16(truncatingIfNeeded: int(kIOHIDVersionNumberKey) ?? 0),
                                country: UInt32(truncatingIfNeeded: int(kIOHIDCountryCodeKey) ?? 0),
                                descriptor: [UInt8](descriptor), name: puckSlot != nil ? "Valve Steam Controller" : name)
        return Device(ref: ref, registryID: registryID, identity: identity,
                      maxInput: max(64, int(kIOHIDMaxInputReportSizeKey) ?? 0),
                      maxFeature: max(64, int(kIOHIDMaxFeatureReportSizeKey) ?? 0), puckSlot: puckSlot, generic: generic)
    }

    /// Input reports of `d` go to `handler` from now on (its input callback is registered once in
    /// `watch` and routes through `Device.onInput`). `owner` is the PadSlot that claimed it.
    func activate(_ d: Device, owner: AnyObject, handler: @escaping (UnsafeBufferPointer<UInt8>) -> Void) {
        d.inputOwner = ObjectIdentifier(owner)
        d.onInput = handler
    }

    /// Stop passing `d` through for `owner` only: a later slot that already claimed the device
    /// (Steam Controller moving to a lower player) keeps its handler.
    func deactivate(_ d: Device, owner: AnyObject) {
        guard d.inputOwner == ObjectIdentifier(owner) else { return }
        d.inputOwner = nil
        d.onInput = nil
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
        // macOS needs headroom for a BLE Steam Controller's feature reports (64 bytes become
        // 65). Do not enlarge other devices' requests: this length reaches the USB transfer,
        // and a DualSense firmware-info request must keep its descriptor-sized buffer.
        let headroom = type == .feature && d.identity.bus == HIDPassthrough.busBluetooth
            && HIDPassthrough.isSteamController(d) ? 64 : 0
        let ref = d.ref, size = (type == .input ? d.maxInput : d.maxFeature) + headroom
        let name = d.identity.name, bus = d.identity.bus, registryID = d.registryID
        io.async {
            var buf = [UInt8](repeating: 0, count: size)
            buf[0] = id
            var len = CFIndex(size)
            let r = buf.withUnsafeMutableBufferPointer {
                IOHIDDeviceGetReport(ref, type.io, CFIndex(id), $0.baseAddress!, &len)
            }
            if r != kIOReturnSuccess {
                log("hid passthrough: GET \(type.rawValue) report \(id) from \(name) (bus \(bus), registry \(registryID)): "
                    + "\(HIDPassthrough.describe(r)) (requested \(size) bytes, result length \(len))")
            }
            let result: Result<[UInt8], IOReturnError> =
                r == kIOReturnSuccess ? .success(Array(buf.prefix(len))) : .failure(IOReturnError(code: r))
            DispatchQueue.main.async { done(result) }
        }
    }

    /// SET_REPORT / output: numbered reports include their ID, unnumbered reports are payload only.
    func setReport(_ d: Device, type: ReportType, data: [UInt8], done: ((IOReturn) -> Void)? = nil) {
        guard !data.isEmpty else { done?(kIOReturnBadArgument); return }
        let ref = d.ref
        let numbered = d.numbered
        let reportID = GenericHIDRouting.reportID(numbered: numbered, firstByte: data[0])
        io.async {
            let r = data.withUnsafeBufferPointer {
                IOHIDDeviceSetReport(ref, type.io, CFIndex(reportID), $0.baseAddress!, data.count)
            }
            if r != kIOReturnSuccess { log("hid passthrough: \(type.rawValue) report \(reportID): \(HIDPassthrough.describe(r))") }
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
        if r == kIOReturnNotOpen {
            return "device not open"
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
