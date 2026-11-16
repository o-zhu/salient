import XCTest
@testable import SalientCore

final class ReadQuestionPipelineLatencyTests: XCTestCase {
    func testUWorldQuestionProgressRefusesNavigationAtStopQuestion() {
        let beforeStop = UWorldQuestionProgress(
            currentQuestion: 39,
            totalQuestions: 40,
            candidateCount: 40,
            activeCandidateCount: 1,
            minQuestionNumber: 1,
            maxQuestionNumber: 40,
            confidence: "active_numeric_rail"
        )
        let atStop = UWorldQuestionProgress(
            currentQuestion: 40,
            totalQuestions: 40,
            candidateCount: 40,
            activeCandidateCount: 1,
            minQuestionNumber: 1,
            maxQuestionNumber: 40,
            confidence: "active_numeric_rail"
        )
        let ambiguous = UWorldQuestionProgress(
            currentQuestion: nil,
            totalQuestions: 40,
            candidateCount: 40,
            activeCandidateCount: 0,
            minQuestionNumber: 1,
            maxQuestionNumber: 40,
            confidence: "unreliable"
        )
        let warningModal = UWorldQuestionProgress(
            currentQuestion: 12,
            totalQuestions: 40,
            candidateCount: 40,
            activeCandidateCount: 1,
            minQuestionNumber: 1,
            maxQuestionNumber: 40,
            blockingDialogDetected: true,
            confidence: "active_numeric_rail"
        )
        let progressText = UWorldQuestionProgress(
            currentQuestion: 39,
            totalQuestions: 40,
            candidateCount: 1,
            activeCandidateCount: 0,
            minQuestionNumber: 1,
            maxQuestionNumber: 40,
            confidence: "progress_text"
        )

        XCTAssertNil(beforeStop.navigationRefusalReason(stopBeforeQuestion: 40))
        XCTAssertNil(progressText.navigationRefusalReason(stopBeforeQuestion: 40))
        XCTAssertEqual(
            atStop.navigationRefusalReason(stopBeforeQuestion: 40),
            "question_40_at_or_after_stop_before_40"
        )
        XCTAssertEqual(
            ambiguous.navigationRefusalReason(stopBeforeQuestion: 40),
            "question_progress_unavailable"
        )
        XCTAssertEqual(
            warningModal.navigationRefusalReason(stopBeforeQuestion: 40),
            "blocking_dialog_detected"
        )
    }

    func testUWorldQuestionProgressEncodesOnlyNumericProgressMetadata() throws {
        let progress = UWorldQuestionProgress(
            currentQuestion: 1,
            totalQuestions: 40,
            candidateCount: 40,
            activeCandidateCount: 1,
            minQuestionNumber: 1,
            maxQuestionNumber: 40,
            confidence: "active_numeric_rail"
        )

        let encoded = String(data: try JSONEncoder().encode(progress), encoding: .utf8) ?? ""

        XCTAssertTrue(encoded.contains("currentQuestion"))
        XCTAssertTrue(encoded.contains("totalQuestions"))
        XCTAssertFalse(encoded.contains("text"))
        XCTAssertFalse(encoded.contains("pageUrl"))
        XCTAssertFalse(encoded.contains("title"))
        XCTAssertFalse(encoded.contains("href"))
        XCTAssertFalse(encoded.contains("/Users/"))
    }

    func testUWorldQuestionProgressScriptReturnsProgressJSONWithoutPageTextFields() {
        let script = UWorldQuestionProgressJavaScript.build()

        XCTAssertTrue(script.contains("currentQuestion"))
        XCTAssertTrue(script.contains("totalQuestions"))
        XCTAssertTrue(script.contains("progress_text"))
        XCTAssertFalse(script.contains("pageUrl"))
        XCTAssertFalse(script.contains("document.title"))
        XCTAssertFalse(script.contains("window.location"))
        XCTAssertFalse(script.contains("outerHTML"))
    }

