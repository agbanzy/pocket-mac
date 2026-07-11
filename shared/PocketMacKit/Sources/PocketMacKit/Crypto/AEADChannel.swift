import Foundation
import CryptoKit

/// The per-frame record layer: ChaCha20-Poly1305 AEAD under a 64-bit monotonic counter nonce,
/// with replay rejection on receive (design doc §6).
///
/// Wire record layout:
/// ```
/// [u64 counter, big-endian][ciphertext…][16-byte Poly1305 tag]
/// ```
/// The nonce is reconstructed on the receiver from `salt(4) ‖ counter(8)`; it is never transmitted.
/// Send and receive use distinct keys and salts, so the two directions share no nonce space.
public struct AEADChannel: SecureChannel {
    public let peerID: PeerID

    private let sendKey: SymmetricKey
    private let recvKey: SymmetricKey
    private let sendSalt: Data // 4 bytes
    private let recvSalt: Data // 4 bytes

    private var sendCounter: UInt64 = 0
    private var replayWindow = ReplayWindow()

    /// Poly1305 tag length.
    private static let tagLength = 16
    /// Counter prefix length on every record.
    private static let counterLength = 8

    public init(keys: SessionKeys) {
        self.peerID = keys.peerID
        self.sendKey = SymmetricKey(data: keys.sendKey)
        self.recvKey = SymmetricKey(data: keys.recvKey)
        self.sendSalt = keys.sendSalt
        self.recvSalt = keys.recvSalt
    }

    // MARK: Seal

    public mutating func seal(_ plaintext: Data) throws -> Data {
        // Guard against nonce reuse at counter exhaustion — tear the session down, never wrap.
        guard sendCounter != UInt64.max else { throw CryptoError.nonceExhausted }

        let counter = sendCounter
        let nonce = try ChaChaPoly.Nonce(data: Self.nonceData(salt: sendSalt, counter: counter))
        let box = try ChaChaPoly.seal(plaintext, using: sendKey, nonce: nonce)

        var record = Data()
        record.append(Self.counterBytes(counter))
        record.append(box.ciphertext)
        record.append(box.tag)

        sendCounter += 1
        return record
    }

    // MARK: Open

    public mutating func open(_ record: Data) throws -> Data {
        guard record.count >= Self.counterLength + Self.tagLength else {
            throw CryptoError.malformedRecord
        }
        let bytes = [UInt8](record)
        let counter = Self.readCounter(bytes)

        // Replay check happens BEFORE the AEAD open so a flood of replays is cheap to reject.
        try replayWindow.validate(counter)

        let ciphertextEnd = bytes.count - Self.tagLength
        let ciphertext = Data(bytes[Self.counterLength ..< ciphertextEnd])
        let tag = Data(bytes[ciphertextEnd ..< bytes.count])

        let nonce = try ChaChaPoly.Nonce(data: Self.nonceData(salt: recvSalt, counter: counter))
        do {
            let box = try ChaChaPoly.SealedBox(nonce: nonce, ciphertext: ciphertext, tag: tag)
            return try ChaChaPoly.open(box, using: recvKey)
        } catch {
            throw CryptoError.authenticationFailed
        }
    }

    // MARK: Nonce / counter helpers

    /// 12-byte nonce: `salt(4) ‖ counter(8, big-endian)`.
    private static func nonceData(salt: Data, counter: UInt64) -> Data {
        var data = Data()
        data.append(salt.prefix(4))
        data.append(counterBytes(counter))
        return data
    }

    private static func counterBytes(_ counter: UInt64) -> Data {
        var value = counter.bigEndian
        return withUnsafeBytes(of: &value) { Data($0) }
    }

    private static func readCounter(_ bytes: [UInt8]) -> UInt64 {
        var value: UInt64 = 0
        for i in 0 ..< counterLength {
            value = (value << 8) | UInt64(bytes[i])
        }
        return value
    }
}
