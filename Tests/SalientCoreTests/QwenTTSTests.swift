import AVFoundation
import XCTest

@testable import SalientCore

final class QwenTTSTests: XCTestCase {
    func testSpeechSettingsMigrationDefaultsExistingSettingsToAppleEngine() throws {
        let data = """
            {
              "rateMultiplier": 1.7,
              "volume": 0.8,
              "pitchMultiplier": 1.1,
              "voiceIdentifier": "com.apple.voice.compact.en-US.Samantha"
            }
            """.data(using: .utf8)!

        let settings = try JSONDecoder().decode(SpeechSettings.self, from: data)

        XCTAssertEqual(settings.engineID, .apple)
        XCTAssertEqual(settings.rateMultiplier, 1.7)
        XCTAssertEqual(settings.qwenSpeaker, QwenModelLane.small.defaultSpeaker)
        XCTAssertFalse(settings.qwenUseReferenceVoice)
        XCTAssertEqual(settings.qwenReferenceVoiceName, QwenReferenceVoiceDefaults.voiceName)
        XCTAssertEqual(settings.qwenReferenceText, QwenReferenceVoiceDefaults.referenceText)
        XCTAssertTrue(settings.showPlaybackHUD)
    }

    func testSpeechSettingsMigratesLegacyQwenCloneEngineToCrispReferenceVoice() throws {
        let data = """
            {
              "engineID": "qwenClone",
              "rateMultiplier": 2.2,
              "volume": 0.9,
              "pitchMultiplier": 1.0,
              "voiceIdentifier": null,
              "qwenSpeaker": "qwen_cmu145_crisp_us_male"
            }
            """.data(using: .utf8)!

        let settings = try JSONDecoder().decode(SpeechSettings.self, from: data)

        XCTAssertEqual(settings.engineID, .qwenBest)
        XCTAssertTrue(settings.qwenUseReferenceVoice)
        XCTAssertEqual(settings.qwenReferenceVoiceName, QwenReferenceVoiceDefaults.voiceName)
        XCTAssertEqual(settings.qwenReferenceVoiceID, .crispStudyVoice)
        XCTAssertEqual(settings.effectiveQwenReferenceVoice.displayName, QwenReferenceVoiceDefaults.displayName)
        XCTAssertEqual(settings.availableQwenReferenceVoiceIDs, [.crispStudyVoice])
        XCTAssertEqual(settings.qwenSpeaker, QwenModelLane.best.defaultSpeaker)
    }

    func testSpeechSettingsMigratesLegacyReferenceAudioIntoSavedStudentVoiceWhileKeepingCrispDefault() throws {
        let data = """
            {
              "engineID": "qwenBest",
              "rateMultiplier": 2.2,
              "volume": 0.9,
              "pitchMultiplier": 1.0,
              "voiceIdentifier": null,
              "qwenUseReferenceVoice": true,
              "qwenReferenceVoiceName": "previous-custom-voice",
              "qwenReferenceAudioPath": "/tmp/previous-custom-voice.wav",
              "qwenReferenceText": "Exact prior transcript."
            }
            """.data(using: .utf8)!

        let settings = try JSONDecoder().decode(SpeechSettings.self, from: data)

        XCTAssertTrue(settings.qwenUseReferenceVoice)
        XCTAssertEqual(settings.qwenSpeaker, QwenModelLane.best.defaultSpeaker)
        XCTAssertEqual(settings.qwenReferenceVoiceID, .crispStudyVoice)
        XCTAssertEqual(settings.qwenStudentReferenceVoice?.displayName, "My Voice")
        XCTAssertEqual(settings.qwenStudentReferenceVoice?.audioPath, "/tmp/previous-custom-voice.wav")
        XCTAssertNil(settings.effectiveQwenReferenceVoice.audioPath)
        XCTAssertEqual(settings.effectiveQwenReferenceVoice.transcript, QwenReferenceVoiceDefaults.referenceText)
        XCTAssertEqual(settings.availableQwenReferenceVoiceIDs, [.crispStudyVoice, .studentClone])
    }

    func testSpeechSettingsPreservesExplicitStudentCloneSelectionAfterCurrentVoiceDefaultMigration() throws {
        var settings = SpeechSettings.default
        settings.engineID = .qwenBest
        settings.qwenUseReferenceVoice = true
        settings.qwenReferenceVoiceID = .studentClone
        settings.qwenStudentReferenceVoice = QwenStudentReferenceVoice(
            displayName: "My Voice",
            audioPath: "/tmp/student-clone.wav",
            transcript: "Exact transcript.",
            durationSeconds: 12,
            createdAt: Date(timeIntervalSince1970: 100)
        )

        let data = try JSONEncoder().encode(settings.clamped)
        let decoded = try JSONDecoder().decode(SpeechSettings.self, from: data)

        XCTAssertTrue(decoded.qwenUseReferenceVoice)
        XCTAssertEqual(decoded.qwenReferenceVoiceID, .studentClone)
        XCTAssertEqual(decoded.effectiveQwenReferenceVoice.displayName, "My Voice")
        XCTAssertEqual(decoded.effectiveQwenReferenceVoice.audioPath, "/tmp/student-clone.wav")
    }

    func testSpeechSettingsDefaultsQwenCloningToCrispReferenceVoice() {
        var settings = SpeechSettings.default
        settings.engineID = .qwenBest

        settings = settings.clamped

        XCTAssertTrue(settings.qwenUseReferenceVoice)
        XCTAssertEqual(settings.qwenReferenceVoiceID, .crispStudyVoice)
        XCTAssertEqual(settings.qwenSpeaker, QwenModelLane.best.defaultSpeaker)
        XCTAssertNotEqual(settings.qwenSpeaker, QwenReferenceVoiceDefaults.voiceName)
        XCTAssertEqual(settings.effectiveQwenReferenceVoice.displayName, QwenReferenceVoiceDefaults.displayName)
        XCTAssertEqual(settings.effectiveQwenReferenceVoice.voiceName, QwenReferenceVoiceDefaults.voiceName)
        XCTAssertEqual(settings.availableQwenReferenceVoiceIDs, [.crispStudyVoice])
        XCTAssertNil(settings.effectiveQwenReferenceVoice.audioPath)
    }

    func testSpeechSettingsKeepsCrispReferenceDefaultWhileRetainingStudentCloneOption() {
        let student = QwenStudentReferenceVoice(
            displayName: "My Voice",
            audioPath: "/tmp/student-clone.wav",
            transcript: QwenStudentReferenceVoiceDefaults.referenceText,
            durationSeconds: 12,
            createdAt: Date(timeIntervalSince1970: 100)
        )
        var settings = SpeechSettings.default
        settings.engineID = .qwenSmall
        settings.qwenUseReferenceVoice = true
        settings.qwenStudentReferenceVoice = student
        settings.qwenReferenceVoiceID = .studentClone
        settings = settings.clamped

        XCTAssertEqual(settings.effectiveQwenReferenceVoice.displayName, "My Voice")
        XCTAssertEqual(settings.qwenReferenceAudioPath, "/tmp/student-clone.wav")
        XCTAssertEqual(settings.availableQwenReferenceVoiceIDs, [.crispStudyVoice, .studentClone])

        settings.qwenReferenceVoiceID = .crispStudyVoice
        settings.qwenUseReferenceVoice = true
        settings.qwenSpeaker = QwenReferenceVoiceDefaults.voiceName
        settings = settings.clamped

        XCTAssertTrue(settings.qwenUseReferenceVoice)
        XCTAssertEqual(settings.qwenReferenceVoiceID, .crispStudyVoice)
        XCTAssertEqual(settings.qwenSpeaker, QwenModelLane.small.defaultSpeaker)
        XCTAssertNotEqual(settings.qwenSpeaker, QwenReferenceVoiceDefaults.voiceName)
        XCTAssertEqual(settings.effectiveQwenReferenceVoice.displayName, QwenReferenceVoiceDefaults.displayName)
        XCTAssertEqual(settings.qwenReferenceAudioPath, "")
        XCTAssertEqual(settings.qwenStudentReferenceVoice, student)
    }

    func testSpeechSettingsNormalizesUnsupportedCrispReferenceIDOutOfPresetSpeakerSlot() {
        var settings = SpeechSettings.default
        settings.engineID = .qwenSmall
        settings.qwenSpeaker = QwenReferenceVoiceDefaults.voiceName
        settings.qwenUseReferenceVoice = false

        settings = settings.clamped

        XCTAssertEqual(settings.qwenSpeaker, QwenModelLane.small.defaultSpeaker)
        XCTAssertNotEqual(settings.qwenSpeaker, QwenReferenceVoiceDefaults.voiceName)
        XCTAssertFalse(settings.qwenUseReferenceVoice)
    }

    func testQwenStudentReferenceVoiceScriptUsesShortConversationalSentences() {
        let script = QwenStudentReferenceVoiceDefaults.referenceText
        let sentences =
            script
            .split { ".!?".contains($0) }
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }

