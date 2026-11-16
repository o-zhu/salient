import Foundation
import AppKit
import XCTest
import SalientCore
import Carbon.HIToolbox
@testable import Salient

@MainActor
final class ReaderTests: XCTestCase {
    func testBrowserPreferencePersistsAndOldPermissionResultCannotReplaceNewBrowser() async {
        let started = expectation(description: "Safari status requested")
        let (stream, continuation) = AsyncStream<AppleEventPermissionStatus>.makeStream()
        let defaults = UserDefaults(suiteName: "ReaderTests-\(UUID())")!
        let model = AppModel(
            router: StudyActionRouter(browser: ReaderBrowserSpy(), speech: ReaderSpeechSpy()),
            userDefaults: defaults, disablesAutomaticModelWarmup: true,
            browserPermissionStatusProvider: { browser in
                if browser == .chrome { return .denied }
                started.fulfill()
                for await status in stream { return status }
                return .authorized
            }
        )
        await fulfillment(of: [started], timeout: 2)
        model.setStudyBrowser(.chrome)
        for _ in 0..<100 where model.browserAutomationStatus != .denied {
            try? await Task.sleep(for: .milliseconds(5))
        }
        continuation.yield(.authorized)
        continuation.finish()
        await Task.yield()
        XCTAssertEqual(model.selectedBrowser, .chrome)
        XCTAssertEqual(model.browserAutomationStatus, .denied)
        XCTAssertEqual(defaults.string(forKey: "study.browser"), "chrome")
        let reopened = AppModel(
            router: StudyActionRouter(browser: ReaderBrowserSpy(), speech: ReaderSpeechSpy()),
            userDefaults: defaults, launchConfiguration: .init(uiFixture: .empty, disablesModelWarmup: true)
        )
        XCTAssertEqual(reopened.selectedBrowser, .chrome)
        XCTAssertTrue(reopened.permissionReport.items[0].title.contains("Chrome"))
    }

    func testReopenRestoresMainWindowWithOrWithoutOtherVisibleWindows() {
        let previousHandler = AppDelegate.reopenMainWindow
        defer { AppDelegate.reopenMainWindow = previousHandler }
        var restored = 0
        AppDelegate.reopenMainWindow = { restored += 1 }
        let delegate = AppDelegate()

        XCTAssertFalse(delegate.applicationShouldHandleReopen(NSApplication.shared, hasVisibleWindows: false))
        XCTAssertFalse(delegate.applicationShouldHandleReopen(NSApplication.shared, hasVisibleWindows: true))
        XCTAssertEqual(restored, 2)
    }

    func testPermissionCheckCanWaitWithoutBlockingLaunchOrReader() async {
        let started = expectation(description: "Permission query started")
        let (stream, continuation) = AsyncStream<AppleEventPermissionStatus>.makeStream()
        let model = AppModel(
            router: StudyActionRouter(browser: ReaderBrowserSpy(), speech: ReaderSpeechSpy()),
            userDefaults: UserDefaults(suiteName: "ReaderTests-\(UUID())")!,
            disablesAutomaticModelWarmup: true,
            browserPermissionStatusProvider: { _ in
                started.fulfill()
                for await status in stream { return status }
                return .notDetermined
            }
        )
        await fulfillment(of: [started], timeout: 2)
        model.readingText = "Reading remains available."
        model.openEnteredTextInRSVP()
        XCTAssertTrue(model.isRSVPReaderVisible)
        // Repeated refresh must not queue duplicate queries while one is pending.
        model.refreshReadiness()
        continuation.yield(.authorized)
        continuation.finish()
        for _ in 0..<100 where model.browserAutomationStatus != .authorized {
            try? await Task.sleep(for: .milliseconds(5))
        }
        XCTAssertEqual(model.browserAutomationStatus, .authorized)
    }

    func testGlobalShortcutRejectsDuplicateBinding() throws {
        let first = GlobalHotKey(id: 901, keyCode: UInt32(kVK_F19), modifiers: HotKeyDefinition.commandOption | HotKeyDefinition.control | HotKeyDefinition.shift) {}
        let second = GlobalHotKey(id: 902, keyCode: UInt32(kVK_F19), modifiers: HotKeyDefinition.commandOption | HotKeyDefinition.control | HotKeyDefinition.shift) {}
        defer { first.unregister(); second.unregister() }
        try first.register()
        XCTAssertThrowsError(try second.register())
    }
    func testReaderStartsWithOfflineVoiceWithoutBrowserOrPlaybackWork() {
        let browser = ReaderBrowserSpy()
        let speech = ReaderSpeechSpy()
        let model = AppModel(
            router: StudyActionRouter(browser: browser, speech: speech),
            userDefaults: UserDefaults(suiteName: "ReaderTests-\(UUID())")!,
            disablesAutomaticModelWarmup: true
        )
        XCTAssertEqual(model.selectedSection, .reading)
        XCTAssertEqual(model.speechSettings.engineID, .pocket)
        XCTAssertEqual(model.speechSettings.rateMultiplier, 1)
        XCTAssertFalse(model.speechSettings.qwenUseReferenceVoice)
        XCTAssertEqual(browser.calls, 0)
        XCTAssertTrue(speech.texts.isEmpty)
    }

