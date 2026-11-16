import Foundation

public enum SpeechEngineID: String, Codable, CaseIterable, Identifiable, Sendable {
    case pocket
    case apple
    case qwenSmall
    case qwenBest

    public var id: String { rawValue }

    public var title: String {
        switch self {
        case .pocket: "Pocket TTS"
        case .apple: "Native Apple"
        case .qwenSmall: "Qwen Fast"
        case .qwenBest: "Qwen Best"
        }
    }

    public var qwenLane: QwenModelLane? {
        switch self {
        case .apple, .pocket: nil
        case .qwenSmall: .small
        case .qwenBest: .best
        }
    }
}

public enum QwenModelLane: String, Codable, CaseIterable, Identifiable, Sendable {
    case small
    case best

    public var id: String { rawValue }

    public var engineID: SpeechEngineID {
        switch self {
        case .small: .qwenSmall
        case .best: .qwenBest
        }
    }

    public var displayName: String {
        switch self {
        case .small: "Qwen Fast"
        case .best: "Qwen Best"
        }
    }

    public var modelID: String {
        switch self {
        case .small: "mlx-community/Qwen3-TTS-12Hz-0.6B-CustomVoice-8bit"
        case .best: "mlx-community/Qwen3-TTS-12Hz-1.7B-CustomVoice-6bit"
        }
    }

    public var referenceModelID: String {
        switch self {
        case .small: "mlx-community/Qwen3-TTS-12Hz-0.6B-Base-8bit"
        case .best: "mlx-community/Qwen3-TTS-12Hz-1.7B-Base-8bit"
        }
    }

    public func modelID(useReferenceVoice: Bool) -> String {
        useReferenceVoice ? referenceModelID : modelID
    }

    public var approximateDownloadSize: String {
        switch self {
        case .small: "about 2 GB"
        case .best: "about 2.7 GB"
        }
    }

    public var referenceApproximateDownloadSize: String {
        switch self {
        case .small: "about 1.3 GB"
        case .best: "about 2.4 GB"
        }
    }

    public func approximateDownloadSize(useReferenceVoice: Bool) -> String {
        useReferenceVoice ? referenceApproximateDownloadSize : approximateDownloadSize
    }

    public func setupDisplayName(useReferenceVoice: Bool) -> String {
        useReferenceVoice ? "\(displayName) Voice Cloning" : displayName
    }

    public var defaultSpeaker: String { "Aiden" }

    public var alternateSpeaker: String { "Ryan" }

    public var presetSpeakers: [String] {
        [defaultSpeaker, alternateSpeaker]
    }

    public func title(for speaker: String) -> String {
        speaker
    }

    public var supportsReferenceVoice: Bool { true }

    public var language: String { "English" }
}

public enum QwenReferenceVoiceDefaults {
    public static let displayName = "Crisp Study Voice"
    public static let voiceName = "qwen_cmu145_crisp_us_male"
    public static let bundledAudioResourceName = "qwen_cmu145_crisp_us_male_b0402"
    public static let bundledAudioExtension = "wav"
    public static let referenceText = "An altruistic act is an act performed for the welfare of others."
}

public enum QwenReferenceVoiceID: String, Codable, CaseIterable, Identifiable, Sendable {
    case crispStudyVoice
    case studentClone

    public var id: String { rawValue }

    public var title: String {
        switch self {
        case .crispStudyVoice: QwenReferenceVoiceDefaults.displayName
        case .studentClone: QwenStudentReferenceVoiceDefaults.displayName
        }
    }
}

public enum QwenStudentReferenceVoiceDefaults {
    public static let displayName = "My Voice"
    public static let voiceName = "student_clone"
    public static let fileName = "student-clone.wav"
    public static let referenceText =
        "Hello. This is my study voice. I will read each question at a steady pace. Today I may say tachycardia and dyspnea. I may say ischemia and glomerulonephritis. I may also say acetylcholine. Sometimes I will say Streptococcus pneumoniae. I will pause naturally and keep the pronunciation clear."
    public static let minimumDurationSeconds = 10.0
    public static let maximumDurationSeconds = 20.0
    public static let minimumSampleRate = 24_000.0
    public static let maximumFileBytes: Int64 = 10 * 1_024 * 1_024
    public static let minimumPeakAmplitude: Float = 0.003
}

