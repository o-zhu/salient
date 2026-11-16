import Foundation
import OSLog

protocol QwenAudioSynthesizing: Sendable {
    func synthesize(
        text: String,
        lane: QwenModelLane,
        speaker: String,
        language: String,
        rateMultiplier: Double,
        cachePolicy: QwenAudioCachePolicy,
        useReferenceVoice: Bool,
        referenceAudioPath: String?,
        referenceText: String?
    ) async throws -> QwenPreparedAudio

    func synthesizeBatch(_ requests: [QwenSynthesisRequest]) async throws -> [QwenPreparedAudio]
}

protocol QwenAdjustableDeEsserSynthesizing: Sendable {
    func synthesize(_ request: QwenSynthesisRequest) async throws -> QwenPreparedAudio
}

extension QwenAudioSynthesizing {
    func synthesizeBatch(_ requests: [QwenSynthesisRequest]) async throws -> [QwenPreparedAudio] {
        var prepared: [QwenPreparedAudio] = []
        prepared.reserveCapacity(requests.count)
        for request in requests {
            try Task.checkCancellation()
            prepared.append(try await synthesize(
                text: request.text,
                lane: request.lane,
                speaker: request.speaker,
                language: request.language,
                rateMultiplier: request.rateMultiplier,
                cachePolicy: request.cachePolicy,
                useReferenceVoice: request.useReferenceVoice,
                referenceAudioPath: request.referenceAudioPath,
                referenceText: request.referenceText
            ))
        }
        return prepared
    }
}

protocol QwenPromptAudioLibraryServing: Sendable {
    func promptAudioLibraryContext(
        lane: QwenModelLane,
        speaker: String,
        language: String,
        useReferenceVoice: Bool,
        referenceAudioPath: String?,
        referenceText: String?
    ) async throws -> QwenPromptAudioLibraryContext

    func restorePromptLibraryAudioIfAvailable(
        text: String,
        context: QwenPromptAudioLibraryContext,
        rateMultiplier: Double
    ) async throws -> Bool

    func learnPromptAudio(
        text: String,
        derivedPrefixTexts: [String],
        context: QwenPromptAudioLibraryContext
    ) async
}

extension QwenRuntimeManager: QwenAudioSynthesizing {}
extension QwenRuntimeManager: QwenAdjustableDeEsserSynthesizing {}
extension QwenRuntimeManager: QwenAudioStreaming {}
extension QwenRuntimeManager: QwenPromptAudioLibraryServing {}

struct QwenPreparedPlaybackItem: Equatable, Sendable {
    var index: Int
    var item: SpeechPlaybackItem
    var audio: QwenPreparedAudio
}

private struct QwenStreamingPlaybackEntry: Sendable {
    var index: Int
    var item: SpeechPlaybackItem
    var cachePolicy: QwenAudioCachePolicy
    var chunks: AsyncThrowingStream<QwenStreamingAudioChunk, Error>
}

private struct QwenPromptLibraryCandidate: Sendable {
    var fullText: String
    var replacementRange: Range<Int>
    var replacementItem: SpeechPlaybackItem
}

private struct QwenPromptLibraryLearning: Sendable {
    var service: any QwenPromptAudioLibraryServing
    var text: String
    var derivedPrefixTexts: [String]
    var context: QwenPromptAudioLibraryContext

    var key: String {
        "\(context.contextHash)|\(QwenPromptAudioLibrary.hashText(text))"
    }
}

private struct QwenPromptLibraryPlaybackPlan: Sendable {
    var items: [SpeechPlaybackItem]
    var learning: QwenPromptLibraryLearning?
    var usedLibraryHit: Bool
}

private actor QwenPromptLibraryLearningScheduler {
    private enum ActiveLearningPhase {
        case quietDelay
        case running
    }

    private var activeNarrationCount = 0
    private var pendingLearning: [QwenPromptLibraryLearning] = []
    private var activeLearningTask: Task<Void, Never>?
    private var activeLearning: QwenPromptLibraryLearning?
    private var activeLearningID: UUID?
    private var activeLearningPhase: ActiveLearningPhase?
    private let quietDelayNanoseconds: UInt64
    private let maximumPendingLearningCount = 16

    init(quietDelayNanoseconds: UInt64 = 350_000_000) {
        self.quietDelayNanoseconds = quietDelayNanoseconds
    }

    func narrationWillStart() {
        activeNarrationCount += 1
        guard let task = activeLearningTask else { return }
        if activeLearningPhase == .quietDelay, let activeLearning {
            enqueue(activeLearning, atFront: true)
        }
        task.cancel()
        activeLearningTask = nil
        activeLearning = nil
        activeLearningID = nil
        activeLearningPhase = nil
    }

    func narrationDidFinish(learning: QwenPromptLibraryLearning?) {
        activeNarrationCount = max(0, activeNarrationCount - 1)
        if let learning {
            enqueue(learning)
        }
        startNextIfIdle()
    }

    func narrationDidAbort() {
        activeNarrationCount = max(0, activeNarrationCount - 1)
        startNextIfIdle()
    }

    private func startNextIfIdle() {
        guard activeNarrationCount == 0,
              activeLearningTask == nil,
              !pendingLearning.isEmpty else {
            return
        }

        let learning = pendingLearning.removeFirst()
        let learningID = UUID()
        let quietDelayNanoseconds = quietDelayNanoseconds
        activeLearning = learning
        activeLearningID = learningID
        activeLearningPhase = .quietDelay
        activeLearningTask = Task.detached(priority: .utility) {
            try? await Task.sleep(nanoseconds: quietDelayNanoseconds)
            guard !Task.isCancelled,
                  await self.markLearningRunning(id: learningID) else {
                await self.learningDidComplete(id: learningID)
                return
            }
            await learning.service.learnPromptAudio(
                text: learning.text,
                derivedPrefixTexts: learning.derivedPrefixTexts,
                context: learning.context
            )
            await self.learningDidComplete(id: learningID)
        }
    }

    private func enqueue(_ learning: QwenPromptLibraryLearning, atFront: Bool = false) {
        guard (atFront || activeLearning?.key != learning.key),
              !pendingLearning.contains(where: { $0.key == learning.key }) else {
            return
        }
        if atFront {
            pendingLearning.insert(learning, at: 0)
        } else {
            pendingLearning.append(learning)
        }
        if pendingLearning.count > maximumPendingLearningCount {
            if atFront {
                pendingLearning.removeLast(pendingLearning.count - maximumPendingLearningCount)
            } else {
                pendingLearning.removeFirst(pendingLearning.count - maximumPendingLearningCount)
            }
        }
    }

    private func markLearningRunning(id: UUID) -> Bool {
        guard activeLearningID == id,
              activeNarrationCount == 0 else {
            return false
        }
        activeLearningPhase = .running
        return true
    }

    private func learningDidComplete(id: UUID) {
        guard activeLearningID == id else { return }
        activeLearningTask = nil
        activeLearning = nil
        activeLearningID = nil
        activeLearningPhase = nil
        startNextIfIdle()
    }
}

public enum QwenPlaybackPolicyState: String, Codable, Equatable, Sendable {
    case normal
    case degraded
}

private struct QwenFastStartPolicy: Sendable {
    var targetFirstAudioSeconds = 1.0
    var cachedStarterFirstAudioSeconds = 0.35
    var fallbackFirstAudioSeconds = 2.0
    var targetInitialRunwaySeconds = 0.8
    var hardGapCapSeconds = 0.5
}

public struct QwenPlaybackTraceEvent: Codable, Equatable, Sendable {
    public enum Kind: String, Codable, Sendable {
        case requestStart
        case promptToSynthesizeStart
        case synthesisBatchStart
        case synthesisBatchComplete
        case synthesisComplete
        case prepared
        case firstPrepared
        case initialBufferWait
        case underrunWait
        case playbackBatchStart
        case playbackItemStart
        case playbackItemEnd
        case playbackBufferEnqueue
        case playbackQueueStart
        case playbackRenderStart
        case playbackQueueEnd
        case firstPCM
        case runtimePrepared
        case runtimeFallback
        case playbackUnderrun
        case playbackRebuffer
        case adaptivePolicyTransition
        case adaptiveBufferWait
    }

    public var kind: Kind
    public var itemIndex: Int?
    public var itemID: String?
    public var segmentID: String?
    public var batchCount: Int?
    public var cacheHit: Bool?
    public var elapsedSeconds: Double?
    public var durationSeconds: Double?
    public var cachePolicy: QwenAudioCachePolicy?
    public var policyState: QwenPlaybackPolicyState?
    public var policyReason: String?
    public var predictedGapSeconds: Double?
    public var lane: String?
    public var rateMultiplier: Double?
    public var speakerClass: String?
    public var warning: String?
    public var inferenceBackend: QwenInferenceBackend?
    public var residencyState: QwenRuntimeResidencyState?
    public var sequenceIndex: Int?
    public var generationElapsedSeconds: Double?
    public var modelLoadSeconds: Double?
    public var warmupSeconds: Double?
    public var realTimeFactor: Double?
    public var peakMemoryBytes: Int64?
    public var device: String?
    public var fallbackReason: QwenInferenceFallbackReason?
    public var playbackRunwaySeconds: Double?

    public init(
        kind: Kind,
        itemIndex: Int? = nil,
        itemID: String? = nil,
        segmentID: String? = nil,
        batchCount: Int? = nil,
        cacheHit: Bool? = nil,
        elapsedSeconds: Double? = nil,
        durationSeconds: Double? = nil,
        cachePolicy: QwenAudioCachePolicy? = nil,
        policyState: QwenPlaybackPolicyState? = nil,
        policyReason: String? = nil,
        predictedGapSeconds: Double? = nil,
        lane: String? = nil,
        rateMultiplier: Double? = nil,
        speakerClass: String? = nil,
        warning: String? = nil,
        inferenceBackend: QwenInferenceBackend? = nil,
        residencyState: QwenRuntimeResidencyState? = nil,
        sequenceIndex: Int? = nil,
        generationElapsedSeconds: Double? = nil,
        modelLoadSeconds: Double? = nil,
        warmupSeconds: Double? = nil,
        realTimeFactor: Double? = nil,
        peakMemoryBytes: Int64? = nil,
        device: String? = nil,
        fallbackReason: QwenInferenceFallbackReason? = nil,
        playbackRunwaySeconds: Double? = nil
    ) {
        self.kind = kind
        self.itemIndex = itemIndex
        self.itemID = itemID
        self.segmentID = segmentID
        self.batchCount = batchCount
        self.cacheHit = cacheHit
        self.elapsedSeconds = elapsedSeconds
        self.durationSeconds = durationSeconds
        self.cachePolicy = cachePolicy
        self.policyState = policyState
        self.policyReason = policyReason
        self.predictedGapSeconds = predictedGapSeconds
        self.lane = lane
        self.rateMultiplier = rateMultiplier
        self.speakerClass = speakerClass
        self.warning = warning
        self.inferenceBackend = inferenceBackend
        self.residencyState = residencyState
        self.sequenceIndex = sequenceIndex
        self.generationElapsedSeconds = generationElapsedSeconds
        self.modelLoadSeconds = modelLoadSeconds
        self.warmupSeconds = warmupSeconds
        self.realTimeFactor = realTimeFactor
        self.peakMemoryBytes = peakMemoryBytes
        self.device = device
        self.fallbackReason = fallbackReason
        self.playbackRunwaySeconds = playbackRunwaySeconds
    }
}

public protocol QwenPlaybackTracing: Sendable {
    func record(_ event: QwenPlaybackTraceEvent) async
}

@MainActor
protocol QwenAudioPlaying: AnyObject {
    var visualizationSink: (any SpeechPlaybackVisualizationSink)? { get set }

    func play(url: URL, rateMultiplier: Double, volume: Double) async throws
    func play(
        _ items: [QwenPreparedPlaybackItem],
        rateMultiplier: Double,
        volume: Double,
        onStartItem: @escaping @MainActor @Sendable (SpeechPlaybackItem) async -> Void
    ) async throws
    func play(
        _ items: [QwenPreparedPlaybackItem],
        rateMultiplier: Double,
        volume: Double,
        onStartItem: @escaping @MainActor @Sendable (SpeechPlaybackItem) async -> Void,
        onBufferEnqueue: @escaping @MainActor @Sendable (SpeechPlaybackItem) async -> Void,
        onRenderStart: @escaping @MainActor @Sendable () async -> Void,
        onFinish: @escaping @MainActor @Sendable () async -> Void
    ) async throws
    func play(
        _ items: [QwenPreparedPlaybackItem],
        rateMultiplier: Double,
        volume: Double,
        onStartItem: @escaping @MainActor @Sendable (SpeechPlaybackItem) async -> Void,
        onBufferEnqueue: @escaping @MainActor @Sendable (SpeechPlaybackItem) async -> Void,
        onRenderStart: @escaping @MainActor @Sendable () async -> Void,
        onFinish: @escaping @MainActor @Sendable () async -> Void,
        onItemEnd: @escaping @MainActor @Sendable (SpeechPlaybackItem) async -> Void
    ) async throws
    func finishNarration()
    func stop()
    func effectiveCompleteFilePlaybackRate(for requestedRate: Double) -> Double
}

