import XCTest
@testable import SalientCore
import Carbon.HIToolbox
import CoreGraphics
import ImageIO
import UniformTypeIdentifiers

final class UWorldStudyTests: XCTestCase {
    func testDecodesSyntheticCapturePayloadIntoSegments() throws {
        let payload = """
        {
          "mode": "question",
          "segments": [
            {"id":"stem-1","text":"A 45-year-old patient has chest pain.","role":"stem","region":"left","rect":{"x":10,"y":20,"width":300,"height":40}},
            {"id":"task-1","text":"Which diagnosis is most likely?","role":"question","region":"left","rect":{"x":10,"y":90,"width":300,"height":30}}
          ]
        }
        """

        let capture = try UWorldCapturePayload.decode(json: payload)

        XCTAssertEqual(capture.mode, .question)
        XCTAssertEqual(capture.segments.map(\.id), ["stem-1", "task-1"])
        XCTAssertEqual(capture.segments.last?.rect.width, 300)
    }

    func testDecodesLegacyCapturePayloadWithRichSourceDefaults() throws {
        let capture = try UWorldCapturePayload.decode(json: """
        {
          "mode": "question",
          "segments": [
            {"id":"stem-1","text":"A patient has a rash.","role":"stem","region":"left","rect":{"x":10,"y":20,"width":300,"height":40}}
          ]
        }
        """)

        XCTAssertEqual(capture.tables, [])
        XCTAssertEqual(capture.media, [])

    }

    func testQuestionReadPlanReadsFinalTaskThenStemBeginning() throws {
        let segments = [
            CapturedSegment(id: "stem-1", text: "A 45-year-old patient has chest pain.", role: .stem, region: .left, rect: .zero),
            CapturedSegment(id: "ui-submit", text: "Submit", role: .ui, region: .left, rect: .zero),
            CapturedSegment(id: "unit", text: "mm Hg", role: .stem, region: .left, rect: .zero),
            CapturedSegment(id: "choice-a", text: "A. Pneumonia", role: .choice, region: .left, rect: .zero),
            CapturedSegment(id: "task-1", text: "Which diagnosis is most likely?", role: .questionTask, region: .left, rect: .zero)
        ]

        let plan = ReadPlanBuilder().questionPlan(from: segments)

        XCTAssertEqual(plan.items.map(\.segmentID), ["task-1#task", "stem-1"])
        XCTAssertEqual(plan.items.first?.text, "Which diagnosis is most likely?")
    }

    func testQuestionReadPlanCanKeepVisibleOrderWhenLastSentenceFirstIsDisabled() throws {
        let segments = [
            CapturedSegment(
                id: "stem-1",
                text: "A 45-year-old patient has chest pain.",
                role: .stem,
                region: .left,
                rect: CapturedRect(x: 20, y: 120, width: 520, height: 28)
            ),
            CapturedSegment(
                id: "task-1",
                text: "Which diagnosis is most likely?",
                role: .questionTask,
                region: .left,
                rect: CapturedRect(x: 20, y: 170, width: 520, height: 28)
            )
        ]

        let plan = ReadPlanBuilder(options: ReadPlanOptions(readsLastSentenceFirst: false))
            .questionPlan(from: segments)

        XCTAssertEqual(plan.items.map(\.segmentID), ["stem-1", "task-1#task"])
        XCTAssertEqual(plan.items.map(\.text), [
            "A 45-year-old patient has chest pain.",
            "Which diagnosis is most likely?"
        ])
    }

    func testQuestionReadPlanCanRemoveParentheticalContentWhenConfigured() throws {
        let segments = [
            CapturedSegment(
                id: "stem-1",
                text: "A patient has fever (38.6 C) and cough.",
                role: .stem,
                region: .left,
                rect: .zero
            ),
            CapturedSegment(
                id: "task-1",
                text: "Which diagnosis is most likely (select one)?",
                role: .questionTask,
                region: .left,
                rect: .zero
            )
        ]

        let plan = ReadPlanBuilder(options: ReadPlanOptions(skipsParentheticalContent: true))
            .questionPlan(from: segments)

        XCTAssertEqual(plan.items.map(\.text), [
            "Which diagnosis is most likely?",
            "A patient has fever and cough."
        ])
    }

    func testQuestionReadPlanMarksAllQuestionAudioPersistent() throws {
        let segments = [
            CapturedSegment(id: "stem-1", text: "A patient has a new murmur.", role: .stem, region: .left, rect: .zero),
            CapturedSegment(id: "task-1", text: "Which of the following responses best explains this finding?", role: .questionTask, region: .left, rect: .zero)
        ]

        let plan = ReadPlanBuilder().questionPlan(from: segments)
        let playbackItems = TTSNormalizer.normalizedPlaybackItems(from: plan.items)

        XCTAssertEqual(playbackItems.map(\.segmentID), ["task-1#starter", "task-1#tail", "stem-1"])
        XCTAssertEqual(playbackItems.map(\.audioCachePolicy), [.persistent, .persistent, .persistent])
    }

    func testQuestionReadPlanKeepsTaskWholeWhenPromptAudioLibraryIsDisabled() throws {
        let segments = [
            CapturedSegment(id: "stem-1", text: "A patient has a new murmur.", role: .stem, region: .left, rect: .zero),
            CapturedSegment(id: "task-1", text: "Which of the following responses best explains this finding?", role: .questionTask, region: .left, rect: .zero)
        ]

        let plan = ReadPlanBuilder(
            options: ReadPlanOptions(usesQuestionPromptAudioLibrary: false)
        )
        .questionPlan(from: segments)
        let playbackItems = TTSNormalizer.normalizedPlaybackItems(from: plan.items)

        XCTAssertEqual(playbackItems.map(\.segmentID), ["task-1#task", "stem-1"])
        XCTAssertEqual(playbackItems.first?.text, "Which of the following responses best explains this finding?")
    }

    func testQuestionReadPlanCoalescesInlineFormattedStemFragmentsForSpeech() throws {
        let segments = [
            CapturedSegment(
                id: "stem-prefix",
                text: "A pregnant patient has a group B",
                role: .stem,
                region: .left,
                rect: CapturedRect(x: 20, y: 120, width: 235, height: 28)
            ),
            CapturedSegment(
                id: "stem-italic",
                text: "Streptococcus",
                role: .stem,
                region: .left,
                rect: CapturedRect(x: 262, y: 120, width: 154, height: 28)
            ),
            CapturedSegment(
                id: "stem-suffix",
                text: "(GBS) rectovaginal culture.",
                role: .stem,
                region: .left,
                rect: CapturedRect(x: 422, y: 120, width: 260, height: 28)
            ),
            CapturedSegment(
                id: "task",
                text: "What should be done next?",
                role: .questionTask,
                region: .left,
                rect: CapturedRect(x: 20, y: 176, width: 320, height: 28)
            )
        ]

        let plan = ReadPlanBuilder().questionPlan(from: segments)
        let playbackItems = TTSNormalizer.normalizedPlaybackItems(from: plan.items)

        XCTAssertEqual(plan.items.map(\.text), [
            "What should be done next?",
            "A pregnant patient has a group B Streptococcus (GBS) rectovaginal culture."
        ])
        XCTAssertEqual(playbackItems.map(\.text), [
            "What should be done next?",
            "A pregnant patient has a group B Streptococcus GBS rectovaginal culture."
        ])
    }

    func testQuestionReadPlanCoalescesWrappedInlineFormattedStemFragmentsForSpeech() throws {
        var prefix = CapturedSegment(
            id: "stem-prefix",
            text: "A pregnant patient has a group B",
            role: .stem,
            region: .left,
            rect: CapturedRect(x: 20, y: 120, width: 420, height: 28)
        )
        prefix.domPath = "body:nth-of-type(1) > div:nth-of-type(1) > p:nth-of-type(1)"
        var italic = CapturedSegment(
            id: "stem-italic",
            text: "Streptococcus",
            role: .stem,
            region: .left,
            rect: CapturedRect(x: 20, y: 150, width: 154, height: 28)
        )
        italic.domPath = "body:nth-of-type(1) > div:nth-of-type(1) > p:nth-of-type(1) > em:nth-of-type(1)"
        var suffix = CapturedSegment(
            id: "stem-suffix",
            text: "(GBS) rectovaginal culture.",
            role: .stem,
            region: .left,
            rect: CapturedRect(x: 181, y: 150, width: 260, height: 28)
        )
        suffix.domPath = "body:nth-of-type(1) > div:nth-of-type(1) > p:nth-of-type(1)"
        let task = CapturedSegment(
            id: "task",
            text: "What should be done next?",
            role: .questionTask,
            region: .left,
            rect: CapturedRect(x: 20, y: 206, width: 320, height: 28)
        )

        let plan = ReadPlanBuilder().questionPlan(from: [prefix, italic, suffix, task])
        let playbackItems = TTSNormalizer.normalizedPlaybackItems(from: plan.items)

        XCTAssertEqual(plan.items.map(\.text), [
            "What should be done next?",
            "A pregnant patient has a group B Streptococcus (GBS) rectovaginal culture."
        ])
        XCTAssertEqual(playbackItems.map(\.text), [
            "What should be done next?",
            "A pregnant patient has a group B Streptococcus GBS rectovaginal culture."
        ])
    }

