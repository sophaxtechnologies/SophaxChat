// AppState.swift
// SophaxChat
//
// Observable app state and ChatManager lifecycle.
// Created once and injected via @EnvironmentObject.

import SwiftUI
import UIKit
import AVFoundation
import LocalAuthentication
import UserNotifications
import SophaxChatCore

@MainActor
final class AppState: ObservableObject {

    // MARK: - Published state

    @Published var isSetupComplete: Bool = false
    @Published var isBlurred: Bool       = false
    @Published var isAppLocked: Bool     = false
    @Published var peers:        [KnownPeer] = []
    @Published var messages:     [String: [StoredMessage]] = [:]  // peerID → messages
    @Published var onlinePeers:  Set<String> = []
    @Published var blockedPeers: Set<String> = []
    @Published var unreadCounts: [String: Int] = [:]
    @Published var typingPeers:  Set<String> = []
    @Published var peerAliases:  [String: String] = [:]
    @Published var errorMessage: String? = nil
    @Published var groups:       [GroupInfo] = []

    /// Username cache for blocked peers (persisted so they're still readable after restart).
    private(set) var blockedPeerNames: [String: String] = [:]
    private var typingTimeouts: [String: Task<Void, Never>] = [:]

    // MARK: - Core

    private(set) var chatManager: ChatManager?
    private let keychain = KeychainManager()

    // MARK: - Init

    init() {
        loadSavedPeers()
        loadBlockedPeers()
        loadAliases()
        loadGroups()
        if keychain.hasIdentity() {
            setupChatManager(username: nil)
        }
    }

    // MARK: - Setup

    func createIdentity(username: String) {
        setupChatManager(username: username)
    }

    private func setupChatManager(username: String?) {
        do {
            let identity     = try IdentityManager(keychain: keychain)
            if let username {
                try identity.setUsername(username)
            }
            let preKeys      = try PreKeyManager(identity: identity, keychain: keychain)
            let mesh         = MeshManager(localIdentityHash: identity.publicIdentity.peerID)
            let store        = try MessageStore(keychain: keychain)
            let attachStore  = try AttachmentStore(keychain: keychain)

            let manager = ChatManager(
                identity:        identity,
                preKeys:         preKeys,
                mesh:            mesh,
                messageStore:    store,
                attachmentStore: attachStore,
                keychain:        keychain
            )
            manager.delegate = self
            manager.start()

            self.chatManager     = manager
            self.isSetupComplete = true
            requestNotificationPermission()

            loadExistingMessages(from: store)
        } catch {
            self.errorMessage = error.localizedDescription
        }
    }

    // MARK: - Message sending

    func sendMessage(_ text: String, toPeerID peerID: String, expiresAt: Date? = nil, replyToID: String? = nil) {
        chatManager?.sendMessage(text, toPeerID: peerID, expiresAt: expiresAt, replyToID: replyToID)
    }

    func sendTypingIndicator(toPeerID peerID: String, isTyping: Bool) {
        chatManager?.sendTypingIndicator(toPeerID: peerID, isTyping: isTyping)
    }

    func sendReaction(emoji: String?, messageID: String, peerID: String) {
        chatManager?.sendReaction(emoji: emoji, toMessageID: messageID, toPeerID: peerID)
    }

    // MARK: - Group messaging

    func createGroup(name: String, memberPeerIDs: [String]) {
        chatManager?.createGroup(name: name, memberPeerIDs: memberPeerIDs)
    }

    func sendGroupMessage(_ text: String, group: GroupInfo) {
        chatManager?.sendGroupMessage(text, groupID: group.id, members: group.memberIDs)
    }

    func groupMessages(for group: GroupInfo) -> [StoredMessage] {
        messages[group.conversationID] ?? []
    }

    func markGroupAsRead(group: GroupInfo) {
        unreadCounts[group.conversationID] = 0
    }

    func displayName(forPeerID peerID: String) -> String {
        if let peer = peers.first(where: { $0.id == peerID }) {
            return displayName(for: peer)
        }
        return String(peerID.prefix(8)) + "…"
    }

    private let groupsDefaultsKey = "com.sophax.groups"

    private func loadGroups() {
        guard let data  = UserDefaults.standard.data(forKey: groupsDefaultsKey),
              let saved = try? JSONDecoder().decode([GroupInfo].self, from: data) else { return }
        groups = saved
        // Group messages are loaded later in loadExistingMessages(from:) once the store is ready
    }