public struct QwenStudentReferenceVoice: Codable, Equatable, Sendable {
    public var displayName: String
    public var audioPath: String
    public var transcript: String
    public var durationSeconds: Double
    public var createdAt: Date

    public init(
        displayName: String = QwenStudentReferenceVoiceDefaults.displayName,
        audioPath: String,
        transcript: String = QwenStudentReferenceVoiceDefaults.referenceText,
        durationSeconds: Double,
        createdAt: Date = Date()
    ) {
        self.displayName = displayName
        self.audioPath = audioPath
        self.transcript = transcript
        self.durationSeconds = durationSeconds
        self.createdAt = createdAt
    }

    public var clamped: QwenStudentReferenceVoice? {
        let trimmedPath = audioPath.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedPath.isEmpty else { return nil }
        let trimmedDisplayName = displayName.trimmingCharacters(in: .whitespacesAndNewlines)
        let trimmedTranscript = transcript.trimmingCharacters(in: .whitespacesAndNewlines)
        return QwenStudentReferenceVoice(
            displayName: trimmedDisplayName.isEmpty ? QwenStudentReferenceVoiceDefaults.displayName : trimmedDisplayName,
            audioPath: trimmedPath,
            transcript: trimmedTranscript.isEmpty ? QwenStudentReferenceVoiceDefaults.referenceText : trimmedTranscript,
            durationSeconds: max(0, durationSeconds),
            createdAt: createdAt
        )
    }
}

public struct QwenEffectiveReferenceVoice: Equatable, Sendable {
    public var id: QwenReferenceVoiceID
    public var displayName: String
    public var voiceName: String
    public var audioPath: String?
    public var transcript: String

    public init(
        id: QwenReferenceVoiceID,
        displayName: String,
        voiceName: String,
        audioPath: String?,
        transcript: String
    ) {
        self.id = id
        self.displayName = displayName
        self.voiceName = voiceName
        self.audioPath = audioPath
        self.transcript = transcript
    }
}

public enum PlaybackHUDAppearance: String, Codable, CaseIterable, Identifiable, Sendable {
    case dark
    case light

    public var id: String { rawValue }

    public var title: String {
        switch self {
        case .dark: "Dark"
        case .light: "Light"
        }
    }
}

public struct SpeechSettings: Codable, Equatable, Sendable {
    /// Packaged apps include Pocket/Alba; unbundled builds can fall back to Apple.
    public static let firstLaunch = SpeechSettings(
        engineID: .pocket, rateMultiplier: 1.0, volume: 1.0,
        pitchMultiplier: 1.0, voiceIdentifier: nil, qwenUseReferenceVoice: false
    )
    public static let currentQwenVoiceDefaultRevision = 2
    public static let defaultQwenDeEsserStrengthDecibels = 6.0
    public static let maximumQwenDeEsserStrengthDecibels = 20.0

    public static let `default` = SpeechSettings(
        engineID: .apple,
        rateMultiplier: 2.4,
        volume: 1.0,
        pitchMultiplier: 1.0,
        voiceIdentifier: nil,
        qwenSpeaker: QwenModelLane.small.defaultSpeaker,
        qwenUseReferenceVoice: true,
        qwenReferenceVoiceName: QwenReferenceVoiceDefaults.voiceName,
        qwenReferenceAudioPath: "",
        qwenReferenceText: QwenReferenceVoiceDefaults.referenceText,
        qwenReferenceVoiceID: .crispStudyVoice,
        qwenStudentReferenceVoice: nil,
        qwenVoiceDefaultRevision: currentQwenVoiceDefaultRevision,
        qwenDeEsserStrengthDecibels: defaultQwenDeEsserStrengthDecibels,
        showPlaybackHUD: true,
        playbackHUDAppearance: .dark,
        readsLastSentenceFirst: true,
        skipsParentheticalContent: false,
        usesQuestionPromptAudioLibrary: true
    )