protocol QwenAudioPlaybackTracing: QwenAudioPlaying {
    func play(
        _ items: [QwenPreparedPlaybackItem],
        rateMultiplier: Double,
        volume: Double,
        onStartItem: @escaping @MainActor @Sendable (SpeechPlaybackItem) async -> Void,
        onBufferEnqueue: @escaping @MainActor @Sendable (SpeechPlaybackItem) async -> Void,
        onRenderStart: @escaping @MainActor @Sendable () async -> Void,
        onFinish: @escaping @MainActor @Sendable () async -> Void
    ) async throws
}

@MainActor
protocol QwenAudioStreamingPlaying: QwenAudioPlaying {
    func playStream(
        item: SpeechPlaybackItem,
        chunks: AsyncThrowingStream<QwenStreamingAudioChunk, Error>,
        rateMultiplier: Double,
        volume: Double,
        minimumBufferedPlaybackSeconds: Double,
        targetRunwayPlaybackSeconds: Double,
        onStartItem: @escaping @MainActor @Sendable (SpeechPlaybackItem) async -> Void,
        onBufferEnqueue: @escaping @MainActor @Sendable (SpeechPlaybackItem) async -> Void,
        onRenderStart: @escaping @MainActor @Sendable () async -> Void,
        onFinish: @escaping @MainActor @Sendable () async -> Void,
        onItemEnd: @escaping @MainActor @Sendable (SpeechPlaybackItem) async -> Void
    ) async throws
}

struct QwenPlaybackPerformanceEvent: Equatable, Sendable {
    enum Kind: Equatable, Sendable {
        case underrun
        case rebuffer
    }

    var kind: Kind
    var runwaySeconds: Double
}

@MainActor
protocol QwenPlaybackPerformanceReporting: AnyObject {
    func consumePerformanceEvents() -> [QwenPlaybackPerformanceEvent]
}

extension QwenAudioPlayback: QwenAudioPlaying {}
extension QwenAudioPlayback: QwenAudioStreamingPlaying {}
extension QwenAudioPlayback: QwenPlaybackPerformanceReporting {}
extension QwenAudioPlaying {
    func finishNarration() {}

    func effectiveCompleteFilePlaybackRate(for requestedRate: Double) -> Double {
        min(max(requestedRate, 0.5), 2.4)
    }

    func play(
        _ items: [QwenPreparedPlaybackItem],
        rateMultiplier: Double,
        volume: Double,
        onStartItem: @escaping @MainActor @Sendable (SpeechPlaybackItem) async -> Void,
        onBufferEnqueue: @escaping @MainActor @Sendable (SpeechPlaybackItem) async -> Void,
        onRenderStart: @escaping @MainActor @Sendable () async -> Void,
        onFinish: @escaping @MainActor @Sendable () async -> Void
    ) async throws {
        try await play(
            items,
            rateMultiplier: rateMultiplier,
            volume: volume,
            onStartItem: onStartItem,
            onBufferEnqueue: onBufferEnqueue,
            onRenderStart: onRenderStart,
            onFinish: onFinish,
            onItemEnd: { _ in }
        )
    }

    func play(
        _ items: [QwenPreparedPlaybackItem],
        rateMultiplier: Double,
        volume: Double,
        onStartItem: @escaping @MainActor @Sendable (SpeechPlaybackItem) async -> Void,
        onBufferEnqueue: @escaping @MainActor @Sendable (SpeechPlaybackItem) async -> Void,
        onRenderStart: @escaping @MainActor @Sendable () async -> Void,
        onFinish: @escaping @MainActor @Sendable () async -> Void,
        onItemEnd: @escaping @MainActor @Sendable (SpeechPlaybackItem) async -> Void
    ) async throws {
        for item in items {
            await onBufferEnqueue(item.item)
        }
        await onRenderStart()
        if let playback = self as? QwenAudioPlayback {
            try await playback.play(
                items,
                rateMultiplier: rateMultiplier,
                volume: volume,
                onStartItem: onStartItem,
                onBufferEnqueue: onBufferEnqueue,
                onRenderStart: onRenderStart,
                onFinish: onFinish,
                onItemEnd: onItemEnd
            )
            return
        }
        for item in items {
            await onStartItem(item.item)
            await onItemEnd(item.item)
        }
        await onFinish()
    }
}
extension QwenAudioPlayback: QwenAudioPlaybackTracing {}

@MainActor
public final class QwenSpeechBackend: SpeechBackend, SpeechPlaybackTimingReporting {
    public var settings: SpeechSettings
    public weak var visualizationSink: (any SpeechPlaybackVisualizationSink)? {
        didSet {
            playback.visualizationSink = visualizationSink
        }
    }
    public weak var timingSink: (any SpeechPlaybackTimingSink)? {
        didSet {
            (playback as? QwenAudioPlayback)?.timingSink = timingSink
        }
    }

    private let runtime: any QwenAudioSynthesizing
    private let playback: any QwenAudioPlaying
    private let wordAligner: (any RSVPWordAligning)?
    private let traceSink: (any QwenPlaybackTracing)?
    private let logger = Logger(subsystem: "SalientCore", category: "QwenSpeech")
    private let promptLibraryLearningScheduler = QwenPromptLibraryLearningScheduler()
    private var preparationTasks: [Task<Void, Never>] = []
    private var alignmentTasks: [Task<Void, Never>] = []
    private var activePreparationStore: QwenPreparedAudioStore?
    private var narrationGeneration: UInt64 = 0

    private let shortStarterDurationThreshold = 1.25
    private let initialTailBufferSeconds = 1.60
    private let firstAudioBudgetSeconds = 2.0
    private let firstAudioBudgetReserveSeconds = 0.15
    private let firstLookaheadBatchLimit = 2
    private let laterLookaheadBatchLimit = 4
    private let maxInitialPlaybackBatchCount = 4
    private let degradedMaxInitialPlaybackBatchCount = 64
    private let fastStartPolicy = QwenFastStartPolicy()
    private let predictedGapThresholdSeconds = 0.5
    private let rollingLongGapThresholdSeconds = 1.0
    private let recentObservedGapLimit = 12
    private let streamingInitialMinimumBufferedPlaybackSeconds = 0.40
    private let streamingContinuationMinimumBufferedPlaybackSeconds = 0.25
    private let streamingTargetRunwayPlaybackSeconds = 0.75
    private let presetCachedStarterLeadInWaitSeconds = 0.55
    private let referenceCachedStarterLeadInWaitSeconds = 0.78
    private let referencePromptLibraryStarterLeadInWaitSeconds = 0.65
    private let streamingEnabledOverride: Bool?
    private var playbackPolicyState: QwenPlaybackPolicyState = .normal
    private var recentObservedGaps: [Double] = []
    private var lastExpectedPlaybackEndElapsed: Double?

    public init(
        settings: SpeechSettings = .default,
        runtime: QwenRuntimeManager = QwenRuntimeManager(),
        playback: QwenAudioPlayback = QwenAudioPlayback(),
        wordAligner: (any RSVPWordAligning)? = nil,
        traceSink: (any QwenPlaybackTracing)? = nil
    ) {
        self.settings = settings.clamped
        self.runtime = runtime
        self.playback = playback
        self.wordAligner = wordAligner
        self.traceSink = traceSink
        self.streamingEnabledOverride = nil
    }

    init(
        settings: SpeechSettings = .default,
        runtime: any QwenAudioSynthesizing,
        playback: any QwenAudioPlaying,
        wordAligner: (any RSVPWordAligning)? = nil,
        traceSink: (any QwenPlaybackTracing)? = nil,
        streamingEnabledOverride: Bool? = nil
    ) {
        self.settings = settings.clamped
        self.runtime = runtime
        self.playback = playback
        self.wordAligner = wordAligner
        self.traceSink = traceSink
        self.streamingEnabledOverride = streamingEnabledOverride
    }

    public func speak(_ text: String) async throws {
        let item = SpeechPlaybackItem(id: "preview", segmentID: "preview", text: text)
        try await speak([item]) { _ in }
    }

