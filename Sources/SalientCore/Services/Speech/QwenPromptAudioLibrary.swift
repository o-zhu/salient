import CryptoKit
import Foundation

public enum QwenPromptAudioLibraryEntrySource: String, Codable, Sendable {
    case narration

    /// Older manifests may name sources this build no longer writes; they still decode.
    public init(from decoder: Decoder) throws {
        _ = try decoder.singleValueContainer().decode(String.self)
        self = .narration
    }
}

public enum QwenPromptAudioLibraryEntryKind: String, Codable, Sendable {
    case fullPrompt
    case derivedPrefix
}

public struct QwenPromptAudioLibraryContext: Codable, Equatable, Hashable, Sendable {
    public var lane: QwenModelLane
    public var modelID: String
    public var speaker: String
    public var language: String
    public var useReferenceVoice: Bool
    public var referenceAudioSignature: String
    public var referenceTextHash: String
    public var cachePipelineVersion: String
    public var qwenDeEsserStrengthDecibels: Double
    public var referenceAudioPathForSynthesis: String?
    public var referenceTextForSynthesis: String?

    public init(
        lane: QwenModelLane,
        speaker: String,
        language: String,
        useReferenceVoice: Bool,
        referenceAudioSignature: String,
        referenceTextHash: String,
        cachePipelineVersion: String,
        qwenDeEsserStrengthDecibels: Double = SpeechSettings.defaultQwenDeEsserStrengthDecibels,
        referenceAudioPathForSynthesis: String? = nil,
        referenceTextForSynthesis: String? = nil
    ) {
        self.lane = lane
        self.modelID = lane.modelID(useReferenceVoice: useReferenceVoice)
        self.speaker = speaker
        self.language = language
        self.useReferenceVoice = useReferenceVoice
        self.referenceAudioSignature = referenceAudioSignature
        self.referenceTextHash = referenceTextHash
        self.cachePipelineVersion = cachePipelineVersion
        self.qwenDeEsserStrengthDecibels = qwenDeEsserStrengthDecibels
        self.referenceAudioPathForSynthesis = referenceAudioPathForSynthesis
        self.referenceTextForSynthesis = referenceTextForSynthesis
    }

    public var contextHash: String {
        QwenPromptAudioLibrary.hashMaterial([
            "pipeline=\(cachePipelineVersion)",
            "deEsserMaxReductionDB=\(String(format: "%.1f", qwenDeEsserStrengthDecibels))",
            "lane=\(lane.rawValue)",
            "model=\(modelID)",
            "speaker=\(useReferenceVoice ? "reference" : speaker)",
            "language=\(language)",
            "reference=\(useReferenceVoice)",
            "referenceAudio=\(referenceAudioSignature)",
            "referenceTextHash=\(referenceTextHash)",
        ])
    }

    private enum CodingKeys: String, CodingKey {
        case lane
        case modelID
        case speaker
        case language
        case useReferenceVoice
        case referenceAudioSignature
        case referenceTextHash
        case cachePipelineVersion
        case qwenDeEsserStrengthDecibels
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        lane = try container.decode(QwenModelLane.self, forKey: .lane)
        useReferenceVoice = try container.decode(Bool.self, forKey: .useReferenceVoice)
        modelID =
            try container.decodeIfPresent(String.self, forKey: .modelID)
            ?? lane.modelID(useReferenceVoice: useReferenceVoice)
        speaker = try container.decode(String.self, forKey: .speaker)
        language = try container.decode(String.self, forKey: .language)
        referenceAudioSignature = try container.decode(String.self, forKey: .referenceAudioSignature)
        referenceTextHash = try container.decode(String.self, forKey: .referenceTextHash)
        cachePipelineVersion = try container.decode(String.self, forKey: .cachePipelineVersion)
        qwenDeEsserStrengthDecibels =
            try container.decodeIfPresent(Double.self, forKey: .qwenDeEsserStrengthDecibels)
            ?? SpeechSettings.defaultQwenDeEsserStrengthDecibels
        referenceAudioPathForSynthesis = nil
        referenceTextForSynthesis = nil
    }

