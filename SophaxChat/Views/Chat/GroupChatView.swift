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

    // Disappearing messages
    @State private var disappearingInterval: DisappearingInterval = .off
    private var disappearingKey: String { "com.sophax.disappearingInterval.group.\(group.id)" }

    // Attachment / camera
    @State private var photoPickerItem: PhotosPickerItem? = nil
    @State private var showingCamera       = false

    // PTT recording
    @StateObject private var voiceRecorder = VoiceRecorder()

    // Reply
    @State private var replyingTo: StoredMessage? = nil

    // UI state
    @State private var showingMemberList   = false
    @State private var showingLeaveConfirm = false

    private var messages: [StoredMessage] {
        appState.messages[group.conversationID] ?? []
    }

    private var memberCount: Int { group.memberIDs.count }

    var body: some View {
        VStack(spacing: 0) {
            // Message list
            ScrollViewReader { proxy in
                ScrollView {
                    LazyVStack(spacing: 8) {
                        ForEach(messages) { message in
                            GroupMessageBubble(
                                message:    message,
                                group:      group,
                                replyingTo: messages.first { $0.id == message.replyToID },
                                onReply:    { withAnimation { replyingTo = message } }
                            )
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
                    if let saved = UserDefaults.standard.string(forKey: disappearingKey),
                       let interval = DisappearingInterval(rawValue: saved) {
                        disappearingInterval = interval
                    }
                }
                .onChange(of: messages.count) { _, _ in
                    appState.markGroupAsRead(group: group)
                }
            }

            // Disappearing messages indicator
            if disappearingInterval != .off {
                HStack(spacing: 4) {
                    Image(systemName: "timer").font(.caption2)
                    Text("Messages disappear after \(disappearingInterval.rawValue.lowercased())")
                        .font(.caption2)
                }
                .foregroundStyle(.orange)
                .padding(.horizontal, 16)
                .padding(.top, 6)
            }

            Divider()

            replyPreviewBar

            inputBar
        }
        .navigationTitle(group.name)
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                // Disappearing messages timer
                Menu {
                    ForEach(DisappearingInterval.allCases) { interval in
                        Button {
                            disappearingInterval = interval
                            UserDefaults.standard.set(interval.rawValue, forKey: disappearingKey)
                        } label: {
                            if disappearingInterval == interval {
                                Label(interval.rawValue, systemImage: "checkmark")
                            } else {
                                Text(interval.rawValue)
                            }
                        }
                    }
                } label: {
                    Image(systemName: disappearingInterval.icon)
                        .foregroundStyle(disappearingInterval == .off ? .primary : .orange)
                }
            }
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

    // MARK: - Sub-views (extracted to keep body type-checkable)

    @ViewBuilder
    private var replyPreviewBar: some View {
        if let replying = replyingTo {
            HStack(spacing: 10) {
                Rectangle()
                    .fill(Color.accentColor)
                    .frame(width: 3)
                    .clipShape(Capsule())
                VStack(alignment: .leading, spacing: 2) {
                    Text(replying.direction == .sent
                         ? "Reply to yourself"
                         : "Reply to \(appState.displayName(forPeerID: replying.senderID ?? ""))")
                        .font(.caption.bold())
                        .foregroundStyle(Color.accentColor)
                    Text(replying.body)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
                Spacer()
                Button { withAnimation { replyingTo = nil } } label: {
                    Image(systemName: "xmark.circle.fill").foregroundStyle(.tertiary)
                }
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 8)
            .background(.bar)
            .transition(.move(edge: .bottom).combined(with: .opacity))
        }
    }

    @ViewBuilder
    private var pttButton: some View {
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
                        let expiresAt = disappearingInterval.seconds.map { Date().addingTimeInterval($0) }
                        appState.sendGroupAudio(data, duration: duration, group: group,
                                                expiresAt: expiresAt, replyToID: replyingTo?.id)
                        replyingTo = nil
                    }
                }
        )
    }

    private var inputBar: some View {
        let isTextNonEmpty = !messageText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        return HStack(spacing: 10) {
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
                        let expiresAt = disappearingInterval.seconds.map { Date().addingTimeInterval($0) }
                        appState.sendGroupImage(image, group: group, expiresAt: expiresAt, replyToID: replyingTo?.id)
                        replyingTo = nil
                    }
                    photoPickerItem = nil
                }
            }
            pttButton
            TextField("Message", text: $messageText, axis: .vertical)
                .textFieldStyle(.plain)
                .font(.body)
                .lineLimit(1...6)
                .focused($isInputFocused)
            if isTextNonEmpty {
                Button(action: sendMessage) {
                    Image(systemName: "arrow.up.circle.fill")
                        .font(.system(size: 30))
                        .foregroundStyle(Color.accentColor)
                }
                .transition(.scale.combined(with: .opacity))
            }
        }
        .animation(.easeInOut(duration: 0.15), value: isTextNonEmpty)
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
        .background(.bar)
    }

    private func sendMessage() {
        let text = messageText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return }
        messageText = ""
        let expiresAt = disappearingInterval.seconds.map { Date().addingTimeInterval($0) }
        appState.sendGroupMessage(text, group: group, expiresAt: expiresAt, replyToID: replyingTo?.id)
        replyingTo = nil
    }
}

