import CryptoKit
import Foundation
import SalientCore

@main
struct SalientReadQuestionProbe {
    static func main() async {
        do {
            let options = try ProbeOptions.parse(Array(CommandLine.arguments.dropFirst()))
            if options.showHelp {
                print(ProbeOptions.usage)
                return
            }
            let output = try await ProbeRunner(options: options).run()
            print("Salient read-question probe complete")
            print("out_dir: \(displayPath(output.outDirectory))")
            print("read_trace: \(displayPath(output.readTraceURL))")
            print("qwen_trace: \(displayPath(output.qwenTraceURL))")
            print("question_progress: \(displayPath(output.questionProgressURL))")
            print("summary: \(displayPath(output.summaryURL))")
            print("iterations: \(output.summary.iterations)")
            print("item_count: \(output.summary.aggregate.itemCount)")
            if let firstAudio = output.summary.aggregate.firstAudioP95Seconds {
                print("first_audio_p95_seconds: \(String(format: "%.4f", firstAudio))")
            }
            if let maxGap = output.summary.aggregate.appSideMaxGapSeconds {
                print("app_side_max_gap_seconds: \(String(format: "%.4f", maxGap))")
            }
            if let p95Gap = output.summary.aggregate.appSideP95GapSeconds {
                print("app_side_p95_gap_seconds: \(String(format: "%.4f", p95Gap))")
            }
            print("app_side_gaps_over_1s: \(output.summary.aggregate.appSideLongGapOverOneSecondCount)")
            print("app_side_gaps_over_2s: \(output.summary.aggregate.appSideLongGapOverTwoSecondCount)")
            print("rsvp_skipped_cues: \(output.summary.aggregate.rsvpSkippedCueCount)")
            if let progressP95 = output.summary.aggregate.rsvpProgressGapP95Seconds {
                print("rsvp_progress_gap_p95_seconds: \(String(format: "%.4f", progressP95))")
            }
            if let queueP95 = output.summary.aggregate.queueSetupP95Seconds {
                print("queue_setup_p95_seconds: \(String(format: "%.4f", queueP95))")
            }
            if let subsequentQueueP95 = output.summary.aggregate.subsequentQueueSetupP95Seconds {
                print(
                    "subsequent_queue_setup_p95_seconds: \(String(format: "%.4f", subsequentQueueP95))"
                )
            }
            if let visualizationMax = output.summary.aggregate.visualizationFrameGapMaxSeconds {
                print("visualization_gap_max_seconds: \(String(format: "%.4f", visualizationMax))")
            }
        } catch let error as ProbeError {
            fputs("error: \(error.localizedDescription)\n", stderr)
            fputs("\n\(ProbeOptions.usage)\n", stderr)
            exit(1)
        } catch {
            fputs("error: \(error.localizedDescription)\n", stderr)
            exit(1)
        }
    }

    private static func displayPath(_ url: URL) -> String {
        let path = url.path
        let currentDirectory = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
            .standardizedFileURL.path
        if path == currentDirectory {
            return "."
        }
        let prefix = currentDirectory.hasSuffix("/") ? currentDirectory : currentDirectory + "/"
        if path.hasPrefix(prefix) {
            return String(path.dropFirst(prefix.count))
        }
        return url.lastPathComponent
    }
}

private struct ProbeRunner {
    var options: ProbeOptions