    func testReadQuestionTraceEventsEncodeOnlySanitizedMetadata() throws {
        let privateText = "A 45-year-old private stem should never appear."
        let privateURL = "https://private.example.test/question/123"
        let privatePath = "/Users/example/private/screenshot.png"
        let events = [
            ReadQuestionTraceEvent(
                kind: .captureEnd,
                elapsedSeconds: 0.42,
                segmentCount: 3,
                sourceCharacterCount: privateText.count
            ),
            ReadQuestionTraceEvent(
                kind: .normalizationEnd,
                elapsedSeconds: 0.55,
                itemCount: 2,
                segmentID: "task#tail",
                itemIndex: 1,
                role: "question_task",
                region: "left",
                normalizedCharacterCount: 29,
                cachePolicy: .persistent
            ),
            ReadQuestionTraceEvent(
                kind: .actionFailed,
                elapsedSeconds: 0.60,
                errorCategory: "decode"
            )
        ]

        let encoded = String(data: try JSONEncoder().encode(events), encoding: .utf8) ?? ""

        XCTAssertTrue(encoded.contains("captureEnd"))
        XCTAssertTrue(encoded.contains("task#tail"))
        XCTAssertTrue(encoded.contains("persistent"))
        XCTAssertFalse(encoded.contains(privateText))
        XCTAssertFalse(encoded.contains(privateURL))
        XCTAssertFalse(encoded.contains(privatePath))
        XCTAssertFalse(encoded.contains("spokenText"))
        XCTAssertFalse(encoded.contains("pageURL"))
        XCTAssertFalse(encoded.contains("audioPath"))
    }

    func testNormalizedPlaybackItemIDsDoNotContainSpokenText() {
        let privateText = "A 45-year-old private stem should never be used as an item ID."
        let items = TTSNormalizer.normalizedPlaybackItems(from: [
            ReadPlanItem(segmentID: "private-stem", text: privateText)
        ])

        XCTAssertEqual(items.count, 1)
        XCTAssertTrue(items[0].id.contains("private-stem"))
        XCTAssertFalse(items[0].id.contains(privateText))
    }

    func testReadQuestionTraceSummaryCombinesPipelineHighlightAndPlaybackMetrics() throws {
        let readEvents = [
            ReadQuestionTraceEvent(kind: .actionStart, elapsedSeconds: 0),
            ReadQuestionTraceEvent(kind: .captureStart, elapsedSeconds: 0.10),
            ReadQuestionTraceEvent(kind: .captureEnd, elapsedSeconds: 0.42, segmentCount: 3),
            ReadQuestionTraceEvent(kind: .normalizationEnd, elapsedSeconds: 0.61, itemCount: 2),
            ReadQuestionTraceEvent(kind: .highlightStart, elapsedSeconds: 0.70, segmentID: "task#starter", itemIndex: 0),
            ReadQuestionTraceEvent(kind: .highlightEnd, elapsedSeconds: 0.95, segmentID: "task#starter", itemIndex: 0),
            ReadQuestionTraceEvent(kind: .highlightStart, elapsedSeconds: 1.20, segmentID: "task#tail", itemIndex: 1),
            ReadQuestionTraceEvent(kind: .highlightEnd, elapsedSeconds: 1.30, segmentID: "task#tail", itemIndex: 1),
            ReadQuestionTraceEvent(kind: .actionEnd, elapsedSeconds: 2.00)
        ]
        let qwenSummary = QwenPlaybackTraceSummary(events: [
            QwenPlaybackTraceEvent(kind: .playbackRenderStart, itemIndex: 0, segmentID: "task#starter", elapsedSeconds: 0.80),
            QwenPlaybackTraceEvent(kind: .playbackItemStart, itemIndex: 0, segmentID: "task#starter", elapsedSeconds: 0.90, durationSeconds: 0.25),
            QwenPlaybackTraceEvent(kind: .underrunWait, itemIndex: 1, segmentID: "task#tail", elapsedSeconds: 1.10),
            QwenPlaybackTraceEvent(kind: .playbackItemStart, itemIndex: 1, segmentID: "task#tail", elapsedSeconds: 1.30, durationSeconds: 0.50)
        ], rateMultiplier: 1.0)
        let audible = ReadQuestionAudibleSummary(
            firstAudibleAudioSeconds: 0.82,
            maxAudibleGapSeconds: 0.12,
            medianAudibleGapSeconds: 0.08,
            p95AudibleGapSeconds: 0.12
        )

        let summary = ReadQuestionTraceSummary(
            events: readEvents,
            qwenSummary: qwenSummary,
            audibleSummary: audible
        )

        XCTAssertEqual(try XCTUnwrap(summary.captureLatencySeconds), 0.32, accuracy: 0.0001)
        XCTAssertEqual(try XCTUnwrap(summary.planningLatencySeconds), 0.19, accuracy: 0.0001)
        XCTAssertEqual(try XCTUnwrap(summary.highlightP95Seconds), 0.2425, accuracy: 0.0001)
        XCTAssertEqual(try XCTUnwrap(summary.highlightMaxSeconds), 0.25, accuracy: 0.0001)
        XCTAssertEqual(try XCTUnwrap(summary.firstAudibleAudioSeconds), 0.82, accuracy: 0.0001)
        XCTAssertEqual(try XCTUnwrap(summary.maxAudibleGapSeconds), 0.12, accuracy: 0.0001)
        XCTAssertEqual(try XCTUnwrap(summary.appSideMaxGapSeconds), 0.15, accuracy: 0.0001)
        XCTAssertEqual(summary.underrunWaitCount, 1)
        XCTAssertEqual(summary.itemCount, 2)
        XCTAssertEqual(summary.validationWarnings, [String]())
    }

