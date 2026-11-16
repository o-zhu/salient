import Foundation

public enum CaptureMode: String, Codable, Equatable, Sendable {
    case question
    case explanation
}

public enum SegmentRole: String, Codable, Equatable, Sendable {
    case stem
    case question
    case questionTask = "question_task"
    case choice
    case explanation
    case ui
    case unknown

    public init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        let rawValue = try container.decode(String.self)
        self = SegmentRole(rawValue: rawValue) ?? .unknown
    }
}

public enum SegmentRegion: String, Codable, Equatable, Sendable {
    case left
    case right
    case center
    case unknown

    public init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        let rawValue = try container.decode(String.self)
        self = SegmentRegion(rawValue: rawValue) ?? .unknown
    }
}

public struct CapturedRect: Codable, Equatable, Sendable {
    public static let zero = CapturedRect(x: 0, y: 0, width: 0, height: 0)

    public var x: Double
    public var y: Double
    public var width: Double
    public var height: Double

    public init(x: Double, y: Double, width: Double, height: Double) {
        self.x = x
        self.y = y
        self.width = width
        self.height = height
    }
}

public struct CapturedSegment: Codable, Equatable, Sendable, Identifiable {
    public var id: String
    public var text: String
    public var role: SegmentRole
    public var region: SegmentRegion
    public var rect: CapturedRect
    public var rects: [CapturedRect]
    public var domPath: String?
    public var textNodePath: String?
    public var startOffset: Int?
    public var endOffset: Int?
    public var answerLabel: String?
    public var isSelected: Bool?
    public var isCorrect: Bool?

    public init(id: String, text: String, role: SegmentRole, region: SegmentRegion, rect: CapturedRect) {
        self.id = id
        self.text = text
        self.role = role
        self.region = region
        self.rect = rect
        self.rects = rect == .zero ? [] : [rect]
        self.domPath = nil
        self.textNodePath = nil
        self.startOffset = nil
        self.endOffset = nil
        self.answerLabel = nil
        self.isSelected = nil
        self.isCorrect = nil
    }

    enum CodingKeys: String, CodingKey {
        case id
        case text
        case role
        case region
        case rect
        case rects
        case domPath
        case textNodePath
        case startOffset
        case endOffset
        case answerLabel
        case isSelected
        case isCorrect
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decode(String.self, forKey: .id)
        text = try container.decodeIfPresent(String.self, forKey: .text) ?? ""
        role = try container.decodeIfPresent(SegmentRole.self, forKey: .role) ?? .unknown
        region = try container.decodeIfPresent(SegmentRegion.self, forKey: .region) ?? .unknown

        let decodedRects = try container.decodeIfPresent([CapturedRect].self, forKey: .rects) ?? []
        rects = decodedRects
        rect = try container.decodeIfPresent(CapturedRect.self, forKey: .rect) ?? decodedRects.first ?? .zero
        if rects.isEmpty, rect != .zero {
            rects = [rect]
        }

        domPath = try container.decodeIfPresent(String.self, forKey: .domPath)
        textNodePath = try container.decodeIfPresent(String.self, forKey: .textNodePath)
        startOffset = try container.decodeIfPresent(Int.self, forKey: .startOffset)
        endOffset = try container.decodeIfPresent(Int.self, forKey: .endOffset)
        answerLabel = try container.decodeIfPresent(String.self, forKey: .answerLabel)
        isSelected = try container.decodeIfPresent(Bool.self, forKey: .isSelected)
        isCorrect = try container.decodeIfPresent(Bool.self, forKey: .isCorrect)
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(id, forKey: .id)
        try container.encode(text, forKey: .text)
        try container.encode(role, forKey: .role)
        try container.encode(region, forKey: .region)
        try container.encode(rect, forKey: .rect)
        try container.encode(rects, forKey: .rects)
        try container.encodeIfPresent(domPath, forKey: .domPath)
        try container.encodeIfPresent(textNodePath, forKey: .textNodePath)
        try container.encodeIfPresent(startOffset, forKey: .startOffset)
        try container.encodeIfPresent(endOffset, forKey: .endOffset)
        try container.encodeIfPresent(answerLabel, forKey: .answerLabel)
        try container.encodeIfPresent(isSelected, forKey: .isSelected)
        try container.encodeIfPresent(isCorrect, forKey: .isCorrect)
    }
}

