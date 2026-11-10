import Darwin
import Dispatch
import Foundation

/// Fuente local de mandos para el Switch 2 Pro Controller a través de Switch2Bridge.
///
/// Switch2Bridge ya publica el estado del mando en un socket Unix propio. Este fichero es
/// únicamente un cliente de lectura: no crea sockets, no escribe en el puente, no lanza ni
/// reinicia procesos y no necesita permisos especiales. La ruta y el formato son los que fija
/// el proyecto del puente (commit d7dc2f240ea4a267a84bc44f89668048380db1ba):
///
/// - socket `~/Library/Application Support/Switch2Bridge/estado.sock`, `AF_UNIX`/`SOCK_STREAM`,
///   `chmod 0600`, varios clientes a la vez;
/// - tramas fijas de 20 bytes little-endian, sin longitud, versión ni CRC:
///   `u32` magia `0x53325031` («S2P1»), `u32` máscara de botones Nintendo, cuatro `i16` (stick
///   izquierdo X/Y, derecho X/Y), `u8` ZL, `u8` ZR, `u8` conectado y `u8` de relleno.
///
/// Los ejes llegan ya en convención SDL (Y positiva hacia abajo) y el productor satura a
/// ±32767. Como `GamepadBridge.read(_:RemotePad:...)` vuelve a negar Y, aquí se niega una sola
/// vez al construir el `RemotePad`; `Int16.min` se satura para no desbordar.
///
/// El ABI es unidireccional: no transporta vibración HD, giroscopio, batería ni LEDs. Su máscara
/// de botones sí incluye Captura, C, GR, GL y SR/SL, pero la ruta xbox360/uinput del guest solo
/// representa los 11 botones de `GuestPad.buttonCodes`: esos bits se descartan y no se finge
/// ninguna función que el guest no pueda recibir. El `RemotePad` declara además `capabilities = 0`
/// para que el guest no pida rumble por un canal que no existe.
enum Switch2BridgeInput {
    static let frameSize = 20
    static let magic: UInt32 = 0x5332_5031
    /// Número propio para no colisionar con los mandos de Moonlight (0…3).
    static let padNumber: UInt16 = 0xFFFE
    static let vendorNintendo: UInt16 = 0x057E
    static let productSwitch2Pro: UInt16 = 0x2069
    /// Tope de bytes por lectura/entrada. Tras decodificar, el sobrante es siempre menor que una
    /// trama (20 B), más el resto de una lectura de 4096 B: no se rechaza un flujo válido por
    /// coincidir justo con el tope.
    static let maxBuffered = 4096

    static var defaultSocketPath: String {
        (NSHomeDirectory() as NSString).appendingPathComponent("Library/Application Support/Switch2Bridge/estado.sock")
    }

    // MARK: - Trama

    struct Frame: Equatable {
        let buttons: UInt32
        let leftX: Int16
        let leftY: Int16
        let rightX: Int16
        let rightY: Int16
        let leftTrigger: UInt8
        let rightTrigger: UInt8
        let connected: Bool

        init?(bytes: [UInt8]) {
            self.init(bytes: bytes[...])
        }

        init?(bytes: ArraySlice<UInt8>) {
            guard bytes.count == Switch2BridgeInput.frameSize,
                  Switch2BridgeInput.littleEndian32(bytes, 0) == Switch2BridgeInput.magic else {
                return nil
            }
            buttons = Switch2BridgeInput.littleEndian32(bytes, 4)
            leftX = Int16(bitPattern: Switch2BridgeInput.littleEndian16(bytes, 8))
            leftY = Int16(bitPattern: Switch2BridgeInput.littleEndian16(bytes, 10))
            rightX = Int16(bitPattern: Switch2BridgeInput.littleEndian16(bytes, 12))
            rightY = Int16(bitPattern: Switch2BridgeInput.littleEndian16(bytes, 14))
            leftTrigger = bytes[bytes.startIndex + 16]
            rightTrigger = bytes[bytes.startIndex + 17]
            connected = bytes[bytes.startIndex + 18] != 0
        }
    }

    static func littleEndian16(_ bytes: ArraySlice<UInt8>, _ offset: Int) -> UInt16 {
        let i = bytes.startIndex + offset
        return UInt16(bytes[i]) | (UInt16(bytes[i + 1]) << 8)
    }

    static func littleEndian32(_ bytes: ArraySlice<UInt8>, _ offset: Int) -> UInt32 {
        let i = bytes.startIndex + offset
        return UInt32(bytes[i])
            | (UInt32(bytes[i + 1]) << 8)
            | (UInt32(bytes[i + 2]) << 16)
            | (UInt32(bytes[i + 3]) << 24)
    }

    // MARK: - Acumulador de tramas

