import AVFoundation
import Foundation
import XCTest

@testable import SalientCore

final class QwenRuntimeOptimizationTests: XCTestCase {
    func testRateChangesReuseOnePersistentSynthesisAndSurviveMissingRuntime() async throws {
        let root = try makeRuntimeRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let runner = OptimizationRecordingRunner()
        let runtime = QwenRuntimeManager(runtimeRoot: root, runner: runner)
        let text = "Synthetic persistent narration cache fixture."

        let first = try await synthesizePersistent(text, rate: 2.4, runtime: runtime)
        try FileManager.default.removeItem(at: root.appendingPathComponent("venv"))
        try FileManager.default.removeItem(at: root.appendingPathComponent("models"))
        let second = try await synthesizePersistent(text, rate: 1.2, runtime: runtime)

        XCTAssertFalse(first.isFromCache)
        XCTAssertTrue(second.isFromCache)
        XCTAssertEqual(first.url, second.url)
        let synthesisCount = await runner.synthesisCount
        XCTAssertEqual(synthesisCount, 1)
    }

    func testConcurrentIdenticalPersistentMissesAreCoalesced() async throws {
        let root = try makeRuntimeRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let runner = OptimizationRecordingRunner(delay: .milliseconds(150))
        let runtime = QwenRuntimeManager(runtimeRoot: root, runner: runner)
        let text = "Synthetic concurrent cache coalescing fixture."

        async let first = runtime.synthesize(
            text: text,
            lane: .small,
            speaker: "Aiden",
            language: "English",
            rateMultiplier: 2.4,
            cachePolicy: .persistent
        )
        try await Task.sleep(for: .milliseconds(20))
        async let second = runtime.synthesize(
            text: text,
            lane: .small,
            speaker: "Aiden",
            language: "English",
            rateMultiplier: 1.8,
            cachePolicy: .persistent
        )
        let results = try await [first, second]

        let synthesisCount = await runner.synthesisCount
        XCTAssertEqual(synthesisCount, 1)
        XCTAssertEqual(results.filter(\.isFromCache).count, 1)
        XCTAssertEqual(Set(results.map(\.url)).count, 1)
    }

    func testPersistentCacheHitDoesNotWaitBehindUnrelatedGeneration() async throws {
        let root = try makeRuntimeRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let runner = OptimizationRecordingRunner(delay: .milliseconds(500))
        let runtime = QwenRuntimeManager(runtimeRoot: root, runner: runner)
        let cachedText = "Synthetic ready cache fixture."

        _ = try await synthesizePersistent(cachedText, rate: 1.7, runtime: runtime)
        let active = Task {
            try await runtime.synthesize(
                text: "Synthetic unrelated slow generation fixture.",
                lane: .small,
                speaker: "Aiden",
                language: "English",
                rateMultiplier: 1.7,
                cachePolicy: .persistent
            )
        }
        for _ in 0..<200 where await runner.synthesisCount < 2 {
            try await Task.sleep(for: .milliseconds(5))
        }
        let activeSynthesisCount = await runner.synthesisCount
        XCTAssertEqual(activeSynthesisCount, 2)

        let startedAt = ContinuousClock.now
        let hit = try await synthesizePersistent(cachedText, rate: 2.4, runtime: runtime)
        let elapsed = ContinuousClock.now - startedAt

        XCTAssertTrue(hit.isFromCache)
        XCTAssertLessThan(elapsed, .milliseconds(200))
        _ = try await active.value
    }