    func testReadQuestionTraceSummaryFlagsRealtimeThresholdsWithoutText() throws {
        let privateText = "A private question stem should not be serialized."
        let summary = ReadQuestionTraceSummary(
            events: [
                ReadQuestionTraceEvent(
                    kind: .actionStart,
                    elapsedSeconds: 0,
                    sourceCharacterCount: privateText.count
                )
            ],
            audibleSummary: ReadQuestionAudibleSummary(
                firstAudibleAudioSeconds: 1.20,
                maxAudibleGapSeconds: 0.42,
                medianAudibleGapSeconds: 0.10,
                p95AudibleGapSeconds: 0.28
            )
        )

        XCTAssertEqual(try XCTUnwrap(summary.firstAudibleAudioSeconds), 1.20, accuracy: 0.0001)
        XCTAssertEqual(try XCTUnwrap(summary.maxAudibleGapSeconds), 0.42, accuracy: 0.0001)
        XCTAssertEqual(try XCTUnwrap(summary.p95AudibleGapSeconds), 0.28, accuracy: 0.0001)
        XCTAssertTrue(summary.validationWarnings.isEmpty)

        let encoded = String(data: try JSONEncoder().encode(summary), encoding: .utf8) ?? ""
        XCTAssertFalse(encoded.contains(privateText))
        XCTAssertFalse(encoded.contains("spokenText"))
        XCTAssertFalse(encoded.contains("audioPath"))
    }

    func testReadQuestionTraceSummaryWarnsWhenRealtimeThresholdsAreExceeded() {
        let summary = ReadQuestionTraceSummary(
            events: [ReadQuestionTraceEvent(kind: .actionStart, elapsedSeconds: 0)],
            audibleSummary: ReadQuestionAudibleSummary(
                firstAudibleAudioSeconds: 2.01,
                maxAudibleGapSeconds: 0.501,
                medianAudibleGapSeconds: 0.10,
                p95AudibleGapSeconds: 0.301
            )
        )

        XCTAssertEqual(summary.validationWarnings, [
            "first_audio_over_2s",
            "max_gap_over_500ms",
            "p95_gap_over_300ms"
        ])
    }

