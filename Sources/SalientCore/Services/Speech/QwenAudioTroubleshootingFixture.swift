import Foundation

public enum QwenAudioTroubleshootingFixture {
    public static func syntheticQuestionPlaybackItems(
        options: ReadPlanOptions = .default
    ) -> [SpeechPlaybackItem] {
        let segments = [
            CapturedSegment(
                id: "synthetic-stem-1",
                text: "A learner reviews a synthetic passage with several neutral details.",
                role: .stem,
                region: .left,
                rect: .zero
            ),
            CapturedSegment(
                id: "synthetic-stem-2",
                text: "The passage is generic so audio troubleshooting artifacts remain safe.",
                role: .stem,
                region: .left,
                rect: .zero
            ),
            CapturedSegment(
                id: "synthetic-task",
                text: "Which of the following findings best explains this synthetic pattern?",
                role: .questionTask,
                region: .left,
                rect: .zero
            )
        ]
        let plan = ReadPlanBuilder(options: options).questionPlan(from: segments)
        return TTSNormalizer.normalizedPlaybackItems(from: plan.items)
    }
}