    func testCancellingQueuedSynthesisDoesNotInterruptActiveRequest() async throws {
        let root = try makeRuntimeRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let runner = OptimizationRecordingRunner(delay: .seconds(1))
        let runtime = QwenRuntimeManager(runtimeRoot: root, runner: runner)

        let active = Task {
            try await runtime.synthesize(
                text: "Synthetic active narration fixture.",
                lane: .small,
                speaker: "Aiden",
                language: "English",
                rateMultiplier: 2.4,
                cachePolicy: .transient,
                useReferenceVoice: false
            )
        }
        await runner.waitForFirstSynthesis()
        let queued = Task {
            try await runtime.synthesize(
                text: "Synthetic queued narration fixture.",
                lane: .small,
                speaker: "Aiden",
                language: "English",
                rateMultiplier: 2.4,
                cachePolicy: .transient,
                useReferenceVoice: false
            )
        }
        for _ in 0..<100 where await runtime.pendingSynthesisLeaseCountForTesting() == 0 {
            try? await Task.sleep(for: .milliseconds(5))
        }
        let queuedWaiterCount = await runtime.pendingSynthesisLeaseCountForTesting()
        XCTAssertEqual(queuedWaiterCount, 1)
        queued.cancel()

        do {
            _ = try await queued.value
            XCTFail("Expected queued synthesis cancellation")
        } catch is CancellationError {
            // Expected: a queued caller never owns or tears down the active request.
        }
        let completed = try await active.value

        XCTAssertGreaterThan(try XCTUnwrap(QwenAudioPostProcessor.durationSeconds(of: completed.url)), 0)
        let synthesisCount = await runner.synthesisCount
        XCTAssertEqual(synthesisCount, 1)
    }

    func testCorruptPersistentCacheEntryIsEvictedAndRegenerated() async throws {
        let root = try makeRuntimeRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let runner = OptimizationRecordingRunner()
        let runtime = QwenRuntimeManager(runtimeRoot: root, runner: runner)
        let text = "Synthetic corrupt cache recovery fixture."

        let first = try await synthesizePersistent(text, rate: 2.4, runtime: runtime)
        try Data("not a wave file".utf8).write(to: first.url, options: .atomic)
        let recovered = try await synthesizePersistent(text, rate: 2.4, runtime: runtime)

        XCTAssertFalse(recovered.isFromCache)
        let synthesisCount = await runner.synthesisCount
        XCTAssertEqual(synthesisCount, 2)
        XCTAssertGreaterThan(try XCTUnwrap(QwenAudioPostProcessor.durationSeconds(of: recovered.url)), 0)
    }

    func testCacheMaintenanceFilesystemProbeIsThrottled() async throws {
        let root = try makeRuntimeRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let capacity = CapacityProbe()
        let runner = OptimizationRecordingRunner()
        let runtime = QwenRuntimeManager(
            runtimeRoot: root,
            runner: runner,
            availableCapacityProvider: capacity.availableCapacity
        )

        _ = try await synthesizeTransient("Synthetic maintenance fixture one.", runtime: runtime)
        _ = try await synthesizeTransient("Synthetic maintenance fixture two.", runtime: runtime)

        XCTAssertEqual(capacity.count, 1)
    }

    func testPartialTransientBatchFailureRemovesAlreadyPublishedPlaybackAudio() async throws {
        let root = try makeRuntimeRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let runner = OptimizationRecordingRunner(silentSynthesisNumbers: [2])
        let runtime = QwenRuntimeManager(runtimeRoot: root, runner: runner)
        let requests = [
            "Synthetic valid batch item.",
            "Synthetic silent batch item.",
        ].map {
            QwenSynthesisRequest(
                text: $0,
                lane: .small,
                speaker: "Aiden",
                language: "English",
                rateMultiplier: 2.4,
                cachePolicy: .transient,
                useReferenceVoice: false
            )
        }

        do {
            _ = try await runtime.synthesizeBatch(requests)
            XCTFail("Expected the silent batch item to fail validation.")
        } catch {
            XCTAssertTrue(error.localizedDescription.contains("silent") || error.localizedDescription.contains("invalid"))
        }

        let temporaryDirectory = root.appendingPathComponent("tmp", isDirectory: true)
        let leftovers = (try? FileManager.default.contentsOfDirectory(atPath: temporaryDirectory.path)) ?? []
        XCTAssertFalse(leftovers.contains { $0.hasSuffix("-playback.wav") })
    }

    private func synthesizePersistent(
        _ text: String,
        rate: Double,
        runtime: QwenRuntimeManager
    ) async throws -> QwenPreparedAudio {
        try await runtime.synthesize(
            text: text,
            lane: .small,
            speaker: "Aiden",
            language: "English",
            rateMultiplier: rate,
            cachePolicy: .persistent
        )
    }

