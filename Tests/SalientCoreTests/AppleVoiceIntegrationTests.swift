import AVFoundation
import Foundation
import XCTest
@testable import SalientCore
@testable import Salient

@MainActor
final class AppleVoiceIntegrationTests: XCTestCase {
    func testEnhancedVoiceWithDifferentIdentifierNamespaceIsNotHidden() {
        let standard = SpeechVoiceOption(identifier: "com.apple.voice.compact.en-US.Samantha", name: "Samantha", language: "en-US")
        let enhanced = SpeechVoiceOption(identifier: "com.apple.ttsbundle.synthetic-enhanced", name: "Voice 4", language: "en-US", quality: .enhanced)
        var premium = enhanced
        premium.identifier = "synthetic-premium"
        premium.quality = .premium
        var novelty = premium
        novelty.isNovelty = true
        var personal = premium
        personal.isPersonal = true
        var french = premium
        french.language = "fr-FR"
        XCTAssertEqual(SpeechVoiceOption.studyVoices(from: [standard, novelty, enhanced, personal, french, premium]), [premium, enhanced, standard])
        XCTAssertTrue(enhanced.displayName.contains("Enhanced"))
    }

    func testVoiceRefreshPreservesSelectionAcrossRemovalAndDownload() throws {
        let defaults = UserDefaults(suiteName: "AppleVoiceIntegrationTests-\(UUID())")!
        let voice = SpeechVoiceOption(identifier: "synthetic-downloaded-voice", name: "Voice 4", language: "en-US", quality: .enhanced)
        var settings = SpeechSettings.firstLaunch
        settings.voiceIdentifier = voice.identifier
        defaults.set(try JSONEncoder().encode(settings), forKey: "speech.settings")
        var catalog: [SpeechVoiceOption] = []
        let model = AppModel(userDefaults: defaults, disablesAutomaticModelWarmup: true, speechVoiceProvider: { catalog })
        XCTAssertTrue(model.selectedAppleVoiceIsUnavailable)
        XCTAssertEqual(model.speechSettings.voiceIdentifier, voice.identifier)
        catalog = [voice]
        model.refreshSpeechVoices()
        XCTAssertEqual(model.availableSpeechVoices, [voice])
        XCTAssertFalse(model.selectedAppleVoiceIsUnavailable)
        catalog = []
        model.refreshSpeechVoices()
        XCTAssertTrue(model.selectedAppleVoiceIsUnavailable)
        XCTAssertEqual(model.speechSettings.voiceIdentifier, voice.identifier)
    }

    func testUtteranceHonorsExplicitVoicePaceAndVolume() throws {
        let voice = try XCTUnwrap(AVSpeechSynthesisVoice(language: "en-US"))
        var settings = SpeechSettings.firstLaunch
        settings.voiceIdentifier = voice.identifier
        settings.rateMultiplier = 1.3
        settings.volume = 0.4
        let utterance = AVFoundationSpeechBackend.makeUtterance("Synthetic voice settings test.", settings: settings)
        XCTAssertEqual(utterance.voice?.identifier, voice.identifier)
        XCTAssertEqual(utterance.rate, AVSpeechUtteranceDefaultSpeechRate * 1.3, accuracy: 0.001)
        XCTAssertEqual(utterance.volume, 0.4, accuracy: 0.001)
        XCTAssertFalse(utterance.prefersAssistiveTechnologySettings)
    }
}
