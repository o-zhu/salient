import Foundation

public struct ReadQuestionTraceEvent: Codable, Equatable, Sendable {
    public enum Kind: String, Codable, Sendable {
        case actionStart
        case captureStart
        case captureEnd
        case decodeEnd
        case planBuilt
        case normalizationEnd
        case speechStart
        case highlightStart
        case highlightEnd
        case highlightLate
        case speechEnd
        case actionEnd
        case actionCancelled
        case actionFailed
    }

    public var kind: Kind
    public var elapsedSeconds: Double?
    public var segmentCount: Int?
    public var itemCount: Int?
    public var segmentID: String?
    public var itemIndex: Int?
    public var role: String?
    public var region: String?
    public var sourceCharacterCount: Int?
    public var normalizedCharacterCount: Int?
    public var cachePolicy: QwenAudioCachePolicy?
    public var errorCategory: String?

    public init(
        kind: Kind,
        elapsedSeconds: Double? = nil,
        segmentCount: Int? = nil,
        itemCount: Int? = nil,
        segmentID: String? = nil,
        itemIndex: Int? = nil,
        role: String? = nil,
        region: String? = nil,
        sourceCharacterCount: Int? = nil,
        normalizedCharacterCount: Int? = nil,
        cachePolicy: QwenAudioCachePolicy? = nil,
        errorCategory: String? = nil
    ) {
        self.kind = kind
        self.elapsedSeconds = elapsedSeconds
        self.segmentCount = segmentCount
        self.itemCount = itemCount
        self.segmentID = segmentID
        self.itemIndex = itemIndex
        self.role = role
        self.region = region
        self.sourceCharacterCount = sourceCharacterCount
        self.normalizedCharacterCount = normalizedCharacterCount
        self.cachePolicy = cachePolicy
        self.errorCategory = errorCategory
    }
}

public protocol ReadQuestionTraceSink: Sendable {
    func record(_ event: ReadQuestionTraceEvent) async
}

public struct ReadQuestionAudibleSummary: Codable, Equatable, Sendable {
    public var firstAudibleAudioSeconds: Double?
    public var maxAudibleGapSeconds: Double?
    public var medianAudibleGapSeconds: Double?
    public var p95AudibleGapSeconds: Double?
    public var audibleLongGapOverOneSecondCount: Int
    public var audibleLongGapOverTwoSecondCount: Int

    public init(
        firstAudibleAudioSeconds: Double? = nil,
        maxAudibleGapSeconds: Double? = nil,
        medianAudibleGapSeconds: Double? = nil,
        p95AudibleGapSeconds: Double? = nil,
        audibleLongGapOverOneSecondCount: Int = 0,
        audibleLongGapOverTwoSecondCount: Int = 0
    ) {
        self.firstAudibleAudioSeconds = firstAudibleAudioSeconds
        self.maxAudibleGapSeconds = maxAudibleGapSeconds
        self.medianAudibleGapSeconds = medianAudibleGapSeconds
        self.p95AudibleGapSeconds = p95AudibleGapSeconds
        self.audibleLongGapOverOneSecondCount = audibleLongGapOverOneSecondCount
        self.audibleLongGapOverTwoSecondCount = audibleLongGapOverTwoSecondCount
    }
}

public struct ReadQuestionTraceSummary: Codable, Equatable, Sendable {
    public var captureLatencySeconds: Double?
    public var planningLatencySeconds: Double?
    public var highlightP95Seconds: Double?
    public var highlightMaxSeconds: Double?
    public var firstAudibleAudioSeconds: Double?
    public var maxAudibleGapSeconds: Double?
    public var medianAudibleGapSeconds: Double?
    public var p95AudibleGapSeconds: Double?
    public var audibleLongGapOverOneSecondCount: Int
    public var audibleLongGapOverTwoSecondCount: Int
    public var appSideMaxGapSeconds: Double?
    public var appSideP95GapSeconds: Double?
    public var appSideLongGapOverOneSecondCount: Int
    public var appSideLongGapOverTwoSecondCount: Int
    public var underrunWaitCount: Int
    public var itemCount: Int
    public var validationWarnings: [String]