    /// Recompone tramas de un flujo `SOCK_STREAM`: conserva una trama parcial, entrega varias
    /// concatenadas y declara inválido el flujo ante una magia incorrecta o un exceso de bytes.
    ///
    /// Decodifica sobre vistas (`ArraySlice`) del propio búfer y solo compacta de vez en cuando:
    /// no crea un `Array` por trama ni hace `removeFirst` por trama.
    struct Splitter {
        enum Outcome: Equatable {
            case frames([Frame])
            case invalid
        }

        private var buffer: [UInt8] = []
        private var start = 0

        var buffered: Int { buffer.count - start }

        mutating func reset() {
            buffer.removeAll(keepingCapacity: true)
            start = 0
        }

        mutating func feed(_ bytes: [UInt8]) -> Outcome {
            guard bytes.count <= Switch2BridgeInput.maxBuffered else {
                reset()
                return .invalid
            }
            compactIfNeeded()
            buffer.append(contentsOf: bytes)
            return drain()
        }

        /// Para el `read` del socket: añade solo los `count` bytes leídos del búfer reusable.
        mutating func feed(_ bytes: [UInt8], count: Int) -> Outcome {
            guard count <= Switch2BridgeInput.maxBuffered else {
                reset()
                return .invalid
            }
            compactIfNeeded()
            buffer.append(contentsOf: bytes[0..<count])
            return drain()
        }

        private mutating func compactIfNeeded() {
            guard start > 0, start == buffer.count || start >= Switch2BridgeInput.frameSize * 8 else { return }
            buffer.removeFirst(start)
            start = 0
        }

        private mutating func drain() -> Outcome {
            // Se decodifica ANTES de aplicar ningún tope: 19 B parciales + una lectura de 4096 B
            // contienen 205 tramas válidas y 15 B de la siguiente, y no deben rechazarse.
            var frames: [Frame] = []
            while buffered >= Switch2BridgeInput.frameSize {
                let end = start + Switch2BridgeInput.frameSize
                guard let frame = Frame(bytes: buffer[start..<end]) else {
                    reset()
                    return .invalid
                }
                frames.append(frame)
                start = end
            }
            if start == buffer.count {
                buffer.removeAll(keepingCapacity: true)
                start = 0
            }
            return .frames(frames)
        }
    }

    // MARK: - Mapeo a la ruta xbox360 del guest

    /// Máscara del puente → bits de `RemotePad`, por **posición física**: B abajo, A derecha,
    /// X arriba, Y izquierda. `read(RemotePad)` para xbox360 entrega el bit 0x4000 como
    /// `BTN.NORTH` (BTN_X, izquierda) y el 0x8000 como `BTN.WEST` (BTN_Y, arriba); por eso X
    /// (arriba) va a 0x8000 y Y (izquierda) a 0x4000. Home va a `MODE`; los sticks, a sus
    /// pulsaciones.
    ///
    /// El ABI **sí** lleva los bits de Captura (0x2000), C (0x4000), GR (0x01000000), GL
    /// (0x02000000) y SR/SL; lo que no los representa es la emulación xbox360/uinput del guest,
    /// que solo expone los 11 botones de `GuestPad.buttonCodes`. Se descartan a propósito, sin
    /// inventar funciones.
    static let buttonMap: [(mask: UInt32, bit: UInt32)] = [
        (0x0000_0004, 0x1000), // B (abajo) → SOUTH
        (0x0000_0008, 0x2000), // A (derecha) → EAST
        (0x0000_0002, 0x8000), // X (arriba) → WEST (BTN_Y, arriba)
        (0x0000_0001, 0x4000), // Y (izquierda) → NORTH (BTN_X, izquierda)
        (0x0040_0000, 0x0100), // L → TL
        (0x0000_0040, 0x0200), // R → TR
        (0x0000_0100, 0x0020), // − → SELECT
        (0x0000_0200, 0x0010), // + → START
        (0x0000_1000, 0x0400), // Home → MODE
        (0x0000_0800, 0x0040), // LStick → THUMBL
        (0x0000_0400, 0x0080), // RStick → THUMBR
        (0x0002_0000, 0x0001), // D-pad arriba
        (0x0001_0000, 0x0002), // D-pad abajo
        (0x0008_0000, 0x0004), // D-pad izquierda
        (0x0004_0000, 0x0008)  // D-pad derecha
    ]

