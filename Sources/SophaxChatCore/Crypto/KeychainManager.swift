// KeychainManager.swift
// SophaxChatCore
//
// Secure storage for cryptographic keys using the iOS Keychain.
// All keys are stored with kSecAttrAccessibleWhenUnlockedThisDeviceOnly
// — they are not backed up to iCloud and are wiped on device restore.

import Foundation
import Security
import CryptoKit

public final class KeychainManager {

    private let service: String
    private let accessGroup: String?

    public init(service: String = "com.sophax.SophaxChat", accessGroup: String? = nil) {
        self.service = service
        self.accessGroup = accessGroup
    }

    // MARK: - Identity Signing Key (Ed25519)

    public func saveSigningKey(_ key: Curve25519.Signing.PrivateKey) throws {
        try save(data: key.rawRepresentation, account: "identity.signing")
    }

    public func loadSigningKey() throws -> Curve25519.Signing.PrivateKey {
        let data = try load(account: "identity.signing")
        return try Curve25519.Signing.PrivateKey(rawRepresentation: data)
    }

    // MARK: - Identity DH Key (X25519)

    public func saveDHIdentityKey(_ key: Curve25519.KeyAgreement.PrivateKey) throws {
        try save(data: key.rawRepresentation, account: "identity.dh")
    }

    public func loadDHIdentityKey() throws -> Curve25519.KeyAgreement.PrivateKey {
        let data = try load(account: "identity.dh")
        return try Curve25519.KeyAgreement.PrivateKey(rawRepresentation: data)
    }

    // MARK: - Signed Prekey

    public func saveSignedPreKey(id: UInt32, key: Curve25519.KeyAgreement.PrivateKey) throws {
        try save(data: key.rawRepresentation, account: "spk.\(id)")
        try save(data: Data(withUnsafeBytes(of: id) { Data($0) }), account: "spk.current_id")
    }

    public func loadSignedPreKey() throws -> (id: UInt32, key: Curve25519.KeyAgreement.PrivateKey) {
        let idData = try load(account: "spk.current_id")
        guard idData.count == 4 else { throw SophaxError.keychainError(errSecItemNotFound) }
        let id = idData.withUnsafeBytes { $0.load(as: UInt32.self) }
        let keyData = try load(account: "spk.\(id)")
        let key = try Curve25519.KeyAgreement.PrivateKey(rawRepresentation: keyData)
        return (id, key)
    }

    // MARK: - One-Time Prekeys

    public func saveOneTimePreKey(id: UInt32, key: Curve25519.KeyAgreement.PrivateKey) throws {
        try save(data: key.rawRepresentation, account: "otpk.\(id)")
    }

    public func loadOneTimePreKey(id: UInt32) throws -> Curve25519.KeyAgreement.PrivateKey {
        let data = try load(account: "otpk.\(id)")
        return try Curve25519.KeyAgreement.PrivateKey(rawRepresentation: data)
    }

    public func deleteOneTimePreKey(id: UInt32) throws {
        try delete(account: "otpk.\(id)")
    }

    // MARK: - Session State

    public func saveSessionState(data: Data, peerID: String) throws {
        try save(data: data, account: "session.\(peerID)")
    }

    public func loadSessionState(peerID: String) throws -> Data {
        return try load(account: "session.\(peerID)")
    }

    public func deleteSessionState(peerID: String) throws {
        try delete(account: "session.\(peerID)")
    }

    // MARK: - Message Storage Key

    public func saveStorageKey(_ key: SymmetricKey) throws {
        let data = key.withUnsafeBytes { Data($0) }
        try save(data: data, account: "storage.master")
    }

    public func loadStorageKey() throws -> SymmetricKey {
        let data = try load(account: "storage.master")
        return SymmetricKey(data: data)
    }

    // MARK: - Username

    public func saveUsername(_ username: String) throws {
        guard let data = username.data(using: .utf8) else {
            throw SophaxError.invalidMessageFormat("Username not UTF-8 encodable")
        }
        try save(data: data, account: "user.username")
    }

    public func loadUsername() throws -> String {
        let data = try load(account: "user.username")
        guard let username = String(data: data, encoding: .utf8) else {
            throw SophaxError.invalidMessageFormat("Username not UTF-8 decodable")
        }
        return username
    }

    // MARK: - Existence Check

    public func hasIdentity() -> Bool {
        return (try? loadSigningKey()) != nil
    }

    // MARK: - Wipe (for account deletion / security)

    public func wipeAll() throws {
        let query: [CFString: Any] = [
            kSecClass: kSecClassGenericPassword,
            kSecAttrService: service
        ]
        let status = SecItemDelete(query as CFDictionary)
        guard status == errSecSuccess || status == errSecItemNotFound else {
            throw SophaxError.keychainError(status)
        }
    }

    // MARK: - Private helpers

    private func save(data: Data, account: String) throws {
        // Try to update first, then add
        let query = baseQuery(account: account)
        let update: [CFString: Any] = [
            kSecValueData: data,
            // kSecAttrAccessibleWhenUnlockedThisDeviceOnly:
            //   - Items NOT backed up to iCloud
            //   - Items NOT transferred to new device
            //   - Accessible only when device is unlocked
            kSecAttrAccessible: kSecAttrAccessibleWhenUnlockedThisDeviceOnly
        ]

        var status = SecItemUpdate(query as CFDictionary, update as CFDictionary)
        if status == errSecItemNotFound {
            var addQuery = query
            addQuery[kSecValueData] = data
            addQuery[kSecAttrAccessible] = kSecAttrAccessibleWhenUnlockedThisDeviceOnly
            status = SecItemAdd(addQuery as CFDictionary, nil)
        }

        guard status == errSecSuccess else {
            throw SophaxError.keychainError(status)
        }
    }

    private func load(account: String) throws -> Data {
        var query = baseQuery(account: account)
        query[kSecReturnData] = true
        query[kSecMatchLimit] = kSecMatchLimitOne

        var result: AnyObject?
        let status = SecItemCopyMatching(query as CFDictionary, &result)

        guard status == errSecSuccess, let data = result as? Data else {
            throw SophaxError.keychainError(status)
        }
        return data
    }

    private func delete(account: String) throws {
        let query = baseQuery(account: account)
        let status = SecItemDelete(query as CFDictionary)
        guard status == errSecSuccess || status == errSecItemNotFound else {
            throw SophaxError.keychainError(status)
        }
    }

    private func baseQuery(account: String) -> [CFString: Any] {
        var query: [CFString: Any] = [
            kSecClass: kSecClassGenericPassword,
            kSecAttrService: service,
            kSecAttrAccount: account
        ]
        if let accessGroup {
            query[kSecAttrAccessGroup] = accessGroup
        }
        return query
    }
}