    private func saveGroups() {
        if let data = try? JSONEncoder().encode(groups) {
            UserDefaults.standard.set(data, forKey: groupsDefaultsKey)
        }
    }

    /// Compress `image` to JPEG under 400 KB and send as an encrypted attachment.
    func sendImage(_ image: UIImage, toPeerID peerID: String, expiresAt: Date? = nil) {
        var quality: CGFloat = 0.75
        var jpegData: Data? = image.jpegData(compressionQuality: quality)
        while let d = jpegData, d.count > 400_000, quality > 0.1 {
            quality -= 0.1
            jpegData = image.jpegData(compressionQuality: quality)
        }
        guard let data = jpegData else { return }
        chatManager?.sendAttachment(data, mimeType: "image/jpeg", toPeerID: peerID, expiresAt: expiresAt)
    }

    /// Send a recorded M4A audio clip as an encrypted attachment.
    func sendAudio(_ data: Data, duration: Double, toPeerID peerID: String, expiresAt: Date? = nil) {
        chatManager?.sendAttachment(
            data, mimeType: "audio/m4a", audioDuration: duration,
            toPeerID: peerID, expiresAt: expiresAt
        )
    }

    /// Load attachment data from the local encrypted store (used by bubble views).
    func loadAttachment(id: String) -> Data? {
        try? chatManager?.attachmentStore.load(id: id)
    }

    // MARK: - Conversation management

    func deleteConversation(peerID: String) {
        try? chatManager?.messageStore.deleteConversation(peerID: peerID)
        messages.removeValue(forKey: peerID)
        unreadCounts.removeValue(forKey: peerID)
    }

    func deleteMessage(_ message: StoredMessage) {
        try? chatManager?.messageStore.deleteMessage(id: message.id, peerID: message.peerID)
        messages[message.peerID]?.removeAll { $0.id == message.id }
    }

    // MARK: - Blocking

    func blockPeer(peerID: String) {
        if let peer = peers.first(where: { $0.id == peerID }) {
            blockedPeerNames[peerID] = peer.username
        }
        blockedPeers.insert(peerID)
        saveBlockedPeers()
        // Remove from active peers list — they'll reappear if unblocked and online
        peers.removeAll { $0.id == peerID }
        messages.removeValue(forKey: peerID)
        unreadCounts.removeValue(forKey: peerID)
        savePeers()
    }

    func unblockPeer(peerID: String) {
        blockedPeers.remove(peerID)
        blockedPeerNames.removeValue(forKey: peerID)
        saveBlockedPeers()
    }

    func isBlocked(_ peerID: String) -> Bool {
        blockedPeers.contains(peerID)
    }

    // MARK: - Unread counts

    func markAsRead(peerID: String) {
        unreadCounts[peerID] = 0
        // Clear any delivered notifications for this conversation
        let ids = messages[peerID]?.map(\.id) ?? []
        UNUserNotificationCenter.current().removePendingNotificationRequests(withIdentifiers: ids)
        UNUserNotificationCenter.current().removeDeliveredNotifications(withIdentifiers: ids)
        // Send read receipts for received messages still showing as .delivered
        let unread = messages[peerID]?.filter { $0.direction == .received && $0.status == .delivered } ?? []
        if !unread.isEmpty {
            chatManager?.sendReadReceipts(messageIDs: unread.map(\.id), toPeerID: peerID)
        }
    }

    // MARK: - Forward message

    /// Re-sends a stored message (text or attachment) to a different peer.
    func forwardMessage(_ message: StoredMessage, toPeerID peerID: String, expiresAt: Date? = nil) {
        if let id   = message.attachmentID,
           let mime = message.attachmentMimeType,
           let data = loadAttachment(id: id) {
            chatManager?.sendAttachment(data, mimeType: mime, caption: message.body,
                                        audioDuration: message.audioDuration,
                                        toPeerID: peerID, expiresAt: expiresAt)
        } else if !message.body.isEmpty {
            chatManager?.sendMessage(message.body, toPeerID: peerID, expiresAt: expiresAt)
        }
    }

    // MARK: - Notifications

