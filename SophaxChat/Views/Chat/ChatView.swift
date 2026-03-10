// ChatView.swift
// SophaxChat
//
// Individual conversation view with end-to-end encrypted messaging.

import SwiftUI
import SophaxChatCore
import CoreImage.CIFilterBuiltins

// MARK: - Disappearing messages interval

enum DisappearingInterval: String, CaseIterable, Identifiable {
    case off      = "Off"
    case thirtySeconds = "30 seconds"
    case fiveMinutes   = "5 minutes"
    case oneHour       = "1 hour"
    case oneDay        = "24 hours"
    case oneWeek       = "7 days"

    var id: String { rawValue }

    var seconds: TimeInterval? {
        switch self {
        case .off:           return nil
        case .thirtySeconds: return 30
        case .fiveMinutes:   return 5 * 60
        case .oneHour:       return 60 * 60
        case .oneDay:        return 24 * 60 * 60
        case .oneWeek:       return 7 * 24 * 60 * 60
        }
    }

    var icon: String {
        self == .off ? "timer" : "timer.circle.fill"
    }
}

struct ChatView: View {
    @EnvironmentObject var appState: AppState
    @Environment(\.dismiss) private var dismiss
    let peer: KnownPeer

    @State private var messageText: String = ""
    @State private var showingSafetyNumber = false
    @State private var showingBlockConfirm = false
    @State private var disappearingInterval: DisappearingInterval = .off
    @State private var typingTask: Task<Void, Never>? = nil
    @FocusState private var isInputFocused: Bool
    @Namespace private var bottomAnchor

    private var disappearingKey: String { "com.sophax.disappearingInterval.\(peer.id)" }

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
                            MessageBubbleView(message: message, onDelete: {
                                appState.deleteMessage(message)
                            })
                            .id(message.id)
                        }
                        // Typing indicator bubble
                        if appState.typingPeers.contains(peer.id) {
                            TypingBubbleView()
                                .id("typing-indicator")
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
                .onChange(of: appState.typingPeers.contains(peer.id)) { _, isTyping in
                    if isTyping {
                        withAnimation {
                            proxy.scrollTo("bottom", anchor: .bottom)
                        }
                    }
                }
                .onAppear {
                    proxy.scrollTo("bottom", anchor: .bottom)
                    appState.markAsRead(peerID: peer.id)
                    if let saved = UserDefaults.standard.string(forKey: disappearingKey),
                       let interval = DisappearingInterval(rawValue: saved) {
                        disappearingInterval = interval
                    }
                }
                .onChange(of: messages.count) { _, _ in
                    appState.markAsRead(peerID: peer.id)
                }
            }

            Divider()

            // Disappearing messages indicator
            if disappearingInterval != .off {
                HStack(spacing: 4) {
                    Image(systemName: "timer")
                        .font(.caption2)
                    Text("Messages disappear after \(disappearingInterval.rawValue.lowercased())")
                        .font(.caption2)
                }
                .foregroundStyle(.orange)
                .padding(.horizontal, 16)
                .padding(.top, 6)
            }

            // Input bar
            HStack(spacing: 12) {
                TextField("Message", text: $messageText, axis: .vertical)
                    .textFieldStyle(.plain)
                    .font(.body)
                    .lineLimit(1...6)
                    .focused($isInputFocused)
                    .onChange(of: messageText) { _, newValue in
                        let nonEmpty = !newValue.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                        if nonEmpty {
                            appState.sendTypingIndicator(toPeerID: peer.id, isTyping: true)
                            typingTask?.cancel()
                            typingTask = Task { @MainActor in
                                try? await Task.sleep(for: .seconds(5))
                                appState.sendTypingIndicator(toPeerID: peer.id, isTyping: false)
                                typingTask = nil
                            }
                        } else {
                            typingTask?.cancel()
                            typingTask = nil
                            appState.sendTypingIndicator(toPeerID: peer.id, isTyping: false)
                        }
                    }

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

                    // Disappearing messages
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

                    // Safety number + more actions
                    Menu {
                        Button {
                            showingSafetyNumber = true
                        } label: {
                            Label("Verify Identity", systemImage: "checkmark.shield")
                        }
                        Divider()
                        Button(role: .destructive) {
                            showingBlockConfirm = true
                        } label: {
                            Label("Block \(peer.username)", systemImage: "nosign")
                        }
                    } label: {
                        Image(systemName: "ellipsis.circle")
                    }
                }
            }
        }
        .sheet(isPresented: $showingSafetyNumber) {
            SafetyNumberView(peer: peer)
        }
        .confirmationDialog(
            "Block \(peer.username)?",
            isPresented: $showingBlockConfirm,
            titleVisibility: .visible
        ) {
            Button("Block", role: .destructive) {
                appState.blockPeer(peerID: peer.id)
                dismiss()
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("You won't receive messages from this person.")
        }
    }

    private var canSend: Bool {
        !messageText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    private func sendMessage() {
        let text = messageText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return }
        // Stop typing indicator immediately on send
        typingTask?.cancel()
        typingTask = nil
        appState.sendTypingIndicator(toPeerID: peer.id, isTyping: false)
        messageText = ""
        let expiresAt = disappearingInterval.seconds.map { Date().addingTimeInterval($0) }
        appState.sendMessage(text, toPeerID: peer.id, expiresAt: expiresAt)
    }
}

