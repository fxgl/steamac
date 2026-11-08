// IOKit boundary for hid-passthrough.py. No real HID devices are opened or used.
// A removed service no longer answers registry queries. A USB DualSense fixture
// requires a descriptor-sized firmware GET_REPORT; BLE Valve needs its extra byte.
// These model the two regressions in STEAMAC-84, not a physical USB reproduction.
typealias IOHIDDevice = TestHIDDevice
typealias IOHIDManager = TestHIDManager
typealias IOHIDElement = TestHIDElement
typealias TestDeviceCallback = (UnsafeMutableRawPointer?, IOReturn, UnsafeMutableRawPointer?, IOHIDDevice) -> Void

private var services: [io_service_t: TestHIDDevice] = [:]
private var nextService: io_service_t = 1
private var permissionRequests = 0
private var diagnosticInventory: [TestHIDDevice] = []
private var loggedLines: [String] = []

final class TestHIDElement: NSObject {
    let reportID: UInt32
    init(reportID: UInt32) { self.reportID = reportID }
}

final class GCController {
    static var published: [GCController] = []
    let vendorName: String?
    let productCategory: String
    init(vendorName: String?, productCategory: String = "Gamepad") {
        self.vendorName = vendorName
        self.productCategory = productCategory
    }
    static func controllers() -> [GCController] { published }
    static func supportsHIDDevice(_ device: IOHIDDevice) -> Bool {
        device.supportQueries += 1
        return device.gameControllerSupported
    }
}

final class TestHIDDevice: NSObject {
    let service: io_service_t
    let id: UInt64
    var live = true
    var isOpen = false
    var scheduled = false
    var openResult = kIOReturnSuccess
    var openCalls = 0
    var closeCalls = 0
    var usagePage: UInt32 = 1
    var usages: Set<UInt32> = [5]
    var gameControllerSupported = false
    var supportQueries = 0
    // The default descriptor declares one numbered input report. No output or
    // feature elements: report numbering still applies to those requests.
    var elements = [TestHIDElement(reportID: 1)]
    weak var manager: TestHIDManager?
    var properties: [String: Any]
    var getRequests: [(IOHIDReportType, Int, Int)] = []
    var setRequests: [(IOHIDReportType, Int, [UInt8])] = []
    var inputCallback: IOHIDReportCallback?
    var inputContext: UnsafeMutableRawPointer?
    var removalCallback: IOHIDCallback?
    var removalContext: UnsafeMutableRawPointer?
    var inputBuffer: UnsafeMutablePointer<UInt8>?
    var inputCapacity = 0

    init(id: UInt64, bluetooth: Bool = false, valve: Bool = false, puckSlot: Int? = nil) {
        self.id = id
        service = nextService
        nextService += 1
        properties = [kIOHIDVendorIDKey: valve ? 0x28de : 0x054c,
                      kIOHIDProductIDKey: valve ? (puckSlot == nil ? 0x1303 : 0x1304) : 0x0ce6,
                      kIOHIDTransportKey: bluetooth ? kIOHIDTransportBluetoothLowEnergyValue : kIOHIDTransportUSBValue,
                      kIOHIDReportDescriptorKey: Data([0x05, 0x01, 0x09, 0x05, 0xa1, 0x01,
                                                       0x85, 0x01, 0x75, 0x08, 0x95, 0x3f, 0x81, 0x02, 0xc0]),
                      kIOHIDMaxInputReportSizeKey: bluetooth && !valve ? 78 : 64,
                      kIOHIDMaxFeatureReportSizeKey: 64]
        if let puckSlot { properties["bInterfaceNumber"] = puckSlot }
        super.init()
        services[service] = self
    }

    func emit(_ report: [UInt8]) {
        guard live && isOpen && scheduled else { return }
        guard let inputBuffer, report.count <= inputCapacity else { return }
        for (i, byte) in report.enumerated() { inputBuffer[i] = byte }
        inputCallback?(inputContext, kIOReturnSuccess, nil, kIOHIDReportTypeInput,
                       UInt32(report[0]), inputBuffer, report.count)
    }

