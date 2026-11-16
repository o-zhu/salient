import Foundation

public struct QwenInteractivePerformanceTarget: Equatable, Sendable {
    public var firstPCMP95Seconds: Double?
    public var firstAudioP50Seconds: Double
    public var firstAudioP95Seconds: Double
    public var firstAudioHardLimitSeconds: Double
    public var synthesisRealTimeFactorP95: Double?
    public var incrementalPeakMemoryBytes: Int64?

    public init(
        firstPCMP95Seconds: Double?,
        firstAudioP50Seconds: Double,
        firstAudioP95Seconds: Double,
        firstAudioHardLimitSeconds: Double,
        synthesisRealTimeFactorP95: Double?,
        incrementalPeakMemoryBytes: Int64?
    ) {
        self.firstPCMP95Seconds = firstPCMP95Seconds
        self.firstAudioP50Seconds = firstAudioP50Seconds
        self.firstAudioP95Seconds = firstAudioP95Seconds
        self.firstAudioHardLimitSeconds = firstAudioHardLimitSeconds
        self.synthesisRealTimeFactorP95 = synthesisRealTimeFactorP95
        self.incrementalPeakMemoryBytes = incrementalPeakMemoryBytes
    }
}

public enum QwenPerformanceContract {
    public static let technicalGapP95Seconds = 0.020
    public static let technicalGapHardLimitSeconds = 0.050
    public static let unintendedBoundaryPauseP95Seconds = 0.150
    public static let unintendedBoundaryPauseHardLimitSeconds = 0.250
    public static let playbackCallbackP95Seconds = 0.002
    public static let initialRunwaySeconds = 0.40
    public static let lowWaterRunwaySeconds = 0.25
    public static let targetRunwaySeconds = 0.75
    public static let maximumRunwaySeconds = 1.50

    public static func interactiveTarget(
        lane: QwenModelLane,
        useReferenceVoice: Bool,
        residencyState: QwenRuntimeResidencyState
    ) -> QwenInteractivePerformanceTarget {
        if residencyState == .cacheHit {
            return .init(
                firstPCMP95Seconds: nil,
                firstAudioP50Seconds: 0.075,
                firstAudioP95Seconds: 0.150,
                firstAudioHardLimitSeconds: 0.250,
                synthesisRealTimeFactorP95: nil,
                incrementalPeakMemoryBytes: nil
            )
        }
        if useReferenceVoice {
            return residencyState == .warm
                ? .init(
                    firstPCMP95Seconds: 0.350,
                    firstAudioP50Seconds: 0.400,
                    firstAudioP95Seconds: 0.700,
                    firstAudioHardLimitSeconds: 1.000,
                    synthesisRealTimeFactorP95: 0.38,
                    incrementalPeakMemoryBytes: 3_800_000_000
                )
                : .init(
                    firstPCMP95Seconds: nil,
                    firstAudioP50Seconds: 2.200,
                    firstAudioP95Seconds: 3.000,
                    firstAudioHardLimitSeconds: 3.500,
                    synthesisRealTimeFactorP95: 0.38,
                    incrementalPeakMemoryBytes: 3_800_000_000
                )
        }
        switch (lane, residencyState) {
        case (.small, .warm):
            return .init(
                firstPCMP95Seconds: 0.150,
                firstAudioP50Seconds: 0.200,
                firstAudioP95Seconds: 0.350,
                firstAudioHardLimitSeconds: 0.500,
                synthesisRealTimeFactorP95: 0.30,
                incrementalPeakMemoryBytes: 2_700_000_000
            )
        case (.small, .cold):
            return .init(
                firstPCMP95Seconds: nil,
                firstAudioP50Seconds: 1.500,
                firstAudioP95Seconds: 2.000,
                firstAudioHardLimitSeconds: 2.500,
                synthesisRealTimeFactorP95: 0.30,
                incrementalPeakMemoryBytes: 2_700_000_000
            )
        case (.best, .warm):
            return .init(
                firstPCMP95Seconds: 0.250,
                firstAudioP50Seconds: 0.300,
                firstAudioP95Seconds: 0.500,
                firstAudioHardLimitSeconds: 0.750,
                synthesisRealTimeFactorP95: 0.35,
                incrementalPeakMemoryBytes: 3_600_000_000
            )
        case (.best, .cold):
            return .init(
                firstPCMP95Seconds: nil,
                firstAudioP50Seconds: 1.800,
                firstAudioP95Seconds: 2.500,
                firstAudioHardLimitSeconds: 3.000,
                synthesisRealTimeFactorP95: 0.35,
                incrementalPeakMemoryBytes: 3_600_000_000
            )
        case (_, .cacheHit):
            preconditionFailure("Cache-hit targets are returned before lane-specific targets.")
        }
    }
}
