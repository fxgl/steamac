import AppKit
import Combine
import CoreAudio
import Darwin
import Foundation

/// Runtime audio controls of libkrun's virtio-snd CoreAudio backend (krun_snd_set_output_device,
/// krun_snd_set_volume, krun_snd_set_buffer_ms). Looked up with dlsym: an older libkrun without
/// them still boots, and the Sound settings explain why they are disabled.
///
/// Volume sent to libkrun: gain = the user's volume, mute = user mute || (Settings > General
/// "Mute sound in the background" && the app is not active). Background transitions fade over
/// ~150 ms (5 gain steps). STEAMAC_SND_TRACE=1 logs every krun_snd_set_volume call.
final class SoundControl {
    private typealias SetOutput = @convention(c) (UInt32, UnsafePointer<CChar>?) -> Int32
    private typealias SetVolumeC = @convention(c) (UInt32, Float, Bool) -> Int32
    private typealias SetBuffer = @convention(c) (UInt32, UInt32) -> Int32
    typealias SetVolume = (UInt32, Float, Bool) -> Int32

    private let setOutput: SetOutput?
    private let setVolume: SetVolume?
    private let setBuffer: SetBuffer?
    /// The running VM's context; nil until attached (or when the VM has no virtio-snd).
    private(set) var ctx: UInt32?
    /// Why this boot has no sound device (shown in Settings), nil if it has one.
    private(set) var noDeviceReason: String?

    private var volume = 1.0
    private var userMute = false
    private var muteInBackground = true
    private var appActive = true
    /// Last (gain, mute) sent to libkrun.
    private var applied: (gain: Float, mute: Bool)?
    /// Bumped to cancel a running fade.
    private var fadeGeneration = 0
    private var activationObservers: [NSObjectProtocol] = []
    static let trace = ProcessInfo.processInfo.environment["STEAMAC_SND_TRACE"].map { !$0.isEmpty && $0 != "0" } ?? false
    static let fadeSteps = 5
    static let fadeDuration = 0.15

    /// `volumeShim` replaces krun_snd_set_volume (selftest).
    init(volumeShim: SetVolume? = nil) {
        func sym<T>(_ name: String, _: T.Type) -> T? {
            dlsym(UnsafeMutableRawPointer(bitPattern: -2), name).map { unsafeBitCast($0, to: T.self) }   // RTLD_DEFAULT
        }
        setOutput = sym("krun_snd_set_output_device", SetOutput.self)
        if let volumeShim {
            setVolume = volumeShim
        } else if let f = sym("krun_snd_set_volume", SetVolumeC.self) {
            setVolume = { f($0, $1, $2) }
        } else {
            setVolume = nil
        }
        setBuffer = sym("krun_snd_set_buffer_ms", SetBuffer.self)
    }

    var canSelectDevice: Bool { setOutput != nil }
    var canSetVolume: Bool { setVolume != nil }
    var canSetBuffer: Bool { setBuffer != nil }

    private var missingAPIs: [String] {
        [("krun_snd_set_output_device", canSelectDevice), ("krun_snd_set_volume", canSetVolume),
         ("krun_snd_set_buffer_ms", canSetBuffer)].filter { !$0.1 }.map(\.0)
    }

    /// English diagnostic for the boot log.
    var missingAPILogReason: String? {
        let missing = missingAPIs
        guard !missing.isEmpty else { return nil }
        return "The installed libkrun has no \(missing.joined(separator: ", ")) (rebuild host/libkrun and reinstall the launcher)."
    }

    /// Why live controls are unavailable in this libkrun (nil = all present).
    var missingAPIReason: String? {
        let missing = missingAPIs
        guard !missing.isEmpty else { return nil }
        return String(localized: "The installed libkrun has no \(missing.joined(separator: ", ")) (rebuild host/libkrun and reinstall the launcher).")
    }
    private var subscriptions: [AnyCancellable] = []

