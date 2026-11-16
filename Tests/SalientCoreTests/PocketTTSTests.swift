import Foundation
import XCTest
@testable import SalientCore

@MainActor final class PocketTTSTests: XCTestCase {
    func testFastPocketSpeechSurvivesSlowPlayerStartupWithoutLosingChunks() async throws {
        let runtime = BurstingPocketRuntime()
        let player = SlowStartingPocketPlayer()
        let backend = PocketSpeechBackend(runtime: runtime, playback: player, fallback: PocketFallbackSpy())
        try await backend.speak("A synthetic passage waits while the audio device starts.")
        XCTAssertEqual(player.sequences, Array(0...256))
        XCTAssertTrue(player.receivedFinal)
    }

    func testBackpressuredPocketProducerCancelsPromptly() async throws {
        let pair = PocketAudioStream.makeStream()
        var sent = 0
        let producer = Task {
            for index in 0..<10_000 {
                try await PocketAudioStream.send(.init(requestID: "synthetic", itemIndex: 0, sequenceIndex: index,
                    sampleRate: 24000, audioData: Data(repeating: 0, count: 4), durationSeconds: 1.0 / 24000,
                    isFinal: false), to: pair.continuation)
                sent += 1
            }
        }
        // No consumer: the bounded producer must wait, not grow indefinitely.
        try await Task.sleep(for: .milliseconds(20))
        XCTAssertGreaterThan(sent, 0)
        XCTAssertLessThan(sent, 10_000)
        let stopped = Date()
        producer.cancel()
        do { try await producer.value; XCTFail("Expected cancellation") }
        catch is CancellationError {}
        pair.continuation.finish()
        XCTAssertLessThan(Date().timeIntervalSince(stopped), 0.5)
    }

    func testInstalledWorkerRetainsSpeechWhileConsumerStartsSlowly() async throws {
        guard ProcessInfo.processInfo.environment["SALIENT_TEST_POCKET_RUNTIME"] == "1" else {
            throw XCTSkip("Opt-in local runtime test; never downloads or plays audio.")
        }
        let repo = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        let runtime = PocketRuntimeManager(workerURL: repo.appendingPathComponent(".build/pocket-runtime/release/salient-pocket-worker"))
        do {
            let chunks = try await runtime.stream(text: "Pocket is ready to read offline. A little space can make a big difference. Listen to each sentence and settle into a comfortable pace. This sample stays on your Mac, and no account or extra download is needed.", requestID: UUID())
            // Cold audio-device setup can take longer than native generation.
            try await Task.sleep(for: .seconds(1))
            var frames = 0
            var finished = false
            for try await chunk in chunks {
                frames += chunk.audioData.count / 4
                finished = finished || chunk.isFinal
            }
            XCTAssertGreaterThan(frames, 240_000)
            XCTAssertTrue(finished)
            await runtime.unload()
        } catch {
            await runtime.unload()
            throw error
        }
    }

    func testInstalledWorkerCancellationRecoveryAndNetworkDeniedSynthesis() async throws {
        guard ProcessInfo.processInfo.environment["SALIENT_TEST_POCKET_RUNTIME"] == "1" else {
            throw XCTSkip("Opt-in test of an already installed local Pocket runtime; never downloads or plays audio.")
        }
        // XCTest embeds its resource bundle inside the test runner. Use the
        // explicitly built helper, as opposed to the signed app-bundle helper.
        let repo = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        let runtime = PocketRuntimeManager(workerURL: repo.appendingPathComponent(".build/pocket-runtime/release/salient-pocket-worker"))
        let installed = await runtime.isInstalled()
        XCTAssertTrue(installed)
        // Cancelling a shared cold startup is normal lifecycle control, not a
        // download failure. Both the warmup and its waiting reader must settle.
        let warming = Task { try await runtime.warm() }
        try await Task.sleep(for: .milliseconds(80))
        let cold = Task { try await runtime.warm() }
        try await Task.sleep(for: .milliseconds(80))
        await runtime.unload()
        for task in [warming, cold] {
            // Native startup can finish before the interruption. Either completion
            // or cancellation is valid; a stale startup must never stay resident.
            do { try await task.value }
            catch is CancellationError {} catch { XCTFail("Unexpected warmup error: \(error)") }
        }
        let stayedResident = await runtime.isResident()
        XCTAssertFalse(stayedResident)
        let oldID = UUID()
        let old = try await runtime.stream(text: "A synthetic cancellation test repeats a long sentence while the reader changes their mind.", requestID: oldID)
        let stop = Date()
        await runtime.cancel(requestID: oldID)
        XCTAssertLessThan(Date().timeIntervalSince(stop), 0.8)
        do { for try await _ in old {}; XCTFail("Cancelled stream completed") } catch {}
        let fresh = try await runtime.stream(text: "A fresh synthetic sentence reads correctly.", requestID: UUID())
        // A late cancellation from the previous request must not stop this one.
        await runtime.cancel(requestID: oldID)
        var totalBytes = 0
        var didFinish = false
        for try await chunk in fresh {
            totalBytes += chunk.audioData.count
            didFinish = didFinish || chunk.isFinal
        }
        XCTAssertGreaterThan(totalBytes, 2400 * 4)
        XCTAssertTrue(didFinish)
        let resident = await runtime.isResident()
        XCTAssertTrue(resident)
        await runtime.unload()
        let unloaded = await runtime.isResident()
        XCTAssertFalse(unloaded)
    }

