// MessageBubbleView.swift
// SophaxChat
//
// Individual message bubble. Renders text, image, and audio content.
// Supports quoted replies, delivery/read status, and context menu actions.

import SwiftUI
import UIKit
import SophaxChatCore

struct MessageBubbleView: View {
    @EnvironmentObject var appState: AppState

    let message:  StoredMessage
    var onDelete: (() -> Void)? = nil
    var onReply:  (() -> Void)? = nil

    @State private var attachmentData:    Data?    = nil
    @State private var showFullScreen:    Bool     = false

    private var isSent: Bool { message.direction == .sent }

    // Look up the message being replied to (if any)
    private var quotedMessage: StoredMessage? {
        guard let id = message.replyToID else { return nil }
        return appState.messages[message.peerID]?.first { $0.id == id }
    }

    var body: some View {
        HStack {
            if isSent { Spacer(minLength: 60) }

            VStack(alignment: isSent ? .trailing : .leading, spacing: 3) {
                // ── Quoted reply (shown above the bubble) ─────────────────────
                if let quoted = quotedMessage {
                    quotedPreviewView(for: quoted)
                        .padding(isSent ? .leading : .trailing, 20)
                }

                // ── Main content ──────────────────────────────────────────────
                contentBubble
                    .contextMenu {
                        if let onReply {
                            Button(action: onReply) {
                                Label("Reply", systemImage: "arrowshape.turn.up.left")
                            }
                            Divider()
                        }
                        Button {
                            UIPasteboard.general.string = message.body
                        } label: {
                            Label("Copy", systemImage: "doc.on.doc")
                        }
                        if let onDelete {
                            Divider()
                            Button(role: .destructive, action: onDelete) {
                                Label("Delete", systemImage: "trash")
                            }
                        }
                    }

                // ── Timestamp + relay hop + status ────────────────────────────
                HStack(spacing: 4) {
                    Text(message.timestamp, style: .time)
                        .font(.caption2)
                        .foregroundStyle(.tertiary)

                    if let hops = message.hopCount, hops > 0 {
                        Label("\(hops)", systemImage: "arrow.triangle.branch")
                            .font(.caption2)
                            .foregroundStyle(.tertiary)
                            .help("Delivered via \(hops) relay hop\(hops == 1 ? "" : "s")")
                    }

                    if isSent { statusIcon }
                }
            }

            if !isSent { Spacer(minLength: 60) }
        }
        .task(id: message.attachmentID) {
            guard let id = message.attachmentID else { return }
            attachmentData = appState.loadAttachment(id: id)
        }
        .sheet(isPresented: $showFullScreen) {
            if let data = attachmentData {
                FullScreenImageView(imageData: data)
            }
        }
    }

    // MARK: - Quoted preview

    @ViewBuilder
    private func quotedPreviewView(for quoted: StoredMessage) -> some View {
        let senderName = quoted.direction == .sent
            ? "You"
            : (appState.peers.first(where: { $0.id == quoted.peerID })
                .map { appState.displayName(for: $0) } ?? "Unknown")

        HStack(spacing: 6) {
            Rectangle()
                .fill(isSent ? Color.white.opacity(0.6) : Color.accentColor)
                .frame(width: 3)
                .clipShape(Capsule())
            VStack(alignment: .leading, spacing: 1) {
                Text(senderName)
                    .font(.caption2.bold())
                    .foregroundStyle(isSent ? .white : .accentColor)
                Text(quoted.body)
                    .font(.caption2)
                    .lineLimit(1)
                    .foregroundStyle(isSent ? .white.opacity(0.75) : .secondary)
            }
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 6)
        .background(isSent ? Color.white.opacity(0.15) : Color(.systemGray6))
        .clipShape(RoundedRectangle(cornerRadius: 10))
    }

    // MARK: - Content bubble

    @ViewBuilder
    private var contentBubble: some View {
        if message.attachmentMimeType?.hasPrefix("image/") == true {
            imageBubble
        } else if message.attachmentMimeType?.hasPrefix("audio/") == true {
            audioBubble
        } else {
            textBubble
        }
    }

