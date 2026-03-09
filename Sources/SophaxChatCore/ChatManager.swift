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
}

// MARK: - ChatManager

public final class ChatManager: @unchecked Sendable {

    // MARK: - Sub-components

    public let identity:     IdentityManager
    public let preKeys:      PreKeyManager
    public let mesh:         MeshManager
    public let messageStore: MessageStore

    private let keychain:    KeychainManager
    private let wireBuilder: WireMessageBuilder
    private let relayRouter: RelayRouter

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

    /// Fires every 60 seconds to purge messages whose expiresAt has passed.
    private var expiryTimer: Timer?

    public weak var delegate: ChatManagerDelegate?

    // MARK: - Init

    public init(
        identity:     IdentityManager,
        preKeys:      PreKeyManager,
        mesh:         MeshManager,
        messageStore: MessageStore,
        keychain:     KeychainManager
    ) {
        self.identity     = identity
        self.preKeys      = preKeys
        self.mesh         = mesh
        self.messageStore = messageStore
        self.keychain     = keychain
        self.wireBuilder  = WireMessageBuilder(identity: identity)
        self.relayRouter  = RelayRouter()
        mesh.delegate     = self
    }

    // MARK: - Public API

    /// Start advertising and browsing on the P2P mesh.
    public func start() {
        mesh.start()
        try? preKeys.rotateIfNeeded()
        scheduleExpiryTimer()
    }

    /// Stop the mesh (call on app background / termination).
    public func stop() {
        mesh.stop()
        expiryTimer?.invalidate()
        expiryTimer = nil
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
    }

    /// Maximum message body length in UTF-8 bytes.
    public static let maxMessageBytes = 65_536   // 64 KB

    /// Maximum number of outbound messages queued per offline peer.
    /// Prevents memory exhaustion if a peer never reconnects.
    private static let maxQueuedMessagesPerPeer = 100

    /// Send a plaintext message to `peerID`.
    ///
    /// Handles all cases automatically:
    ///   - New session: performs X3DH, sends `.initiateSession`
    ///   - Existing session: sends `.message` (Double Ratchet)
    ///   - Peer reachable via relay: wraps in `RelayEnvelope`
    ///   - No connectivity: queues for later delivery
    public func sendMessage(_ text: String, toPeerID peerID: String, expiresAt: Date? = nil) {
        guard !text.isEmpty, text.utf8.count <= Self.maxMessageBytes else {
            delegate?.chatManager(self, didEncounterError:
                SophaxError.invalidMessageFormat("Message must be 1–65536 bytes"))
            return
        }
        let messageID = UUID().uuidString
        let stored = StoredMessage(
            id: messageID, peerID: peerID,
            direction: .sent, body: text, status: .sending
        )
        try? messageStore.append(message: stored)

        // Notify the UI immediately so the sent message appears in the chat view
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            self.delegate?.chatManager(self, didSendMessage: stored, toPeer: peerID)
        }

