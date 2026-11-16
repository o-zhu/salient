import AVFoundation
import AppKit
import SalientCore
import SwiftUI
import XCTest

@testable import Salient

@MainActor
final class AppNavigationTests: XCTestCase {
    func testLaunchConfigurationParsesSyntheticFixtureAndWarmupOverride() {
        let configuration = AppLaunchConfiguration.parse(arguments: [
            "Salient",
            "--ui-fixture", "processing",
            "--disable-model-warmup",
            "--ui-appearance", "light",
            "--ui-increased-contrast",
        ])

        XCTAssertEqual(configuration.uiFixture, .processing)
        XCTAssertTrue(configuration.disablesModelWarmup)
        XCTAssertEqual(configuration.uiAppearance, .light)
        XCTAssertTrue(configuration.usesIncreasedContrast)
    }

    func testAdaptiveModelWarmPolicyDefaultsAndPersists() {
        let defaults = UserDefaults(suiteName: "AppNavigationTests-\(UUID().uuidString)")!
        let router = StudyActionRouter(browser: AppNavigationBrowserStub(), speech: AppNavigationSpeechStub())
        let model = AppModel(
            router: router,
            userDefaults: defaults,
            disablesAutomaticModelWarmup: true
        )
        XCTAssertEqual(model.modelWarmPolicy, .adaptive)

        model.setModelWarmPolicy(.onDemand)
        let reloaded = AppModel(
            router: router,
            userDefaults: defaults,
            disablesAutomaticModelWarmup: true
        )
        XCTAssertEqual(reloaded.modelWarmPolicy, .onDemand)
    }

    func testReaderIsTheDefaultFirstSection() {
        let router = StudyActionRouter(
            browser: AppNavigationBrowserStub(),
            speech: AppNavigationSpeechStub()
        )
        let defaults = UserDefaults(suiteName: "AppNavigationTests-\(UUID().uuidString)")!

        let model = AppModel(router: router, userDefaults: defaults)

        XCTAssertEqual(AppSection.allCases.first, .reading)
        XCTAssertEqual(model.selectedSection, .reading)
        XCTAssertEqual(model.state.navigation.selectedSection, .reading)
        XCTAssertEqual(AppModel.displayName, "Salient")
    }

    func testSidebarListsOnlyReaderDestinations() {
        XCTAssertEqual(AppSection.allCases, [.reading, .keyboardShortcuts, .speech, .permissions])
        XCTAssertEqual(AppSection.workSections, [.reading])
        XCTAssertEqual(AppSection.setupSections, [.keyboardShortcuts, .speech, .permissions])
    }

    func testSidebarUsesCompactSetupLabelsWithoutChangingDestinationTitles() {
        XCTAssertEqual(AppSection.keyboardShortcuts.sidebarTitle, "Shortcuts")
        XCTAssertEqual(AppSection.speech.sidebarTitle, "Narration")
        XCTAssertEqual(AppSection.speech.title, "Narration Settings")
        XCTAssertEqual(AppSection.keyboardShortcuts.title, "Keyboard Shortcuts")
    }

    func testPageScrollingLeavesScrollerVisibilityToSystemPreferences() throws {
        let sourceURL = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .appendingPathComponent("Sources/Salient/App/SalientTheme.swift")
        let source = try String(contentsOf: sourceURL, encoding: .utf8)

        XCTAssertFalse(source.contains("hasVerticalScroller"))
        XCTAssertFalse(source.contains("hasHorizontalScroller"))
        XCTAssertFalse(source.contains("scrollIndicators(.hidden)"))
    }

    func testWindowTitleAccessorDoesNotToggleMovableByWindowBackground() throws {
        let sourceURL = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .appendingPathComponent("Sources/Salient/App/WindowTitleVisibilityAccessor.swift")
        let source = try String(contentsOf: sourceURL, encoding: .utf8)

        XCTAssertFalse(source.contains("isMovableByWindowBackground"))
    }

    func testNarrationSettingsCopyReplacesReadingSettingsLabels() {
        XCTAssertEqual(AppSection.speech.title, "Narration Settings")
        XCTAssertEqual(AppSection.speech.sidebarTitle, "Narration")
    }

    func testNarrationSettingsVoiceCloningCopyMatchesCurrentLayout() {
        XCTAssertEqual(SpeechSettingsCopy.voiceCloningSectionTitle, "Voice Cloning")
        XCTAssertEqual(SpeechSettingsCopy.useMyVoiceTitle, "Use My Voice")
        XCTAssertFalse(SpeechSettingsCopy.voiceCloningSectionSubtitle.contains("Qwen setup"))
        XCTAssertFalse(SpeechSettingsCopy.voiceCloningSectionSubtitle.contains("faster starts"))
    }

    func testNarrationReadPlanPreferencesDefaultAndPersistThroughAppModel() {
        let suiteName = "AppNavigationTests-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        let router = StudyActionRouter(
            browser: AppNavigationBrowserStub(),
            speech: AppNavigationSpeechStub()
        )
        let model = AppModel(router: router, userDefaults: defaults)

        XCTAssertTrue(model.speechSettings.readsLastSentenceFirst)
        XCTAssertFalse(model.speechSettings.skipsParentheticalContent)
        XCTAssertTrue(model.speechSettings.usesQuestionPromptAudioLibrary)

        model.setReadsLastSentenceFirst(false)
        model.setSkipsParentheticalContent(true)
        model.setUsesQuestionPromptAudioLibrary(false)

