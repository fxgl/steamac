import AppKit
import Darwin
import Sparkle

/// In-app updates of release builds (Sparkle 2, embedded by bundle.sh, signed by dist.sh): the feed
/// (SUFeedURL, an appcast host/launcher/appcast.sh signs with the EdDSA key whose public half is
/// SUPublicEDKey) is checked every 6 h while Settings > General "Check for updates at startup" is on.
/// No Sparkle UI: this user driver shows the update in UpdatePanel. Install Update downloads it in
/// the background (SteamOS keeps running) and Sparkle's installer prepares it, then the update
/// installs when the launcher quits (Install on Quit) or now (Install and Relaunch).
///
/// The VM process (the only one running NSApplication) hosts Sparkle, and quitting never goes
/// through AppKit: the guest powers off (power key, 180 s grace) and libkrun ends the process. So:
///   - Install and Relaunch first shuts SteamOS down like Shut Down (Lifecycle.shutdownForUpdate,
///     from updater(_:shouldPostponeRelaunchForUpdate:untilInvokingBlock:)); Sparkle's own quit request
///     that follows is ignored (Lifecycle.applicationShouldTerminate, isUpdater), never a force quit.
///   - Sparkle's installer waits for this bundle's processes and installs once they are gone. The
///     supervisor boots a new VM process from the bundle after a guest reboot, which would race
///     with the installer replacing it: a prepared update leaves Supervisor.updateMarker in the run
///     dir (the supervisor then never boots again), and a SteamOS restart becomes Install and
///     Relaunch (takeOverReboot, also when the update gets prepared while SteamOS restarts).
final class SparkleUpdates: NSObject, SPUUserDriver, SPUUpdaterDelegate {
    static let updaterBundleID = "org.sparkle-project.Sparkle.Updater"
    static let feedEnv = "STEAMAC_UPDATE_FEED"
    static let checkInterval: TimeInterval = 6 * 3600

    /// Why this copy keeps the GitHub check (nil: Sparkle can replace it).
    static let blocker: String? = {
        let url = Bundle.main.bundleURL
        let readOnly = (try? url.resourceValues(forKeys: [.volumeIsReadOnlyKey]))?.volumeIsReadOnly ?? false
        return blocker(info: Bundle.main.infoDictionary ?? [:], bundlePath: url.path, readOnlyVolume: readOnly)
    }()

    static func blocker(info: [String: Any], bundlePath: String, readOnlyVolume: Bool) -> String? {
        func set(_ key: String) -> Bool { (info[key] as? String).map { !$0.isEmpty } ?? false }
        guard set("SUFeedURL"), set("SUPublicEDKey") else { return "no SUFeedURL/SUPublicEDKey: not a dist.sh build" }
        guard bundlePath.hasSuffix(".app") else { return "not an app bundle" }
        if bundlePath.contains("/AppTranslocation/") { return "translocated by Gatekeeper (not moved to Applications)" }
        if readOnlyVolume { return "on a read-only volume" }
        return nil
    }

    /// Settings self-test: which copies may replace themselves.
    static func selfCheck() -> [String] {
        let info = ["SUFeedURL": "https://fxgl.github.io/steamac/appcast.xml", "SUPublicEDKey": "key"]
        let cases: [(String, [String: Any], String, Bool, Bool)] = [
            ("release", info, "/Applications/FX Steam Launcher.app", false, true),
            ("source build", [:], "/Applications/FX Steam Launcher.app", false, false),
            ("no key", ["SUFeedURL": "https://e/appcast.xml"], "/Applications/FX Steam Launcher.app", false, false),
            ("dev launcher", info, "/x/work/out", false, false),
            ("translocated", info, "/private/var/folders/x/T/AppTranslocation/1/d/FX Steam Launcher.app", false, false),
            ("disk image", info, "/Volumes/FX Steam Launcher/FX Steam Launcher.app", true, false),
        ]
        return cases.compactMap { name, info, path, readOnly, want in
            (blocker(info: info, bundlePath: path, readOnlyVolume: readOnly) == nil) == want ? nil : "update: in-app updates for \(name) not \(want)"
        }
    }

