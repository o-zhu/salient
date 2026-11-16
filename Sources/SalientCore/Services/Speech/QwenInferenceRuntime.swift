import AVFoundation
import CryptoKit
import Foundation
import MLXAudioCore
import MLXAudioTTS

struct QwenNativeInferenceRequest: Sendable {
    var id: String
    var itemIndex: Int
    var text: String
    var modelDirectory: URL
    var speaker: String
    var language: String
    var useReferenceVoice: Bool
    var referenceAudioURL: URL?
    var referenceAudioSignature: String
    var referenceText: String?
    var metalLibraryURL: URL?
}

struct QwenInferencePreparation: Equatable, Sendable {
    var residencyState: QwenRuntimeResidencyState
    var modelLoadSeconds: Double
    var warmupSeconds: Double
}

actor QwenNativeEmissionTracker {
    private var emittedAudio = false

    func markAudioEmitted() {
        emittedAudio = true
    }

    func hasEmittedAudio() -> Bool {
        emittedAudio
    }
}

protocol QwenInferenceRuntime: Sendable {
    func isResident() async -> Bool
    func prepare(_ request: QwenNativeInferenceRequest) async throws -> QwenInferencePreparation
    func stream(
        _ request: QwenNativeInferenceRequest,
        onChunk: @Sendable @escaping (QwenStreamingAudioChunk) async throws -> Void
    ) async throws
    func synthesizeFile(_ request: QwenNativeInferenceRequest, outputURL: URL) async throws
    func unload() async
}

