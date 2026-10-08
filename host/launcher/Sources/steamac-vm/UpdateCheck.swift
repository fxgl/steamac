import AppKit
import Combine
import SwiftUI

/// New-version check: the latest GitHub release of fxgl/steamac against this launcher's
/// CFBundleShortVersionString. Runs in the VM process of the first boot (once per app launch, not
/// per VM reboot) a few seconds after the window is up, at most every 6 h (also across launches),
/// never in development builds (work/out/steamac-vm), and only while Settings > General "Check for
/// updates at startup" is on. The request goes to api.github.com with only the User-Agent
/// `FXSteamLauncher/<version>` (plus the ETag of the previous answer, so GitHub can answer "not
/// modified"); no Sentry involvement. Network and HTTP errors of the startup check are only logged.
/// A newer release opens UpdatePanel beside the VM window, without taking the keyboard or the mouse
/// capture; the app menu's "Check for Updates…" checks at once (no 6 h limit, skipped versions
/// included) and also reports "up to date" and errors.
///
/// Test hooks: STEAMAC_UPDATE_URL (another release JSON, http(s):// or file://: a /releases/latest
/// object or a /releases array; also enables the startup check of the dev launcher) and
/// STEAMAC_FAKE_VERSION (the version this launcher pretends to be).
final class UpdateChecker {
    static let shared = UpdateChecker()

    static let latestURL = URL(string: "https://api.github.com/repos/fxgl/steamac/releases/latest")!
    static let releasesPage = URL(string: "https://github.com/fxgl/steamac/releases")!
    static let urlEnv = "STEAMAC_UPDATE_URL", fakeVersionEnv = "STEAMAC_FAKE_VERSION"
    static let interval: TimeInterval = 6 * 3600
    static let timeout: TimeInterval = 10
    /// After the VM window appears (the check never delays the boot).
    static let startupDelay: TimeInterval = 3

    /// Defaults keys (settings domain; not preferences: Reset All Settings keeps them).
    private enum Store {
        static let lastCheck = "updateLastCheck", skipped = "updateSkippedVersion"
        /// Last 200 answer, its ETag and the URL it came from (If-None-Match / 304).
        static let etag = "updateETag", body = "updateCachedBody", url = "updateCachedURL"
    }

    struct Release {
        let tag: String
        let version: [Int]
        let name: String
        let notes: String
        let published: Date?
        let page: URL?
        /// The .dmg asset.
        let dmg: URL?

        var versionString: String { UpdateChecker.format(version) }
        /// Download: the .dmg, else the release page, else the releases list.
        var downloadURL: URL { dmg ?? page ?? UpdateChecker.releasesPage }
    }

    enum Outcome {
        case newer(Release)
        case upToDate(latest: Release?)
        case failed(String)
    }

    private var defaults: UserDefaults { LauncherSettings.shared.defaults }
    /// Requests not answered yet (a startup check does not start while one runs).
    private var pending = 0
    /// A newer release this process found (and the user did not skip): the menu offers it.
    private(set) var available: Release?
    private var panel: UpdatePanel?
    private var vmWindow: () -> NSWindow? = { nil }
    private var subscription: AnyCancellable?

    // MARK: versions

    static var currentVersion: String {
        if let v = ProcessInfo.processInfo.environment[fakeVersionEnv], !v.isEmpty { return v }
        return Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "0"
    }

    /// `vX.Y[.Z…]` / `X.Y[.Z…]` -> numeric components (nil for anything else, e.g. `v1.4-rc1`).
    static func parse(_ text: String) -> [Int]? {
        var t = Substring(text.trimmingCharacters(in: .whitespaces))
        if t.first == "v" || t.first == "V" { t = t.dropFirst() }
        let parts = t.split(separator: ".", omittingEmptySubsequences: false)
        guard (1...4).contains(parts.count) else { return nil }
        var out: [Int] = []
        for p in parts {
            guard !p.isEmpty, p.count <= 9, p.allSatisfy({ $0.isASCII && $0.isNumber }), let n = Int(p) else { return nil }
            out.append(n)
        }
        return out
    }

