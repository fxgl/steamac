import Foundation

/// In-app update from a GitHub release `.dmg`: download into Application Support, then a detached
/// helper replaces this `.app` after the launcher (supervisor) has quit and opens the new build.
enum UpdateInstall {
    static let bundleID = "es.fxgam.steamac"
    /// DMG downloads are ~100 MB; keep a generous resource timeout.
    static let timeout: TimeInterval = 15 * 60

    static var cacheDir: String { AppBundle.appSupportDir + "/updates" }

    /// Destination to replace when this process runs from an `.app` bundle; nil for the bare
    /// `work/out/steamac-vm` binary (open the downloaded DMG instead).
    static var appBundlePath: String? {
        let path = Bundle.main.bundlePath
        return path.hasSuffix(".app") ? path : nil
    }

    static func canReplaceApp(at path: String) -> Bool {
        let fm = FileManager.default
        let parent = (path as NSString).deletingLastPathComponent
        return fm.isWritableFile(atPath: path) || fm.isWritableFile(atPath: parent)
    }

    static func dmgCachePath(for release: UpdateChecker.Release) -> String {
        let name = release.dmg?.lastPathComponent ?? "FX-Steam-Launcher-\(release.versionString).dmg"
        return cacheDir + "/" + name
    }

    /// Download `url` to `path` (replacing any previous file). `progress` and `done` on the main queue.
    final class Download: NSObject, URLSessionDownloadDelegate {
        private let path: String
        private let progress: (Int64, Int64, Double) -> Void
        private let done: (Result<String, Error>) -> Void
        private var session: URLSession!
        private var task: URLSessionDownloadTask?
        private let start = Date()
        private var lastReport = Date.distantPast
        private var finished = false

        init(url: URL, path: String, userAgent: String,
             progress: @escaping (Int64, Int64, Double) -> Void,
             done: @escaping (Result<String, Error>) -> Void) {
            self.path = path
            self.progress = progress
            self.done = done
            super.init()
            let config = URLSessionConfiguration.ephemeral
            config.urlCache = nil
            config.httpCookieStorage = nil
            config.httpShouldSetCookies = false
            config.timeoutIntervalForRequest = 60
            config.timeoutIntervalForResource = UpdateInstall.timeout
            session = URLSession(configuration: config, delegate: self, delegateQueue: nil)
            var request = URLRequest(url: url, cachePolicy: .reloadIgnoringLocalCacheData,
                                     timeoutInterval: UpdateInstall.timeout)
            request.setValue(userAgent, forHTTPHeaderField: "User-Agent")
            task = session.downloadTask(with: request)
            task?.resume()
        }

        func cancel() {
            task?.cancel()
            session.invalidateAndCancel()
        }

        private func finish(_ result: Result<String, Error>) {
            guard !finished else { return }
            finished = true
            session.finishTasksAndInvalidate()
            DispatchQueue.main.async { self.done(result) }
        }

        func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask,
                        didWriteData bytesWritten: Int64, totalBytesWritten: Int64,
                        totalBytesExpectedToWrite: Int64) {
            let now = Date()
            guard now.timeIntervalSince(lastReport) > 0.25 || totalBytesWritten == totalBytesExpectedToWrite else { return }
            lastReport = now
            let rate = Double(totalBytesWritten) / max(0.001, now.timeIntervalSince(start))
            DispatchQueue.main.async { self.progress(totalBytesWritten, totalBytesExpectedToWrite, rate) }
        }

