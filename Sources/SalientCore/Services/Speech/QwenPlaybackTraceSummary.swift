import Foundation

public struct QwenPlaybackGap: Codable, Equatable, Sendable {
    public var previousItemIndex: Int
    public var previousSegmentID: String
    public var nextItemIndex: Int
    public var nextSegmentID: String
    public var gapSeconds: Double

    public init(
        previousItemIndex: Int,
        previousSegmentID: String,
        nextItemIndex: Int,
        nextSegmentID: String,
        gapSeconds: Double
    ) {
        self.previousItemIndex = previousItemIndex
        self.previousSegmentID = previousSegmentID
        self.nextItemIndex = nextItemIndex
        self.nextSegmentID = nextSegmentID
        self.gapSeconds = gapSeconds
    }
}

public struct QwenPlaybackRollingSummary: Codable, Equatable, Sendable {
    public var windowStartItemIndex: Int?
    public var windowEndItemIndex: Int?
    public var segmentIDs: [String]
    public var maxInterItemGapSeconds: Double?
    public var p95InterItemGapSeconds: Double?
    public var longGapOverOneSecondCount: Int
    public var longGapOverTwoSecondCount: Int
    public var playbackItemStartCount: Int
    public var underrunWaitCount: Int
    public var initialBufferWaitCount: Int
    public var adaptiveBufferWaitCount: Int
    public var cacheHitPreparedCount: Int
    public var cacheMissPreparedCount: Int
    public var cachePolicyCounts: [String: Int]
    public var lane: String?
    public var rateMultiplier: Double?
    public var speakerClass: String?
    public var policyState: QwenPlaybackPolicyState?
    public var warnings: [String]

    public init(
        windowStartItemIndex: Int?,
        windowEndItemIndex: Int?,
        segmentIDs: [String],
        maxInterItemGapSeconds: Double?,
        p95InterItemGapSeconds: Double?,
        longGapOverOneSecondCount: Int,
        longGapOverTwoSecondCount: Int,
        playbackItemStartCount: Int,
        underrunWaitCount: Int,
        initialBufferWaitCount: Int,
        adaptiveBufferWaitCount: Int,
        cacheHitPreparedCount: Int,
        cacheMissPreparedCount: Int,
        cachePolicyCounts: [String: Int],
        lane: String?,
        rateMultiplier: Double?,
        speakerClass: String?,
        policyState: QwenPlaybackPolicyState?,
        warnings: [String]
    ) {
        self.windowStartItemIndex = windowStartItemIndex
        self.windowEndItemIndex = windowEndItemIndex
        self.segmentIDs = segmentIDs
        self.maxInterItemGapSeconds = maxInterItemGapSeconds
        self.p95InterItemGapSeconds = p95InterItemGapSeconds
        self.longGapOverOneSecondCount = longGapOverOneSecondCount
        self.longGapOverTwoSecondCount = longGapOverTwoSecondCount
        self.playbackItemStartCount = playbackItemStartCount
        self.underrunWaitCount = underrunWaitCount
        self.initialBufferWaitCount = initialBufferWaitCount
        self.adaptiveBufferWaitCount = adaptiveBufferWaitCount
        self.cacheHitPreparedCount = cacheHitPreparedCount
        self.cacheMissPreparedCount = cacheMissPreparedCount
        self.cachePolicyCounts = cachePolicyCounts
        self.lane = lane
        self.rateMultiplier = rateMultiplier
        self.speakerClass = speakerClass
        self.policyState = policyState
        self.warnings = warnings
    }
}

public struct QwenPlaybackTraceSummary: Codable, Equatable, Sendable {
    public var firstPCMSeconds: Double?
    public var firstAudioSeconds: Double?
    public var firstRenderSeconds: Double?
    public var maxInterItemGapSeconds: Double?
    public var p95InterItemGapSeconds: Double?
    public var gaps: [QwenPlaybackGap]
    public var longGapOverOneSecondCount: Int
    public var longGapOverTwoSecondCount: Int
    public var rollingSummaries: [QwenPlaybackRollingSummary]
    public var playbackItemStartCount: Int
    public var underrunWaitCount: Int
    public var technicalUnderrunCount: Int
    public var rebufferCount: Int
    public var initialBufferWaitCount: Int
    public var adaptiveBufferWaitCount: Int
    public var cacheHitPreparedCount: Int
    public var cacheMissPreparedCount: Int
    public var inferenceBackendCounts: [String: Int]
    public var residencyStateCounts: [String: Int]
    public var fallbackReasonCounts: [String: Int]
    public var maxPeakMemoryBytes: Int64?
    public var p95RealTimeFactor: Double?

