import Foundation
import NaturalLanguage

public enum TTSNormalizer {
    private static let maxPlaybackChunkCharacters = 180
    private static let micro = #"(?:µ|μ|u)"#
    private static let squared = #"(?:\^\s*2|2|²)"#
    private static let cubed = #"(?:\^\s*3|3|³)"#
    private static let unitStart = #"(?<![A-Za-zµμ])"#
    private static let unitEnd = #"(?=$|[^A-Za-z0-9µμ])"#
    private static let microgram = #"(?:(?:µ|μ|u)g|mcg)"#
    private static let massUnit = #"(?:(?:µ|μ|u)g|mcg|mg|g|ng|pg)"#
    private static let activityUnit = #"(?:(?:m?IU)|mU|(?:(?:µ|μ|u)U)|U|units?)"#
    private static let perBodyUnit = #"(?:(?:µ|μ|u)g|mcg|mg|g|ng|pg|(?:m?IU)|mU|(?:(?:µ|μ|u)U)|U|units?|mL|L|kg)"#
    private static let interwordHyphenPattern = #"(?<=[\p{L}])\s*[-–—]\s*(?=[\p{L}\p{N}])|(?<=[\p{N}])\s*[-–—]\s*(?=[\p{L}])"#
    private static let romanNumeralToken = #"(?:XII|XI|VIII|VII|VI|IV|IX|III|II|X|V|I)"#
    private static let romanNumeralSequence = #"\#(romanNumeralToken)(?:\s*(?:[,/]\s*(?:(?:and|or)\s+)?|\b(?:and|or|through|to)\s+)\#(romanNumeralToken))*"#
    private static let romanNumeralWords = [
        "I": "one",
        "II": "two",
        "III": "three",
        "IV": "four",
        "V": "five",
        "VI": "six",
        "VII": "seven",
        "VIII": "eight",
        "IX": "nine",
        "X": "ten",
        "XI": "eleven",
        "XII": "twelve"
    ]
    private static let ageDecadeWords = [
        "20": "twenties",
        "30": "thirties",
        "40": "forties",
        "50": "fifties",
        "60": "sixties",
        "70": "seventies",
        "80": "eighties",
        "90": "nineties"
    ]

    private static let unitOnlyPatterns = [
        #"mm\s*hg"#,
        #"mm\s*H[₂2]O"#,
        #"cm\s*H[₂2]O"#,
        #"(?:(?:µ|μ|u)g|mcg|mg|g|ng|pg|m?IU|mU|(?:µ|μ|u)U|U|units?)\s*/\s*(?:dL|mL|L)"#,
        #"mEq\s*/\s*(?:dL|mL|L)"#,
        #"m?mol\s*/\s*L"#,
        #"m?Osm(?:ol)?\s*/\s*(?:kg|L)(?:\s*H[₂2]O)?"#,
        #"m?mol"#,
        #"m?Osm(?:ol)?"#,
        #"(?:(?:µ|μ|u)g|mcg|mg|g|ng|pg|m?IU|mU|(?:µ|μ|u)U|U|units?|mL|L|kg)\s*/\s*(?:m(?:\s*(?:\^\s*2|2|²))?|24\s*(?:h|hr|hrs?|hours?)|h|hr|hrs?|hours?|min|kg|day|cell)"#,
        #"Hb\s*/\s*cell"#,
        #"(?:cells?|million|thousand|k)\s*/\s*(?:mm(?:\s*(?:\^\s*3|3|³))?|(?:µ|μ|u)L|mcL)"#,
        #"/\s*(?:mm(?:\s*(?:\^\s*3|3|³))?|(?:µ|μ|u)L|mcL)"#,
        #"/\s*min"#,
        #"/\s*m(?:\s*(?:\^\s*2|2|²))?"#,
        #"/\s*hpf"#,
        #"mm\s*/\s*(?:h|hr|hrs?|hours?)"#,
        #"/\s*24\s*(?:h|hr|hrs?|hours?)"#,
        #"mm\s*(?:\^\s*3|3|³)"#,
        #"(?:(?:µ|μ|u)m)\s*(?:\^\s*3|3|³)"#,
        #"fL"#,
        #"(?:mL|mcL|(?:µ|μ|u)L|L)"#,
        #"kg"#,
        #"hpf"#,
        #"m\s*(?:\^\s*2|2|²)"#,
        #"cm"#,
        #"mm"#,
        #"°?\s*[CF]"#,
        #"(?:h|hr|hrs?)"#,
        #"seconds?|secs?|s"#
    ]

