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
    /// Read receipt — tells the sender that we have read their messages.
    case readReceipt
    /// Emoji reaction on a specific message.
    case reaction
    /// Group chat message encrypted with the shared group symmetric key.
    case groupMessage
    /// Emoji reaction on a specific group message.
    case groupReaction
    /// A member voluntarily left a group — triggers sender-key rotation in remaining members.
    case groupMemberLeft
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
    public let body:               String
    public let type:               MessageType
    public let replyToID:          String?
    public let timestamp:          Date
    /// nil = persistent; Date = auto-delete after this point
    public let expiresAt:          Date?
    /// Binary attachment (JPEG image or M4A audio). Encrypted with the Double Ratchet.
    public let attachmentData:     Data?
    /// MIME type: "image/jpeg" | "audio/m4a"
    public let attachmentMimeType: String?
    /// Audio duration in seconds (nil for non-audio).
    public let audioDuration:      Double?
    /// JSON-encoded GroupInvitePayload — only set when type == .groupInvite.
    public let groupInviteData:    Data?

    public enum MessageType: String, Codable, Sendable {
        case text
        case image
        case audio
        /// Group invite — body is the group name; groupInviteData carries GroupInvitePayload JSON.
        case groupInvite
        /// Sender key distribution (v2 groups) — senderKeyData carries SenderKeyDistributionMessage JSON.
        case senderKeyDistribution
    }

    /// JSON-encoded SenderKeyDistributionMessage — only set when type == .senderKeyDistribution.
    public let senderKeyData: Data?

    public init(
        body:               String,
        type:               MessageType = .text,
        replyToID:          String?     = nil,
        expiresAt:          Date?       = nil,
        attachmentData:     Data?       = nil,
        attachmentMimeType: String?     = nil,
        audioDuration:      Double?     = nil,
        groupInviteData:    Data?       = nil,
        senderKeyData:      Data?       = nil
    ) {
        self.body               = body
        self.type               = type
        self.replyToID          = replyToID
        self.timestamp          = Date()
        self.expiresAt          = expiresAt
        self.attachmentData     = attachmentData
        self.attachmentMimeType = attachmentMimeType
        self.audioDuration      = audioDuration
        self.groupInviteData    = groupInviteData
        self.senderKeyData      = senderKeyData
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

// MARK: - Read Receipt

/// Sent when the local user views messages from a peer.
/// Allows the sender to upgrade their delivery tick to a "read" indicator.
public struct ReadReceiptMessage: Codable, Sendable {
    /// IDs of the received messages being acknowledged as read.
    public let messageIDs: [String]

    public init(messageIDs: [String]) {
        self.messageIDs = messageIDs
    }
}

// MARK: - Group Message

/// Wire message for a group chat message.
///
/// Encryption:
///   v1 (nil senderKeyIteration): ChaChaPoly with the shared group symmetric key.
///   v2 (non-nil senderKeyIteration): ChaChaPoly with a per-message key derived from
///     the sender's KDF chain at the given iteration (Signal-style Sender Keys).
///
/// Sent individually to each group member (via direct/relay/queue routing).
public struct GroupWireMessage: Codable, Sendable {
    public let groupID:              String
    public let messageID:            String
    public let senderPeerID:         String
    public let senderUsername:       String
    public let timestamp:            Date
    /// ChaChaPoly.combined = nonce(12 B) + body ciphertext + tag(16 B)
    public let ciphertext:           Data
    /// ChaChaPoly.combined for the binary attachment (nil = text-only message).
    public let attachmentCiphertext: Data?
    /// "image/jpeg" | "audio/m4a" — nil when no attachment.
    public let attachmentMimeType:   String?
    /// Audio duration in seconds (nil for non-audio).
    public let audioDuration:        Double?
    /// v2 Sender Keys: which KDF chain iteration produced the message key.
    /// nil → v1 shared-key message (backward compat).
    public let senderKeyIteration:   UInt32?
    /// Disappearing message: auto-delete at this point; nil = persistent.
    public let expiresAt:            Date?
    /// Message ID this message is replying to (nil = not a reply).
    public let replyToID:            String?

    public init(
        groupID:              String,
        messageID:            String,
        senderPeerID:         String,
        senderUsername:       String,
        timestamp:            Date,
        ciphertext:           Data,
        attachmentCiphertext: Data?   = nil,
        attachmentMimeType:   String? = nil,
        audioDuration:        Double? = nil,
        senderKeyIteration:   UInt32? = nil,
        expiresAt:            Date?   = nil,
        replyToID:            String? = nil
    ) {
        self.groupID              = groupID
        self.messageID            = messageID
        self.senderPeerID         = senderPeerID
        self.senderUsername       = senderUsername
        self.timestamp            = timestamp
        self.ciphertext           = ciphertext
        self.attachmentCiphertext = attachmentCiphertext
        self.attachmentMimeType   = attachmentMimeType
        self.audioDuration        = audioDuration
        self.senderKeyIteration   = senderKeyIteration
        self.expiresAt            = expiresAt
        self.replyToID            = replyToID
    }
}

// MARK: - Group Reaction

/// Sent when a peer reacts to (or removes a reaction from) a group message.
public struct GroupReactionMessage: Codable, Sendable {
    public let groupID:          String
    public let targetMessageID:  String
    /// The emoji string, or nil to clear the reaction.
    public let emoji:            String?

    public init(groupID: String, targetMessageID: String, emoji: String?) {
        self.groupID         = groupID
        self.targetMessageID = targetMessageID
        self.emoji           = emoji
    }
}

// MARK: - Reaction

/// Sent when a peer reacts to (or removes a reaction from) one of your messages.
/// `emoji` is nil to remove a previously set reaction.
public struct ReactionMessage: Codable, Sendable {
    /// ID of the message being reacted to.
    public let targetMessageID: String
    /// The emoji string, or nil to clear the reaction.
    public let emoji: String?

    public init(targetMessageID: String, emoji: String?) {
        self.targetMessageID = targetMessageID
        self.emoji           = emoji
    }
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
    public let id:                 String
    public let peerID:             String
    public let direction:          Direction
    public let body:               String
    public let timestamp:          Date
    public var status:             MessageStatus
    public let replyToID:          String?
    public let expiresAt:          Date?
    /// Nil = delivered directly; >0 = relayed through N hops
    public let hopCount:           UInt8?
    /// Local file ID in AttachmentStore — nil means no attachment.
    public let attachmentID:       String?
    /// "image/jpeg" | "audio/m4a" — mirrors MessageContent.attachmentMimeType
    public let attachmentMimeType: String?
    /// Audio duration in seconds (nil for non-audio).
    public let audioDuration:      Double?
    /// Emoji reactions on this message, keyed by peerID. nil = no reactions.
    /// Declared optional for backward-compatibility (old stored messages lack this key).
    public var reactions:          [String: String]?
    /// For group messages: the actual sender's peerID. nil for direct messages.
    public let senderID:           String?
    /// Wall-clock time when this device received/decrypted the message.
    /// Used for display ordering instead of sender-supplied `timestamp` (which can be spoofed).
    /// Nil for messages stored before this field was added (backward compat).
    public let receivedAt:         Date?

    public enum Direction: String, Codable, Sendable {
        case sent, received
    }

    public enum MessageStatus: String, Codable, Sendable {
        case sending, delivered, failed, read
    }

    public init(
        id:                 String          = UUID().uuidString,
        peerID:             String,
        direction:          Direction,
        body:               String,
        timestamp:          Date            = Date(),
        status:             MessageStatus   = .sending,
        replyToID:          String?         = nil,
        expiresAt:          Date?           = nil,
        hopCount:           UInt8?          = nil,
        attachmentID:       String?         = nil,
        attachmentMimeType: String?         = nil,
        audioDuration:      Double?         = nil,
        reactions:          [String: String]? = nil,
        senderID:           String?         = nil,
        receivedAt:         Date?           = nil
    ) {
        self.id                 = id
        self.peerID             = peerID
        self.direction          = direction
        self.body               = body
        self.timestamp          = timestamp
        self.status             = status
        self.replyToID          = replyToID
        self.expiresAt          = expiresAt
        self.hopCount           = hopCount
        self.attachmentID       = attachmentID
        self.attachmentMimeType = attachmentMimeType
        self.audioDuration      = audioDuration
        self.reactions          = reactions
        self.senderID           = senderID
        self.receivedAt         = receivedAt
    }
}

// MARK: - Group Member Left

/// Broadcast by a member who is voluntarily leaving a group.
/// Recipients use this to update their local member list and rotate their sender keys
/// so the leaver cannot decrypt future messages.
public struct GroupMemberLeftMessage: Codable, Sendable {
    public let groupID:           String
    public let leavingPeerID:     String
    /// Remaining member peerIDs (does NOT include the leaver).
    public let remainingMemberIDs: [String]

    public init(groupID: String, leavingPeerID: String, remainingMemberIDs: [String]) {
        self.groupID            = groupID
        self.leavingPeerID      = leavingPeerID
        self.remainingMemberIDs = remainingMemberIDs
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
