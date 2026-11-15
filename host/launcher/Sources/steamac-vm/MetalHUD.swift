import AppKit
import Darwin
import Foundation
import MachO

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

/// Actual dyld state, independent of our HUD injection request. Xcode, environment settings,
/// or Apple's tooling can load Metal interposers even when the launcher's HUD is off.
struct MetalInstrumentation {
    struct Snapshot: Equatable {
        let tag: String
        let images: [String]
    }
    private var previous: Snapshot?

    private static func category(_ name: UnsafePointer<CChar>) -> UInt8 {
        if strcmp(name, "libMTLHud.dylib") == 0 { return 1 }
        if strcmp(name, "libMetalMetricsInterpose.dylib") == 0 { return 2 }
        if strstr(name, "MTLDebugLayer") != nil || strstr(name, "MetalDebug") != nil { return 4 }
        if strstr(name, "MTLCapture") != nil || strstr(name, "MetalCapture") != nil { return 8 }
        return 0
    }

    private static func tag(_ categories: UInt8) -> String {
        var result = ""
        if categories & 1 != 0 { result = "hud" }
        if categories & 2 != 0 { result += (result.isEmpty ? "" : ",") + "metrics" }
        if categories & 4 != 0 { result += (result.isEmpty ? "" : ",") + "debug" }
        if categories & 8 != 0 { result += (result.isEmpty ? "" : ",") + "capture" }
        return result.isEmpty ? "none" : result
    }

    static func current() -> Snapshot {
        var categories: UInt8 = 0
        var images: [String] = []
        for index in 0..<_dyld_image_count() {
            guard let path = _dyld_get_image_name(index) else { continue }
            let name = strrchr(path, 47).map { UnsafePointer($0.advanced(by: 1)) } ?? path
            let bit = category(name)
            guard bit != 0 else { continue }
            categories |= bit
            let image = String(cString: name)
            if !images.contains(image) { images.append(image) }
        }
        return Snapshot(tag: tag(categories), images: images.sorted())
    }

    mutating func update(_ snapshot: Snapshot) -> Snapshot? {
        guard previous != snapshot else { return nil }
        previous = snapshot
        return snapshot
    }

    mutating func sample() -> Snapshot? { update(Self.current()) }

    static func selfCheck() -> [String] {
        var failures: [String] = []
        let cases: [(String, UInt8)] = [
            ("libMTLHud.dylib", 1), ("libMetalMetricsInterpose.dylib", 2),
            ("MTLDebugLayer", 4), ("libMTLCapture.dylib", 8), ("MetalCapture", 8),
            ("Metal", 0), ("MetalPerformanceShaders", 0), ("libvulkan_kosmickrisp.dylib", 0),
        ]
        for (name, expected) in cases {
            if name.withCString({ category($0) }) != expected { failures.append("instrumentation image classification: \(name)") }
        }
        if tag(3) != "hud,metrics" || tag(15) != "hud,metrics,debug,capture" || tag(0) != "none" {
            failures.append("instrumentation category tag ordering")
        }
        var monitor = MetalInstrumentation()
        let none = Snapshot(tag: "none", images: [])
        let metrics = Snapshot(tag: "metrics", images: ["libMetalMetricsInterpose.dylib"])
        if monitor.update(none) != none || monitor.update(none) != nil
            || monitor.update(metrics) != metrics || monitor.update(metrics) != nil
            || monitor.update(none) != none {
            failures.append("instrumentation change-only logging gate")
        }
        let live = current()
        if live.images.contains(where: { $0.contains("/") }) { failures.append("instrumentation diagnostic exposes paths") }
        return failures
    }
}
