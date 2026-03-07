// ChatManager.swift
// SophaxChatCore
//
// High-level coordinator — the single entry point for the app layer.
//
// Responsibilities:
//   • Owns the IdentityManager, PreKeyManager, MeshManager, MessageStore
//   • Orchestrates the full session lifecycle (X3DH → Double Ratchet)
//   • Dispatches events to the delegate on the main thread

import Foundation
import CryptoKit

// MARK: - Delegate

public protocol ChatManagerDelegate: AnyObject {
    /// A peer came online.
    func chatManager(_ manager: ChatManager, didDiscoverPeer peer: KnownPeer)
    /// A peer went offline.
    func chatManager(_ manager: ChatManager, peerDidDisconnect peerID: String)
    /// A new message was received and decrypted.
    func chatManager(_ manager: ChatManager, didReceiveMessage message: StoredMessage, fromPeer peerID: String)
    /// A sent message was acknowledged (delivered).
    func chatManager(_ manager: ChatManager, messageDelivered messageID: String, toPeer peerID: String)
    /// A non-fatal error occurred.
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

    // MARK: - Session state

    /// Active Double Ratchet sessions keyed by peerID.
    private var sessions: [String: DoubleRatchet] = [:]
    /// Peers we've received a Hello from (know their bundle).
    private var knownPeers: [String: KnownPeer] = [:]
    /// Peers we've discovered but not yet exchanged Hello with.
    private var pendingPeers: [String: PreKeyBundle] = [:]

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
        mesh.delegate     = self
    }

    // MARK: - Public API

    /// Start advertising and browsing on the mesh.
    public func start() {
        mesh.start()
    }

    /// Stop the mesh.
    public func stop() {
        mesh.stop()
    }

    /// Send a text message to a peer.
    /// If no session exists yet, initiates X3DH first.
    public func sendMessage(_ text: String, toPeerID peerID: String) {
        let messageID = UUID().uuidString
        let stored = StoredMessage(
            id: messageID, peerID: peerID,
            direction: .sent, body: text, status: .sending
        )
        try? messageStore.append(message: stored)

        do {
            let ratchet = try getOrCreateSession(peerID: peerID)
            let content = MessageContent(body: text)
            let plaintext = try JSONEncoder().encode(content)
            let ad = associatedData(peerID: peerID)
            let ratchetMsg = try ratchet.encrypt(plaintext: plaintext, associatedData: ad)

            // Persist updated session state
            try persistSession(ratchet, peerID: peerID)

            let payload = ChatMessagePayload(ratchetMessage: ratchetMsg, messageID: messageID)
            let wire    = try wireBuilder.build(.message, payload: payload)
            try mesh.send(wire, toPeerID: peerID)
        } catch {
            try? messageStore.updateStatus(.failed, forMessageID: messageID, peerID: peerID)
            delegate?.chatManager(self, didEncounterError: error)
        }
    }

    /// All messages for a conversation, sorted oldest first.
    public func messages(forPeer peerID: String) -> [StoredMessage] {
        (try? messageStore.messages(forPeer: peerID)) ?? []
    }

    /// All known peers with conversation history.
    public func allPeers() -> [KnownPeer] {
        Array(knownPeers.values)
    }

    // MARK: - Private: Session management

    private func getOrCreateSession(peerID: String) throws -> DoubleRatchet {
        if let existing = sessions[peerID] { return existing }

        // Try loading from Keychain
        if let stateData = try? keychain.loadSessionState(peerID: peerID),
           let ratchet = try? DoubleRatchet.importState(stateData) {
            sessions[peerID] = ratchet
            return ratchet
        }

        // Need to initiate a new session
        guard let peer = knownPeers[peerID] else {
            throw SophaxError.sessionNotInitialized
        }
        return try initiateSession(with: peer)
    }

    private func initiateSession(with peer: KnownPeer) throws -> DoubleRatchet {
        guard let bundle = pendingPeers[peer.id] else {
            throw SophaxError.sessionNotInitialized
        }

        // X3DH sender side
        let x3dhResult = try X3DH.initiateSender(
            senderIdentity: identity.dhKeyPair,
            recipientBundle: bundle
        )

        // Double Ratchet init as initiator
        let ratchet = try DoubleRatchet.initAsInitiator(
            sharedSecret: x3dhResult.sharedSecret,
            remoteRatchetPublicKey: bundle.signedPreKeyPublic
        )

        sessions[peer.id] = ratchet
        try persistSession(ratchet, peerID: peer.id)
        return ratchet
    }

    private func persistSession(_ ratchet: DoubleRatchet, peerID: String) throws {
        let stateData = try ratchet.exportState()
        try keychain.saveSessionState(data: stateData, peerID: peerID)
    }

    // MARK: - Private: Message handling

    private func handleHello(_ payload: HelloMessage, fromPeer peerID: String) throws {
        let bundle = payload.bundle

        // Verify signature
        guard try bundle.verifySignedPreKey() else {
            throw SophaxError.invalidSignature
        }

        // Verify bundle freshness
        guard abs(bundle.timestamp.timeIntervalSinceNow) < CryptoConstants.maxPreKeyBundleAge else {
            throw SophaxError.stalePreKeyBundle
        }

        let safetyNumber = generateSafetyNumber(for: bundle)
        let peer = KnownPeer(from: bundle, safetyNumber: safetyNumber)
        knownPeers[peer.id] = peer
        pendingPeers[peer.id] = bundle

        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            self.delegate?.chatManager(self, didDiscoverPeer: peer)
        }
    }

    private func handleInitiateSession(_ payload: InitiateSessionMessage, fromPeer mcPeerID: String) throws {
        let senderBundle = payload.senderBundle

        // Verify sender's signed prekey
        guard try senderBundle.verifySignedPreKey() else {
            throw SophaxError.invalidSignature
        }

        let peerID = senderBundle.peerID

        // Retrieve the one-time prekey if Alice used one
        let otpk = payload.usedOneTimePreKeyId.flatMap { preKeys.consumeOneTimePreKey(id: $0) }

        // X3DH receiver side
        let sharedSecret = try X3DH.initiateReceiver(
            recipientIdentityDH:      identity.dhKeyPair,
            recipientSignedPreKey:    preKeys.signedPreKeyPair,
            recipientOneTimePreKey:   otpk,
            senderIdentityDHKeyData:  senderBundle.dhIdentityKeyPublic,
            senderEphemeralKeyData:   payload.ephemeralPublicKey
        )

        // Double Ratchet init as responder (Bob)
        let ratchet = try DoubleRatchet.initAsResponder(
            sharedSecret: sharedSecret,
            ownRatchetKeyPair: preKeys.signedPreKeyPair
        )

        // Decrypt the first message
        let ad       = associatedData(peerID: peerID)
        let plaintext = try ratchet.decrypt(message: payload.initialMessage, associatedData: ad)
        let content   = try JSONDecoder().decode(MessageContent.self, from: plaintext)

        sessions[peerID] = ratchet
        try persistSession(ratchet, peerID: peerID)

        // Store as received message
        let stored = StoredMessage(
            peerID: peerID, direction: .received, body: content.body, status: .delivered
        )
        try messageStore.append(message: stored)

        // Update known peers
        let safetyNumber = generateSafetyNumber(for: senderBundle)
        let peer = KnownPeer(from: senderBundle, safetyNumber: safetyNumber)
        knownPeers[peerID] = peer

        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            self.delegate?.chatManager(self, didReceiveMessage: stored, fromPeer: peerID)
        }
    }

    private func handleChatMessage(_ payload: ChatMessagePayload, fromPeer peerID: String) throws {
        guard let ratchet = sessions[peerID] else {
            throw SophaxError.sessionNotInitialized
        }

        let ad = associatedData(peerID: peerID)
        let plaintext = try ratchet.decrypt(message: payload.ratchetMessage, associatedData: ad)
        let content   = try JSONDecoder().decode(MessageContent.self, from: plaintext)

        try persistSession(ratchet, peerID: peerID)

        let stored = StoredMessage(
            id: payload.messageID, peerID: peerID,
            direction: .received, body: content.body, status: .delivered
        )
        try messageStore.append(message: stored)

        // Send ACK
        let ack = AckMessage(messageID: payload.messageID, status: .delivered)
        if let wire = try? wireBuilder.build(.ack, payload: ack) {
            try? mesh.send(wire, toPeerID: peerID)
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

    // MARK: - Private: Helpers

    /// Associated data for Double Ratchet operations.
    /// Binds the session to the specific pair of identities — prevents session hijacking.
    private func associatedData(peerID: String) -> Data {
        let localID = identity.publicIdentity.peerID
        let sortedIDs = [localID, peerID].sorted()
        return Data((sortedIDs.joined() + CryptoConstants.appVersion).utf8)
    }

    private func generateSafetyNumber(for bundle: PreKeyBundle) -> String {
        let combined = bundle.signingKeyPublic + bundle.dhIdentityKeyPublic
        let hash = SHA512.hash(data: combined)
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

    public func meshManager(_ manager: MeshManager, didDiscoverPeer peerID: String, withName displayName: String) {
        // Nothing — wait for the Hello message to learn their crypto identity
    }

    public func meshManager(_ manager: MeshManager, didLosePeer peerID: String) {
        knownPeers[peerID]?.isOnline = false
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            self.delegate?.chatManager(self, peerDidDisconnect: peerID)
        }
    }

    public func meshManager(_ manager: MeshManager, didConnectToPeer peerID: String) {
        // Send our Hello (prekey bundle) immediately on connection
        Task {
            do {
                let bundle  = try preKeys.generateBundle()
                let hello   = HelloMessage(bundle: bundle)
                let wire    = try wireBuilder.build(.hello, payload: hello)
                try mesh.send(wire, toPeerID: peerID)
            } catch {
                delegate?.chatManager(self, didEncounterError: error)
            }
        }
    }

    public func meshManager(_ manager: MeshManager, didDisconnectFromPeer peerID: String) {
        knownPeers[peerID]?.isOnline = false
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            self.delegate?.chatManager(self, peerDidDisconnect: peerID)
        }
    }

    public func meshManager(_ manager: MeshManager, didReceiveMessage message: WireMessage, fromPeer peerID: String) {
        // Verify signature if we know the peer's signing key
        if let peer = knownPeers[message.senderID] {
            guard (try? WireMessageBuilder.verify(message, signingKeyPublic: peer.signingKeyPublic)) == true else {
                #if DEBUG
                print("[ChatManager] Signature verification failed for message from \(peerID)")
                #endif
                return
            }
        }
        // (For Hello messages from unknown peers, we verify after decoding the bundle)

        do {
            switch message.type {
            case .hello:
                let payload = try wireBuilder.decodePayload(HelloMessage.self, from: message)
                // Verify bundle signature covers the signing key we just received
                guard try WireMessageBuilder.verify(message, signingKeyPublic: payload.bundle.signingKeyPublic) else {
                    throw SophaxError.invalidSignature
                }
                try handleHello(payload, fromPeer: peerID)

            case .initiateSession:
                let payload = try wireBuilder.decodePayload(InitiateSessionMessage.self, from: message)
                try handleInitiateSession(payload, fromPeer: peerID)

            case .sessionAck:
                let payload = try wireBuilder.decodePayload(ChatMessagePayload.self, from: message)
                try handleChatMessage(payload, fromPeer: message.senderID)

            case .message:
                let payload = try wireBuilder.decodePayload(ChatMessagePayload.self, from: message)
                try handleChatMessage(payload, fromPeer: message.senderID)

            case .ack:
                let payload = try wireBuilder.decodePayload(AckMessage.self, from: message)
                handleAck(payload, fromPeer: message.senderID)

            case .typing:
                break   // Handle typing indicators in UI layer if desired
            }
        } catch {
            #if DEBUG
            print("[ChatManager] Error processing message: \(error)")
            #endif
            delegate?.chatManager(self, didEncounterError: error)
        }
    }

    public func meshManager(_ manager: MeshManager, sendDidFailForPeer peerID: String, error: Error) {
        delegate?.chatManager(self, didEncounterError: error)
    }
}
