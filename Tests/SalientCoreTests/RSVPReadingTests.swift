import Foundation
@testable import SalientCore
import XCTest

final class RSVPReadingTests: XCTestCase {
    func testSettingsClampSpeedAndWarnAboveComprehensionThreshold() {
        let slow = RSVPReadingSettings(wordsPerMinute: 40).clamped
        let fast = RSVPReadingSettings(wordsPerMinute: 900).clamped
        let warning = RSVPReadingSettings(wordsPerMinute: 451).clamped

        XCTAssertEqual(RSVPReadingSettings.default.wordsPerMinute, 260)
        XCTAssertTrue(RSVPReadingSettings.default.showsDuringNarration)
        XCTAssertEqual(slow.wordsPerMinute, 100)
        XCTAssertEqual(fast.wordsPerMinute, 600)
        XCTAssertFalse(RSVPReadingSettings(wordsPerMinute: 450).showsComprehensionWarning)
        XCTAssertTrue(warning.showsComprehensionWarning)
    }

    func testReadAlongTimingPolicyLeadsObservedAudioAndClampsLead() throws {
        let policy = RSVPReadAlongTimingPolicy.default

        let normal = try XCTUnwrap(policy.adjustment(
            observedDurationSeconds: 1.8,
            tokenCount: 4
        ))
        XCTAssertEqual(normal.visualDurationSeconds, 1.728, accuracy: 0.0001)
        XCTAssertEqual(normal.requestedLeadSeconds, 0.072, accuracy: 0.0001)
        XCTAssertEqual(normal.effectiveLeadSeconds, 0.072, accuracy: 0.0001)
        XCTAssertFalse(normal.didClampToMinimumTokenDuration)

        let long = try XCTUnwrap(policy.adjustment(
            observedDurationSeconds: 10,
            tokenCount: 20
        ))
        XCTAssertEqual(long.visualDurationSeconds, 9.82, accuracy: 0.0001)
        XCTAssertEqual(long.requestedLeadSeconds, 0.18, accuracy: 0.0001)
        XCTAssertEqual(long.effectiveLeadSeconds, 0.18, accuracy: 0.0001)
        XCTAssertFalse(long.didClampToMinimumTokenDuration)
    }

    func testReadAlongTimingPolicyKeepsShortSegmentsReadable() throws {
        let adjustment = try XCTUnwrap(RSVPReadAlongTimingPolicy.default.adjustment(
            observedDurationSeconds: 0.18,
            tokenCount: 4
        ))

        XCTAssertEqual(adjustment.visualDurationSeconds, 0.22, accuracy: 0.0001)
        XCTAssertEqual(adjustment.requestedLeadSeconds, 0.06, accuracy: 0.0001)
        XCTAssertEqual(adjustment.effectiveLeadSeconds, 0, accuracy: 0.0001)
        XCTAssertTrue(adjustment.didClampToMinimumTokenDuration)
    }

    func testTokenizationORPAndPunctuationPauses() {
        let settings = RSVPReadingSettings(wordsPerMinute: 300)
        let plan = RSVPReadingPlanBuilder(settings: settings).plan(
            title: "Synthetic",
            sections: [
                RSVPReadingSection(label: "Stem", text: "Drug eruption. Microcephaly improves?")
            ]
        )

        XCTAssertEqual(plan.frames.map(\.displayText), ["Drug", "eruption.", "Microcephaly", "improves?"])
        XCTAssertEqual(plan.frames.map(\.sourceTokenIndex), [0, 1, 2, 3])
        XCTAssertEqual(plan.frames[0].orpIndex, 1)
        XCTAssertEqual(plan.frames[2].orpIndex, 3)
        XCTAssertGreaterThan(plan.frames[1].durationSeconds, plan.frames[0].durationSeconds)
        XCTAssertGreaterThan(plan.frames[3].durationSeconds, plan.frames[0].durationSeconds)
    }