    public var engineID: SpeechEngineID
    public var rateMultiplier: Double
    public var volume: Double
    public var pitchMultiplier: Double
    public var voiceIdentifier: String?
    public var qwenSpeaker: String
    public var qwenUseReferenceVoice: Bool
    public var qwenReferenceVoiceName: String
    public var qwenReferenceAudioPath: String
    public var qwenReferenceText: String
    public var qwenReferenceVoiceID: QwenReferenceVoiceID
    public var qwenStudentReferenceVoice: QwenStudentReferenceVoice?
    public var qwenVoiceDefaultRevision: Int
    public var qwenDeEsserStrengthDecibels: Double
    public var showPlaybackHUD: Bool
    public var playbackHUDAppearance: PlaybackHUDAppearance
    public var readsLastSentenceFirst: Bool
    public var skipsParentheticalContent: Bool
    public var usesQuestionPromptAudioLibrary: Bool

    public init(
        engineID: SpeechEngineID = .apple,
        rateMultiplier: Double,
        volume: Double,
        pitchMultiplier: Double,
        voiceIdentifier: String?,
        qwenSpeaker: String = QwenModelLane.small.defaultSpeaker,
        qwenUseReferenceVoice: Bool = false,
        qwenReferenceVoiceName: String = QwenReferenceVoiceDefaults.voiceName,
        qwenReferenceAudioPath: String = "",
        qwenReferenceText: String = QwenReferenceVoiceDefaults.referenceText,
        qwenReferenceVoiceID: QwenReferenceVoiceID = .crispStudyVoice,
        qwenStudentReferenceVoice: QwenStudentReferenceVoice? = nil,
        qwenVoiceDefaultRevision: Int = SpeechSettings.currentQwenVoiceDefaultRevision,
        qwenDeEsserStrengthDecibels: Double = SpeechSettings.defaultQwenDeEsserStrengthDecibels,
        showPlaybackHUD: Bool = true,
        playbackHUDAppearance: PlaybackHUDAppearance = .dark,
        readsLastSentenceFirst: Bool = true,
        skipsParentheticalContent: Bool = false,
        usesQuestionPromptAudioLibrary: Bool = true
    ) {
        self.engineID = engineID
        self.rateMultiplier = rateMultiplier
        self.volume = volume
        self.pitchMultiplier = pitchMultiplier
        self.voiceIdentifier = voiceIdentifier
        self.qwenSpeaker = qwenSpeaker
        self.qwenUseReferenceVoice = qwenUseReferenceVoice
        self.qwenReferenceVoiceName = qwenReferenceVoiceName
        self.qwenReferenceAudioPath = qwenReferenceAudioPath
        self.qwenReferenceText = qwenReferenceText
        self.qwenReferenceVoiceID = qwenReferenceVoiceID
        self.qwenStudentReferenceVoice = qwenStudentReferenceVoice
        self.qwenVoiceDefaultRevision = qwenVoiceDefaultRevision
        self.qwenDeEsserStrengthDecibels = qwenDeEsserStrengthDecibels
        self.showPlaybackHUD = showPlaybackHUD
        self.playbackHUDAppearance = playbackHUDAppearance
        self.readsLastSentenceFirst = readsLastSentenceFirst
        self.skipsParentheticalContent = skipsParentheticalContent
        self.usesQuestionPromptAudioLibrary = usesQuestionPromptAudioLibrary
    }

