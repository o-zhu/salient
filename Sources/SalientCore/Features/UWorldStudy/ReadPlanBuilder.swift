import Foundation

public struct ReadPlan: Equatable, Sendable {
    public var items: [ReadPlanItem]

    public init(items: [ReadPlanItem]) {
        self.items = items
    }
}

public struct ReadPlanItem: Equatable, Sendable, Identifiable {
    public var id: String { segmentID + ":" + text }
    public var segmentID: String
    public var text: String
    public var audioCachePolicy: QwenAudioCachePolicy

    public init(
        segmentID: String,
        text: String,
        audioCachePolicy: QwenAudioCachePolicy = .transient
    ) {
        self.segmentID = segmentID
        self.text = text
        self.audioCachePolicy = audioCachePolicy
    }
}

public struct ReadPlanOptions: Equatable, Sendable {
    public static let `default` = ReadPlanOptions()

    public var readsLastSentenceFirst: Bool
    public var skipsParentheticalContent: Bool
    public var usesQuestionPromptAudioLibrary: Bool

    public init(
        readsLastSentenceFirst: Bool = true,
        skipsParentheticalContent: Bool = false,
        usesQuestionPromptAudioLibrary: Bool = true
    ) {
        self.readsLastSentenceFirst = readsLastSentenceFirst
        self.skipsParentheticalContent = skipsParentheticalContent
        self.usesQuestionPromptAudioLibrary = usesQuestionPromptAudioLibrary
    }
}

public struct ReadPlanBuilder: Sendable {
    private struct ReadableQuestionEntry {
        var segmentID: String
        var text: String
        var rect: CapturedRect
        var sourceOrder: Int
    }

    private struct AnswerChoiceMarker {
        var labelValue: Int
        var rect: CapturedRect
        var sourceOrder: Int
    }

    private struct AnswerChoiceRegion {
        var top: Double
        var bottom: Double
        var labelMinX: Double
        var labelMaxX: Double

        func containsSegmentRect(_ rect: CapturedRect) -> Bool {
            guard rect != .zero else { return false }
            let centerX = rect.x + rect.width / 2
            let centerY = rect.y + rect.height / 2
            return centerY >= top &&
                centerY <= bottom &&
                centerX >= labelMinX - 24
        }

        func containsTableRect(_ rect: CapturedRect) -> Bool {
            guard rect != .zero else { return false }
            let verticalOverlap = min(rect.y + rect.height, bottom) - max(rect.y, top)
            guard verticalOverlap > 0 else { return false }
            return rect.x + rect.width >= labelMinX - 24 &&
                rect.x <= labelMaxX + 1_200
        }
    }

    public var options: ReadPlanOptions

    static let commonQuestionStarterPhrases = [
        "Which of the following responses best explains",
        "Which of the following findings best explains",
        "Which of the following is the most likely diagnosis?",
        "Which of the following is the best next step?",
        "Which of the following is the most appropriate",
        "Which of the following would most likely",
        "Which of the following is most likely",
        "Which of the following is most likely?",
        "Which of the following is the most likely",
        "Which of the following is the next best",
        "Which of the following is the best",
        "Which of the following best explains",
        "Which of the following",
        "The most likely diagnosis is",
        "The next best step is",
        "What is the most likely",
        "What is the next best step",
        "Which diagnosis is most likely"
    ]

    private static let questionTaskPatterns = [
        "which of the following",
        "most likely",
        "best next step",
        "next step",
        "diagnosis",
        "mechanism",
        "cause",
        "treatment",
        "management"
    ]

    public init(options: ReadPlanOptions = .default) {
        self.options = options
    }

    public func questionPlan(from payload: UWorldCapturePayload) -> ReadPlan {
        questionPlan(from: payload.segments, tables: payload.tables)
    }