    /// Numeric, missing components are 0: 1.3.10 > 1.3.9, 1.3 == 1.3.0.
    static func compare(_ a: [Int], _ b: [Int]) -> ComparisonResult {
        for i in 0..<max(a.count, b.count) {
            let x = i < a.count ? a[i] : 0, y = i < b.count ? b[i] : 0
            if x != y { return x < y ? .orderedAscending : .orderedDescending }
        }
        return .orderedSame
    }

    static func format(_ v: [Int]) -> String { v.map(String.init).joined(separator: ".") }

    /// The newest published release of a /releases/latest object or a /releases array (drafts,
    /// prereleases and tags that are no version number ignored); nil if there is none.
    static func newest(inJSON data: Data) throws -> Release? {
        let json = try JSONSerialization.jsonObject(with: data)
        let list: [[String: Any]]
        if let one = json as? [String: Any] { list = [one] }
        else if let many = json as? [[String: Any]] { list = many }
        else { throw OptionError("unexpected JSON") }
        let iso = ISO8601DateFormatter()
        func web(_ s: Any?) -> URL? {
            guard let s = s as? String, let u = URL(string: s), u.scheme == "https" || u.scheme == "http" else { return nil }
            return u
        }
        let releases: [Release] = list.compactMap { r in
            guard r["draft"] as? Bool != true, r["prerelease"] as? Bool != true,
                  let tag = r["tag_name"] as? String, let version = parse(tag) else { return nil }
            let assets = r["assets"] as? [[String: Any]] ?? []
            let dmg = assets.first { ($0["name"] as? String)?.lowercased().hasSuffix(".dmg") == true }
            return Release(tag: tag, version: version, name: r["name"] as? String ?? "", notes: r["body"] as? String ?? "",
                           published: (r["published_at"] as? String).flatMap(iso.date(from:)),
                           page: web(r["html_url"]), dmg: web(dmg?["browser_download_url"]))
        }
        return releases.max { compare($0.version, $1.version) == .orderedAscending }
    }

    /// Settings self-test: version parsing and ordering, release selection, release notes text.
    static func selfCheck() -> [String] {
        var failures: [String] = []
        let parsed: [(String, [Int]?)] = [("v1.3.1", [1, 3, 1]), ("1.3", [1, 3]), ("V2", [2]), ("v1.3.10", [1, 3, 10]),
                                          ("v1.4-rc1", nil), ("v1..2", nil), ("", nil), ("latest", nil), ("v1.2.3.4.5", nil)]
        for (text, want) in parsed where parse(text) != want { failures.append("update: parse \"\(text)\" → \(String(describing: parse(text)))") }
        let order: [(String, String, ComparisonResult)] = [("1.3.10", "1.3.9", .orderedDescending), ("1.3", "1.3.0", .orderedSame),
                                                            ("1.3", "1.3.1", .orderedAscending), ("2.0", "1.99.99", .orderedDescending),
                                                            ("v1.3.1", "1.3.1", .orderedSame)]
        for (a, b, want) in order where compare(parse(a)!, parse(b)!) != want { failures.append("update: \(a) vs \(b) not \(want.rawValue)") }
        let json = """
            [{"tag_name": "v9.0", "draft": true}, {"tag_name": "v8.0", "prerelease": true}, {"tag_name": "nightly"},
             {"tag_name": "v1.3.10", "name": "1.3.10", "body": "x", "html_url": "https://github.com/fxgl/steamac/releases/tag/v1.3.10",
              "assets": [{"name": "FX-Steam-Launcher-1.3.10-gpl-sources.tar", "browser_download_url": "https://e/x.tar"},
                         {"name": "FX-Steam-Launcher-1.3.10.dmg", "browser_download_url": "https://e/x.dmg"}]},
             {"tag_name": "v1.3.9"}]
            """
        let newest = try? newest(inJSON: Data(json.utf8))
        if newest?.tag != "v1.3.10" || newest?.dmg?.absoluteString != "https://e/x.dmg" {
            failures.append("update: newest release \(newest?.tag ?? "none"), dmg \(newest?.dmg?.absoluteString ?? "none")")
        }
        let md = "## What's new\r\n* **Faster** boot\n- see [notes](https://e)\n\n\n\nend<!-- hidden -->\n---\n```\ncode\n```\n"
        let notes = String(releaseNotesText(md).characters)
        if notes != "What's new\n• Faster boot\n• see notes\n\nend\n──────────\ncode" { failures.append("update: release notes \(notes.debugDescription)") }
        log("selftest-settings: update check: \(failures.isEmpty ? "ok" : failures.joined(separator: "; "))")
        return failures
    }