    @MainActor
    func run() async throws -> ProbeOutput {
        let lane = try options.lane()
        let speaker = options.speaker ?? lane.defaultSpeaker
        let runtime = QwenRuntimeManager(runtimeRoot: options.runtimeRoot)
        try FileManager.default.createDirectory(at: options.outDirectory, withIntermediateDirectories: true)

        if options.clearCache {
            try await runtime.clearCache()
        }
        let shouldPrewarmStarters = options.prewarmStarters && options.usesQuestionPromptAudioLibrary
        if shouldPrewarmStarters {
            let prewarmSpeaker = options.useReferenceVoice ? QwenReferenceVoiceDefaults.voiceName : speaker
            try await runtime.prewarm(
                lane: lane,
                speaker: prewarmSpeaker,
                useReferenceVoice: options.useReferenceVoice,
                referenceText: options.useReferenceVoice ? QwenReferenceVoiceDefaults.referenceText : nil
            )
            try await runtime.prewarmQuestionStarters(
                lane: lane,
                speaker: prewarmSpeaker,
                useReferenceVoice: options.useReferenceVoice,
                rateMultiplier: options.rateMultiplier
            )
        }
        let runStartedAt = Date()
        var readRecords: [ReadTraceRecord] = []
        var qwenRecords: [QwenTraceRecord] = []
        var progressRecords: [QuestionProgressRecord] = []
        var runSummaries: [ProbeIterationSummary] = []

        for iteration in 0..<options.iterations {
            let readTrace = ReadTraceRecorder()
            let qwenTrace = QwenTraceRecorder()
            let readAlongRecorder = ProbeReadAlongRecorder()
            let visualizationRecorder = ProbeVisualizationRecorder()
            let browser = try browserService()
            if options.action == .nextQuestionAndRead,
               let stopBeforeQuestion = options.stopBeforeQuestion {
                let progress = try await guardedQuestionProgress(
                    using: browser,
                    stopBeforeQuestion: stopBeforeQuestion
                )
                progressRecords.append(QuestionProgressRecord(
                    iteration: iteration,
                    phase: "before_navigation",
                    progress: progress
                ))
            }
            let settings = SpeechSettings(
                engineID: options.engineID,
                rateMultiplier: options.rateMultiplier,
                volume: options.volume,
                pitchMultiplier: 1.0,
                voiceIdentifier: nil,
                qwenSpeaker: speaker,
                qwenUseReferenceVoice: options.useReferenceVoice,
                qwenReferenceVoiceName: QwenReferenceVoiceDefaults.voiceName,
                qwenReferenceAudioPath: "",
                qwenReferenceText: QwenReferenceVoiceDefaults.referenceText,
                showPlaybackHUD: false,
                usesQuestionPromptAudioLibrary: options.usesQuestionPromptAudioLibrary
            )
            let speech = QwenSpeechBackend(
                settings: settings,
                runtime: runtime,
                playback: QwenAudioPlayback(),
                traceSink: qwenTrace
            )
            speech.visualizationSink = visualizationRecorder
            let router = StudyActionRouter(
                browser: browser,
                speech: speech,
                readPlanBuilder: ReadPlanBuilder(options: settings.readPlanOptions),
                traceSink: readTrace
            )
            router.readAlongPresentationSink = readAlongRecorder
            let result = await router.run(options.action.studyAction)
            if options.mode == .safariLive,
               options.action == .nextQuestionAndRead {
                if let progress = try? await questionProgress(using: browser) {
                    progressRecords.append(QuestionProgressRecord(
                        iteration: iteration,
                        phase: "after_read",
                        progress: progress
                    ))
                }
            }
            let readEvents = await readTrace.snapshot()
            let qwenEvents = await qwenTrace.snapshot()
            let qwenSummary = QwenPlaybackTraceSummary(
                events: qwenEvents,
                rateMultiplier: options.rateMultiplier
            )
            let readSummary = ReadQuestionTraceSummary(
                events: readEvents,
                qwenSummary: qwenSummary
            )

            readRecords.append(contentsOf: readEvents.map {
                ReadTraceRecord(iteration: iteration, event: $0)
            })
            qwenRecords.append(contentsOf: qwenEvents.map {
                QwenTraceRecord(iteration: iteration, event: $0)
            })
            runSummaries.append(ProbeIterationSummary(
                iteration: iteration,
                status: result.status == .succeeded ? "succeeded" : "failed",
                readSummary: readSummary,
                qwenSummary: qwenSummary,
                rsvpSync: readAlongRecorder.syncRecords(iteration: iteration),
                rsvpCueDispatch: readAlongRecorder.cueDispatchRecords(iteration: iteration),
                rsvpProgress: readAlongRecorder.progressSummary(),
                queueSetup: ProbeQueueSetupSummary(events: qwenEvents),
                visualization: visualizationRecorder.summary()
            ))
        }

        let manifest = ProbeManifest(
            createdAt: ISO8601DateFormatter().string(from: runStartedAt),
            mode: options.mode.rawValue,
            action: options.action.rawValue,
            iterations: options.iterations,
            engineID: options.engineID.rawValue,
            rateMultiplier: options.rateMultiplier,
            volume: options.volume,
            speaker: speaker,
            useReferenceVoice: options.useReferenceVoice,
            clearCache: options.clearCache,
            prewarmStarters: shouldPrewarmStarters,
            usesQuestionPromptAudioLibrary: options.usesQuestionPromptAudioLibrary,
            stopBeforeQuestion: options.stopBeforeQuestion,
            setupOnly: options.setupOnly,
            skipCapture: options.skipCapture,
            captureJSONSHA256: try captureJSONHash()
        )
        let summary = ProbeSummary(
            createdAt: manifest.createdAt,
            mode: manifest.mode,
            action: manifest.action,
            iterations: options.iterations,
            aggregate: ProbeAggregateSummary(summaries: runSummaries),
            runs: runSummaries
        )

        let manifestURL = options.outDirectory.appendingPathComponent("probe-manifest.json")
        let readTraceURL = options.outDirectory.appendingPathComponent("read-question-trace.json")
        let qwenTraceURL = options.outDirectory.appendingPathComponent("qwen-trace-events.json")
        let questionProgressURL = options.outDirectory.appendingPathComponent("question-progress.json")
        let summaryURL = options.outDirectory.appendingPathComponent("read-question-summary.json")
        try writeJSON(manifest, to: manifestURL)
        try writeJSON(readRecords, to: readTraceURL)
        try writeJSON(qwenRecords, to: qwenTraceURL)
        try writeJSON(progressRecords, to: questionProgressURL)
        try writeJSON(summary, to: summaryURL)
        return ProbeOutput(
            outDirectory: options.outDirectory,
            readTraceURL: readTraceURL,
            qwenTraceURL: qwenTraceURL,
            questionProgressURL: questionProgressURL,
            summaryURL: summaryURL,
            summary: summary
        )
    }

    @MainActor
    private func browserService() throws -> any BrowserAutomationService {
        switch options.mode {
        case .fixture:
            return ProbeBrowserAutomation(captureJSON: try Self.syntheticCaptureJSON())
        case .captureJSON:
            guard let captureJSONURL = options.captureJSONURL else {
                throw ProbeError.invalidArgument("--capture-json is required when --mode capture-json")
            }
            return ProbeBrowserAutomation(captureJSON: try String(contentsOf: captureJSONURL, encoding: .utf8))
        case .safariLive:
            return SafariAutomationService()
        }
    }