    public func questionPlan(from segments: [CapturedSegment], tables: [CapturedTable] = []) -> ReadPlan {
        let answerChoiceRegions = answerChoiceRegions(from: segments, tables: tables)
        let readableSegments = coalescedInlineSegments(
            from: readableQuestionSegments(from: segments).filter {
                !isInsideAnswerChoiceRegion($0, regions: answerChoiceRegions)
            }
        )
        let readableEntries = readableQuestionEntries(
            from: readableSegments,
            tables: tables,
            answerChoiceRegions: answerChoiceRegions
        )
        guard !readableEntries.isEmpty else {
            return ReadPlan(items: [])
        }

        let task = findQuestionTask(in: readableSegments)
        var items: [ReadPlanItem] = []

        if let task, options.readsLastSentenceFirst {
            items.append(contentsOf: taskItems(for: task))
        }

        for entry in readableEntries {
            if entry.segmentID == task?.id {
                if let task, !options.readsLastSentenceFirst {
                    items.append(contentsOf: taskItems(for: task))
                }
                continue
            }
            let text = speechText(from: entry.text)
            if !text.isEmpty {
                items.append(ReadPlanItem(segmentID: entry.segmentID, text: text, audioCachePolicy: .persistent))
            }
        }

        return ReadPlan(items: deduplicated(items))
    }

    public func explanationPlan(from segments: [CapturedSegment]) -> ReadPlan {
        var readable = coalescedInlineSegments(from: segments.filter { $0.region == .right && isReadable($0) })
        if readable.isEmpty {
            readable = coalescedInlineSegments(from: segments.filter(isReadable))
        }

        let items = readable.compactMap { segment in
            let text = speechText(from: segment.text)
            return text.isEmpty ? nil : ReadPlanItem(segmentID: segment.id, text: text)
        }
        return ReadPlan(items: deduplicated(items))
    }

    private func taskItems(for task: CapturedSegment) -> [ReadPlanItem] {
        let text = speechText(from: task.text)
        guard !text.isEmpty else { return [] }
        if options.usesQuestionPromptAudioLibrary,
           let split = Self.commonQuestionStarterSplit(text) {
            return [
                ReadPlanItem(segmentID: task.id + "#starter", text: split.starter, audioCachePolicy: .persistent),
                ReadPlanItem(segmentID: task.id + "#tail", text: split.tail, audioCachePolicy: .persistent)
            ]
        }
        return [
            ReadPlanItem(segmentID: task.id + "#task", text: text, audioCachePolicy: .persistent)
        ]
    }

    private func speechText(from rawText: String) -> String {
        let text = options.skipsParentheticalContent
            ? Self.removingParentheticalContent(from: rawText)
            : rawText
        return text.trimmedForSpeech
    }

    private func readableQuestionSegments(from segments: [CapturedSegment]) -> [CapturedSegment] {
        segments.filter { segment in
            segment.region != .right && isReadable(segment)
        }
    }

    private func coalescedInlineSegments(from segments: [CapturedSegment]) -> [CapturedSegment] {
        var coalesced: [CapturedSegment] = []
        var pending: [CapturedSegment] = []

        func flushPending() {
            guard !pending.isEmpty else { return }
            coalesced.append(Self.mergedInlineSegment(from: pending))
            pending.removeAll(keepingCapacity: true)
        }

        for segment in segments {
            if let previous = pending.last,
               Self.shouldMergeInline(previous: previous, next: segment) {
                pending.append(segment)
            } else {
                flushPending()
                pending = [segment]
            }
        }
        flushPending()
        return coalesced
    }

    private func readableQuestionEntries(
        from segments: [CapturedSegment],
        tables: [CapturedTable],
        answerChoiceRegions: [AnswerChoiceRegion]
    ) -> [ReadableQuestionEntry] {
        var entries = segments.enumerated().map { index, segment in
            ReadableQuestionEntry(
                segmentID: segment.id,
                text: segment.text,
                rect: Self.leadingRect(for: segment) ?? segment.rect,
                sourceOrder: index
            )
        }
        let segmentCount = entries.count
        for (tableIndex, table) in tables.enumerated() where table.region != .right {
            entries.append(contentsOf: tableReadEntries(
                from: table,
                answerChoiceRegions: answerChoiceRegions,
                sourceOrderBase: segmentCount + tableIndex * 1_000
            ))
        }

        return visuallyOrdered(entries)
    }

