import Foundation

public struct SpeechPlaybackItem: Equatable, Sendable {
    public var id: String
    public var segmentID: String
    public var sourceText: String
    public var text: String
    public var audioCachePolicy: QwenAudioCachePolicy

    public init(
        id: String,
        segmentID: String,
        sourceText: String? = nil,
        text: String,
        audioCachePolicy: QwenAudioCachePolicy = .transient
    ) {
        self.id = id
        self.segmentID = segmentID
        self.sourceText = sourceText ?? text
        self.text = text
        self.audioCachePolicy = audioCachePolicy
    }
}

public enum SpeechPlaybackTimingSource: String, Codable, Equatable, Sendable {
    case pocketStream
    case qwenPreparedAudio
    case appleObserved
    case calibratedEstimate
}

public struct SpeechPlaybackItemTiming: Codable, Equatable, Sendable {
    public var itemID: String
    public var segmentID: String
    public var itemIndex: Int?
    public var durationSeconds: TimeInterval
    public var source: SpeechPlaybackTimingSource
    public var sourceAudioDurationSeconds: TimeInterval?
    public var audibleStartSeconds: TimeInterval?
    public var audibleEndSeconds: TimeInterval?

    public init(
        itemID: String,
        segmentID: String,
        itemIndex: Int? = nil,
        durationSeconds: TimeInterval,
        source: SpeechPlaybackTimingSource,
        sourceAudioDurationSeconds: TimeInterval? = nil,
        audibleStartSeconds: TimeInterval? = nil,
        audibleEndSeconds: TimeInterval? = nil
    ) {
        self.itemID = itemID
        self.segmentID = segmentID
        self.itemIndex = itemIndex
        self.durationSeconds = durationSeconds
        self.source = source
        self.sourceAudioDurationSeconds = sourceAudioDurationSeconds
        self.audibleStartSeconds = audibleStartSeconds
        self.audibleEndSeconds = audibleEndSeconds
    }
}

public enum SpeechPlaybackWordCueSource: String, Codable, Equatable, Sendable {
    case forcedAligned
    case weightedFallback
    case appleObserved
}

public enum SpeechPlaybackVisualOffset: String, Codable, Equatable, Sendable {
    case lead50Milliseconds
    case synchronized
    case lag50Milliseconds

    public static var effectiveDeveloperOverride: Self {
        #if DEBUG
            if let rawValue = UserDefaults.standard.string(forKey: "SalientDeveloperRSVPVisualOffset"),
                let override = Self(rawValue: rawValue)
            {
                return override
            }
        #endif
        return .lead50Milliseconds
    }

    fileprivate func sourceOffsetSeconds(
        intervalToNextCue: TimeInterval,
        playbackRate: Double
    ) -> TimeInterval {
        let rate = min(2.4, max(0.5, playbackRate))
        switch self {
        case .lead50Milliseconds:
            return min(0.050 * rate, max(0, intervalToNextCue) * 0.25)
        case .synchronized:
            return 0
        case .lag50Milliseconds:
            return -0.050 * rate
        }
    }
}

public struct SpeechPlaybackWordCue: Codable, Equatable, Sendable {
    public var tokenIndex: Int
    public var startSeconds: TimeInterval
    public var endSeconds: TimeInterval

    public init(
        tokenIndex: Int,
        startSeconds: TimeInterval,
        endSeconds: TimeInterval
    ) {
        self.tokenIndex = tokenIndex
        self.startSeconds = startSeconds
        self.endSeconds = endSeconds
    }
}

public struct SpeechPlaybackWordCueTrack: Codable, Equatable, Sendable {
    public var itemID: String
    public var segmentID: String
    public var itemIndex: Int?
    public var source: SpeechPlaybackWordCueSource
    public var cues: [SpeechPlaybackWordCue]
    public var alignmentRuntimeSeconds: TimeInterval?
    public var tokenCoverage: Double

    public init(
        itemID: String,
        segmentID: String,
        itemIndex: Int? = nil,
        source: SpeechPlaybackWordCueSource,
        cues: [SpeechPlaybackWordCue],
        alignmentRuntimeSeconds: TimeInterval? = nil,
        tokenCoverage: Double = 1
    ) {
        self.itemID = itemID
        self.segmentID = segmentID
        self.itemIndex = itemIndex
        self.source = source
        self.cues = cues
        self.alignmentRuntimeSeconds = alignmentRuntimeSeconds
        self.tokenCoverage = tokenCoverage
    }