    /// The pid that sent the current quit Apple event is Sparkle's installer agent (Updater.app).
    static func isUpdater(pid: pid_t) -> Bool {
        if NSRunningApplication(processIdentifier: pid)?.bundleIdentifier == updaterBundleID { return true }
        var buffer = [CChar](repeating: 0, count: 4 * Int(MAXPATHLEN))
        guard proc_pidpath(pid, &buffer, UInt32(buffer.count)) > 0 else { return false }
        let path = String(cString: buffer)
        guard let r = path.range(of: ".app/Contents/MacOS/", options: .backwards) else { return false }
        return Bundle(path: String(path[..<r.lowerBound]) + ".app")?.bundleIdentifier == updaterBundleID
    }

    private enum Stage: String {
        case idle, checking, found, downloading, preparing, ready, installing
    }

    private unowned let checker: UpdateChecker
    private let shutdownForUpdate: () -> Void
    private var updater: SPUUpdater?
    private var stage = Stage.idle
    /// The update of the current cycle.
    private var release: UpdateChecker.Release?
    /// Sparkle's question waiting for an answer: update found (Install / Skip / later) or ready to
    /// install (Install and Relaunch / Install on Quit). One at a time; answered once.
    private var reply: ((SPUUserUpdateChoice) -> Void)?
    /// Cancels the running user-initiated check or download.
    private var cancellation: (() -> Void)?
    private var received: UInt64 = 0, expected: UInt64 = 0, extraction = 0.0
    private var shownPercent = -1
    /// A newer version found (not skipped): the menu offers it.
    private(set) var available: UpdateChecker.Release?
    /// Sparkle's installer holds a prepared update: it installs once this app's processes exit.
    private var prepared = false
    /// Install and Relaunch chosen (button or a SteamOS restart): the next question answers Install.
    private var installRequested = false

    init(checker: UpdateChecker, shutdownForUpdate: @escaping () -> Void) {
        self.checker = checker
        self.shutdownForUpdate = shutdownForUpdate
    }

    /// False if Sparkle refuses the configuration (logged; the GitHub check runs instead).
    func start() -> Bool {
        let updater = SPUUpdater(hostBundle: .main, applicationBundle: .main, userDriver: self, delegate: self)
        updater.updateCheckInterval = SparkleUpdates.checkInterval
        updater.automaticallyDownloadsUpdates = false
        updater.automaticallyChecksForUpdates = LauncherSettings.shared.checkForUpdates
        do {
            try updater.start()
        } catch {
            log("update: Sparkle did not start: \(error.localizedDescription)")
            return false
        }
        self.updater = updater
        let version = Bundle(for: SPUUpdater.self).object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "?"
        log("update: in-app updates (Sparkle \(version)) from \(updater.feedURL?.absoluteString ?? "?"), "
            + (updater.automaticallyChecksForUpdates ? "checked every \(Int(SparkleUpdates.checkInterval / 3600)) h" : "automatic checks off"))
        return true
    }

    var feedHost: String? { updater?.feedURL?.host }

    var stateDescription: String {
        "\(stage.rawValue)\(release.map { " \($0.tag)" } ?? ""), prepared \(prepared)"
    }

    func setAutomaticChecks(_ on: Bool) {
        updater?.automaticallyChecksForUpdates = on
        log("update: automatic checks \(on ? "on" : "off")")
    }

    func checkInBackground() {
        updater?.checkForUpdatesInBackground()
    }

    /// Menu "Check for Updates…": a check now (Sparkle shows a cycle already under way instead,
    /// showUpdateInFocus, and resumes a prepared update).
    func menuAction() {
        updater?.checkForUpdates()
    }

    // MARK: panel buttons

