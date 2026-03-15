// SettingsView.swift
// SophaxChat
//
// App settings: blocked peers and other user preferences.

import SwiftUI
import SophaxChatCore

struct SettingsView: View {
    @EnvironmentObject var appState: AppState
    @Environment(\.dismiss) private var dismiss

    @State private var tcpConnectAddress: String = ""
    @State private var showTCPConnectAlert: Bool  = false
    @State private var tcpConnectError: String?   = nil

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

                // Internet mode — Tor-first
                Section {
                    Toggle("Internet Mode", isOn: $appState.tcpEnabled)

                    if appState.tcpEnabled {
                        // ── Tor / Orbot (recommended — zero config, solves NAT) ──────────
                        Link(destination: URL(string: "https://apps.apple.com/app/orbot/id1609461599")!) {
                            HStack {
                                VStack(alignment: .leading, spacing: 2) {
                                    Text("Get Orbot — Tor VPN")
                                        .foregroundStyle(.primary)
                                    Text("Recommended: enable VPN mode in Orbot, then come back")
                                        .font(.caption)
                                        .foregroundStyle(.secondary)
                                }
                                Spacer()
                                Image(systemName: "arrow.up.right")
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                            }
                        }

                        // ── Advanced: manual SOCKS5 proxy (Orbot proxy mode / other) ────
                        HStack {
                            Text("SOCKS5 Proxy")
                            Spacer()
                            TextField("127.0.0.1:9050", text: $appState.tcpSocksProxy)
                                .keyboardType(.asciiCapable)
                                .autocorrectionDisabled()
                                .textInputAutocapitalization(.never)
                                .multilineTextAlignment(.trailing)
                                .foregroundStyle(.secondary)
                        }

                        // ── Advanced: manual IP (for users with static public IP or .onion) ─
                        HStack {
                            Text("My Address")
                            Spacer()
                            TextField("host:port or .onion:25519", text: $appState.myTCPAddress)
                                .keyboardType(.asciiCapable)
                                .autocorrectionDisabled()
                                .textInputAutocapitalization(.never)
                                .multilineTextAlignment(.trailing)
                                .foregroundStyle(.secondary)
                        }

                        HStack {
                            Text("TCP Port")
                            Spacer()
                            TextField("25519", text: $appState.tcpPort)
                                .keyboardType(.numberPad)
                                .multilineTextAlignment(.trailing)
                                .frame(width: 70)
                                .foregroundStyle(.secondary)
                        }

                        // ── Direct connect ────────────────────────────────────────────────
                        HStack {
                            TextField("host:port", text: $tcpConnectAddress)
                                .keyboardType(.asciiCapable)
                                .autocorrectionDisabled()
                                .textInputAutocapitalization(.never)
                            Button("Connect") {
                                let addr = tcpConnectAddress.trimmingCharacters(in: .whitespaces)
                                guard !addr.isEmpty else { return }
                                appState.connectViaTCP(address: addr)
                                tcpConnectAddress = ""
                            }
                            .buttonStyle(.bordered)
                            .disabled(tcpConnectAddress.trimmingCharacters(in: .whitespaces).isEmpty)
                        }
                    }
                } header: {
                    Text("Internet Mode")
                } footer: {
                    if appState.tcpEnabled {
                        Text("Recommended: install Orbot and enable its VPN mode — all traffic automatically routes through Tor, no configuration needed here. Your peer's Orbot .onion address works as "My Address" on their device.\n\nWithout Tor, TCP requires a public IP + open port. All messages are end-to-end encrypted regardless — TCP is just a carrier.")
                    } else {
                        Text("Extend beyond local Bluetooth/WiFi. The recommended approach is Tor via Orbot (decentralized, anonymous, solves NAT). Messages stay end-to-end encrypted over any transport.")
                    }
                }

                // Support
                Section {
                    Link(destination: URL(string: "https://github.com/sophaxtechnologies/SophaxChat#support")!) {
                        Label("Support SophaxChat", systemImage: "heart.fill")
                            .foregroundStyle(.pink)
                    }
                    Link(destination: URL(string: "https://github.com/sophaxtechnologies/SophaxChat")!) {
                        Label("View Source on GitHub", systemImage: "chevron.left.forwardslash.chevron.right")
                            .foregroundStyle(.primary)
                    }
                } footer: {
                    Text("SophaxChat is free, open-source, and server-free. If it's useful to you, consider supporting it — via Bitcoin or Monero, no account needed.")
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
                        Text(appState.tcpEnabled ? "BLE / WiFi + TCP" : "Bluetooth LE / WiFi Direct")
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