    private func visuallyOrdered(_ entries: [ReadableQuestionEntry]) -> [ReadableQuestionEntry] {
        guard entries.contains(where: { $0.rect != .zero }) else { return entries }
        return entries.sorted { lhs, rhs in
            let lhsHasRect = lhs.rect != .zero
            let rhsHasRect = rhs.rect != .zero
            if lhsHasRect != rhsHasRect {
                return lhsHasRect
            }
            guard lhsHasRect, rhsHasRect else {
                return lhs.sourceOrder < rhs.sourceOrder
            }
            if Self.rectsShareLine(lhs.rect, rhs.rect), lhs.rect.x != rhs.rect.x {
                return lhs.rect.x < rhs.rect.x
            }
            if lhs.rect.y != rhs.rect.y {
                return lhs.rect.y < rhs.rect.y
            }
            if lhs.rect.x != rhs.rect.x {
                return lhs.rect.x < rhs.rect.x
            }
            return lhs.sourceOrder < rhs.sourceOrder
        }
    }

    private func tableReadEntries(
        from table: CapturedTable,
        answerChoiceRegions: [AnswerChoiceRegion],
        sourceOrderBase: Int
    ) -> [ReadableQuestionEntry] {
        let rows = table.rows.isEmpty
            ? table.cells.map { row in row.map(\.text) }
            : table.rows
        guard !isLikelyAnswerChoiceTable(
            table: table,
            rows: rows,
            answerChoiceRegions: answerChoiceRegions
        ) else {
            return []
        }
        let rowCount = rows.count
        return rows.enumerated().compactMap { rowIndex, row in
            let cleanCells = row.map(\.trimmedForSpeech).filter { !$0.isEmpty }
            guard isReadableQuestionTableRow(cells: cleanCells, table: table) else {
                return nil
            }
            let text = tableRowText(cells: row, headers: table.headers)
            guard !text.isEmpty, !TTSNormalizer.isLikelyUnitText(text) else {
                return nil
            }
            return ReadableQuestionEntry(
                segmentID: "\(table.id)#row-\(rowIndex)",
                text: text,
                rect: tableRowRect(table: table, rowIndex: rowIndex, rowCount: rowCount),
                sourceOrder: sourceOrderBase + rowIndex
            )
        }
    }

    private func isReadableQuestionTableRow(cells: [String], table: CapturedTable) -> Bool {
        guard cells.count >= 2 else { return false }
        guard !isLikelyAnswerChoiceTableRow(cells) else { return false }
        guard !isLikelyInterfaceTableRow(cells: cells, table: table) else { return false }
        return true
    }

    private func isLikelyAnswerChoiceTable(rows: [[String]]) -> Bool {
        let labels = rows.compactMap { Self.answerChoiceLabel(in: $0) }
        guard labels.count >= 2 else { return false }

        var previous: Int?
        for label in labels {
            guard let scalar = label.unicodeScalars.first else { continue }
            let value = Int(scalar.value)
            if let previous, value == previous + 1 {
                return true
            }
            previous = value
        }
        return false
    }

    private func isLikelyAnswerChoiceTable(
        table: CapturedTable,
        rows: [[String]],
        answerChoiceRegions: [AnswerChoiceRegion]
    ) -> Bool {
        if isLikelyAnswerChoiceTable(rows: rows) {
            return true
        }
        guard table.region != .right else { return false }
        let rects = table.rects.isEmpty ? [table.rect] : table.rects
        return rects.contains { rect in
            answerChoiceRegions.contains { region in
                region.containsTableRect(rect)
            }
        }
    }

