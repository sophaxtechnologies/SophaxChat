// CreateGroupView.swift
// SophaxChat
//
// Sheet for creating a new encrypted group conversation.
// The creator names the group and selects members from known peers.

import SwiftUI
import SophaxChatCore

struct CreateGroupView: View {
    @EnvironmentObject var appState: AppState
    @Environment(\.dismiss) private var dismiss

    @State private var groupName:        String = ""
    @State private var selectedPeerIDs:  Set<String> = []
    @FocusState private var nameFocused: Bool

    private var canCreate: Bool {
        !groupName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        && !selectedPeerIDs.isEmpty
    }

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    TextField("Group name", text: $groupName)
                        .focused($nameFocused)
                        .autocorrectionDisabled()
                } header: {
                    Text("Group Name")
                }

                Section {
                    if appState.peers.isEmpty {
                        Text("No nearby peers found. Make sure other devices have SophaxChat open.")
                            .foregroundStyle(.secondary)
                            .font(.subheadline)
                    } else {
                        ForEach(appState.peers.filter { !appState.isBlocked($0.id) }) { peer in
                            Button {
                                if selectedPeerIDs.contains(peer.id) {
                                    selectedPeerIDs.remove(peer.id)
                                } else {
                                    selectedPeerIDs.insert(peer.id)
                                }
                            } label: {
                                HStack(spacing: 12) {
                                    PeerAvatar(peer: peer, size: 36)
                                    VStack(alignment: .leading, spacing: 1) {
                                        Text(appState.displayName(for: peer))
                                            .font(.subheadline.weight(.medium))
                                            .foregroundStyle(.primary)
                                        if appState.onlinePeers.contains(peer.id) {
                                            Text("Online")
                                                .font(.caption2)
                                                .foregroundStyle(.green)
                                        }
                                    }
                                    Spacer()
                                    if selectedPeerIDs.contains(peer.id) {
                                        Image(systemName: "checkmark.circle.fill")
                                            .foregroundStyle(.accentColor)
                                    } else {
                                        Image(systemName: "circle")
                                            .foregroundStyle(.tertiary)
                                    }
                                }
                            }
                            .buttonStyle(.plain)
                        }
                    }
                } header: {
                    Text("Add Members")
                } footer: {
                    if !selectedPeerIDs.isEmpty {
                        Text("\(selectedPeerIDs.count) member\(selectedPeerIDs.count == 1 ? "" : "s") selected (plus you)")
                    }
                }
            }
            .navigationTitle("New Group")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Create") {
                        let name = groupName.trimmingCharacters(in: .whitespacesAndNewlines)
                        appState.createGroup(name: name, memberPeerIDs: Array(selectedPeerIDs))
                        dismiss()
                    }
                    .disabled(!canCreate)
                    .fontWeight(.semibold)
                }
            }
            .onAppear { nameFocused = true }
        }
    }
}

#Preview {
    CreateGroupView().environmentObject(AppState())
}