    func testORPIndexUsesCoreCharactersAndMapsBackToDisplayText() {
        let plan = RSVPReadingPlanBuilder(settings: RSVPReadingSettings(wordsPerMinute: 260)).plan(
            title: "Synthetic",
            sections: [
                RSVPReadingSection(label: "Stem", text: #"complete microcephaly "complete" (text) B. 12345"#)
            ]
        )

        let indicesByToken = Dictionary(uniqueKeysWithValues: plan.frames.map { ($0.displayText, $0.orpIndex) })

        XCTAssertEqual(indicesByToken["complete"], 2)
        XCTAssertEqual(indicesByToken["microcephaly"], 3)
        XCTAssertEqual(indicesByToken[#""complete""#], 3)
        XCTAssertEqual(indicesByToken["(text)"], 2)
        XCTAssertEqual(indicesByToken["B."], 0)
        XCTAssertEqual(indicesByToken["12345"], 1)
    }

    func testNarrationPlanUsesProcessedSpeechTextAndTagsPlaybackItems() {
        let items = [
            SpeechPlaybackItem(
                id: "lab",
                segmentID: "stem#lab",
                sourceText: "HbA1c 7.2%",
                text: "hemoglobin A one C 7 point 2"
            ),
            SpeechPlaybackItem(
                id: "dose",
                segmentID: "stem#dose",
                sourceText: "4-cm mass",
                text: "4 centimeter mass"
            )
        ]

        let plan = RSVPReadingPlanBuilder(settings: RSVPReadingSettings(wordsPerMinute: 260))
            .plan(from: items, title: "Narration")

        XCTAssertEqual(
            plan.frames.map(\.displayText),
            ["hemoglobin", "A", "one", "C", "7", "point", "2", "4", "centimeter", "mass"]
        )
        XCTAssertEqual(
            plan.frames.map(\.playbackItemID),
            ["lab", "lab", "lab", "lab", "lab", "lab", "lab", "dose", "dose", "dose"]
        )
    }

    func testWeightedFallbackCueTrackUsesAudibleBoundsAndMonotonicTokenOffsets() throws {
        let item = SpeechPlaybackItem(
            id: "stem",
            segmentID: "stem",
            text: "Short phrase, then a longer conclusion."
        )

        let track = try XCTUnwrap(RSVPReadAlongCueTrackBuilder().weightedFallbackTrack(
            item: item,
            itemIndex: 2,
            settings: RSVPReadingSettings(wordsPerMinute: 260),
            sourceAudioDurationSeconds: 2,
            audibleStartSeconds: 0.08,
            audibleEndSeconds: 1.92
        ))

        XCTAssertEqual(track.source, .weightedFallback)
        XCTAssertEqual(track.itemIndex, 2)
        XCTAssertEqual(try XCTUnwrap(track.cues.first).startSeconds, 0.08, accuracy: 0.0001)
        XCTAssertEqual(try XCTUnwrap(track.cues.last).endSeconds, 1.92, accuracy: 0.0001)
        XCTAssertTrue(zip(track.cues, track.cues.dropFirst()).allSatisfy { pair in
            pair.0.endSeconds <= pair.1.startSeconds + 0.0001
        })
    }

    func testCueLookupUsesConstantVisualLeadCappedToQuarterInterval() throws {
        let track = SpeechPlaybackWordCueTrack(
            itemID: "stem",
            segmentID: "stem",
            source: .weightedFallback,
            cues: [
                .init(tokenIndex: 0, startSeconds: 0, endSeconds: 0.2),
                .init(tokenIndex: 1, startSeconds: 0.2, endSeconds: 0.3),
                .init(tokenIndex: 2, startSeconds: 0.3, endSeconds: 0.5),
            ]
        )

        XCTAssertEqual(track.cueIndex(at: 0.174), 0)
        XCTAssertEqual(track.cueIndex(at: 0.176), 1)
        XCTAssertEqual(track.cueIndex(at: 0.249), 1)
        XCTAssertEqual(track.cueIndex(at: 0.251), 2)
        XCTAssertEqual(track.cueIndex(at: 0.199, visualOffset: .synchronized), 0)
        XCTAssertEqual(track.cueIndex(at: 0.201, visualOffset: .synchronized), 1)
        XCTAssertEqual(track.cueIndex(at: 0.249, visualOffset: .lag50Milliseconds), 0)
        XCTAssertEqual(track.cueIndex(at: 0.251, visualOffset: .lag50Milliseconds), 1)
    }

    func testForcedAlignmentMapsPunctuationAndRejectsLowCoverage() throws {
        let item = SpeechPlaybackItem(
            id: "lab",
            segmentID: "lab",
            text: "Patient's WBC is 13,600."
        )
        let aligned = [
            RSVPAlignedWord(text: "Patient's", startSeconds: 0.08, endSeconds: 0.42),
            RSVPAlignedWord(text: "WBC", startSeconds: 0.44, endSeconds: 0.72),
            RSVPAlignedWord(text: "is", startSeconds: 0.73, endSeconds: 0.82),
            RSVPAlignedWord(text: "13,600", startSeconds: 0.84, endSeconds: 1.25),
        ]

        let track = try XCTUnwrap(RSVPReadAlongCueTrackBuilder().forcedAlignedTrack(
            item: item,
            itemIndex: 0,
            alignedWords: aligned,
            alignmentRuntimeSeconds: 0.1
        ))
        XCTAssertEqual(track.source, .forcedAligned)
        XCTAssertEqual(track.cues.map(\.tokenIndex), [0, 1, 2, 3])
        XCTAssertEqual(track.tokenCoverage, 1)

        XCTAssertNil(RSVPReadAlongCueTrackBuilder().forcedAlignedTrack(
            item: item,
            itemIndex: 0,
            alignedWords: Array(aligned.prefix(2))
        ))
    }

    func testSyntheticDisplayClockHasNoFiveMinuteCumulativeDriftAcrossPlaybackRates() throws {
        let wordInterval = 0.2
        let cueCount = Int((5 * 60) / wordInterval)
        let cues = (0..<cueCount).map { index in
            SpeechPlaybackWordCue(
                tokenIndex: index,
                startSeconds: Double(index) * wordInterval,
                endSeconds: Double(index + 1) * wordInterval
            )
        }
        let track = SpeechPlaybackWordCueTrack(
            itemID: "synthetic",
            segmentID: "synthetic",
            source: .weightedFallback,
            cues: cues
        )

        for rate in [0.5, 1.0, 1.6, 2.4] {
            var wallTime = 0.0
            var lastCueIndex: Int?
            var dispatchErrors: [Double] = []
            while wallTime * rate < 5 * 60 {
                let sourcePosition = wallTime * rate
                let cueIndex = try XCTUnwrap(track.cueIndex(
                    at: sourcePosition,
                    playbackRate: rate
                ))
                if cueIndex != lastCueIndex {
                    let sourceLead = min(0.05 * rate, wordInterval * 0.25)
                    let desiredSourcePosition = max(0, cues[cueIndex].startSeconds - sourceLead)
                    dispatchErrors.append(abs(sourcePosition - desiredSourcePosition) / rate)
                    lastCueIndex = cueIndex
                }
                wallTime += 1.0 / 60.0
            }

            let sorted = dispatchErrors.sorted()
            let p95 = sorted[Int(Double(sorted.count - 1) * 0.95)]
            XCTAssertLessThanOrEqual(p95, 0.035, "rate=\(rate)")
            XCTAssertLessThanOrEqual(dispatchErrors.last ?? .infinity, 0.025, "rate=\(rate)")
            XCTAssertEqual(lastCueIndex, cueCount - 1, "rate=\(rate)")
        }
    }

    func testForcedAlignmentMapsCompoundsMedicalUnitsAndCurlyApostrophes() throws {
        let item = SpeechPlaybackItem(
            id: "normalized",
            segmentID: "normalized",
            text: "A 32-year-old patient’s dose is 5 mg/dL."
        )
        let aligned = [
            RSVPAlignedWord(text: "A", startSeconds: 0, endSeconds: 0.08),
            RSVPAlignedWord(text: "32-year-old", startSeconds: 0.09, endSeconds: 0.58),
            RSVPAlignedWord(text: "patient's", startSeconds: 0.59, endSeconds: 0.92),
            RSVPAlignedWord(text: "dose", startSeconds: 0.93, endSeconds: 1.12),
            RSVPAlignedWord(text: "is", startSeconds: 1.13, endSeconds: 1.22),
            RSVPAlignedWord(text: "5", startSeconds: 1.23, endSeconds: 1.31),
            RSVPAlignedWord(text: "mg", startSeconds: 1.32, endSeconds: 1.42),
            RSVPAlignedWord(text: "dL", startSeconds: 1.43, endSeconds: 1.55),
        ]

        let track = try XCTUnwrap(RSVPReadAlongCueTrackBuilder().forcedAlignedTrack(
            item: item,
            itemIndex: 0,
            alignedWords: aligned
        ))
        XCTAssertEqual(track.tokenCoverage, 1)
        XCTAssertEqual(track.cues.map(\.tokenIndex), Array(0..<9))
    }

    func testForcedAlignmentRejectsEmptyTextAndNonMonotonicTimestamps() {
        let builder = RSVPReadAlongCueTrackBuilder()
        XCTAssertNil(builder.forcedAlignedTrack(
            item: SpeechPlaybackItem(id: "empty", segmentID: "empty", text: ""),
            itemIndex: 0,
            alignedWords: []
        ))
        XCTAssertNil(builder.forcedAlignedTrack(
            item: SpeechPlaybackItem(id: "words", segmentID: "words", text: "one two"),
            itemIndex: 0,
            alignedWords: [
                RSVPAlignedWord(text: "one", startSeconds: 0.4, endSeconds: 0.6),
                RSVPAlignedWord(text: "two", startSeconds: 0.2, endSeconds: 0.3),
            ]
        ))
    }

    func testTokenizationRemovesInterwordHyphensForDisplay() {
        let plan = RSVPReadingPlanBuilder(settings: RSVPReadingSettings(wordsPerMinute: 260)).plan(
            title: "Synthetic",
            sections: [
                RSVPReadingSection(
                    label: "Stem",
                    text: "A 32-year-old has long-term follow-up but WBCs are 0-1/hpf."
                )
            ]
        )

        XCTAssertEqual(
            plan.frames.map(\.displayText),
            ["A", "32", "year", "old", "has", "long", "term", "follow", "up", "but", "WBCs", "are", "0-1/hpf."]
        )
    }

}
