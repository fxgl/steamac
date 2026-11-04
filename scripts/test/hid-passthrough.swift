// IOKit boundary for hid-passthrough.py. No real HID devices are opened or used.
// A removed service no longer answers registry queries. A USB DualSense fixture
// requires a descriptor-sized firmware GET_REPORT; BLE Valve needs its extra byte.
// These model the two regressions in STEAMAC-84, not a physical USB reproduction.
typealias IOHIDDevice = TestHIDDevice
typealias IOHIDManager = TestHIDManager
typealias TestDeviceCallback = (UnsafeMutableRawPointer?, IOReturn, UnsafeMutableRawPointer?, IOHIDDevice) -> Void

private var services: [io_service_t: TestHIDDevice] = [:]
private var nextService: io_service_t = 1

final class TestHIDDevice: NSObject {
    let service: io_service_t
    let id: UInt64
    var live = true
    var properties: [String: Any]
    var getRequests: [(IOHIDReportType, Int, Int)] = []
    var inputCallback: IOHIDReportCallback?
    var inputContext: UnsafeMutableRawPointer?
    var removalCallback: IOHIDCallback?
    var removalContext: UnsafeMutableRawPointer?

    init(id: UInt64, bluetooth: Bool = false, valve: Bool = false, puckSlot: Int? = nil) {
        self.id = id
        service = nextService
        nextService += 1
        properties = [kIOHIDVendorIDKey: valve ? 0x28de : 0x054c,
                      kIOHIDProductIDKey: valve ? (puckSlot == nil ? 0x1303 : 0x1304) : 0x0ce6,
                      kIOHIDTransportKey: bluetooth ? kIOHIDTransportBluetoothLowEnergyValue : kIOHIDTransportUSBValue,
                      kIOHIDReportDescriptorKey: Data([0x05, 0x01, 0x09, 0x05]),
                      kIOHIDMaxInputReportSizeKey: bluetooth && !valve ? 78 : 64,
                      kIOHIDMaxFeatureReportSizeKey: 64]
        if let puckSlot { properties["bInterfaceNumber"] = puckSlot }
        super.init()
        services[service] = self
    }

    func emit(_ report: [UInt8]) {
        var report = report
        report.withUnsafeMutableBufferPointer {
            inputCallback?(inputContext, kIOReturnSuccess, nil, kIOHIDReportTypeInput,
                           UInt32($0[0]), $0.baseAddress!, $0.count)
        }
    }

    func emitRemoval() {
        live = false
        removalCallback?(removalContext, kIOReturnSuccess, nil)
    }
}
final class TestHIDManager {}

func log(_ line: String) { print(line) }
let IOHIDManagerCreate: (CFAllocator?, IOOptionBits) -> IOHIDManager = { _, _ in TestHIDManager() }
func IOHIDManagerSetDeviceMatchingMultiple(_ manager: IOHIDManager, _ matching: CFArray?) {}
func IOHIDManagerRegisterDeviceMatchingCallback(_ manager: IOHIDManager, _ callback: TestDeviceCallback?, _ context: UnsafeMutableRawPointer?) {}
func IOHIDManagerRegisterDeviceRemovalCallback(_ manager: IOHIDManager, _ callback: TestDeviceCallback?, _ context: UnsafeMutableRawPointer?) {}
func IOHIDManagerScheduleWithRunLoop(_ manager: IOHIDManager, _ runLoop: CFRunLoop?, _ mode: CFString?) {}
func IOHIDManagerUnscheduleFromRunLoop(_ manager: IOHIDManager, _ runLoop: CFRunLoop?, _ mode: CFString?) {}
func IOHIDManagerOpen(_ manager: IOHIDManager, _ options: IOOptionBits) -> IOReturn { kIOReturnSuccess }
@discardableResult
func IOHIDManagerClose(_ manager: IOHIDManager, _ options: IOOptionBits) -> IOReturn { kIOReturnSuccess }
func IOHIDRequestAccess(_ type: IOHIDRequestType) -> Bool { true }
func IOHIDCheckAccess(_ type: IOHIDRequestType) -> IOHIDAccessType { kIOHIDAccessTypeGranted }
func IOHIDDeviceUnscheduleFromRunLoop(_ device: IOHIDDevice, _ runLoop: CFRunLoop?, _ mode: CFString?) {}
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
}
func IOHIDDeviceGetReport(_ device: IOHIDDevice, _ type: IOHIDReportType, _ id: CFIndex,
                         _ report: UnsafeMutablePointer<UInt8>, _ size: UnsafeMutablePointer<CFIndex>) -> IOReturn {
    device.getRequests.append((type, id, size.pointee))
    guard device.live else { return kIOReturnBadArgument }
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
    device.live ? kIOReturnSuccess : kIOReturnBadArgument
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
        let usb = TestHIDDevice(id: 10)
        hid.added(usb, result: kIOReturnSuccess)
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
        hid.added(bluetooth, result: kIOReturnSuccess)
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
        let original = TestHIDDevice(id: 12, bluetooth: true)
        let alias = TestHIDDevice(id: 12, bluetooth: true)
        rematched.added(original, result: kIOReturnSuccess)
        rematched.added(alias, result: kIOReturnSuccess)
        rematched.added(alias, result: kIOReturnSuccess)
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
        hid.added(ble, result: kIOReturnSuccess)
        let valve = hid.devices.last!
        let feature = get(hid, valve, .feature, 1)
        check(feature?.count == 65 && feature?.first == 1, "BLE Steam Controller keeps the 65-byte feature fix")
        check(ble.getRequests.last?.2 == 128, "BLE Steam Controller feature requests keep headroom")
        _ = get(hid, valve, .input, 1)
        check(ble.getRequests.last?.2 == 64, "BLE input requests are not enlarged")

        let puck = TestHIDDevice(id: 21, valve: true, puckSlot: 2)
        hid.added(puck, result: kIOReturnSuccess)
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
        print("HID passthrough: \(checks) checks, \(failures) failures")
        return failures == 0 ? 0 : 1
    }
}
exit(HIDPassthrough.regressionTests())
