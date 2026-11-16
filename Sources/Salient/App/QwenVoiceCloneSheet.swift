import AVFoundation
import AppKit
import SalientCore
import SwiftUI

struct QwenVoiceCloneSheet: View {
    @Environment(\.dismiss) private var dismiss
    @EnvironmentObject private var model: AppModel
    @StateObject private var recorder = QwenVoiceCloneRecorder()
    @State private var isSaving = false
    @State private var saveError: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            header

            Divider()

            permissionBlock

            if recorder.permissionState == .authorized {
                passageBlock
                recordingBlock
                validationBlock
            }

            if let saveError {
                Text(saveError)
                    .font(.callout)
                    .foregroundStyle(.red)
                    .textSelection(.enabled)
            }

            actionBar
        }
        .padding(24)
        .frame(minWidth: 620, idealWidth: 680, maxWidth: 760)
        .onAppear {
            recorder.refreshPermission()
        }
        .onDisappear {
            if !isSaving {
                recorder.stopSamplePlayback()
                recorder.stopRecording()
                recorder.discardTempRecording()
            }
        }
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text("Clone Voice Now")
                .font(.system(.title2, design: .serif).weight(.semibold))
            Text("Record a 10 to 20 second local sample for Qwen voice cloning.")
                .font(.callout)
                .foregroundStyle(.secondary)
            Text("The sample is stored only in Salient's local Application Support folder and replaces any previous My Voice sample.")
                .font(.caption)
                .foregroundStyle(SalientTheme.teal)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    @ViewBuilder
    private var permissionBlock: some View {
        switch recorder.permissionState {
        case .authorized:
            Label("Microphone ready", systemImage: "checkmark.circle.fill")
                .foregroundStyle(.green)
        case .notDetermined:
            HStack(spacing: 12) {
                Label("Microphone access is needed for recording.", systemImage: "mic")
                    .foregroundStyle(.secondary)
                Spacer()
                Button {
                    recorder.requestPermission()
                } label: {
                    Label("Allow Microphone", systemImage: "hand.raised")
                }
                .buttonStyle(.borderedProminent)
            }
        case .denied:
            HStack(spacing: 12) {
                Label("Microphone access is blocked.", systemImage: "mic.slash")
                    .foregroundStyle(.red)
                Spacer()
                Button {
                    openMicrophoneSettings()
                } label: {
                    Label("Open Settings", systemImage: "gear")
                }
                .buttonStyle(.bordered)
            }
        }
    }

    private var passageBlock: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Medical Passage")
                .font(.headline)
            Text(QwenStudentReferenceVoiceDefaults.referenceText)
                .font(.body)
                .lineSpacing(4)
                .textSelection(.enabled)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private var recordingBlock: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 12) {
                Button {
                    toggleRecording()
                } label: {
                    Label(
                        recorder.isRecording ? "Stop Recording" : "Record",
                        systemImage: recorder.isRecording ? "stop.circle" : "record.circle"
                    )
                    .frame(minWidth: 150)
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.large)
                .disabled(isSaving)

                Text("\(recorder.elapsedSeconds.formatted(.number.precision(.fractionLength(1)))) sec")
                    .font(.system(.body, design: .monospaced))
                    .foregroundStyle(.secondary)
                    .frame(width: 76, alignment: .trailing)

                ProgressView(
                    value: min(recorder.elapsedSeconds, QwenStudentReferenceVoiceDefaults.maximumDurationSeconds),
                    total: QwenStudentReferenceVoiceDefaults.maximumDurationSeconds
                )
                .controlSize(.large)
            }

            VoiceCloneLevelMeter(level: recorder.level)
                .frame(height: 10)
        }
    }

    private var validationBlock: some View {
        HStack(spacing: 10) {
            Image(systemName: recorder.validationPassed ? "checkmark.circle.fill" : "info.circle")
                .foregroundStyle(recorder.validationPassed ? .green : .secondary)
            Text(recorder.validationMessage)
                .font(.callout)
                .foregroundStyle(recorder.validationPassed ? .primary : .secondary)
            Spacer()
            if recorder.outputURL != nil {
                Button {
                    do {
                        try recorder.toggleSamplePlayback()
                    } catch {
                        saveError = error.localizedDescription
                    }
                } label: {
                    Label(recorder.isPlayingSample ? "Stop Sample" : "Play Sample", systemImage: recorder.isPlayingSample ? "stop.circle" : "play.circle")
                }
                .buttonStyle(.bordered)
                .disabled(!recorder.validationPassed)

                Button {
                    recorder.reset()
                    saveError = nil
                } label: {
                    Label("Try Again", systemImage: "arrow.counterclockwise")
                }
                .buttonStyle(.bordered)
            }
        }
    }

    private var actionBar: some View {
        HStack {
            Spacer()

            Button("Cancel") {
                recorder.stopSamplePlayback()
                recorder.stopRecording()
                recorder.discardTempRecording()
                dismiss()
            }
            .disabled(isSaving)

            Button {
                saveRecording()
            } label: {
                if isSaving {
                    ProgressView()
                        .controlSize(.small)
                } else {
                    Label("Save & Use", systemImage: "checkmark.circle")
                }
            }
            .buttonStyle(.borderedProminent)
            .disabled(!recorder.validationPassed || recorder.outputURL == nil || isSaving)
        }
    }

    private func toggleRecording() {
        saveError = nil
        if recorder.isRecording {
            recorder.stopRecording()
        } else {
            do {
                try recorder.startRecording()
            } catch {
                saveError = error.localizedDescription
            }
        }
    }

    private func saveRecording() {
        guard let outputURL = recorder.outputURL, recorder.validationPassed else { return }
        isSaving = true
        saveError = nil
        Task { @MainActor in
            let saved = await model.saveQwenStudentReferenceVoice(from: outputURL)
            isSaving = false
            if saved {
                recorder.discardTempRecording()
                dismiss()
            } else {
                saveError = model.lastError ?? "The recording could not be saved."
            }
        }
    }

    private func openMicrophoneSettings() {
        guard let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Microphone") else {
            return
        }
        NSWorkspace.shared.open(url)
    }
}

