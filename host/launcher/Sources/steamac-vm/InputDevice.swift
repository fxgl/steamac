import CKrun
import Darwin
import Foundation
import os

struct AbsAxis {
    var min: Int32
    var max: Int32
    var fuzz: Int32 = 0
    var flat: Int32 = 0
    var res: Int32 = 0
}

/// A virtio-input device backed by libkrun's krun_input_config / krun_input_event_provider
/// vtables. Events are queued from any thread; libkrun's input worker drains them after it
/// sees the ready pipe become readable (its epoll emulation is level-triggered kqueue).
final class InputDevice {
    let name: String
    let serial: String
    let ids: krun_input_device_ids
    let properties: [UInt16]
    let capabilities: [UInt16: [UInt16]]   // EV type -> codes
    let absInfo: [UInt16: AbsAxis]

    private var lock = os_unfair_lock()
    private var queue: [krun_input_event]
    private var head = 0
    private var count = 0
    private var active = false
    private let readFd: Int32
    private let writeFd: Int32
    static let capacity = 4096

    init(name: String, serial: String, ids: krun_input_device_ids, properties: [UInt16] = [],
         capabilities: [UInt16: [UInt16]], absInfo: [UInt16: AbsAxis] = [:]) {
        self.name = name
        self.serial = serial
        self.ids = ids
        self.properties = properties
        self.capabilities = capabilities
        self.absInfo = absInfo
        queue = Array(repeating: krun_input_event(), count: InputDevice.capacity)
        var fds: [Int32] = [0, 0]
        guard pipe(&fds) == 0 else { fatal("pipe: \(String(cString: strerror(errno)))") }
        readFd = fds[0]
        writeFd = fds[1]
        for fd in fds {
            _ = fcntl(fd, F_SETFL, fcntl(fd, F_GETFL) | O_NONBLOCK)
            _ = fcntl(fd, F_SETFD, FD_CLOEXEC)
        }
    }

    // MARK: producer side

    /// Queue a batch of events followed by SYN_REPORT. Dropped (whole batch) if the guest
    /// driver is not active yet or the queue is full, so SYN groups never get split.
    func send(_ events: [(UInt16, UInt16, Int32)]) {
        guard !events.isEmpty else { return }
        os_unfair_lock_lock(&lock)
        defer { os_unfair_lock_unlock(&lock) }
        guard active, count + events.count + 1 <= InputDevice.capacity else { return }
        let wasEmpty = count == 0
        for (type, code, value) in events {
            push(krun_input_event(type: type, code: code, value: UInt32(bitPattern: value)))
        }
        push(krun_input_event(type: EV.SYN, code: SYN.REPORT, value: 0))
        if wasEmpty {
            var b: UInt8 = 1
            _ = Darwin.write(writeFd, &b, 1)
        }
    }

    private func push(_ e: krun_input_event) {
        queue[(head + count) % InputDevice.capacity] = e
        count += 1
    }

    // MARK: consumer side (libkrun input worker thread)

    fileprivate func activate() {
        os_unfair_lock_lock(&lock)
        active = true
        head = 0
        count = 0
        drainPipe()
        os_unfair_lock_unlock(&lock)
    }

    fileprivate func nextEvent(_ out: UnsafeMutablePointer<krun_input_event>) -> Int32 {
        os_unfair_lock_lock(&lock)
        defer { os_unfair_lock_unlock(&lock) }
        guard count > 0 else {
            drainPipe()
            return 0
        }
        out.pointee = queue[head]
        head = (head + 1) % InputDevice.capacity
        count -= 1
        if count == 0 { drainPipe() }
        return 1
    }

    private func drainPipe() {
        var buf = [UInt8](repeating: 0, count: 64)
        while Darwin.read(readFd, &buf, buf.count) > 0 {}
    }

    // MARK: config queries (libkrun device thread). Never fail: libkrun before 1.19.7 loses the
    // guest's select byte after an error (InputConfig::invalidate), so unsupported
    // selections answer "0 bytes" instead.

    private static func writeBitmap(_ codes: [UInt16], _ buf: UnsafeMutablePointer<UInt8>?, _ len: Int) -> Int32 {
        guard let buf, let maxCode = codes.max() else { return 0 }
        let bytes = min(Int(maxCode) / 8 + 1, len)
        for i in 0..<bytes { buf[i] = 0 }
        for c in codes where Int(c) / 8 < bytes {
            buf[Int(c) / 8] |= UInt8(1 << (c % 8))
        }
        return Int32(bytes)
    }

    private static func writeString(_ s: String, _ buf: UnsafeMutablePointer<UInt8>?, _ len: Int) -> Int32 {
        guard let buf else { return 0 }
        let bytes = Array(s.utf8.prefix(len))
        for (i, b) in bytes.enumerated() { buf[i] = b }
        return Int32(bytes.count)
    }

    fileprivate func queryCapabilities(_ type: UInt8, _ buf: UnsafeMutablePointer<UInt8>?, _ len: Int) -> Int32 {
        if UInt16(type) == EV.REP {
            // Advertise EV_REP (1 zero byte, like QEMU): guest input core does soft autorepeat.
            guard capabilities[EV.REP] != nil, let buf, len >= 1 else { return 0 }
            buf[0] = 0
            return 1
        }
        guard let codes = capabilities[UInt16(type)] else { return 0 }
        return InputDevice.writeBitmap(codes, buf, len)
    }