    private func captureJSONHash() throws -> String? {
        switch options.mode {
        case .fixture:
            return Self.sha256Hex(try Self.syntheticCaptureJSON())
        case .captureJSON:
            guard let captureJSONURL = options.captureJSONURL else { return nil }
            return Self.sha256Hex(try String(contentsOf: captureJSONURL, encoding: .utf8))
        case .safariLive:
            return nil
        }
    }

    private static func syntheticCaptureJSON() throws -> String {
        let payload = UWorldCapturePayload(
            requestId: "synthetic-read-question",
            mode: .question,
            segments: [
                CapturedSegment(
                    id: "synthetic-stem-1",
                    text: "A learner reviews a synthetic passage with several neutral details.",
                    role: .stem,
                    region: .left,
                    rect: CapturedRect(x: 20, y: 120, width: 520, height: 32)
                ),
                CapturedSegment(
                    id: "synthetic-stem-2",
                    text: "The passage is generic so timing artifacts remain safe.",
                    role: .stem,
                    region: .left,
                    rect: CapturedRect(x: 20, y: 160, width: 520, height: 32)
                ),
                CapturedSegment(
                    id: "synthetic-task",
                    text: "Which of the following findings best explains this synthetic pattern?",
                    role: .questionTask,
                    region: .left,
                    rect: CapturedRect(x: 20, y: 220, width: 520, height: 32)
                )
            ],
            viewport: CapturedViewport(width: 1280, height: 860)
        )
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        let data = try encoder.encode(payload)
        return String(decoding: data, as: UTF8.self)
    }

    private static func sha256Hex(_ text: String) -> String {
        SHA256.hash(data: Data(text.utf8)).map { String(format: "%02x", $0) }.joined()
    }

    private func writeJSON<T: Encodable>(_ value: T, to url: URL) throws {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        let data = try encoder.encode(value)
        try data.write(to: url, options: .atomic)
    }

    @MainActor
    private func guardedQuestionProgress(
        using browser: any BrowserAutomationService,
        stopBeforeQuestion: Int
    ) async throws -> UWorldQuestionProgress {
        let progress = try await questionProgress(using: browser)
        if !["active_numeric_rail", "progress_text"].contains(progress.confidence) {
            throw ProbeError.progressGuard(
                "Could not reliably detect UWorld question number; refusing to send ArrowRight."
            )
        }
        if let reason = progress.navigationRefusalReason(stopBeforeQuestion: stopBeforeQuestion) {
            throw ProbeError.progressGuard(
                "Question progress guard refused ArrowRight: \(reason)."
            )
        }
        return progress
    }

    @MainActor
    private func questionProgress(using browser: any BrowserAutomationService) async throws -> UWorldQuestionProgress {
        switch await browser.executeJavaScriptInUWorldTab(UWorldQuestionProgressJavaScript.build()) {
        case .success(let json):
            guard let data = json.data(using: .utf8) else {
                throw ProbeError.progressGuard("Question progress output was not UTF-8.")
            }
            return try JSONDecoder().decode(UWorldQuestionProgress.self, from: data)
        case .failure(let message):
            throw ProbeError.progressGuard(message)
        }
    }
}

private struct ProbeOutput {
    var outDirectory: URL
    var readTraceURL: URL
    var qwenTraceURL: URL
    var questionProgressURL: URL
    var summaryURL: URL
    var summary: ProbeSummary
}

private struct ProbeManifest: Codable {
    var createdAt: String
    var mode: String
    var action: String
    var iterations: Int
    var engineID: String
    var rateMultiplier: Double
    var volume: Double
    var speaker: String
    var useReferenceVoice: Bool
    var clearCache: Bool
    var prewarmStarters: Bool
    var usesQuestionPromptAudioLibrary: Bool
    var stopBeforeQuestion: Int?
    var setupOnly: Bool
    var skipCapture: Bool
    var captureJSONSHA256: String?
}

private struct ReadTraceRecord: Codable {
    var iteration: Int
    var event: ReadQuestionTraceEvent
}

private struct QwenTraceRecord: Codable {
    var iteration: Int
    var event: QwenPlaybackTraceEvent
}

private struct QuestionProgressRecord: Codable {
    var iteration: Int
    var phase: String
    var progress: UWorldQuestionProgress
}

private struct ProbeSummary: Codable {
    var createdAt: String
    var mode: String
    var action: String
    var iterations: Int
    var aggregate: ProbeAggregateSummary
    var runs: [ProbeIterationSummary]
}

private struct ProbeIterationSummary: Codable {
    var iteration: Int
    var status: String
    var readSummary: ReadQuestionTraceSummary
    var qwenSummary: QwenPlaybackTraceSummary
    var rsvpSync: [RSVPReadAlongSyncRecord]
    var rsvpCueDispatch: [RSVPCueDispatchRecord]
    var rsvpProgress: ProbeRSVPProgressSummary
    var queueSetup: ProbeQueueSetupSummary
    var visualization: ProbeVisualizationSummary
}

private struct ProbeRSVPProgressSummary: Codable {
    var callbackCount: Int
    var callbackGapP95Seconds: Double?
    var callbackGapMaxSeconds: Double?
    var callbackGapOver35MillisecondsCount: Int
    var expectedCueCount: Int
    var observedCueCount: Int
    var skippedCueCount: Int
    var largestTokenIndexJump: Int
}

private struct ProbeQueueSetupSummary: Codable {
    var count: Int
    var p95Seconds: Double?
    var maxSeconds: Double?
    var subsequentCount: Int
    var subsequentP95Seconds: Double?
    var subsequentMaxSeconds: Double?

