import Foundation
import XCTest

@testable import SalientCore

@MainActor
final class SpeechLifecycleTests: XCTestCase {
    func testStudySpeechBackendStartsReplacementOnlyAfterPriorStop() async throws {
        let backend = BlockingSpeechBackend()
        let speech = StudySpeechBackend(
            settings: .default,
            appleBackend: backend,
            qwenBackend: NoopSpeechBackend()
        )
        let first = Task { @MainActor in
            try await speech.speak("first")
        }
        while !backend.events.contains("speak:first") {
            await Task.yield()
        }

        try await speech.speak("second")

        do {
            try await first.value
            XCTFail("Expected the replaced speech request to be cancelled.")
        } catch is CancellationError {
            XCTAssertEqual(backend.events, ["speak:first", "stop", "speak:second"])
        }
    }

    func testExplicitStopInvalidatesPendingReplacementGeneration() async throws {
        let backend = BlockingSpeechBackend()
        let speech = StudySpeechBackend(
            settings: .default,
            appleBackend: backend,
            qwenBackend: NoopSpeechBackend()
        )
        let request = Task { @MainActor in
            try await speech.speak("first")
        }
        while !backend.events.contains("speak:first") {
            await Task.yield()
        }

        await speech.stop()

        do {
            try await request.value
            XCTFail("Expected explicit speech stop to cancel the request.")
        } catch is CancellationError {
            XCTAssertEqual(backend.events, ["speak:first", "stop"])
        }
    }

    func testCancellingQwenSpeakResumesWhilePreparationIsStillBlocked() async {
        var settings = SpeechSettings.default
        settings.engineID = .qwenSmall
        settings.usesQuestionPromptAudioLibrary = false
        let runtime = BlockingQwenSynthesizer()
        let backend = QwenSpeechBackend(
            settings: settings,
            runtime: runtime,
            playback: NoopQwenPlayback(),
            streamingEnabledOverride: false
        )
        let completion = expectation(description: "cancelled Qwen speech returns promptly")
        let speechTask = Task { @MainActor in
            defer { completion.fulfill() }
            do {
                try await backend.speak("Synthetic blocked narration fixture.")
                return false
            } catch is CancellationError {
                return true
            } catch {
                return false
            }
        }

        for _ in 0..<100 where !(await runtime.hasStarted) {
            try? await Task.sleep(for: .milliseconds(10))
        }
        let didStart = await runtime.hasStarted
        XCTAssertTrue(didStart)
        speechTask.cancel()

        await fulfillment(of: [completion], timeout: 0.5)
        await runtime.release()
        let wasCancelled = await speechTask.value
        XCTAssertTrue(wasCancelled)
        for _ in 0..<100 where !(await runtime.didProduceAudio) {
            try? await Task.sleep(for: .milliseconds(5))
        }
        let didProduceAudio = await runtime.didProduceAudio
        let producedAudioURL = runtime.producedAudioURL
        XCTAssertTrue(didProduceAudio)
        for _ in 0..<100 where FileManager.default.fileExists(atPath: producedAudioURL.path) {
            try? await Task.sleep(for: .milliseconds(5))
        }
        XCTAssertFalse(FileManager.default.fileExists(atPath: producedAudioURL.path))
    }
}

@MainActor
private final class BlockingSpeechBackend: SpeechBackend {
    private(set) var events: [String] = []
    private var continuation: CheckedContinuation<Void, Error>?

    func speak(_ text: String) async throws {
        events.append("speak:\(text)")
        guard text == "first" else { return }
        try await withCheckedThrowingContinuation { continuation in
            self.continuation = continuation
        }
    }

    func stop() async {
        guard let continuation else { return }
        events.append("stop")
        self.continuation = nil
        continuation.resume(throwing: CancellationError())
    }
}

@MainActor
private final class NoopSpeechBackend: SpeechBackend {
    func speak(_: String) async throws {}
    func stop() async {}
}

private actor BlockingQwenSynthesizer: QwenAudioSynthesizing {
    private(set) var hasStarted = false
    private(set) var didProduceAudio = false
    let producedAudioURL = FileManager.default.temporaryDirectory
        .appendingPathComponent("salient-cancelled-preparation-\(UUID().uuidString).wav")
    private var continuation: CheckedContinuation<Void, Never>?

    func synthesize(
        text _: String,
        lane _: QwenModelLane,
        speaker _: String,
        language _: String,
        rateMultiplier _: Double,
        cachePolicy _: QwenAudioCachePolicy,
        useReferenceVoice _: Bool,
        referenceAudioPath _: String?,
        referenceText _: String?
    ) async throws -> QwenPreparedAudio {
        hasStarted = true
        await withCheckedContinuation { continuation in
            self.continuation = continuation
        }
        try Data("synthetic transient audio".utf8).write(to: producedAudioURL, options: .atomic)
        didProduceAudio = true
        return QwenPreparedAudio(
            url: producedAudioURL,
            durationSeconds: 0.1,
            isFromCache: false,
            removeAfterPlayback: true
        )
    }

    func release() {
        let continuation = continuation
        self.continuation = nil
        continuation?.resume()
    }
}

@MainActor
private final class NoopQwenPlayback: QwenAudioPlaying {
    weak var visualizationSink: (any SpeechPlaybackVisualizationSink)?

    func play(url _: URL, rateMultiplier _: Double, volume _: Double) async throws {}

    func play(
        _: [QwenPreparedPlaybackItem],
        rateMultiplier _: Double,
        volume _: Double,
        onStartItem _: @escaping @MainActor @Sendable (SpeechPlaybackItem) async -> Void
    ) async throws {}

    func stop() {}
}
