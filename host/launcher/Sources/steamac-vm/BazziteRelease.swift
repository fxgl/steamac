import Foundation

/// Assets owned by the user's Bazzite fork. A release is selectable only when it
/// contains the versioned guest manifest; unrelated upstream releases are ignored.
struct BazziteRelease: Decodable, Identifiable, Hashable {
    struct Asset: Decodable, Hashable {
        let name: String
        let browser_download_url: URL
    }
    let tag_name: String
    let name: String?
    let draft: Bool
    let assets: [Asset]
    var id: String { tag_name }
    var title: String { name.flatMap { $0.isEmpty ? nil : $0 } ?? tag_name }
    var manifestURL: URL? { assets.first { $0.name == "bazzite-steamac.json" }?.browser_download_url }
    static let repository = "Naozumi520/bazzite"
    static let api = URL(string: "https://api.github.com/repos/\(repository)/releases")!

    static func validateAssetURL(_ url: URL) throws {
        guard url.scheme == "https", url.host == "github.com", url.user == nil,
              url.password == nil, url.port == nil,
              url.path.hasPrefix("/\(repository)/releases/download/"),
              !url.pathComponents.contains("..") else {
            throw OptionError("Bazzite assets must come from \(repository) GitHub Releases")
        }
    }
}