    func testQuestionReadPlanUsesVisibleOrderWhenCapturedSourceOrderDiffersFromLayout() throws {
        let segments = [
            CapturedSegment(
                id: "stem-medications",
                text: "The only medication is a daily vitamin.",
                role: .stem,
                region: .left,
                rect: CapturedRect(x: 20, y: 120, width: 520, height: 24)
            ),
            CapturedSegment(
                id: "stem-bmi",
                text: "BMI is 30.",
                role: .stem,
                region: .left,
                rect: CapturedRect(x: 20, y: 180, width: 520, height: 24)
            ),
            CapturedSegment(
                id: "stem-exam",
                text: "Cardiopulmonary examination is normal.",
                role: .stem,
                region: .left,
                rect: CapturedRect(x: 20, y: 210, width: 520, height: 24)
            ),
            CapturedSegment(
                id: "stem-social-history",
                text: "The patient does not use tobacco, alcohol, or other substances.",
                role: .stem,
                region: .left,
                rect: CapturedRect(x: 20, y: 150, width: 520, height: 24)
            ),
            CapturedSegment(
                id: "stem-labs",
                text: "Laboratory testing shows an abnormal screening value.",
                role: .stem,
                region: .left,
                rect: CapturedRect(x: 20, y: 270, width: 520, height: 24)
            ),
            CapturedSegment(
                id: "stem-measurement",
                text: "The physical measurement is larger than expected.",
                role: .stem,
                region: .left,
                rect: CapturedRect(x: 20, y: 240, width: 520, height: 24)
            ),
            CapturedSegment(
                id: "task",
                text: "Which of the following is the best next step?",
                role: .questionTask,
                region: .left,
                rect: CapturedRect(x: 20, y: 320, width: 520, height: 24)
            )
        ]

        let plan = ReadPlanBuilder().questionPlan(from: segments)

        XCTAssertEqual(plan.items.map(\.segmentID), [
            "task#task",
            "stem-medications",
            "stem-social-history",
            "stem-bmi",
            "stem-exam",
            "stem-measurement",
            "stem-labs"
        ])
    }

    func testQuestionReadPlanKeepsWrappedUnitFragmentFromReorderingFollowingSentences() throws {
        let task = CapturedSegment(
            id: "task",
            text: "Which of the following is the best explanation?",
            role: .questionTask,
            region: .left,
            rect: CapturedRect(x: 20, y: 320, width: 520, height: 24)
        )
        let pressure = CapturedSegment(
            id: "pressure",
            text: "Blood pressure is normal.",
            role: .stem,
            region: .left,
            rect: CapturedRect(x: 420, y: 120, width: 300, height: 24)
        )
        var bodyMassIndex = CapturedSegment(
            id: "body-mass-index",
            text: "BMI is 32 kg/m",
            role: .stem,
            region: .left,
            rect: CapturedRect(x: 780, y: 120, width: 90, height: 24)
        )
        bodyMassIndex.rects = [
            CapturedRect(x: 780, y: 120, width: 90, height: 24),
            CapturedRect(x: 20, y: 150, width: 70, height: 24)
        ]
        let rate = CapturedSegment(
            id: "rate",
            text: "Heart rate is normal.",
            role: .stem,
            region: .left,
            rect: CapturedRect(x: 98, y: 150, width: 220, height: 24)
        )
        let height = CapturedSegment(
            id: "height",
            text: "Measurement is slightly decreased.",
            role: .stem,
            region: .left,
            rect: CapturedRect(x: 318, y: 150, width: 260, height: 24)
        )
        var imaging = CapturedSegment(
            id: "imaging",
            text: "Imaging shows a reassuring finding with a normal range:",
            role: .stem,
            region: .left,
            rect: CapturedRect(x: 586, y: 150, width: 380, height: 24)
        )
        imaging.rects = [
            CapturedRect(x: 586, y: 150, width: 380, height: 24),
            CapturedRect(x: 20, y: 180, width: 360, height: 24)
        ]
        let imagingTail = CapturedSegment(
            id: "imaging-tail",
            text: ">5 units.",
            role: .stem,
            region: .left,
            rect: CapturedRect(x: 388, y: 180, width: 90, height: 24)
        )

        let plan = ReadPlanBuilder().questionPlan(from: [
            pressure,
            bodyMassIndex,
            rate,
            height,
            imaging,
            imagingTail,
            task
        ])

        XCTAssertEqual(plan.items.map(\.segmentID), [
            "task#starter",
            "task#tail",
            "pressure",
            "body-mass-index",
            "rate",
            "height",
            "imaging"
        ])
        XCTAssertEqual(plan.items.map(\.text), [
            "Which of the following is the best",
            "explanation?",
            "Blood pressure is normal.",
            "BMI is 32 kg/m",
            "Heart rate is normal.",
            "Measurement is slightly decreased.",
            "Imaging shows a reassuring finding with a normal range: >5 units."
        ])
    }

    func testQuestionReadPlanKeepsDroppedDoseAreaUnitFromMergingFollowingSentence() throws {
        var dose = CapturedSegment(
            id: "dose",
            text: "Dose is 50 mg/m",
            role: .stem,
            region: .left,
            rect: CapturedRect(x: 760, y: 120, width: 120, height: 24)
        )
        dose.rects = [
            CapturedRect(x: 760, y: 120, width: 120, height: 24),
            CapturedRect(x: 20, y: 150, width: 68, height: 24)
        ]
        let nextSentence = CapturedSegment(
            id: "next-sentence",
            text: "The patient returns tomorrow.",
            role: .stem,
            region: .left,
            rect: CapturedRect(x: 96, y: 150, width: 280, height: 24)
        )
        let task = CapturedSegment(
            id: "task",
            text: "Which of the following is best?",
            role: .questionTask,
            region: .left,
            rect: CapturedRect(x: 20, y: 210, width: 420, height: 24)
        )

        let plan = ReadPlanBuilder().questionPlan(from: [dose, nextSentence, task])

        XCTAssertEqual(plan.items.map(\.segmentID), [
            "task#starter",
            "task#tail",
            "dose",
            "next-sentence"
        ])
        XCTAssertEqual(plan.items.map(\.text), [
            "Which of the following",
            "is best?",
            "Dose is 50 mg/m",
            "The patient returns tomorrow."
        ])
    }

    func testQuestionReadPlanFiltersSplitReviewMetadataFragments() throws {
        let segments = [
            CapturedSegment(
                id: "stem",
                text: "A synthetic stem is readable.",
                role: .stem,
                region: .left,
                rect: CapturedRect(x: 20, y: 120, width: 520, height: 24)
            ),
            CapturedSegment(
                id: "task",
                text: "Which of the following is most likely?",
                role: .questionTask,
                region: .left,
                rect: CapturedRect(x: 20, y: 160, width: 520, height: 24)
            ),
            CapturedSegment(
                id: "percent",
                text: "81%",
                role: .stem,
                region: .left,
                rect: CapturedRect(x: 480, y: 590, width: 60, height: 20)
            ),
            CapturedSegment(
                id: "seconds",
                text: "46 secs",
                role: .stem,
                region: .left,
                rect: CapturedRect(x: 780, y: 590, width: 80, height: 20)
            ),
            CapturedSegment(
                id: "time-spent",
                text: "Time Spent",
                role: .stem,
                region: .left,
                rect: CapturedRect(x: 780, y: 610, width: 100, height: 20)
            )
        ]

        let plan = ReadPlanBuilder().questionPlan(from: segments)

        XCTAssertEqual(plan.items.map(\.segmentID), [
            "task#task",
            "stem"
        ])
    }