        func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask,
                        didFinishDownloadingTo location: URL) {
            do {
                let fm = FileManager.default
                try fm.createDirectory(atPath: (path as NSString).deletingLastPathComponent,
                                       withIntermediateDirectories: true)
                if fm.fileExists(atPath: path) { try fm.removeItem(atPath: path) }
                try fm.moveItem(at: location, to: URL(fileURLWithPath: path))
                // Gatekeeper still checks the notarized staple; drop the download quarantine so a
                // local attach / open is not blocked after we verified the .app inside.
                let p = Process()
                p.executableURL = URL(fileURLWithPath: "/usr/bin/xattr")
                p.arguments = ["-d", "com.apple.quarantine", path]
                p.standardOutput = FileHandle.nullDevice
                p.standardError = FileHandle.nullDevice
                try? p.run()
                p.waitUntilExit()
                finish(.success(path))
            } catch {
                finish(.failure(error))
            }
        }

        func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
            guard let error else { return }
            if (error as NSError).code == NSURLErrorCancelled {
                finish(.failure(CancellationError()))
            } else {
                finish(.failure(error))
            }
        }
    }

    /// Launch a helper that waits for `pid` (the supervisor) to exit, copies the `.app` out of
    /// `dmg` onto `destination`, opens it, then detaches the DMG and deletes the download.
    static func scheduleReplace(dmg: String, destination: String, afterSupervisorExits pid: pid_t) throws {
        let fm = FileManager.default
        try fm.createDirectory(atPath: cacheDir, withIntermediateDirectories: true)
        let script = cacheDir + "/install-\(pid).sh"
        let expected = Bundle.main.object(forInfoDictionaryKey: "CFBundleName") as? String ?? "FX Steam Launcher"
        let lines = [
            "#!/bin/bash",
            "set -euo pipefail",
            "PID=\(pid)",
            "DMG=\(bashSingleQuoted(dmg))",
            "DEST=\(bashSingleQuoted(destination))",
            "EXPECTED=\(bashSingleQuoted(expected))",
            "BUNDLE_ID=\(bashSingleQuoted(bundleID))",
            "LOG=\(bashSingleQuoted(AppBundle.logPath))",
            "MOUNT=\(bashSingleQuoted(cacheDir + "/mnt-\(pid)"))",
            "exec >>\"$LOG\" 2>&1",
            "echo \"update-install: waiting for supervisor pid $PID to exit\"",
            "for _ in $(seq 1 900); do",
            "  if ! kill -0 \"$PID\" 2>/dev/null; then break; fi",
            "  sleep 0.2",
            "done",
            "if kill -0 \"$PID\" 2>/dev/null; then",
            "  echo \"update-install: timed out waiting for pid $PID\"",
            "  exit 1",
            "fi",
            "sleep 0.5",
            "rm -rf \"$MOUNT\"",
            "mkdir -p \"$MOUNT\"",
            "echo \"update-install: attaching $DMG at $MOUNT\"",
            "hdiutil attach -nobrowse -readonly -mountpoint \"$MOUNT\" \"$DMG\"",
            "cleanup() { hdiutil detach \"$MOUNT\" -quiet || true; rm -rf \"$MOUNT\"; }",
            "trap cleanup EXIT",
            "SRC=\"\"",
            "if [[ -d \"$MOUNT/$EXPECTED.app\" ]]; then SRC=\"$MOUNT/$EXPECTED.app\"; fi",
            "if [[ -z \"$SRC\" ]]; then",
            "  for c in \"$MOUNT\"/*.app; do",
            "    if [[ -d \"$c\" ]]; then SRC=$c; break; fi",
            "  done",
            "fi",
            "if [[ -z \"$SRC\" || ! -d \"$SRC\" ]]; then",
            "  echo \"update-install: no .app in DMG\"",
            "  exit 1",
            "fi",
            "ID=$(/usr/libexec/PlistBuddy -c 'Print :CFBundleIdentifier' \"$SRC/Contents/Info.plist\" 2>/dev/null || true)",
            "if [[ \"$ID\" != \"$BUNDLE_ID\" ]]; then",
            "  echo \"update-install: refusing $SRC (bundle id '$ID', want $BUNDLE_ID)\"",
            "  exit 1",
            "fi",
            "echo \"update-install: ditto $SRC -> $DEST\"",
            "ditto \"$SRC\" \"$DEST\"",
            "trap - EXIT",
            "hdiutil detach \"$MOUNT\" -quiet || true",
            "rm -rf \"$MOUNT\"",
            "rm -f \"$DMG\"",
            "echo \"update-install: opening $DEST\"",
            "open \"$DEST\"",
            "rm -f -- \"$0\"",
            "",
        ]
        try lines.joined(separator: "\n").write(toFile: script, atomically: true, encoding: .utf8)
        try fm.setAttributes([.posixPermissions: 0o700], ofItemAtPath: script)

        // Detach from our process group so quitting the launcher does not SIGHUP the helper.
        let spawn = Process()
        spawn.executableURL = URL(fileURLWithPath: "/bin/bash")
        spawn.arguments = ["-c", "exec /bin/bash \(bashSingleQuoted(script)) &"]
        spawn.standardInput = FileHandle.nullDevice
        spawn.standardOutput = FileHandle.nullDevice
        spawn.standardError = FileHandle.nullDevice
        try spawn.run()
        log("update: scheduled install helper \(script) (wait for pid \(pid), replace \(destination))")
    }

    /// Quit the VM process without a reboot marker so the supervisor exits too (the install helper
    /// waits on the supervisor pid).
    static func quitLauncherForInstall() -> Never {
        CrashReporting.noteUserExit()
        if let dir = Supervisor.runDir {
            try? FileManager.default.removeItem(atPath: Supervisor.rebootMarker(dir))
        }
        log("update: quitting to apply the downloaded update")
        exit(CrashReporting.forceQuitStatus)
    }

    private static func bashSingleQuoted(_ s: String) -> String {
        "'" + s.replacingOccurrences(of: "'", with: "'\\''") + "'"
    }
}