    func testPocketIsFirstLaunchDefaultAndSavedEngineChoicesRoundTrip() throws {
        XCTAssertEqual(SpeechSettings.firstLaunch.engineID, .pocket)
        XCTAssertNil(SpeechEngineID.pocket.qwenLane)
        for engine in SpeechEngineID.allCases {
            var settings = SpeechSettings.firstLaunch
            settings.engineID = engine
            settings.rateMultiplier = 1.8
            let decoded = try JSONDecoder().decode(SpeechSettings.self, from: JSONEncoder().encode(settings))
            XCTAssertEqual(decoded.engineID, engine)
            XCTAssertEqual(decoded.rateMultiplier, 1.8)
        }
    }

    func testStudyRouterChoosesPocketWithoutUsingQwen() async throws {
        let pocket = PocketFallbackSpy()
        let apple = PocketFallbackSpy()
        let qwen = PocketFallbackSpy()
        let backend = StudySpeechBackend(settings: .firstLaunch, appleBackend: apple, qwenBackend: qwen, pocketBackend: pocket)
        try await backend.speak("Synthetic routing check.")
        XCTAssertEqual(pocket.texts, ["Synthetic routing check."])
        XCTAssertTrue(apple.texts.isEmpty)
        XCTAssertTrue(qwen.texts.isEmpty)
    }

    func testMissingDownloadUsesAppleAndNeverStartsModel() async throws {
        let runtime = PocketRuntimeSpy(installed: false)
        let fallback = PocketFallbackSpy()
        let backend = PocketSpeechBackend(runtime: runtime, playback: PocketPlayerSpy(), fallback: fallback)
        try await backend.speak("Synthetic fallback check.")
        XCTAssertEqual(fallback.texts, ["Synthetic fallback check."])
        let requests = await runtime.requests
        XCTAssertEqual(requests, 0)
    }

    func testStopCancelsInFlightGenerationPromptlyAndNextRequestWorks() async throws {
        let runtime = PocketRuntimeSpy(installed: true)
        let player = PocketPlayerSpy()
        let fallback = PocketFallbackSpy()
        let backend = PocketSpeechBackend(runtime: runtime, playback: player, fallback: fallback)
        let ended = expectation(description: "Pocket stop returns")
        let first = Task {
            defer { ended.fulfill() }
            do { try await backend.speak("Blocked synthetic text."); XCTFail("Expected cancellation") }
            catch is CancellationError {} catch { XCTFail("Unexpected: \(error)") }
        }
        for _ in 0..<100 {
            if await runtime.requests > 0 { break }
            try await Task.sleep(for: .milliseconds(5))
        }
        await backend.stop()
        await fulfillment(of: [ended], timeout: 0.5)
        await first.value
        await runtime.completeImmediately()
        try await backend.speak("Second synthetic text.")
        XCTAssertTrue(fallback.texts.isEmpty)
        XCTAssertEqual(player.finished, 1)
        let cancelled = await runtime.cancelled
        XCTAssertEqual(cancelled, 1)
    }

    func testPCMFramingRejectsWrongRequestSequenceMalformedAndNonFiniteSamples() async throws {
        for payload in [
            event(id: "other"), event(sequence: 2), event(frames: 2), event(pcm: "not base64"),
            event(pcm: bytes(Float.nan)), event(pcm: bytes(Float.infinity)), event(type: "done", frames: 0)
        ] {
            do {
                _ = try await PocketResponseDecoder(requestID: "expected").consume(payload)
                XCTFail("Unsafe PCM accepted")
            } catch {}
        }
        let decoder = PocketResponseDecoder(requestID: "expected")
        let chunk = try await decoder.consume(event())
        XCTAssertEqual(chunk.sampleRate, 24000)
        XCTAssertEqual(chunk.audioData.count, 4)
        let final = try await decoder.consume(event(type: "done", sequence: 1))
        XCTAssertTrue(final.isFinal)
        XCTAssertEqual(final.durationSeconds, 1.0 / 24000, accuracy: 0.000001)
    }