    func emitRemoval() {
        live = false
        if scheduled { removalCallback?(removalContext, kIOReturnSuccess, nil) }
        if let manager, manager.isOpen && manager.scheduled {
            manager.removalCallback?(manager.removalContext, kIOReturnSuccess, nil, self)
        }
    }
}
final class TestHIDManager {
    let independent: Bool
    var isOpen = false
    var scheduled = false
    var matchingCallback: TestDeviceCallback?
    var matchingContext: UnsafeMutableRawPointer?
    var removalCallback: TestDeviceCallback?
    var removalContext: UnsafeMutableRawPointer?
    var devices: [TestHIDDevice] = []

    init(options: IOOptionBits) {
        independent = options & IOHIDManagerOptions.independentDevices.rawValue != 0
    }

    // Legacy managers open and schedule matched devices themselves; independent
    // managers only enumerate. The production callback must do its own I/O setup.
    func emitMatch(_ device: TestHIDDevice) {
        precondition(isOpen && scheduled)
        devices.append(device)
        device.manager = self
        let result: IOReturn
        if independent { result = kIOReturnSuccess }
        else {
            result = IOHIDDeviceOpen(device, IOOptionBits(kIOHIDOptionsTypeNone))
            device.scheduled = scheduled
        }
        matchingCallback?(matchingContext, result, nil, device)
    }
}