    /// Before krun_start_enter: apply the saved output device, volume and buffer, then follow the
    /// Settings window and the app's activation ("applies now").
    func attach(ctx: UInt32, settings: LauncherSettings) {
        attach(ctx: ctx, volume: settings.soundVolume, mute: settings.soundMute, muteInBackground: settings.muteInBackground)
        apply(outputUID: settings.soundOutputUID)
        apply(latency: settings.soundLatency)
        // @Published emits the new value before it is stored: use the emitted values.
        subscriptions = [
            settings.$soundOutputUID.dropFirst().removeDuplicates().sink { [weak self] in self?.apply(outputUID: $0) },
            settings.$soundVolume.combineLatest(settings.$soundMute).dropFirst()
                .debounce(for: .milliseconds(50), scheduler: DispatchQueue.main)
                .sink { [weak self] v, m in self?.setUser(volume: v, mute: m) },
            settings.$muteInBackground.dropFirst().removeDuplicates().sink { [weak self] in self?.setMuteInBackground($0) },
            settings.$soundLatency.dropFirst().removeDuplicates().sink { [weak self] in self?.apply(latency: $0) },
        ]
    }

    /// Volume state + activation observers (no Settings model: the selftest drives it directly).
    func attach(ctx: UInt32, volume: Double, mute: Bool, muteInBackground: Bool) {
        self.ctx = ctx
        noDeviceReason = nil
        self.volume = volume
        userMute = mute
        self.muteInBackground = muteInBackground
        applied = nil
        let nc = NotificationCenter.default
        activationObservers.forEach(nc.removeObserver)
        activationObservers = [
            nc.addObserver(forName: NSApplication.didResignActiveNotification, object: nil, queue: .main) { [weak self] _ in
                self?.setAppActive(false)
            },
            nc.addObserver(forName: NSApplication.didBecomeActiveNotification, object: nil, queue: .main) { [weak self] _ in
                self?.setAppActive(true)
            },
        ]
        log("sound: volume \(Int((volume * 100).rounded()))%\(mute ? " (muted)" : "")"
            + (muteInBackground ? ", muted while in the background" : ""))
        push(fade: false)
    }

    func detach(reason: LocalizedStringResource) {
        ctx = nil
        noDeviceReason = String(localized: reason)
    }

    func apply(outputUID: String) {
        guard let ctx, let setOutput else { return }
        let r = outputUID.isEmpty ? setOutput(ctx, nil) : outputUID.withCString { setOutput(ctx, $0) }
        report("output device \(outputUID.isEmpty ? "system default" : outputUID)", r)
    }

    func setUser(volume: Double, mute: Bool) {
        self.volume = volume
        userMute = mute
        log("sound: volume \(Int((volume * 100).rounded()))%\(mute ? " (muted)" : "")")
        push(fade: false)
    }

    func setMuteInBackground(_ on: Bool) {
        let was = backgroundMuted
        muteInBackground = on
        noteBackground(was)
        push(fade: true)
    }

    func setAppActive(_ active: Bool) {
        guard active != appActive else { return }
        let was = backgroundMuted
        appActive = active
        noteBackground(was)
        push(fade: true)
    }

    /// Muted only because the app is in the background.
    var backgroundMuted: Bool { muteInBackground && !appActive && !userMute }

    private func noteBackground(_ was: Bool) {
        if ctx != nil, backgroundMuted != was { log("sound: background mute \(backgroundMuted ? "on" : "off")") }
    }

    /// Send the effective (gain, mute); fade when only the mute state flips and `fade` is set.
    private func push(fade: Bool) {
        guard ctx != nil, setVolume != nil else { return }
        fadeGeneration += 1
        let gain = Float(max(0, min(1, volume)))
        let mute = userMute || (muteInBackground && !appActive)
        guard let prev = applied else { return send(gain, mute) }
        if prev.gain == gain && prev.mute == mute { return }
        guard fade, prev.mute != mute, gain > 0 else { return send(gain, mute) }
        let generation = fadeGeneration
        let n = SoundControl.fadeSteps
        let step = SoundControl.fadeDuration / Double(n)
        if mute {
            // Ramp down from the current gain, then mute (gain stays the user's volume).
            let from = prev.gain
            for i in 1...n {
                DispatchQueue.main.asyncAfter(deadline: .now() + step * Double(i)) { [weak self] in
                    guard let self, self.fadeGeneration == generation else { return }
                    if i < n { self.send(from * Float(n - i) / Float(n), false) } else { self.send(gain, true) }
                }
            }
        } else {
            send(0, false)
            for i in 1...n {
                DispatchQueue.main.asyncAfter(deadline: .now() + step * Double(i)) { [weak self] in
                    guard let self, self.fadeGeneration == generation else { return }
                    self.send(gain * Float(i) / Float(n), false)
                }
            }
        }
    }