// MARK: - Group Member List Sheet

private struct GroupMemberListView: View {
    @EnvironmentObject var appState: AppState
    @Environment(\.dismiss) private var dismiss
    let group: GroupInfo

    private var myPeerID: String {
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
                                            .foregroundStyle(Color.accentColor)
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
    let message:    StoredMessage
    let group:      GroupInfo
    let replyingTo: StoredMessage?   // quoted message (nil if not a reply)
    let onReply:    () -> Void

    private var isSent: Bool { message.direction == .sent }

    private var senderName: String {
        guard let senderID = message.senderID else { return "" }
        return appState.displayName(forPeerID: senderID)
    }

    var body: some View {
        HStack {
            if isSent { Spacer(minLength: 60) }

            VStack(alignment: isSent ? .trailing : .leading, spacing: 2) {
                // Sender name (only for received messages)
                if !isSent && !senderName.isEmpty {
                    Text(senderName)
                        .font(.caption2.bold())
                        .foregroundStyle(Color.accentColor)
                        .padding(.horizontal, 4)
                }

                VStack(alignment: isSent ? .trailing : .leading, spacing: 4) {
                    // Quoted reply preview
                    if let quoted = replyingTo {
                        QuotedBubble(message: quoted, isSentContext: isSent)
                    }

                    groupBubbleContent
                }
                .contextMenu {
                    Button {
                        withAnimation { onReply() }
                    } label: {
                        Label("Reply", systemImage: "arrowshape.turn.up.left")
                    }
                    Button {
                        UIPasteboard.general.string = message.body
                    } label: {
                        Label("Copy", systemImage: "doc.on.doc")
                    }
                    Divider()
                    ForEach(["👍", "❤️", "😂", "😮", "😢", "👎"], id: \.self) { emoji in
                        Button {
                            let myID = appState.chatManager?.identity.publicIdentity.peerID ?? ""
                            let current = message.reactions?[myID]
                            appState.sendGroupReaction(
                                emoji: current == emoji ? nil : emoji,
                                messageID: message.id,
                                group: group
                            )
                        } label: {
                            let myID = appState.chatManager?.identity.publicIdentity.peerID ?? ""
                            if message.reactions?[myID] == emoji {
                                Label(emoji, systemImage: "checkmark")
                            } else {
                                Text(emoji)
                            }
                        }
                    }
                }

                // Reaction pills
                if let reactions = message.reactions, !reactions.isEmpty {
                    ReactionPillRow(reactions: reactions)
                }

                // Timestamp + delivery status footer
                HStack(spacing: 4) {
                    Text(message.timestamp, style: .time)
                        .font(.caption2)
                        .foregroundStyle(.tertiary)
                    if isSent {
                        Image(systemName: "checkmark")
                            .font(.caption2)
                            .foregroundStyle(.tertiary)
                        Text("→ \(group.memberIDs.count - 1)")
                            .font(.caption2)
                            .foregroundStyle(.tertiary)
                    }
                }
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
            HStack(spacing: 6) {
                Image(systemName: "waveform").font(.body)
                if let dur = message.audioDuration { Text(formatDuration(dur)).font(.subheadline) }
            }
            .foregroundStyle(isSent ? .white : .primary)
            .padding(.horizontal, 14).padding(.vertical, 10)
            .background(isSent ? Color.accentColor : Color(.secondarySystemGroupedBackground))
            .clipShape(RoundedRectangle(cornerRadius: 18))
        } else {
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

// MARK: - Quoted bubble (reply preview)

private struct QuotedBubble: View {
    let message:       StoredMessage
    let isSentContext: Bool

    var body: some View {
        HStack(spacing: 6) {
            Rectangle()
                .fill(Color.accentColor)
                .frame(width: 2)
                .clipShape(Capsule())
            Text(message.body.isEmpty ? "Attachment" : message.body)
                .font(.caption)
                .foregroundStyle(.secondary)
                .lineLimit(2)
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 6)
        .background(Color(.tertiarySystemGroupedBackground))
        .clipShape(RoundedRectangle(cornerRadius: 10))
    }
}

// MARK: - Reaction pill row (reused from 1:1)

private struct ReactionPillRow: View {
    let reactions: [String: String]

    private var counts: [(emoji: String, count: Int)] {
        var tally: [String: Int] = [:]
        for emoji in reactions.values { tally[emoji, default: 0] += 1 }
        return tally.map { ($0.key, $0.value) }.sorted { $0.count > $1.count }
    }

    var body: some View {
        HStack(spacing: 4) {
            ForEach(counts, id: \.emoji) { item in
                HStack(spacing: 2) {
                    Text(item.emoji).font(.caption)
                    if item.count > 1 {
                        Text("\(item.count)").font(.caption2).foregroundStyle(.secondary)
                    }
                }
                .padding(.horizontal, 7)
                .padding(.vertical, 3)
                .background(Color(.tertiarySystemGroupedBackground))
                .clipShape(Capsule())
            }
        }
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