    public func cueIndex(
        at sourcePositionSeconds: TimeInterval,
        visualOffset: SpeechPlaybackVisualOffset = .lead50Milliseconds,
        playbackRate: Double = 1
    ) -> Int? {
        guard !cues.isEmpty, sourcePositionSeconds.isFinite else { return nil }
        var lower = 0
        var upper = cues.count
        while lower < upper {
            let middle = (lower + upper) / 2
            let cue = cues[middle]
            let nextStart = middle + 1 < cues.count ? cues[middle + 1].startSeconds : cue.endSeconds
            let interval = max(0, nextStart - cue.startSeconds)
            let offset = visualOffset.sourceOffsetSeconds(
                intervalToNextCue: interval,
                playbackRate: playbackRate
            )
            if cue.startSeconds - offset <= sourcePositionSeconds {
                lower = middle + 1
            } else {
                upper = middle
            }
        }
        return lower > 0 ? lower - 1 : 0
    }
}

public struct SpeechPlaybackProgress: Codable, Equatable, Sendable {
    public var playbackID: UUID
    public var itemID: String
    public var segmentID: String
    public var itemIndex: Int?
    public var sourcePositionSeconds: TimeInterval
    public var sourceDurationSeconds: TimeInterval
    public var currentTokenIndex: Int?
    public var playbackRate: Double

    public init(
        playbackID: UUID,
        itemID: String,
        segmentID: String,
        itemIndex: Int? = nil,
        sourcePositionSeconds: TimeInterval,
        sourceDurationSeconds: TimeInterval,
        currentTokenIndex: Int? = nil,
        playbackRate: Double = 1
    ) {
        self.playbackID = playbackID
        self.itemID = itemID
        self.segmentID = segmentID
        self.itemIndex = itemIndex
        self.sourcePositionSeconds = sourcePositionSeconds
        self.sourceDurationSeconds = sourceDurationSeconds
        self.currentTokenIndex = currentTokenIndex
        self.playbackRate = playbackRate
    }
}

@MainActor
public protocol SpeechPlaybackTimingSink: AnyObject {
    func speechPlaybackWillUseFinalItems(_ items: [SpeechPlaybackItem])
    func speechPlaybackDidReceiveTiming(_ timing: SpeechPlaybackItemTiming)
    func speechPlaybackDidReceiveWordCueTrack(_ track: SpeechPlaybackWordCueTrack)
    func speechPlaybackDidReceiveProgress(_ progress: SpeechPlaybackProgress)
    func speechPlaybackDidFinishItem(itemID: String, segmentID: String, itemIndex: Int?)
}

extension SpeechPlaybackTimingSink {
    public func speechPlaybackWillUseFinalItems(_ items: [SpeechPlaybackItem]) {}
    public func speechPlaybackDidReceiveTiming(_ timing: SpeechPlaybackItemTiming) {}
    public func speechPlaybackDidReceiveWordCueTrack(_ track: SpeechPlaybackWordCueTrack) {}
    public func speechPlaybackDidReceiveProgress(_ progress: SpeechPlaybackProgress) {}
    public func speechPlaybackDidFinishItem(itemID: String, segmentID: String, itemIndex: Int?) {}
}

@MainActor
public protocol SpeechPlaybackTimingReporting: AnyObject {
    var timingSink: (any SpeechPlaybackTimingSink)? { get set }
}

@MainActor
public protocol SpeechBackend: AnyObject {
    func speak(_ text: String) async throws
    func speak(
        _ items: [SpeechPlaybackItem],
        willSpeak: @escaping @MainActor (SpeechPlaybackItem) async -> Void
    ) async throws
    func stop() async
}

extension SpeechBackend {
    public func speak(
        _ items: [SpeechPlaybackItem],
        willSpeak: @escaping @MainActor (SpeechPlaybackItem) async -> Void
    ) async throws {
        for item in items {
            try Task.checkCancellation()
            await willSpeak(item)
            try await speak(item.text)
        }
    }
}