actor NativeMLXQwenRuntime: QwenInferenceRuntime {
    static let streamingIntervalSeconds = 0.32

    private var model: Qwen3TTSModel?
    private var modelDirectory: URL?
    private var preparedReferenceKey: String?
    private var preparedReference: Qwen3TTSModel.Qwen3TTSReferenceConditioning?
    private var generationOwner: UUID?
    private var generationWaiterOrder: [UUID] = []
    private var generationWaiters: [UUID: CheckedContinuation<UUID, Error>] = [:]
    private var lastPreparation = QwenInferencePreparation(
        residencyState: .cold,
        modelLoadSeconds: 0,
        warmupSeconds: 0
    )

    func isResident() async -> Bool {
        model != nil
    }

    func prepare(_ request: QwenNativeInferenceRequest) async throws -> QwenInferencePreparation {
        try Self.prepareMetalLibraryIfNeeded(sourceURL: request.metalLibraryURL)
        let canonicalDirectory = request.modelDirectory.standardizedFileURL.resolvingSymlinksInPath()
        let isWarm = model != nil && modelDirectory == canonicalDirectory
        var modelLoadSeconds = 0.0
        if !isWarm {
            model = nil
            preparedReference = nil
            preparedReferenceKey = nil
            let startedAt = ContinuousClock.now
            model = try await Qwen3TTSModel.fromModelDirectory(canonicalDirectory)
            modelDirectory = canonicalDirectory
            modelLoadSeconds = Self.seconds(since: startedAt)
        }

        guard let model else {
            throw QwenRuntimeError.commandFailed("Native Qwen model did not load.")
        }

        var warmupSeconds = 0.0
        if request.useReferenceVoice {
            guard let audioURL = request.referenceAudioURL,
                let referenceText = request.referenceText?.trimmingCharacters(in: .whitespacesAndNewlines),
                !referenceText.isEmpty
            else {
                throw QwenRuntimeError.setupRequired("The selected Qwen reference voice is incomplete.")
            }
            let key = Self.referenceKey(
                modelDirectory: canonicalDirectory,
                audioURL: audioURL,
                audioSignature: request.referenceAudioSignature,
                text: referenceText,
                language: request.language
            )
            if preparedReferenceKey != key || preparedReference == nil {
                let startedAt = ContinuousClock.now
                let (_, referenceAudio) = try loadAudioArray(from: audioURL, sampleRate: model.sampleRate)
                preparedReference = try model.prepareReferenceConditioning(
                    refAudio: referenceAudio,
                    refText: referenceText,
                    language: request.language
                )
                preparedReferenceKey = key
                warmupSeconds = Self.seconds(since: startedAt)
            }
        } else {
            preparedReference = nil
            preparedReferenceKey = nil
        }

        let preparation = QwenInferencePreparation(
            residencyState: isWarm ? .warm : .cold,
            modelLoadSeconds: modelLoadSeconds,
            warmupSeconds: warmupSeconds
        )
        lastPreparation = preparation
        return preparation
    }

    func stream(
        _ request: QwenNativeInferenceRequest,
        onChunk: @Sendable @escaping (QwenStreamingAudioChunk) async throws -> Void
    ) async throws {
        let generationLease = try await acquireGenerationSlot()
        defer { releaseGenerationSlot(generationLease) }
        try Task.checkCancellation()
        let preparation = try await prepare(request)
        guard let model else {
            throw QwenRuntimeError.commandFailed("Native Qwen model is unavailable.")
        }

        var parameters = model.defaultGenerationParameters
        parameters.maxTokens = 1_200
        parameters.temperature = 0.5
        parameters.topP = 0.9
        // Keep every reference path aligned with the proven complete-file
        // helper settings. A higher penalty can turn isolated words metallic.
        parameters.repetitionPenalty = 1.1

        let startedAt = ContinuousClock.now
        var sequenceIndex = 0
        var generatedDuration = 0.0
        var hasAudibleSample = false
        var peakMemoryBytes: Int64?
        let stream: AsyncThrowingStream<AudioGeneration, Error>
        if request.useReferenceVoice, let preparedReference {
            stream = model.generateStream(
                text: request.text,
                conditioning: preparedReference,
                generationParameters: parameters,
                streamingInterval: Self.streamingIntervalSeconds
            )
        } else {
            stream = model.generateStream(
                text: request.text,
                voice: request.speaker,
                refAudio: nil,
                refText: nil,
                language: request.language,
                generationParameters: parameters,
                streamingInterval: Self.streamingIntervalSeconds
            )
        }

        for try await event in stream {
            try Task.checkCancellation()
            switch event {
            case .token:
                continue
            case .info(let info):
                peakMemoryBytes = Int64(max(0, info.peakMemoryUsage) * 1_073_741_824)
            case .audio(let array):
                let samples = array.asArray(Float.self)
                guard !samples.isEmpty else { continue }
                if !hasAudibleSample {
                    hasAudibleSample = samples.contains { abs($0) >= 0.0005 }
                }
                let duration = Double(samples.count) / Double(model.sampleRate)
                generatedDuration += duration
                let data = samples.withUnsafeBufferPointer { Data(buffer: $0) }
                try await onChunk(
                    QwenStreamingAudioChunk(
                        requestID: request.id,
                        itemIndex: request.itemIndex,
                        sequenceIndex: sequenceIndex,
                        sampleRate: Double(model.sampleRate),
                        audioData: data,
                        durationSeconds: duration,
                        isFinal: false,
                        elapsedSeconds: Self.seconds(since: startedAt),
                        peakMemoryBytes: peakMemoryBytes,
                        backend: .nativeMLX,
                        residencyState: preparation.residencyState,
                        modelLoadSeconds: preparation.modelLoadSeconds,
                        warmupSeconds: preparation.warmupSeconds,
                        device: "gpu"
                    ))
                sequenceIndex += 1
            }
        }

        guard generatedDuration > 0, hasAudibleSample else {
            throw QwenRuntimeError.commandFailed("Native Qwen synthesis produced no audible audio.")
        }
        let elapsed = Self.seconds(since: startedAt)
        let realTimeFactor = generatedDuration > 0 ? elapsed / generatedDuration : nil
        try await onChunk(
            QwenStreamingAudioChunk(
                requestID: request.id,
                itemIndex: request.itemIndex,
                sequenceIndex: sequenceIndex,
                sampleRate: Double(model.sampleRate),
                audioData: Data(),
                durationSeconds: 0,
                isFinal: true,
                elapsedSeconds: elapsed,
                peakMemoryBytes: peakMemoryBytes,
                backend: .nativeMLX,
                residencyState: preparation.residencyState,
                modelLoadSeconds: preparation.modelLoadSeconds,
                warmupSeconds: preparation.warmupSeconds,
                realTimeFactor: realTimeFactor,
                device: "gpu"
            ))
    }

    func synthesizeFile(_ request: QwenNativeInferenceRequest, outputURL: URL) async throws {
        let temporaryURL = outputURL.deletingLastPathComponent()
            .appendingPathComponent(".\(outputURL.lastPathComponent).\(UUID().uuidString).tmp.wav")
        try FileManager.default.createDirectory(
            at: outputURL.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        let writer = QwenPCMFileWriter(outputURL: temporaryURL)
        do {
            try await stream(request) { chunk in
                try await writer.append(chunk)
            }
            guard await writer.frameCount > 0 else {
                throw QwenRuntimeError.commandFailed("Native Qwen synthesis produced no audio.")
            }
            await writer.finish()
            if FileManager.default.fileExists(atPath: outputURL.path) {
                try FileManager.default.removeItem(at: outputURL)
            }
            try FileManager.default.moveItem(at: temporaryURL, to: outputURL)
        } catch {
            await writer.finish()
            try? FileManager.default.removeItem(at: temporaryURL)
            throw error
        }
    }

    func unload() async {
        let generationLease = await acquireGenerationSlotForTeardown()
        defer { releaseGenerationSlot(generationLease) }
        model = nil
        modelDirectory = nil
        preparedReference = nil
        preparedReferenceKey = nil
        lastPreparation = QwenInferencePreparation(
            residencyState: .cold,
            modelLoadSeconds: 0,
            warmupSeconds: 0
        )
    }

    private func acquireGenerationSlot() async throws -> UUID {
        try Task.checkCancellation()
        let leaseID = UUID()
        if generationOwner == nil {
            generationOwner = leaseID
            return leaseID
        }

        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                if Task.isCancelled {
                    continuation.resume(throwing: CancellationError())
                } else {
                    generationWaiterOrder.append(leaseID)
                    generationWaiters[leaseID] = continuation
                }
            }
        } onCancel: {
            Task {
                await self.cancelGenerationWaiter(leaseID)
            }
        }
    }

    private func acquireGenerationSlotForTeardown() async -> UUID {
        let leaseID = UUID()
        if generationOwner == nil {
            generationOwner = leaseID
            return leaseID
        }
        return try! await withCheckedThrowingContinuation { continuation in
            generationWaiterOrder.append(leaseID)
            generationWaiters[leaseID] = continuation
        }
    }

    private func releaseGenerationSlot(_ leaseID: UUID) {
        guard generationOwner == leaseID else { return }
        while let nextLeaseID = generationWaiterOrder.first {
            generationWaiterOrder.removeFirst()
            guard let continuation = generationWaiters.removeValue(forKey: nextLeaseID) else {
                continue
            }
            generationOwner = nextLeaseID
            continuation.resume(returning: nextLeaseID)
            return
        }
        generationOwner = nil
    }

    private func cancelGenerationWaiter(_ leaseID: UUID) {
        guard let continuation = generationWaiters.removeValue(forKey: leaseID) else { return }
        generationWaiterOrder.removeAll { $0 == leaseID }
        continuation.resume(throwing: CancellationError())
    }

    private static func referenceKey(
        modelDirectory: URL,
        audioURL: URL,
        audioSignature: String,
        text: String,
        language: String
    ) -> String {
        let resolvedAudioSignature: String
        if !audioSignature.isEmpty {
            resolvedAudioSignature = audioSignature
        } else if let data = try? Data(contentsOf: audioURL) {
            resolvedAudioSignature = SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
        } else {
            resolvedAudioSignature = audioURL.standardizedFileURL.path
        }
        let textDigest = SHA256.hash(data: Data(text.utf8)).map { String(format: "%02x", $0) }.joined()
        return [
            modelDirectory.path,
            resolvedAudioSignature,
            language,
            textDigest,
        ].joined(separator: "|")
    }

    private static func prepareMetalLibraryIfNeeded(sourceURL: URL?) throws {
        guard let executableURL = Bundle.main.executableURL else {
            throw QwenRuntimeError.commandFailed(
                "Native Qwen could not locate the current executable; the Python fallback remains available."
            )
        }
        let executableDirectory = executableURL.deletingLastPathComponent()
        let bundledCandidates = [
            executableDirectory.appendingPathComponent("mlx.metallib"),
            executableDirectory.appendingPathComponent("default.metallib"),
            executableDirectory.appendingPathComponent("Resources/mlx.metallib"),
            executableDirectory.appendingPathComponent("Resources/default.metallib"),
        ]
        if bundledCandidates.contains(where: { FileManager.default.fileExists(atPath: $0.path) }) {
            return
        }
        guard let sourceURL, FileManager.default.fileExists(atPath: sourceURL.path) else {
            throw QwenRuntimeError.commandFailed(
                "Native Qwen could not find its local Metal library; the Python fallback remains available."
            )
        }
        let destinationURL = executableDirectory.appendingPathComponent("mlx.metallib")
        if executableURL.path.contains(".app/Contents/MacOS/") {
            throw QwenRuntimeError.commandFailed(
                "Native Qwen is not packaged with its local Metal library; the Python fallback remains available."
            )
        }
        do {
            if (try? FileManager.default.destinationOfSymbolicLink(atPath: destinationURL.path)) != nil {
                try FileManager.default.removeItem(at: destinationURL)
            }
            try FileManager.default.createSymbolicLink(at: destinationURL, withDestinationURL: sourceURL)
        } catch {
            throw QwenRuntimeError.commandFailed("Native Qwen could not prepare its local Metal library.")
        }
    }

    private static func seconds(since instant: ContinuousClock.Instant) -> Double {
        let duration = instant.duration(to: .now)
        return Double(duration.components.seconds)
            + Double(duration.components.attoseconds) / 1_000_000_000_000_000_000
    }
}

