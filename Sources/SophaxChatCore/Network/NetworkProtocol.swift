// NetworkProtocol.swift
// SophaxChatCore
//
// All messages exchanged over the P2P mesh network.
// Messages are JSON-encoded and transported via MultipeerConnectivity.
//
// Protocol flow:
//
//   [Discovery]
//     Alice discovers Bob via MCNearbyServiceBrowser.
//
//   [Handshake]
//     Alice → Bob: .hello  (Alice's PreKeyBundle)
//     Bob → Alice: .hello  (Bob's PreKeyBundle)
//
//   [Session Initiation - Alice wants to message Bob]
//     Alice → Bob: .initiateSession  (EK_A, used OPK id, first encrypted message)
//
//   [Session Acceptance - Bob processes X3DH and replies]
//     Bob → Alice: .sessionAck + first Double Ratchet message
//
//   [Normal messages]
//     Alice ↔ Bob: .message  (Double Ratchet encrypted)
//
//   [Delivery confirmation]
//     Bob → Alice: .ack

import Foundation
import CryptoKit

// MARK: - Wire Message Envelope

/// Top-level wrapper for all network messages.
/// The envelope contains the message type discriminator and the payload.
/// The payload is itself encrypted except for handshake messages.
public struct WireMessage: Codable, Sendable {
    public let type:      WireMessageType
    public let payload:   Data        // JSON-encoded inner message
    public let senderID:  String      // Sender's peerID (hash of identity keys)
    public let timestamp: Date
    /// Ed25519 signature of (type.rawValue + payload + senderID + timestamp ISO8601)
    public let signature: Data

    public init(type: WireMessageType, payload: Data, senderID: String, signature: Data) {
        self.type      = type
        self.payload   = payload
        self.senderID  = senderID
        self.timestamp = Date()
        self.signature = signature
    }

    /// Returns the bytes to sign/verify.
    public func signingBytes() throws -> Data {
        var data = Data()
        data.append(contentsOf: type.rawValue.utf8)
        data.append(payload)
        data.append(contentsOf: senderID.utf8)
        let iso = ISO8601DateFormatter().string(from: timestamp)
        data.append(contentsOf: iso.utf8)
        return data
    }
}

public enum WireMessageType: String, Codable, Sendable {
    /// Initial handshake — contains the sender's PreKeyBundle.
    case hello
    /// Initiates a new encrypted session (X3DH initiation).
    case initiateSession
    /// Acknowledges session initiation; contains a Double Ratchet message.
    case sessionAck
    /// Normal encrypted chat message.
    case message
    /// Delivery acknowledgment.
    case ack
    /// Typing indicator (unencrypted, optional).
    case typing
}

// MARK: - Hello (Handshake)

/// Sent immediately after connecting to a peer.
/// Contains the sender's full PreKeyBundle.
public struct HelloMessage: Codable, Sendable {
    public let bundle: PreKeyBundle
}

// MARK: - Initiate Session (X3DH)

/// Sent by Alice to initiate a new encrypted session with Bob.
/// Contains everything Bob needs to compute the shared secret and decrypt the message.
public struct InitiateSessionMessage: Codable, Sendable {
    /// Alice's full identity (so Bob can validate and respond).
    public let senderBundle: PreKeyBundle

    /// Alice's ephemeral public key (EK_A) from X3DH.
    public let ephemeralPublicKey: Data

    /// Which of Bob's signed prekey Alice used (so Bob knows which SPK to use).
    public let usedSignedPreKeyId: UInt32

    /// Which of Bob's one-time prekeys Alice used (so Bob can consume it).
    public let usedOneTimePreKeyId: UInt32?

    /// The first Double Ratchet encrypted message, nested inside.
    public let initialMessage: RatchetMessage
}

// MARK: - Chat Message

/// A regular Double Ratchet–encrypted message.
public struct ChatMessagePayload: Codable, Sendable {
    /// The Double Ratchet encrypted content.
    public let ratchetMessage: RatchetMessage
    /// Unique message ID (UUID) — used for deduplication and ACKs.
    public let messageID: String
    /// Encrypted message metadata (type, reply-to, etc.) — inside the ratchet plaintext.
    /// We store this separately for UI use after decryption.
}