func log(_ line: String) { loggedLines.append(line); print(line) }
let IOHIDManagerCreate: (CFAllocator?, IOOptionBits) -> IOHIDManager = { _, options in TestHIDManager(options: options) }
func IOHIDManagerSetDeviceMatchingMultiple(_ manager: IOHIDManager, _ matching: CFArray?) {}
func IOHIDManagerSetDeviceMatching(_ manager: IOHIDManager, _ matching: CFDictionary?) {}
func IOHIDManagerCopyDevices(_ manager: IOHIDManager) -> CFSet? {
    diagnosticInventory.isEmpty ? nil : NSSet(array: diagnosticInventory) as CFSet
}
func IOHIDManagerRegisterDeviceMatchingCallback(_ manager: IOHIDManager, _ callback: TestDeviceCallback?, _ context: UnsafeMutableRawPointer?) {
    manager.matchingCallback = callback
    manager.matchingContext = context
}
func IOHIDManagerRegisterDeviceRemovalCallback(_ manager: IOHIDManager, _ callback: TestDeviceCallback?, _ context: UnsafeMutableRawPointer?) {
    manager.removalCallback = callback
    manager.removalContext = context
}
func IOHIDManagerScheduleWithRunLoop(_ manager: IOHIDManager, _ runLoop: CFRunLoop?, _ mode: CFString?) { manager.scheduled = true }
func IOHIDManagerUnscheduleFromRunLoop(_ manager: IOHIDManager, _ runLoop: CFRunLoop?, _ mode: CFString?) { manager.scheduled = false }
func IOHIDManagerOpen(_ manager: IOHIDManager, _ options: IOOptionBits) -> IOReturn {
    manager.isOpen = true
    return kIOReturnSuccess
}
@discardableResult
func IOHIDManagerClose(_ manager: IOHIDManager, _ options: IOOptionBits) -> IOReturn {
    if !manager.independent {
        for device in manager.devices { IOHIDDeviceClose(device, options) }
    }
    manager.isOpen = false
    return kIOReturnSuccess
}
func IOHIDRequestAccess(_ type: IOHIDRequestType) -> Bool { permissionRequests += 1; return false }
func IOHIDCheckAccess(_ type: IOHIDRequestType) -> IOHIDAccessType { kIOHIDAccessTypeDenied }
func IOHIDDeviceOpen(_ device: IOHIDDevice, _ options: IOOptionBits) -> IOReturn {
    device.openCalls += 1
    guard device.live else { return kIOReturnNoDevice }
    guard device.openResult == kIOReturnSuccess else { return device.openResult }
    device.isOpen = true
    return kIOReturnSuccess
}
@discardableResult
func IOHIDDeviceClose(_ device: IOHIDDevice, _ options: IOOptionBits) -> IOReturn {
    device.closeCalls += 1
    device.isOpen = false
    return kIOReturnSuccess
}
func IOHIDDeviceScheduleWithRunLoop(_ device: IOHIDDevice, _ runLoop: CFRunLoop?, _ mode: CFString?) { device.scheduled = true }
func IOHIDDeviceUnscheduleFromRunLoop(_ device: IOHIDDevice, _ runLoop: CFRunLoop?, _ mode: CFString?) { device.scheduled = false }
func IOHIDDeviceConformsTo(_ device: IOHIDDevice, _ page: UInt32, _ usage: UInt32) -> Bool {
    device.usagePage == page && device.usages.contains(usage)
}
func IOHIDDeviceCopyMatchingElements(_ device: IOHIDDevice, _ matching: CFDictionary?, _ options: IOOptionBits) -> CFArray? {
    device.elements as CFArray
}
func IOHIDElementGetReportID(_ element: IOHIDElement) -> UInt32 { element.reportID }
func IOHIDDeviceGetService(_ device: IOHIDDevice) -> io_service_t { device.service }
func IORegistryEntryGetRegistryEntryID(_ service: io_service_t, _ id: UnsafeMutablePointer<UInt64>) -> IOReturn {
    guard let device = services[service], device.live else { return kIOReturnBadArgument }
    id.pointee = device.id
    return kIOReturnSuccess
}
func IOHIDDeviceGetProperty(_ device: IOHIDDevice, _ key: CFString) -> CFTypeRef? {
    device.properties[key as String] as AnyObject?
}
func IOHIDDeviceRegisterRemovalCallback(_ device: IOHIDDevice, _ callback: IOHIDCallback?, _ context: UnsafeMutableRawPointer?) {
    device.removalCallback = callback
    device.removalContext = context
}
func IOHIDDeviceRegisterInputReportCallback(_ device: IOHIDDevice, _ report: UnsafeMutablePointer<UInt8>, _ size: CFIndex,
                                          _ callback: IOHIDReportCallback?, _ context: UnsafeMutableRawPointer?) {
    device.inputCallback = callback
    device.inputContext = context
    device.inputBuffer = report
    device.inputCapacity = size
}
func IOHIDDeviceGetReport(_ device: IOHIDDevice, _ type: IOHIDReportType, _ id: CFIndex,
                         _ report: UnsafeMutablePointer<UInt8>, _ size: UnsafeMutablePointer<CFIndex>) -> IOReturn {
    device.getRequests.append((type, id, size.pointee))
    guard device.live && device.isOpen else { return kIOReturnNotOpen }
    let valveBLE = (device.properties[kIOHIDVendorIDKey] as? Int) == 0x28de
        && (device.properties[kIOHIDTransportKey] as? String) == kIOHIDTransportBluetoothLowEnergyValue
    if !valveBLE && type == kIOHIDReportTypeFeature && id == 32 && size.pointee != 64 { return kIOReturnTimeout }
    let count = valveBLE && type == kIOHIDReportTypeFeature ? 65 : (id == 9 ? 20 : 64)
    guard size.pointee >= count else { return kIOReturnNoSpace }
    for i in 0..<count { report[i] = i == 0 ? UInt8(id) : UInt8(i) }
    size.pointee = count
    return kIOReturnSuccess
}
func IOHIDDeviceSetReport(_ device: IOHIDDevice, _ type: IOHIDReportType, _ id: CFIndex,
                         _ report: UnsafePointer<UInt8>, _ size: CFIndex) -> IOReturn {
    device.setRequests.append((type, id, Array(UnsafeBufferPointer(start: report, count: size))))
    return device.live && device.isOpen ? kIOReturnSuccess : kIOReturnNotOpen
}