public struct CapturedTableCell: Codable, Equatable, Sendable {
    public var text: String
    public var rowSpan: Int
    public var columnSpan: Int
    public var isHeader: Bool
    public var rect: CapturedRect?

    public init(
        text: String,
        rowSpan: Int = 1,
        columnSpan: Int = 1,
        isHeader: Bool = false,
        rect: CapturedRect? = nil
    ) {
        self.text = text
        self.rowSpan = max(1, rowSpan)
        self.columnSpan = max(1, columnSpan)
        self.isHeader = isHeader
        self.rect = rect
    }

    private enum CodingKeys: String, CodingKey {
        case text
        case rowSpan
        case columnSpan
        case isHeader
        case rect
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        text = try container.decodeIfPresent(String.self, forKey: .text) ?? ""
        rowSpan = max(1, try container.decodeIfPresent(Int.self, forKey: .rowSpan) ?? 1)
        columnSpan = max(1, try container.decodeIfPresent(Int.self, forKey: .columnSpan) ?? 1)
        isHeader = try container.decodeIfPresent(Bool.self, forKey: .isHeader) ?? false
        rect = try container.decodeIfPresent(CapturedRect.self, forKey: .rect)
    }
}

public struct CapturedTable: Codable, Equatable, Sendable, Identifiable {
    public var id: String
    public var caption: String?
    public var headers: [String]
    public var rows: [[String]]
    public var cells: [[CapturedTableCell]]
    public var region: SegmentRegion
    public var role: String?
    public var rect: CapturedRect
    public var rects: [CapturedRect]
    public var domPath: String?

    public init(
        id: String,
        caption: String? = nil,
        headers: [String] = [],
        rows: [[String]] = [],
        cells: [[CapturedTableCell]] = [],
        region: SegmentRegion = .unknown,
        role: String? = nil,
        rect: CapturedRect = .zero,
        rects: [CapturedRect] = [],
        domPath: String? = nil
    ) {
        self.id = id
        self.caption = caption
        self.headers = headers
        self.rows = rows
        self.cells = cells
        self.region = region
        self.role = role
        self.rect = rect
        self.rects = rects.isEmpty && rect != .zero ? [rect] : rects
        self.domPath = domPath
    }

    private enum CodingKeys: String, CodingKey {
        case id
        case caption
        case headers
        case rows
        case cells
        case region
        case role
        case rect
        case rects
        case domPath
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decodeIfPresent(String.self, forKey: .id) ?? UUID().uuidString
        caption = try container.decodeIfPresent(String.self, forKey: .caption)
        headers = try container.decodeIfPresent([String].self, forKey: .headers) ?? []
        rows = try container.decodeIfPresent([[String]].self, forKey: .rows) ?? []
        cells = try container.decodeIfPresent([[CapturedTableCell]].self, forKey: .cells) ?? []
        region = try container.decodeIfPresent(SegmentRegion.self, forKey: .region) ?? .unknown
        role = try container.decodeIfPresent(String.self, forKey: .role)
        let decodedRects = try container.decodeIfPresent([CapturedRect].self, forKey: .rects) ?? []
        rects = decodedRects
        rect = try container.decodeIfPresent(CapturedRect.self, forKey: .rect) ?? decodedRects.first ?? .zero
        if rects.isEmpty, rect != .zero {
            rects = [rect]
        }
        domPath = try container.decodeIfPresent(String.self, forKey: .domPath)
    }
}

public struct CapturedMediaReference: Codable, Equatable, Sendable, Identifiable {
    public var id: String
    public var kind: String
    public var altText: String?
    public var caption: String?
    public var nearbyText: String?
    public var role: String?
    public var region: SegmentRegion
    public var rect: CapturedRect
    public var rects: [CapturedRect]
    public var domPath: String?