    func testQuestionReadPlanSkipsEntireAnswerChoiceTableWithHeaderAndRadioColumn() throws {
        let segments = [
            CapturedSegment(
                id: "stem",
                text: "A patient has irregular menses and normal TSH.",
                role: .stem,
                region: .left,
                rect: CapturedRect(x: 20, y: 120, width: 700, height: 28)
            ),
            CapturedSegment(
                id: "task",
                text: "What laboratory pattern is most likely?",
                role: .questionTask,
                region: .left,
                rect: CapturedRect(x: 20, y: 170, width: 700, height: 28)
            )
        ]
        let answerTable = CapturedTable(
            id: "answer-hormone-table",
            rows: [
                ["", "", "GnRH", "FSH", "Estrogen", ""],
                ["○", "A.", "↓", "↓", "↓", "ab"],
                ["○", "B.", "↑", "↑", "↓", "ab"],
                ["○", "C.", "↑", "Normal", "↑", "ab"],
                ["○", "D.", "Normal", "Normal", "Normal", "ab"],
                ["○", "E.", "↓", "↓", "↑", "ab"]
            ],
            region: .left,
            role: "table",
            rect: CapturedRect(x: 20, y: 220, width: 700, height: 220)
        )

        let plan = ReadPlanBuilder().questionPlan(from: segments, tables: [answerTable])

        XCTAssertEqual(plan.items.map(\.segmentID), ["task#task", "stem"])
        XCTAssertFalse(plan.items.map(\.text).joined(separator: " ").contains("GnRH"))
        XCTAssertFalse(plan.items.map(\.text).joined(separator: " ").contains("A."))
    }

    func testQuestionReadPlanSkipsAnswerChoiceGridWhenLabelsAreOutsideTable() throws {
        var segments = [
            CapturedSegment(
                id: "stem",
                text: "A learner reviews a synthetic developmental vignette.",
                role: .stem,
                region: .left,
                rect: CapturedRect(x: 20, y: 120, width: 700, height: 28)
            ),
            CapturedSegment(
                id: "task",
                text: "Which of the following is the most appropriate assessment?",
                role: .questionTask,
                region: .left,
                rect: CapturedRect(x: 20, y: 170, width: 760, height: 28)
            )
        ]
        let rowYs: [Double] = [276, 318, 360, 402, 444, 486, 528, 570]
        let labels = ["A.", "B.", "C.", "D.", "E.", "F.", "G.", "H."]
        for (index, label) in labels.enumerated() {
            segments.append(CapturedSegment(
                id: "choice-\(label.dropLast())",
                text: label,
                role: .choice,
                region: .left,
                rect: CapturedRect(x: 145, y: rowYs[index], width: 36, height: 24)
            ))
        }
        segments += [
            CapturedSegment(id: "grid-header-1", text: "Domain 1", role: .stem, region: .left, rect: CapturedRect(x: 285, y: 224, width: 110, height: 24)),
            CapturedSegment(id: "grid-header-2", text: "Domain 2", role: .stem, region: .left, rect: CapturedRect(x: 585, y: 224, width: 110, height: 24)),
            CapturedSegment(id: "grid-header-3", text: "Domain 3", role: .stem, region: .left, rect: CapturedRect(x: 885, y: 224, width: 110, height: 24)),
            CapturedSegment(id: "grid-value-a-1", text: "Low", role: .stem, region: .left, rect: CapturedRect(x: 285, y: 276, width: 90, height: 24)),
            CapturedSegment(id: "grid-value-a-2", text: "Low", role: .stem, region: .left, rect: CapturedRect(x: 585, y: 276, width: 90, height: 24)),
            CapturedSegment(id: "grid-value-a-3", text: "Low", role: .stem, region: .left, rect: CapturedRect(x: 885, y: 276, width: 90, height: 24)),
            CapturedSegment(id: "grid-value-h-1", text: "Expected", role: .stem, region: .left, rect: CapturedRect(x: 285, y: 570, width: 120, height: 24)),
            CapturedSegment(id: "grid-value-h-2", text: "Expected", role: .stem, region: .left, rect: CapturedRect(x: 585, y: 570, width: 120, height: 24)),
            CapturedSegment(id: "grid-value-h-3", text: "Expected", role: .stem, region: .left, rect: CapturedRect(x: 885, y: 570, width: 120, height: 24))
        ]
        let answerGrid = CapturedTable(
            id: "answer-grid-with-external-labels",
            headers: ["Domain 1", "Domain 2", "Domain 3"],
            rows: [
                ["Low", "Low", "Low"],
                ["Low", "Low", "Expected"],
                ["Low", "Expected", "Low"],
                ["Low", "Expected", "Expected"],
                ["Expected", "Low", "Low"],
                ["Expected", "Low", "Expected"],
                ["Expected", "Expected", "Low"],
                ["Expected", "Expected", "Expected"]
            ],
            region: .left,
            role: "table",
            rect: CapturedRect(x: 250, y: 210, width: 760, height: 400)
        )

        let plan = ReadPlanBuilder().questionPlan(from: segments, tables: [answerGrid])

        XCTAssertEqual(plan.items.map(\.segmentID), ["task#starter", "task#tail", "stem"])
        XCTAssertFalse(plan.items.map(\.text).joined(separator: " ").contains("Domain"))
        XCTAssertFalse(plan.items.map(\.text).joined(separator: " ").contains("Expected"))
    }

    func testQuestionReadPlanSkipsNestedTablesInsideAnswerChoiceTable() throws {
        let segments = [
            CapturedSegment(
                id: "stem",
                text: "A learner reviews a synthetic developmental vignette.",
                role: .stem,
                region: .left,
                rect: CapturedRect(x: 140, y: 120, width: 700, height: 28)
            ),
            CapturedSegment(
                id: "task",
                text: "Which of the following is the most appropriate assessment?",
                role: .questionTask,
                region: .left,
                rect: CapturedRect(x: 140, y: 170, width: 760, height: 28)
            )
        ]
        let outerAnswerTable = CapturedTable(
            id: "outer-answer-table",
            rows: [
                ["A.", "row values"],
                ["B.", "row values"],
                ["C.", "row values"]
            ],
            region: .left,
            role: "table",
            rect: CapturedRect(x: 140, y: 220, width: 600, height: 180)
        )
        let nestedTables = [
            CapturedTable(
                id: "nested-answer-row-a",
                rows: [["Low", "Low", "Low"]],
                region: .left,
                role: "table",
                rect: CapturedRect(x: 230, y: 235, width: 450, height: 26)
            ),
            CapturedTable(
                id: "nested-answer-row-b",
                rows: [["Low", "Low", "Expected"]],
                region: .left,
                role: "table",
                rect: CapturedRect(x: 230, y: 295, width: 450, height: 26)
            ),
            CapturedTable(
                id: "nested-answer-row-c",
                rows: [["Expected", "Expected", "Expected"]],
                region: .left,
                role: "table",
                rect: CapturedRect(x: 230, y: 355, width: 450, height: 26)
            )
        ]

        let plan = ReadPlanBuilder().questionPlan(
            from: segments,
            tables: [outerAnswerTable] + nestedTables
        )

        XCTAssertEqual(plan.items.map(\.segmentID), ["task#starter", "task#tail", "stem"])
        XCTAssertFalse(plan.items.map(\.text).joined(separator: " ").contains("Low"))
        XCTAssertFalse(plan.items.map(\.text).joined(separator: " ").contains("Expected"))
    }

    func testExplanationReadPlanKeepsAudioTransient() throws {
        let segments = [
            CapturedSegment(id: "explanation-1", text: "This explanation remains uncached.", role: .explanation, region: .right, rect: .zero)
        ]

        let plan = ReadPlanBuilder().explanationPlan(from: segments)
        let playbackItems = TTSNormalizer.normalizedPlaybackItems(from: plan.items)

        XCTAssertEqual(playbackItems.map(\.audioCachePolicy), [.transient])
    }

    func testDecodesHandoffCapturePayloadWithRectsAndQuestionTaskRole() throws {
        let payload = """
        {
          "requestId": "uworld-test",
          "mode": "question",
          "pageUrl": "https://example.test",
          "title": "Fixture",
          "viewport": {"width": 1200, "height": 900},
          "segments": [
            {
              "id":"seg-1-0",
              "text":"What is the next best step?",
              "role":"question_task",
              "region":"left",
              "rects":[{"x":10,"y":20,"width":300,"height":40}],
              "domPath":"body:nth-of-type(1) > p:nth-of-type(1)",
              "textNodePath":"0.1.0",
              "startOffset":0,
              "endOffset":28
            }
          ]
        }
        """

        let capture = try UWorldCapturePayload.decode(json: payload)

        XCTAssertEqual(capture.segments.first?.role, .questionTask)
        XCTAssertEqual(capture.segments.first?.rect, CapturedRect(x: 10, y: 20, width: 300, height: 40))
        XCTAssertEqual(capture.segments.first?.textNodePath, "0.1.0")
    }

    func testQuestionReadPlanSplitsQuotedTerminalQuestionStarter() throws {
        let segments = [
            CapturedSegment(id: "stem-1", text: "A researcher asks about renal physiology.", role: .stem, region: .left, rect: .zero),
            CapturedSegment(id: "task-1", text: "\"Which of the following responses best explains this medication?\"", role: .question, region: .left, rect: .zero)
        ]

        let plan = ReadPlanBuilder().questionPlan(from: segments)

        XCTAssertEqual(plan.items.map(\.text), [
            "Which of the following responses best explains",
            "this medication?",
            "A researcher asks about renal physiology."
        ])
        XCTAssertEqual(plan.items.map(\.segmentID), [
            "task-1#starter",
            "task-1#tail",
            "stem-1"
        ])
    }

