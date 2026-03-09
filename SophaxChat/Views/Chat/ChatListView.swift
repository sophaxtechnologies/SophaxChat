// ChatListView.swift
// SophaxChat
//
// Main screen: list of conversations + nearby peers.

import SwiftUI
import SophaxChatCore

struct ChatListView: View {
    @EnvironmentObject var appState: AppState
    @State private var showingIdentity = false

    var body: some View {
        NavigationStack {
            List {
                // Active conversations (peers with messages)
                let conversationPeers = appState.peers.filter {
                    appState.messages[$0.id] != nil
                }
                if !conversationPeers.isEmpty {
                    Section("Conversations") {
                        ForEach(conversationPeers) { peer in
                            NavigationLink(destination: ChatView(peer: peer)) {
                                ConversationRow(peer: peer, messages: appState.messages[peer.id] ?? [])
                            }
                        }
                    }
                }

                // Online peers without conversations yet
                let newPeers = appState.peers.filter {
                    appState.messages[$0.id] == nil && appState.onlinePeers.contains($0.id)
                }
                if !newPeers.isEmpty {
                    Section("Nearby") {
                        ForEach(newPeers) { peer in
                            NavigationLink(destination: ChatView(peer: peer)) {
                                PeerRow(peer: peer, isOnline: true)
                            }
                        }
                    }
                }

                // Empty state
                if appState.peers.isEmpty {
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
                    Button {
                        showingIdentity = true
                    } label: {
                        Image(systemName: "person.crop.circle")
                    }
                }
            }
            .refreshable {
                // MeshManager auto-discovers — nothing to refresh
            }
        }
        .sheet(isPresented: $showingIdentity) {
            IdentityView()
        }
        .alert("Error", isPresented: Binding(
            get: { appState.errorMessage != nil },
            set: { if !$0 { appState.errorMessage = nil } }
        ), presenting: appState.errorMessage) { _ in
            Button("OK") { appState.errorMessage = nil }
        } message: { msg in
            Text(msg)
        }
    }
}

// MARK: - Conversation Row

struct ConversationRow: View {
    let peer: KnownPeer
    let messages: [StoredMessage]

    var lastMessage: StoredMessage? { messages.last }

    var body: some View {
        HStack(spacing: 12) {
            PeerAvatar(peer: peer, size: 48)
            VStack(alignment: .leading, spacing: 2) {
                HStack {
                    Text(peer.username)
                        .font(.subheadline.weight(.semibold))
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
                            Image(systemName: last.status == .delivered ? "checkmark.circle.fill" : "clock")
                                .font(.caption2)
                                .foregroundStyle(last.status == .delivered ? .green : .secondary)
                        }
                        Text(last.body)
                            .font(.subheadline)
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                    }
                    Spacer()
                    if peer.isOnline {
                        Circle().fill(.green).frame(width: 8, height: 8)
                    }
                }
            }
        }
        .padding(.vertical, 4)
    }
}

// MARK: - Peer Row (no messages yet)

struct PeerRow: View {
    let peer: KnownPeer
    let isOnline: Bool

    var body: some View {
        HStack(spacing: 12) {
            PeerAvatar(peer: peer, size: 40)
            VStack(alignment: .leading, spacing: 2) {
                Text(peer.username)
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

    /// Generate a deterministic color from the peer's identity hash.
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
