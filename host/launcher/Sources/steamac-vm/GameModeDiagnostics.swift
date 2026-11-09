import AppKit
import Darwin
import Foundation

/// Passive evidence, not a Game Mode switch: macOS owns activation and remembers the
/// user's per-app choice. Plist eligibility or fullscreen alone does not mean it is on.
enum GameModeDiagnostics {
    static func metadata(_ info: [String: Any]) -> String {
        ["LSApplicationCategoryType", "LSSupportsGameMode", "GCSupportsGameMode", "LSUIElement"].map { key in
            let value = info[key].map { String(describing: $0) } ?? "missing"
            return "\(key)=\(value)"
        }.joined(separator: ", ")
    }

    @MainActor
    static func snapshot(window: NSWindow?) -> String {
        let diskInfo = Bundle.main.bundleURL.appendingPathComponent("Contents/Info.plist")
        let disk = (try? Data(contentsOf: diskInfo)).flatMap {
            (try? PropertyListSerialization.propertyList(from: $0, options: [], format: nil)) as? [String: Any]
        }
        let windowState = window.map {
            "native-fullscreen=\($0.styleMask.contains(.fullScreen)) visible=\($0.isVisible) miniaturized=\($0.isMiniaturized) key=\($0.isKeyWindow)"
        } ?? "no VM window"
        return "runtime metadata: \(metadata(Bundle.main.infoDictionary ?? [:]))\n"
            + "disk metadata: \(disk.map(metadata) ?? "unavailable")\n"
            + "application: activation-policy=\(NSApp.activationPolicy().rawValue) active=\(NSApp.isActive)\n"
            + "VM window: \(windowState)\n"
            + "Game Mode activation: owned by macOS; see game-policy.log (eligibility is not activation).\n"
    }

    /// Called only when the user includes launcher logs in a problem report. Keep policy
    /// messages about this app and anonymous on/off transitions, never other game titles.
    static func policyLog(in directory: String) -> String {
        let url = URL(fileURLWithPath: directory).appendingPathComponent(".game-policy.tmp")
        guard FileManager.default.createFile(atPath: url.path, contents: nil, attributes: [.posixPermissions: 0o600]) else {
            return "gamepolicyd log unavailable: cannot create output\n"
        }
        defer { try? FileManager.default.removeItem(at: url) }
        do {
            let file = try FileHandle(forWritingTo: url)
            defer { try? file.close() }
            let process = Process(), done = DispatchSemaphore(value: 0)
            process.executableURL = URL(fileURLWithPath: "/usr/bin/log")
            process.arguments = ["show", "--last", "10m", "--style", "compact", "--info", "--debug", "--predicate",
                "process == 'gamepolicyd' AND (eventMessage BEGINSWITH 'Found game GameProcess(Optional(\"steamac-vm\"),' OR eventMessage BEGINSWITH 'Found game GameProcess(Optional(\"FX Steam Launcher\"),' OR eventMessage BEGINSWITH 'Game mode status is now ')"]
            process.standardOutput = file; process.standardError = file
            process.terminationHandler = { _ in done.signal() }
            try process.run()
            let timedOut = done.wait(timeout: .now() + 5) != .success
            if timedOut { kill(process.processIdentifier, SIGKILL) }
            process.waitUntilExit()
            let reader = try FileHandle(forReadingFrom: url)
            defer { try? reader.close() }
            let size = try reader.seekToEnd()
            try reader.seek(toOffset: size > 64 << 10 ? size - (64 << 10) : 0)
            let data = try reader.read(upToCount: 64 << 10) ?? Data()
            return "gamepolicyd query: status=\(process.terminationStatus) timed-out=\(timedOut) (last 10 minutes)\n"
                + String(decoding: data, as: UTF8.self)
        } catch {
            return "gamepolicyd log unavailable: \(error)\n"
        }
    }

    static func selfCheck() -> [String] {
        let missing = metadata([:])
        let declared = metadata(["LSSupportsGameMode": true, "GCSupportsGameMode": false,
                                 "LSApplicationCategoryType": "public.app-category.games", "LSUIElement": true])
        var failures: [String] = []
        if !missing.contains("LSSupportsGameMode=missing") || !missing.contains("GCSupportsGameMode=missing") {
            failures.append("missing Game Mode declarations must stay distinct from false")
        }
        if !declared.contains("LSSupportsGameMode=true") || !declared.contains("GCSupportsGameMode=false")
            || !declared.contains("LSUIElement=true") || !declared.contains("public.app-category.games") {
            failures.append("Game Mode eligibility metadata loses an explicit value")
        }
        return failures
    }
}