    func testQuestionReadPlanSplitsUnquotedCommonStarterBeforeStemBeginning() throws {
        let segments = [
            CapturedSegment(id: "stem-1", text: "A patient has a new murmur.", role: .stem, region: .left, rect: .zero),
            CapturedSegment(id: "choice-a", text: "A. Observation", role: .choice, region: .left, rect: .zero),
            CapturedSegment(id: "unit", text: "mm Hg", role: .stem, region: .left, rect: .zero),
            CapturedSegment(id: "task-1", text: "Which of the following responses best explains this finding?", role: .questionTask, region: .left, rect: .zero)
        ]

        let plan = ReadPlanBuilder().questionPlan(from: segments)

        XCTAssertEqual(plan.items.map(\.text), [
            "Which of the following responses best explains",
            "this finding?",
            "A patient has a new murmur."
        ])
        XCTAssertEqual(plan.items.map(\.segmentID), ["task-1#starter", "task-1#tail", "stem-1"])
    }

    func testCommonQuestionStarterSplitPrefersLongestMatchingPrefix() throws {
        let split = try XCTUnwrap(ReadPlanBuilder.commonQuestionStarterSplit(
            "Which of the following responses best explains the reason for this change?"
        ))

        XCTAssertEqual(split.starter, "Which of the following responses best explains")
        XCTAssertEqual(split.tail, "the reason for this change?")
    }

    func testCommonQuestionStarterSplitCoversRealtimeCacheVariants() throws {
        let examples: [(text: String, starter: String, tail: String)] = [
            (
                "Which of the following findings best explains this synthetic pattern?",
                "Which of the following findings best explains",
                "this synthetic pattern?"
            ),
            (
                "Which of the following best explains the laboratory result?",
                "Which of the following best explains",
                "the laboratory result?"
            ),
            (
                "Which of the following is most likely to explain this change?",
                "Which of the following is most likely",
                "to explain this change?"
            ),
            (
                "Which of the following is the most appropriate next step?",
                "Which of the following is the most appropriate",
                "next step?"
            ),
            (
                "Which of the following would most likely be seen?",
                "Which of the following would most likely",
                "be seen?"
            ),
            (
                "The most likely diagnosis is associated with which exposure?",
                "The most likely diagnosis is",
                "associated with which exposure?"
            ),
            (
                "The next best step is to repeat testing.",
                "The next best step is",
                "to repeat testing."
            )
        ]

        for example in examples {
            let split = try XCTUnwrap(
                ReadPlanBuilder.commonQuestionStarterSplit(example.text),
                example.text
            )
            XCTAssertEqual(split.starter, example.starter)
            XCTAssertEqual(split.tail, example.tail)
        }
    }

    func testTTSNormalizerPreservesMedicalDecimalsAndExpandsChoiceLabels() {
        let normalized = TTSNormalizer.normalize("A. Give 0.5 mg/kg IV q6h. BP is 88/54 mm Hg.")

        XCTAssertEqual(normalized, "Choice A. Give 0 point 5 IV every 6 hours. BP is 88 over 54.")
    }

    func testTTSNormalizerSpeaksHyphenatedWeightUnitsAsWords() {
        let normalized = TTSNormalizer.normalize(
            "She has had a 35-lb (16-kg) weight gain over the past year."
        )

        XCTAssertEqual(normalized, "She has had a 35 pound weight gain over the past year.")
        XCTAssertFalse(normalized.localizedCaseInsensitiveContains("lb"))
        XCTAssertFalse(normalized.localizedCaseInsensitiveContains("kg"))
    }

    func testTTSNormalizerSpeaksMetricImperialWeightPairsAsWords() {
        let normalized = TTSNormalizer.normalize("He weighs 20 kg (44 lb).")

        XCTAssertEqual(normalized, "He weighs 20 kilograms or 44 pounds.")
        XCTAssertFalse(normalized.localizedCaseInsensitiveContains("kg"))
        XCTAssertFalse(normalized.localizedCaseInsensitiveContains("lb"))
    }

    func testTTSNormalizerSpeaksFluidOuncesAsWords() {
        let normalized = TTSNormalizer.normalize("The infant takes 5 oz per feed and 1 oz overnight.")

        XCTAssertEqual(normalized, "The infant takes 5 ounces per feed and 1 ounce overnight.")
        XCTAssertFalse(normalized.localizedCaseInsensitiveContains(" oz"))
    }

    func testTTSNormalizerSpeaksHyphenatedCentimetersAsWords() {
        let normalized = TTSNormalizer.normalize("A 4-cm adrenal mass is found on CT.")

        XCTAssertEqual(normalized, "A 4 centimeter adrenal mass is found on CT.")
        XCTAssertFalse(normalized.contains("-cm"))
        XCTAssertTrue(TTSNormalizer.isLikelyUnitText("cm"))
    }

    func testTTSNormalizerRemovesInterwordHyphensAfterUnitHandling() {
        let normalized = TTSNormalizer.normalize(
            "A 32-year-old has a 4-cm mass and needs long-term follow-up."
        )

        XCTAssertEqual(
            normalized,
            "A 32 year old has a 4 centimeter mass and needs long term follow up."
        )
        XCTAssertFalse(normalized.contains("-"))
    }

    func testTTSNormalizerSpeaksPatientAgeDecadesAsWords() {
        XCTAssertEqual(
            TTSNormalizer.normalize("A woman in her 30s presents with palpitations."),
            "A woman in her thirties presents with palpitations."
        )
        XCTAssertEqual(
            TTSNormalizer.normalize("Patients in their 40s and 50s have increased risk."),
            "Patients in their forties and fifties have increased risk."
        )
        XCTAssertEqual(
            TTSNormalizer.normalize("A man in his late 60s has progressive dyspnea."),
            "A man in his late sixties has progressive dyspnea."
        )

        let playbackItems = TTSNormalizer.normalizedPlaybackItems(from: [
            ReadPlanItem(segmentID: "stem-age", text: "A patient in her 70s reports fatigue.")
        ])

        XCTAssertEqual(playbackItems.map(\.text), [
            "A patient in her seventies reports fatigue."
        ])
    }

    func testTTSNormalizerKeepsBMIAsAcronym() {
        let normalized = TTSNormalizer.normalize("BMI is 34 kg/m^2.")
        let normalizedSuperscript = TTSNormalizer.normalize("BMI is 22 kg/m².")

        XCTAssertEqual(normalized, "BMI is 34.")
        XCTAssertEqual(normalizedSuperscript, "BMI is 22.")
        XCTAssertTrue(normalized.contains("BMI"))
        XCTAssertTrue(normalizedSuperscript.contains("BMI"))
        XCTAssertFalse(normalized.localizedCaseInsensitiveContains("body mass index"))
        XCTAssertFalse(normalizedSuperscript.contains("²"))
    }

    func testTTSNormalizerRemovesDoseAreaUnitsWhenSuperscriptIsPresentOrDropped() {
        let normalized = TTSNormalizer.normalize("Dose is 50 mg/m.")
        let normalizedCaret = TTSNormalizer.normalize("Dose is 50 mg/m^2.")
        let normalizedSuperscript = TTSNormalizer.normalize("Dose is 50 mg/m².")

        XCTAssertEqual(normalized, "Dose is 50.")
        XCTAssertEqual(normalizedCaret, "Dose is 50.")
        XCTAssertEqual(normalizedSuperscript, "Dose is 50.")
        XCTAssertTrue(TTSNormalizer.isLikelyUnitText("mg/m"))
        XCTAssertTrue(TTSNormalizer.isLikelyUnitText("mg/m^2"))
        XCTAssertTrue(TTSNormalizer.isLikelyUnitText("mg/m²."))

        let playbackItems = TTSNormalizer.normalizedPlaybackItems(from: [
            ReadPlanItem(segmentID: "dose", text: "Dose is 50 mg/m.")
        ])

        XCTAssertEqual(playbackItems.map(\.text), ["Dose is 50."])
    }

    func testTTSNormalizerSpeaksStandaloneA1cAsAOneC() {
        let normalized = TTSNormalizer.normalize("A1c is 6.8%, and HbA1c was checked.")

        XCTAssertEqual(normalized, "A one C is 6 point 8, and hemoglobin A one C was checked.")
        XCTAssertFalse(normalized.localizedCaseInsensitiveContains("A1c"))
    }