        XCTAssertGreaterThanOrEqual(sentences.count, 5)
        XCTAssertTrue(
            sentences.allSatisfy { sentence in
                sentence.split(separator: " ").count <= 14
            })
        XCTAssertTrue(
            sentences.allSatisfy { sentence in
                sentence.filter { $0 == "," }.count <= 1
            })
        XCTAssertTrue(script.localizedCaseInsensitiveContains("tachycardia"))
        XCTAssertTrue(script.localizedCaseInsensitiveContains("glomerulonephritis"))
        XCTAssertTrue(script.localizedCaseInsensitiveContains("Streptococcus pneumoniae"))
    }

    func testSpeechSettingsDefaultEnablesPlaybackHUD() {
        XCTAssertTrue(SpeechSettings.default.showPlaybackHUD)
    }

    func testSpeechSettingsDefaultEnablesQuestionPromptAudioLibrary() throws {
        XCTAssertTrue(SpeechSettings.default.usesQuestionPromptAudioLibrary)

        let legacyData = """
            {
              "engineID": "qwenSmall",
              "rateMultiplier": 2.4,
              "volume": 1.0,
              "pitchMultiplier": 1.0,
              "voiceIdentifier": null
            }
            """.data(using: .utf8)!
        let migrated = try JSONDecoder().decode(SpeechSettings.self, from: legacyData)

        XCTAssertTrue(migrated.usesQuestionPromptAudioLibrary)
    }

    func testSpeechSettingsDefaultsPlaybackHUDToDarkAppearance() {
        XCTAssertEqual(SpeechSettings.default.playbackHUDAppearance, .dark)
    }

    func testSpeechSettingsMigratesLegacyPlaybackHUDAppearanceToDark() throws {
        let data = """
            {
              "rateMultiplier": 1.7,
              "volume": 0.8,
              "pitchMultiplier": 1.1,
              "voiceIdentifier": null,
              "showPlaybackHUD": true
            }
            """.data(using: .utf8)!

        let settings = try JSONDecoder().decode(SpeechSettings.self, from: data)

        XCTAssertEqual(settings.playbackHUDAppearance, .dark)
    }

    func testSpeechSettingsPersistsLightPlaybackHUDAppearance() throws {
        let settings = SpeechSettings(
            rateMultiplier: 2.4,
            volume: 1.0,
            pitchMultiplier: 1.0,
            voiceIdentifier: nil,
            playbackHUDAppearance: .light
        )

        let decoded = try JSONDecoder().decode(
            SpeechSettings.self,
            from: try JSONEncoder().encode(settings)
        )

        XCTAssertEqual(decoded.playbackHUDAppearance, .light)
    }

    func testQwenModelLaneMetadataUsesCustomVoiceModels() {
        XCTAssertEqual(QwenModelLane.small.engineID, .qwenSmall)
        XCTAssertEqual(QwenModelLane.best.engineID, .qwenBest)
        XCTAssertEqual(QwenModelLane.small.displayName, "Qwen Fast")
        XCTAssertEqual(QwenModelLane.best.displayName, "Qwen Best")
        XCTAssertEqual(QwenModelLane.small.defaultSpeaker, "Aiden")
        XCTAssertEqual(QwenModelLane.small.title(for: QwenModelLane.small.defaultSpeaker), "Aiden")
        XCTAssertFalse(QwenModelLane.small.presetSpeakers.contains(QwenReferenceVoiceDefaults.voiceName))
        XCTAssertTrue(QwenModelLane.small.presetSpeakers.contains("Aiden"))
        XCTAssertEqual(QwenModelLane.small.alternateSpeaker, "Ryan")
        XCTAssertTrue(QwenModelLane.small.modelID.contains("0.6B-CustomVoice-8bit"))
        XCTAssertTrue(QwenModelLane.best.modelID.contains("1.7B-CustomVoice-6bit"))
        XCTAssertTrue(QwenModelLane.small.referenceModelID.contains("0.6B-Base-8bit"))
        XCTAssertTrue(QwenModelLane.best.referenceModelID.contains("1.7B-Base-8bit"))
        XCTAssertTrue(QwenModelLane.small.supportsReferenceVoice)
        XCTAssertTrue(QwenModelLane.best.supportsReferenceVoice)
    }

    func testQwenReadinessStatesMapToDependencyCenterRows() {
        let installing = QwenRuntimeReport(
            runtimeRoot: "/tmp/qwen",
            logsDirectory: "/tmp/qwen/logs",
            architecture: "arm64",
            uvAvailable: true,
            pythonEnvironmentAvailable: true,
            mlxAudioAvailable: true,
            helperAvailable: true,
            installedModelIDs: [],
            installingLane: .small
        )
        let installingReport = DependencyCenterReport.current(
            safariAutomation: .authorized,
            globalHotKeyEnabled: false,
            qwenRuntime: installing,
            selectedSpeechEngine: .qwenSmall
        )
        XCTAssertEqual(installingReport.items.first { $0.id == "qwen-tts" }?.state, .installing)

        let ready = QwenRuntimeReport(
            runtimeRoot: "/tmp/qwen",
            logsDirectory: "/tmp/qwen/logs",
            architecture: "arm64",
            uvAvailable: true,
            pythonEnvironmentAvailable: true,
            mlxAudioAvailable: true,
            helperAvailable: true,
            installedModelIDs: [QwenModelLane.best.modelID]
        )
        let readyReport = DependencyCenterReport.current(
            safariAutomation: .authorized,
            globalHotKeyEnabled: false,
            qwenRuntime: ready,
            selectedSpeechEngine: .qwenBest
        )
        XCTAssertEqual(readyReport.items.first { $0.id == "qwen-tts" }?.state, .available)
    }

    func testQwenInstallerProgressParsesJsonLines() throws {
        let progress = QwenInstallProgress.parse(
            line: #"{"stage":"Downloading model","fractionCompleted":0.65}"#,
            lane: .best
        )

        XCTAssertEqual(progress?.lane, .best)
        XCTAssertEqual(progress?.stage, "Downloading model")
        XCTAssertEqual(progress?.fractionCompleted, 0.65)
    }

    func testQwenCacheKeyChangesWhenModelSpeakerOrTextChangesAndIgnoresPlaybackRate() {
        let base = QwenRuntimeManager.cacheKey(
            text: "A private study sentence.",
            lane: .small,
            speaker: "Aiden",
            language: "English",
            rateMultiplier: 2.4
        )

        XCTAssertNotEqual(
            base,
            QwenRuntimeManager.cacheKey(
                text: "A private study sentence.",
                lane: .small,
                speaker: "Aiden",
                language: "English",
                rateMultiplier: 2.4,
                qwenDeEsserStrengthDecibels: 10
            ))
        XCTAssertNotEqual(
            base,
            QwenRuntimeManager.cacheKey(
                text: "A private study sentence.",
                lane: .best,
                speaker: "Aiden",
                language: "English",
                rateMultiplier: 2.4
            ))
        XCTAssertNotEqual(
            base,
            QwenRuntimeManager.cacheKey(
                text: "A private study sentence.",
                lane: .small,
                speaker: "Ryan",
                language: "English",
                rateMultiplier: 2.4
            ))
        XCTAssertEqual(
            base,
            QwenRuntimeManager.cacheKey(
                text: "A private study sentence.",
                lane: .small,
                speaker: "Aiden",
                language: "English",
                rateMultiplier: 1.2
            ))
        XCTAssertNotEqual(
            base,
            QwenRuntimeManager.cacheKey(
                text: "A different private study sentence.",
                lane: .small,
                speaker: "Aiden",
                language: "English",
                rateMultiplier: 2.4
            ))
        XCTAssertNotEqual(
            base,
            QwenRuntimeManager.cacheKey(
                text: "A private study sentence.",
                lane: .small,
                speaker: "Aiden",
                language: "English",
                rateMultiplier: 2.4,
                useReferenceVoice: true,
                referenceAudioSignature: "reference-a.wav",
                referenceText: "Reference transcript."
            ))
    }

    func testQwenCacheKeyChangesBetweenCrispAndStudentReferenceVoice() {
        let crisp = QwenRuntimeManager.cacheKey(
            text: "Which medication is most appropriate?",
            lane: .small,
            speaker: QwenReferenceVoiceDefaults.voiceName,
            language: "English",
            rateMultiplier: 2.4,
            useReferenceVoice: true,
            referenceAudioSignature: "qwen_cmu145_crisp_us_male_b0402.wav|bytes=100",
            referenceText: QwenReferenceVoiceDefaults.referenceText
        )

        let student = QwenRuntimeManager.cacheKey(
            text: "Which medication is most appropriate?",
            lane: .small,
            speaker: QwenStudentReferenceVoiceDefaults.voiceName,
            language: "English",
            rateMultiplier: 2.4,
            useReferenceVoice: true,
            referenceAudioSignature: "student-clone.wav|bytes=100",
            referenceText: QwenStudentReferenceVoiceDefaults.referenceText
        )

        XCTAssertNotEqual(crisp, student)
    }

    func testQwenReferenceCacheKeyIgnoresPresetSpeaker() {
        let prewarmed = QwenRuntimeManager.cacheKey(
            text: "Which medication is most appropriate?",
            lane: .small,
            speaker: QwenModelLane.small.defaultSpeaker,
            language: "English",
            rateMultiplier: 2.4,
            useReferenceVoice: true,
            referenceAudioSignature: "qwen_cmu145_crisp_us_male_b0402.wav|bytes=100",
            referenceText: QwenReferenceVoiceDefaults.referenceText
        )
        let spoken = QwenRuntimeManager.cacheKey(
            text: "Which medication is most appropriate?",
            lane: .small,
            speaker: QwenReferenceVoiceDefaults.voiceName,
            language: "English",
            rateMultiplier: 2.4,
            useReferenceVoice: true,
            referenceAudioSignature: "qwen_cmu145_crisp_us_male_b0402.wav|bytes=100",
            referenceText: QwenReferenceVoiceDefaults.referenceText
        )

        XCTAssertEqual(prewarmed, spoken)
    }

    func testQwenCachePipelineVersionMarksFastStartAudio() {
        XCTAssertEqual(
            QwenRuntimeManager.cachePipelineVersion,
            "qwen-reference-quality-v11-steep-de-esser-mlx-audio-swift-0.1.3"
        )
    }

    func testSpeechSettingsPersistsAndClampsQwenDeEsserStrength() throws {
        var settings = SpeechSettings.default
        settings.qwenDeEsserStrengthDecibels = 9.5

        let decoded = try JSONDecoder().decode(
            SpeechSettings.self,
            from: try JSONEncoder().encode(settings)
        )

        XCTAssertEqual(decoded.qwenDeEsserStrengthDecibels, 9.5)
        settings.qwenDeEsserStrengthDecibels = 50
        XCTAssertEqual(
            settings.clamped.qwenDeEsserStrengthDecibels,
            SpeechSettings.maximumQwenDeEsserStrengthDecibels
        )
        settings.qwenDeEsserStrengthDecibels = -1
        XCTAssertEqual(settings.clamped.qwenDeEsserStrengthDecibels, 0)
    }

    func testLegacySpeechSettingsUsesCurrentDeEsserDefault() throws {
        let data = #"{"rateMultiplier":1.7,"volume":0.8,"pitchMultiplier":1.0}"#.data(using: .utf8)!

        let decoded = try JSONDecoder().decode(SpeechSettings.self, from: data)

        XCTAssertEqual(
            decoded.qwenDeEsserStrengthDecibels,
            SpeechSettings.defaultQwenDeEsserStrengthDecibels
        )
    }

    func testQwenPromptAudioLibraryCanonicalizesOnlySafeNearPromptText() {
        let canonical = QwenPromptAudioLibrary.canonicalText(
            for: #"Which of the following is the "best" next step?"#
        )

        XCTAssertEqual(
            canonical,
            QwenPromptAudioLibrary.canonicalText(for: "  which   of the following is the best next step ")
        )
        XCTAssertEqual(
            canonical,
            QwenPromptAudioLibrary.canonicalText(for: "Which of the following is the best next step.")
        )
        XCTAssertNotEqual(
            canonical,
            QwenPromptAudioLibrary.canonicalText(for: "Which of the following is the worst next step?")
        )
    }

    func testQwenPromptAudioLibraryPersistsVoiceContextsSeparatelyAndIgnoresRate() async throws {
        let root = temporaryRuntimeRoot()
        let library = QwenPromptAudioLibrary(rootDirectory: root.appendingPathComponent("prompt-library", isDirectory: true))
        let prompt = "Which of the following is most likely responsible for this finding?"
        let audio = root.appendingPathComponent("source.wav")
        try Self.writeTestWAV(to: audio)
        let fastContext = QwenPromptAudioLibraryContext(
            lane: .small,
            speaker: "Aiden",
            language: "English",
            useReferenceVoice: false,
            referenceAudioSignature: "",
            referenceTextHash: "",
            cachePipelineVersion: QwenRuntimeManager.cachePipelineVersion
        )
        let bestContext = QwenPromptAudioLibraryContext(
            lane: .best,
            speaker: "Aiden",
            language: "English",
            useReferenceVoice: false,
            referenceAudioSignature: "",
            referenceTextHash: "",
            cachePipelineVersion: QwenRuntimeManager.cachePipelineVersion
        )
        var strongerContext = fastContext
        strongerContext.qwenDeEsserStrengthDecibels = 10

        try await library.storeAudio(
            from: audio,
            text: prompt,
            context: fastContext,
            source: .narration,
            kind: .fullPrompt
        )

        let safeNear = "which of the following is most likely responsible for this finding"
        let fastMatch = try await library.lookup(text: safeNear, context: fastContext, kind: .fullPrompt)
        let bestMatch = try await library.lookup(text: safeNear, context: bestContext, kind: .fullPrompt)

        XCTAssertNotNil(fastMatch)
        XCTAssertNil(bestMatch)
        XCTAssertEqual(fastContext.contextHash, fastContext.contextHash)
        XCTAssertNotEqual(fastContext.contextHash, strongerContext.contextHash)
        XCTAssertFalse(fastContext.contextHash.contains("2.4"))
    }

    func testQwenPromptAudioLibraryManifestDoesNotPersistReferencePathOrTranscript() async throws {
        let root = temporaryRuntimeRoot()
        let library = QwenPromptAudioLibrary(rootDirectory: root.appendingPathComponent("prompt-library", isDirectory: true))
        let audio = root.appendingPathComponent("source.wav")
        try Self.writeTestWAV(to: audio)
        let privatePath = "/Users/example/private-reference.wav"
        let privateTranscript = "A private reference transcript should not be written into the prompt manifest."
        let context = QwenPromptAudioLibraryContext(
            lane: .small,
            speaker: QwenReferenceVoiceDefaults.voiceName,
            language: "English",
            useReferenceVoice: true,
            referenceAudioSignature: "private-reference.wav|bytes=123|mtime=456",
            referenceTextHash: QwenPromptAudioLibrary.hashText(privateTranscript),
            cachePipelineVersion: QwenRuntimeManager.cachePipelineVersion,
            referenceAudioPathForSynthesis: privatePath,
            referenceTextForSynthesis: privateTranscript
        )

        try await library.storeAudio(
            from: audio,
            text: "Which of the following is the most likely diagnosis?",
            context: context,
            source: .narration,
            kind: .fullPrompt
        )

        let manifestText = try String(
            contentsOf: root.appendingPathComponent("prompt-library/\(context.contextHash)/manifest.json"),
            encoding: .utf8
        )
        XCTAssertFalse(manifestText.contains(privatePath))
        XCTAssertFalse(manifestText.contains(privateTranscript))
    }

    func testQwenRuntimeRestoresPromptLibraryAudioAcrossNormalCacheClears() async throws {
        let root = temporaryRuntimeRoot()
        try makeFakeRuntimeReady(root: root, lane: .small)
        let recorder = CommandRecorder()
        let runner = RecordingRunner(recorder: recorder) { command in
            if let outputIndex = command.arguments.firstIndex(of: "--output") {
                try Self.writeTestWAV(to: URL(fileURLWithPath: command.arguments[outputIndex + 1]))
            }
            return QwenCommandResult(exitCode: 0, stdout: #"{"ok":true}"#, stderr: "")
        }
        let runtime = QwenRuntimeManager(runtimeRoot: root, runner: runner)
        let prompt = "Which of the following is the most likely cause of these findings?"
        let context = try await runtime.promptAudioLibraryContext(
            lane: .small,
            speaker: "Aiden",
            language: "English",
            useReferenceVoice: false,
            referenceAudioPath: nil,
            referenceText: nil
        )

        await runtime.learnPromptAudio(text: prompt, derivedPrefixTexts: [], context: context)
        let learnSynthCommandCount = await synthCommandCount(in: recorder)
        XCTAssertEqual(learnSynthCommandCount, 1)
        try await runtime.clearCache()

        let restored = try await runtime.restorePromptLibraryAudioIfAvailable(
            text: prompt,
            context: context,
            rateMultiplier: 2.4
        )
        let audio = try await runtime.synthesize(
            text: prompt,
            lane: .small,
            speaker: "Aiden",
            language: "English",
            rateMultiplier: 2.4,
            cachePolicy: .persistent
        )

        XCTAssertTrue(restored)
        XCTAssertTrue(audio.isFromCache)
        let finalSynthCommandCount = await synthCommandCount(in: recorder)
        XCTAssertEqual(finalSynthCommandCount, 1)

        try await runtime.clearPromptAudioLibrary()
        let restoredAfterClear = try await runtime.restorePromptLibraryAudioIfAvailable(
            text: prompt,
            context: context,
            rateMultiplier: 2.4
        )
        XCTAssertFalse(restoredAfterClear)
    }

    func testQwenRuntimePrewarmsCommonQuestionStartersWithoutLeakingTextToCommandOrLogs() async throws {
        let root = temporaryRuntimeRoot()
        try makeFakeRuntimeReady(root: root, lane: .small)
        let recorder = CommandRecorder()
        let runner = RecordingRunner(recorder: recorder) { command in
            if let outputIndex = command.arguments.firstIndex(of: "--output") {
                try Self.writeTestWAV(to: URL(fileURLWithPath: command.arguments[outputIndex + 1]))
            }
            return QwenCommandResult(exitCode: 0, stdout: #"{"ok":true}"#, stderr: "")
        }
        let runtime = QwenRuntimeManager(runtimeRoot: root, runner: runner)

        try await runtime.prewarmQuestionStarters(lane: .small, speaker: "Aiden")

        let commands = await recorder.commands
        let synthCommands = commands.filter { $0.redactedDescription.hasPrefix("qwen synthesize") }
        XCTAssertEqual(synthCommands.count, ReadPlanBuilder.commonQuestionStarterPhrases.count)
        for starter in ReadPlanBuilder.commonQuestionStarterPhrases {
            XCTAssertFalse(
                synthCommands.contains { command in
                    command.arguments.contains { $0.contains(starter) } || command.redactedDescription.contains(starter)
                })
        }

        let logText = try String(contentsOf: root.appendingPathComponent("logs/qwen-runtime.log"), encoding: .utf8)
        for starter in ReadPlanBuilder.commonQuestionStarterPhrases {
            XCTAssertFalse(logText.contains(starter))
        }
    }

    func testQwenClearCacheCanImmediatelyRewarmCommonQuestionStarters() async throws {
        let root = temporaryRuntimeRoot()
        try makeFakeRuntimeReady(root: root, lane: .small)
        try FileManager.default.createDirectory(at: root.appendingPathComponent("cache"), withIntermediateDirectories: true)
        try "old".write(to: root.appendingPathComponent("cache/stale.wav"), atomically: true, encoding: .utf8)
        let recorder = CommandRecorder()
        let runner = RecordingRunner(recorder: recorder) { command in
            if let outputIndex = command.arguments.firstIndex(of: "--output") {
                try Self.writeTestWAV(to: URL(fileURLWithPath: command.arguments[outputIndex + 1]))
            }
            return QwenCommandResult(exitCode: 0, stdout: #"{"ok":true}"#, stderr: "")
        }
        let runtime = QwenRuntimeManager(runtimeRoot: root, runner: runner)

        try await runtime.clearCacheAndPrewarmQuestionStarters(lane: .small, speaker: "Aiden")

        XCTAssertFalse(FileManager.default.fileExists(atPath: root.appendingPathComponent("cache/stale.wav").path))
        let commands = await recorder.commands
        XCTAssertEqual(
            commands.filter { $0.redactedDescription.hasPrefix("qwen synthesize") }.count,
            ReadPlanBuilder.commonQuestionStarterPhrases.count
        )
    }

    func testQwenRuntimeOnlyPersistsCommonQuestionStarterAudio() async throws {
        let root = temporaryRuntimeRoot()
        try makeFakeRuntimeReady(root: root, lane: .small)
        let recorder = CommandRecorder()
        let runner = RecordingRunner(recorder: recorder) { command in
            if let outputIndex = command.arguments.firstIndex(of: "--output") {
                try Self.writeTestWAV(to: URL(fileURLWithPath: command.arguments[outputIndex + 1]))
            }
            return QwenCommandResult(exitCode: 0, stdout: #"{"ok":true}"#, stderr: "")
        }
        let runtime = QwenRuntimeManager(runtimeRoot: root, runner: runner)
        let privateStem = "A synthetic private stem sentence should not become persistent audio."

        let privateFirst = try await runtime.synthesize(
            text: privateStem,
            lane: .small,
            speaker: "Aiden",
            language: "English",
            rateMultiplier: 2.4
        )
        let privateSecond = try await runtime.synthesize(
            text: privateStem,
            lane: .small,
            speaker: "Aiden",
            language: "English",
            rateMultiplier: 2.4
        )

        XCTAssertFalse(privateFirst.isFromCache)
        XCTAssertFalse(privateSecond.isFromCache)
        XCTAssertEqual(try cachedWAVs(in: root), [])
        let privateSynthCommandCount = await synthCommandCount(in: recorder)
        XCTAssertEqual(privateSynthCommandCount, 2)

        let starter = try XCTUnwrap(ReadPlanBuilder.commonQuestionStarterPhrases.first)
        let starterFirst = try await runtime.synthesize(
            text: starter,
            lane: .small,
            speaker: "Aiden",
            language: "English",
            rateMultiplier: 2.4
        )
        let starterSecond = try await runtime.synthesize(
            text: starter,
            lane: .small,
            speaker: "Aiden",
            language: "English",
            rateMultiplier: 2.4
        )

        XCTAssertFalse(starterFirst.isFromCache)
        XCTAssertTrue(starterSecond.isFromCache)
        XCTAssertEqual(try cachedWAVs(in: root).count, 1)
        let finalSynthCommandCount = await synthCommandCount(in: recorder)
        XCTAssertEqual(finalSynthCommandCount, 3)

        let taskTail = "this finding?"
        let tailFirst = try await runtime.synthesize(
            text: taskTail,
            lane: .small,
            speaker: "Aiden",
            language: "English",
            rateMultiplier: 2.4,
            cachePolicy: .persistent
        )
        let tailSecond = try await runtime.synthesize(
            text: taskTail,
            lane: .small,
            speaker: "Aiden",
            language: "English",
            rateMultiplier: 2.4,
            cachePolicy: .persistent
        )

        XCTAssertFalse(tailFirst.isFromCache)
        XCTAssertTrue(tailSecond.isFromCache)
        XCTAssertEqual(try cachedWAVs(in: root).count, 2)
        let synthCommandCountAfterTail = await synthCommandCount(in: recorder)
        XCTAssertEqual(synthCommandCountAfterTail, 4)
    }

    func testQwenRuntimeBatchUsesOneResidentHelperForUncachedItems() async throws {
        let root = temporaryRuntimeRoot()
        try Self.makeFakeModelReady(root: root, lane: .small)
        let processLog = root.appendingPathComponent("resident-processes.log")
        try writeFakeResidentPython(root: root, processLog: processLog)
        let runtime = QwenRuntimeManager(runtimeRoot: root)

        let requests = [
            QwenSynthesisRequest(
                text: "Synthetic resident item one.",
                lane: .small,
                speaker: "Aiden",
                language: "English",
                rateMultiplier: 2.4,
                cachePolicy: .transient,
                useReferenceVoice: false,
                referenceAudioPath: nil,
                referenceText: nil
            ),
            QwenSynthesisRequest(
                text: "Synthetic resident item two.",
                lane: .small,
                speaker: "Aiden",
                language: "English",
                rateMultiplier: 2.4,
                cachePolicy: .transient,
                useReferenceVoice: false,
                referenceAudioPath: nil,
                referenceText: nil
            ),
        ]

        let audios = try await runtime.synthesizeBatch(requests)

        XCTAssertEqual(audios.count, 2)
        XCTAssertTrue(audios.allSatisfy { !$0.isFromCache })
        let processStarts = try String(contentsOf: processLog, encoding: .utf8)
            .split(separator: "\n")
        XCTAssertEqual(processStarts.count, 1)
        let runtimeLog = try String(contentsOf: root.appendingPathComponent("logs/qwen-runtime.log"), encoding: .utf8)
        XCTAssertTrue(runtimeLog.contains("start qwen serve batch count=2"))
        XCTAssertFalse(runtimeLog.contains("Synthetic resident item one."))
        XCTAssertFalse(runtimeLog.contains("Synthetic resident item two."))
    }

    func testQwenRuntimeChunksLargeResidentHelperBatches() async throws {
        let root = temporaryRuntimeRoot()
        try Self.makeFakeModelReady(root: root, lane: .small)
        let processLog = root.appendingPathComponent("resident-processes.log")
        try writeFakeResidentPython(root: root, processLog: processLog)
        let runtime = QwenRuntimeManager(runtimeRoot: root)
        let requests = (0..<9).map { index in
            QwenSynthesisRequest(
                text: "Synthetic resident item \(index).",
                lane: .small,
                speaker: "Ryan",
                language: "English",
                rateMultiplier: 2.4,
                cachePolicy: .transient,
                useReferenceVoice: false,
                referenceAudioPath: nil,
                referenceText: nil
            )
        }

        let audios = try await runtime.synthesizeBatch(requests)

        XCTAssertEqual(audios.count, 9)
        let processStarts = try String(contentsOf: processLog, encoding: .utf8)
            .split(separator: "\n")
        XCTAssertEqual(processStarts.count, 1)
        let runtimeLog = try String(contentsOf: root.appendingPathComponent("logs/qwen-runtime.log"), encoding: .utf8)
        XCTAssertTrue(runtimeLog.contains("start qwen serve batch count=4"))
        XCTAssertTrue(runtimeLog.contains("start qwen serve batch count=1"))
        XCTAssertFalse(runtimeLog.contains("start qwen serve batch count=9"))
    }

    func testQwenClearCacheRecordsClearTime() async throws {
        let root = temporaryRuntimeRoot()
        let runtime = QwenRuntimeManager(runtimeRoot: root)

        try await runtime.clearCache()

        let state = try cacheMaintenanceState(in: root)
        XCTAssertLessThan(abs(state.lastClearedAt.timeIntervalSinceNow), 5)
    }

    func testQwenRuntimeClearsCacheWhenMaintenanceRecordIsExpired() async throws {
        let root = temporaryRuntimeRoot()
        try makeFakeRuntimeReady(root: root, lane: .small)
        let cache = root.appendingPathComponent("cache", isDirectory: true)
        try FileManager.default.createDirectory(at: cache, withIntermediateDirectories: true)
        try "old".write(to: cache.appendingPathComponent("stale.wav"), atomically: true, encoding: .utf8)
        try writeCacheMaintenanceState(
            lastClearedAt: Date(timeIntervalSinceNow: -QwenRuntimeManager.cacheRetentionInterval - 60),
            in: root
        )
        let recorder = CommandRecorder()
        let runner = RecordingRunner(recorder: recorder) { command in
            if let outputIndex = command.arguments.firstIndex(of: "--output") {
                try Self.writeTestWAV(to: URL(fileURLWithPath: command.arguments[outputIndex + 1]))
            }
            return QwenCommandResult(exitCode: 0, stdout: #"{"ok":true}"#, stderr: "")
        }
        let runtime = QwenRuntimeManager(runtimeRoot: root, runner: runner)

        _ = try await runtime.synthesize(
            text: "A replayable question stem.",
            lane: .small,
            speaker: "Aiden",
            language: "English",
            rateMultiplier: 2.4,
            cachePolicy: .persistent
        )

        XCTAssertFalse(FileManager.default.fileExists(atPath: cache.appendingPathComponent("stale.wav").path))
        XCTAssertEqual(try cachedWAVs(in: root).count, 1)
        let state = try cacheMaintenanceState(in: root)
        XCTAssertLessThan(abs(state.lastClearedAt.timeIntervalSinceNow), 5)
    }

    func testQwenRuntimeClearsGeneratedArtifactsWhenDiskSpaceIsLow() async throws {
        let root = temporaryRuntimeRoot()
        try makeFakeRuntimeReady(root: root, lane: .small)
        let cache = root.appendingPathComponent("cache", isDirectory: true)
        let tmp = root.appendingPathComponent("tmp", isDirectory: true)
        let logs = root.appendingPathComponent("logs", isDirectory: true)
        try FileManager.default.createDirectory(at: cache, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: tmp, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: logs, withIntermediateDirectories: true)
        try "old".write(to: cache.appendingPathComponent("stale.wav"), atomically: true, encoding: .utf8)
        try "scratch".write(to: tmp.appendingPathComponent("stale.txt"), atomically: true, encoding: .utf8)
        try "log".write(to: logs.appendingPathComponent("stale.log"), atomically: true, encoding: .utf8)
        try writeCacheMaintenanceState(lastClearedAt: Date(), in: root)
        let capacity = CapacitySequence([
            QwenRuntimeManager.lowDiskCacheClearThresholdBytes - 1,
            QwenRuntimeManager.lowDiskCacheClearThresholdBytes + 1,
        ])
        let recorder = CommandRecorder()
        let runner = RecordingRunner(recorder: recorder) { command in
            if let outputIndex = command.arguments.firstIndex(of: "--output") {
                try Self.writeTestWAV(to: URL(fileURLWithPath: command.arguments[outputIndex + 1]))
            }
            return QwenCommandResult(exitCode: 0, stdout: #"{"ok":true}"#, stderr: "")
        }
        let runtime = QwenRuntimeManager(
            runtimeRoot: root,
            runner: runner,
            availableCapacityProvider: capacity.next
        )

        _ = try await runtime.synthesize(
            text: "A replayable question stem.",
            lane: .small,
            speaker: "Aiden",
            language: "English",
            rateMultiplier: 2.4,
            cachePolicy: .persistent
        )

        XCTAssertFalse(FileManager.default.fileExists(atPath: cache.appendingPathComponent("stale.wav").path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: tmp.appendingPathComponent("stale.txt").path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: logs.appendingPathComponent("stale.log").path))
        XCTAssertEqual(try cachedWAVs(in: root).count, 1)
        let synthCommandCount = await synthCommandCount(in: recorder)
        XCTAssertEqual(synthCommandCount, 1)
    }

    func testQwenMeteredLevelsAreNormalizedAndClamped() {
        let silent = FakeAudioMeter(powers: [-160])
        let speech = FakeAudioMeter(powers: [-24, -12])
        let loud = FakeAudioMeter(powers: [0])

        XCTAssertEqual(QwenAudioPlayback.normalizedLevel(from: silent), 0, accuracy: 0.0001)
        XCTAssertGreaterThan(QwenAudioPlayback.normalizedLevel(from: speech), 0)
        XCTAssertLessThanOrEqual(QwenAudioPlayback.normalizedLevel(from: speech), 1)
        XCTAssertEqual(QwenAudioPlayback.normalizedLevel(from: loud), 1, accuracy: 0.0001)
    }

    func testQwenEstimatedPlaybackLevelsFollowAudioWindows() throws {
        let format = try XCTUnwrap(AVAudioFormat(standardFormatWithSampleRate: 100, channels: 1))
        let buffer = try XCTUnwrap(AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 100))
        buffer.frameLength = 100
        let channel = try XCTUnwrap(buffer.floatChannelData?[0])
        for frame in 0..<50 {
            channel[frame] = 0.01
        }
        for frame in 50..<100 {
            channel[frame] = 0.10
        }

        let levels = QwenAudioPlayback.estimatedLevels(from: buffer, windowSeconds: 0.5)

        XCTAssertEqual(levels.count, 2)
        XCTAssertGreaterThan(levels[1], levels[0])
    }

    func testQwenEstimatedVisualizationFramesSeparateLowAndHighFrequencyEnergy() throws {
        let sampleRate = 8_192.0
        let format = try XCTUnwrap(AVAudioFormat(standardFormatWithSampleRate: sampleRate, channels: 1))
        let buffer = try XCTUnwrap(AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 819))
        buffer.frameLength = 819
        let channel = try XCTUnwrap(buffer.floatChannelData?[0])

        for frame in 0..<409 {
            let phase = 2 * Double.pi * 180.0 * Double(frame) / sampleRate
            channel[frame] = Float(sin(phase) * 0.55)
        }
        for frame in 409..<819 {
            let phase = 2 * Double.pi * 2_400.0 * Double(frame) / sampleRate
            channel[frame] = Float(sin(phase) * 0.55)
        }

        let frames = QwenAudioPlayback.estimatedVisualizationFrames(
            from: buffer,
            windowSeconds: 0.05,
            barCount: 8
        )

        XCTAssertEqual(frames.count, 3)
        let lowDominantIndex = try XCTUnwrap(frames[0].barLevels.indices.max { frames[0].barLevels[$0] < frames[0].barLevels[$1] })
        let highDominantIndex = try XCTUnwrap(frames[1].barLevels.indices.max { frames[1].barLevels[$0] < frames[1].barLevels[$1] })
        XCTAssertLessThan(lowDominantIndex, 3)
        XCTAssertGreaterThan(highDominantIndex, 4)
        XCTAssertGreaterThan(frames[0].level, 0.5)
        XCTAssertGreaterThan(frames[1].level, 0.5)
        XCTAssertNotEqual(frames[0].barLevels, frames[1].barLevels)
    }

    func testQwenDurationOnlyVisualizationFramesMoveAtSameLevel() {
        let first = QwenAudioPlayback.durationOnlyVisualizationFrame(
            elapsedSeconds: 0,
            chunkIndex: 0,
            level: 0.35
        )
        let next = QwenAudioPlayback.durationOnlyVisualizationFrame(
            elapsedSeconds: 0.10,
            chunkIndex: 0,
            level: 0.35
        )

        XCTAssertEqual(first.level, next.level, accuracy: 0.0001)
        XCTAssertNotEqual(first.barLevels, next.barLevels)
        XCTAssertNotEqual(first.brightness, next.brightness)
    }

    func testQwenQueuedPlaybackUsesFastSpectrumVisualizationForLargeBatches() {
        XCTAssertFalse(
            QwenAudioPlayback.usesFastSpectrumVisualization(
                itemCount: 3,
                totalDurationSeconds: 6.0
            ))
        XCTAssertTrue(
            QwenAudioPlayback.usesFastSpectrumVisualization(
                itemCount: 4,
                totalDurationSeconds: 6.0
            ))
        XCTAssertTrue(
            QwenAudioPlayback.usesFastSpectrumVisualization(
                itemCount: 2,
                totalDurationSeconds: 14.0
            ))
    }

    func testQwenCompleteFilePlaybackClampsRateToAVAudioPlayerSupportedRange() {
        XCTAssertEqual(QwenAudioPlayback.completeFilePlaybackRate(for: 0.25), 0.5)
        XCTAssertEqual(QwenAudioPlayback.completeFilePlaybackRate(for: 1.7), 1.7)
        XCTAssertEqual(QwenAudioPlayback.completeFilePlaybackRate(for: 2.4), 2.0)
    }

    func testQwenFastSpectrumVisualizationFramesSeparateLowAndHighFrequencyEnergy() throws {
        let sampleRate = 8_192.0
        let format = try XCTUnwrap(AVAudioFormat(standardFormatWithSampleRate: sampleRate, channels: 1))
        let framesPerWindow = Int(sampleRate * 0.05)
        let buffer = try XCTUnwrap(AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(framesPerWindow * 8)))
        buffer.frameLength = buffer.frameCapacity
        let channel = try XCTUnwrap(buffer.floatChannelData?[0])

        for frame in 0..<(framesPerWindow * 3) {
            let phase = 2 * Double.pi * 180.0 * Double(frame) / sampleRate
            channel[frame] = Float(sin(phase) * 0.55)
        }
        for frame in (framesPerWindow * 3)..<Int(buffer.frameLength) {
            let phase = 2 * Double.pi * 2_400.0 * Double(frame) / sampleRate
            channel[frame] = Float(sin(phase) * 0.55)
        }

        let frames = QwenAudioPlayback.estimatedFastSpectrumVisualizationFrames(
            from: buffer,
            windowSeconds: 0.05,
            barCount: 8
        )

        XCTAssertEqual(frames.count, 8)
        let lowDominantIndex = try XCTUnwrap(frames[1].barLevels.indices.max { frames[1].barLevels[$0] < frames[1].barLevels[$1] })
        let highDominantIndex = try XCTUnwrap(frames[6].barLevels.indices.max { frames[6].barLevels[$0] < frames[6].barLevels[$1] })
        XCTAssertLessThan(lowDominantIndex, 3)
        XCTAssertGreaterThan(highDominantIndex, 4)
        XCTAssertNotEqual(frames[0].barLevels, frames[1].barLevels)
    }

    func testQwenFastSpectrumVisualizationFramesSmoothAbruptLevelChanges() throws {
        let sampleRate = 24_000.0
        let format = try XCTUnwrap(AVAudioFormat(standardFormatWithSampleRate: sampleRate, channels: 1))
        let buffer = try XCTUnwrap(AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(sampleRate * 0.5)))
        buffer.frameLength = buffer.frameCapacity
        let channel = try XCTUnwrap(buffer.floatChannelData?[0])
        let framesPerWindow = Int(sampleRate / 30.0)

        for frame in 0..<Int(buffer.frameLength) {
            let windowIndex = frame / framesPerWindow
            let amplitude = windowIndex.isMultiple(of: 2) ? 0.015 : 0.16
            let phase = 2 * Double.pi * 440.0 * Double(frame) / sampleRate
            channel[frame] = Float(sin(phase) * amplitude)
        }

        let frames = QwenAudioPlayback.estimatedFastSpectrumVisualizationFrames(from: buffer)
        let maxBarDelta =
            zip(frames, frames.dropFirst()).map { previous, current in
                zip(previous.barLevels, current.barLevels).map { abs($0 - $1) }.max() ?? 0
            }.max() ?? 0

        XCTAssertGreaterThan(frames.map(\.level).max() ?? 0, 0.70)
        XCTAssertLessThan(maxBarDelta, 0.45)
    }

    func testQwenFastSpectrumVisualizationUsesHighTemporalResolutionForLoudnessPeaks() throws {
        let sampleRate = 24_000.0
        let format = try XCTUnwrap(AVAudioFormat(standardFormatWithSampleRate: sampleRate, channels: 1))
        let buffer = try XCTUnwrap(AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(sampleRate * 0.2)))
        buffer.frameLength = buffer.frameCapacity
        let channel = try XCTUnwrap(buffer.floatChannelData?[0])

        for frame in 0..<Int(buffer.frameLength) {
            let time = Double(frame) / sampleRate
            let isConsonantPeak = (0.085...0.105).contains(time)
            let amplitude = isConsonantPeak ? 0.16 : 0.018
            let phase = 2 * Double.pi * 1_900.0 * time
            channel[frame] = Float(sin(phase) * amplitude)
        }

        let frames = QwenAudioPlayback.estimatedFastSpectrumVisualizationFrames(from: buffer)
        let peakIndex = try XCTUnwrap(frames.indices.max { frames[$0].level < frames[$1].level })
        let expectedPeakIndex = Int(0.085 / (1.0 / 60.0))

        XCTAssertGreaterThanOrEqual(frames.count, 10)
        XCTAssertLessThanOrEqual(abs(peakIndex - expectedPeakIndex), 2)
    }

    func testQwenMeteredVisualizationDecaysAfterFinalFrameInsteadOfFreezing() throws {
        let loudFrame = SpeechPlaybackVisualizationFrame(
            level: 0.9,
            barLevels: Array(repeating: 0.9, count: 16)
        )

        let firstOverrun = try XCTUnwrap(
            QwenAudioPlayback.meteredVisualizationFrame(
                meterFrames: [[loudFrame]],
                durations: [0.03],
                rate: 1.0,
                elapsedSeconds: 0.08
            ))
        let laterOverrun = try XCTUnwrap(
            QwenAudioPlayback.meteredVisualizationFrame(
                meterFrames: [[loudFrame]],
                durations: [0.03],
                rate: 1.0,
                elapsedSeconds: 0.16
            ))

        XCTAssertLessThan(firstOverrun.level, loudFrame.level)
        XCTAssertLessThan(laterOverrun.level, firstOverrun.level)
        XCTAssertLessThan(laterOverrun.barLevels.max() ?? 1, 0.3)
    }

    func testQwenMeteredVisualizationUsesAudioClockWhenPlaybackClockDrifts() throws {
        let quietFrame = SpeechPlaybackVisualizationFrame(
            level: 0.1,
            barLevels: Array(repeating: 0.1, count: 16)
        )
        let peakFrame = SpeechPlaybackVisualizationFrame(
            level: 0.9,
            barLevels: Array(repeating: 0.9, count: 16)
        )

        let frame = try XCTUnwrap(
            QwenAudioPlayback.meteredVisualizationFrame(
                meterFrames: [[quietFrame, peakFrame]],
                durations: [0.20],
                rate: 1.0,
                audioElapsedSeconds: 0.018,
                playbackElapsedSeconds: 0.002
            ))

        XCTAssertEqual(frame, peakFrame)
    }

    func testQwenMeteredVisualizationDecaysWhenAudioClockStopsAtFinalFrame() throws {
        let loudFrame = SpeechPlaybackVisualizationFrame(
            level: 0.9,
            barLevels: Array(repeating: 0.9, count: 16)
        )

        let frame = try XCTUnwrap(
            QwenAudioPlayback.meteredVisualizationFrame(
                meterFrames: [[loudFrame]],
                durations: [0.03],
                rate: 1.0,
                audioElapsedSeconds: 0.029,
                playbackElapsedSeconds: 0.16
            ))

        XCTAssertLessThan(frame.level, 0.3)
        XCTAssertLessThan(frame.barLevels.max() ?? 1, 0.3)
    }

    func testQwenMeteredVisualizationAdvancesToNextChunkWithoutBoundaryFreeze() throws {
        let firstFrame = SpeechPlaybackVisualizationFrame(
            level: 0.8,
            barLevels: Array(repeating: 0.2, count: 16)
        )
        let nextFrame = SpeechPlaybackVisualizationFrame(
            level: 0.4,
            barLevels: Array(repeating: 0.7, count: 16)
        )

        let frame = try XCTUnwrap(
            QwenAudioPlayback.meteredVisualizationFrame(
                meterFrames: [[firstFrame], [nextFrame]],
                durations: [0.04, 0.04],
                rate: 1.0,
                elapsedSeconds: 0.045
            ))

        XCTAssertEqual(frame, nextFrame)
    }

    func testQwenPlaybackUsesPitchPreservingRateProcessor() throws {
        let processor = QwenAudioPlayback.makeRateProcessor(rateMultiplier: 2.4)

        let timePitch = try XCTUnwrap(processor as? AVAudioUnitTimePitch)
        XCTAssertFalse(processor is AVAudioUnitVarispeed)
        XCTAssertEqual(timePitch.rate, 2.4, accuracy: 0.0001)
        XCTAssertEqual(timePitch.pitch, 0, accuracy: 0.0001)
        XCTAssertEqual(timePitch.overlap, 32, accuracy: 0.0001)
    }

    func testQwenPlaybackRoutesRateProcessorThroughMainMixer() throws {
        let source = try String(
            contentsOf: URL(fileURLWithPath: #filePath)
                .deletingLastPathComponent()
                .deletingLastPathComponent()
                .deletingLastPathComponent()
                .appendingPathComponent("Sources/SalientCore/Services/Speech/QwenAudioPlayback.swift"),
            encoding: .utf8
        )

        XCTAssertTrue(source.contains("to: engine.mainMixerNode"))
        XCTAssertFalse(source.contains("to: engine.outputNode"))
    }

    @MainActor
    func testQwenAudioPlaybackPublishesFrameBeforeAudioStart() async throws {
        let root = temporaryRuntimeRoot()
        let audioURL = root.appendingPathComponent("synthetic.wav")
        try Self.writeTestWAV(to: audioURL)
        let playback = QwenAudioPlayback()
        let eventLog = EventLog()
        let sink = RecordingVisualizationSink(eventLog: eventLog)
        playback.visualizationSink = sink
        let item = SpeechPlaybackItem(id: "synthetic", segmentID: "synthetic", text: "Synthetic playback.")
        let prepared = QwenPreparedPlaybackItem(
            index: 0,
            item: item,
            audio: QwenPreparedAudio(url: audioURL, durationSeconds: 0.1, isFromCache: false)
        )

        try await playback.play(
            [prepared],
            rateMultiplier: 1.0,
            volume: 0,
            onStartItem: { _ in eventLog.events.append("item-start") },
            onBufferEnqueue: { _ in eventLog.events.append("buffer-enqueue") },
            onRenderStart: { eventLog.events.append("render-start") },
            onFinish: { eventLog.events.append("finish") },
            onItemEnd: { _ in eventLog.events.append("item-end") }
        )

        XCTAssertTrue(eventLog.events.contains("hud-audio-start"))
        XCTAssertTrue(eventLog.events.contains("hud-level"))
        XCTAssertLessThan(
            try index(of: "hud-level", in: eventLog.events),
            try index(of: "hud-audio-start", in: eventLog.events),
            eventLog.events.joined(separator: ",")
        )
    }

    @MainActor
    func testQwenAudioPlaybackDoesNotWaitForVisualizationAnalysisBeforeRender() async throws {
        let root = temporaryRuntimeRoot()
        let audioURL = root.appendingPathComponent("slow-visualization-analysis.wav")
        try Self.writeTestWAV(to: audioURL)
        let analysisCompleted = ThreadSafeFlag()
        let allowAnalysisToFinish = DispatchSemaphore(value: 0)
        defer { allowAnalysisToFinish.signal() }
        let playback = QwenAudioPlayback { _ in
            _ = allowAnalysisToFinish.wait(timeout: .now() + 2.0)
            analysisCompleted.set()
            return [.levelOnly(0.5)]
        }
        let eventLog = EventLog()
        let sink = RecordingVisualizationSink(eventLog: eventLog)
        playback.visualizationSink = sink
        let prepared = QwenPreparedPlaybackItem(
            index: 0,
            item: SpeechPlaybackItem(id: "slow-analysis", segmentID: "slow-analysis", text: "Synthetic playback."),
            audio: QwenPreparedAudio(url: audioURL, durationSeconds: 0.1, isFromCache: false)
        )
        var analysisHadFinishedAtRender = true

        try await playback.play(
            [prepared],
            rateMultiplier: 1.0,
            volume: 0,
            onStartItem: { _ in },
            onBufferEnqueue: { _ in },
            onRenderStart: {
                analysisHadFinishedAtRender = analysisCompleted.value
                allowAnalysisToFinish.signal()
            },
            onFinish: {},
            onItemEnd: { _ in }
        )

        XCTAssertFalse(analysisHadFinishedAtRender)
        XCTAssertTrue(eventLog.events.contains("hud-level"))
        XCTAssertLessThan(
            try index(of: "hud-level", in: eventLog.events),
            try index(of: "hud-audio-start", in: eventLog.events),
            eventLog.events.joined(separator: ",")
        )
        for _ in 0..<100 where !analysisCompleted.value {
            try? await Task.sleep(for: .milliseconds(10))
        }
        XCTAssertTrue(analysisCompleted.value)
    }

    @MainActor
    func testQwenQueuedPlaybackDoesNotWaitForSlowStartItemBeforeRenderStart() async throws {
        let root = temporaryRuntimeRoot()
        let audioURL = root.appendingPathComponent("slow-highlight.wav")
        try Self.writeTestWAV(to: audioURL)
        let playback = QwenAudioPlayback()
        let eventLog = EventLog()
        let item = SpeechPlaybackItem(id: "slow-highlight", segmentID: "slow-highlight", text: "Synthetic playback.")
        let prepared = QwenPreparedPlaybackItem(
            index: 0,
            item: item,
            audio: QwenPreparedAudio(url: audioURL, durationSeconds: 0.1, isFromCache: false)
        )

        try await playback.play(
            [prepared],
            rateMultiplier: 1.0,
            volume: 0,
            onStartItem: { _ in
                eventLog.events.append("will-start")
                try? await Task.sleep(nanoseconds: 300_000_000)
                eventLog.events.append("will-end")
            },
            onBufferEnqueue: { _ in eventLog.events.append("buffer-enqueue") },
            onRenderStart: { eventLog.events.append("render-start") },
            onFinish: { eventLog.events.append("finish") },
            onItemEnd: { _ in eventLog.events.append("item-end") }
        )
        try await Task.sleep(nanoseconds: 100_000_000)

        XCTAssertLessThan(
            try index(of: "render-start", in: eventLog.events),
            try index(of: "will-end", in: eventLog.events),
            eventLog.events.joined(separator: ",")
        )
        XCTAssertLessThan(
            try index(of: "will-end", in: eventLog.events),
            try index(of: "item-end", in: eventLog.events),
            eventLog.events.joined(separator: ",")
        )
    }

    @MainActor
    func testQwenCompleteFilePlaybackStopCancelsWithoutStartingNextItemOrFinishing() async throws {
        let root = temporaryRuntimeRoot()
        let firstURL = root.appendingPathComponent("stop-first.wav")
        let secondURL = root.appendingPathComponent("stop-second.wav")
        try Self.writeConstantWAV(to: firstURL, durationSeconds: 0.6, amplitude: 0.1)
        try Self.writeConstantWAV(to: secondURL, durationSeconds: 0.6, amplitude: 0.1)
        let playback = QwenAudioPlayback()
        defer { playback.stop() }
        let eventLog = EventLog()
        let visualizationSink = RecordingVisualizationSink(eventLog: eventLog)
        playback.visualizationSink = visualizationSink
        let prepared = [
            QwenPreparedPlaybackItem(
                index: 0,
                item: SpeechPlaybackItem(id: "first", segmentID: "first", text: "First item."),
                audio: QwenPreparedAudio(url: firstURL, durationSeconds: 0.6, isFromCache: false)
            ),
            QwenPreparedPlaybackItem(
                index: 1,
                item: SpeechPlaybackItem(id: "second", segmentID: "second", text: "Second item."),
                audio: QwenPreparedAudio(url: secondURL, durationSeconds: 0.6, isFromCache: false)
            ),
        ]

        let playbackTask = Task { @MainActor in
            do {
                try await playback.play(
                    prepared,
                    rateMultiplier: 1.0,
                    volume: 0,
                    onStartItem: { item in eventLog.events.append("item-start:\(item.id)") },
                    onBufferEnqueue: { _ in },
                    onRenderStart: {},
                    onFinish: { eventLog.events.append("finish") },
                    onItemEnd: { item in eventLog.events.append("item-end:\(item.id)") }
                )
                return false
            } catch is CancellationError {
                return true
            } catch {
                return false
            }
        }

        for _ in 0..<200 where !eventLog.events.contains("hud-audio-start") {
            try await Task.sleep(for: .milliseconds(5))
        }
        XCTAssertTrue(eventLog.events.contains("hud-audio-start"), eventLog.events.joined(separator: ","))

        playback.stop()

        let wasCancelled = await playbackTask.value
        XCTAssertTrue(wasCancelled)
        try await Task.sleep(for: .milliseconds(100))
        XCTAssertFalse(eventLog.events.contains("item-start:second"), eventLog.events.joined(separator: ","))
        XCTAssertFalse(eventLog.events.contains("item-end:first"), eventLog.events.joined(separator: ","))
        XCTAssertFalse(eventLog.events.contains("finish"), eventLog.events.joined(separator: ","))
    }

    @MainActor
    func testQwenQueuedPlaybackStartsNextItemBeforeWaitingForPreviousFinishCallback() async throws {
        let root = temporaryRuntimeRoot()
        let firstURL = root.appendingPathComponent("first-boundary.wav")
        let secondURL = root.appendingPathComponent("second-boundary.wav")
        try Self.writeConstantWAV(to: firstURL, durationSeconds: 0.08, amplitude: 0.1)
        try Self.writeConstantWAV(to: secondURL, durationSeconds: 0.08, amplitude: 0.1)
        let playback = QwenAudioPlayback()
        let eventLog = EventLog()
        let prepared = [
            QwenPreparedPlaybackItem(
                index: 0,
                item: SpeechPlaybackItem(id: "first", segmentID: "first", text: "First item."),
                audio: QwenPreparedAudio(url: firstURL, durationSeconds: 0.08, isFromCache: false)
            ),
            QwenPreparedPlaybackItem(
                index: 1,
                item: SpeechPlaybackItem(id: "second", segmentID: "second", text: "Second item."),
                audio: QwenPreparedAudio(url: secondURL, durationSeconds: 0.08, isFromCache: false)
            ),
        ]

        try await playback.play(
            prepared,
            rateMultiplier: 1.0,
            volume: 0,
            onStartItem: { item in eventLog.events.append("item-start:\(item.id)") },
            onBufferEnqueue: { _ in },
            onRenderStart: {},
            onFinish: {},
            onItemEnd: { item in
                eventLog.events.append("item-end-begin:\(item.id)")
                if item.id == "first" {
                    try? await Task.sleep(nanoseconds: 250_000_000)
                }
                eventLog.events.append("item-end-done:\(item.id)")
            }
        )
        try await Task.sleep(nanoseconds: 300_000_000)

        XCTAssertLessThan(
            try index(of: "item-start:second", in: eventLog.events),
            try index(of: "item-end-done:first", in: eventLog.events),
            eventLog.events.joined(separator: ",")
        )
    }

    @MainActor
    func testQwenQueuedPlaybackVisualizationFramesFollowAudioEnergyAtFastRate() async throws {
        let root = temporaryRuntimeRoot()
        let audioURL = root.appendingPathComponent("stepped-energy.wav")
        try Self.writeSteppedEnergyWAV(to: audioURL)
        let playback = QwenAudioPlayback()
        let eventLog = EventLog()
        let sink = RecordingVisualizationSink(eventLog: eventLog)
        playback.visualizationSink = sink
        let item = SpeechPlaybackItem(id: "stepped-energy", segmentID: "stepped-energy", text: "Synthetic playback.")
        let prepared = QwenPreparedPlaybackItem(
            index: 0,
            item: item,
            audio: QwenPreparedAudio(url: audioURL, durationSeconds: 0.7, isFromCache: false)
        )

        try await playback.play(
            [prepared],
            rateMultiplier: 2.4,
            volume: 0,
            onStartItem: { _ in },
            onBufferEnqueue: { _ in },
            onRenderStart: {},
            onFinish: {},
            onItemEnd: { _ in }
        )

        let levels = sink.frames.map(\.level)
        XCTAssertGreaterThanOrEqual(levels.count, 4)
        XCTAssertLessThan(levels.min() ?? 1, 0.25)
        XCTAssertGreaterThan(levels.max() ?? 0, 0.70)
    }

    @MainActor
    func testQwenLargeQueuedPlaybackVisualizationFramesStillFollowAudioEnergy() async throws {
        let root = temporaryRuntimeRoot()
        let quietOne = root.appendingPathComponent("quiet-one.wav")
        let loudOne = root.appendingPathComponent("loud-one.wav")
        let quietTwo = root.appendingPathComponent("quiet-two.wav")
        let loudTwo = root.appendingPathComponent("loud-two.wav")
        try Self.writeConstantWAV(to: quietOne, durationSeconds: 0.2, amplitude: 0.006, frequency: 180)
        try Self.writeConstantWAV(to: loudOne, durationSeconds: 0.2, amplitude: 0.14, frequency: 2_400)
        try Self.writeConstantWAV(to: quietTwo, durationSeconds: 0.2, amplitude: 0.006, frequency: 180)
        try Self.writeConstantWAV(to: loudTwo, durationSeconds: 0.2, amplitude: 0.14, frequency: 2_400)
        let playback = QwenAudioPlayback()
        let eventLog = EventLog()
        let sink = RecordingVisualizationSink(eventLog: eventLog)
        playback.visualizationSink = sink
        let urls = [quietOne, loudOne, quietTwo, loudTwo]
        let prepared = urls.enumerated().map { index, url in
            let item = SpeechPlaybackItem(id: "item-\(index)", segmentID: "item-\(index)", text: "Synthetic playback.")
            return QwenPreparedPlaybackItem(
                index: index,
                item: item,
                audio: QwenPreparedAudio(url: url, durationSeconds: 0.2, isFromCache: false)
            )
        }

        try await playback.play(
            prepared,
            rateMultiplier: 1.0,
            volume: 0,
            onStartItem: { _ in },
            onBufferEnqueue: { _ in },
            onRenderStart: {},
            onFinish: {},
            onItemEnd: { _ in }
        )

        let levels = sink.frames.map(\.level)
        let dominantIndices = sink.frames
            .filter { $0.level > 0.02 }
            .compactMap { frame in
                frame.barLevels.indices.max { frame.barLevels[$0] < frame.barLevels[$1] }
            }
        XCTAssertGreaterThanOrEqual(levels.count, 8)
        XCTAssertLessThan(levels.min() ?? 1, 0.15)
        XCTAssertGreaterThan(levels.max() ?? 0, 0.70)
        XCTAssertGreaterThan(Set(dominantIndices).count, 1)
    }

    @MainActor
    func testQwenStreamingPlaybackVisualizationFramesFollowPCMFrequencyEnergy() async throws {
        let playback = QwenAudioPlayback()
        let eventLog = EventLog()
        let sink = RecordingVisualizationSink(eventLog: eventLog)
        playback.visualizationSink = sink
        let item = SpeechPlaybackItem(id: "streamed", segmentID: "streamed", text: "Synthetic playback.")
        let chunks = AsyncThrowingStream<QwenStreamingAudioChunk, Error> { continuation in
            continuation.yield(
                Self.streamingPCMChunk(
                    sequenceIndex: 0,
                    frequency: 180,
                    durationSeconds: 0.18,
                    isFinal: false
                ))
            continuation.yield(
                Self.streamingPCMChunk(
                    sequenceIndex: 1,
                    frequency: 2_400,
                    durationSeconds: 0.18,
                    isFinal: true
                ))
            continuation.finish()
        }

        try await playback.playStream(
            item: item,
            chunks: chunks,
            rateMultiplier: 1.0,
            volume: 0,
            minimumBufferedPlaybackSeconds: 0.10,
            targetRunwayPlaybackSeconds: 0.10,
            onStartItem: { _ in },
            onBufferEnqueue: { _ in },
            onRenderStart: {},
            onFinish: {},
            onItemEnd: { _ in }
        )

        let energeticFrames = sink.frames.filter { $0.level > 0.05 }
        XCTAssertGreaterThanOrEqual(energeticFrames.count, 4)
        let firstDominantIndex = try XCTUnwrap(
            energeticFrames.first?.barLevels.indices.max {
                energeticFrames.first!.barLevels[$0] < energeticFrames.first!.barLevels[$1]
            }
        )
        let lastDominantIndex = try XCTUnwrap(
            energeticFrames.last?.barLevels.indices.max {
                energeticFrames.last!.barLevels[$0] < energeticFrames.last!.barLevels[$1]
            }
        )
        XCTAssertLessThan(firstDominantIndex, 4)
        XCTAssertGreaterThan(lastDominantIndex, 8)
    }

    @MainActor
    func testQwenQueuedPlaybackSignalsAudioStopAfterFrames() async throws {
        let root = temporaryRuntimeRoot()
        let audioURL = root.appendingPathComponent("stop-signal.wav")
        try Self.writeConstantWAV(to: audioURL, durationSeconds: 0.15, amplitude: 0.12)
        let playback = QwenAudioPlayback()
        let eventLog = EventLog()
        let sink = RecordingVisualizationSink(eventLog: eventLog)
        playback.visualizationSink = sink
        let item = SpeechPlaybackItem(id: "stop-signal", segmentID: "stop-signal", text: "Synthetic playback.")
        let prepared = QwenPreparedPlaybackItem(
            index: 0,
            item: item,
            audio: QwenPreparedAudio(url: audioURL, durationSeconds: 0.15, isFromCache: false)
        )

        try await playback.play(
            [prepared],
            rateMultiplier: 1.0,
            volume: 0,
            onStartItem: { _ in },
            onBufferEnqueue: { _ in },
            onRenderStart: {},
            onFinish: {},
            onItemEnd: { _ in }
        )

        XCTAssertFalse(eventLog.events.contains("hud-audio-stop"))
        playback.finishNarration()
        XCTAssertEqual(eventLog.events.filter { $0 == "hud-audio-stop" }.count, 1)
        XCTAssertLessThan(
            try index(of: "hud-level", in: eventLog.events),
            try index(of: "hud-audio-stop", in: eventLog.events),
            eventLog.events.joined(separator: ",")
        )
    }

    @MainActor
    func testQwenQueuedPlaybackKeepsOneVisualizationSessionAcrossBatches() async throws {
        let root = temporaryRuntimeRoot()
        let firstURL = root.appendingPathComponent("visual-session-first.wav")
        let secondURL = root.appendingPathComponent("visual-session-second.wav")
        try Self.writeConstantWAV(to: firstURL, durationSeconds: 0.10, amplitude: 0.08)
        try Self.writeConstantWAV(to: secondURL, durationSeconds: 0.10, amplitude: 0.12)
        let playback = QwenAudioPlayback()
        let eventLog = EventLog()
        let sink = RecordingVisualizationSink(eventLog: eventLog)
        playback.visualizationSink = sink

        for (index, url) in [firstURL, secondURL].enumerated() {
            let prepared = QwenPreparedPlaybackItem(
                index: index,
                item: SpeechPlaybackItem(
                    id: "visual-session-\(index)",
                    segmentID: "visual-session-\(index)",
                    text: "Synthetic playback."
                ),
                audio: QwenPreparedAudio(url: url, durationSeconds: 0.10, isFromCache: false)
            )
            try await playback.play(
                [prepared],
                rateMultiplier: 1.0,
                volume: 0,
                onStartItem: { _ in },
                onBufferEnqueue: { _ in },
                onRenderStart: {},
                onFinish: {},
                onItemEnd: { _ in }
            )
        }

        XCTAssertEqual(eventLog.events.filter { $0 == "hud-audio-start" }.count, 1)
        XCTAssertFalse(eventLog.events.contains("hud-audio-stop"))
        playback.finishNarration()
        XCTAssertEqual(eventLog.events.filter { $0 == "hud-audio-stop" }.count, 1)
    }

    func testQwenSynthesisDoesNotPutPrivateTextInCommandsOrLogs() async throws {
        let root = temporaryRuntimeRoot()
        try makeFakeRuntimeReady(root: root, lane: .small)
        let recorder = CommandRecorder()
        let runner = RecordingRunner(recorder: recorder) { command in
            if let outputIndex = command.arguments.firstIndex(of: "--output") {
                try Self.writeTestWAV(to: URL(fileURLWithPath: command.arguments[outputIndex + 1]))
            }
            return QwenCommandResult(exitCode: 0, stdout: #"{"ok":true}"#, stderr: "")
        }
        let runtime = QwenRuntimeManager(runtimeRoot: root, runner: runner)
        let privateText = "A 45-year-old private stem should never be logged."

        _ = try await runtime.synthesize(
            text: privateText,
            lane: .small,
            speaker: "Aiden",
            language: "English",
            rateMultiplier: 2.4
        )

        let commands = await recorder.commands
        XCTAssertFalse(commands.isEmpty)
        for command in commands {
            XCTAssertFalse(command.arguments.contains { $0.contains(privateText) })
            XCTAssertFalse(command.redactedDescription.contains(privateText))
        }

        let logURL = root.appendingPathComponent("logs/qwen-runtime.log")
        let logText = try String(contentsOf: logURL, encoding: .utf8)
        XCTAssertFalse(logText.contains(privateText))
    }

    func testQwenReferenceVoiceUsesReferenceAudioAndTranscriptFileWithoutLeakingTranscriptToCommand() async throws {
        let root = temporaryRuntimeRoot()
        try makeFakeRuntimeReady(root: root, lane: .small, useReferenceVoice: true)
        let recorder = CommandRecorder()
        let runner = RecordingRunner(recorder: recorder) { command in
            if let outputIndex = command.arguments.firstIndex(of: "--output") {
                try Self.writeTestWAV(to: URL(fileURLWithPath: command.arguments[outputIndex + 1]))
            }
            return QwenCommandResult(exitCode: 0, stdout: #"{"ok":true}"#, stderr: "")
        }
        let runtime = QwenRuntimeManager(runtimeRoot: root, runner: runner)
        let referenceText = "A private reference transcript should stay out of command arguments."
        let referenceAudio = root.appendingPathComponent("reference.wav")
        try Self.writeReferenceWAV(to: referenceAudio, durationSeconds: 11.0)

        _ = try await runtime.synthesize(
            text: "Read this with the cloned voice.",
            lane: .small,
            speaker: QwenReferenceVoiceDefaults.voiceName,
            language: "English",
            rateMultiplier: 2.4,
            useReferenceVoice: true,
            referenceAudioPath: referenceAudio.path,
            referenceText: referenceText
        )

        let commands = await recorder.commands
        let synth = try XCTUnwrap(commands.first { $0.redactedDescription.hasPrefix("qwen synthesize") })
        XCTAssertNotNil(synth.arguments.firstIndex(of: "--ref-audio"))
        XCTAssertEqual(
            synth.arguments[synth.arguments.firstIndex(of: "--model")! + 1], root.appendingPathComponent("models/small-reference").path)
        let refTextIndex = try XCTUnwrap(synth.arguments.firstIndex(of: "--ref-text-file"))
        XCTAssertTrue(synth.arguments[refTextIndex + 1].hasSuffix("-reference.txt"))
        XCTAssertFalse(synth.arguments.contains { $0.contains(referenceText) })
        XCTAssertFalse(synth.redactedDescription.contains(referenceText))
    }

    func testQwenDefaultReferenceVoiceReportsMissingBundledAsset() async throws {
        let root = temporaryRuntimeRoot()
        let runtime = QwenRuntimeManager(runtimeRoot: root)

        do {
            _ = try await runtime.defaultReferenceAudioURL()
            XCTFail("Expected missing bundled reference voice to be reported.")
        } catch let error as QwenRuntimeError {
            XCTAssertEqual(
                error,
                .setupRequired("The bundled Qwen reference voice is missing from the app. Record My Voice before using Qwen voice cloning.")
            )
        }
    }

    func testQwenStudentReferenceVoiceImportAcceptsValidRecorderSampleAndReplacesPreviousClone() async throws {
        let root = temporaryRuntimeRoot()
        let runtime = QwenRuntimeManager(runtimeRoot: root)
        let first = root.appendingPathComponent("first-valid.wav")
        let second = root.appendingPathComponent("second-valid.wav")
        try Self.writeReferenceWAV(to: first, durationSeconds: 10.5)
        try Self.writeReferenceWAV(to: second, durationSeconds: 12.0, amplitude: 0.2)

        let importedFirst = try await runtime.importStudentReferenceVoice(from: first)
        let firstData = try Data(contentsOf: URL(fileURLWithPath: importedFirst.audioPath))
        let importedSecond = try await runtime.importStudentReferenceVoice(from: second)
        let secondData = try Data(contentsOf: URL(fileURLWithPath: importedSecond.audioPath))

        XCTAssertEqual(importedFirst.displayName, "My Voice")
        XCTAssertEqual(importedFirst.audioPath, importedSecond.audioPath)
        XCTAssertEqual(URL(fileURLWithPath: importedSecond.audioPath).lastPathComponent, "student-clone.wav")
        XCTAssertEqual(importedSecond.transcript, QwenStudentReferenceVoiceDefaults.referenceText)
        XCTAssertEqual(importedSecond.durationSeconds, 12.0, accuracy: 0.01)
        XCTAssertNotEqual(firstData, secondData)
    }

    func testQwenStudentReferenceVoiceImportRejectsInvalidRecorderSamples() async throws {
        let root = temporaryRuntimeRoot()
        let runtime = QwenRuntimeManager(runtimeRoot: root)
        let tooShort = root.appendingPathComponent("too-short.wav")
        let tooLong = root.appendingPathComponent("too-long.wav")
        let stereo = root.appendingPathComponent("stereo.wav")
        let lowSampleRate = root.appendingPathComponent("low-sample-rate.wav")
        let silent = root.appendingPathComponent("silent.wav")
        let wrongFormat = root.appendingPathComponent("not-a-wav.txt")
        try Self.writeReferenceWAV(to: tooShort, durationSeconds: 9.5)
        try Self.writeReferenceWAV(to: tooLong, durationSeconds: 20.5)
        try Self.writeReferenceWAV(to: stereo, durationSeconds: 11.0, channels: 2)
        try Self.writeReferenceWAV(to: lowSampleRate, durationSeconds: 11.0, sampleRate: 16_000)
        try Self.writeReferenceWAV(to: silent, durationSeconds: 11.0, amplitude: 0.0)
        try Data("not audio".utf8).write(to: wrongFormat)

        for invalidURL in [tooShort, tooLong, stereo, lowSampleRate, silent, wrongFormat] {
            do {
                _ = try await runtime.importStudentReferenceVoice(from: invalidURL)
                XCTFail("Expected import to reject \(invalidURL.lastPathComponent)")
            } catch let error as QwenRuntimeError {
                XCTAssertTrue(error.localizedDescription.contains("voice sample") || error.localizedDescription.contains("WAV"))
            }
        }
    }

    func testQwenInstallFailureIsReportedByManagedRuntime() async throws {
        let root = temporaryRuntimeRoot()
        try makeFakeUVReady(root: root)
        let runner = RecordingRunner(recorder: CommandRecorder()) { _ in
            QwenCommandResult(exitCode: 42, stdout: "", stderr: "simulated setup failure")
        }
        let runtime = QwenRuntimeManager(runtimeRoot: root, runner: runner)

        do {
            try await runtime.install(lane: .small)
            XCTFail("Expected setup failure")
        } catch {
            XCTAssertTrue(error.localizedDescription.contains("failed"))
        }

        let report = await runtime.doctor()
        XCTAssertEqual(report.lastError?.contains("simulated setup failure"), true)
    }

    func testQwenFailedModelDownloadDoesNotPublishPartialInstall() async throws {
        let root = temporaryRuntimeRoot()
        try makeFakeUVReady(root: root)
        try Self.makeExecutableFile(at: root.appendingPathComponent("venv/bin/python"))
        try Self.makeExecutableFile(at: root.appendingPathComponent("venv/bin/hf"))
        let runner = RecordingRunner(recorder: CommandRecorder()) { command in
            if command.redactedDescription == "download \(QwenModelLane.small.modelID)",
               let localDirectoryIndex = command.arguments.firstIndex(of: "--local-dir") {
                try Self.makeFakeModelReady(
                    directory: URL(fileURLWithPath: command.arguments[localDirectoryIndex + 1])
                )
                return QwenCommandResult(exitCode: 42, stdout: "", stderr: "simulated interrupted download")
            }
            return QwenCommandResult(exitCode: 0, stdout: "", stderr: "")
        }
        let runtime = QwenRuntimeManager(runtimeRoot: root, runner: runner)

        do {
            try await runtime.install(lane: .small)
            XCTFail("Expected interrupted download failure")
        } catch {
            XCTAssertTrue(error.localizedDescription.contains("failed"))
        }

        let modelRoot = root.appendingPathComponent("models", isDirectory: true)
        XCTAssertFalse(FileManager.default.fileExists(atPath: modelRoot.appendingPathComponent("small").path))
        let leftovers = (try? FileManager.default.contentsOfDirectory(atPath: modelRoot.path)) ?? []
        XCTAssertFalse(leftovers.contains { $0.hasSuffix(".installing") })
    }

    func testQwenInstallUsesModernHFDownloaderWhenAvailable() async throws {
        let root = temporaryRuntimeRoot()
        try makeFakeUVReady(root: root)
        let recorder = CommandRecorder()
        let runner = RecordingRunner(recorder: recorder) { command in
            if command.redactedDescription == "create managed Python 3.12 environment" {
                try Self.makeExecutableFile(at: root.appendingPathComponent("venv/bin/python"))
            }

            if command.redactedDescription == "install pinned MLX Audio and Hugging Face dependencies" {
                try Self.makeExecutableFile(at: root.appendingPathComponent("venv/bin/hf"))
            }

            if command.redactedDescription == "download \(QwenModelLane.best.modelID)",
               let localDirectoryIndex = command.arguments.firstIndex(of: "--local-dir") {
                try Self.makeFakeModelReady(
                    directory: URL(fileURLWithPath: command.arguments[localDirectoryIndex + 1])
                )
            }

            if command.redactedDescription.hasPrefix("qwen synthesize"),
                let outputIndex = command.arguments.firstIndex(of: "--output")
            {
                try Self.writeTestWAV(to: URL(fileURLWithPath: command.arguments[outputIndex + 1]))
            }

            return QwenCommandResult(exitCode: 0, stdout: "", stderr: "")
        }
        let runtime = QwenRuntimeManager(
            runtimeRoot: root,
            runner: runner,
            nativeStreamingEnabledOverride: false
        )

        try await runtime.install(lane: .best)

        let commands = await recorder.commands
        let download = try XCTUnwrap(
            commands.first {
                $0.redactedDescription == "download \(QwenModelLane.best.modelID)"
            })
        XCTAssertEqual(download.executable, root.appendingPathComponent("venv/bin/hf").path)
        XCTAssertEqual(Array(download.arguments.prefix(3)), ["download", QwenModelLane.best.modelID, "--local-dir"])
        let bestStagingDirectory = URL(fileURLWithPath: try XCTUnwrap(download.arguments.last))
        XCTAssertEqual(bestStagingDirectory.deletingLastPathComponent(), root.appendingPathComponent("models"))
        XCTAssertTrue(bestStagingDirectory.lastPathComponent.hasPrefix(".best."))
        XCTAssertTrue(bestStagingDirectory.lastPathComponent.hasSuffix(".installing"))
    }

    func testQwenReferenceInstallDownloadsBaseModelIntoReferenceDirectory() async throws {
        let root = temporaryRuntimeRoot()
        try makeFakeUVReady(root: root)
        let recorder = CommandRecorder()
        let runner = RecordingRunner(recorder: recorder) { command in
            if command.redactedDescription == "create managed Python 3.12 environment" {
                try Self.makeExecutableFile(at: root.appendingPathComponent("venv/bin/python"))
            }

            if command.redactedDescription == "install pinned MLX Audio and Hugging Face dependencies" {
                try Self.makeExecutableFile(at: root.appendingPathComponent("venv/bin/hf"))
            }

            if command.redactedDescription == "download \(QwenModelLane.small.referenceModelID)",
               let localDirectoryIndex = command.arguments.firstIndex(of: "--local-dir") {
                try Self.makeFakeModelReady(
                    directory: URL(fileURLWithPath: command.arguments[localDirectoryIndex + 1])
                )
            }

            if command.redactedDescription.hasPrefix("qwen synthesize"),
                let outputIndex = command.arguments.firstIndex(of: "--output")
            {
                try Self.writeTestWAV(to: URL(fileURLWithPath: command.arguments[outputIndex + 1]))
            }

            return QwenCommandResult(exitCode: 0, stdout: "", stderr: "")
        }
        let runtime = QwenRuntimeManager(
            runtimeRoot: root,
            runner: runner,
            nativeStreamingEnabledOverride: false
        )
        let reference = root.appendingPathComponent("reference.wav")
        try Self.writeReferenceWAV(to: reference, durationSeconds: 11.0)

        try await runtime.install(
            lane: .small,
            useReferenceVoice: true,
            referenceAudioPath: reference.path,
            referenceText: QwenStudentReferenceVoiceDefaults.referenceText
        )

        let commands = await recorder.commands
        let download = try XCTUnwrap(
            commands.first {
                $0.redactedDescription == "download \(QwenModelLane.small.referenceModelID)"
            })
        XCTAssertEqual(download.executable, root.appendingPathComponent("venv/bin/hf").path)
        XCTAssertEqual(
            Array(download.arguments.prefix(3)),
            ["download", QwenModelLane.small.referenceModelID, "--local-dir"]
        )
        let referenceStagingDirectory = URL(fileURLWithPath: try XCTUnwrap(download.arguments.last))
        XCTAssertEqual(referenceStagingDirectory.deletingLastPathComponent(), root.appendingPathComponent("models"))
        XCTAssertTrue(referenceStagingDirectory.lastPathComponent.hasPrefix(".small-reference."))
        XCTAssertTrue(referenceStagingDirectory.lastPathComponent.hasSuffix(".installing"))
    }

    func testQwenInstallReusesExistingManagedPythonEnvironment() async throws {
        let root = temporaryRuntimeRoot()
        try makeFakeUVReady(root: root)
        try Self.makeExecutableFile(at: root.appendingPathComponent("venv/bin/python"))
        try Self.makeExecutableFile(at: root.appendingPathComponent("venv/bin/hf"))
        let recorder = CommandRecorder()
        let runner = RecordingRunner(recorder: recorder) { command in
            if command.redactedDescription == "create managed Python 3.12 environment" {
                return QwenCommandResult(
                    exitCode: 2,
                    stdout: "",
                    stderr: "error: Failed to create virtual environment. A virtual environment already exists"
                )
            }

            if command.redactedDescription == "download \(QwenModelLane.best.referenceModelID)",
               let localDirectoryIndex = command.arguments.firstIndex(of: "--local-dir") {
                try Self.makeFakeModelReady(
                    directory: URL(fileURLWithPath: command.arguments[localDirectoryIndex + 1])
                )
            }

            if command.redactedDescription.hasPrefix("qwen synthesize"),
                let outputIndex = command.arguments.firstIndex(of: "--output")
            {
                try Self.writeTestWAV(to: URL(fileURLWithPath: command.arguments[outputIndex + 1]))
            }

            return QwenCommandResult(exitCode: 0, stdout: "", stderr: "")
        }
        let runtime = QwenRuntimeManager(
            runtimeRoot: root,
            runner: runner,
            nativeStreamingEnabledOverride: false
        )
        let reference = root.appendingPathComponent("reference.wav")
        try Self.writeReferenceWAV(to: reference, durationSeconds: 11.0)

        try await runtime.install(
            lane: .best,
            useReferenceVoice: true,
            referenceAudioPath: reference.path,
            referenceText: QwenStudentReferenceVoiceDefaults.referenceText
        )

        let commands = await recorder.commands
        XCTAssertFalse(commands.contains { $0.redactedDescription == "create managed Python 3.12 environment" })
        XCTAssertTrue(commands.contains { $0.redactedDescription == "download \(QwenModelLane.best.referenceModelID)" })
    }

    @MainActor
    func testPlanBackendCanPrepareOutOfOrderButPlaybackStaysInReadPlanOrder() async throws {
        let eventLog = EventLog()
        let browser = FakeBrowserAutomation(
            captureJSON: """
                {"mode":"question","segments":[
                  {"id":"stem","text":"A student reads a stem.","role":"stem","region":"left","rects":[{"x":0,"y":0,"width":1,"height":1}],"textNodePath":"0.0","startOffset":0,"endOffset":23},
                  {"id":"task","text":"What should be reviewed?","role":"question_task","region":"left","rects":[{"x":0,"y":2,"width":1,"height":1}],"textNodePath":"0.1","startOffset":0,"endOffset":24}
                ]}
                """, eventLog: eventLog)
        let speech = OutOfOrderPreparingSpeechBackend(eventLog: eventLog)
        let router = StudyActionRouter(browser: browser, speech: speech)

        let result = await router.run(.readQuestion)

        XCTAssertEqual(result.status, .succeeded)
        XCTAssertEqual(
            eventLog.events,
            [
                "capture",
                "prepared:stem",
                "prepared:task#task",
                "highlight:task",
                "speak:What should be reviewed?",
                "highlight:stem",
                "speak:A student reads a stem.",
                "clear",
            ])
    }

    @MainActor
    func testQwenBackendPromptLibraryHitRewritesStarterAndTailIntoFullPromptAudio() async throws {
        let events = AsyncEventLog()
        let fullPrompt = "Which of the following is the most likely diagnosis?"
        let runtime = PromptLibraryRecordingQwenSynthesizer(
            events: events,
            labelsByText: [
                fullPrompt: "full-prompt",
                "Which of the following": "starter",
                "is the most likely diagnosis?": "tail",
                "The patient has a synthetic stem.": "stem",
            ],
            restoreHits: [fullPrompt]
        )
        let playback = RecordingQwenPlayback(events: events)
        let backend = QwenSpeechBackend(
            settings: qwenSmallSettings(),
            runtime: runtime,
            playback: playback,
            streamingEnabledOverride: false
        )
        let items = [
            SpeechPlaybackItem(id: "task-starter", segmentID: "task#starter", text: "Which of the following"),
            SpeechPlaybackItem(id: "task-tail", segmentID: "task#tail", text: "is the most likely diagnosis?"),
            SpeechPlaybackItem(id: "stem", segmentID: "stem", text: "The patient has a synthetic stem."),
        ]

        try await backend.speak(items) { item in
            await events.append("will:\(item.id):\(item.segmentID):\(item.text)")
        }

        let snapshot = await events.snapshot()
        XCTAssertTrue(snapshot.contains("restore-hit:full-prompt"))
        XCTAssertTrue(snapshot.contains("prepare-start:full-prompt"))
        XCTAssertFalse(snapshot.contains("prepare-start:starter"))
        XCTAssertFalse(snapshot.contains("prepare-start:tail"))
        XCTAssertTrue(snapshot.contains("will:task-starter:task#starter:\(fullPrompt)"))
    }

    @MainActor
    func testQwenBackendPublishesFinalPlaybackItemsAndPreparedAudioTiming() async throws {
        let events = AsyncEventLog()
        let fullPrompt = "Which of the following is the most likely diagnosis?"
        let runtime = PromptLibraryRecordingQwenSynthesizer(
            events: events,
            labelsByText: [
                fullPrompt: "full-prompt",
                "The patient has a synthetic stem.": "stem",
            ],
            restoreHits: [fullPrompt]
        )
        let playback = RecordingQwenPlayback(events: events)
        let settings = qwenSmallSettings()
        let backend = QwenSpeechBackend(
            settings: settings,
            runtime: runtime,
            playback: playback,
            streamingEnabledOverride: false
        )
        let timingSink = RecordingSpeechPlaybackTimingSink()
        backend.timingSink = timingSink
        let items = [
            SpeechPlaybackItem(id: "task-starter", segmentID: "task#starter", text: "Which of the following"),
            SpeechPlaybackItem(id: "task-tail", segmentID: "task#tail", text: "is the most likely diagnosis?"),
            SpeechPlaybackItem(id: "stem", segmentID: "stem", text: "The patient has a synthetic stem."),
        ]

        try await backend.speak(items) { _ in }

        XCTAssertEqual(timingSink.finalItems.map(\.text), [fullPrompt, "The patient has a synthetic stem."])
        let firstTiming = try XCTUnwrap(timingSink.timings.first)
        XCTAssertEqual(firstTiming.itemID, "task-starter")
        XCTAssertEqual(firstTiming.segmentID, "task#starter")
        XCTAssertEqual(firstTiming.itemIndex, 0)
        XCTAssertEqual(firstTiming.durationSeconds, 0.20 / settings.rateMultiplier, accuracy: 0.001)
        XCTAssertEqual(firstTiming.source, .qwenPreparedAudio)
        XCTAssertEqual(timingSink.finishedItems.map(\.itemID), ["task-starter", "stem"])
    }

    @MainActor
    func testSlowPrecisionAlignerDoesNotDelayFirstAudioOrPlaybackCompletion() async throws {
        let events = AsyncEventLog()
        let runtime = FakeQwenSynthesizer(
            events: events,
            labelsByText: ["Synthetic narration runway.": "stem"],
            durationsByLabel: ["stem": 4]
        )
        let playback = RecordingQwenPlayback(events: events)
        let aligner = SlowFailingWordAligner(events: events)
        let backend = QwenSpeechBackend(
            settings: qwenSmallSettings(),
            runtime: runtime,
            playback: playback,
            wordAligner: aligner,
            streamingEnabledOverride: false
        )

        let startedAt = Date()
        try await backend.speak([
            SpeechPlaybackItem(id: "stem", segmentID: "stem", text: "Synthetic narration runway.")
        ]) { _ in }
        let elapsed = Date().timeIntervalSince(startedAt)
        let eventSnapshot = await events.snapshot()

        XCTAssertLessThan(elapsed, 0.5)
        XCTAssertTrue(eventSnapshot.contains("play-sequence:stem.wav"))
        await backend.stop()
    }

    func testPrecisionAlignmentRuntimeNeverDownloadsWithoutExplicitInstall() async throws {
        let root = temporaryRuntimeRoot().appendingPathComponent("precision-alignment")
        defer { try? FileManager.default.removeItem(at: root) }
        let runtime = RSVPPrecisionAlignmentRuntime(runtimeRoot: root)

        let initialState = await runtime.currentState()
        XCTAssertEqual(initialState, .notInstalled)
        let track = await runtime.align(
            item: SpeechPlaybackItem(id: "synthetic", segmentID: "synthetic", text: "Synthetic text."),
            itemIndex: 0,
            audioURL: root.appendingPathComponent("missing.wav")
        )

        XCTAssertNil(track)
        let finalState = await runtime.currentState()
        XCTAssertEqual(finalState, .notInstalled)
        XCTAssertFalse(FileManager.default.fileExists(atPath: root.path))
    }

    @MainActor
    func testQwenBackendPromptLibraryMissKeepsStarterTailAndSchedulesLearning() async throws {
        let events = AsyncEventLog()
        let fullPrompt = "Which of the following is the most likely diagnosis?"
        let runtime = PromptLibraryRecordingQwenSynthesizer(
            events: events,
            labelsByText: [
                fullPrompt: "full-prompt",
                "Which of the following": "starter",
                "is the most likely diagnosis?": "tail",
                "The patient has a synthetic stem.": "stem",
            ],
            restoreHits: []
        )
        let playback = RecordingQwenPlayback(events: events)
        let backend = QwenSpeechBackend(
            settings: qwenSmallSettings(),
            runtime: runtime,
            playback: playback,
            streamingEnabledOverride: false
        )
        let items = [
            SpeechPlaybackItem(id: "task-starter", segmentID: "task#starter", text: "Which of the following"),
            SpeechPlaybackItem(id: "task-tail", segmentID: "task#tail", text: "is the most likely diagnosis?"),
            SpeechPlaybackItem(id: "stem", segmentID: "stem", text: "The patient has a synthetic stem."),
        ]

        try await backend.speak(items) { item in
            await events.append("will:\(item.id):\(item.segmentID):\(item.text)")
        }
        try await Task.sleep(nanoseconds: 500_000_000)

        let snapshot = await events.snapshot()
        XCTAssertTrue(snapshot.contains("restore-miss:full-prompt"))
        XCTAssertTrue(snapshot.contains("prepare-start:starter"))
        XCTAssertTrue(snapshot.contains("prepare-start:tail"))
        XCTAssertTrue(snapshot.contains("learn:full-prompt"))
        XCTAssertLessThan(
            try index(of: "prepare-start:starter", in: snapshot),
            try index(of: "learn:full-prompt", in: snapshot),
            snapshot.joined(separator: ",")
        )
    }

    @MainActor
    func testQwenBackendPromptLibraryLearningWaitsUntilNoNarrationIsActive() async throws {
        let events = AsyncEventLog()
        let fullPrompt = "Which of the following is the most likely diagnosis?"
        let runtime = PromptLibraryRecordingQwenSynthesizer(
            events: events,
            labelsByText: [
                fullPrompt: "full-prompt",
                "Which of the following": "starter",
                "is the most likely diagnosis?": "tail",
                "The patient has a synthetic stem.": "stem",
                "Second narration is active long enough to catch background learning.": "second",
            ],
            restoreHits: []
        )
        let playback = DelayedRecordingQwenPlayback(
            events: events,
            sequenceDelayNanoseconds: 700_000_000
        )
        let backend = QwenSpeechBackend(
            settings: qwenSmallSettings(),
            runtime: runtime,
            playback: playback,
            streamingEnabledOverride: false
        )
        let firstItems = [
            SpeechPlaybackItem(id: "task-starter", segmentID: "task#starter", text: "Which of the following"),
            SpeechPlaybackItem(id: "task-tail", segmentID: "task#tail", text: "is the most likely diagnosis?"),
            SpeechPlaybackItem(id: "stem", segmentID: "stem", text: "The patient has a synthetic stem."),
        ]
        let secondItems = [
            SpeechPlaybackItem(
                id: "second",
                segmentID: "second",
                text: "Second narration is active long enough to catch background learning."
            )
        ]

        try await backend.speak(firstItems) { _ in }
        let secondNarration = Task { @MainActor in
            try await backend.speak(secondItems) { _ in }
        }
        try await Task.sleep(nanoseconds: 450_000_000)

        let activeSnapshot = await events.snapshot()
        XCTAssertTrue(activeSnapshot.contains("play-start:second"), activeSnapshot.joined(separator: ","))
        XCTAssertFalse(activeSnapshot.contains("learn:full-prompt"), activeSnapshot.joined(separator: ","))

        try await secondNarration.value
        try await Task.sleep(nanoseconds: 450_000_000)

        let finalSnapshot = await events.snapshot()
        XCTAssertTrue(finalSnapshot.contains("learn:full-prompt"), finalSnapshot.joined(separator: ","))
        XCTAssertLessThan(
            try index(of: "play-end:second", in: finalSnapshot),
            try index(of: "learn:full-prompt", in: finalSnapshot),
            finalSnapshot.joined(separator: ",")
        )
    }

    @MainActor
    func testStudySpeechBackendEmitsVisualizationEventsAroundPlayback() async throws {
        let eventLog = EventLog()
        let backend = DelayedSpeechBackend(eventLog: eventLog)
        let sink = RecordingVisualizationSink(eventLog: eventLog)
        let speech = StudySpeechBackend(
            settings: .default,
            appleBackend: backend,
            qwenBackend: backend
        )
        speech.visualizationSink = sink

        try await speech.speak("This is a visualized sentence.")

        XCTAssertEqual(eventLog.events.first, "hud-start")
        XCTAssertEqual(eventLog.events.last, "hud-end")
        XCTAssertTrue(eventLog.events.contains("hud-level"))
        XCTAssertTrue(
            eventLog.events.firstIndex(of: "hud-start")! < eventLog.events.firstIndex(of: "speak:This is a visualized sentence.")!)
        XCTAssertTrue(eventLog.events.firstIndex(of: "speak:This is a visualized sentence.")! < eventLog.events.firstIndex(of: "hud-end")!)
    }

    @MainActor
    func testQwenVisualizationStaysGeneratingUntilAudioStarts() async throws {
        let eventLog = EventLog()
        let playbackEvents = AsyncEventLog()
        let runtime = FakeQwenSynthesizer(
            events: playbackEvents,
            labelsByText: ["Audio arrives after synthesis.": "preview"]
        )
        let playback = RecordingQwenPlayback(events: playbackEvents)
        let qwen = QwenSpeechBackend(
            settings: qwenSmallSettings(),
            runtime: runtime,
            playback: playback
        )
        let speech = StudySpeechBackend(
            settings: qwenSmallSettings(),
            appleBackend: DelayedSpeechBackend(eventLog: eventLog),
            qwenBackend: qwen
        )
        let sink = RecordingVisualizationSink(eventLog: eventLog)
        speech.visualizationSink = sink

        try await speech.speak("Audio arrives after synthesis.")

        XCTAssertEqual(eventLog.events.first, "hud-start")
        XCTAssertTrue(eventLog.events.contains("hud-audio-start"))
        XCTAssertLessThan(
            try index(of: "hud-audio-start", in: eventLog.events),
            try index(of: "hud-end", in: eventLog.events)
        )
        XCTAssertFalse(eventLog.events.prefix { $0 != "hud-audio-start" }.contains("hud-level"))
    }

    @MainActor
    func testStudySpeechBackendDoesNotEmitVisualizationWhenToggleIsOff() async throws {
        let eventLog = EventLog()
        let backend = DelayedSpeechBackend(eventLog: eventLog)
        let sink = RecordingVisualizationSink(eventLog: eventLog)
        let settings = SpeechSettings(
            rateMultiplier: 2.4,
            volume: 1.0,
            pitchMultiplier: 1.0,
            voiceIdentifier: nil,
            showPlaybackHUD: false
        )
        let speech = StudySpeechBackend(
            settings: settings,
            appleBackend: backend,
            qwenBackend: backend
        )
        speech.visualizationSink = sink

        try await speech.speak("No visualizer.")

        XCTAssertEqual(eventLog.events, ["speak:No visualizer."])
    }

    @MainActor
    func testStudySpeechBackendEndsVisualizationWhenPlaybackIsCancelled() async throws {
        let eventLog = EventLog()
        let backend = CancellableSpeechBackend(eventLog: eventLog)
        let sink = RecordingVisualizationSink(eventLog: eventLog)
        let speech = StudySpeechBackend(
            settings: .default,
            appleBackend: backend,
            qwenBackend: backend
        )
        speech.visualizationSink = sink

        let task = Task { @MainActor in
            try await speech.speak("Cancel this visualized sentence.")
        }
        while !eventLog.events.contains("speak:Cancel this visualized sentence.") {
            try await Task.sleep(nanoseconds: 10_000_000)
        }

        task.cancel()

        do {
            try await task.value
            XCTFail("Expected speech cancellation")
        } catch is CancellationError {
            XCTAssertEqual(eventLog.events.first, "hud-start")
            XCTAssertEqual(eventLog.events.last, "hud-end")
        }
    }

    @MainActor
    func testQwenSpeechBackendPersistsQuestionAudioItems() async throws {
        let events = AsyncEventLog()
        let runtime = FakeQwenSynthesizer(
            events: events,
            labelsByText: [
                "Which of the following": "task-starter",
                "best explains this finding?": "task-tail",
                "A patient has chest pain.": "stem",
            ]
        )
        let playback = RecordingQwenPlayback(events: events)
        let backend = QwenSpeechBackend(
            settings: qwenSmallSettings(),
            runtime: runtime,
            playback: playback
        )

        try await backend.speak([
            SpeechPlaybackItem(id: "starter", segmentID: "task#starter", text: "Which of the following"),
            SpeechPlaybackItem(id: "tail", segmentID: "task#tail", text: "best explains this finding?"),
            SpeechPlaybackItem(
                id: "stem",
                segmentID: "stem",
                text: "A patient has chest pain.",
                audioCachePolicy: .persistent
            ),
        ]) { _ in }

        let log = await events.snapshot()
        XCTAssertTrue(log.contains("cache-policy:task-starter:persistent"))
        XCTAssertTrue(log.contains("cache-policy:task-tail:persistent"))
        XCTAssertTrue(log.contains("cache-policy:stem:persistent"))
    }

    @MainActor
    func testQwenPlaybackBatchesShortStarterWithTailAndFirstStemWhenReady() async throws {
        let events = AsyncEventLog()
        let runtime = FakeQwenSynthesizer(
            events: events,
            labelsByText: [
                "Which of the following": "task-starter",
                "responses best explains this finding?": "task-tail",
                "A student reads a longer stem.": "stem",
            ],
            delaysByLabel: [
                "task-tail": 100_000_000,
                "stem": 500_000_000,
            ],
            durationsByLabel: [
                "task-starter": 0.05,
                "task-tail": 0.40,
                "stem": 0.40,
            ]
        )
        let playback = RecordingQwenPlayback(events: events)
        let backend = QwenSpeechBackend(
            settings: qwenSmallSettings(),
            runtime: runtime,
            playback: playback
        )
        let items = [
            SpeechPlaybackItem(id: "starter", segmentID: "task#starter", text: "Which of the following"),
            SpeechPlaybackItem(id: "tail", segmentID: "task#tail", text: "responses best explains this finding?"),
            SpeechPlaybackItem(id: "stem", segmentID: "stem", text: "A student reads a longer stem."),
        ]

        try await backend.speak(items) { item in
            await events.append("will:\(item.segmentID)")
        }

        let log = await events.snapshot()
        XCTAssertLessThan(
            try index(of: "prepare-done:stem", in: log), try index(of: "play-sequence:task-starter.wav,task-tail.wav,stem.wav", in: log))
        XCTAssertLessThan(try index(of: "will:task#starter", in: log), try index(of: "will:task#tail", in: log))
        XCTAssertLessThan(try index(of: "will:task#tail", in: log), try index(of: "will:stem", in: log))
        XCTAssertFalse(log.contains { $0.hasPrefix("play-single:") })
    }

    @MainActor
    func testQwenPlaybackTreatsFastRateStarterAsShortForInitialTailBuffering() async throws {
        let events = AsyncEventLog()
        let runtime = FakeQwenSynthesizer(
            events: events,
            labelsByText: [
                "Which of the following": "task-starter",
                "responses best explains this finding?": "task-tail",
            ],
            delaysByLabel: [
                "task-tail": 100_000_000
            ],
            durationsByLabel: [
                "task-starter": 1.36,
                "task-tail": 0.40,
            ]
        )
        let playback = RecordingQwenPlayback(events: events)
        let backend = QwenSpeechBackend(
            settings: qwenSmallSettings(),
            runtime: runtime,
            playback: playback
        )

        try await backend.speak([
            SpeechPlaybackItem(id: "starter", segmentID: "task#starter", text: "Which of the following"),
            SpeechPlaybackItem(id: "tail", segmentID: "task#tail", text: "responses best explains this finding?"),
        ]) { item in
            await events.append("will:\(item.segmentID)")
        }

        let log = await events.snapshot()
        XCTAssertLessThan(
            try index(of: "prepare-done:task-tail", in: log), try index(of: "play-sequence:task-starter.wav,task-tail.wav", in: log))
        XCTAssertLessThan(try index(of: "will:task#starter", in: log), try index(of: "will:task#tail", in: log))
        XCTAssertFalse(log.contains("play-sequence:task-starter.wav"))
    }

    @MainActor
    func testQwenPlaybackDegradesAndBuffersWhenShortStarterWouldOutrunSlowTail() async throws {
        let events = AsyncEventLog()
        let trace = TraceRecorder()
        let runtime = FakeQwenSynthesizer(
            events: events,
            labelsByText: [
                "Which of the following": "task-starter",
                "slow tail": "task-tail",
                "A longer stem follows.": "stem",
            ],
            delaysByLabel: [
                "task-tail": 1_900_000_000
            ],
            durationsByLabel: [
                "task-starter": 0.05,
                "task-tail": 0.40,
                "stem": 0.40,
            ]
        )
        let playback = RecordingQwenPlayback(events: events)
        let backend = QwenSpeechBackend(
            settings: qwenSmallSettings(),
            runtime: runtime,
            playback: playback,
            traceSink: trace
        )

        try await backend.speak([
            SpeechPlaybackItem(id: "starter", segmentID: "task#starter", text: "Which of the following"),
            SpeechPlaybackItem(id: "tail", segmentID: "task#tail", text: "slow tail"),
            SpeechPlaybackItem(id: "stem", segmentID: "stem", text: "A longer stem follows."),
        ]) { _ in }

        let log = await events.snapshot()
        XCTAssertLessThan(
            try index(of: "prepare-done:task-tail", in: log),
            try index(of: "play-sequence:task-starter.wav,task-tail.wav,stem.wav", in: log),
            log.joined(separator: ",")
        )
        XCTAssertFalse(log.contains("play-sequence:task-starter.wav"))

        let traceEvents = await trace.snapshot()
        XCTAssertTrue(traceEvents.contains { $0.kind.rawValue == "adaptivePolicyTransition" })
        XCTAssertTrue(traceEvents.contains { $0.kind.rawValue == "adaptiveBufferWait" })
        let encoded = String(data: try JSONEncoder().encode(traceEvents), encoding: .utf8) ?? ""
        XCTAssertTrue(encoded.contains("\"policyState\":\"degraded\""))
        XCTAssertFalse(encoded.contains("slow tail"))
        XCTAssertFalse(encoded.contains("Which of the following"))
    }

    @MainActor
    func testQwenPlaybackStartsDegradedReadWhenEarlyRunwayIsSafe() async throws {
        let events = AsyncEventLog()
        let trace = TraceRecorder()
        let runtime = FakeQwenSynthesizer(
            events: events,
            labelsByText: [
                "Which of the following": "task-starter",
                "best explains this finding?": "task-tail",
                "A long first stem sentence follows.": "stem-1",
                "A later sentence follows.": "stem-2",
                "A slow final sentence follows.": "slow-stem",
            ],
            delaysByLabel: [
                "slow-stem": 1_500_000_000
            ],
            durationsByLabel: [
                "task-starter": 0.10,
                "task-tail": 0.40,
                "stem-1": 8.00,
                "stem-2": 0.40,
                "slow-stem": 0.40,
            ]
        )
        let playback = RecordingQwenPlayback(events: events)
        let backend = QwenSpeechBackend(
            settings: qwenSmallSettings(),
            runtime: runtime,
            playback: playback,
            traceSink: trace
        )

        try await backend.speak([
            SpeechPlaybackItem(id: "starter", segmentID: "task#starter", text: "Which of the following"),
            SpeechPlaybackItem(id: "tail", segmentID: "task#tail", text: "best explains this finding?"),
            SpeechPlaybackItem(id: "stem1", segmentID: "stem-1", text: "A long first stem sentence follows."),
            SpeechPlaybackItem(id: "stem2", segmentID: "stem-2", text: "A later sentence follows."),
            SpeechPlaybackItem(id: "slow", segmentID: "slow-stem", text: "A slow final sentence follows."),
        ]) { _ in }

        let log = await events.snapshot()
        let firstPlay = try XCTUnwrap(log.first { $0.hasPrefix("play-sequence:") })
        XCTAssertEqual(firstPlay, "play-sequence:task-starter.wav,task-tail.wav,stem-1.wav")
        XCTAssertLessThan(
            try index(of: firstPlay, in: log),
            try index(of: "prepare-done:slow-stem", in: log),
            log.joined(separator: ",")
        )

        let traceEvents = await trace.snapshot()
        let batchStart = try XCTUnwrap(traceEvents.first { $0.kind == .playbackBatchStart })
        XCTAssertEqual(batchStart.batchCount, 3)
        XCTAssertTrue(traceEvents.contains { $0.kind == .adaptiveBufferWait })
    }

    @MainActor
    func testQwenPlaybackStartsLongFirstItemNearRealtimeTargetWhenTailIsSlow() async throws {
        let events = AsyncEventLog()
        let trace = TraceRecorder()
        let runtime = FakeQwenSynthesizer(
            events: events,
            labelsByText: [
                "A long first chunk can safely cover lookahead.": "first",
                "slow tail": "tail",
            ],
            delaysByLabel: [
                "first": 150_000_000,
                "tail": 1_400_000_000,
            ],
            durationsByLabel: [
                "first": 3.00,
                "tail": 0.40,
            ]
        )
        let playback = RecordingQwenPlayback(events: events)
        let backend = QwenSpeechBackend(
            settings: qwenSmallSettings(),
            runtime: runtime,
            playback: playback,
            traceSink: trace
        )

        try await backend.speak([
            SpeechPlaybackItem(id: "first", segmentID: "first", text: "A long first chunk can safely cover lookahead."),
            SpeechPlaybackItem(id: "tail", segmentID: "tail", text: "slow tail"),
        ]) { _ in }

        let log = await events.snapshot()
        XCTAssertLessThan(
            try index(of: "play-sequence:first.wav", in: log),
            try index(of: "prepare-done:tail", in: log),
            log.joined(separator: ",")
        )

        let traceEvents = await trace.snapshot()
        let firstStart = try XCTUnwrap(traceEvents.first { $0.kind == .playbackItemStart })
        XCTAssertLessThanOrEqual(try XCTUnwrap(firstStart.elapsedSeconds), 1.15)
        let batchStart = try XCTUnwrap(traceEvents.first { $0.kind == .playbackBatchStart })
        XCTAssertEqual(batchStart.batchCount, 1)
    }

    @MainActor
    func testQwenPlaybackWaitsForTailWhenCachedStarterIsTooShortToBeUseful() async throws {
        let events = AsyncEventLog()
        let trace = TraceRecorder()
        let runtime = FakeQwenSynthesizer(
            events: events,
            labelsByText: [
                "Which of the following": "starter",
                "slow tail": "tail",
            ],
            delaysByLabel: [
                "tail": 2_300_000_000
            ],
            durationsByLabel: [
                "starter": 0.05,
                "tail": 0.40,
            ],
            cacheHitLabels: ["starter"]
        )
        let playback = RecordingQwenPlayback(events: events)
        let backend = QwenSpeechBackend(
            settings: qwenSmallSettings(),
            runtime: runtime,
            playback: playback,
            traceSink: trace
        )

        try await backend.speak([
            SpeechPlaybackItem(id: "starter", segmentID: "task#starter", text: "Which of the following"),
            SpeechPlaybackItem(id: "tail", segmentID: "task#tail", text: "slow tail"),
        ]) { _ in }

        let traceEvents = await trace.snapshot()
        let firstPrepared = try XCTUnwrap(traceEvents.first { $0.kind == .firstPrepared })
        XCTAssertEqual(firstPrepared.cacheHit, true)
        let firstStart = try XCTUnwrap(traceEvents.first { $0.kind == .playbackItemStart })
        XCTAssertGreaterThanOrEqual(try XCTUnwrap(firstStart.elapsedSeconds), 2.25)
        XCTAssertLessThanOrEqual(try XCTUnwrap(firstStart.elapsedSeconds), 2.45)
        let batchStart = try XCTUnwrap(traceEvents.first { $0.kind == .playbackBatchStart })
        XCTAssertEqual(batchStart.batchCount, 2)
        XCTAssertFalse(traceEvents.contains { $0.kind == .underrunWait })
    }

    @MainActor
    func testQwenPlaybackStartsUsefulCachedStarterImmediatelyUnderLoad() async throws {
        let events = AsyncEventLog()
        let trace = TraceRecorder()
        let runtime = FakeQwenSynthesizer(
            events: events,
            labelsByText: [
                "Which of the following": "starter",
                "slow tail": "tail",
                "A stem follows.": "stem",
            ],
            delaysByLabel: [
                "tail": 2_300_000_000
            ],
            durationsByLabel: [
                "starter": 1.36,
                "tail": 0.40,
                "stem": 0.40,
            ],
            cacheHitLabels: ["starter"]
        )
        let playback = RecordingQwenPlayback(events: events)
        let backend = QwenSpeechBackend(
            settings: qwenSmallSettings(),
            runtime: runtime,
            playback: playback,
            traceSink: trace
        )

        try await backend.speak([
            SpeechPlaybackItem(id: "starter", segmentID: "task#starter", text: "Which of the following"),
            SpeechPlaybackItem(id: "tail", segmentID: "task#tail", text: "slow tail"),
            SpeechPlaybackItem(id: "stem", segmentID: "stem", text: "A stem follows."),
        ]) { _ in }

        let log = await events.snapshot()
        let firstPlay = try XCTUnwrap(log.first { $0.hasPrefix("play-sequence:") })
        XCTAssertEqual(firstPlay, "play-sequence:starter.wav")
        XCTAssertLessThan(
            try index(of: firstPlay, in: log),
            try index(of: "prepare-done:tail", in: log),
            log.joined(separator: ",")
        )
        XCTAssertTrue(log.contains("play-sequence:tail.wav,stem.wav"), log.joined(separator: ","))

        let traceEvents = await trace.snapshot()
        let firstStart = try XCTUnwrap(traceEvents.first { $0.kind == .playbackItemStart })
        XCTAssertLessThanOrEqual(try XCTUnwrap(firstStart.elapsedSeconds), 0.35)
        let batchStart = try XCTUnwrap(traceEvents.first { $0.kind == .playbackBatchStart })
        XCTAssertEqual(batchStart.batchCount, 1)
    }

    @MainActor
    func testQwenPlaybackKeepsReadPlanOrderWhenLaterPreparationFinishesFirst() async throws {
        let events = AsyncEventLog()
        let runtime = FakeQwenSynthesizer(
            events: events,
            labelsByText: [
                "Which of the following": "task-starter",
                "tail that is ready first": "task-tail",
            ],
            delaysByLabel: ["task-starter": 150_000_000]
        )
        let playback = RecordingQwenPlayback(events: events)
        let backend = QwenSpeechBackend(
            settings: qwenSmallSettings(),
            runtime: runtime,
            playback: playback
        )
        let items = [
            SpeechPlaybackItem(id: "starter", segmentID: "task#starter", text: "Which of the following"),
            SpeechPlaybackItem(id: "tail", segmentID: "task#tail", text: "tail that is ready first"),
        ]

        try await backend.speak(items) { item in
            await events.append("will:\(item.segmentID)")
        }

        let log = await events.snapshot()
        XCTAssertLessThan(try index(of: "prepare-done:task-starter", in: log), try index(of: "prepare-start:task-tail", in: log))
        XCTAssertLessThan(try index(of: "play-sequence:task-starter.wav,task-tail.wav", in: log), log.count)
        XCTAssertLessThan(try index(of: "will:task#starter", in: log), try index(of: "will:task#tail", in: log))
        XCTAssertFalse(log.contains { $0.hasPrefix("play-single:") })
    }

    @MainActor
    func testQwenSpeechBackendStartsImmediatelyWhenFirstAudioBudgetIsGone() async throws {
        let events = AsyncEventLog()
        let trace = TraceRecorder()
        // The tail cannot finish until the starter is handed to playback, so any lookahead hold
        // after the budget expires shows up as ordering/trace failures instead of a wall-clock race.
        let tailGate = AsyncTestGate()
        let safetyRelease = Task {
            try? await Task.sleep(nanoseconds: 10_000_000_000)
            await tailGate.open(by: "safety-timeout")
        }
        defer { safetyRelease.cancel() }
        let runtime = FakeQwenSynthesizer(
            events: events,
            labelsByText: [
                "Which of the following": "task-starter",
                "slow tail": "task-tail",
            ],
            delaysByLabel: [
                "task-starter": 2_050_000_000,
            ],
            durationsByLabel: [
                "task-starter": 0.05,
                "task-tail": 0.40,
            ],
            gatesByLabel: ["task-tail": tailGate]
        )
        let playback = RecordingQwenPlayback(events: events)
        let backend = QwenSpeechBackend(
            settings: qwenSmallSettings(),
            runtime: runtime,
            playback: playback,
            traceSink: trace
        )

        try await backend.speak([
            SpeechPlaybackItem(id: "starter", segmentID: "task#starter", text: "Which of the following"),
            SpeechPlaybackItem(id: "tail", segmentID: "task#tail", text: "slow tail"),
        ]) { item in
            if item.id == "starter" {
                await tailGate.open(by: "starter-playback")
            }
        }

        let log = await events.snapshot()
        let encodedLog = log.joined(separator: ",")
        let gateOpenedBy = await tailGate.openedBy
        XCTAssertEqual(gateOpenedBy, "starter-playback", encodedLog)
        XCTAssertLessThan(
            try index(of: "play-sequence:task-starter.wav", in: log),
            try index(of: "prepare-done:task-tail", in: log),
            encodedLog
        )
        XCTAssertTrue(log.contains("play-sequence:task-tail.wav"), encodedLog)

        let traceEvents = await trace.snapshot()
        let encodedTrace = String(data: try JSONEncoder().encode(traceEvents), encoding: .utf8) ?? ""
        // Precondition: the starter really arrived after the 2.0 s fallback first-audio budget.
        let firstPrepared = try XCTUnwrap(traceEvents.first { $0.kind == .firstPrepared }, encodedTrace)
        XCTAssertEqual(firstPrepared.itemIndex, 0, encodedTrace)
        XCTAssertGreaterThanOrEqual(try XCTUnwrap(firstPrepared.elapsedSeconds), 2.0, encodedTrace)

        let transition = try XCTUnwrap(
            traceEvents.first { $0.kind == .adaptivePolicyTransition },
            encodedTrace
        )
        XCTAssertEqual(transition.policyReason, "predictedGap", encodedTrace)
        XCTAssertEqual(transition.itemIndex, 1, encodedTrace)
        XCTAssertFalse(traceEvents.contains { $0.kind == .initialBufferWait }, encodedTrace)
        XCTAssertFalse(traceEvents.contains { $0.kind == .adaptiveBufferWait }, encodedTrace)

        let firstBatch = try XCTUnwrap(traceEvents.first { $0.kind == .playbackBatchStart }, encodedTrace)
        XCTAssertEqual(firstBatch.itemIndex, 0, encodedTrace)
        XCTAssertEqual(firstBatch.batchCount, 1, encodedTrace)
        let firstStart = try XCTUnwrap(traceEvents.first { $0.kind == .playbackItemStart }, encodedTrace)
        XCTAssertEqual(firstStart.itemID, "starter", encodedTrace)
        let transitionIndex = try XCTUnwrap(traceEvents.firstIndex { $0.kind == .adaptivePolicyTransition })
        let firstBatchIndex = try XCTUnwrap(traceEvents.firstIndex { $0.kind == .playbackBatchStart })
        XCTAssertLessThan(transitionIndex, firstBatchIndex, encodedTrace)
    }

    @MainActor
    func testQwenSpeechBackendSynthesizesFirstColdItemBeforeBatchingLookahead() async throws {
        let events = AsyncEventLog()
        let runtime = BatchRecordingQwenSynthesizer(
            events: events,
            labelsByText: [
                "Which of the following": "starter",
                "tail answer?": "tail",
                "A longer stem follows.": "stem",
            ]
        )
        let playback = RecordingQwenPlayback(events: events)
        let backend = QwenSpeechBackend(
            settings: qwenSmallSettings(),
            runtime: runtime,
            playback: playback
        )

        try await backend.speak([
            SpeechPlaybackItem(id: "starter", segmentID: "task#starter", text: "Which of the following"),
            SpeechPlaybackItem(id: "tail", segmentID: "task#tail", text: "tail answer?"),
            SpeechPlaybackItem(id: "stem", segmentID: "stem", text: "A longer stem follows."),
        ]) { item in
            await events.append("will:\(item.segmentID)")
        }

        let log = await events.snapshot()
        XCTAssertLessThan(try index(of: "single-start:starter", in: log), try index(of: "single-done:starter", in: log))
        XCTAssertLessThan(try index(of: "single-done:starter", in: log), try index(of: "batch-start:tail,stem", in: log))
        XCTAssertLessThan(try index(of: "will:task#starter", in: log), try index(of: "will:task#tail", in: log))
        XCTAssertFalse(log.contains("single-start:tail"))
        XCTAssertFalse(log.contains("single-start:stem"))
        XCTAssertFalse(log.contains("batch-start:tail"))
    }

    @MainActor
    func testQwenSpeechBackendChunksLargeLookaheadBatches() async throws {
        let events = AsyncEventLog()
        let texts = (0..<8).map { "Synthetic lookahead sentence \($0)." }
        let runtime = BatchRecordingQwenSynthesizer(
            events: events,
            labelsByText: Dictionary(
                uniqueKeysWithValues: texts.enumerated().map { index, text in
                    (text, "item-\(index)")
                })
        )
        let playback = RecordingQwenPlayback(events: events)
        let backend = QwenSpeechBackend(
            settings: qwenSmallSettings(speaker: "Ryan"),
            runtime: runtime,
            playback: playback
        )
        let items = texts.enumerated().map { index, text in
            SpeechPlaybackItem(id: "item-\(index)", segmentID: "segment-\(index)", text: text)
        }

        try await backend.speak(items) { _ in }

        let log = await events.snapshot()
        XCTAssertTrue(log.contains("single-start:item-0"))
        XCTAssertTrue(log.contains("batch-start:item-1,item-2"))
        XCTAssertTrue(log.contains("batch-start:item-3,item-4,item-5,item-6"))
        XCTAssertTrue(log.contains("batch-start:item-7"))
        XCTAssertFalse(log.contains("batch-start:item-2,item-3,item-4,item-5,item-6,item-7"))
    }

    @MainActor
    func testQwenSpeechBackendBatchesReferenceVoiceLookahead() async throws {
        let events = AsyncEventLog()
        let runtime = BatchRecordingQwenSynthesizer(
            events: events,
            labelsByText: [
                "Which of the following": "starter",
                "tail answer?": "tail",
                "A longer stem follows.": "stem",
            ]
        )
        let playback = RecordingQwenPlayback(events: events)
        var settings = qwenSmallSettings()
        settings.qwenDeEsserStrengthDecibels = 8.5
        settings.qwenUseReferenceVoice = true
        settings.qwenReferenceVoiceID = .studentClone
        settings.qwenStudentReferenceVoice = QwenStudentReferenceVoice(
            audioPath: "/tmp/synthetic-student-reference.wav",
            transcript: "Synthetic reference transcript.",
            durationSeconds: 11.0
        )
        let backend = QwenSpeechBackend(
            settings: settings,
            runtime: runtime,
            playback: playback
        )

        try await backend.speak([
            SpeechPlaybackItem(id: "starter", segmentID: "task#starter", text: "Which of the following"),
            SpeechPlaybackItem(id: "tail", segmentID: "task#tail", text: "tail answer?"),
            SpeechPlaybackItem(id: "stem", segmentID: "stem", text: "A longer stem follows."),
        ]) { _ in }

        let log = await events.snapshot()
        XCTAssertTrue(log.contains("single-start:starter"))
        XCTAssertTrue(log.contains("batch-start:tail,stem"), log.joined(separator: ","))
        XCTAssertTrue(log.contains("batch-reference:true,true"), log.joined(separator: ","))
        XCTAssertTrue(log.contains("batch-ref-audio:true,true"), log.joined(separator: ","))
        XCTAssertTrue(log.contains("batch-ref-text:true,true"), log.joined(separator: ","))
        XCTAssertTrue(log.contains("batch-de-esser:8.5,8.5"), log.joined(separator: ","))
        XCTAssertFalse(log.contains("single-start:tail"), log.joined(separator: ","))
        XCTAssertFalse(log.contains("single-start:stem"), log.joined(separator: ","))
    }

    @MainActor
    func testQwenSpeechBackendStreamsTaskStarterTailAndFirstStemWhenEnabled() async throws {
        let events = AsyncEventLog()
        let trace = TraceRecorder()
        let runtime = StreamingRecordingQwenSynthesizer(
            events: events,
            labelsByText: [
                "Which of the following": "starter",
                "best explains this finding?": "tail",
                "A stem follows.": "stem",
            ],
            delaysByLabel: [
                "tail": 180_000_000
            ]
        )
        let playback = RecordingQwenPlayback(events: events)
        let backend = QwenSpeechBackend(
            settings: qwenSmallSettings(),
            runtime: runtime,
            playback: playback,
            traceSink: trace,
            streamingEnabledOverride: true
        )

        try await backend.speak([
            SpeechPlaybackItem(id: "starter", segmentID: "task#starter", text: "Which of the following"),
            SpeechPlaybackItem(id: "tail", segmentID: "task#tail", text: "best explains this finding?"),
            SpeechPlaybackItem(id: "stem", segmentID: "stem", text: "A stem follows."),
        ]) { _ in }

        let log = await events.snapshot()
        XCTAssertLessThan(
            try index(of: "stream-start:starter", in: log),
            try index(of: "play-stream:task#starter", in: log),
            log.joined(separator: ",")
        )
        XCTAssertLessThan(
            try index(of: "play-stream:task#starter", in: log),
            try index(of: "play-stream:task#tail", in: log),
            log.joined(separator: ",")
        )
        XCTAssertLessThan(
            try index(of: "play-stream:task#tail", in: log),
            try index(of: "play-stream:stem", in: log),
            log.joined(separator: ",")
        )
        XCTAssertTrue(log.contains("stream-start:tail"), log.joined(separator: ","))
        XCTAssertTrue(log.contains("stream-start:stem"), log.joined(separator: ","))
        XCTAssertFalse(log.contains("single-start:starter"), log.joined(separator: ","))
        XCTAssertFalse(log.contains("single-start:tail"), log.joined(separator: ","))
        XCTAssertFalse(log.contains("batch-start:stem"), log.joined(separator: ","))

        let traceEvents = await trace.snapshot()
        let firstPrepared = try XCTUnwrap(traceEvents.first { $0.kind == .firstPrepared })
        XCTAssertEqual(firstPrepared.itemIndex, 0)
        let firstBatch = try XCTUnwrap(traceEvents.first { $0.kind == .playbackBatchStart })
        XCTAssertEqual(firstBatch.batchCount, 1)
    }

    @MainActor
    func testQwenFastDefaultsToCompleteFileBatchPlayback() async throws {
        let events = AsyncEventLog()
        let runtime = StreamingRecordingQwenSynthesizer(
            events: events,
            labelsByText: [
                "First segment.": "first",
                "Second segment.": "second",
                "Third segment.": "third",
            ]
        )
        let playback = RecordingQwenPlayback(events: events)
        let backend = QwenSpeechBackend(
            settings: qwenSmallSettings(),
            runtime: runtime,
            playback: playback
        )

        try await backend.speak([
            SpeechPlaybackItem(id: "first", segmentID: "first", text: "First segment."),
            SpeechPlaybackItem(id: "second", segmentID: "second", text: "Second segment."),
            SpeechPlaybackItem(id: "third", segmentID: "third", text: "Third segment."),
        ]) { _ in }

        let log = await events.snapshot()
        XCTAssertTrue(log.contains("single-start:first"), log.joined(separator: ","))
        XCTAssertTrue(log.contains("batch-start:second,third"), log.joined(separator: ","))
        XCTAssertFalse(log.contains { $0.hasPrefix("stream-start:") }, log.joined(separator: ","))
        XCTAssertFalse(log.contains { $0.hasPrefix("play-stream:") }, log.joined(separator: ","))
    }

    @MainActor
    func testQwenBestDefaultsToCompleteFileBatchPlayback() async throws {
        let events = AsyncEventLog()
        let runtime = StreamingRecordingQwenSynthesizer(
            events: events,
            labelsByText: [
                "First segment.": "first",
                "Second segment.": "second",
                "Third segment.": "third",
            ]
        )
        let playback = RecordingQwenPlayback(events: events)
        var settings = qwenSmallSettings()
        settings.engineID = .qwenBest
        let backend = QwenSpeechBackend(
            settings: settings,
            runtime: runtime,
            playback: playback
        )

        try await backend.speak([
            SpeechPlaybackItem(id: "first", segmentID: "first", text: "First segment."),
            SpeechPlaybackItem(id: "second", segmentID: "second", text: "Second segment."),
            SpeechPlaybackItem(id: "third", segmentID: "third", text: "Third segment."),
        ]) { _ in }

        let log = await events.snapshot()
        XCTAssertTrue(log.contains("single-start:first"), log.joined(separator: ","))
        XCTAssertTrue(log.contains("batch-start:second,third"), log.joined(separator: ","))
        XCTAssertFalse(log.contains { $0.hasPrefix("stream-start:") }, log.joined(separator: ","))
        XCTAssertFalse(log.contains { $0.hasPrefix("play-stream:") }, log.joined(separator: ","))
    }

    @MainActor
    func testQwenSpeechBackendHoldsReferenceStarterUntilTailStreamHasRunway() async throws {
        let events = AsyncEventLog()
        let runtime = StreamingRecordingQwenSynthesizer(
            events: events,
            labelsByText: [
                "Which of the following": "starter",
                "best explains this finding?": "tail",
                "A stem follows.": "stem",
            ],
            delaysByLabel: [
                "tail": 120_000_000
            ]
        )
        let playback = RecordingQwenPlayback(events: events)
        var settings = qwenSmallSettings()
        settings.qwenUseReferenceVoice = true
        settings.qwenReferenceVoiceID = .studentClone
        settings.qwenStudentReferenceVoice = QwenStudentReferenceVoice(
            audioPath: "/tmp/synthetic-student-reference.wav",
            transcript: "Synthetic reference transcript.",
            durationSeconds: 11.0
        )
        let backend = QwenSpeechBackend(
            settings: settings,
            runtime: runtime,
            playback: playback,
            streamingEnabledOverride: true
        )

        try await backend.speak([
            SpeechPlaybackItem(id: "starter", segmentID: "task#starter", text: "Which of the following"),
            SpeechPlaybackItem(id: "tail", segmentID: "task#tail", text: "best explains this finding?"),
            SpeechPlaybackItem(id: "stem", segmentID: "stem", text: "A stem follows."),
        ]) { _ in }

        let log = await events.snapshot()
        XCTAssertLessThan(
            try index(of: "stream-chunk:tail", in: log),
            try index(of: "play-stream:task#starter", in: log),
            log.joined(separator: ",")
        )
        XCTAssertLessThan(
            try index(of: "stream-start:stem", in: log),
            try index(of: "play-stream:task#tail", in: log),
            log.joined(separator: ",")
        )
        XCTAssertLessThan(
            try index(of: "play-stream:task#starter", in: log),
            try index(of: "play-stream:task#tail", in: log),
            log.joined(separator: ",")
        )
        XCTAssertLessThan(
            try index(of: "stream-start:stem", in: log),
            try index(of: "play-stream:stem", in: log),
            log.joined(separator: ",")
        )
    }

    @MainActor
    func testQwenSpeechBackendStartsReferenceStemStreamEarlyAfterPromptLibraryHit() async throws {
        let events = AsyncEventLog()
        let fullPrompt = "Which of the following best explains this finding?"
        let runtime = StreamingRecordingQwenSynthesizer(
            events: events,
            labelsByText: [
                fullPrompt: "full-prompt",
                "Which of the following": "starter",
                "best explains this finding?": "tail",
                "A stem follows.": "stem",
            ],
            delaysByLabel: [
                "stem": 120_000_000
            ],
            restoreHits: [fullPrompt]
        )
        let playback = RecordingQwenPlayback(events: events)
        var settings = qwenSmallSettings()
        settings.qwenUseReferenceVoice = true
        settings.qwenReferenceVoiceID = .studentClone
        settings.qwenStudentReferenceVoice = QwenStudentReferenceVoice(
            audioPath: "/tmp/synthetic-student-reference.wav",
            transcript: "Synthetic reference transcript.",
            durationSeconds: 11.0
        )
        let backend = QwenSpeechBackend(
            settings: settings,
            runtime: runtime,
            playback: playback,
            streamingEnabledOverride: true
        )

        try await backend.speak([
            SpeechPlaybackItem(id: "starter", segmentID: "task#starter", text: "Which of the following"),
            SpeechPlaybackItem(id: "tail", segmentID: "task#tail", text: "best explains this finding?"),
            SpeechPlaybackItem(id: "stem", segmentID: "stem", text: "A stem follows."),
        ]) { _ in }

        let log = await events.snapshot()
        XCTAssertTrue(log.contains("restore-hit:full-prompt"), log.joined(separator: ","))
        XCTAssertLessThan(
            try index(of: "stream-chunk:stem", in: log),
            try index(of: "play-stream:task#starter", in: log),
            log.joined(separator: ",")
        )
        XCTAssertFalse(log.contains("stream-start:tail"), log.joined(separator: ","))
        XCTAssertFalse(log.contains("single-start:stem"), log.joined(separator: ","))
    }

    @MainActor
    func testQwenSpeechBackendUsesPreparedPlaybackForPromptLibraryHitWhenStreamingDisabled() async throws {
        let events = AsyncEventLog()
        let fullPrompt = "Which of the following best explains this finding?"
        let runtime = StreamingRecordingQwenSynthesizer(
            events: events,
            labelsByText: [
                fullPrompt: "full-prompt",
                "Which of the following": "starter",
                "best explains this finding?": "tail",
                "Stem one.": "stem-1",
                "Stem two.": "stem-2",
            ],
            delaysByLabel: [
                "full-prompt": 120_000_000,
                "stem-2": 120_000_000,
            ],
            restoreHits: [fullPrompt]
        )
        let playback = RecordingQwenPlayback(events: events)
        let backend = QwenSpeechBackend(
            settings: qwenSmallSettings(),
            runtime: runtime,
            playback: playback,
            streamingEnabledOverride: false
        )

        try await backend.speak([
            SpeechPlaybackItem(id: "starter", segmentID: "task#starter", text: "Which of the following"),
            SpeechPlaybackItem(id: "tail", segmentID: "task#tail", text: "best explains this finding?"),
            SpeechPlaybackItem(id: "stem-1", segmentID: "stem-1", text: "Stem one."),
            SpeechPlaybackItem(id: "stem-2", segmentID: "stem-2", text: "Stem two."),
        ]) { _ in }

        let log = await events.snapshot()
        XCTAssertTrue(log.contains("restore-hit:full-prompt"), log.joined(separator: ","))
        XCTAssertTrue(log.contains("single-start:full-prompt"), log.joined(separator: ","))
        XCTAssertTrue(log.contains("batch-start:stem-1,stem-2"), log.joined(separator: ","))
        XCTAssertTrue(log.contains("play-sequence:full-prompt.wav,stem-1.wav,stem-2.wav"), log.joined(separator: ","))
        XCTAssertFalse(log.contains("stream-start:tail"), log.joined(separator: ","))
        XCTAssertFalse(log.contains("stream-start:stem-1"), log.joined(separator: ","))
        XCTAssertFalse(log.contains("stream-start:stem-2"), log.joined(separator: ","))
        XCTAssertFalse(log.contains("play-stream:task#starter"), log.joined(separator: ","))
    }

    @MainActor
    func testQwenSpeechBackendStartsReferenceCompleteLookaheadAtFirstStem() async throws {
        let events = AsyncEventLog()
        let labelsByText = [
            "Which of the following": "starter",
            "best explains this finding?": "tail",
            "Stem one.": "stem-1",
            "Stem two.": "stem-2",
            "Stem three.": "stem-3",
            "Stem four.": "stem-4",
            "Long uncached continuation one.": "lookahead-1",
            "Long uncached continuation two.": "lookahead-2",
        ]
        let runtime = StreamingRecordingQwenSynthesizer(
            events: events,
            labelsByText: labelsByText,
            delaysByLabel: [
                "stem-2": 60_000_000,
                "stem-3": 60_000_000,
                "stem-4": 60_000_000,
            ]
        )
        let playback = RecordingQwenPlayback(events: events)
        var settings = qwenSmallSettings()
        settings.qwenUseReferenceVoice = true
        settings.qwenReferenceVoiceID = .studentClone
        settings.qwenStudentReferenceVoice = QwenStudentReferenceVoice(
            audioPath: "/tmp/synthetic-student-reference.wav",
            transcript: "Synthetic reference transcript.",
            durationSeconds: 11.0
        )
        let backend = QwenSpeechBackend(
            settings: settings,
            runtime: runtime,
            playback: playback,
            streamingEnabledOverride: true
        )

        try await backend.speak([
            SpeechPlaybackItem(id: "starter", segmentID: "task#starter", text: "Which of the following"),
            SpeechPlaybackItem(id: "tail", segmentID: "task#tail", text: "best explains this finding?"),
            SpeechPlaybackItem(id: "stem-1", segmentID: "stem-1", text: "Stem one."),
            SpeechPlaybackItem(id: "stem-2", segmentID: "stem-2", text: "Stem two."),
            SpeechPlaybackItem(id: "stem-3", segmentID: "stem-3", text: "Stem three."),
            SpeechPlaybackItem(id: "stem-4", segmentID: "stem-4", text: "Stem four."),
            SpeechPlaybackItem(id: "lookahead-1", segmentID: "lookahead-1", text: "Long uncached continuation one."),
            SpeechPlaybackItem(id: "lookahead-2", segmentID: "lookahead-2", text: "Long uncached continuation two."),
        ]) { _ in }

        let log = await events.snapshot()
        XCTAssertLessThan(
            try index(of: "play-stream:stem-1", in: log),
            try index(of: "single-start:lookahead-1", in: log),
            log.joined(separator: ",")
        )
        XCTAssertLessThan(
            try index(of: "single-start:lookahead-1", in: log),
            try index(of: "play-stream:stem-4", in: log),
            log.joined(separator: ",")
        )
        XCTAssertLessThan(
            try index(of: "batch-start:lookahead-2", in: log),
            try index(of: "play-stream:stem-4", in: log),
            log.joined(separator: ",")
        )
    }

    @MainActor
    func testQwenPlaybackTraceRecordsTimingAndOrderWithoutText() async throws {
        let events = AsyncEventLog()
        let trace = TraceRecorder()
        let runtime = FakeQwenSynthesizer(
            events: events,
            labelsByText: [
                "Which of the following": "task-starter",
                "tail": "task-tail",
            ],
            durationsByLabel: [
                "task-starter": 0.05,
                "task-tail": 0.40,
            ]
        )
        let playback = RecordingQwenPlayback(events: events)
        let backend = QwenSpeechBackend(
            settings: qwenSmallSettings(),
            runtime: runtime,
            playback: playback,
            traceSink: trace
        )

        try await backend.speak([
            SpeechPlaybackItem(id: "starter", segmentID: "task#starter", text: "Which of the following"),
            SpeechPlaybackItem(id: "tail", segmentID: "task#tail", text: "tail"),
        ]) { _ in }

        let traceEvents = await trace.snapshot()
        XCTAssertTrue(traceEvents.contains { $0.kind == .requestStart })
        XCTAssertTrue(traceEvents.contains { $0.kind == .firstPrepared && $0.itemIndex == 0 && $0.cacheHit == false })
        XCTAssertTrue(traceEvents.contains { $0.kind == .initialBufferWait && $0.itemIndex == 1 })
        XCTAssertTrue(traceEvents.contains { $0.kind == .playbackBatchStart && $0.itemIndex == 0 && $0.batchCount == 2 })
        XCTAssertEqual(
            traceEvents.filter { $0.kind == .playbackItemStart }.compactMap(\.itemIndex),
            [0, 1]
        )
    }

    func testQwenPlaybackTraceSummaryReportsFirstAudioAndInterItemGapsWithoutText() throws {
        let events = [
            QwenPlaybackTraceEvent(kind: .requestStart, elapsedSeconds: 0),
            QwenPlaybackTraceEvent(
                kind: .playbackItemStart,
                itemIndex: 0,
                itemID: "starter",
                segmentID: "task#starter",
                elapsedSeconds: 0.50,
                durationSeconds: 0.25
            ),
            QwenPlaybackTraceEvent(
                kind: .playbackItemStart,
                itemIndex: 1,
                itemID: "tail",
                segmentID: "task#tail",
                elapsedSeconds: 1.20,
                durationSeconds: 0.40
            ),
            QwenPlaybackTraceEvent(
                kind: .playbackItemStart,
                itemIndex: 2,
                itemID: "stem",
                segmentID: "stem",
                elapsedSeconds: 1.62,
                durationSeconds: 0.50
            ),
        ]

        let summary = QwenPlaybackTraceSummary(events: events, rateMultiplier: 1.0)

        XCTAssertEqual(try XCTUnwrap(summary.firstAudioSeconds), 0.50, accuracy: 0.0001)
        XCTAssertEqual(try XCTUnwrap(summary.maxInterItemGapSeconds), 0.45, accuracy: 0.0001)
        XCTAssertEqual(summary.gaps.map(\.previousSegmentID), ["task#starter", "task#tail"])
        XCTAssertEqual(summary.gaps.map(\.nextSegmentID), ["task#tail", "stem"])
        XCTAssertEqual(summary.gaps.map(\.gapSeconds), [0.45, 0.02])

        let encoded = String(data: try JSONEncoder().encode(summary), encoding: .utf8) ?? ""
        XCTAssertFalse(encoded.contains("Which of the following"))
        XCTAssertFalse(encoded.contains("private"))
    }

    func testQwenPlaybackTraceSummaryUsesItemEndForStreamingDuration() throws {
        let events = [
            QwenPlaybackTraceEvent(kind: .requestStart, elapsedSeconds: 0),
            QwenPlaybackTraceEvent(
                kind: .playbackItemStart,
                itemIndex: 0,
                itemID: "starter",
                segmentID: "task#starter",
                elapsedSeconds: 0.05,
                durationSeconds: 0
            ),
            QwenPlaybackTraceEvent(
                kind: .playbackItemEnd,
                itemIndex: 0,
                itemID: "starter",
                segmentID: "task#starter",
                elapsedSeconds: 1.25
            ),
            QwenPlaybackTraceEvent(
                kind: .playbackItemStart,
                itemIndex: 1,
                itemID: "tail",
                segmentID: "task#tail",
                elapsedSeconds: 1.31,
                durationSeconds: 0.40
            ),
        ]

        let summary = QwenPlaybackTraceSummary(events: events, rateMultiplier: 1.0)

        XCTAssertEqual(summary.gaps.map(\.gapSeconds), [0.06])
        XCTAssertEqual(try XCTUnwrap(summary.maxInterItemGapSeconds), 0.06, accuracy: 0.0001)
    }

    func testQwenPlaybackTraceSummaryEncodesLongGapCountsAndRollingMetadataWithoutText() throws {
        let events = [
            QwenPlaybackTraceEvent(kind: .requestStart, elapsedSeconds: 0),
            QwenPlaybackTraceEvent(
                kind: .playbackItemStart,
                itemIndex: 0,
                itemID: "starter",
                segmentID: "task#starter",
                elapsedSeconds: 0.50,
                durationSeconds: 0.20
            ),
            QwenPlaybackTraceEvent(
                kind: .playbackItemStart,
                itemIndex: 1,
                itemID: "tail",
                segmentID: "task#tail",
                elapsedSeconds: 1.90,
                durationSeconds: 0.40
            ),
            QwenPlaybackTraceEvent(
                kind: .playbackItemStart,
                itemIndex: 2,
                itemID: "stem",
                segmentID: "stem",
                elapsedSeconds: 4.60,
                durationSeconds: 0.50
            ),
        ]
        let summary = QwenPlaybackTraceSummary(events: events, rateMultiplier: 1.0)

        let data = try JSONEncoder().encode(summary)
        let object = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])

        XCTAssertEqual(object["longGapOverOneSecondCount"] as? Int, 2)
        XCTAssertEqual(object["longGapOverTwoSecondCount"] as? Int, 1)
        XCTAssertEqual(object["p95InterItemGapSeconds"] as? Double ?? -1, 2.245, accuracy: 0.0001)
        let rolling = try XCTUnwrap(object["rollingSummaries"] as? [[String: Any]])
        XCTAssertFalse(rolling.isEmpty)
        XCTAssertEqual(rolling.first?["longGapOverOneSecondCount"] as? Int, 2)

        let encoded = String(data: data, encoding: .utf8) ?? ""
        XCTAssertTrue(encoded.contains("task#starter"))
        XCTAssertFalse(encoded.contains("Which of the following"))
        XCTAssertFalse(encoded.contains("private"))
    }

    func testQwenStreamingAudioChunkEncodesOnlyPlaybackMetadata() throws {
        let privateText = "A private question stem should never be encoded."
        let privatePath = "/Users/example/private-reference.wav"
        let chunk = QwenStreamingAudioChunk(
            requestID: "stream-request",
            itemIndex: 2,
            sequenceIndex: 3,
            sampleRate: 24_000,
            audioData: Data([0, 1, 2, 3]),
            durationSeconds: 0.32,
            isFinal: false,
            elapsedSeconds: 0.69,
            peakMemoryBytes: 4_200_000_000
        )

        let encoded = String(data: try JSONEncoder().encode(chunk), encoding: .utf8) ?? ""

        XCTAssertTrue(encoded.contains("stream-request"))
        XCTAssertTrue(encoded.contains("audioData"))
        XCTAssertTrue(encoded.contains("peakMemoryBytes"))
        XCTAssertFalse(encoded.contains(privateText))
        XCTAssertFalse(encoded.contains(privatePath))
        XCTAssertFalse(encoded.contains("text"))
        XCTAssertFalse(encoded.contains("audioPath"))
    }

    func testQwenAudioTroubleshootingFixtureUsesSyntheticSplitQuestionPlan() {
        let items = QwenAudioTroubleshootingFixture.syntheticQuestionPlaybackItems()
        let combinedText = items.map(\.text).joined(separator: " ")

        XCTAssertEqual(
            items.map(\.segmentID),
            [
                "synthetic-task#starter",
                "synthetic-task#tail",
                "synthetic-stem-1",
                "synthetic-stem-2",
            ])
        XCTAssertEqual(items.first?.text, "Which of the following findings best explains")
        XCTAssertFalse(combinedText.localizedCaseInsensitiveContains("UWorld"))
        XCTAssertFalse(combinedText.localizedCaseInsensitiveContains("private"))
    }

    func testQwenAudioTroubleshootingFixtureKeepsTaskWholeWhenPromptLibraryDisabled() {
        let items = QwenAudioTroubleshootingFixture.syntheticQuestionPlaybackItems(
            options: ReadPlanOptions(usesQuestionPromptAudioLibrary: false)
        )
        let combinedText = items.map(\.text).joined(separator: " ")

        XCTAssertEqual(
            items.map(\.segmentID),
            [
                "synthetic-task#task",
                "synthetic-stem-1",
                "synthetic-stem-2",
            ])
        XCTAssertTrue(combinedText.contains("Which of the following findings best explains this synthetic pattern?"))
        XCTAssertFalse(combinedText.localizedCaseInsensitiveContains("UWorld"))
        XCTAssertFalse(combinedText.localizedCaseInsensitiveContains("private"))
    }

    func testQwenHelperCapsBatchGenerationAtSerialMaxTokens() throws {
        let helperURL = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .appendingPathComponent("Sources/SalientCore/Resources/qwen_tts_helper.py")
        let source = try String(contentsOf: helperURL, encoding: .utf8)

        XCTAssertTrue(source.contains("DEFAULT_MAX_TOKENS = 1200"))
        XCTAssertTrue(source.contains("max_tokens=DEFAULT_MAX_TOKENS"))
    }

    func testQwenHelperKeepsReferenceBatchingExperimentalAndUsesStablePenalty() throws {
        let helperURL = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .appendingPathComponent("Sources/SalientCore/Resources/qwen_tts_helper.py")
        let source = try String(contentsOf: helperURL, encoding: .utf8)

        XCTAssertTrue(source.contains("shared_ref_audio"))
        XCTAssertTrue(source.contains("shared_ref_text"))
        XCTAssertTrue(source.contains("voice = None"))
        XCTAssertTrue(source.contains("SALIENT_QWEN_REFERENCE_BATCHING"))
        XCTAssertTrue(source.contains("REFERENCE_REPETITION_PENALTY = 1.1"))
        XCTAssertFalse(source.contains("repetition_penalty = 1.5"))
    }

    func testQwenHelperDefinesStreamingJsonEventsWithoutTextOrPrivatePaths() throws {
        let helperURL = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .appendingPathComponent("Sources/SalientCore/Resources/qwen_tts_helper.py")
        let source = try String(contentsOf: helperURL, encoding: .utf8)

        for event in ["stream_start", "audio_chunk", "stream_item_done", "stream_done", "stream_error"] {
            XCTAssertTrue(source.contains(event), event)
        }
        for field in [
            "request_id", "item_index", "sequence_idx", "sample_rate", "chunk_duration_seconds", "audio_b64", "is_final_chunk",
            "elapsed_seconds", "peak_mlx_memory_bytes", "mlx_device",
        ] {
            XCTAssertTrue(source.contains(field), field)
        }
        XCTAssertTrue(source.contains("streaming_interval=streaming_interval"))
        XCTAssertFalse(source.contains("\"text\" :"))
        XCTAssertFalse(source.contains("\"text\":"))
        XCTAssertFalse(source.contains("\"ref_audio\" :"))
        XCTAssertFalse(source.contains("\"ref_audio\":"))
    }

    private func temporaryRuntimeRoot() -> URL {
        URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("salient-qwen-tests-\(UUID().uuidString)", isDirectory: true)
    }

    private func qwenSmallSettings(speaker: String = "Aiden") -> SpeechSettings {
        SpeechSettings(
            engineID: .qwenSmall,
            rateMultiplier: 2.4,
            volume: 0,
            pitchMultiplier: 1.0,
            voiceIdentifier: nil,
            qwenSpeaker: speaker
        )
    }

    private func index(of event: String, in events: [String]) throws -> Int {
        try XCTUnwrap(events.firstIndex(of: event), "Missing event \(event) in \(events)")
    }

    private func cachedWAVs(in root: URL) throws -> [String] {
        let cache = root.appendingPathComponent("cache", isDirectory: true)
        guard FileManager.default.fileExists(atPath: cache.path) else {
            return []
        }
        return try FileManager.default.contentsOfDirectory(
            at: cache,
            includingPropertiesForKeys: nil
        )
        .filter { $0.pathExtension == "wav" }
        .map(\.lastPathComponent)
        .sorted()
    }

    private func synthCommandCount(in recorder: CommandRecorder) async -> Int {
        await recorder.commands.filter { $0.redactedDescription.hasPrefix("qwen synthesize") }.count
    }

    private func cacheMaintenanceState(in root: URL) throws -> CacheMaintenanceStateSnapshot {
        let data = try Data(contentsOf: root.appendingPathComponent("cache-state.json"))
        return try JSONDecoder().decode(CacheMaintenanceStateSnapshot.self, from: data)
    }

    private func writeCacheMaintenanceState(lastClearedAt: Date, in root: URL) throws {
        let data = try JSONEncoder().encode(CacheMaintenanceStateSnapshot(lastClearedAt: lastClearedAt))
        try data.write(to: root.appendingPathComponent("cache-state.json"), options: .atomic)
    }

    private func makeFakeRuntimeReady(root: URL, lane: QwenModelLane, useReferenceVoice: Bool = false) throws {
        try Self.makeExecutableFile(at: root.appendingPathComponent("venv/bin/python"))
        try Self.makeFakeModelReady(root: root, lane: lane, useReferenceVoice: useReferenceVoice)
    }

    private func makeFakeUVReady(root: URL) throws {
        try Self.makeExecutableFile(at: root.appendingPathComponent("bin/uv"))
    }

    private static func makeFakeModelReady(root: URL, lane: QwenModelLane, useReferenceVoice: Bool = false) throws {
        let suffix = useReferenceVoice ? "\(lane.rawValue)-reference" : lane.rawValue
        try makeFakeModelReady(directory: root.appendingPathComponent("models/\(suffix)"))
    }

    private static func makeFakeModelReady(directory: URL) throws {
        let model = directory.appendingPathComponent("config.json")
        try FileManager.default.createDirectory(at: model.deletingLastPathComponent(), withIntermediateDirectories: true)
        try "{}".write(to: model, atomically: true, encoding: .utf8)
        try "synthetic-weights".write(
            to: model.deletingLastPathComponent().appendingPathComponent("model.safetensors"),
            atomically: true,
            encoding: .utf8
        )
    }

    private static func makeExecutableFile(at url: URL) throws {
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try "#!/bin/sh\n".write(to: url, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: url.path)
    }

    private func writeFakeResidentPython(root: URL, processLog: URL) throws {
        let pythonURL = root.appendingPathComponent("venv/bin/python")
        try FileManager.default.createDirectory(at: pythonURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        let script = """
            #!/usr/bin/env python3
            import json
            import math
            import pathlib
            import struct
            import sys
            import wave

            LOG = r\"\(processLog.path)\"
            pathlib.Path(LOG).parent.mkdir(parents=True, exist_ok=True)
            with open(LOG, "a", encoding="utf-8") as handle:
                handle.write("start\\n")

            print(json.dumps({"ok": True, "event": "ready"}), flush=True)

            def write_wav(path):
                path = pathlib.Path(path)
                path.parent.mkdir(parents=True, exist_ok=True)
                sample_rate = 24000
                frames = []
                for frame in range(2400):
                    sample = int(math.sin(frame / 10.0) * 2000)
                    frames.append(struct.pack("<h", sample))
                with wave.open(str(path), "wb") as wav:
                    wav.setnchannels(1)
                    wav.setsampwidth(2)
                    wav.setframerate(sample_rate)
                    wav.writeframes(b"".join(frames))

            for line in sys.stdin:
                payload = json.loads(line)
                response_items = []
                for item in payload["items"]:
                    write_wav(item["output"])
                    response_items.append({"output": item["output"], "bytes": pathlib.Path(item["output"]).stat().st_size})
                print(json.dumps({"id": payload["id"], "ok": True, "items": response_items}), flush=True)
            """
        try script.write(to: pythonURL, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: pythonURL.path)
    }

    private static func writeTestWAV(to url: URL) throws {
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        let format = AVAudioFormat(standardFormatWithSampleRate: 24_000, channels: 1)!
        let file = try AVAudioFile(forWriting: url, settings: format.settings)
        let frameCount = AVAudioFrameCount(2_400)
        let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: frameCount)!
        buffer.frameLength = frameCount
        let samples = buffer.floatChannelData![0]
        for frame in 0..<Int(frameCount) {
            samples[frame] = frame < 200 || frame > 2_200 ? 0 : 0.05
        }
        try file.write(from: buffer)
    }

    private static func writeSteppedEnergyWAV(to url: URL) throws {
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        let sampleRate = 24_000.0
        let format = AVAudioFormat(standardFormatWithSampleRate: sampleRate, channels: 1)!
        let file = try AVAudioFile(forWriting: url, settings: format.settings)
        let frameCount = AVAudioFrameCount(sampleRate * 0.7)
        let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: frameCount)!
        buffer.frameLength = frameCount
        let samples = buffer.floatChannelData![0]
        for frame in 0..<Int(frameCount) {
            let time = Double(frame) / sampleRate
            let amplitude = time < 0.35 ? 0.012 : 0.14
            samples[frame] = Float(sin(2 * Double.pi * 440 * time) * amplitude)
        }
        try file.write(from: buffer)
    }

    private static func writeConstantWAV(
        to url: URL,
        durationSeconds: Double,
        amplitude: Float,
        frequency: Double = 440.0
    ) throws {
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        let sampleRate = 24_000.0
        let format = AVAudioFormat(standardFormatWithSampleRate: sampleRate, channels: 1)!
        let file = try AVAudioFile(forWriting: url, settings: format.settings)
        let frameCount = AVAudioFrameCount(sampleRate * durationSeconds)
        let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: frameCount)!
        buffer.frameLength = frameCount
        let samples = buffer.floatChannelData![0]
        for frame in 0..<Int(frameCount) {
            let time = Double(frame) / sampleRate
            samples[frame] = Float(sin(2 * Double.pi * frequency * time) * Double(amplitude))
        }
        try file.write(from: buffer)
    }

    private static func streamingPCMChunk(
        sequenceIndex: Int,
        frequency: Double,
        durationSeconds: Double,
        sampleRate: Double = 24_000,
        amplitude: Float = 0.14,
        isFinal: Bool
    ) -> QwenStreamingAudioChunk {
        let frameCount = max(1, Int(sampleRate * durationSeconds))
        var samples = [Float](repeating: 0, count: frameCount)
        for frame in 0..<frameCount {
            let time = Double(frame) / sampleRate
            samples[frame] = Float(sin(2 * Double.pi * frequency * time) * Double(amplitude))
        }
        let data = samples.withUnsafeBufferPointer { pointer in
            Data(buffer: pointer)
        }
        return QwenStreamingAudioChunk(
            requestID: "streaming-test",
            itemIndex: 0,
            sequenceIndex: sequenceIndex,
            sampleRate: sampleRate,
            audioData: data,
            durationSeconds: durationSeconds,
            isFinal: isFinal,
            elapsedSeconds: durationSeconds * Double(sequenceIndex + 1),
            peakMemoryBytes: nil
        )
    }

    private static func writeReferenceWAV(
        to url: URL,
        durationSeconds: Double,
        sampleRate: Double = 24_000,
        channels: AVAudioChannelCount = 1,
        amplitude: Float = 0.1
    ) throws {
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        let channelCount = Int(channels)
        let sampleRateInt = UInt32(sampleRate)
        let frameCount = Int(durationSeconds * sampleRate)
        let bytesPerSample = 2
        let blockAlign = UInt16(channelCount * bytesPerSample)
        let byteRate = sampleRateInt * UInt32(blockAlign)
        let dataSize = UInt32(frameCount * channelCount * bytesPerSample)

        var data = Data()
        func appendASCII(_ text: String) {
            data.append(Data(text.utf8))
        }
        func appendUInt16(_ value: UInt16) {
            var littleEndian = value.littleEndian
            data.append(Data(bytes: &littleEndian, count: MemoryLayout<UInt16>.size))
        }
        func appendUInt32(_ value: UInt32) {
            var littleEndian = value.littleEndian
            data.append(Data(bytes: &littleEndian, count: MemoryLayout<UInt32>.size))
        }
        func appendInt16(_ value: Int16) {
            var littleEndian = value.littleEndian
            data.append(Data(bytes: &littleEndian, count: MemoryLayout<Int16>.size))
        }

        appendASCII("RIFF")
        appendUInt32(36 + dataSize)
        appendASCII("WAVE")
        appendASCII("fmt ")
        appendUInt32(16)
        appendUInt16(1)
        appendUInt16(UInt16(channelCount))
        appendUInt32(sampleRateInt)
        appendUInt32(byteRate)
        appendUInt16(blockAlign)
        appendUInt16(16)
        appendASCII("data")
        appendUInt32(dataSize)

        for frame in 0..<frameCount {
            let normalized = amplitude == 0 ? 0 : sin(Float(frame) / 17.0) * amplitude
            let sample = Int16(max(-1, min(1, normalized)) * Float(Int16.max))
            for _ in 0..<channelCount {
                appendInt16(sample)
            }
        }
        try data.write(to: url)
    }
}

