import Foundation

struct StreamSessionInfo: Equatable {
    let clientName: String
    let address: String
    let width: Int
    let height: Int
    let fps: Int
    let codec: StreamCodec
}

/// Main-thread lifetime owner. Network callbacks return to main before changing session state.
final class StreamSession {
    let launch: StreamLaunch
    let secrets = StreamSessionSecrets.random()
    private let environment: StreamEnvironment
    private var rtsp: StreamRTSP?
    private var video: StreamVideoStream?
    private var audio: StreamAudioStream?
    private var control: StreamControl?
    private var videoConfig: StreamVideoConfig?
    private var audioConfig: StreamAudioConfig?
    private var stopped = false
    private var playing = false
    private var negotiationTimeout: DispatchWorkItem?
    var onStarted: ((StreamSessionInfo) -> Void)?
    var onEnded: ((String?) -> Void)?

    init(launch: StreamLaunch, environment: StreamEnvironment) {
        self.launch = launch
        self.environment = environment
    }

    func start() throws {
        let server = StreamRTSP(launch: launch, secrets: secrets, announce: { [weak self] video, audio in
            guard let self, !self.stopped, !self.playing else { throw StreamError("Session is no longer negotiating") }
            self.videoConfig = video
            self.audioConfig = audio
        }, play: { [weak self] in
            guard let self, !self.stopped else { throw StreamError("Session has ended") }
            try self.play()
        })
        try server.start()
        rtsp = server
        let timeout = DispatchWorkItem { [weak self] in self?.finish("Stream negotiation timed out") }
        negotiationTimeout = timeout
        DispatchQueue.main.asyncAfter(deadline: .now() + 30, execute: timeout)
    }

    private func play() throws {
        if playing { return }
        guard let vc = videoConfig, let ac = audioConfig else { throw StreamError("ANNOUNCE required before PLAY") }
        do {
            let video = try StreamVideoStream(config: vc, capture: environment.capture)
            self.video = video
            video.onError = { [weak self] message in DispatchQueue.main.async { self?.finish(message) } }
            let audio = try StreamAudioStream(ctx: environment.ctx, sound: environment.sound, config: ac, launch: launch)
            self.audio = audio
            let control = try StreamControl(key: launch.aesKey, clientAddress: launch.clientAddress,
                connectData: secrets.controlConnectData, onInput: { [input = environment.input] in input.handle($0) },
                onKeyFrame: { [weak video] in video?.requestKeyFrame() },
                onInvalidate: { [weak video] first, last in video?.invalidateReferenceFrames(first: first, last: last) },
                onEnd: { [weak self] message in self?.finish(message) })
            self.control = control
            environment.input.begin { [weak control] controller, low, high in
                control?.rumble(controller: controller, lowFrequency: low, highFrequency: high)
            }
            try control.start()
            try audio.start(clientAddress: launch.clientAddress, pingPayload: secrets.audioPingPayload)
            try video.start(clientAddress: launch.clientAddress, pingPayload: secrets.videoPingPayload)
            playing = true
            negotiationTimeout?.cancel()
            negotiationTimeout = nil
            onStarted?(StreamSessionInfo(clientName: launch.client.name, address: launch.clientAddress,
                width: vc.width, height: vc.height, fps: vc.fps, codec: vc.codec))
        } catch {
            finish(String(describing: error))
            throw error
        }
    }

    func stop() {
        guard !stopped else { return }
        stopped = true
        negotiationTimeout?.cancel()
        negotiationTimeout = nil
        // Stop the network producer before releasing any held input or media resources.
        control?.stop()
        control = nil
        environment.input.end()
        video?.stop()
        video = nil
        audio?.stop()
        audio = nil
        rtsp?.stop()
        rtsp = nil
    }

    private func finish(_ message: String?) {
        guard !stopped else { return }
        stop()
        onEnded?(message)
    }
}
