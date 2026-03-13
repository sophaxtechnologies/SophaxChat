// GroupChatView.swift
// SophaxChat
//
// Chat view for an encrypted group conversation.

import SwiftUI
import SophaxChatCore
import PhotosUI
import AVFoundation

struct GroupChatView: View {
    @EnvironmentObject var appState: AppState
    @Environment(\.dismiss) private var dismiss
    let group: GroupInfo

    @State private var messageText: String = ""
    @FocusState private var isInputFocused: Bool

    // Attachment / camera
    @State private var photoPickerItem: PhotosPickerItem? = nil
    @State private var showingCamera       = false

    // PTT recording
    @StateObject private var voiceRecorder = VoiceRecorder()

    // UI state
    @State private var showingMemberList   = false
    @State private var showingLeaveConfirm = false

    private var messages: [StoredMessage] {
        appState.messages[group.conversationID] ?? []
    }

    var body: some View {
        VStack(spacing: 0) {
            // Message list
            ScrollViewReader { proxy in
                ScrollView {
                    LazyVStack(spacing: 8) {
                        ForEach(messages) { message in
                            GroupMessageBubble(message: message, group: group)
                        }
                        Color.clear.frame(height: 1).id("bottom")
                    }
                    .padding(.horizontal, 16)
                    .padding(.top, 8)
                    .padding(.bottom, 12)
                }
                .onChange(of: messages.count) { _, _ in
                    withAnimation { proxy.scrollTo("bottom", anchor: .bottom) }
                }
                .onAppear {
                    proxy.scrollTo("bottom", anchor: .bottom)
                    appState.markGroupAsRead(group: group)
                }
                .onChange(of: messages.count) { _, _ in
                    appState.markGroupAsRead(group: group)
                }
            }

            Divider()

            // Input bar
            HStack(spacing: 10) {
                // Attachment button
                PhotosPicker(selection: $photoPickerItem, matching: .images) {
                    Image(systemName: "photo")
                        .font(.system(size: 22))
                        .foregroundStyle(.secondary)
                }
                .onChange(of: photoPickerItem) { _, item in
                    guard let item else { return }
                    Task {
                        if let data = try? await item.loadTransferable(type: Data.self),
                           let image = UIImage(data: data) {
                            appState.sendGroupImage(image, group: group)
                        }
                        photoPickerItem = nil
                    }
                }

                // Hold-to-record PTT button
                ZStack {
                    Circle()
                        .fill(voiceRecorder.isRecording ? Color.red.opacity(0.15) : Color.clear)
                        .frame(width: 36, height: 36)
                        .animation(.easeInOut(duration: 0.2), value: voiceRecorder.isRecording)
                    Image(systemName: voiceRecorder.isRecording ? "waveform" : "mic")
                        .font(.system(size: 20))
                        .foregroundStyle(voiceRecorder.isRecording ? .red : .secondary)
                        .symbolEffect(.pulse, isActive: voiceRecorder.isRecording)
                }
                .frame(width: 36, height: 36)
                .contentShape(Rectangle())
                .gesture(
                    DragGesture(minimumDistance: 0)
                        .onChanged { _ in
                            guard !voiceRecorder.isRecording else { return }
                            voiceRecorder.start()
                        }
                        .onEnded { _ in
                            voiceRecorder.stop { data, duration in
                                guard let data, duration > 0.5 else { return }
                                appState.sendGroupAudio(data, duration: duration, group: group)
                            }
                        }
                )

                TextField("Message", text: $messageText, axis: .vertical)
                    .textFieldStyle(.plain)
                    .font(.body)
                    .lineLimit(1...6)
                    .focused($isInputFocused)

                if !messageText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                    Button(action: sendMessage) {
                        Image(systemName: "arrow.up.circle.fill")
                            .font(.system(size: 30))
                            .foregroundStyle(Color.accentColor)
                    }
                    .transition(.scale.combined(with: .opacity))
                }
            }
            .animation(.easeInOut(duration: 0.15),
                       value: !messageText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            .padding(.horizontal, 16)
            .padding(.vertical, 10)
            .background(.bar)
        }
        .navigationTitle(group.name)
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Menu {
                    Button {
                        showingMemberList = true
                    } label: {
                        Label("Members (\(group.memberIDs.count))", systemImage: "person.2")
                    }
                    Divider()
                    Button(role: .destructive) {
                        showingLeaveConfirm = true
                    } label: {
                        Label("Leave Group", systemImage: "rectangle.portrait.and.arrow.right")
                    }
                } label: {
                    VStack(spacing: 0) {
                        Image(systemName: "person.2")
                            .font(.caption2)
                        Text("\(group.memberIDs.count)")
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                    }
                }
            }
        }
        .sheet(isPresented: $showingMemberList) {
            GroupMemberListView(group: group)
                .environmentObject(appState)
        }
        .confirmationDialog(
            "Leave \"\(group.name)\"?",
            isPresented: $showingLeaveConfirm,
            titleVisibility: .visible
        ) {
            Button("Leave Group", role: .destructive) {
                appState.leaveGroup(group)
                dismiss()
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("You will no longer receive messages from this group. This cannot be undone.")
        }
    }

    private func sendMessage() {
        let text = messageText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return }
        messageText = ""
        appState.sendGroupMessage(text, group: group)
    }
}

// MARK: - Group Member List Sheet

private struct GroupMemberListView: View {
    @EnvironmentObject var appState: AppState
    @Environment(\.dismiss) private var dismiss
    let group: GroupInfo