    private func send(_ gain: Float, _ mute: Bool) {
        guard let ctx, let setVolume else { return }
        let r = setVolume(ctx, gain, mute)
        applied = (gain, mute)
        if SoundControl.trace {
            log("sound: krun_snd_set_volume(gain=\(String(format: "%.2f", gain)), mute=\(mute)) = \(r)")
        } else if r != 0 {
            log("sound: krun_snd_set_volume failed: \(r) (\(String(cString: strerror(-r))))")
        }
    }

    func apply(latency: LauncherSettings.Latency) {
        guard let ctx, let setBuffer else { return }
        report("buffer \(latency.bufferMs) ms (\(latency.rawValue))", setBuffer(ctx, latency.bufferMs))
    }

    private func report(_ what: String, _ r: Int32) {
        if r == 0 { log("sound: \(what)") }
        else { log("sound: \(what) failed: \(r) (\(String(cString: strerror(-r))))") }
    }
}

/// CoreAudio output devices (for the Sound settings).
enum AudioDevices {
    struct Device: Identifiable, Hashable {
        let uid: String
        let name: String
        var id: String { uid }
    }

    static func outputs() -> [Device] {
        var addr = AudioObjectPropertyAddress(mSelector: kAudioHardwarePropertyDevices,
                                              mScope: kAudioObjectPropertyScopeGlobal, mElement: kAudioObjectPropertyElementMain)
        var size: UInt32 = 0
        guard AudioObjectGetPropertyDataSize(AudioObjectID(kAudioObjectSystemObject), &addr, 0, nil, &size) == noErr else { return [] }
        var ids = [AudioObjectID](repeating: 0, count: Int(size) / MemoryLayout<AudioObjectID>.size)
        guard AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject), &addr, 0, nil, &size, &ids) == noErr else { return [] }
        return ids.compactMap { id in
            guard hasOutput(id), let uid = string(id, kAudioDevicePropertyDeviceUID),
                  let name = string(id, kAudioObjectPropertyName) else { return nil }
            return Device(uid: uid, name: name)
        }
    }

    /// Name of the current system default output device.
    static func defaultOutputName() -> String? {
        var addr = AudioObjectPropertyAddress(mSelector: kAudioHardwarePropertyDefaultOutputDevice,
                                              mScope: kAudioObjectPropertyScopeGlobal, mElement: kAudioObjectPropertyElementMain)
        var id = AudioObjectID(0)
        var size = UInt32(MemoryLayout<AudioObjectID>.size)
        guard AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject), &addr, 0, nil, &size, &id) == noErr else { return nil }
        return string(id, kAudioObjectPropertyName)
    }

    private static func hasOutput(_ id: AudioObjectID) -> Bool {
        var addr = AudioObjectPropertyAddress(mSelector: kAudioDevicePropertyStreams,
                                              mScope: kAudioObjectPropertyScopeOutput, mElement: kAudioObjectPropertyElementMain)
        var size: UInt32 = 0
        return AudioObjectGetPropertyDataSize(id, &addr, 0, nil, &size) == noErr && size > 0
    }

    private static func string(_ id: AudioObjectID, _ selector: AudioObjectPropertySelector) -> String? {
        var addr = AudioObjectPropertyAddress(mSelector: selector, mScope: kAudioObjectPropertyScopeGlobal,
                                              mElement: kAudioObjectPropertyElementMain)
        var value: Unmanaged<CFString>?
        var size = UInt32(MemoryLayout<Unmanaged<CFString>?>.size)
        guard AudioObjectGetPropertyData(id, &addr, 0, nil, &size, &value) == noErr, let v = value else { return nil }
        return v.takeRetainedValue() as String
    }
}
