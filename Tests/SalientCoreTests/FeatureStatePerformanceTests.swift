import Combine
import Foundation
import SalientCore
import XCTest

@testable import Salient

@MainActor
final class FeatureStatePerformanceTests: XCTestCase {
    func testHighFrequencyOverlayUpdatesDoNotInvalidateGlobalAppModel() {
        let model = makeFixtureModel()
        var globalChangeCount = 0
        let observation = model.objectWillChange.sink {
            globalChangeCount += 1
        }
        defer { observation.cancel() }

        model.speechPlaybackVisualizationDidStart()
        model.speechPlaybackVisualizationAudioDidStart()
        model.speechPlaybackVisualizationFrameDidChange(
            SpeechPlaybackVisualizationFrame(level: 0.7, barLevels: [0.4, 0.7, 0.5])
        )
        XCTAssertEqual(globalChangeCount, 0)

        let item = SpeechPlaybackItem(
            id: "overlay-isolation",
            segmentID: "stem",
            text: "Alpha beta gamma."
        )
        model.readAlongPresentationWillStart(items: [item], mode: .question)
        let changesAfterOpeningReader = globalChangeCount
        model.readAlongPresentationDidReceiveProgress(
            SpeechPlaybackProgress(
                playbackID: UUID(),
                itemID: item.id,
                segmentID: "stem",
                itemIndex: 0,
                sourcePositionSeconds: 0.2,
                sourceDurationSeconds: 1,
                currentTokenIndex: 1
            )
        )

        XCTAssertEqual(globalChangeCount, changesAfterOpeningReader)
        XCTAssertEqual(model.playbackHUDFrame.level, 0.7)
        XCTAssertEqual(model.rsvpReaderRequestedFrameIndex, 1)
    }

    private func makeFixtureModel() -> AppModel {
        AppModel(
            router: StudyActionRouter(
                browser: FeatureStateBrowserStub(),
                speech: FeatureStateSpeechStub()
            ),
            userDefaults: UserDefaults(suiteName: "FeatureStatePerformanceTests-\(UUID().uuidString)")!,
            launchConfiguration: AppLaunchConfiguration(uiFixture: .empty, disablesModelWarmup: true)
        )
    }
}

@MainActor
private final class FeatureStateBrowserStub: BrowserAutomationService {
    func executeJavaScriptInUWorldTab(_ javaScript: String) async -> BrowserAutomationResult {
        .failure("Not used in feature-state performance tests.")
    }
}

@MainActor
private final class FeatureStateSpeechStub: SpeechBackend {
    func speak(_ text: String) async throws {}

    func speak(
        _ items: [SpeechPlaybackItem],
        willSpeak: @escaping @MainActor (SpeechPlaybackItem) async -> Void
    ) async throws {}

    func stop() async {}
}
