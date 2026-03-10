// AppState.swift
// SophaxChat
//
// Observable app state and ChatManager lifecycle.
// Created once and injected via @EnvironmentObject.

import SwiftUI
import SophaxChatCore

@MainActor
final class AppState: ObservableObject {

    // MARK: - Published state

    @Published var isSetupComplete: Bool = false
    @Published var isBlurred: Bool       = false
    @Published var peers:        [KnownPeer] = []
    @Published var messages:     [String: [StoredMessage]] = [:]  // peerID → messages
    @Published var onlinePeers:  Set<String> = []
    @Published var blockedPeers: Set<String> = []
    @Published var unreadCounts: [String: Int] = [:]
    @Published var errorMessage: String? = nil

    // MARK: - Core

    private(set) var chatManager: ChatManager?
    private let keychain = KeychainManager()

    // MARK: - Init

    init() {
        loadSavedPeers()
        loadBlockedPeers()
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
            let identity = try IdentityManager(keychain: keychain)
            if let username {
                try identity.setUsername(username)
            }
            let preKeys  = try PreKeyManager(identity: identity, keychain: keychain)
            let mesh     = MeshManager(localIdentityHash: identity.publicIdentity.peerID)
            let store    = try MessageStore(keychain: keychain)

            let manager = ChatManager(
                identity:     identity,
                preKeys:      preKeys,
                mesh:         mesh,
                messageStore: store,
                keychain:     keychain
            )
            manager.delegate = self
            manager.start()

            self.chatManager    = manager
            self.isSetupComplete = true

            loadExistingMessages(from: store)
        } catch {
            self.errorMessage = error.localizedDescription
        }
    }

    // MARK: - Message sending

    func sendMessage(_ text: String, toPeerID peerID: String, expiresAt: Date? = nil) {
        chatManager?.sendMessage(text, toPeerID: peerID, expiresAt: expiresAt)
    }

    // MARK: - Conversation management

    func deleteConversation(peerID: String) {
        try? chatManager?.messageStore.deleteConversation(peerID: peerID)
        messages.removeValue(forKey: peerID)
        unreadCounts.removeValue(forKey: peerID)
    }

    // MARK: - Blocking

    func blockPeer(peerID: String) {
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
        saveBlockedPeers()
    }

    func isBlocked(_ peerID: String) -> Bool {
        blockedPeers.contains(peerID)
    }

    // MARK: - Unread counts

    func markAsRead(peerID: String) {
        unreadCounts[peerID] = 0
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

    // MARK: - Blocked peers persistence

    private let blockedDefaultsKey = "com.sophax.blockedPeers"

    private func loadBlockedPeers() {
        let saved = UserDefaults.standard.stringArray(forKey: blockedDefaultsKey) ?? []
        blockedPeers = Set(saved)
    }

    private func saveBlockedPeers() {
        UserDefaults.standard.set(Array(blockedPeers), forKey: blockedDefaultsKey)
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
    }

    func chatManager(_ manager: ChatManager, messageDelivered messageID: String, toPeer peerID: String) {
        if let idx = messages[peerID]?.firstIndex(where: { $0.id == messageID }) {
            messages[peerID]?[idx].status = .delivered
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
