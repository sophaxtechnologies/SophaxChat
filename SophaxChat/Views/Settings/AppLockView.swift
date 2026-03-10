// AppLockView.swift
// SophaxChat
//
// Full-screen lock overlay shown when app lock is enabled.
// Auto-attempts biometric / passcode authentication on appear.

import SwiftUI

struct AppLockView: View {
    @EnvironmentObject var appState: AppState

    var body: some View {
        ZStack {
            Color(.systemBackground).ignoresSafeArea()

            VStack(spacing: 28) {
                Image(systemName: "lock.shield.fill")
                    .font(.system(size: 64))
                    .foregroundStyle(Color.accentColor)

                VStack(spacing: 6) {
                    Text("SophaxChat")
                        .font(.title.bold())
                    Text("App is locked")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                }

                Button(action: { appState.tryUnlock() }) {
                    Label("Unlock", systemImage: "faceid")
                        .font(.headline)
                        .padding(.horizontal, 36)
                        .padding(.vertical, 14)
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.large)
            }
        }
        .onAppear {
            // Attempt auto-unlock as soon as the lock screen appears
            appState.tryUnlock()
        }
    }
}

#Preview {
    AppLockView().environmentObject(AppState())
}
