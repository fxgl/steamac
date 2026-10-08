import AppKit
import SwiftUI

/// The Report a Problem sheet (Report.swift collects and sends). Opened from Help / the app menu,
/// Settings > General, the stall card's "Report…" link and the offer after an unexpected VM exit
/// (CrashOffer, supervisor process); the control FIFO drives it in tests (ReportControl).
@MainActor
final class ReportModel: ObservableObject {
    enum Phase: Equatable { case editing, working, sent(String), failed(String) }

    static let emailKey = "reportEmail"

    @Published var email: String
    @Published var text = ""
    @Published var choices = ReportChoices()
    @Published private(set) var phase = Phase.editing
    @Published private(set) var status = ""
    /// Upload fraction; nil while collecting.
    @Published private(set) var progress: Double?
    let context: ReportContext
    /// Tag the event test=true (control FIFO / crash-offer test runs).
    var test = false
    var onClose: ((_ sent: Bool) -> Void)?
    private(set) var bundle: ReportBundle?
    private var task: Task<Void, Never>?

    init(context: ReportContext) {
        self.context = context
        email = LauncherSettings.shared.defaults.string(forKey: ReportModel.emailKey) ?? ""
    }

    var emailValid: Bool {
        email.trimmingCharacters(in: .whitespaces).range(of: "^[^@\\s]+@[^@\\s]+\\.[A-Za-z]{2,}$", options: .regularExpression) != nil
    }
    var textValid: Bool { text.trimmingCharacters(in: .whitespacesAndNewlines).count >= 10 }
    var canSend: Bool { emailValid && textValid && phase == .editing }
    var hasWindow: Bool { context.captureScreenshot != nil }
    var savedPath: String { bundle.map { ($0.dir as NSString).abbreviatingWithTildeInPath } ?? "" }

    // MARK: actions

    /// Collect (unless the folder already matches the choices) and show it in Finder.
    func preview(reveal: Bool = true) {
        guard phase == .editing else { return }
        task = Task {
            guard let b = await ensureBundle() else { return }
            b.writeReport(email: email.trimmingCharacters(in: .whitespaces), description: text)
            phase = .editing
            log("report: preview \(b.dir)")
            if reveal { NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: b.dir)]) }
        }
    }

    func send() {
        guard canSend else { return }
        let address = email.trimmingCharacters(in: .whitespaces)
        LauncherSettings.shared.defaults.set(address, forKey: ReportModel.emailKey)
        task = Task {
            guard let b = await ensureBundle() else { return }
            b.writeReport(email: address, description: text)
            status = String(localized: "Sending the report…")
            progress = 0
            do {
                let id = try await FeedbackSender.send(b, email: address, description: text, test: test) { p in
                    Task { @MainActor [weak self] in self?.progress = p }
                }
                b.delete()
                bundle = nil
                phase = .sent(String(id.prefix(8)))
                log("report: sent, report ID \(id.prefix(8))")
            } catch {
                guard !Task.isCancelled else { return }
                phase = .failed(error.localizedDescription)
                log("report: sending \(b.shortId) failed: \(error); kept in \(b.dir)")
            }
        }
    }

    func retry() {
        guard case .failed = phase else { return }
        phase = .editing
        send()
    }

    func reveal() {
        if let b = bundle { NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: b.dir)]) }
    }

    /// Cancel / Close / Done. A report that failed to send stays on disk; anything else collected is removed.
    func close() {
        task?.cancel()
        var sent = false, kept = false
        switch phase {
        case .failed: kept = bundle != nil
        case .sent: sent = true
        default: bundle?.delete()
        }
        log("report: dialog closed" + (kept ? " (report kept in \(bundle!.dir))" : ""))
        onClose?(sent)
    }

    private func ensureBundle() async -> ReportBundle? {
        if let b = bundle, b.choices == choices, FileManager.default.fileExists(atPath: b.dir) { return b }
        bundle?.delete()
        bundle = nil
        phase = .working
        progress = nil
        do {
            let b = try await ReportBundle.collect(context: context, choices: choices) { [weak self] s in self?.status = s }
            if Task.isCancelled { b.delete(); return nil }
            bundle = b
            return b
        } catch {
            phase = .failed(String(localized: "Cannot create the report folder: \(error.localizedDescription)"))
            return nil
        }
    }
}

