import Darwin
import Foundation

enum StreamSelfTest {
    static func run() -> Never {
        let components: [(String, () -> [String])] = [
            ("HTTP and pairing", StreamHTTPServer.selfCheck),
            ("control", StreamControl.selfCheck),
            ("RTSP", StreamRTSP.selfCheck),
            ("input", StreamInput.selfCheck),
            ("capture", StreamCapture.selfCheck),
            ("video", StreamVideoStream.selfCheck),
            ("audio", StreamAudioStream.selfCheck),
        ]
        var failures = 0
        for (name, run) in components {
            let errors = run()
            print("stream selftest: \(errors.isEmpty ? "PASS" : "FAIL") \(name)")
            for error in errors { print("stream selftest: FAIL \(name): \(error)") }
            failures += errors.count
        }
        print("stream selftest: \(components.count) components, \(failures) failures")
        exit(failures == 0 ? 0 : 1)
    }
}
