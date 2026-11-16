import Foundation

public enum ModelWarmPolicy: String, CaseIterable, Codable, Equatable, Sendable {
    case adaptive
    case alwaysWarm
    case onDemand

    public var displayName: String {
        switch self {
        case .adaptive: "Adaptive"
        case .alwaysWarm: "Always Warm"
        case .onDemand: "On Demand"
        }
    }
}

public enum ModelResidencyState: String, Codable, Equatable, Sendable {
    case installed
    case selected
    case warming
    case resident
    case idle
    case failed
}

public struct ModelResidencyWorkload: Equatable, Sendable {
    public var isSpeechActive: Bool
    public var isSynthesisActive: Bool
    public var isDownloadActive: Bool

    public init(
        isSpeechActive: Bool = false,
        isSynthesisActive: Bool = false,
        isDownloadActive: Bool = false
    ) {
        self.isSpeechActive = isSpeechActive
        self.isSynthesisActive = isSynthesisActive
        self.isDownloadActive = isDownloadActive
    }

    public var protectsResidentModels: Bool {
        isSpeechActive || isSynthesisActive || isDownloadActive
    }
}

public struct ModelResidencyDecision: Equatable, Sendable {
    public var shouldWarmQwen: Bool
    public var shouldUnloadQwen: Bool

    public init(
        shouldWarmQwen: Bool = false,
        shouldUnloadQwen: Bool = false
    ) {
        self.shouldWarmQwen = shouldWarmQwen
        self.shouldUnloadQwen = shouldUnloadQwen
    }
}

public enum ModelResidencyPolicyEvaluator {
    public static func decision(
        policy: ModelWarmPolicy,
        now: Date,
        lastQwenInteractionAt: Date,
        qwenInstalled: Bool,
        qwenResident: Bool,
        qwenTriggerActive: Bool = false,
        memoryPressure: Bool = false,
        workload: ModelResidencyWorkload = ModelResidencyWorkload(),
        qwenIdleTimeout: TimeInterval = 15 * 60
    ) -> ModelResidencyDecision {
        let protected = workload.protectsResidentModels
        if memoryPressure {
            return ModelResidencyDecision(shouldUnloadQwen: qwenResident && !protected)
        }

        switch policy {
        case .alwaysWarm:
            return ModelResidencyDecision(shouldWarmQwen: qwenInstalled && !qwenResident)
        case .onDemand:
            return ModelResidencyDecision(shouldUnloadQwen: qwenResident && !protected)
        case .adaptive:
            return ModelResidencyDecision(
                shouldWarmQwen: qwenInstalled && qwenTriggerActive && !qwenResident,
                shouldUnloadQwen: qwenResident
                    && !protected
                    && now.timeIntervalSince(lastQwenInteractionAt) >= qwenIdleTimeout
            )
        }
    }
}