    public init(events: [QwenPlaybackTraceEvent], rateMultiplier: Double) {
        let starts = events
            .filter { $0.kind == .playbackItemStart }
            .compactMap(PlaybackStart.init(event:))
            .sorted { lhs, rhs in
                if lhs.elapsedSeconds == rhs.elapsedSeconds {
                    return lhs.itemIndex < rhs.itemIndex
                }
                return lhs.elapsedSeconds < rhs.elapsedSeconds
            }
        let playbackRate = min(max(rateMultiplier, 0.5), 2.4)
        let endsByItemIndex = Self.playbackEndsByItemIndex(events)

        firstPCMSeconds = events
            .filter { $0.kind == .firstPCM }
            .compactMap(\.elapsedSeconds)
            .min()
            .map(Self.rounded)
        firstAudioSeconds = starts.first.map { Self.rounded($0.elapsedSeconds) }
        firstRenderSeconds = events
            .filter { $0.kind == .playbackRenderStart }
            .compactMap(\.elapsedSeconds)
            .min()
            .map(Self.rounded)
        gaps = zip(starts, starts.dropFirst()).map { previous, next in
            let previousEnd = Self.playbackEndElapsed(
                for: previous,
                before: next.elapsedSeconds,
                endsByItemIndex: endsByItemIndex
            ) ?? (previous.elapsedSeconds + previous.durationSeconds / playbackRate)
            return QwenPlaybackGap(
                previousItemIndex: previous.itemIndex,
                previousSegmentID: previous.segmentID,
                nextItemIndex: next.itemIndex,
                nextSegmentID: next.segmentID,
                gapSeconds: Self.rounded(max(0, next.elapsedSeconds - previousEnd))
            )
        }
        maxInterItemGapSeconds = gaps.map(\.gapSeconds).max()
        p95InterItemGapSeconds = Self.percentile(gaps.map(\.gapSeconds).sorted(), 95).map(Self.rounded)
        longGapOverOneSecondCount = gaps.filter { $0.gapSeconds > 1.0 }.count
        longGapOverTwoSecondCount = gaps.filter { $0.gapSeconds > 2.0 }.count
        playbackItemStartCount = starts.count
        underrunWaitCount = events.filter { $0.kind == .underrunWait }.count
        technicalUnderrunCount = events.filter { $0.kind == .playbackUnderrun }.count
        rebufferCount = events.filter { $0.kind == .playbackRebuffer }.count
        initialBufferWaitCount = events.filter { $0.kind == .initialBufferWait }.count
        adaptiveBufferWaitCount = events.filter { $0.kind == .adaptiveBufferWait }.count
        cacheHitPreparedCount = events.filter {
            ($0.kind == .prepared || $0.kind == .firstPrepared) && $0.cacheHit == true
        }.count
        cacheMissPreparedCount = events.filter {
            ($0.kind == .prepared || $0.kind == .firstPrepared) && $0.cacheHit == false
        }.count
        inferenceBackendCounts = Self.counts(events.compactMap(\.inferenceBackend).map(\.rawValue))
        residencyStateCounts = Self.counts(events.compactMap(\.residencyState).map(\.rawValue))
        fallbackReasonCounts = Self.counts(events.compactMap(\.fallbackReason).map(\.rawValue))
        maxPeakMemoryBytes = events.compactMap(\.peakMemoryBytes).max()
        p95RealTimeFactor = Self.percentile(events.compactMap(\.realTimeFactor).sorted(), 95).map(Self.rounded)
        rollingSummaries = Self.makeRollingSummaries(
            events: events,
            starts: starts,
            gaps: gaps
        )
    }

    private static func rounded(_ value: Double) -> Double {
        (value * 10_000).rounded() / 10_000
    }

    private static func counts(_ values: [String]) -> [String: Int] {
        values.reduce(into: [:]) { counts, value in
            counts[value, default: 0] += 1
        }
    }