struct ReportView: View {
    @ObservedObject var model: ReportModel

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            switch model.phase {
            case .sent(let id): sent(id)
            case .failed(let message): failed(message)
            case .editing, .working: form
            }
        }
        .padding(20)
        .frame(width: 540, alignment: .leading)
    }

    private func header(_ symbol: String, _ color: Color, _ title: LocalizedStringResource, _ detail: String?) -> some View {
        HStack(alignment: .top, spacing: 12) {
            Image(systemName: symbol).font(.system(size: 28)).foregroundStyle(color)
            VStack(alignment: .leading, spacing: 3) {
                Text(title).font(.title3.weight(.semibold))
                if let detail {
                    Text(verbatim: detail).font(.callout).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                }
            }
        }
    }

    private var working: Bool { model.phase == .working }

    private var form: some View {
        VStack(alignment: .leading, spacing: 14) {
            header("exclamationmark.bubble.fill", .accentColor, "Report a Problem",
                   String(localized: "Describe what went wrong. Your description, your email and the items checked below go to the FX Steam Launcher developers (sentry.fxgam.es)."))
            VStack(alignment: .leading, spacing: 4) {
                Text("Email").font(.callout.weight(.medium))
                TextField("you@example.com", text: $model.email).textFieldStyle(.roundedBorder)
                Text(verbatim: !model.email.isEmpty && !model.emailValid ? String(localized: "Enter a valid email address.")
                     : String(localized: "So the developers can reply. Remembered on this Mac."))
                    .font(.caption).foregroundStyle(!model.email.isEmpty && !model.emailValid ? Color.red : Color.secondary)
            }
            VStack(alignment: .leading, spacing: 4) {
                Text("What happened?").font(.callout.weight(.medium))
                ZStack(alignment: .topLeading) {
                    TextEditor(text: $model.text)
                        .font(.body)
                        .scrollContentBackground(.hidden)
                        .padding(4)
                        .frame(height: 110)
                        .background(Color(nsColor: .textBackgroundColor))
                        .overlay(RoundedRectangle(cornerRadius: 5).stroke(Color.secondary.opacity(0.4)))
                    if model.text.isEmpty {
                        Text("What you did, what you expected and what happened instead (game, settings, since when)…")
                            .foregroundStyle(.tertiary).padding(.horizontal, 9).padding(.vertical, 4).allowsHitTesting(false)
                    }
                }
                if !model.text.isEmpty && !model.textValid {
                    Text("A few more words, please (at least 10 characters).").font(.caption).foregroundStyle(.secondary)
                }
            }
            VStack(alignment: .leading, spacing: 8) {
                check($model.choices.launcherLogs, "Include launcher logs",
                      String(localized: "This session's launcher, libkrun, virglrenderer and MoltenVK messages and perf/stall lines (last ~2 MB; home folder paths shortened to ~, your user and computer names removed)."))
                check($model.choices.guestLogs, "Include SteamOS logs (system journal, Steam/Proton logs)",
                      model.context.guest != nil
                        ? String(localized: "The SteamOS console, this boot's system journal, coredumps, dmesg, Steam client logs and Proton logs. Steam IDs, account names and email addresses are removed where recognisable.")
                        : String(localized: "SteamOS is not running: only its console log of this session is included."))
                check($model.choices.screenshot, "Include a screenshot of the VM window",
                      model.hasWindow ? String(localized: "Off by default: the picture may show your Steam account name, friends or other personal information.")
                                      : String(localized: "No VM window is open."))
                    .disabled(!model.hasWindow)
            }
            .disabled(working)
            VStack(alignment: .leading, spacing: 3) {
                Text("Always included: app, macOS and library versions, Mac model, GPU, disk sizes and the launcher settings (never passwords or Keychain items).")
                if CrashReporting.statusSummary != "on" {
                    Text("Crash reports are off. Sending this report does not turn them on: only this report is sent.")
                }
            }
            .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            if working {
                HStack(spacing: 8) {
                    if let p = model.progress {
                        ProgressView(value: p).frame(width: 160)
                    } else {
                        ProgressView().controlSize(.small)
                    }
                    Text(verbatim: model.status).font(.callout).foregroundStyle(.secondary)
                }
            }
            HStack {
                Button("Show What Will Be Sent") { model.preview() }
                    .disabled(working)
                Spacer()
                Button("Cancel", role: .cancel) { model.close() }
                    .keyboardShortcut(.cancelAction)
                Button("Send") { model.send() }
                    .keyboardShortcut(.defaultAction)
                    .disabled(!model.canSend)
            }
        }
    }

    private func check(_ on: Binding<Bool>, _ title: LocalizedStringResource, _ detail: String) -> some View {
        Toggle(isOn: on) {
            VStack(alignment: .leading, spacing: 1) {
                Text(title)
                Text(verbatim: detail).font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            }
        }
        .toggleStyle(.checkbox)
    }

    private func sent(_ id: String) -> some View {
        VStack(alignment: .leading, spacing: 14) {
            header("checkmark.circle.fill", .green, "Report sent — thank you!", nil)
            HStack(spacing: 6) {
                Text("Report ID:")
                Text(verbatim: id).font(.body.monospaced().weight(.semibold)).textSelection(.enabled)
            }
            Text("Mention this ID if you contact the developers about this problem.")
                .font(.callout).foregroundStyle(.secondary)
            HStack {
                Spacer()
                Button("Done") { model.close() }.keyboardShortcut(.defaultAction)
            }
        }
    }

    private func failed(_ message: String) -> some View {
        VStack(alignment: .leading, spacing: 14) {
            header("exclamationmark.triangle.fill", .orange, "The report could not be sent", message)
            if !model.savedPath.isEmpty {
                Text("It was saved in \(model.savedPath). Try again later, or send that folder to the developers by email.")
                    .font(.callout).fixedSize(horizontal: false, vertical: true).textSelection(.enabled)
            }
            HStack {
                Button("Reveal in Finder") { model.reveal() }.disabled(model.savedPath.isEmpty)
                Spacer()
                Button("Close") { model.close() }.keyboardShortcut(.cancelAction)
                Button("Retry") { model.retry() }.keyboardShortcut(.defaultAction).disabled(model.savedPath.isEmpty)
            }
        }
    }
}

