import Foundation
import CryptoKit

/// The Noise `IK` handshake on X25519 / ChaCha20-Poly1305 / SHA-256:
/// ```
/// <- s
/// ...
/// -> e, es, s, ss
/// <- e, ee, se
/// ```
/// The initiator already knows the responder's static public key (from pairing) — exactly the
/// `IK` premise, and WireGuard's pattern. This is a pure state machine (no I/O), so the full
/// exchange is unit-testable in memory. The transport-driven driver lives in ``NoisePatternHandshake``.
struct NoiseHandshakeIK {
    enum Role { case initiator, responder }

    let role: Role
    private var sym: NoiseSymmetricState
    private let s: Curve25519.KeyAgreement.PrivateKey       // local static
    private let sPub: Data
    private var e: Curve25519.KeyAgreement.PrivateKey?       // local ephemeral
    private var rs: Curve25519.KeyAgreement.PublicKey?       // remote static
    private var re: Curve25519.KeyAgreement.PublicKey?       // remote ephemeral

    static let protocolName = "Noise_IK_25519_ChaChaPoly_SHA256"
    /// Encrypted-static length in message 1: 32-byte key + 16-byte tag.
    private static let encStaticLength = 48

    /// - Parameters:
    ///   - remoteStatic: required for the initiator (the paired Mac's key); nil for the responder,
    ///     which learns the initiator's static from message 1.
    ///   - prologue: bound into the transcript before any token — carries the pairing SAS so a wrong
    ///     PIN yields a different handshake hash and the first AEAD open fails.
    ///   - ephemeral: injectable for deterministic tests; random in production.
    init(role: Role,
         localStatic: Curve25519.KeyAgreement.PrivateKey,
         remoteStatic: Curve25519.KeyAgreement.PublicKey?,
         prologue: Data,
         ephemeral: Curve25519.KeyAgreement.PrivateKey? = nil) {
        self.role = role
        self.s = localStatic
        self.sPub = localStatic.publicKey.rawRepresentation
        self.rs = remoteStatic
        self.e = ephemeral

        var sym = NoiseSymmetricState(protocolName: Self.protocolName)
        sym.mixHash(prologue)
        // Pre-message `<- s`: the responder's static public key, known to both sides.
        let responderStaticPub = (role == .initiator) ? (remoteStatic?.rawRepresentation ?? Data()) : sPub
        sym.mixHash(responderStaticPub)
        self.sym = sym
    }

    /// The authenticated peer, available once the remote static is known (responder: after msg1).
    var remotePeerID: PeerID? {
        rs.map { PeerID(publicKey: $0.rawRepresentation) }
    }

    // MARK: Message 1 — initiator → responder (e, es, s, ss)

    mutating func writeMessage1(payload: Data = Data()) throws -> Data {
        precondition(role == .initiator)
        guard let rs else { throw CryptoError.handshakeFailed(reason: "initiator missing remote static") }
        let eph = e ?? Curve25519.KeyAgreement.PrivateKey()
        e = eph

        var out = Data()
        let ePub = eph.publicKey.rawRepresentation
        out.append(ePub)
        sym.mixHash(ePub)                                    // e
        sym.mixKey(try NoiseDH.agree(eph, rs))               // es
        out.append(try sym.encryptAndHash(sPub))             // s (encrypted static)
        sym.mixKey(try NoiseDH.agree(s, rs))                 // ss
        out.append(try sym.encryptAndHash(payload))          // payload
        return out
    }

    mutating func readMessage1(_ data: Data) throws -> Data {
        precondition(role == .responder)
        var reader = BinaryReader(data)
        let ePub = try reader.readRaw(32)
        let rePub = try publicKey(ePub)
        re = rePub
        sym.mixHash(ePub)                                    // e
        sym.mixKey(try NoiseDH.agree(s, rePub))              // es
        let encStatic = try reader.readRaw(Self.encStaticLength)
        let rsBytes = try sym.decryptAndHash(encStatic)      // s
        let rsPub = try publicKey(rsBytes)
        rs = rsPub
        sym.mixKey(try NoiseDH.agree(s, rsPub))              // ss
        return try sym.decryptAndHash(try reader.readRaw(reader.remaining)) // payload
    }

    // MARK: Message 2 — responder → initiator (e, ee, se)

    mutating func writeMessage2(payload: Data = Data()) throws -> Data {
        precondition(role == .responder)
        guard let re, let rs else { throw CryptoError.handshakeFailed(reason: "responder missing remote keys") }
        let eph = e ?? Curve25519.KeyAgreement.PrivateKey()
        e = eph

        var out = Data()
        let ePub = eph.publicKey.rawRepresentation
        out.append(ePub)
        sym.mixHash(ePub)                                    // e
        sym.mixKey(try NoiseDH.agree(eph, re))               // ee
        sym.mixKey(try NoiseDH.agree(eph, rs))               // se  (responder ephemeral ↔ initiator static)
        out.append(try sym.encryptAndHash(payload))          // payload
        return out
    }

    mutating func readMessage2(_ data: Data) throws -> Data {
        precondition(role == .initiator)
        guard let eph = e else { throw CryptoError.handshakeFailed(reason: "initiator missing ephemeral") }
        var reader = BinaryReader(data)
        let ePub = try reader.readRaw(32)
        let rePub = try publicKey(ePub)
        re = rePub
        sym.mixHash(ePub)                                    // e
        sym.mixKey(try NoiseDH.agree(eph, rePub))            // ee
        sym.mixKey(try NoiseDH.agree(s, rePub))              // se  (initiator static ↔ responder ephemeral)
        return try sym.decryptAndHash(try reader.readRaw(reader.remaining)) // payload
    }

    // MARK: Completion

    /// Derives the directional ``SessionKeys``. Both sides mirror: the initiator's send key is the
    /// responder's receive key, and vice versa. Directional 4-byte salts are split from the final
    /// transcript hash (identical on both ends), so both sides agree without extra negotiation.
    func makeSessionKeys() throws -> SessionKeys {
        guard let peerID = remotePeerID else {
            throw CryptoError.handshakeFailed(reason: "no authenticated remote static")
        }
        let (c1, c2) = sym.split()
        let saltA = sym.handshakeHash.prefix(4)
        let saltB = sym.handshakeHash.dropFirst(4).prefix(4)
        switch role {
        case .initiator:
            return SessionKeys(sendKey: c1, recvKey: c2, sendSalt: Data(saltA), recvSalt: Data(saltB), peerID: peerID)
        case .responder:
            return SessionKeys(sendKey: c2, recvKey: c1, sendSalt: Data(saltB), recvSalt: Data(saltA), peerID: peerID)
        }
    }

    private func publicKey(_ raw: Data) throws -> Curve25519.KeyAgreement.PublicKey {
        do {
            return try Curve25519.KeyAgreement.PublicKey(rawRepresentation: raw)
        } catch {
            throw CryptoError.invalidKeyLength
        }
    }
}
