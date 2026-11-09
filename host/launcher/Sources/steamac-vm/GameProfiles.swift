import AppKit
import Combine
import Foundation
import SwiftUI

/// Host-only driver choice is deliberately absent from the guest payload.
struct GameProfile: Codable, Equatable {
    var gfx: String?
    var driver: String?
    var env = ""
    var isDefault: Bool { gfx == nil && driver == nil && env.isEmpty }

    init(gfx: String? = nil, driver: String? = nil, env: String = "") {
        self.gfx = gfx
        self.driver = driver
        self.env = env
    }
    /// Every field is optional in the stored JSON: a profile without launch words (or written by
    /// hand, `defaults write … profile.<appid>`) must not be dropped.
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        gfx = try c.decodeIfPresent(String.self, forKey: .gfx)
        driver = try c.decodeIfPresent(String.self, forKey: .driver)
        env = try c.decodeIfPresent(String.self, forKey: .env) ?? ""
    }

    private static let word = try! NSRegularExpression(pattern: "^(VKD3D|DXVK|PROTON|WINE|MESA|RADV|VK|DXMT|MTL|STEAMAC)_[A-Z0-9_]*=[A-Za-z0-9_.,:;+-]*$")
    static func validWord(_ text: String) -> Bool {
        let range = NSRange(text.startIndex..<text.endIndex, in: text)
        return word.firstMatch(in: text, range: range)?.range == range
    }
    static func validEnv(_ text: String) -> Bool {
        text.count <= 256 && text.split(separator: " ", omittingEmptySubsequences: true).joined(separator: " ") == text
            && text.split(separator: " ").allSatisfy { validWord(String($0)) }
    }
    /// Matches the service's allowlist, last assignment wins; reports never include rejected words.
    static func sanitizedEnv(_ text: String) -> String {
        var values: [String: String] = [:]
        for word in text.split(separator: " ") where validWord(String(word)) {
            let name = String(word.prefix { $0 != "=" })
            values[name] = String(word)
        }
        var result = ""
        for key in values.keys.sorted() {
            let next = result.isEmpty ? values[key]! : result + " " + values[key]!
            if next.count <= 256 { result = next }
        }
        return result
    }

    var summary: String {
        let graphics = gfx == "dxmt" ? "DXMT" : "Vulkan"
        let driverName = driver.flatMap(LauncherSettings.VulkanDriver.init(rawValue:))?.name
        return ([graphics] + (driverName.map { [$0] } ?? []) + (env.isEmpty ? [] : [env])).joined(separator: " · ")
    }

    static let securityText = String(localized: "Games use DXMT only when their profile selects it. Their D3D11 and D3D10 draw through DXMT directly with the Mac's Metal using native ARM64EC Proton when installed, or Proton 10.0 (x86-64) otherwise; games with Default graphics stay on Vulkan. DXMT has compatibility gaps, including no D3D11 stream output. Allowing DXMT takes effect on the next VM start. Security risk: while on, programs in SteamOS can run code on the Mac with your user's rights. The executor runs inside the VM process and trusts the guest; a fault can stop the VM.")
    static func selfCheck() -> [String] {
        var failures: [String] = []
        if sanitizedEnv("DXVK_A=1 PROTON_B=2 DXVK_A=3 BAD=secret WINE_X=$(id)") != "DXVK_A=3 PROTON_B=2" { failures.append("profiles: env canonicalization") }
        for value in ["PATH=/tmp", "DXVK_A=$(id)", "DXVK_A=1\nWINE_B=2", String(repeating: "A", count: 257)] {
            if validEnv(value) { failures.append("profiles: accepted invalid env") }
        }
        if !validEnv("VKD3D_CONFIG=dxr;dxr11 MTL_HUD_ENABLED=1") || !validEnv("") { failures.append("profiles: valid env rejected") }
        let data = Data(#"{"recommended":{"driver":"moltenvk","gfx":"vulkan","env":null,"installs":2,"sessions":3,"ratings":{"well":2,"issues":0,"unplayable":0,"no_start":0},"fps_avg_median":29,"launch_rate":1}}"#.utf8)
        if (try? JSONDecoder().decode(GameRecommendation.Response.self, from: data).recommended?.profile) != GameProfile(gfx: "vulkan", driver: "moltenvk") { failures.append("profiles: recommendation decoding") }
        let progress = BootProgress()
        var event: GuestGameEvent?
        progress.onGameEvent = { event = $0 }
        progress.guestLine("game-gfx 42 dxmt")
        if event != .gfx(appid: 42, gfx: "dxmt") { failures.append("profiles: game-gfx parsing") }
        progress.guestLine("game-gfx 42 unknown")
        if event != .gfx(appid: 42, gfx: "dxmt") { failures.append("profiles: invalid gfx accepted") }
        return failures
    }
}