    init(events: [QwenPlaybackTraceEvent]) {
        var pendingStart: Double?
        var durations: [Double] = []
        for event in events {
            switch event.kind {
            case .playbackQueueStart:
                pendingStart = event.elapsedSeconds
            case .playbackRenderStart:
                if let start = pendingStart, let end = event.elapsedSeconds, end >= start {
                    durations.append(end - start)
                }
                pendingStart = nil
            default:
                continue
            }
        }
        let subsequentDurations = Array(durations.dropFirst()).sorted()
        durations.sort()
        count = durations.count
        p95Seconds = Self.percentile(durations, 95)
        maxSeconds = durations.last
        subsequentCount = subsequentDurations.count
        subsequentP95Seconds = Self.percentile(subsequentDurations, 95)
        subsequentMaxSeconds = subsequentDurations.last
    }

    private static func percentile(_ sortedValues: [Double], _ pct: Double) -> Double? {
        guard !sortedValues.isEmpty else { return nil }
        let rank = min(1, max(0, pct / 100)) * Double(sortedValues.count - 1)
        let lower = Int(rank.rounded(.down))
        let upper = Int(rank.rounded(.up))
        guard lower != upper else { return sortedValues[lower] }
        let fraction = rank - Double(lower)
        return sortedValues[lower] * (1 - fraction) + sortedValues[upper] * fraction
    }
}

private struct ProbeVisualizationSummary: Codable {
    var frameCount: Int
    var frameGapP95Seconds: Double?
    var frameGapMaxSeconds: Double?
    var audioStartCount: Int
    var audioStopCount: Int
}

private struct RSVPReadAlongSyncRecord: Codable {
    var iteration: Int
    var itemID: String
    var segmentID: String
    var itemIndex: Int?
    var tokenCount: Int
    var audioDurationSeconds: Double
    var visualDurationSeconds: Double
    var leadSeconds: Double
    var didClampToMinimumTokenDuration: Bool
}

private struct RSVPCueDispatchRecord: Codable {
    var iteration: Int
    var itemID: String
    var segmentID: String
    var itemIndex: Int?
    var cueSource: SpeechPlaybackWordCueSource
    var cueReadinessSeconds: Double
    var tokenIndex: Int
    var sourcePositionSeconds: Double
    var desiredVisualLeadSeconds: Double
    var observedVisualLeadSeconds: Double
    var displayDispatchErrorSeconds: Double
    var alignmentRuntimeSeconds: Double?
    var tokenCoverage: Double
}

private struct ProbeAggregateSummary: Codable {
    var itemCount: Int
    var firstAudioP95Seconds: Double?
    var captureP95Seconds: Double?
    var planningP95Seconds: Double?
    var highlightP95Seconds: Double?
    var highlightMaxSeconds: Double?
    var appSideMaxGapSeconds: Double?
    var appSideP95GapSeconds: Double?
    var appSideLongGapOverOneSecondCount: Int
    var appSideLongGapOverTwoSecondCount: Int
    var underrunWaitCount: Int
    var rsvpSyncItemCount: Int
    var rsvpSyncMinimumDurationClampCount: Int
    var rsvpSyncAverageLeadSeconds: Double?
    var rsvpCueDispatchCount: Int
    var rsvpCueDispatchP95ErrorSeconds: Double?
    var rsvpCueDispatchMaxErrorSeconds: Double?
    var rsvpProgressCallbackCount: Int
    var rsvpProgressGapP95Seconds: Double?
    var rsvpProgressGapMaxSeconds: Double?
    var rsvpExpectedCueCount: Int
    var rsvpObservedCueCount: Int
    var rsvpSkippedCueCount: Int
    var rsvpLargestTokenIndexJump: Int
    var queueSetupCount: Int
    var queueSetupP95Seconds: Double?
    var queueSetupMaxSeconds: Double?
    var subsequentQueueSetupCount: Int
    var subsequentQueueSetupP95Seconds: Double?
    var subsequentQueueSetupMaxSeconds: Double?
    var visualizationFrameCount: Int
    var visualizationFrameGapP95Seconds: Double?
    var visualizationFrameGapMaxSeconds: Double?

