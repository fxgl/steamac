import AppKit
import CoreGraphics

/// Physical size the guest sees in the EDID (drives the DPI-aware UI scale in the guest).
/// Default: the real size of the launcher window on the host monitor — window content size in
/// points × the screen's mm per point (CGDisplayScreenSize / frame), so guest UIs come out at
/// real-world size on any monitor, Retina or not. Sizes are taken from the window in points, so
/// with Retina resolution (`pixelScale` guest pixels per point) the guest gets a denser display of
/// the same physical size and scales its UI up to match. The same mm per guest pixel is reused
/// whenever the window is resized (the guest display follows the window), so the DPI stays
/// constant for the whole session unless a side hits the EDID physical-size limit.
enum EdidSize {
    struct Result {
        let widthMM: Int
        let heightMM: Int
        /// Millimetres per guest pixel (= per window point / pixelScale once the guest follows the window).
        let mmPerUnitX: Double
        let mmPerUnitY: Double
        let source: String

        /// Physical size for a guest display of `w`x`h` pixels at this session's DPI.
        func millimetres(_ w: Int, _ h: Int) -> (Int, Int) {
            (EdidSize.boundedMillimetres(Double(w) * mmPerUnitX),
             EdidSize.boundedMillimetres(Double(h) * mmPerUnitY))
        }
    }

    private static func boundedMillimetres(_ mm: Double) -> Int {
        // The base EDID detailed timing has 12-bit physical sizes, even with DisplayID.
        min(4095, Int(mm.rounded()))
    }

    static func resolve(_ o: Options) -> Result {
        log("display pacing: guest EDID refresh \(o.refreshRate) Hz"
            + " (virtual mode only; does not set the host refresh or phase-lock DXMT presents)")
        // Physical sizes from the window size in points; per-unit values per guest pixel.
        let w = o.displayWidth, h = o.displayHeight
        let (gw, gh) = o.guestSize
        func perPixel(_ mmX: Double, _ mmY: Double, _ source: String) -> Result {
            Result(widthMM: boundedMillimetres(mmX), heightMM: boundedMillimetres(mmY),
                   mmPerUnitX: mmX / Double(gw), mmPerUnitY: mmY / Double(gh), source: source)
        }
        if let (wmm, hmm) = o.displayMM {
            return perPixel(Double(wmm), Double(hmm), "--display-mm")
        }
        if let dpi = o.dpi {
            return perPixel(Double(w) * 25.4 / Double(dpi), Double(h) * 25.4 / Double(dpi), "--dpi \(dpi)")
        }
        let at96 = (Double(w) * 25.4 / 96, Double(h) * 25.4 / 96)
        if o.headless {
            return perPixel(at96.0, at96.1, "96 dpi (headless)")
        }
        guard let screen = WindowController.targetScreen(),
              let num = screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber else {
            return perPixel(at96.0, at96.1, "96 dpi (no host screen)")
        }
        let mm = CGDisplayScreenSize(CGDirectDisplayID(num.uint32Value))
        let pts = screen.frame.size
        let name = screen.localizedName
        let mmPerPtX = mm.width / pts.width, mmPerPtY = mm.height / pts.height
        // Plausible: ~0.15 (dense HiDPI scaled) .. ~0.6 mm/pt (huge TV); anything else is a bogus EDID.
        guard mm.width > 0, mm.height > 0, (0.12...0.8).contains(mmPerPtX), (0.12...0.8).contains(mmPerPtY) else {
            return perPixel(at96.0, at96.1, "96 dpi (host screen \"\(name)\" reports no usable size)")
        }
        let content = WindowController.initialContentSize(width: w, height: h, screen: screen)
        return Result(widthMM: boundedMillimetres(content.width * mmPerPtX),
                      heightMM: boundedMillimetres(content.height * mmPerPtY),
                      mmPerUnitX: mmPerPtX * Double(w) / Double(gw), mmPerUnitY: mmPerPtY * Double(h) / Double(gh),
                      source: "host screen \"\(name)\", \(String(format: "%.3f", (mmPerPtX + mmPerPtY) / 2)) mm/pt,"
                        + " window \(Int(content.width))x\(Int(content.height)) pt")
    }
}
