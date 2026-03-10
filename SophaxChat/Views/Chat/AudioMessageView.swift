// AudioMessageView.swift
// SophaxChat
//
// Playback bubble for encrypted voice messages.

import SwiftUI
import AVFoundation

@MainActor
final class AudioPlayer: NSObject, ObservableObject, AVAudioPlayerDelegate {

    @Published var isPlaying:  Bool    = false
    @Published var progress:   Double  = 0       // 0–1
    @Published var elapsed:    Double  = 0       // seconds

    private var player:  AVAudioPlayer?
    private var timer:   Timer?

    func load(_ data: Data) {
        try? AVAudioSession.sharedInstance().setCategory(.playback, mode: .default)
        try? AVAudioSession.sharedInstance().setActive(true)
        player = try? AVAudioPlayer(data: data)
        player?.delegate = self
        player?.prepareToPlay()
    }

    func togglePlay() {
        guard let p = player else { return }
        if isPlaying {
            p.pause()
            stopTimer()
            isPlaying = false
        } else {
            p.play()
            startTimer()
            isPlaying = true
        }
    }

    func stop() {
        player?.stop()
        player?.currentTime = 0
        stopTimer()
        isPlaying = false
        progress  = 0
        elapsed   = 0
    }

    // MARK: - AVAudioPlayerDelegate

    nonisolated func audioPlayerDidFinishPlaying(_ player: AVAudioPlayer, successfully flag: Bool) {
        Task { @MainActor in
            self.stopTimer()
            self.isPlaying = false
            self.progress  = 0
            self.elapsed   = 0
            self.player?.currentTime = 0
        }
    }

    // MARK: - Private

    private func startTimer() {
        timer = Timer.scheduledTimer(withTimeInterval: 0.1, repeats: true) { [weak self] _ in
            Task { @MainActor [weak self] in
                guard let self, let p = self.player else { return }
                self.elapsed  = p.currentTime
                self.progress = p.duration > 0 ? p.currentTime / p.duration : 0
            }
        }
    }

    private func stopTimer() {
        timer?.invalidate()
        timer = nil
    }
}

struct AudioMessageView: View {
    let audioData:    Data
    let duration:     Double    // seconds
    let isSent:       Bool

    @StateObject private var player = AudioPlayer()

    var body: some View {
        HStack(spacing: 10) {
            // Play/pause button
            Button {
                player.togglePlay()
            } label: {
                Image(systemName: player.isPlaying ? "pause.circle.fill" : "play.circle.fill")
                    .font(.system(size: 32))
                    .foregroundStyle(isSent ? .white : .accentColor)
            }
            .buttonStyle(.plain)

            VStack(alignment: .leading, spacing: 4) {
                // Progress bar
                GeometryReader { geo in
                    ZStack(alignment: .leading) {
                        Capsule()
                            .fill(isSent ? Color.white.opacity(0.35) : Color.secondary.opacity(0.25))
                        Capsule()
                            .fill(isSent ? Color.white : Color.accentColor)
                            .frame(width: geo.size.width * player.progress)
                    }
                }
                .frame(height: 4)

                // Time
                Text(formattedTime)
                    .font(.caption2)
                    .foregroundStyle(isSent ? .white.opacity(0.8) : .secondary)
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 10)
        .onAppear { player.load(audioData) }
        .onDisappear { player.stop() }
    }

    private var formattedTime: String {
        let seconds = player.isPlaying ? player.elapsed : duration
        let m = Int(seconds) / 60
        let s = Int(seconds) % 60
        return String(format: "%d:%02d", m, s)
    }
}
