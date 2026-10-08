import AppKit
import SwiftUI

/// "Send crash reports and diagnostics" (CrashReporting): Settings > General, the first-run
/// alert (SteamClientPicker.alertAccessoryView) and the Create SteamOS Disk sheet. Bound to
/// `sendCrashReports`; the VM process applies a change right away, the supervisor before the
/// next boot or report.
struct CrashReportsToggle: View {
    @ObservedObject var settings: LauncherSettings
    /// Settings window: the "applies now" / command-line override captions.
    var showsApplies = false
    /// First-run alert and Create SteamOS Disk sheet: a checkbox (Settings uses switches).
    var checkbox = false
    @State private var showDetails = false

    var body: some View {
        let toggle = Toggle(isOn: $settings.sendCrashReports) {
            VStack(alignment: .leading, spacing: 2) {
                Text("Send crash reports and diagnostics")
                Text(tr(CrashReporting.summary))
                    .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                Button("What is sent") { showDetails.toggle() }
                    .buttonStyle(.link)
                    .font(.caption)
                    .popover(isPresented: $showDetails, arrowEdge: .bottom) { WhatIsSentView() }
                if showsApplies {
                    Text("applies now").font(.caption).foregroundStyle(.secondary)
                    if let flag = settings.overrides[.sendCrashReports] {
                        Text(tr("overridden by command line (%@)", flag)).font(.caption).foregroundStyle(.red)
                    }
                }
            }
        }
        if checkbox { toggle.toggleStyle(.checkbox) } else { toggle }
    }
}

/// The "What is sent" popover (also captured by --selftest-settings).
struct WhatIsSentView: View {
    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("What is sent").font(.headline)
            ForEach(CrashReporting.whatIsSent, id: \.self) { item in
                HStack(alignment: .firstTextBaseline, spacing: 6) {
                    Text("•")
                    Text(tr(item)).fixedSize(horizontal: false, vertical: true)
                }
                .font(.callout)
            }
            Text(tr("Reports go to the developers' own Sentry server (sentry.fxgam.es). Turn this off any time in "
                  + "Settings > General, or for one run with --no-crash-reports / STEAMAC_SENTRY=0."))
                .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
        }
        .padding(16)
        .frame(width: 420, alignment: .leading)
    }
}