// MARK: - Typing Bubble

private struct TypingBubbleView: View {
    @State private var phase = 0

    var body: some View {
        HStack(spacing: 4) {
            ForEach(0..<3, id: \.self) { i in
                Circle()
                    .fill(Color.secondary.opacity(phase == i ? 1.0 : 0.3))
                    .frame(width: 7, height: 7)
                    .offset(y: phase == i ? -3 : 0)
                    .animation(.easeInOut(duration: 0.35), value: phase)
            }
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 12)
        .background(Color(.systemGray5))
        .clipShape(RoundedRectangle(cornerRadius: 18))
        .frame(maxWidth: .infinity, alignment: .leading)
        .task {
            while !Task.isCancelled {
                for i in 0..<3 {
                    phase = i
                    try? await Task.sleep(for: .milliseconds(350))
                }
            }
        }
    }
}

// MARK: - Safety Number View

struct SafetyNumberView: View {
    @Environment(\.dismiss) private var dismiss
    @EnvironmentObject var appState: AppState
    let peer: KnownPeer

    @State private var showingMyQR   = false
    @State private var showingPeerQR = false

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
                        color: .blue,
                        onShowQR: { showingPeerQR = true }
                    )

                    // Your number
                    if let mine = mySafetyNumber {
                        SafetyNumberBlock(
                            label: "Your number",
                            sublabel: "You read this to them",
                            safetyNumber: mine,
                            color: .green,
                            onShowQR: { showingMyQR = true }
                        )
                        .sheet(isPresented: $showingMyQR) {
                            QRSheet(title: "Your Safety Number", safetyNumber: mine)
                        }
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
            .sheet(isPresented: $showingPeerQR) {
                QRSheet(title: "\(peer.username)'s Safety Number", safetyNumber: peer.safetyNumber)
            }
        }
    }
}

private struct QRSheet: View {
    @Environment(\.dismiss) private var dismiss
    let title: String
    let safetyNumber: String

    var body: some View {
        NavigationStack {
            VStack(spacing: 24) {
                QRCodeView(safetyNumber: safetyNumber)
                    .padding(.top, 24)
                Text("Scan this with the other device to compare safety numbers.")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                    .padding(.horizontal)
            }
            .navigationTitle(title)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") { dismiss() }
                }
            }
        }
    }
}

// MARK: - QR Code generator

private struct QRCodeView: View {
    let safetyNumber: String

    private var qrImage: Image? {
        let context = CIContext()
        let filter  = CIFilter.qrCodeGenerator()
        filter.message = Data(safetyNumber.utf8)
        filter.correctionLevel = "H"
        guard let output = filter.outputImage else { return nil }
        // Scale up so it renders crisp
        let scaled = output.transformed(by: CGAffineTransform(scaleX: 10, y: 10))
        guard let cgImage = context.createCGImage(scaled, from: scaled.extent) else { return nil }
        return Image(decorative: cgImage, scale: 1)
    }

    var body: some View {
        if let img = qrImage {
            img
                .interpolation(.none)
                .resizable()
                .scaledToFit()
                .frame(width: 200, height: 200)
                .padding(12)
                .background(.white)
                .clipShape(RoundedRectangle(cornerRadius: 12))
        }
    }
}

private struct SafetyNumberBlock: View {
    let label: String
    let sublabel: String
    let safetyNumber: String
    let color: Color
    let onShowQR: () -> Void

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
                Button(action: onShowQR) {
                    Image(systemName: "qrcode")
                        .foregroundStyle(color)
                }
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
