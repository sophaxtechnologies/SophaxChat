// SophaxChatApp.swift
// SophaxChat
//
// App entry point.

import SwiftUI
import SophaxChatCore

@main
struct SophaxChatApp: App {

    @StateObject private var appState = AppState()

    var body: some Scene {
        WindowGroup {
            RootView()
                .environmentObject(appState)
                // Prevent the app from appearing in the app switcher screenshot
                // (reduces the risk of sensitive content being captured by iOS)
                .onReceive(NotificationCenter.default.publisher(for: UIApplication.willResignActiveNotification)) { _ in
                    appState.isBlurred = true
                }
                .onReceive(NotificationCenter.default.publisher(for: UIApplication.didBecomeActiveNotification)) { _ in
                    appState.isBlurred = false
                }
        }
    }
}

// MARK: - Root View

struct RootView: View {
    @EnvironmentObject var appState: AppState

    var body: some View {
        ZStack {
            if appState.isSetupComplete {
                ChatListView()
            } else {
                OnboardingView()
            }

            // Security overlay: blurs content when app goes to background
            // Prevents sensitive content appearing in the app switcher
            if appState.isBlurred {
                Rectangle()
                    .fill(.ultraThinMaterial)
                    .ignoresSafeArea()
                    .transition(.opacity)
            }
        }
        .animation(.easeInOut(duration: 0.15), value: appState.isBlurred)
    }
}