    fileprivate func queryAbs(_ axis: UInt8, _ out: UnsafeMutablePointer<krun_input_absinfo>?) -> Int32 {
        guard let out else { return 0 }
        if let a = absInfo[UInt16(axis)] {
            out.pointee = krun_input_absinfo(min: UInt32(bitPattern: a.min), max: UInt32(bitPattern: a.max),
                                             fuzz: UInt32(bitPattern: a.fuzz), flat: UInt32(bitPattern: a.flat),
                                             res: UInt32(bitPattern: a.res))
        } else {
            out.pointee = krun_input_absinfo()
        }
        return 0
    }

    // MARK: C vtables

    private static func dev(_ p: UnsafeMutableRawPointer?) -> InputDevice {
        Unmanaged<InputDevice>.fromOpaque(p!).takeUnretainedValue()
    }

    /// Register with libkrun. The device is retained for the process lifetime.
    func attach(ctx: UInt32) throws {
        let me = Unmanaged.passRetained(self).toOpaque()

        var config = krun_input_config()
        config.features = UInt64(KRUN_INPUT_CONFIG_FEATURE_QUERY)
        config.create_userdata = me
        config.create = { instance, userdata, _ in
            instance?.pointee = UnsafeMutableRawPointer(mutating: userdata)
            return 0
        }
        config.vtable.destroy = { _ in 0 }
        config.vtable.query_device_name = { inst, buf, len in
            InputDevice.writeString(InputDevice.dev(inst).name, buf, len)
        }
        config.vtable.query_serial_name = { inst, buf, len in
            InputDevice.writeString(InputDevice.dev(inst).serial, buf, len)
        }
        config.vtable.query_device_ids = { inst, ids in
            ids?.pointee = InputDevice.dev(inst).ids
            return 0
        }
        config.vtable.query_event_capabilities = { inst, type, buf, len in
            InputDevice.dev(inst).queryCapabilities(type, buf, len)
        }
        config.vtable.query_abs_info = { inst, axis, info in
            InputDevice.dev(inst).queryAbs(axis, info)
        }
        config.vtable.query_properties = { inst, buf, len in
            InputDevice.writeBitmap(InputDevice.dev(inst).properties, buf, len)
        }

        var events = krun_input_event_provider()
        events.features = UInt64(KRUN_INPUT_EVENT_PROVIDER_FEATURE_QUEUE)
        events.create_userdata = me
        events.create = { instance, userdata, _ in
            // Called on libkrun's input worker thread when the guest driver activates the device.
            let p = UnsafeMutableRawPointer(mutating: userdata)
            InputDevice.dev(p).activate()
            instance?.pointee = p
            return 0
        }
        events.vtable.destroy = { _ in 0 }
        events.vtable.get_ready_efd = { inst in InputDevice.dev(inst).readFd }
        events.vtable.next_event = { inst, out in
            guard let out else { return KRUN_INPUT_ERR_INVALID_PARAM }
            return InputDevice.dev(inst).nextEvent(out)
        }

        let r = krun_add_input_device(ctx, &config, MemoryLayout<krun_input_config>.size,
                                      &events, MemoryLayout<krun_input_event_provider>.size)
        if r < 0 { throw KrunError(call: "krun_add_input_device(\(name))", code: r) }
    }
}

// MARK: device definitions

enum InputDevices {
    static let absMax: Int32 = 32767
    static let mouseButtons = [BTN.LEFT, BTN.RIGHT, BTN.MIDDLE, BTN.SIDE, BTN.EXTRA]
    /// joydev treats an ABS_X/ABS_Y device as a joystick unless it looks exactly like an absolute
    /// mouse (EV = SYN|KEY|ABS|MSC|REL, keys exactly LEFT/RIGHT/MIDDLE; see
    /// joydev_dev_is_absolute_mouse()). Side/extra buttons go through the relative mouse instead.
    static let tabletButtons = [BTN.LEFT, BTN.RIGHT, BTN.MIDDLE]
    static let MSC_SCAN: UInt16 = 0x04
    static let wheels = [REL.WHEEL, REL.HWHEEL, REL.WHEEL_HI_RES, REL.HWHEEL_HI_RES]

    static func keyboard() -> InputDevice {
        InputDevice(name: "steamac virtio keyboard", serial: "steamac-kbd",
                    ids: krun_input_device_ids(bustype: BUS.VIRTUAL, vendor: 0x1af4, product: 0x0001, version: 1),
                    capabilities: [EV.KEY: Keymap.allCodes, EV.REP: []])
    }

    static func tablet() -> InputDevice {
        InputDevice(name: "steamac virtio tablet", serial: "steamac-tablet",
                    ids: krun_input_device_ids(bustype: BUS.VIRTUAL, vendor: 0x1af4, product: 0x0003, version: 1),
                    capabilities: [EV.KEY: tabletButtons, EV.REL: wheels, EV.ABS: [ABS.X, ABS.Y], EV.MSC: [MSC_SCAN]],
                    absInfo: [ABS.X: AbsAxis(min: 0, max: absMax), ABS.Y: AbsAxis(min: 0, max: absMax)])
    }

    static func mouse() -> InputDevice {
        InputDevice(name: "steamac virtio mouse", serial: "steamac-mouse",
                    ids: krun_input_device_ids(bustype: BUS.VIRTUAL, vendor: 0x1af4, product: 0x0002, version: 1),
                    capabilities: [EV.KEY: mouseButtons, EV.REL: [REL.X, REL.Y] + wheels])
    }
}