struct GameRecommendation: Decodable {
    let driver: String
    let gfx: String
    let env: String?
    var profile: GameProfile { GameProfile(gfx: gfx, driver: driver, env: GameProfile.sanitizedEnv(env ?? "")) }
    var usable: Bool {
        guard let choice = LauncherSettings.VulkanDriver(rawValue: driver) else { return false }
        return ["dxmt", "vulkan"].contains(gfx) && choice.unavailableReason == nil
    }
    struct Response: Decodable { let recommended: GameRecommendation? }
}

/// Lifetime is one Games tab opening; failed lookups are quiet and are not retried while open.
final class GameRecommendations: ObservableObject {
    enum State { case loading, unavailable, found(GameRecommendation) }
    @Published private(set) var rows: [Int: State] = [:]
    private var generation = UUID()
    func reset() { generation = UUID(); rows = [:] }
    func fetch(_ appid: Int) {
        guard rows[appid] == nil else { return }
        guard let base = ProcessInfo.processInfo.environment[GameStatsStore.urlEnv].flatMap(URL.init(string:))
                ?? (Bundle.main.object(forInfoDictionaryKey: "SteamacGameStatsURL") as? String).flatMap(URL.init(string:)),
              var c = URLComponents(url: base.appendingPathComponent("v1/games/\(appid)"), resolvingAgainstBaseURL: false) else {
            rows[appid] = .unavailable; return
        }
        let mac = GameStatsMac.current
        c.queryItems = [URLQueryItem(name: "max_ram_gb", value: String(mac.ramGB))]
            + (mac.gpuCores.map { [URLQueryItem(name: "max_gpu_cores", value: String($0))] } ?? [])
            + (mac.pcores.map { [URLQueryItem(name: "max_pcores", value: String($0))] } ?? [])
        guard let url = c.url else { rows[appid] = .unavailable; return }
        rows[appid] = .loading
        let generation = generation
        URLSession.shared.dataTask(with: url) { [weak self] data, response, _ in
            let result = data.flatMap { try? JSONDecoder().decode(GameRecommendation.Response.self, from: $0).recommended }
            DispatchQueue.main.async {
                guard self?.generation == generation else { return }
                if let result, (response as? HTTPURLResponse)?.statusCode == 200 { self?.rows[appid] = .found(result) }
                else { self?.rows[appid] = .unavailable }
            }
        }.resume()
    }
}

/// One boot's profile synchronization and user-approved restart offers.
final class GameProfileController {
    private let settings: LauncherSettings
    private let port: ProgressPort
    private let options: Options
    private let window: () -> NSWindow?
    private let restart: () -> Void
    private var subscription: AnyCancellable?
    private var agentUp = false
    private var promptedPayload: String?
    private var offeredGames: Set<Int> = []
    private var alert: NSAlert?
    private var prompt: NSPanel?

