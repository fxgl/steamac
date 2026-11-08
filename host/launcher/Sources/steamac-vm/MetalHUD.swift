import Darwin
import Foundation

/// libMTLHud installs completion handlers independently of the layer's visibility. Loading it
/// is a per-boot decision; hiding the overlay cannot unload those handlers (STEAMAC-59/7K/9J).
enum MetalHUD {
    private(set) static var loaded = false

    /// Before the first Metal device, including CrashReporting's GPU-name query. An inherited
    /// MTL_HUD_ENABLED=1 must not inject the HUD into the supervisor or a headless/off VM.
    static func configure(isChild: Bool, headless: Bool, requested: Bool) {
        // macOS 27 can keep the library ready while the per-layer mode hides it.
        // Retain opt-in loading on macOS 26, where its completion handlers can crash.
        let supportsLiveToggle: Bool
        if #available(macOS 27, *) { supportsLiveToggle = true }
        else { supportsLiveToggle = false }
        loaded = isChild && !headless && (requested || supportsLiveToggle)
        setenv("MTL_HUD_ENABLED", loaded ? "1" : "0", 1)
    }

    static func visible(requested: Bool) -> Bool { loaded && requested }

    static let macOS26Warning = String(localized: "Apple's Metal HUD can crash the VM on macOS 26 (observed on 26.5.2 and 26.6.2). Leave it off if this happens.")
    static var restartNote: String {
        if #available(macOS 27, *) {
            return String(localized: "Show or hide the HUD immediately while the VM is running.")
        }
        return String(localized: "Enabling requires a VM restart. Turning it off hides the overlay now; restart to unload Apple's HUD library.")
    }

    static func selfCheck() -> [String] {
        let saved = getenv("MTL_HUD_ENABLED").map { String(cString: $0) }
        let savedLoaded = loaded
        defer {
            loaded = savedLoaded
            if let saved { setenv("MTL_HUD_ENABLED", saved, 1) }
            else { unsetenv("MTL_HUD_ENABLED") }
        }
        var failures: [String] = []
        for child in [false, true] {
            for headless in [false, true] {
                for requested in [false, true] {
                    // Deliberately hostile inheritance: "off" must disable injection, not hide it.
                    setenv("MTL_HUD_ENABLED", "1", 1)
                    configure(isChild: child, headless: headless, requested: requested)
                    let liveToggle: Bool
                    if #available(macOS 27, *) { liveToggle = true } else { liveToggle = false }
                    let expected = child && !headless && (requested || liveToggle)
                    if loaded != expected || String(cString: getenv("MTL_HUD_ENABLED")!) != (expected ? "1" : "0") {
                        failures.append("HUD injection: child=\(child) headless=\(headless) requested=\(requested)")
                    }
                    if visible(requested: true) != expected || visible(requested: false) {
                        failures.append("HUD visibility: enable without injection or hide while loaded")
                    }
                }
            }
        }
        return failures
    }
}
