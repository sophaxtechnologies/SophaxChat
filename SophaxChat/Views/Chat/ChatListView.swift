// ChatListView.swift
// SophaxChat
//
// Main screen: list of conversations + nearby peers.

import SwiftUI
import SophaxChatCore

struct ChatListView: View {
    @EnvironmentObject var appState: AppState
    @State private var showingIdentity    = false
    @State private var showingSettings    = false
    @State private var showingCreateGroup = false
    @State private var peerToBlock: KnownPeer? = nil

    var body: some View {
        NavigationStack {
            List {
                // Active conversations (peers with messages, not blocked)
                let conversationPeers = appState.peers.filter {
                    appState.messages[$0.id] != nil && !appState.isBlocked($0.id)
                }
                if !conversationPeers.isEmpty {
                    Section("Conversations") {
                        ForEach(conversationPeers) { peer in
                            NavigationLink(destination: ChatView(peer: peer)) {
                                ConversationRow(
                                    peer: peer,
                                    messages: appState.messages[peer.id] ?? [],
                                    unreadCount: appState.unreadCounts[peer.id] ?? 0
                                )
                            }
                            .swipeActions(edge: .trailing, allowsFullSwipe: false) {
                                Button(role: .destructive) {
                                    appState.deleteConversation(peerID: peer.id)
                                } label: {
                                    Label("Delete", systemImage: "trash")
                                }
                                Button {
                                    peerToBlock = peer
                                } label: {
                                    Label("Block", systemImage: "nosign")
                                }
                                .tint(.orange)
                            }
                        }
                    }
                }

                // Group conversations
                if !appState.groups.isEmpty {
                    Section("Groups") {
                        ForEach(appState.groups) { group in
                            NavigationLink(destination: GroupChatView(group: group)) {
                                GroupConversationRow(group: group)
                            }
                        }
                    }
                }

                // Online peers without conversations yet
                let newPeers = appState.peers.filter {
                    appState.messages[$0.id] == nil
                    && appState.onlinePeers.contains($0.id)
                    && !appState.isBlocked($0.id)
                }
                if !newPeers.isEmpty {
                    Section("Nearby") {
                        ForEach(newPeers) { peer in
                            NavigationLink(destination: ChatView(peer: peer)) {
                                PeerRow(peer: peer, isOnline: true)
                            }
                            .swipeActions(edge: .trailing, allowsFullSwipe: false) {
                                Button {
                                    peerToBlock = peer
                                } label: {
                                    Label("Block", systemImage: "nosign")
                                }
                                .tint(.orange)
                            }
                        }
                    }
                }

                // Empty state
                if appState.peers.filter({ !appState.isBlocked($0.id) }).isEmpty {
                    Section {
                        VStack(spacing: 16) {
                            Image(systemName: "antenna.radiowaves.left.and.right")
                                .font(.system(size: 40))
                                .foregroundStyle(.tertiary)
                            Text("Looking for nearby devices…")
                                .font(.subheadline)
                                .foregroundStyle(.secondary)
                            Text("Make sure both devices have the app open and are within Bluetooth/WiFi range.")
                                .font(.caption)
                                .foregroundStyle(.tertiary)
                                .multilineTextAlignment(.center)
                        }
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 32)
                        .listRowBackground(Color.clear)
                    }
                }
            }
            .navigationTitle("SophaxChat")
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    HStack(spacing: 4) {
                        Button {
                            showingCreateGroup = true
                        } label: {
                            Image(systemName: "person.2.badge.plus")
                        }
                        Button {
                            showingSettings = true
                        } label: {
                            Image(systemName: "gearshape")
                        }
                        Button {
                            showingIdentity = true
                        } label: {
                            Image(systemName: "person.crop.circle")
                        }
                    }
                }
            }
            .refreshable { }
        }
        .sheet(isPresented: $showingIdentity) {
            IdentityView()
        }
        .sheet(isPresented: $showingSettings) {
            SettingsView()
        }
        .sheet(isPresented: $showingCreateGroup) {
            CreateGroupView()
        }
        .alert("Error", isPresented: Binding(
            get: { appState.errorMessage != nil },
            set: { if !$0 { appState.errorMessage = nil } }
        ), presenting: appState.errorMessage) { _ in
            Button("OK") { appState.errorMessage = nil }
        } message: { msg in
            Text(msg)
        }
        .confirmationDialog(
            "Block \(peerToBlock?.username ?? "")?",
            isPresented: Binding(get: { peerToBlock != nil }, set: { if !$0 { peerToBlock = nil } }),
            titleVisibility: .visible
        ) {
            Button("Block", role: .destructive) {
                if let peer = peerToBlock {
                    appState.blockPeer(peerID: peer.id)
                }
                peerToBlock = nil
            }
            Button("Cancel", role: .cancel) { peerToBlock = nil }
        } message: {
            Text("You won't receive messages from this person. This can be undone in Settings.")
        }
    }
}

// MARK: - Group Conversation Row

struct GroupConversationRow: View {
    @EnvironmentObject var appState: AppState
    let group: GroupInfo

    private var lastMessage: StoredMessage? {
        appState.messages[group.conversationID]?.last
    }
    private var unreadCount: Int {
        appState.unreadCounts[group.conversationID] ?? 0
    }

