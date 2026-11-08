import AppKit
import Darwin
import Foundation
import Security
import UniformTypeIdentifiers

/// Running inside "FX Steam Launcher.app" (build.sh / bundle.sh): the kernel, initramfs, layer
/// disk, gvproxy, desync and Valve's RAUC CA are bundled in Contents/Resources; the SteamOS disk
/// comes from Settings > Advanced "Disk image", else the default locations below. Never copied
/// anywhere: the user picks an existing image or creates a new one (DiskCreator).
enum AppBundle {
    /// Contents/Resources when this executable lives in an .app bundle.
    static var resources: String? {
        Bundle.main.bundlePath.hasSuffix(".app") ? Bundle.main.resourcePath : nil
    }

    /// Release defaults (Info.plist `SteamacReleaseDefaults`, set by bundle.sh for the .app):
    /// SSH off and no default guest password on created disks. The dev launcher has neither.
    static var releaseDefaults: Bool {
        Bundle.main.object(forInfoDictionaryKey: "SteamacReleaseDefaults") as? Bool ?? false
    }

    /// A local copy may have lost a resource even when the published DMG is complete
    /// (STEAMAC-8K). Paths are kept in the local log, not in the warning's diagnostic fields.
    struct InstallationFailure: LocalizedError, CustomStringConvertible {
        let diagnostics: [String: String]
        var description: String {
            "The FX Steam Launcher installation is incomplete: its SteamOS download tool (desync) is missing, unreadable or not executable. Download the latest DMG again and copy FX Steam Launcher to Applications, replacing the old copy. Check security software for a blocked or removed desync file, then try again."
        }
        var errorDescription: String? {
            String(localized: "The FX Steam Launcher installation is incomplete: its SteamOS download tool (desync) is missing, unreadable or not executable. Download the latest DMG again and copy FX Steam Launcher to Applications, replacing the old copy. Check security software for a blocked or removed desync file, then try again.")
        }
    }

    struct ResourceStatus {
        let regular: Bool
        let readable: Bool
        let executable: Bool
        let statError: Int32
        var usable: Bool { regular && readable && executable }
        var presence: String { statError == 0 ? "present" : (statError == ENOENT ? "missing" : "unavailable") }

        init(path: String) {
            var st = stat()
            let result = stat(path, &st)
            statError = result == 0 ? 0 : errno
            regular = result == 0 && (st.st_mode & S_IFMT) == S_IFREG
            readable = access(path, R_OK) == 0
            executable = access(path, X_OK) == 0
        }
    }

    /// App Translocation's containing directory is a stable macOS path marker. This avoids
    /// linking private Security.framework translocation APIs.
    static func isTranslocated(_ bundleURL: URL) -> Bool {
        bundleURL.pathComponents.contains("AppTranslocation")
    }

    /// Only runs after a required bundled tool failed its availability check.
    static func installationFailure(bundleURL: URL, desync: ResourceStatus) -> InstallationFailure {
        let resources = bundleURL.appendingPathComponent("Contents/Resources", isDirectory: true)
        var diagnostics = [
            "translocated": String(isTranslocated(bundleURL)),
            "translocation_check": "bundle path component",
            "desync_presence": desync.presence,
            "desync_stat_errno": String(desync.statError),
            "desync_regular_file": String(desync.regular),
            "desync_readable": String(desync.readable),
            "desync_executable": String(desync.executable),
        ]
        do {
            let entries = try FileManager.default.contentsOfDirectory(at: resources, includingPropertiesForKeys: nil)
                .sorted { $0.lastPathComponent < $1.lastPathComponent }
            diagnostics["resources_count"] = String(entries.count)
            diagnostics["resources_listing"] = entries.map { entry in
                var st = stat()
                let size = lstat(entry.path, &st) == 0 ? String(st.st_size) : "unknown"
                let relative = "Contents/Resources/" + entry.lastPathComponent
                return "\(relative.debugDescription) size=\(size)"
            }.joined(separator: "\n")
        } catch {
            let e = error as NSError
            diagnostics["resources_listing_error"] = "\(e.domain) \(e.code)"
        }
        var code: SecStaticCode?
        let created = SecStaticCodeCreateWithPath(bundleURL as CFURL, SecCSFlags(), &code)
        diagnostics["code_signature_create_status"] = String(created)
        if created == errSecSuccess, let code {
            let flags = SecCSFlags(rawValue: kSecCSStrictValidate | kSecCSCheckAllArchitectures | kSecCSCheckNestedCode)
            let validity = SecStaticCodeCheckValidity(code, flags, nil)
            diagnostics["code_signature_validity_status"] = String(validity)
            diagnostics["code_signature_valid"] = String(validity == errSecSuccess)
        } else {
            diagnostics["code_signature_valid"] = "unknown"
            diagnostics["code_signature_validity_status"] = "not checked (code creation failed)"
        }
        log("installation: bundle path \(bundleURL.path)")
        for key in diagnostics.keys.sorted() { log("installation: \(key)=\(diagnostics[key]!)") }
        return InstallationFailure(diagnostics: diagnostics)
    }