    public func speak(
        _ items: [SpeechPlaybackItem],
        willSpeak: @escaping @MainActor (SpeechPlaybackItem) async -> Void
    ) async throws {
        var currentSettings = settings.clamped
        guard let lane = currentSettings.engineID.qwenLane else {
            throw QwenRuntimeError.setupRequired("Select a Qwen voice before using the Qwen backend.")
        }
        guard !items.isEmpty else { return }

        narrationGeneration &+= 1
        let activeNarrationGeneration = narrationGeneration
        alignmentTasks.forEach { $0.cancel() }
        alignmentTasks.removeAll()
        await promptLibraryLearningScheduler.narrationWillStart()
        defer {
            if narrationGeneration == activeNarrationGeneration {
                playback.finishNarration()
            }
        }
        var preparationStoreToCancel: QwenPreparedAudioStore?
        do {
            let requestStartedAt = Date()
            let effectiveReferenceVoice = currentSettings.effectiveQwenReferenceVoice
            let speaker = currentSettings.qwenUseReferenceVoice
                ? effectiveReferenceVoice.voiceName
                : (currentSettings.qwenSpeaker.isEmpty ? lane.defaultSpeaker : currentSettings.qwenSpeaker)
            let speakerClass = currentSettings.qwenUseReferenceVoice ? "reference" : "preset"
            let usesStreamingPlayback = qwenStreamingEnabled(
                for: lane,
                useReferenceVoice: currentSettings.qwenUseReferenceVoice
            ) && runtime is any QwenAudioStreaming
                && playback is any QwenAudioStreamingPlaying
            if !usesStreamingPlayback {
                currentSettings.rateMultiplier = playback.effectiveCompleteFilePlaybackRate(
                    for: currentSettings.rateMultiplier
                )
            }
            playbackPolicyState = recentObservedGaps.contains { $0 > rollingLongGapThresholdSeconds }
                ? .degraded
                : .normal
            lastExpectedPlaybackEndElapsed = nil
            await record(.init(
                kind: .requestStart,
                elapsedSeconds: 0,
                policyState: playbackPolicyState,
                lane: lane.rawValue,
                rateMultiplier: currentSettings.rateMultiplier,
                speakerClass: speakerClass
            ))
            if playbackPolicyState == .degraded {
                await record(.init(
                    kind: .adaptivePolicyTransition,
                    elapsedSeconds: 0,
                    policyState: .degraded,
                    policyReason: "priorRollingLongGap",
                    lane: lane.rawValue,
                    rateMultiplier: currentSettings.rateMultiplier,
                    speakerClass: speakerClass
                ))
            }
            let promptPlaybackPlan = await promptLibraryPlaybackPlan(
                for: items,
                lane: lane,
                speaker: speaker,
                settings: currentSettings
            )
            let playbackItems = promptPlaybackPlan.items
            timingSink?.speechPlaybackWillUseFinalItems(playbackItems)
            if usesStreamingPlayback,
               let streamingRuntime = runtime as? any QwenAudioStreaming,
               let streamingPlayback = playback as? any QwenAudioStreamingPlaying {
                let store = QwenPreparedAudioStore()
                preparationStoreToCancel = store
                try await speakStreaming(
                    playbackItems,
                    lane: lane,
                    speaker: speaker,
                    settings: currentSettings,
                    speakerClass: speakerClass,
                    requestStartedAt: requestStartedAt,
                    streamingRuntime: streamingRuntime,
                    streamingPlayback: streamingPlayback,
                    store: store,
                    willSpeak: willSpeak
                )
                await store.cancelAll()
                preparationStoreToCancel = nil
                if narrationGeneration == activeNarrationGeneration {
                    await promptLibraryLearningScheduler.narrationDidFinish(learning: promptPlaybackPlan.learning)
                }
                return
            }
            let store = QwenPreparedAudioStore()
            preparationStoreToCancel = store
            activePreparationStore = store
            let preparationTask = Task {
                await prepareItems(
                    playbackItems,
                    lane: lane,
                    speaker: speaker,
                    settings: currentSettings,
                    speakerClass: speakerClass,
                    requestStartedAt: requestStartedAt,
                    store: store
                )
            }
            let tasks = [preparationTask]
            preparationTasks = tasks
            defer {
                tasks.forEach { $0.cancel() }
                if activePreparationStore === store {
                    preparationTasks.removeAll()
                    activePreparationStore = nil
                }
            }

            var nextIndex = 0
            var hasStartedPlayback = false
            while nextIndex < playbackItems.count {
                try Task.checkCancellation()
                guard let audio = try await waitForPreparedAudio(in: store, index: nextIndex) else {
                    continue
                }
                try Task.checkCancellation()
                let elapsed = Date().timeIntervalSince(requestStartedAt)
                await record(.init(
                    kind: nextIndex == 0 ? .firstPrepared : .prepared,
                    itemIndex: nextIndex,
                    itemID: playbackItems[nextIndex].id,
                    segmentID: playbackItems[nextIndex].segmentID,
                    cacheHit: audio.isFromCache,
                    elapsedSeconds: elapsed,
                    durationSeconds: audio.durationSeconds,
                    cachePolicy: Self.cachePolicy(for: playbackItems[nextIndex]),
                    policyState: playbackPolicyState,
                    lane: lane.rawValue,
                    rateMultiplier: currentSettings.rateMultiplier,
                    speakerClass: speakerClass
                ))

            var batch = [
                QwenPreparedPlaybackItem(index: nextIndex, item: playbackItems[nextIndex], audio: audio)
            ]

            if !hasStartedPlayback {
                if nextIndex + 1 < playbackItems.count {
                    if await shouldEnterDegradedForPredictedGap(
                        firstAudio: audio,
                        nextIndex: nextIndex + 1,
                        playbackRate: currentSettings.rateMultiplier,
                        store: store
                    ) {
                        await enterDegradedPolicy(
                            reason: "predictedGap",
                            itemIndex: nextIndex + 1,
                            itemID: playbackItems[nextIndex + 1].id,
                            segmentID: playbackItems[nextIndex + 1].segmentID,
                            requestStartedAt: requestStartedAt,
                            predictedGapSeconds: predictedGapThresholdSeconds + 0.0001,
                            lane: lane.rawValue,
                            rateMultiplier: currentSettings.rateMultiplier,
                            speakerClass: speakerClass
                        )
                    }
                    let tailWait = initialTailWait(
                        firstAudio: audio,
                        playbackRate: currentSettings.rateMultiplier,
                        requestStartedAt: requestStartedAt,
                        hasNextItem: nextIndex + 1 < playbackItems.count
                    )
                    switch tailWait {
                    case .none:
                        break
                    case .timed(let seconds):
                        await record(.init(
                            kind: .initialBufferWait,
                            itemIndex: nextIndex + 1,
                            itemID: playbackItems[nextIndex + 1].id,
                            segmentID: playbackItems[nextIndex + 1].segmentID,
                            elapsedSeconds: Date().timeIntervalSince(requestStartedAt),
                            policyState: playbackPolicyState,
                            lane: lane.rawValue,
                            rateMultiplier: currentSettings.rateMultiplier,
                            speakerClass: speakerClass
                        ))
                        if playbackPolicyState == .degraded {
                            await record(.init(
                                kind: .adaptiveBufferWait,
                                itemIndex: nextIndex + 1,
                                itemID: playbackItems[nextIndex + 1].id,
                                segmentID: playbackItems[nextIndex + 1].segmentID,
                                elapsedSeconds: Date().timeIntervalSince(requestStartedAt),
                                durationSeconds: seconds,
                                policyState: playbackPolicyState,
                                policyReason: "initialContiguousBuffer",
                                lane: lane.rawValue,
                                rateMultiplier: currentSettings.rateMultiplier,
                                speakerClass: speakerClass
                            ))
                        }
                        let waitDeadline = Date().addingTimeInterval(seconds)
                        var nextQueueIndex = nextIndex + 1
                        while nextQueueIndex < playbackItems.count,
                              batch.count < maxInitialPlaybackBatchCount(for: playbackPolicyState) {
                            let remaining = waitDeadline.timeIntervalSinceNow
                            if remaining <= 0 {
                                guard shouldWaitForInitialContiguousAudio(
                                    batch: batch,
                                    itemCount: playbackItems.count,
                                    playbackRate: currentSettings.rateMultiplier
                                ) else {
                                    break
                                }
                                guard let nextAudio = try await waitForPreparedAudio(
                                    in: store,
                                    index: nextQueueIndex
                                ) else {
                                    break
                                }
                                batch.append(QwenPreparedPlaybackItem(
                                    index: nextQueueIndex,
                                    item: playbackItems[nextQueueIndex],
                                    audio: nextAudio
                                ))
                                nextQueueIndex += 1
                                if shouldStartDegradedEarly(
                                    batch: batch,
                                    itemCount: playbackItems.count,
                                    playbackRate: currentSettings.rateMultiplier
                                ) {
                                    break
                                }
                                continue
                            }
                            if let nextAudio = try await waitForPreparedAudio(
                                in: store,
                                index: nextQueueIndex,
                                timeout: remaining
                            ) {
                                batch.append(QwenPreparedPlaybackItem(
                                    index: nextQueueIndex,
                                    item: playbackItems[nextQueueIndex],
                                    audio: nextAudio
                                ))
                                nextQueueIndex += 1
                                if shouldStartDegradedEarly(
                                    batch: batch,
                                    itemCount: playbackItems.count,
                                    playbackRate: currentSettings.rateMultiplier
                                ) {
                                    break
                                }
                                if playbackPolicyState == .normal {
                                    break
                                }
                            } else {
                                if shouldWaitForInitialContiguousAudio(
                                    batch: batch,
                                    itemCount: playbackItems.count,
                                    playbackRate: currentSettings.rateMultiplier
                                ) {
                                    continue
                                }
                                await record(.init(
                                    kind: .underrunWait,
                                    itemIndex: nextQueueIndex,
                                    itemID: playbackItems[nextQueueIndex].id,
                                    segmentID: playbackItems[nextQueueIndex].segmentID,
                                    elapsedSeconds: Date().timeIntervalSince(requestStartedAt),
                                    policyState: playbackPolicyState,
                                    lane: lane.rawValue,
                                    rateMultiplier: currentSettings.rateMultiplier,
                                    speakerClass: speakerClass
                                ))
                                await enterDegradedPolicy(
                                    reason: "underrunWait",
                                    itemIndex: nextQueueIndex,
                                    itemID: playbackItems[nextQueueIndex].id,
                                    segmentID: playbackItems[nextQueueIndex].segmentID,
                                    requestStartedAt: requestStartedAt,
                                    lane: lane.rawValue,
                                    rateMultiplier: currentSettings.rateMultiplier,
                                    speakerClass: speakerClass
                                )
                                break
                            }
                        }
                    }
                }
            }

            try await appendReadyContiguousItems(
                to: &batch,
                startingAt: nextIndex + batch.count,
                items: playbackItems,
                store: store,
                maxCount: hasStartedPlayback ? nil : maxInitialPlaybackBatchCount(for: playbackPolicyState)
            )
            await record(.init(
                kind: .playbackBatchStart,
                itemIndex: nextIndex,
                itemID: playbackItems[nextIndex].id,
                segmentID: playbackItems[nextIndex].segmentID,
                batchCount: batch.count,
                elapsedSeconds: Date().timeIntervalSince(requestStartedAt),
                policyState: playbackPolicyState,
                lane: lane.rawValue,
                rateMultiplier: currentSettings.rateMultiplier,
                speakerClass: speakerClass
            ))
            await record(.init(
                kind: .playbackQueueStart,
                itemIndex: nextIndex,
                itemID: playbackItems[nextIndex].id,
                segmentID: playbackItems[nextIndex].segmentID,
                batchCount: batch.count,
                elapsedSeconds: Date().timeIntervalSince(requestStartedAt),
                policyState: playbackPolicyState,
                lane: lane.rawValue,
                rateMultiplier: currentSettings.rateMultiplier,
                speakerClass: speakerClass
            ))
            let playbackTraceByID = Dictionary(uniqueKeysWithValues: batch.map { item in
                (
                    item.item.id,
                    (
                        index: item.index,
                        segmentID: item.item.segmentID,
                        durationSeconds: item.audio.durationSeconds
                    )
                )
            })
            publishPreparedTimings(for: batch, playbackRate: currentSettings.rateMultiplier)
            schedulePrecisionAlignment(
                for: batch,
                playbackRate: currentSettings.rateMultiplier
            )
            let batchStartIndex = nextIndex
            let batchStartItem = playbackItems[batchStartIndex]
            let batchCount = batch.count
            if let tracedPlayback = playback as? QwenAudioPlaybackTracing {
                try await tracedPlayback.play(
                    batch,
                    rateMultiplier: currentSettings.rateMultiplier,
                    volume: currentSettings.volume,
                    onStartItem: { [weak self] item in
                        let trace = playbackTraceByID[item.id]
                        await self?.recordPlaybackItemStart(
                            item: item,
                            trace: trace,
                            requestStartedAt: requestStartedAt,
                            playbackRate: currentSettings.rateMultiplier,
                            lane: lane.rawValue,
                            speakerClass: speakerClass
                        )
                        await willSpeak(item)
                    },
                    onBufferEnqueue: { [weak self] item in
                        let trace = playbackTraceByID[item.id]
                        await self?.record(.init(
                            kind: .playbackBufferEnqueue,
                            itemIndex: trace?.index,
                            itemID: item.id,
                            segmentID: trace?.segmentID ?? item.segmentID,
                            elapsedSeconds: Date().timeIntervalSince(requestStartedAt),
                            policyState: self?.playbackPolicyState,
                            lane: lane.rawValue,
                            rateMultiplier: currentSettings.rateMultiplier,
                            speakerClass: speakerClass
                        ))
                    },
                    onRenderStart: { [weak self] in
                        await self?.record(.init(
                            kind: .playbackRenderStart,
                            itemIndex: batchStartIndex,
                            itemID: batchStartItem.id,
                            segmentID: batchStartItem.segmentID,
                            batchCount: batchCount,
                            elapsedSeconds: Date().timeIntervalSince(requestStartedAt),
                            policyState: self?.playbackPolicyState,
                            lane: lane.rawValue,
                            rateMultiplier: currentSettings.rateMultiplier,
                            speakerClass: speakerClass
                        ))
                    },
                    onFinish: { [weak self] in
                        await self?.record(.init(
                            kind: .playbackQueueEnd,
                            itemIndex: batchStartIndex,
                            itemID: batchStartItem.id,
                            segmentID: batchStartItem.segmentID,
                            batchCount: batchCount,
                            elapsedSeconds: Date().timeIntervalSince(requestStartedAt),
                            policyState: self?.playbackPolicyState,
                            lane: lane.rawValue,
                            rateMultiplier: currentSettings.rateMultiplier,
                            speakerClass: speakerClass
                        ))
                    },
                    onItemEnd: { [weak self] item in
                        let trace = playbackTraceByID[item.id]
                        self?.publishItemFinished(item: item, trace: trace)
                        await self?.record(.init(
                            kind: .playbackItemEnd,
                            itemIndex: trace?.index,
                            itemID: item.id,
                            segmentID: trace?.segmentID ?? item.segmentID,
                            elapsedSeconds: Date().timeIntervalSince(requestStartedAt),
                            policyState: self?.playbackPolicyState,
                            lane: lane.rawValue,
                            rateMultiplier: currentSettings.rateMultiplier,
                            speakerClass: speakerClass
                        ))
                    }
                )
            } else {
                try await playback.play(
                    batch,
                    rateMultiplier: currentSettings.rateMultiplier,
                    volume: currentSettings.volume
                ) { [weak self] item in
                    let trace = playbackTraceByID[item.id]
                    await self?.recordPlaybackItemStart(
                        item: item,
                        trace: trace,
                        requestStartedAt: requestStartedAt,
                        playbackRate: currentSettings.rateMultiplier,
                        lane: lane.rawValue,
                        speakerClass: speakerClass
                    )
                    await willSpeak(item)
                }
                for item in batch.map(\.item) {
                    let trace = playbackTraceByID[item.id]
                    publishItemFinished(item: item, trace: trace)
                }
            }
            nextIndex += batch.count
            hasStartedPlayback = true
        }
            await store.cancelAll()
            preparationStoreToCancel = nil
            if narrationGeneration == activeNarrationGeneration {
                await promptLibraryLearningScheduler.narrationDidFinish(learning: promptPlaybackPlan.learning)
            }
        } catch {
            await preparationStoreToCancel?.cancelAll()
            preparationStoreToCancel = nil
            if narrationGeneration == activeNarrationGeneration {
                await promptLibraryLearningScheduler.narrationDidAbort()
            }
            throw error
        }
    }

