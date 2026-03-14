// ChatManager.swift
// SophaxChatCore
//
// High-level coordinator — the single entry point for the app layer.
//
// Session lifecycle:
//   1. Peer connects (MPC) → Hello exchanged immediately → PreKeyBundle stored
//   2. First sendMessage → X3DH sender-side → .initiateSession wire message
//   3. Subsequent messages → .message wire message (Double Ratchet)
//   4. Relay: peer not directly connected → wrap in RelayEnvelope, broadcast
//   5. Offline: no connected peers → queue message, drain on next connect/hello
//
// Threading:
//   All MeshManagerDelegate callbacks are dispatched through an internal
//   DispatchQueue by MeshManager, then delegate calls are re-dispatched to
//   main. ChatManager is @unchecked Sendable — the caller must not call
//   public methods concurrently from different threads.

import Foundation
import CryptoKit

// MARK: - Sealed sender helpers (file-private)

private func sealWireMessage(_ wire: WireMessage, recipientDHPublicKey: Data) throws -> SealedMessage {
    // Generate ephemeral key pair
    let ephPair   = DHKeyPair()
    let recipKey  = try Curve25519.KeyAgreement.PublicKey(rawRepresentation: recipientDHPublicKey)
    let shared    = try ephPair.privateKey.sharedSecretFromKeyAgreement(with: recipKey)

    // Derive sealing key
    var ikmData = Data()
    shared.withUnsafeBytes { ikmData.append(contentsOf: $0) }
    let sealingKey = HKDF<SHA256>.deriveKey(
        inputKeyMaterial: SymmetricKey(data: ikmData),
        info: CryptoConstants.sealedSenderInfo,
        outputByteCount: 32
    )

    let wireJSON  = try JSONEncoder().encode(wire)
    let nonce     = ChaChaPoly.Nonce()
    let sealed    = try ChaChaPoly.seal(wireJSON, using: sealingKey, nonce: nonce, authenticating: Data())
    return SealedMessage(ephemeralPublicKey: ephPair.publicKeyData, encryptedPayload: sealed.combined)
}

private func unsealMessage(_ sealed: SealedMessage, recipientDHPrivateKey: Curve25519.KeyAgreement.PrivateKey) throws -> WireMessage {
    let ephKey = try Curve25519.KeyAgreement.PublicKey(rawRepresentation: sealed.ephemeralPublicKey)
    let shared = try recipientDHPrivateKey.sharedSecretFromKeyAgreement(with: ephKey)

    var ikmData = Data()
    shared.withUnsafeBytes { ikmData.append(contentsOf: $0) }
    let sealingKey = HKDF<SHA256>.deriveKey(
        inputKeyMaterial: SymmetricKey(data: ikmData),
        info: CryptoConstants.sealedSenderInfo,
        outputByteCount: 32
    )

    do {
        let box      = try ChaChaPoly.SealedBox(combined: sealed.encryptedPayload)
        let wireJSON = try ChaChaPoly.open(box, using: sealingKey, authenticating: Data())
        return try JSONDecoder().decode(WireMessage.self, from: wireJSON)
    } catch {
        throw SophaxError.decryptionFailed
    }
}

// MARK: - Delegate

public protocol ChatManagerDelegate: AnyObject {
    /// A peer came online and their identity has been verified.
    func chatManager(_ manager: ChatManager, didDiscoverPeer peer: KnownPeer)
    /// A peer is no longer reachable (direct or relay).
    func chatManager(_ manager: ChatManager, peerDidDisconnect peerID: String)
    /// A new inbound message was decrypted and stored.
    func chatManager(_ manager: ChatManager, didReceiveMessage message: StoredMessage, fromPeer peerID: String)
    /// A message was sent (or queued) successfully by the local user.
    func chatManager(_ manager: ChatManager, didSendMessage message: StoredMessage, toPeer peerID: String)
    /// A sent message was acknowledged by the recipient.
    func chatManager(_ manager: ChatManager, messageDelivered messageID: String, toPeer peerID: String)
    /// A non-fatal error occurred (logged; caller may display or ignore).
    func chatManager(_ manager: ChatManager, didEncounterError error: Error)
    /// The remote peer's typing state changed.
    func chatManager(_ manager: ChatManager, peerDidUpdateTyping peerID: String, isTyping: Bool)
    /// The remote peer has read one or more messages we sent.
    func chatManager(_ manager: ChatManager, messagesRead messageIDs: [String], byPeer peerID: String)
    /// A peer updated their emoji reaction on a specific message.
    func chatManager(_ manager: ChatManager, didUpdateReactions reactions: [String: String], onMessageID messageID: String, peerID: String)
    /// The local user was added to a new group (created locally or invited by another peer).
    func chatManager(_ manager: ChatManager, didJoinGroup group: GroupInfo)
    /// A group chat message was decrypted and stored.
    func chatManager(_ manager: ChatManager, didReceiveGroupMessage message: StoredMessage, inGroup groupID: String)
    /// An X3DH session was established WITHOUT a one-time prekey (reduced entropy window).
    func chatManager(_ manager: ChatManager, sessionEstablishedWithPeer peerID: String, usedOPK: Bool)
    /// A previously-known peer has come back online after being offline.
    func chatManager(_ manager: ChatManager, peerDidReconnect peer: KnownPeer)
    /// Emoji reactions on a group message were updated.
    func chatManager(_ manager: ChatManager, didUpdateGroupReactions reactions: [String: String],
                     onMessageID messageID: String, groupID: String)
    /// A member left a group. The delegate should update stored membership to `remainingMemberIDs`.
    func chatManager(_ manager: ChatManager, peer leavingPeerID: String,
                     leftGroupID groupID: String, remainingMemberIDs: [String])
}

// MARK: - ChatManager

public final class ChatManager: @unchecked Sendable {

    // MARK: - Sub-components

    public let identity:        IdentityManager
    public let preKeys:         PreKeyManager
    public let mesh:            MeshManager
    public let messageStore:    MessageStore
    public let attachmentStore: AttachmentStore

    private let keychain:       KeychainManager
    private let wireBuilder:    WireMessageBuilder
    private let relayRouter:    RelayRouter

    // MARK: - State

    /// Active Double Ratchet sessions keyed by application-level peerID.
    /// Always access through withSession(_:) to guarantee mutual exclusion.
    private var sessions: [String: DoubleRatchet] = [:]

    /// Serialises every load → mutate → persist cycle on a single session.
    /// DoubleRatchet is a class whose encrypt/decrypt methods mutate internal
    /// state; concurrent access to the same session would corrupt the chain.
    private let sessionLock = NSLock()

    /// Peers whose identity we've cryptographically verified, keyed by peerID.
    private var knownPeers: [String: KnownPeer] = [:]

    /// PreKeyBundles keyed by peerID — populated on Hello, used for X3DH initiation.
    private var peerBundles: [String: PreKeyBundle] = [:]

    /// Outbound messages queued for peers not currently reachable.
    /// Drained as soon as a path (direct or relay) becomes available.
    private var pendingQueue: [String: [(wire: WireMessage, messageID: String)]] = [:]

    /// Codable wrapper so pending queue items can be persisted to disk.
    private struct PendingQueueItem: Codable {
        let wire:      WireMessage
        let messageID: String
    }

    private let pendingQueueFileName = "pending_queue"

    /// In-memory cache of message keys for group messages that arrived out of order.
    /// Key: "groupID/senderPeerID" → (senderKeyIteration → messageKey)
    /// Bounded to `maxSkippedKeysCacheSize` entries per sender; oldest are evicted first.
    private var skippedGroupMessageKeys: [String: [UInt32: SymmetricKey]] = [:]
    private static let maxSkippedKeysCacheSize = 200

    /// Messages stored on behalf of offline peers (relay-store role).
    private struct StoredForwardItem {
        let targetPeerID: String
        let messageID:    String
        let sealed:       SealedMessage
        let expiresAt:    Date
    }
    private var storedForwardItems: [StoredForwardItem] = []
    private static let maxStoredForwardItems  = 300
    private static let storeAndForwardTTL: TimeInterval = 48 * 60 * 60   // 48 hours

    /// Fires every 60 seconds to purge messages whose expiresAt has passed.
    private var expiryTimer: Timer?

    public weak var delegate: ChatManagerDelegate?

    // MARK: - Init

    public init(
        identity:        IdentityManager,
        preKeys:         PreKeyManager,
        mesh:            MeshManager,
        messageStore:    MessageStore,
        attachmentStore: AttachmentStore,
        keychain:        KeychainManager
    ) {
        self.identity        = identity
        self.preKeys         = preKeys
        self.mesh            = mesh
        self.messageStore    = messageStore
        self.attachmentStore = attachmentStore
        self.keychain        = keychain
        self.wireBuilder     = WireMessageBuilder(identity: identity)
        self.relayRouter     = RelayRouter()
        mesh.delegate        = self
    }

    // MARK: - Public API

