import Foundation
import Testing
@testable import PocketMacKit

@Suite("AEAD record layer")
struct AEADChannelTests {
    /// Builds two channels with mirrored directional keys — what a completed handshake produces.
    static func mirroredChannels() -> (initiator: AEADChannel, responder: AEADChannel) {
        func rand(_ n: Int) -> Data { Data((0 ..< n).map { _ in UInt8.random(in: 0 ... 255) }) }
        let k1 = rand(32), k2 = rand(32), s1 = rand(4), s2 = rand(4)
        let pA = PeerID(publicKey: rand(32)), pB = PeerID(publicKey: rand(32))
        let initiator = AEADChannel(keys: SessionKeys(sendKey: k1, recvKey: k2, sendSalt: s1, recvSalt: s2, peerID: pB))
        let responder = AEADChannel(keys: SessionKeys(sendKey: k2, recvKey: k1, sendSalt: s2, recvSalt: s1, peerID: pA))
        return (initiator, responder)
    }

    @Test("seal → open round-trips plaintext")
    func roundTrip() throws {
        var (a, b) = Self.mirroredChannels()
        let plaintext = Data("pointer-move frame".utf8)
        let record = try a.seal(plaintext)
        #expect(try b.open(record) == plaintext)
    }

    @Test("many frames round-trip in order with advancing counters")
    func streamRoundTrip() throws {
        var (a, b) = Self.mirroredChannels()
        for i in 0 ..< 100 {
            let pt = Data("frame \(i)".utf8)
            #expect(try b.open(try a.seal(pt)) == pt)
        }
    }

    @Test("open with the wrong key fails authentication")
    func wrongKeyFails() throws {
        var (a, _) = Self.mirroredChannels()
        // A fresh responder whose recv key does not match A's send key.
        var wrong = Self.mirroredChannels().responder
        let record = try a.seal(Data("secret".utf8))
        #expect(throws: CryptoError.authenticationFailed) {
            _ = try wrong.open(record)
        }
    }

    @Test("a flipped ciphertext byte fails authentication (tamper rejection)")
    func tamperedCiphertextFails() throws {
        var (a, b) = Self.mirroredChannels()
        var record = try a.seal(Data("the quick brown fox".utf8))
        record[9] ^= 0x01 // a ciphertext byte (past the 8-byte counter)
        #expect(throws: CryptoError.authenticationFailed) {
            _ = try b.open(record)
        }
    }

    @Test("a flipped tag byte fails authentication")
    func tamperedTagFails() throws {
        var (a, b) = Self.mirroredChannels()
        var record = try a.seal(Data("payload".utf8))
        record[record.count - 1] ^= 0x80 // last byte = part of the Poly1305 tag
        #expect(throws: CryptoError.authenticationFailed) {
            _ = try b.open(record)
        }
    }

    @Test("a record too short to hold counter+tag is malformed")
    func truncatedRecordRejected() throws {
        var (_, b) = Self.mirroredChannels()
        #expect(throws: CryptoError.malformedRecord) {
            _ = try b.open(Data([0, 1, 2, 3])) // < 8 + 16
        }
    }

    @Test("sealing the same plaintext twice yields distinct records with advancing counters")
    func nonceIsCounterDerived() throws {
        var (a, _) = Self.mirroredChannels()
        let pt = Data("same".utf8)
        let r0 = try a.seal(pt)
        let r1 = try a.seal(pt)
        #expect(r0 != r1)                        // counter advanced → different nonce → different ciphertext
        #expect(r0.prefix(8) == Data([0,0,0,0,0,0,0,0]))
        #expect(r1.prefix(8) == Data([0,0,0,0,0,0,0,1]))
    }

    @Test("a replayed record is rejected on the second delivery")
    func replayRejected() throws {
        var (a, b) = Self.mirroredChannels()
        let record = try a.seal(Data("once".utf8))
        _ = try b.open(record)                    // first delivery accepted
        #expect(throws: CryptoError.self) {
            _ = try b.open(record)                // replay dropped
        }
    }

    @Test("an out-of-order (lower counter) record is rejected")
    func reorderRejected() throws {
        var (a, b) = Self.mirroredChannels()
        let r0 = try a.seal(Data("zero".utf8))
        let r1 = try a.seal(Data("one".utf8))
        _ = try b.open(r1)                        // deliver counter 1 first
        #expect(throws: CryptoError.self) {
            _ = try b.open(r0)                    // counter 0 now < highest seen → rejected
        }
    }
}

@Suite("Replay window policy")
struct ReplayWindowTests {
    @Test("strictly-increasing counters are accepted")
    func monotonicAccepted() throws {
        var w = ReplayWindow()
        for c in [UInt64(0), 1, 2, 5, 9, 100] { try w.validate(c) }
    }

    @Test("a duplicate counter is rejected")
    func duplicateRejected() throws {
        var w = ReplayWindow()
        try w.validate(7)
        #expect(throws: CryptoError.self) { try w.validate(7) }
    }

    @Test("a non-increasing counter is rejected")
    func nonIncreasingRejected() throws {
        var w = ReplayWindow()
        try w.validate(10)
        #expect(throws: CryptoError.self) { try w.validate(4) }
    }
}
