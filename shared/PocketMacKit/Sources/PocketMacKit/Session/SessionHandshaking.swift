import Foundation
import CryptoKit

/// Drives a ``NoiseHandshakeIK`` exchange over a ``Transport`` and returns the derived
/// ``SessionKeys``. A protocol so the handshake can be swapped (e.g. a `TLSChannel` contingency)
/// without touching the connection controllers.
public protocol SessionHandshaking: Sendable {
    /// The phone side: knows the Mac's static key from pairing and initiates.
    func performInitiator(
        over transport: any Transport,
        localStatic: Curve25519.KeyAgreement.PrivateKey,
        remoteStatic: Curve25519.KeyAgreement.PublicKey,
        prologue: Data
    ) async throws -> SessionKeys

    /// The Mac side: learns the phone's static from message 1 and authorizes it before replying.
    /// `authorize` receives the peer's id AND its raw public key, so a pairing flow can persist the
    /// new peer at the moment it is authenticated.
    func performResponder(
        over transport: any Transport,
        localStatic: Curve25519.KeyAgreement.PrivateKey,
        prologue: Data,
        authorize: @Sendable (PeerID, _ publicKey: Data) -> Bool
    ) async throws -> SessionKeys
}

/// The shipping handshake: Noise `IK` on CryptoKit primitives.
public struct NoisePatternHandshake: SessionHandshaking {
    public init() {}

    public func performInitiator(
        over transport: any Transport,
        localStatic: Curve25519.KeyAgreement.PrivateKey,
        remoteStatic: Curve25519.KeyAgreement.PublicKey,
        prologue: Data
    ) async throws -> SessionKeys {
        var handshake = NoiseHandshakeIK(role: .initiator, localStatic: localStatic,
                                         remoteStatic: remoteStatic, prologue: prologue)
        try await transport.send(try handshake.writeMessage1())
        _ = try handshake.readMessage2(try await transport.receive())
        return try handshake.makeSessionKeys()
    }

    public func performResponder(
        over transport: any Transport,
        localStatic: Curve25519.KeyAgreement.PrivateKey,
        prologue: Data,
        authorize: @Sendable (PeerID, _ publicKey: Data) -> Bool
    ) async throws -> SessionKeys {
        var handshake = NoiseHandshakeIK(role: .responder, localStatic: localStatic,
                                         remoteStatic: nil, prologue: prologue)
        _ = try handshake.readMessage1(try await transport.receive())

        // Accept-only-paired: authorize the learned initiator identity BEFORE replying. An
        // unauthorized peer gets no message 2 and never establishes a session.
        guard let peerID = handshake.remotePeerID,
              let publicKey = handshake.remoteStaticPublicKey,
              authorize(peerID, publicKey) else {
            throw CryptoError.handshakeFailed(reason: "peer not authorized")
        }
        try await transport.send(try handshake.writeMessage2())
        return try handshake.makeSessionKeys()
    }
}