private struct CacheMaintenanceStateSnapshot: Codable {
    var lastClearedAt: Date
}

private final class CapacitySequence: @unchecked Sendable {
    private let lock = NSLock()
    private var values: [Int64]

    init(_ values: [Int64]) {
        self.values = values
    }

    func next(_ url: URL) throws -> Int64? {
        lock.lock()
        defer { lock.unlock() }
        if values.count > 1 {
            return values.removeFirst()
        }
        return values.first
    }
}

private final class ThreadSafeFlag: @unchecked Sendable {
    private let lock = NSLock()
    private var storage = false

    var value: Bool {
        lock.lock()
        defer { lock.unlock() }
        return storage
    }

    func set() {
        lock.lock()
        storage = true
        lock.unlock()
    }
}

private actor CommandRecorder {
    private(set) var commands: [QwenShellCommand] = []

    func record(_ command: QwenShellCommand) {
        commands.append(command)
    }
}

private struct RecordingRunner: QwenCommandRunning {
    var recorder: CommandRecorder
    var handler: @Sendable (QwenShellCommand) throws -> QwenCommandResult

    func run(_ command: QwenShellCommand) async throws -> QwenCommandResult {
        await recorder.record(command)
        return try handler(command)
    }
}

private actor AsyncEventLog {
    private var events: [String] = []

    func append(_ event: String) {
        events.append(event)
    }

    func snapshot() -> [String] {
        events
    }
}