    // MARK: checks

    /// VM process, once the window is up: the startup check (first boot of this launch only) and
    /// Settings > General "Check for updates at startup" turned on later (applies now).
    func start(vmWindow: @escaping () -> NSWindow?) {
        self.vmWindow = vmWindow
        subscription = LauncherSettings.shared.$checkForUpdates.dropFirst().sink { [weak self] on in
            guard on else { return }
            DispatchQueue.main.async { self?.automaticCheck() }
        }
        guard Supervisor.bootNumber == 1 else { return }
        DispatchQueue.main.asyncAfter(deadline: .now() + UpdateChecker.startupDelay) { [weak self] in self?.automaticCheck() }
    }

    /// The startup check: setting, build kind, 6 h limit and Skip This Version apply; errors only logged.
    func automaticCheck() {
        guard LauncherSettings.shared.checkForUpdates else { log("update: startup check off (Settings > General)"); return }
        let testURL = ProcessInfo.processInfo.environment[UpdateChecker.urlEnv].map { !$0.isEmpty } ?? false
        guard CrashReporting.buildKind != .development || testURL else {
            log("update: no startup check in development builds (menu Check for Updates… still works)")
            return
        }
        if let last = defaults.object(forKey: Store.lastCheck) as? Date {
            let age = Date().timeIntervalSince(last)
            if age >= 0 && age < UpdateChecker.interval {
                log("update: last checked \(Int(age / 60)) min ago; next startup check after \(Int(UpdateChecker.interval / 3600)) h")
                return
            }
        }
        guard pending == 0 else { return }
        fetch { [weak self] outcome in
            guard let self else { return }
            switch outcome {
            case .newer(let r):
                if let s = self.defaults.string(forKey: Store.skipped).flatMap(UpdateChecker.parse),
                   UpdateChecker.compare(s, r.version) == .orderedSame {
                    log("update: \(r.tag) available, skipped by the user (Skip This Version)")
                    return
                }
                self.available = r
                guard LauncherSettings.shared.checkForUpdates else { return }   // turned off meanwhile
                if self.panel?.window.isVisible == true { return }   // a manual check shows it already
                self.show(.available(r, current: UpdateChecker.currentVersion), activate: false)
            case .upToDate(let latest):
                log("update: up to date (\(UpdateChecker.currentVersion); latest release \(latest?.tag ?? "none"))")
            case .failed(let message):
                log("update: check failed: \(message)")
            }
        }
    }

    /// App menu "Check for Updates…" (or "Update Available…"): the found release, else a check
    /// now that ignores the 6 h limit and skipped versions and reports the result.
    func menuAction() {
        if let r = available {
            show(.available(r, current: UpdateChecker.currentVersion), activate: true)
            return
        }
        manualCheck()
    }

    func manualCheck() {
        show(.checking, activate: true)
        fetch { [weak self] outcome in
            guard let self, let panel = self.panel, panel.window.isVisible, case .checking = panel.model.state else {
                log("update: manual check result dropped (window closed)")
                return
            }
            switch outcome {
            case .newer(let r):
                self.available = r
                self.show(.available(r, current: UpdateChecker.currentVersion), activate: false)
            case .upToDate(let latest):
                log("update: up to date (\(UpdateChecker.currentVersion); latest release \(latest?.tag ?? "none"))")
                self.show(.upToDate(current: UpdateChecker.currentVersion), activate: false)
            case .failed(let message):
                log("update: check failed: \(message)")
                self.show(.failed(message), activate: false)
            }
        }
    }

    var menuTitle: String {
        available.map { tr("Update Available: %@…", $0.versionString) } ?? tr("Check for Updates…")
    }

