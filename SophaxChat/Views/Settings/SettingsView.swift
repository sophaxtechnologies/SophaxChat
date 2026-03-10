// SettingsView.swift
// SophaxChat
//
// App settings: blocked peers and other user preferences.

import SwiftUI
import SophaxChatCore

struct SettingsView: View {
    @EnvironmentObject var appState: AppState
    @Environment(\.dismiss) private var dismiss

    var blockedList: [(id: String, name: String)] {
        appState.blockedPeers.sorted().map { id in
            let name = appState.blockedPeerNames[id] ?? String(id.prefix(12)) + "…"
            return (id: id, name: name)
        }
    }

    var body: some View {
        NavigationStack {
            List {
                // Blocked peers
                Section {
                    if blockedList.isEmpty {
                        Text("No blocked users")
                            .foregroundStyle(.secondary)
                    } else {
                        ForEach(blockedList, id: \.id) { entry in
                            HStack {
                                VStack(alignment: .leading, spacing: 2) {
                                    Text(entry.name)
                                        .font(.subheadline.weight(.medium))
                                    Text(String(entry.id.prefix(16)) + "…")
                                        .font(.system(.caption2, design: .monospaced))
                                        .foregroundStyle(.tertiary)
                                }
                                Spacer()
                                Button("Unblock") {
                                    appState.unblockPeer(peerID: entry.id)
                                }
                                .font(.subheadline)
                                .buttonStyle(.bordered)
                                .tint(.accentColor)
                            }
                        }
                    }
                } header: {
                    Text("Blocked Users")
                } footer: {
                    Text("Blocked users cannot send you messages. Unblocking allows future messages if they are nearby.")
                }

                // App lock
                Section {
                    Toggle("App Lock", isOn: Binding(
                        get: { appState.appLockEnabled },
                        set: { enabled in
                            appState.appLockEnabled = enabled
                            if !enabled { appState.isAppLocked = false }
                        }
                    ))
                } header: {
                    Text("Security")
                } footer: {
                    Text("Require Face ID, Touch ID, or passcode to open SophaxChat.")
                }

                // App info
                Section {
                    HStack {
                        Text("Version")
                        Spacer()
                        Text(appVersion)
                            .foregroundStyle(.secondary)
                    }
                    HStack {
                        Text("Protocol")
                        Spacer()
                        Text("X3DH + Double Ratchet")
                            .foregroundStyle(.secondary)
                            .font(.caption)
                    }
                    HStack {
                        Text("Transport")
                        Spacer()
                        Text("Bluetooth LE / WiFi Direct")
                            .foregroundStyle(.secondary)
                            .font(.caption)
                    }
                } header: {
                    Text("About")
                }
            }
            .navigationTitle("Settings")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") { dismiss() }
                }
            }
        }
    }

    private var appVersion: String {
        Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "—"
    }
}

#Preview {
    SettingsView().environmentObject(AppState())
}
