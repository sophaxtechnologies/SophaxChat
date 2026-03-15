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
    /// Groups announced by nearby peers that the local user is NOT a member of.
    /// Keyed by groupID; stale entries (>5 min old) are replaced on each announcement.
    @Published var discoveredChannels: [String: ChannelAnnouncement] = [:]

    /// Safety Number pinning: peerID → safety number at time of verification.
    /// Nil entry = never verified. Different value = key changed warning.
    @Published var verifiedPeers: [String: String] = [:]

    /// peerID → true when their session was established without a one-time prekey (reduced entropy).
    @Published var noOPKSessions: Set<String> = []

    // MARK: - TCP / internet mode

    /// Whether the TCP internet transport is active.
    @Published var tcpEnabled: Bool = false {
        didSet { applyTCPConfig(); UserDefaults.standard.set(tcpEnabled, forKey: tcpEnabledKey) }
    }
    /// Local listen port (default 25519).
    @Published var tcpPort: String = "25519" {
        didSet { applyTCPConfig(); UserDefaults.standard.set(tcpPort, forKey: tcpPortKey) }
    }
    /// Optional SOCKS5 proxy for Tor ("host:port", e.g. "127.0.0.1:9050").
    @Published var tcpSocksProxy: String = "" {
        didSet { applyTCPConfig(); UserDefaults.standard.set(tcpSocksProxy, forKey: tcpSocksProxyKey) }
    }
    /// User-entered public address ("IP:port") included in Hello so peers learn our internet address.
    @Published var myTCPAddress: String = "" {
        didSet {
            chatManager?.myTCPAddress = myTCPAddress.isEmpty ? nil : myTCPAddress
            UserDefaults.standard.set(myTCPAddress, forKey: tcpAddressKey)
        }
    }

    private let tcpEnabledKey    = "com.sophax.tcp.enabled"
    private let tcpPortKey       = "com.sophax.tcp.port"
    private let tcpSocksProxyKey = "com.sophax.tcp.socksProxy"
    private let tcpAddressKey    = "com.sophax.tcp.address"

    /// Set to a peer that just came back online; triggers reconnect banner in UI.
    @Published var reconnectedPeer: KnownPeer? = nil

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
        loadVerifiedPeers()
        loadTCPSettings()
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
            manager.delegate      = self
            manager.myTCPAddress  = myTCPAddress.isEmpty ? nil : myTCPAddress
            manager.start()
            if tcpEnabled { startTCPTransport(on: manager) }

            self.chatManager     = manager
            self.isSetupComplete = true
            requestNotificationPermission()

            loadExistingMessages(from: store)
        } catch {
            self.errorMessage = error.localizedDescription
        }
    }

    // MARK: - Background operation

    /// Called by the BGAppRefreshTask when iOS re-wakes the app after suspension.
    /// Restarts the mesh briefly so any store-and-forward deliveries can complete
    /// and outbound pending queues can be drained if peers are in range.
    @MainActor
    func handleBackgroundMeshRefresh() async {
        // If setup is not complete (first launch) there's nothing to do.
        guard isSetupComplete, let manager = chatManager else { return }

        // Restart the mesh if it isn't already running
        manager.start()

        // Give MPC ~10 seconds to connect to any nearby peer and drain queues,
        // then stop to avoid draining the battery further.
        try? await Task.sleep(for: .seconds(10))
        manager.stop()
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
        guard let group = chatManager?.createGroup(name: name, memberPeerIDs: memberPeerIDs) else { return }
        chatManager?.broadcastChannelAnnouncement(for: group)
    }

    func sendGroupMessage(_ text: String, group: GroupInfo, expiresAt: Date? = nil, replyToID: String? = nil) {
        chatManager?.sendGroupMessage(text, groupID: group.id, members: group.memberIDs,
                                      expiresAt: expiresAt, replyToID: replyToID)
    }

    func sendGroupReaction(emoji: String?, messageID: String, group: GroupInfo) {
        chatManager?.sendGroupReaction(emoji: emoji, toMessageID: messageID,
                                       groupID: group.id, members: group.memberIDs)
    }

    func sendGroupImage(_ image: UIImage, group: GroupInfo, expiresAt: Date? = nil, replyToID: String? = nil) {
        var quality: CGFloat = 0.75
        var jpegData: Data? = image.jpegData(compressionQuality: quality)
        while let d = jpegData, d.count > 400_000, quality > 0.1 {
            quality -= 0.1
            jpegData = image.jpegData(compressionQuality: quality)
        }
        guard let data = jpegData else { return }
        chatManager?.sendGroupAttachment(data, mimeType: "image/jpeg",
                                         groupID: group.id, members: group.memberIDs,
                                         expiresAt: expiresAt, replyToID: replyToID)
    }

    func sendGroupAudio(_ data: Data, duration: Double, group: GroupInfo, expiresAt: Date? = nil, replyToID: String? = nil) {
        chatManager?.sendGroupAttachment(data, mimeType: "audio/m4a",
                                         audioDuration: duration,
                                         groupID: group.id, members: group.memberIDs,
                                         expiresAt: expiresAt, replyToID: replyToID)
    }

    // MARK: - Username change

    func changeUsername(_ newUsername: String) {
        let trimmed = newUsername.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, trimmed.count <= 64 else { return }
        guard let identity = chatManager?.identity else { return }
        try? identity.setUsername(trimmed)
        chatManager?.broadcastHello()
    }

    func leaveGroup(_ group: GroupInfo) {
        chatManager?.leaveGroup(group)
        groups.removeAll { $0.id == group.id }
        saveGroups()
        messages.removeValue(forKey: group.conversationID)
        unreadCounts.removeValue(forKey: group.conversationID)
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
        // Register category with a placeholder so the message body is hidden
        // when the user has "Show Previews: When Unlocked" or "Never" set in system Settings.
        let category = UNNotificationCategory(
            identifier: "SOPHAX_MSG",
            actions: [],
            intentIdentifiers: [],
            hiddenPreviewsBodyPlaceholder: NSLocalizedString("New message", comment: ""),
            options: []
        )
        UNUserNotificationCenter.current().setNotificationCategories([category])
        UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound, .badge]) { _, _ in }
    }

    private func scheduleNotification(for message: StoredMessage, fromPeer peerID: String) {
        let content  = UNMutableNotificationContent()
        let peerName = peers.first(where: { $0.id == peerID }).map { displayName(for: $0) } ?? "New message"
        content.title              = peerName
        content.body               = message.body
        content.sound              = .default
        content.threadIdentifier   = peerID
        content.categoryIdentifier = "SOPHAX_MSG"
        let request = UNNotificationRequest(identifier: message.id, content: content, trigger: nil)
        UNUserNotificationCenter.current().add(request)
    }

    private func scheduleGroupNotification(for message: StoredMessage, groupID: String) {
        guard let group = groups.first(where: { $0.id == groupID }) else { return }
        let senderName = message.senderID.flatMap { sid in
            peers.first(where: { $0.id == sid }).map { displayName(for: $0) }
        } ?? "Someone"
        let content  = UNMutableNotificationContent()
        content.title              = group.name
        content.subtitle           = senderName
        content.body               = message.body
        content.sound              = .default
        content.threadIdentifier   = group.conversationID
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

    // MARK: - Safety Number pinning

    /// Mark a peer's safety number as verified (called after successful QR or manual comparison).
    func markPeerVerified(_ peerID: String, safetyNumber: String) {
        verifiedPeers[peerID] = safetyNumber
        saveVerifiedPeers()
    }

    /// Returns true if this peer has been verified and their safety number hasn't changed.
    func isVerified(_ peerID: String, currentSafetyNumber: String) -> Bool {
        verifiedPeers[peerID] == currentSafetyNumber
    }

    /// Returns true if a peer was previously verified but their safety number has since changed.
    func hasKeyChanged(for peerID: String, currentSafetyNumber: String) -> Bool {
        guard let pinned = verifiedPeers[peerID] else { return false }
        return pinned != currentSafetyNumber
    }

    // MARK: - TCP internet mode

    /// Initiate an outbound TCP connection to a peer at "host:port" or "host.onion:port".
    /// Returns an error message string on failure, nil on success.
    @discardableResult
    func connectViaTCP(address: String) -> String? {
        guard Self.isValidTCPAddress(address) else {
            return "Invalid address. Use host:port format, e.g. 192.168.1.1:25519 or xyz.onion:25519"
        }
        do {
            try chatManager?.connectViaTCP(address: address)
            return nil
        } catch {
            return error.localizedDescription
        }
    }

    /// Validates "host:port" format. Splits on the last colon to support .onion and IPv4.
    static func isValidTCPAddress(_ address: String) -> Bool {
        guard let colonIdx = address.lastIndex(of: ":") else { return false }
        let host = String(address[..<colonIdx])
        let portStr = String(address[address.index(after: colonIdx)...])
        guard !host.isEmpty, let port = UInt16(portStr), port > 0 else { return false }
        return true
    }

    /// Called on `didBecomeActive` — reconnect to all known peers that have a TCP address.
    /// No-op if TCP is disabled or no peers have an address.
    /// Decentralized: connects directly peer-to-peer, no server involved.
    func reconnectTCPPeers() {
        guard tcpEnabled, let tcp = chatManager?.tcpTransport else { return }
        for peer in peers {
            guard let addr = peer.tcpAddress, !tcp.isConnected(peerID: peer.id) else { continue }
            try? chatManager?.connectViaTCP(address: addr)
        }
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
        // Sort by receivedAt (local wall-clock) when available; fall back to sender timestamp.
        // This prevents a clock-skewed or malicious sender from reordering our conversation view.
        existing.sort {
            ($0.receivedAt ?? $0.timestamp) < ($1.receivedAt ?? $1.timestamp)
        }
        messages[message.peerID] = existing
    }

    // MARK: - TCP persistence + lifecycle

    private func loadTCPSettings() {
        let ud = UserDefaults.standard
        tcpEnabled    = ud.bool(forKey: tcpEnabledKey)
        tcpPort       = ud.string(forKey: tcpPortKey)       ?? "25519"
        tcpSocksProxy = ud.string(forKey: tcpSocksProxyKey) ?? ""
        myTCPAddress  = ud.string(forKey: tcpAddressKey)    ?? ""
    }

    private func makeTCPConfig() -> TCPTransport.Config {
        let port  = UInt16(tcpPort) ?? 25519
        let proxy = tcpSocksProxy.trimmingCharacters(in: .whitespaces)
        return TCPTransport.Config(port: port, socksProxy: proxy.isEmpty ? nil : proxy)
    }

    private func startTCPTransport(on manager: ChatManager) {
        let transport = TCPTransport(config: makeTCPConfig())
        manager.startTCP(transport)
    }

    private func applyTCPConfig() {
        guard let manager = chatManager else { return }
        if tcpEnabled {
            startTCPTransport(on: manager)
        } else {
            manager.stopTCP()
        }
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

    // MARK: - Keychain helpers

    /// Executes a Keychain save, logging failures in debug builds.
    /// Silent discard is intentional in release — Keychain errors are transient
    /// (locked device, quota) and must not crash the app or block the call site.
    @inline(__always)
    private func keychainSave(_ label: String, _ operation: () throws -> Void) {
        do {
            try operation()
        } catch {
            #if DEBUG
            print("[SophaxChat] ⚠️ Keychain save failed (\(label)): \(error)")
            #endif
        }
    }

    // MARK: - Verified peers persistence

    private func loadVerifiedPeers() {
        // Primary: Keychain (device-local, excluded from iCloud backup)
        let fromKeychain = keychain.loadVerifiedPeers()
        if !fromKeychain.isEmpty {
            verifiedPeers = fromKeychain
            return
        }
        // One-time migration from UserDefaults → Keychain
        let legacyKey = "com.sophax.verifiedPeers"
        if let data  = UserDefaults.standard.data(forKey: legacyKey),
           let saved = try? JSONDecoder().decode([String: String].self, from: data),
           !saved.isEmpty {
            verifiedPeers = saved
            keychainSave("verifiedPeers:migration") { try keychain.saveVerifiedPeers(saved) }
            UserDefaults.standard.removeObject(forKey: legacyKey)
        }
    }

    private func saveVerifiedPeers() {
        keychainSave("verifiedPeers") { try keychain.saveVerifiedPeers(verifiedPeers) }
    }
}

// MARK: - ChatManagerDelegate

extension AppState: @preconcurrency ChatManagerDelegate {

    func chatManager(_ manager: ChatManager, didDiscoverPeer peer: KnownPeer) {
        guard !blockedPeers.contains(peer.id) else { return }
        if let idx = peers.firstIndex(where: { $0.id == peer.id }) {
            let existing = peers[idx]
            // TOFU key-change detection: if the signing key is different from what we knew,
            // inject the old safety number into verifiedPeers so hasKeyChanged() fires in the UI.
            if existing.signingKeyPublic != peer.signingKeyPublic {
                if verifiedPeers[peer.id] == nil {
                    verifiedPeers[peer.id] = existing.safetyNumber
                    saveVerifiedPeers()
                }
                // Replace the stored peer with the new key data
                peers[idx] = peer
                savePeers()
            } else {
                peers[idx].isOnline = true
            }
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

    func chatManager(_ manager: ChatManager, sessionEstablishedWithPeer peerID: String, usedOPK: Bool) {
        if !usedOPK {
            noOPKSessions.insert(peerID)
        }
    }

    func chatManager(_ manager: ChatManager, peerDidReconnect peer: KnownPeer) {
        reconnectedPeer = peer
        // Auto-clear after 4 seconds
        Task { @MainActor [weak self] in
            try? await Task.sleep(for: .seconds(4))
            if self?.reconnectedPeer?.id == peer.id {
                self?.reconnectedPeer = nil
            }
        }
    }

    func chatManager(_ manager: ChatManager, didUpdateGroupReactions reactions: [String: String],
                     onMessageID messageID: String, groupID: String) {
        let convID = "group.\(groupID)"
        if let idx = messages[convID]?.firstIndex(where: { $0.id == messageID }) {
            messages[convID]?[idx].reactions = reactions.isEmpty ? nil : reactions
        }
    }

    func chatManager(_ manager: ChatManager, peer leavingPeerID: String,
                     leftGroupID groupID: String, remainingMemberIDs: [String]) {
        guard let idx = groups.firstIndex(where: { $0.id == groupID }) else { return }
        let old = groups[idx]
        groups[idx] = GroupInfo(
            id:        old.id,
            name:      old.name,
            memberIDs: remainingMemberIDs,
            creatorID: old.creatorID
        )
        saveGroups()
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
            let appStatus = UIApplication.shared.applicationState
            if appStatus == .background || appStatus == .inactive {
                scheduleGroupNotification(for: message, groupID: groupID)
            }
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

    func chatManager(_ manager: ChatManager, didDiscoverChannel announcement: ChannelAnnouncement) {
        // Only show groups the local user is not already a member of
        let myID = manager.identity.publicIdentity.peerID
        let alreadyMember = groups.contains { $0.id == announcement.groupID }
        guard !alreadyMember, announcement.creatorID != myID else { return }
        discoveredChannels[announcement.groupID] = announcement
    }

    func chatManager(_ manager: ChatManager, groupMessageDelivered messageID: String,
                     inGroup groupID: String, byPeer peerID: String) {
        let convID = "group.\(groupID)"
        guard var msgs = messages[convID],
              let idx  = msgs.firstIndex(where: { $0.id == messageID }) else { return }
        var set = msgs[idx].deliveredBy ?? []
        guard !set.contains(peerID) else { return }
        set.append(peerID)
        msgs[idx].deliveredBy = set
        messages[convID] = msgs
    }
}