    var body: some View {
        HStack(spacing: 12) {
            // Group avatar
            ZStack {
                Circle()
                    .fill(Color.accentColor.opacity(0.15))
                    .frame(width: 48, height: 48)
                Image(systemName: "person.2.fill")
                    .font(.system(size: 20))
                    .foregroundStyle(.accentColor)
            }

            VStack(alignment: .leading, spacing: 2) {
                HStack {
                    Text(group.name)
                        .font(.subheadline.weight(unreadCount > 0 ? .bold : .semibold))
                    Spacer()
                    if let last = lastMessage {
                        Text(last.timestamp, style: .relative)
                            .font(.caption2)
                            .foregroundStyle(.tertiary)
                    }
                }
                HStack {
                    Text("\(group.memberIDs.count) members")
                        .font(.caption2)
                        .foregroundStyle(.tertiary)
                    if let last = lastMessage {
                        Text("· \(last.body)")
                            .font(.subheadline)
                            .foregroundStyle(unreadCount > 0 ? .primary : .secondary)
                            .fontWeight(unreadCount > 0 ? .medium : .regular)
                            .lineLimit(1)
                    }
                    Spacer()
                    if unreadCount > 0 {
                        Text("\(unreadCount)")
                            .font(.caption2.bold())
                            .foregroundStyle(.white)
                            .padding(.horizontal, 6)
                            .padding(.vertical, 2)
                            .background(Color.accentColor)
                            .clipShape(Capsule())
                    }
                }
            }
        }
        .padding(.vertical, 4)
    }
}

// MARK: - Conversation Row

struct ConversationRow: View {
    @EnvironmentObject var appState: AppState
    let peer: KnownPeer
    let messages: [StoredMessage]
    let unreadCount: Int

    var lastMessage: StoredMessage? { messages.last }

    var body: some View {
        HStack(spacing: 12) {
            PeerAvatar(peer: peer, size: 48)
            VStack(alignment: .leading, spacing: 2) {
                HStack {
                    Text(appState.displayName(for: peer))
                        .font(.subheadline.weight(unreadCount > 0 ? .bold : .semibold))
                    Spacer()
                    if let last = lastMessage {
                        Text(last.timestamp, style: .relative)
                            .font(.caption2)
                            .foregroundStyle(.tertiary)
                    }
                }
                HStack {
                    if let last = lastMessage {
                        if last.direction == .sent {
                            statusIcon(for: last.status)
                        }
                        Text(last.body)
                            .font(.subheadline)
                            .foregroundStyle(unreadCount > 0 ? .primary : .secondary)
                            .fontWeight(unreadCount > 0 ? .medium : .regular)
                            .lineLimit(1)
                    }
                    Spacer()
                    if unreadCount > 0 {
                        Text("\(unreadCount)")
                            .font(.caption2.bold())
                            .foregroundStyle(.white)
                            .padding(.horizontal, 6)
                            .padding(.vertical, 2)
                            .background(Color.accentColor)
                            .clipShape(Capsule())
                    } else if peer.isOnline {
                        Circle().fill(.green).frame(width: 8, height: 8)
                    }
                }
            }
        }
        .padding(.vertical, 4)
    }

    @ViewBuilder
    private func statusIcon(for status: StoredMessage.MessageStatus) -> some View {
        switch status {
        case .sending:
            Image(systemName: "clock").font(.caption2).foregroundStyle(.secondary)
        case .delivered:
            Image(systemName: "checkmark.circle.fill").font(.caption2).foregroundStyle(.green)
        case .read:
            Image(systemName: "checkmark.circle.fill").font(.caption2).foregroundStyle(.accentColor)
        case .failed:
            Image(systemName: "exclamationmark.circle").font(.caption2).foregroundStyle(.red)
        }
    }
}

// MARK: - Peer Row (no messages yet)

struct PeerRow: View {
    @EnvironmentObject var appState: AppState
    let peer: KnownPeer
    let isOnline: Bool

    var body: some View {
        HStack(spacing: 12) {
            PeerAvatar(peer: peer, size: 40)
            VStack(alignment: .leading, spacing: 2) {
                Text(appState.displayName(for: peer))
                    .font(.subheadline.weight(.medium))
                Text("Tap to send a message")
                    .font(.caption)
                    .foregroundStyle(.tertiary)
            }
            Spacer()
            if isOnline {
                Circle().fill(.green).frame(width: 8, height: 8)
            }
        }
    }
}

// MARK: - Peer Avatar

struct PeerAvatar: View {
    let peer: KnownPeer
    let size: CGFloat

    private var avatarColor: Color {
        let hash = peer.id.prefix(6)
        let value = Int(hash, radix: 16) ?? 0
        let hue = Double(value % 360) / 360.0
        return Color(hue: hue, saturation: 0.6, brightness: 0.8)
    }

    private var initials: String {
        peer.username.prefix(1).uppercased()
    }

    var body: some View {
        ZStack {
            Circle()
                .fill(avatarColor.opacity(0.2))
                .frame(width: size, height: size)
            Text(initials)
                .font(.system(size: size * 0.4, weight: .semibold))
                .foregroundStyle(avatarColor)
        }
    }
}

#Preview {
    ChatListView().environmentObject(AppState())
}