    func testTTSNormalizerRemovesMilliEquivalentPerDeciliterUnits() {
        let normalized = TTSNormalizer.normalize("Urine ammonium is 40 mEq/dL.")

        XCTAssertEqual(normalized, "Urine ammonium is 40.")
        XCTAssertTrue(TTSNormalizer.isLikelyUnitText("mEq/dL"))

        let playbackItems = TTSNormalizer.normalizedPlaybackItems(from: [
            ReadPlanItem(segmentID: "value", text: "Urine ammonium is 40 mEq/dL."),
            ReadPlanItem(segmentID: "unit", text: "mEq/dL")
        ])

        XCTAssertEqual(playbackItems.map(\.segmentID), ["value"])
        XCTAssertEqual(playbackItems.map(\.text), ["Urine ammonium is 40."])
    }

    func testTTSNormalizerRemovesMilliUnitPerMilliliterUnits() {
        let normalized = TTSNormalizer.normalize("TSH is 2.9 mU/mL.")

        XCTAssertEqual(normalized, "TSH is 2 point 9.")
        XCTAssertTrue(TTSNormalizer.isLikelyUnitText("mU/mL"))

        let playbackItems = TTSNormalizer.normalizedPlaybackItems(from: [
            ReadPlanItem(segmentID: "value", text: "TSH is 2.9 mU/mL."),
            ReadPlanItem(segmentID: "unit", text: "mU/mL")
        ])

        XCTAssertEqual(playbackItems.map(\.segmentID), ["value"])
        XCTAssertEqual(playbackItems.map(\.text), ["TSH is 2 point 9."])
    }

    func testTTSNormalizerRemovesCubicMillimeterUnitsBeforePlayback() {
        XCTAssertEqual(TTSNormalizer.normalize("Leukocytes are 13,600 mm3."), "Leukocytes are 13,600.")
        XCTAssertEqual(TTSNormalizer.normalize("Leukocytes are 13,600 mm^3."), "Leukocytes are 13,600.")
        XCTAssertEqual(TTSNormalizer.normalize("Leukocytes are 13,600 mm³."), "Leukocytes are 13,600.")
        XCTAssertTrue(TTSNormalizer.isLikelyUnitText("mm3"))
        XCTAssertTrue(TTSNormalizer.isLikelyUnitText("mm^3"))
        XCTAssertTrue(TTSNormalizer.isLikelyUnitText("mm³"))

        let playbackItems = TTSNormalizer.normalizedPlaybackItems(from: [
            ReadPlanItem(segmentID: "value", text: "Leukocytes are 13,600 mm³."),
            ReadPlanItem(segmentID: "unit", text: "mm³")
        ])

        XCTAssertEqual(playbackItems.map(\.segmentID), ["value"])
        XCTAssertEqual(playbackItems.map(\.text), ["Leukocytes are 13,600."])
    }

    func testTTSNormalizerRemovesHighPowerFieldUnitsFromUrinalysisRanges() {
        let normalized = TTSNormalizer.normalize("Urinalysis shows white blood cells 0-1/hpf.")

        XCTAssertEqual(normalized, "Urinalysis shows white blood cells 0 to 1.")
        XCTAssertTrue(TTSNormalizer.isLikelyUnitText("/hpf"))
        XCTAssertTrue(TTSNormalizer.isLikelyUnitText("hpf"))

        let playbackItems = TTSNormalizer.normalizedPlaybackItems(from: [
            ReadPlanItem(segmentID: "value", text: "White blood cells 0-1/hpf."),
            ReadPlanItem(segmentID: "unit", text: "/hpf")
        ])

        XCTAssertEqual(playbackItems.map(\.segmentID), ["value"])
        XCTAssertEqual(playbackItems.map(\.text), ["White blood cells 0 to 1."])
    }

    func testTTSNormalizerRemovesColonsBeforeSpeech() {
        let normalized = TTSNormalizer.normalize("Labs: sodium is 140. Question: what is next?")

        XCTAssertEqual(normalized, "Labs sodium is 140. Question what is next?")
        XCTAssertFalse(normalized.contains(":"))
    }

    func testTTSNormalizerSpeaksCranialNerveRomanNumeralRangesAndLists() {
        XCTAssertEqual(
            TTSNormalizer.normalize("Cranial nerves II-XII are grossly intact."),
            "Cranial nerves two to twelve are grossly intact."
        )
        XCTAssertEqual(
            TTSNormalizer.normalize("CNs III, IV, and VI control extraocular movements."),
            "cranial nerves three, four, and six control extraocular movements."
        )
        XCTAssertEqual(
            TTSNormalizer.normalize("CN II through XII are intact."),
            "cranial nerves two through twelve are intact."
        )
        XCTAssertEqual(
            TTSNormalizer.normalize("CN VII palsy is present."),
            "cranial nerve seven palsy is present."
        )
    }

    func testTTSNormalizerSpeaksContextualMedicalRomanNumeralsWithoutChangingIVRoute() {
        XCTAssertEqual(
            TTSNormalizer.normalize("Stage III-IV disease and type II diabetes are noted."),
            "Stage three to four disease and type two diabetes are noted."
        )
        XCTAssertEqual(
            TTSNormalizer.normalize("Factor V Leiden is treated with IV anticoagulation."),
            "Factor five Leiden is treated with IV anticoagulation."
        )
    }

    func testTTSNormalizerRemovesLabAndRateUnitsWhileKeepingValues() {
        let normalized = TTSNormalizer.normalize(
            "Temperature is 36.8 C (98.2 F), blood pressure is 148/90 mm Hg, pulse is 86/min. " +
            "BMI is 34 kg/m^2. HbA1c is 6.8%. Sodium 140 mEq/L. Glucose 140 mg/dL. " +
            "Osmolality >600 mOsm/kg. Leukocytes 9,000/mm3. TSH 2.9 μU/mL."
        )

        XCTAssertEqual(
            normalized,
            "Temperature is 36 point 8, blood pressure is 148 over 90, pulse is 86. " +
            "BMI is 34. hemoglobin A one C is 6 point 8. Sodium 140. " +
            "Glucose 140. Osmolality greater than 600. Leukocytes 9,000. TSH 2 point 9."
        )
        XCTAssertFalse(normalized.localizedCaseInsensitiveContains("mm Hg"))
        XCTAssertFalse(normalized.localizedCaseInsensitiveContains("/min"))
        XCTAssertFalse(normalized.localizedCaseInsensitiveContains("kg/m"))
        XCTAssertFalse(normalized.localizedCaseInsensitiveContains("mg/dL"))
        XCTAssertFalse(normalized.localizedCaseInsensitiveContains("mEq"))
        XCTAssertFalse(normalized.localizedCaseInsensitiveContains("μU"))
    }

    func testTTSNormalizerPreservesProseHourWordsButRemovesCompactHourUnits() {
        XCTAssertEqual(
            TTSNormalizer.normalize("Symptoms began 1 hour ago and lasted 2 hours."),
            "Symptoms began 1 hour ago and lasted 2 hours."
        )
        XCTAssertEqual(
            TTSNormalizer.normalize("ESR is 18 mm/h and urine output is 3,000 mL/24 hours."),
            "ESR is 18 and urine output is 3,000."
        )
        XCTAssertEqual(
            TTSNormalizer.normalize("The IV fluid rate is 60 mL/hr."),
            "The IV fluid rate is 60."
        )
        XCTAssertTrue(TTSNormalizer.isLikelyUnitText("mL/hr"))
    }

    func testTTSNormalizerBuildsPlaybackItemsAndRepairsDecimalBoundaries() {
        let readItems = [
            ReadPlanItem(segmentID: "temperature-1", text: "Temperature is 36."),
            ReadPlanItem(segmentID: "temperature-2", text: "8 C."),
            ReadPlanItem(segmentID: "unit", text: "mm Hg"),
            ReadPlanItem(segmentID: "pulse", text: "Pulse is 86/min.")
        ]

        let playbackItems = TTSNormalizer.normalizedPlaybackItems(from: readItems)

        XCTAssertEqual(playbackItems.map(\.segmentID), ["temperature-1", "pulse"])
        XCTAssertEqual(playbackItems.map(\.text), [
            "Temperature is 36 point 8.",
            "Pulse is 86."
        ])
        XCTAssertEqual(playbackItems.first?.sourceText, "Temperature is 36.")
    }

    func testTTSNormalizerSplitsLongPlaybackItemsForEarlierQwenStartup() {
        let longStem = """
        A student has several days of fever, cough, pleuritic chest pain, and progressive shortness of breath despite outpatient therapy. The examination shows tachypnea, focal crackles, and dullness to percussion over the lower lung field. A chest radiograph shows a dense lobar opacity with a small adjacent effusion.
        """

        let playbackItems = TTSNormalizer.normalizedPlaybackItems(from: [
            ReadPlanItem(segmentID: "stem-long", text: longStem, audioCachePolicy: .persistent)
        ])

        XCTAssertGreaterThan(playbackItems.count, 1)
        XCTAssertTrue(playbackItems.allSatisfy { $0.text.count <= 180 })
        XCTAssertEqual(playbackItems.map(\.segmentID), [
            "stem-long#chunk-0",
            "stem-long#chunk-1",
            "stem-long#chunk-2"
        ])
        XCTAssertTrue(playbackItems.allSatisfy { $0.audioCachePolicy == .persistent })
        XCTAssertFalse(playbackItems.map(\.id).joined().contains("fever"))
    }

