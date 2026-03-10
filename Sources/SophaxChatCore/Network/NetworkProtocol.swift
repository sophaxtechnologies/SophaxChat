// NetworkProtocol.swift
// SophaxChatCore
//
// All messages exchanged over the P2P mesh network.
//
// Protocol flow:
//
//   [Discovery]
//     Peers discover each other via MCNearbyServiceBrowser.
//
//   [Handshake — immediately on MPC connection]
//     A → B: .hello  (A's PreKeyBundle)
//     B → A: .hello  (B's PreKeyBundle)
//
//   [Session Initiation — A sends first encrypted message to B]
//     A → B: .initiateSession  (EK_A, used prekey IDs, first Double Ratchet message)
//
//   [Normal messages — after session established]
//     A ↔ B: .message  (Double Ratchet encrypted)
//
//   [Delivery confirmation]
//     B → A: .ack
//
//   [Multihop relay — A and B not directly connected]
//     A → C: .relay (RelayEnvelope targeting B, TTL=5)
//     C → B: .relay (RelayEnvelope, TTL=4)   [C forwards after checking target]
//     B processes the inner message

import Foundation
import CryptoKit

// MARK: - Wire Message Envelope

/// Top-level wrapper for all network messages.
/// Every WireMessage is signed with the sender's Ed25519 identity key.
public struct WireMessage: Codable, Sendable {
    public let type:      WireMessageType
    public let payload:   Data        // JSON-encoded inner message
    public let senderID:  String      // Sender's peerID (deterministic hash of identity keys)
    public let timestamp: Date        // Fixed at build time — same value in signingBytes()
    public let signature: Data        // Ed25519(type || payload || senderID || timestamp)

    /// Use WireMessageBuilder.build() to construct — do NOT call directly.
    /// The timestamp parameter must be passed by the builder so signing bytes
    /// and the final message share the EXACT SAME timestamp.
    public init(
        type:      WireMessageType,
        payload:   Data,
        senderID:  String,
        timestamp: Date,              // ← explicit, not Date() here
        signature: Data
    ) {
        self.type      = type
        self.payload   = payload
        self.senderID  = senderID
        self.timestamp = timestamp
        self.signature = signature
    }

    /// Canonical byte representation that is signed/verified.
    /// MUST be deterministic — no Date() call here.
    public func signingBytes() -> Data {
        var data = Data()
        data.append(contentsOf: type.rawValue.utf8)
        data.append(payload)
        data.append(contentsOf: senderID.utf8)
        // ISO 8601 is deterministic for a fixed Date value
        data.append(contentsOf: ISO8601DateFormatter().string(from: timestamp).utf8)
        return data
    }
}

// MARK: - Message Types

public enum WireMessageType: String, Codable, Sendable {
    /// Initial handshake — contains the sender's PreKeyBundle.
    case hello
    /// X3DH session initiation — contains EK_A and the first Double Ratchet message.
    case initiateSession
    /// Normal Double Ratchet–encrypted message.
    case message
    /// Delivery acknowledgment.
    case ack
    /// Relay envelope for multihop delivery.
    case relay
    /// Typing indicator (unencrypted, metadata-only).
    case typing
    /// Sealed sender — wraps an encrypted WireMessage so relay nodes cannot read the inner type or payload.
    case sealed
}

// MARK: - Hello (Handshake)

/// Sent immediately after an MPC connection is established.
/// Contains the sender's full PreKeyBundle so the recipient can initiate X3DH.
public struct HelloMessage: Codable, Sendable {
    public let bundle: PreKeyBundle
}

// MARK: - Session Initiation (X3DH)