    /// `nil` cuando el mando está desconectado: el llamador libera el pad.
    static func remotePad(from frame: Frame) -> GamepadBridge.RemotePad? {
        guard frame.connected else { return nil }
        var pad = GamepadBridge.RemotePad(number: padNumber)
        pad.kind = .xbox360
        pad.capabilities = 0 // sin canal de retorno: nada de rumble simulado
        pad.supportedButtons = 0xffff
        pad.buttons = buttonMap.reduce(into: UInt32(0)) { result, entry in
            if frame.buttons & entry.mask != 0 { result |= entry.bit }
        }
        pad.leftX = frame.leftX
        pad.leftY = negated(frame.leftY)
        pad.rightX = frame.rightX
        pad.rightY = negated(frame.rightY)
        pad.leftTrigger = frame.leftTrigger
        pad.rightTrigger = frame.rightTrigger
        pad.source = .switch2Bridge
        return pad
    }

    /// Estado de reposo que se envía al mando dormido o desconectado, sin retirar el pad del
    /// guest: suelta botones y centra los sticks sin recrear el dispositivo.
    static func neutralPad() -> GamepadBridge.RemotePad {
        var pad = GamepadBridge.RemotePad(number: padNumber)
        pad.kind = .xbox360
        pad.capabilities = 0
        pad.supportedButtons = 0xffff
        pad.source = .switch2Bridge
        return pad
    }

    /// La trama ya trae Y positiva hacia abajo; `read(RemotePad)` la vuelve a negar.
    static func negated(_ value: Int16) -> Int16 {
        value == Int16.min ? Int16.max : -value
    }

    // MARK: - Cliente del socket

    /// Cliente de solo lectura. Todo el trabajo de socket ocurre en una cola serial; el estado
    /// se entrega al hilo principal con fusión (solo la última trama pendiente), de modo que una
    /// UI ocupada no acumula bloques. Nunca escribe en el socket.
    final class Client {
        typealias Handler = (GamepadBridge.RemotePad?) -> Void

        private let path: String
        private let handler: Handler
        private let queue = DispatchQueue(label: "es.fxgam.steamac.switch2bridge")
        private let stateLock = NSLock()
        private var fd: Int32 = -1
        private var readSource: DispatchSourceRead?
        private var retryTimer: DispatchSourceTimer?
        private var watchdog: DispatchSourceTimer?
        private var splitter = Splitter()
        /// Búfer reusable de lectura: evita asignar 4 KiB por cada evento del socket.
        private var readBuffer = [UInt8](repeating: 0, count: 4096)
        private var stopped = false
        /// Se entrega un único `nil` al parar; ninguna muestra posterior puede adelantarlo.
        private var finished = false
        private var announcedPad = false
        private var lastByte = DispatchTime.now()
        private var pendingPad: GamepadBridge.RemotePad?
        private var padScheduled = false

        init(path: String = Switch2BridgeInput.defaultSocketPath, handler: @escaping Handler) {
            self.path = path
            self.handler = handler
        }

        func start() {
            queue.async { [weak self] in
                guard let self, !self.isStopped else { return }
                self.open()
                self.startWatchdog()
            }
        }

        /// Idempotente: marca la parada de forma síncrona, corta el socket en su cola y entrega
        /// exactamente un `nil` en el hilo principal. Una muestra que llegue después se descarta.
        func stop() {
            stateLock.lock()
            guard !stopped else {
                stateLock.unlock()
                return
            }
            stopped = true
            pendingPad = nil
            stateLock.unlock()
            queue.async { [weak self] in self?.shutdown() }
            DispatchQueue.main.async { [weak self] in self?.deliverFinal() }
        }

        private var isStopped: Bool {
            stateLock.lock()
            defer { stateLock.unlock() }
            return stopped
        }

        private func shutdown() {
            closeConnection()
            retryTimer?.cancel()
            retryTimer = nil
            watchdog?.cancel()
            watchdog = nil
            splitter.reset()
            announcedPad = false
        }

        deinit {
            readSource?.cancel()
            retryTimer?.cancel()
            watchdog?.cancel()
            if fd >= 0 { Darwin.close(fd) }
        }

        // MARK: Socket

        private func open() {
            guard !isStopped, fd < 0 else { return }
            let descriptor = socket(AF_UNIX, SOCK_STREAM, 0)
            guard descriptor >= 0 else {
                scheduleRetry()
                return
            }
            var one: Int32 = 1
            _ = setsockopt(descriptor, SOL_SOCKET, SO_NOSIGPIPE, &one, socklen_t(MemoryLayout<Int32>.size))

            var address = sockaddr_un()
            address.sun_family = sa_family_t(AF_UNIX)
            let pathBytes = Array(path.utf8)
            guard pathBytes.count < MemoryLayout.size(ofValue: address.sun_path) else {
                Darwin.close(descriptor)
                scheduleRetry()
                return
            }
            withUnsafeMutableBytes(of: &address.sun_path) { destination in
                destination.copyBytes(from: pathBytes)
            }
            let result = withUnsafePointer(to: &address) { pointer in
                pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                    connect(descriptor, $0, socklen_t(MemoryLayout<sockaddr_un>.size))
                }
            }
            guard result == 0 else {
                Darwin.close(descriptor)
                scheduleRetry()
                return
            }
            let flags = fcntl(descriptor, F_GETFL, 0)
            _ = fcntl(descriptor, F_SETFL, flags | O_NONBLOCK)