    /// GET the release JSON (10 s, If-None-Match with the cached ETag); `done` on the main queue.
    private func fetch(_ done: @escaping (Outcome) -> Void) {
        pending += 1
        let env = ProcessInfo.processInfo.environment[UpdateChecker.urlEnv].flatMap { $0.isEmpty ? nil : URL(string: $0) }
        let url = env ?? UpdateChecker.latestURL
        let current = UpdateChecker.currentVersion
        defaults.set(Date(), forKey: Store.lastCheck)
        var request = URLRequest(url: url, cachePolicy: .reloadIgnoringLocalCacheData, timeoutInterval: UpdateChecker.timeout)
        request.setValue("FXSteamLauncher/\(current)", forHTTPHeaderField: "User-Agent")
        request.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
        let cached = defaults.string(forKey: Store.url) == url.absoluteString ? defaults.data(forKey: Store.body) : nil
        if cached != nil, let etag = defaults.string(forKey: Store.etag) { request.setValue(etag, forHTTPHeaderField: "If-None-Match") }
        let config = URLSessionConfiguration.ephemeral
        config.urlCache = nil
        config.httpCookieStorage = nil
        config.httpShouldSetCookies = false
        config.timeoutIntervalForRequest = UpdateChecker.timeout
        config.timeoutIntervalForResource = UpdateChecker.timeout
        let session = URLSession(configuration: config)
        log("update: checking \(url.absoluteString) (this launcher: \(current))")
        let defaults = self.defaults
        session.dataTask(with: request) { data, response, error in
            let outcome = UpdateChecker.outcome(data: data, response: response, error: error, cached: cached,
                                                current: current, url: url, defaults: defaults)
            DispatchQueue.main.async { [weak self] in
                self?.pending -= 1
                done(outcome)
            }
        }.resume()
        session.finishTasksAndInvalidate()
    }

    private static func outcome(data: Data?, response: URLResponse?, error: Error?, cached: Data?, current: String,
                                url: URL, defaults: UserDefaults) -> Outcome {
        if let error {
            log("update: error: \(error)")
            return .failed(NetworkFailure.message(error, server: .updates))
        }
        var body = data
        var etag: String?
        if let http = response as? HTTPURLResponse {
            log("update: HTTP \(http.statusCode)" + (http.statusCode == 304 ? " (not modified: the cached answer)" : ""))
            switch http.statusCode {
            case 200:
                etag = http.value(forHTTPHeaderField: "ETag")
            case 304 where cached != nil:
                body = cached
            case 403 where http.value(forHTTPHeaderField: "X-RateLimit-Remaining") == "0",
                 429:
                return .failed("GitHub's request limit for this network is reached; try again later.")
            default:
                return .failed("The server answered HTTP \(http.statusCode).")
            }
        }
        guard let body else { return .failed("Empty answer.") }
        let release: Release?
        do { release = try newest(inJSON: body) } catch { return .failed("Unreadable answer from the server.") }
        if response is HTTPURLResponse, body != cached {
            defaults.set(body, forKey: Store.body)
            defaults.set(url.absoluteString, forKey: Store.url)
            if let etag { defaults.set(etag, forKey: Store.etag) } else { defaults.removeObject(forKey: Store.etag) }
        }
        guard let release else { return .upToDate(latest: nil) }
        let mine = parse(current) ?? [0]
        return compare(release.version, mine) == .orderedDescending ? .newer(release) : .upToDate(latest: release)
    }

    // MARK: panel

    private func show(_ state: UpdatePanel.State, activate: Bool) {
        let panel = self.panel ?? UpdatePanel(actions: .init(
            download: { [weak self] r in
                log("update: download \(r.tag): opening \(r.downloadURL.absoluteString)")
                NSWorkspace.shared.open(r.downloadURL)
                self?.panel?.window.close()
            },
            skip: { [weak self] r in
                guard let self else { return }
                log("update: skipping \(r.tag)")
                self.defaults.set(r.versionString, forKey: Store.skipped)
                self.available = nil
                self.panel?.window.close()
            },
            later: { [weak self] in
                log("update: remind me later")
                self?.panel?.window.close()
            },
            releases: { [weak self] in
                NSWorkspace.shared.open(UpdateChecker.releasesPage)
                self?.panel?.window.close()
            },
            dismiss: { [weak self] in self?.panel?.window.close() }))
        self.panel = panel
        if case .available(let r, let current) = state { log("update: \(r.tag) available (this launcher: \(current)); showing the update window") }
        panel.show(state, beside: vmWindow(), activate: activate)
    }

