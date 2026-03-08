// MessageBubbleView.swift
// SophaxChat
//
// Individual message bubble in the chat view.

import SwiftUI
import SophaxChatCore

struct MessageBubbleView: View {
    let message: StoredMessage

    private var isSent: Bool { message.direction == .sent }

    var body: some View {
        HStack {
            if isSent { Spacer(minLength: 60) }

            VStack(alignment: isSent ? .trailing : .leading, spacing: 3) {
                // Message body
                Text(message.body)
                    .font(.body)
                    .foregroundStyle(isSent ? .white : .primary)
                    .padding(.horizontal, 14)
                    .padding(.vertical, 10)
                    .background(isSent ? Color.accentColor : Color(.secondarySystemGroupedBackground))
                    .clipShape(RoundedRectangle(cornerRadius: 18))

                // Timestamp + relay indicator + status
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

                    if isSent {
                        statusIcon
                    }
                }
            }

            if !isSent { Spacer(minLength: 60) }
        }
    }

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
    }
    .padding()
}
