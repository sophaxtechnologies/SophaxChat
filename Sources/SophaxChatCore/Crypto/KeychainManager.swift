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

    // MARK: - Signed Prekey Creation Date

    /// Stores the Date the current signed prekey was generated.
    /// Used to trigger rotation after 7 days.
    public func saveSignedPreKeyDate(_ date: Date) throws {
        var ti = date.timeIntervalSinceReferenceDate
        let data = Data(bytes: &ti, count: MemoryLayout<Double>.size)
        try save(data: data, account: "spk.created_at")
    }

    public func loadSignedPreKeyDate() throws -> Date {
        let data = try load(account: "spk.created_at")
        guard data.count == MemoryLayout<Double>.size else {
            throw SophaxError.keychainError(errSecItemNotFound)
        }
        let ti = data.withUnsafeBytes { $0.load(as: Double.self) }
        return Date(timeIntervalSinceReferenceDate: ti)
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

    // MARK: - Group Keys

    public func saveGroupKey(_ key: SymmetricKey, groupID: String) throws {
        let data = key.withUnsafeBytes { Data($0) }
        try save(data: data, account: "group.key.\(groupID)")
    }

    public func loadGroupKey(groupID: String) throws -> SymmetricKey {
        let data = try load(account: "group.key.\(groupID)")
        return SymmetricKey(data: data)
    }

    public func deleteGroupKey(groupID: String) {
        let query: [CFString: Any] = [
            kSecClass:        kSecClassGenericPassword,
            kSecAttrService:  service,
            kSecAttrAccount:  "group.key.\(groupID)"
        ]
        SecItemDelete(query as CFDictionary)
    }

    // MARK: - Sender Key States (v2 group messaging)

    /// Save all peer sender key states for a group as a single JSON blob.
    /// Key: peerID → SenderKeyState.
    public func savePeerSenderKeyStates(_ states: [String: SenderKeyState], groupID: String) throws {
        let data = try JSONEncoder().encode(states)
        try save(data: data, account: "skd.peers.\(groupID)")
    }

    /// Load peer sender key states; returns empty dict if none stored yet.
    public func loadPeerSenderKeyStates(groupID: String) -> [String: SenderKeyState] {
        guard let data   = try? load(account: "skd.peers.\(groupID)"),
              let states = try? JSONDecoder().decode([String: SenderKeyState].self, from: data)
        else { return [:] }
        return states
    }

    public func saveMySenderKeyState(_ state: SenderKeyState, groupID: String) throws {
        let data = try JSONEncoder().encode(state)
        try save(data: data, account: "skd.mine.\(groupID)")
    }

    /// Returns nil if no sender key has been generated for this group yet.
    public func loadMySenderKeyState(groupID: String) -> SenderKeyState? {
        guard let data  = try? load(account: "skd.mine.\(groupID)"),
              let state = try? JSONDecoder().decode(SenderKeyState.self, from: data)
        else { return nil }
        return state
    }

    /// Delete all sender key material for a group (called on leave).
    public func deleteAllSenderKeyStates(groupID: String) {
        let q1: [CFString: Any] = [kSecClass: kSecClassGenericPassword,
                                   kSecAttrService: service,
                                   kSecAttrAccount: "skd.peers.\(groupID)"]
        SecItemDelete(q1 as CFDictionary)
        let q2: [CFString: Any] = [kSecClass: kSecClassGenericPassword,
                                   kSecAttrService: service,
                                   kSecAttrAccount: "skd.mine.\(groupID)"]
        SecItemDelete(q2 as CFDictionary)
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