    private func requestNotificationPermission() {
        UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound, .badge]) { _, _ in }
    }

    private func scheduleNotification(for message: StoredMessage, fromPeer peerID: String) {
        let content  = UNMutableNotificationContent()
        let peerName = peers.first(where: { $0.id == peerID }).map { displayName(for: $0) } ?? "New message"
        content.title           = peerName
        content.body            = message.body
        content.sound           = .default
        content.threadIdentifier = peerID           // group notifications by conversation
        content.categoryIdentifier = "SOPHAX_MSG"
        let request = UNNotificationRequest(identifier: message.id, content: content, trigger: nil)
        UNUserNotificationCenter.current().add(request)
    }

    // MARK: - Contact aliases

    func displayName(for peer: KnownPeer) -> String {
        peerAliases[peer.id] ?? peer.username
    }

    func setAlias(_ alias: String?, for peerID: String) {
        let trimmed = alias?.trimmingCharacters(in: .whitespacesAndNewlines)
        if let name = trimmed, !name.isEmpty {
            peerAliases[peerID] = name
        } else {
            peerAliases.removeValue(forKey: peerID)
        }
        saveAliases()
    }

    // MARK: - App lock

    var appLockEnabled: Bool {
        get { UserDefaults.standard.bool(forKey: "com.sophax.appLockEnabled") }
        set { UserDefaults.standard.set(newValue, forKey: "com.sophax.appLockEnabled") }
    }

    func lockApp() {
        guard appLockEnabled else { return }
        isAppLocked = true
    }

    func tryUnlock() {
        let ctx = LAContext()
        var error: NSError?
        guard ctx.canEvaluatePolicy(.deviceOwnerAuthentication, error: &error) else {
            isAppLocked = false   // No biometrics + no passcode configured — just unlock
            return
        }
        ctx.evaluatePolicy(.deviceOwnerAuthentication,
                           localizedReason: "Unlock SophaxChat") { success, _ in
            DispatchQueue.main.async { [weak self] in
                if success { self?.isAppLocked = false }
            }
        }
    }

    // MARK: - Private helpers

    private func loadExistingMessages(from store: MessageStore) {
        let peerIDs = store.allConversationPeerIDs()
        for peerID in peerIDs {
            guard !blockedPeers.contains(peerID) else { continue }
            if let msgs = try? store.messages(forPeer: peerID) {
                messages[peerID] = msgs
            }
        }
        // Also load group conversations
        for group in groups {
            if let msgs = try? store.messages(forPeer: group.conversationID) {
                messages[group.conversationID] = msgs
            }
        }
    }

    private func appendMessage(_ message: StoredMessage) {
        var existing = messages[message.peerID] ?? []
        guard !existing.contains(where: { $0.id == message.id }) else { return }
        existing.append(message)
        existing.sort { $0.timestamp < $1.timestamp }
        messages[message.peerID] = existing
    }

    // MARK: - Peer persistence

    private let peersDefaultsKey = "com.sophax.knownPeers"

    private func loadSavedPeers() {
        guard let data = UserDefaults.standard.data(forKey: peersDefaultsKey),
              let saved = try? JSONDecoder().decode([KnownPeer].self, from: data) else { return }
        peers = saved.map { peer in
            var p = peer
            p.isOnline = false
            p.isDirectlyConnected = false
            return p
        }
    }

    private func savePeers() {
        if let data = try? JSONEncoder().encode(peers) {
            UserDefaults.standard.set(data, forKey: peersDefaultsKey)
        }
    }

    // MARK: - Alias persistence

    private let aliasesKey = "com.sophax.peerAliases"

    private func loadAliases() {
        guard let data = UserDefaults.standard.data(forKey: aliasesKey),
              let saved = try? JSONDecoder().decode([String: String].self, from: data) else { return }
        peerAliases = saved
    }

    private func saveAliases() {
        if let data = try? JSONEncoder().encode(peerAliases) {
            UserDefaults.standard.set(data, forKey: aliasesKey)
        }
    }

    // MARK: - Blocked peers persistence

    private let blockedDefaultsKey = "com.sophax.blockedPeers"
    private let blockedNamesKey    = "com.sophax.blockedPeerNames"

    private func loadBlockedPeers() {
        let saved = UserDefaults.standard.stringArray(forKey: blockedDefaultsKey) ?? []
        blockedPeers = Set(saved)
        if let data  = UserDefaults.standard.data(forKey: blockedNamesKey),
           let names = try? JSONDecoder().decode([String: String].self, from: data) {
            blockedPeerNames = names
        }
    }

    private func saveBlockedPeers() {
        UserDefaults.standard.set(Array(blockedPeers), forKey: blockedDefaultsKey)
        if let data = try? JSONEncoder().encode(blockedPeerNames) {
            UserDefaults.standard.set(data, forKey: blockedNamesKey)
        }
    }
}