    func install(_ r: UpdateChecker.Release) {
        log("update: install \(r.tag): downloading")
        answer(.install)
    }

    func skip() {
        available = nil
        answer(.skip)
    }

    func cancel() {
        log("update: download cancelled")
        let c = cancellation
        cancellation = nil
        c?()
    }

    func installOnQuit() {
        log("update: \(release?.tag ?? "the update") installs when FX Steam Launcher quits")
        answer(.dismiss)
    }

    func installNow(origin: String) {
        installRequested = true
        log("update: \(origin): installing \(release?.tag ?? "the prepared update") and opening the launcher again")
        if stage == .ready, reply != nil {
            answer(.install)
        } else if prepared {
            updater?.checkForUpdates()   // resumes the prepared update: showUpdateFound answers Install
        }
    }

    /// The window closed: a question it showed counts as "later" (found: offered again; ready:
    /// Install on Quit), a check is cancelled; a download goes on in the background.
    func panelClosed() {
        switch stage {
        case .checking:
            let c = cancellation
            cancellation = nil
            c?()
        case .found, .ready:
            answer(.dismiss)
        case .idle, .downloading, .preparing, .installing:
            break
        }
    }

    /// See the type comment; true when the restart installs the prepared update instead.
    func takeOverReboot() -> Bool {
        guard prepared else { return false }
        installNow(origin: "SteamOS is restarting")
        return true
    }

    private func answer(_ choice: SPUUserUpdateChoice) {
        guard let r = reply else { return }
        reply = nil
        r(choice)
    }

    private var rebootPending: Bool {
        Supervisor.runDir.map { FileManager.default.fileExists(atPath: Supervisor.rebootMarker($0)) } ?? false
    }

    private func setPrepared(_ on: Bool) {
        guard prepared != on else { return }
        prepared = on
        guard let dir = Supervisor.runDir else { return }
        let marker = Supervisor.updateMarker(dir)
        if on {
            FileManager.default.createFile(atPath: marker, contents: Data((release?.tag ?? "").utf8))
            log("update: \(release?.tag ?? "update") prepared; it installs when the launcher exits (no further VM boots)")
        } else {
            try? FileManager.default.removeItem(atPath: marker)
        }
    }

    /// Prepared: Install now if that was asked for or SteamOS is restarting already (its reboot
    /// marker would boot the bundle Sparkle is about to replace); else ask.
    private func didPrepare(reply: @escaping (SPUUserUpdateChoice) -> Void, activate: Bool) {
        setPrepared(true)
        if installRequested || rebootPending {
            if !installRequested { log("update: SteamOS is restarting: installing the prepared update instead") }
            installRequested = true
            reply(.install)
            return
        }
        self.reply = reply
        stage = .ready
        if let r = release { checker.show(.ready(r), activate: activate) }
    }

    private static func release(_ item: SUAppcastItem) -> UpdateChecker.Release {
        var notes = item.itemDescription ?? ""
        if (item.itemDescriptionFormat ?? "html") == "html" {
            notes = notes.replacingOccurrences(of: "<[^>]+>", with: "", options: .regularExpression)
        }
        var r = UpdateChecker.Release(tag: item.displayVersionString, version: UpdateChecker.parse(item.displayVersionString) ?? [],
                                      name: item.title ?? "", notes: notes, published: item.date,
                                      page: item.fullReleaseNotesURL ?? item.infoURL, dmg: nil)
        r.inApp = true
        return r
    }

    /// The state of the current cycle in the window.
    private var panelState: UpdatePanel.State? {
        guard let r = release else { return stage == .checking ? .checking : nil }
        switch stage {
        case .idle: return nil
        case .checking: return .checking
        case .found: return .available(r, current: UpdateChecker.currentVersion)
        case .downloading: return .downloading(r, received: received, expected: expected)
        case .preparing: return .preparing(r, progress: extraction)
        case .ready: return .ready(r)
        case .installing: return .installing(r)
        }
    }

