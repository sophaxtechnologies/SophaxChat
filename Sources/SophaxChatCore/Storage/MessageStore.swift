// MessageStore.swift
// SophaxChatCore
//
// Encrypted at-rest message storage.
//
// Architecture:
//   • One JSON file per conversation (named by peerID hash)
//   • Each file is encrypted with AES-256-GCM using a per-app master key
//   • Master key is stored in Keychain (kSecAttrAccessibleWhenUnlockedThisDeviceOnly)
//   • Files are stored in the app's private Application Support directory
//     (not accessible to other apps, not backed up if configured so)
//
// Security note: This provides "encryption at rest" — even if the filesystem
// is read by an attacker (e.g., physical access with device unlocked), the
// messages cannot be read without the Keychain-protected master key.
// For maximum security, enable "Full-disk encryption" (default on modern iOS).

import Foundation
import CryptoKit

public final class MessageStore: @unchecked Sendable {

    private let storageKey: SymmetricKey
    private let baseURL:    URL
    private let queue = DispatchQueue(label: "com.sophax.messagestore", qos: .userInitiated)

    // In-memory cache to avoid redundant decrypt operations
    private var cache: [String: [StoredMessage]] = [:]

    // MARK: - Init

    public init(keychain: KeychainManager) throws {
        // Load or generate the master storage key
        if let existing = try? keychain.loadStorageKey() {
            self.storageKey = existing
        } else {
            let newKey = SymmetricKey(size: .bits256)
            try keychain.saveStorageKey(newKey)
            self.storageKey = newKey
        }

        // Use Application Support directory (excluded from iCloud backup by default)
        guard let appSupport = FileManager.default.urls(
            for: .applicationSupportDirectory,
            in: .userDomainMask
        ).first else {
            throw SophaxError.invalidMessageFormat("Application Support directory unavailable")
        }
        self.baseURL = appSupport.appendingPathComponent("sophax_messages", isDirectory: true)

        try FileManager.default.createDirectory(at: baseURL, withIntermediateDirectories: true)

        // Exclude from iCloud backup
        var resourceValues = URLResourceValues()
        resourceValues.isExcludedFromBackup = true
        var mutableURL = baseURL
        try? mutableURL.setResourceValues(resourceValues)
    }

    // MARK: - Public API

    /// Load all messages for a conversation.
    public func messages(forPeer peerID: String) throws -> [StoredMessage] {
        if let cached = cache[peerID] { return cached }
        let messages = try loadFromDisk(peerID: peerID)
        cache[peerID] = messages
        return messages
    }

    /// Append a single message to a conversation.
    /// Idempotent: silently ignores duplicates (same message ID) to handle relay replays.
    public func append(message: StoredMessage) throws {
        var messages = (try? messages(forPeer: message.peerID)) ?? []
        guard !messages.contains(where: { $0.id == message.id }) else { return }
        messages.append(message)
        cache[message.peerID] = messages
        try saveToDisk(messages: messages, peerID: message.peerID)
    }

    /// Update the emoji reactions map for a specific message.
    public func updateReactions(_ reactions: [String: String], forMessageID messageID: String, peerID: String) throws {
        var messages = (try? self.messages(forPeer: peerID)) ?? []
        guard let idx = messages.firstIndex(where: { $0.id == messageID }) else { return }
        messages[idx].reactions = reactions.isEmpty ? nil : reactions
        cache[peerID] = messages
        try saveToDisk(messages: messages, peerID: peerID)
    }

    /// Update message status (sent → delivered, sending → failed, etc.).
    public func updateStatus(_ status: StoredMessage.MessageStatus, forMessageID messageID: String, peerID: String) throws {
        var messages = (try? self.messages(forPeer: peerID)) ?? []
        guard let idx = messages.firstIndex(where: { $0.id == messageID }) else { return }
        messages[idx].status = status
        cache[peerID] = messages
        try saveToDisk(messages: messages, peerID: peerID)
    }

    /// All conversation peer IDs that have stored messages.
    public func allConversationPeerIDs() -> [String] {
        guard let files = try? FileManager.default.contentsOfDirectory(at: baseURL, includingPropertiesForKeys: nil) else {
            return []
        }
        return files.map { $0.deletingPathExtension().lastPathComponent }
    }

