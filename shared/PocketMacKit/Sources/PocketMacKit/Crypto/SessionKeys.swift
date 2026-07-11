import Foundation
import CryptoKit

/// The transport keys produced by a completed handshake's `Split()`, plus the authenticated peer.
///
/// Two independent directional keys (send/receive) so a record sealed for one direction can never be
/// opened as the other. A 4-byte per-direction salt prefixes the nonce for domain separation on top
/// of the already-distinct keys. Key material is stored as raw `Data` so the type is trivially `Sendable`.
public struct SessionKeys: Sendable, Equatable {
    public let sendKey: Data      // 32 bytes
    public let recvKey: Data      // 32 bytes
    public let sendSalt: Data     // 4 bytes
    public let recvSalt: Data     // 4 bytes
    public let peerID: PeerID

    public init(sendKey: Data, recvKey: Data, sendSalt: Data, recvSalt: Data, peerID: PeerID) {
        self.sendKey = sendKey
        self.recvKey = recvKey
        self.sendSalt = sendSalt
        self.recvSalt = recvSalt
        self.peerID = peerID
    }
}