private struct VoiceCloneLevelMeter: View {
    var level: Double

    var body: some View {
        GeometryReader { proxy in
            ZStack(alignment: .leading) {
                Capsule()
                    .fill(.secondary.opacity(0.16))
                Capsule()
                    .fill(SalientTheme.teal)
                    .frame(width: max(8, proxy.size.width * min(max(level, 0), 1)))
            }
        }
        .accessibilityLabel("Input level")
    }
}

@MainActor
private final class QwenVoiceCloneRecorder: NSObject, ObservableObject {
    @Published var permissionState: MicrophonePermissionState = .notDetermined
    @Published var isRecording = false
    @Published var elapsedSeconds = 0.0
    @Published var level = 0.0
    @Published var outputURL: URL?
    @Published var validationMessage = "Record the passage to create My Voice."
    @Published var validationPassed = false
    @Published var isPlayingSample = false

    private var recorder: AVAudioRecorder?
    private var audioPlayer: AVAudioPlayer?
    private var meterTimer: Timer?
    private var peakLevel = 0.0

    func refreshPermission() {
        switch AVCaptureDevice.authorizationStatus(for: .audio) {
        case .authorized:
            permissionState = .authorized
        case .notDetermined:
            permissionState = .notDetermined
        case .denied, .restricted:
            permissionState = .denied
        @unknown default:
            permissionState = .denied
        }
    }

    func requestPermission() {
        AVCaptureDevice.requestAccess(for: .audio) { [weak self] _ in
            Task { @MainActor in
                self?.refreshPermission()
            }
        }
    }

    func startRecording() throws {
        guard permissionState == .authorized else {
            throw QwenRuntimeError.setupRequired("Microphone access is required to record a voice sample.")
        }
        reset()
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("salient-qwen-voice-clone-\(UUID().uuidString).wav")
        let settings: [String: Any] = [
            AVFormatIDKey: Int(kAudioFormatLinearPCM),
            AVSampleRateKey: QwenStudentReferenceVoiceDefaults.minimumSampleRate,
            AVNumberOfChannelsKey: 1,
            AVLinearPCMBitDepthKey: 16,
            AVLinearPCMIsFloatKey: false,
            AVLinearPCMIsBigEndianKey: false
        ]
        let nextRecorder = try AVAudioRecorder(url: url, settings: settings)
        nextRecorder.isMeteringEnabled = true
        nextRecorder.prepareToRecord()
        guard nextRecorder.record(forDuration: QwenStudentReferenceVoiceDefaults.maximumDurationSeconds) else {
            throw QwenRuntimeError.setupRequired("Could not start microphone recording.")
        }
        recorder = nextRecorder
        outputURL = url
        isRecording = true
        validationPassed = false
        validationMessage = "Recording..."
        startMeterTimer()
    }