private actor TraceRecorder: QwenPlaybackTracing {
    private var events: [QwenPlaybackTraceEvent] = []

    func record(_ event: QwenPlaybackTraceEvent) {
        events.append(event)
    }

    func snapshot() -> [QwenPlaybackTraceEvent] {
        events
    }
}

@MainActor
private final class RecordingSpeechPlaybackTimingSink: SpeechPlaybackTimingSink {
    private(set) var finalItems: [SpeechPlaybackItem] = []
    private(set) var timings: [SpeechPlaybackItemTiming] = []
    private(set) var finishedItems: [(itemID: String, segmentID: String, itemIndex: Int?)] = []

    func speechPlaybackWillUseFinalItems(_ items: [SpeechPlaybackItem]) {
        finalItems = items
    }

    func speechPlaybackDidReceiveTiming(_ timing: SpeechPlaybackItemTiming) {
        timings.append(timing)
    }

    func speechPlaybackDidFinishItem(itemID: String, segmentID: String, itemIndex: Int?) {
        finishedItems.append((itemID: itemID, segmentID: segmentID, itemIndex: itemIndex))
    }
}

private actor SlowFailingWordAligner: RSVPWordAligning {
    private let events: AsyncEventLog

    init(events: AsyncEventLog) {
        self.events = events
    }

    func align(
        item: SpeechPlaybackItem,
        itemIndex: Int?,
        audioURL: URL
    ) async -> SpeechPlaybackWordCueTrack? {
        await events.append("alignment-start:\(item.id)")
        try? await Task.sleep(for: .seconds(5))
        return nil
    }
}

