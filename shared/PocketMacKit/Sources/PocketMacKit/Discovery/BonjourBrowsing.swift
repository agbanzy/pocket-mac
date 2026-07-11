import Foundation
import Network

/// Browses for Pocket Mac helpers on the LAN via `NWBrowser` and yields the current result set.
///
/// The iOS app must ship `NSLocalNetworkUsageDescription` and `NSBonjourServices` (listing
/// `_pocketmac._tcp`) or the browser silently returns nothing. Permission denial surfaces as
/// `kDNSServiceErr_PolicyDenied` (-65570) on the browser's state — treat that as "guide the user to
/// Settings", not as "no devices".
public final class BonjourBrowsing: @unchecked Sendable {
    private let queue = DispatchQueue(label: "com.innoedge.pocketmac.browse")
    private var browser: NWBrowser?

    public init() {}

    /// The browser's lifecycle state, so the UI can distinguish "searching" from "permission denied".
    public enum BrowseState: Sendable, Equatable {
        case setup
        case ready
        case failed(String)
        /// Local Network permission denied (`kDNSServiceErr_PolicyDenied`).
        case permissionDenied
    }

    /// Starts browsing and returns a stream of `(services, state)` snapshots.
    public func start() -> AsyncStream<(services: [DiscoveredService], state: BrowseState)> {
        let descriptor = NWBrowser.Descriptor.bonjour(type: PocketMac.bonjourServiceType, domain: nil)
        let browser = NWBrowser(for: descriptor, using: .tcp)
        self.browser = browser
        let queue = self.queue

        return AsyncStream { continuation in
            browser.stateUpdateHandler = { state in
                switch state {
                case .ready:
                    continuation.yield((services: [], state: .ready))
                case .failed(let error):
                    if case .dns(let code) = error, code == kDNSServiceErr_PolicyDenied {
                        continuation.yield((services: [], state: .permissionDenied))
                    } else {
                        continuation.yield((services: [], state: .failed(String(describing: error))))
                    }
                case .cancelled:
                    continuation.finish()
                default:
                    continuation.yield((services: [], state: .setup))
                }
            }
            browser.browseResultsChangedHandler = { results, _ in
                let services = results.compactMap { result -> DiscoveredService? in
                    guard case let .service(name, _, _, _) = result.endpoint else { return nil }
                    return DiscoveredService(name: name, endpoint: result.endpoint)
                }
                continuation.yield((services: services, state: .ready))
            }
            continuation.onTermination = { _ in browser.cancel() }
            browser.start(queue: queue)
        }
    }

    public func stop() {
        browser?.cancel()
        browser = nil
    }
}