    private func synthesizeTransient(
        _ text: String,
        runtime: QwenRuntimeManager
    ) async throws -> QwenPreparedAudio {
        try await runtime.synthesize(
            text: text,
            lane: .small,
            speaker: "Aiden",
            language: "English",
            rateMultiplier: 2.4,
            cachePolicy: .transient
        )
    }

    private func makeRuntimeRoot() throws -> URL {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("salient-qwen-optimization-tests-\(UUID().uuidString)", isDirectory: true)
        let pythonURL = root.appendingPathComponent("venv/bin/python")
        try FileManager.default.createDirectory(at: pythonURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        try "#!/bin/sh\nexit 0\n".write(to: pythonURL, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: pythonURL.path)
        let modelDirectory = root.appendingPathComponent("models/small", isDirectory: true)
        try FileManager.default.createDirectory(at: modelDirectory, withIntermediateDirectories: true)
        try "{}".write(to: modelDirectory.appendingPathComponent("config.json"), atomically: true, encoding: .utf8)
        try "synthetic-weights".write(
            to: modelDirectory.appendingPathComponent("model.safetensors"),
            atomically: true,
            encoding: .utf8
        )
        return root
    }
}

private actor OptimizationRecordingRunner: QwenCommandRunning {
    private(set) var synthesisCount = 0
    private let delay: Duration?
    private let silentSynthesisNumbers: Set<Int>
    private var firstSynthesisWaiters: [CheckedContinuation<Void, Never>] = []

    init(delay: Duration? = nil, silentSynthesisNumbers: Set<Int> = []) {
        self.delay = delay
        self.silentSynthesisNumbers = silentSynthesisNumbers
    }

    func waitForFirstSynthesis() async {
        guard synthesisCount == 0 else { return }
        await withCheckedContinuation { continuation in
            firstSynthesisWaiters.append(continuation)
        }
    }

    func run(_ command: QwenShellCommand) async throws -> QwenCommandResult {
        if command.redactedDescription.hasPrefix("qwen synthesize"),
           let outputIndex = command.arguments.firstIndex(of: "--output") {
            synthesisCount += 1
            let waiters = firstSynthesisWaiters
            firstSynthesisWaiters.removeAll()
            for waiter in waiters {
                waiter.resume()
            }
            if let delay {
                try await Task.sleep(for: delay)
            }
            let outputURL = URL(fileURLWithPath: command.arguments[outputIndex + 1])
            if silentSynthesisNumbers.contains(synthesisCount) {
                try Self.writeSilentWAV(to: outputURL)
            } else {
                try Self.writeTestWAV(to: outputURL)
            }
        }
        return QwenCommandResult(exitCode: 0, stdout: #"{"ok":true}"#, stderr: "")
    }

    private static func writeTestWAV(to url: URL) throws {
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        let format = AVAudioFormat(standardFormatWithSampleRate: 24_000, channels: 1)!
        let file = try AVAudioFile(forWriting: url, settings: format.settings)
        let frameCount = AVAudioFrameCount(2_400)
        let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: frameCount)!
        buffer.frameLength = frameCount
        let samples = buffer.floatChannelData![0]
        for frame in 0..<Int(frameCount) {
            samples[frame] = frame < 100 || frame > 2_300 ? 0 : 0.05
        }
        try file.write(from: buffer)
    }

    private static func writeSilentWAV(to url: URL) throws {
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        let format = AVAudioFormat(standardFormatWithSampleRate: 24_000, channels: 1)!
        let file = try AVAudioFile(forWriting: url, settings: format.settings)
        let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 2_400)!
        buffer.frameLength = 2_400
        let samples = buffer.floatChannelData![0]
        for frame in 0..<2_400 {
            samples[frame] = 0
        }
        try file.write(from: buffer)
    }
}

private final class CapacityProbe: @unchecked Sendable {
    private let lock = NSLock()
    private var storage = 0

    var count: Int {
        lock.withLock { storage }
    }

    func availableCapacity(_: URL) throws -> Int64? {
        lock.withLock { storage += 1 }
        return 20 * 1024 * 1024 * 1024
    }
}