        do {
            let wire = try buildOutboundWire(
                text: text, messageID: messageID,
                toPeerID: peerID, expiresAt: expiresAt
            )
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

    /// All peers with a verified identity (online or offline).
    public func allPeers() -> [KnownPeer] {
        Array(knownPeers.values)
    }

    // MARK: - Private: Build outbound wire message

    /// Constructs the correct WireMessage for the given peer.
    ///
    /// - If a session already exists (memory or Keychain): returns `.message`
    /// - If no session but bundle known: performs X3DH, returns `.initiateSession`
    /// - If no bundle yet: throws `sessionNotInitialized` (caller queues the message)
    private func buildOutboundWire(
        text: String, messageID: String,
        toPeerID peerID: String, expiresAt: Date?
    ) throws -> WireMessage {
        let content   = MessageContent(body: text, expiresAt: expiresAt)
        let plaintext = try JSONEncoder().encode(content)
        let ad        = associatedData(peerID: peerID)

        // ── Case 1: existing session ──────────────────────────────────────────
        // withSession returns nil (not throws) when no session exists yet.
        if let ratchetMsg = try withSession(peerID: peerID, { ratchet in
            try ratchet.encrypt(plaintext: plaintext, associatedData: ad)
        }) {
            let payload = ChatMessagePayload(ratchetMessage: ratchetMsg, messageID: messageID)
            return try wireBuilder.build(.message, payload: payload)
        }

        // ── Case 2: new session — need peer's PreKeyBundle for X3DH ──────────
        guard let bundle = peerBundles[peerID] else {
            // Bundle not yet received — caller should queue and retry after Hello
            throw SophaxError.sessionNotInitialized
        }

        // X3DH: Alice (sender) side
        let x3dhResult = try X3DH.initiateSender(
            senderIdentity:  identity.dhKeyPair,
            recipientBundle: bundle
        )

        // Double Ratchet: Alice starts as initiator
        let ratchet = try DoubleRatchet.initAsInitiator(
            sharedSecret:           x3dhResult.sharedSecret,
            remoteRatchetPublicKey: bundle.signedPreKeyPublic
        )

        // Encrypt the first message inside the session initiation envelope
        let ratchetMsg = try ratchet.encrypt(plaintext: plaintext, associatedData: ad)
        try storeNewSession(ratchet, peerID: peerID)

        // Alice's own bundle (Bob needs it to verify the X3DH and future messages)
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
            // ── Multihop relay: flood to all connected peers ──────────────────
            let envelope = RelayEnvelope(
                id:           UUID().uuidString,
                targetPeerID: peerID,
                originPeerID: identity.publicIdentity.peerID,
                ttl:          RelayEnvelope.maxTTL,
                hopCount:     0,
                message:      wire
            )
            let relayWire = try wireBuilder.build(.relay, payload: envelope)
            try mesh.broadcast(relayWire)

        } else {
            // ── No connectivity: queue for later ──────────────────────────────
            var queue = pendingQueue[peerID, default: []]
            guard queue.count < Self.maxQueuedMessagesPerPeer else {
                throw SophaxError.invalidMessageFormat("Offline message queue is full — reconnect before sending more")
            }
            queue.append((wire: wire, messageID: messageID))
            pendingQueue[peerID] = queue
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
        knownPeers[peerID]  = peer
        peerBundles[peerID] = bundle

        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            self.delegate?.chatManager(self, didDiscoverPeer: peer)
        }

        // Peer's bundle is now known — drain any messages queued before Hello arrived
        drainQueue(forPeerID: peerID)
    }

    private func handleInitiateSession(_ payload: InitiateSessionMessage) throws {
        let senderBundle = payload.senderBundle
        guard try senderBundle.verifySignedPreKey() else {
            throw SophaxError.invalidSignature
        }

        let peerID = senderBundle.peerID
        peerBundles[peerID] = senderBundle

        // Retrieve and consume the one-time prekey if Alice used one,
        // then replenish the supply so future sessions have keys available.
        let otpk = payload.usedOneTimePreKeyId.flatMap { preKeys.consumeOneTimePreKey(id: $0) }
        try? preKeys.replenishIfNeeded()

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

        try storeNewSession(ratchet, peerID: peerID)

        // Register the peer
        let safetyNumber = generateSafetyNumber(for: senderBundle)
        var peer = KnownPeer(from: senderBundle, safetyNumber: safetyNumber)
        peer.isDirectlyConnected = mesh.isConnected(peerID: peerID)
        knownPeers[peerID] = peer

        let stored = StoredMessage(
            peerID:    peerID,
            direction: .received,
            body:      content.body,
            status:    .delivered,
            expiresAt: content.expiresAt
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

        let stored = StoredMessage(
            id:        payload.messageID,
            peerID:    peerID,
            direction: .received,
            body:      content.body,
            status:    .delivered,
            expiresAt: content.expiresAt,
            hopCount:  hopCount
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

        case .relay, .typing:
            break   // No relay-of-relay; typing over relay has no value
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

            case .relay:
                let envelope = try wireBuilder.decodePayload(RelayEnvelope.self, from: message)
                try handleRelay(envelope, fromRelayPeer: message.senderID)

            case .typing:
                break
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
}