/// The sheet on a window (one at a time per process).
@MainActor
final class ReportSheet {
    private static var current: ReportSheet?
    let window: NSWindow
    let model: ReportModel
    private weak var parent: NSWindow?

    private init(window: NSWindow, model: ReportModel, parent: NSWindow) {
        self.window = window
        self.model = model
        self.parent = parent
    }

    static var model: ReportModel? { current?.model }
    static var sheetWindow: NSWindow? { current?.window }

    /// `onClose(sent)` runs after the sheet is gone.
    @discardableResult
    static func present(on parent: NSWindow, context: ReportContext, onClose: ((Bool) -> Void)? = nil) -> ReportModel {
        if let c = current {
            c.window.makeKeyAndOrderFront(nil)
            return c.model
        }
        let model = ReportModel(context: context)
        let host = NSHostingController(rootView: ReportView(model: model))
        host.sizingOptions = [.preferredContentSize]
        let w = NSWindow(contentViewController: host)
        w.styleMask = [.titled]
        w.title = String(localized: "Report a Problem")
        let sheet = ReportSheet(window: w, model: model, parent: parent)
        model.onClose = { [weak sheet] sent in
            sheet?.dismiss()
            onClose?(sent)
        }
        current = sheet
        NSApp.activate()
        parent.makeKeyAndOrderFront(nil)
        parent.beginSheet(w)
        log("report: dialog opened (\(context.origin))")
        return model
    }

