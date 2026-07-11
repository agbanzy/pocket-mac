import Foundation
import CryptoKit

/// Holds a device's long-term X25519 identity. The private key never leaves the store.
///
/// Design-doc §6 says "Secure Enclave / Keychain". Honest correction carried here: X25519 keys
/// **cannot** reside in the Secure Enclave (it is P-256 only), so the durable implementation is
/// ``KeychainIdentityStore`` with `kSecAttrAccessibleWhenUnlockedThisDeviceOnly`, non-synchronizable.
/// Hardware binding later means adding a P-256 Secure-Enclave attestation key alongside this DH key.
public protocol IdentityStoring: Sendable {
    func loadOrCreateIdentity() throws -> DeviceIdentity
    func privateKey() throws -> Curve25519.KeyAgreement.PrivateKey
}

/// In-memory identity for tests, the probe CLI, and previews. Not persisted.
public final class InMemoryIdentityStore: IdentityStoring, @unchecked Sendable {
    private let key: Curve25519.KeyAgreement.PrivateKey

    public init(privateKey: Curve25519.KeyAgreement.PrivateKey = Curve25519.KeyAgreement.PrivateKey()) {
        self.key = privateKey
    }

    public func loadOrCreateIdentity() throws -> DeviceIdentity {
        DeviceIdentity(publicKey: key.publicKey)
    }

    public func privateKey() throws -> Curve25519.KeyAgreement.PrivateKey { key }
}

#if canImport(Security)
import Security

/// Keychain-backed identity for the shipping apps. Stores the raw X25519 private key as a generic
/// password, accessible only when the device is unlocked and never synced off-device.
public final class KeychainIdentityStore: IdentityStoring, @unchecked Sendable {
    private let service: String
    private let account: String
    private let lock = NSLock()

    public init(service: String = "com.innoedge.pocketmac.identity", account: String = "device-x25519") {
        self.service = service
        self.account = account
    }

    public func loadOrCreateIdentity() throws -> DeviceIdentity {
        DeviceIdentity(publicKey: try key().publicKey)
    }

    public func privateKey() throws -> Curve25519.KeyAgreement.PrivateKey {
        try key()
    }

    private func key() throws -> Curve25519.KeyAgreement.PrivateKey {
        lock.lock(); defer { lock.unlock() }
        if let existing = try readKey() { return existing }
        let fresh = Curve25519.KeyAgreement.PrivateKey()
        try storeKey(fresh)
        return fresh
    }

    private func baseQuery() -> [String: Any] {
        [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
        ]
    }

    private func readKey() throws -> Curve25519.KeyAgreement.PrivateKey? {
        var query = baseQuery()
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne
        var item: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &item)
        switch status {
        case errSecSuccess:
            guard let data = item as? Data else { return nil }
            return try Curve25519.KeyAgreement.PrivateKey(rawRepresentation: data)
        case errSecItemNotFound:
            return nil
        default:
            throw CryptoError.handshakeFailed(reason: "keychain read failed (\(status))")
        }
    }

    private func storeKey(_ key: Curve25519.KeyAgreement.PrivateKey) throws {
        var query = baseQuery()
        query[kSecValueData as String] = key.rawRepresentation
        query[kSecAttrAccessible as String] = kSecAttrAccessibleWhenUnlockedThisDeviceOnly
        query[kSecAttrSynchronizable as String] = false
        let status = SecItemAdd(query as CFDictionary, nil)
        guard status == errSecSuccess || status == errSecDuplicateItem else {
            throw CryptoError.handshakeFailed(reason: "keychain write failed (\(status))")
        }
    }
}
#endif