    public init(
        events: [ReadQuestionTraceEvent],
        qwenSummary: QwenPlaybackTraceSummary? = nil,
        audibleSummary: ReadQuestionAudibleSummary? = nil,
        validationWarnings: [String] = []
    ) {
        captureLatencySeconds = Self.interval(
            from: .captureStart,
            to: .captureEnd,
            in: events
        )
        planningLatencySeconds = Self.interval(
            from: .captureEnd,
            to: .normalizationEnd,
            in: events
        )

        let highlightDurations = Self.highlightDurations(in: events).sorted()
        highlightP95Seconds = Self.percentile(highlightDurations, 95).map(Self.rounded)
        highlightMaxSeconds = highlightDurations.max().map(Self.rounded)

        firstAudibleAudioSeconds = audibleSummary?.firstAudibleAudioSeconds
            ?? qwenSummary?.firstAudioSeconds
        maxAudibleGapSeconds = audibleSummary?.maxAudibleGapSeconds
            ?? qwenSummary?.maxInterItemGapSeconds
        medianAudibleGapSeconds = audibleSummary?.medianAudibleGapSeconds
        p95AudibleGapSeconds = audibleSummary?.p95AudibleGapSeconds
            ?? qwenSummary?.p95InterItemGapSeconds
        audibleLongGapOverOneSecondCount = audibleSummary?.audibleLongGapOverOneSecondCount
            ?? qwenSummary?.longGapOverOneSecondCount
            ?? 0
        audibleLongGapOverTwoSecondCount = audibleSummary?.audibleLongGapOverTwoSecondCount
            ?? qwenSummary?.longGapOverTwoSecondCount
            ?? 0
        appSideMaxGapSeconds = qwenSummary?.maxInterItemGapSeconds
        appSideP95GapSeconds = qwenSummary?.p95InterItemGapSeconds
        appSideLongGapOverOneSecondCount = qwenSummary?.longGapOverOneSecondCount ?? 0
        appSideLongGapOverTwoSecondCount = qwenSummary?.longGapOverTwoSecondCount ?? 0
        underrunWaitCount = qwenSummary?.underrunWaitCount ?? 0
        itemCount = events.reversed().compactMap(\.itemCount).first
            ?? qwenSummary?.playbackItemStartCount
            ?? 0
        self.validationWarnings = Self.validationWarnings(
            existing: validationWarnings,
            firstAudioSeconds: firstAudibleAudioSeconds,
            maxGapSeconds: maxAudibleGapSeconds,
            p95GapSeconds: p95AudibleGapSeconds
        )
    }

    private static func validationWarnings(
        existing: [String],
        firstAudioSeconds: Double?,
        maxGapSeconds: Double?,
        p95GapSeconds: Double?
    ) -> [String] {
        var warnings = existing
        if let firstAudioSeconds, firstAudioSeconds > 2.0 {
            warnings.append("first_audio_over_2s")
        }
        if let maxGapSeconds, maxGapSeconds > 0.5 {
            warnings.append("max_gap_over_500ms")
        }
        if let p95GapSeconds, p95GapSeconds > 0.3 {
            warnings.append("p95_gap_over_300ms")
        }
        return Array(NSOrderedSet(array: warnings)) as? [String] ?? warnings
    }

    private static func interval(
        from startKind: ReadQuestionTraceEvent.Kind,
        to endKind: ReadQuestionTraceEvent.Kind,
        in events: [ReadQuestionTraceEvent]
    ) -> Double? {
        guard let start = events.first(where: { $0.kind == startKind })?.elapsedSeconds,
              let end = events.first(where: { $0.kind == endKind })?.elapsedSeconds else {
            return nil
        }
        return rounded(max(0, end - start))
    }

    private static func highlightDurations(in events: [ReadQuestionTraceEvent]) -> [Double] {
        var starts: [String: Double] = [:]
        var durations: [Double] = []
        for event in events {
            let key = eventKey(for: event)
            switch event.kind {
            case .highlightStart:
                if let elapsed = event.elapsedSeconds {
                    starts[key] = elapsed
                }
            case .highlightEnd, .highlightLate:
                guard let start = starts.removeValue(forKey: key),
                      let end = event.elapsedSeconds else {
                    continue
                }
                durations.append(max(0, end - start))
            default:
                continue
            }
        }
        return durations
    }

    private static func eventKey(for event: ReadQuestionTraceEvent) -> String {
        if let itemIndex = event.itemIndex {
            return "item:\(itemIndex)"
        }
        if let segmentID = event.segmentID {
            return "segment:\(segmentID)"
        }
        return "highlight"
    }

    private static func percentile(_ sortedValues: [Double], _ percentile: Double) -> Double? {
        guard !sortedValues.isEmpty else { return nil }
        if percentile <= 0 { return sortedValues[0] }
        if percentile >= 100 { return sortedValues[sortedValues.count - 1] }
        let index = (Double(sortedValues.count - 1) * percentile) / 100
        let lower = Int(index.rounded(.down))
        let upper = Int(index.rounded(.up))
        if lower == upper {
            return sortedValues[lower]
        }
        let fraction = index - Double(lower)
        return sortedValues[lower] * (1 - fraction) + sortedValues[upper] * fraction
    }

    private static func rounded(_ value: Double) -> Double {
        (value * 10_000).rounded() / 10_000
    }
}