            fd = descriptor
            splitter.reset()
            lastByte = .now()
            retryTimer?.cancel()
            retryTimer = nil

            let source = DispatchSource.makeReadSource(fileDescriptor: descriptor, queue: queue)
            source.setEventHandler { [weak self] in self?.drain() }
            readSource = source
            source.resume()
            log("switch2bridge: connected to \(path)")
        }

        private func closeConnection() {
            readSource?.cancel()
            readSource = nil
            if fd >= 0 {
                Darwin.close(fd)
                fd = -1
            }
            splitter.reset()
        }

        private func lose() {
            closeConnection()
            announcedPad = false
            emit(nil)
            scheduleRetry()
        }

        private func scheduleRetry() {
            guard !isStopped, retryTimer == nil else { return }
            let timer = DispatchSource.makeTimerSource(queue: queue)
            timer.schedule(deadline: .now() + 2, repeating: 2, leeway: .milliseconds(200))
            timer.setEventHandler { [weak self] in self?.open() }
            retryTimer = timer
            timer.resume()
        }

        private func startWatchdog() {
            guard watchdog == nil else { return }
            let timer = DispatchSource.makeTimerSource(queue: queue)
            timer.schedule(deadline: .now() + 1, repeating: 1, leeway: .milliseconds(200))
            timer.setEventHandler { [weak self] in
                guard let self, self.fd >= 0 else { return }
                let elapsed = DispatchTime.now().uptimeNanoseconds &- self.lastByte.uptimeNanoseconds
                // El puente emite un latido cada segundo mientras no hay reportes: tres segundos
                // de silencio significan socket muerto o demonio detenido.
                if elapsed > 3_000_000_000 {
                    log("switch2bridge: no frames for 3 s, reconnecting")
                    self.lose()
                }
            }
            watchdog = timer
            timer.resume()
        }

        /// Lectura acotada: como mucho 16 lecturas de 4 KiB por evento, sin bloquear la cola.
        /// El búfer y el acumulador se reutilizan; no se crea un `Array` por trama.
        private func drain() {
            guard fd >= 0 else { return }
            for _ in 0..<16 {
                let count = readBuffer.withUnsafeMutableBytes { Darwin.read(fd, $0.baseAddress, $0.count) }
                if count > 0 {
                    lastByte = .now()
                    switch splitter.feed(readBuffer, count: count) {
                    case .frames(let frames):
                        for frame in frames { handle(frame) }
                    case .invalid:
                        log("switch2bridge: invalid frame, reconnecting")
                        lose()
                        return
                    }
                } else if count == 0 {
                    lose()
                    return
                } else if errno == EINTR {
                    continue
                } else if errno == EAGAIN || errno == EWOULDBLOCK {
                    break
                } else {
                    lose()
                    return
                }
            }
        }

        private func handle(_ frame: Frame) {
            if frame.connected {
                if let pad = Switch2BridgeInput.remotePad(from: frame) {
                    announcedPad = true
                    emit(pad)
                }
            } else if announcedPad {
                // El mando se durmió o se desconectó: suelta todo sin retirar el dispositivo.
                emit(Switch2BridgeInput.neutralPad())
            }
        }

        /// Fusión: solo la última trama pendiente llega al hilo principal. Después de `stop()`
        /// no se acepta ninguna muestra nueva.
        private func emit(_ pad: GamepadBridge.RemotePad?) {
            stateLock.lock()
            guard !stopped else {
                stateLock.unlock()
                return
            }
            pendingPad = pad
            let schedule = !padScheduled
            padScheduled = true
            stateLock.unlock()
            guard schedule else { return }
            DispatchQueue.main.async { [weak self] in self?.deliverPending() }
        }

        /// Solo pruebas: simula una muestra sin abrir socket.
        func emitForTesting(_ pad: GamepadBridge.RemotePad?) {
            emit(pad)
        }

        private func deliverPending() {
            stateLock.lock()
            guard !finished else {
                stateLock.unlock()
                return
            }
            let value = pendingPad
            pendingPad = nil
            padScheduled = false
            let stoppedNow = stopped
            if stoppedNow { finished = true }
            stateLock.unlock()
            handler(stoppedNow ? nil : value)
        }