    public static func == (lhs: QwenPromptAudioLibraryContext, rhs: QwenPromptAudioLibraryContext) -> Bool {
        lhs.lane == rhs.lane
            && lhs.modelID == rhs.modelID
            && lhs.speaker == rhs.speaker
            && lhs.language == rhs.language
            && lhs.useReferenceVoice == rhs.useReferenceVoice
            && lhs.referenceAudioSignature == rhs.referenceAudioSignature
            && lhs.referenceTextHash == rhs.referenceTextHash
            && lhs.cachePipelineVersion == rhs.cachePipelineVersion
            && lhs.qwenDeEsserStrengthDecibels == rhs.qwenDeEsserStrengthDecibels
    }

    public func hash(into hasher: inout Hasher) {
        hasher.combine(lane)
        hasher.combine(modelID)
        hasher.combine(speaker)
        hasher.combine(language)
        hasher.combine(useReferenceVoice)
        hasher.combine(referenceAudioSignature)
        hasher.combine(referenceTextHash)
        hasher.combine(cachePipelineVersion)
        hasher.combine(qwenDeEsserStrengthDecibels)
    }
}

public struct QwenPromptAudioLibraryEntry: Codable, Equatable, Sendable {
    public var schemaVersion: Int
    public var canonicalText: String
    public var displayText: String
    public var contextHash: String
    public var audioFilename: String
    public var durationSeconds: Double
    public var audibleStartSeconds: Double
    public var audibleEndSeconds: Double
    public var createdAt: Date
    public var lastUsedAt: Date
    public var hitCount: Int
    public var source: QwenPromptAudioLibraryEntrySource
    public var kind: QwenPromptAudioLibraryEntryKind
}

public struct QwenPromptAudioLibraryMatch: Sendable {
    public var entry: QwenPromptAudioLibraryEntry
    public var audioURL: URL
}

private struct QwenPromptAudioLibraryManifest: Codable {
    var schemaVersion: Int
    var entries: [QwenPromptAudioLibraryEntry]

    static var empty: QwenPromptAudioLibraryManifest {
        QwenPromptAudioLibraryManifest(schemaVersion: QwenPromptAudioLibrary.schemaVersion, entries: [])
    }
}

