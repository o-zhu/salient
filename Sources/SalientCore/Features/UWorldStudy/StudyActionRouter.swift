import Foundation

public enum StudyAction: Equatable, Sendable {
    case readText(String)
    case submit
    case readQuestion
    case readExplanation
    case stopSpeech
    case nextQuestionAndRead

    public var title: String {
        switch self {
        case .readText: "Read Text"
        case .submit: "Submit"
        case .readQuestion: "Read Question"
        case .readExplanation: "Read Explanation"
        case .stopSpeech: "Stop Playback"
        case .nextQuestionAndRead: "Next + Read"
        }
    }
}

public enum StudyActionStatus: Equatable, Sendable {
    case succeeded
    case failed
}

public struct StudyActionResult: Equatable, Sendable {
    public var status: StudyActionStatus
    public var message: String

    public init(status: StudyActionStatus, message: String) {
        self.status = status
        self.message = message
    }

    public static func succeeded(_ message: String) -> StudyActionResult {
        StudyActionResult(status: .succeeded, message: message)
    }

    public static func failed(_ message: String) -> StudyActionResult {
        StudyActionResult(status: .failed, message: message)
    }
}

@MainActor
public protocol ReadAlongPresentationSink: AnyObject {
    func readAlongPresentationWillStart(items: [SpeechPlaybackItem], mode: CaptureMode)
    func readAlongPresentationDidReceiveFinalPlaybackItems(_ items: [SpeechPlaybackItem], mode: CaptureMode)
    func readAlongPresentationWillSpeak(item: SpeechPlaybackItem, itemIndex: Int)
    func readAlongPresentationDidReceiveTiming(_ timing: SpeechPlaybackItemTiming)
    func readAlongPresentationDidReceiveWordCueTrack(_ track: SpeechPlaybackWordCueTrack)
    func readAlongPresentationDidReceiveProgress(_ progress: SpeechPlaybackProgress)
    func readAlongPresentationDidFinishItem(item: SpeechPlaybackItem, itemIndex: Int)
    func readAlongPresentationDidEnd()
}

public extension ReadAlongPresentationSink {
    func readAlongPresentationWillStart(items: [SpeechPlaybackItem], mode: CaptureMode) {}
    func readAlongPresentationDidReceiveFinalPlaybackItems(_ items: [SpeechPlaybackItem], mode: CaptureMode) {}
    func readAlongPresentationWillSpeak(item: SpeechPlaybackItem, itemIndex: Int) {}
    func readAlongPresentationDidReceiveTiming(_ timing: SpeechPlaybackItemTiming) {}
    func readAlongPresentationDidReceiveWordCueTrack(_ track: SpeechPlaybackWordCueTrack) {}
    func readAlongPresentationDidReceiveProgress(_ progress: SpeechPlaybackProgress) {}
    func readAlongPresentationDidFinishItem(item: SpeechPlaybackItem, itemIndex: Int) {}
    func readAlongPresentationDidEnd() {}
}

@MainActor
public final class StudyActionRouter {
    private static let noUWorldMessage = "No UWorld tab found. Select your study tab and try again."
    private let browser: any BrowserAutomationService
    private let speech: any SpeechBackend
    private var readPlanBuilder: ReadPlanBuilder
    private let traceSink: (any ReadQuestionTraceSink)?
    private var hasBrowserHighlightSession = false
    private var highlightGeneration = UUID().uuidString
    private var activeReadAlongMode: CaptureMode?
    private var activeReadAlongItemIndexByID: [String: Int] = [:]
    private var activeReadAlongItemByID: [String: SpeechPlaybackItem] = [:]
    public weak var readAlongPresentationSink: (any ReadAlongPresentationSink)?

    public init(
        browser: any BrowserAutomationService,
        speech: any SpeechBackend,
        readPlanBuilder: ReadPlanBuilder = ReadPlanBuilder(),
        traceSink: (any ReadQuestionTraceSink)? = nil
    ) {
        self.browser = browser
        self.speech = speech
        self.readPlanBuilder = readPlanBuilder
        self.traceSink = traceSink
        if let timingSpeech = speech as? any SpeechPlaybackTimingReporting {
            timingSpeech.timingSink = self
        }
    }

