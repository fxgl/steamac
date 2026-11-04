import AppKit
import Combine
import SwiftUI

/// Independent of Settings: Moonlight's pairing request may arrive with no launcher window open.
final class StreamPairingPrompt: NSObject, NSWindowDelegate {
    static var hostName: String { Host.current().localizedName ?? ProcessInfo.processInfo.hostName }
    private var subscription: AnyCancellable?
    private var window: NSWindow?
    private var request: StreamPairingRequest?

    init(host: GameStreamHost) {
        super.init()
        subscription = host.$pairing.receive(on: DispatchQueue.main).sink { [weak self] in self?.present($0) }
    }

    private func present(_ next: StreamPairingRequest?) {
        guard request?.id != next?.id else { return }
        window?.orderOut(nil)
        window = nil
        request = next
        guard let next else { return }
        let controller = NSHostingController(rootView: StreamPairingView(request: next))
        let panel = NSPanel(contentViewController: controller)
        panel.styleMask = [.titled, .closable]
        panel.level = .floating
        panel.hidesOnDeactivate = false
        panel.isReleasedWhenClosed = false
        panel.delegate = self
        panel.center()
        window = panel
        // A captured VM keyboard must not consume the PIN intended for this window.
        lifecycle.window?.releasePointer()
        NSApp.activate(ignoringOtherApps: true)
        panel.makeKeyAndOrderFront(nil)
    }

    func windowWillClose(_ notification: Notification) { request?.cancel() }
}