    // MARK: control FIFO (`update …`)

    /// check (menu) | startup (the startup check now) | press download|skip|later|ok|releases |
    /// dump PNG (the window; PNG-with-vm.png: the window and the VM window as on screen) | state
    func control(_ args: [String]) {
        switch args.first {
        case "check": menuAction()
        case "startup": automaticCheck()
        case "press":
            guard let panel else { log("control: update: no update window"); return }
            panel.press(args.dropFirst().first ?? "")
        case "dump":
            guard let panel else { log("control: update: no update window"); return }
            panel.dump(to: args.dropFirst().first ?? "update.png", with: vmWindow())
        case "state":
            let visible = panel?.window.isVisible == true
            log("control: update: window \(visible ? "shown (\(panel!.model.state.name))" : "hidden"), menu \"\(menuTitle)\""
                + ", skipped \(defaults.string(forKey: Store.skipped) ?? "none")"
                + (available.map { ", download \($0.downloadURL.absoluteString)" } ?? ""))
        default: log("control: update: unknown command")
        }
    }
}

/// The update window: a plain titled panel next to the VM window (on top of it only when the
/// screen has no room beside it), shown without becoming key so the VM keeps the keyboard and a
/// captured mouse.
final class UpdatePanel {
    enum State {
        case checking
        case available(UpdateChecker.Release, current: String)
        case upToDate(current: String)
        case failed(String)

        var name: String {
            switch self {
            case .checking: return "checking"
            case .available(let r, _): return "available \(r.tag)"
            case .upToDate: return "up to date"
            case .failed: return "failed"
            }
        }
    }

    struct Actions {
        let download: (UpdateChecker.Release) -> Void
        let skip: (UpdateChecker.Release) -> Void
        let later: () -> Void
        let releases: () -> Void
        /// Cancel / OK: close the window.
        let dismiss: () -> Void
    }

    final class Model: ObservableObject {
        @Published var state: State = .checking
    }

    let window: NSPanel
    let model = Model()
    private let actions: Actions
    private let host: NSHostingView<UpdateView>
    static let width: CGFloat = 540

    init(actions: Actions) {
        self.actions = actions
        window = NSPanel(contentRect: NSRect(x: 0, y: 0, width: UpdatePanel.width, height: 200),
                         styleMask: [.titled, .closable], backing: .buffered, defer: false)
        host = NSHostingView(rootView: UpdateView(model: model, actions: actions))
        window.title = tr("Software Update")
        window.isReleasedWhenClosed = false
        window.hidesOnDeactivate = false
        window.isFloatingPanel = false
        window.becomesKeyOnlyIfNeeded = true
        window.contentView = host
    }

    func show(_ state: State, beside vm: NSWindow?, activate: Bool) {
        let wasVisible = window.isVisible
        model.state = state
        host.layoutSubtreeIfNeeded()
        var size = host.fittingSize
        size.width = UpdatePanel.width
        let frame = window.frameRect(forContentRect: NSRect(origin: .zero, size: size))
        if wasVisible {
            var f = window.frame
            f.origin.y += f.height - frame.height
            f.size = frame.size
            window.setFrame(f, display: true)
        } else {
            window.setFrame(UpdatePanel.placement(frame.size, beside: vm), display: false)
        }
        if activate {
            window.makeKeyAndOrderFront(nil)
            NSApp.activate()
        } else {
            window.orderFront(nil)
        }
    }