    /// Delete all messages whose `expiresAt` timestamp is in the past.
    /// Called periodically by ChatManager (every 60 s) and on app launch.
    public func deleteExpiredMessages() {
        let now = Date()
        let peerIDs = allConversationPeerIDs()
        for peerID in peerIDs {
            guard var messages = try? self.messages(forPeer: peerID) else { continue }
            let before = messages.count
            messages.removeAll { msg in
                guard let exp = msg.expiresAt else { return false }
                return exp < now
            }
            guard messages.count != before else { continue }
            cache[peerID] = messages
            try? saveToDisk(messages: messages, peerID: peerID)
        }
    }

    /// Delete a single message by ID.
    public func deleteMessage(id: String, peerID: String) throws {
        var messages = (try? self.messages(forPeer: peerID)) ?? []
        messages.removeAll { $0.id == id }
        cache[peerID] = messages
        if messages.isEmpty {
            try? FileManager.default.removeItem(at: fileURL(for: peerID))
        } else {
            try saveToDisk(messages: messages, peerID: peerID)
        }
    }

    /// Delete all messages for a conversation.
    public func deleteConversation(peerID: String) throws {
        let url = fileURL(for: peerID)
        cache.removeValue(forKey: peerID)
        try? FileManager.default.removeItem(at: url)
    }

    /// Encrypt and write arbitrary data to a named file in the same directory.
    /// Used by ChatManager to persist the offline pending queue.
    public func saveEncryptedBlob(_ data: Data, fileName: String) throws {
        let url       = baseURL.appendingPathComponent("\(fileName).enc")
        let encrypted = try encrypt(data)
        try encrypted.write(to: url, options: .atomic)
    }

    /// Load and decrypt an arbitrary blob previously saved with saveEncryptedBlob.
    /// Returns nil if the file does not exist.
    public func loadEncryptedBlob(fileName: String) -> Data? {
        let url = baseURL.appendingPathComponent("\(fileName).enc")
        guard FileManager.default.fileExists(atPath: url.path),
              let encrypted = try? Data(contentsOf: url),
              let plain     = try? decrypt(encrypted) else { return nil }
        return plain
    }

    /// Wipe ALL stored messages.
    public func wipeAll() throws {
        cache.removeAll()
        let files = try FileManager.default.contentsOfDirectory(at: baseURL, includingPropertiesForKeys: nil)
        for file in files {
            try FileManager.default.removeItem(at: file)
        }
    }

    // MARK: - Private: Disk I/O with encryption

    private func loadFromDisk(peerID: String) throws -> [StoredMessage] {
        let url = fileURL(for: peerID)
        guard FileManager.default.fileExists(atPath: url.path) else {
            return []
        }
        let encryptedData = try Data(contentsOf: url)
        let plaintext     = try decrypt(encryptedData)
        return try JSONDecoder().decode([StoredMessage].self, from: plaintext)
    }

    private func saveToDisk(messages: [StoredMessage], peerID: String) throws {
        let plaintext     = try JSONEncoder().encode(messages)
        let encryptedData = try encrypt(plaintext)
        let url           = fileURL(for: peerID)
        try encryptedData.write(to: url, options: .atomic)
    }

    // MARK: - Private: Encryption helpers

    /// AES-256-GCM encrypt with the master storage key.
    /// Output format: 12-byte nonce || ciphertext || 16-byte tag (combined)
    private func encrypt(_ plaintext: Data) throws -> Data {
        let sealed = try AES.GCM.seal(plaintext, using: storageKey)
        guard let combined = sealed.combined else {
            throw SophaxError.encryptionFailed("AES-GCM combined output unavailable")
        }
        return combined
    }

    /// AES-256-GCM decrypt with the master storage key.
    private func decrypt(_ data: Data) throws -> Data {
        do {
            let sealedBox = try AES.GCM.SealedBox(combined: data)
            return try AES.GCM.open(sealedBox, using: storageKey)
        } catch {
            throw SophaxError.decryptionFailed
        }
    }

    // MARK: - Private: File URL

    private func fileURL(for peerID: String) -> URL {
        // Allow alphanumeric, hyphens, and dots (for "group." prefix)
        let safeID = peerID.filter { $0.isLetter || $0.isNumber || $0 == "-" || $0 == "." }
        return baseURL.appendingPathComponent("\(safeID).enc")
    }
}
