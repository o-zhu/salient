import Foundation
import XCTest

@testable import SalientCore

final class QwenPerformanceContractTests: XCTestCase {
    func testNativeStreamingDefaultsOffAndCanBeExplicitlyEnabled() {
        XCTAssertFalse(QwenNativeStreamingPolicy.isEnabled(environment: [:]))
        XCTAssertTrue(QwenNativeStreamingPolicy.isEnabled(environment: [
            QwenNativeStreamingPolicy.environmentKey: QwenNativeStreamingPolicy.fastLaneValue
        ]))
        for disabledValue in ["0", "false", "NO", " off "] {
            XCTAssertFalse(QwenNativeStreamingPolicy.isEnabled(environment: [
                QwenNativeStreamingPolicy.environmentKey: disabledValue
            ]))
        }
    }

    func testInteractiveNativeStreamingRequiresExplicitLaneOptIn() {
        XCTAssertFalse(QwenNativeStreamingPolicy.isInteractiveStreamingEnabled(
            lane: .small,
            useReferenceVoice: false,
            environment: [:]
        ))
        XCTAssertTrue(QwenNativeStreamingPolicy.isInteractiveStreamingEnabled(
            lane: .small,
            useReferenceVoice: false,
            environment: [QwenNativeStreamingPolicy.environmentKey: QwenNativeStreamingPolicy.fastLaneValue]
        ))
        XCTAssertFalse(QwenNativeStreamingPolicy.isInteractiveStreamingEnabled(
            lane: .best,
            useReferenceVoice: false,
            environment: [QwenNativeStreamingPolicy.environmentKey: QwenNativeStreamingPolicy.fastLaneValue]
        ))
        XCTAssertFalse(QwenNativeStreamingPolicy.isInteractiveStreamingEnabled(
            lane: .small,
            useReferenceVoice: true,
            environment: [:]
        ))
        XCTAssertTrue(QwenNativeStreamingPolicy.isInteractiveStreamingEnabled(
            lane: .best,
            useReferenceVoice: true,
            environment: [QwenNativeStreamingPolicy.environmentKey: QwenNativeStreamingPolicy.allLanesValue]
        ))
    }

    func testFastWarmTargetsMatchPromotionGate() {
        let target = QwenPerformanceContract.interactiveTarget(
            lane: .small,
            useReferenceVoice: false,
            residencyState: .warm
        )
        XCTAssertEqual(target.firstPCMP95Seconds, 0.150)
        XCTAssertEqual(target.firstAudioP95Seconds, 0.350)
        XCTAssertEqual(target.firstAudioHardLimitSeconds, 0.500)
        XCTAssertEqual(target.synthesisRealTimeFactorP95, 0.30)
        XCTAssertEqual(QwenPerformanceContract.technicalGapHardLimitSeconds, 0.050)
    }

    func testPlaybackTraceSeparatesFirstPCMRenderAndAudio() throws {
        let events: [QwenPlaybackTraceEvent] = [
            .init(kind: .requestStart, elapsedSeconds: 0),
            .init(
                kind: .firstPCM,
                itemIndex: 0,
                segmentID: "synthetic-0",
                elapsedSeconds: 0.12,
                inferenceBackend: .nativeMLX,
                residencyState: .warm,
                generationElapsedSeconds: 0.08,
                modelLoadSeconds: 0,
                warmupSeconds: 0,
                peakMemoryBytes: 2_000_000_000,
                device: "gpu"
            ),
            .init(kind: .playbackRenderStart, itemIndex: 0, segmentID: "synthetic-0", elapsedSeconds: 0.24),
            .init(
                kind: .playbackItemStart,
                itemIndex: 0,
                segmentID: "synthetic-0",
                elapsedSeconds: 0.25,
                durationSeconds: 1.0
            ),
            .init(
                kind: .runtimePrepared,
                itemIndex: 0,
                segmentID: "synthetic-0",
                elapsedSeconds: 0.30,
                inferenceBackend: .nativeMLX,
                residencyState: .warm,
                realTimeFactor: 0.22,
                peakMemoryBytes: 2_300_000_000,
                device: "gpu"
            ),
        ]

        let summary = QwenPlaybackTraceSummary(events: events, rateMultiplier: 1)
        XCTAssertEqual(summary.firstPCMSeconds, 0.12)
        XCTAssertEqual(summary.firstRenderSeconds, 0.24)
        XCTAssertEqual(summary.firstAudioSeconds, 0.25)
        XCTAssertEqual(summary.inferenceBackendCounts[QwenInferenceBackend.nativeMLX.rawValue], 2)
        XCTAssertEqual(summary.residencyStateCounts[QwenRuntimeResidencyState.warm.rawValue], 2)
        XCTAssertEqual(summary.maxPeakMemoryBytes, 2_300_000_000)
        XCTAssertEqual(summary.p95RealTimeFactor, 0.22)
    }

    func testStreamingChunkMetadataRoundTripsWithoutNarrationText() throws {
        let chunk = QwenStreamingAudioChunk(
            requestID: "synthetic-request",
            itemIndex: 3,
            sequenceIndex: 2,
            sampleRate: 24_000,
            audioData: Data([0, 0, 0, 0]),
            durationSeconds: 1.0 / 24_000,
            isFinal: false,
            elapsedSeconds: 0.09,
            peakMemoryBytes: 2_300_000_000,
            backend: .nativeMLX,
            residencyState: .warm,
            modelLoadSeconds: 0,
            warmupSeconds: 0.02,
            realTimeFactor: 0.22,
            device: "gpu"
        )
        let data = try JSONEncoder().encode(chunk)
        let decoded = try JSONDecoder().decode(QwenStreamingAudioChunk.self, from: data)
        XCTAssertEqual(decoded, chunk)
        let json = try XCTUnwrap(String(data: data, encoding: .utf8))
        XCTAssertFalse(json.contains("text"))
        XCTAssertFalse(json.contains("path"))
    }

}