    private var myPeerID: String {
        // best effort; fine if unavailable
        (appState.chatManager?.identity.publicIdentity.peerID) ?? ""
    }

    var body: some View {
        NavigationStack {
            List {
                Section {
                    ForEach(group.memberIDs, id: \.self) { peerID in
                        HStack(spacing: 12) {
                            if let peer = appState.peers.first(where: { $0.id == peerID }) {
                                PeerAvatar(peer: peer, size: 36)
                            } else {
                                Circle()
                                    .fill(Color.secondary.opacity(0.2))
                                    .frame(width: 36, height: 36)
                                    .overlay {
                                        Image(systemName: "person")
                                            .font(.system(size: 14))
                                            .foregroundStyle(.secondary)
                                    }
                            }

                            VStack(alignment: .leading, spacing: 1) {
                                HStack(spacing: 4) {
                                    Text(appState.displayName(forPeerID: peerID))
                                        .font(.subheadline.weight(.medium))
                                    if peerID == group.creatorID {
                                        Text("Creator")
                                            .font(.caption2)
                                            .foregroundStyle(.secondary)
                                            .padding(.horizontal, 5)
                                            .padding(.vertical, 1)
                                            .background(Color.secondary.opacity(0.15))
                                            .clipShape(Capsule())
                                    }
                                    if peerID == myPeerID {
                                        Text("You")
                                            .font(.caption2)
                                            .foregroundStyle(.accentColor)
                                            .padding(.horizontal, 5)
                                            .padding(.vertical, 1)
                                            .background(Color.accentColor.opacity(0.1))
                                            .clipShape(Capsule())
                                    }
                                }
                                if appState.onlinePeers.contains(peerID) {
                                    Text("Online")
                                        .font(.caption2)
                                        .foregroundStyle(.green)
                                }
                            }
                        }
                        .padding(.vertical, 2)
                    }
                } header: {
                    Text("\(group.memberIDs.count) Members")
                }
            }
            .navigationTitle(group.name)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") { dismiss() }
                }
            }
        }
    }
}

// MARK: - Group Message Bubble

private struct GroupMessageBubble: View {
    @EnvironmentObject var appState: AppState
    let message: StoredMessage
    let group: GroupInfo

    private var isSent: Bool { message.direction == .sent }

    private var senderName: String {
        guard let senderID = message.senderID else { return "" }
        return appState.displayName(forPeerID: senderID)
    }

    var body: some View {
        HStack {
            if isSent { Spacer(minLength: 60) }

            VStack(alignment: isSent ? .trailing : .leading, spacing: 2) {
                // Sender name (only for received messages in groups)
                if !isSent && !senderName.isEmpty {
                    Text(senderName)
                        .font(.caption2.bold())
                        .foregroundStyle(.accentColor)
                        .padding(.horizontal, 4)
                }

                VStack(alignment: isSent ? .trailing : .leading, spacing: 6) {
                    groupBubbleContent
                }
                .contextMenu {
                    Button {
                        UIPasteboard.general.string = message.body
                    } label: {
                        Label("Copy", systemImage: "doc.on.doc")
                    }
                }

                Text(message.timestamp, style: .time)
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
            }

            if !isSent { Spacer(minLength: 60) }
        }
    }

    @ViewBuilder
    private var groupBubbleContent: some View {
        let mime = message.attachmentMimeType ?? ""
        if let id = message.attachmentID, mime.hasPrefix("image/"),
           let data = appState.loadAttachment(id: id),
           let uiImage = UIImage(data: data) {
            // Image attachment
            Image(uiImage: uiImage)
                .resizable()
                .scaledToFill()
                .frame(maxWidth: 220, maxHeight: 180)
                .clipShape(RoundedRectangle(cornerRadius: 14))
            if !message.body.isEmpty {
                Text(message.body)
                    .font(.subheadline)
                    .foregroundStyle(isSent ? .white : .primary)
                    .padding(.horizontal, 14).padding(.vertical, 8)
                    .background(isSent ? Color.accentColor : Color(.secondarySystemGroupedBackground))
                    .clipShape(RoundedRectangle(cornerRadius: 14))
            }
        } else if mime.hasPrefix("audio/") {
            // Audio attachment
            HStack(spacing: 6) {
                Image(systemName: "waveform").font(.body)
                if let dur = message.audioDuration { Text(formatDuration(dur)).font(.subheadline) }
            }
            .foregroundStyle(isSent ? .white : .primary)
            .padding(.horizontal, 14).padding(.vertical, 10)
            .background(isSent ? Color.accentColor : Color(.secondarySystemGroupedBackground))
            .clipShape(RoundedRectangle(cornerRadius: 18))
        } else {
            // Plain text
            Text(message.body)
                .font(.body)
                .foregroundStyle(isSent ? .white : .primary)
                .padding(.horizontal, 14).padding(.vertical, 10)
                .background(isSent ? Color.accentColor : Color(.secondarySystemGroupedBackground))
                .clipShape(RoundedRectangle(cornerRadius: 18))
        }
    }

    private func formatDuration(_ seconds: Double) -> String {
        let s = Int(seconds)
        return String(format: "%d:%02d", s / 60, s % 60)
    }
}

#Preview {
    NavigationStack {
        GroupChatView(group: GroupInfo(
            name: "Test Group",
            memberIDs: ["alice", "bob"],
            creatorID: "alice"
        ))
        .environmentObject(AppState())
    }
}
