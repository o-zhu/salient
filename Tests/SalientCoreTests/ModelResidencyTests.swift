import Foundation
import XCTest

@testable import SalientCore

final class ModelResidencyTests: XCTestCase {
    func testAdaptiveWarmsOnlyForExplicitNarrationTrigger() {
        let now = Date(timeIntervalSince1970: 10_000)

        let home = decision(now: now)
        let narration = decision(now: now, qwenTriggerActive: true)

        XCTAssertFalse(home.shouldWarmQwen)
        XCTAssertTrue(narration.shouldWarmQwen)
    }

    func testAdaptiveExpiresQwenAtIdleDeadline() {
        let now = Date(timeIntervalSince1970: 10_000)
        let expired = ModelResidencyPolicyEvaluator.decision(
            policy: .adaptive,
            now: now,
            lastQwenInteractionAt: now.addingTimeInterval(-(15 * 60)),
            qwenInstalled: true,
            qwenResident: true
        )
        let recent = ModelResidencyPolicyEvaluator.decision(
            policy: .adaptive,
            now: now,
            lastQwenInteractionAt: now.addingTimeInterval(-(14 * 60)),
            qwenInstalled: true,
            qwenResident: true
        )

        XCTAssertTrue(expired.shouldUnloadQwen)
        XCTAssertFalse(recent.shouldUnloadQwen)
    }

    func testActiveWorkProtectsResidentsFromIdleAndMemoryPressure() {
        let now = Date(timeIntervalSince1970: 10_000)
        let workload = ModelResidencyWorkload(isSpeechActive: true)
        let decision = ModelResidencyPolicyEvaluator.decision(
            policy: .adaptive,
            now: now,
            lastQwenInteractionAt: .distantPast,
            qwenInstalled: true,
            qwenResident: true,
            memoryPressure: true,
            workload: workload
        )

        XCTAssertFalse(decision.shouldUnloadQwen)
    }

    func testMemoryPressureReleasesIdleResidentsRegardlessOfWarmPolicy() {
        let now = Date(timeIntervalSince1970: 10_000)
        let decision = ModelResidencyPolicyEvaluator.decision(
            policy: .alwaysWarm,
            now: now,
            lastQwenInteractionAt: now,
            qwenInstalled: true,
            qwenResident: true,
            memoryPressure: true
        )

        XCTAssertTrue(decision.shouldUnloadQwen)
        XCTAssertFalse(decision.shouldWarmQwen)
    }

    private func decision(
        now: Date,
        qwenTriggerActive: Bool = false
    ) -> ModelResidencyDecision {
        ModelResidencyPolicyEvaluator.decision(
            policy: .adaptive,
            now: now,
            lastQwenInteractionAt: now,
            qwenInstalled: true,
            qwenResident: false,
            qwenTriggerActive: qwenTriggerActive
        )
    }
}