    private func promptLibraryPlaybackPlan(
        for items: [SpeechPlaybackItem],
        lane: QwenModelLane,
        speaker: String,
        settings: SpeechSettings
    ) async -> QwenPromptLibraryPlaybackPlan {
        guard settings.usesQuestionPromptAudioLibrary,
              let service = runtime as? any QwenPromptAudioLibraryServing,
              let candidate = Self.promptLibraryCandidate(from: items) else {
            return QwenPromptLibraryPlaybackPlan(items: items, learning: nil, usedLibraryHit: false)
        }

        do {
            let referenceVoice = settings.effectiveQwenReferenceVoice
            var context = try await service.promptAudioLibraryContext(
                lane: lane,
                speaker: speaker,
                language: lane.language,
                useReferenceVoice: settings.qwenUseReferenceVoice,
                referenceAudioPath: referenceVoice.audioPath,
                referenceText: referenceVoice.transcript
            )
            context.qwenDeEsserStrengthDecibels = settings.qwenDeEsserStrengthDecibels
            let didRestore = try await service.restorePromptLibraryAudioIfAvailable(
                text: candidate.fullText,
                context: context,
                rateMultiplier: settings.rateMultiplier
            )
            if didRestore {
                var rewritten = items
                rewritten.replaceSubrange(candidate.replacementRange, with: [candidate.replacementItem])
                return QwenPromptLibraryPlaybackPlan(items: rewritten, learning: nil, usedLibraryHit: true)
            }
            return QwenPromptLibraryPlaybackPlan(
                items: items,
                learning: QwenPromptLibraryLearning(
                    service: service,
                    text: candidate.fullText,
                    derivedPrefixTexts: QwenPromptAudioLibrary.derivedPrefixTexts(for: candidate.fullText),
                    context: context
                ),
                usedLibraryHit: false
            )
        } catch {
            return QwenPromptLibraryPlaybackPlan(items: items, learning: nil, usedLibraryHit: false)
        }
    }

    private static func promptLibraryCandidate(from items: [SpeechPlaybackItem]) -> QwenPromptLibraryCandidate? {
        guard let first = items.first else { return nil }
        if items.count >= 2,
           first.segmentID.hasSuffix("#starter"),
           items[1].segmentID.hasSuffix("#tail") {
            let fullText = joinedPromptText([first.text, items[1].text])
            guard !fullText.isEmpty else { return nil }
            return QwenPromptLibraryCandidate(
                fullText: fullText,
                replacementRange: 0..<2,
                replacementItem: SpeechPlaybackItem(
                    id: first.id,
                    segmentID: first.segmentID,
                    sourceText: fullText,
                    text: fullText,
                    audioCachePolicy: .persistent
                )
            )
        }

        guard first.segmentID.hasSuffix("#task") || first.segmentID == "task" else {
            return nil
        }
        let fullText = first.text.trimmedForSpeech
        guard !fullText.isEmpty else { return nil }
        return QwenPromptLibraryCandidate(
            fullText: fullText,
            replacementRange: 0..<1,
            replacementItem: SpeechPlaybackItem(
                id: first.id,
                segmentID: first.segmentID,
                sourceText: first.sourceText,
                text: first.text,
                audioCachePolicy: .persistent
            )
        )
    }