    static var appSupportDir: String {
        NSHomeDirectory() + "/Library/Application Support/" + LauncherSettings.defaultDomain
    }

    static var logPath: String {
        NSHomeDirectory() + "/Library/Logs/" + LauncherSettings.defaultDomain + "/steamac-vm.log"
    }

    /// Where a disk is looked for when Settings has none: Application Support, then the repo's
    /// work/out (next to the bundle, or the build tree recorded in Info.plist at bundle time).
    static func defaultDiskCandidates() -> [String] {
        var c = [appSupportDir + "/steamos.img"]
        let sibling = (Bundle.main.bundlePath as NSString).deletingLastPathComponent + "/steamos.img"
        if resources != nil { c.append(sibling) }
        if let out = Bundle.main.object(forInfoDictionaryKey: "SteamacBuildOut") as? String {
            let p = out + "/steamos.img"
            if !c.contains(p) { c.append(p) }
        }
        return c
    }

    static func defaultDisk() -> String? {
        defaultDiskCandidates().first(where: isDiskImage)
    }

    /// Validate the raw SteamOS GPT, not its suffix: recovery archives and Steam's macOS
    /// installer are readable files too, but cannot boot (STEAMAC-7Y/7Z).
    static func isDiskImage(_ path: String) -> Bool {
        var directory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: path, isDirectory: &directory), !directory.boolValue,
              let table = try? GPT.read(path: path, allowAlignedUsableRange: BazziteGuest.exists(path)) else { return false }
        if BazziteGuest.exists(path), let guest = try? BazziteGuest.load(path),
           table.sectors * 512 == UInt64(guest.diskBytes),
           [guest.kernel.name, guest.initrd.name].allSatisfy({ FileManager.default.isReadableFile(atPath: BazziteGuest.directory(path) + "/" + $0) }) { return true }
        return DiskLayout.parts(homeGiB: DiskLayout.defaultHomeGiB).allSatisfy { part in
            var matches = 0
            for entry in table.entries where entry.name == part.name {
                guard entry.type == part.type else { return false }
                matches += 1
            }
            return matches == 1
        }
    }

    static var invalidDiskMessage: String {
        String(localized: "Choose a SteamOS raw GPT disk or a Bazzite disk with its matching .bazzite boot folder. Use Create New Disk to download a build.")
    }

    /// Shared by both disk pickers: do not save a bad selection or silently ignore it.
    @MainActor
    static func acceptDiskSelection(_ path: String) -> Bool {
        guard isDiskImage(path) else {
            let alert = NSAlert()
            alert.messageText = String(localized: "Not a usable guest disk")
            alert.informativeText = (path as NSString).abbreviatingWithTildeInPath + "\n\n" + invalidDiskMessage
            alert.runModal()
            return false
        }
        return true
    }

    /// "Choose a guest disk image" panels (first run, Settings > Advanced): files only, no
    /// packages (public.data excludes bundles and folders; a raw image of any name conforms).
    static func configureDiskPanel(_ panel: NSOpenPanel) {
        panel.title = String(localized: "Choose a guest disk image")
        panel.canChooseFiles = true
        panel.canChooseDirectories = false
        panel.allowsMultipleSelection = false
        panel.treatsFilePackagesAsDirectories = false
        panel.allowedContentTypes = [.data]
    }

    /// The disk the next start uses (Settings value or default), nil if none is usable.
    static func configuredDisk(_ settings: LauncherSettings) -> String? {
        if !settings.diskImage.isEmpty {
            return isDiskImage(settings.diskImage) ? settings.diskImage : nil
        }
        return defaultDisk()
    }

    /// Bundle defaults for what the command line did not give.
    static func fill(_ o: inout Options, settings: LauncherSettings, overrides: inout [LauncherSettings.Key: String]) {
        guard let res = resources else { return }
        if o.kernel.isEmpty { o.kernel = res + "/Image" }
        if o.initrd == nil && !o.explicit.contains("--kernel") { o.initrd = res + "/initramfs.cpio.gz" }
        if o.gvproxyPath == nil, FileManager.default.isExecutableFile(atPath: res + "/gvproxy") {
            o.gvproxyPath = res + "/gvproxy"
        }
        // SIGUSR1 frame dumps: the app's working directory is / (not writable).
        if !o.explicit.contains("--frame-dump") {
            let dir = (logPath as NSString).deletingLastPathComponent
            try? FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
            o.frameDumpPath = dir + "/steamac-frame.png"
        }
        guard o.disks.isEmpty else { return }
        guard let disk = configuredDisk(settings) else {
            o.needsDisk = true
            return
        }
        o.disks = [DiskSpec(path: disk, readOnly: false)]
        if !BazziteGuest.exists(disk) {
            o.disks.append(DiskSpec(path: res + "/steamac-layer.img", readOnly: true))
        }
    }

    /// Finder / `open` launch: stdout and stderr are /dev/null, so the guest console and the
    /// launcher log are appended to ~/Library/Logs/es.fxgam.steamac/steamac-vm.log instead
    /// (rotated at 64 MiB). Running Contents/MacOS/steamac-vm from a shell keeps the terminal/pipes.
    static var outputDiscarded: Bool {
        var null = stat(), out = stat(), err = stat()
        guard stat("/dev/null", &null) == 0, fstat(STDOUT_FILENO, &out) == 0, fstat(STDERR_FILENO, &err) == 0 else { return false }
        return (out.st_rdev, err.st_rdev) == (null.st_rdev, null.st_rdev)
            && (out.st_mode & S_IFMT) == S_IFCHR && (err.st_mode & S_IFMT) == S_IFCHR
    }

    static func redirectOutputIfLaunchedFromFinder() {
        guard resources != nil, outputDiscarded else { return }
        let path = logPath
        try? FileManager.default.createDirectory(atPath: (path as NSString).deletingLastPathComponent,
                                                 withIntermediateDirectories: true)
        var st = stat()
        if stat(path, &st) == 0, st.st_size > 64 << 20 {
            rename(path, (path as NSString).deletingPathExtension + ".old.log")
        }
        let fd = open(path, O_WRONLY | O_CREAT | O_APPEND, 0o644)
        guard fd >= 0 else { return }
        dup2(fd, STDOUT_FILENO)
        dup2(fd, STDERR_FILENO)
        close(fd)
        let stamp = ISO8601DateFormatter().string(from: Date())
        log("---- \(stamp) FX Steam Launcher started (pid \(getpid()), \(Bundle.main.bundlePath))")
    }

    /// A launch error the user must see: an alert when launched from Finder / `open` (the log is not
    /// on screen; a shell launch has the message on stderr).
    @MainActor
    static func alertIfLaunchedFromFinder(_ title: LocalizedStringResource, _ message: String) {
        guard resources != nil && (getppid() == 1 || Supervisor.isChild) else { return }
        let alert = NSAlert()
        alert.messageText = String(localized: title)
        alert.informativeText = message
        NSApplication.shared.setActivationPolicy(.regular)
        NSApp.activate()
        alert.runModal()
    }
}

