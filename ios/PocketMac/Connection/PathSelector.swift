import Foundation
import PocketMacKit

/// Which network path a connection attempt should take. Keeping the controller path-aware now means
/// the relay can be added later without reshaping the connect flow — the `SecureSession` above the
/// transport is identical either way ("keyed to identity, not path").
enum PathSelector: Sendable {
    /// A Bonjour-discovered helper on the same LAN. Live for Milestone 0.
    case lan(DiscoveredService)

    /// TODO(Phase 8): tunnel through the rendezvous relay using this routing token when the LAN path
    /// is unavailable (phone and Mac on different networks / behind NAT). Not implemented yet — the
    /// controller returns an offline state for this case. See the `relay/` service and the
    /// `rendezvousToken` minted into the `PairingPayload` at pairing time.
    case relay(rendezvousToken: Data)
}
