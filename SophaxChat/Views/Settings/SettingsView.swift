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

                // Internet mode (TCP)
                Section {
                    Toggle("Internet Mode", isOn: $appState.tcpEnabled)

                    if appState.tcpEnabled {
                        HStack {
                            Text("TCP Port")
                            Spacer()
                            TextField("25519", text: $appState.tcpPort)
                                .keyboardType(.numberPad)
                                .multilineTextAlignment(.trailing)
                                .frame(width: 80)
                                .foregroundStyle(.secondary)
                        }

                        HStack {
                            Text("My Address")
                            Spacer()
                            TextField("IP:port", text: $appState.myTCPAddress)
                                .keyboardType(.asciiCapable)
                                .autocorrectionDisabled()
                                .textInputAutocapitalization(.never)
                                .multilineTextAlignment(.trailing)
                                .foregroundStyle(.secondary)
                        }

                        HStack {
                            Text("Tor / SOCKS5 Proxy")
                            Spacer()
                            TextField("127.0.0.1:9050", text: $appState.tcpSocksProxy)
                                .keyboardType(.asciiCapable)
                                .autocorrectionDisabled()
                                .textInputAutocapitalization(.never)
                                .multilineTextAlignment(.trailing)
                                .foregroundStyle(.secondary)
                        }

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
                        Text("TCP lets you chat over the internet, not just nearby. Enter your public IP:port in "My Address" so peers can reach you. Use a local SOCKS5 proxy (e.g. Orbot) for Tor anonymity, or enable Orbot VPN mode system-wide (no proxy config needed). All messages are end-to-end encrypted — TCP is just a carrier.")
                    } else {
                        Text("Enable to chat over the internet. Messages stay end-to-end encrypted regardless of transport.")
                    }
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