    init(settings: LauncherSettings, progress: BootProgress, port: ProgressPort, options: Options,
         window: @escaping () -> NSWindow?, restart: @escaping () -> Void) {
        self.settings = settings; self.port = port; self.options = options; self.window = window; self.restart = restart
        let alive = progress.onAlive
        progress.onAlive = { [weak self] ms, load in alive?(ms, load); self?.connected() }
        let ready = progress.onReady
        progress.onReady = { [weak self] in
            ready?(); self?.connected()
            if let self, let id = Supervisor.profileLaunchAppID { _ = self.port.send("launch \(id)") }
        }
        progress.onProfilesOK = { [weak self] hash, pending in self?.acknowledged(hash, pending: pending) }
        let event = progress.onGameEvent
        progress.onGameEvent = { [weak self] e in
            event?(e)
            if case .start(let id) = e { self?.offerDriver(id) }
        }
        let focus = progress.onFocus
        progress.onFocus = { [weak self] f in
            focus?(f)
            if case .game(let id) = f { self?.offerDriver(id) }
        }
        subscription = settings.$profiles.dropFirst().debounce(for: .milliseconds(350), scheduler: DispatchQueue.main).sink { [weak self] _ in self?.send() }
    }

    private func connected() {
        guard !agentUp else { return }
        agentUp = true
        send()
    }
    private func send() {
        guard agentUp else { return }
        struct Payload: Encodable {
            struct Profile: Encodable { let gfx: String?; let env: String? }
            let v = 1
            let games: [String: Profile]
        }
        let games = settings.profiles.reduce(into: [String: Payload.Profile]()) { result, entry in
            let env = GameProfile.sanitizedEnv(entry.value.env)
            if entry.value.gfx != nil || !env.isEmpty { result[String(entry.key)] = .init(gfx: entry.value.gfx, env: env.isEmpty ? nil : env) }
        }
        let encoder = JSONEncoder(); encoder.outputFormatting = [.sortedKeys]
        guard let data = try? encoder.encode(Payload(games: games)) else { return }
        port.send("profiles " + data.base64EncodedString())
    }
    private func acknowledged(_ hash: String, pending: Bool) {
        guard pending, hash != promptedPayload, alert == nil, prompt == nil, window() != nil else { return }
        promptedPayload = hash
        let panel = NSPanel(contentRect: NSRect(x: 0, y: 0, width: 380, height: 130),
                            styleMask: [.titled], backing: .buffered, defer: false)
        panel.isReleasedWhenClosed = false
        panel.title = String(localized: "Game profiles")
        panel.contentView = NSHostingView(rootView: VStack(alignment: .leading, spacing: 18) {
            Text("Restart Steam to apply the game profiles?").font(.headline)
            HStack {
                Spacer()
                Button("Later") { [weak self] in self?.prompt?.close(); self?.prompt = nil }
                Button("Restart Steam") { [weak self] in
                    _ = self?.port.send("restart-steam")
                    self?.prompt?.close(); self?.prompt = nil
                }.keyboardShortcut(.defaultAction)
            }
        }.padding(20))
        prompt = panel
        panel.center()
        panel.makeKeyAndOrderFront(nil)
    }
    private func offerDriver(_ appid: Int) {
        let raw = settings.profile(for: appid).driver ?? settings.vulkanDriver.rawValue
        guard appid > 0, !offeredGames.contains(appid), alert == nil, prompt == nil,
              let driver = LauncherSettings.VulkanDriver(rawValue: raw), driver != options.vulkanDriver,
              driver.unavailableReason == nil, let window = window() else { return }
        offeredGames.insert(appid)
        let name = settings.gameName(appid) ?? String(appid)
        let a = NSAlert(); alert = a
        a.messageText = String(localized: "Restart the VM with \(driver.name) for \(name)?")
        a.informativeText = LauncherSettings.VulkanDriver.switchNote
        a.addButton(withTitle: String(localized: "Restart")); a.addButton(withTitle: String(localized: "Not now"))
        a.beginSheetModal(for: window) { [weak self] response in
            guard let self else { return }
            self.alert = nil
            if response == .alertFirstButtonReturn, Supervisor.queueProfileBoot(driver: driver, appid: appid) { self.restart() }
        }
    }
}