    public func updateReadPlanOptions(_ options: ReadPlanOptions) {
        readPlanBuilder.options = options
    }

    public func run(_ action: StudyAction) async -> StudyActionResult {
        switch action {
        case .readText(let text):
            return await readText(text)
        case .submit:
            return await submit()
        case .readQuestion:
            return await read(mode: .question)
        case .readExplanation:
            return await read(mode: .explanation)
        case .stopSpeech:
            await speech.stop()
            invalidateHighlightGeneration()
            await clearHighlight()
            readAlongPresentationSink?.readAlongPresentationDidEnd()
            return .succeeded("Playback stopped.")
        case .nextQuestionAndRead:
            return await nextQuestionAndRead()
        }
    }

    private func submit() async -> StudyActionResult {
        switch await browser.executeJavaScriptInUWorldTab(SubmitJavaScript.build()) {
        case .success(let output):
            return output == "clicked"
                ? .succeeded("Clicked Submit.")
                : .failed(output)
        case .failure(let message):
            return .failed(message)
        }
    }

    /// Pasted text uses the same voice, cancellation, and word timing as browser reading,
    /// without accessing the browser or normalizing away content.
    private func readText(_ text: String) async -> StudyActionResult {
        let text = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return .failed("Add some text to start reading.") }
        let items = text.components(separatedBy: "\n\n")
            .filter { !$0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
            .enumerated().map { index, paragraph in
                SpeechPlaybackItem(id: "text-\(index)", segmentID: "text-\(index)", text: paragraph)
            }
        activeReadAlongMode = .question
        activeReadAlongItemIndexByID = Dictionary(uniqueKeysWithValues: items.enumerated().map { ($0.element.id, $0.offset) })
        activeReadAlongItemByID = Dictionary(uniqueKeysWithValues: items.map { ($0.id, $0) })
        defer {
            readAlongPresentationSink?.readAlongPresentationDidEnd()
            activeReadAlongMode = nil
            activeReadAlongItemIndexByID = [:]
            activeReadAlongItemByID = [:]
        }
        do {
            try Task.checkCancellation()
            readAlongPresentationSink?.readAlongPresentationWillStart(items: items, mode: .question)
            try await speech.speak(items) { [weak self] item in
                guard let self, let index = self.activeReadAlongItemIndexByID[item.id] else { return }
                self.readAlongPresentationSink?.readAlongPresentationWillSpeak(item: item, itemIndex: index)
            }
            return .succeeded("Finished reading.")
        } catch is CancellationError {
            await speech.stop()
            return .succeeded("Playback stopped.")
        } catch {
            return .failed("Could not read the text. \(error.localizedDescription)")
        }
    }