// MARK: - ChatManagerDelegate

extension AppState: ChatManagerDelegate {

    func chatManager(_ manager: ChatManager, didDiscoverPeer peer: KnownPeer) {
        guard !blockedPeers.contains(peer.id) else { return }
        if let idx = peers.firstIndex(where: { $0.id == peer.id }) {
            peers[idx].isOnline = true
        } else {
            peers.append(peer)
            savePeers()
        }
        onlinePeers.insert(peer.id)
    }

    func chatManager(_ manager: ChatManager, peerDidDisconnect peerID: String) {
        onlinePeers.remove(peerID)
        if let idx = peers.firstIndex(where: { $0.id == peerID }) {
            peers[idx].isOnline = false
        }
    }

    func chatManager(_ manager: ChatManager, didSendMessage message: StoredMessage, toPeer peerID: String) {
        appendMessage(message)
    }

    func chatManager(_ manager: ChatManager, didReceiveMessage message: StoredMessage, fromPeer peerID: String) {
        guard !blockedPeers.contains(peerID) else { return }
        appendMessage(message)
        unreadCounts[peerID, default: 0] += 1
        UIImpactFeedbackGenerator(style: .soft).impactOccurred()
        // Post a local notification when the app is not in the foreground
        let appState = UIApplication.shared.applicationState
        if appState == .background || appState == .inactive {
            scheduleNotification(for: message, fromPeer: peerID)
        }
    }

    func chatManager(_ manager: ChatManager, messageDelivered messageID: String, toPeer peerID: String) {
        if let idx = messages[peerID]?.firstIndex(where: { $0.id == messageID }) {
            messages[peerID]?[idx].status = .delivered
        }
    }

    func chatManager(_ manager: ChatManager, messagesRead messageIDs: [String], byPeer peerID: String) {
        for messageID in messageIDs {
            if let idx = messages[peerID]?.firstIndex(where: { $0.id == messageID }) {
                messages[peerID]?[idx].status = .read
            }
        }
    }

    func chatManager(_ manager: ChatManager, didUpdateReactions reactions: [String: String], onMessageID messageID: String, peerID: String) {
        if let idx = messages[peerID]?.firstIndex(where: { $0.id == messageID }) {
            messages[peerID]?[idx].reactions = reactions.isEmpty ? nil : reactions
        }
    }

    func chatManager(_ manager: ChatManager, peerDidUpdateTyping peerID: String, isTyping: Bool) {
        guard !blockedPeers.contains(peerID) else { return }
        typingTimeouts[peerID]?.cancel()
        if isTyping {
            typingPeers.insert(peerID)
            // Auto-clear after 8 seconds in case the stop signal is lost
            typingTimeouts[peerID] = Task { @MainActor [weak self] in
                try? await Task.sleep(for: .seconds(8))
                self?.typingPeers.remove(peerID)
                self?.typingTimeouts.removeValue(forKey: peerID)
            }
        } else {
            typingPeers.remove(peerID)
            typingTimeouts.removeValue(forKey: peerID)
        }
    }

    func chatManager(_ manager: ChatManager, didJoinGroup group: GroupInfo) {
        if !groups.contains(where: { $0.id == group.id }) {
            groups.append(group)
            saveGroups()
        }
    }

    func chatManager(_ manager: ChatManager, didReceiveGroupMessage message: StoredMessage, inGroup groupID: String) {
        appendMessage(message)
        let convID = "group.\(groupID)"
        unreadCounts[convID, default: 0] += message.direction == .received ? 1 : 0
        if message.direction == .received {
            UIImpactFeedbackGenerator(style: .soft).impactOccurred()
        }
    }

    func chatManager(_ manager: ChatManager, didEncounterError error: Error) {
        if case SophaxError.decryptionFailed = error { return }
        errorMessage = error.localizedDescription
        Task { @MainActor in
            try? await Task.sleep(for: .seconds(4))
            if errorMessage == error.localizedDescription {
                errorMessage = nil
            }
        }
    }
}