    /// Right of the VM window, else left, below, above (top-aligned with it where possible); the
    /// top-right corner of its screen when none fits.
    static func placement(_ size: NSSize, beside vm: NSWindow?) -> NSRect {
        let screen = vm?.screen ?? NSScreen.main
        guard let vf = screen?.visibleFrame else { return NSRect(origin: .zero, size: size) }
        let gap: CGFloat = 12
        guard let vm, vm.isVisible, !vm.styleMask.contains(.fullScreen) else {
            return NSRect(x: vf.maxX - size.width - gap, y: vf.maxY - size.height - gap, width: size.width, height: size.height)
        }
        let v = vm.frame
        let topY = min(vf.maxY, v.maxY) - size.height
        let y = max(vf.minY, topY)
        let x = min(max(vf.minX, v.minX), vf.maxX - size.width)
        let candidates = [
            NSRect(x: v.maxX + gap, y: y, width: size.width, height: size.height),
            NSRect(x: v.minX - gap - size.width, y: y, width: size.width, height: size.height),
            NSRect(x: x, y: v.minY - gap - size.height, width: size.width, height: size.height),
            NSRect(x: x, y: v.maxY + gap, width: size.width, height: size.height),
        ]
        return candidates.first { vf.contains($0) }
            ?? NSRect(x: vf.maxX - size.width - gap, y: vf.maxY - size.height - gap, width: size.width, height: size.height)
    }

    /// Control FIFO: the buttons of the current state.
    func press(_ button: String) {
        switch (button, model.state) {
        case ("download", .available(let r, _)): actions.download(r)
        case ("skip", .available(let r, _)): actions.skip(r)
        case ("later", .available): actions.later()
        case ("releases", .failed): actions.releases()
        case ("ok", _), ("cancel", _): actions.dismiss()
        default: log("control: update: no \(button) button in state \(model.state.name)")
        }
    }

    func dump(to path: String, with vm: NSWindow?) {
        let base = (path as NSString).deletingPathExtension
        if let rep = SettingsWindowController.snapshot(window), let png = rep.representation(using: .png, properties: [:]),
           (try? png.write(to: URL(fileURLWithPath: path))) != nil {
            log("control: update window dumped to \(path) (\(model.state.name), frame \(NSStringFromRect(window.frame)), key \(window.isKeyWindow))")
        } else {
            log("control: update window dump failed")
        }
        // Both windows as the window server shows them (own windows need no Screen Recording permission).
        guard let vm else { return }
        typealias CreateFromArray = @convention(c) (CGRect, CFArray, UInt32) -> Unmanaged<CGImage>?
        guard let sym = dlsym(UnsafeMutableRawPointer(bitPattern: -2), "CGWindowListCreateImageFromArray") else { return }   // RTLD_DEFAULT
        let create = unsafeBitCast(sym, to: CreateFromArray.self)
        // A CFArray of raw CGWindowID values (no callbacks), not of CFNumbers.
        var raw = [window.windowNumber, vm.windowNumber].map { UnsafeRawPointer(bitPattern: UInt(max(0, $0))) }
        guard let ids = CFArrayCreate(nil, &raw, raw.count, nil) else { return }
        if let image = create(.null, ids, 0)?.takeRetainedValue() {
            do {
                try PNG.write(image, to: base + "-with-vm.png")
                log("control: update window and VM window dumped to \(base)-with-vm.png (VM frame \(NSStringFromRect(vm.frame)), VM key \(vm.isKeyWindow))")
            } catch {
                log("control: update dump failed: \(error)")
            }
        } else {
            log("control: update: no window server image of the update and VM windows")
        }
    }
}