    private enum CodingKeys: String, CodingKey {
        case engineID
        case rateMultiplier
        case volume
        case pitchMultiplier
        case voiceIdentifier
        case qwenSpeaker
        case qwenUseReferenceVoice
        case qwenReferenceVoiceName
        case qwenReferenceAudioPath
        case qwenReferenceText
        case qwenReferenceVoiceID
        case qwenStudentReferenceVoice
        case qwenVoiceDefaultRevision
        case qwenDeEsserStrengthDecibels
        case showPlaybackHUD
        case playbackHUDAppearance
        case readsLastSentenceFirst
        case skipsParentheticalContent
        case usesQuestionPromptAudioLibrary
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let rawEngineID = try container.decodeIfPresent(String.self, forKey: .engineID)
        let usedLegacyCloneEngine = rawEngineID == "qwenClone"
        engineID = usedLegacyCloneEngine ? .qwenBest : rawEngineID.flatMap(SpeechEngineID.init(rawValue:)) ?? .apple
        rateMultiplier = try container.decodeIfPresent(Double.self, forKey: .rateMultiplier) ?? Self.default.rateMultiplier
        volume = try container.decodeIfPresent(Double.self, forKey: .volume) ?? Self.default.volume
        pitchMultiplier = try container.decodeIfPresent(Double.self, forKey: .pitchMultiplier) ?? Self.default.pitchMultiplier
        voiceIdentifier = try container.decodeIfPresent(String.self, forKey: .voiceIdentifier)
        qwenSpeaker = try container.decodeIfPresent(String.self, forKey: .qwenSpeaker) ?? Self.default.qwenSpeaker
        let decodedUsesReferenceVoice = try container.decodeIfPresent(Bool.self, forKey: .qwenUseReferenceVoice) ?? usedLegacyCloneEngine
        let legacyReferenceAudioPath =
            try container.decodeIfPresent(String.self, forKey: .qwenReferenceAudioPath) ?? Self.default.qwenReferenceAudioPath
        let legacyReferenceText = try container.decodeIfPresent(String.self, forKey: .qwenReferenceText) ?? Self.default.qwenReferenceText
        let decodedStudentVoice = try container.decodeIfPresent(QwenStudentReferenceVoice.self, forKey: .qwenStudentReferenceVoice)?.clamped
        let decodedReferenceVoiceID =
            try container.decodeIfPresent(QwenReferenceVoiceID.self, forKey: .qwenReferenceVoiceID) ?? Self.default.qwenReferenceVoiceID
        let decodedDefaultRevision = try container.decodeIfPresent(Int.self, forKey: .qwenVoiceDefaultRevision) ?? 0
        let migratedStudentVoice: QwenStudentReferenceVoice?
        if let decodedStudentVoice {
            migratedStudentVoice = decodedStudentVoice
        } else if !legacyReferenceAudioPath.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            migratedStudentVoice =
                QwenStudentReferenceVoice(
                    displayName: QwenStudentReferenceVoiceDefaults.displayName,
                    audioPath: legacyReferenceAudioPath,
                    transcript: legacyReferenceText,
                    durationSeconds: 0,
                    createdAt: .distantPast
                ).clamped
        } else {
            migratedStudentVoice = nil
        }
        let selectedReferenceVoiceID: QwenReferenceVoiceID
        if decodedDefaultRevision < Self.currentQwenVoiceDefaultRevision {
            selectedReferenceVoiceID = .crispStudyVoice
            qwenSpeaker = engineID.qwenLane?.defaultSpeaker ?? QwenModelLane.small.defaultSpeaker
            qwenUseReferenceVoice = engineID.qwenLane != nil
        } else if decodedReferenceVoiceID == .studentClone, migratedStudentVoice != nil {
            selectedReferenceVoiceID = .studentClone
            qwenUseReferenceVoice = decodedUsesReferenceVoice
        } else {
            selectedReferenceVoiceID = .crispStudyVoice
            qwenUseReferenceVoice = decodedUsesReferenceVoice
        }
        qwenReferenceVoiceID = selectedReferenceVoiceID
        qwenStudentReferenceVoice = migratedStudentVoice
        qwenVoiceDefaultRevision = Self.currentQwenVoiceDefaultRevision
        let legacyFields = Self.legacyReferenceFields(
            selectedID: selectedReferenceVoiceID,
            studentVoice: migratedStudentVoice
        )
        qwenReferenceVoiceName = legacyFields.voiceName
        qwenReferenceAudioPath = legacyFields.audioPath
        qwenReferenceText = legacyFields.referenceText
        qwenDeEsserStrengthDecibels =
            try container.decodeIfPresent(Double.self, forKey: .qwenDeEsserStrengthDecibels)
            ?? Self.defaultQwenDeEsserStrengthDecibels
        showPlaybackHUD = try container.decodeIfPresent(Bool.self, forKey: .showPlaybackHUD) ?? true
        playbackHUDAppearance = try container.decodeIfPresent(PlaybackHUDAppearance.self, forKey: .playbackHUDAppearance) ?? .dark
        readsLastSentenceFirst =
            try container.decodeIfPresent(Bool.self, forKey: .readsLastSentenceFirst) ?? Self.default.readsLastSentenceFirst
        skipsParentheticalContent =
            try container.decodeIfPresent(Bool.self, forKey: .skipsParentheticalContent) ?? Self.default.skipsParentheticalContent
        usesQuestionPromptAudioLibrary =
            try container.decodeIfPresent(Bool.self, forKey: .usesQuestionPromptAudioLibrary) ?? Self.default.usesQuestionPromptAudioLibrary
    }

    public var clamped: SpeechSettings {
        let lane = engineID.qwenLane
        let fallbackSpeaker = lane?.defaultSpeaker ?? QwenModelLane.small.defaultSpeaker
        let studentVoice = qwenStudentReferenceVoice?.clamped
        let selectedReferenceVoiceID: QwenReferenceVoiceID =
            qwenReferenceVoiceID == .studentClone && studentVoice != nil
            ? .studentClone
            : .crispStudyVoice
        let usesReferenceVoice =
            qwenUseReferenceVoice
            && lane != nil
            && (selectedReferenceVoiceID == .crispStudyVoice || studentVoice != nil)
        let legacyFields = Self.legacyReferenceFields(
            selectedID: selectedReferenceVoiceID,
            studentVoice: studentVoice
        )
        let normalizedSpeaker = Self.normalizedQwenSpeaker(
            qwenSpeaker,
            lane: lane,
            fallback: fallbackSpeaker
        )
        return SpeechSettings(
            engineID: engineID,
            rateMultiplier: min(max(rateMultiplier, 0.5), 2.4),
            volume: min(max(volume, 0.0), 1.0),
            pitchMultiplier: min(max(pitchMultiplier, 0.5), 2.0),
            voiceIdentifier: voiceIdentifier,
            qwenSpeaker: normalizedSpeaker,
            qwenUseReferenceVoice: usesReferenceVoice,
            qwenReferenceVoiceName: legacyFields.voiceName,
            qwenReferenceAudioPath: legacyFields.audioPath,
            qwenReferenceText: legacyFields.referenceText,
            qwenReferenceVoiceID: selectedReferenceVoiceID,
            qwenStudentReferenceVoice: studentVoice,
            qwenVoiceDefaultRevision: Self.currentQwenVoiceDefaultRevision,
            qwenDeEsserStrengthDecibels: min(
                max(qwenDeEsserStrengthDecibels, 0),
                Self.maximumQwenDeEsserStrengthDecibels
            ),
            showPlaybackHUD: showPlaybackHUD,
            playbackHUDAppearance: playbackHUDAppearance,
            readsLastSentenceFirst: readsLastSentenceFirst,
            skipsParentheticalContent: skipsParentheticalContent,
            usesQuestionPromptAudioLibrary: usesQuestionPromptAudioLibrary
        )
    }

    public var readPlanOptions: ReadPlanOptions {
        ReadPlanOptions(
            readsLastSentenceFirst: readsLastSentenceFirst,
            skipsParentheticalContent: skipsParentheticalContent,
            usesQuestionPromptAudioLibrary: usesQuestionPromptAudioLibrary
        )
    }

    public var hasQwenStudentReferenceVoice: Bool {
        qwenStudentReferenceVoice?.clamped != nil
    }

    public var availableQwenReferenceVoiceIDs: [QwenReferenceVoiceID] {
        hasQwenStudentReferenceVoice ? [.crispStudyVoice, .studentClone] : [.crispStudyVoice]
    }

    public var effectiveQwenReferenceVoice: QwenEffectiveReferenceVoice {
        if qwenReferenceVoiceID == .studentClone,
            let studentVoice = qwenStudentReferenceVoice?.clamped
        {
            return QwenEffectiveReferenceVoice(
                id: .studentClone,
                displayName: studentVoice.displayName,
                voiceName: QwenStudentReferenceVoiceDefaults.voiceName,
                audioPath: studentVoice.audioPath,
                transcript: studentVoice.transcript
            )
        }
        return QwenEffectiveReferenceVoice(
            id: .crispStudyVoice,
            displayName: QwenReferenceVoiceDefaults.displayName,
            voiceName: QwenReferenceVoiceDefaults.voiceName,
            audioPath: nil,
            transcript: QwenReferenceVoiceDefaults.referenceText
        )
    }

    private static func legacyReferenceFields(
        selectedID: QwenReferenceVoiceID,
        studentVoice: QwenStudentReferenceVoice?
    ) -> (voiceName: String, audioPath: String, referenceText: String) {
        if selectedID == .studentClone,
            let studentVoice = studentVoice?.clamped
        {
            return (
                QwenStudentReferenceVoiceDefaults.voiceName,
                studentVoice.audioPath,
                studentVoice.transcript
            )
        }
        return (
            QwenReferenceVoiceDefaults.voiceName,
            "",
            QwenReferenceVoiceDefaults.referenceText
        )
    }

    private static func normalizedQwenSpeaker(
        _ speaker: String,
        lane: QwenModelLane?,
        fallback: String
    ) -> String {
        let trimmed = speaker.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return fallback }
        guard let lane else {
            return trimmed == QwenReferenceVoiceDefaults.voiceName ? fallback : trimmed
        }
        return lane.presetSpeakers.contains(trimmed) ? trimmed : fallback
    }
}

