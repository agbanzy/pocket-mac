import Foundation
import CryptoKit
import PocketMacKit

/// Thin wrapper over the kit's `KeychainIdentityStore`. Owns this phone's long-term X25519 identity;
/// the private key is created on first use and never leaves the Keychain. Used as the Noise
/// initiator's `localStatic` during the pairing/connect handshake.
@MainActor
final class IdentityService {
    private let store: IdentityStoring

    init(store: IdentityStoring = KeychainIdentityStore()) {
        self.store = store
    }

    /// This device's public identity + derived `PeerID`, materializing the keypair on first call.
    func identity() throws -> DeviceIdentity {
        try store.loadOrCreateIdentity()
    }

    /// The private static key handed to `NoisePatternHandshake.performInitiator` as `localStatic`.
    func privateKey() throws -> Curve25519.KeyAgreement.PrivateKey {
        try store.privateKey()
    }

    /// Short fingerprint of this device's identity, for display. Never throws to the UI.
    var peerFingerprint: String {
        (try? store.loadOrCreateIdentity().peerID.fingerprint) ?? "unavailable"
    }
}