    // MARK: - Text bubble

    private var textBubble: some View {
        Text(message.body)
            .font(.body)
            .foregroundStyle(isSent ? .white : .primary)
            .padding(.horizontal, 14)
            .padding(.vertical, 10)
            .background(isSent ? Color.accentColor : Color(.secondarySystemGroupedBackground))
            .clipShape(RoundedRectangle(cornerRadius: 18))
    }

    // MARK: - Image bubble

    @ViewBuilder
    private var imageBubble: some View {
        if let data = attachmentData, let uiImage = UIImage(data: data) {
            Image(uiImage: uiImage)
                .resizable()
                .scaledToFill()
                .frame(maxWidth: 220, maxHeight: 200)
                .clipped()
                .clipShape(RoundedRectangle(cornerRadius: 14))
                .overlay(
                    RoundedRectangle(cornerRadius: 14)
                        .stroke(isSent ? Color.accentColor.opacity(0.4) : Color.secondary.opacity(0.2), lineWidth: 1)
                )
                .onTapGesture { showFullScreen = true }
                .overlay(alignment: .bottomTrailing) {
                    if !message.body.isEmpty && message.body != "📷 Photo" {
                        Text(message.body)
                            .font(.caption)
                            .foregroundStyle(.white)
                            .padding(6)
                            .background(.black.opacity(0.45))
                            .clipShape(RoundedRectangle(cornerRadius: 8))
                            .padding(6)
                    }
                }
        } else {
            // Placeholder while loading
            RoundedRectangle(cornerRadius: 14)
                .fill(Color(.systemGray5))
                .frame(width: 180, height: 140)
                .overlay {
                    if message.status == .sending {
                        ProgressView()
                    } else {
                        Image(systemName: "photo")
                            .font(.system(size: 32))
                            .foregroundStyle(.tertiary)
                    }
                }
        }
    }

    // MARK: - Audio bubble

    @ViewBuilder
    private var audioBubble: some View {
        if let data = attachmentData {
            AudioMessageView(
                audioData: data,
                duration:  message.audioDuration ?? 0,
                isSent:    isSent
            )
            .frame(minWidth: 200)
            .background(isSent ? Color.accentColor : Color(.secondarySystemGroupedBackground))
            .clipShape(RoundedRectangle(cornerRadius: 18))
        } else {
            HStack(spacing: 8) {
                Image(systemName: "waveform")
                    .foregroundStyle(.tertiary)
                Text("Voice message")
                    .font(.body)
                    .foregroundStyle(isSent ? .white : .primary)
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 10)
            .background(isSent ? Color.accentColor : Color(.secondarySystemGroupedBackground))
            .clipShape(RoundedRectangle(cornerRadius: 18))
        }
    }

    // MARK: - Status icon

    @ViewBuilder
    private var statusIcon: some View {
        switch message.status {
        case .sending:
            Image(systemName: "clock")
                .font(.caption2)
                .foregroundStyle(.tertiary)
        case .delivered:
            Image(systemName: "checkmark.circle.fill")
                .font(.caption2)
                .foregroundStyle(.green)
        case .read:
            Image(systemName: "checkmark.circle.fill")
                .font(.caption2)
                .foregroundStyle(Color.accentColor)
        case .failed:
            Image(systemName: "exclamationmark.circle")
                .font(.caption2)
                .foregroundStyle(.red)
        }
    }
}

#Preview {
    VStack(spacing: 8) {
        MessageBubbleView(message: StoredMessage(
            peerID: "test", direction: .sent, body: "Hey, this is encrypted!",
            status: .delivered
        ))
        MessageBubbleView(message: StoredMessage(
            peerID: "test", direction: .received, body: "Absolutely secure 🔒",
            status: .delivered
        ))
        MessageBubbleView(message: StoredMessage(
            peerID: "test", direction: .sent, body: "Sending...",
            status: .sending
        ))
        MessageBubbleView(message: StoredMessage(
            peerID: "test", direction: .sent, body: "Read!",
            status: .read
        ))
    }
    .padding()
    .environmentObject(AppState())
}