    private static func joinedPromptText(_ parts: [String]) -> String {
        parts
            .map { $0.trimmedForSpeech }
            .filter { !$0.isEmpty }
            .joined(separator: " ")
            .replacingOccurrences(of: #"\s+"#, with: " ", options: .regularExpression)
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private func qwenStreamingEnabled(
        for lane: QwenModelLane,
        useReferenceVoice: Bool
    ) -> Bool {
        if let streamingEnabledOverride {
            return streamingEnabledOverride
        }
        return QwenNativeStreamingPolicy.isInteractiveStreamingEnabled(
            lane: lane,
            useReferenceVoice: useReferenceVoice
        )
    }

    private func speakStreaming(
        _ items: [SpeechPlaybackItem],
        lane: QwenModelLane,
        speaker: String,
        settings: SpeechSettings,
        speakerClass: String,
        requestStartedAt: Date,
        streamingRuntime: any QwenAudioStreaming,
        streamingPlayback: any QwenAudioStreamingPlaying,
        store: QwenPreparedAudioStore,
        willSpeak: @escaping @MainActor (SpeechPlaybackItem) async -> Void
    ) async throws {
        let streamingPrefixCount = streamingPrefixCount(for: items)
        let streamedItemLimit = streamingItemLimit(
            for: items,
            streamingPrefixCount: streamingPrefixCount,
            speakerClass: speakerClass
        )
        let firstStreamedStemIndex = firstStreamedStemIndex(in: items, startIndex: streamingPrefixCount)
        let streamReadiness = QwenStreamingReadinessTracker()
        activePreparationStore = store
        let completeLookaheadItems = Array(items.enumerated().dropFirst(streamedItemLimit))
        var lookaheadTask: Task<Void, Never>?

        func startLookaheadIfNeeded() {
            guard lookaheadTask == nil, !completeLookaheadItems.isEmpty else { return }
            let task = Task {
                await prepareStreamingLookaheadItems(
                    completeLookaheadItems,
                    itemCount: items.count,
                    lane: lane,
                    speaker: speaker,
                    settings: settings,
                    speakerClass: speakerClass,
                    requestStartedAt: requestStartedAt,
                    store: store
                )
            }
            lookaheadTask = task
            preparationTasks = [task]
        }

        defer {
            preparationTasks.removeAll()
            lookaheadTask?.cancel()
            if activePreparationStore === store {
                activePreparationStore = nil
            }
        }

        var streamingEntriesByIndex: [Int: QwenStreamingPlaybackEntry] = [:]

        func startStreamingEntryIfNeeded(index: Int) async {
            guard index >= 0,
                  index < streamedItemLimit,
                  streamingEntriesByIndex[index] == nil else {
                return
            }
            let entry = makeStreamingEntry(
                index: index,
                item: items[index],
                lane: lane,
                speaker: speaker,
                settings: settings,
                streamingRuntime: streamingRuntime,
                readinessTracker: streamReadiness,
                requestStartedAt: requestStartedAt,
                speakerClass: speakerClass
            )
            streamingEntriesByIndex[index] = entry
            await record(.init(
                kind: .promptToSynthesizeStart,
                itemIndex: entry.index,
                itemID: entry.item.id,
                segmentID: entry.item.segmentID,
                elapsedSeconds: Date().timeIntervalSince(requestStartedAt),
                cachePolicy: entry.cachePolicy,
                policyState: playbackPolicyState,
                lane: lane.rawValue,
                rateMultiplier: settings.rateMultiplier,
                speakerClass: speakerClass
            ))
        }

        let delaysStemStreamUntilStarterPlayback = speakerClass == "reference"
            && !Self.startsWithPromptLibraryFullStarter(items)
        if Self.startsWithPromptLibraryFullStarter(items) {
            for index in 0..<streamedItemLimit {
                await startStreamingEntryIfNeeded(index: index)
            }
            startLookaheadIfNeeded()
        } else {
            for index in 0..<streamingPrefixCount {
                await startStreamingEntryIfNeeded(index: index)
            }
            if let firstStreamedStemIndex,
               !delaysStemStreamUntilStarterPlayback {
                await startStreamingEntryIfNeeded(index: firstStreamedStemIndex)
            }
        }
        var nextIndex = 0
        while nextIndex < items.count {
            try Task.checkCancellation()
            if nextIndex < streamedItemLimit {
                if nextIndex == firstStreamedStemIndex,
                   !delaysStemStreamUntilStarterPlayback {
                    await startStreamingEntryIfNeeded(index: nextIndex)
                }
                await startStreamingEntryIfNeeded(index: nextIndex)
                guard let entry = streamingEntriesByIndex[nextIndex] else { break }
                if let firstStreamedStemIndex,
                   shouldHoldReferencePromptLibraryStarterForStemRunway(
                    nextIndex: nextIndex,
                    speakerClass: speakerClass,
                    items: items
                   ) {
                    await streamReadiness.waitUntilReady(
                        index: firstStreamedStemIndex,
                        timeoutSeconds: referencePromptLibraryStarterLeadInWaitSeconds
                    )
                } else if shouldHoldReferenceStarterForTailRunway(
                    entry: entry,
                    nextIndex: nextIndex,
                    streamingPrefixCount: streamingPrefixCount,
                    speakerClass: speakerClass
                ) {
                    await streamReadiness.waitUntilReady(
                        index: nextIndex + 1,
                        timeoutSeconds: cachedStarterLeadInWaitSeconds(for: speakerClass)
                    )
                }
                let playbackStartIndex = nextIndex
                let lookaheadStartIndex = streamingLookaheadStartIndex(
                    streamedItemLimit: streamedItemLimit,
                    firstStreamedStemIndex: firstStreamedStemIndex,
                    speakerClass: speakerClass
                )
                let onStreamingPlaybackStart: @MainActor @Sendable () async -> Void = {
                    if playbackStartIndex == 0,
                       delaysStemStreamUntilStarterPlayback,
                       let firstStreamedStemIndex {
                        await startStreamingEntryIfNeeded(index: firstStreamedStemIndex)
                    }
                    await startStreamingEntryIfNeeded(index: playbackStartIndex + 1)
                    if speakerClass == "reference" {
                        await startStreamingEntryIfNeeded(index: playbackStartIndex + 2)
                    }
                    if playbackStartIndex >= lookaheadStartIndex {
                        startLookaheadIfNeeded()
                    }
                }
                try await playStreamingEntry(
                    entry,
                    streamingPlayback: streamingPlayback,
                    settings: settings,
                    requestStartedAt: requestStartedAt,
                    lane: lane,
                    speakerClass: speakerClass,
                    willSpeak: willSpeak,
                    onPlaybackStart: onStreamingPlaybackStart
                )
                nextIndex += 1
                continue
            }
            startLookaheadIfNeeded()
            guard let audio = try await waitForPreparedAudio(in: store, index: nextIndex) else {
                continue
            }
            await record(.init(
                kind: .prepared,
                itemIndex: nextIndex,
                itemID: items[nextIndex].id,
                segmentID: items[nextIndex].segmentID,
                cacheHit: audio.isFromCache,
                elapsedSeconds: Date().timeIntervalSince(requestStartedAt),
                durationSeconds: audio.durationSeconds,
                cachePolicy: Self.cachePolicy(for: items[nextIndex]),
                policyState: playbackPolicyState,
                lane: lane.rawValue,
                rateMultiplier: settings.rateMultiplier,
                speakerClass: speakerClass
            ))
            var batch = [
                QwenPreparedPlaybackItem(index: nextIndex, item: items[nextIndex], audio: audio)
            ]
            try await appendReadyContiguousItems(
                to: &batch,
                startingAt: nextIndex + 1,
                items: items,
                store: store
            )
            try await playPreparedBatch(
                batch,
                items: items,
                batchStartIndex: nextIndex,
                settings: settings,
                requestStartedAt: requestStartedAt,
                lane: lane,
                speakerClass: speakerClass,
                willSpeak: willSpeak
            )
            nextIndex += batch.count
        }
    }

    private func streamingPrefixCount(for items: [SpeechPlaybackItem]) -> Int {
        guard !items.isEmpty else { return 0 }
        guard items.count > 1,
              items[1].segmentID.hasSuffix("#tail") else {
            return 1
        }
        return 2
    }

    private static func startsWithPromptLibraryFullStarter(_ items: [SpeechPlaybackItem]) -> Bool {
        guard let first = items.first,
              first.segmentID.hasSuffix("#starter") else {
            return false
        }
        return !(items.count > 1 && items[1].segmentID.hasSuffix("#tail"))
    }

    private func streamingItemLimit(
        for items: [SpeechPlaybackItem],
        streamingPrefixCount: Int,
        speakerClass: String
    ) -> Int {
        guard !items.isEmpty else { return 0 }
        let earlyReadableStreamCount: Int
        if Self.startsWithPromptLibraryFullStarter(items) {
            earlyReadableStreamCount = 1
        } else if speakerClass == "reference" {
            earlyReadableStreamCount = 4
        } else {
            earlyReadableStreamCount = 1
        }
        return min(items.count, streamingPrefixCount + earlyReadableStreamCount)
    }

    private func streamingLookaheadStartIndex(
        streamedItemLimit: Int,
        firstStreamedStemIndex: Int?,
        speakerClass: String
    ) -> Int {
        let defaultStartIndex = max(0, streamedItemLimit - 1)
        guard speakerClass == "reference",
              let firstStreamedStemIndex else {
            return defaultStartIndex
        }
        return min(firstStreamedStemIndex, defaultStartIndex)
    }

    private func firstStreamedStemIndex(
        in items: [SpeechPlaybackItem],
        startIndex: Int
    ) -> Int? {
        guard startIndex < items.count else { return nil }
        return items.indices.dropFirst(startIndex).first { index in
            let segmentID = items[index].segmentID
            return !segmentID.hasSuffix("#starter") && !segmentID.hasSuffix("#tail")
        }
    }

    private func makeStreamingEntry(
        index: Int,
        item: SpeechPlaybackItem,
        lane: QwenModelLane,
        speaker: String,
        settings: SpeechSettings,
        streamingRuntime: any QwenAudioStreaming,
        readinessTracker: QwenStreamingReadinessTracker,
        requestStartedAt: Date,
        speakerClass: String
    ) -> QwenStreamingPlaybackEntry {
        let cachePolicy = Self.cachePolicy(for: item)
        let request = QwenStreamingSynthesisRequest(
            itemIndex: index,
            request: QwenSynthesisRequest(
                text: item.text,
                lane: lane,
                speaker: speaker,
                language: lane.language,
                rateMultiplier: settings.rateMultiplier,
                cachePolicy: cachePolicy,
                useReferenceVoice: settings.qwenUseReferenceVoice,
                referenceAudioPath: settings.effectiveQwenReferenceVoice.audioPath,
                referenceText: settings.effectiveQwenReferenceVoice.transcript,
                qwenDeEsserStrengthDecibels: settings.qwenDeEsserStrengthDecibels
            )
        )
        return QwenStreamingPlaybackEntry(
            index: index,
            item: item,
            cachePolicy: cachePolicy,
            chunks: streamingChunks(
                from: streamingRuntime,
                request: request,
                onFirstChunk: { [weak self] chunk in
                    await readinessTracker.markReady(index: index)
                    await self?.record(.init(
                        kind: .firstPCM,
                        itemIndex: index,
                        itemID: item.id,
                        segmentID: item.segmentID,
                        elapsedSeconds: Date().timeIntervalSince(requestStartedAt),
                        cachePolicy: cachePolicy,
                        lane: lane.rawValue,
                        rateMultiplier: settings.rateMultiplier,
                        speakerClass: speakerClass,
                        inferenceBackend: chunk.backend,
                        residencyState: chunk.residencyState,
                        sequenceIndex: chunk.sequenceIndex,
                        generationElapsedSeconds: chunk.elapsedSeconds,
                        modelLoadSeconds: chunk.modelLoadSeconds,
                        warmupSeconds: chunk.warmupSeconds,
                        peakMemoryBytes: chunk.peakMemoryBytes,
                        device: chunk.device,
                        fallbackReason: chunk.fallbackReason
                    ))
                },
                onFinalChunk: { [weak self] chunk in
                    await self?.record(.init(
                        kind: chunk.fallbackReason == nil ? .runtimePrepared : .runtimeFallback,
                        itemIndex: index,
                        itemID: item.id,
                        segmentID: item.segmentID,
                        elapsedSeconds: Date().timeIntervalSince(requestStartedAt),
                        cachePolicy: cachePolicy,
                        lane: lane.rawValue,
                        rateMultiplier: settings.rateMultiplier,
                        speakerClass: speakerClass,
                        inferenceBackend: chunk.backend,
                        residencyState: chunk.residencyState,
                        sequenceIndex: chunk.sequenceIndex,
                        generationElapsedSeconds: chunk.elapsedSeconds,
                        modelLoadSeconds: chunk.modelLoadSeconds,
                        warmupSeconds: chunk.warmupSeconds,
                        realTimeFactor: chunk.realTimeFactor,
                        peakMemoryBytes: chunk.peakMemoryBytes,
                        device: chunk.device,
                        fallbackReason: chunk.fallbackReason
                    ))
                }
            )
        )
    }

    private func shouldHoldReferenceStarterForTailRunway(
        entry: QwenStreamingPlaybackEntry,
        nextIndex: Int,
        streamingPrefixCount: Int,
        speakerClass: String
    ) -> Bool {
        (speakerClass == "reference" || speakerClass == "preset")
            && nextIndex == 0
            && streamingPrefixCount > 1
            && entry.item.segmentID.hasSuffix("#starter")
    }

    private func shouldHoldReferencePromptLibraryStarterForStemRunway(
        nextIndex: Int,
        speakerClass: String,
        items: [SpeechPlaybackItem]
    ) -> Bool {
        speakerClass == "reference"
            && nextIndex == 0
            && Self.startsWithPromptLibraryFullStarter(items)
    }

    private func cachedStarterLeadInWaitSeconds(for speakerClass: String) -> Double {
        speakerClass == "reference"
            ? referenceCachedStarterLeadInWaitSeconds
            : presetCachedStarterLeadInWaitSeconds
    }

    private func streamingMinimumBufferedPlaybackSeconds(for itemIndex: Int) -> Double {
        itemIndex == 0
            ? streamingInitialMinimumBufferedPlaybackSeconds
            : streamingContinuationMinimumBufferedPlaybackSeconds
    }

    private func playStreamingEntry(
        _ entry: QwenStreamingPlaybackEntry,
        streamingPlayback: any QwenAudioStreamingPlaying,
        settings: SpeechSettings,
        requestStartedAt: Date,
        lane: QwenModelLane,
        speakerClass: String,
        willSpeak: @escaping @MainActor (SpeechPlaybackItem) async -> Void,
        onPlaybackStart: @escaping @MainActor @Sendable () async -> Void
    ) async throws {
        await record(.init(
            kind: .playbackBatchStart,
            itemIndex: entry.index,
            itemID: entry.item.id,
            segmentID: entry.item.segmentID,
            batchCount: 1,
            elapsedSeconds: Date().timeIntervalSince(requestStartedAt),
            policyState: playbackPolicyState,
            lane: lane.rawValue,
            rateMultiplier: settings.rateMultiplier,
            speakerClass: speakerClass
        ))
        await record(.init(
            kind: .playbackQueueStart,
            itemIndex: entry.index,
            itemID: entry.item.id,
            segmentID: entry.item.segmentID,
            batchCount: 1,
            elapsedSeconds: Date().timeIntervalSince(requestStartedAt),
            policyState: playbackPolicyState,
            lane: lane.rawValue,
            rateMultiplier: settings.rateMultiplier,
            speakerClass: speakerClass
        ))
        try await streamingPlayback.playStream(
            item: entry.item,
            chunks: entry.chunks,
            rateMultiplier: settings.rateMultiplier,
            volume: settings.volume,
            minimumBufferedPlaybackSeconds: streamingMinimumBufferedPlaybackSeconds(for: entry.index),
            targetRunwayPlaybackSeconds: streamingTargetRunwayPlaybackSeconds,
            onStartItem: { [weak self] item in
                await self?.recordPlaybackItemStart(
                    item: item,
                    trace: (index: entry.index, segmentID: item.segmentID, durationSeconds: 0),
                    requestStartedAt: requestStartedAt,
                    playbackRate: settings.rateMultiplier,
                    lane: lane.rawValue,
                    speakerClass: speakerClass
                )
                await willSpeak(item)
                await onPlaybackStart()
            },
            onBufferEnqueue: { [weak self] item in
                await self?.record(.init(
                    kind: entry.index == 0 ? .firstPrepared : .prepared,
                    itemIndex: entry.index,
                    itemID: item.id,
                    segmentID: item.segmentID,
                    elapsedSeconds: Date().timeIntervalSince(requestStartedAt),
                    cachePolicy: entry.cachePolicy,
                    policyState: self?.playbackPolicyState,
                    lane: lane.rawValue,
                    rateMultiplier: settings.rateMultiplier,
                    speakerClass: speakerClass
                ))
                await self?.record(.init(
                    kind: .playbackBufferEnqueue,
                    itemIndex: entry.index,
                    itemID: item.id,
                    segmentID: item.segmentID,
                    elapsedSeconds: Date().timeIntervalSince(requestStartedAt),
                    policyState: self?.playbackPolicyState,
                    lane: lane.rawValue,
                    rateMultiplier: settings.rateMultiplier,
                    speakerClass: speakerClass
                ))
            },
            onRenderStart: { [weak self] in
                await self?.record(.init(
                    kind: .playbackRenderStart,
                    itemIndex: entry.index,
                    itemID: entry.item.id,
                    segmentID: entry.item.segmentID,
                    batchCount: 1,
                    elapsedSeconds: Date().timeIntervalSince(requestStartedAt),
                    policyState: self?.playbackPolicyState,
                    lane: lane.rawValue,
                    rateMultiplier: settings.rateMultiplier,
                    speakerClass: speakerClass
                ))
            },
            onFinish: { [weak self] in
                await self?.record(.init(
                    kind: .playbackQueueEnd,
                    itemIndex: entry.index,
                    itemID: entry.item.id,
                    segmentID: entry.item.segmentID,
                    batchCount: 1,
                    elapsedSeconds: Date().timeIntervalSince(requestStartedAt),
                    policyState: self?.playbackPolicyState,
                    lane: lane.rawValue,
                    rateMultiplier: settings.rateMultiplier,
                    speakerClass: speakerClass
                ))
            },
            onItemEnd: { [weak self] item in
                guard let self else { return }
                self.lastExpectedPlaybackEndElapsed = Date().timeIntervalSince(requestStartedAt)
                self.publishItemFinished(
                    item: item,
                    trace: (index: entry.index, segmentID: item.segmentID, durationSeconds: 0)
                )
                await self.record(.init(
                    kind: .playbackItemEnd,
                    itemIndex: entry.index,
                    itemID: item.id,
                    segmentID: item.segmentID,
                    elapsedSeconds: Date().timeIntervalSince(requestStartedAt),
                    policyState: self.playbackPolicyState,
                    lane: lane.rawValue,
                    rateMultiplier: settings.rateMultiplier,
                    speakerClass: speakerClass
                ))
            }
        )
        if let performanceReporter = streamingPlayback as? any QwenPlaybackPerformanceReporting {
            for event in performanceReporter.consumePerformanceEvents() {
                await record(.init(
                    kind: event.kind == .underrun ? .playbackUnderrun : .playbackRebuffer,
                    itemIndex: entry.index,
                    itemID: entry.item.id,
                    segmentID: entry.item.segmentID,
                    elapsedSeconds: Date().timeIntervalSince(requestStartedAt),
                    policyState: playbackPolicyState,
                    lane: lane.rawValue,
                    rateMultiplier: settings.rateMultiplier,
                    speakerClass: speakerClass,
                    playbackRunwaySeconds: event.runwaySeconds
                ))
            }
        }
    }

    private func streamingChunks(
        from streamingRuntime: any QwenAudioStreaming,
        request: QwenStreamingSynthesisRequest,
        onFirstChunk: @escaping @Sendable (QwenStreamingAudioChunk) async -> Void,
        onFinalChunk: @escaping @Sendable (QwenStreamingAudioChunk) async -> Void
    ) -> AsyncThrowingStream<QwenStreamingAudioChunk, Error> {
        AsyncThrowingStream { continuation in
            let task = Task.detached(priority: .userInitiated) {
                do {
                    try await streamingRuntime.streamAudio(request) { chunk in
                        if !chunk.audioData.isEmpty, chunk.sequenceIndex == 0 {
                            await onFirstChunk(chunk)
                        }
                        if chunk.isFinal {
                            await onFinalChunk(chunk)
                        }
                        continuation.yield(chunk)
                    }
                    continuation.finish()
                } catch {
                    continuation.finish(throwing: error)
                }
            }
            continuation.onTermination = { _ in
                task.cancel()
            }
        }
    }

    private func playPreparedBatch(
        _ batch: [QwenPreparedPlaybackItem],
        items: [SpeechPlaybackItem],
        batchStartIndex: Int,
        settings: SpeechSettings,
        requestStartedAt: Date,
        lane: QwenModelLane,
        speakerClass: String,
        willSpeak: @escaping @MainActor (SpeechPlaybackItem) async -> Void
    ) async throws {
        guard !batch.isEmpty else { return }
        var settings = settings
        settings.rateMultiplier = playback.effectiveCompleteFilePlaybackRate(
            for: settings.rateMultiplier
        )
        let batchStartItem = items[batchStartIndex]
        let batchCount = batch.count
        await record(.init(
            kind: .playbackBatchStart,
            itemIndex: batchStartIndex,
            itemID: batchStartItem.id,
            segmentID: batchStartItem.segmentID,
            batchCount: batchCount,
            elapsedSeconds: Date().timeIntervalSince(requestStartedAt),
            policyState: playbackPolicyState,
            lane: lane.rawValue,
            rateMultiplier: settings.rateMultiplier,
            speakerClass: speakerClass
        ))
        await record(.init(
            kind: .playbackQueueStart,
            itemIndex: batchStartIndex,
            itemID: batchStartItem.id,
            segmentID: batchStartItem.segmentID,
            batchCount: batchCount,
            elapsedSeconds: Date().timeIntervalSince(requestStartedAt),
            policyState: playbackPolicyState,
            lane: lane.rawValue,
            rateMultiplier: settings.rateMultiplier,
            speakerClass: speakerClass
        ))
        let playbackTraceByID = Dictionary(uniqueKeysWithValues: batch.map { item in
            (
                item.item.id,
                (
                    index: item.index,
                    segmentID: item.item.segmentID,
                    durationSeconds: item.audio.durationSeconds
                )
            )
        })
        publishPreparedTimings(for: batch, playbackRate: settings.rateMultiplier)
        schedulePrecisionAlignment(for: batch, playbackRate: settings.rateMultiplier)
        if let tracedPlayback = playback as? QwenAudioPlaybackTracing {
            try await tracedPlayback.play(
                batch,
                rateMultiplier: settings.rateMultiplier,
                volume: settings.volume,
                onStartItem: { [weak self] item in
                    let trace = playbackTraceByID[item.id]
                    await self?.recordPlaybackItemStart(
                        item: item,
                        trace: trace,
                        requestStartedAt: requestStartedAt,
                        playbackRate: settings.rateMultiplier,
                        lane: lane.rawValue,
                        speakerClass: speakerClass
                    )
                    await willSpeak(item)
                },
                onBufferEnqueue: { [weak self] item in
                    let trace = playbackTraceByID[item.id]
                    await self?.record(.init(
                        kind: .playbackBufferEnqueue,
                        itemIndex: trace?.index,
                        itemID: item.id,
                        segmentID: trace?.segmentID ?? item.segmentID,
                        elapsedSeconds: Date().timeIntervalSince(requestStartedAt),
                        policyState: self?.playbackPolicyState,
                        lane: lane.rawValue,
                        rateMultiplier: settings.rateMultiplier,
                        speakerClass: speakerClass
                    ))
                },
                onRenderStart: { [weak self] in
                    await self?.record(.init(
                        kind: .playbackRenderStart,
                        itemIndex: batchStartIndex,
                        itemID: batchStartItem.id,
                        segmentID: batchStartItem.segmentID,
                        batchCount: batchCount,
                        elapsedSeconds: Date().timeIntervalSince(requestStartedAt),
                        policyState: self?.playbackPolicyState,
                        lane: lane.rawValue,
                        rateMultiplier: settings.rateMultiplier,
                        speakerClass: speakerClass
                    ))
                },
                onFinish: { [weak self] in
                    await self?.record(.init(
                        kind: .playbackQueueEnd,
                        itemIndex: batchStartIndex,
                        itemID: batchStartItem.id,
                        segmentID: batchStartItem.segmentID,
                        batchCount: batchCount,
                        elapsedSeconds: Date().timeIntervalSince(requestStartedAt),
                        policyState: self?.playbackPolicyState,
                        lane: lane.rawValue,
                        rateMultiplier: settings.rateMultiplier,
                        speakerClass: speakerClass
                    ))
                },
                onItemEnd: { [weak self] item in
                    let trace = playbackTraceByID[item.id]
                    self?.publishItemFinished(item: item, trace: trace)
                    await self?.record(.init(
                        kind: .playbackItemEnd,
                        itemIndex: trace?.index,
                        itemID: item.id,
                        segmentID: trace?.segmentID ?? item.segmentID,
                        elapsedSeconds: Date().timeIntervalSince(requestStartedAt),
                        policyState: self?.playbackPolicyState,
                        lane: lane.rawValue,
                        rateMultiplier: settings.rateMultiplier,
                        speakerClass: speakerClass
                    ))
                }
            )
        } else {
            try await playback.play(
                batch,
                rateMultiplier: settings.rateMultiplier,
                volume: settings.volume
            ) { [weak self] item in
                let trace = playbackTraceByID[item.id]
                await self?.recordPlaybackItemStart(
                    item: item,
                    trace: trace,
                    requestStartedAt: requestStartedAt,
                    playbackRate: settings.rateMultiplier,
                    lane: lane.rawValue,
                    speakerClass: speakerClass
                )
                await willSpeak(item)
            }
            for item in batch.map(\.item) {
                let trace = playbackTraceByID[item.id]
                publishItemFinished(item: item, trace: trace)
            }
        }
    }

    private func schedulePrecisionAlignment(
        for batch: [QwenPreparedPlaybackItem],
        playbackRate: Double
    ) {
        guard let wordAligner, !batch.isEmpty else { return }
        let rate = min(max(playbackRate, 0.5), 2.4)
        let runway = batch.reduce(0) { $0 + max(0, $1.audio.durationSeconds) } / rate
        guard runway >= 1.5 else { return }

        let task = Task(priority: .utility) { [weak self] in
            for prepared in batch {
                guard !Task.isCancelled else { return }
                guard let track = await wordAligner.align(
                    item: prepared.item,
                    itemIndex: prepared.index,
                    audioURL: prepared.audio.url
                ) else {
                    continue
                }
                guard !Task.isCancelled else { return }
                self?.timingSink?.speechPlaybackDidReceiveWordCueTrack(track)
            }
        }
        alignmentTasks.append(task)
        if alignmentTasks.count > 16 {
            alignmentTasks.removeFirst(alignmentTasks.count - 16)
        }
    }

    public func stop() async {
        narrationGeneration &+= 1
        preparationTasks.forEach { $0.cancel() }
        preparationTasks.removeAll()
        await activePreparationStore?.cancelAll()
        activePreparationStore = nil
        alignmentTasks.forEach { $0.cancel() }
        alignmentTasks.removeAll()
        playback.stop()
        await promptLibraryLearningScheduler.narrationDidAbort()
    }

    private func prepareItems(
        _ items: [SpeechPlaybackItem],
        lane: QwenModelLane,
        speaker: String,
        settings: SpeechSettings,
        speakerClass: String,
        requestStartedAt: Date,
        store: QwenPreparedAudioStore
    ) async {
        guard !items.isEmpty else { return }
        let firstPrepared = await prepareSingleItem(
            items[0],
            index: 0,
            lane: lane,
            speaker: speaker,
            settings: settings,
            speakerClass: speakerClass,
            requestStartedAt: requestStartedAt,
            store: store
        )
        guard firstPrepared else {
            await cancelUnsetItems(in: store, itemCount: items.count, startingAt: 1)
            return
        }
        await Task.yield()
        guard items.count > 1, !Task.isCancelled else { return }

        let remaining = Array(items.enumerated().dropFirst())
        let initialLookahead = Array(remaining.prefix(firstLookaheadBatchLimit))
        let preparedInitialLookahead = await prepareBatch(
            initialLookahead,
            lane: lane,
            speaker: speaker,
            settings: settings,
            speakerClass: speakerClass,
            requestStartedAt: requestStartedAt,
            store: store
        )
        guard preparedInitialLookahead, !Task.isCancelled else {
            await cancelUnsetItems(in: store, itemCount: items.count, startingAt: initialLookahead.last?.offset ?? 1)
            return
        }

        let laterLookahead = Array(remaining.dropFirst(firstLookaheadBatchLimit))
        guard !laterLookahead.isEmpty else { return }
        var batchStart = 0
        while batchStart < laterLookahead.count, !Task.isCancelled {
            let batchEnd = min(batchStart + laterLookaheadBatchLimit, laterLookahead.count)
            let chunk = Array(laterLookahead[batchStart..<batchEnd])
            let preparedChunk = await prepareBatch(
                chunk,
                lane: lane,
                speaker: speaker,
                settings: settings,
                speakerClass: speakerClass,
                requestStartedAt: requestStartedAt,
                store: store
            )
            guard preparedChunk, !Task.isCancelled else {
                let nextIndex = (chunk.last?.offset ?? items.count - 1) + 1
                await cancelUnsetItems(in: store, itemCount: items.count, startingAt: nextIndex)
                return
            }
            batchStart = batchEnd
        }
    }

    private func prepareStreamingLookaheadItems(
        _ indexedItems: [(offset: Int, element: SpeechPlaybackItem)],
        itemCount: Int,
        lane: QwenModelLane,
        speaker: String,
        settings: SpeechSettings,
        speakerClass: String,
        requestStartedAt: Date,
        store: QwenPreparedAudioStore
    ) async {
        guard !indexedItems.isEmpty else { return }
        let firstLookahead = indexedItems[0]
        let batchedItems = Array(indexedItems.dropFirst())
        let batchTask = batchedItems.isEmpty ? nil : Task {
            await prepareStreamingBatchedLookaheadItems(
                batchedItems,
                itemCount: itemCount,
                lane: lane,
                speaker: speaker,
                settings: settings,
                speakerClass: speakerClass,
                requestStartedAt: requestStartedAt,
                store: store
            )
        }
        let preparedFirstLookahead = await prepareSingleItem(
            firstLookahead.element,
            index: firstLookahead.offset,
            lane: lane,
            speaker: speaker,
            settings: settings,
            speakerClass: speakerClass,
            requestStartedAt: requestStartedAt,
            store: store
        )
        guard preparedFirstLookahead, !Task.isCancelled else {
            batchTask?.cancel()
            await cancelUnsetItems(in: store, itemCount: itemCount, startingAt: firstLookahead.offset + 1)
            return
        }
        _ = await batchTask?.value
    }

    private func prepareStreamingBatchedLookaheadItems(
        _ batchedItems: [(offset: Int, element: SpeechPlaybackItem)],
        itemCount: Int,
        lane: QwenModelLane,
        speaker: String,
        settings: SpeechSettings,
        speakerClass: String,
        requestStartedAt: Date,
        store: QwenPreparedAudioStore
    ) async -> Bool {
        guard !batchedItems.isEmpty else { return true }
        var batchStart = 0
        var batchLimit = firstLookaheadBatchLimit
        while batchStart < batchedItems.count, !Task.isCancelled {
            let batchEnd = min(batchStart + batchLimit, batchedItems.count)
            let chunk = Array(batchedItems[batchStart..<batchEnd])
            let preparedChunk = await prepareBatch(
                chunk,
                lane: lane,
                speaker: speaker,
                settings: settings,
                speakerClass: speakerClass,
                requestStartedAt: requestStartedAt,
                store: store
            )
            guard preparedChunk, !Task.isCancelled else {
                let nextIndex = chunk.first?.offset ?? 1
                await cancelUnsetItems(in: store, itemCount: itemCount, startingAt: nextIndex)
                return false
            }
            batchStart = batchEnd
            batchLimit = laterLookaheadBatchLimit
        }
        return true
    }

    @discardableResult
    private func prepareSingleItem(
        _ item: SpeechPlaybackItem,
        index: Int,
        lane: QwenModelLane,
        speaker: String,
        settings: SpeechSettings,
        speakerClass: String,
        requestStartedAt: Date,
        store: QwenPreparedAudioStore
    ) async -> Bool {
        let cachePolicy = Self.cachePolicy(for: item)
        await record(.init(
            kind: .promptToSynthesizeStart,
            itemIndex: index,
            itemID: item.id,
            segmentID: item.segmentID,
            elapsedSeconds: Date().timeIntervalSince(requestStartedAt),
            cachePolicy: cachePolicy,
            policyState: playbackPolicyState,
            lane: lane.rawValue,
            rateMultiplier: settings.rateMultiplier,
            speakerClass: speakerClass
        ))
        do {
            let request = QwenSynthesisRequest(
                text: item.text,
                lane: lane,
                speaker: speaker,
                language: lane.language,
                rateMultiplier: settings.rateMultiplier,
                cachePolicy: cachePolicy,
                useReferenceVoice: settings.qwenUseReferenceVoice,
                referenceAudioPath: settings.effectiveQwenReferenceVoice.audioPath,
                referenceText: settings.effectiveQwenReferenceVoice.transcript,
                qwenDeEsserStrengthDecibels: settings.qwenDeEsserStrengthDecibels
            )
            let audio: QwenPreparedAudio
            if let adjustableRuntime = runtime as? any QwenAdjustableDeEsserSynthesizing {
                audio = try await adjustableRuntime.synthesize(request)
            } else {
                audio = try await runtime.synthesize(
                    text: request.text,
                    lane: request.lane,
                    speaker: request.speaker,
                    language: request.language,
                    rateMultiplier: request.rateMultiplier,
                    cachePolicy: request.cachePolicy,
                    useReferenceVoice: request.useReferenceVoice,
                    referenceAudioPath: request.referenceAudioPath,
                    referenceText: request.referenceText
                )
            }
            await recordSynthesisComplete(
                audio,
                item: item,
                index: index,
                cachePolicy: cachePolicy,
                lane: lane,
                rateMultiplier: settings.rateMultiplier,
                speakerClass: speakerClass,
                requestStartedAt: requestStartedAt
            )
            prewarmPlaybackVisualization(audio)
            await store.set(.success(audio), for: index)
            return true
        } catch is CancellationError {
            await store.set(.cancelled, for: index)
        } catch let error as QwenRuntimeError {
            await store.set(.qwenFailure(error), for: index)
        } catch {
            await store.set(.failure(error.localizedDescription), for: index)
        }
        return false
    }

    @discardableResult
    private func prepareBatch(
        _ indexedItems: [(offset: Int, element: SpeechPlaybackItem)],
        lane: QwenModelLane,
        speaker: String,
        settings: SpeechSettings,
        speakerClass: String,
        requestStartedAt: Date,
        store: QwenPreparedAudioStore
    ) async -> Bool {
        guard !indexedItems.isEmpty else { return true }
        for (index, item) in indexedItems {
            let cachePolicy = Self.cachePolicy(for: item)
            await record(.init(
                kind: .promptToSynthesizeStart,
                itemIndex: index,
                itemID: item.id,
                segmentID: item.segmentID,
                elapsedSeconds: Date().timeIntervalSince(requestStartedAt),
                cachePolicy: cachePolicy,
                policyState: playbackPolicyState,
                lane: lane.rawValue,
                rateMultiplier: settings.rateMultiplier,
                speakerClass: speakerClass
            ))
        }
        await record(.init(
            kind: .synthesisBatchStart,
            itemIndex: indexedItems.first?.offset,
            itemID: indexedItems.first?.element.id,
            segmentID: indexedItems.first?.element.segmentID,
            batchCount: indexedItems.count,
            elapsedSeconds: Date().timeIntervalSince(requestStartedAt),
            policyState: playbackPolicyState,
            lane: lane.rawValue,
            rateMultiplier: settings.rateMultiplier,
            speakerClass: speakerClass
        ))

        let requests = indexedItems.map { _, item in
            QwenSynthesisRequest(
                text: item.text,
                lane: lane,
                speaker: speaker,
                language: lane.language,
                rateMultiplier: settings.rateMultiplier,
                cachePolicy: Self.cachePolicy(for: item),
                useReferenceVoice: settings.qwenUseReferenceVoice,
                referenceAudioPath: settings.effectiveQwenReferenceVoice.audioPath,
                referenceText: settings.effectiveQwenReferenceVoice.transcript,
                qwenDeEsserStrengthDecibels: settings.qwenDeEsserStrengthDecibels
            )
        }

        do {
            let audios = try await runtime.synthesizeBatch(requests)
            guard audios.count == indexedItems.count else {
                throw QwenRuntimeError.commandFailed("Qwen batch returned \(audios.count) outputs for \(indexedItems.count) requests.")
            }
            await record(.init(
                kind: .synthesisBatchComplete,
                itemIndex: indexedItems.first?.offset,
                itemID: indexedItems.first?.element.id,
                segmentID: indexedItems.first?.element.segmentID,
                batchCount: indexedItems.count,
                elapsedSeconds: Date().timeIntervalSince(requestStartedAt),
                policyState: playbackPolicyState,
                lane: lane.rawValue,
                rateMultiplier: settings.rateMultiplier,
                speakerClass: speakerClass
            ))
            for ((index, item), audio) in zip(indexedItems, audios) {
                await recordSynthesisComplete(
                    audio,
                    item: item,
                    index: index,
                    cachePolicy: Self.cachePolicy(for: item),
                    lane: lane,
                    rateMultiplier: settings.rateMultiplier,
                    speakerClass: speakerClass,
                    requestStartedAt: requestStartedAt
                )
                prewarmPlaybackVisualization(audio)
                await store.set(.success(audio), for: index)
            }
            return true
        } catch is CancellationError {
            for (index, _) in indexedItems {
                await store.set(.cancelled, for: index)
            }
        } catch let error as QwenRuntimeError {
            for (index, _) in indexedItems {
                await store.set(.qwenFailure(error), for: index)
            }
        } catch {
            for (index, _) in indexedItems {
                await store.set(.failure(error.localizedDescription), for: index)
            }
        }
        return false
    }

    private func recordSynthesisComplete(
        _ audio: QwenPreparedAudio,
        item: SpeechPlaybackItem,
        index: Int,
        cachePolicy: QwenAudioCachePolicy,
        lane: QwenModelLane,
        rateMultiplier: Double,
        speakerClass: String,
        requestStartedAt: Date
    ) async {
        await record(.init(
            kind: .synthesisComplete,
            itemIndex: index,
            itemID: item.id,
            segmentID: item.segmentID,
            cacheHit: audio.isFromCache,
            elapsedSeconds: Date().timeIntervalSince(requestStartedAt),
            durationSeconds: audio.durationSeconds,
            cachePolicy: cachePolicy,
            policyState: playbackPolicyState,
            lane: lane.rawValue,
            rateMultiplier: rateMultiplier,
            speakerClass: speakerClass
        ))
    }

    private func prewarmPlaybackVisualization(_ audio: QwenPreparedAudio) {
        (playback as? QwenAudioPlayback)?.prewarmVisualization(for: audio)
    }

    private func cancelUnsetItems(
        in store: QwenPreparedAudioStore,
        itemCount: Int,
        startingAt startIndex: Int
    ) async {
        guard startIndex < itemCount else { return }
        for index in startIndex..<itemCount where await store.outcome(for: index) == nil {
            await store.set(.cancelled, for: index)
        }
    }

    nonisolated private func waitForPreparedAudio(
        in store: QwenPreparedAudioStore,
        index: Int,
        timeout: TimeInterval? = nil
    ) async throws -> QwenPreparedAudio? {
        if let outcome = await store.outcome(for: index) {
            return try outcome.get()
        }
        guard let timeout else {
            return try await store.wait(for: index).get()
        }
        guard timeout > 0 else {
            return nil
        }

        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if let outcome = await store.outcome(for: index) {
                return try outcome.get()
            }
            let remaining = deadline.timeIntervalSinceNow
            guard remaining > 0 else { break }
            let sleepSeconds = min(0.01, remaining)
            try await Task.sleep(nanoseconds: UInt64(sleepSeconds * 1_000_000_000))
        }
        return nil
    }

    private func appendReadyContiguousItems(
        to batch: inout [QwenPreparedPlaybackItem],
        startingAt startIndex: Int,
        items: [SpeechPlaybackItem],
        store: QwenPreparedAudioStore,
        maxCount: Int? = nil
    ) async throws {
        var index = startIndex
        while index < items.count,
              maxCount.map({ batch.count < $0 }) ?? true,
              let outcome = await store.outcome(for: index) {
            let audio = try outcome.get()
            batch.append(QwenPreparedPlaybackItem(index: index, item: items[index], audio: audio))
            index += 1
        }
    }

    private func maxInitialPlaybackBatchCount(for policyState: QwenPlaybackPolicyState) -> Int {
        switch policyState {
        case .normal:
            return maxInitialPlaybackBatchCount
        case .degraded:
            return degradedMaxInitialPlaybackBatchCount
        }
    }

    private func shouldStartDegradedEarly(
        batch: [QwenPreparedPlaybackItem],
        itemCount: Int,
        playbackRate: Double
    ) -> Bool {
        guard playbackPolicyState == .degraded,
              batch.count < itemCount else {
            return false
        }
        return playbackRunwaySeconds(for: batch, playbackRate: playbackRate) >= fastStartPolicy.targetInitialRunwaySeconds
    }

    private func playbackRunwaySeconds(
        for batch: [QwenPreparedPlaybackItem],
        playbackRate: Double
    ) -> Double {
        let clampedRate = min(max(playbackRate, 0.5), 2.4)
        return batch.reduce(0) { total, item in
            total + item.audio.durationSeconds / clampedRate
        }
    }

    private func shouldWaitForInitialContiguousAudio(
        batch: [QwenPreparedPlaybackItem],
        itemCount: Int,
        playbackRate: Double
    ) -> Bool {
        guard playbackPolicyState == .degraded,
              batch.count < itemCount else {
            return false
        }
        return playbackRunwaySeconds(for: batch, playbackRate: playbackRate) < fastStartPolicy.targetInitialRunwaySeconds
    }

    private func shouldEnterDegradedForPredictedGap(
        firstAudio: QwenPreparedAudio,
        nextIndex: Int,
        playbackRate: Double,
        store: QwenPreparedAudioStore
    ) async -> Bool {
        guard playbackPolicyState == .normal else { return false }
        return await store.outcome(for: nextIndex) == nil
    }

    private func initialTailWait(
        firstAudio: QwenPreparedAudio,
        playbackRate: Double,
        requestStartedAt: Date,
        hasNextItem: Bool
    ) -> InitialTailWait {
        let clampedRate = min(max(playbackRate, 0.5), 2.4)
        let firstPlaybackDuration = firstAudio.durationSeconds / clampedRate
        guard hasNextItem,
              firstAudio.durationSeconds > 0 else {
            return .none
        }
        if firstAudio.isFromCache,
           firstPlaybackDuration >= fastStartPolicy.hardGapCapSeconds {
            return .none
        }
        if playbackPolicyState == .normal,
           firstPlaybackDuration >= shortStarterDurationThreshold {
            return .none
        }

        let elapsed = Date().timeIntervalSince(requestStartedAt)
        if playbackPolicyState == .degraded {
            return degradedInitialTailWait(
                firstPlaybackDuration: firstPlaybackDuration,
                firstAudioIsFromCache: firstAudio.isFromCache,
                elapsed: elapsed
            )
        }

        let budget = firstAudioBudgetSeconds
        let bufferSeconds = initialTailBufferSeconds
        let remaining = budget - firstAudioBudgetReserveSeconds - elapsed
        if remaining <= 0 {
            return .none
        }
        return .timed(min(bufferSeconds, remaining))
    }

    private func degradedInitialTailWait(
        firstPlaybackDuration: Double,
        firstAudioIsFromCache: Bool,
        elapsed: Double
    ) -> InitialTailWait {
        let fallbackRemaining = fastStartPolicy.fallbackFirstAudioSeconds - elapsed
        guard fallbackRemaining > 0 else {
            return .none
        }

        if firstPlaybackDuration < fastStartPolicy.hardGapCapSeconds {
            return .timed(fallbackRemaining)
        }

        let firstAudioTarget = firstAudioIsFromCache
            ? fastStartPolicy.cachedStarterFirstAudioSeconds
            : fastStartPolicy.targetFirstAudioSeconds
        let targetRemaining = firstAudioTarget - elapsed
        let runwayWait = max(0, fastStartPolicy.targetInitialRunwaySeconds - firstPlaybackDuration)
        let desiredWait = max(0, max(targetRemaining, runwayWait))
        guard desiredWait > 0 else {
            return .none
        }
        return .timed(min(fallbackRemaining, desiredWait))
    }

    private func recordPlaybackItemStart(
        item: SpeechPlaybackItem,
        trace: (index: Int, segmentID: String, durationSeconds: Double)?,
        requestStartedAt: Date,
        playbackRate: Double,
        lane: String,
        speakerClass: String
    ) async {
        let elapsed = Date().timeIntervalSince(requestStartedAt)
        let durationSeconds = trace?.durationSeconds ?? 0
        if let expectedEnd = lastExpectedPlaybackEndElapsed {
            let observedGap = max(0, elapsed - expectedEnd)
            recordObservedGap(observedGap)
            if observedGap > predictedGapThresholdSeconds {
                await enterDegradedPolicy(
                    reason: "observedGap",
                    itemIndex: trace?.index,
                    itemID: item.id,
                    segmentID: trace?.segmentID ?? item.segmentID,
                    requestStartedAt: requestStartedAt,
                    predictedGapSeconds: observedGap,
                    lane: lane,
                    rateMultiplier: playbackRate,
                    speakerClass: speakerClass
                )
            }
        }
        let clampedRate = min(max(playbackRate, 0.5), 2.4)
        if durationSeconds > 0 {
            lastExpectedPlaybackEndElapsed = elapsed + durationSeconds / clampedRate
        } else {
            lastExpectedPlaybackEndElapsed = nil
        }
        await record(.init(
            kind: .playbackItemStart,
            itemIndex: trace?.index,
            itemID: item.id,
            segmentID: trace?.segmentID ?? item.segmentID,
            elapsedSeconds: elapsed,
            durationSeconds: durationSeconds,
            policyState: playbackPolicyState,
            lane: lane,
            rateMultiplier: playbackRate,
            speakerClass: speakerClass
        ))
    }

    private func publishPreparedTimings(
        for batch: [QwenPreparedPlaybackItem],
        playbackRate: Double
    ) {
        let clampedRate = min(max(playbackRate, 0.5), 2.4)
        for prepared in batch {
            let duration = prepared.audio.durationSeconds
            guard duration.isFinite, duration > 0 else { continue }
            // QwenRuntimeManager has already written a threshold-trimmed WAV with an 80 ms
            // safety pad. Publishing the full prepared frame range here makes every fallback cue
            // available before playback without rescanning audio on the first-audio path.
            timingSink?.speechPlaybackDidReceiveTiming(SpeechPlaybackItemTiming(
                itemID: prepared.item.id,
                segmentID: prepared.item.segmentID,
                itemIndex: prepared.index,
                durationSeconds: duration / clampedRate,
                source: .qwenPreparedAudio,
                sourceAudioDurationSeconds: duration,
                audibleStartSeconds: 0,
                audibleEndSeconds: duration
            ))
        }
    }

    private func publishItemFinished(
        item: SpeechPlaybackItem,
        trace: (index: Int, segmentID: String, durationSeconds: Double)?
    ) {
        timingSink?.speechPlaybackDidFinishItem(
            itemID: item.id,
            segmentID: trace?.segmentID ?? item.segmentID,
            itemIndex: trace?.index
        )
    }

    private func recordObservedGap(_ gapSeconds: Double) {
        guard gapSeconds.isFinite, gapSeconds > 0 else { return }
        recentObservedGaps.append(gapSeconds)
        if recentObservedGaps.count > recentObservedGapLimit {
            recentObservedGaps.removeFirst(recentObservedGaps.count - recentObservedGapLimit)
        }
    }

    private func enterDegradedPolicy(
        reason: String,
        itemIndex: Int?,
        itemID: String?,
        segmentID: String?,
        requestStartedAt: Date,
        predictedGapSeconds: Double? = nil,
        lane: String,
        rateMultiplier: Double,
        speakerClass: String
    ) async {
        guard playbackPolicyState != .degraded else { return }
        playbackPolicyState = .degraded
        await record(.init(
            kind: .adaptivePolicyTransition,
            itemIndex: itemIndex,
            itemID: itemID,
            segmentID: segmentID,
            elapsedSeconds: Date().timeIntervalSince(requestStartedAt),
            policyState: .degraded,
            policyReason: reason,
            predictedGapSeconds: predictedGapSeconds,
            lane: lane,
            rateMultiplier: rateMultiplier,
            speakerClass: speakerClass
        ))
    }

    private func record(_ event: QwenPlaybackTraceEvent) async {
        await traceSink?.record(event)
        logger.debug(
            "Qwen event kind=\(event.kind.rawValue, privacy: .public) item=\(event.itemIndex ?? -1, privacy: .public) batch=\(event.batchCount ?? 0, privacy: .public) cacheHit=\(event.cacheHit.map(String.init) ?? "n/a", privacy: .public) elapsed=\(event.elapsedSeconds ?? -1, privacy: .public)"
        )
    }

    nonisolated static func cachePolicy(for item: SpeechPlaybackItem) -> QwenAudioCachePolicy {
        if item.audioCachePolicy == .persistent {
            return .persistent
        }
        return isTerminalTaskSegment(item.segmentID) ? .persistent : item.audioCachePolicy
    }

    private nonisolated static func isTerminalTaskSegment(_ segmentID: String) -> Bool {
        let parts = segmentID.split(separator: "#", maxSplits: 1).map(String.init)
        guard parts.count == 2 else { return false }
        return ["starter", "tail", "task"].contains(parts[1])
    }
}

private actor QwenPreparedAudioStore {
    private var outcomes: [Int: QwenPreparationOutcome] = [:]
    private var continuations: [
        Int: [UUID: CheckedContinuation<QwenPreparationOutcome, Never>]
    ] = [:]
    private var isCancelled = false

    func outcome(for index: Int) -> QwenPreparationOutcome? {
        outcomes[index] ?? (isCancelled ? .cancelled : nil)
    }

    func wait(for index: Int) async -> QwenPreparationOutcome {
        if Task.isCancelled {
            return .cancelled
        }
        if let outcome = outcomes[index] {
            return outcome
        }
        if isCancelled {
            return .cancelled
        }

        let waiterID = UUID()
        return await withTaskCancellationHandler {
            await withCheckedContinuation { continuation in
                if Task.isCancelled || isCancelled {
                    continuation.resume(returning: .cancelled)
                } else if let outcome = outcomes[index] {
                    continuation.resume(returning: outcome)
                } else {
                    continuations[index, default: [:]][waiterID] = continuation
                }
            }
        } onCancel: {
            Task {
                await self.cancelWaiter(waiterID, for: index)
            }
        }
    }

    func set(_ outcome: QwenPreparationOutcome, for index: Int) {
        if isCancelled {
            removeTemporaryAudio(in: outcome)
            return
        }
        guard outcomes[index] == nil else { return }
        outcomes[index] = outcome
        let waiting = continuations.removeValue(forKey: index).map { Array($0.values) } ?? []
        for continuation in waiting {
            continuation.resume(returning: outcome)
        }
    }

    func cancelAll() {
        guard !isCancelled else { return }
        isCancelled = true
        for outcome in outcomes.values {
            removeTemporaryAudio(in: outcome)
        }
        outcomes.removeAll()
        let waiting = continuations.values.flatMap { $0.values }
        continuations.removeAll()
        for continuation in waiting {
            continuation.resume(returning: .cancelled)
        }
    }

    private func cancelWaiter(_ waiterID: UUID, for index: Int) {
        guard var waiting = continuations[index],
              let continuation = waiting.removeValue(forKey: waiterID) else {
            return
        }
        if waiting.isEmpty {
            continuations.removeValue(forKey: index)
        } else {
            continuations[index] = waiting
        }
        continuation.resume(returning: .cancelled)
    }

    private func removeTemporaryAudio(in outcome: QwenPreparationOutcome) {
        guard case .success(let audio) = outcome, audio.removeAfterPlayback else { return }
        try? FileManager.default.removeItem(at: audio.url)
    }
}

private actor QwenStreamingReadinessTracker {
    private var readyIndices: Set<Int> = []

    func markReady(index: Int) {
        readyIndices.insert(index)
    }

    func waitUntilReady(index: Int, timeoutSeconds: TimeInterval) async {
        guard !readyIndices.contains(index), timeoutSeconds > 0 else { return }
        let deadline = Date().addingTimeInterval(timeoutSeconds)
        while !readyIndices.contains(index), Date() < deadline, !Task.isCancelled {
            do {
                try await Task.sleep(for: .milliseconds(20))
            } catch {
                return
            }
        }
    }
}

private enum QwenPreparationOutcome: Equatable, Sendable {
    case success(QwenPreparedAudio)
    case qwenFailure(QwenRuntimeError)
    case failure(String)
    case cancelled

