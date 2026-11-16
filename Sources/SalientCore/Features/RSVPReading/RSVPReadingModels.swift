import Foundation

public struct RSVPReadingSettings: Codable, Equatable, Sendable {
    public static let minimumWordsPerMinute = 100
    public static let maximumWordsPerMinute = 600
    public static let comprehensionWarningWordsPerMinute = 450

    public static let `default` = RSVPReadingSettings()

    public var wordsPerMinute: Int
    public var isORPEnabled: Bool
    public var usesPunctuationPauses: Bool
    public var usesSectionPauses: Bool
    public var showsDuringNarration: Bool

    public init(
        wordsPerMinute: Int = 260,
        isORPEnabled: Bool = true,
        usesPunctuationPauses: Bool = true,
        usesSectionPauses: Bool = true,
        showsDuringNarration: Bool = true
    ) {
        self.wordsPerMinute = wordsPerMinute
        self.isORPEnabled = isORPEnabled
        self.usesPunctuationPauses = usesPunctuationPauses
        self.usesSectionPauses = usesSectionPauses
        self.showsDuringNarration = showsDuringNarration
    }

    public var clamped: RSVPReadingSettings {
        RSVPReadingSettings(
            wordsPerMinute: min(
                max(wordsPerMinute, Self.minimumWordsPerMinute),
                Self.maximumWordsPerMinute
            ),
            isORPEnabled: isORPEnabled,
            usesPunctuationPauses: usesPunctuationPauses,
            usesSectionPauses: usesSectionPauses,
            showsDuringNarration: showsDuringNarration
        )
    }

    public var showsComprehensionWarning: Bool {
        wordsPerMinute > Self.comprehensionWarningWordsPerMinute
    }
}

public struct RSVPReadingSection: Equatable, Sendable {
    public var label: String
    public var text: String
    public var playbackItemID: String?

    public init(label: String, text: String, playbackItemID: String? = nil) {
        self.label = label
        self.text = text
        self.playbackItemID = playbackItemID
    }
}

public struct RSVPReadingFrame: Identifiable, Equatable, Sendable {
    public var id: Int { sourceTokenIndex }
    public var displayText: String
    public var orpIndex: Int
    public var sectionLabel: String
    public var durationSeconds: TimeInterval
    public var sourceTokenIndex: Int
    public var playbackItemID: String?
    public var isDurationFixed: Bool

    public init(
        displayText: String,
        orpIndex: Int,
        sectionLabel: String,
        durationSeconds: TimeInterval,
        sourceTokenIndex: Int,
        playbackItemID: String? = nil,
        isDurationFixed: Bool = false
    ) {
        self.displayText = displayText
        self.orpIndex = orpIndex
        self.sectionLabel = sectionLabel
        self.durationSeconds = durationSeconds
        self.sourceTokenIndex = sourceTokenIndex
        self.playbackItemID = playbackItemID
        self.isDurationFixed = isDurationFixed
    }
}

public struct RSVPReadingPlan: Equatable, Sendable {
    public var title: String
    public var frames: [RSVPReadingFrame]
    public var wordsPerMinute: Int

    public init(title: String, frames: [RSVPReadingFrame], wordsPerMinute: Int = RSVPReadingSettings.default.wordsPerMinute) {
        self.title = title
        self.frames = frames
        self.wordsPerMinute = wordsPerMinute
    }
}

public struct RSVPReadingPlanBuilder: Sendable {
    public var settings: RSVPReadingSettings

    public init(settings: RSVPReadingSettings = .default) {
        self.settings = settings.clamped
    }

    public func plan(
        title: String,
        sections: [RSVPReadingSection]
    ) -> RSVPReadingPlan {
        var frames: [RSVPReadingFrame] = []
        var tokenIndex = 0
        for sectionIndex in sections.indices {
            let section = sections[sectionIndex]
            let tokens = Self.tokens(from: section.text)
            for tokenOffset in tokens.indices {
                frames.append(frame(
                    token: tokens[tokenOffset],
                    sectionLabel: section.label,
                    playbackItemID: section.playbackItemID,
                    sourceTokenIndex: tokenIndex,
                    isSectionStart: tokenOffset == tokens.startIndex && sectionIndex > sections.startIndex
                ))
                tokenIndex += 1
            }
        }
        return RSVPReadingPlan(title: title, frames: frames, wordsPerMinute: settings.wordsPerMinute)
    }

    public func plan(
        from playbackItems: [SpeechPlaybackItem],
        title: String = "Narration"
    ) -> RSVPReadingPlan {
        plan(
            title: title,
            sections: playbackItems.map { item in
                RSVPReadingSection(label: "Narration", text: item.text, playbackItemID: item.id)
            }
        )
    }

    private func frame(
        token: String,
        sectionLabel: String,
        playbackItemID: String?,
        sourceTokenIndex: Int,
        isSectionStart: Bool
    ) -> RSVPReadingFrame {
        RSVPReadingFrame(
            displayText: token,
            orpIndex: settings.isORPEnabled ? Self.orpIndex(for: token) : 0,
            sectionLabel: sectionLabel,
            durationSeconds: duration(for: token, isSectionStart: isSectionStart),
            sourceTokenIndex: sourceTokenIndex,
            playbackItemID: playbackItemID
        )
    }

    private func duration(for token: String, isSectionStart: Bool) -> TimeInterval {
        let base = 60.0 / Double(settings.wordsPerMinute)
        var duration = base * Self.wordLengthMultiplier(for: token)
        if settings.usesPunctuationPauses {
            if token.range(of: #"[.!?]["')\]]*$"#, options: .regularExpression) != nil {
                duration += base * 1.55
            } else if token.range(of: #"[,;:]["')\]]*$"#, options: .regularExpression) != nil {
                duration += base * 0.75
            }
        }
        if settings.usesSectionPauses, isSectionStart {
            duration += base * 1.85
        }
        return duration
    }

    private static func wordLengthMultiplier(for token: String) -> Double {
        let length = coreCharacters(in: token).count
        if length >= 14 { return 1.45 }
        if length >= 10 { return 1.25 }
        if length <= 2 { return 0.90 }
        return 1.0
    }

    private static func orpIndex(for token: String) -> Int {
        let indexedCoreCharacters = token.enumerated().filter { _, character in
            character.isLetter || character.isNumber
        }
        let length = indexedCoreCharacters.count
        if length <= 1 { return 0 }
        let coreIndex: Int
        if length <= 5 {
            coreIndex = 1
        } else if length <= 9 {
            coreIndex = 2
        } else if length <= 13 {
            coreIndex = 3
        } else {
            coreIndex = 4
        }
        return indexedCoreCharacters[min(coreIndex, indexedCoreCharacters.count - 1)].offset
    }

    private static func coreCharacters(in token: String) -> [Character] {
        token.filter { character in
            character.isLetter || character.isNumber
        }
    }

    private static func tokens(from text: String) -> [String] {
        let normalized = removingInterwordHyphens(in: text)
            .replacingOccurrences(of: #"\s+"#, with: " ", options: .regularExpression)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard !normalized.isEmpty else { return [] }
        return normalized
            .split(separator: " ")
            .map(String.init)
            .filter { !$0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
    }

    private static func removingInterwordHyphens(in text: String) -> String {
        text.replacingOccurrences(
            of: #"(?<=[\p{L}])\s*[-–—]\s*(?=[\p{L}\p{N}])|(?<=[\p{N}])\s*[-–—]\s*(?=[\p{L}])"#,
            with: " ",
            options: .regularExpression
        )
    }

    public static func tokenCount(in text: String) -> Int {
        tokens(from: text).count
    }

}
