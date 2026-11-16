import Foundation

public struct RSVPReadAlongCueTrackBuilder: Sendable {
    public init() {}

    public func weightedFallbackTrack(
        item: SpeechPlaybackItem,
        itemIndex: Int?,
        settings: RSVPReadingSettings,
        sourceAudioDurationSeconds: TimeInterval,
        audibleStartSeconds: TimeInterval? = nil,
        audibleEndSeconds: TimeInterval? = nil
    ) -> SpeechPlaybackWordCueTrack? {
        guard sourceAudioDurationSeconds.isFinite, sourceAudioDurationSeconds > 0 else {
            return nil
        }
        let plan = RSVPReadingPlanBuilder(settings: settings).plan(from: [item])
        guard !plan.frames.isEmpty else { return nil }

        let lowerBound = min(
            sourceAudioDurationSeconds,
            max(0, audibleStartSeconds ?? 0)
        )
        let upperCandidate = audibleEndSeconds ?? sourceAudioDurationSeconds
        let upperBound = min(
            sourceAudioDurationSeconds,
            max(lowerBound, upperCandidate)
        )
        let audibleDuration = upperBound - lowerBound
        guard audibleDuration > 0 else { return nil }

        let totalWeight = plan.frames.reduce(0) { partial, frame in
            partial + max(0.001, frame.durationSeconds)
        }
        guard totalWeight.isFinite, totalWeight > 0 else { return nil }

        var elapsedWeight: TimeInterval = 0
        var cues: [SpeechPlaybackWordCue] = []
        cues.reserveCapacity(plan.frames.count)
        for (tokenIndex, frame) in plan.frames.enumerated() {
            let weight = max(0.001, frame.durationSeconds)
            let start = lowerBound + audibleDuration * (elapsedWeight / totalWeight)
            elapsedWeight += weight
            let end = lowerBound + audibleDuration * (elapsedWeight / totalWeight)
            cues.append(
                SpeechPlaybackWordCue(
                    tokenIndex: tokenIndex,
                    startSeconds: start,
                    endSeconds: max(start, end)
                ))
        }

        return SpeechPlaybackWordCueTrack(
            itemID: item.id,
            segmentID: item.segmentID,
            itemIndex: itemIndex,
            source: .weightedFallback,
            cues: cues
        )
    }

    public func forcedAlignedTrack(
        item: SpeechPlaybackItem,
        itemIndex: Int?,
        alignedWords: [RSVPAlignedWord],
        alignmentRuntimeSeconds: TimeInterval? = nil
    ) -> SpeechPlaybackWordCueTrack? {
        let tokens = RSVPReadingPlanBuilder(settings: .default).plan(from: [item]).frames
        guard !tokens.isEmpty, !alignedWords.isEmpty else { return nil }

        guard
            alignedWords.allSatisfy({ word in
                word.startSeconds.isFinite && word.endSeconds.isFinite
                    && word.startSeconds >= 0 && word.endSeconds >= word.startSeconds
            }),
            zip(alignedWords, alignedWords.dropFirst()).allSatisfy({ pair in
                pair.0.startSeconds <= pair.1.startSeconds
                    && pair.0.endSeconds <= pair.1.endSeconds
            })
        else {
            return nil
        }

        let normalizedTokens = tokens.map { Self.alignmentKey($0.displayText) }
        var cues: [SpeechPlaybackWordCue] = []
        let normalizedWords = alignedWords.map { Self.alignmentKey($0.text) }
        var tokenIndex = 0
        var wordIndex = 0
        while tokenIndex < normalizedTokens.count, wordIndex < normalizedWords.count {
            let tokenKey = normalizedTokens[tokenIndex]
            let wordKey = normalizedWords[wordIndex]
            if tokenKey == wordKey, !tokenKey.isEmpty {
                cues.append(
                    .init(
                        tokenIndex: tokenIndex,
                        startSeconds: alignedWords[wordIndex].startSeconds,
                        endSeconds: alignedWords[wordIndex].endSeconds
                    ))
                tokenIndex += 1
                wordIndex += 1
                continue
            }

            if let tokenCount = Self.concatenatedMatchCount(
                target: wordKey,
                parts: normalizedTokens,
                startingAt: tokenIndex
            ) {
                let word = alignedWords[wordIndex]
                let matchedKeys = normalizedTokens[tokenIndex..<(tokenIndex + tokenCount)]
                let totalCharacters = max(1, matchedKeys.reduce(0) { $0 + $1.count })
                var consumedCharacters = 0
                for localIndex in 0..<tokenCount {
                    let startFraction = Double(consumedCharacters) / Double(totalCharacters)
                    consumedCharacters += normalizedTokens[tokenIndex + localIndex].count
                    let endFraction = Double(consumedCharacters) / Double(totalCharacters)
                    let duration = word.endSeconds - word.startSeconds
                    cues.append(
                        .init(
                            tokenIndex: tokenIndex + localIndex,
                            startSeconds: word.startSeconds + duration * startFraction,
                            endSeconds: word.startSeconds + duration * endFraction
                        ))
                }
                tokenIndex += tokenCount
                wordIndex += 1
                continue
            }

            if let wordCount = Self.concatenatedMatchCount(
                target: tokenKey,
                parts: normalizedWords,
                startingAt: wordIndex
            ) {
                cues.append(
                    .init(
                        tokenIndex: tokenIndex,
                        startSeconds: alignedWords[wordIndex].startSeconds,
                        endSeconds: alignedWords[wordIndex + wordCount - 1].endSeconds
                    ))
                tokenIndex += 1
                wordIndex += wordCount
                continue
            }

            wordIndex += 1
        }

        let coverage = Double(cues.count) / Double(tokens.count)
        guard coverage >= 0.90,
            zip(cues, cues.dropFirst()).allSatisfy({ pair in
                pair.0.startSeconds <= pair.1.startSeconds
            })
        else {
            return nil
        }
        return SpeechPlaybackWordCueTrack(
            itemID: item.id,
            segmentID: item.segmentID,
            itemIndex: itemIndex,
            source: .forcedAligned,
            cues: cues,
            alignmentRuntimeSeconds: alignmentRuntimeSeconds,
            tokenCoverage: coverage
        )
    }

    private static func alignmentKey(_ text: String) -> String {
        text.lowercased()
            .replacingOccurrences(of: "’", with: "'")
            .replacingOccurrences(of: "‘", with: "'")
            .filter { character in
                character.isLetter || character.isNumber || character == "'"
            }
    }

    private static func concatenatedMatchCount(
        target: String,
        parts: [String],
        startingAt startIndex: Int,
        maximumParts: Int = 5
    ) -> Int? {
        guard !target.isEmpty, parts.indices.contains(startIndex) else { return nil }
        var candidate = ""
        let upperBound = min(parts.count, startIndex + maximumParts)
        for index in startIndex..<upperBound {
            candidate += parts[index]
            if candidate == target {
                return index - startIndex + 1
            }
            if !target.hasPrefix(candidate) {
                return nil
            }
        }
        return nil
    }
}

public struct RSVPAlignedWord: Codable, Equatable, Sendable {
    public var text: String
    public var startSeconds: TimeInterval
    public var endSeconds: TimeInterval

    public init(text: String, startSeconds: TimeInterval, endSeconds: TimeInterval) {
        self.text = text
        self.startSeconds = startSeconds
        self.endSeconds = endSeconds
    }
}
