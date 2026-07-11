import Foundation
import CryptoKit

/// Noise's HKDF: `temp_key = HMAC(ck, ikm)`, then `output_i = HMAC(temp_key, output_{i-1} ‖ i)`.
/// This is HKDF-Expand with the Noise-specified info bytes; implemented directly so it matches the
/// Noise spec exactly rather than relying on CryptoKit's `HKDF` info convention.
enum NoiseHKDF {
    static func derive(chainingKey: Data, inputKeyMaterial: Data, outputs: Int) -> [Data] {
        let tempKey = hmac(key: chainingKey, data: inputKeyMaterial)
        let o1 = hmac(key: tempKey, data: Data([0x01]))
        if outputs == 1 { return [o1] }
        let o2 = hmac(key: tempKey, data: o1 + Data([0x02]))
        if outputs == 2 { return [o1, o2] }
        let o3 = hmac(key: tempKey, data: o2 + Data([0x03]))
        return [o1, o2, o3]
    }

    static func hmac(key: Data, data: Data) -> Data {
        Data(HMAC<SHA256>.authenticationCode(for: data, using: SymmetricKey(data: key)))
    }
}

/// X25519 Diffie-Hellman, returning the raw 32-byte shared secret Noise expects.
enum NoiseDH {
    static func agree(_ priv: Curve25519.KeyAgreement.PrivateKey,
                      _ pub: Curve25519.KeyAgreement.PublicKey) throws -> Data {
        let secret = try priv.sharedSecretFromKeyAgreement(with: pub)
        return secret.withUnsafeBytes { Data($0) }
    }
}

/// Noise `CipherState`: an AEAD key plus a 64-bit nonce. `hasKey == false` means data passes through
/// as plaintext (used before the first `MixKey`).
struct NoiseCipherState {
    private var key: SymmetricKey?
    private var nonce: UInt64 = 0

    init(key: Data?) { self.key = key.map { SymmetricKey(data: $0) } }

    var hasKey: Bool { key != nil }

    mutating func encrypt(ad: Data, plaintext: Data) throws -> Data {
        guard let key else { return plaintext }
        let box = try ChaChaPoly.seal(plaintext, using: key, nonce: try Self.nonce(nonce), authenticating: ad)
        nonce &+= 1
        return box.ciphertext + box.tag
    }

    mutating func decrypt(ad: Data, ciphertext: Data) throws -> Data {
        guard let key else { return ciphertext }
        guard ciphertext.count >= 16 else { throw CryptoError.handshakeFailed(reason: "short AEAD blob") }
        let ct = ciphertext.prefix(ciphertext.count - 16)
        let tag = ciphertext.suffix(16)
        let plaintext: Data
        do {
            let box = try ChaChaPoly.SealedBox(nonce: try Self.nonce(nonce), ciphertext: ct, tag: tag)
            plaintext = try ChaChaPoly.open(box, using: key, authenticating: ad)
        } catch {
            throw CryptoError.authenticationFailed
        }
        nonce &+= 1
        return plaintext
    }

    /// Noise nonce: 32 bits of zero followed by the 64-bit counter, **little-endian**.
    private static func nonce(_ n: UInt64) throws -> ChaChaPoly.Nonce {
        var data = Data(count: 4)
        var le = n.littleEndian
        data.append(withUnsafeBytes(of: &le) { Data($0) })
        return try ChaChaPoly.Nonce(data: data)
    }
}

/// Noise `SymmetricState`: the chaining key + handshake hash + current cipher state, with the
/// `MixKey` / `MixHash` / `EncryptAndHash` / `DecryptAndHash` / `Split` operations from the spec.
struct NoiseSymmetricState {
    private var cipher: NoiseCipherState
    private var chainingKey: Data
    private(set) var handshakeHash: Data

    init(protocolName: String) {
        let name = Data(protocolName.utf8)
        if name.count <= 32 {
            var h = name
            h.append(Data(count: 32 - name.count))
            handshakeHash = h
        } else {
            handshakeHash = Data(SHA256.hash(data: name))
        }
        chainingKey = handshakeHash
        cipher = NoiseCipherState(key: nil)
    }

    mutating func mixKey(_ input: Data) {
        let out = NoiseHKDF.derive(chainingKey: chainingKey, inputKeyMaterial: input, outputs: 2)
        chainingKey = out[0]
        cipher = NoiseCipherState(key: out[1])
    }

    mutating func mixHash(_ data: Data) {
        handshakeHash = Data(SHA256.hash(data: handshakeHash + data))
    }

    mutating func encryptAndHash(_ plaintext: Data) throws -> Data {
        let ciphertext = try cipher.encrypt(ad: handshakeHash, plaintext: plaintext)
        mixHash(ciphertext)
        return ciphertext
    }

    mutating func decryptAndHash(_ ciphertext: Data) throws -> Data {
        let plaintext = try cipher.decrypt(ad: handshakeHash, ciphertext: ciphertext)
        mixHash(ciphertext)
        return plaintext
    }

    /// Produces the two directional transport keys. `c1` is initiator→responder, `c2` the reverse.
    func split() -> (c1: Data, c2: Data) {
        let out = NoiseHKDF.derive(chainingKey: chainingKey, inputKeyMaterial: Data(), outputs: 2)
        return (out[0], out[1])
    }
}