    func get() throws -> QwenPreparedAudio {
        switch self {
        case .success(let audio):
            return audio
        case .qwenFailure(let error):
            throw error
        case .failure(let message):
            throw QwenRuntimeError.commandFailed(message)
        case .cancelled:
            throw CancellationError()
        }
    }
}

private enum InitialTailWait: Sendable {
    case none
    case timed(TimeInterval)
}

@MainActor
public final class StudySpeechBackend: SpeechBackend, SpeechPlaybackTimingReporting {
    public var settings: SpeechSettings {
        didSet {
            let clamped = settings.clamped
            applySettings(clamped)
        }
    }

    public weak var visualizationSink: (any SpeechPlaybackVisualizationSink)? {
        didSet {
            if let qwen = qwenBackend as? QwenSpeechBackend {
                qwen.visualizationSink = visualizationSink
            }
            (pocketBackend as? PocketSpeechBackend)?.visualizationSink = visualizationSink
        }
    }

    public weak var timingSink: (any SpeechPlaybackTimingSink)? {
        didSet {
            applyTimingSink()
        }
    }

    private let appleBackend: any SpeechBackend
    private let qwenBackend: any SpeechBackend
    private let pocketBackend: any SpeechBackend
    private var appleMeterTask: Task<Void, Never>?
    private var speechGeneration: UInt64 = 0
    private var hasActiveSpeech = false

