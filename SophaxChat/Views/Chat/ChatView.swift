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
                    .submitLabel(.send)
                    .onSubmit { sendMessage() }

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
    let peer: KnownPeer

    var body: some View {
        NavigationView {
            VStack(spacing: 24) {
                Image(systemName: "checkmark.shield.fill")
                    .font(.system(size: 56))
                    .foregroundStyle(.green)

                VStack(spacing: 8) {
                    Text("Safety Number")
                        .font(.title2.bold())
                    Text("Verify this number with \(peer.username) over a secure channel (in person, phone call) to confirm their identity.")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                        .multilineTextAlignment(.center)
                        .padding(.horizontal)
                }

                // Display safety number in groups for readability
                let groups = peer.safetyNumber.split(separator: " ")
                LazyVGrid(columns: Array(repeating: .init(.flexible()), count: 3), spacing: 12) {
                    ForEach(Array(groups.enumerated()), id: \.offset) { _, group in
                        Text(group)
                            .font(.system(.body, design: .monospaced).bold())
                            .padding(12)
                            .background(Color(.secondarySystemGroupedBackground))
                            .clipShape(RoundedRectangle(cornerRadius: 8))
                    }
                }
                .padding(.horizontal)

                Text("If these numbers don't match what \(peer.username) shows, do not trust this connection.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                    .padding(.horizontal)

                Spacer()
            }
            .padding(.top, 32)
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