private actor FakeQwenSynthesizer: QwenAudioSynthesizing {
    private let events: AsyncEventLog
    private let labelsByText: [String: String]
    private let delaysByLabel: [String: UInt64]
    private let durationsByLabel: [String: Double]
    private let cacheHitLabels: Set<String>
    private let gatesByLabel: [String: AsyncTestGate]

    init(
        events: AsyncEventLog,
        labelsByText: [String: String],
        delaysByLabel: [String: UInt64] = [:],
        durationsByLabel: [String: Double] = [:],
        cacheHitLabels: Set<String> = [],
        gatesByLabel: [String: AsyncTestGate] = [:]
    ) {
        self.events = events
        self.labelsByText = labelsByText
        self.delaysByLabel = delaysByLabel
        self.durationsByLabel = durationsByLabel
        self.cacheHitLabels = cacheHitLabels
        self.gatesByLabel = gatesByLabel
    }

    func synthesize(
        text: String,
        lane: QwenModelLane,
        speaker: String,
        language: String,
        rateMultiplier: Double,
        cachePolicy: QwenAudioCachePolicy,
        useReferenceVoice: Bool,
        referenceAudioPath: String?,
        referenceText: String?
    ) async throws -> QwenPreparedAudio {
        let label = labelsByText[text] ?? text
        await events.append("cache-policy:\(label):\(cachePolicy.rawValue)")
        await events.append("prepare-start:\(label)")
        if let gate = gatesByLabel[label] {
            await gate.wait()
            try Task.checkCancellation()
        }
        if let delay = delaysByLabel[label] {
            try await Task.sleep(nanoseconds: delay)
        }
        await events.append("prepare-done:\(label)")
        return QwenPreparedAudio(
            url: URL(fileURLWithPath: "/tmp/\(label).wav"),
            durationSeconds: durationsByLabel[label] ?? 0.05,
            isFromCache: cacheHitLabels.contains(label)
        )
    }
}