    /// Progress: only into a window that is on screen (hidden, the download goes on unseen).
    private func showProgress() {
        guard checker.shownState != nil, let state = panelState else { return }
        let percent = expected > 0 ? Int(received * 100 / max(expected, 1)) : Int(extraction * 100)
        if case .downloading = state, percent == shownPercent { return }
        shownPercent = percent
        checker.show(state, activate: false)
    }

    // MARK: SPUUserDriver

    func show(_ request: SPUUpdatePermissionRequest, reply: @escaping (SUUpdatePermissionResponse) -> Void) {
        // Not asked (updaterShouldPromptForPermissionToCheckForUpdates): Settings decides.
        reply(SUUpdatePermissionResponse(automaticUpdateChecks: LauncherSettings.shared.checkForUpdates, sendSystemProfile: false))
    }

    func showUserInitiatedUpdateCheck(cancellation: @escaping () -> Void) {
        stage = .checking
        release = nil
        self.cancellation = cancellation
        checker.show(.checking, activate: true)
    }

    func showUpdateFound(with appcastItem: SUAppcastItem, state: SPUUserUpdateState, reply: @escaping (SPUUserUpdateChoice) -> Void) {
        let r = SparkleUpdates.release(appcastItem)
        release = r
        cancellation = nil
        available = r
        if state.stage == .installing {
            log("update: \(r.tag) is prepared (\(state.userInitiated ? "menu" : "scheduled check"))")
            didPrepare(reply: reply, activate: state.userInitiated)
            return
        }
        log("update: \(r.tag) available (this launcher: \(UpdateChecker.currentVersion), \(state.userInitiated ? "menu" : "scheduled check"))")
        self.reply = reply
        stage = .found
        checker.show(.available(r, current: UpdateChecker.currentVersion), activate: state.userInitiated)
    }

    func showUpdateReleaseNotes(with downloadData: SPUDownloadData) {
        // The feed embeds the notes (updater(_:shouldDownloadReleaseNotesForUpdate:) is false).
        guard let r = release, let text = String(data: downloadData.data, encoding: .utf8) else { return }
        release = UpdateChecker.Release(tag: r.tag, version: r.version, name: r.name, notes: text, published: r.published,
                                        page: r.page, dmg: nil, inApp: true)
        if stage == .found, checker.shownState != nil, let state = panelState { checker.show(state, activate: false) }
    }

    func showUpdateReleaseNotesFailedToDownloadWithError(_ error: Error) {
        log("update: release notes not downloaded: \(error.localizedDescription)")
    }

    func showUpdateNotFoundWithError(_ error: Error, acknowledgement: @escaping () -> Void) {
        acknowledgement()
        stage = .idle
        if !prepared { available = nil }
        let e = error as NSError
        let reason = (e.userInfo[SPUNoUpdateFoundReasonKey] as? NSNumber).flatMap { SPUNoUpdateFoundReason(rawValue: $0.int32Value) }
        let note: String?
        switch reason {
        case .systemIsTooOld?, .systemIsTooNew?, .hardwareDoesNotSupportARM64?: note = e.localizedRecoverySuggestion
        default: note = nil
        }
        log("update: up to date (\(UpdateChecker.currentVersion))" + (note.map { "; \($0)" } ?? ""))
        checker.show(.upToDate(current: UpdateChecker.currentVersion, note: note), activate: false)
    }

    func showUpdaterError(_ error: Error, acknowledgement: @escaping () -> Void) {
        acknowledgement()
        let e = error as NSError
        let message = [e.localizedDescription, e.localizedRecoverySuggestion].compactMap { $0 }.joined(separator: " ")
        log("update: error \(e.domain) \(e.code): \(e.localizedDescription)"
            + ((e.userInfo[NSUnderlyingErrorKey] as? NSError).map { " (\($0.localizedDescription))" } ?? ""))
        let installing = [.downloading, .preparing, .ready, .installing].contains(stage)
        stage = .idle
        reply = nil
        cancellation = nil
        if installing {
            setPrepared(false)
            installRequested = false
            checker.show(.installFailed(message), activate: false)
        } else if checker.shownState != nil {
            checker.show(.failed(message), activate: false)
        }
    }