/// Release notes (Markdown) as plain text with inline styling: headings bold, list markers as
/// bullets, rules as a line, code fences and HTML comments removed, at most ~6000 characters.
func releaseNotesText(_ markdown: String) -> AttributedString {
    var s = markdown.replacingOccurrences(of: "\r\n", with: "\n")
    s = s.replacingOccurrences(of: "<!--[\\s\\S]*?-->", with: "", options: .regularExpression)
    let lines = s.split(separator: "\n", omittingEmptySubsequences: false).compactMap { raw -> String? in
        let line = String(raw).replacingOccurrences(of: "\\s+$", with: "", options: .regularExpression)
        if line.range(of: "^\\s*(```|~~~)", options: .regularExpression) != nil { return nil }
        if line.range(of: "^\\s*([-*_])(\\s*\\1){2,}$", options: .regularExpression) != nil { return "──────────" }
        if let m = line.range(of: "^#{1,6}\\s+", options: .regularExpression) {
            let title = line[m.upperBound...].trimmingCharacters(in: CharacterSet(charactersIn: "# "))
            return title.isEmpty ? "" : "**\(title)**"
        }
        if let m = line.range(of: "^\\s*[-*+]\\s+", options: .regularExpression) {
            let indent = line.prefix { $0 == " " || $0 == "\t" }
            return indent + "• " + line[m.upperBound...]
        }
        return line
    }
    s = lines.joined(separator: "\n").replacingOccurrences(of: "\n{3,}", with: "\n\n", options: .regularExpression)
        .trimmingCharacters(in: .whitespacesAndNewlines)
    if s.count > 6000 {
        let head = s.prefix(6000)
        s = String(head[..<(head.lastIndex(of: "\n") ?? head.endIndex)]) + "\n…"
    }
    if s.isEmpty { s = "No release notes." }
    let options = AttributedString.MarkdownParsingOptions(interpretedSyntax: .inlineOnlyPreservingWhitespace)
    return (try? AttributedString(markdown: s, options: options)) ?? AttributedString(s)
}

struct UpdateView: View {
    @ObservedObject var model: UpdatePanel.Model
    let actions: UpdatePanel.Actions

    var body: some View {
        HStack(alignment: .top, spacing: 16) {
            // The dev launcher (no bundle) has only a generic icon.
            Group {
                if AppBundle.resources != nil {
                    Image(nsImage: NSApp.applicationIconImage).resizable()
                } else {
                    Image(systemName: "arrow.down.app").resizable().scaledToFit().foregroundStyle(.tint).padding(6)
                }
            }
            .frame(width: 64, height: 64)
            VStack(alignment: .leading, spacing: 10) {
                switch model.state {
                case .checking:
                    Text("Checking for updates…").font(.headline)
                    ProgressView().progressViewStyle(.linear)
                    HStack {
                        Spacer()
                        Button("Cancel") { actions.dismiss() }.keyboardShortcut(.cancelAction)
                    }
                case .available(let r, let current):
                    Text(tr("FX Steam Launcher %@ is available — you have %@", r.versionString, current))
                        .font(.headline)
                        .fixedSize(horizontal: false, vertical: true)
                    if let subtitle = subtitle(r) {
                        Text(subtitle).font(.caption).foregroundStyle(.secondary)
                    }
                    Text("Release notes").font(.subheadline.weight(.semibold))
                    ScrollView {
                        Text(releaseNotesText(r.notes))
                            .textSelection(.enabled)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .padding(10)
                    }
                    .frame(height: 240)
                    .background(Color(nsColor: .textBackgroundColor))
                    .overlay(RoundedRectangle(cornerRadius: 6).stroke(Color(nsColor: .separatorColor)))
                    .clipShape(RoundedRectangle(cornerRadius: 6))
                    HStack {
                        Button("Skip This Version") { actions.skip(r) }
                        Spacer()
                        Button("Remind Me Later") { actions.later() }.keyboardShortcut(.cancelAction)
                        Button("Download") { actions.download(r) }.keyboardShortcut(.defaultAction)
                    }
                case .upToDate(let current):
                    Text("You're up to date").font(.headline)
                    Text(tr("FX Steam Launcher %@ is the newest version available.", current))
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                    HStack {
                        Spacer()
                        Button("OK") { actions.dismiss() }.keyboardShortcut(.defaultAction)
                    }
                case .failed(let message):
                    Text("Couldn't check for updates").font(.headline)
                    Text(message)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                    HStack {
                        Button("Open Releases Page") { actions.releases() }
                        Spacer()
                        Button("OK") { actions.dismiss() }.keyboardShortcut(.defaultAction)
                    }
                }
            }
        }
        .padding(20)
        .frame(width: UpdatePanel.width, alignment: .topLeading)
    }

    private func subtitle(_ r: UpdateChecker.Release) -> String? {
        var parts: [String] = []
        if !r.name.isEmpty && r.name != r.tag && r.name != r.versionString { parts.append(r.name) }
        if let d = r.published { parts.append("Released " + d.formatted(date: .long, time: .omitted)) }
        return parts.isEmpty ? nil : parts.joined(separator: " · ")
    }
}