/// Sent by Alice to initiate a new encrypted session with Bob.
/// Contains everything Bob needs to:
///   1. Reproduce the X3DH shared secret
///   2. Initialise the Double Ratchet as responder
///   3. Decrypt the first message
public struct InitiateSessionMessage: Codable, Sendable {
    /// Alice's full PreKeyBundle — Bob stores this for future verification.
    public let senderBundle:        PreKeyBundle
    /// Alice's ephemeral public key (EK_A) from X3DH.
    public let ephemeralPublicKey:  Data
    /// Which of Bob's signed prekeys Alice used.
    public let usedSignedPreKeyId:  UInt32
    /// Which of Bob's one-time prekeys Alice used (nil if none available).
    public let usedOneTimePreKeyId: UInt32?
    /// First Double Ratchet encrypted message.
    public let initialMessage:      RatchetMessage
}

// MARK: - Chat Message Payload

/// Carries a Double Ratchet–encrypted message after session establishment.
public struct ChatMessagePayload: Codable, Sendable {
    public let ratchetMessage: RatchetMessage
    /// Stable UUID for deduplication and ACK correlation.
    public let messageID:      String
}

/// Plaintext content encrypted inside the Double Ratchet ciphertext.
/// This is the ONLY place where message text lives unencrypted — in memory during processing.
public struct MessageContent: Codable, Sendable {
    public let body:        String
    public let type:        MessageType
    public let replyToID:   String?
    public let timestamp:   Date
    /// nil = persistent; Date = auto-delete after this point
    public let expiresAt:   Date?

    public enum MessageType: String, Codable, Sendable {
        case text
    }

    public init(
        body:      String,
        type:      MessageType = .text,
        replyToID: String? = nil,
        expiresAt: Date? = nil
    ) {
        self.body      = body
        self.type      = type
        self.replyToID = replyToID
        self.timestamp = Date()
        self.expiresAt = expiresAt
    }
}

// MARK: - Multihop Relay

/// Wraps any WireMessage for relay delivery through intermediate peers.
///
/// Flow:
///   Alice → Charlie: RelayEnvelope(target=Bob, ttl=5, message=chatMsg)
///   Charlie checks: Am I Bob? No → decrement TTL → forward to all peers except Alice
///   Bob receives:   Am I Bob? Yes → process inner message
public struct RelayEnvelope: Codable, Sendable {
    /// UUID — relay nodes use this to deduplicate (drop already-seen envelopes).
    public let id:           String
    /// Final destination peerID.
    public let targetPeerID: String
    /// Original sender peerID (for reply routing).
    public let originPeerID: String
    /// Decremented at every hop; dropped when it reaches 0.
    public let ttl:          UInt8
    /// Number of hops already taken (for UI display and analytics).
    public let hopCount:     UInt8
    /// The actual message for the target peer.
    public let message:      WireMessage

    public static let maxTTL: UInt8 = 6

    /// Returns a new envelope with TTL decremented and hopCount incremented.
    public func forwarded() -> RelayEnvelope {
        RelayEnvelope(
            id:           id,
            targetPeerID: targetPeerID,
            originPeerID: originPeerID,
            ttl:          ttl > 0 ? ttl - 1 : 0,
            hopCount:     hopCount + 1,
            message:      message
        )
    }
}

// MARK: - Ack

public struct AckMessage: Codable, Sendable {
    public let messageID: String
    public let status:    AckStatus

    public enum AckStatus: String, Codable, Sendable {
        case delivered
        case failed
    }
}

// MARK: - Typing

public struct TypingMessage: Codable, Sendable {
    public let isTyping: Bool
}

// MARK: - Sealed Sender

/// Wraps a WireMessage so that relay nodes cannot see the inner message type or payload.
///
/// Encryption scheme:
///   1. Sender generates an ephemeral Curve25519 key pair (EK_s)
///   2. sharedSecret = ECDH(EK_s_private, recipient_DH_public)
///   3. sealingKey = HKDF-SHA256(sharedSecret, info="SophaxChat_SealedSender_v1", len=32)
///   4. encryptedPayload = ChaCha20-Poly1305(sealingKey, JSON(innerWireMessage))
///
/// Only the intended recipient (who knows their DH private key) can decrypt.
/// Relay nodes see only: origin, target, an ephemeral public key, and ciphertext.
public struct SealedMessage: Codable, Sendable {
    /// Sender's ephemeral Curve25519 public key (32 bytes) — one per sealed message.
    public let ephemeralPublicKey: Data
    /// ChaCha20-Poly1305 ciphertext: nonce(12B) + encrypted WireMessage JSON + tag(16B).
    public let encryptedPayload: Data
}