    /// Start advertising and browsing on the P2P mesh.
    public func start() {
        mesh.start()
        try? preKeys.rotateIfNeeded()
        scheduleExpiryTimer()
        loadPersistedQueue()
    }

    /// Stop the mesh (call on app background / termination).
    public func stop() {
        mesh.stop()
        expiryTimer?.invalidate()
        expiryTimer = nil
        persistQueue()
    }

    // MARK: - Public: Identity broadcast

    /// Re-broadcast our Hello (PreKeyBundle) to all currently-connected peers.
    /// Call after a username change so peers pick up the new display name.
    public func broadcastHello() {
        guard let bundle = try? preKeys.generateBundle() else { return }
        let hello = HelloMessage(bundle: bundle)
        guard let wire = try? wireBuilder.build(.hello, payload: hello) else { return }
        try? mesh.broadcast(wire)
    }

    // MARK: - Public: Group reactions

    /// Send an emoji reaction (or remove one) on a specific group message.
    public func sendGroupReaction(emoji: String?, toMessageID messageID: String, groupID: String, members: [String]) {
        let myID    = identity.publicIdentity.peerID
        let payload = GroupReactionMessage(groupID: groupID, targetMessageID: messageID, emoji: emoji)
        guard let wire = try? wireBuilder.build(.groupReaction, payload: payload) else { return }
        for peerID in members where peerID != myID {
            try? sendOrQueue(wire, toPeerID: peerID, messageID: UUID().uuidString)
        }
        // Apply locally
        let convID = "group.\(groupID)"
        guard let msgs = try? messageStore.messages(forPeer: convID),
              let idx  = msgs.firstIndex(where: { $0.id == messageID }) else { return }
        var reactions = msgs[idx].reactions ?? [:]
        if let e = emoji { reactions[myID] = e } else { reactions.removeValue(forKey: myID) }
        try? messageStore.updateReactions(reactions, forMessageID: messageID, peerID: convID)
        let finalReactions = reactions
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            self.delegate?.chatManager(self, didUpdateGroupReactions: finalReactions,
                                       onMessageID: messageID, groupID: groupID)
        }
    }

    private func scheduleExpiryTimer() {
        expiryTimer?.invalidate()
        // Run on main runloop — safe since all ChatManager state is on main
        expiryTimer = Timer.scheduledTimer(withTimeInterval: 60, repeats: true) { [weak self] _ in
            self?.purgeExpiredMessages()
        }
        // Fire once immediately to clean up any stale messages from previous sessions
        purgeExpiredMessages()
    }

    private func purgeExpiredMessages() {
        messageStore.deleteExpiredMessages()
        let now = Date()
        storedForwardItems.removeAll { $0.expiresAt <= now }
    }

    /// Maximum text message body length in UTF-8 bytes.
    public static let maxMessageBytes = 65_536       // 64 KB

    /// Maximum binary attachment size (image, audio) in bytes.
    public static let maxAttachmentBytes = 524_288   // 512 KB

    /// Maximum number of outbound messages queued per offline peer.
    /// Prevents memory exhaustion if a peer never reconnects.
    private static let maxQueuedMessagesPerPeer = 100

    /// Maximum expiry interval accepted from inbound messages (1 year).
    /// Clamps peer-supplied expiresAt so a malicious sender cannot set
    /// an absurd far-future date to prevent local cleanup.
    private static let maxExpiryInterval: TimeInterval = 365 * 24 * 60 * 60

    /// Send a plaintext message to `peerID`.
    ///
    /// Handles all cases automatically:
    ///   - New session: performs X3DH, sends `.initiateSession`
    ///   - Existing session: sends `.message` (Double Ratchet)
    ///   - Peer reachable via relay: wraps in `RelayEnvelope`
    ///   - No connectivity: queues for later delivery
    public func sendMessage(_ text: String, toPeerID peerID: String, expiresAt: Date? = nil, replyToID: String? = nil) {
        guard !text.isEmpty, text.utf8.count <= Self.maxMessageBytes else {
            delegate?.chatManager(self, didEncounterError:
                SophaxError.invalidMessageFormat("Message must be 1–65536 bytes"))
            return
        }
        let messageID = UUID().uuidString
        let stored = StoredMessage(
            id: messageID, peerID: peerID,
            direction: .sent, body: text, status: .sending,
            replyToID: replyToID
        )
        do {
            try messageStore.append(message: stored)
        } catch {
            delegate?.chatManager(self, didEncounterError: error)
            return
        }

        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            self.delegate?.chatManager(self, didSendMessage: stored, toPeer: peerID)
        }

        do {
            let content = MessageContent(body: text, replyToID: replyToID, expiresAt: expiresAt)
            let wire = try buildOutboundWire(content: content, messageID: messageID, toPeerID: peerID)
            try sendOrQueue(wire, toPeerID: peerID, messageID: messageID)
        } catch {
            try? messageStore.updateStatus(.failed, forMessageID: messageID, peerID: peerID)
            delegate?.chatManager(self, didEncounterError: error)
        }
    }

    /// Send read receipts for messages the local user has viewed.
    /// Best-effort: uses direct / relay / offline-queue routing.
    public func sendReadReceipts(messageIDs: [String], toPeerID peerID: String) {
        guard !messageIDs.isEmpty else { return }
        let payload = ReadReceiptMessage(messageIDs: messageIDs)
        guard let wire = try? wireBuilder.build(.readReceipt, payload: payload) else { return }
        try? sendOrQueue(wire, toPeerID: peerID, messageID: UUID().uuidString)
    }

    /// Send an emoji reaction (or remove one) on a specific message.
    /// `emoji` = nil removes any existing reaction from the local user.
    public func sendReaction(emoji: String?, toMessageID messageID: String, toPeerID peerID: String) {
        let payload = ReactionMessage(targetMessageID: messageID, emoji: emoji)
        guard let wire = try? wireBuilder.build(.reaction, payload: payload) else { return }
        try? sendOrQueue(wire, toPeerID: peerID, messageID: UUID().uuidString)
    }

    // MARK: - Group messaging

    /// Create a new group, distribute Sender Keys to all members, and notify the delegate.
    @discardableResult
    public func createGroup(name: String, memberPeerIDs: [String]) -> GroupInfo? {
        guard !name.isEmpty, !memberPeerIDs.isEmpty else { return nil }
        let myID   = identity.publicIdentity.peerID
        let groupID = UUID().uuidString
        var seen = Set<String>()
        let allMembers = ([myID] + memberPeerIDs).filter { seen.insert($0).inserted }
        let group = GroupInfo(id: groupID, name: name, memberIDs: allMembers, creatorID: myID)

        // Generate my sender chain key (v2 — random 32-byte seed via CryptoKit)
        let tmpKey       = SymmetricKey(size: .bits256)
        let chainKeyData = tmpKey.withUnsafeBytes { Data($0) }
        let myState      = SenderKeyState(chainKey: chainKeyData, iteration: 0)
        do {
            try keychain.saveMySenderKeyState(myState, groupID: groupID)
        } catch {
            delegate?.chatManager(self, didEncounterError: error)
            return nil
        }

        let invite = GroupInvitePayload(
            groupID:         groupID,
            groupName:       name,
            memberIDs:       allMembers,
            creatorID:       myID,
            senderChainKey:  chainKeyData,
            senderIteration: 0
        )
        guard let inviteData = try? JSONEncoder().encode(invite) else { return nil }

        // Send the invite to each member via the existing DR-encrypted channel
        for peerID in memberPeerIDs {
            let content = MessageContent(body: name, type: .groupInvite,
                                         groupInviteData: inviteData)
            if let wire = try? buildOutboundWire(content: content,
                                                  messageID: UUID().uuidString,
                                                  toPeerID: peerID) {
                try? sendOrQueue(wire, toPeerID: peerID, messageID: UUID().uuidString)
            }
        }

        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            self.delegate?.chatManager(self, didJoinGroup: group)
        }
        return group
    }

    /// Send a text message to all members of a group.
    public func sendGroupMessage(_ body: String, groupID: String, members: [String], expiresAt: Date? = nil, replyToID: String? = nil) {
        guard !body.isEmpty else { return }

        let myID       = identity.publicIdentity.peerID
        let myUsername = identity.publicIdentity.username
        let messageID  = UUID().uuidString
        let timestamp  = Date()

        // Encrypt — prefer v2 (Sender Key ratchet), fall back to v1 (shared key)
        let ciphertext:         Data
        let senderKeyIteration: UInt32?

        if var myState = keychain.loadMySenderKeyState(groupID: groupID) {
            // ── v2: Sender Key ratchet ────────────────────────────────────────
            let (messageKey, nextCK) = senderKeyRatchetStep(myState.chainKey)
            let iteration            = myState.iteration
            myState = SenderKeyState(chainKey: nextCK, iteration: iteration + 1)
            try? keychain.saveMySenderKeyState(myState, groupID: groupID)
            guard let bodyData = body.data(using: .utf8),
                  let sealed   = try? ChaChaPoly.seal(bodyData, using: messageKey) else { return }
            ciphertext         = sealed.combined
            senderKeyIteration = iteration

        } else if let groupKey = try? keychain.loadGroupKey(groupID: groupID) {
            // ── v1: shared key fallback ───────────────────────────────────────
            guard let bodyData = body.data(using: .utf8),
                  let sealed   = try? ChaChaPoly.seal(bodyData, using: groupKey) else { return }
            ciphertext         = sealed.combined
            senderKeyIteration = nil

        } else { return }

        let wireMsg = GroupWireMessage(
            groupID:            groupID,
            messageID:          messageID,
            senderPeerID:       myID,
            senderUsername:     myUsername,
            timestamp:          timestamp,
            ciphertext:         ciphertext,
            senderKeyIteration: senderKeyIteration,
            expiresAt:          expiresAt,
            replyToID:          replyToID
        )

        // Store locally as sent (mark delivered immediately — no per-member ack for group)
        let stored = StoredMessage(
            id: messageID, peerID: "group.\(groupID)",
            direction: .sent, body: body, status: .delivered,
            replyToID: replyToID, expiresAt: expiresAt, senderID: myID
        )
        try? messageStore.append(message: stored)
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            self.delegate?.chatManager(self, didReceiveGroupMessage: stored, inGroup: groupID)
        }

        // Broadcast to each member (excluding self)
        for peerID in members where peerID != myID {
            if let wire = try? wireBuilder.build(.groupMessage, payload: wireMsg) {
                try? sendOrQueue(wire, toPeerID: peerID, messageID: messageID)
            }
        }
    }

    /// Send a binary attachment (image or audio) to all members of a group.
    public func sendGroupAttachment(
        _ data: Data,
        mimeType: String,
        caption: String = "",
        audioDuration: Double? = nil,
        groupID: String,
        members: [String],
        expiresAt: Date? = nil,
        replyToID: String? = nil
    ) {
        guard data.count <= Self.maxAttachmentBytes else {
            delegate?.chatManager(self, didEncounterError:
                SophaxError.invalidMessageFormat("Attachment exceeds 512 KB limit"))
            return
        }

        let myID         = identity.publicIdentity.peerID
        let myUsername   = identity.publicIdentity.username
        let messageID    = UUID().uuidString
        let attachmentID = UUID().uuidString
        let timestamp    = Date()
        let msgType: MessageContent.MessageType = mimeType.hasPrefix("image/") ? .image : .audio
        let displayBody  = caption.isEmpty
            ? (msgType == .image ? "📷 Photo" : "🎤 Voice message")
            : caption

        // Save attachment locally for sender's own bubble
        try? attachmentStore.save(data, id: attachmentID)

        // Encrypt body + attachment — prefer v2 (Sender Keys), fall back to v1 (shared key)
        // Both body and attachment use the SAME message key (one chain step = one message).
        let bodyCiphertext:     Data
        let attCiphertext:      Data
        let senderKeyIteration: UInt32?

        if var myState = keychain.loadMySenderKeyState(groupID: groupID) {
            // ── v2: Sender Key ratchet ────────────────────────────────────────
            let (messageKey, nextCK) = senderKeyRatchetStep(myState.chainKey)
            let iteration            = myState.iteration
            myState = SenderKeyState(chainKey: nextCK, iteration: iteration + 1)
            try? keychain.saveMySenderKeyState(myState, groupID: groupID)
            guard let bodyData   = displayBody.data(using: .utf8),
                  let sealedBody = try? ChaChaPoly.seal(bodyData, using: messageKey),
                  let sealedAtt  = try? ChaChaPoly.seal(data,     using: messageKey) else { return }
            bodyCiphertext     = sealedBody.combined
            attCiphertext      = sealedAtt.combined
            senderKeyIteration = iteration

        } else if let groupKey = try? keychain.loadGroupKey(groupID: groupID) {
            // ── v1: shared key fallback ───────────────────────────────────────
            guard let bodyData   = displayBody.data(using: .utf8),
                  let sealedBody = try? ChaChaPoly.seal(bodyData, using: groupKey),
                  let sealedAtt  = try? ChaChaPoly.seal(data,     using: groupKey) else { return }
            bodyCiphertext     = sealedBody.combined
            attCiphertext      = sealedAtt.combined
            senderKeyIteration = nil

        } else { return }

        let wireMsg = GroupWireMessage(
            groupID:              groupID,
            messageID:            messageID,
            senderPeerID:         myID,
            senderUsername:       myUsername,
            timestamp:            timestamp,
            ciphertext:           bodyCiphertext,
            attachmentCiphertext: attCiphertext,
            attachmentMimeType:   mimeType,
            audioDuration:        audioDuration,
            senderKeyIteration:   senderKeyIteration,
            expiresAt:            expiresAt,
            replyToID:            replyToID
        )

        let stored = StoredMessage(
            id: messageID, peerID: "group.\(groupID)",
            direction: .sent, body: displayBody, status: .delivered,
            replyToID: replyToID, expiresAt: expiresAt,
            attachmentID: attachmentID, attachmentMimeType: mimeType,
            audioDuration: audioDuration, senderID: myID
        )
        try? messageStore.append(message: stored)
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            self.delegate?.chatManager(self, didReceiveGroupMessage: stored, inGroup: groupID)
        }

        for peerID in members where peerID != myID {
            if let wire = try? wireBuilder.build(.groupMessage, payload: wireMsg) {
                try? sendOrQueue(wire, toPeerID: peerID, messageID: messageID)
            }
        }
    }

    /// Remove the local user from a group.
    ///
    /// Broadcasts a `.groupMemberLeft` notification to all remaining members so they
    /// can update their local membership list and rotate their sender keys (ensuring
    /// the leaver cannot decrypt any future group messages).
    public func leaveGroup(_ group: GroupInfo) {
        let myID = identity.publicIdentity.peerID
        let remaining = group.memberIDs.filter { $0 != myID }

        // Notify all remaining members before deleting local crypto state
        let leaveMsg = GroupMemberLeftMessage(
            groupID:            group.id,
            leavingPeerID:      myID,
            remainingMemberIDs: remaining
        )
        if let wire = try? wireBuilder.build(.groupMemberLeft, payload: leaveMsg) {
            for peerID in remaining {
                try? sendOrQueue(wire, toPeerID: peerID, messageID: UUID().uuidString)
            }
        }

        // Clean up local state
        keychain.deleteGroupKey(groupID: group.id)               // v1 cleanup
        keychain.deleteAllSenderKeyStates(groupID: group.id)     // v2 cleanup
        try? messageStore.deleteConversation(peerID: group.conversationID)
    }

    /// Send a binary attachment (image or audio) to `peerID`.
    public func sendAttachment(
        _ data: Data,
        mimeType: String,
        caption: String = "",
        audioDuration: Double? = nil,
        toPeerID peerID: String,
        expiresAt: Date? = nil
    ) {
        guard data.count <= Self.maxAttachmentBytes else {
            delegate?.chatManager(self, didEncounterError:
                SophaxError.invalidMessageFormat("Attachment exceeds 512 KB limit"))
            return
        }

        let messageID    = UUID().uuidString
        let attachmentID = UUID().uuidString
        let msgType: MessageContent.MessageType = mimeType.hasPrefix("image/") ? .image : .audio
        let displayBody  = caption.isEmpty
            ? (msgType == .image ? "📷 Photo" : "🎤 Voice message")
            : caption

        // Save attachment locally for the sender's own bubble
        try? attachmentStore.save(data, id: attachmentID)

        let stored = StoredMessage(
            id: messageID, peerID: peerID,
            direction: .sent, body: displayBody, status: .sending,
            attachmentID: attachmentID, attachmentMimeType: mimeType,
            audioDuration: audioDuration
        )
        do {
            try messageStore.append(message: stored)
        } catch {
            delegate?.chatManager(self, didEncounterError: error)
            return
        }

        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            self.delegate?.chatManager(self, didSendMessage: stored, toPeer: peerID)
        }

        do {
            let content = MessageContent(
                body: caption, type: msgType, expiresAt: expiresAt,
                attachmentData: data, attachmentMimeType: mimeType,
                audioDuration: audioDuration
            )
            let wire = try buildOutboundWire(content: content, messageID: messageID, toPeerID: peerID)
            try sendOrQueue(wire, toPeerID: peerID, messageID: messageID)
        } catch {
            try? messageStore.updateStatus(.failed, forMessageID: messageID, peerID: peerID)
            delegate?.chatManager(self, didEncounterError: error)
        }
    }

    /// All stored messages for a conversation, oldest-first.
    public func messages(forPeer peerID: String) -> [StoredMessage] {
        (try? messageStore.messages(forPeer: peerID)) ?? []
    }

    /// Send a typing indicator to `peerID` (direct path only, best-effort — no relay, no queue).
    public func sendTypingIndicator(toPeerID peerID: String, isTyping: Bool) {
        guard mesh.isConnected(peerID: peerID) else { return }
        guard let wire = try? wireBuilder.build(.typing, payload: TypingMessage(isTyping: isTyping)) else { return }
        try? mesh.send(wire, toPeerID: peerID)
    }

    /// All peers with a verified identity (online or offline).
    public func allPeers() -> [KnownPeer] {
        Array(knownPeers.values)
    }

    // MARK: - Private: Build outbound wire message

    /// Encrypt `content` and return the wire message for `peerID`.
    ///
    /// - Existing session → `.message`
    /// - No session + bundle known → X3DH + `.initiateSession`
    /// - No bundle yet → throws `sessionNotInitialized` (caller queues)
    private func buildOutboundWire(
        content: MessageContent,
        messageID: String,
        toPeerID peerID: String
    ) throws -> WireMessage {
        let plaintext = try JSONEncoder().encode(content)
        let ad        = associatedData(peerID: peerID)

        // ── Case 1: existing session ──────────────────────────────────────────
        if let ratchetMsg = try withSession(peerID: peerID, { ratchet in
            try ratchet.encrypt(plaintext: plaintext, associatedData: ad)
        }) {
            let payload = ChatMessagePayload(ratchetMessage: ratchetMsg, messageID: messageID)
            return try wireBuilder.build(.message, payload: payload)
        }

        // ── Case 2: new session — need peer's PreKeyBundle for X3DH ──────────
        guard let bundle = peerBundles[peerID] else {
            throw SophaxError.sessionNotInitialized
        }

        let x3dhResult = try X3DH.initiateSender(
            senderIdentity:  identity.dhKeyPair,
            recipientBundle: bundle
        )
        let ratchet = try DoubleRatchet.initAsInitiator(
            sharedSecret:           x3dhResult.sharedSecret,
            remoteRatchetPublicKey: bundle.signedPreKeyPublic
        )
        let ratchetMsg = try ratchet.encrypt(plaintext: plaintext, associatedData: ad)
        try storeNewSession(ratchet, peerID: peerID)

        let senderBundle = try preKeys.generateBundle()
        let initPayload  = InitiateSessionMessage(
            senderBundle:        senderBundle,
            ephemeralPublicKey:  x3dhResult.ephemeralPublicKey,
            usedSignedPreKeyId:  bundle.signedPreKeyId,
            usedOneTimePreKeyId: x3dhResult.usedOneTimePreKeyId,
            initialMessage:      ratchetMsg
        )
        return try wireBuilder.build(.initiateSession, payload: initPayload)
    }

    // MARK: - Private: Routing

    /// Send a wire message: direct → relay → offline queue (in priority order).
    private func sendOrQueue(
        _ wire: WireMessage,
        toPeerID peerID: String,
        messageID: String
    ) throws {
        if mesh.isConnected(peerID: peerID) {
            // ── Direct path ───────────────────────────────────────────────────
            try mesh.send(wire, toPeerID: peerID)

        } else if mesh.directPeerCount > 0 {
            // ── Multihop relay: seal the inner message then flood ─────────────
            // Sealed sender hides message type and payload from relay nodes.
            // Only the intended recipient can decrypt; relay nodes see only
            // the ephemeral public key and opaque ciphertext.
            let innerWire: WireMessage
            var sealedForTarget: SealedMessage? = nil
            if let peer = knownPeers[peerID] {
                let sealed = try sealWireMessage(wire, recipientDHPublicKey: peer.dhKeyPublic)
                sealedForTarget = sealed
                innerWire = try wireBuilder.build(.sealed, payload: sealed)
            } else {
                innerWire = wire    // Unknown peer — fallback to plaintext relay
            }

            let envelope = RelayEnvelope(
                id:           UUID().uuidString,
                targetPeerID: peerID,
                originPeerID: identity.publicIdentity.peerID,
                ttl:          RelayEnvelope.maxTTL,
                hopCount:     0,
                message:      innerWire
            )
            let relayWire = try wireBuilder.build(.relay, payload: envelope)
            try mesh.broadcast(relayWire)

            // ── Store-and-forward: also ask relay peers to hold the message ───
            // If the target is not currently in the mesh, at least one relay peer
            // may later encounter them. Re-uses the sealed message already produced
            // above so no extra crypto is needed.
            if let sf = sealedForTarget {
                let sfReq = StoreAndForwardRequest(
                    targetPeerID: peerID,
                    messageID:    messageID,
                    sealed:       sf,
                    expiresAt:    Date().addingTimeInterval(Self.storeAndForwardTTL)
                )
                if let sfWire = try? wireBuilder.build(.storeAndForward, payload: sfReq) {
                    try? mesh.broadcast(sfWire)
                }
            }

        } else {
            // ── No connectivity: queue for later ──────────────────────────────
            var queue = pendingQueue[peerID, default: []]
            guard queue.count < Self.maxQueuedMessagesPerPeer else {
                throw SophaxError.invalidMessageFormat("Offline message queue is full — reconnect before sending more")
            }
            queue.append((wire: wire, messageID: messageID))
            pendingQueue[peerID] = queue
            persistQueue()
        }
    }

    /// Drain queued messages for a peer that just became reachable.
    private func drainQueue(forPeerID peerID: String) {
        guard let queued = pendingQueue.removeValue(forKey: peerID),
              !queued.isEmpty else { return }
        for item in queued {
            do {
                try sendOrQueue(item.wire, toPeerID: peerID, messageID: item.messageID)
            } catch {
                try? messageStore.updateStatus(.failed, forMessageID: item.messageID, peerID: peerID)
            }
        }
    }

    // MARK: - Private: Session management

    /// Execute `body` with the session for `peerID` under `sessionLock`.
    ///
    /// Returns `nil` if no session exists (Keychain miss) — callers treat that as
    /// "needs X3DH initiation". Throws on Keychain or crypto errors.
    ///
    /// The entire sequence — load → body → persist — is held under the lock so
    /// no two calls can operate on the same DoubleRatchet concurrently.
    private func withSession<T>(
        peerID: String,
        _ body: (DoubleRatchet) throws -> T
    ) throws -> T? {
        sessionLock.lock()
        defer { sessionLock.unlock() }

        // Load from memory; fall back to Keychain
        let ratchet: DoubleRatchet
        if let existing = sessions[peerID] {
            ratchet = existing
        } else {
            guard let data = try? keychain.loadSessionState(peerID: peerID) else {
                return nil   // No persisted session — not an error
            }
            ratchet = try DoubleRatchet.importState(data)   // throws if state is corrupted
            sessions[peerID] = ratchet
        }

        // Run the caller's crypto operation
        let result = try body(ratchet)

        // Persist mutated ratchet state (still under lock)
        sessions[peerID] = ratchet
        try keychain.saveSessionState(data: ratchet.exportState(), peerID: peerID)

        return result
    }

    /// Store a brand-new ratchet session (after X3DH initiation or reception).
    private func storeNewSession(_ ratchet: DoubleRatchet, peerID: String) throws {
        sessionLock.lock()
        defer { sessionLock.unlock() }
        sessions[peerID] = ratchet
        try keychain.saveSessionState(data: ratchet.exportState(), peerID: peerID)
    }

    // MARK: - Private: Message handlers

    private func handleHello(_ payload: HelloMessage) throws {
        let bundle = payload.bundle

        guard try bundle.verifySignedPreKey() else {
            throw SophaxError.invalidSignature
        }
        guard abs(bundle.timestamp.timeIntervalSinceNow) < CryptoConstants.maxPreKeyBundleAge else {
            throw SophaxError.stalePreKeyBundle
        }

        let peerID       = bundle.peerID
        let safetyNumber = generateSafetyNumber(for: bundle)
        let peer         = KnownPeer(from: bundle, safetyNumber: safetyNumber)

        // Detect reconnect: peer was known but is now coming back online
        let wasOffline = knownPeers[peerID].map { !$0.isOnline } ?? false

        knownPeers[peerID]  = peer
        peerBundles[peerID] = bundle

        let reconnected = wasOffline
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            self.delegate?.chatManager(self, didDiscoverPeer: peer)
            if reconnected {
                self.delegate?.chatManager(self, peerDidReconnect: peer)
            }
        }

        // Peer's bundle is now known — drain any messages queued before Hello arrived
        drainQueue(forPeerID: peerID)

        // Deliver any messages we were holding for this peer (store-and-forward relay role)
        deliverStoredForwardItems(toPeerID: peerID)
    }

    private func handleInitiateSession(_ payload: InitiateSessionMessage) throws {
        let senderBundle = payload.senderBundle
        guard try senderBundle.verifySignedPreKey() else {
            throw SophaxError.invalidSignature
        }

        let peerID = senderBundle.peerID

        // Deduplication: if an active session already exists with this peerID,
        // drop the duplicate initiateSession. This prevents replayed X3DH messages
        // from overwriting an established session.
        // A legitimate re-initiation always comes from a new peerID (new identity keys).
        if sessions[peerID] != nil || (try? keychain.loadSessionState(peerID: peerID)) != nil {
            return
        }

        peerBundles[peerID] = senderBundle

        // Retrieve and consume the one-time prekey if Alice used one,
        // then replenish the supply so future sessions have keys available.
        let usedOPKId = payload.usedOneTimePreKeyId
        let otpk = usedOPKId.flatMap { preKeys.consumeOneTimePreKey(id: $0) }
        try? preKeys.replenishIfNeeded()

        // Notify delegate so the UI can warn when no OPK was available (reduced entropy)
        let usedOPK = usedOPKId != nil
        let notifyPeerID = peerID
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            self.delegate?.chatManager(self, sessionEstablishedWithPeer: notifyPeerID, usedOPK: usedOPK)
        }

        // X3DH: Bob (responder) side — produces the same shared secret as Alice
        let sharedSecret = try X3DH.initiateReceiver(
            recipientIdentityDH:     identity.dhKeyPair,
            recipientSignedPreKey:   preKeys.signedPreKeyPair,
            recipientOneTimePreKey:  otpk,
            senderIdentityDHKeyData: senderBundle.dhIdentityKeyPublic,
            senderEphemeralKeyData:  payload.ephemeralPublicKey
        )

        // Double Ratchet: Bob starts as responder
        let ratchet = try DoubleRatchet.initAsResponder(
            sharedSecret:      sharedSecret,
            ownRatchetKeyPair: preKeys.signedPreKeyPair
        )

        // Decrypt the initial message (Alice's first plaintext)
        let ad        = associatedData(peerID: peerID)
        let plaintext = try ratchet.decrypt(message: payload.initialMessage, associatedData: ad)
        let content   = try JSONDecoder().decode(MessageContent.self, from: plaintext)

        var attachmentID: String? = nil
        if let attachData = content.attachmentData, content.attachmentMimeType != nil {
            let id = UUID().uuidString
            try? attachmentStore.save(attachData, id: id)
            attachmentID = id
        }

        // Group invite in the initial message — unlikely but handle gracefully
        if content.type == .groupInvite {
            if let inviteData = content.groupInviteData {
                handleGroupInviteReceived(inviteData, fromPeer: peerID)
            }
            try storeNewSession(ratchet, peerID: peerID)
            return
        }

        // Sender key distribution in the initial message — handle gracefully
        if content.type == .senderKeyDistribution {
            handleSenderKeyDistribution(content, fromPeer: peerID)
            try storeNewSession(ratchet, peerID: peerID)
            return
        }

        let displayBody: String
        switch content.type {
        case .text:                  displayBody = content.body
        case .image:                 displayBody = content.body.isEmpty ? "📷 Photo" : content.body
        case .audio:                 displayBody = content.body.isEmpty ? "🎤 Voice message" : content.body
        case .groupInvite:           displayBody = content.body           // dead code; handled above
        case .senderKeyDistribution: return                               // dead code; handled above
        }

        try storeNewSession(ratchet, peerID: peerID)

        // Register the peer
        let safetyNumber = generateSafetyNumber(for: senderBundle)
        var peer = KnownPeer(from: senderBundle, safetyNumber: safetyNumber)
        peer.isDirectlyConnected = mesh.isConnected(peerID: peerID)
        knownPeers[peerID] = peer

        let stored = StoredMessage(
            peerID:             peerID,
            direction:          .received,
            body:               displayBody,
            status:             .delivered,
            expiresAt:          clampedExpiry(content.expiresAt),
            attachmentID:       attachmentID,
            attachmentMimeType: content.attachmentMimeType,
            audioDuration:      content.audioDuration
        )
        try messageStore.append(message: stored)

        let discoveredPeer = peer
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            self.delegate?.chatManager(self, didDiscoverPeer: discoveredPeer)
            self.delegate?.chatManager(self, didReceiveMessage: stored, fromPeer: peerID)
        }
    }

    private func handleChatMessage(
        _ payload: ChatMessagePayload,
        fromPeer peerID: String,
        hopCount: UInt8? = nil
    ) throws {
        let ad = associatedData(peerID: peerID)

        guard let plaintext = try withSession(peerID: peerID, { ratchet in
            try ratchet.decrypt(message: payload.ratchetMessage, associatedData: ad)
        }) else {
            throw SophaxError.sessionNotInitialized
        }

        let content = try JSONDecoder().decode(MessageContent.self, from: plaintext)

        // Save attachment to local store (decrypted data is ephemeral after this)
        var attachmentID: String? = nil
        if let attachData = content.attachmentData, content.attachmentMimeType != nil {
            let id = UUID().uuidString
            try? attachmentStore.save(attachData, id: id)
            attachmentID = id
        }

        // Group invite — don't store as a chat message; process separately
        if content.type == .groupInvite {
            if let inviteData = content.groupInviteData {
                handleGroupInviteReceived(inviteData, fromPeer: peerID)
            }
            // Still ack delivery
            let ack  = AckMessage(messageID: payload.messageID, status: .delivered)
            if let wire = try? wireBuilder.build(.ack, payload: ack) {
                try? sendOrQueue(wire, toPeerID: peerID, messageID: payload.messageID)
            }
            return
        }

        // Sender key distribution — don't store as a chat message; update crypto state
        if content.type == .senderKeyDistribution {
            handleSenderKeyDistribution(content, fromPeer: peerID)
            let ack  = AckMessage(messageID: payload.messageID, status: .delivered)
            if let wire = try? wireBuilder.build(.ack, payload: ack) {
                try? sendOrQueue(wire, toPeerID: peerID, messageID: payload.messageID)
            }
            return
        }

        let displayBody: String
        switch content.type {
        case .text:  displayBody = content.body
        case .image: displayBody = content.body.isEmpty ? "📷 Photo" : content.body
        case .audio: displayBody = content.body.isEmpty ? "🎤 Voice message" : content.body
        case .groupInvite:            return  // already handled above; belt-and-suspenders guard
        case .senderKeyDistribution:  return  // already handled above; belt-and-suspenders guard
        }

        let stored = StoredMessage(
            id:                 payload.messageID,
            peerID:             peerID,
            direction:          .received,
            body:               displayBody,
            status:             .delivered,
            replyToID:          content.replyToID,
            expiresAt:          clampedExpiry(content.expiresAt),
            hopCount:           hopCount,
            attachmentID:       attachmentID,
            attachmentMimeType: content.attachmentMimeType,
            audioDuration:      content.audioDuration
        )
        try messageStore.append(message: stored)

        // Acknowledge delivery — errors here are non-fatal (peer may be gone),
        // but surfaced to the delegate so they are visible in logs.
        do {
            let ack  = AckMessage(messageID: payload.messageID, status: .delivered)
            let wire = try wireBuilder.build(.ack, payload: ack)
            try sendOrQueue(wire, toPeerID: peerID, messageID: payload.messageID)
        } catch {
            delegate?.chatManager(self, didEncounterError: error)
        }

        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            self.delegate?.chatManager(self, didReceiveMessage: stored, fromPeer: peerID)
        }
    }

    private func handleAck(_ payload: AckMessage, fromPeer peerID: String) {
        try? messageStore.updateStatus(.delivered, forMessageID: payload.messageID, peerID: peerID)
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            self.delegate?.chatManager(self, messageDelivered: payload.messageID, toPeer: peerID)
        }
    }

    private func handleReadReceipt(_ payload: ReadReceiptMessage, fromPeer peerID: String) {
        for id in payload.messageIDs {
            try? messageStore.updateStatus(.read, forMessageID: id, peerID: peerID)
        }
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            self.delegate?.chatManager(self, messagesRead: payload.messageIDs, byPeer: peerID)
        }
    }

    private func handleReaction(_ payload: ReactionMessage, fromPeer peerID: String) {
        // Determine which conversation owns the target message.
        // For sent messages the peerID is the conversation partner; reactions come from that peer.
        // For received messages the peerID is also the conversation partner.
        let convID = peerID
        guard let msgs = try? messageStore.messages(forPeer: convID),
              let idx = msgs.firstIndex(where: { $0.id == payload.targetMessageID }) else { return }
        var reactions = msgs[idx].reactions ?? [:]
        if let emoji = payload.emoji {
            reactions[peerID] = emoji
        } else {
            reactions.removeValue(forKey: peerID)
        }
        try? messageStore.updateReactions(reactions, forMessageID: payload.targetMessageID, peerID: convID)
        let messageID  = payload.targetMessageID
        let finalReactions = reactions
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            self.delegate?.chatManager(self, didUpdateReactions: finalReactions, onMessageID: messageID, peerID: convID)
        }
    }

    private func handleGroupReaction(_ payload: GroupReactionMessage, fromPeer peerID: String) {
        let convID = "group.\(payload.groupID)"
        guard let msgs = try? messageStore.messages(forPeer: convID),
              let idx  = msgs.firstIndex(where: { $0.id == payload.targetMessageID }) else { return }
        var reactions = msgs[idx].reactions ?? [:]
        if let emoji = payload.emoji {
            reactions[peerID] = emoji
        } else {
            reactions.removeValue(forKey: peerID)
        }
        try? messageStore.updateReactions(reactions, forMessageID: payload.targetMessageID, peerID: convID)
        let messageID      = payload.targetMessageID
        let groupID        = payload.groupID
        let finalReactions = reactions
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            self.delegate?.chatManager(self, didUpdateGroupReactions: finalReactions,
                                       onMessageID: messageID, groupID: groupID)
        }
    }

    // MARK: - Store-and-forward handlers

    /// A connected peer asks us to hold a sealed message for an offline third party.
    private func handleStoreAndForward(_ payload: StoreAndForwardRequest) {
        guard payload.expiresAt > Date() else { return }
        // Dedup
        guard !storedForwardItems.contains(where: { $0.messageID == payload.messageID }) else { return }

        // If target is currently connected to us, deliver immediately
        if mesh.isConnected(peerID: payload.targetPeerID) {
            let delivery = StoreAndForwardDelivery(
                items: [StoreAndForwardItem(messageID: payload.messageID, sealed: payload.sealed)]
            )
            if let wire = try? wireBuilder.build(.storeAndForwardDelivery, payload: delivery) {
                try? mesh.send(wire, toPeerID: payload.targetPeerID)
            }
            return
        }

        // Capacity management: purge expired then drop oldest if still full
        let now = Date()
        storedForwardItems.removeAll { $0.expiresAt <= now }
        if storedForwardItems.count >= Self.maxStoredForwardItems {
            storedForwardItems.removeFirst()
        }

        storedForwardItems.append(StoredForwardItem(
            targetPeerID: payload.targetPeerID,
            messageID:    payload.messageID,
            sealed:       payload.sealed,
            expiresAt:    payload.expiresAt
        ))
    }

    /// We received stored messages from a relay peer (we are the target).
    private func handleStoreAndForwardDelivery(_ payload: StoreAndForwardDelivery) {
        for item in payload.items {
            guard let inner = try? unsealMessage(
                item.sealed, recipientDHPrivateKey: identity.dhKeyPair.privateKey
            ) else { continue }
            // Verify signature if sender is known
            if let peer = knownPeers[inner.senderID] {
                guard (try? WireMessageBuilder.verify(
                    inner, signingKeyPublic: peer.signingKeyPublic
                )) == true else { continue }
            }
            try? processRelayedInnerMessage(inner, hopCount: 0)
        }
    }

    /// Deliver all stored-forward items to `peerID` (called when they come online).
    private func deliverStoredForwardItems(toPeerID peerID: String) {
        let pending = storedForwardItems.filter { $0.targetPeerID == peerID && $0.expiresAt > Date() }
        guard !pending.isEmpty else { return }
        let items = pending.map { StoreAndForwardItem(messageID: $0.messageID, sealed: $0.sealed) }
        let delivery = StoreAndForwardDelivery(items: items)
        if let wire = try? wireBuilder.build(.storeAndForwardDelivery, payload: delivery) {
            try? mesh.send(wire, toPeerID: peerID)
        }
        storedForwardItems.removeAll { $0.targetPeerID == peerID }
    }

    private func handleGroupMemberLeft(_ payload: GroupMemberLeftMessage) {
        let myID    = identity.publicIdentity.peerID
        let groupID = payload.groupID

        // Notify the delegate so the UI can remove the leaver from the member list
        let leavingPeerID = payload.leavingPeerID
        let remaining     = payload.remainingMemberIDs
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            self.delegate?.chatManager(self, peer: leavingPeerID,
                                       leftGroupID: groupID, remainingMemberIDs: remaining)
        }

        // Only remaining members rotate; if we're the leaver this message is irrelevant
        guard remaining.contains(myID) else { return }

        // Remove the leaver's sender key state so we stop trying to decrypt with old material
        var states = keychain.loadPeerSenderKeyStates(groupID: groupID)
        states.removeValue(forKey: leavingPeerID)
        try? keychain.savePeerSenderKeyStates(states, groupID: groupID)

        // Rotate our own sender key (fresh random seed) so the leaver's copy of our
        // old chain key is no longer valid for any future messages.
        guard keychain.loadMySenderKeyState(groupID: groupID) != nil else { return }
        let tmpKey      = SymmetricKey(size: .bits256)
        let newChainKey = tmpKey.withUnsafeBytes { Data($0) }
        try? keychain.saveMySenderKeyState(
            SenderKeyState(chainKey: newChainKey, iteration: 0), groupID: groupID)

        // Re-distribute our new sender key to every remaining member (excluding self)
        let skd = SenderKeyDistributionMessage(groupID: groupID, chainKey: newChainKey, iteration: 0)
        guard let skdData = try? JSONEncoder().encode(skd) else { return }
        for memberID in remaining where memberID != myID {
            let content = MessageContent(body: "", type: .senderKeyDistribution, senderKeyData: skdData)
            if let wire = try? buildOutboundWire(content: content,
                                                  messageID: UUID().uuidString,
                                                  toPeerID: memberID) {
                try? sendOrQueue(wire, toPeerID: memberID, messageID: UUID().uuidString)
            }
        }
    }

    private func handleGroupInviteReceived(_ inviteData: Data, fromPeer peerID: String) {
        guard let invite = try? JSONDecoder().decode(GroupInvitePayload.self, from: inviteData) else { return }
        let myID = identity.publicIdentity.peerID

        if let senderChainKey = invite.senderChainKey {
            // ── v2: Sender Keys ───────────────────────────────────────────────
            // Store creator's sender key state
            var states = keychain.loadPeerSenderKeyStates(groupID: invite.groupID)
            states[invite.creatorID] = SenderKeyState(
                chainKey:  senderChainKey,
                iteration: invite.senderIteration ?? 0
            )
            try? keychain.savePeerSenderKeyStates(states, groupID: invite.groupID)

            // Generate my own sender key and store it
            let tmpKey       = SymmetricKey(size: .bits256)
            let chainKeyData = tmpKey.withUnsafeBytes { Data($0) }
            let myState      = SenderKeyState(chainKey: chainKeyData, iteration: 0)
            try? keychain.saveMySenderKeyState(myState, groupID: invite.groupID)

            // Distribute my sender key to all other members via DR
            let skd = SenderKeyDistributionMessage(groupID: invite.groupID, chainKey: chainKeyData)
            if let skdData = try? JSONEncoder().encode(skd) {
                for memberID in invite.memberIDs where memberID != myID {
                    let content = MessageContent(body: "", type: .senderKeyDistribution,
                                                 senderKeyData: skdData)
                    if let wire = try? buildOutboundWire(content: content,
                                                         messageID: UUID().uuidString,
                                                         toPeerID: memberID) {
                        try? sendOrQueue(wire, toPeerID: memberID, messageID: UUID().uuidString)
                    }
                }
            }

        } else if let keyData = invite.groupKeyData {
            // ── v1: shared key fallback ───────────────────────────────────────
            let groupKey = SymmetricKey(data: keyData)
            try? keychain.saveGroupKey(groupKey, groupID: invite.groupID)
        }

        let group = GroupInfo(
            id:        invite.groupID,
            name:      invite.groupName,
            memberIDs: invite.memberIDs,
            creatorID: invite.creatorID
        )
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            self.delegate?.chatManager(self, didJoinGroup: group)
        }
    }

    private func handleGroupMessage(_ payload: GroupWireMessage) {
        let body:            String
        var attachDecryptKey: SymmetricKey? = nil

        if let iteration = payload.senderKeyIteration {
            // ── v2: Sender Key ratchet ────────────────────────────────────────
            let MAX_SKIP: UInt32 = 100
            let cacheKey = "\(payload.groupID)/\(payload.senderPeerID)"

            // ── Fast path: out-of-order delivery via skipped-key cache ─────────
            if let cachedKey = skippedGroupMessageKeys[cacheKey]?[iteration] {
                guard let sealedBox = try? ChaChaPoly.SealedBox(combined: payload.ciphertext),
                      let bodyData  = try? ChaChaPoly.open(sealedBox, using: cachedKey),
                      let decoded   = String(data: bodyData, encoding: .utf8) else { return }
                body             = decoded
                attachDecryptKey = cachedKey
                // Consume the cached key so it cannot be replayed
                skippedGroupMessageKeys[cacheKey]?.removeValue(forKey: iteration)
                if skippedGroupMessageKeys[cacheKey]?.isEmpty == true {
                    skippedGroupMessageKeys.removeValue(forKey: cacheKey)
                }
            } else {
                // ── Normal path: advance the chain ───────────────────────────
                var states = keychain.loadPeerSenderKeyStates(groupID: payload.groupID)
                guard var senderState = states[payload.senderPeerID] else {
                    return   // No sender key yet — distribution may arrive later
                }
                guard iteration >= senderState.iteration,
                      iteration - senderState.iteration <= MAX_SKIP else { return }

                // Fast-forward to the target iteration, caching skipped message keys
                // so out-of-order messages that arrive later can still be decrypted.
                var cached = skippedGroupMessageKeys[cacheKey] ?? [:]
                while senderState.iteration < iteration {
                    let (msgKey, nextCK) = senderKeyRatchetStep(senderState.chainKey)
                    cached[senderState.iteration] = msgKey
                    senderState = SenderKeyState(chainKey: nextCK, iteration: senderState.iteration + 1)
                }
                // Evict oldest entries if the cache grows too large
                if cached.count > Self.maxSkippedKeysCacheSize {
                    cached.keys.sorted()
                        .prefix(cached.count - Self.maxSkippedKeysCacheSize)
                        .forEach { cached.removeValue(forKey: $0) }
                }
                skippedGroupMessageKeys[cacheKey] = cached.isEmpty ? nil : cached

                let (messageKey, nextCK) = senderKeyRatchetStep(senderState.chainKey)
                guard let sealedBox = try? ChaChaPoly.SealedBox(combined: payload.ciphertext),
                      let bodyData  = try? ChaChaPoly.open(sealedBox, using: messageKey),
                      let decoded   = String(data: bodyData, encoding: .utf8) else { return }
                body             = decoded
                attachDecryptKey = messageKey

                states[payload.senderPeerID] = SenderKeyState(chainKey: nextCK, iteration: iteration + 1)
                try? keychain.savePeerSenderKeyStates(states, groupID: payload.groupID)
            }

        } else {
            // ── v1: shared key fallback ───────────────────────────────────────
            guard let groupKey  = try? keychain.loadGroupKey(groupID: payload.groupID) else { return }
            guard let sealedBox = try? ChaChaPoly.SealedBox(combined: payload.ciphertext),
                  let bodyData  = try? ChaChaPoly.open(sealedBox, using: groupKey),
                  let decoded   = String(data: bodyData, encoding: .utf8) else { return }
            body             = decoded
            attachDecryptKey = groupKey
        }

        // Decrypt attachment if present
        var attachmentID: String? = nil
        if let attCiphertext = payload.attachmentCiphertext,
           payload.attachmentMimeType != nil,
           let key      = attachDecryptKey,
           let sealedAtt = try? ChaChaPoly.SealedBox(combined: attCiphertext),
           let attData  = try? ChaChaPoly.open(sealedAtt, using: key) {
            let id = UUID().uuidString
            try? attachmentStore.save(attData, id: id)
            attachmentID = id
        }

        let convID = "group.\(payload.groupID)"
        let stored = StoredMessage(
            id:                 payload.messageID,
            peerID:             convID,
            direction:          .received,
            body:               body,
            timestamp:          payload.timestamp,
            status:             .delivered,
            replyToID:          payload.replyToID,
            expiresAt:          clampedExpiry(payload.expiresAt),
            attachmentID:       attachmentID,
            attachmentMimeType: payload.attachmentMimeType,
            audioDuration:      payload.audioDuration,
            senderID:           payload.senderPeerID,
            receivedAt:         Date()
        )
        try? messageStore.append(message: stored)
        let groupID = payload.groupID
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            self.delegate?.chatManager(self, didReceiveGroupMessage: stored, inGroup: groupID)
        }
    }

    /// Handle a RelayEnvelope arriving from a directly-connected peer.
    private func handleRelay(_ envelope: RelayEnvelope, fromRelayPeer relayPeerID: String) throws {
        let myPeerID = identity.publicIdentity.peerID

        if envelope.targetPeerID == myPeerID {
            // ── Destination reached — process the inner message ───────────────
            let inner = envelope.message

            // Verify inner message signature if we know the original sender
            if let peer = knownPeers[inner.senderID] {
                guard (try? WireMessageBuilder.verify(
                    inner, signingKeyPublic: peer.signingKeyPublic
                )) == true else {
                    return   // Bad signature on inner message — drop silently
                }
            }

            try processRelayedInnerMessage(inner, hopCount: envelope.hopCount)

        } else {
            // ── Not for me — check dedup cache and forward if still alive ─────
            guard !relayRouter.isRateLimited(senderID: relayPeerID) else { return }
            guard relayRouter.shouldProcess(envelope) else { return }

            let forwarded = envelope.forwarded()
            let relayWire = try wireBuilder.build(.relay, payload: forwarded)
            // Exclude the peer who sent us this envelope to avoid looping
            try mesh.broadcast(relayWire, excluding: relayPeerID)
        }
    }

    /// Dispatch a WireMessage that arrived via the relay system.
    private func processRelayedInnerMessage(_ message: WireMessage, hopCount: UInt8) throws {
        switch message.type {

        case .hello:
            let payload = try wireBuilder.decodePayload(HelloMessage.self, from: message)
            // Verify using the signing key that's inside the bundle itself
            guard try WireMessageBuilder.verify(
                message, signingKeyPublic: payload.bundle.signingKeyPublic
            ) else { throw SophaxError.invalidSignature }
            try handleHello(payload)

        case .initiateSession:
            let payload = try wireBuilder.decodePayload(InitiateSessionMessage.self, from: message)
            // Self-authenticating: verify outer WireMessage signature using the key
            // embedded in the sender's bundle. This prevents a relay node from
            // substituting its own X25519 keys into the X3DH handshake (MITM).
            guard try WireMessageBuilder.verify(
                message, signingKeyPublic: payload.senderBundle.signingKeyPublic
            ) else { throw SophaxError.invalidSignature }
            try handleInitiateSession(payload)

        case .message:
            let payload = try wireBuilder.decodePayload(ChatMessagePayload.self, from: message)
            try handleChatMessage(payload, fromPeer: message.senderID, hopCount: hopCount)

        case .ack:
            let payload = try wireBuilder.decodePayload(AckMessage.self, from: message)
            handleAck(payload, fromPeer: message.senderID)

        case .readReceipt:
            let payload = try wireBuilder.decodePayload(ReadReceiptMessage.self, from: message)
            handleReadReceipt(payload, fromPeer: message.senderID)

        case .reaction:
            let payload = try wireBuilder.decodePayload(ReactionMessage.self, from: message)
            handleReaction(payload, fromPeer: message.senderID)

        case .groupMessage:
            let payload = try wireBuilder.decodePayload(GroupWireMessage.self, from: message)
            handleGroupMessage(payload)

        case .sealed:
            let sealed = try wireBuilder.decodePayload(SealedMessage.self, from: message)
            let inner  = try unsealMessage(sealed, recipientDHPrivateKey: identity.dhKeyPair.privateKey)
            // Verify inner signature using sender's known key
            if let peer = knownPeers[inner.senderID] {
                guard (try? WireMessageBuilder.verify(inner, signingKeyPublic: peer.signingKeyPublic)) == true else {
                    return
                }
            }
            try processRelayedInnerMessage(inner, hopCount: hopCount)

        case .groupReaction:
            let payload = try wireBuilder.decodePayload(GroupReactionMessage.self, from: message)
            handleGroupReaction(payload, fromPeer: message.senderID)

        case .groupMemberLeft:
            let payload = try wireBuilder.decodePayload(GroupMemberLeftMessage.self, from: message)
            handleGroupMemberLeft(payload)

        case .storeAndForward, .storeAndForwardDelivery:
            break   // S&F is direct-only; relay nodes must not forward these

        case .relay, .typing:
            break   // No relay-of-relay; typing over relay has no value
        }
    }

    // MARK: - Private: Persistent queue

    private func persistQueue() {
        let serializable: [String: [PendingQueueItem]] = pendingQueue.mapValues { items in
            items.map { PendingQueueItem(wire: $0.wire, messageID: $0.messageID) }
        }
        guard let data = try? JSONEncoder().encode(serializable) else { return }
        try? messageStore.saveEncryptedBlob(data, fileName: pendingQueueFileName)
    }

    private func loadPersistedQueue() {
        guard let data = messageStore.loadEncryptedBlob(fileName: pendingQueueFileName),
              let decoded = try? JSONDecoder().decode([String: [PendingQueueItem]].self, from: data) else { return }
        pendingQueue = decoded.mapValues { items in
            items.map { (wire: $0.wire, messageID: $0.messageID) }
        }
    }

    // MARK: - Private: Helpers

    /// Associated data for Double Ratchet AEAD operations.
    /// Binds the session cryptographically to the specific pair of identities.
    /// The IDs are sorted so the value is the same on both sides regardless of
    /// who initiated the session.
    private func associatedData(peerID: String) -> Data {
        let localID   = identity.publicIdentity.peerID
        let sortedIDs = [localID, peerID].sorted()
        return Data((sortedIDs.joined() + CryptoConstants.appVersion).utf8)
    }

    /// 60-digit safety number (12 groups of 5 digits) for out-of-band
    /// identity verification, derived from SHA-512 of both identity keys.
    private func generateSafetyNumber(for bundle: PreKeyBundle) -> String {
        let combined = bundle.signingKeyPublic + bundle.dhIdentityKeyPublic
        let hash     = SHA512.hash(data: combined)
        let hashData = Data(hash)
        var groups: [String] = []
        for i in stride(from: 0, to: 30, by: 5) {
            let chunk = hashData[i..<(i + 5)]
            let value = chunk.reduce(UInt64(0)) { ($0 << 8) | UInt64($1) } % 100_000
            groups.append(String(format: "%05d", value))
        }
        return groups.joined(separator: " ")
    }
}

