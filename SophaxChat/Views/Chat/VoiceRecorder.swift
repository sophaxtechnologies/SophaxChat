// VoiceRecorder.swift
// SophaxChat
//
// Hold-to-record PTT voice message recorder using AVAudioRecorder.
// Records AAC-LC M4A at 16 kHz / 24 kbps (~4 KB/s) targeting ≤ 512 KB.

import AVFoundation
import SwiftUI

@MainActor
final class VoiceRecorder: NSObject, ObservableObject {

    @Published var isRecording: Bool = false

    private var recorder:    AVAudioRecorder?
    private var startTime:   Date?
    private var tempURL:     URL?
    private var completion:  ((Data?, Double) -> Void)?

    // MARK: - Public API

    func start() {
        guard !isRecording else { return }

        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString)
            .appendingPathExtension("m4a")
        tempURL = url

        let settings: [String: Any] = [
            AVFormatIDKey:             Int(kAudioFormatMPEG4AAC),
            AVSampleRateKey:           16_000,
            AVNumberOfChannelsKey:     1,
            AVEncoderAudioQualityKey:  AVAudioQuality.medium.rawValue,
            AVEncoderBitRateKey:       24_000
        ]

        do {
            #if !targetEnvironment(macCatalyst)
            try AVAudioSession.sharedInstance().setCategory(.playAndRecord,
                                                             mode: .default,
                                                             options: [.defaultToSpeaker, .allowBluetooth])
            try AVAudioSession.sharedInstance().setActive(true)
            #endif
            recorder = try AVAudioRecorder(url: url, settings: settings)
            recorder?.delegate = self
            recorder?.record()
            startTime  = Date()
            isRecording = true
        } catch {
            isRecording = false
        }
    }

    /// Stops recording and returns the audio data + duration via the completion handler.
    /// Called on the main actor; completion is also delivered on main actor.
    func stop(completion: @escaping (Data?, Double) -> Void) {
        guard isRecording, let rec = recorder, let start = startTime else {
            completion(nil, 0)
            return
        }
        self.completion = completion
        let duration = Date().timeIntervalSince(start)
        rec.stop()
        // Delegate -audioRecorderDidFinishRecording fires next; we deliver there.
        // Store duration so delegate can use it.
        storedDuration = duration
        isRecording   = false
    }

    // MARK: - Private

    private var storedDuration: Double = 0

    private func deliver() {
        defer {
            recorder    = nil
            startTime   = nil
            storedDuration = 0
            tempURL     = nil
            completion  = nil
            #if !targetEnvironment(macCatalyst)
            try? AVAudioSession.sharedInstance().setActive(false, options: .notifyOthersOnDeactivation)
            #endif
        }

        guard let url = tempURL, let cb = completion else { return }
        let data = try? Data(contentsOf: url)
        try? FileManager.default.removeItem(at: url)
        cb(data, storedDuration)
    }
}

// MARK: - AVAudioRecorderDelegate

extension VoiceRecorder: AVAudioRecorderDelegate {
    nonisolated func audioRecorderDidFinishRecording(_ recorder: AVAudioRecorder, successfully flag: Bool) {
        Task { @MainActor [weak self] in
            self?.deliver()
        }
    }

    nonisolated func audioRecorderEncodeErrorDidOccur(_ recorder: AVAudioRecorder, error: Error?) {
        Task { @MainActor [weak self] in
            self?.isRecording   = false
            self?.completion?(nil, 0)
            self?.completion    = nil
            self?.recorder      = nil
        }
    }
}
