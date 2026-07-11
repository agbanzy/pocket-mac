import Foundation
import Observation
import PocketMacKit

/// Observable wrapper over the kit's `BonjourBrowsing`. Publishes the current service list and the
/// browser state so the UI can distinguish "searching" from "Local Network permission denied"
/// (`kDNSServiceErr_PolicyDenied`).
@MainActor
@Observable
final class DiscoveryService {
    private(set) var services: [DiscoveredService] = []
    private(set) var state: BonjourBrowsing.BrowseState = .setup
    private(set) var isBrowsing = false

    private let browser = BonjourBrowsing()
    private var task: Task<Void, Never>?

    /// True when Local Network access was denied — the UI should route the user to Settings.
    var permissionDenied: Bool {
        if case .permissionDenied = state { return true }
        return false
    }

    func start() {
        guard !isBrowsing else { return }
        isBrowsing = true
        state = .setup
        task = Task { [weak self] in
            guard let self else { return }
            for await snapshot in self.browser.start() {
                self.services = snapshot.services
                self.state = snapshot.state
            }
        }
    }

    func stop() {
        task?.cancel()
        task = nil
        browser.stop()
        isBrowsing = false
    }
}
