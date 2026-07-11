import Foundation
import Network

/// A discovered Pocket Mac helper on the local network. Carries the `NWEndpoint` the browser
/// resolved — connections are made **to this endpoint**, never to a hand-built `host.local` string
/// (manual `.local` resolution has been unreliable since iOS 17).
public struct DiscoveredService: Sendable, Equatable, Identifiable {
    public let name: String
    public let endpoint: NWEndpoint

    public var id: String { name }

    public init(name: String, endpoint: NWEndpoint) {
        self.name = name
        self.endpoint = endpoint
    }

    /// Opens (but does not start) a TCP `NWConnection` to this service, ready to wrap in an
    /// ``NWConnectionTransport``.
    public func makeConnection() -> NWConnection {
        NWConnection(to: endpoint, using: .tcp)
    }
}
