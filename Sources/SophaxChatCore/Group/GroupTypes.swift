// GroupTypes.swift
// SophaxChatCore
//
// Types for end-to-end encrypted group messaging.
// Groups use a shared symmetric key (ChaChaPoly) distributed via
// the existing Double Ratchet encrypted channel.

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
    /// Prefixed to distinguish from peer conversations.
    public var conversationID: String { "group.\(id)" }
}

// MARK: - GroupInvitePayload

/// Embedded in a Double Ratchet–encrypted MessageContent (type = .groupInvite)
/// so only the intended recipient can read the group key.
public struct GroupInvitePayload: Codable, Sendable {
    public let groupID:      String
    public let groupName:    String
    public let memberIDs:    [String]
    public let creatorID:    String
    /// Raw 32-byte ChaChaPoly symmetric key for this group.
    public let groupKeyData: Data

    public init(
        groupID:      String,
        groupName:    String,
        memberIDs:    [String],
        creatorID:    String,
        groupKeyData: Data
    ) {
        self.groupID      = groupID
        self.groupName    = groupName
        self.memberIDs    = memberIDs
        self.creatorID    = creatorID
        self.groupKeyData = groupKeyData
    }
}
