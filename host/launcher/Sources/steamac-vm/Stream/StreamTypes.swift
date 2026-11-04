// Moonlight (GameStream) host: what the HTTP/pairing, RTSP/session, control, input, video and audio
// parts of Stream/ share. Settings > Streaming turns the host on; it runs in the VM process (frames,
// guest audio and input devices live there) and listens only while enabled.
import CoreMedia
import CoreVideo
import Foundation
import VideoToolbox

/// The standard GameStream ports (Moonlight has no way to ask for others on a LAN host).
enum StreamPorts {
    static let http: UInt16 = 47989
    static let https: UInt16 = 47984
    static let rtsp: UInt16 = 48010
    static let video: UInt16 = 47998
    static let control: UInt16 = 47999
    static let audio: UInt16 = 48000
}

struct StreamError: Error, CustomStringConvertible {
    let description: String
    init(_ description: String) { self.description = description }
}

/// One paired Moonlight client. Settings > Streaming lists them; revoking removes the entry, after
/// which the client's certificate no longer opens the HTTPS endpoints.
struct StreamClient: Codable, Equatable, Identifiable {
    var id: String { fingerprint }
    /// Lowercase hex SHA-256 of the client certificate (DER).
    let fingerprint: String
    /// The device name Moonlight sent while pairing ("devicename"; "roth" when it sent none).
    var name: String
    /// The client certificate, DER.
    let certificate: Data
    let pairedAt: Date
}

/// A pairing attempt waiting for the PIN Moonlight shows. Exactly one of `submit`/`cancel` takes
/// effect; later calls are ignored. Either may be called from any thread.
final class StreamPairingRequest: Identifiable {
    let id = UUID()
    let clientName: String
    private let lock = NSLock()
    private var answer: ((String?) -> Void)?

    init(clientName: String, answer: @escaping (String?) -> Void) {
        self.clientName = clientName
        self.answer = answer
    }

    /// The 4-digit PIN entered on the Mac.
    func submit(pin: String) { take()?(pin) }
    func cancel() { take()?(nil) }

    private func take() -> ((String?) -> Void)? {
        lock.lock()
        defer { lock.unlock() }
        let a = answer
        answer = nil
        return a
    }
}

/// A paired client's /launch or /resume (HTTPS, client certificate checked).
struct StreamLaunch {
    let client: StreamClient
    /// The client's IP address as seen by the HTTPS connection; the RTSP, video, audio and control
    /// streams only accept this address.
    let clientAddress: String
    let appID: Int
    /// mode=WxHxFPS
    let width: Int
    let height: Int
    let fps: Int
    /// rikey: AES-128 key for the encrypted control stream (and audio when encrypted).
    let aesKey: Data
    /// rikeyid: seeds the audio stream's AES-CBC IVs.
    let aesKeyID: UInt32
    /// localAudioPlayMode=1: keep playing the guest's sound on the Mac while streaming.
    let playAudioOnHost: Bool
    /// surroundAudioInfo: channel count in the low 16 bits, channel mask in the high 16 bits.
    let surroundAudioInfo: UInt32
    /// remoteControllersBitmap: the client's attached controllers when it launched.
    let remoteControllersBitmap: UInt16
    /// true for /resume.
    let resume: Bool
}

enum StreamCodec: String, Equatable {
    case h264, hevc

    /// The codecs this Mac encodes in hardware (serverinfo ServerCodecModeSupport, RTSP DESCRIBE).
    static let hardwareSupported: [StreamCodec] = {
        var list: CFArray?
        guard VTCopyVideoEncoderList(nil, &list) == noErr, let encoders = list as? [[String: Any]] else { return [.h264] }
        func hardware(_ type: CMVideoCodecType) -> Bool {
            encoders.contains {
                ($0[kVTVideoEncoderList_CodecType as String] as? NSNumber)?.uint32Value == type
                    && ($0[kVTVideoEncoderList_IsHardwareAccelerated as String] as? Bool) == true
            }
        }
        var codecs: [StreamCodec] = [.h264]
        if hardware(kCMVideoCodecType_HEVC) { codecs.append(.hevc) }
        return codecs
    }()
}

/// The video stream the client asked for in RTSP ANNOUNCE.
struct StreamVideoConfig: Equatable {
    var width: Int
    var height: Int
    var fps: Int
    var bitrateKbps: Int
    /// Payload bytes per video packet (x-nv-video[0].packetSize).
    var packetSize: Int
    /// x-nv-vqos[0].fec.minRequiredFecPackets
    var minRequiredFecPackets: Int
    var codec: StreamCodec
    /// encoderCscMode bit 0.
    var fullRange: Bool
    /// encoderCscMode >> 1: 0 Rec.601, 1 Rec.709, 2 Rec.2020.
    var colorspace: Int
    /// x-nv-video[0].maxNumReferenceFrames (0 = no limit).
    var maxReferenceFrames: Int
    /// x-nv-video[0].videoEncoderSlicesPerFrame (at least 1).
    var slicesPerFrame: Int
}

/// The audio stream the client asked for in RTSP ANNOUNCE: an Opus (multistream) configuration
/// as advertised in DESCRIBE's surround-params.
struct StreamAudioConfig: Equatable {
    var channels: Int
    var streams: Int
    var coupledStreams: Int
    /// Opus channel mapping, `channels` entries.
    var mapping: [UInt8]
    /// x-nv-aqos.packetDuration (5 or 10 ms per packet).
    var packetDurationMs: Int
    /// x-nv-audio.surround.AudioQuality
    var highQuality: Bool
    /// AES-128-CBC audio payloads (rikey/rikeyid).
    var encrypted: Bool
}

/// Per-session secrets the RTSP SETUP responses hand out (X-SS-Ping-Payload, X-SS-Connect-Data):
/// the video and audio streams learn the client's UDP port only from a ping carrying their
/// payload; the control stream only accepts an ENet connect carrying `controlConnectData`.
struct StreamSessionSecrets {
    /// 16 ASCII characters each.
    let videoPingPayload: Data
    let audioPingPayload: Data
    let controlConnectData: UInt32

    static func random() -> StreamSessionSecrets {
        func payload() -> Data {
            let alphabet = Array("ABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789".utf8)
            return Data((0..<16).map { _ in alphabet.randomElement()! })
        }
        return StreamSessionSecrets(videoPingPayload: payload(), audioPingPayload: payload(),
                                    controlConnectData: UInt32.random(in: 1...UInt32.max))
    }
}

/// The guest display during a session.
struct StreamDisplayControl {
    /// Main thread. Sizes the guest display to width×height (within the VM's limits) and holds it
    /// there: window-driven resizes wait until `end`.
    let begin: (_ width: Int, _ height: Int) -> Void
    /// Main thread. The guest display follows the window again.
    let end: () -> Void
}

/// What the VM process hands the host (main.swift builds it once, window mode only).
struct StreamEnvironment {
    /// libkrun context id: the audio stream taps the guest's playback through it.
    let ctx: UInt32
    let capture: StreamCapture
    let input: StreamInput
    let sound: SoundControl
    let display: StreamDisplayControl
}
