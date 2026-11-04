import AppKit
import Combine
import Foundation

/// Settings > General "Pause the game" while FX Steam Launcher is in the background: when the
/// app resigns active and a game has the guest's focus, the guest agent freezes that game's
/// cgroup (`freeze-game <appid>` on fx.progress; Steam itself keeps running). While frozen the
/// launcher sends `still-background` every 2 s — the agent thaws on its own after 6 s without
/// one, so a killed launcher never leaves a game frozen. `thaw-game` when the app becomes
/// active again, the setting is turned off or the focus moves. The agent confirms with
/// `game-frozen <appid>` / `game-thawed <appid>`: `confirmed` (the "Game paused" overlay) follows
/// those, never just the request.
final class GamePause {
    static let keepaliveInterval: TimeInterval = 2
    /// Control FIFO `keepalive off`: stop the keepalives (tests of the guest's 6 s auto-thaw).
    nonisolated(unsafe) static var keepaliveSuppressed = false

    private let send: (String) -> Bool
    private var enabled: Bool
    private var appActive = true
    private var focus: GuestFocus = .steam
    /// App id the guest was asked to freeze.
    private(set) var frozen: Int?
    /// App id the guest reports frozen (`game-frozen`, until `game-thawed`).
    private(set) var confirmed: Int?
    private var keepalive: DispatchSourceTimer?
    private var thawFallback: DispatchWorkItem?
    private var observers: [NSObjectProtocol] = []
    private var subscription: AnyCancellable?
    /// Paused state changed (stall indicator gate): requested or confirmed.
    var onChange: ((Bool) -> Void)?
    /// The confirmed frozen game changed (nil = running).
    var onConfirmedChange: ((Int?) -> Void)?
    /// The whole VM is suspended (SuspendController): nothing to freeze, a frozen game is thawed
    /// (the request reaches the guest when it runs again).
    var vmSuspended = false { didSet { if vmSuspended != oldValue { update() } } }
    /// A remote player is active even when the Mac's launcher is in the background.
    var streaming = false { didSet { if streaming != oldValue { update() } } }
    /// No `game-thawed` this long after `thaw-game` (agent gone): consider the game running.
    static let thawConfirmTimeout: TimeInterval = 2

    init(settings: LauncherSettings, progress: BootProgress, send: @escaping (String) -> Bool) {
        self.send = send
        enabled = settings.pauseInBackground
        let previousFocus = progress.onFocus
        progress.onFocus = { [weak self] f in previousFocus?(f); self?.focus = f; self?.update() }
        let previousFrozen = progress.onGameFrozen
        progress.onGameFrozen = { [weak self] id, isFrozen in previousFrozen?(id, isFrozen); self?.guestReported(id, frozen: isFrozen) }
        let nc = NotificationCenter.default
        observers = [
            nc.addObserver(forName: NSApplication.didResignActiveNotification, object: nil, queue: .main) { [weak self] _ in
                self?.setAppActive(false)
            },
            nc.addObserver(forName: NSApplication.didBecomeActiveNotification, object: nil, queue: .main) { [weak self] _ in
                self?.setAppActive(true)
            },
        ]
        // @Published emits the new value before it is stored: use the emitted value.
        subscription = settings.$pauseInBackground.dropFirst().removeDuplicates().sink { [weak self] on in
            self?.enabled = on
            self?.update()
        }
    }

    func setAppActive(_ active: Bool) {
        appActive = active
        update()
    }

    private func update() {
        var want: Int?
        if enabled, !appActive, !vmSuspended, !streaming, case .game(let id) = focus, id > 0 { want = id }
        guard want != frozen else { return }
        if let id = frozen {
            keepalive?.cancel()
            keepalive = nil
            _ = send("thaw-game")
            log("game: resuming game \(id)")
            if confirmed != nil {
                let work = DispatchWorkItem { [weak self] in
                    guard let self, self.frozen == nil, self.confirmed != nil else { return }
                    log("game: no thaw confirmation from the guest; assuming the game runs")
                    self.setConfirmed(nil)
                }
                thawFallback = work
                DispatchQueue.main.asyncAfter(deadline: .now() + GamePause.thawConfirmTimeout, execute: work)
            }
        }
        frozen = want
        if let id = want {
            thawFallback?.cancel()
            _ = send("freeze-game \(id)")
            log("game: pausing game \(id) (launcher in the background)")
            let t = DispatchSource.makeTimerSource(queue: .main)
            t.schedule(deadline: .now() + GamePause.keepaliveInterval, repeating: GamePause.keepaliveInterval)
            t.setEventHandler { [weak self] in
                if !GamePause.keepaliveSuppressed { _ = self?.send("still-background") }
            }
            t.resume()
            keepalive = t
        }
        onChange?(frozen != nil || confirmed != nil)
    }

    /// `game-frozen` / `game-thawed` from the agent.
    private func guestReported(_ id: Int, frozen isFrozen: Bool) {
        if isFrozen {
            // A late confirmation of a freeze the host already took back: the thaw follows.
            guard frozen == id else { return }
            log("game: game \(id) paused (guest confirmed)")
            setConfirmed(id)
        } else if confirmed == id {
            log("game: game \(id) running again (guest confirmed)")
            thawFallback?.cancel()
            setConfirmed(nil)
        }
    }

    private func setConfirmed(_ id: Int?) {
        guard id != confirmed else { return }
        confirmed = id
        onConfirmedChange?(id)
        onChange?(frozen != nil || confirmed != nil)
    }
}
