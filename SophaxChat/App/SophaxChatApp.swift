// SophaxChatApp.swift
// SophaxChat
//
// App entry point.

import SwiftUI
import BackgroundTasks
import SophaxChatCore

@main
struct SophaxChatApp: App {

    @StateObject private var appState = AppState()

    // MARK: - Background task identifier

    private static let meshRefreshID = "com.sophax.mesh-refresh"

    var body: some Scene {
        WindowGroup {
            RootView()
                .environmentObject(appState)
                // Prevent the app from appearing in the app switcher screenshot
                // (reduces the risk of sensitive content being captured by iOS)
                .onReceive(NotificationCenter.default.publisher(for: UIApplication.willResignActiveNotification)) { _ in
                    appState.isBlurred = true
                    appState.lockApp()
                    scheduleBackgroundMeshRefresh()
                }
                .onReceive(NotificationCenter.default.publisher(for: UIApplication.didBecomeActiveNotification)) { _ in
                    appState.isBlurred = false
                    // AppLockView.onAppear handles unlock attempt automatically
                }
        }
        // Background processing task — re-wakes the mesh briefly after iOS suspends the app.
        // The bluetooth-central/peripheral background modes in Info.plist allow MPC to stay
        // alive for several minutes after backgrounding; this BGTask extends coverage when
        // iOS has fully suspended the process.
        .backgroundTask(.appRefresh(Self.meshRefreshID)) {
            await appState.handleBackgroundMeshRefresh()
        }
    }

    // MARK: - Background scheduling

    private func scheduleBackgroundMeshRefresh() {
        let request = BGAppRefreshTaskRequest(identifier: Self.meshRefreshID)
        // iOS will call this after ~15 minutes at the earliest; actual timing is system-driven.
        request.earliestBeginDate = Date(timeIntervalSinceNow: 15 * 60)
        try? BGTaskScheduler.shared.submit(request)
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

            // App lock overlay
            if appState.isAppLocked {
                AppLockView()
                    .ignoresSafeArea()
                    .transition(.opacity)
            }
        }
        .animation(.easeInOut(duration: 0.15), value: appState.isBlurred)
        .animation(.easeInOut(duration: 0.2), value: appState.isAppLocked)
    }
}
