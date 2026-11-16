import Foundation
import SalientCore

/// Release verification uses the real packaged app and its normal runtime lookup.
/// Run with CFFIXED_USER_HOME pointing at a new, empty home and a network-denied
/// sandbox. This path never installs a model or changes the user's preferences.
enum PocketBundleCheck {
    static let sample = "Pocket is ready to read offline. A little space can make a big difference. Listen to each sentence and settle into a comfortable pace. This sample stays on your Mac, and no account or extra download is needed."

    static func runAndExit(playback: Bool) -> Never {
        Task.detached {
            do {
                let report = try await verify(playback: playback)
                let data = try JSONSerialization.data(withJSONObject: report, options: [.prettyPrinted, .sortedKeys])
                FileHandle.standardOutput.write(data + Data([0x0A]))
                Foundation.exit(0)
            } catch {
                let data = try? JSONSerialization.data(withJSONObject: ["status": "failed", "error": error.localizedDescription], options: [.sortedKeys])
                FileHandle.standardError.write((data ?? Data("Pocket bundle verification failed".utf8)) + Data([0x0A]))
                Foundation.exit(1)
            }
        }
        dispatchMain()
    }

    private static func verify(playback: Bool) async throws -> [String: Any] {
        let manager = FileManager.default
        let managed = PocketRuntimeManager.defaultRoot
        guard !manager.fileExists(atPath: managed.path) else { throw CheckError.existingManagedInstallation }
        guard let bundled = PocketRuntimeManager.bundledAssetRoot else { throw CheckError.missingBundle }
        let runtime = PocketRuntimeManager()
        guard await runtime.isInstalled(), await runtime.resolvedAssetRoot() == bundled else { throw CheckError.missingBundle }
        var frames = 0
        var peak: Float = 0
        var final = false
        let started = Date()
        do {
            let chunks = try await runtime.stream(text: sample, requestID: UUID())
            for try await chunk in chunks {
                guard chunk.audioData.count % 4 == 0 else { throw CheckError.invalidAudio }
                try chunk.audioData.withUnsafeBytes { bytes in
                    for offset in stride(from: 0, to: bytes.count, by: 4) {
                        let value = Float(bitPattern: UInt32(littleEndian: bytes.loadUnaligned(fromByteOffset: offset, as: UInt32.self)))
                        guard value.isFinite else { throw CheckError.invalidAudio }
                        peak = max(peak, abs(value))
                    }
                }
                frames += chunk.audioData.count / 4
                final = final || chunk.isFinal
            }
            guard final, frames > 2400, peak > 0.0001 else { throw CheckError.invalidAudio }
            await runtime.unload()
            if playback { try await play(runtime: runtime) }
            await runtime.unload()
        } catch {
            await runtime.unload()
            throw error
        }
        guard !manager.fileExists(atPath: managed.path) else { throw CheckError.unexpectedCopy }
        return [
            "status": "passed", "pocketVersion": PocketRuntimeManager.version,
            "source": "bundled", "bundledRoot": bundled.path, "managedRoot": managed.path,
            "managedRootCreated": false, "downloadInvoked": false,
            "sampleRate": 24000, "frames": frames, "peak": peak,
            "generatedSeconds": Double(frames) / 24000,
            "elapsedSeconds": Date().timeIntervalSince(started), "playbackCompleted": playback,
        ]
    }

    @MainActor
    private static func play(runtime: PocketRuntimeManager) async throws {
        var settings = SpeechSettings.firstLaunch
        settings.showPlaybackHUD = false
        settings.rateMultiplier = 1
        let backend = PocketSpeechBackend(settings: settings, runtime: runtime)
        try await backend.speak(sample)
        guard backend.playbackUnderrunCount == 0 else { throw CheckError.underrun }
    }

    private enum CheckError: String, LocalizedError {
        case existingManagedInstallation = "The check requires an empty user home without Pocket assets."
        case missingBundle = "The packaged Pocket assets were not selected."
        case invalidAudio = "Pocket did not generate valid non-silent audio."
        case unexpectedCopy = "The bundled runtime unexpectedly created a managed asset directory."
        case underrun = "Bundled playback experienced an underrun."
        var errorDescription: String? { rawValue }
    }
}