    func testTTSNormalizerPacksAdjacentShortSentencesWithinPlaybackLimit() {
        let text = [
            "A patient reports intermittent fatigue during afternoon study sessions.",
            "Symptoms improve after a brief meal and several minutes of rest.",
            "Vital signs remain stable throughout repeated clinical observations.",
            "No fever occurs."
        ].joined(separator: " ")

        let playbackItems = TTSNormalizer.normalizedPlaybackItems(from: [
            ReadPlanItem(segmentID: "stem-packed", text: text)
        ])

        XCTAssertEqual(playbackItems.count, 2)
        XCTAssertEqual(playbackItems.map(\.segmentID), [
            "stem-packed#chunk-0",
            "stem-packed#chunk-1"
        ])
        XCTAssertEqual(
            playbackItems.map(\.text).joined(separator: " "),
            TTSNormalizer.normalize(text)
        )
        XCTAssertTrue(playbackItems.allSatisfy { $0.text.count <= 180 })
        XCTAssertTrue(playbackItems[0].text.contains("Symptoms improve"))
        XCTAssertTrue(playbackItems[1].text.hasSuffix("No fever occurs."))
    }

    func testTTSNormalizerSentencePackingPreservesDecimalsAndAbbreviations() {
        let text = [
            "Dr. Rivera reviews the U.S. report showing a glucose level of 3.5 and a stable pulse.",
            "The first observation remains unchanged during careful monitoring.",
            "A final sentence provides enough additional context to require chunking without breaking abbreviations."
        ].joined(separator: " ")

        let playbackItems = TTSNormalizer.normalizedPlaybackItems(from: [
            ReadPlanItem(segmentID: "stem-abbreviations", text: text)
        ])

        XCTAssertEqual(playbackItems.count, 2)
        XCTAssertEqual(
            playbackItems.map(\.text).joined(separator: " "),
            TTSNormalizer.normalize(text)
        )
        XCTAssertTrue(playbackItems.allSatisfy { $0.text.count <= 180 })
        XCTAssertTrue(playbackItems[0].text.contains("Dr. Rivera"))
        XCTAssertTrue(playbackItems[0].text.contains("U.S. report"))
        XCTAssertTrue(playbackItems[0].text.contains("3 point 5"))
        XCTAssertFalse(playbackItems.contains { ["Dr.", "U.", "S."].contains($0.text) })
    }

    func testTTSNormalizerPacksShortFinalSentenceWithoutOrphanChunk() {
        let text = [
            "A carefully documented history describes several weeks of intermittent symptoms that recur during prolonged activity and improve with rest.",
            "Repeated examination findings remain reassuring during each scheduled follow-up visit.",
            "No fever."
        ].joined(separator: " ")

        let playbackItems = TTSNormalizer.normalizedPlaybackItems(from: [
            ReadPlanItem(segmentID: "stem-no-orphan", text: text)
        ])

        XCTAssertEqual(playbackItems.count, 2)
        XCTAssertTrue(playbackItems.allSatisfy { $0.text.count <= 180 })
        XCTAssertNotEqual(playbackItems.last?.text, "No fever.")
        XCTAssertTrue(playbackItems.last?.text.hasSuffix("No fever.") == true)
        XCTAssertGreaterThan(playbackItems.last?.text.count ?? 0, 60)
    }

    func testPlaybackVisualizationContextMapsReadModesToHudModes() {
        XCTAssertEqual(SpeechPlaybackVisualizationContext(readMode: .question), .question)
        XCTAssertEqual(SpeechPlaybackVisualizationContext(readMode: .explanation), .explanation)
        XCTAssertEqual(SpeechPlaybackVisualizationContext.neutral, .neutral)
    }

    func testStudyShortcutDefaultsIncludeAllUWorldActions() {
        let titles = StudyShortcutAction.allCases.map(\.title)

        XCTAssertEqual(titles.count, StudyShortcutAction.allCases.count)
        XCTAssertTrue(titles.contains("Next + Read"))
        XCTAssertTrue(StudyShortcutAction.submit.defaultShortcut.displayString.contains("Return"))
        XCTAssertTrue(StudyShortcutAction.readQuestion.defaultShortcut.isUsableGlobalShortcut)
    }

    func testControlShortcutIsUsableForGlobalHotkeys() {
        let recordedShortcut = HotKeyDefinition(
            keyCode: UInt32(kVK_ANSI_A),
            modifiers: HotKeyDefinition.control,
            isEnabled: true
        )
        XCTAssertTrue(recordedShortcut.isUsableGlobalShortcut)
        XCTAssertEqual(recordedShortcut.displayString, "⌃A")

        let legacyAppKitShortcut = HotKeyDefinition(
            keyCode: UInt32(kVK_ANSI_A),
            modifiers: 1 << 18,
            isEnabled: true
        )
        XCTAssertEqual(legacyAppKitShortcut.displayString, "⌃A")
        XCTAssertTrue(legacyAppKitShortcut.isUsableGlobalShortcut)
        XCTAssertEqual(legacyAppKitShortcut.effectiveModifiers & HotKeyDefinition.control, HotKeyDefinition.control)
    }

    func testGlobalHotKeyConflictMessageIsActionable() {
        let message = GlobalHotKey.HotKeyError.registerFailed(-9878).localizedDescription

        XCTAssertTrue(message.contains("already used"))
        XCTAssertTrue(message.contains("another app"))
    }

    func testSpeechSettingsClampUserAdjustableValues() {
        let settings = SpeechSettings(
            rateMultiplier: 12,
            volume: -1,
            pitchMultiplier: 4,
            voiceIdentifier: "voice"
        ).clamped

        XCTAssertEqual(settings.rateMultiplier, 2.4)
        XCTAssertEqual(settings.volume, 0)
        XCTAssertEqual(settings.pitchMultiplier, 2.0)
        XCTAssertEqual(settings.voiceIdentifier, "voice")
    }

    func testSpeechVoiceMenuKeepsOnlyModernEnglishVoices() {
        let voices = [
            SpeechVoiceOption(identifier: "com.apple.voice.compact.en-US.Samantha", name: "Samantha", language: "en-US"),
            SpeechVoiceOption(identifier: "com.apple.voice.super-compact.en-GB.Daniel", name: "Daniel", language: "en-GB"),
            SpeechVoiceOption(identifier: "com.apple.voice.super-compact.fr-FR.Thomas", name: "Thomas", language: "fr-FR"),
            SpeechVoiceOption(identifier: "com.apple.speech.synthesis.voice.Hysterical", name: "Jester", language: "en-US"),
            SpeechVoiceOption(identifier: "com.apple.eloquence.en-US.Eddy", name: "Eddy", language: "en-US")
        ]

        XCTAssertEqual(
            voices.filter(\.isRecommendedStudyVoice).map(\.name),
            ["Samantha", "Daniel"]
        )
    }

    func testCaptureJavaScriptUsesBundledHandoffCaptureScript() {
        let script = CaptureJavaScript.build(mode: .question)

        XCTAssertTrue(script.contains("__uworldTTSCaptureInternals"))
        XCTAssertTrue(script.contains("isLikelyInterfaceText"))
        XCTAssertTrue(script.contains("function captureTables"))
        XCTAssertTrue(script.contains("function captureMediaReferences"))
        XCTAssertTrue(script.contains("tables: captureTables()"))
        XCTAssertTrue(script.contains("media: captureMediaReferences()"))
        XCTAssertTrue(script.contains("captureUWorldSegments(\"question\")"))
        XCTAssertFalse(script.contains("127.0.0.1:8765"))
    }

    func testHighlightJavaScriptUsesCapturedTextRangePayload() {
        var segment = CapturedSegment(
            id: "seg-1-0",
            text: "What should be reviewed?",
            role: .questionTask,
            region: .left,
            rect: CapturedRect(x: 10, y: 20, width: 200, height: 24)
        )
        segment.textNodePath = "0.1.0"
        segment.startOffset = 4
        segment.endOffset = 28

        let highlightScript = HighlightJavaScript.build(segment: segment)
        let clearScript = HighlightJavaScript.clear()

        XCTAssertTrue(highlightScript.contains("__uworldTTSHighlight"))
        XCTAssertTrue(highlightScript.contains("\"id\":\"seg-1-0\""))
        XCTAssertTrue(highlightScript.contains("\"textNodePath\":\"0.1.0\""))
        XCTAssertTrue(highlightScript.contains("\"startOffset\":4"))
        XCTAssertTrue(clearScript.contains("__uworldTTSClearHighlight"))
        XCTAssertTrue(clearScript.contains("return \"cleared\""))
    }