    func testReadQuestionTraceSummaryEncodesAppSideLongGapCountsWithoutText() throws {
        let privateText = "A private live question sentence should not appear."
        let readEvents = [
            ReadQuestionTraceEvent(kind: .actionStart, elapsedSeconds: 0),
            ReadQuestionTraceEvent(kind: .captureStart, elapsedSeconds: 0.10),
            ReadQuestionTraceEvent(kind: .captureEnd, elapsedSeconds: 0.30, sourceCharacterCount: privateText.count),
            ReadQuestionTraceEvent(kind: .normalizationEnd, elapsedSeconds: 0.40, itemCount: 3),
            ReadQuestionTraceEvent(kind: .actionEnd, elapsedSeconds: 6.00, itemCount: 3)
        ]
        let qwenSummary = QwenPlaybackTraceSummary(events: [
            QwenPlaybackTraceEvent(
                kind: .playbackItemStart,
                itemIndex: 0,
                segmentID: "task#starter",
                elapsedSeconds: 0.70,
                durationSeconds: 0.20
            ),
            QwenPlaybackTraceEvent(
                kind: .playbackItemStart,
                itemIndex: 1,
                segmentID: "task#tail",
                elapsedSeconds: 2.00,
                durationSeconds: 0.40
            ),
            QwenPlaybackTraceEvent(
                kind: .playbackItemStart,
                itemIndex: 2,
                segmentID: "stem",
                elapsedSeconds: 4.70,
                durationSeconds: 0.50
            )
        ], rateMultiplier: 1.0)

        let summary = ReadQuestionTraceSummary(
            events: readEvents,
            qwenSummary: qwenSummary
        )
        let data = try JSONEncoder().encode(summary)
        let object = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])

        XCTAssertEqual(object["appSideLongGapOverOneSecondCount"] as? Int, 2)
        XCTAssertEqual(object["appSideLongGapOverTwoSecondCount"] as? Int, 1)
        XCTAssertEqual(object["appSideP95GapSeconds"] as? Double ?? -1, 2.24, accuracy: 0.0001)

        let encoded = String(data: data, encoding: .utf8) ?? ""
        XCTAssertFalse(encoded.contains(privateText))
        XCTAssertFalse(encoded.contains("A private live question"))
        XCTAssertFalse(encoded.contains("spokenText"))
    }

    @MainActor
    func testStudyActionRouterTracesDelayedHighlightWithoutPrivateText() async throws {
        let privateStem = "A 45-year-old private stem should never appear."
        let browser = DelayedHighlightBrowserAutomation(
            captureJSON: """
            {"mode":"question","segments":[
              {"id":"stem","text":"\(privateStem)","role":"stem","region":"left","rects":[{"x":0,"y":0,"width":1,"height":1}],"textNodePath":"0.0","startOffset":0,"endOffset":\(privateStem.utf16.count)},
              {"id":"task","text":"What should be reviewed?","role":"question_task","region":"left","rects":[{"x":0,"y":2,"width":1,"height":1}],"textNodePath":"0.1","startOffset":0,"endOffset":24}
            ]}
            """,
            highlightDelayNanoseconds: 500_000_000
        )
        let trace = ReadQuestionTraceRecorder()
        let router = StudyActionRouter(
            browser: browser,
            speech: ReadQuestionRecordingSpeechBackend(),
            traceSink: trace
        )

        let result = await router.run(.readQuestion)

        XCTAssertEqual(result.status, .succeeded)
        let events = await trace.snapshot()
        let highlightStarts = events.filter { $0.kind == .highlightStart }
        let highlightEnds = events.filter { $0.kind == .highlightEnd || $0.kind == .highlightLate }
        XCTAssertFalse(highlightStarts.isEmpty)
        XCTAssertEqual(highlightStarts.count, highlightEnds.count)
        let taskStart = try XCTUnwrap(highlightStarts.first { $0.segmentID == "task" }?.elapsedSeconds)
        let taskEnd = try XCTUnwrap(highlightEnds.first { $0.segmentID == "task" }?.elapsedSeconds)
        XCTAssertGreaterThanOrEqual(taskEnd - taskStart, 0.50)
        XCTAssertTrue(events.contains { $0.kind == .highlightLate && $0.segmentID == "task" })

        let encoded = String(data: try JSONEncoder().encode(events), encoding: .utf8) ?? ""
        XCTAssertTrue(encoded.contains("segmentID"))
        XCTAssertTrue(encoded.contains("task"))
        XCTAssertFalse(encoded.contains(privateStem))
        XCTAssertFalse(encoded.contains("What should be reviewed?"))
        XCTAssertFalse(encoded.contains("pageUrl"))
    }

    @MainActor
    func testStudyActionRouterIgnoresLateHighlightAfterSpeechCompletesAndClears() async throws {
        let eventLog = ReadQuestionEventLog()
        let browser = EventRecordingBrowserAutomation(captureJSON: """
        {"mode":"question","segments":[
          {"id":"stem","text":"A neutral synthetic stem.","role":"stem","region":"left","rects":[{"x":0,"y":0,"width":1,"height":1}],"textNodePath":"0.0","startOffset":0,"endOffset":25},
          {"id":"task","text":"What should be reviewed?","role":"question_task","region":"left","rects":[{"x":0,"y":2,"width":1,"height":1}],"textNodePath":"0.1","startOffset":0,"endOffset":24}
        ]}
        """, eventLog: eventLog)
        let router = StudyActionRouter(
            browser: browser,
            speech: LateWillSpeakBackend(delayNanoseconds: 120_000_000)
        )

        let result = await router.run(.readQuestion)
        try await Task.sleep(nanoseconds: 220_000_000)

        XCTAssertEqual(result.status, .succeeded)
        XCTAssertEqual(eventLog.events, ["capture", "clear"])
    }
}

