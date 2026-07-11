import Foundation
import PocketMacKit

/// A remembered Mac pairing on the phone side. The persisted pairing-payload URL is the source of
/// truth — it carries everything needed to re-establish the encrypted session (`macPublicKey` for the
/// initiator's `remoteStatic`, and the SAS that binds the handshake prologue).
struct PairedMac: Codable, Equatable, Identifiable {
    let payloadURLString: String
    let displayName: String
    let peerIDRawValue: Data
    let pairedAt: Date

    var id: Data { peerIDRawValue }
    var peerID: PeerID { PeerID(rawValue: peerIDRawValue) }

    /// Re-parsed pairing payload. Optional because the stored URL string is authoritative.
    var payload: PairingPayload? { try? PairingPayload(urlString: payloadURLString) }

    /// The kit `PeerRecord` view of this pairing (as required by the app model).
    var peerRecord: PeerRecord {
        PeerRecord(peerID: peerID,
                   publicKey: payload?.macPublicKey ?? Data(),
                   displayName: displayName,
                   pairedAt: pairedAt)
    }

    init(payload: PairingPayload, pairedAt: Date = Date()) {
        self.payloadURLString = payload.urlString()
        self.displayName = payload.deviceName
        self.peerIDRawValue = payload.macPeerID.rawValue
        self.pairedAt = pairedAt
    }
}

/// Persists the currently paired Mac in `UserDefaults`. Single-Mac scope for Milestone 0; the storage
/// shape (a Codable record keyed off `PeerID`) generalizes to multiple remembered Macs later.
@MainActor
final class PeerVault {
    private let defaults: UserDefaults
    private let key = "com.innoedge.pocketmac.pairedMac"

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
    }

    func load() -> PairedMac? {
        guard let data = defaults.data(forKey: key) else { return nil }
        return try? JSONDecoder().decode(PairedMac.self, from: data)
    }

    func save(_ mac: PairedMac) {
        guard let data = try? JSONEncoder().encode(mac) else { return }
        defaults.set(data, forKey: key)
    }

    func clear() {
        defaults.removeObject(forKey: key)
    }
}