    public static func isLikelyUnitText(_ text: String) -> Bool {
        let compact = text.trimmedForSpeech
            .trimmingCharacters(in: CharacterSet(charactersIn: "()[]{}.,;:"))
        guard !compact.isEmpty else { return false }
        if ["hour", "hours"].contains(compact.lowercased()) {
            return false
        }

        let pattern = "^(?:" + unitOnlyPatterns.joined(separator: "|") + ")$"
        return compact.range(of: pattern, options: [.regularExpression, .caseInsensitive]) != nil
    }

    public static func normalize(_ text: String) -> String {
        var normalized = text.trimmedForSpeech

        normalized = normalized.replacingOccurrences(
            of: #"\b(\d+(?:\.\d+)?)\s*[-–—]\s*lbs?\b\s*\(\s*\d+(?:\.\d+)?\s*[-–—]\s*kg\s*\)"#,
            with: "$1 pound",
            options: [.regularExpression, .caseInsensitive]
        )
        normalized = normalized.replacingOccurrences(
            of: #"\b(\d+(?:\.\d+)?)\s*[-–—]?\s*kg\b\s*\(\s*(\d+(?:\.\d+)?)\s*[-–—]?\s*lbs?\s*\)"#,
            with: "$1 kilograms or $2 pounds",
            options: [.regularExpression, .caseInsensitive]
        )
        normalized = normalized.replacingOccurrences(
            of: #"\b((?:temperature\s+(?:is\s+)?)\d+(?:\.\d+)?)\s*°?\s*C\s*\(\s*\d+(?:\.\d+)?\s*°?\s*F\s*\)"#,
            with: "$1",
            options: [.regularExpression, .caseInsensitive]
        )
        normalized = normalizeRomanNumerals(in: normalized)
        normalized = normalizeAgeDecades(in: normalized)
        normalized = normalized.replacingOccurrences(of: "(", with: " ")
        normalized = normalized.replacingOccurrences(of: ")", with: " ")
        normalized = normalized.replacingOccurrences(
            of: #"^([A-Z])\.\s+"#,
            with: #"Choice $1. "#,
            options: .regularExpression
        )
        normalized = normalized.replacingOccurrences(
            of: #"(?<=\d)\.(?=\d)"#,
            with: " point ",
            options: .regularExpression
        )
        normalized = normalized.replacingOccurrences(
            of: #"(?<=\d)\s*/\s*(?=\d)"#,
            with: " over ",
            options: .regularExpression
        )

        let replacements: [(String, String)] = [
            (#"\bHbA1c\b"#, "hemoglobin A one C"),
            (#"\bA1c\b"#, "A one C"),
            (#"\bO2\b"#, "oxygen"),
            (#"\bq(\d+)h\b"#, "every $1 hours"),
            (#"≤\s*(?=\d)"#, "less than or equal to "),
            (#"≥\s*(?=\d)"#, "greater than or equal to "),
            (#"<\s*(?=\d)"#, "less than "),
            (#">\s*(?=\d)"#, "greater than "),
            (#"(?<=\d)\s*%"#, ""),
            (#"(?<=\d)\s*[-–]\s*(?=\d)"#, " to "),
            (#"(?<=\d)\s*[-–—]\s*lbs?\b"#, " pound"),
            (#"(?<=\d)\s+lbs?\b"#, " pounds"),
            (#"(?<=\d)\s*[-–—]\s*kg\b"#, " kilogram"),
            (#"(?<=\d)\s*[-–—]\s*cm\b"#, " centimeter"),
            (#"\b1\s*oz\b"#, "1 ounce"),
            (#"(?<=\d)\s*oz\b"#, " ounces"),
            (#"\bmm\s*Hg\b"#, ""),
            (#"\bmm\s*H[₂2]O\b"#, ""),
            (#"\bcm\s*H[₂2]O\b"#, ""),
            (#"\#(unitStart)(?:\#(massUnit)|\#(activityUnit))\s*/\s*(?:dL|mL|L)\b"#, ""),
            (#"\#(unitStart)mEq\s*/\s*(?:dL|mL|L)\b"#, ""),
            (#"\#(unitStart)m?mol\s*/\s*L\b"#, ""),
            (#"\#(unitStart)m?Osm(?:ol)?\s*/\s*(?:kg|L)(?:\s*H[₂2]O)?\b"#, ""),
            (#"\#(unitStart)m?mol\b"#, ""),
            (#"\#(unitStart)m?Osm(?:ol)?\b"#, ""),
            (#"\#(unitStart)\#(perBodyUnit)\s*/\s*(?:m(?:\s*\#(squared))?|24\s*(?:h|hr|hrs?|hours?)|h|hr|hrs?|hours?|min|kg|day|cell)\#(unitEnd)"#, ""),
            (#"\bHb\s*/\s*cell\b"#, ""),
            (#"(?:\b(?:cells?|million|thousand|k)\s*)?/\s*(?:mm(?:\s*\#(cubed))?|\#(micro)L|mcL)\#(unitEnd)"#, ""),
            (#"\bmm\s*/\s*(?:h|hr|hrs?|hours?)\b"#, ""),
            (#"/\s*24\s*(?:h|hr|hrs?|hours?)\b"#, ""),
            (#"\#(unitStart)mm\s*\#(cubed)\#(unitEnd)"#, ""),
            (#"\#(unitStart)\#(micro)m\s*\#(cubed)\#(unitEnd)"#, ""),
            (#"\bfL\b"#, ""),
            (#"\#(unitStart)(?:mL|mcL|\#(micro)L|L)\b"#, ""),
            (#"\#(unitStart)kg\b"#, ""),
            (#"(?<=\d)\s*/?\s*hpf\b"#, ""),
            (#"\bm\s*\#(squared)\#(unitEnd)"#, ""),
            (#"\bcm\b"#, ""),
            (#"(?<=\d)\s*mm\b"#, ""),
            (#"(?<=\d)\s*°?\s*[CF]\b"#, ""),
            (#"(?<=\d)\s*(?:seconds?|secs?|s)\b"#, ""),
            (#"(?<=\d)\s*(?:h|hr|hrs?)\b"#, ""),
            (#"(?<!\S)/\s*min\b"#, ""),
            (#"(?<=\d)\s*/\s*min\b"#, ""),
            (#"(?<=\d)\s*/\s*m(?:\s*\#(squared))?\#(unitEnd)"#, "")
        ]
        for (pattern, replacement) in replacements {
            normalized = normalized.replacingOccurrences(
                of: pattern,
                with: replacement,
                options: [.regularExpression, .caseInsensitive]
            )
        }
        normalized = normalized.replacingOccurrences(
            of: #"\s*:\s*"#,
            with: " ",
            options: .regularExpression
        )
        normalized = normalized.replacingOccurrences(
            of: #"\s+([,.;:!?])"#,
            with: "$1",
            options: .regularExpression
        )
        normalized = normalized.replacingOccurrences(
            of: #",\s*([.;:!?])"#,
            with: "$1",
            options: .regularExpression
        )
        normalized = removingInterwordHyphens(in: normalized)
        normalized = normalized.replacingOccurrences(
            of: #"\s+"#,
            with: " ",
            options: .regularExpression
        )

        return normalized.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    static func removingInterwordHyphens(in text: String) -> String {
        text.replacingOccurrences(
            of: interwordHyphenPattern,
            with: " ",
            options: .regularExpression
        )
    }

    private static func normalizeAgeDecades(in text: String) -> String {
        let decadeToken = #"(?:(?:early|mid|late)\s+)?[2-9]0'?s"#
        let decadeList = #"\#(decadeToken)(?:\s*(?:,|and|or|to|[-–—])\s*\#(decadeToken))*"#
        let contextPattern = #"\b((?:in\s+(?:his|her|their)|ages?|aged)\s+)(\#(decadeList))\b"#

        return replaceMatches(in: text, pattern: contextPattern, options: .caseInsensitive) { match, source in
            guard let prefix = capturedString(1, in: match, source: source),
                  let decades = capturedString(2, in: match, source: source) else {
                return capturedString(0, in: match, source: source) ?? ""
            }
            return prefix + spokenAgeDecadeList(decades)
        }
    }

    private static func spokenAgeDecadeList(_ text: String) -> String {
        replaceMatches(in: text, pattern: #"\b([2-9]0)'?s\b"#, options: .caseInsensitive) { match, source in
            guard let decade = capturedString(1, in: match, source: source),
                  let word = ageDecadeWords[decade] else {
                return capturedString(0, in: match, source: source) ?? ""
            }
            return word
        }
    }

    private static func normalizeRomanNumerals(in text: String) -> String {
        var normalized = expandCranialNerveAbbreviations(in: text)
        normalized = replaceRomanNumeralRanges(in: normalized)
        normalized = replaceContextualRomanNumerals(in: normalized)
        return normalized
    }

    private static func expandCranialNerveAbbreviations(in text: String) -> String {
        var normalized = text.replacingOccurrences(
            of: #"\bCNs\b(?=\s+\#(romanNumeralToken)\b)"#,
            with: "cranial nerves",
            options: .regularExpression
        )
        normalized = normalized.replacingOccurrences(
            of: #"\bCN\b(?=\s+\#(romanNumeralToken)\s*(?:[-–—]|\b(?:through|to)\b)\s*\#(romanNumeralToken)\b)"#,
            with: "cranial nerves",
            options: [.regularExpression, .caseInsensitive]
        )
        normalized = normalized.replacingOccurrences(
            of: #"\bCN\b(?=\s+\#(romanNumeralToken)\b)"#,
            with: "cranial nerve",
            options: .regularExpression
        )
        return normalized
    }

    private static func replaceRomanNumeralRanges(in text: String) -> String {
        replaceMatches(
            in: text,
            pattern: #"(?<![A-Za-z])(\#(romanNumeralToken))\s*[-–—]\s*(\#(romanNumeralToken))(?![A-Za-z])"#,
            options: .caseInsensitive
        ) { match, source in
            guard let lower = capturedString(1, in: match, source: source),
                  let upper = capturedString(2, in: match, source: source),
                  let lowerWord = romanNumeralWords[lower.uppercased()],
                  let upperWord = romanNumeralWords[upper.uppercased()] else {
                return capturedString(0, in: match, source: source) ?? ""
            }
            return "\(lowerWord) to \(upperWord)"
        }
    }

    private static func replaceContextualRomanNumerals(in text: String) -> String {
        let contextPattern = #"\b(?:cranial nerves?|stages?|grades?|class(?:es)?|types?|factors?|phases?|sections?|chapters?)\s+\#(romanNumeralSequence)"#
        return replaceMatches(in: text, pattern: contextPattern, options: .caseInsensitive) { match, source in
            guard let phrase = capturedString(0, in: match, source: source) else { return "" }
            return replaceRomanNumeralTokens(in: phrase)
        }
    }

    private static func replaceRomanNumeralTokens(in text: String) -> String {
        replaceMatches(
            in: text,
            pattern: #"(?<![A-Za-z])(\#(romanNumeralToken))(?![A-Za-z])"#,
            options: .caseInsensitive
        ) { match, source in
            guard let roman = capturedString(1, in: match, source: source),
                  let word = romanNumeralWords[roman.uppercased()] else {
                return capturedString(0, in: match, source: source) ?? ""
            }
            return word
        }
    }

    private static func replaceMatches(
        in text: String,
        pattern: String,
        options: NSRegularExpression.Options = [],
        transform: (NSTextCheckingResult, String) -> String
    ) -> String {
        guard let regex = try? NSRegularExpression(pattern: pattern, options: options) else {
            return text
        }

        var result = text
        let matches = regex.matches(in: text, range: NSRange(text.startIndex..., in: text))
        for match in matches.reversed() {
            guard let resultRange = Range(match.range, in: result) else { continue }
            result.replaceSubrange(resultRange, with: transform(match, text))
        }
        return result
    }

    private static func capturedString(
        _ index: Int,
        in match: NSTextCheckingResult,
        source: String
    ) -> String? {
        let range = match.range(at: index)
        guard range.location != NSNotFound,
              let stringRange = Range(range, in: source) else {
            return nil
        }
        return String(source[stringRange])
    }

    public static func normalizedPlaybackItems(from items: [ReadPlanItem]) -> [SpeechPlaybackItem] {
        var playbackItems: [SpeechPlaybackItem] = []
        for item in items {
            if isLikelyUnitText(item.text) {
                continue
            }
            let spokenText = normalize(item.text)
            guard !spokenText.isEmpty, !isLikelyUnitText(spokenText) else {
                continue
            }

            if let repaired = repairedDecimalBoundary(previous: playbackItems.last, nextText: spokenText) {
                playbackItems[playbackItems.count - 1] = repaired
                continue
            }

            let chunks = playbackChunks(for: spokenText)
            for (chunkIndex, chunk) in chunks.enumerated() {
                let segmentID = chunks.count == 1 ? item.segmentID : "\(item.segmentID)#chunk-\(chunkIndex)"
                playbackItems.append(SpeechPlaybackItem(
                    id: "\(segmentID)#playback-\(playbackItems.count)",
                    segmentID: segmentID,
                    sourceText: item.text,
                    text: chunk,
                    audioCachePolicy: item.audioCachePolicy
                ))
            }
        }
        return playbackItems
    }

    private static func playbackChunks(for text: String) -> [String] {
        let trimmed = text.trimmedForSpeech
        guard trimmed.count > maxPlaybackChunkCharacters else {
            return [trimmed]
        }

        let sentenceChunks = sentenceChunks(in: trimmed)
        let primaryChunks = sentenceChunks.count > 1 ? sentenceChunks : [trimmed]
        let boundedChunks = primaryChunks.flatMap(splitOversizedChunk)
        return packChunks(boundedChunks).filter { !$0.isEmpty }
    }

    private static func sentenceChunks(in text: String) -> [String] {
        let tokenizer = NLTokenizer(unit: .sentence)
        tokenizer.string = text
        let chunks = tokenizer.tokens(for: text.startIndex..<text.endIndex).compactMap { range in
            let chunk = String(text[range]).trimmedForSpeech
            return chunk.isEmpty ? nil : chunk
        }
        return chunks.isEmpty ? [text] : chunks
    }

    private static func splitOversizedChunk(_ text: String) -> [String] {
        let trimmed = text.trimmedForSpeech
        guard trimmed.count > maxPlaybackChunkCharacters else {
            return [trimmed]
        }

        let clauseChunks = regexChunks(
            in: trimmed,
            pattern: #"[^,;]+[,;]?"#
        )
        if clauseChunks.count > 1 {
            return packChunks(clauseChunks)
        }
        return packChunks(trimmed.split(separator: " ").map(String.init))
    }

    private static func packChunks(_ chunks: [String]) -> [String] {
        var packed: [String] = []
        var current = ""
        for rawChunk in chunks {
            let chunk = rawChunk.trimmedForSpeech
            guard !chunk.isEmpty else { continue }
            if current.isEmpty {
                current = chunk
            } else if current.count + 1 + chunk.count <= maxPlaybackChunkCharacters {
                current += " " + chunk
            } else {
                packed.append(current)
                current = chunk
            }
        }
        if !current.isEmpty {
            packed.append(current)
        }
        return packed
    }

    private static func regexChunks(in text: String, pattern: String) -> [String] {
        guard let regex = try? NSRegularExpression(pattern: pattern) else {
            return [text]
        }
        let matches = regex.matches(in: text, range: NSRange(text.startIndex..., in: text))
        return matches.compactMap { match in
            guard let range = Range(match.range, in: text) else { return nil }
            let chunk = String(text[range]).trimmedForSpeech
            return chunk.isEmpty ? nil : chunk
        }
    }

    private static func repairedDecimalBoundary(
        previous: SpeechPlaybackItem?,
        nextText: String
    ) -> SpeechPlaybackItem? {
        guard var previous else { return nil }
        guard let previousMatch = previous.text.firstMatch(of: #"^(.*\d)\.$"#),
              let nextMatch = nextText.firstMatch(of: #"^(\d+)(\b.*)$"#) else {
            return nil
        }
        previous.text = "\(previousMatch[1]) point \(nextMatch[1])\(nextMatch[2])"
        return previous
    }
}

private extension String {
    func firstMatch(of pattern: String) -> [String]? {
        guard let regex = try? NSRegularExpression(pattern: pattern),
              let match = regex.firstMatch(in: self, range: NSRange(startIndex..., in: self)) else {
            return nil
        }
        return (0..<match.numberOfRanges).compactMap { index in
            let range = match.range(at: index)
            guard let stringRange = Range(range, in: self) else { return nil }
            return String(self[stringRange])
        }
    }
}