    private func dismiss() {
        if let parent { parent.endSheet(window) }
        window.orderOut(nil)
        if ReportSheet.current === self { ReportSheet.current = nil }
    }
}

// MARK: - after an unexpected VM exit (supervisor)

/// Supervisor, after the VM process ended unexpectedly: a small non-modal window "FX Steam
/// Launcher stopped unexpectedly" with Report… (the sheet, without a guest or screenshot) and
/// Close; returns once it is closed. STEAMAC_REPORT_DUMP=<dir> (tests): PNGs of the window and the
/// sheet, then it closes by itself; with STEAMAC_REPORT_TEST_SEND=1 it also sends a test report.
@MainActor
enum CrashOffer {
    nonisolated static let dumpEnv = "STEAMAC_REPORT_DUMP"
    private static var window: NSWindow?
    private static let delegate = OfferDelegate()

    /// Not for headless runs, nor `--sentry-test-crash` (scripted) unless a test dump is asked for.
    nonisolated static func wanted(_ o: Options) -> Bool {
        !o.headless && (o.sentryTestCrash == nil || ProcessInfo.processInfo.environment[dumpEnv] != nil)
    }

    static func run(status: Int32, options: Options, runDir: String) {
        let summary = CrashReporting.exitSummary(status: status)
        log("report: offering a problem report (\(summary))")
        let app = NSApplication.shared
        app.setActivationPolicy(.regular)
        app.delegate = delegate
        MainMenu.installMinimal()
        let context = ReportContext(origin: "crash", options: options, runDir: runDir, exitSummary: summary)
        let w = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 460, height: 150), styleMask: [.titled, .closable],
                         backing: .buffered, defer: false)
        w.title = "FX Steam Launcher"
        w.isReleasedWhenClosed = false
        w.delegate = delegate
        let view = OfferView(summary: CrashReporting.localizedExitSummary(status: status), report: {
            ReportSheet.present(on: w, context: context) { sent in if sent { w.close() } }
        }, close: { w.close() })
        let host = NSHostingView(rootView: view)
        host.frame.size = host.fittingSize
        w.setContentSize(host.fittingSize)
        w.contentView = host
        window = w
        w.center()
        app.activate()
        w.makeKeyAndOrderFront(nil)
        if let dir = ProcessInfo.processInfo.environment[dumpEnv] { selfTest(dir: dir, window: w, context: context) }
        app.run()
        window = nil
        log("report: crash offer closed")
    }

    /// Supervisor signal (Ctrl+C in the terminal): close the offer.
    static func dismiss() { window?.close() }

    fileprivate static func stop() {
        NSApp.stop(nil)
        // stop() takes effect after the next event.
        if let e = NSEvent.otherEvent(with: .applicationDefined, location: .zero, modifierFlags: [], timestamp: 0,
                                      windowNumber: 0, context: nil, subtype: 0, data1: 0, data2: 0) {
            NSApp.postEvent(e, atStart: false)
        }
    }

    private static func selfTest(dir: String, window w: NSWindow, context: ReportContext) {
        try? FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
        let send = ProcessInfo.processInfo.environment["STEAMAC_REPORT_TEST_SEND"] == "1"
        Task { @MainActor in
            try? await Task.sleep(for: .seconds(1))
            ReportControl.dump(w, to: dir + "/crash-offer.png")
            let model = ReportSheet.present(on: w, context: context)
            model.test = true
            model.email = "test@fxgam.es"
            model.text = "TEST REPORT — please ignore (crash offer self-test)"
            try? await Task.sleep(for: .seconds(1.5))
            if let s = ReportSheet.sheetWindow { ReportControl.dump(s, to: dir + "/crash-offer-report.png") }
            if send {
                model.send()
                while model.phase == .editing || model.phase == .working { try? await Task.sleep(for: .milliseconds(200)) }
                try? await Task.sleep(for: .milliseconds(500))
                if let s = ReportSheet.sheetWindow { ReportControl.dump(s, to: dir + "/crash-offer-result.png") }
            }
            model.close()
            w.close()
        }
    }

    private struct OfferView: View {
        let summary: String
        let report: () -> Void
        let close: () -> Void

        var body: some View {
            HStack(alignment: .top, spacing: 14) {
                Image(nsImage: NSApp.applicationIconImage).resizable().frame(width: 56, height: 56)
                VStack(alignment: .leading, spacing: 8) {
                    Text("FX Steam Launcher stopped unexpectedly").font(.headline)
                    Text("The virtual machine ended without being asked to (\(summary)).")
                        .font(.callout).fixedSize(horizontal: false, vertical: true)
                    Text("Report it with the logs of this session so the developers can look into it.")
                        .font(.callout).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                    HStack {
                        Spacer()
                        Button("Close", action: close).keyboardShortcut(.cancelAction)
                        Button("Report…", action: report).keyboardShortcut(.defaultAction)
                    }
                    .padding(.top, 4)
                }
            }
            .padding(20)
            .frame(width: 460, alignment: .leading)
        }
    }

    private final class OfferDelegate: NSObject, NSApplicationDelegate, NSWindowDelegate {
        func windowWillClose(_ notification: Notification) {
            guard (notification.object as? NSWindow) === CrashOffer.window else { return }
            DispatchQueue.main.async { CrashOffer.stop() }
        }

        /// Quit (Cmd+Q): end the offer; the supervisor then cleans up and exits.
        func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
            CrashOffer.window?.close()
            return .terminateCancel
        }
    }
}