    func testSubmitJavaScriptFindsVisibleSubmitButtonInFixture() throws {
        let script = SubmitJavaScript.build()

        XCTAssertTrue(script.contains("querySelectorAll"))
        XCTAssertTrue(script.contains("submit"))
        XCTAssertTrue(script.contains("scrollIntoView"))
        XCTAssertFalse(script.contains("UWorld"))
    }

    @MainActor
    func testStudyActionRouterCanUseInjectedServicesWithoutSafari() async throws {
        let browser = FakeBrowserAutomation(captureJSON: """
        {"mode":"question","segments":[
          {"id":"stem","text":"A student reads a stem.","role":"stem","region":"left","rect":{"x":0,"y":0,"width":1,"height":1}},
          {"id":"task","text":"What should be reviewed?","role":"question","region":"left","rect":{"x":0,"y":2,"width":1,"height":1}}
        ]}
        """)
        let speech = RecordingSpeechBackend()
        let router = StudyActionRouter(browser: browser, speech: speech)

        let result = await router.run(.readQuestion)

        XCTAssertEqual(result.status, .succeeded)
        XCTAssertEqual(speech.spokenTexts, ["What should be reviewed?", "A student reads a stem."])
    }

    func testCaptureJavaScriptOnlyUsesBottomChromeHeuristicForViewportIntersectingText() {
        let script = CaptureJavaScript.build(mode: .question)

        XCTAssertTrue(script.contains("function rectIntersectsViewport"))
        XCTAssertTrue(script.contains("rectIntersectsViewport(rect, viewportHeight)"))
    }

    @MainActor
    func testStudyActionRouterNextQuestionAndReadPressesRightArrowBeforeReading() async throws {
        let eventLog = EventLog()
        let browser = FakeBrowserAutomation(captureJSON: """
        {"mode":"question","segments":[
          {"id":"stem","text":"A student sees a stem.","role":"stem","region":"left","rect":{"x":0,"y":0,"width":1,"height":1}},
          {"id":"task","text":"What should be reviewed?","role":"question","region":"left","rect":{"x":0,"y":2,"width":1,"height":1}}
        ]}
        """, eventLog: eventLog)
        let speech = RecordingSpeechBackend(eventLog: eventLog)
        let router = StudyActionRouter(browser: browser, speech: speech)

        let result = await router.run(.nextQuestionAndRead)

        XCTAssertEqual(result.status, .succeeded)
        XCTAssertEqual(eventLog.events.first, "arrow")
        XCTAssertEqual(eventLog.events.dropFirst().first, "capture")
    }

    @MainActor
    func testStudyActionRouterHighlightsEachSegmentBeforeReadingIt() async throws {
        let eventLog = EventLog()
        let browser = FakeBrowserAutomation(captureJSON: """
        {"mode":"question","segments":[
          {"id":"stem","text":"A student reads a stem.","role":"stem","region":"left","rects":[{"x":0,"y":0,"width":1,"height":1}],"textNodePath":"0.0","startOffset":0,"endOffset":23},
          {"id":"task","text":"What should be reviewed?","role":"question_task","region":"left","rects":[{"x":0,"y":2,"width":1,"height":1}],"textNodePath":"0.1","startOffset":0,"endOffset":24}
        ]}
        """, eventLog: eventLog)
        let speech = RecordingSpeechBackend(eventLog: eventLog)
        let router = StudyActionRouter(browser: browser, speech: speech)

        let result = await router.run(.readQuestion)

        XCTAssertEqual(result.status, .succeeded)
        XCTAssertEqual(eventLog.events, [
            "capture",
            "highlight:task",
            "speak:What should be reviewed?",
            "highlight:stem",
            "speak:A student reads a stem.",
            "clear"
        ])
    }

    @MainActor
    func testStudyActionRouterPublishesReadAlongEventsInPlaybackOrder() async throws {
        let eventLog = EventLog()
        let browser = FakeBrowserAutomation(captureJSON: """
        {"mode":"question","segments":[
          {"id":"stem","text":"A student reads a stem.","role":"stem","region":"left","rects":[{"x":0,"y":0,"width":1,"height":1}],"textNodePath":"0.0","startOffset":0,"endOffset":23},
          {"id":"task","text":"What should be reviewed?","role":"question_task","region":"left","rects":[{"x":0,"y":2,"width":1,"height":1}],"textNodePath":"0.1","startOffset":0,"endOffset":24}
        ]}
        """, eventLog: eventLog)
        let speech = RecordingSpeechBackend(eventLog: eventLog)
        let router = StudyActionRouter(browser: browser, speech: speech)
        let readAlongSink = RecordingReadAlongPresentationSink(eventLog: eventLog)
        router.readAlongPresentationSink = readAlongSink

        let result = await router.run(.readQuestion)

        XCTAssertEqual(result.status, .succeeded)
        XCTAssertEqual(eventLog.events, [
            "capture",
            "readalong:start:question:2",
            "readalong:item:0:task#task",
            "highlight:task",
            "speak:What should be reviewed?",
            "readalong:item:1:stem",
            "highlight:stem",
            "speak:A student reads a stem.",
            "readalong:end",
            "clear"
        ])
    }

    @MainActor
    func testStudyActionRouterForwardsFinalReadAlongItemsAndTiming() async throws {
        let eventLog = EventLog()
        let browser = FakeBrowserAutomation(captureJSON: """
        {"mode":"question","segments":[
          {"id":"task","text":"What should be reviewed?","role":"question_task","region":"left","rects":[{"x":0,"y":0,"width":1,"height":1}],"textNodePath":"0.0","startOffset":0,"endOffset":24}
        ]}
        """, eventLog: eventLog)
        let speech = TimingReportingSpeechBackend(eventLog: eventLog)
        let router = StudyActionRouter(browser: browser, speech: speech)
        let readAlongSink = RecordingReadAlongPresentationSink(eventLog: eventLog)
        router.readAlongPresentationSink = readAlongSink

        let result = await router.run(.readQuestion)

        XCTAssertEqual(result.status, .succeeded)
        XCTAssertEqual(eventLog.events, [
            "capture",
            "readalong:start:question:1",
            "readalong:final:question:1:Final spoken text.",
            "readalong:timing:task#task#playback-0:2.50:qwenPreparedAudio",
            "readalong:cues:task#task#playback-0:weightedFallback:2",
            "readalong:progress:task#task#playback-0:1:0.50",
            "readalong:item:0:task#task",
            "highlight:task",
            "speak:Final spoken text.",
            "readalong:finish:0:task#task",
            "readalong:end",
            "clear"
        ])
    }

    @MainActor
    func testStudyActionRouterReadsCapturedQuestionTables() async throws {
        let browser = FakeBrowserAutomation(captureJSON: """
        {"mode":"question","segments":[
          {"id":"stem","text":"Examination of the cerebrospinal fluid shows:","role":"stem","region":"left","rect":{"x":20,"y":100,"width":500,"height":28}},
          {"id":"task","text":"Which diagnosis is most likely?","role":"question_task","region":"left","rect":{"x":20,"y":360,"width":500,"height":28}}
        ],
        "tables":[
          {
            "id":"csf-results",
            "rows":[
              ["Opening pressure","370 mm H2O"],
              ["Glucose","80 mg/dL"],
              ["Protein","24 mg/dL"],
              ["Leukocytes","1 cell/μL"],
              ["Red blood cells","0 cells/μL"],
              ["Gram stain","negative"]
            ],
            "region":"center",
            "role":"table",
            "rect":{"x":420,"y":150,"width":420,"height":180}
          }
        ]}
        """)
        let speech = RecordingSpeechBackend()
        let router = StudyActionRouter(browser: browser, speech: speech)

        let result = await router.run(.readQuestion)

        XCTAssertEqual(result.status, .succeeded)
        XCTAssertEqual(speech.spokenTexts, [
            "Which diagnosis is most likely?",
            "Examination of the cerebrospinal fluid shows",
            "Opening pressure 370",
            "Glucose 80",
            "Protein 24",
            "Leukocytes 1",
            "Red blood cells 0",
            "Gram stain negative"
        ])
    }

