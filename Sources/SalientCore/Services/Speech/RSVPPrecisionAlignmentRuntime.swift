import CryptoKit
import Foundation
import MLXAudioCore
import MLXAudioSTT

public enum RSVPPrecisionAlignmentState: String, Codable, Equatable, Sendable {
    case notInstalled
    case installing
    case installed
    case loading
    case ready
    case failed
}

public struct RSVPPrecisionAlignmentProgress: Equatable, Sendable {
    public var stage: String
    public var fractionCompleted: Double

    public init(stage: String, fractionCompleted: Double) {
        self.stage = stage
        self.fractionCompleted = min(1, max(0, fractionCompleted))
    }
}

public protocol RSVPWordAligning: Sendable {
    func align(
        item: SpeechPlaybackItem,
        itemIndex: Int?,
        audioURL: URL
    ) async -> SpeechPlaybackWordCueTrack?
}

public actor RSVPPrecisionAlignmentRuntime: RSVPWordAligning {
    public static let modelID = "mlx-community/Qwen3-ForcedAligner-0.6B-4bit"
    public static let idleTimeoutSeconds: TimeInterval = 15 * 60

    private let fileManager: FileManager
    private let httpClient: any HTTPTransferClient
    private let runtimeRoot: URL
    private let modelDirectory: URL
    private let sidecarDirectory: URL
    private var model: Qwen3ForcedAlignerModel?
    private var state: RSVPPrecisionAlignmentState
    private var lastError: String?
    private var idleUnloadTask: Task<Void, Never>?

    public init(
        runtimeRoot: URL? = nil,
        fileManager: FileManager = .default,
        httpClient: any HTTPTransferClient = URLSessionHTTPTransferClient()
    ) {
        let root = runtimeRoot ?? Self.defaultRuntimeRoot(fileManager: fileManager)
        self.fileManager = fileManager
        self.httpClient = httpClient
        self.runtimeRoot = root
        self.modelDirectory = root.appendingPathComponent("model", isDirectory: true)
        self.sidecarDirectory = root.appendingPathComponent("cue-sidecars", isDirectory: true)
        self.state =
            Self.hasInstalledModel(in: root.appendingPathComponent("model"), fileManager: fileManager)
            ? .installed
            : .notInstalled
    }

    public func currentState() -> RSVPPrecisionAlignmentState {
        state
    }

    public func currentError() -> String? {
        lastError
    }

    public func install(
        progress: (@Sendable (RSVPPrecisionAlignmentProgress) async -> Void)? = nil
    ) async throws {
        state = .installing
        lastError = nil
        do {
            try fileManager.createDirectory(at: modelDirectory, withIntermediateDirectories: true)
            try fileManager.createDirectory(at: sidecarDirectory, withIntermediateDirectories: true)
            await progress?(.init(stage: "Discovering precision-sync model files", fractionCompleted: 0.03))
            let files = try await discoverModelFiles()
            guard !files.isEmpty else {
                throw RSVPPrecisionAlignmentError.installation("No downloadable model files were found.")
            }
            let totalBytes = files.compactMap(\.size).reduce(0, +)
            var completedBytes: Int64 = 0
            for file in files {
                try Task.checkCancellation()
                guard let expectedBytes = file.size, expectedBytes >= 0 else {
                    throw RSVPPrecisionAlignmentError.installation("The model host did not report a file size.")
                }
                await progress?(
                    .init(
                        stage: "Downloading precision-sync model",
                        fractionCompleted: totalBytes > 0
                            ? 0.05 + 0.82 * Double(completedBytes) / Double(totalBytes)
                            : 0.10
                    ))
                try await download(
                    remoteURL: try resolveURL(path: file.path),
                    destination: modelDirectory.appendingPathComponent(file.path),
                    expectedBytes: expectedBytes
                )
                completedBytes += expectedBytes
            }
            try writeManifest(files: files)
            state = .loading
            await progress?(.init(stage: "Loading precision-sync model", fractionCompleted: 0.90))
            model = try await Qwen3ForcedAlignerModel.fromModelDirectory(modelDirectory)
            state = .ready
            scheduleIdleUnload()
            await progress?(.init(stage: "Precision sync ready", fractionCompleted: 1))
        } catch is CancellationError {
            state = Self.hasInstalledModel(in: modelDirectory, fileManager: fileManager) ? .installed : .notInstalled
            throw CancellationError()
        } catch {
            state = .failed
            lastError = error.localizedDescription
            throw error
        }
    }

    public func align(
        item: SpeechPlaybackItem,
        itemIndex: Int?,
        audioURL: URL
    ) async -> SpeechPlaybackWordCueTrack? {
        guard state != .notInstalled, state != .installing else { return nil }
        let cacheKey = Self.cacheKey(item: item, audioURL: audioURL, fileManager: fileManager)
        if let cached = loadCachedTrack(cacheKey: cacheKey, item: item, itemIndex: itemIndex) {
            scheduleIdleUnload()
            return cached
        }
        do {
            let startedAt = Date()
            // Snapshot transient playback audio before model loading. Playback owns the file and
            // may remove it when the queued item completes; alignment owns only this numeric PCM.
            let (_, audio) = try loadAudioArray(from: audioURL, sampleRate: 16_000)
            let aligner = try await loadIfInstalled()
            let result = aligner.generate(audio: audio, text: item.text, language: "English")
            let words = result.items.map { aligned in
                RSVPAlignedWord(
                    text: aligned.text,
                    startSeconds: aligned.startTime,
                    endSeconds: aligned.endTime
                )
            }
            guard
                let track = RSVPReadAlongCueTrackBuilder().forcedAlignedTrack(
                    item: item,
                    itemIndex: itemIndex,
                    alignedWords: words,
                    alignmentRuntimeSeconds: Date().timeIntervalSince(startedAt)
                )
            else {
                return nil
            }
            saveCachedTrack(track, cacheKey: cacheKey)
            scheduleIdleUnload()
            return track
        } catch {
            lastError = error.localizedDescription
            state = Self.hasInstalledModel(in: modelDirectory, fileManager: fileManager) ? .installed : .failed
            return nil
        }
    }

    public func unload() {
        idleUnloadTask?.cancel()
        idleUnloadTask = nil
        model = nil
        state = Self.hasInstalledModel(in: modelDirectory, fileManager: fileManager) ? .installed : .notInstalled
    }

    private func loadIfInstalled() async throws -> Qwen3ForcedAlignerModel {
        if let model {
            state = .ready
            return model
        }
        guard Self.hasInstalledModel(in: modelDirectory, fileManager: fileManager) else {
            state = .notInstalled
            throw RSVPPrecisionAlignmentError.notInstalled
        }
        state = .loading
        let loaded = try await Qwen3ForcedAlignerModel.fromModelDirectory(modelDirectory)
        model = loaded
        state = .ready
        return loaded
    }

    private func scheduleIdleUnload() {
        idleUnloadTask?.cancel()
        idleUnloadTask = Task { [weak self] in
            try? await Task.sleep(for: .seconds(Self.idleTimeoutSeconds))
            guard !Task.isCancelled else { return }
            await self?.unload()
        }
    }

    private func discoverModelFiles() async throws -> [RSVPHuggingFaceTreeEntry] {
        let encodedModelID =
            Self.modelID.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed)
            ?? Self.modelID
        guard let url = URL(string: "https://huggingface.co/api/models/\(encodedModelID)/tree/main?recursive=1") else {
            throw RSVPPrecisionAlignmentError.installation("Could not build the model discovery URL.")
        }
        let (data, response) = try await httpClient.data(for: URLRequest(url: url))
        guard (200..<300).contains(response.statusCode) else {
            throw RSVPPrecisionAlignmentError.installation("Model discovery failed with HTTP \(response.statusCode).")
        }
        return try JSONDecoder().decode([RSVPHuggingFaceTreeEntry].self, from: data)
            .filter { $0.type == "file" }
            .filter { !$0.path.hasPrefix(".") }
            .filter { !$0.path.lowercased().hasSuffix(".md") }
            .filter { !$0.path.lowercased().contains("license") }
            .sorted { $0.path < $1.path }
    }

    private func resolveURL(path: String) throws -> URL {
        let model = Self.modelID.split(separator: "/").map(String.init).joined(separator: "/")
        let encodedPath = path.split(separator: "/").map { component in
            String(component).addingPercentEncoding(withAllowedCharacters: .urlPathAllowed)
                ?? String(component)
        }.joined(separator: "/")
        guard let url = URL(string: "https://huggingface.co/\(model)/resolve/main/\(encodedPath)") else {
            throw RSVPPrecisionAlignmentError.installation("Could not build a model download URL.")
        }
        return url
    }

    private func download(remoteURL: URL, destination: URL, expectedBytes: Int64) async throws {
        try fileManager.createDirectory(at: destination.deletingLastPathComponent(), withIntermediateDirectories: true)
        let partial = destination.appendingPathExtension("partial")
        if Self.fileSize(destination, fileManager: fileManager) == expectedBytes {
            try? fileManager.removeItem(at: partial)
            return
        }
        var partialBytes = Self.fileSize(partial, fileManager: fileManager) ?? 0
        if partialBytes > expectedBytes {
            try fileManager.removeItem(at: partial)
            partialBytes = 0
        }
        var request = URLRequest(url: remoteURL)
        if partialBytes > 0 {
            request.setValue("bytes=\(partialBytes)-", forHTTPHeaderField: "Range")
        }
        let (temporaryURL, response) = try await httpClient.download(for: request)
        guard (200..<300).contains(response.statusCode) else {
            throw RSVPPrecisionAlignmentError.installation("Model download failed with HTTP \(response.statusCode).")
        }
        if partialBytes > 0, response.statusCode == 206 {
            try await Self.append(contentsOf: temporaryURL, to: partial)
        } else {
            try? fileManager.removeItem(at: partial)
            try fileManager.moveItem(at: temporaryURL, to: partial)
        }
        guard Self.fileSize(partial, fileManager: fileManager) == expectedBytes else {
            throw RSVPPrecisionAlignmentError.installation("A downloaded model file failed byte-count validation.")
        }
        if fileManager.fileExists(atPath: destination.path) {
            _ = try fileManager.replaceItemAt(destination, withItemAt: partial)
        } else {
            try fileManager.moveItem(at: partial, to: destination)
        }
    }

    private static func append(contentsOf source: URL, to destination: URL) async throws {
        try await Task.detached(priority: .utility) {
            let input = try FileHandle(forReadingFrom: source)
            defer { try? input.close() }
            let output = try FileHandle(forWritingTo: destination)
            defer { try? output.close() }
            try output.seekToEnd()
            while let data = try input.read(upToCount: 1_048_576), !data.isEmpty {
                try Task.checkCancellation()
                try output.write(contentsOf: data)
            }
            try output.synchronize()
        }.value
    }

    private func writeManifest(files: [RSVPHuggingFaceTreeEntry]) throws {
        let manifest = RSVPPrecisionAlignmentManifest(
            modelID: Self.modelID,
            files: files.compactMap { entry in
                entry.size.map { .init(path: entry.path, byteCount: $0) }
            }
        )
        let data = try JSONEncoder().encode(manifest)
        try data.write(to: modelDirectory.appendingPathComponent(".salient-model-manifest.json"), options: .atomic)
    }

    private func loadCachedTrack(
        cacheKey: String,
        item: SpeechPlaybackItem,
        itemIndex: Int?
    ) -> SpeechPlaybackWordCueTrack? {
        let url = sidecarDirectory.appendingPathComponent(cacheKey).appendingPathExtension("json")
        guard let data = try? Data(contentsOf: url),
            let cached = try? JSONDecoder().decode(RSVPPrecisionCueSidecar.self, from: data),
            cached.schemaVersion == 1,
            cached.modelID == Self.modelID
        else {
            return nil
        }
        return SpeechPlaybackWordCueTrack(
            itemID: item.id,
            segmentID: item.segmentID,
            itemIndex: itemIndex,
            source: .forcedAligned,
            cues: cached.cues,
            alignmentRuntimeSeconds: 0,
            tokenCoverage: cached.tokenCoverage
        )
    }

    private func saveCachedTrack(_ track: SpeechPlaybackWordCueTrack, cacheKey: String) {
        try? fileManager.createDirectory(at: sidecarDirectory, withIntermediateDirectories: true)
        let sidecar = RSVPPrecisionCueSidecar(
            schemaVersion: 1,
            modelID: Self.modelID,
            cues: track.cues,
            tokenCoverage: track.tokenCoverage
        )
        guard let data = try? JSONEncoder().encode(sidecar) else { return }
        try? data.write(
            to: sidecarDirectory.appendingPathComponent(cacheKey).appendingPathExtension("json"),
            options: .atomic
        )
    }

    private static func cacheKey(
        item: SpeechPlaybackItem,
        audioURL: URL,
        fileManager: FileManager
    ) -> String {
        let attributes = try? fileManager.attributesOfItem(atPath: audioURL.path)
        let size = (attributes?[.size] as? NSNumber)?.int64Value ?? 0
        let modified = (attributes?[.modificationDate] as? Date)?.timeIntervalSince1970 ?? 0
        let material = "1|\(modelID)|\(item.text)|\(size)|\(modified)"
        return SHA256.hash(data: Data(material.utf8))
            .map { String(format: "%02x", $0) }
            .joined()
    }

    private static func defaultRuntimeRoot(fileManager: FileManager) -> URL {
        let applicationSupport =
            fileManager.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? URL(fileURLWithPath: NSHomeDirectory()).appendingPathComponent("Library/Application Support")
        return
            applicationSupport
            .appendingPathComponent("Salient", isDirectory: true)
            .appendingPathComponent("Models", isDirectory: true)
            .appendingPathComponent("RSVPPrecisionAlignment", isDirectory: true)
    }

    private static func hasInstalledModel(in directory: URL, fileManager: FileManager) -> Bool {
        fileManager.fileExists(atPath: directory.appendingPathComponent("config.json").path)
            && ((try? fileManager.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil)) ?? [])
                .contains { $0.pathExtension == "safetensors" }
    }

    private static func fileSize(_ url: URL, fileManager: FileManager) -> Int64? {
        guard fileManager.fileExists(atPath: url.path),
            let attributes = try? fileManager.attributesOfItem(atPath: url.path)
        else {
            return nil
        }
        return (attributes[.size] as? NSNumber)?.int64Value
    }
}

public enum RSVPPrecisionAlignmentError: LocalizedError {
    case notInstalled
    case installation(String)

    public var errorDescription: String? {
        switch self {
        case .notInstalled:
            "The optional RSVP precision-sync model is not installed."
        case .installation(let message):
            message
        }
    }
}

private struct RSVPHuggingFaceTreeEntry: Decodable {
    var path: String
    var type: String
    var size: Int64?
}

private struct RSVPPrecisionAlignmentManifest: Codable {
    struct File: Codable {
        var path: String
        var byteCount: Int64
    }

    var modelID: String
    var files: [File]
}

private struct RSVPPrecisionCueSidecar: Codable {
    var schemaVersion: Int
    var modelID: String
    var cues: [SpeechPlaybackWordCue]
    var tokenCoverage: Double
}