        let reloaded = AppModel(router: router, userDefaults: defaults)
        XCTAssertFalse(reloaded.speechSettings.readsLastSentenceFirst)
        XCTAssertTrue(reloaded.speechSettings.skipsParentheticalContent)
        XCTAssertFalse(reloaded.speechSettings.usesQuestionPromptAudioLibrary)
    }

    func testAppModelPersistsMigratedQwenVoiceDefaultsOnStartup() throws {
        let suiteName = "AppNavigationTests-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        let legacySettings = """
            {
              "engineID": "qwenSmall",
              "rateMultiplier": 1.7,
              "volume": 1.0,
              "pitchMultiplier": 1.0,
              "qwenSpeaker": "Aiden",
              "qwenUseReferenceVoice": true,
              "qwenReferenceVoiceID": "studentClone",
              "qwenStudentReferenceVoice": {
                "displayName": "My Voice",
                "audioPath": "/tmp/student-clone.wav",
                "transcript": "Synthetic transcript.",
                "durationSeconds": 12,
                "createdAt": 100
              }
            }
            """.data(using: .utf8)!
        defaults.set(legacySettings, forKey: "speech.settings")
        let router = StudyActionRouter(
            browser: AppNavigationBrowserStub(),
            speech: AppNavigationSpeechStub()
        )

        let model = AppModel(router: router, userDefaults: defaults)

        XCTAssertTrue(model.speechSettings.qwenUseReferenceVoice)
        XCTAssertEqual(model.speechSettings.qwenReferenceVoiceID, .crispStudyVoice)
        XCTAssertNotNil(model.speechSettings.qwenStudentReferenceVoice)

        let savedData = try XCTUnwrap(defaults.data(forKey: "speech.settings"))
        let savedJSON = try XCTUnwrap(String(data: savedData, encoding: .utf8))
        XCTAssertTrue(savedJSON.contains(#""qwenVoiceDefaultRevision":\#(SpeechSettings.currentQwenVoiceDefaultRevision)"#))
        XCTAssertTrue(savedJSON.contains(#""qwenReferenceVoiceID":"crispStudyVoice""#))
        XCTAssertFalse(savedJSON.contains(#""qwenReferenceVoiceID":"studentClone""#))
    }

    func testSharedSpacingScaleKeepsCardsAndWorkspacePanesConsistent() {
        XCTAssertEqual(SalientTheme.cardSpacing, SalientTheme.workspacePaneSpacing)
        XCTAssertGreaterThan(SalientTheme.cardSpacing, SalientTheme.rowSpacing)
        XCTAssertGreaterThan(SalientTheme.sectionSpacing, SalientTheme.cardSpacing)
    }

    func testPlaybackHUDAppearancePersistsThroughAppModel() {
        let suiteName = "AppNavigationTests-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        let router = StudyActionRouter(
            browser: AppNavigationBrowserStub(),
            speech: AppNavigationSpeechStub()
        )
        let model = AppModel(router: router, userDefaults: defaults)

        model.setPlaybackHUDAppearance(.light)

        let reloaded = AppModel(router: router, userDefaults: defaults)
        XCTAssertEqual(reloaded.speechSettings.playbackHUDAppearance, .light)
    }

    func testQwenDeEsserStrengthPersistsThroughAppModel() {
        let suiteName = "AppNavigationTests-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        let router = StudyActionRouter(
            browser: AppNavigationBrowserStub(),
            speech: AppNavigationSpeechStub()
        )
        let model = AppModel(router: router, userDefaults: defaults)

        model.setQwenDeEsserStrengthDecibels(8.5)

        let reloaded = AppModel(router: router, userDefaults: defaults)
        XCTAssertEqual(reloaded.speechSettings.qwenDeEsserStrengthDecibels, 8.5)
    }

    func testRSVPReadingSettingsPersistThroughAppModel() {
        let suiteName = "AppNavigationTests-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        let router = StudyActionRouter(
            browser: AppNavigationBrowserStub(),
            speech: AppNavigationSpeechStub()
        )
        let model = AppModel(router: router, userDefaults: defaults)

        model.setRSVPWordsPerMinute(520)
        model.setShowRSVPDuringNarration(false)

        let reloaded = AppModel(router: router, userDefaults: defaults)
        XCTAssertEqual(reloaded.rsvpReadingSettings.wordsPerMinute, 520)
        XCTAssertTrue(reloaded.rsvpReadingSettings.showsComprehensionWarning)
        XCTAssertFalse(reloaded.rsvpReadingSettings.showsDuringNarration)
        XCTAssertEqual(reloaded.speechSettings, model.speechSettings)
    }

    func testRSVPPanelConfigurationFloatsWithoutActivatingAndReordersOnSync() {
        XCTAssertTrue(RSVPReaderPanelConfiguration.styleMask.contains(.nonactivatingPanel))
        XCTAssertTrue(RSVPReaderPanelConfiguration.collectionBehavior.contains(.canJoinAllSpaces))
        XCTAssertTrue(RSVPReaderPanelConfiguration.collectionBehavior.contains(.transient))
        XCTAssertTrue(RSVPReaderPanelConfiguration.ordersFrontWhenPanelAlreadyExists)
    }

    func testRSVPNarrationSyncShortensOnlyInitialFrameDelay() {
        let settings = RSVPReadingSettings(wordsPerMinute: 260)
        let frame = RSVPReadingFrame(
            displayText: "Alpha",
            orpIndex: 1,
            sectionLabel: "Narration",
            durationSeconds: 0.220,
            sourceTokenIndex: 0,
            playbackItemID: "spoken",
            isDurationFixed: true
        )

        let normalDelay = RSVPReaderPlaybackTiming.displayDelay(
            for: frame,
            planWordsPerMinute: 260,
            settings: settings
        )
        let syncedInitialDelay = RSVPReaderPlaybackTiming.displayDelay(
            for: frame,
            planWordsPerMinute: 260,
            settings: settings,
            initialAdvanceLeadSeconds: RSVPReaderPlaybackTiming.readAlongInitialAdvanceLeadSeconds
        )
        let shortFrame = RSVPReadingFrame(
            displayText: "A",
            orpIndex: 0,
            sectionLabel: "Narration",
            durationSeconds: 0.070,
            sourceTokenIndex: 1,
            playbackItemID: "spoken",
            isDurationFixed: true
        )

        XCTAssertEqual(normalDelay, 0.220, accuracy: 0.0001)
        XCTAssertEqual(syncedInitialDelay, 0.145, accuracy: 0.0001)
        XCTAssertEqual(
            RSVPReaderPlaybackTiming.displayDelay(
                for: shortFrame,
                planWordsPerMinute: 260,
                settings: settings,
                initialAdvanceLeadSeconds: RSVPReaderPlaybackTiming.readAlongInitialAdvanceLeadSeconds
            ),
            RSVPReaderPlaybackTiming.minimumFrameDelaySeconds,
            accuracy: 0.0001
        )
        XCTAssertEqual(
            RSVPReaderPanelController.readAlongInitialAdvanceLeadSeconds(
                followsNarration: true,
                playImmediately: true
            ),
            RSVPReaderPlaybackTiming.readAlongInitialAdvanceLeadSeconds,
            accuracy: 0.0001
        )
        XCTAssertEqual(
            RSVPReaderPanelController.readAlongInitialAdvanceLeadSeconds(
                followsNarration: false,
                playImmediately: true
            ),
            0,
            accuracy: 0.0001
        )
        XCTAssertEqual(
            RSVPReaderPanelController.readAlongInitialAdvanceLeadSeconds(
                followsNarration: true,
                playImmediately: false
            ),
            0,
            accuracy: 0.0001
        )
    }

    func testRSVPWordPresentationKeepsCharactersAdjacentWhileHighlightingPivot() {
        let presentation = RSVPWordPresentation(word: "as", orpIndex: 1, isORPEnabled: true)

        XCTAssertEqual(presentation.prefix, "a")
        XCTAssertEqual(presentation.pivot, "s")
        XCTAssertEqual(presentation.suffix, "")
        XCTAssertEqual(presentation.displayText, "as")
        XCTAssertTrue(presentation.isPivotHighlighted)

        let disabled = RSVPWordPresentation(word: "as", orpIndex: 1, isORPEnabled: false)
        XCTAssertEqual(disabled.prefix, "as")
        XCTAssertEqual(disabled.pivot, "")
        XCTAssertEqual(disabled.suffix, "")
        XCTAssertEqual(disabled.displayText, "as")
        XCTAssertFalse(disabled.isPivotHighlighted)
    }

    func testRSVPWordPresentationSplitsAroundRawORPIndexWithPunctuation() {
        let quoted = RSVPWordPresentation(word: #""complete""#, orpIndex: 3, isORPEnabled: true)
        XCTAssertEqual(quoted.prefix, #""co"#)
        XCTAssertEqual(quoted.pivot, "m")
        XCTAssertEqual(quoted.suffix, #"plete""#)
        XCTAssertEqual(quoted.displayText, #""complete""#)

        let parenthesized = RSVPWordPresentation(word: "(text)", orpIndex: 2, isORPEnabled: true)
        XCTAssertEqual(parenthesized.prefix, "(t")
        XCTAssertEqual(parenthesized.pivot, "e")
        XCTAssertEqual(parenthesized.suffix, "xt)")
        XCTAssertEqual(parenthesized.displayText, "(text)")
    }

    func testRSVPWordDisplayStyleUsesHelveticaSansSerifWithSingleHighlightedRun() {
        let presentation = RSVPWordPresentation(word: "neurologic", orpIndex: 3, isORPEnabled: true)
        let layout = RSVPWordDisplayStyle.wordLayout(for: presentation, availableWidth: 420)
        let attributedWord = RSVPWordDisplayStyle.highlightedWord(for: presentation)

        XCTAssertEqual(RSVPWordDisplayStyle.preferredFontName, "Helvetica")
        XCTAssertEqual(layout.fontSize, RSVPWordDisplayStyle.baseFontSize)
        XCTAssertEqual(String(attributedWord.characters), "neurologic")
        XCTAssertFalse(String(attributedWord.characters).contains(" r"))
        XCTAssertFalse(String(attributedWord.characters).contains("r "))
        XCTAssertNotEqual(layout.horizontalOffset, 0)
    }

    func testRSVPWordDisplayRendersKernedHighlightedWordScreenshot() throws {
        let outputURL = URL(fileURLWithPath: "tmp/rsvp-orpspacing-neurologic.png")
        let bitmap = try renderRSVPWordBitmap(
            word: "neurologic",
            orpIndex: 3,
            outputURL: outputURL,
            width: 420,
            height: 140,
            showsFixationGuides: true
        )
        let data = try XCTUnwrap(bitmap.representation(using: .png, properties: [:]))

        XCTAssertGreaterThan(data.count, 1_000)
    }

    func testRSVPWordDisplayUsesGoldenORPAndSeparatedFixationGuides() throws {
        let guidedBitmap = try renderRSVPWordBitmap(
            word: "Speed",
            orpIndex: 1,
            outputURL: nil,
            width: 420,
            height: 216,
            showsFixationGuides: true
        )
        let wordOnlyBitmap = try renderRSVPWordBitmap(
            word: "Speed",
            orpIndex: 1,
            outputURL: nil,
            width: 420,
            height: 216,
            showsFixationGuides: false
        )
        let highlightedBounds = try rsvpHighlightedBounds(in: wordOnlyBitmap)
        let highlightColor = try rsvpAverageColor(in: wordOnlyBitmap) { red, green, blue in
            rsvpMatchesHighContrastORP(red: red, green: green, blue: blue)
        }
        let centerX = guidedBitmap.pixelsWide / 2
        let guideXRange = (centerX - 3)...(centerX + 3)
        let topGuideBounds = try rsvpBounds(
            in: guidedBitmap,
            xRange: guideXRange,
            yRange: 0...(highlightedBounds.minY - 1)
        ) { red, green, blue in
            rsvpMatchesHighContrastORP(red: red, green: green, blue: blue)
        }
        let bottomGuideBounds = try rsvpBounds(
            in: guidedBitmap,
            xRange: guideXRange,
            yRange: (highlightedBounds.maxY + 1)...(guidedBitmap.pixelsHigh - 1)
        ) { red, green, blue in
            rsvpMatchesHighContrastORP(red: red, green: green, blue: blue)
        }

        XCTAssertGreaterThan(highlightColor.red, 0.70)
        XCTAssertGreaterThan(highlightColor.green, 0.54)
        XCTAssertLessThan(highlightColor.blue, 0.35)
        XCTAssertGreaterThanOrEqual(highlightedBounds.minY - topGuideBounds.maxY, 30)
        XCTAssertGreaterThanOrEqual(bottomGuideBounds.minY - highlightedBounds.maxY, 30)
    }

    func testRSVPWordDisplayDrawsSubtleCenterRuleThroughORPColumn() throws {
        let guidedBitmap = try renderRSVPWordBitmap(
            word: "Speed",
            orpIndex: 1,
            outputURL: nil,
            width: 420,
            height: 216,
            showsFixationGuides: true
        )
        let wordOnlyBitmap = try renderRSVPWordBitmap(
            word: "Speed",
            orpIndex: 1,
            outputURL: nil,
            width: 420,
            height: 216,
            showsFixationGuides: false
        )
        let highlightedBounds = try rsvpHighlightedBounds(in: wordOnlyBitmap)
        let centerX = guidedBitmap.pixelsWide / 2
        let centerRulePixels = try rsvpPixelCount(
            in: guidedBitmap,
            xRange: centerX...centerX,
            yRange: highlightedBounds.minY...highlightedBounds.maxY
        ) { red, green, blue in
            let brightness = (red + green + blue) / 3
            let channelSpread = max(red, green, blue) - min(red, green, blue)
            return brightness > 0.43 && brightness < 0.56 && channelSpread < 0.11
        }

        XCTAssertGreaterThanOrEqual(centerRulePixels, 8)
    }

    func testRSVPWordDisplayColorsRoundORPWithoutMovingGeneratedGlyph() throws {
        let outputURL = URL(fileURLWithPath: "tmp/rsvp-orpalignment-he.png")
        _ = try renderRSVPWordBitmap(
            word: "he",
            orpIndex: 1,
            outputURL: outputURL,
            width: 340,
            height: 216,
            showsFixationGuides: true
        )
        let bitmap = try renderRSVPWordBitmap(
            word: "he",
            orpIndex: 1,
            outputURL: nil,
            width: 340,
            height: 216,
            showsFixationGuides: false
        )
        let highlightedBounds = try rsvpHighlightedBounds(in: bitmap)
        let plainBitmap = try renderRSVPWordBitmap(
            word: "he",
            orpIndex: 1,
            outputURL: nil,
            width: 340,
            height: 216,
            showsFixationGuides: false,
            settings: RSVPReadingSettings(isORPEnabled: false)
        )
        let expectedPivotBounds = try rsvpWhiteBounds(
            in: plainBitmap,
            xRange: highlightedBounds.minX...highlightedBounds.maxX
        )

        XCTAssertLessThanOrEqual(
            abs(highlightedBounds.minY - expectedPivotBounds.minY),
            1,
            "highlighted: \(highlightedBounds), expected: \(expectedPivotBounds)"
        )
        XCTAssertLessThanOrEqual(
            abs(highlightedBounds.maxY - expectedPivotBounds.maxY),
            1,
            "highlighted: \(highlightedBounds), expected: \(expectedPivotBounds)"
        )
    }

    func testRSVPWordDisplayColorsORPWithoutMovingGeneratedGlyph() throws {
        let outputURL = URL(fileURLWithPath: "tmp/rsvp-orpalignment-medical.png")
        _ = try renderRSVPWordBitmap(
            word: "Medical",
            orpIndex: 2,
            outputURL: outputURL,
            width: 420,
            height: 160,
            showsFixationGuides: true
        )
        let highlightedBitmap = try renderRSVPWordBitmap(
            word: "Medical",
            orpIndex: 2,
            outputURL: nil,
            width: 420,
            height: 160,
            showsFixationGuides: false
        )
        let highlightedBounds = try rsvpHighlightedBounds(in: highlightedBitmap)
        let plainBitmap = try renderRSVPWordBitmap(
            word: "Medical",
            orpIndex: 2,
            outputURL: nil,
            width: 420,
            height: 160,
            showsFixationGuides: false,
            settings: RSVPReadingSettings(isORPEnabled: false)
        )
        let expectedPivotBounds = try rsvpWhiteBounds(
            in: plainBitmap,
            xRange: highlightedBounds.minX...highlightedBounds.maxX
        )

        XCTAssertLessThanOrEqual(
            abs(highlightedBounds.minY - expectedPivotBounds.minY),
            1,
            "highlighted: \(highlightedBounds), expected: \(expectedPivotBounds)"
        )
        XCTAssertLessThanOrEqual(
            abs(highlightedBounds.maxY - expectedPivotBounds.maxY),
            1,
            "highlighted: \(highlightedBounds), expected: \(expectedPivotBounds)"
        )
    }

    func testRSVPReadingSettingsMigrateOldDefaultToShowDuringNarration() {
        let defaults = UserDefaults(suiteName: "AppNavigationTests-\(UUID().uuidString)")!
        let legacySettings = RSVPReadingSettings(showsDuringNarration: false)
        defaults.set(try! JSONEncoder().encode(legacySettings), forKey: "rsvpReading.settings")

        let model = AppModel(
            router: StudyActionRouter(browser: AppNavigationBrowserStub(), speech: AppNavigationSpeechStub()),
            userDefaults: defaults
        )

        XCTAssertTrue(model.rsvpReadingSettings.showsDuringNarration)

        let reloaded = AppModel(
            router: StudyActionRouter(browser: AppNavigationBrowserStub(), speech: AppNavigationSpeechStub()),
            userDefaults: defaults
        )
        XCTAssertTrue(reloaded.rsvpReadingSettings.showsDuringNarration)
    }

    func testRSVPReadAlongOpensByDefaultSoftSyncsByPlaybackItemAndCanBeDisabled() throws {
        let defaults = UserDefaults(suiteName: "AppNavigationTests-\(UUID().uuidString)")!
        let router = StudyActionRouter(
            browser: AppNavigationBrowserStub(),
            speech: AppNavigationSpeechStub()
        )
        let model = AppModel(router: router, userDefaults: defaults)
        let items = [
            SpeechPlaybackItem(id: "first", segmentID: "stem", sourceText: "Alpha beta gamma.", text: "Alpha beta."),
            SpeechPlaybackItem(id: "second", segmentID: "explanation", sourceText: "Original source words.", text: "Gamma delta."),
        ]

        model.readAlongPresentationWillStart(items: items, mode: .question)

        XCTAssertTrue(model.isRSVPReaderVisible)
        XCTAssertTrue(model.isRSVPReaderFollowingNarration)
        XCTAssertFalse(model.isRSVPReaderPlaybackRequested)
        XCTAssertEqual(model.rsvpReadingPlan?.title, "Question Narration")
        XCTAssertEqual(model.rsvpReadingPlan?.frames.map(\.displayText), ["Alpha", "beta.", "Gamma", "delta."])
        XCTAssertEqual(model.rsvpReadingPlan?.frames.compactMap(\.playbackItemID), ["first", "first", "second", "second"])
        XCTAssertEqual(model.rsvpReaderRequestedFrameIndex, 0)
        let initialFirstItemDuration = try XCTUnwrap(
            model.rsvpReadingPlan?.frames
                .filter { $0.playbackItemID == "first" }
                .reduce(0) { $0 + $1.durationSeconds })

        model.readAlongPresentationDidReceiveTiming(
            SpeechPlaybackItemTiming(
                itemID: "first",
                segmentID: "stem",
                itemIndex: 0,
                durationSeconds: 1.8,
                source: .qwenPreparedAudio,
                sourceAudioDurationSeconds: 1.8,
                audibleStartSeconds: 0,
                audibleEndSeconds: 1.8
            ))
        let firstItemDuration = try XCTUnwrap(
            model.rsvpReadingPlan?.frames
                .filter { $0.playbackItemID == "first" }
                .reduce(0) { $0 + $1.durationSeconds })
        XCTAssertEqual(firstItemDuration, initialFirstItemDuration, accuracy: 0.001)

        model.readAlongPresentationDidReceiveProgress(
            SpeechPlaybackProgress(
                playbackID: UUID(),
                itemID: "first",
                segmentID: "stem",
                itemIndex: 0,
                sourcePositionSeconds: 1.7,
                sourceDurationSeconds: 1.8,
                playbackRate: 1
            ))
        XCTAssertEqual(model.rsvpReaderRequestedFrameIndex, 1)

        model.readAlongPresentationWillSpeak(item: items[1], itemIndex: 1)

        XCTAssertTrue(model.isRSVPReaderVisible)
        XCTAssertTrue(model.isRSVPReaderFollowingNarration)
        XCTAssertFalse(model.isRSVPReaderPlaybackRequested)
        XCTAssertEqual(model.rsvpReaderRequestedFrameIndex, RSVPReadingPlanBuilder.tokenCount(in: items[0].text))
        XCTAssertTrue(model.rsvpReaderSyncRevision >= 2)

        model.readAlongPresentationDidEnd()

        XCTAssertTrue(model.isRSVPReaderVisible)
        model.rsvpReaderDisplayedFrameDidChange(try XCTUnwrap(model.rsvpReadingPlan?.frames.indices.last))

        XCTAssertFalse(model.isRSVPReaderVisible)
        XCTAssertFalse(model.isRSVPReaderFollowingNarration)
        XCTAssertFalse(model.isRSVPReaderPlaybackRequested)
        XCTAssertNil(model.rsvpReadingPlan)

        model.setShowRSVPDuringNarration(false)
        model.readAlongPresentationWillStart(items: items, mode: .question)

        XCTAssertFalse(model.isRSVPReaderVisible)
        XCTAssertFalse(model.isRSVPReaderFollowingNarration)
        XCTAssertFalse(model.isRSVPReaderPlaybackRequested)
        XCTAssertNil(model.rsvpReadingPlan)
    }

    func testRSVPReadAlongDoesNotFreeRunAfterAudioEndsAndClosesAfterFinalFrame() throws {
        let defaults = UserDefaults(suiteName: "AppNavigationTests-\(UUID().uuidString)")!
        let model = AppModel(
            router: StudyActionRouter(browser: AppNavigationBrowserStub(), speech: AppNavigationSpeechStub()),
            userDefaults: defaults
        )
        let item = SpeechPlaybackItem(
            id: "segment",
            segmentID: "stem",
            text: "Alpha beta gamma delta."
        )

        model.readAlongPresentationWillStart(items: [item], mode: .question)
        model.readAlongPresentationDidReceiveTiming(
            SpeechPlaybackItemTiming(
                itemID: item.id,
                segmentID: item.segmentID,
                itemIndex: 0,
                durationSeconds: 1.8,
                source: .qwenPreparedAudio
            ))
        model.readAlongPresentationWillSpeak(item: item, itemIndex: 0)
        model.rsvpReaderDisplayedFrameDidChange(1)
        model.readAlongPresentationDidFinishItem(item: item, itemIndex: 0)

        XCTAssertTrue(model.isRSVPReaderVisible)
        XCTAssertTrue(model.isRSVPReaderFollowingNarration)
        XCTAssertFalse(model.isRSVPReaderPlaybackRequested)

        model.readAlongPresentationDidEnd()

        XCTAssertTrue(model.isRSVPReaderVisible)
        XCTAssertTrue(model.isRSVPReaderFollowingNarration)

        let finalIndex = try XCTUnwrap(model.rsvpReadingPlan?.frames.indices.last)
        model.rsvpReaderDisplayedFrameDidChange(finalIndex)

        XCTAssertFalse(model.isRSVPReaderVisible)
        XCTAssertFalse(model.isRSVPReaderFollowingNarration)
        XCTAssertFalse(model.isRSVPReaderPlaybackRequested)
        XCTAssertNil(model.rsvpReadingPlan)
    }

    func testRSVPReadAlongUsesAudioClockAndFreezesCueSourceForCurrentItem() {
        let defaults = UserDefaults(suiteName: "AppNavigationTests-\(UUID().uuidString)")!
        let model = AppModel(
            router: StudyActionRouter(browser: AppNavigationBrowserStub(), speech: AppNavigationSpeechStub()),
            userDefaults: defaults
        )
        let item = SpeechPlaybackItem(id: "stem", segmentID: "stem", text: "Alpha beta.")
        model.readAlongPresentationWillStart(items: [item], mode: .question)
        model.readAlongPresentationDidReceiveTiming(.init(
            itemID: item.id,
            segmentID: item.segmentID,
            itemIndex: 0,
            durationSeconds: 1.8,
            source: .qwenPreparedAudio,
            sourceAudioDurationSeconds: 1.8,
            audibleStartSeconds: 0,
            audibleEndSeconds: 1.8
        ))
        model.readAlongPresentationWillSpeak(item: item, itemIndex: 0)

        model.readAlongPresentationDidReceiveWordCueTrack(.init(
            itemID: item.id,
            segmentID: item.segmentID,
            itemIndex: 0,
            source: .forcedAligned,
            cues: [
                .init(tokenIndex: 0, startSeconds: 0, endSeconds: 1.7),
                .init(tokenIndex: 1, startSeconds: 1.7, endSeconds: 1.8),
            ]
        ))
        model.readAlongPresentationDidReceiveProgress(.init(
            playbackID: UUID(),
            itemID: item.id,
            segmentID: item.segmentID,
            itemIndex: 0,
            sourcePositionSeconds: 0.9,
            sourceDurationSeconds: 1.8
        ))
        model.readAlongPresentationWillSpeak(item: item, itemIndex: 0)

        XCTAssertEqual(model.rsvpReaderRequestedFrameIndex, 1)
        XCTAssertFalse(model.isRSVPReaderPlaybackRequested)
    }

    func testRSVPReadAlongNextItemStartWinsDuringPriorSegmentDrain() {
        let defaults = UserDefaults(suiteName: "AppNavigationTests-\(UUID().uuidString)")!
        let model = AppModel(
            router: StudyActionRouter(browser: AppNavigationBrowserStub(), speech: AppNavigationSpeechStub()),
            userDefaults: defaults
        )
        let items = [
            SpeechPlaybackItem(id: "first", segmentID: "stem", text: "Alpha beta gamma delta."),
            SpeechPlaybackItem(id: "second", segmentID: "explanation", text: "Epsilon zeta."),
        ]

        model.readAlongPresentationWillStart(items: items, mode: .question)
        model.readAlongPresentationWillSpeak(item: items[0], itemIndex: 0)
        model.rsvpReaderDisplayedFrameDidChange(1)
        model.readAlongPresentationDidFinishItem(item: items[0], itemIndex: 0)
        model.readAlongPresentationWillSpeak(item: items[1], itemIndex: 1)

        XCTAssertTrue(model.isRSVPReaderVisible)
        XCTAssertFalse(model.isRSVPReaderPlaybackRequested)
        XCTAssertEqual(
            model.rsvpReaderRequestedFrameIndex,
            RSVPReadingPlanBuilder.tokenCount(in: items[0].text)
        )
    }

    func testRSVPNarrationTimingDoesNotPersistCalibrationOrText() throws {
        let defaultsName = "AppNavigationTests-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: defaultsName)!
        let item = SpeechPlaybackItem(
            id: "spoken",
            segmentID: "stem",
            sourceText: "HbA1c 7.2%",
            text: "hemoglobin A one C 7 point 2"
        )
        let model = AppModel(
            router: StudyActionRouter(browser: AppNavigationBrowserStub(), speech: AppNavigationSpeechStub()),
            userDefaults: defaults
        )

        model.readAlongPresentationWillStart(items: [item], mode: .question)
        let uncalibratedDuration = try XCTUnwrap(model.rsvpReadingPlan?.frames.reduce(0) { $0 + $1.durationSeconds })
        model.readAlongPresentationDidReceiveTiming(
            SpeechPlaybackItemTiming(
                itemID: item.id,
                segmentID: item.segmentID,
                itemIndex: 0,
                durationSeconds: uncalibratedDuration * 1.5,
                source: .appleObserved
            ))

        let durationAfterTiming = try XCTUnwrap(
            model.rsvpReadingPlan?.frames.reduce(0) { $0 + $1.durationSeconds })
        XCTAssertEqual(durationAfterTiming, uncalibratedDuration, accuracy: 0.001)
        XCTAssertNil(defaults.data(forKey: "rsvpReading.timingCalibration"))

        let storedObjects = defaults.dictionaryRepresentation()
        XCTAssertFalse(storedObjects.description.contains(item.text))
        XCTAssertFalse(storedObjects.description.contains(item.sourceText))

        let reloaded = AppModel(
            router: StudyActionRouter(browser: AppNavigationBrowserStub(), speech: AppNavigationSpeechStub()),
            userDefaults: UserDefaults(suiteName: defaultsName)!
        )
        reloaded.readAlongPresentationWillStart(items: [item], mode: .question)

        let reloadedDuration = try XCTUnwrap(
            reloaded.rsvpReadingPlan?.frames.reduce(0) { $0 + $1.durationSeconds })
        XCTAssertEqual(reloadedDuration, uncalibratedDuration, accuracy: 0.001)
    }

    func testSavingQwenStudentReferenceVoiceSelectsCloningWithoutResettingPlaybackSettings() async throws {
        let root = appNavigationTemporaryQwenRoot()
        let runtime = QwenRuntimeManager(runtimeRoot: root)
        let sample = root.appendingPathComponent("student-input.wav")
        try appNavigationWriteReferenceWAV(to: sample, durationSeconds: 11.0)
        let defaults = UserDefaults(suiteName: "AppNavigationTests-\(UUID().uuidString)")!
        let router = StudyActionRouter(
            browser: AppNavigationBrowserStub(),
            speech: AppNavigationSpeechStub()
        )
        let model = AppModel(router: router, userDefaults: defaults, qwenRuntime: runtime)
        model.setSpeechEngineID(.qwenSmall)
        model.setSpeechRateMultiplier(1.8)
        model.setSpeechVolume(0.65)

        let saved = await model.saveQwenStudentReferenceVoice(from: sample)

        XCTAssertTrue(saved)
        XCTAssertEqual(model.speechSettings.engineID, .qwenSmall)
        XCTAssertEqual(model.speechSettings.rateMultiplier, 1.8)
        XCTAssertEqual(model.speechSettings.volume, 0.65)
        XCTAssertTrue(model.speechSettings.qwenUseReferenceVoice)
        XCTAssertEqual(model.speechSettings.qwenReferenceVoiceID, .studentClone)
        XCTAssertEqual(model.speechSettings.effectiveQwenReferenceVoice.displayName, "My Voice")
        XCTAssertEqual(
            URL(fileURLWithPath: model.speechSettings.effectiveQwenReferenceVoice.audioPath ?? "").lastPathComponent, "student-clone.wav")

        model.setQwenReferenceVoiceID(.crispStudyVoice)

        XCTAssertTrue(model.speechSettings.qwenUseReferenceVoice)
        XCTAssertEqual(model.speechSettings.qwenReferenceVoiceID, .crispStudyVoice)
        XCTAssertEqual(model.speechSettings.qwenSpeaker, QwenModelLane.small.defaultSpeaker)
        XCTAssertEqual(model.speechSettings.effectiveQwenReferenceVoice.displayName, QwenReferenceVoiceDefaults.displayName)
        XCTAssertNotNil(model.speechSettings.qwenStudentReferenceVoice)
    }

    func testLightPlaybackHUDStyleUsesMoreTranslucentWhiteGlassAndSubtleGlyphs() {
        let style = PlaybackHUDAppearanceDesign(appearance: .light)

        XCTAssertEqual(style.panelAppearanceName, .aqua)
        XCTAssertLessThan(style.capsuleFillOpacity, 0.22)
        XCTAssertGreaterThan(style.nativeGlassTintOpacity, 0)
        XCTAssertLessThan(style.nativeGlassTintOpacity, 0.20)
        XCTAssertEqual(style.activeGlyphTone, .warmOrange)
        XCTAssertEqual(style.inactiveGlyphTone, .lightGray)
    }

    func testFloatingOverlaysPreserveReadableRSVPAndLiveVisualizationSpace() {
        let barCount = 16
        let visualizationWidth =
            CGFloat(barCount) * PlaybackHUDConfiguration.barWidth
            + CGFloat(barCount - 1) * PlaybackHUDConfiguration.barSpacing

        XCTAssertEqual(SalientFloatingOverlayDesign.cornerRadius, 24)
        XCTAssertGreaterThan(RSVPReaderPanelConfiguration.wordDisplayHeight, PlaybackHUDConfiguration.stageSize.height)
        XCTAssertLessThan(visualizationWidth, PlaybackHUDConfiguration.stageSize.width)
        XCTAssertGreaterThan(PlaybackHUDConfiguration.panelSize.height, PlaybackHUDConfiguration.stageSize.height)
    }

    func testPlaybackHUDStopControlOnlyRespondsWhileHovered() {
        var state = PlaybackHUDStopControlState()

        XCTAssertEqual(state.opacity, 0)
        XCTAssertFalse(state.allowsHitTesting)

        state.setPointerInside(true)

        XCTAssertEqual(state.opacity, 1)
        XCTAssertTrue(state.allowsHitTesting)
    }

    func testPlaybackHUDViewModelInvokesConfiguredStopHandler() {
        var didStop = false
        let viewModel = PlaybackHUDViewModel {
            didStop = true
        }

        viewModel.stopPlayback()

        XCTAssertTrue(didStop)
    }

    func testPlaybackHUDLevelDecaysAfterAudioStopsWhileReadContinues() async throws {
        let router = StudyActionRouter(
            browser: AppNavigationBrowserStub(),
            speech: AppNavigationSpeechStub()
        )
        let defaults = UserDefaults(suiteName: "AppNavigationTests-\(UUID().uuidString)")!
        let model = AppModel(router: router, userDefaults: defaults)
        let activeFrame = SpeechPlaybackVisualizationFrame(
            level: 0.8,
            barLevels: Array(repeating: 0.8, count: 16)
        )

        model.speechPlaybackVisualizationDidStart()
        model.speechPlaybackVisualizationAudioDidStart()
        model.speechPlaybackVisualizationFrameDidChange(activeFrame)
        model.speechPlaybackVisualizationAudioDidStop()
        for _ in 0..<12 where (model.playbackHUDFrame.barLevels.max() ?? 1) >= 0.5 {
            try await Task.sleep(nanoseconds: 25_000_000)
        }

        XCTAssertTrue(model.isPlaybackHUDVisible)
        XCTAssertFalse(model.isPlaybackHUDGenerating)
        XCTAssertLessThan(model.playbackHUDLevel, activeFrame.level)
        XCTAssertLessThan(model.playbackHUDFrame.barLevels.max() ?? 1, 0.5)
        XCTAssertGreaterThanOrEqual(model.playbackHUDLevel, 0)
    }

    func testPlaybackHUDAudioStartDoesNotInventGenericFrameBeforeMetering() {
        let router = StudyActionRouter(
            browser: AppNavigationBrowserStub(),
            speech: AppNavigationSpeechStub()
        )
        let defaults = UserDefaults(suiteName: "AppNavigationTests-\(UUID().uuidString)")!
        let model = AppModel(router: router, userDefaults: defaults)

        model.speechPlaybackVisualizationDidStart()
        model.speechPlaybackVisualizationAudioDidStart()

        XCTAssertTrue(model.isPlaybackHUDVisible)
        XCTAssertFalse(model.isPlaybackHUDGenerating)
        XCTAssertEqual(model.playbackHUDLevel, 0)
        XCTAssertTrue(model.playbackHUDFrame.barLevels.allSatisfy { $0 == 0 })
    }
}

@MainActor
private final class AppNavigationBrowserStub: BrowserAutomationService {
    func executeJavaScriptInUWorldTab(_ javaScript: String) async -> BrowserAutomationResult {
        .failure("Not used in navigation tests.")
    }
}

@MainActor
private final class AppNavigationSpeechStub: SpeechBackend {
    func speak(_ text: String) async throws {}

    func speak(
        _ items: [SpeechPlaybackItem],
        willSpeak: @escaping @MainActor (SpeechPlaybackItem) async -> Void
    ) async throws {}

    func stop() async {}
}

private func appNavigationTemporaryQwenRoot() -> URL {
    FileManager.default.temporaryDirectory
        .appendingPathComponent("salient-app-navigation-qwen-\(UUID().uuidString)", isDirectory: true)
}

@MainActor
private func renderRSVPWordBitmap(
    word: String,
    orpIndex: Int,
    outputURL: URL?,
    width: CGFloat,
    height: CGFloat,
    showsFixationGuides: Bool = false,
    settings: RSVPReadingSettings = RSVPReadingSettings()
) throws -> NSBitmapImageRep {
    if let outputURL {
        try FileManager.default.createDirectory(
            at: outputURL.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
    }
    let frame = RSVPReadingFrame(
        displayText: word,
        orpIndex: orpIndex,
        sectionLabel: "Probe",
        durationSeconds: 0.1,
        sourceTokenIndex: 0
    )
    let size = NSSize(width: width, height: height)
    let rootView = ZStack {
        Color(red: 0.36, green: 0.40, blue: 0.44)
        RSVPWordDisplay(
            frame: frame,
            settings: settings,
            showsFixationGuides: showsFixationGuides
        )
        .frame(height: RSVPReaderPanelConfiguration.wordDisplayHeight)
        .padding(.horizontal, 18)
    }
    .frame(width: size.width, height: size.height)
    let hostingView = NSHostingView(rootView: rootView)
    hostingView.frame = NSRect(origin: .zero, size: size)
    hostingView.layoutSubtreeIfNeeded()

    // Pixel assertions use a Retina fixture. A windowless hosting view otherwise
    // inherits the current display scale, which can change during native UI QA.
    let bitmap = try XCTUnwrap(NSBitmapImageRep(
        bitmapDataPlanes: nil,
        pixelsWide: Int(size.width * 2),
        pixelsHigh: Int(size.height * 2),
        bitsPerSample: 8,
        samplesPerPixel: 4,
        hasAlpha: true,
        isPlanar: false,
        colorSpaceName: .deviceRGB,
        bytesPerRow: 0,
        bitsPerPixel: 0
    ))
    bitmap.size = size
    hostingView.cacheDisplay(in: hostingView.bounds, to: bitmap)
    if let outputURL {
        let data = try XCTUnwrap(bitmap.representation(using: .png, properties: [:]))
        try data.write(to: outputURL, options: .atomic)
    }
    return bitmap
}

private func rsvpInkBounds(in bitmap: NSBitmapImageRep) throws -> RSVPWordInkBounds {
    let highlighted = try rsvpHighlightedBounds(in: bitmap)
    let neighboring = try rsvpWhiteBounds(in: bitmap)
    return RSVPWordInkBounds(highlighted: highlighted, neighboring: neighboring)
}

private func rsvpHighlightedBounds(in bitmap: NSBitmapImageRep) throws -> RSVPInkBounds {
    try rsvpBounds(in: bitmap) { red, green, blue in
        rsvpMatchesHighContrastORP(red: red, green: green, blue: blue)
    }
}

private func rsvpWhiteBounds(
    in bitmap: NSBitmapImageRep,
    xRange: ClosedRange<Int>? = nil
) throws -> RSVPInkBounds {
    try rsvpBounds(in: bitmap, xRange: xRange) { red, green, blue in
        let brightness = (red + green + blue) / 3
        let channelSpread = max(red, green, blue) - min(red, green, blue)
        return brightness > 0.58 && channelSpread < 0.18
    }
}

private func rsvpBounds(
    in bitmap: NSBitmapImageRep,
    xRange: ClosedRange<Int>? = nil,
    yRange: ClosedRange<Int>? = nil,
    matches: (CGFloat, CGFloat, CGFloat) -> Bool
) throws -> RSVPInkBounds {
    var bounds = RSVPInkBounds()
    let clippedXRange = max(0, xRange?.lowerBound ?? 0)...min(bitmap.pixelsWide - 1, xRange?.upperBound ?? bitmap.pixelsWide - 1)
    let clippedYRange = max(0, yRange?.lowerBound ?? 0)...min(bitmap.pixelsHigh - 1, yRange?.upperBound ?? bitmap.pixelsHigh - 1)

    for y in clippedYRange {
        for x in clippedXRange {
            guard let color = bitmap.colorAt(x: x, y: y)?.usingColorSpace(.sRGB) else {
                continue
            }
            let red = color.redComponent
            let green = color.greenComponent
            let blue = color.blueComponent

            if matches(red, green, blue) {
                bounds.include(x: x, y: y)
            }
        }
    }

    guard !bounds.isEmpty else {
        throw RSVPInkBoundsError.missingInk
    }
    return bounds
}

private func rsvpPixelCount(
    in bitmap: NSBitmapImageRep,
    xRange: ClosedRange<Int>,
    yRange: ClosedRange<Int>,
    matches: (CGFloat, CGFloat, CGFloat) -> Bool
) throws -> Int {
    var count = 0
    let clippedXRange = max(0, xRange.lowerBound)...min(bitmap.pixelsWide - 1, xRange.upperBound)
    let clippedYRange = max(0, yRange.lowerBound)...min(bitmap.pixelsHigh - 1, yRange.upperBound)

    for y in clippedYRange {
        for x in clippedXRange {
            guard let color = bitmap.colorAt(x: x, y: y)?.usingColorSpace(.sRGB) else {
                continue
            }
            if matches(color.redComponent, color.greenComponent, color.blueComponent) {
                count += 1
            }
        }
    }

    return count
}

private func rsvpAverageColor(
    in bitmap: NSBitmapImageRep,
    matches: (CGFloat, CGFloat, CGFloat) -> Bool
) throws -> RSVPAverageColor {
    var red: CGFloat = 0
    var green: CGFloat = 0
    var blue: CGFloat = 0
    var count: CGFloat = 0

    for y in 0..<bitmap.pixelsHigh {
        for x in 0..<bitmap.pixelsWide {
            guard let color = bitmap.colorAt(x: x, y: y)?.usingColorSpace(.sRGB) else {
                continue
            }
            guard matches(color.redComponent, color.greenComponent, color.blueComponent) else {
                continue
            }
            red += color.redComponent
            green += color.greenComponent
            blue += color.blueComponent
            count += 1
        }
    }

    guard count > 0 else {
        throw RSVPInkBoundsError.missingInk
    }
    return RSVPAverageColor(red: red / count, green: green / count, blue: blue / count)
}

private func rsvpMatchesHighContrastORP(red: CGFloat, green: CGFloat, blue: CGFloat) -> Bool {
    red > 0.44 && red - green > 0.08 && red - blue > 0.08
}

private struct RSVPAverageColor {
    var red: CGFloat
    var green: CGFloat
    var blue: CGFloat
}

private struct RSVPWordInkBounds {
    var highlighted: RSVPInkBounds
    var neighboring: RSVPInkBounds
}

private struct RSVPInkBounds: CustomStringConvertible {
    private(set) var minX = Int.max
    private(set) var minY = Int.max
    private(set) var maxX = Int.min
    private(set) var maxY = Int.min

    var isEmpty: Bool {
        maxX == Int.min
    }

    mutating func include(x: Int, y: Int) {
        minX = min(minX, x)
        minY = min(minY, y)
        maxX = max(maxX, x)
        maxY = max(maxY, y)
    }

    var description: String {
        "(minX: \(minX), minY: \(minY), maxX: \(maxX), maxY: \(maxY))"
    }
}

private enum RSVPInkBoundsError: Error {
    case missingInk
}

private func appNavigationWriteReferenceWAV(to url: URL, durationSeconds: Double) throws {
    try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
    let sampleRate = 24_000.0
    let format = AVAudioFormat(standardFormatWithSampleRate: sampleRate, channels: 1)!
    let file = try AVAudioFile(forWriting: url, settings: format.settings)
    let frameCount = AVAudioFrameCount(durationSeconds * sampleRate)
    let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: frameCount)!
    buffer.frameLength = frameCount
    let samples = buffer.floatChannelData![0]
    for frame in 0..<Int(frameCount) {
        samples[frame] = sin(Float(frame) / 19.0) * 0.1
    }
    try file.write(from: buffer)
}
