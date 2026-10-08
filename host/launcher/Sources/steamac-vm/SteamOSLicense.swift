import Foundation

/// Valve's terms for the SteamOS image DiskCreator downloads: the "End User License Agreement for
/// SteamOS and Steam Client Back-Up Image" (the text Valve shows on its Steam Frame image download
/// page) and the Steam Subscriber Agreement it incorporates. The user accepts both before the
/// first download: the checkbox in the Create SteamOS Disk window or `--create-disk ...
/// --accept-eula`. The acceptance (date + EULA URL) is kept in the settings domain; it counts only
/// for the EULA URL below, so pointing `eulaURL` at a new agreement asks again.
enum SteamOSLicense {
    static let eulaURL = URL(string: "https://store.steampowered.com/steamos/download/?ver=steamframe")!
    static let ssaURL = URL(string: "https://store.steampowered.com/subscriber_agreement/")!
    static let summary = "SteamOS and the Steam client are Valve's software. Valve licenses them for personal use "
        + "only and forbids redistributing them; Steam itself is governed by the Steam Subscriber Agreement."
    static let localizedSummary = String(localized: "SteamOS and the Steam client are Valve's software. Valve licenses them for personal use only and forbids redistributing them; Steam itself is governed by the Steam Subscriber Agreement.")
    private static let key = "steamosLicenseAccepted"

    /// When the current agreement was accepted, nil if not (or an older agreement was).
    static func acceptedAt(_ settings: LauncherSettings) -> Date? {
        guard let record = settings.defaults.dictionary(forKey: key),
              record["eula"] as? String == eulaURL.absoluteString else { return nil }
        return record["date"] as? Date
    }

    static func accept(_ settings: LauncherSettings, via source: String) {
        guard acceptedAt(settings) == nil else { return }
        settings.defaults.set(["date": Date(), "eula": eulaURL.absoluteString, "via": source], forKey: key)
        log("license: Valve's SteamOS EULA (\(eulaURL.absoluteString)) and Steam Subscriber Agreement accepted (\(source))")
    }
}