    func stopRecording() {
        guard isRecording || recorder != nil else { return }
        elapsedSeconds = recorder?.currentTime ?? elapsedSeconds
        recorder?.stop()
        recorder = nil
        isRecording = false
        meterTimer?.invalidate()
        meterTimer = nil
        validateRecording()
    }

    func toggleSamplePlayback() throws {
        if isPlayingSample {
            stopSamplePlayback()
            return
        }
        guard let outputURL, validationPassed else {
            throw QwenRuntimeError.setupRequired("Record a valid sample before playback.")
        }
        stopSamplePlayback()
        let player = try AVAudioPlayer(contentsOf: outputURL)
        player.delegate = self
        player.prepareToPlay()
        guard player.play() else {
            throw QwenRuntimeError.setupRequired("Could not play the recorded sample.")
        }
        audioPlayer = player
        isPlayingSample = true
    }

    func stopSamplePlayback() {
        audioPlayer?.stop()
        audioPlayer = nil
        isPlayingSample = false
    }

    func reset() {
        stopSamplePlayback()
        stopRecording()
        discardTempRecording()
        elapsedSeconds = 0
        level = 0
        peakLevel = 0
        validationPassed = false
        validationMessage = "Record the passage to create My Voice."
    }

    func discardTempRecording() {
        stopSamplePlayback()
        if let outputURL {
            try? FileManager.default.removeItem(at: outputURL)
        }
        outputURL = nil
    }

    private func startMeterTimer() {
        meterTimer?.invalidate()
        let timer = Timer.scheduledTimer(withTimeInterval: 0.05, repeats: true) { [weak self] _ in
            Task { @MainActor in
                self?.tickMeter()
            }
        }
        RunLoop.main.add(timer, forMode: .common)
        meterTimer = timer
    }

    private func tickMeter() {
        guard let recorder else { return }
        guard recorder.isRecording else {
            stopRecording()
            return
        }
        recorder.updateMeters()
        elapsedSeconds = recorder.currentTime
        let peakPower = recorder.peakPower(forChannel: 0)
        let normalized = Self.normalizedPower(peakPower)
        level = normalized
        peakLevel = max(peakLevel, normalized)
        if elapsedSeconds >= QwenStudentReferenceVoiceDefaults.maximumDurationSeconds {
            stopRecording()
        }
    }

    private func validateRecording() {
        guard outputURL != nil else {
            validationPassed = false
            validationMessage = "Record the passage to create My Voice."
            return
        }
        if elapsedSeconds < QwenStudentReferenceVoiceDefaults.minimumDurationSeconds {
            validationPassed = false
            validationMessage = "The sample is too short. Record at least 10 seconds."
        } else if elapsedSeconds > QwenStudentReferenceVoiceDefaults.maximumDurationSeconds + 0.2 {
            validationPassed = false
            validationMessage = "The sample is too long. Keep it under 20 seconds."
        } else if peakLevel < Double(QwenStudentReferenceVoiceDefaults.minimumPeakAmplitude) {
            validationPassed = false
            validationMessage = "The sample is too quiet. Move closer and try again."
        } else {
            validationPassed = true
            validationMessage = "Ready to save My Voice."
        }
    }

    private static func normalizedPower(_ decibels: Float) -> Double {
        guard decibels > -60 else { return 0 }
        return min(1, max(0, Double(pow(10, decibels / 20))))
    }
}

extension QwenVoiceCloneRecorder: AVAudioPlayerDelegate {
    nonisolated func audioPlayerDidFinishPlaying(_ player: AVAudioPlayer, successfully flag: Bool) {
        Task { @MainActor in
            self.isPlayingSample = false
            self.audioPlayer = nil
        }
    }
}

private enum MicrophonePermissionState {
    case authorized
    case notDetermined
    case denied
}