    init(summaries: [ProbeIterationSummary]) {
        itemCount = summaries.map(\.readSummary.itemCount).max() ?? 0
        firstAudioP95Seconds = Self.percentile(
            summaries.compactMap(\.readSummary.firstAudibleAudioSeconds).sorted(),
            95
        )
        captureP95Seconds = Self.percentile(
            summaries.compactMap(\.readSummary.captureLatencySeconds).sorted(),
            95
        )
        planningP95Seconds = Self.percentile(
            summaries.compactMap(\.readSummary.planningLatencySeconds).sorted(),
            95
        )
        highlightP95Seconds = Self.percentile(
            summaries.compactMap(\.readSummary.highlightP95Seconds).sorted(),
            95
        )
        highlightMaxSeconds = summaries.compactMap(\.readSummary.highlightMaxSeconds).max()
        appSideMaxGapSeconds = summaries.compactMap(\.readSummary.appSideMaxGapSeconds).max()
        appSideP95GapSeconds = Self.percentile(
            summaries.compactMap(\.readSummary.appSideP95GapSeconds).sorted(),
            95
        )
        appSideLongGapOverOneSecondCount = summaries
            .map(\.readSummary.appSideLongGapOverOneSecondCount)
            .reduce(0, +)
        appSideLongGapOverTwoSecondCount = summaries
            .map(\.readSummary.appSideLongGapOverTwoSecondCount)
            .reduce(0, +)
        underrunWaitCount = summaries.map(\.readSummary.underrunWaitCount).reduce(0, +)
        let rsvpRecords = summaries.flatMap(\.rsvpSync)
        rsvpSyncItemCount = rsvpRecords.count
        rsvpSyncMinimumDurationClampCount = rsvpRecords
            .filter(\.didClampToMinimumTokenDuration)
            .count
        if rsvpRecords.isEmpty {
            rsvpSyncAverageLeadSeconds = nil
        } else {
            rsvpSyncAverageLeadSeconds = Self.rounded(
                rsvpRecords.map(\.leadSeconds).reduce(0, +) / Double(rsvpRecords.count)
            )
        }
        let cueRecords = summaries.flatMap(\.rsvpCueDispatch)
        let cueErrors = cueRecords.map(\.displayDispatchErrorSeconds).sorted()
        rsvpCueDispatchCount = cueRecords.count
        rsvpCueDispatchP95ErrorSeconds = Self.percentile(cueErrors, 95)
        rsvpCueDispatchMaxErrorSeconds = cueErrors.last.map(Self.rounded)
        rsvpProgressCallbackCount = summaries.map(\.rsvpProgress.callbackCount).reduce(0, +)
        rsvpProgressGapP95Seconds = Self.percentile(
            summaries.compactMap(\.rsvpProgress.callbackGapP95Seconds).sorted(),
            95
        )
        rsvpProgressGapMaxSeconds = summaries.compactMap(\.rsvpProgress.callbackGapMaxSeconds).max()
        rsvpExpectedCueCount = summaries.map(\.rsvpProgress.expectedCueCount).reduce(0, +)
        rsvpObservedCueCount = summaries.map(\.rsvpProgress.observedCueCount).reduce(0, +)
        rsvpSkippedCueCount = summaries.map(\.rsvpProgress.skippedCueCount).reduce(0, +)
        rsvpLargestTokenIndexJump = summaries.map(\.rsvpProgress.largestTokenIndexJump).max() ?? 0
        queueSetupCount = summaries.map(\.queueSetup.count).reduce(0, +)
        queueSetupP95Seconds = Self.percentile(
            summaries.compactMap(\.queueSetup.p95Seconds).sorted(),
            95
        )
        queueSetupMaxSeconds = summaries.compactMap(\.queueSetup.maxSeconds).max()
        subsequentQueueSetupCount = summaries.map(\.queueSetup.subsequentCount).reduce(0, +)
        subsequentQueueSetupP95Seconds = Self.percentile(
            summaries.compactMap(\.queueSetup.subsequentP95Seconds).sorted(),
            95
        )
        subsequentQueueSetupMaxSeconds = summaries.compactMap(\.queueSetup.subsequentMaxSeconds).max()
        visualizationFrameCount = summaries.map(\.visualization.frameCount).reduce(0, +)
        let visualizationP95 = summaries.compactMap(\.visualization.frameGapP95Seconds).sorted()
        visualizationFrameGapP95Seconds = Self.percentile(visualizationP95, 95)
        visualizationFrameGapMaxSeconds = summaries.compactMap(\.visualization.frameGapMaxSeconds).max()
    }

    private static func percentile(_ sortedValues: [Double], _ pct: Double) -> Double? {
        guard !sortedValues.isEmpty else { return nil }
        if pct <= 0 { return rounded(sortedValues[0]) }
        if pct >= 100 { return rounded(sortedValues[sortedValues.count - 1]) }
        let index = (Double(sortedValues.count - 1) * pct) / 100
        let lower = Int(index.rounded(.down))
        let upper = Int(index.rounded(.up))
        if lower == upper {
            return rounded(sortedValues[lower])
        }
        let fraction = index - Double(lower)
        return rounded(sortedValues[lower] * (1 - fraction) + sortedValues[upper] * fraction)
    }

    private static func rounded(_ value: Double) -> Double {
        (value * 10_000).rounded() / 10_000
    }
}

private actor ReadTraceRecorder: ReadQuestionTraceSink {
    private var events: [ReadQuestionTraceEvent] = []

    func record(_ event: ReadQuestionTraceEvent) {
        events.append(event)
    }

    func snapshot() -> [ReadQuestionTraceEvent] {
        events
    }
}

private actor QwenTraceRecorder: QwenPlaybackTracing {
    private var events: [QwenPlaybackTraceEvent] = []

    func record(_ event: QwenPlaybackTraceEvent) {
        events.append(event)
    }

    func snapshot() -> [QwenPlaybackTraceEvent] {
        events
    }
}

@MainActor
private final class ProbeVisualizationRecorder: SpeechPlaybackVisualizationSink {
    private var frameTimes: [Double] = []
    private var audioStartCount = 0
    private var audioStopCount = 0

    func speechPlaybackVisualizationDidStart() {}

    func speechPlaybackVisualizationAudioDidStart() {
        audioStartCount += 1
    }

    func speechPlaybackVisualizationAudioDidStop() {
        audioStopCount += 1
    }

    func speechPlaybackVisualizationLevelDidChange(_ level: Double) {}

    func speechPlaybackVisualizationFrameDidChange(_ frame: SpeechPlaybackVisualizationFrame) {
        frameTimes.append(ProcessInfo.processInfo.systemUptime)
    }