// MARK: - MeshManagerDelegate

extension ChatManager: MeshManagerDelegate {

    public func meshManager(
        _ manager: MeshManager, didDiscoverPeer peerID: String, withName displayName: String
    ) {
        // Nothing yet — wait for the Hello message to learn their crypto identity
    }

    public func meshManager(_ manager: MeshManager, didLosePeer peerID: String) {
        knownPeers[peerID]?.isOnline            = false
        knownPeers[peerID]?.isDirectlyConnected = false
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            self.delegate?.chatManager(self, peerDidDisconnect: peerID)
        }
    }

    public func meshManager(_ manager: MeshManager, didConnectToPeer mcPeerID: String) {
        // Send our PreKeyBundle immediately so the peer can initiate X3DH.
        // Called on the main thread by MeshManager — all operations here are synchronous
        // and non-blocking (pure in-memory crypto + MCSession.send which is thread-safe).
        do {
            let bundle = try preKeys.generateBundle()
            let hello  = HelloMessage(bundle: bundle)
            let wire   = try wireBuilder.build(.hello, payload: hello)
            try mesh.send(wire, toPeerID: mcPeerID)
        } catch {
            delegate?.chatManager(self, didEncounterError: error)
        }
        // Note: drainQueue is called from handleHello once the peer's real peerID is known
    }

    public func meshManager(_ manager: MeshManager, didDisconnectFromPeer peerID: String) {
        knownPeers[peerID]?.isOnline            = false
        knownPeers[peerID]?.isDirectlyConnected = false
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            self.delegate?.chatManager(self, peerDidDisconnect: peerID)
        }
    }

    public func meshManager(
        _ manager: MeshManager, didReceiveMessage message: WireMessage, fromPeer mcPeerID: String
    ) {
        // Verify Ed25519 signature for known peers.
        // For Hello messages the bundle contains the signing key — verified inside handleHello.
        if message.type != .hello {
            if let peer = knownPeers[message.senderID] {
                guard (try? WireMessageBuilder.verify(
                    message, signingKeyPublic: peer.signingKeyPublic
                )) == true else {
                    #if DEBUG
                    print("[ChatManager] ⚠️ Sig fail: type=\(message.type.rawValue) sender=\(message.senderID.prefix(8))")
                    #endif
                    return
                }
            }
        }

        do {
            switch message.type {

            case .hello:
                let payload = try wireBuilder.decodePayload(HelloMessage.self, from: message)
                // Self-verifying: use the key inside the bundle
                guard try WireMessageBuilder.verify(
                    message, signingKeyPublic: payload.bundle.signingKeyPublic
                ) else { throw SophaxError.invalidSignature }
                try handleHello(payload)

            case .initiateSession:
                let payload = try wireBuilder.decodePayload(InitiateSessionMessage.self, from: message)
                // Self-authenticating: verify using the key embedded in the sender's bundle.
                // The outer signature check above (line ~550) skips unknown senders, so
                // initiateSession must ALWAYS verify itself — same as hello.
                guard try WireMessageBuilder.verify(
                    message, signingKeyPublic: payload.senderBundle.signingKeyPublic
                ) else { throw SophaxError.invalidSignature }
                try handleInitiateSession(payload)

            case .message:
                let payload = try wireBuilder.decodePayload(ChatMessagePayload.self, from: message)
                try handleChatMessage(payload, fromPeer: message.senderID)

            case .ack:
                let payload = try wireBuilder.decodePayload(AckMessage.self, from: message)
                handleAck(payload, fromPeer: message.senderID)

            case .readReceipt:
                let payload = try wireBuilder.decodePayload(ReadReceiptMessage.self, from: message)
                handleReadReceipt(payload, fromPeer: message.senderID)

            case .reaction:
                let payload = try wireBuilder.decodePayload(ReactionMessage.self, from: message)
                handleReaction(payload, fromPeer: message.senderID)

            case .groupMessage:
                let payload = try wireBuilder.decodePayload(GroupWireMessage.self, from: message)
                handleGroupMessage(payload)

            case .groupReaction:
                let payload = try wireBuilder.decodePayload(GroupReactionMessage.self, from: message)
                handleGroupReaction(payload, fromPeer: message.senderID)

            case .groupMemberLeft:
                let payload = try wireBuilder.decodePayload(GroupMemberLeftMessage.self, from: message)
                handleGroupMemberLeft(payload)

            case .storeAndForward:
                let payload = try wireBuilder.decodePayload(StoreAndForwardRequest.self, from: message)
                handleStoreAndForward(payload)

            case .storeAndForwardDelivery:
                let payload = try wireBuilder.decodePayload(StoreAndForwardDelivery.self, from: message)
                handleStoreAndForwardDelivery(payload)

            case .relay:
                let envelope = try wireBuilder.decodePayload(RelayEnvelope.self, from: message)
                try handleRelay(envelope, fromRelayPeer: message.senderID)

            case .sealed:
                // Sealed sender arriving on a direct connection (unusual but valid)
                let sealed = try wireBuilder.decodePayload(SealedMessage.self, from: message)
                let inner  = try unsealMessage(sealed, recipientDHPrivateKey: identity.dhKeyPair.privateKey)
                if let peer = knownPeers[inner.senderID] {
                    guard (try? WireMessageBuilder.verify(inner, signingKeyPublic: peer.signingKeyPublic)) == true else {
                        break
                    }
                }
                try processRelayedInnerMessage(inner, hopCount: 0)

            case .typing:
                let payload = try wireBuilder.decodePayload(TypingMessage.self, from: message)
                let senderID = message.senderID
                let isTyping = payload.isTyping
                DispatchQueue.main.async { [weak self] in
                    guard let self else { return }
                    self.delegate?.chatManager(self, peerDidUpdateTyping: senderID, isTyping: isTyping)
                }
            }
        } catch {
            #if DEBUG
            print("[ChatManager] ❌ Error: \(error) | type=\(message.type.rawValue)")
            #endif
            delegate?.chatManager(self, didEncounterError: error)
        }
    }

    public func meshManager(
        _ manager: MeshManager, sendDidFailForPeer peerID: String, error: Error
    ) {
        delegate?.chatManager(self, didEncounterError: error)
    }

    // MARK: - Private helpers

    /// Clamps a peer-supplied expiry date to at most `maxExpiryInterval` from now.
    /// Prevents a malicious sender from setting expiresAt = year 9999 to block cleanup.
    private func clampedExpiry(_ date: Date?) -> Date? {
        guard let date else { return nil }
        let maxDate = Date().addingTimeInterval(Self.maxExpiryInterval)
        return min(date, maxDate)
    }

    // MARK: - Sender Key KDF chain (v2 group messaging)

    /// One step of the Signal-style sender key KDF chain.
    ///
    ///   messageKey_n   = HMAC-SHA256(chainKey_n, 0x01)
    ///   chainKey_{n+1} = HMAC-SHA256(chainKey_n, 0x02)
    ///
    /// The `messageKey` is used to encrypt/decrypt exactly one message.
    /// The `nextChainKey` replaces `chainKey` for subsequent messages.
    private func senderKeyRatchetStep(
        _ chainKey: Data
    ) -> (messageKey: SymmetricKey, nextChainKey: Data) {
        let ck         = SymmetricKey(data: chainKey)
        let messageKey = Data(HMAC<SHA256>.authenticationCode(for: Data([0x01]), using: ck))
        let nextCK     = Data(HMAC<SHA256>.authenticationCode(for: Data([0x02]), using: ck))
        return (SymmetricKey(data: messageKey), nextCK)
    }

    /// Store a peer's sender key distribution and update Keychain.
    private func handleSenderKeyDistribution(_ content: MessageContent, fromPeer peerID: String) {
        guard let skdData = content.senderKeyData,
              let skd     = try? JSONDecoder().decode(SenderKeyDistributionMessage.self, from: skdData)
        else { return }

        var states        = keychain.loadPeerSenderKeyStates(groupID: skd.groupID)
        states[peerID]    = SenderKeyState(chainKey: skd.chainKey, iteration: skd.iteration)
        try? keychain.savePeerSenderKeyStates(states, groupID: skd.groupID)
    }
}