/// First start of the app without a usable disk image: explain, then create a new disk
/// (CreateDiskWindowController, no Docker) or let the user pick an existing image (Settings >
/// Advanced "Disk image"); the supervisor then boots it.
enum FirstRun {
    static func run(settings: LauncherSettings) -> Never {
        let app = NSApplication.shared
        log("first run: no usable disk image (\(settings.diskImage.isEmpty ? "none found" : settings.diskImage)); asking the user")
        app.setActivationPolicy(.regular)
        MainMenu.installMinimal()
        app.activate()
        let alert = makeAlert(settings: settings)
        while true {
            let choice = alert.runModal()
            var chosen: String?
            if choice == .alertFirstButtonReturn {
                chosen = CreateDiskWindowController.runModal(settings: settings)
            } else if choice == .alertSecondButtonReturn {
                let panel = NSOpenPanel()
                AppBundle.configureDiskPanel(panel)
                panel.message = String(localized: "Raw GPT disk image (e.g. steamos.img). It stays where it is.")
                if panel.runModal() == .OK, let url = panel.url,
                   MainActor.assumeIsolated({ AppBundle.acceptDiskSelection(url.path) }) {
                    chosen = url.path
                }
            } else {
                log("first run: no disk chosen; quitting")
                exit(0)
            }
            guard let path = chosen else { continue }
            settings.diskImage = path
            log("first run: disk image \(path)")
            // Tell the supervisor to start the VM now (same marker as a guest reboot).
            if let dir = Supervisor.runDir {
                FileManager.default.createFile(atPath: Supervisor.rebootMarker(dir), contents: Data(Supervisor.firstRunMarker.utf8))
            }
            exit(0)
        }
    }

    /// The first-run alert (also captured by --selftest-settings).
    static func makeAlert(settings: LauncherSettings) -> NSAlert {
        let alert = NSAlert()
        alert.messageText = String(localized: "No guest disk image")
        let looked = AppBundle.defaultDiskCandidates().map { "• " + ($0 as NSString).abbreviatingWithTildeInPath }
        var info = String(localized: "FX Steam Launcher needs a guest disk image. Click Create New Disk… below, then choose Operating system → Bazzite ARM64 or SteamOS.\n\n")
        if !settings.diskImage.isEmpty {
            let path = (settings.diskImage as NSString).abbreviatingWithTildeInPath
            info += path + "\n\n" + AppBundle.invalidDiskMessage + "\n\n"
        }
        let paths = looked.joined(separator: "\n")
        info += String(localized: "Looked in:\n\(paths)\n\n")
        info += String(localized: "Create a new one: the official SteamOS image is downloaded from Valve and verified (about 4.5 GB; the disk uses ~10 GB on your Mac at first). Or choose an existing image, which is used in place and never copied.")
        alert.informativeText = info
        alert.accessoryView = SteamClientPicker.alertAccessoryView(settings: settings)
        alert.addButton(withTitle: String(localized: "Create New Disk…"))
        alert.addButton(withTitle: String(localized: "Use Existing Disk…"))
        alert.addButton(withTitle: String(localized: "Quit"))
        return alert
    }
}