private actor AsyncTestGate {
    private(set) var openedBy: String?

    func open(by reason: String) {
        if openedBy == nil {
            openedBy = reason
        }
    }

    func wait() async {
        while openedBy == nil, !Task.isCancelled {
            try? await Task.sleep(nanoseconds: 1_000_000)
        }
    }
}

private actor PromptLibraryRecordingQwenSynthesizer: QwenAudioSynthesizing, QwenPromptAudioLibraryServing {
    private let events: AsyncEventLog
    private let labelsByText: [String: String]
    private let restoreHits: Set<String>

    init(
        events: AsyncEventLog,
        labelsByText: [String: String],
        restoreHits: Set<String>
    ) {
        self.events = events
        self.labelsByText = labelsByText
        self.restoreHits = restoreHits
    }

    func promptAudioLibraryContext(
        lane: QwenModelLane,
        speaker: String,
        language: String,
        useReferenceVoice: Bool,
        referenceAudioPath: String?,
        referenceText: String?
    ) async throws -> QwenPromptAudioLibraryContext {
        let referenceTextHash = referenceText.map { QwenPromptAudioLibrary.hashText($0) } ?? ""
        return QwenPromptAudioLibraryContext(
            lane: lane,
            speaker: speaker,
            language: language,
            useReferenceVoice: useReferenceVoice,
            referenceAudioSignature: referenceAudioPath ?? "",
            referenceTextHash: referenceTextHash,
            cachePipelineVersion: QwenRuntimeManager.cachePipelineVersion,
            referenceAudioPathForSynthesis: referenceAudioPath,
            referenceTextForSynthesis: referenceText
        )
    }

    func restorePromptLibraryAudioIfAvailable(
        text: String,
        context: QwenPromptAudioLibraryContext,
        rateMultiplier: Double
    ) async throws -> Bool {
        let label = labelsByText[text] ?? text
        if restoreHits.contains(text) {
            await events.append("restore-hit:\(label)")
            return true
        }
        await events.append("restore-miss:\(label)")
        return false
    }

    func learnPromptAudio(
        text: String,
        derivedPrefixTexts: [String],
        context: QwenPromptAudioLibraryContext
    ) async {
        let label = labelsByText[text] ?? text
        await events.append("learn:\(label)")
        for derived in derivedPrefixTexts {
            await events.append("learn-derived:\(labelsByText[derived] ?? derived)")
        }
    }

    func synthesize(
        text: String,
        lane: QwenModelLane,
        speaker: String,
        language: String,
        rateMultiplier: Double,
        cachePolicy: QwenAudioCachePolicy,
        useReferenceVoice: Bool,
        referenceAudioPath: String?,
        referenceText: String?
    ) async throws -> QwenPreparedAudio {
        let label = labelsByText[text] ?? text
        await events.append("prepare-start:\(label)")
        await events.append("prepare-done:\(label)")
        return QwenPreparedAudio(
            url: URL(fileURLWithPath: "/tmp/\(label).wav"),
            durationSeconds: 0.20,
            isFromCache: restoreHits.contains(text)
        )
    }
}

