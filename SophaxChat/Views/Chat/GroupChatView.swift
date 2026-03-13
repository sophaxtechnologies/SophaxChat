// GroupChatView.swift
// SophaxChat
//
// Chat view for an encrypted group conversation.

import SwiftUI
import SophaxChatCore

struct GroupChatView: View {
    @EnvironmentObject var appState: AppState
    @Environment(\.dismiss) private var dismiss
    let group: GroupInfo

    @State private var messageText: String = ""
    @FocusState private var isInputFocused: Bool

    private var messages: [StoredMessage] {
        appState.messages[group.conversationID] ?? []
    }

    private var memberNames: String {
        let names = group.memberIDs.prefix(3).map { appState.displayName(forPeerID: $0) }
        let suffix = group.memberIDs.count > 3 ? " +\(group.memberIDs.count - 3)" : ""
        return names.joined(separator: ", ") + suffix
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

    private func sendMessage() {
        let text = messageText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return }
        messageText = ""
        appState.sendGroupMessage(text, group: group)
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

                Text(message.body)
                    .font(.body)
                    .foregroundStyle(isSent ? .white : .primary)
                    .padding(.horizontal, 14)
                    .padding(.vertical, 10)
                    .background(isSent ? Color.accentColor : Color(.secondarySystemGroupedBackground))
                    .clipShape(RoundedRectangle(cornerRadius: 18))
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
