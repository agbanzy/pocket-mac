import Foundation
import CryptoKit

/// The out-of-band pairing bundle the Mac shows and the phone consumes. Encodes to a single
/// `pocketmac://pair?…` URL that is rendered as a **QR code** on device and injected as a
/// **deep link** in the Simulator (which has no camera) — the same struct decoded two ways, so both
/// paths exercise the identical codec.
///
/// The `sas` (6-digit short authentication string) is bound into the handshake prologue
/// (``pairingPrologue``): a wrong PIN produces a different transcript hash and the first AEAD open
/// fails, giving wrong-PIN rejection. The `rendezvousToken` is a random relay routing token minted
/// at pairing time — never a cryptographic key.
public struct PairingPayload: Sendable, Equatable {
    public let version: UInt8
    public let macPublicKey: Data       // raw 32-byte X25519
    public let deviceName: String
    public let rendezvousToken: Data    // 16 bytes, for the relay path
    public let sas: String              // 6 digits

    public var macPeerID: PeerID { PeerID(publicKey: macPublicKey) }

    /// Bytes bound into the Noise prologue for the pairing handshake. Both ends derive it from the
    /// shared SAS; a mismatch fails the handshake.
    public var pairingPrologue: Data { Data("PocketMac/pair/v1".utf8) + Data(sas.utf8) }

    public init(version: UInt8 = PocketMac.wireProtocolVersion,
                macPublicKey: Data,
                deviceName: String,
                rendezvousToken: Data,
                sas: String) {
        self.version = version
        self.macPublicKey = macPublicKey
        self.deviceName = deviceName
        self.rendezvousToken = rendezvousToken
        self.sas = sas
    }

    public init(macIdentity: DeviceIdentity, deviceName: String, rendezvousToken: Data, sas: String) {
        self.init(macPublicKey: macIdentity.rawPublicKey,
                  deviceName: deviceName,
                  rendezvousToken: rendezvousToken,
                  sas: sas)
    }

    // MARK: URL form (QR string ≡ deep link)

    public func urlString() -> String {
        var components = URLComponents()
        components.scheme = "pocketmac"
        components.host = "pair"
        components.queryItems = [
            URLQueryItem(name: "v", value: String(version)),
            URLQueryItem(name: "pk", value: Base64URL.encode(macPublicKey)),
            URLQueryItem(name: "n", value: deviceName),
            URLQueryItem(name: "rt", value: Base64URL.encode(rendezvousToken)),
            URLQueryItem(name: "sas", value: sas),
        ]
        return components.string ?? ""
    }

    public init(urlString: String) throws {
        guard let url = URL(string: urlString) else {
            throw CryptoError.handshakeFailed(reason: "invalid pairing URL")
        }
        try self.init(url: url)
    }

    public init(url: URL) throws {
        guard url.scheme == "pocketmac", url.host == "pair",
              let components = URLComponents(url: url, resolvingAgainstBaseURL: false),
              let items = components.queryItems else {
            throw CryptoError.handshakeFailed(reason: "not a pocketmac pairing URL")
        }
        func value(_ name: String) -> String? { items.first { $0.name == name }?.value }

        guard let vStr = value("v"), let v = UInt8(vStr),
              let pkStr = value("pk"), let pk = Base64URL.decode(pkStr), pk.count == 32,
              let name = value("n"),
              let rtStr = value("rt"), let rt = Base64URL.decode(rtStr),
              let sas = value("sas") else {
            throw CryptoError.handshakeFailed(reason: "pairing URL missing fields")
        }
        self.init(version: v, macPublicKey: pk, deviceName: name, rendezvousToken: rt, sas: sas)
    }
}

/// URL-safe base64 without padding (`+/` → `-_`, `=` stripped).
enum Base64URL {
    static func encode(_ data: Data) -> String {
        data.base64EncodedString()
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
    }

    static func decode(_ string: String) -> Data? {
        var s = string.replacingOccurrences(of: "-", with: "+")
                      .replacingOccurrences(of: "_", with: "/")
        let remainder = s.count % 4
        if remainder > 0 { s += String(repeating: "=", count: 4 - remainder) }
        return Data(base64Encoded: s)
    }
}