    private static func playbackEndsByItemIndex(_ events: [QwenPlaybackTraceEvent]) -> [Int: [Double]] {
        var ends: [Int: [Double]] = [:]
        for event in events where event.kind == .playbackItemEnd {
            guard let itemIndex = event.itemIndex,
                  let elapsedSeconds = event.elapsedSeconds else {
                continue
            }
            ends[itemIndex, default: []].append(elapsedSeconds)
        }
        for itemIndex in ends.keys {
            ends[itemIndex]?.sort()
        }
        return ends
    }

    private static func playbackEndElapsed(
        for start: PlaybackStart,
        before nextStartElapsed: Double,
        endsByItemIndex: [Int: [Double]]
    ) -> Double? {
        endsByItemIndex[start.itemIndex]?.first {
            $0 >= start.elapsedSeconds && $0 <= nextStartElapsed
        }
    }

    private static func makeRollingSummaries(
        events: [QwenPlaybackTraceEvent],
        starts: [PlaybackStart],
        gaps: [QwenPlaybackGap]
    ) -> [QwenPlaybackRollingSummary] {
        guard !starts.isEmpty else { return [] }
        let windowSize = 8
        let stride = 4
        var summaries: [QwenPlaybackRollingSummary] = []
        var startOffset = 0
        while startOffset < starts.count {
            let endOffset = min(startOffset + windowSize, starts.count)
            let windowStarts = Array(starts[startOffset..<endOffset])
            let windowIndices = Set(windowStarts.map(\.itemIndex))
            let windowGaps = gaps.filter {
                windowIndices.contains($0.previousItemIndex) && windowIndices.contains($0.nextItemIndex)
            }
            let sortedGapSeconds = windowGaps.map(\.gapSeconds).sorted()
            let windowEvents = events.filter { event in
                guard let itemIndex = event.itemIndex else { return true }
                return windowIndices.contains(itemIndex)
            }
            summaries.append(QwenPlaybackRollingSummary(
                windowStartItemIndex: windowStarts.first?.itemIndex,
                windowEndItemIndex: windowStarts.last?.itemIndex,
                segmentIDs: windowStarts.map(\.segmentID),
                maxInterItemGapSeconds: sortedGapSeconds.max(),
                p95InterItemGapSeconds: percentile(sortedGapSeconds, 95).map(rounded),
                longGapOverOneSecondCount: sortedGapSeconds.filter { $0 > 1.0 }.count,
                longGapOverTwoSecondCount: sortedGapSeconds.filter { $0 > 2.0 }.count,
                playbackItemStartCount: windowStarts.count,
                underrunWaitCount: windowEvents.filter { $0.kind == .underrunWait }.count,
                initialBufferWaitCount: windowEvents.filter { $0.kind == .initialBufferWait }.count,
                adaptiveBufferWaitCount: windowEvents.filter { $0.kind == .adaptiveBufferWait }.count,
                cacheHitPreparedCount: windowEvents.filter {
                    ($0.kind == .prepared || $0.kind == .firstPrepared) && $0.cacheHit == true
                }.count,
                cacheMissPreparedCount: windowEvents.filter {
                    ($0.kind == .prepared || $0.kind == .firstPrepared) && $0.cacheHit == false
                }.count,
                cachePolicyCounts: cachePolicyCounts(in: windowEvents),
                lane: windowEvents.reversed().compactMap(\.lane).first,
                rateMultiplier: windowEvents.reversed().compactMap(\.rateMultiplier).first,
                speakerClass: windowEvents.reversed().compactMap(\.speakerClass).first,
                policyState: windowEvents.reversed().compactMap(\.policyState).first,
                warnings: windowEvents.compactMap(\.warning)
            ))
            guard endOffset < starts.count else { break }
            startOffset += stride
        }
        return summaries
    }

    private static func cachePolicyCounts(in events: [QwenPlaybackTraceEvent]) -> [String: Int] {
        var counts: [String: Int] = [:]
        for policy in events.compactMap(\.cachePolicy) {
            counts[policy.rawValue, default: 0] += 1
        }
        return counts
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
}

private struct PlaybackStart {
    var itemIndex: Int
    var segmentID: String
    var elapsedSeconds: Double
    var durationSeconds: Double

    init?(event: QwenPlaybackTraceEvent) {
        guard let itemIndex = event.itemIndex,
              let elapsedSeconds = event.elapsedSeconds else {
            return nil
        }
        self.itemIndex = itemIndex
        self.segmentID = event.segmentID ?? "item-\(itemIndex)"
        self.elapsedSeconds = elapsedSeconds
        self.durationSeconds = max(0, event.durationSeconds ?? 0)
    }
}