    @MainActor
    func testStudyActionRouterSkipsCapturedChoiceAndQuestionNavigationTables() async throws {
        let browser = FakeBrowserAutomation(captureJSON: """
        {"mode":"question","segments":[
          {"id":"question-number","text":"Question 12","role":"unknown","region":"left","rect":{"x":0,"y":70,"width":90,"height":24}},
          {"id":"stem","text":"A patient has progressive headaches.","role":"stem","region":"left","rect":{"x":20,"y":100,"width":500,"height":28}},
          {"id":"task","text":"Which diagnosis is most likely?","role":"question_task","region":"left","rect":{"x":20,"y":360,"width":500,"height":28}}
        ],
        "tables":[
          {
            "id":"question-navigation",
            "rows":[
              ["Question","12"],
              ["1","2","3","4"]
            ],
            "region":"left",
            "role":"table",
            "rect":{"x":0,"y":120,"width":90,"height":80}
          },
          {
            "id":"answer-choices",
            "rows":[
              ["A","Observation"],
              ["B","Acetazolamide"],
              ["C","Lumbar puncture"]
            ],
            "region":"left",
            "role":"table",
            "rect":{"x":20,"y":230,"width":560,"height":120}
          }
        ]}
        """)
        let speech = RecordingSpeechBackend()
        let router = StudyActionRouter(browser: browser, speech: speech)

        let result = await router.run(.readQuestion)

        XCTAssertEqual(result.status, .succeeded)
        XCTAssertEqual(speech.spokenTexts, [
            "Which diagnosis is most likely?",
            "A patient has progressive headaches."
        ])
    }

    @MainActor
    func testStudyActionRouterKeepsQuestionTaskFullyHighlightedAcrossCachedStarterSplit() async throws {
        let fullTask = "Which of the following is most likely to reveal the finding?"
        let browser = FakeBrowserAutomation(captureJSON: """
        {"mode":"question","segments":[
          {"id":"task","text":"\(fullTask)","role":"question_task","region":"left","rects":[{"x":0,"y":2,"width":1,"height":1}],"textNodePath":"0.1","startOffset":0,"endOffset":\(fullTask.utf16.count)}
        ]}
        """)
        let speech = RecordingSpeechBackend()
        let router = StudyActionRouter(browser: browser, speech: speech)

        let result = await router.run(.readQuestion)

        XCTAssertEqual(result.status, .succeeded)
        XCTAssertEqual(speech.spokenTexts, [
            "Which of the following is most likely",
            "to reveal the finding?"
        ])
        XCTAssertEqual(browser.highlightScripts.count, 2)
        for script in browser.highlightScripts {
            XCTAssertTrue(script.contains("\"text\":\"\(fullTask)\""))
            XCTAssertTrue(script.contains("\"startOffset\":0"))
            XCTAssertTrue(script.contains("\"endOffset\":\(fullTask.utf16.count)"))
        }
    }

    @MainActor
    func testStudyActionRouterReportsStoppedPlaybackOnSpeechCancellation() async throws {
        let browser = FakeBrowserAutomation(captureJSON: """
        {"mode":"question","segments":[
          {"id":"stem","text":"A student reads a stem.","role":"stem","region":"left","rect":{"x":0,"y":0,"width":1,"height":1}},
          {"id":"task","text":"What should be reviewed?","role":"question_task","region":"left","rect":{"x":0,"y":2,"width":1,"height":1}}
        ]}
        """)
        let speech = CancellingSpeechBackend()
        let router = StudyActionRouter(browser: browser, speech: speech)

        let result = await router.run(.readQuestion)

        XCTAssertEqual(result.status, .succeeded)
        XCTAssertEqual(result.message, "Playback stopped.")
        XCTAssertEqual(speech.spokenTexts, ["What should be reviewed?"])
    }
}

private final class FakeBrowserAutomation: BrowserAutomationService {
    let captureJSON: String
    let eventLog: EventLog?
    private(set) var highlightScripts: [String] = []

    init(captureJSON: String, eventLog: EventLog? = nil) {
        self.captureJSON = captureJSON
        self.eventLog = eventLog
    }

    func executeJavaScriptInUWorldTab(_ javaScript: String) async -> BrowserAutomationResult {
        scripts.append(javaScript)
        if javaScript.contains("captureUWorldSegments") {
            eventLog?.events.append("capture")
            return .success(captureJSON)
        }
        if javaScript.contains("ArrowRight") {
            eventLog?.events.append("arrow")
            return .success("pressed")
        }
        if javaScript.contains("return \"highlighted\"") {
            highlightScripts.append(javaScript)
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

    private(set) var scripts: [String] = []
}

private final class EventLog {
    var events: [String] = []
}

private final class RecordingReadAlongPresentationSink: ReadAlongPresentationSink {
    private let eventLog: EventLog

    init(eventLog: EventLog) {
        self.eventLog = eventLog
    }

    @MainActor
    func readAlongPresentationWillStart(items: [SpeechPlaybackItem], mode: CaptureMode) {
        eventLog.events.append("readalong:start:\(mode.rawValue):\(items.count)")
    }

    @MainActor
    func readAlongPresentationDidReceiveFinalPlaybackItems(_ items: [SpeechPlaybackItem], mode: CaptureMode) {
        eventLog.events.append("readalong:final:\(mode.rawValue):\(items.count):\(items.map(\.text).joined(separator: "|"))")
    }

    @MainActor
    func readAlongPresentationWillSpeak(item: SpeechPlaybackItem, itemIndex: Int) {
        eventLog.events.append("readalong:item:\(itemIndex):\(item.segmentID)")
    }

    @MainActor
    func readAlongPresentationDidReceiveTiming(_ timing: SpeechPlaybackItemTiming) {
        eventLog.events.append(
            "readalong:timing:\(timing.itemID):\(String(format: "%.2f", timing.durationSeconds)):\(timing.source.rawValue)"
        )
    }

    @MainActor
    func readAlongPresentationDidReceiveWordCueTrack(_ track: SpeechPlaybackWordCueTrack) {
        eventLog.events.append(
            "readalong:cues:\(track.itemID):\(track.source.rawValue):\(track.cues.count)"
        )
    }

    @MainActor
    func readAlongPresentationDidReceiveProgress(_ progress: SpeechPlaybackProgress) {
        eventLog.events.append(
            "readalong:progress:\(progress.itemID):\(progress.currentTokenIndex ?? -1):\(String(format: "%.2f", progress.sourcePositionSeconds))"
        )
    }

    @MainActor
    func readAlongPresentationDidFinishItem(item: SpeechPlaybackItem, itemIndex: Int) {
        eventLog.events.append("readalong:finish:\(itemIndex):\(item.segmentID)")
    }

    @MainActor
    func readAlongPresentationDidEnd() {
        eventLog.events.append("readalong:end")
    }
}

private final class RecordingSpeechBackend: SpeechBackend {
    private let eventLog: EventLog?
    private(set) var spokenTexts: [String] = []

    init(eventLog: EventLog? = nil) {
        self.eventLog = eventLog
    }

    func speak(_ text: String) async throws {
        spokenTexts.append(text)
        eventLog?.events.append("speak:\(text)")
    }

    func stop() async {}
}

@MainActor
private final class TimingReportingSpeechBackend: SpeechBackend, SpeechPlaybackTimingReporting {
    weak var timingSink: (any SpeechPlaybackTimingSink)?
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
        guard let first = items.first else { return }
        let finalItem = SpeechPlaybackItem(
            id: first.id,
            segmentID: first.segmentID,
            sourceText: first.sourceText,
            text: "Final spoken text.",
            audioCachePolicy: first.audioCachePolicy
        )
        timingSink?.speechPlaybackWillUseFinalItems([finalItem])
        timingSink?.speechPlaybackDidReceiveTiming(SpeechPlaybackItemTiming(
            itemID: finalItem.id,
            segmentID: finalItem.segmentID,
            itemIndex: 0,
            durationSeconds: 2.5,
            source: .qwenPreparedAudio
        ))
        timingSink?.speechPlaybackDidReceiveWordCueTrack(.init(
            itemID: finalItem.id,
            segmentID: finalItem.segmentID,
            itemIndex: 0,
            source: .weightedFallback,
            cues: [
                .init(tokenIndex: 0, startSeconds: 0, endSeconds: 0.5),
                .init(tokenIndex: 1, startSeconds: 0.5, endSeconds: 1),
            ]
        ))
        timingSink?.speechPlaybackDidReceiveProgress(.init(
            playbackID: UUID(),
            itemID: finalItem.id,
            segmentID: finalItem.segmentID,
            itemIndex: 0,
            sourcePositionSeconds: 0.5,
            sourceDurationSeconds: 1,
            currentTokenIndex: 1
        ))
        await willSpeak(finalItem)
        try await speak(finalItem.text)
        timingSink?.speechPlaybackDidFinishItem(
            itemID: finalItem.id,
            segmentID: finalItem.segmentID,
            itemIndex: 0
        )
    }

    func stop() async {}
}

private final class CancellingSpeechBackend: SpeechBackend {
    private(set) var spokenTexts: [String] = []

    func speak(_ text: String) async throws {
        spokenTexts.append(text)
        throw CancellationError()
    }

    func stop() async {}
}
