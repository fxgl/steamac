import CoreHaptics
import Foundation
import GameController

/// The guest pad's rumble (`rumble <strong> <weak>` on fx.pad: what SDL and Steam asked the
/// guest's FF_RUMBLE device for) on the driving controller's actuators through GameController's
/// haptics (Core Haptics): the strong (low-frequency) motor on the left handle and the weak
/// (high-frequency) one on the right, as an Xbox pad's motors sit; a controller without separate
/// handles gets the stronger of the two everywhere. Silent while the VM is paused. Main thread.
final class Rumble {
    private var controller: GCController?
    /// [left, right], [all] or [] (nothing created yet / no haptics).
    private var motors: [Motor] = []
    /// The guest's last rumble (strong, weak), 0…65535.
    private(set) var level: (strong: UInt16, weak: UInt16) = (0, 0)
    private var reportedNoHaptics = false
    var paused = false {
        didSet { if paused != oldValue { play() } }
    }

    /// The controller that gets the rumble from now on (nil: none).
    func attach(_ c: GCController?) {
        guard c !== controller else { return }
        for m in motors { m.stop() }
        motors = []
        reportedNoHaptics = false
        controller = c
        play()
    }

    /// The guest's combined rumble, 0…65535 per motor.
    func set(strong: UInt16, weak: UInt16) {
        guard strong != level.strong || weak != level.weak else { return }
        level = (strong, weak)
        play()
    }

    private func play() {
        let strong = paused ? 0 : Float(level.strong) / 65535
        let weak = paused ? 0 : Float(level.weak) / 65535
        if motors.isEmpty && (strong > 0 || weak > 0) { makeMotors() }
        switch motors.count {
        case 2: motors[0].play(strong); motors[1].play(weak)
        case 1: motors[0].play(max(strong, weak))
        default: break
        }
    }

    private func makeMotors() {
        guard let c = controller else { return }
        guard let haptics = c.haptics else {
            if !reportedNoHaptics {
                log("gamepad: \(GamepadBridge.logDisplayName(of: c)) has no haptics: rumble is not played")
                reportedNoHaptics = true
            }
            return
        }
        let localities = haptics.supportedLocalities
        // Low sharpness for the strong motor, high for the weak one.
        let plan: [(GCHapticsLocality, Float)] = localities.contains(.leftHandle) && localities.contains(.rightHandle)
            ? [(.leftHandle, 0.2), (.rightHandle, 0.8)] : [(.default, 0.5)]
        motors = plan.compactMap { locality, sharpness in
            haptics.createEngine(withLocality: locality).map { Motor(engine: $0, sharpness: sharpness, name: locality.rawValue) }
        }
        log("gamepad: rumble on \(GamepadBridge.logDisplayName(of: c)) (\(plan.map(\.0.rawValue).joined(separator: ", ")))"
            + (motors.count == plan.count ? "" : ": no haptic engine"))
    }
}

/// One actuator group: a looping continuous event whose intensity follows the guest.
private final class Motor {
    private let engine: CHHapticEngine
    private let sharpness: Float
    private let name: String
    private var player: CHHapticAdvancedPatternPlayer?
    private var engineRunning = false
    private var playing = false
    private var reportedError = false

    init(engine: CHHapticEngine, sharpness: Float, name: String) {
        self.engine = engine
        self.sharpness = sharpness
        self.name = name
        // The engine stops on its own (app in the background, idle, controller gone): start over.
        let reset: () -> Void = { [weak self] in
            DispatchQueue.main.async {
                self?.player = nil
                self?.engineRunning = false
                self?.playing = false
            }
        }
        engine.stoppedHandler = { _ in reset() }
        engine.resetHandler = reset
    }

    /// 0…1; 0 stops.
    func play(_ intensity: Float) {
        do {
            guard intensity > 0 else {
                if playing { try player?.stop(atTime: CHHapticTimeImmediate) }
                playing = false
                return
            }
            if !engineRunning {
                try engine.start()
                engineRunning = true
            }
            if player == nil {
                let event = CHHapticEvent(eventType: .hapticContinuous, parameters: [
                    CHHapticEventParameter(parameterID: .hapticIntensity, value: 1),
                    CHHapticEventParameter(parameterID: .hapticSharpness, value: sharpness),
                ], relativeTime: 0, duration: 30)
                let p = try engine.makeAdvancedPlayer(with: CHHapticPattern(events: [event], parameters: []))
                p.loopEnabled = true
                p.loopEnd = 30
                player = p
            }
            let control = [CHHapticDynamicParameter(parameterID: .hapticIntensityControl, value: intensity, relativeTime: 0)]
            try player?.sendParameters(control, atTime: CHHapticTimeImmediate)
            if !playing {
                try player?.start(atTime: CHHapticTimeImmediate)
                try player?.sendParameters(control, atTime: CHHapticTimeImmediate)
                playing = true
            }
        } catch {
            if !reportedError {
                log("gamepad: rumble (\(name)): \(error.localizedDescription)")
                reportedError = true
            }
            player = nil
            engineRunning = false
            playing = false
        }
    }

    func stop() {
        if playing { try? player?.stop(atTime: CHHapticTimeImmediate) }
        engine.stop(completionHandler: nil)
    }
}