private actor BatchRecordingQwenSynthesizer: QwenAudioSynthesizing {
    private let events: AsyncEventLog
    private let labelsByText: [String: String]

    init(events: AsyncEventLog, labelsByText: [String: String]) {
        self.events = events
        self.labelsByText = labelsByText
    }

    func synthesize(
        text: String,
        lane: QwenModelLane,
        speaker: String,
        language: String,
        rateMultiplier: Double,
        cachePolicy: QwenAudioCachePolicy,
        useReferenceVoice: Bool,
        referenceAudioPath: String?,
        referenceText: String?
    ) async throws -> QwenPreparedAudio {
        let label = labelsByText[text] ?? text
        await events.append("single-start:\(label)")
        try await Task.sleep(nanoseconds: 20_000_000)
        await events.append("single-done:\(label)")
        return preparedAudio(label: label)
    }

    func synthesizeBatch(_ requests: [QwenSynthesisRequest]) async throws -> [QwenPreparedAudio] {
        let labels = requests.map { labelsByText[$0.text] ?? $0.text }
        await events.append("batch-start:\(labels.joined(separator: ","))")
        await events.append("batch-reference:\(requests.map { String($0.useReferenceVoice) }.joined(separator: ","))")
        await events.append("batch-ref-audio:\(requests.map { String(!($0.referenceAudioPath ?? "").isEmpty) }.joined(separator: ","))")
        await events.append("batch-ref-text:\(requests.map { String(!($0.referenceText ?? "").isEmpty) }.joined(separator: ","))")
        await events.append(
            "batch-de-esser:\(requests.map { String(format: "%.1f", $0.qwenDeEsserStrengthDecibels) }.joined(separator: ","))"
        )
        try await Task.sleep(nanoseconds: 20_000_000)
        await events.append("batch-done:\(labels.joined(separator: ","))")
        return labels.map(preparedAudio(label:))
    }

    private func preparedAudio(label: String) -> QwenPreparedAudio {
        QwenPreparedAudio(
            url: URL(fileURLWithPath: "/tmp/\(label).wav"),
            durationSeconds: 0.20,
            isFromCache: false
        )
    }
}

