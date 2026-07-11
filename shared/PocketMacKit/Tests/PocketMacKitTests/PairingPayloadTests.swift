import Foundation
import CryptoKit
import Testing
@testable import PocketMacKit

@Suite("Pairing payload codec")
struct PairingPayloadTests {
    func sampleMac() -> DeviceIdentity {
        DeviceIdentity(publicKey: Curve25519.KeyAgreement.PrivateKey().publicKey)
    }

    @Test("round-trips through its URL form (QR ≡ deep link)")
    func urlRoundTrip() throws {
        let payload = PairingPayload(macIdentity: sampleMac(),
                                     deviceName: "Godwin’s MacBook Pro",
                                     rendezvousToken: PairingCode.makeRendezvousToken(),
                                     sas: PairingCode.makeSAS())
        let decoded = try PairingPayload(urlString: payload.urlString())
        #expect(decoded == payload)
        #expect(decoded.macPeerID == payload.macPeerID)
    }

    @Test("the URL is a well-formed pocketmac pairing link")
    func urlShape() throws {
        let payload = PairingPayload(macIdentity: sampleMac(), deviceName: "Mac",
                                     rendezvousToken: PairingCode.makeRendezvousToken(), sas: "424242")
        let url = payload.urlString()
        #expect(url.hasPrefix("pocketmac://pair?"))
        #expect(url.contains("sas=424242"))
    }

    @Test("the pairing prologue changes with the SAS")
    func prologueBindsSAS() throws {
        let mac = sampleMac()
        let rt = PairingCode.makeRendezvousToken()
        let a = PairingPayload(macIdentity: mac, deviceName: "Mac", rendezvousToken: rt, sas: "111111")
        let b = PairingPayload(macIdentity: mac, deviceName: "Mac", rendezvousToken: rt, sas: "222222")
        #expect(a.pairingPrologue != b.pairingPrologue)
    }

    @Test("a malformed pairing URL throws instead of trapping")
    func malformedURLThrows() {
        #expect(throws: CryptoError.self) {
            _ = try PairingPayload(urlString: "pocketmac://pair?v=1&pk=notbase64!!")
        }
        #expect(throws: CryptoError.self) {
            _ = try PairingPayload(urlString: "https://example.com/pair")
        }
    }

    @Test("a device name with spaces and unicode survives the URL round-trip")
    func unicodeNameRoundTrip() throws {
        let payload = PairingPayload(macIdentity: sampleMac(),
                                     deviceName: "Élise’s Mac — office 🏢",
                                     rendezvousToken: PairingCode.makeRendezvousToken(), sas: "007007")
        #expect(try PairingPayload(urlString: payload.urlString()) == payload)
    }
}
