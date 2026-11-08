import Foundation

/// This sidecar selects Fedora's initramfs and bootc deployment instead of the
/// SteamOS initramfs and Arch /usr layer. Paths are resolved next to the disk.
struct BazziteGuest: Codable {
    struct Asset: Codable {
        let name: String
        let sha256: String
        let bytes: Int64
    }
    let schema: Int
    let build: String
    let sourceRevision: String
    let diskBytes: Int64
    let commandLine: String
    let disk: Asset
    let kernel: Asset
    let initrd: Asset
    var installedDiskBytes: Int64? = nil

    static func directory(_ path: String) -> String { path + ".bazzite" }
    static func manifestPath(_ path: String) -> String { directory(path) + "/bazzite-steamac.json" }
    static func load(_ path: String) throws -> BazziteGuest {
        let data = try Data(contentsOf: URL(fileURLWithPath: manifestPath(path)))
        let result = try JSONDecoder().decode(Self.self, from: data)
        try result.validate()
        return result
    }
    static func exists(_ path: String) -> Bool { FileManager.default.fileExists(atPath: manifestPath(path)) }

    func validate() throws {
        guard schema == 1, !build.isEmpty, diskBytes >= 8 << 30, diskBytes <= 256 << 30,
              commandLine.utf8.count < 4096, !commandLine.contains("\n"), !commandLine.contains("\r"),
              commandLine.split(separator: " ").contains(where: { $0.hasPrefix("ostree=/ostree/") }),
              commandLine.split(separator: " ").contains(where: { $0.hasPrefix("root=UUID=") }),
              Set([disk.name, kernel.name, initrd.name]).count == 3 else {
            throw OptionError("Invalid Bazzite guest manifest")
        }
        if let installedDiskBytes {
            guard installedDiskBytes >= diskBytes, installedDiskBytes <= 2048 << 30, installedDiskBytes % (1 << 20) == 0 else { throw OptionError("Invalid installed Bazzite capacity") }
        }
        for asset in [disk, kernel, initrd] {
            guard !asset.name.isEmpty, asset.name != ".", asset.name != "..",
                  asset.name == (asset.name as NSString).lastPathComponent,
                  !asset.name.contains("\\"),
                  asset.sha256.count == 64,
                  asset.sha256.allSatisfy({ $0.isHexDigit && !$0.isUppercase }),
                  asset.bytes > 0, asset.bytes <= 2_147_483_647 else {
                throw OptionError("Invalid Bazzite release asset")
            }
        }
        guard disk.name.hasSuffix(".gz") else { throw OptionError("Expected a gzip Bazzite disk") }
    }

    func apply(_ o: inout Options, diskPath: String) {
        let dir = Self.directory(diskPath)
        if !o.explicit.contains("--kernel") { o.kernel = dir + "/" + kernel.name }
        if !o.explicit.contains("--initrd") { o.initrd = dir + "/" + initrd.name }
        if !o.explicit.contains("--cmdline") { o.cmdline = commandLine }
        // Bazzite ARM64 is built for the host wmtr/DXMT path. Keep the bundled
        // executor enabled; silently falling back to Vulkan hides D3D11 failures.
        if !o.explicit.contains("--wmtr-lib") && !o.explicit.contains("--no-wmtr") {
            o.wmtrLibrary = LauncherSettings.Wmtr.path(for: "")
        }
        if !o.explicit.contains("--mouse") { o.mouseMode = .tablet }
    }
}