    func testReadinessRejectsPartialInstallation() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let runtime = PocketRuntimeManager(root: directory)
        let ready = await runtime.isInstalled()
        XCTAssertFalse(ready)
        do { try await runtime.warm(); XCTFail("Partial runtime became resident") }
        catch { XCTAssertEqual(error as? PocketRuntimeError, .needsSetup) }
    }

    func testLongPastedParagraphPreservesWordsAndParenthesesInBoundedChunks() {
        let text = String(repeating: "An example (including an aside) is 3.5 units. ", count: 150)
        let chunks = PocketSpeechChunker.items(from: [.init(id: "long", segmentID: "long", text: text)])
        XCTAssertGreaterThan(chunks.count, 1)
        XCTAssertTrue(chunks.allSatisfy { $0.text.count <= 800 })
        XCTAssertEqual(chunks.map(\.text).joined(separator: " ").split(whereSeparator: \.isWhitespace), text.split(whereSeparator: \.isWhitespace))
        XCTAssertEqual(Set(chunks.map(\.id)).count, chunks.count)
    }

    private func bytes(_ sample: Float) -> String {
        withUnsafeBytes(of: sample.bitPattern.littleEndian) { Data($0).base64EncodedString() }
    }

    private func event(id: String = "expected", type: String = "chunk", sequence: Int = 0,
                       frames: Int = 1, pcm: String? = nil) -> Data {
        try! JSONSerialization.data(withJSONObject: ["type": type, "id": id, "sequence": sequence,
            "frames": frames, "pcm": pcm ?? bytes(0.2)])
    }
}

private actor PocketRuntimeSpy: PocketSynthesizing {
    let installed: Bool
    var requests = 0
    var cancelled = 0
    private var completes = false
    private var pending: (UUID, AsyncThrowingStream<QwenStreamingAudioChunk, Error>.Continuation)?
    init(installed: Bool) { self.installed = installed }
    func isInstalled() -> Bool { installed }
    func completeImmediately() { completes = true }
    func stream(text: String, requestID: UUID) -> AsyncThrowingStream<QwenStreamingAudioChunk, Error> {
        requests += 1
        let pair = AsyncThrowingStream<QwenStreamingAudioChunk, Error>.makeStream()
        if completes {
            pair.continuation.yield(.init(requestID: requestID.uuidString, itemIndex: 0, sequenceIndex: 0,
                sampleRate: 24000, audioData: Data(), durationSeconds: 1, isFinal: true))
            pair.continuation.finish()
        } else { pending = (requestID, pair.continuation) }
        return pair.stream
    }
    func cancel(requestID: UUID) {
        guard pending?.0 == requestID else { return }
        cancelled += 1
        pending?.1.finish(throwing: CancellationError())
        pending = nil
    }
}

private actor BurstingPocketRuntime: PocketSynthesizing {
    func isInstalled() -> Bool { true }
    func cancel(requestID: UUID) {}
    func stream(text: String, requestID: UUID) -> AsyncThrowingStream<QwenStreamingAudioChunk, Error> {
        AsyncThrowingStream { continuation in
            for index in 0...256 {
                continuation.yield(.init(requestID: requestID.uuidString, itemIndex: 0, sequenceIndex: index,
                    sampleRate: 24000, audioData: index == 256 ? Data() : Data(repeating: 0, count: 4),
                    durationSeconds: index == 256 ? 256.0 / 24000 : 1.0 / 24000, isFinal: index == 256))
            }
            continuation.finish()
        }
    }
}

@MainActor private final class SlowStartingPocketPlayer: PocketAudioPlaying {
    weak var timingSink: (any SpeechPlaybackTimingSink)?
    weak var visualizationSink: (any SpeechPlaybackVisualizationSink)?
    var sequences: [Int] = []
    var receivedFinal = false
    func play(item: SpeechPlaybackItem, chunks: AsyncThrowingStream<QwenStreamingAudioChunk, Error>, settings: SpeechSettings,
              willSpeak: @escaping @MainActor (SpeechPlaybackItem) async -> Void) async throws {
        try await Task.sleep(for: .milliseconds(100))
        await willSpeak(item)
        for try await chunk in chunks {
            sequences.append(chunk.sequenceIndex)
            receivedFinal = receivedFinal || chunk.isFinal
        }
    }
    func stop() {}
}

@MainActor private final class PocketPlayerSpy: PocketAudioPlaying {
    weak var timingSink: (any SpeechPlaybackTimingSink)?
    weak var visualizationSink: (any SpeechPlaybackVisualizationSink)?
    var finished = 0
    func play(item: SpeechPlaybackItem, chunks: AsyncThrowingStream<QwenStreamingAudioChunk, Error>, settings: SpeechSettings,
              willSpeak: @escaping @MainActor (SpeechPlaybackItem) async -> Void) async throws {
        await willSpeak(item)
        for try await _ in chunks { try Task.checkCancellation() }
        finished += 1
    }
    func stop() {}
}

@MainActor private final class PocketFallbackSpy: SpeechBackend {
    var texts: [String] = []
    func speak(_ text: String) async throws { texts.append(text) }
    func stop() async {}
}