// MARK: - control FIFO

/// `--control-fifo` commands (VM process):
///   report open                         the sheet over the VM window
///   report fill EMAIL TEXT…             email + description (and tag the event test=true)
///   report include launcher|steamos|screenshot on|off
///   report preview                      collect the folder (logged; not shown in Finder)
///   report send | retry | close
///   report dsn DSN|default              send to another DSN (failure-path tests)
///   report dump PATH                    PNG of the sheet
@MainActor
enum ReportControl {
    /// Opens the sheet (main.swift).
    static var open: (() -> Void)?

    static func handle(_ args: [String]) {
        guard let verb = args.first else { return }
        if verb == "open" { open?(); return }
        if verb == "dsn" {
            FeedbackSender.dsnOverride = args.count > 1 && args[1] != "default" ? args[1] : nil
            log("control: report DSN \(FeedbackSender.dsnOverride ?? "default")")
            return
        }
        guard let model = ReportSheet.model else { log("control: report: no dialog open"); return }
        switch verb {
        case "fill":
            guard args.count >= 3 else { break }
            model.email = args[1]
            model.text = args.dropFirst(2).joined(separator: " ")
            model.test = true
        case "include":
            guard args.count == 3 else { break }
            let on = args[2] == "on"
            switch args[1] {
            case "launcher": model.choices.launcherLogs = on
            case "steamos": model.choices.guestLogs = on
            case "screenshot": model.choices.screenshot = on
            default: log("control: report include: launcher, steamos or screenshot")
            }
        case "preview": model.preview(reveal: false)
        case "send": model.send()
        case "retry": model.retry()
        case "close": model.close()
        case "dump":
            if let w = ReportSheet.sheetWindow { dump(w, to: args.count > 1 ? args[1] : "report.png") }
        default: log("control: unknown report command")
        }
    }

    static func dump(_ window: NSWindow, to path: String) {
        guard let rep = SettingsWindowController.snapshot(window), let png = rep.representation(using: .png, properties: [:]) else {
            log("report: dump of \(path) failed")
            return
        }
        do {
            try png.write(to: URL(fileURLWithPath: path))
            log("report: window dumped to \(path)")
        } catch {
            log("report: dump of \(path) failed: \(error)")
        }
    }
}