    func speechPlaybackVisualizationDidEnd() {}

    func summary() -> ProbeVisualizationSummary {
        let gaps = zip(frameTimes, frameTimes.dropFirst())
            .map { max(0, $1 - $0) }
            .sorted()
        return ProbeVisualizationSummary(
            frameCount: frameTimes.count,
            frameGapP95Seconds: Self.percentile(gaps, 95),
            frameGapMaxSeconds: gaps.last,
            audioStartCount: audioStartCount,
            audioStopCount: audioStopCount
        )
    }

    private static func percentile(_ sortedValues: [Double], _ pct: Double) -> Double? {
        guard !sortedValues.isEmpty else { return nil }
        let rank = min(1, max(0, pct / 100)) * Double(sortedValues.count - 1)
        let lower = Int(rank.rounded(.down))
        let upper = Int(rank.rounded(.up))
        guard lower != upper else { return sortedValues[lower] }
        let fraction = rank - Double(lower)
        return sortedValues[lower] * (1 - fraction) + sortedValues[upper] * fraction
    }
}

@MainActor
private final class ProbeReadAlongRecorder: ReadAlongPresentationSink {
    private var itemsByID: [String: SpeechPlaybackItem] = [:]
    private var timings: [SpeechPlaybackItemTiming] = []
    private var cueTracksByItemID: [String: SpeechPlaybackWordCueTrack] = [:]
    private var frozenCueTracksByItemID: [String: SpeechPlaybackWordCueTrack] = [:]
    private var cueReadinessByItemID: [String: Double] = [:]
    private var lastTokenIndexByItemID: [String: Int] = [:]
    private var cueDispatches: [RSVPCueDispatchRecord] = []
    private var progressCallbackTimes: [Double] = []
    private var observedCueKeys: Set<String> = []
    private var largestTokenIndexJump = 0
    private var startedUptime = ProcessInfo.processInfo.systemUptime

    func readAlongPresentationWillStart(items: [SpeechPlaybackItem], mode: CaptureMode) {
        startedUptime = ProcessInfo.processInfo.systemUptime
        merge(items)
    }

    func readAlongPresentationDidReceiveFinalPlaybackItems(_ items: [SpeechPlaybackItem], mode: CaptureMode) {
        itemsByID = [:]
        merge(items)
    }

    func readAlongPresentationDidReceiveTiming(_ timing: SpeechPlaybackItemTiming) {
        timings.append(timing)
        if let item = itemsByID[timing.itemID],
           let sourceDuration = timing.sourceAudioDurationSeconds,
           let track = RSVPReadAlongCueTrackBuilder().weightedFallbackTrack(
               item: item,
               itemIndex: timing.itemIndex,
               settings: .default,
               sourceAudioDurationSeconds: sourceDuration,
               audibleStartSeconds: timing.audibleStartSeconds,
               audibleEndSeconds: timing.audibleEndSeconds
           ) {
            readAlongPresentationDidReceiveWordCueTrack(track)
        }
    }

    func readAlongPresentationDidReceiveWordCueTrack(_ track: SpeechPlaybackWordCueTrack) {
        if cueTracksByItemID[track.itemID]?.source == .forcedAligned,
           track.source != .forcedAligned {
            return
        }
        cueTracksByItemID[track.itemID] = track
        cueReadinessByItemID[track.itemID] = max(
            0,
            ProcessInfo.processInfo.systemUptime - startedUptime
        )
    }

    func readAlongPresentationDidReceiveProgress(_ progress: SpeechPlaybackProgress) {
        progressCallbackTimes.append(ProcessInfo.processInfo.systemUptime)
        let track: SpeechPlaybackWordCueTrack
        if let frozen = frozenCueTracksByItemID[progress.itemID] {
            track = frozen
        } else if let available = cueTracksByItemID[progress.itemID] {
            frozenCueTracksByItemID[progress.itemID] = available
            track = available
        } else {
            return
        }
        guard
              let cueIndex = track.cueIndex(
                  at: progress.sourcePositionSeconds,
                  playbackRate: progress.playbackRate
              ),
              track.cues.indices.contains(cueIndex) else {
            return
        }
        let cue = track.cues[cueIndex]
        guard lastTokenIndexByItemID[progress.itemID] != cue.tokenIndex else { return }
        if let prior = lastTokenIndexByItemID[progress.itemID] {
            largestTokenIndexJump = max(largestTokenIndexJump, max(0, cue.tokenIndex - prior))
        } else {
            largestTokenIndexJump = max(largestTokenIndexJump, cue.tokenIndex + 1)
        }
        lastTokenIndexByItemID[progress.itemID] = cue.tokenIndex
        observedCueKeys.insert("\(progress.itemID)#\(cue.tokenIndex)")
        let nextStart = cueIndex + 1 < track.cues.count
            ? track.cues[cueIndex + 1].startSeconds
            : cue.endSeconds
        let playbackRate = min(2.4, max(0.5, progress.playbackRate))
        let desiredLead = cue.tokenIndex == 0
            ? 0
            : min(0.050, max(0, nextStart - cue.startSeconds) / playbackRate * 0.25)
        let observedLead = (cue.startSeconds - progress.sourcePositionSeconds) / playbackRate
        cueDispatches.append(RSVPCueDispatchRecord(
            iteration: 0,
            itemID: progress.itemID,
            segmentID: progress.segmentID,
            itemIndex: progress.itemIndex,
            cueSource: track.source,
            cueReadinessSeconds: cueReadinessByItemID[progress.itemID] ?? 0,
            tokenIndex: cue.tokenIndex,
            sourcePositionSeconds: progress.sourcePositionSeconds,
            desiredVisualLeadSeconds: desiredLead,
            observedVisualLeadSeconds: observedLead,
            displayDispatchErrorSeconds: abs(observedLead - desiredLead),
            alignmentRuntimeSeconds: track.alignmentRuntimeSeconds,
            tokenCoverage: track.tokenCoverage
        ))
    }

