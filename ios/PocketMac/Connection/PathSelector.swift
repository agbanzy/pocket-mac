import Foundation
import PocketMacKit

/// Which network path a connection attempt should take. Keeping the controller path-aware now means
/// the relay can be added later without reshaping the connect flow — the `SecureSession` above the
/// transport is identical either way ("keyed to identity, not path").
enum PathSelector: Sendable {
    /// A Bonjour-discovered helper on the same LAN. Lowest latency; preferred when available.
    case lan(DiscoveredService)

    /// Tunnel through the rendezvous relay using this routing token when the LAN path is unavailable
    /// (phone and Mac on different networks / behind NAT). Uses the `rendezvousToken` minted into the
    /// `PairingPayload` at pairing time.
    case relay(rendezvousToken: Data)

    var connectionPath: ConnectionPath {
        switch self {
        case .lan: .lan
        case .relay: .relay
        }
    }
}

/// The realized path a live session runs over — shown on the connection chip.
enum ConnectionPath: String, Sendable, Equatable {
    case lan = "LAN"
    case relay = "Remote"
}