    func testPublicAppOffersOnlyReaderSectionsAndShortcuts() {
        XCTAssertEqual(AppModel.displayName, "Salient")
        XCTAssertEqual(AppSection.allCases, [.reading, .keyboardShortcuts, .speech, .permissions])
        XCTAssertEqual(StudyShortcutAction.allCases, [.readQuestion, .readExplanation, .submit, .stopPlayback, .nextQuestionAndRead])
    }

    func testSavedVoiceSettingsSurviveTheNewFirstLaunchDefault() throws {
        let defaults = UserDefaults(suiteName: "ReaderTests-\(UUID())")!
        var saved = SpeechSettings.firstLaunch
        saved.rateMultiplier = 1.7
        defaults.set(try JSONEncoder().encode(saved), forKey: "speech.settings")
        let model = AppModel(
            router: StudyActionRouter(browser: ReaderBrowserSpy(), speech: ReaderSpeechSpy()),
            userDefaults: defaults, disablesAutomaticModelWarmup: true
        )
        XCTAssertEqual(model.speechSettings.rateMultiplier, 1.7)
    }

    func testPlainTextAndStopNeverAccessSafariAndPreserveContent() async {
        let browser = ReaderBrowserSpy()
        let speech = ReaderSpeechSpy()
        let sink = ReaderReadAlongSpy()
        let router = StudyActionRouter(browser: browser, speech: speech)
        router.readAlongPresentationSink = sink
        let result = await router.run(.readText("One (including this) is 3.5.\n\nSecond paragraph."))
        XCTAssertEqual(result.status, .succeeded)
        XCTAssertEqual(speech.texts, ["One (including this) is 3.5.", "Second paragraph."])
        XCTAssertEqual(sink.starts, 1)
        XCTAssertEqual(sink.items, 2)
        XCTAssertEqual(sink.ends, 1)
        _ = await router.run(.stopSpeech)
        XCTAssertEqual(browser.calls, 0)
        XCTAssertEqual(speech.stops, 1)
    }

    func testEmptyInputDoesNotStartSpeech() async {
        let speech = ReaderSpeechSpy()
        let router = StudyActionRouter(browser: ReaderBrowserSpy(), speech: speech)
        let result = await router.run(.readText(" \n\t"))
        XCTAssertEqual(result.status, .failed)
        XCTAssertTrue(speech.texts.isEmpty)
    }

    func testSilentReaderWorksWithoutLibraryOrBrowser() {
        let browser = ReaderBrowserSpy()
        let model = AppModel(
            router: StudyActionRouter(browser: browser, speech: ReaderSpeechSpy()),
            userDefaults: UserDefaults(suiteName: "ReaderTests-\(UUID())")!,
            disablesAutomaticModelWarmup: true
        )
        model.readingText = "A steady reading rhythm."
        model.openEnteredTextInRSVP()
        XCTAssertEqual(model.rsvpReadingPlan?.frames.map(\.displayText), ["A", "steady", "reading", "rhythm."])
        XCTAssertTrue(model.isRSVPReaderVisible)
        XCTAssertFalse(model.isRSVPReaderFollowingNarration)
        XCTAssertEqual(browser.calls, 0)
    }

    func testSyntheticReaderFixturePopulatesOnlyReadingText() {
        let model = AppModel(
            router: StudyActionRouter(browser: ReaderBrowserSpy(), speech: ReaderSpeechSpy()),
            userDefaults: UserDefaults(suiteName: "ReaderTests-\(UUID())")!,
            launchConfiguration: .init(uiFixture: .populated, disablesModelWarmup: true)
        )
        XCTAssertFalse(model.readingText.isEmpty)
        XCTAssertEqual(model.selectedSection, .reading)
    }
}

@MainActor private final class ReaderBrowserSpy: BrowserAutomationService {
    var calls = 0
    func executeJavaScriptInUWorldTab(_ javaScript: String) async -> BrowserAutomationResult {
        calls += 1
        return .failure("Unexpected browser access")
    }
}

@MainActor private final class ReaderSpeechSpy: SpeechBackend {
    var texts: [String] = []
    var stops = 0
    func speak(_ text: String) async throws { texts.append(text) }
    func stop() async { stops += 1 }
}

@MainActor private final class ReaderReadAlongSpy: ReadAlongPresentationSink {
    var starts = 0
    var items = 0
    var ends = 0
    func readAlongPresentationWillStart(items: [SpeechPlaybackItem], mode: CaptureMode) { starts += 1 }
    func readAlongPresentationWillSpeak(item: SpeechPlaybackItem, itemIndex: Int) { items += 1 }
    func readAlongPresentationDidEnd() { ends += 1 }
}