    public init(
        settings: SpeechSettings = .default,
        apple: AVFoundationSpeechBackend? = nil,
        qwen: QwenSpeechBackend? = nil,
        pocket: PocketSpeechBackend? = nil
    ) {
        self.appleBackend = apple ?? AVFoundationSpeechBackend(settings: settings.clamped)
        self.qwenBackend = qwen ?? QwenSpeechBackend(settings: settings.clamped)
        self.pocketBackend = pocket ?? PocketSpeechBackend(settings: settings.clamped)
        self.settings = settings.clamped
        applySettings(self.settings)
    }

    public init(
        settings: SpeechSettings = .default,
        appleBackend: any SpeechBackend,
        qwenBackend: any SpeechBackend,
        pocketBackend: (any SpeechBackend)? = nil
    ) {
        let clamped = settings.clamped
        self.settings = clamped
        self.appleBackend = appleBackend
        self.qwenBackend = qwenBackend
        self.pocketBackend = pocketBackend ?? PocketSpeechBackend(settings: settings.clamped)
        applySettings(clamped)
    }

    public func speak(_ text: String) async throws {
        try await latestPlayback {
            try await visualizedPlayback {
                try await activeBackend().speak(text)
            }
        }
    }

    public func speak(
        _ items: [SpeechPlaybackItem],
        willSpeak: @escaping @MainActor (SpeechPlaybackItem) async -> Void
    ) async throws {
        try await latestPlayback {
            try await visualizedPlayback {
                try await activeBackend().speak(items, willSpeak: willSpeak)
            }
        }
    }