public actor QwenPromptAudioLibrary {
    public static let schemaVersion = 1

    private let rootDirectory: URL
    private var fileManager: FileManager { .default }
    private var manifestCache: [String: QwenPromptAudioLibraryManifest] = [:]
    private var manifestLastPersistedAt: [String: Date] = [:]
    private let hitMetadataPersistenceInterval: TimeInterval = 30

    public init(rootDirectory: URL) {
        self.rootDirectory = rootDirectory
    }

    public static func canonicalText(for text: String) -> String {
        var normalized = TTSNormalizer.normalize(text)
            .folding(options: [.caseInsensitive, .diacriticInsensitive], locale: Locale(identifier: "en_US_POSIX"))
        normalized = normalized.replacingOccurrences(
            of: #"["'`“”‘’]"#,
            with: "",
            options: .regularExpression
        )
        normalized = normalized.replacingOccurrences(
            of: #"[^A-Za-z0-9]+"#,
            with: " ",
            options: .regularExpression
        )
        normalized = normalized.replacingOccurrences(
            of: #"\s+"#,
            with: " ",
            options: .regularExpression
        )
        return normalized.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
    }

    public static func hashText(_ text: String) -> String {
        hashData(Data(text.utf8))
    }

    static func hashMaterial(_ lines: [String]) -> String {
        hashText(lines.joined(separator: "\n"))
    }

    public func lookup(
        text: String,
        context: QwenPromptAudioLibraryContext,
        kind: QwenPromptAudioLibraryEntryKind
    ) throws -> QwenPromptAudioLibraryMatch? {
        let canonical = Self.canonicalText(for: text)
        guard !canonical.isEmpty else { return nil }
        var manifest = try readManifest(contextHash: context.contextHash)
        guard
            let index = manifest.entries.firstIndex(where: {
                $0.canonicalText == canonical && $0.contextHash == context.contextHash && $0.kind == kind
            })
        else {
            return nil
        }

        let audioURL = audioDirectory(contextHash: context.contextHash)
            .appendingPathComponent(manifest.entries[index].audioFilename)
        guard fileManager.fileExists(atPath: audioURL.path),
            let duration = QwenAudioPostProcessor.durationSeconds(of: audioURL),
            duration.isFinite,
            duration > 0,
            QwenAudioPostProcessor.hasAudibleSignal(at: audioURL)
        else {
            try? fileManager.removeItem(at: audioURL)
            manifest.entries.remove(at: index)
            try writeManifest(manifest, contextHash: context.contextHash)
            return nil
        }

        let now = Date()
        manifest.entries[index].lastUsedAt = now
        manifest.entries[index].hitCount += 1
        manifestCache[context.contextHash] = manifest
        if now.timeIntervalSince(manifestLastPersistedAt[context.contextHash] ?? .distantPast)
            >= hitMetadataPersistenceInterval
        {
            try writeManifest(manifest, contextHash: context.contextHash)
        }
        return QwenPromptAudioLibraryMatch(entry: manifest.entries[index], audioURL: audioURL)
    }

    @discardableResult
    public func storeAudio(
        from sourceURL: URL,
        text: String,
        context: QwenPromptAudioLibraryContext,
        source: QwenPromptAudioLibraryEntrySource,
        kind: QwenPromptAudioLibraryEntryKind
    ) throws -> QwenPromptAudioLibraryEntry {
        let canonical = Self.canonicalText(for: text)
        guard !canonical.isEmpty else {
            throw QwenRuntimeError.commandFailed("Cannot store an empty prompt audio library entry.")
        }
        try createContextDirectories(contextHash: context.contextHash)
        var manifest = try readManifest(contextHash: context.contextHash)
        if let existing = manifest.entries.first(where: {
            $0.canonicalText == canonical && $0.contextHash == context.contextHash && $0.kind == kind
        }) {
            let existingURL = audioDirectory(contextHash: context.contextHash)
                .appendingPathComponent(existing.audioFilename)
            if !fileManager.fileExists(atPath: existingURL.path) {
                try copyReplacingExisting(from: sourceURL, to: existingURL)
            }
            return existing
        }

        let audioFilename = "\(kind.rawValue)-\(Self.hashText(canonical)).wav"
        let destination = audioDirectory(contextHash: context.contextHash)
            .appendingPathComponent(audioFilename)
        try copyReplacingExisting(from: sourceURL, to: destination)
        let duration = QwenAudioPostProcessor.durationSeconds(of: destination) ?? 0
        let bounds = QwenAudioPostProcessor.audibleBoundsSeconds(of: destination)
        let now = Date()
        let entry = QwenPromptAudioLibraryEntry(
            schemaVersion: Self.schemaVersion,
            canonicalText: canonical,
            displayText: text.trimmedForSpeech,
            contextHash: context.contextHash,
            audioFilename: audioFilename,
            durationSeconds: duration,
            audibleStartSeconds: bounds?.start ?? 0,
            audibleEndSeconds: bounds?.end ?? duration,
            createdAt: now,
            lastUsedAt: now,
            hitCount: 0,
            source: source,
            kind: kind
        )
        manifest.entries.append(entry)
        manifest.entries.sort {
            if $0.kind.rawValue == $1.kind.rawValue {
                return $0.canonicalText < $1.canonicalText
            }
            return $0.kind.rawValue < $1.kind.rawValue
        }
        try writeManifest(manifest, contextHash: context.contextHash)
        return entry
    }

    public func contains(
        text: String,
        context: QwenPromptAudioLibraryContext,
        kind: QwenPromptAudioLibraryEntryKind
    ) throws -> Bool {
        let canonical = Self.canonicalText(for: text)
        guard !canonical.isEmpty else { return false }
        let manifest = try readManifest(contextHash: context.contextHash)
        guard
            let entry = manifest.entries.first(where: {
                $0.canonicalText == canonical && $0.contextHash == context.contextHash && $0.kind == kind
            })
        else {
            return false
        }
        let audioURL = audioDirectory(contextHash: context.contextHash)
            .appendingPathComponent(entry.audioFilename)
        return fileManager.fileExists(atPath: audioURL.path)
    }

    public func clear() throws {
        if fileManager.fileExists(atPath: rootDirectory.path) {
            try fileManager.removeItem(at: rootDirectory)
        }
        try fileManager.createDirectory(at: rootDirectory, withIntermediateDirectories: true)
        manifestCache.removeAll()
        manifestLastPersistedAt.removeAll()
    }

    public static func derivedPrefixTexts(for prompt: String) -> [String] {
        let trimmed = prompt.trimmedForSpeech
        guard !trimmed.isEmpty else { return [] }
        let lower = trimmed.lowercased()
        let prefixes = [
            "Which of the following is the most likely",
            "Which of the following is most likely",
            "Which of the following is the best next step",
            "Which of the following is the best",
            "Which of the following is most appropriate",
            "Which of the following findings",
        ]
        var derived: [String] = []
        for prefix in prefixes where lower.hasPrefix(prefix.lowercased()) {
            let prefixWordCount = prefix.split(separator: " ").count
            let promptWordCount = trimmed.split(separator: " ").count
            guard promptWordCount > prefixWordCount else { continue }
            derived.append(prefix)
        }
        return Array(Set(derived)).sorted { $0.count > $1.count }
    }

    private func contextDirectory(contextHash: String) -> URL {
        rootDirectory.appendingPathComponent(contextHash, isDirectory: true)
    }

    private func audioDirectory(contextHash: String) -> URL {
        contextDirectory(contextHash: contextHash).appendingPathComponent("audio", isDirectory: true)
    }

    private func manifestURL(contextHash: String) -> URL {
        contextDirectory(contextHash: contextHash).appendingPathComponent("manifest.json")
    }

    private func createContextDirectories(contextHash: String) throws {
        try fileManager.createDirectory(
            at: audioDirectory(contextHash: contextHash),
            withIntermediateDirectories: true
        )
    }

    private func readManifest(contextHash: String) throws -> QwenPromptAudioLibraryManifest {
        if let cached = manifestCache[contextHash] {
            return cached
        }
        let url = manifestURL(contextHash: contextHash)
        guard fileManager.fileExists(atPath: url.path) else {
            manifestCache[contextHash] = .empty
            manifestLastPersistedAt[contextHash] = Date()
            return .empty
        }
        let data = try Data(contentsOf: url)
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let manifest = try decoder.decode(QwenPromptAudioLibraryManifest.self, from: data)
        manifestCache[contextHash] = manifest
        manifestLastPersistedAt[contextHash] = Date()
        return manifest
    }

    private func writeManifest(
        _ manifest: QwenPromptAudioLibraryManifest,
        contextHash: String
    ) throws {
        try createContextDirectories(contextHash: contextHash)
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        let data = try encoder.encode(manifest)
        try data.write(to: manifestURL(contextHash: contextHash), options: .atomic)
        manifestCache[contextHash] = manifest
        manifestLastPersistedAt[contextHash] = Date()
    }

    private func copyReplacingExisting(from source: URL, to destination: URL) throws {
        try fileManager.createDirectory(at: destination.deletingLastPathComponent(), withIntermediateDirectories: true)
        let temporaryURL = destination.deletingLastPathComponent()
            .appendingPathComponent(".\(destination.lastPathComponent).\(UUID().uuidString).copying")
        defer { try? fileManager.removeItem(at: temporaryURL) }
        try fileManager.copyItem(at: source, to: temporaryURL)
        guard let duration = QwenAudioPostProcessor.durationSeconds(of: temporaryURL),
            duration.isFinite,
            duration > 0,
            QwenAudioPostProcessor.hasAudibleSignal(at: temporaryURL)
        else {
            throw QwenRuntimeError.commandFailed("Prompt audio was invalid.")
        }
        if fileManager.fileExists(atPath: destination.path) {
            _ = try fileManager.replaceItemAt(destination, withItemAt: temporaryURL)
        } else {
            try fileManager.moveItem(at: temporaryURL, to: destination)
        }
    }

    private static func hashData(_ data: Data) -> String {
        let digest = SHA256.hash(data: data)
        return digest.map { String(format: "%02x", $0) }.joined()
    }
}