    func syncRecords(iteration: Int) -> [RSVPReadAlongSyncRecord] {
        timings.compactMap { timing in
            guard let item = itemsByID[timing.itemID] else { return nil }
            let tokenCount = RSVPReadingPlanBuilder.tokenCount(in: item.text)
            guard let adjustment = RSVPReadAlongTimingPolicy.default.adjustment(
                observedDurationSeconds: timing.durationSeconds,
                tokenCount: tokenCount
            ) else {
                return nil
            }
            return RSVPReadAlongSyncRecord(
                iteration: iteration,
                itemID: timing.itemID,
                segmentID: timing.segmentID,
                itemIndex: timing.itemIndex,
                tokenCount: tokenCount,
                audioDurationSeconds: timing.durationSeconds,
                visualDurationSeconds: adjustment.visualDurationSeconds,
                leadSeconds: adjustment.effectiveLeadSeconds,
                didClampToMinimumTokenDuration: adjustment.didClampToMinimumTokenDuration
            )
        }
    }

    func cueDispatchRecords(iteration: Int) -> [RSVPCueDispatchRecord] {
        cueDispatches.map { record in
            var record = record
            record.iteration = iteration
            return record
        }
    }

    func progressSummary() -> ProbeRSVPProgressSummary {
        let gaps = zip(progressCallbackTimes, progressCallbackTimes.dropFirst())
            .map { max(0, $1 - $0) }
            .sorted()
        let selectedTracks = cueTracksByItemID.mapValues { track in
            frozenCueTracksByItemID[track.itemID] ?? track
        }
        let expectedCueCount = selectedTracks.values.reduce(0) { $0 + $1.cues.count }
        return ProbeRSVPProgressSummary(
            callbackCount: progressCallbackTimes.count,
            callbackGapP95Seconds: percentile(gaps, 95),
            callbackGapMaxSeconds: gaps.last,
            callbackGapOver35MillisecondsCount: gaps.filter { $0 > 0.035 }.count,
            expectedCueCount: expectedCueCount,
            observedCueCount: observedCueKeys.count,
            skippedCueCount: max(0, expectedCueCount - observedCueKeys.count),
            largestTokenIndexJump: largestTokenIndexJump
        )
    }

    private func percentile(_ sortedValues: [Double], _ pct: Double) -> Double? {
        guard !sortedValues.isEmpty else { return nil }
        let rank = min(1, max(0, pct / 100)) * Double(sortedValues.count - 1)
        let lower = Int(rank.rounded(.down))
        let upper = Int(rank.rounded(.up))
        guard lower != upper else { return sortedValues[lower] }
        let fraction = rank - Double(lower)
        return sortedValues[lower] * (1 - fraction) + sortedValues[upper] * fraction
    }

    private func merge(_ items: [SpeechPlaybackItem]) {
        for item in items {
            itemsByID[item.id] = item
        }
    }
}

@MainActor
private final class ProbeBrowserAutomation: BrowserAutomationService {
    let captureJSON: String

    init(captureJSON: String) {
        self.captureJSON = captureJSON
    }

    func executeJavaScriptInUWorldTab(_ javaScript: String) async -> BrowserAutomationResult {
        if javaScript.contains("captureUWorldSegments") {
            return .success(captureJSON)
        }
        if javaScript.contains("ArrowRight") {
            return .success("pressed")
        }
        if javaScript.contains("return \"highlighted\"") {
            return .success("highlighted")
        }
        if javaScript.contains("return \"cleared\"") {
            return .success("cleared")
        }
        return .success("clicked")
    }
}

private struct ProbeOptions {
    var mode: ProbeMode = .fixture
    var action: ProbeAction = .readQuestion
    var iterations = 1
    var engineID: SpeechEngineID = .qwenSmall
    var rateMultiplier = SpeechSettings.default.rateMultiplier
    var volume = 1.0
    var speaker: String?
    var captureJSONURL: URL?
    var useReferenceVoice = false
    var clearCache = false
    var prewarmStarters = false
    var usesQuestionPromptAudioLibrary = true
    var stopBeforeQuestion: Int?
    var setupOnly = false
    var skipCapture = false
    var runtimeRoot: URL?
    var outDirectory = FileManager.default.temporaryDirectory
        .appendingPathComponent("salient-read-question-probe-\(Int(Date().timeIntervalSince1970))", isDirectory: true)
    var showHelp = false