        /// La parada entrega exactamente un `nil`, y siempre después de cualquier muestra en vuelo.
        private func deliverFinal() {
            stateLock.lock()
            guard !finished else {
                stateLock.unlock()
                return
            }
            finished = true
            pendingPad = nil
            padScheduled = false
            stateLock.unlock()
            handler(nil)
        }
    }

    // MARK: - Pruebas de comportamiento (--selftest-settings)

    /// Sin socket real: fixtures dorados, framing, mapeo, Y, rangos, desconexión y política de
    /// reparto. Los fixtures se escriben como bytes literales, independientes del decodificador.
    static func selfCheck() -> [String] {
        var failures: [String] = []
        var checks = 0
        func check(_ ok: Bool, _ name: String) {
            checks += 1
            if !ok { failures.append("Switch2Bridge input: \(name)") }
        }
        failures += GamepadBridge.keyframeSelfCheck()
        func bytes(buttons: UInt32 = 0, leftX: Int16 = 0, leftY: Int16 = 0,
                   rightX: Int16 = 0, rightY: Int16 = 0,
                   leftTrigger: UInt8 = 0, rightTrigger: UInt8 = 0,
                   connected: Bool = true) -> [UInt8] {
            var result = [UInt8](repeating: 0, count: Switch2BridgeInput.frameSize)
            result[0] = 0x31; result[1] = 0x50; result[2] = 0x32; result[3] = 0x53
            for i in 0..<4 {
                result[4 + i] = UInt8((buttons >> (8 * UInt32(i))) & 0xff)
            }
            func put(_ value: Int16, _ offset: Int) {
                let raw = UInt16(bitPattern: value)
                result[offset] = UInt8(raw & 0xff)
                result[offset + 1] = UInt8(raw >> 8)
            }
            put(leftX, 8); put(leftY, 10); put(rightX, 12); put(rightY, 14)
            result[16] = leftTrigger
            result[17] = rightTrigger
            result[18] = connected ? 1 : 0
            return result
        }

        // Trama real observada en el socket autorizado (spec L47).
        let golden: [UInt8] = [0x31, 0x50, 0x32, 0x53, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 1, 0]
        let idle = Frame(bytes: golden)
        check(idle != nil, "trama dorada de 20 bytes")
        check(idle?.connected == true, "trama dorada conectada")
        check(idle.flatMap { Switch2BridgeInput.remotePad(from: $0) } != nil, "trama dorada produce pad")
        check(idle.flatMap { Switch2BridgeInput.remotePad(from: $0) }?.buttons == 0, "trama dorada sin botones")

        // Endianness y rangos: los bytes se interpretan little-endian.
        let axes = Frame(bytes: bytes(leftX: 0x1234, leftY: -2, rightX: Int16.min, rightY: Int16.max,
                                      leftTrigger: 255, rightTrigger: 7))
        check(axes?.leftX == 0x1234, "eje X little-endian")
        check(axes?.leftY == -2, "eje Y little-endian con signo")
        check(axes?.rightX == Int16.min, "eje en el mínimo")
        check(axes?.rightY == Int16.max, "eje en el máximo")
        check(axes?.leftTrigger == 255 && axes?.rightTrigger == 7, "gatillos 0…255")

        // Visible para el consumidor: la posición física llega a evdev como BTN_WEST (arriba) y
        // BTN_NORTH (izquierda), igual que la ruta GameController del guest.
        if let x = Frame(bytes: bytes(buttons: 0x2)).flatMap({ Switch2BridgeInput.remotePad(from: $0) }) {
            let s = GamepadBridge.read(x, as: .xbox360, swapABXY: false, deadzone: 0)
            check(s.buttons[BTN.WEST] == true && s.buttons[BTN.NORTH] == false,
                  "X física (arriba) llega como BTN_WEST")
        } else {
            check(false, "X física construye el pad")
        }
        if let y = Frame(bytes: bytes(buttons: 0x1)).flatMap({ Switch2BridgeInput.remotePad(from: $0) }) {
            let s = GamepadBridge.read(y, as: .xbox360, swapABXY: false, deadzone: 0)
            check(s.buttons[BTN.NORTH] == true && s.buttons[BTN.WEST] == false,
                  "Y física (izquierda) llega como BTN_NORTH")
        } else {
            check(false, "Y física construye el pad")
        }
        if let b = Frame(bytes: bytes(buttons: 0x4)).flatMap({ Switch2BridgeInput.remotePad(from: $0) }) {
            let s = GamepadBridge.read(b, as: .xbox360, swapABXY: false, deadzone: 0)
            check(s.buttons[BTN.SOUTH] == true && s.buttons[BTN.EAST] == false,
                  "B física (abajo) llega como BTN_SOUTH")
        } else {
            check(false, "B física construye el pad")
        }
        let combined = Frame(bytes: bytes(buttons: 0x0000_000C)).flatMap { Switch2BridgeInput.remotePad(from: $0) }
        check(combined?.buttons == 0x3000, "B+A simultáneos")
        let dpad = Frame(bytes: bytes(buttons: 0x0006_0000)).flatMap { Switch2BridgeInput.remotePad(from: $0) }
        check(dpad?.buttons == 0x0009, "D-pad arriba+derecha")
        let unmapped: UInt32 = 0x0000_2000 | 0x0000_4000 | 0x0100_0000 | 0x0200_0000
        check(Frame(bytes: bytes(buttons: unmapped)).flatMap { Switch2BridgeInput.remotePad(from: $0) }?.buttons == 0,
              "Captura/C/GR/GL no se inventan")

        // Y: una sola inversión y sin desbordar en Int16.min.
        let down = Frame(bytes: bytes(leftY: 1000)).flatMap { Switch2BridgeInput.remotePad(from: $0) }
        check(down?.leftY == -1000, "Y se invierte al construir el RemotePad")
        if let down {
            let state = GamepadBridge.read(down, as: .xbox360, swapABXY: false, deadzone: 0)
            if let y = state.axes[ABS.Y] {
                check(abs(Int(y) - 1000) <= 1, "Y hacia abajo llega hacia abajo a evdev")
            } else {
                check(false, "Y presente en el estado")
            }
        } else {
            check(false, "Y construye el pad")
        }
        let extreme = Frame(bytes: bytes(leftY: Int16.min)).flatMap { Switch2BridgeInput.remotePad(from: $0) }
        check(extreme?.leftY == Int16.max, "Int16.min se satura a max")
        if let extreme {
            let state = GamepadBridge.read(extreme, as: .xbox360, swapABXY: false, deadzone: 0)
            check(state.axes[ABS.Y] == -32767, "eje extremo sin desbordar")
        } else {
            check(false, "eje extremo construye el pad")
        }

        // Contrato del pad: sin rumble, sin botones fuera de máscara, fuente identificable.
        let contractPad = Frame(bytes: bytes(leftTrigger: 255)).flatMap { Switch2BridgeInput.remotePad(from: $0) }
        if let pad = contractPad {
            check(pad.capabilities == 0, "sin canal de retorno para vibración")
            check(pad.supportedButtons == 0xffff, "máscara de botones soportados")
            check(pad.source == .switch2Bridge, "origen Switch2Bridge")
            check(pad.kind == .xbox360, "identidad xbox360 del guest")
        } else {
            check(false, "contrato del pad")
        }
        check(neutralPad().buttons == 0 && neutralPad().leftX == 0 && neutralPad().leftTrigger == 0,
              "pad neutro al desconectar")
        check(Frame(bytes: bytes(connected: false)).flatMap { Switch2BridgeInput.remotePad(from: $0) } == nil,
              "desconectado no crea pad")

        // Framing: parcial, concatenado, magia inválida y tope del acumulador.
        var partial = Splitter()
        check(partial.feed(Array(golden[0..<7])) == .frames([]), "trama parcial espera")
        check(partial.buffered == 7, "trama parcial conservada")
        check(partial.feed(Array(golden[7...])) == .frames([idle!]), "trama parcial completada")
        var concatenated = Splitter()
        check(concatenated.feed(golden + golden) == .frames([idle!, idle!]), "dos tramas concatenadas")
        var many = Splitter()
        var stream: [UInt8] = []
        stream.reserveCapacity(golden.count * 200)
        for _ in 0..<200 { stream.append(contentsOf: golden) }
        if case .frames(let decoded) = many.feed(stream) {
            check(decoded.count == 200 && many.buffered == 0, "200 tramas sin crecer")
        } else {
            check(false, "200 tramas válidas")
        }
        var counted = Splitter()
        if case .frames(let only) = counted.feed(golden + golden, count: golden.count) {
            check(only.count == 1 && counted.buffered == 0, "feed(count:) no consume el resto")
        } else {
            check(false, "feed(count:) válido")
        }
        // Regresión real del límite: 19 B parciales + una lectura completa de 4096 B son un
        // flujo válido (205 tramas y 15 B de la siguiente), no un cierre espurio.
        var fragmented = Splitter()
        check(fragmented.feed(Array(golden[0..<19])) == .frames([]), "parcial de 19 B espera")
        var chunk: [UInt8] = [golden[19]]
        for _ in 0..<204 { chunk.append(contentsOf: golden) }
        chunk.append(contentsOf: golden[0..<15])
        check(chunk.count == 4096, "lectura de 4096 B exacta")
        if case .frames(let decoded) = fragmented.feed(chunk) {
            check(decoded.count == 205 && fragmented.buffered == 15, "19 B + 4096 B válidos")
        } else {
            check(false, "19 B + 4096 B válidos")
        }
        var invalid = Splitter()
        var badMagic = golden
        badMagic[0] = 0
        check(invalid.feed(badMagic) == .invalid, "magia inválida invalida el flujo")
        var bounded = Splitter()
        check(bounded.feed([UInt8](repeating: 0, count: Switch2BridgeInput.maxBuffered + 1)) == .invalid,
              "acumulador acotado")

        // Reparto: la fuente cede ante GameController, Moonlight y HID; nunca los desplaza.
        check(GamepadBridge.bridgePlayerIndex(hasPad: true, usable: [true, true, true, true],
                                         controllers: [false, false, false, false],
                                         remote: [], rawHID: []) == 0, "jugador 1 libre")
        check(GamepadBridge.bridgePlayerIndex(hasPad: true, usable: [true, true, true, true],
                                         controllers: [true, false, false, false],
                                         remote: [], rawHID: []) == 1, "cede ante GameController")
        check(GamepadBridge.bridgePlayerIndex(hasPad: true, usable: [true, true, true, true],
                                         controllers: [false, false, false, false],
                                         remote: [0], rawHID: []) == 1, "cede ante Moonlight")
        check(GamepadBridge.bridgePlayerIndex(hasPad: true, usable: [true, true, true, true],
                                         controllers: [false, false, false, false],
                                         remote: [], rawHID: [0]) == 1, "cede ante HID")
        // Prioridad real: un HID genérico reserva el 0 y la fuente local debe tomar el 1.
        let hidReservations = SteamControllerRouting.rawPlayers(previous: [:], devices: [10], available: [0, 1],
                                                                genericDevices: [10], hidCapable: [0, 1])
        check(hidReservations == [10: 0], "HID genérico reserva el jugador 0")
        check(GamepadBridge.bridgePlayerIndex(hasPad: true, usable: [true, true],
                                              controllers: [false, false], remote: [],
                                              rawHID: Set(hidReservations.values)) == 1,
              "bridge cede el 0 al HID")
        check(GamepadBridge.bridgePlayerIndex(hasPad: true, usable: [true, false, false, false],
                                         controllers: [true, false, false, false],
                                         remote: [], rawHID: []) == nil, "sin jugador libre")
        check(GamepadBridge.bridgePlayerIndex(hasPad: false, usable: [true, true, true, true],
                                         controllers: [false, false, false, false],
                                         remote: [], rawHID: []) == nil, "sin pad no reserva")
        check(GamepadBridge.bridgePlayerIndex(hasPad: true, usable: [true, true, true, true],
                                         controllers: [false, false, false, false],
                                         remote: [0, 1, 2], rawHID: [3]) == nil, "los cuatro ocupados")
        check(GamepadBridge.bridgeSuppressed(devices: [(0x057E, 0x2069)]), "mismo mando ya en HID")
        check(!GamepadBridge.bridgeSuppressed(devices: [(0x054C, 0x0CE6)]), "otro HID no suprime")
        check(!GamepadBridge.bridgeSuppressed(devices: []), "sin HID no suprime")

        log("selftest-settings: Switch2Bridge input: \(checks) checks, "
            + "\(failures.isEmpty ? "PASS" : failures.joined(separator: "; "))")
        return failures
    }

    /// Smoke real del cliente sobre un socket Unix temporal: servidor POSIX propio, una trama
    /// conectada, cierre del servidor (desconexión) y parada del cliente. No usa el socket del
    /// usuario, CoreBluetooth, USB ni Wine; limpia únicamente su directorio temporal.
    static func socketSelfCheck() -> [String] {
        var failures: [String] = []
        let directory = "/tmp/steamac-s2p1-\(UUID().uuidString.prefix(8))"
        let socketPath = directory + "/estado.sock"
        guard socketPath.utf8.count < 104 else {
            return ["Switch2Bridge socket: ruta temporal demasiado larga"]
        }
        do {
            try FileManager.default.createDirectory(atPath: directory, withIntermediateDirectories: true)
            _ = chmod(directory, 0o700)
        } catch {
            return ["Switch2Bridge socket: no se pudo crear el directorio temporal: \(error)"]
        }
        defer { try? FileManager.default.removeItem(atPath: directory) }
        var directoryInfo = stat()
        if stat(directory, &directoryInfo) != 0 || (directoryInfo.st_mode & 0o777) != 0o700 {
            return ["Switch2Bridge socket: el directorio temporal no es privado 0700"]
        }

        let listener = socket(AF_UNIX, SOCK_STREAM, 0)
        guard listener >= 0 else { return ["Switch2Bridge socket: no se pudo crear el listener"] }
        var address = sockaddr_un()
        address.sun_family = sa_family_t(AF_UNIX)
        let pathBytes = Array(socketPath.utf8)
        withUnsafeMutableBytes(of: &address.sun_path) { $0.copyBytes(from: pathBytes) }
        let bound = withUnsafePointer(to: &address) { pointer in
            pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                Darwin.bind(listener, $0, socklen_t(MemoryLayout<sockaddr_un>.size))
            }
        }
        guard bound == 0, listen(listener, 1) == 0 else {
            close(listener)
            unlink(socketPath)
            return ["Switch2Bridge socket: no se pudo abrir el listener temporal"]
        }

        let group = DispatchGroup()
        group.enter()
        Thread {
            func acceptAndSend(_ timeoutMs: Int32, buttons: UInt32) {
                var descriptor = pollfd(fd: listener, events: Int16(POLLIN), revents: 0)
                guard poll(&descriptor, 1, timeoutMs) > 0 else { return }
                let accepted = accept(listener, nil, nil)
                guard accepted >= 0 else { return }
                var frame = [UInt8](repeating: 0, count: Switch2BridgeInput.frameSize)
                frame[0] = 0x31; frame[1] = 0x50; frame[2] = 0x32; frame[3] = 0x53
                for i in 0..<4 { frame[4 + i] = UInt8((buttons >> (8 * UInt32(i))) & 0xff) }
                frame[18] = 1
                _ = frame.withUnsafeBytes { send(accepted, $0.baseAddress, $0.count, 0) }
                usleep(150_000)
                close(accepted)
            }
            acceptAndSend(2_000, buttons: 0)
            // El cliente reintenta cada 2 s: el mismo listener debe seguir vivo para probar
            // la reconexión, no sólo la desconexión.
            acceptAndSend(3_000, buttons: 0x0000_0008)
            close(listener)
            unlink(socketPath)
            group.leave()
        }.start()

        var values: [GamepadBridge.RemotePad?] = []
        let client = Client(path: socketPath) { values.append($0) }
        client.start()
        let deadline = Date().addingTimeInterval(4.5)
        while Date() < deadline && values.count < 4 {
            RunLoop.main.run(until: Date().addingTimeInterval(0.02))
        }
        // La secuencia observable completa antes de parar: inicial, desconexión, reconexión
        // con A (0x8 del ABI) y desconexión final. 0x2000 (BTN_EAST) es un valor independiente,
        // no se deriva de `buttonMap`.
        let sequence = values
        client.stop()
        _ = group.wait(timeout: .now() + 1)
        if sequence.count != 4 {
            failures.append("Switch2Bridge socket: secuencia esperada de 4 callbacks, obtenidos \(sequence.count)")
        } else {
            if sequence[0]?.buttons != 0 || sequence[0]?.source != .switch2Bridge {
                failures.append("Switch2Bridge socket: primera muestra conectada inesperada")
            }
            if sequence[1] != nil {
                failures.append("Switch2Bridge socket: falta el nil de la primera desconexión")
            }
            if sequence[2]?.buttons != 0x2000 || sequence[2]?.source != .switch2Bridge {
                failures.append("Switch2Bridge socket: A del ABI no llegó como EAST 0x2000")
            }
            if sequence[3] != nil {
                failures.append("Switch2Bridge socket: falta el nil de la desconexión final")
            }
        }
        log("selftest-settings: Switch2Bridge socket real: secuencia \(sequence.count) callbacks, "
            + "\(failures.isEmpty ? "PASS" : "FAIL")")
        return failures
    }

    /// Sin socket ni mocks: el handler real recibe una muestra antes de parar, exactamente un
    /// `nil` al parar (aunque `stop()` se llame dos veces) y ninguna muestra después.
    static func lifecycleSelfCheck() -> [String] {
        var failures: [String] = []
        var values: [GamepadBridge.RemotePad?] = []
        let client = Client(path: "/nonexistent/switch2bridge-lifecycle.sock") { values.append($0) }
        let sample = neutralPad()
        client.emitForTesting(sample)
        RunLoop.main.run(until: Date().addingTimeInterval(0.2))
        if values.count != 1 || values[0]?.source != .switch2Bridge {
            failures.append("Switch2Bridge lifecycle: no entregó la muestra previa")
        }
        client.stop()
        client.stop()
        RunLoop.main.run(until: Date().addingTimeInterval(0.3))
        if values.count != 2 || values[1] != nil {
            failures.append("Switch2Bridge lifecycle: stop debe entregar exactamente un nil")
        }
        client.emitForTesting(sample)
        RunLoop.main.run(until: Date().addingTimeInterval(0.2))
        if values.count != 2 {
            failures.append("Switch2Bridge lifecycle: entregó una muestra después de stop")
        }
        log("selftest-settings: Switch2Bridge lifecycle: \(values.count) callbacks, "
            + "\(failures.isEmpty ? "PASS" : failures.joined(separator: "; "))")
        return failures
    }
}
