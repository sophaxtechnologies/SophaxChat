// ChatView.swift
// SophaxChat
//
// Individual conversation view with end-to-end encrypted messaging.

import SwiftUI
import SophaxChatCore

struct ChatView: View {
    @EnvironmentObject var appState: AppState
    let peer: KnownPeer

    @State private var messageText: String = ""
    @State private var showingSafetyNumber = false
    @FocusState private var isInputFocused: Bool
    @Namespace private var bottomAnchor

    private var messages: [StoredMessage] {
        appState.messages[peer.id] ?? []
    }

    private var isOnline: Bool {
        appState.onlinePeers.contains(peer.id)
    }

    var body: some View {
        VStack(spacing: 0) {
            // Message list
            ScrollViewReader { proxy in
                ScrollView {
                    LazyVStack(spacing: 8) {
                        ForEach(messages) { message in
                            MessageBubbleView(message: message)
                                .id(message.id)
                        }
                        // Invisible anchor at the bottom
                        Color.clear.frame(height: 1).id("bottom")
                    }
                    .padding(.horizontal, 16)
                    .padding(.top, 8)
                    .padding(.bottom, 12)
                }
                .onChange(of: messages.count) { _, _ in
                    withAnimation {
                        proxy.scrollTo("bottom", anchor: .bottom)
                    }
                }
                .onAppear {
                    proxy.scrollTo("bottom", anchor: .bottom)
                }
            }

            Divider()

            // Input bar
            HStack(spacing: 12) {
                TextField("Message", text: $messageText, axis: .vertical)
                    .textFieldStyle(.plain)
                    .font(.body)
                    .lineLimit(1...6)
                    .focused($isInputFocused)

                Button(action: sendMessage) {
                    Image(systemName: "arrow.up.circle.fill")
                        .font(.system(size: 30))
                        .foregroundStyle(canSend ? Color.accentColor : Color.accentColor.opacity(0.3))
                }
                .disabled(!canSend)
                .animation(.easeInOut, value: canSend)
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 10)
            .background(.bar)
        }
        .navigationTitle(peer.username)
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                HStack(spacing: 12) {
                    // Online indicator
                    HStack(spacing: 4) {
                        Circle().fill(isOnline ? .green : .gray).frame(width: 8, height: 8)
                        Text(isOnline ? "Online" : "Offline")
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                    }

                    // Safety number
                    Button {
                        showingSafetyNumber = true
                    } label: {
                        Image(systemName: "checkmark.shield")
                    }
                }
            }
        }
        .sheet(isPresented: $showingSafetyNumber) {
            SafetyNumberView(peer: peer)
        }
    }

    private var canSend: Bool {
        !messageText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    private func sendMessage() {
        let text = messageText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return }
        messageText = ""
        appState.sendMessage(text, toPeerID: peer.id)
    }
}

// MARK: - Safety Number View

struct SafetyNumberView: View {
    @Environment(\.dismiss) private var dismiss
    @EnvironmentObject var appState: AppState
    let peer: KnownPeer

    private var mySafetyNumber: String? {
        appState.chatManager?.identity.publicIdentity.safetyNumber
    }

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(spacing: 28) {
                    Image(systemName: "checkmark.shield.fill")
                        .font(.system(size: 48))
                        .foregroundStyle(.green)
                        .padding(.top, 24)

                    Text("Compare both numbers out loud or in person. If they match on both devices, the connection is authentic.")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                        .multilineTextAlignment(.center)
                        .padding(.horizontal)

                    // Their number
                    SafetyNumberBlock(
                        label: "\(peer.username)'s number",
                        sublabel: "They read this to you",
                        safetyNumber: peer.safetyNumber,
                        color: .blue
                    )

                    // Your number
                    if let mine = mySafetyNumber {
                        SafetyNumberBlock(
                            label: "Your number",
                            sublabel: "You read this to them",
                            safetyNumber: mine,
                            color: .green
                        )
                    }

                    Text("If either number doesn't match, someone may be intercepting your messages. Do not continue.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .multilineTextAlignment(.center)
                        .padding(.horizontal)
                        .padding(.bottom, 24)
                }
            }
            .navigationTitle("Verify Identity")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") { dismiss() }
                }
            }
        }
    }
}

private struct SafetyNumberBlock: View {
    let label: String
    let sublabel: String
    let safetyNumber: String
    let color: Color

    var body: some View {
        VStack(spacing: 10) {
            HStack {
                VStack(alignment: .leading, spacing: 2) {
                    Text(label)
                        .font(.subheadline.weight(.semibold))
                    Text(sublabel)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                Spacer()
            }
            .padding(.horizontal)

            let groups = safetyNumber.split(separator: " ")
            LazyVGrid(columns: Array(repeating: .init(.flexible()), count: 3), spacing: 10) {
                ForEach(Array(groups.enumerated()), id: \.offset) { _, group in
                    Text(group)
                        .font(.system(.body, design: .monospaced).bold())
                        .padding(10)
                        .frame(maxWidth: .infinity)
                        .background(color.opacity(0.08))
                        .clipShape(RoundedRectangle(cornerRadius: 8))
                }
            }
            .padding(.horizontal)
        }
    }
}