// MARK: - WireMessage Builder

/// Creates and verifies signed WireMessages.
public struct WireMessageBuilder {
    private let identity: IdentityManager

    public init(identity: IdentityManager) {
        self.identity = identity
    }

    /// Build a signed WireMessage.
    /// Uses a single `Date()` snapshot so signing bytes and the final
    /// message carry the SAME timestamp — avoiding the previous bug where
    /// two separate `init` calls produced two different timestamps.
    public func build<T: Codable>(_ type: WireMessageType, payload: T) throws -> WireMessage {
        let payloadData = try JSONEncoder().encode(payload)
        let senderID    = identity.publicIdentity.peerID
        let timestamp   = Date()   // ← captured ONCE

        // Construct unsigned message to compute the canonical bytes to sign
        let unsigned = WireMessage(
            type: type, payload: payloadData,
            senderID: senderID, timestamp: timestamp, signature: Data()
        )
        let signature = try identity.sign(unsigned.signingBytes())

        // Return the final message with the same timestamp
        return WireMessage(
            type: type, payload: payloadData,
            senderID: senderID, timestamp: timestamp, signature: signature
        )
    }

    /// Verify the Ed25519 signature on a received WireMessage.
    public static func verify(_ message: WireMessage, signingKeyPublic: Data) throws -> Bool {
        let bytes = message.signingBytes()
        return try IdentityManager.verify(
            signature: message.signature,
            for: bytes,
            signingKeyPublic: signingKeyPublic
        )
    }

    public func decodePayload<T: Codable>(_ type: T.Type, from message: WireMessage) throws -> T {
        try JSONDecoder().decode(type, from: message.payload)
    }
}

// MARK: - Stored Message

/// A message persisted in the local encrypted store.
public struct StoredMessage: Codable, Identifiable, Sendable {
    public let id:        String
    public let peerID:    String
    public let direction: Direction
    public let body:      String
    public let timestamp: Date
    public var status:    MessageStatus
    public let replyToID: String?
    public let expiresAt: Date?
    /// Nil = delivered directly; >0 = relayed through N hops
    public let hopCount:  UInt8?

    public enum Direction: String, Codable, Sendable {
        case sent, received
    }

    public enum MessageStatus: String, Codable, Sendable {
        case sending, delivered, failed
    }

    public init(
        id:        String = UUID().uuidString,
        peerID:    String,
        direction: Direction,
        body:      String,
        timestamp: Date = Date(),
        status:    MessageStatus = .sending,
        replyToID: String? = nil,
        expiresAt: Date? = nil,
        hopCount:  UInt8? = nil
    ) {
        self.id        = id
        self.peerID    = peerID
        self.direction = direction
        self.body      = body
        self.timestamp = timestamp
        self.status    = status
        self.replyToID = replyToID
        self.expiresAt = expiresAt
        self.hopCount  = hopCount
    }
}

// MARK: - Known Peer

/// A peer whose identity keys we've received and cryptographically verified.
public struct KnownPeer: Codable, Identifiable, Sendable {
    public let id:               String
    public let username:         String
    public let signingKeyPublic: Data
    public let dhKeyPublic:      Data
    public let safetyNumber:     String
    public var lastSeen:         Date?
    public var isOnline:         Bool
    public var isDirectlyConnected: Bool    // false = reachable only via relay

    public init(from bundle: PreKeyBundle, safetyNumber: String) {
        self.id                  = bundle.peerID
        self.username            = bundle.username
        self.signingKeyPublic    = bundle.signingKeyPublic
        self.dhKeyPublic         = bundle.dhIdentityKeyPublic
        self.safetyNumber        = safetyNumber
        self.lastSeen            = Date()
        self.isOnline            = true
        self.isDirectlyConnected = true
    }
}