private actor ReadQuestionTraceRecorder: ReadQuestionTraceSink {
    private var events: [ReadQuestionTraceEvent] = []

    func record(_ event: ReadQuestionTraceEvent) {
        events.append(event)
    }

    func snapshot() -> [ReadQuestionTraceEvent] {
        events
    }
}

@MainActor
private final class DelayedHighlightBrowserAutomation: BrowserAutomationService {
    let captureJSON: String
    let highlightDelayNanoseconds: UInt64

    init(captureJSON: String, highlightDelayNanoseconds: UInt64) {
        self.captureJSON = captureJSON
        self.highlightDelayNanoseconds = highlightDelayNanoseconds
    }

    func executeJavaScriptInUWorldTab(_ javaScript: String) async -> BrowserAutomationResult {
        if javaScript.contains("captureUWorldSegments") {
            return .success(captureJSON)
        }
        if javaScript.contains("return \"highlighted\"") {
            try? await Task.sleep(nanoseconds: highlightDelayNanoseconds)
            return .success("highlighted")
        }
        if javaScript.contains("return \"cleared\"") {
            return .success("cleared")
        }
        return .success("clicked")
    }
}

@MainActor
private final class ReadQuestionRecordingSpeechBackend: SpeechBackend {
    private(set) var spokenTexts: [String] = []

    func speak(_ text: String) async throws {
        spokenTexts.append(text)
    }

    func stop() async {}
}

@MainActor
private final class LateWillSpeakBackend: SpeechBackend {
    let delayNanoseconds: UInt64

    init(delayNanoseconds: UInt64) {
        self.delayNanoseconds = delayNanoseconds
    }

    func speak(_ text: String) async throws {}

    func speak(
        _ items: [SpeechPlaybackItem],
        willSpeak: @escaping @MainActor (SpeechPlaybackItem) async -> Void
    ) async throws {
        guard let first = items.first else { return }
        Task { @MainActor in
            try? await Task.sleep(nanoseconds: delayNanoseconds)
            await willSpeak(first)
        }
    }

    func stop() async {}
}

@MainActor
private final class EventRecordingBrowserAutomation: BrowserAutomationService {
    let captureJSON: String
    let eventLog: ReadQuestionEventLog

    init(captureJSON: String, eventLog: ReadQuestionEventLog) {
        self.captureJSON = captureJSON
        self.eventLog = eventLog
    }

    func executeJavaScriptInUWorldTab(_ javaScript: String) async -> BrowserAutomationResult {
        if javaScript.contains("captureUWorldSegments") {
            eventLog.events.append("capture")
            return .success(captureJSON)
        }
        if javaScript.contains("return \"highlighted\"") {
            eventLog.events.append("highlight")
            return .success("highlighted")
        }
        if javaScript.contains("return \"cleared\"") {
            eventLog.events.append("clear")
            return .success("cleared")
        }
        return .success("clicked")
    }
}

private final class ReadQuestionEventLog {
    var events: [String] = []
}
