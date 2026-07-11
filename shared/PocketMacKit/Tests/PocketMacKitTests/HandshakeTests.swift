import Foundation
import CryptoKit
import Testing
@testable import PocketMacKit

@Suite("Noise IK handshake")
struct HandshakeTests {
    typealias PrivKey = Curve25519.KeyAgreement.PrivateKey

    /// Runs a full IK exchange in memory and returns both sides' completed handshakes.
    /// `rsForInitiator` lets a test pin a wrong responder static (MITM); prologues can differ (wrong PIN).
    static func exchange(
        initiatorStatic: PrivKey,
        responderStatic: PrivKey,
        rsForInitiator: Curve25519.KeyAgreement.PublicKey,
        initiatorPrologue: Data,
        responderPrologue: Data,
        tamperMessage1: ((inout Data) -> Void)? = nil
    ) throws -> (initiator: NoiseHandshakeIK, responder: NoiseHandshakeIK) {
        var initiator = NoiseHandshakeIK(role: .initiator, localStatic: initiatorStatic,
                                         remoteStatic: rsForInitiator, prologue: initiatorPrologue)
        var responder = NoiseHandshakeIK(role: .responder, localStatic: responderStatic,
                                         remoteStatic: nil, prologue: responderPrologue)
        var m1 = try initiator.writeMessage1()
        tamperMessage1?(&m1)
        _ = try responder.readMessage1(m1)
        let m2 = try responder.writeMessage2()
        _ = try initiator.readMessage2(m2)
        return (initiator, responder)
    }

    @Test("both sides derive matching, mirrored session keys")
    func bothSidesAgree() throws {
        let iStatic = PrivKey(), rStatic = PrivKey()
        let prologue = Data("pair-sas-123456".utf8)
        let (i, r) = try Self.exchange(initiatorStatic: iStatic, responderStatic: rStatic,
                                       rsForInitiator: rStatic.publicKey,
                                       initiatorPrologue: prologue, responderPrologue: prologue)
        let iKeys = try i.makeSessionKeys()
        let rKeys = try r.makeSessionKeys()

        #expect(iKeys.sendKey == rKeys.recvKey)
        #expect(iKeys.recvKey == rKeys.sendKey)
        #expect(iKeys.sendSalt == rKeys.recvSalt)
        #expect(iKeys.recvSalt == rKeys.sendSalt)

        // The peers authenticate each other's real identities.
        #expect(iKeys.peerID == DeviceIdentity(publicKey: rStatic.publicKey).peerID)
        #expect(rKeys.peerID == DeviceIdentity(publicKey: iStatic.publicKey).peerID)

        // And the derived keys actually interoperate through the record layer, end to end.
        var iCh = AEADChannel(keys: iKeys)
        var rCh = AEADChannel(keys: rKeys)
        let ping = Data("hello from phone".utf8)
        #expect(try rCh.open(try iCh.seal(ping)) == ping)
        let pong = Data("hello from mac".utf8)
        #expect(try iCh.open(try rCh.seal(pong)) == pong)
    }

    @Test("responder authenticates the initiator's PeerID after message 1")
    func responderLearnsPeerID() throws {
        let iStatic = PrivKey(), rStatic = PrivKey()
        var initiator = NoiseHandshakeIK(role: .initiator, localStatic: iStatic,
                                         remoteStatic: rStatic.publicKey, prologue: Data())
        var responder = NoiseHandshakeIK(role: .responder, localStatic: rStatic,
                                         remoteStatic: nil, prologue: Data())
        #expect(responder.remotePeerID == nil)      // unknown before msg1
        _ = try responder.readMessage1(try initiator.writeMessage1())
        #expect(responder.remotePeerID == DeviceIdentity(publicKey: iStatic.publicKey).peerID)
    }

    @Test("two independent sessions produce distinct keys (fresh ephemerals)")
    func distinctSessions() throws {
        let iStatic = PrivKey(), rStatic = PrivKey()
        func run() throws -> SessionKeys {
            let (i, _) = try Self.exchange(initiatorStatic: iStatic, responderStatic: rStatic,
                                           rsForInitiator: rStatic.publicKey,
                                           initiatorPrologue: Data(), responderPrologue: Data())
            return try i.makeSessionKeys()
        }
        #expect(try run().sendKey != run().sendKey)
    }

    @Test("a wrong pinned responder static is rejected (MITM defense)")
    func wrongPinnedStaticRejected() throws {
        let iStatic = PrivKey(), rStatic = PrivKey(), attacker = PrivKey()
        #expect(throws: CryptoError.self) {
            // Initiator pins the attacker's key, but talks to the real responder.
            _ = try Self.exchange(initiatorStatic: iStatic, responderStatic: rStatic,
                                  rsForInitiator: attacker.publicKey,
                                  initiatorPrologue: Data(), responderPrologue: Data())
        }
    }

    @Test("a mismatched pairing PIN is rejected (channel binding)")
    func wrongPINRejected() throws {
        let iStatic = PrivKey(), rStatic = PrivKey()
        #expect(throws: CryptoError.self) {
            _ = try Self.exchange(initiatorStatic: iStatic, responderStatic: rStatic,
                                  rsForInitiator: rStatic.publicKey,
                                  initiatorPrologue: Data("sas-111111".utf8),
                                  responderPrologue: Data("sas-999999".utf8))
        }
    }

    @Test("a tampered handshake message is rejected")
    func tamperedMessageRejected() throws {
        let iStatic = PrivKey(), rStatic = PrivKey()
        #expect(throws: CryptoError.self) {
            _ = try Self.exchange(initiatorStatic: iStatic, responderStatic: rStatic,
                                  rsForInitiator: rStatic.publicKey,
                                  initiatorPrologue: Data(), responderPrologue: Data(),
                                  tamperMessage1: { msg in msg[40] ^= 0x01 }) // inside the encrypted static
        }
    }
}
