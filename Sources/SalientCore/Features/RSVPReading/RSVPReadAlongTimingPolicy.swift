import Foundation

public struct RSVPReadAlongTimingAdjustment: Codable, Equatable, Sendable {
    public var observedDurationSeconds: TimeInterval
    public var visualDurationSeconds: TimeInterval
    public var requestedLeadSeconds: TimeInterval
    public var effectiveLeadSeconds: TimeInterval
    public var didClampToMinimumTokenDuration: Bool

    public init(
        observedDurationSeconds: TimeInterval,
        visualDurationSeconds: TimeInterval,
        requestedLeadSeconds: TimeInterval,
        effectiveLeadSeconds: TimeInterval,
        didClampToMinimumTokenDuration: Bool
    ) {
        self.observedDurationSeconds = observedDurationSeconds
        self.visualDurationSeconds = visualDurationSeconds
        self.requestedLeadSeconds = requestedLeadSeconds
        self.effectiveLeadSeconds = effectiveLeadSeconds
        self.didClampToMinimumTokenDuration = didClampToMinimumTokenDuration
    }
}

public struct RSVPReadAlongTimingPolicy: Codable, Equatable, Sendable {
    public static let `default` = RSVPReadAlongTimingPolicy()

    public var leadFraction: Double
    public var minimumLeadSeconds: TimeInterval
    public var maximumLeadSeconds: TimeInterval
    public var minimumTokenDurationSeconds: TimeInterval

    public init(
        leadFraction: Double = 0.04,
        minimumLeadSeconds: TimeInterval = 0.060,
        maximumLeadSeconds: TimeInterval = 0.180,
        minimumTokenDurationSeconds: TimeInterval = 0.055
    ) {
        self.leadFraction = leadFraction
        self.minimumLeadSeconds = minimumLeadSeconds
        self.maximumLeadSeconds = maximumLeadSeconds
        self.minimumTokenDurationSeconds = minimumTokenDurationSeconds
    }

    public func adjustment(
        observedDurationSeconds: TimeInterval,
        tokenCount: Int
    ) -> RSVPReadAlongTimingAdjustment? {
        guard observedDurationSeconds.isFinite,
              observedDurationSeconds > 0,
              tokenCount > 0 else {
            return nil
        }

        let requestedLead = clampedLead(for: observedDurationSeconds)
        let ledDuration = max(0, observedDurationSeconds - requestedLead)
        let minimumDuration = Double(tokenCount) * minimumTokenDurationSeconds
        let visualDuration = max(ledDuration, minimumDuration)
        let effectiveLead = max(0, observedDurationSeconds - visualDuration)
        return RSVPReadAlongTimingAdjustment(
            observedDurationSeconds: observedDurationSeconds,
            visualDurationSeconds: visualDuration,
            requestedLeadSeconds: requestedLead,
            effectiveLeadSeconds: effectiveLead,
            didClampToMinimumTokenDuration: minimumDuration > ledDuration
        )
    }

    private func clampedLead(for observedDurationSeconds: TimeInterval) -> TimeInterval {
        let rawLead = observedDurationSeconds * max(0, leadFraction)
        let lowerBounded = max(minimumLeadSeconds, rawLead)
        return min(maximumLeadSeconds, lowerBounded)
    }
}
