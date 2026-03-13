// GroupTypes.swift
// SophaxChatCore
//
// Types for end-to-end encrypted group messaging.
//
// Crypto evolution:
//   v1 (legacy): shared ChaChaPoly symmetric key, distributed via DR channel.
//   v2 (current): Signal-style Sender Keys — each member has their own KDF chain,
//                 providing per-message forward secrecy and break-in recovery.

import Foundation

// MARK: - GroupInfo

/// A persisted group conversation.
public struct GroupInfo: Codable, Identifiable, Sendable {
    /// Stable UUID assigned by the creator.
    public let id:        String
    public let name:      String
    /// All member peerIDs including the creator.
    public let memberIDs: [String]
    /// PeerID of the group creator.
    public let creatorID: String

    public init(
        id:        String   = UUID().uuidString,
        name:      String,
        memberIDs: [String],
        creatorID: String
    ) {
        self.id        = id
        self.name      = name
        self.memberIDs = memberIDs
        self.creatorID = creatorID
    }

    /// The key used in MessageStore for this group's conversation.
    public var conversationID: String { "group.\(id)" }
}

// MARK: - GroupInvitePayload

/// Embedded in a Double Ratchet–encrypted MessageContent (type = .groupInvite)
/// so only the intended recipient can read the group credentials.
///
/// v1 (legacy): groupKeyData contains a raw 32-byte ChaChaPoly shared key.
/// v2 (current): senderChainKey + senderIteration carry the creator's Sender Key state;
///               groupKeyData is nil.
public struct GroupInvitePayload: Codable, Sendable {
    public let groupID:         String
    public let groupName:       String
    public let memberIDs:       [String]
    public let creatorID:       String
    /// v1 shared key — nil when using v2 Sender Keys.
    public let groupKeyData:    Data?
    /// v2: creator's KDF chain key seed (32 bytes, HMAC-SHA256 based).
    public let senderChainKey:  Data?
    /// v2: chain iteration at time of invite (0 for a fresh group key).
    public let senderIteration: UInt32?

    /// v1 initialiser (backward compat — used when receiving old-format invites).
    public init(
        groupID:      String,
        groupName:    String,
        memberIDs:    [String],
        creatorID:    String,
        groupKeyData: Data
    ) {
        self.groupID         = groupID
        self.groupName       = groupName
        self.memberIDs       = memberIDs
        self.creatorID       = creatorID
        self.groupKeyData    = groupKeyData
        self.senderChainKey  = nil
        self.senderIteration = nil
    }

    /// v2 initialiser — Sender Keys.
    public init(
        groupID:         String,
        groupName:       String,
        memberIDs:       [String],
        creatorID:       String,
        senderChainKey:  Data,
        senderIteration: UInt32 = 0
    ) {
        self.groupID         = groupID
        self.groupName       = groupName
        self.memberIDs       = memberIDs
        self.creatorID       = creatorID
        self.groupKeyData    = nil
        self.senderChainKey  = senderChainKey
        self.senderIteration = senderIteration
    }
}

// MARK: - SenderKeyState

/// One sender's KDF chain state for a specific group.
/// Stored per (groupID, senderPeerID) in the Keychain.
///
/// Signal-style sender key ratchet:
///   messageKey_n   = HMAC-SHA256(chainKey_n, 0x01)  — used to encrypt one message
///   chainKey_{n+1} = HMAC-SHA256(chainKey_n, 0x02)  — replaces chainKey for next message
///
/// `iteration` tracks how many steps have been consumed.  Out-of-order messages
/// are handled by fast-forwarding the chain (up to MAX_SKIP = 100 steps); any
/// skipped message keys are discarded (those messages become unrecoverable).
public struct SenderKeyState: Codable, Sendable {
    /// Current 32-byte KDF chain key.
    public let chainKey:  Data
    /// Number of steps already consumed from this chain.
    public let iteration: UInt32

    public init(chainKey: Data, iteration: UInt32 = 0) {
        self.chainKey  = chainKey
        self.iteration = iteration
    }
}

// MARK: - SenderKeyDistributionMessage

/// Sent over the existing DR-encrypted channel to share a member's sender key
/// with all other group members.  Sent when:
///   • A new member accepts a group invite.
///   • A member resets their chain (key compromise recovery).
public struct SenderKeyDistributionMessage: Codable, Sendable {
    public let groupID:   String
    public let chainKey:  Data
    public let iteration: UInt32

    public init(groupID: String, chainKey: Data, iteration: UInt32 = 0) {
        self.groupID   = groupID
        self.chainKey  = chainKey
        self.iteration = iteration
    }
}