    private func read(mode: CaptureMode) async -> StudyActionResult {
        let startedAt = Date()
        let readHighlightGeneration = beginHighlightGeneration()
        await trace(.init(kind: .actionStart, elapsedSeconds: 0))
        do {
            try Task.checkCancellation()
        } catch {
            await trace(.init(kind: .actionCancelled, elapsedSeconds: elapsed(since: startedAt)))
            return await stopForCancellation()
        }

        let script = CaptureJavaScript.build(mode: mode)
        await trace(.init(kind: .captureStart, elapsedSeconds: elapsed(since: startedAt)))
        let output = await browser.executeJavaScriptInUWorldTab(script)

        guard case .success(let json) = output else {
            invalidateHighlightGeneration()
            await clearHighlight(startedAt: startedAt)
            await trace(.init(
                kind: .actionFailed,
                elapsedSeconds: elapsed(since: startedAt),
                errorCategory: "capture"
            ))
            if case .failure(let message) = output { return .failed(message) }
            return .failed("Could not capture browser content.")
        }
        await trace(.init(
            kind: .captureEnd,
            elapsedSeconds: elapsed(since: startedAt),
            sourceCharacterCount: json.count
        ))

        let payload: UWorldCapturePayload
        do {
            payload = try UWorldCapturePayload.decode(json: json)
        } catch {
            invalidateHighlightGeneration()
            await clearHighlight(startedAt: startedAt)
            await trace(.init(
                kind: .actionFailed,
                elapsedSeconds: elapsed(since: startedAt),
                errorCategory: "decode"
            ))
            return .failed("Could not parse captured browser content: \(error.localizedDescription)")
        }
        await trace(.init(
            kind: .decodeEnd,
            elapsedSeconds: elapsed(since: startedAt),
            segmentCount: payload.segments.count,
            sourceCharacterCount: payload.segments.reduce(0) { $0 + $1.text.count }
        ))

        let plan = mode == .question
            ? readPlanBuilder.questionPlan(from: payload)
            : readPlanBuilder.explanationPlan(from: payload.segments)
        await trace(.init(
            kind: .planBuilt,
            elapsedSeconds: elapsed(since: startedAt),
            segmentCount: payload.segments.count,
            itemCount: plan.items.count,
            sourceCharacterCount: plan.items.reduce(0) { $0 + $1.text.count }
        ))
        guard !plan.items.isEmpty else {
            invalidateHighlightGeneration()
            await clearHighlight(startedAt: startedAt)
            await trace(.init(
                kind: .actionFailed,
                elapsedSeconds: elapsed(since: startedAt),
                errorCategory: "empty_plan"
            ))
            return .failed("No readable study text was found.")
        }

        let segmentsByID = Dictionary(payload.segments.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        let playbackItems = TTSNormalizer.normalizedPlaybackItems(from: plan.items)
        await trace(.init(
            kind: .normalizationEnd,
            elapsedSeconds: elapsed(since: startedAt),
            itemCount: playbackItems.count,
            sourceCharacterCount: plan.items.reduce(0) { $0 + $1.text.count },
            normalizedCharacterCount: playbackItems.reduce(0) { $0 + $1.text.count }
        ))
        guard !playbackItems.isEmpty else {
            invalidateHighlightGeneration()
            await clearHighlight(startedAt: startedAt)
            await trace(.init(
                kind: .actionFailed,
                elapsedSeconds: elapsed(since: startedAt),
                errorCategory: "empty_normalized_plan"
            ))
            return .failed("No readable study text was found.")
        }
        let itemIndexByID = Dictionary(uniqueKeysWithValues: playbackItems.enumerated().map { index, item in
            (item.id, index)
        })
        activeReadAlongMode = mode
        activeReadAlongItemIndexByID = itemIndexByID
        activeReadAlongItemByID = Dictionary(uniqueKeysWithValues: playbackItems.map { ($0.id, $0) })
        var didStartReadAlongPresentation = false

        do {
            try Task.checkCancellation()
            readAlongPresentationSink?.readAlongPresentationWillStart(items: playbackItems, mode: mode)
            didStartReadAlongPresentation = true
            await trace(.init(
                kind: .speechStart,
                elapsedSeconds: elapsed(since: startedAt),
                itemCount: playbackItems.count
            ))
            try await speech.speak(playbackItems) { [weak self] item in
                guard let self else { return }
                if let itemIndex = self.activeReadAlongItemIndexByID[item.id] ?? itemIndexByID[item.id] {
                    self.readAlongPresentationSink?.readAlongPresentationWillSpeak(item: item, itemIndex: itemIndex)
                }
                await self.highlight(
                    item,
                    segmentsByID: segmentsByID,
                    itemIndex: itemIndexByID[item.id],
                    startedAt: startedAt,
                    generation: readHighlightGeneration
                )
            }
            await trace(.init(
                kind: .speechEnd,
                elapsedSeconds: elapsed(since: startedAt),
                itemCount: playbackItems.count
            ))
            readAlongPresentationSink?.readAlongPresentationDidEnd()
            activeReadAlongMode = nil
            activeReadAlongItemIndexByID = [:]
            activeReadAlongItemByID = [:]
            invalidateHighlightGeneration()
            await clearHighlight(startedAt: startedAt)
            await trace(.init(
                kind: .actionEnd,
                elapsedSeconds: elapsed(since: startedAt),
                itemCount: playbackItems.count
            ))
            return .succeeded("Read \(playbackItems.count) segment\(playbackItems.count == 1 ? "" : "s").")
        } catch is CancellationError {
            if didStartReadAlongPresentation {
                readAlongPresentationSink?.readAlongPresentationDidEnd()
            }
            activeReadAlongMode = nil
            activeReadAlongItemIndexByID = [:]
            activeReadAlongItemByID = [:]
            await trace(.init(kind: .actionCancelled, elapsedSeconds: elapsed(since: startedAt)))
            return await stopForCancellation()
        } catch {
            if didStartReadAlongPresentation {
                readAlongPresentationSink?.readAlongPresentationDidEnd()
            }
            activeReadAlongMode = nil
            activeReadAlongItemIndexByID = [:]
            activeReadAlongItemByID = [:]
            invalidateHighlightGeneration()
            await clearHighlight(startedAt: startedAt)
            await trace(.init(
                kind: .actionFailed,
                elapsedSeconds: elapsed(since: startedAt),
                itemCount: playbackItems.count,
                errorCategory: "speech"
            ))
            return .failed("Could not read captured study text: \(error.localizedDescription)")
        }
    }

    private func nextQuestionAndRead() async -> StudyActionResult {
        switch await browser.executeJavaScriptInUWorldTab(Self.rightArrowPressScript) {
        case .failure(let message):
            if Self.isNoUWorldMessage(message) {
                return .failed(Self.noUWorldMessage)
            }
            return .failed(message)
        default:
            break
        }

        return await read(mode: .question)
    }

    private static func isNoUWorldMessage(_ message: String) -> Bool {
        message.lowercased().contains("no uworld tab")
    }

    private func stopForCancellation() async -> StudyActionResult {
        await speech.stop()
        invalidateHighlightGeneration()
        await clearHighlight()
        return .succeeded("Playback stopped.")
    }

    private func highlight(
        _ item: ReadPlanItem,
        segmentsByID: [String: CapturedSegment],
        itemIndex: Int? = nil,
        startedAt: Date? = nil,
        generation: String? = nil
    ) async {
        guard generation == nil || generation == highlightGeneration else { return }
        guard let segment = highlightedSegment(for: item, segmentsByID: segmentsByID) else { return }
        let highlightStartedAt = Date()
        if let startedAt {
            await trace(.init(
                kind: .highlightStart,
                elapsedSeconds: elapsed(since: startedAt),
                segmentID: segment.id,
                itemIndex: itemIndex,
                role: segment.role.rawValue,
                region: segment.region.rawValue,
                sourceCharacterCount: segment.text.count
            ))
        }
        _ = await browser.executeJavaScriptInUWorldTab(HighlightJavaScript.build(segment: segment))
        if let startedAt {
            let highlightDuration = Date().timeIntervalSince(highlightStartedAt)
            await trace(.init(
                kind: highlightDuration > 0.150 ? .highlightLate : .highlightEnd,
                elapsedSeconds: elapsed(since: startedAt),
                segmentID: segment.id,
                itemIndex: itemIndex,
                role: segment.role.rawValue,
                region: segment.region.rawValue,
                sourceCharacterCount: segment.text.count
            ))
        }
    }

    private func highlight(
        _ item: SpeechPlaybackItem,
        segmentsByID: [String: CapturedSegment],
        itemIndex: Int? = nil,
        startedAt: Date? = nil,
        generation: String? = nil
    ) async {
        let readPlanItem = ReadPlanItem(segmentID: item.segmentID, text: item.sourceText)
        await highlight(
            readPlanItem,
            segmentsByID: segmentsByID,
            itemIndex: itemIndex,
            startedAt: startedAt,
            generation: generation
        )
    }

    private func clearHighlight(startedAt: Date? = nil) async {
        guard hasBrowserHighlightSession else { return }
        hasBrowserHighlightSession = false
        if let startedAt {
            await trace(.init(
                kind: .highlightStart,
                elapsedSeconds: elapsed(since: startedAt),
                segmentID: "__clear__"
            ))
        }
        _ = await browser.executeJavaScriptInUWorldTab(HighlightJavaScript.clear())
        if let startedAt {
            await trace(.init(
                kind: .highlightEnd,
                elapsedSeconds: elapsed(since: startedAt),
                segmentID: "__clear__"
            ))
        }
    }

    private func highlightedSegment(
        for item: ReadPlanItem,
        segmentsByID: [String: CapturedSegment]
    ) -> CapturedSegment? {
        let segmentIDParts = item.segmentID.split(separator: "#", maxSplits: 1).map(String.init)
        let baseSegmentID = segmentIDParts.first ?? item.segmentID
        guard var segment = segmentsByID[baseSegmentID] else { return nil }
        if segmentIDParts.count == 2,
           ["starter", "tail"].contains(segmentIDParts[1]) {
            return segment
        }

        let itemText = item.text.trimmedForSpeech
        let segmentText = segment.text.trimmedForSpeech
        guard itemText != segmentText,
              let originalStartOffset = segment.startOffset else {
            return segment
        }

        let range = (segment.text as NSString).range(of: itemText)
        guard range.location != NSNotFound else { return segment }

        segment.text = itemText
        segment.startOffset = originalStartOffset + range.location
        segment.endOffset = originalStartOffset + range.location + range.length
        return segment
    }

    private static let rightArrowPressScript = """
    (function () {
      var target = document.activeElement || document.body;
      var eventInit = {
        key: "ArrowRight",
        code: "ArrowRight",
        keyCode: 39,
        which: 39,
        bubbles: true,
        cancelable: true
      };
      var keyDown = new KeyboardEvent("keydown", eventInit);
      var keyUp = new KeyboardEvent("keyup", eventInit);
      target.dispatchEvent(keyDown);
      target.dispatchEvent(keyUp);
      return "pressed";
    })()
    """

    private func trace(_ event: ReadQuestionTraceEvent) async {
        await traceSink?.record(event)
    }

    private func elapsed(since start: Date) -> Double {
        Date().timeIntervalSince(start)
    }

    private func beginHighlightGeneration() -> String {
        hasBrowserHighlightSession = true
        let generation = UUID().uuidString
        highlightGeneration = generation
        return generation
    }

    private func invalidateHighlightGeneration() {
        highlightGeneration = UUID().uuidString
    }
}

extension StudyActionRouter: SpeechPlaybackTimingSink {
    public func speechPlaybackWillUseFinalItems(_ items: [SpeechPlaybackItem]) {
        guard let mode = activeReadAlongMode else { return }
        activeReadAlongItemIndexByID = Dictionary(uniqueKeysWithValues: items.enumerated().map { index, item in
            (item.id, index)
        })
        activeReadAlongItemByID = Dictionary(uniqueKeysWithValues: items.map { ($0.id, $0) })
        readAlongPresentationSink?.readAlongPresentationDidReceiveFinalPlaybackItems(items, mode: mode)
    }

    public func speechPlaybackDidReceiveTiming(_ timing: SpeechPlaybackItemTiming) {
        guard activeReadAlongMode != nil else { return }
        readAlongPresentationSink?.readAlongPresentationDidReceiveTiming(timing)
    }

    public func speechPlaybackDidReceiveWordCueTrack(_ track: SpeechPlaybackWordCueTrack) {
        guard activeReadAlongMode != nil else { return }
        readAlongPresentationSink?.readAlongPresentationDidReceiveWordCueTrack(track)
    }

    public func speechPlaybackDidReceiveProgress(_ progress: SpeechPlaybackProgress) {
        guard activeReadAlongMode != nil else { return }
        readAlongPresentationSink?.readAlongPresentationDidReceiveProgress(progress)
    }

    public func speechPlaybackDidFinishItem(itemID: String, segmentID: String, itemIndex: Int?) {
        guard activeReadAlongMode != nil,
              let item = activeReadAlongItemByID[itemID] else {
            return
        }
        let resolvedIndex = itemIndex ?? activeReadAlongItemIndexByID[itemID] ?? 0
        readAlongPresentationSink?.readAlongPresentationDidFinishItem(item: item, itemIndex: resolvedIndex)
    }
}