    static let usage = """
    usage: swift run SalientReadQuestionProbe [options]

    Developer-only full Read Question timing probe. It writes privacy-safe JSON with counts, IDs, hashes, and durations only.

      --mode fixture|capture-json|safari-live
      --capture-json path                 Required for --mode capture-json
      --action readQuestion|nextQuestionAndRead
      --iterations count                  Default: 1
      --engine qwenSmall|qwenBest         Default: qwenSmall
      --rate value                        Playback rate multiplier. Default: 2.4
      --volume value                      Playback volume from 0.0 to 1.0. Default: 1.0
      --speaker name                      Qwen speaker. Default: lane default
      --use-reference-voice
      --clear-cache
      --prewarm-starters
      --disable-prompt-audio-library  Keep task prompts whole and skip prompt-library lookup/learning
      --stop-before-question number       Refuse nextQuestionAndRead when the detected current question is at or beyond this number
      --setup-only                       Run setup flags, write empty artifacts, and do not read/play audio
      --skip-capture                      Accepted for wrapper-script parity; the Swift probe never records WAVs
      --runtime-root path                 Isolated Qwen runtime root (models/venv/voices may be symlinked)
      --out-dir path
      --help
    """

    static func parse(_ arguments: [String]) throws -> ProbeOptions {
        var options = ProbeOptions()
        var index = 0
        while index < arguments.count {
            let argument = arguments[index]
            switch argument {
            case "--help", "-h":
                options.showHelp = true
            case "--mode":
                let value = try value(after: argument, in: arguments, at: &index)
                guard let mode = ProbeMode(rawValue: value) else {
                    throw ProbeError.invalidArgument("--mode must be fixture, capture-json, or safari-live")
                }
                options.mode = mode
            case "--capture-json":
                options.captureJSONURL = URL(fileURLWithPath: try value(after: argument, in: arguments, at: &index))
            case "--action":
                let value = try value(after: argument, in: arguments, at: &index)
                guard let action = ProbeAction(rawValue: value) else {
                    throw ProbeError.invalidArgument("--action must be readQuestion or nextQuestionAndRead")
                }
                options.action = action
            case "--iterations":
                options.iterations = try intValue(after: argument, in: arguments, at: &index)
            case "--engine":
                let value = try value(after: argument, in: arguments, at: &index)
                guard let engine = SpeechEngineID(rawValue: value), engine.qwenLane != nil else {
                    throw ProbeError.invalidArgument("--engine must be qwenSmall or qwenBest")
                }
                options.engineID = engine
            case "--rate":
                options.rateMultiplier = try doubleValue(after: argument, in: arguments, at: &index)
            case "--volume":
                options.volume = try doubleValue(after: argument, in: arguments, at: &index)
            case "--speaker":
                options.speaker = try value(after: argument, in: arguments, at: &index)
            case "--use-reference-voice":
                options.useReferenceVoice = true
            case "--clear-cache":
                options.clearCache = true
            case "--prewarm-starters":
                options.prewarmStarters = true
            case "--disable-prompt-audio-library":
                options.usesQuestionPromptAudioLibrary = false
            case "--stop-before-question":
                options.stopBeforeQuestion = try intValue(after: argument, in: arguments, at: &index)
            case "--setup-only":
                options.setupOnly = true
            case "--skip-capture":
                options.skipCapture = true
            case "--runtime-root":
                options.runtimeRoot = URL(
                    fileURLWithPath: try value(after: argument, in: arguments, at: &index),
                    isDirectory: true
                )
            case "--out-dir":
                options.outDirectory = URL(fileURLWithPath: try value(after: argument, in: arguments, at: &index), isDirectory: true)
            default:
                throw ProbeError.invalidArgument("unknown argument: \(argument)")
            }
            index += 1
        }
        options.iterations = options.setupOnly ? 0 : max(1, options.iterations)
        options.rateMultiplier = min(max(options.rateMultiplier, 0.5), 2.4)
        options.volume = min(max(options.volume, 0), 1)
        if let stopBeforeQuestion = options.stopBeforeQuestion, stopBeforeQuestion < 1 {
            throw ProbeError.invalidArgument("--stop-before-question must be 1 or greater")
        }
        return options
    }

    func lane() throws -> QwenModelLane {
        guard let lane = engineID.qwenLane else {
            throw ProbeError.invalidArgument("read-question probe only supports Qwen engines")
        }
        return lane
    }

    private static func value(after option: String, in arguments: [String], at index: inout Int) throws -> String {
        let valueIndex = index + 1
        guard valueIndex < arguments.count else {
            throw ProbeError.invalidArgument("missing value after \(option)")
        }
        index = valueIndex
        return arguments[valueIndex]
    }

    private static func doubleValue(after option: String, in arguments: [String], at index: inout Int) throws -> Double {
        let rawValue = try value(after: option, in: arguments, at: &index)
        guard let value = Double(rawValue) else {
            throw ProbeError.invalidArgument("\(option) requires a numeric value")
        }
        return value
    }

    private static func intValue(after option: String, in arguments: [String], at index: inout Int) throws -> Int {
        let rawValue = try value(after: option, in: arguments, at: &index)
        guard let value = Int(rawValue) else {
            throw ProbeError.invalidArgument("\(option) requires an integer value")
        }
        return value
    }
}

private enum ProbeMode: String {
    case fixture
    case captureJSON = "capture-json"
    case safariLive = "safari-live"
}

private enum ProbeAction: String {
    case readQuestion
    case nextQuestionAndRead

    var studyAction: StudyAction {
        switch self {
        case .readQuestion:
            return .readQuestion
        case .nextQuestionAndRead:
            return .nextQuestionAndRead
        }
    }
}

private enum ProbeError: LocalizedError {
    case invalidArgument(String)
    case progressGuard(String)

    var errorDescription: String? {
        switch self {
        case .invalidArgument(let message):
            message
        case .progressGuard(let message):
            message
        }
    }
}
