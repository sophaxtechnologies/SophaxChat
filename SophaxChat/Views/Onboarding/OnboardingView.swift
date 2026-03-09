// OnboardingView.swift
// SophaxChat
//
// First-launch onboarding: choose a username and create a cryptographic identity.
// No email, phone number, or account registration required.

import SwiftUI

struct OnboardingView: View {
    @EnvironmentObject var appState: AppState

    @State private var username: String = ""
    @State private var showingInfo: Bool = false
    @FocusState private var isTextFieldFocused: Bool

    var body: some View {
        NavigationStack {
            VStack(spacing: 32) {
                Spacer()

                // Logo / icon
                ZStack {
                    Circle()
                        .fill(Color.accentColor.opacity(0.12))
                        .frame(width: 120, height: 120)
                    Image(systemName: "lock.shield.fill")
                        .font(.system(size: 52))
                        .foregroundStyle(Color.accentColor)
                }

                VStack(spacing: 8) {
                    Text("SophaxChat")
                        .font(.largeTitle.bold())
                    Text("Encrypted • Anonymous • Open-source")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                }

                // Username input
                VStack(alignment: .leading, spacing: 8) {
                    Text("Choose a display name")
                        .font(.subheadline.weight(.medium))
                        .foregroundStyle(.secondary)

                    TextField("e.g. alice", text: $username)
                        .textFieldStyle(.plain)
                        .font(.body)
                        .padding(14)
                        .background(Color(.secondarySystemGroupedBackground))
                        .clipShape(RoundedRectangle(cornerRadius: 12))
                        .focused($isTextFieldFocused)
                        .autocorrectionDisabled()
                        .textInputAutocapitalization(.never)
                        .submitLabel(.go)
                        .onSubmit { createIdentity() }

                    Text("This name is visible to nearby peers. No account is required.")
                        .font(.caption)
                        .foregroundStyle(.tertiary)
                }
                .padding(.horizontal, 32)

                // CTA
                Button(action: createIdentity) {
                    Label("Start Chatting", systemImage: "arrow.right.circle.fill")
                        .font(.body.weight(.semibold))
                        .frame(maxWidth: .infinity)
                        .padding(16)
                        .background(username.isValidUsername ? Color.accentColor : Color.accentColor.opacity(0.3))
                        .foregroundStyle(.white)
                        .clipShape(RoundedRectangle(cornerRadius: 14))
                }
                .disabled(!username.isValidUsername)
                .padding(.horizontal, 32)
                .animation(.easeInOut, value: username.isValidUsername)

                Spacer()

                // Security info
                Button {
                    showingInfo = true
                } label: {
                    Label("How does the security work?", systemImage: "info.circle")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }
            }
            .navigationBarHidden(true)
            .onAppear { isTextFieldFocused = true }
        }
        .sheet(isPresented: $showingInfo) {
            SecurityInfoView()
        }
    }

    private func createIdentity() {
        guard username.isValidUsername else { return }
        isTextFieldFocused = false
        appState.createIdentity(username: username.trimmingCharacters(in: .whitespaces))
    }
}

// MARK: - Security Info Sheet

struct SecurityInfoView: View {
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            List {
                Section {
                    SecurityFeatureRow(
                        icon: "lock.fill", color: .blue,
                        title: "End-to-End Encryption",
                        description: "Every message is encrypted on your device before sending. Only the recipient can decrypt it — not us, not anyone else."
                    )
                    SecurityFeatureRow(
                        icon: "arrow.triangle.2.circlepath", color: .green,
                        title: "Double Ratchet Algorithm",
                        description: "The same protocol used by Signal. Each message uses a new encryption key, so compromise of one key doesn't expose other messages (forward secrecy + break-in recovery)."
                    )
                    SecurityFeatureRow(
                        icon: "key.fill", color: .orange,
                        title: "X3DH Key Agreement",
                        description: "Sessions are established with Extended Triple Diffie-Hellman — the same protocol as Signal. No server stores your keys."
                    )
                    SecurityFeatureRow(
                        icon: "wifi.slash", color: .purple,
                        title: "No Servers",
                        description: "Messages travel directly between devices via Bluetooth and WiFi Direct. There is no central server to breach."
                    )
                    SecurityFeatureRow(
                        icon: "person.slash", color: .red,
                        title: "No Identity Required",
                        description: "No phone number, email, or account. Your identity is a cryptographic key pair generated on your device."
                    )
                    SecurityFeatureRow(
                        icon: "eye.slash", color: .pink,
                        title: "Open Source",
                        description: "The full source code is publicly auditable. Security through obscurity is not security."
                    )
                } header: {
                    Text("Security Features")
                }
            }
            .navigationTitle("How It Works")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") { dismiss() }
                }
            }
        }
    }
}

struct SecurityFeatureRow: View {
    let icon: String
    let color: Color
    let title: String
    let description: String

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            Image(systemName: icon)
                .font(.body.weight(.semibold))
                .foregroundStyle(color)
                .frame(width: 28)
            VStack(alignment: .leading, spacing: 2) {
                Text(title).font(.subheadline.weight(.semibold))
                Text(description).font(.caption).foregroundStyle(.secondary)
            }
        }
        .padding(.vertical, 4)
    }
}

// MARK: - Helpers

private extension String {
    var isValidUsername: Bool {
        let trimmed = trimmingCharacters(in: .whitespaces)
        return trimmed.count >= 1 && trimmed.count <= 32
    }
}

#Preview {
    OnboardingView().environmentObject(AppState())
}