public struct SpeechVoiceOption: Equatable, Identifiable, Sendable {
    public enum Quality: Int, Sendable {
        case standard = 1, enhanced = 2, premium = 3

        public var title: String {
            switch self {
            case .standard: "Standard"
            case .enhanced: "Enhanced"
            case .premium: "Premium"
            }
        }
    }

    public var id: String { identifier }
    public var identifier: String
    public var name: String
    public var language: String
    public var quality: Quality
    public var isNovelty: Bool
    public var isPersonal: Bool
    public var displayName: String {
        let suffix = " (\(quality.title))"
        let voiceName = name.hasSuffix(suffix) ? String(name.dropLast(suffix.count)) : name
        return "\(voiceName) · \(language) · \(quality.title)"
    }
    public var isRecommendedStudyVoice: Bool {
        let normalizedLanguage = language.lowercased()
        let isEnglish = normalizedLanguage == "en" || normalizedLanguage.hasPrefix("en-")
        // Enhanced Siri voices can use a different identifier namespace. Trust
        // the public quality/trait metadata instead of excluding those voices.
        return isEnglish && !isNovelty && !isPersonal
            && (identifier.hasPrefix("com.apple.voice.") || quality != .standard)
    }

    public init(identifier: String, name: String, language: String,
                quality: Quality = .standard, isNovelty: Bool = false, isPersonal: Bool = false) {
        self.identifier = identifier
        self.name = name
        self.language = language
        self.quality = quality
        self.isNovelty = isNovelty
        self.isPersonal = isPersonal
    }

    public static func studyVoices(from voices: [Self]) -> [Self] {
        voices.filter(\.isRecommendedStudyVoice).sorted { lhs, rhs in
            if lhs.quality != rhs.quality { return lhs.quality.rawValue > rhs.quality.rawValue }
            if lhs.language != rhs.language { return lhs.language < rhs.language }
            if lhs.name != rhs.name { return lhs.name.localizedStandardCompare(rhs.name) == .orderedAscending }
            return lhs.identifier < rhs.identifier
        }
    }
}
