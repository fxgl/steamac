import AppKit
import Darwin
import Foundation

/// libMTLHud installs completion handlers independently of the layer's visibility. Loading it
/// is a per-boot opt-in; hiding cannot unload its handlers (STEAMAC-59/7K/7Q/9X/9Y).
enum MetalHUD {
    private(set) static var loaded = false
    private(set) static var driver = LauncherSettings.VulkanDriver.moltenvk

    /// Before the first Metal device, including CrashReporting's GPU-name query. An inherited
    /// MTL_HUD_ENABLED=1 must not inject the HUD into the supervisor or a headless/off VM.
    static func configure(isChild: Bool, headless: Bool, requested: Bool, driver: LauncherSettings.VulkanDriver) {
        self.driver = driver
        loaded = isChild && !headless && requested
        setenv("MTL_HUD_ENABLED", loaded ? "1" : "0", 1)
    }

    static func visible(requested: Bool) -> Bool { loaded && requested }

    static func diagnostics(requested: Bool) -> [String: String] {
        ["metal_hud": visible(requested: requested) ? "on" : "off",
         "metal_hud_injected": loaded ? "on" : "off",
         "metal_hud_requested": requested ? "on" : "off",
         "metal_hud_driver": driver.rawValue]
    }

    static let kosmicKrispNote = String(localized: "Apple's Metal HUD can crash the VM with KosmicKrisp (Metal 4), even when the overlay is hidden. As an alternative, use Settings > General > Log frame-pacing statistics (guest display timing, not game FPS). Restart the VM after turning the HUD off to unload Apple's HUD library.")
    static let restartNote = String(localized: "Enabling requires a VM restart. Turning it off hides the overlay now; restart to unload Apple's HUD library.")

    static func enableWarning(current: Bool, requested: Bool, nextDriver: LauncherSettings.VulkanDriver? = nil) -> String? {
        (driver == .kosmickrisp || nextDriver == .kosmickrisp) && !current && requested ? kosmicKrispNote : nil
    }

    @MainActor static func confirmEnable(current: Bool, nextDriver: LauncherSettings.VulkanDriver) -> Bool {
        guard let warning = enableWarning(current: current, requested: true, nextDriver: nextDriver) else { return true }
        let alert = NSAlert()
        alert.alertStyle = .warning
        alert.messageText = String(localized: "Enable Apple's Metal HUD?")
        alert.informativeText = warning + "\n\n" + restartNote
        alert.addButton(withTitle: String(localized: "Continue"))
        alert.addButton(withTitle: String(localized: "Cancel"))
        return alert.runModal() == .alertFirstButtonReturn
    }

    static func selfCheck() -> [String] {
        let saved = getenv("MTL_HUD_ENABLED").map { String(cString: $0) }
        let savedLoaded = loaded
        let savedDriver = driver
        defer {
            loaded = savedLoaded
            driver = savedDriver
            if let saved { setenv("MTL_HUD_ENABLED", saved, 1) }
            else { unsetenv("MTL_HUD_ENABLED") }
        }
        var failures: [String] = []
        for driver in LauncherSettings.VulkanDriver.allCases {
            for child in [false, true] {
                for headless in [false, true] {
                    for requested in [false, true] {
                        // Deliberately hostile inheritance: "off" must disable injection, not hide it.
                        setenv("MTL_HUD_ENABLED", "1", 1)
                        configure(isChild: child, headless: headless, requested: requested, driver: driver)
                        let expected = child && !headless && requested
                        if loaded != expected || String(cString: getenv("MTL_HUD_ENABLED")!) != (expected ? "1" : "0") {
                            failures.append("HUD injection: driver=\(driver.rawValue) child=\(child) headless=\(headless) requested=\(requested)")
                        }
                        if self.driver != driver {
                            failures.append("HUD diagnostics disagree with the boot driver")
                        }
                        if visible(requested: true) != expected || visible(requested: false) {
                            failures.append("HUD visibility: enable without injection or hide while loaded")
                        }
                        for requestedNow in [false, true] {
                            let tags = diagnostics(requested: requestedNow)
                            if tags["metal_hud"] != (expected && requestedNow ? "on" : "off")
                                || tags["metal_hud_injected"] != (expected ? "on" : "off")
                                || tags["metal_hud_requested"] != (requestedNow ? "on" : "off")
                                || tags["metal_hud_driver"] != driver.rawValue {
                                failures.append("HUD diagnostic tags confuse visibility, injection, request or boot driver")
                            }
                        }
                        for current in [false, true] {
                            for nextDriver: LauncherSettings.VulkanDriver? in [nil, .moltenvk, .kosmickrisp] {
                                let warned = enableWarning(current: current, requested: requested, nextDriver: nextDriver) != nil
                                let unsafeDriver = driver == .kosmickrisp || nextDriver == .kosmickrisp
                                if warned != (unsafeDriver && !current && requested) {
                                    failures.append("HUD warning: driver=\(driver.rawValue) next=\(String(describing: nextDriver)) current=\(current) requested=\(requested)")
                                }
                            }
                        }
                    }
                }
            }
        }
        return failures
    }
}