extension HIDPassthrough {
    static func regressionTests() -> Int32 {
        var failures = 0
        var checks = 0
        func check(_ condition: Bool, _ name: String) {
            checks += 1
            print("\(condition ? "PASS" : "FAIL"): \(name)")
            if !condition { failures += 1 }
        }
        func get(_ hid: HIDPassthrough, _ device: Device, _ type: ReportType, _ id: UInt8) -> [UInt8]? {
            var completed = false
            var bytes: [UInt8]?
            hid.getReport(device, type: type, id: id) { result in
                if case .success(let data) = result { bytes = data }
                completed = true
            }
            let deadline = Date(timeIntervalSinceNow: 2)
            while !completed && Date() < deadline { RunLoop.main.run(until: Date(timeIntervalSinceNow: 0.001)) }
            check(completed, "GET_REPORT completes on main queue")
            return bytes
        }

        let hid = HIDPassthrough()
        hid.matchSteamControllers = true
        precondition(hid.start())
        let usb = TestHIDDevice(id: 10)
        hid.manager!.emitMatch(usb)
        let first = hid.devices[0]
        let firmware = get(hid, first, .feature, 32)
        check(firmware?.count == 64 && firmware?.first == 32, "USB DualSense firmware read succeeds without global headroom")
        check(usb.getRequests.last?.2 == 64, "USB GET_REPORT retains descriptor-sized request")
        let owner = NSObject()
        var inputs = 0
        hid.activate(first, owner: owner) { _ in inputs += 1 }
        usb.emit([1, 0])
        check(inputs == 1, "initial controller forwards input")
        usb.emitRemoval()
        check(hid.devices.isEmpty, "removal survives failed registry lookup")
        hid.deactivate(first, owner: owner)

        let bluetooth = TestHIDDevice(id: 11, bluetooth: true)
        hid.manager!.emitMatch(bluetooth)
        check(hid.devices.count == 1 && hid.devices.first?.ref === bluetooth, "USB to Bluetooth reconnect selects the live controller")
        let reconnected = hid.devices[0]
        let pairing = get(hid, reconnected, .feature, 9)
        check(pairing?.first == 9, "pairing request uses the reconnected device, not the dead USB ref")
        hid.activate(reconnected, owner: owner) { _ in inputs += 1 }
        bluetooth.emit([0x31, 0])
        check(inputs == 2, "reconnected device forwards input")
        _ = get(hid, reconnected, .input, 0x31)
        check(bluetooth.getRequests.last?.2 == 78, "Bluetooth DualSense input keeps descriptor size")

        let rematched = HIDPassthrough()
        precondition(rematched.start())
        let original = TestHIDDevice(id: 12, bluetooth: true)
        let alias = TestHIDDevice(id: 12, bluetooth: true)
        rematched.manager!.emitMatch(original)
        rematched.manager!.emitMatch(alias)
        rematched.manager!.emitMatch(alias)
        check(rematched.devices.count == 1 && rematched.devices.first?.ref === original,
              "re-matching still de-duplicates registry identity and keeps the open ref")
        check(original.removalCallback != nil && alias.removalCallback == nil,
              "re-matching retains the original device's removal notification")
        alias.live = false
        original.emitRemoval()
        check(rematched.devices.isEmpty, "retained device removal survives re-match and failed registry lookup")
        rematched.removed(original)
        check(rematched.devices.isEmpty, "duplicate removal is harmless")
        hid.deactivate(reconnected, owner: owner)

        let ble = TestHIDDevice(id: 20, bluetooth: true, valve: true)
        hid.manager!.emitMatch(ble)
        let valve = hid.devices.last!
        check(HIDPassthrough.isSteamController(valve), "Valve BLE is matched once Steam Controllers are enabled")
        let feature = get(hid, valve, .feature, 1)
        check(feature?.count == 65 && feature?.first == 1, "BLE Steam Controller keeps the 65-byte feature fix")
        check(ble.getRequests.last?.2 == 128, "BLE Steam Controller feature requests keep headroom")
        _ = get(hid, valve, .input, 1)
        check(ble.getRequests.last?.2 == 64, "BLE input requests are not enlarged")

        let puck = TestHIDDevice(id: 21, valve: true, puckSlot: 2)
        hid.manager!.emitMatch(puck)
        let slot = hid.devices.last!
        _ = get(hid, slot, .feature, 1)
        check(puck.getRequests.last?.2 == 64, "USB Puck requests are not enlarged")
        var movedInputs = 0
        let secondOwner = NSObject()
        hid.activate(slot, owner: owner) { _ in movedInputs += 100 }
        hid.activate(slot, owner: secondOwner) { _ in movedInputs += 1 }
        hid.deactivate(slot, owner: owner)
        puck.emit([0x42, 0])
        check(movedInputs == 1, "moving a Steam Controller preserves the new player's input handler")
        hid.deactivate(slot, owner: secondOwner)
        puck.emit([0x42, 0])
        check(movedInputs == 1, "deactivating the current player stops forwarding")
        hid.stopPuckTimer()
        print("Original regressions: \(checks) checks, \(failures) failures")

        #if HAS_INDEPENDENT_DEVICES
        check(hid.manager!.independent, "manager enumerates in independent-devices mode")
        check(bluetooth.isOpen && bluetooth.scheduled && bluetooth.openCalls == 1,
              "accepted device is explicitly opened and scheduled once")
        check(original.closeCalls == 1 && !original.isOpen && !original.scheduled && alias.openCalls == 0,
              "removal closes and unschedules the retained ref; re-matches never open aliases")

        let deniedHID = HIDPassthrough()
        precondition(deniedHID.start())
        let denied = TestHIDDevice(id: 30)
        denied.openResult = kIOReturnNotPermitted
        let requestsBefore = permissionRequests
        deniedHID.manager!.emitMatch(denied)
        check(deniedHID.devices.isEmpty && denied.openCalls == 1 && !denied.isOpen
              && !denied.scheduled && denied.inputCallback == nil,
              "NotPermitted device open never adds, schedules or passes through the device")
        check(permissionRequests == requestsBefore + 1, "denied device open requests Input Monitoring")
        let failedMatch = TestHIDDevice(id: 31)
        deniedHID.added(failedMatch, result: kIOReturnError)
        check(failedMatch.openCalls == 0 && deniedHID.devices.isEmpty,
              "failed matching callback is not retried as a successful device open")
        let invalid = TestHIDDevice(id: 32)
        invalid.properties[kIOHIDReportDescriptorKey] = Data()
        deniedHID.manager!.emitMatch(invalid)
        check(invalid.openCalls == 1 && invalid.closeCalls == 1 && !invalid.isOpen,
              "device rejected after open is closed without scheduling")

        let owned = TestHIDDevice(id: 33)
        autoreleasepool {
            let lifecycle = HIDPassthrough()
            precondition(lifecycle.start())
            lifecycle.manager!.emitMatch(owned)
            var delivered = 0
            if let device = lifecycle.devices.first {
                lifecycle.activate(device, owner: owner) { _ in delivered += 1 }
            }
            IOHIDManagerClose(lifecycle.manager!, IOOptionBits(kIOHIDOptionsTypeNone))
            owned.emit([1, 0])
            check(owned.isOpen && delivered == 1, "closing independent manager leaves device I/O owned by Device")
            owned.emitRemoval()
            check(lifecycle.devices.isEmpty, "independent device removal works after manager close")
        }
        check(owned.closeCalls == 1 && !owned.isOpen && !owned.scheduled,
              "released Device closes and unschedules its own I/O")
        #endif

        #if HAS_GENERIC_HID
        let genericHID = HIDPassthrough()
        genericHID.matchGenericControllers = true
        precondition(genericHID.start())
        func generic(_ id: UInt64, usage: UInt32 = 5) -> TestHIDDevice {
            let device = TestHIDDevice(id: id)
            device.properties[kIOHIDVendorIDKey] = 0x1234
            device.properties[kIOHIDProductIDKey] = 0x5678
            device.usages = [usage]
            var descriptor = device.properties[kIOHIDReportDescriptorKey] as! Data
            descriptor[3] = UInt8(usage)
            device.properties[kIOHIDReportDescriptorKey] = descriptor
            return device
        }
        let supported = generic(40)
        supported.gameControllerSupported = true
        #if HAS_GAMECONTROLLER_OWNERSHIP
        supported.properties[kIOHIDVendorIDKey] = 0x2ca3
        supported.properties[kIOHIDProductIDKey] = 0x1020
        supported.properties[kIOHIDProductKey] = "C5"
        supported.properties[kIOHIDManufacturerKey] = "DJI"
        #endif
        genericHID.manager!.emitMatch(supported)
        genericHID.manager!.emitMatch(supported)
        #if HAS_GAMECONTROLLER_OWNERSHIP
        check(genericHID.devices.isEmpty && supported.openCalls == 0 && supported.supportQueries == 1
              && !supported.scheduled,
              "advertised support without publication holds HID unopened; support cached on re-match")
        let early = generic(44)
        early.gameControllerSupported = true
        early.properties[kIOHIDProductKey] = "Early Pad"
        genericHID.manager!.emitMatch(early)
        GCController.published = [GCController(vendorName: "Xbox Wireless Controller", productCategory: "Xbox One")]
        genericHID.gameControllersChanged()
        check(supported.openCalls == 0 && early.openCalls == 0,
              "unrelated published controller does not end another HID's grace period")
        let earlyController = GCController(vendorName: "  EARLY \n PAD ")
        GCController.published.append(earlyController)
        genericHID.gameControllersChanged()
        check(early.openCalls == 0 && !early.scheduled && genericHID.genericDevices[early.id]?.ownership == .gameController,
              "matching controller published within grace excludes generic HID without opening")
        let removedPending = generic(45)
        removedPending.gameControllerSupported = true
        genericHID.manager!.emitMatch(removedPending)
        removedPending.emitRemoval()
        check(genericHID.genericDevices[removedPending.id] == nil && removedPending.openCalls == 0,
              "manager removal forgets unopened pending HID without querying dead registry")

        let specialHID = HIDPassthrough()
        specialHID.matchSteamControllers = true
        specialHID.matchGenericControllers = true
        precondition(specialHID.start())
        let specialSony = TestHIDDevice(id: 46)
        let specialValve = TestHIDDevice(id: 47, bluetooth: true, valve: true)
        specialSony.gameControllerSupported = true
        specialValve.gameControllerSupported = true
        specialHID.manager!.emitMatch(specialSony)
        specialHID.manager!.emitMatch(specialValve)
        specialHID.gameControllersChanged()
        check(specialHID.devices.count == 2 && specialHID.devices.allSatisfy { !$0.generic }
              && specialSony.openCalls == 1 && specialValve.openCalls == 1
              && specialSony.supportQueries == 0 && specialValve.supportQueries == 0,
              "DualSense and Valve retain immediate special routes despite advertised support and GC changes")
        #else
        check(genericHID.devices.isEmpty && supported.openCalls == 0 && supported.supportQueries == 1,
              "GameController-supported gamepad is excluded before open; support is cached on re-match")
        #endif
        let multiAxis = generic(41, usage: 8)
        genericHID.manager!.emitMatch(multiAxis)
        check(genericHID.devices.isEmpty && multiAxis.openCalls == 0,
              "non-gamepad/joystick usage is excluded before open")
        let numbered = generic(42, usage: 4)
        genericHID.manager!.emitMatch(numbered)
        check(genericHID.devices.first?.ref === numbered && genericHID.devices.first?.generic == true,
              "unsupported generic joystick takes the raw HID path")

        func set(_ device: Device, _ type: ReportType, _ bytes: [UInt8]) {
            var result: IOReturn?
            genericHID.setReport(device, type: type, data: bytes) { result = $0 }
            let deadline = Date(timeIntervalSinceNow: 2)
            while result == nil && Date() < deadline { RunLoop.main.run(until: Date(timeIntervalSinceNow: 0.001)) }
            check(result == kIOReturnSuccess, "SET_REPORT completes successfully on main queue")
        }
        if let device = genericHID.devices.first {
            set(device, .output, [0x81, 0x55])
            check(numbered.setRequests.last?.1 == 0x81 && numbered.setRequests.last?.2 == [0x81, 0x55],
                  "input-only report IDs apply device-wide to undeclared output reports")
            set(device, .feature, [0x82, 0x66])
            check(numbered.setRequests.last?.1 == 0x82 && numbered.setRequests.last?.2 == [0x82, 0x66],
                  "input-only report IDs apply device-wide to undeclared feature reports")
        }
        let unnumbered = generic(43)
        unnumbered.elements = []
        unnumbered.properties[kIOHIDReportDescriptorKey] = Data([0x05, 0x01, 0x09, 0x05, 0xa1, 0x01,
                                                               0x75, 0x08, 0x95, 0x40, 0x81, 0x02, 0xc0])
        genericHID.manager!.emitMatch(unnumbered)
        check(genericHID.devices.last?.ref === unnumbered, "unsupported generic gamepad takes the raw HID path")
        if let device = genericHID.devices.last, device.ref === unnumbered {
            set(device, .output, [0x81, 0x55])
            check(unnumbered.setRequests.last?.1 == 0 && unnumbered.setRequests.last?.2 == [0x81, 0x55],
                  "unnumbered output uses report ID zero without stripping payload")
        }
        #if HAS_GAMECONTROLLER_OWNERSHIP
        // Exercise the real production timer, not an artificial supportsHIDDevice override.
        RunLoop.main.run(until: Date(timeIntervalSinceNow: GenericHIDRouting.publicationGrace + 0.1))
        check(genericHID.devices.contains { $0.ref === supported } && supported.openCalls == 1,
              "advertised support with no matching published controller accepts HID after real grace timer")
        check(early.openCalls == 0 && !genericHID.devices.contains { $0.ref === early },
              "controller published during grace remains excluded after timer expiry")
        check(removedPending.openCalls == 0, "removed pending device is not opened at grace expiry")
        var lateInputs = 0
        if let device = genericHID.devices.first(where: { $0.ref === supported }) {
            genericHID.activate(device, owner: owner) { _ in lateInputs += 1 }
        }
        supported.emit([1, 0])
        check(lateInputs == 1, "accepted supported HID forwards input before GC publication")
        let lateController = GCController(vendorName: " dJi  C5 ")
        GCController.published.append(lateController)
        genericHID.gameControllersChanged()
        supported.emit([1, 0])
        check(!genericHID.devices.contains { $0.ref === supported } && !supported.isOpen
              && !supported.scheduled && lateInputs == 1,
              "late matching GC publication releases generic HID and stops duplicate input")
        GCController.published.removeAll { $0 === lateController }
        genericHID.gameControllersChanged()
        check(genericHID.devices.contains { $0.ref === supported } && supported.openCalls == 2,
              "GC disappearance re-offers the retained HID without a fresh match")
        GCController.published.append(lateController)
        genericHID.gameControllersChanged()
        let decisionsBefore = loggedLines.filter { $0.contains("2ca3:1020 C5:") }.count
        genericHID.gameControllersChanged()
        genericHID.manager!.emitMatch(supported)
        check(decisionsBefore == 5 && loggedLines.filter { $0.contains("2ca3:1020 C5:") }.count == decisionsBefore,
              "one VID:PID/product ownership log per transition, no repeated GC/rematch spam")
        early.emitRemoval()
        check(genericHID.genericDevices[early.id] == nil && early.openCalls == 0,
              "manager removal forgets GC-owned unopened device")
        let publishedBeforeEmptyTest = GCController.published
        GCController.published = []
        let emptyGCHID = HIDPassthrough()
        emptyGCHID.matchGenericControllers = true
        precondition(emptyGCHID.start())
        let unpublished = generic(48)
        unpublished.gameControllerSupported = true
        emptyGCHID.manager!.emitMatch(unpublished)
        RunLoop.main.run(until: Date(timeIntervalSinceNow: GenericHIDRouting.publicationGrace + 0.1))
        check(GCController.controllers().isEmpty && emptyGCHID.devices.first?.ref === unpublished
              && unpublished.openCalls == 1,
              "supportsHIDDevice=true with zero published controllers accepts HID after grace")
        GCController.published = publishedBeforeEmptyTest
        #endif
        #endif
        #if HAS_HID_DIAGNOSTICS
        let unseen = generic(50, usage: 8)
        unseen.properties[kIOHIDProductKey] = "Horizon SLT6"
        unseen.properties[kIOHIDVendorIDKey] = 0x35cf
        unseen.properties[kIOHIDProductIDKey] = 0x04fb
        unseen.properties[kIOHIDPrimaryUsagePageKey] = 1
        unseen.properties[kIOHIDPrimaryUsageKey] = 8
        let keyboard = generic(51, usage: 6)
        keyboard.properties[kIOHIDProductKey] = "Keyboard"
        diagnosticInventory = [unseen, keyboard, supported, numbered]
        let supportedOpensBeforeCensus = supported.openCalls
        let census = genericHID.diagnosticLines().joined(separator: "\n")
        check(census.contains("35cf:04fb") && census.contains("Horizon SLT6")
              && census.contains("primary=1/8") && census.contains("excluded usage"),
              "inventory exposes controllers excluded by usage matching (STEAMAC-8V)")
        #if HAS_GAMECONTROLLER_OWNERSHIP
        check(census.contains("GameController-owned (matching published controller)"),
              "inventory requires matching published controller, not advertised HID support")
        #else
        check(census.contains("GameController-supported"), "inventory distinguishes GameController filtering")
        #endif
        check(census.contains("passed through"), "inventory identifies active raw HID routes")
        check(unseen.openCalls == 0 && keyboard.openCalls == 0 && supported.openCalls == supportedOpensBeforeCensus
              && !unseen.scheduled && !keyboard.scheduled && permissionRequests == requestsBefore + 1,
              "diagnostic census never opens or schedules excluded devices or requests access")
        check(keyboard.supportQueries == 0, "diagnostics do not probe GameController support for keyboards")
        diagnosticInventory = []
        check(genericHID.diagnosticLines().contains(where: { $0.contains("no HID devices") }),
              "empty inventory is explicit")

        func dualSenseReport(bluetooth: Bool) -> [UInt8] {
            var report = [UInt8](repeating: 0, count: bluetooth ? 78 : 64)
            report[0] = bluetooth ? 0x31 : 1
            let base = bluetooth ? 2 : 1
            for (i, byte): (Int, UInt8) in [128, 127, 129, 126, 0, 255].enumerated() { report[base + i] = byte }
            report[base + 15] = 0xff; report[base + 16] = 0xff // gyro x = -1, little endian
            report[base + 21] = 0x00; report[base + 22] = 0xe0 // accel x = -8192
            report[base + 32] = 0 // first contact active at (0x345, 0x678)
            report[base + 33] = 0x45; report[base + 34] = 0x83; report[base + 35] = 0x67
            report[base + 36] = 0x80 // second contact inactive; coordinates must not be interpreted
            return report
        }
        for bluetooth in [false, true] {
            let report = dualSenseReport(bluetooth: bluetooth)
            let decoded = report.withUnsafeBufferPointer { HIDPassthrough.dualSenseDiagnostic($0, bus: bluetooth ? busBluetooth : busUSB) }
            check(decoded?.contains("sticks L=128,127 R=129,126") == true
                  && decoded?.contains("triggers=0,255") == true
                  && decoded?.contains("gyro=-1,0,0") == true
                  && decoded?.contains("accel=-8192,0,0") == true
                  && decoded?.contains("touch0=837,1656") == true
                  && decoded?.contains("touch1=inactive") == true,
                  "\(bluetooth ? "Bluetooth" : "USB") DualSense diagnostics separate sticks, sensors and touches (STEAMAC-8R)")
            let truncated = Array(report.dropLast())
            check(truncated.withUnsafeBufferPointer { HIDPassthrough.dualSenseDiagnostic($0, bus: bluetooth ? busBluetooth : busUSB) } == nil,
                  "truncated DualSense report is not decoded")
        }
        let snapshot = dualSenseReport(bluetooth: true)
        bluetooth.emit(snapshot)
        let lines = hid.diagnosticLines().joined(separator: "\n")
        check(lines.contains("sticks L=128,127 R=129,126") && lines.contains("age="),
              "diagnostic report reads the latest callback buffer and its age")
        check(inputs == 2, "diagnostics do not reactivate a deactivated input route")
        #elseif HAS_GENERIC_HID
        check(false, "HID discovery and DualSense axis diagnostics present (STEAMAC-8V/8R)")
        #endif
        #if HAS_INPUT_MONITORING_WARNING
        let warningHID = HIDPassthrough()
        warningHID.matchSteamControllers = true
        var permissionChanges: [Bool] = []
        warningHID.onPermissionNeededChange = { permissionChanges.append($0) }
        warningHID.awaitPermission()
        check(warningHID.needsInputMonitoring && warningHID.waitingForPermission,
              "permission denial publishes warning and polls for a grant")
        warningHID.matchGenericControllers = true
        warningHID.matchSteamControllers = false
        check(warningHID.needsInputMonitoring, "generic matching keeps the composite-controller warning")
        let permissionTimer = warningHID.permissionTimer
        warningHID.matchGenericControllers = false
        check(!warningHID.needsInputMonitoring && !warningHID.waitingForPermission
              && warningHID.permissionTimer == nil && permissionTimer?.isValid == false,
              "disabling permission-requiring matching clears warning and stops polling even before start")
        check(permissionChanges == [true, false], "permission warning changes propagate to Settings")
        warningHID.matchSteamControllers = true
        warningHID.recreatedAfterGrant = true
        warningHID.awaitPermission()
        check(warningHID.needsInputMonitoring && warningHID.permissionTimer == nil
              && !warningHID.waitingForPermission,
              "second denial after grant retains warning without promising another automatic reopen")
        warningHID.matchSteamControllers = false
        #endif
        print("HID passthrough: \(checks) checks, \(failures) failures")
        return failures == 0 ? 0 : 1
    }
}
exit(HIDPassthrough.regressionTests())