    public func stop() async {
        speechGeneration &+= 1
        hasActiveSpeech = false
        appleMeterTask?.cancel()
        appleMeterTask = nil
        visualizationSink?.speechPlaybackVisualizationDidEnd()
        await appleBackend.stop()
        await qwenBackend.stop()
        await pocketBackend.stop()
    }

    private func latestPlayback<T>(_ operation: () async throws -> T) async throws -> T {
        speechGeneration &+= 1
        let generation = speechGeneration
        if hasActiveSpeech {
            await appleBackend.stop()
            await qwenBackend.stop()
            await pocketBackend.stop()
        }
        try Task.checkCancellation()
        guard generation == speechGeneration else { throw CancellationError() }
        hasActiveSpeech = true
        defer {
            if speechGeneration == generation {
                hasActiveSpeech = false
            }
        }
        return try await operation()
    }

    private func activeBackend() -> any SpeechBackend {
        switch settings.engineID {
        case .apple: appleBackend
        case .pocket: pocketBackend
        case .qwenSmall, .qwenBest: qwenBackend
        }
    }

    private func applySettings(_ settings: SpeechSettings) {
        if let apple = appleBackend as? AVFoundationSpeechBackend {
            apple.settings = settings
        }
        if let qwen = qwenBackend as? QwenSpeechBackend {
            qwen.settings = settings
            qwen.visualizationSink = visualizationSink
        }
        if let pocket = pocketBackend as? PocketSpeechBackend {
            pocket.settings = settings
            pocket.visualizationSink = visualizationSink
        }
        applyTimingSink()
    }

    private func applyTimingSink() {
        if let apple = appleBackend as? any SpeechPlaybackTimingReporting {
            apple.timingSink = timingSink
        }
        if let qwen = qwenBackend as? any SpeechPlaybackTimingReporting {
            qwen.timingSink = timingSink
        }
        (pocketBackend as? any SpeechPlaybackTimingReporting)?.timingSink = timingSink
    }

    private func visualizedPlayback<T>(_ operation: () async throws -> T) async throws -> T {
        guard settings.showPlaybackHUD, let visualizationSink else {
            return try await operation()
        }

        let generation = speechGeneration
        visualizationSink.speechPlaybackVisualizationDidStart()
        if settings.engineID == .apple {
            visualizationSink.speechPlaybackVisualizationAudioDidStart()
            startAppleMeterAnimation()
        }
        defer {
            if speechGeneration == generation {
                appleMeterTask?.cancel()
                appleMeterTask = nil
                visualizationSink.speechPlaybackVisualizationDidEnd()
            }
        }
        return try await operation()
    }

    private func startAppleMeterAnimation() {
        appleMeterTask?.cancel()
        let pattern: [[Double]] = [
            [0.38, 0.57, 0.75, 0.64, 0.46, 0.30, 0.22, 0.18, 0.28, 0.48, 0.66, 0.58, 0.40, 0.26, 0.18, 0.14],
            [0.24, 0.35, 0.52, 0.70, 0.82, 0.68, 0.48, 0.32, 0.24, 0.34, 0.54, 0.72, 0.61, 0.42, 0.28, 0.20],
            [0.16, 0.25, 0.38, 0.52, 0.70, 0.86, 0.74, 0.56, 0.40, 0.30, 0.42, 0.60, 0.78, 0.64, 0.45, 0.30],
            [0.28, 0.48, 0.66, 0.54, 0.36, 0.24, 0.18, 0.30, 0.52, 0.78, 0.88, 0.70, 0.48, 0.32, 0.22, 0.16]
        ]
        appleMeterTask = Task { @MainActor [weak self] in
            var index = 0
            while !Task.isCancelled {
                guard let self else { return }
                let bars = pattern[index % pattern.count]
                let level = bars.max() ?? 0
                self.visualizationSink?.speechPlaybackVisualizationFrameDidChange(
                    SpeechPlaybackVisualizationFrame(level: level, barLevels: bars)
                )
                index += 1
                try? await Task.sleep(nanoseconds: 80_000_000)
            }
        }
    }
}