    public init(
        id: String,
        kind: String,
        altText: String? = nil,
        caption: String? = nil,
        nearbyText: String? = nil,
        role: String? = nil,
        region: SegmentRegion = .unknown,
        rect: CapturedRect = .zero,
        rects: [CapturedRect] = [],
        domPath: String? = nil
    ) {
        self.id = id
        self.kind = kind
        self.altText = altText
        self.caption = caption
        self.nearbyText = nearbyText
        self.role = role
        self.region = region
        self.rect = rect
        self.rects = rects.isEmpty && rect != .zero ? [rect] : rects
        self.domPath = domPath
    }

    private enum CodingKeys: String, CodingKey {
        case id
        case kind
        case altText
        case caption
        case nearbyText
        case role
        case region
        case rect
        case rects
        case domPath
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decodeIfPresent(String.self, forKey: .id) ?? UUID().uuidString
        kind = try container.decodeIfPresent(String.self, forKey: .kind) ?? "media"
        altText = try container.decodeIfPresent(String.self, forKey: .altText)
        caption = try container.decodeIfPresent(String.self, forKey: .caption)
        nearbyText = try container.decodeIfPresent(String.self, forKey: .nearbyText)
        role = try container.decodeIfPresent(String.self, forKey: .role)
        region = try container.decodeIfPresent(SegmentRegion.self, forKey: .region) ?? .unknown
        let decodedRects = try container.decodeIfPresent([CapturedRect].self, forKey: .rects) ?? []
        rects = decodedRects
        rect = try container.decodeIfPresent(CapturedRect.self, forKey: .rect) ?? decodedRects.first ?? .zero
        if rects.isEmpty, rect != .zero {
            rects = [rect]
        }
        domPath = try container.decodeIfPresent(String.self, forKey: .domPath)
    }
}

public struct UWorldCapturePayload: Codable, Equatable, Sendable {
    public var requestId: String?
    public var mode: CaptureMode
    public var segments: [CapturedSegment]
    public var tables: [CapturedTable]
    public var media: [CapturedMediaReference]
    public var pageUrl: String?
    public var title: String?
    public var viewport: CapturedViewport?

    public init(
        requestId: String? = nil,
        mode: CaptureMode,
        segments: [CapturedSegment],
        tables: [CapturedTable] = [],
        media: [CapturedMediaReference] = [],
        pageUrl: String? = nil,
        title: String? = nil,
        viewport: CapturedViewport? = nil
    ) {
        self.requestId = requestId
        self.mode = mode
        self.segments = segments
        self.tables = tables
        self.media = media
        self.pageUrl = pageUrl
        self.title = title
        self.viewport = viewport
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        requestId = try container.decodeIfPresent(String.self, forKey: .requestId)
        mode = try container.decodeIfPresent(CaptureMode.self, forKey: .mode) ?? .question
        segments = try container.decodeIfPresent([CapturedSegment].self, forKey: .segments) ?? []
        tables = try container.decodeIfPresent([CapturedTable].self, forKey: .tables) ?? []
        media = try container.decodeIfPresent([CapturedMediaReference].self, forKey: .media) ?? []
        pageUrl = try container.decodeIfPresent(String.self, forKey: .pageUrl)
        title = try container.decodeIfPresent(String.self, forKey: .title)
        viewport = try container.decodeIfPresent(CapturedViewport.self, forKey: .viewport)
    }

    private enum CodingKeys: String, CodingKey {
        case requestId
        case mode
        case segments
        case tables
        case media
        case pageUrl
        case title
        case viewport
    }

    public static func decode(json: String) throws -> UWorldCapturePayload {
        let data = Data(json.utf8)
        return try JSONDecoder().decode(UWorldCapturePayload.self, from: data)
    }
}

public struct CapturedViewport: Codable, Equatable, Sendable {
    public var width: Double
    public var height: Double

    public init(width: Double, height: Double) {
        self.width = width
        self.height = height
    }
}