/// The decrypted plaintext content of a chat message.
/// This struct is what's actually encrypted inside the Double Ratchet.
public struct MessageContent: Codable, Sendable {
    public let body:      String
    public let type:      MessageType
    public let replyToID: String?      // Message ID of the message being replied to
    public let timestamp: Date

    public enum MessageType: String, Codable, Sendable {
        case text
        // Future: image, file, location, etc.
    }

    public init(body: String, type: MessageType = .text, replyToID: String? = nil) {
        self.body      = body
        self.type      = type
        self.replyToID = replyToID
        self.timestamp = Date()
    }
}

// MARK: - Ack

/// Delivery acknowledgment. Sent back to the sender after decrypting a message.
public struct AckMessage: Codable, Sendable {
    public let messageID: String
    public let status:    AckStatus

    public enum AckStatus: String, Codable, Sendable {
        case delivered
        case failed
    }
}

// MARK: - Typing Indicator

public struct TypingMessage: Codable, Sendable {
    public let isTyping: Bool
}

// MARK: - WireMessage Builder

public struct WireMessageBuilder {
    private let identity: IdentityManager

    public init(identity: IdentityManager) {
        self.identity = identity
    }

    public func build<T: Codable>(_ type: WireMessageType, payload: T) throws -> WireMessage {
        let payloadData = try JSONEncoder().encode(payload)
        let senderID    = identity.publicIdentity.peerID

        var envelope = WireMessage(type: type, payload: payloadData, senderID: senderID, signature: Data())

        // Sign the envelope
        let bytesToSign = try envelope.signingBytes()
        let signature   = try identity.sign(bytesToSign)

        // Rebuild with signature
        return WireMessage(type: type, payload: payloadData, senderID: senderID, signature: signature)
    }

    /// Verify the signature on a received WireMessage.
    public static func verify(_ message: WireMessage, signingKeyPublic: Data) throws -> Bool {
        let bytesToVerify = try message.signingBytes()
        return try IdentityManager.verify(
            signature: message.signature,
            for: bytesToVerify,
            signingKeyPublic: signingKeyPublic
        )
    }

    public func decodePayload<T: Codable>(_ type: T.Type, from message: WireMessage) throws -> T {
        try JSONDecoder().decode(type, from: message.payload)
    }
}

// MARK: - Stored Message (local model)

/// A message stored locally in the chat history.
public struct StoredMessage: Codable, Identifiable, Sendable {
    public let id:           String    // UUID
    public let peerID:       String    // Conversation partner's peerID
    public let direction:    Direction
    public let body:         String
    public let timestamp:    Date
    public var status:       MessageStatus
    public let replyToID:    String?

    public enum Direction: String, Codable, Sendable {
        case sent
        case received
    }

    public enum MessageStatus: String, Codable, Sendable {
        case sending
        case delivered
        case failed
    }

    public init(
        id:        String = UUID().uuidString,
        peerID:    String,
        direction: Direction,
        body:      String,
        timestamp: Date = Date(),
        status:    MessageStatus = .sending,
        replyToID: String? = nil
    ) {
        self.id        = id
        self.peerID    = peerID
        self.direction = direction
        self.body      = body
        self.timestamp = timestamp
        self.status    = status
        self.replyToID = replyToID
    }
}

// MARK: - Known Peer (contact)

/// A known peer whose identity keys we've verified.
public struct KnownPeer: Codable, Identifiable, Sendable {
    public let id:              String    // peerID
    public let username:        String
    public let signingKeyPublic: Data
    public let dhKeyPublic:      Data
    public let safetyNumber:     String
    public var lastSeen:         Date?
    public var isOnline:         Bool

    public init(from bundle: PreKeyBundle, safetyNumber: String) {
        self.id               = bundle.peerID
        self.username         = bundle.username
        self.signingKeyPublic = bundle.signingKeyPublic
        self.dhKeyPublic      = bundle.dhIdentityKeyPublic
        self.safetyNumber     = safetyNumber
        self.lastSeen         = Date()
        self.isOnline         = true
    }
}