    private func isLikelyAnswerChoiceTableRow(_ cells: [String]) -> Bool {
        if Self.answerChoiceLabel(in: cells) != nil {
            return true
        }

        guard let first = cells.first?.trimmedForSpeech else { return false }
        if Self.matches(first, #"^[\("']?\s*[A-Ja-j]\s*[\).]?[\)"']?$"#) {
            return true
        }

        let combined = cells.joined(separator: " ").trimmedForSpeech
        return Self.matches(combined, #"^[\("']?\s*[A-Ja-j]\s*[\).]\s+\S"#)
    }

    private static func answerChoiceLabel(in cells: [String]) -> String? {
        let cleanCells = cells.map(\.trimmedForSpeech).filter { !$0.isEmpty }
        guard !cleanCells.isEmpty else { return nil }

        for cell in cleanCells.prefix(4) {
            if let label = answerChoiceLabelOnly(in: cell) {
                return label
            }
            if let label = leadingAnswerChoiceLabel(in: cell) {
                return label
            }
        }

        return leadingAnswerChoiceLabel(in: cleanCells.prefix(5).joined(separator: " "))
    }

    private static func answerChoiceLabelOnly(in text: String) -> String? {
        capturedLabel(
            in: text,
            pattern: #"^\s*(?:["'“”‘’]\s*)?(?:\(([A-Ja-j])\)|([A-Ja-j])[\).]?)\s*$"#
        )
    }

    private static func leadingAnswerChoiceLabel(in text: String) -> String? {
        capturedLabel(
            in: text,
            pattern: #"^\s*(?:[○◯●◉◎]\s*)?(?:[✕✖×❌✓✔✅☑]\s*)?(?:["'“”‘’]\s*)?(?:\(([A-Ja-j])\)|([A-Ja-j])[\).])\s+\S"#
        )
    }

    private static func capturedLabel(in text: String, pattern: String) -> String? {
        let compact = text.trimmedForSpeech
        guard let regex = try? NSRegularExpression(pattern: pattern, options: []) else {
            return nil
        }
        let range = NSRange(compact.startIndex..<compact.endIndex, in: compact)
        guard let match = regex.firstMatch(in: compact, range: range) else {
            return nil
        }
        for index in 1..<match.numberOfRanges {
            guard let labelRange = Range(match.range(at: index), in: compact) else {
                continue
            }
            return String(compact[labelRange]).uppercased()
        }
        return nil
    }

    private func isLikelyInterfaceTableRow(cells: [String], table: CapturedTable) -> Bool {
        let combined = cells.joined(separator: " ").trimmedForSpeech
        guard !combined.isEmpty else { return true }
        if Self.matches(combined, #"^question\s+\d+(?:\s+of\s+\d+)?$"#) {
            return true
        }
        if cells.count >= 2,
           cells[0].caseInsensitiveCompare("question") == .orderedSame,
           Self.matches(cells[1], #"^\d{1,4}$"#) {
            return true
        }
        if cells.allSatisfy({ Self.matches($0, #"^\d{1,4}$"#) }) {
            return true
        }
        if table.rect != .zero,
           table.rect.x < 120,
           combined.count <= 80,
           cells.allSatisfy({ Self.isShortInterfaceToken($0) }) {
            return true
        }
        return false
    }

    private static func isShortInterfaceToken(_ text: String) -> Bool {
        let compact = text.trimmedForSpeech
        guard !compact.isEmpty else { return true }
        return matches(compact, #"^(?:\d{1,4}|question|previous|next|mark|review|submit|pause|resume|correct|incorrect)$"#)
    }

    private func tableRowText(cells: [String], headers: [String]) -> String {
        let cleanCells = cells.map(\.trimmedForSpeech).filter { !$0.isEmpty }
        guard !cleanCells.isEmpty else { return "" }

        let cleanHeaders = headers.map(\.trimmedForSpeech).filter { !$0.isEmpty }
        guard cleanHeaders.count == cleanCells.count, cleanHeaders.count > 2 else {
            return cleanCells.joined(separator: " ")
        }

        return zip(cleanHeaders, cleanCells)
            .map { "\($0) \($1)" }
            .joined(separator: ". ")
    }

    private func tableRowRect(table: CapturedTable, rowIndex: Int, rowCount: Int) -> CapturedRect {
        guard table.rect != .zero, rowCount > 0 else {
            return table.rect
        }
        let rowHeight = table.rect.height / Double(rowCount)
        return CapturedRect(
            x: table.rect.x,
            y: table.rect.y + rowHeight * Double(rowIndex),
            width: table.rect.width,
            height: rowHeight
        )
    }

    private func isReadable(_ segment: CapturedSegment) -> Bool {
        guard segment.role != .ui, segment.role != .choice else {
            return false
        }

        let text = segment.text.trimmedForSpeech
        return !text.isEmpty &&
            !TTSNormalizer.isLikelyUnitText(text) &&
            !isLikelyInterfaceSegment(segment)
    }

    private func isLikelyInterfaceSegment(_ segment: CapturedSegment) -> Bool {
        let text = segment.text.trimmedForSpeech
        guard !text.isEmpty else { return true }
        if Self.matches(text, #"^question\s+\d+(?:\s+of\s+\d+)?$"#) {
            return true
        }
        if Self.matches(text, #"^\d+\s*/\s*\d+$"#) {
            return true
        }
        if Self.matches(text, #"^\d{1,3}%$"#) {
            return true
        }
        if Self.matches(text, #"^\d+\s+secs?(?:\s+time\s+spent)?$"#) {
            return true
        }
        if Self.matches(text, #"^time\s+spent$"#) {
            return true
        }
        if Self.matches(text, #"^(?:correct|incorrect)$"#) {
            return true
        }
        if segment.rect != .zero,
           segment.rect.x < 120,
           Self.matches(text, #"^\d{1,4}$"#) {
            return true
        }
        return false
    }

    private func isInsideAnswerChoiceRegion(
        _ segment: CapturedSegment,
        regions: [AnswerChoiceRegion]
    ) -> Bool {
        guard !regions.isEmpty else { return false }
        guard segment.region != .right else { return false }
        guard segment.role != .questionTask, segment.role != .question else {
            return false
        }
        let rects = segment.rects.isEmpty ? [segment.rect] : segment.rects
        return rects.contains { rect in
            regions.contains { region in
                region.containsSegmentRect(rect)
            }
        }
    }

    private func answerChoiceRegions(
        from segments: [CapturedSegment],
        tables: [CapturedTable]
    ) -> [AnswerChoiceRegion] {
        Self.answerChoiceRegions(from: segments) +
            tables.compactMap { answerChoiceRegion(from: $0) }
    }

    private static func answerChoiceRegions(from segments: [CapturedSegment]) -> [AnswerChoiceRegion] {
        let markers = segments.enumerated().compactMap { index, segment -> AnswerChoiceMarker? in
            guard segment.region != .right else { return nil }
            guard let label = answerChoiceLabel(in: [segment.text]),
                  let scalar = label.unicodeScalars.first else {
                return nil
            }
            let labelOnly = answerChoiceLabelOnly(in: segment.text) != nil
            guard segment.role == .choice || labelOnly else { return nil }
            guard let rect = leadingRect(for: segment) else { return nil }
            return AnswerChoiceMarker(
                labelValue: Int(scalar.value),
                rect: rect,
                sourceOrder: index
            )
        }
        .sorted { lhs, rhs in
            lhs.sourceOrder < rhs.sourceOrder
        }

        var regions: [AnswerChoiceRegion] = []
        var run: [AnswerChoiceMarker] = []

        func flushRun() {
            guard run.count >= 2,
                  let region = answerChoiceRegion(from: run) else {
                run.removeAll(keepingCapacity: true)
                return
            }
            regions.append(region)
            run.removeAll(keepingCapacity: true)
        }

        for marker in markers {
            if let last = run.last,
               marker.labelValue == last.labelValue + 1 {
                run.append(marker)
            } else {
                flushRun()
                run = [marker]
            }
        }
        flushRun()

        return regions
    }

    private func answerChoiceRegion(from table: CapturedTable) -> AnswerChoiceRegion? {
        guard table.region != .right else { return nil }
        let rows = table.rows.isEmpty
            ? table.cells.map { row in row.map(\.text) }
            : table.rows
        guard isLikelyAnswerChoiceTable(rows: rows) else {
            return nil
        }
        let rects = (table.rects.isEmpty ? [table.rect] : table.rects).filter { $0 != .zero }
        guard !rects.isEmpty else { return nil }
        let rect = Self.unionRect(rects)
        return AnswerChoiceRegion(
            top: rect.y - 8,
            bottom: rect.y + rect.height + 8,
            labelMinX: rect.x,
            labelMaxX: rect.x + rect.width
        )
    }

    private static func answerChoiceRegion(from run: [AnswerChoiceMarker]) -> AnswerChoiceRegion? {
        let rects = run.map(\.rect).filter { $0 != .zero }
        guard !rects.isEmpty else { return nil }

        let centersY = rects
            .map { $0.y + $0.height / 2 }
            .sorted()
        let rowGaps = zip(centersY.dropFirst(), centersY).map { $0 - $1 }.filter { $0 > 4 }
        let typicalRowGap = median(rowGaps) ?? max(32, (median(rects.map(\.height)) ?? 20) * 1.8)
        let topPadding = max(28, min(96, typicalRowGap * 1.35))
        let bottomPadding = max(16, min(64, typicalRowGap * 0.75))
        let minY = rects.map(\.y).min() ?? 0
        let maxY = rects.map { $0.y + $0.height }.max() ?? 0
        let minX = rects.map(\.x).min() ?? 0
        let maxX = rects.map { $0.x + $0.width }.max() ?? minX

        return AnswerChoiceRegion(
            top: minY - topPadding,
            bottom: maxY + bottomPadding,
            labelMinX: minX,
            labelMaxX: maxX
        )
    }

    private func findQuestionTask(in segments: [CapturedSegment]) -> CapturedSegment? {
        var best: CapturedSegment?
        for segment in segments {
            let text = segment.text.trimmedForSpeech.lowercased()
            if segment.role == .questionTask || segment.role == .question {
                best = segment
                continue
            }
            if text.hasSuffix("?") || Self.questionTaskPatterns.contains(where: { text.contains($0) }) {
                best = segment
            }
        }
        return best ?? segments.last
    }

    static func commonQuestionStarterSplit(_ text: String) -> (starter: String, tail: String)? {
        let trimmed = text.trimmedForSpeech
        guard !trimmed.isEmpty else { return nil }

        let quoteCharacters = CharacterSet(charactersIn: "\"'“”‘’")
        let edgeCharacters = CharacterSet.whitespacesAndNewlines.union(quoteCharacters)
        let content = trimmed.trimmingCharacters(in: edgeCharacters)
        let contentLower = content.lowercased()

        for starter in commonQuestionStarterPhrases.sorted(by: { $0.count > $1.count }) {
            let normalizedStarter = starter.trimmedForSpeech
            guard !normalizedStarter.isEmpty,
                  contentLower.hasPrefix(normalizedStarter.lowercased()) else {
                continue
            }

            let endIndex = content.index(content.startIndex, offsetBy: normalizedStarter.count)
            if endIndex < content.endIndex,
               content[endIndex].isLetter || content[endIndex].isNumber || content[endIndex] == "'" {
                continue
            }

            var tail = String(content[endIndex...]).trimmedForSpeech
            tail = tail.replacingOccurrences(
                of: #"^[,;:\-–—\s]+"#,
                with: "",
                options: .regularExpression
            )
            tail = tail.trimmingCharacters(in: edgeCharacters)
            guard tail.range(of: #"\w"#, options: .regularExpression) != nil else {
                return nil
            }
            return (normalizedStarter, tail)
        }

        return nil
    }

    private func deduplicated(_ items: [ReadPlanItem]) -> [ReadPlanItem] {
        var seen = Set<String>()
        return items.filter { item in
            let key = item.segmentID + "\u{1f}" + item.text
            return seen.insert(key).inserted
        }
    }

    private static func matches(_ text: String, _ pattern: String) -> Bool {
        text.range(of: pattern, options: [.regularExpression, .caseInsensitive]) != nil
    }

    private static func removingParentheticalContent(from text: String) -> String {
        var result = ""
        var parenthesisDepth = 0
        for character in text {
            if character == "(" {
                parenthesisDepth += 1
                continue
            }
            if character == ")" {
                parenthesisDepth = max(0, parenthesisDepth - 1)
                continue
            }
            if parenthesisDepth == 0 {
                result.append(character)
            }
        }
        return result
            .replacingOccurrences(of: #"\s+([,.;:!?])"#, with: "$1", options: .regularExpression)
            .trimmedForSpeech
    }

    private static func shouldMergeInline(previous: CapturedSegment, next: CapturedSegment) -> Bool {
        guard previous.region == next.region else { return false }
        guard previous.role != .ui, previous.role != .choice,
              next.role != .ui, next.role != .choice else {
            return false
        }
        guard !previous.text.trimmedForSpeech.isEmpty,
              !next.text.trimmedForSpeech.isEmpty else {
            return false
        }
        guard let previousRect = trailingRect(for: previous),
              let nextRect = leadingRect(for: next) else {
            return false
        }
        guard !endsHardSentenceBoundary(previous.text) else {
            return false
        }
        if endsWithLikelyDroppedSuperscriptUnit(previous.text),
           startsLikeNewSentence(next.text) {
            return false
        }
        if rectsShareLine(previousRect, nextRect) {
            let gap = nextRect.x - (previousRect.x + previousRect.width)
            let maxGap = max(18, min(previousRect.height, nextRect.height))
            return gap >= -4 && gap <= maxGap
        }

        return sameInlineContainer(previous, next) &&
            rectsAreSoftWrappedContinuation(previousRect, nextRect)
    }

    private static func mergedInlineSegment(from segments: [CapturedSegment]) -> CapturedSegment {
        guard let first = segments.first else {
            return CapturedSegment(id: "empty", text: "", role: .unknown, region: .unknown, rect: .zero)
        }
        guard segments.count > 1 else { return first }

        let rects = segments.flatMap { segment in
            segment.rects.isEmpty && segment.rect != .zero ? [segment.rect] : segment.rects
        }
        let rect = unionRect(rects)
        var merged = CapturedSegment(
            id: first.id,
            text: joinedInlineText(segments.map(\.text)),
            role: mergedRole(from: segments),
            region: first.region,
            rect: rect
        )
        merged.rects = rects.isEmpty ? (rect == .zero ? [] : [rect]) : rects
        merged.domPath = first.domPath
        merged.textNodePath = first.textNodePath
        merged.startOffset = first.startOffset
        merged.endOffset = segments.last?.endOffset
        merged.answerLabel = first.answerLabel
        merged.isSelected = segments.contains { $0.isSelected == true } ? true : first.isSelected
        merged.isCorrect = segments.contains { $0.isCorrect == true } ? true : first.isCorrect
        return merged
    }

    private static func mergedRole(from segments: [CapturedSegment]) -> SegmentRole {
        if segments.contains(where: { $0.role == .questionTask }) { return .questionTask }
        if segments.contains(where: { $0.role == .question }) { return .question }
        if segments.contains(where: { $0.role == .explanation }) { return .explanation }
        return segments.first?.role ?? .unknown
    }

    private static func joinedInlineText(_ texts: [String]) -> String {
        texts.reduce("") { partial, rawText in
            let text = rawText.trimmedForSpeech
            guard !text.isEmpty else { return partial }
            guard !partial.isEmpty else { return text }
            if shouldAttachWithoutSpace(previous: partial, next: text) {
                return partial + text
            }
            return partial + " " + text
        }
    }

    private static func shouldAttachWithoutSpace(previous: String, next: String) -> Bool {
        guard let nextFirst = next.unicodeScalars.first else { return false }
        if CharacterSet(charactersIn: ",.;:!?)]}%”’").contains(nextFirst) {
            return true
        }
        guard let previousLast = previous.unicodeScalars.last else { return false }
        return CharacterSet(charactersIn: "([{/“‘").contains(previousLast)
    }

    private static func endsHardSentenceBoundary(_ text: String) -> Bool {
        matches(text.trimmedForSpeech, #"[.!?]["”’')\]]*$"#)
    }

    private static func endsWithLikelyDroppedSuperscriptUnit(_ text: String) -> Bool {
        matches(text.trimmedForSpeech, #"(?:\bkg\s*/\s*m|/\s*(?:m|mm|cm))$"#)
    }

    private static func startsLikeNewSentence(_ text: String) -> Bool {
        guard let first = text.trimmedForSpeech.unicodeScalars.first else {
            return false
        }
        return CharacterSet.uppercaseLetters.contains(first)
    }

    private static func sameInlineContainer(_ lhs: CapturedSegment, _ rhs: CapturedSegment) -> Bool {
        guard let lhsKey = inlineContainerKey(for: lhs),
              let rhsKey = inlineContainerKey(for: rhs) else {
            return false
        }
        return lhsKey == rhsKey
    }

    private static func inlineContainerKey(for segment: CapturedSegment) -> String? {
        guard let domPath = segment.domPath?.trimmedForSpeech, !domPath.isEmpty else {
            return nil
        }
        var parts = domPath.components(separatedBy: " > ")
        while let tagName = parts.last.flatMap(domTagName), inlineDomTagNames.contains(tagName) {
            parts.removeLast()
        }
        return parts.isEmpty ? nil : parts.joined(separator: " > ")
    }

    private static func domTagName(from pathComponent: String) -> String? {
        pathComponent
            .split(separator: ":", maxSplits: 1)
            .first
            .map { String($0).lowercased() }
    }

    private static func leadingRect(for segment: CapturedSegment) -> CapturedRect? {
        if let first = segment.rects.first, first != .zero { return first }
        return segment.rect == .zero ? nil : segment.rect
    }

    private static func trailingRect(for segment: CapturedSegment) -> CapturedRect? {
        if let last = segment.rects.last, last != .zero { return last }
        return segment.rect == .zero ? nil : segment.rect
    }

    private static func rectsShareLine(_ lhs: CapturedRect, _ rhs: CapturedRect) -> Bool {
        let overlap = min(lhs.y + lhs.height, rhs.y + rhs.height) - max(lhs.y, rhs.y)
        let minHeight = max(1, min(lhs.height, rhs.height))
        if overlap / minHeight >= 0.45 {
            return true
        }
        let centerDelta = abs((lhs.y + lhs.height / 2) - (rhs.y + rhs.height / 2))
        return centerDelta <= max(4, minHeight * 0.35)
    }

    private static func rectsAreSoftWrappedContinuation(_ lhs: CapturedRect, _ rhs: CapturedRect) -> Bool {
        let lhsCenterY = lhs.y + lhs.height / 2
        let rhsCenterY = rhs.y + rhs.height / 2
        guard rhsCenterY > lhsCenterY else { return false }
        let verticalGap = rhs.y - (lhs.y + lhs.height)
        let maxVerticalGap = max(8, min(lhs.height, rhs.height) * 0.8)
        return verticalGap <= maxVerticalGap
    }

    private static func unionRect(_ rects: [CapturedRect]) -> CapturedRect {
        let nonZeroRects = rects.filter { $0 != .zero }
        guard let first = nonZeroRects.first else { return .zero }
        let minX = nonZeroRects.map(\.x).min() ?? first.x
        let minY = nonZeroRects.map(\.y).min() ?? first.y
        let maxX = nonZeroRects.map { $0.x + $0.width }.max() ?? first.x + first.width
        let maxY = nonZeroRects.map { $0.y + $0.height }.max() ?? first.y + first.height
        return CapturedRect(x: minX, y: minY, width: maxX - minX, height: maxY - minY)
    }

    private static func median(_ values: [Double]) -> Double? {
        guard !values.isEmpty else { return nil }
        let sorted = values.sorted()
        let middle = sorted.count / 2
        if sorted.count.isMultiple(of: 2) {
            return (sorted[middle - 1] + sorted[middle]) / 2
        }
        return sorted[middle]
    }

    private static let inlineDomTagNames: Set<String> = [
        "a", "abbr", "b", "cite", "code", "em", "font", "i", "label", "mark",
        "small", "span", "strong", "sub", "sup", "u"
    ]
}

extension String {
    var trimmedForSpeech: String {
        trimmingCharacters(in: .whitespacesAndNewlines)
            .replacingOccurrences(of: #"\s+"#, with: " ", options: .regularExpression)
    }
}