    func showDownloadInitiated(cancellation: @escaping () -> Void) {
        stage = .downloading
        self.cancellation = cancellation
        received = 0
        expected = 0
        shownPercent = -1
        if let state = panelState { checker.show(state, activate: false) }
    }

    func showDownloadDidReceiveExpectedContentLength(_ expectedContentLength: UInt64) {
        expected = expectedContentLength
        received = 0
        log("update: downloading \(ByteCountFormatter.string(fromByteCount: Int64(clamping: expectedContentLength), countStyle: .file))")
        showProgress()
    }

    func showDownloadDidReceiveData(ofLength length: UInt64) {
        received += length
        showProgress()
    }

    func showDownloadDidStartExtractingUpdate() {
        log("update: downloaded; preparing")
        stage = .preparing
        cancellation = nil
        extraction = 0
        shownPercent = -1
        showProgress()
    }

    func showExtractionReceivedProgress(_ progress: Double) {
        extraction = progress
        showProgress()
    }

    func showReady(toInstallAndRelaunch reply: @escaping (SPUUserUpdateChoice) -> Void) {
        didPrepare(reply: reply, activate: false)
    }

    func showInstallingUpdate(withApplicationTerminated applicationTerminated: Bool, retryTerminatingApplication: @escaping () -> Void) {
        // Termination is SteamOS's shutdown (Lifecycle), already under way: retrying would only
        // send another quit request.
        stage = .installing
        log("update: installing \(release?.tag ?? "the update") once the launcher has exited")
        if let state = panelState { checker.show(state, activate: false) }
    }

    func showUpdateInstalledAndRelaunched(_ relaunched: Bool, acknowledgement: @escaping () -> Void) {
        acknowledgement()
        setPrepared(false)
        log("update: installed\(relaunched ? " and relaunched" : "")")
    }

    func showUpdateInFocus() {
        if let state = panelState { checker.show(state, activate: true) }
    }

    func dismissUpdateInstallation() {
        reply = nil
        cancellation = nil
        stage = .idle
        // The cycle is over: its questions and progress go; results (up to date, errors) stay.
        switch checker.shownState {
        case .checking?, .available?, .downloading?, .preparing?, .ready?: checker.closePanel()
        default: break
        }
    }

    // MARK: SPUUpdaterDelegate

    func updaterShouldPromptForPermissionToCheck(forUpdates updater: SPUUpdater) -> Bool { false }

    func feedURLString(for updater: SPUUpdater) -> String? {
        ProcessInfo.processInfo.environment[SparkleUpdates.feedEnv].flatMap { $0.isEmpty ? nil : $0 }
    }

    func updater(_ updater: SPUUpdater, shouldDownloadReleaseNotesForUpdate updateItem: SUAppcastItem) -> Bool { false }

    /// Before Sparkle asks this app to quit for Install and Relaunch: SteamOS powers off first.
    func updater(_ updater: SPUUpdater, shouldPostponeRelaunchForUpdate item: SUAppcastItem,
                 untilInvokingBlock installHandler: @escaping () -> Void) -> Bool {
        log("update: shutting SteamOS down to install \(item.displayVersionString)")
        stage = .installing
        if let state = panelState { checker.show(state, activate: false) }
        shutdownForUpdate()
        return false
    }

    func updater(_ updater: SPUUpdater, didFinishUpdateCycleFor updateCheck: SPUUpdateCheck, error: Error?) {
        guard let error else { return }
        let e = error as NSError
        if e.domain == SUSparkleErrorDomain, e.code == Int(SUError.noUpdateError.rawValue) { return }
        log("update: cycle ended: \(e.localizedDescription)")
    }
}