actor QwenPCMFileWriter {
    private let outputURL: URL
    private var file: AVAudioFile?
    private(set) var frameCount = 0
    private var sampleRate: Double?

    init(outputURL: URL) {
        self.outputURL = outputURL
    }

    func append(_ chunk: QwenStreamingAudioChunk) throws {
        guard !chunk.audioData.isEmpty else { return }
        guard chunk.sampleRate.isFinite, chunk.sampleRate > 0 else {
            throw QwenRuntimeError.commandFailed("Qwen output used an invalid sample rate.")
        }
        if let sampleRate, sampleRate != chunk.sampleRate {
            throw QwenRuntimeError.commandFailed("Qwen output changed sample rate during synthesis.")
        }
        let stride = MemoryLayout<Float>.stride
        guard chunk.audioData.count.isMultiple(of: stride) else {
            throw QwenRuntimeError.commandFailed("Qwen output contained malformed PCM data.")
        }
        let frames = chunk.audioData.count / stride
        guard frames > 0,
            let format = AVAudioFormat(
                commonFormat: .pcmFormatFloat32,
                sampleRate: chunk.sampleRate,
                channels: 1,
                interleaved: false
            ),
            let buffer = AVAudioPCMBuffer(
                pcmFormat: format,
                frameCapacity: AVAudioFrameCount(frames)
            ),
            let destination = buffer.floatChannelData?[0]
        else {
            throw QwenRuntimeError.commandFailed("Qwen output could not allocate a PCM buffer.")
        }
        buffer.frameLength = AVAudioFrameCount(frames)
        try chunk.audioData.withUnsafeBytes { rawBuffer in
            let source = rawBuffer.bindMemory(to: Float.self)
            guard let sourceAddress = source.baseAddress else {
                throw QwenRuntimeError.commandFailed("Qwen output PCM data was empty.")
            }
            destination.update(from: sourceAddress, count: frames)
        }
        if file == nil {
            file = try AVAudioFile(
                forWriting: outputURL,
                settings: format.settings,
                commonFormat: .pcmFormatFloat32,
                interleaved: false
            )
            sampleRate = chunk.sampleRate
        }
        try file?.write(from: buffer)
        frameCount += frames
    }

    func finish() {
        file = nil
    }
}