private actor StreamingRecordingQwenSynthesizer: QwenAudioSynthesizing, QwenAudioStreaming, QwenPromptAudioLibraryServing {
    private let events: AsyncEventLog
    private let labelsByText: [String: String]
    private let delaysByLabel: [String: UInt64]
    private let restoreHits: Set<String>

    init(
        events: AsyncEventLog,
        labelsByText: [String: String],
        delaysByLabel: [String: UInt64] = [:],
        restoreHits: Set<String> = []
    ) {
        self.events = events
        self.labelsByText = labelsByText
        self.delaysByLabel = delaysByLabel
        self.restoreHits = restoreHits
    }

    func promptAudioLibraryContext(
        lane: QwenModelLane,
        speaker: String,
        language: String,
        useReferenceVoice: Bool,
        referenceAudioPath: String?,
        referenceText: String?
    ) async throws -> QwenPromptAudioLibraryContext {
        QwenPromptAudioLibraryContext(
            lane: lane,
            speaker: speaker,
            language: language,
            useReferenceVoice: useReferenceVoice,
            referenceAudioSignature: referenceAudioPath ?? "",
            referenceTextHash: referenceText.map { QwenPromptAudioLibrary.hashText($0) } ?? "",
            cachePipelineVersion: QwenRuntimeManager.cachePipelineVersion,
            referenceAudioPathForSynthesis: referenceAudioPath,
            referenceTextForSynthesis: referenceText
        )
    }

    func restorePromptLibraryAudioIfAvailable(
        text: String,
        context: QwenPromptAudioLibraryContext,
        rateMultiplier: Double
    ) async throws -> Bool {
        guard restoreHits.contains(text) else { return false }
        await events.append("restore-hit:\(labelsByText[text] ?? text)")
        return true
    }

    func learnPromptAudio(
        text: String,
        derivedPrefixTexts: [String],
        context: QwenPromptAudioLibraryContext
    ) async {
    }

    func synthesize(
        text: String,
        lane: QwenModelLane,
        speaker: String,
        language: String,
        rateMultiplier: Double,
        cachePolicy: QwenAudioCachePolicy,
        useReferenceVoice: Bool,
        referenceAudioPath: String?,
        referenceText: String?
    ) async throws -> QwenPreparedAudio {
        let label = labelsByText[text] ?? text
        await events.append("single-start:\(label)")
        if let delay = delaysByLabel[label] {
            try await Task.sleep(nanoseconds: delay)
        }
        await events.append("single-done:\(label)")
        return preparedAudio(label: label)
    }

    func synthesizeBatch(_ requests: [QwenSynthesisRequest]) async throws -> [QwenPreparedAudio] {
        let labels = requests.map { labelsByText[$0.text] ?? $0.text }
        await events.append("batch-start:\(labels.joined(separator: ","))")
        for label in labels {
            if let delay = delaysByLabel[label] {
                try await Task.sleep(nanoseconds: delay)
            }
            await events.append("prepare-done:\(label)")
        }
        return labels.map(preparedAudio(label:))
    }

    func streamAudio(
        _ request: QwenStreamingSynthesisRequest,
        onChunk: @Sendable @escaping (QwenStreamingAudioChunk) async throws -> Void
    ) async throws {
        let label = labelsByText[request.request.text] ?? request.request.text
        await events.append("stream-start:\(label)")
        try await Task.sleep(nanoseconds: delaysByLabel[label] ?? 20_000_000)
        let samples = [Float](repeating: 0.05, count: 12_000)
        let data = samples.withUnsafeBufferPointer { pointer in
            Data(buffer: pointer)
        }
        await events.append("stream-chunk:\(label)")
        try await onChunk(
            QwenStreamingAudioChunk(
                requestID: request.id,
                itemIndex: request.itemIndex,
                sequenceIndex: 0,
                sampleRate: 24_000,
                audioData: data,
                durationSeconds: 0.5,
                isFinal: true,
                elapsedSeconds: 0.02,
                peakMemoryBytes: 1024
            ))
        await events.append("stream-done:\(label)")
    }

    private func preparedAudio(label: String) -> QwenPreparedAudio {
        QwenPreparedAudio(
            url: URL(fileURLWithPath: "/tmp/\(label).wav"),
            durationSeconds: 0.40,
            isFromCache: false
        )
    }
}

@MainActor
private final class RecordingQwenPlayback: QwenAudioStreamingPlaying {
    weak var visualizationSink: (any SpeechPlaybackVisualizationSink)?

    private let events: AsyncEventLog

    init(events: AsyncEventLog) {
        self.events = events
    }

    func play(url: URL, rateMultiplier: Double, volume: Double) async throws {
        await events.append("play-single:\(url.lastPathComponent)")
    }

    func play(
        _ items: [QwenPreparedPlaybackItem],
        rateMultiplier: Double,
        volume: Double,
        onStartItem: @escaping @MainActor @Sendable (SpeechPlaybackItem) async -> Void
    ) async throws {
        await events.append("play-sequence:\(items.map { $0.audio.url.lastPathComponent }.joined(separator: ","))")
        for item in items {
            await onStartItem(item.item)
        }
        visualizationSink?.speechPlaybackVisualizationAudioDidStart()
    }

    func playStream(
        item: SpeechPlaybackItem,
        chunks: AsyncThrowingStream<QwenStreamingAudioChunk, Error>,
        rateMultiplier: Double,
        volume: Double,
        minimumBufferedPlaybackSeconds: Double,
        targetRunwayPlaybackSeconds: Double,
        onStartItem: @escaping @MainActor @Sendable (SpeechPlaybackItem) async -> Void,
        onBufferEnqueue: @escaping @MainActor @Sendable (SpeechPlaybackItem) async -> Void,
        onRenderStart: @escaping @MainActor @Sendable () async -> Void,
        onFinish: @escaping @MainActor @Sendable () async -> Void,
        onItemEnd: @escaping @MainActor @Sendable (SpeechPlaybackItem) async -> Void
    ) async throws {
        var iterator = chunks.makeAsyncIterator()
        guard try await iterator.next() != nil else {
            return
        }
        await events.append("play-stream:\(item.segmentID)")
        await onBufferEnqueue(item)
        await onRenderStart()
        await onStartItem(item)
        while try await iterator.next() != nil {}
        await onItemEnd(item)
        await onFinish()
        visualizationSink?.speechPlaybackVisualizationAudioDidStart()
    }

    func stop() {}
}

@MainActor
private final class DelayedRecordingQwenPlayback: QwenAudioStreamingPlaying {
    weak var visualizationSink: (any SpeechPlaybackVisualizationSink)?

    private let events: AsyncEventLog
    private let sequenceDelayNanoseconds: UInt64

    init(events: AsyncEventLog, sequenceDelayNanoseconds: UInt64) {
        self.events = events
        self.sequenceDelayNanoseconds = sequenceDelayNanoseconds
    }

    func play(url: URL, rateMultiplier: Double, volume: Double) async throws {
        await events.append("play-single:\(url.lastPathComponent)")
    }

    func play(
        _ items: [QwenPreparedPlaybackItem],
        rateMultiplier: Double,
        volume: Double,
        onStartItem: @escaping @MainActor @Sendable (SpeechPlaybackItem) async -> Void
    ) async throws {
        let label = items.map(\.item.id).joined(separator: ",")
        await events.append("play-start:\(label)")
        for item in items {
            await onStartItem(item.item)
        }
        visualizationSink?.speechPlaybackVisualizationAudioDidStart()
        try await Task.sleep(nanoseconds: sequenceDelayNanoseconds)
        visualizationSink?.speechPlaybackVisualizationAudioDidStop()
        await events.append("play-end:\(label)")
    }

    func playStream(
        item: SpeechPlaybackItem,
        chunks: AsyncThrowingStream<QwenStreamingAudioChunk, Error>,
        rateMultiplier: Double,
        volume: Double,
        minimumBufferedPlaybackSeconds: Double,
        targetRunwayPlaybackSeconds: Double,
        onStartItem: @escaping @MainActor @Sendable (SpeechPlaybackItem) async -> Void,
        onBufferEnqueue: @escaping @MainActor @Sendable (SpeechPlaybackItem) async -> Void,
        onRenderStart: @escaping @MainActor @Sendable () async -> Void,
        onFinish: @escaping @MainActor @Sendable () async -> Void,
        onItemEnd: @escaping @MainActor @Sendable (SpeechPlaybackItem) async -> Void
    ) async throws {
        await events.append("play-stream:\(item.segmentID)")
        await onStartItem(item)
        try await Task.sleep(nanoseconds: sequenceDelayNanoseconds)
        await onItemEnd(item)
        await onFinish()
    }

    func stop() {}
}

private struct FakeAudioMeter: PlaybackAudioMetering {
    var powers: [Float]
    var numberOfChannels: Int { powers.count }

    func averagePower(forChannel channelNumber: Int) -> Float {
        powers[channelNumber]
    }
}

private final class FakeBrowserAutomation: BrowserAutomationService {
    let captureJSON: String
    let eventLog: EventLog?

    init(captureJSON: String, eventLog: EventLog? = nil) {
        self.captureJSON = captureJSON
        self.eventLog = eventLog
    }

    func executeJavaScriptInUWorldTab(_ javaScript: String) async -> BrowserAutomationResult {
        if javaScript.contains("captureUWorldSegments") {
            eventLog?.events.append("capture")
            return .success(captureJSON)
        }
        if javaScript.contains("return \"highlighted\"") {
            if javaScript.contains("\"id\":\"task\"") {
                eventLog?.events.append("highlight:task")
            } else if javaScript.contains("\"id\":\"stem\"") {
                eventLog?.events.append("highlight:stem")
            } else {
                eventLog?.events.append("highlight")
            }
            return .success("highlighted")
        }
        if javaScript.contains("return \"cleared\"") {
            eventLog?.events.append("clear")
            return .success("cleared")
        }
        return .success("clicked")
    }
}

private final class EventLog {
    var events: [String] = []
}

@MainActor
private final class RecordingVisualizationSink: SpeechPlaybackVisualizationSink {
    private let eventLog: EventLog
    private var hasLoggedLevel = false
    private(set) var frames: [SpeechPlaybackVisualizationFrame] = []

    init(eventLog: EventLog) {
        self.eventLog = eventLog
    }

    func speechPlaybackVisualizationDidStart() {
        eventLog.events.append("hud-start")
    }

    func speechPlaybackVisualizationAudioDidStart() {
        eventLog.events.append("hud-audio-start")
    }

    func speechPlaybackVisualizationAudioDidStop() {
        eventLog.events.append("hud-audio-stop")
    }

    func speechPlaybackVisualizationLevelDidChange(_ level: Double) {
        if !hasLoggedLevel {
            eventLog.events.append("hud-level")
            hasLoggedLevel = true
        }
    }

    func speechPlaybackVisualizationFrameDidChange(_ frame: SpeechPlaybackVisualizationFrame) {
        frames.append(frame)
        speechPlaybackVisualizationLevelDidChange(frame.level)
    }

    func speechPlaybackVisualizationDidEnd() {
        eventLog.events.append("hud-end")
    }
}

@MainActor
private final class DelayedSpeechBackend: SpeechBackend {
    private let eventLog: EventLog

    init(eventLog: EventLog) {
        self.eventLog = eventLog
    }

    func speak(_ text: String) async throws {
        eventLog.events.append("speak:\(text)")
        try await Task.sleep(nanoseconds: 120_000_000)
    }

    func stop() async {}
}

@MainActor
private final class CancellableSpeechBackend: SpeechBackend {
    private let eventLog: EventLog

    init(eventLog: EventLog) {
        self.eventLog = eventLog
    }

    func speak(_ text: String) async throws {
        eventLog.events.append("speak:\(text)")
        while !Task.isCancelled {
            try await Task.sleep(nanoseconds: 20_000_000)
        }
        throw CancellationError()
    }

    func stop() async {}
}

@MainActor
private final class OutOfOrderPreparingSpeechBackend: SpeechBackend {
    private let eventLog: EventLog

    init(eventLog: EventLog) {
        self.eventLog = eventLog
    }

    func speak(_ text: String) async throws {
        eventLog.events.append("speak:\(text)")
    }

    func speak(
        _ items: [SpeechPlaybackItem],
        willSpeak: @escaping @MainActor (SpeechPlaybackItem) async -> Void
    ) async throws {
        let tasks = items.map { item in
            Task { @MainActor in
                let baseSegmentID = item.segmentID.split(separator: "#", maxSplits: 1).first.map(String.init) ?? item.segmentID
                if baseSegmentID == "task" {
                    try await Task.sleep(nanoseconds: 20_000_000)
                }
                eventLog.events.append("prepared:\(item.segmentID)")
                return item
            }
        }

        for index in items.indices {
            let item = try await tasks[index].value
            await willSpeak(item)
            try await speak(item.text)
        }
    }

    func stop() async {}
}
