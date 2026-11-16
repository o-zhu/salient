import AVFoundation
import CryptoKit
import Foundation

public actor QwenRuntimeManager {
    public static let cachePipelineVersion = "qwen-reference-quality-v11-steep-de-esser-mlx-audio-swift-0.1.3"
    public static let cacheRetentionInterval: TimeInterval = 5 * 24 * 60 * 60
    static let lowDiskCacheClearThresholdBytes: Int64 = 2 * 1024 * 1024 * 1024
    static let minimumFreeDiskSpaceBytes: Int64 = 512 * 1024 * 1024
    static let cacheMaintenanceCheckInterval: Duration = .seconds(60)
    private static let residentHelperBatchLimit = 4

    private let fileManager: FileManager
    private let runner: any QwenCommandRunning
    private let runtimeRoot: URL
    private let availableCapacityProvider: @Sendable (URL) throws -> Int64?
    private let promptAudioLibrary: QwenPromptAudioLibrary
    private let nativeInferenceRuntime: any QwenInferenceRuntime
    private let nativeStreamingEnabledOverride: Bool?
    private var installingLane: QwenModelLane?
    private var installingReferenceVoice = false
    private var lastError: String?
    private var residentHelpers: [String: QwenResidentHelperSession] = [:]
    private var runtimeDirectoriesReady = false
    private var helperSynchronized = false
    private var lastCacheMaintenanceCheck: ContinuousClock.Instant?
    private var cachedNativeMetalLibraryURL: URL?
    private var referenceAudioSignatures: [String: QwenReferenceAudioSignatureCacheEntry] = [:]
    private var installedModelValidationCache: [String: QwenInstalledModelValidationCacheEntry] = [:]
    private var synthesisLeaseOwner: UUID?
    private var synthesisLeaseWaiterOrder: [UUID] = []
    private var synthesisLeaseWaiters: [UUID: CheckedContinuation<UUID, Error>] = [:]

    public init(
        runtimeRoot: URL? = nil,
        fileManager: FileManager = .default,
        runner: any QwenCommandRunning = ProcessQwenCommandRunner(),
        availableCapacityProvider: (@Sendable (URL) throws -> Int64?)? = nil,
        nativeStreamingEnabledOverride: Bool? = nil
    ) {
        self.fileManager = fileManager
        self.runner = runner
        self.availableCapacityProvider = availableCapacityProvider ?? { try Self.defaultAvailableCapacityProvider(for: $0) }
        let resolvedRuntimeRoot: URL
        if let runtimeRoot {
            resolvedRuntimeRoot = runtimeRoot
        } else {
            let appSupport =
                fileManager.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
                ?? URL(fileURLWithPath: NSHomeDirectory()).appendingPathComponent("Library/Application Support")
            resolvedRuntimeRoot =
                appSupport
                .appendingPathComponent("Salient", isDirectory: true)
                .appendingPathComponent("QwenTTS", isDirectory: true)
        }
        self.runtimeRoot = resolvedRuntimeRoot
        self.nativeInferenceRuntime = NativeMLXQwenRuntime()
        self.nativeStreamingEnabledOverride = nativeStreamingEnabledOverride
        self.promptAudioLibrary = QwenPromptAudioLibrary(
            rootDirectory: resolvedRuntimeRoot.appendingPathComponent("prompt-library", isDirectory: true)
        )
    }

    public nonisolated static func cacheKey(
        text: String,
        lane: QwenModelLane,
        speaker: String,
        language: String,
        rateMultiplier _: Double,
        qwenDeEsserStrengthDecibels: Double = SpeechSettings.defaultQwenDeEsserStrengthDecibels,
        useReferenceVoice: Bool = false,
        referenceAudioSignature: String = "",
        referenceText: String = ""
    ) -> String {
        let cacheSpeaker = useReferenceVoice ? "reference" : speaker
        let material = [
            "pipeline=\(cachePipelineVersion)",
            "model=\(lane.modelID(useReferenceVoice: useReferenceVoice))",
            "speaker=\(cacheSpeaker)",
            "language=\(language)",
            "deEsserMaxReductionDB=\(String(format: "%.1f", min(max(qwenDeEsserStrengthDecibels, 0), SpeechSettings.maximumQwenDeEsserStrengthDecibels)))",
            "referenceAudio=\(referenceAudioSignature)",
            "referenceText=\(referenceText)",
            "text=\(text)",
        ].joined(separator: "\n")
        let digest = SHA256.hash(data: Data(material.utf8))
        return digest.map { String(format: "%02x", $0) }.joined()
    }

    private nonisolated static func legacyRateCacheKey(
        text: String,
        lane: QwenModelLane,
        speaker: String,
        language: String,
        rateMultiplier: Double,
        qwenDeEsserStrengthDecibels: Double,
        useReferenceVoice: Bool,
        referenceAudioSignature: String,
        referenceText: String
    ) -> String {
        let cacheSpeaker = useReferenceVoice ? "reference" : speaker
        let material = [
            "pipeline=\(cachePipelineVersion)",
            "model=\(lane.modelID(useReferenceVoice: useReferenceVoice))",
            "speaker=\(cacheSpeaker)",
            "language=\(language)",
            "rate=\(String(format: "%.2f", rateMultiplier))",
            "deEsserMaxReductionDB=\(String(format: "%.1f", min(max(qwenDeEsserStrengthDecibels, 0), SpeechSettings.maximumQwenDeEsserStrengthDecibels)))",
            "referenceAudio=\(referenceAudioSignature)",
            "referenceText=\(referenceText)",
            "text=\(text)",
        ].joined(separator: "\n")
        let digest = SHA256.hash(data: Data(material.utf8))
        return digest.map { String(format: "%02x", $0) }.joined()
    }

    public func doctor() async -> QwenRuntimeReport {
        await syncHelperIfPossible()
        let installedModelIDs = Set(
            QwenModelLane.allCases.flatMap { lane in
                [
                    isModelInstalled(lane, useReferenceVoice: false) ? lane.modelID : nil,
                    isModelInstalled(lane, useReferenceVoice: true) ? lane.referenceModelID : nil,
                ].compactMap { $0 }
            })
        return QwenRuntimeReport(
            runtimeRoot: runtimeRoot.path,
            logsDirectory: logsDirectory.path,
            architecture: machineArchitecture(),
            uvAvailable: uvExecutableURL() != nil,
            pythonEnvironmentAvailable: fileManager.isExecutableFile(atPath: managedPythonURL.path),
            mlxAudioAvailable: await mlxAudioImportWorks(),
            helperAvailable: fileManager.fileExists(atPath: helperURL.path),
            installedModelIDs: installedModelIDs,
            installingLane: installingLane,
            installingReferenceVoice: installingReferenceVoice,
            lastError: lastError
        )
    }

    public func isResident() async -> Bool {
        if await nativeInferenceRuntime.isResident() {
            return true
        }
        let helpers = Array(residentHelpers.values)
        for helper in helpers where await helper.isRunning() {
            return true
        }
        return false
    }

    public func unloadResidentHelpers() async {
        await nativeInferenceRuntime.unload()
        await stopResidentHelpers()
    }

    public func install(
        lane: QwenModelLane,
        useReferenceVoice: Bool = false,
        referenceAudioPath: String? = nil,
        referenceText: String? = nil,
        progress: (@Sendable (QwenInstallProgress) async -> Void)? = nil
    ) async throws {
        installingLane = lane
        installingReferenceVoice = useReferenceVoice
        lastError = nil
        defer {
            installingLane = nil
            installingReferenceVoice = false
        }

        do {
            try createRuntimeDirectories()
            try await emit(.init(lane: lane, stage: "Preparing runtime", fractionCompleted: 0.05), progress)
            try await syncHelper()
            try await ensureUV(progress: progress, lane: lane)
            try await ensurePythonEnvironment(progress: progress, lane: lane)
            try await downloadModel(lane, useReferenceVoice: useReferenceVoice, progress: progress)
            try await emit(.init(lane: lane, stage: "Warming Qwen voice", fractionCompleted: 0.92), progress)
            try await prewarm(
                lane: lane,
                speaker: lane.defaultSpeaker,
                useReferenceVoice: useReferenceVoice,
                referenceAudioPath: referenceAudioPath,
                referenceText: referenceText
            )
            try await emit(.init(lane: lane, stage: "Ready", fractionCompleted: 1.0), progress)
        } catch is CancellationError {
            lastError = QwenRuntimeError.cancelled.localizedDescription
            throw CancellationError()
        } catch {
            lastError = error.localizedDescription
            throw error
        }
    }

    public func prewarm(
        lane: QwenModelLane,
        speaker: String,
        useReferenceVoice: Bool = false,
        referenceAudioPath: String? = nil,
        referenceText: String? = nil
    ) async throws {
        if nativeStreamingEnabled(for: lane, useReferenceVoice: useReferenceVoice) {
            let request = QwenStreamingSynthesisRequest(
                itemIndex: 0,
                request: QwenSynthesisRequest(
                    text: "Ready.",
                    lane: lane,
                    speaker: speaker,
                    language: lane.language,
                    rateMultiplier: 1.0,
                    cachePolicy: .transient,
                    useReferenceVoice: useReferenceVoice,
                    referenceAudioPath: referenceAudioPath,
                    referenceText: useReferenceVoice
                        ? (referenceText ?? QwenReferenceVoiceDefaults.referenceText)
                        : nil
                )
            )
            try await streamAudio(request) { _ in }
            return
        }
        let audio = try await synthesize(
            text: "Ready.",
            lane: lane,
            speaker: speaker,
            language: lane.language,
            rateMultiplier: 1.0,
            cachePolicy: .transient,
            useReferenceVoice: useReferenceVoice,
            referenceAudioPath: referenceAudioPath,
            referenceText: useReferenceVoice ? (referenceText ?? QwenReferenceVoiceDefaults.referenceText) : nil
        )
        removeTemporaryAudioIfNeeded(audio)
    }

    public func prewarmQuestionStarters(
        lane: QwenModelLane,
        speaker: String,
        useReferenceVoice: Bool = false,
        rateMultiplier: Double = SpeechSettings.default.rateMultiplier,
        qwenDeEsserStrengthDecibels: Double = SpeechSettings.defaultQwenDeEsserStrengthDecibels,
        referenceAudioPath: String? = nil,
        referenceText: String? = nil
    ) async throws {
        try Task.checkCancellation()
        let requests = ReadPlanBuilder.commonQuestionStarterPhrases.map { starter in
            QwenSynthesisRequest(
                text: starter,
                lane: lane,
                speaker: speaker,
                language: lane.language,
                rateMultiplier: rateMultiplier,
                cachePolicy: .persistent,
                useReferenceVoice: useReferenceVoice,
                referenceAudioPath: referenceAudioPath,
                referenceText: useReferenceVoice ? (referenceText ?? QwenReferenceVoiceDefaults.referenceText) : nil,
                qwenDeEsserStrengthDecibels: qwenDeEsserStrengthDecibels
            )
        }
        _ = try await synthesizeBatch(requests)
    }

    public func promptAudioLibraryContext(
        lane: QwenModelLane,
        speaker: String,
        language: String,
        useReferenceVoice: Bool,
        referenceAudioPath: String?,
        referenceText: String?
    ) async throws -> QwenPromptAudioLibraryContext {
        try createRuntimeDirectories()
        let reference = try resolvedReferenceVoice(
            lane: lane,
            useReferenceVoice: useReferenceVoice,
            audioPath: referenceAudioPath,
            text: referenceText
        )
        let normalizedReferenceText = reference.text?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        let referenceAudioSignature = try reference.audioURL.map(referenceAudioSignature(for:)) ?? ""
        return QwenPromptAudioLibraryContext(
            lane: lane,
            speaker: speaker,
            language: language,
            useReferenceVoice: useReferenceVoice,
            referenceAudioSignature: referenceAudioSignature,
            referenceTextHash: normalizedReferenceText.isEmpty ? "" : QwenPromptAudioLibrary.hashText(normalizedReferenceText),
            cachePipelineVersion: Self.cachePipelineVersion,
            referenceAudioPathForSynthesis: reference.audioURL?.path,
            referenceTextForSynthesis: normalizedReferenceText.isEmpty ? nil : normalizedReferenceText
        )
    }

    public func restorePromptLibraryAudioIfAvailable(
        text: String,
        context: QwenPromptAudioLibraryContext,
        rateMultiplier: Double
    ) async throws -> Bool {
        try createRuntimeDirectories()
        try maintainCacheIfNeeded(now: Date())
        guard let match = try await promptAudioLibrary.lookup(text: text, context: context, kind: .fullPrompt) else {
            return false
        }
        guard isUsableAudioFile(at: match.audioURL) else {
            return false
        }
        let key = Self.cacheKey(
            text: text,
            lane: context.lane,
            speaker: context.speaker,
            language: context.language,
            rateMultiplier: rateMultiplier,
            qwenDeEsserStrengthDecibels: context.qwenDeEsserStrengthDecibels,
            useReferenceVoice: context.useReferenceVoice,
            referenceAudioSignature: context.referenceAudioSignature,
            referenceText: context.referenceTextForSynthesis?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        )
        let destination = cacheDirectory.appendingPathComponent("\(key).wav")
        if cachedAudioIfUsable(at: destination) == nil {
            try fileManager.createDirectory(at: cacheDirectory, withIntermediateDirectories: true)
            let temporaryURL = cacheDirectory.appendingPathComponent(".\(key).\(UUID().uuidString).restore")
            defer { try? fileManager.removeItem(at: temporaryURL) }
            try fileManager.copyItem(at: match.audioURL, to: temporaryURL)
            guard isUsableAudioFile(at: temporaryURL) else {
                throw QwenRuntimeError.commandFailed("Stored prompt audio is invalid.")
            }
            try fileManager.moveItem(at: temporaryURL, to: destination)
        }
        return true
    }

    public func learnPromptAudio(
        text: String,
        derivedPrefixTexts: [String],
        context: QwenPromptAudioLibraryContext
    ) async {
        await learnPromptAudio(
            text: text,
            derivedPrefixTexts: derivedPrefixTexts,
            context: context,
            source: .narration
        )
    }

    private func learnPromptAudio(
        text: String,
        derivedPrefixTexts _: [String],
        context: QwenPromptAudioLibraryContext,
        source: QwenPromptAudioLibraryEntrySource
    ) async {
        // Derived-prefix entries had no playback lookup path and multiplied background
        // synthesis work. Keep the schema case for compatibility, but only learn audio
        // that can actually be consumed.
        let phrases = [(text, QwenPromptAudioLibraryEntryKind.fullPrompt)]
        for (phrase, kind) in phrases {
            do {
                if try await promptAudioLibrary.contains(text: phrase, context: context, kind: kind) {
                    continue
                }
                let audio = try await synthesize(
                    text: phrase,
                    lane: context.lane,
                    speaker: context.speaker,
                    language: context.language,
                    rateMultiplier: 1.0,
                    qwenDeEsserStrengthDecibels: context.qwenDeEsserStrengthDecibels,
                    cachePolicy: .persistent,
                    useReferenceVoice: context.useReferenceVoice,
                    referenceAudioPath: context.referenceAudioPathForSynthesis,
                    referenceText: context.referenceTextForSynthesis
                )
                _ = try await promptAudioLibrary.storeAudio(
                    from: audio.url,
                    text: phrase,
                    context: context,
                    source: source,
                    kind: kind
                )
            } catch {
                appendLog("failed qwen prompt library learn kind=\(kind.rawValue)")
            }
        }
    }

    public func clearPromptAudioLibrary() async throws {
        try await promptAudioLibrary.clear()
    }

    public func synthesize(
        text: String,
        lane: QwenModelLane,
        speaker: String,
        language: String,
        rateMultiplier: Double,
        cachePolicy: QwenAudioCachePolicy = .automatic,
        useReferenceVoice: Bool = false,
        referenceAudioPath: String? = nil,
        referenceText: String? = nil
    ) async throws -> QwenPreparedAudio {
        try await synthesize(
            text: text,
            lane: lane,
            speaker: speaker,
            language: language,
            rateMultiplier: rateMultiplier,
            qwenDeEsserStrengthDecibels: SpeechSettings.defaultQwenDeEsserStrengthDecibels,
            cachePolicy: cachePolicy,
            useReferenceVoice: useReferenceVoice,
            referenceAudioPath: referenceAudioPath,
            referenceText: referenceText
        )
    }

    public func synthesize(
        text: String,
        lane: QwenModelLane,
        speaker: String,
        language: String,
        rateMultiplier: Double,
        qwenDeEsserStrengthDecibels: Double,
        cachePolicy: QwenAudioCachePolicy = .automatic,
        useReferenceVoice: Bool = false,
        referenceAudioPath: String? = nil,
        referenceText: String? = nil
    ) async throws -> QwenPreparedAudio {
        let synthesisInterval = SalientSignposts.begin(.synthesis)
        defer { SalientSignposts.end(synthesisInterval) }
        let request = QwenSynthesisRequest(
            text: text,
            lane: lane,
            speaker: speaker,
            language: language,
            rateMultiplier: rateMultiplier,
            cachePolicy: cachePolicy,
            useReferenceVoice: useReferenceVoice,
            referenceAudioPath: referenceAudioPath,
            referenceText: referenceText,
            qwenDeEsserStrengthDecibels: qwenDeEsserStrengthDecibels
        )
        guard let audio = try await synthesizeBatch([request]).first else {
            throw QwenRuntimeError.commandFailed("Qwen synthesis returned no audio.")
        }
        return audio
    }

    func synthesize(_ request: QwenSynthesisRequest) async throws -> QwenPreparedAudio {
        guard let audio = try await synthesizeBatch([request]).first else {
            throw QwenRuntimeError.commandFailed("Qwen synthesis returned no audio.")
        }
        return audio
    }

    func streamAudio(
        _ request: QwenStreamingSynthesisRequest,
        onChunk: @Sendable @escaping (QwenStreamingAudioChunk) async throws -> Void
    ) async throws {
        try Task.checkCancellation()
        try createRuntimeDirectories()
        let synthesisLease = try await acquireSynthesisLease()
        defer { releaseSynthesisLease(synthesisLease) }
        try Task.checkCancellation()
        try maintainCacheIfNeeded(now: Date())

        let useNativeRuntime = nativeStreamingEnabled(
            for: request.request.lane,
            useReferenceVoice: request.request.useReferenceVoice
        )
        switch try prepareSynthesisPlan(
            for: request.request,
            index: request.itemIndex,
            requirePythonRuntime: !useNativeRuntime
        ) {
        case .cached(let audio):
            try await streamCachedAudio(audio, request: request, onChunk: onChunk)
        case .pending(let plan):
            defer { cleanupPendingSynthesis(plan) }
            if useNativeRuntime {
                let emissionTracker = QwenNativeEmissionTracker()
                let cacheWriter = plan.removeAfterPlayback
                    ? nil
                    : QwenPCMFileWriter(outputURL: plan.rawURL)
                do {
                    try await nativeInferenceRuntime.stream(
                        QwenNativeInferenceRequest(
                            id: request.id,
                            itemIndex: request.itemIndex,
                            text: request.request.text,
                            modelDirectory: plan.modelURL,
                            speaker: request.request.speaker,
                            language: request.request.language,
                            useReferenceVoice: request.request.useReferenceVoice,
                            referenceAudioURL: plan.referenceAudioURL,
                            referenceAudioSignature: plan.referenceAudioSignature,
                            referenceText: plan.referenceText,
                            metalLibraryURL: nativeMetalLibraryURL()
                        )
                    ) { chunk in
                        if Self.containsAudiblePCM(chunk.audioData) {
                            await emissionTracker.markAudioEmitted()
                        }
                        try await onChunk(chunk)
                        try await cacheWriter?.append(chunk)
                    }
                    if let cacheWriter, await cacheWriter.frameCount > 0 {
                        await cacheWriter.finish()
                        try QwenAudioPostProcessor.writeTrimmedCopy(
                            from: plan.rawURL,
                            to: plan.outputURL,
                            qwenDeEsserStrengthDecibels: plan.request.qwenDeEsserStrengthDecibels
                        )
                    }
                    return
                } catch is CancellationError {
                    await cacheWriter?.finish()
                    throw CancellationError()
                } catch {
                    await cacheWriter?.finish()
                    guard !(await emissionTracker.hasEmittedAudio()) else {
                        appendLog("failed native qwen stream after audio")
                        throw error
                    }
                    appendLog("failed native qwen stream before audio; fallback=python-complete-file")
                    try await preparePythonSynthesisRuntime()
                    await nativeInferenceRuntime.unload()
                    try await runResidentSynthesis([plan])
                    let audio = try postprocessPendingSynthesis(plan)
                    try await streamCachedAudio(
                        audio,
                        request: request,
                        backend: .pythonMLX,
                        fallbackReason: .nativeGenerationFailedBeforeAudio,
                        onChunk: onChunk
                    )
                    return
                }
            }
            // Legacy Python streaming remains available only to tests that inject it.
            // Production streaming uses native MLX; complete-file Python is the fallback.
            try await preparePythonSynthesisRuntime()
            try await runResidentStreaming(plan, requestID: request.id, itemIndex: request.itemIndex, onChunk: onChunk)
        }
    }

    func synthesizeBatch(_ requests: [QwenSynthesisRequest]) async throws -> [QwenPreparedAudio] {
        guard !requests.isEmpty else { return [] }
        try Task.checkCancellation()
        try createRuntimeDirectories()
        try maintainCacheIfNeeded(now: Date())
        // Cache reads do not need the exclusive model-generation lease. This
        // prevents ready audio from queueing behind an unrelated long miss.
        if let cached = try cachedBatchIfFullyAvailable(requests) {
            return cached
        }
        let synthesisLease = try await acquireSynthesisLease()
        defer { releaseSynthesisLease(synthesisLease) }
        try Task.checkCancellation()
        try maintainCacheIfNeeded(now: Date())

        var results = [QwenPreparedAudio?](repeating: nil, count: requests.count)
        var pending: [QwenPendingSynthesis] = []
        var completedSuccessfully = false
        defer {
            pending.forEach(cleanupPendingSynthesis)
            if !completedSuccessfully {
                results.compactMap { $0 }.forEach(removeTemporaryAudioIfNeeded)
            }
        }

        do {
            for (index, request) in requests.enumerated() {
                switch try prepareSynthesisPlan(for: request, index: index) {
                case .cached(let audio):
                    results[index] = audio
                case .pending(let plan):
                    pending.append(plan)
                }
            }

            if !pending.isEmpty {
                try await preparePythonSynthesisRuntime()
                do {
                    try await runResidentSynthesis(pending)
                } catch is CancellationError {
                    throw CancellationError()
                } catch {
                    appendLog("failed qwen serve; falling back to one-shot helper")
                    await discardResidentHelpers()
                    for plan in pending where !isUsableAudioFile(at: plan.rawURL) {
                        try await runOneShotSynthesis(plan)
                    }
                }

                for plan in pending {
                    results[plan.index] = try postprocessPendingSynthesis(plan)
                }
            }

            let prepared = try results.enumerated().map { index, audio in
                guard let audio else {
                    throw QwenRuntimeError.commandFailed("Qwen synthesis did not prepare item \(index).")
                }
                return audio
            }
            completedSuccessfully = true
            return prepared
        } catch is CancellationError {
            throw CancellationError()
        }
    }

    private func cachedBatchIfFullyAvailable(
        _ requests: [QwenSynthesisRequest]
    ) throws -> [QwenPreparedAudio]? {
        var cached: [QwenPreparedAudio] = []
        cached.reserveCapacity(requests.count)
        for (index, request) in requests.enumerated() {
            switch try prepareSynthesisPlan(
                for: request,
                index: index,
                requirePythonRuntime: false
            ) {
            case .cached(let audio):
                cached.append(audio)
            case .pending(let plan):
                cleanupPendingSynthesis(plan)
                return nil
            }
        }
        return cached
    }

    private func prepareSynthesisPlan(
        for request: QwenSynthesisRequest,
        index: Int,
        requirePythonRuntime: Bool = true
    ) throws -> QwenSynthesisPlan {
        let reference = try resolvedReferenceVoice(
            lane: request.lane,
            useReferenceVoice: request.useReferenceVoice,
            audioPath: request.referenceAudioPath,
            text: request.referenceText
        )
        let normalizedReferenceText = reference.text?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        let referenceAudioSignature = try reference.audioURL.map(referenceAudioSignature(for:)) ?? ""
        let shouldPersistAudio = Self.shouldPersistSynthesizedAudio(request.text, cachePolicy: request.cachePolicy)
        let persistentURL: URL?
        if shouldPersistAudio {
            let key = Self.cacheKey(
                text: request.text,
                lane: request.lane,
                speaker: request.speaker,
                language: request.language,
                rateMultiplier: request.rateMultiplier,
                qwenDeEsserStrengthDecibels: request.qwenDeEsserStrengthDecibels,
                useReferenceVoice: request.useReferenceVoice,
                referenceAudioSignature: referenceAudioSignature,
                referenceText: normalizedReferenceText
            )
            let cachedURL = cacheDirectory.appendingPathComponent("\(key).wav")
            if let audio = cachedAudioIfUsable(at: cachedURL) {
                return .cached(audio)
            }

            let legacyKey = Self.legacyRateCacheKey(
                text: request.text,
                lane: request.lane,
                speaker: request.speaker,
                language: request.language,
                rateMultiplier: request.rateMultiplier,
                qwenDeEsserStrengthDecibels: request.qwenDeEsserStrengthDecibels,
                useReferenceVoice: request.useReferenceVoice,
                referenceAudioSignature: referenceAudioSignature,
                referenceText: normalizedReferenceText
            )
            let legacyURL = cacheDirectory.appendingPathComponent("\(legacyKey).wav")
            if let legacyAudio = cachedAudioIfUsable(at: legacyURL) {
                let promotedURL = promoteLegacyCacheEntry(from: legacyURL, to: cachedURL)
                return .cached(
                    QwenPreparedAudio(
                        url: promotedURL,
                        durationSeconds: legacyAudio.durationSeconds,
                        isFromCache: true
                    ))
            }
            persistentURL = cachedURL
        } else {
            persistentURL = nil
        }

        guard !requirePythonRuntime || fileManager.isExecutableFile(atPath: managedPythonURL.path) else {
            throw QwenRuntimeError.setupRequired("Qwen needs setup before it can read with \(request.lane.displayName).")
        }
        guard isModelInstalled(request.lane, useReferenceVoice: request.useReferenceVoice) else {
            throw QwenRuntimeError.setupRequired(
                "\(request.lane.setupDisplayName(useReferenceVoice: request.useReferenceVoice)) is not installed yet.")
        }

        let textURL = temporaryDirectory.appendingPathComponent("\(UUID().uuidString).txt")
        let referenceTextURL: URL? =
            normalizedReferenceText.isEmpty
            ? nil
            : temporaryDirectory.appendingPathComponent("\(UUID().uuidString)-reference.txt")
        let rawURL = temporaryDirectory.appendingPathComponent("\(UUID().uuidString)-raw.wav")
        let outputURL = persistentURL ?? temporaryDirectory.appendingPathComponent("\(UUID().uuidString)-playback.wav")
        try request.text.write(to: textURL, atomically: true, encoding: .utf8)
        if let referenceTextURL {
            try normalizedReferenceText.write(to: referenceTextURL, atomically: true, encoding: .utf8)
        }

        return .pending(
            QwenPendingSynthesis(
                index: index,
                request: request,
                modelURL: modelDirectory(for: request.lane, useReferenceVoice: request.useReferenceVoice),
                referenceAudioURL: reference.audioURL,
                referenceAudioSignature: referenceAudioSignature,
                referenceText: normalizedReferenceText.isEmpty ? nil : normalizedReferenceText,
                referenceTextURL: referenceTextURL,
                textURL: textURL,
                rawURL: rawURL,
                outputURL: outputURL,
                removeAfterPlayback: persistentURL == nil
            ))
    }

    private func runOneShotSynthesis(_ plan: QwenPendingSynthesis) async throws {
        var arguments = [
            helperURL.path,
            "synthesize",
            "--model", plan.modelURL.path,
            "--speaker", plan.request.speaker,
            "--language", plan.request.language,
            "--text-file", plan.textURL.path,
            "--output", plan.rawURL.path,
        ]
        if let audioURL = plan.referenceAudioURL {
            arguments.append(contentsOf: ["--ref-audio", audioURL.path])
        }
        if let referenceTextURL = plan.referenceTextURL {
            arguments.append(contentsOf: ["--ref-text-file", referenceTextURL.path])
        }

        let command = QwenShellCommand(
            executable: managedPythonURL.path,
            arguments: arguments,
            environment: helperEnvironment,
            redactedDescription: "qwen synthesize \(plan.request.lane.modelID) \(plan.request.speaker)"
        )
        try await runChecked(command)
    }

    private func runResidentSynthesis(_ pending: [QwenPendingSynthesis]) async throws {
        let grouped = Dictionary(grouping: pending, by: { $0.modelURL.path })
        for group in grouped.values {
            guard let first = group.first else { continue }
            var startIndex = 0
            while startIndex < group.count {
                let endIndex = min(startIndex + Self.residentHelperBatchLimit, group.count)
                let chunk = Array(group[startIndex..<endIndex])
                let request = QwenResidentHelperRequest(
                    id: UUID().uuidString,
                    items: chunk.map { plan in
                        QwenResidentHelperItem(
                            textFile: plan.textURL.path,
                            output: plan.rawURL.path,
                            speaker: plan.request.speaker,
                            language: plan.request.language,
                            refAudio: plan.referenceAudioURL?.path,
                            refTextFile: plan.referenceTextURL?.path
                        )
                    }
                )
                let session = await residentSession(for: first.modelURL)
                appendLog("start qwen serve batch count=\(chunk.count)")
                let response = try await session.synthesize(request)
                guard response.items?.count == chunk.count else {
                    throw QwenRuntimeError.commandFailed("Qwen resident helper returned an unexpected output count.")
                }
                for (responseItem, plan) in zip(response.items ?? [], chunk) {
                    let returnedURL = URL(fileURLWithPath: responseItem.output).standardizedFileURL
                    guard returnedURL == plan.rawURL.standardizedFileURL,
                          responseItem.bytes.map({ $0 > 0 }) ?? true,
                          isUsableAudioFile(at: plan.rawURL) else {
                        try? fileManager.removeItem(at: plan.rawURL)
                        throw QwenRuntimeError.commandFailed("Qwen resident helper returned an invalid audio output.")
                    }
                }
                appendLog("ok qwen serve batch count=\(chunk.count)")
                startIndex = endIndex
            }
        }
    }

    private func runResidentStreaming(
        _ plan: QwenPendingSynthesis,
        requestID: String,
        itemIndex: Int,
        onChunk: @Sendable @escaping (QwenStreamingAudioChunk) async throws -> Void
    ) async throws {
        let session = await residentSession(for: plan.modelURL)
        let request = QwenResidentHelperRequest(
            id: requestID,
            mode: "stream",
            streamingInterval: 0.32,
            items: [
                QwenResidentHelperItem(
                    textFile: plan.textURL.path,
                    output: plan.rawURL.path,
                    speaker: plan.request.speaker,
                    language: plan.request.language,
                    refAudio: plan.referenceAudioURL?.path,
                    refTextFile: plan.referenceTextURL?.path,
                    itemIndex: itemIndex
                )
            ]
        )
        appendLog("start qwen serve stream")
        do {
            try await session.stream(request) { chunk in
                try await onChunk(chunk)
            }
            appendLog("ok qwen serve stream")
        } catch {
            appendLog("failed qwen serve stream")
            throw error
        }
    }

    private func streamCachedAudio(
        _ audio: QwenPreparedAudio,
        request: QwenStreamingSynthesisRequest,
        backend: QwenInferenceBackend = .cache,
        fallbackReason: QwenInferenceFallbackReason? = nil,
        onChunk: @Sendable @escaping (QwenStreamingAudioChunk) async throws -> Void
    ) async throws {
        let file = try AVAudioFile(forReading: audio.url)
        let format = file.processingFormat
        guard
            let buffer = AVAudioPCMBuffer(
                pcmFormat: format,
                frameCapacity: AVAudioFrameCount(file.length)
            )
        else {
            throw QwenRuntimeError.commandFailed("Could not allocate cached Qwen stream buffer.")
        }
        try file.read(into: buffer)
        guard let channels = buffer.floatChannelData,
            buffer.frameLength > 0,
            format.sampleRate > 0
        else {
            throw QwenRuntimeError.commandFailed("Cached Qwen audio was empty.")
        }

        let frameCount = Int(buffer.frameLength)
        let channelCount = max(1, Int(format.channelCount))
        var samples = [Float](repeating: 0, count: frameCount)
        for channel in 0..<channelCount {
            let data = channels[channel]
            for frame in 0..<frameCount {
                samples[frame] += data[frame] / Float(channelCount)
            }
        }
        let audioData = samples.withUnsafeBufferPointer { pointer in
            Data(buffer: pointer)
        }
        try await onChunk(
            QwenStreamingAudioChunk(
                requestID: request.id,
                itemIndex: request.itemIndex,
                sequenceIndex: 0,
                sampleRate: format.sampleRate,
                audioData: audioData,
                durationSeconds: Double(frameCount) / format.sampleRate,
                isFinal: true,
                elapsedSeconds: 0,
                peakMemoryBytes: nil,
                backend: backend,
                residencyState: audio.isFromCache ? .cacheHit : .warm,
                device: backend == .pythonMLX ? "gpu" : nil,
                fallbackReason: fallbackReason
            ))
    }

    private func nativeStreamingEnabled(
        for lane: QwenModelLane,
        useReferenceVoice: Bool
    ) -> Bool {
        if let nativeStreamingEnabledOverride {
            return nativeStreamingEnabledOverride
        }
        return QwenNativeStreamingPolicy.isInteractiveStreamingEnabled(
            lane: lane,
            useReferenceVoice: useReferenceVoice
        )
    }

    private func acquireSynthesisLease() async throws -> UUID {
        try Task.checkCancellation()
        let leaseID = UUID()
        if synthesisLeaseOwner == nil {
            synthesisLeaseOwner = leaseID
            return leaseID
        }

        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                if Task.isCancelled {
                    continuation.resume(throwing: CancellationError())
                } else {
                    synthesisLeaseWaiterOrder.append(leaseID)
                    synthesisLeaseWaiters[leaseID] = continuation
                }
            }
        } onCancel: {
            Task {
                await self.cancelSynthesisLeaseWaiter(leaseID)
            }
        }
    }

    private func releaseSynthesisLease(_ leaseID: UUID) {
        guard synthesisLeaseOwner == leaseID else { return }
        while let nextLeaseID = synthesisLeaseWaiterOrder.first {
            synthesisLeaseWaiterOrder.removeFirst()
            guard let continuation = synthesisLeaseWaiters.removeValue(forKey: nextLeaseID) else {
                continue
            }
            synthesisLeaseOwner = nextLeaseID
            continuation.resume(returning: nextLeaseID)
            return
        }
        synthesisLeaseOwner = nil
    }

    private func cancelSynthesisLeaseWaiter(_ leaseID: UUID) {
        guard let continuation = synthesisLeaseWaiters.removeValue(forKey: leaseID) else { return }
        synthesisLeaseWaiterOrder.removeAll { $0 == leaseID }
        continuation.resume(throwing: CancellationError())
    }

    func pendingSynthesisLeaseCountForTesting() -> Int {
        synthesisLeaseWaiters.count
    }

    private func preparePythonSynthesisRuntime() async throws {
        guard fileManager.isExecutableFile(atPath: managedPythonURL.path) else {
            throw QwenRuntimeError.setupRequired("Qwen needs setup before it can read.")
        }
        await nativeInferenceRuntime.unload()
        try await syncHelper()
    }

    private func cachedAudioIfUsable(at url: URL) -> QwenPreparedAudio? {
        guard fileManager.fileExists(atPath: url.path),
              QwenAudioPostProcessor.isWaveContainer(at: url),
              let duration = QwenAudioPostProcessor.durationSeconds(of: url),
              duration.isFinite,
              duration > 0,
              QwenAudioPostProcessor.hasAudibleSignal(at: url) else {
            if fileManager.fileExists(atPath: url.path) {
                try? fileManager.removeItem(at: url)
            }
            return nil
        }
        return QwenPreparedAudio(
            url: url,
            durationSeconds: duration,
            isFromCache: true
        )
    }

    private func isUsableAudioFile(at url: URL) -> Bool {
        guard QwenAudioPostProcessor.isWaveContainer(at: url),
              let duration = QwenAudioPostProcessor.durationSeconds(of: url) else { return false }
        return duration.isFinite && duration > 0 && QwenAudioPostProcessor.hasAudibleSignal(at: url)
    }

    private nonisolated static func containsAudiblePCM(_ data: Data) -> Bool {
        guard !data.isEmpty, data.count.isMultiple(of: MemoryLayout<Float>.stride) else {
            return false
        }
        return data.withUnsafeBytes { rawBuffer in
            rawBuffer.bindMemory(to: Float.self).contains { abs($0) >= 0.0005 }
        }
    }

    private func promoteLegacyCacheEntry(from legacyURL: URL, to destinationURL: URL) -> URL {
        if cachedAudioIfUsable(at: destinationURL) != nil {
            return destinationURL
        }
        do {
            try fileManager.linkItem(at: legacyURL, to: destinationURL)
            return destinationURL
        } catch {
            do {
                try fileManager.copyItem(at: legacyURL, to: destinationURL)
                return destinationURL
            } catch {
                return legacyURL
            }
        }
    }

    private func residentSession(for modelURL: URL) async -> QwenResidentHelperSession {
        let key = modelURL.path
        if let session = residentHelpers[key] {
            return session
        }
        let obsoleteHelpers = Array(residentHelpers.values)
        residentHelpers.removeAll()
        await withTaskGroup(of: Void.self) { group in
            for helper in obsoleteHelpers {
                group.addTask {
                    await helper.stop()
                }
            }
        }
        let session = QwenResidentHelperSession(
            pythonURL: managedPythonURL,
            helperURL: helperURL,
            modelURL: modelURL,
            environment: helperEnvironment
        )
        residentHelpers[key] = session
        return session
    }

    private func discardResidentHelpers() async {
        await stopResidentHelpers()
    }

    private func stopResidentHelpers() async {
        let helpers = Array(residentHelpers.values)
        residentHelpers.removeAll()
        await withTaskGroup(of: Void.self) { group in
            for helper in helpers {
                group.addTask {
                    await helper.stop()
                }
            }
        }
    }

    private func postprocessPendingSynthesis(_ plan: QwenPendingSynthesis) throws -> QwenPreparedAudio {
        try Task.checkCancellation()
        let completedURL = plan.outputURL.deletingLastPathComponent()
            .appendingPathComponent(".\(plan.outputURL.lastPathComponent).\(UUID().uuidString).completed.wav")
        defer { try? fileManager.removeItem(at: completedURL) }
        try QwenAudioPostProcessor.writeTrimmedCopy(
            from: plan.rawURL,
            to: completedURL,
            qwenDeEsserStrengthDecibels: plan.request.qwenDeEsserStrengthDecibels
        )
        guard let duration = QwenAudioPostProcessor.durationSeconds(of: completedURL),
              duration.isFinite,
              duration > 0,
              QwenAudioPostProcessor.isWaveContainer(at: completedURL),
              QwenAudioPostProcessor.hasAudibleSignal(at: completedURL) else {
            throw QwenRuntimeError.commandFailed("Qwen synthesis produced invalid audio.")
        }
        if fileManager.fileExists(atPath: plan.outputURL.path) {
            try fileManager.removeItem(at: plan.outputURL)
        }
        try fileManager.moveItem(at: completedURL, to: plan.outputURL)
        return QwenPreparedAudio(
            url: plan.outputURL,
            durationSeconds: duration,
            isFromCache: false,
            removeAfterPlayback: plan.removeAfterPlayback
        )
    }

    private func cleanupPendingSynthesis(_ plan: QwenPendingSynthesis) {
        try? fileManager.removeItem(at: plan.textURL)
        if let referenceTextURL = plan.referenceTextURL {
            try? fileManager.removeItem(at: referenceTextURL)
        }
        try? fileManager.removeItem(at: plan.rawURL)
    }

    public nonisolated static func shouldPersistSynthesizedAudio(_ text: String) -> Bool {
        shouldPersistSynthesizedAudio(text, cachePolicy: .automatic)
    }

    public nonisolated static func shouldPersistSynthesizedAudio(
        _ text: String,
        cachePolicy: QwenAudioCachePolicy
    ) -> Bool {
        switch cachePolicy {
        case .persistent:
            return true
        case .transient:
            return false
        case .automatic:
            break
        }

        let normalizedText = text.trimmedForSpeech
        return ReadPlanBuilder.commonQuestionStarterPhrases.contains { starter in
            starter.trimmedForSpeech.caseInsensitiveCompare(normalizedText) == .orderedSame
        }
    }

    public func clearCache() throws {
        if fileManager.fileExists(atPath: cacheDirectory.path) {
            try fileManager.removeItem(at: cacheDirectory)
        }
        try fileManager.createDirectory(at: cacheDirectory, withIntermediateDirectories: true)
        try writeCacheMaintenanceState(.init(lastClearedAt: Date()))
        lastCacheMaintenanceCheck = nil
    }

    public func clearCacheAndPrewarmQuestionStarters(
        lane: QwenModelLane,
        speaker: String,
        useReferenceVoice: Bool = false,
        rateMultiplier: Double = SpeechSettings.default.rateMultiplier
    ) async throws {
        try clearCache()
        try await prewarmQuestionStarters(
            lane: lane,
            speaker: speaker,
            useReferenceVoice: useReferenceVoice,
            rateMultiplier: rateMultiplier
        )
    }

    public func resetRuntime() async throws {
        let synthesisLease = try await acquireSynthesisLease()
        defer { releaseSynthesisLease(synthesisLease) }
        await discardResidentHelpers()
        await nativeInferenceRuntime.unload()
        if fileManager.fileExists(atPath: runtimeRoot.path) {
            try fileManager.removeItem(at: runtimeRoot)
        }
        runtimeDirectoriesReady = false
        helperSynchronized = false
        lastCacheMaintenanceCheck = nil
        cachedNativeMetalLibraryURL = nil
        referenceAudioSignatures.removeAll()
        installedModelValidationCache.removeAll()
        installingLane = nil
        installingReferenceVoice = false
        lastError = nil
    }

    public func defaultReferenceAudioURL() throws -> URL {
        try createRuntimeDirectories()
        try syncBundledReferenceVoiceIfNeeded()
        return bundledReferenceVoiceDestinationURL
    }

    public func importReferenceAudio(from sourceURL: URL) throws -> URL {
        try createRuntimeDirectories()
        let sourceExtension = sourceURL.pathExtension.lowercased()
        guard sourceExtension == "wav" else {
            throw QwenRuntimeError.setupRequired("Choose a WAV reference voice file for Qwen voice cloning.")
        }
        let baseName = sourceURL.deletingPathExtension().lastPathComponent
            .split { !$0.isLetter && !$0.isNumber && $0 != "-" && $0 != "_" }
            .joined(separator: "-")
        let safeBaseName = baseName.isEmpty ? "custom-qwen-voice" : String(baseName.prefix(64))
        let destination =
            voicesDirectory
            .appendingPathComponent("\(safeBaseName)-\(UUID().uuidString.prefix(8)).wav")
        try fileManager.copyItem(at: sourceURL, to: destination)
        return destination
    }

    public func importStudentReferenceVoice(
        from sourceURL: URL,
        transcript: String = QwenStudentReferenceVoiceDefaults.referenceText
    ) throws -> QwenStudentReferenceVoice {
        try createRuntimeDirectories()
        let validation = try validateStudentReferenceVoiceAudio(sourceURL)
        let destination = voicesDirectory.appendingPathComponent(QwenStudentReferenceVoiceDefaults.fileName)
        let temporaryURL = voicesDirectory.appendingPathComponent(
            ".student-reference.\(UUID().uuidString).importing.wav"
        )
        defer { try? fileManager.removeItem(at: temporaryURL) }
        try fileManager.copyItem(at: sourceURL, to: temporaryURL)
        _ = try validateStudentReferenceVoiceAudio(temporaryURL)
        if fileManager.fileExists(atPath: destination.path) {
            _ = try fileManager.replaceItemAt(destination, withItemAt: temporaryURL)
        } else {
            try fileManager.moveItem(at: temporaryURL, to: destination)
        }
        let normalizedTranscript = transcript.trimmingCharacters(in: .whitespacesAndNewlines)
        return QwenStudentReferenceVoice(
            displayName: QwenStudentReferenceVoiceDefaults.displayName,
            audioPath: destination.path,
            transcript: normalizedTranscript.isEmpty ? QwenStudentReferenceVoiceDefaults.referenceText : normalizedTranscript,
            durationSeconds: validation.durationSeconds,
            createdAt: Date()
        )
    }

    public func validateStudentReferenceVoiceAudio(_ sourceURL: URL) throws -> QwenReferenceAudioValidation {
        guard sourceURL.pathExtension.lowercased() == "wav" else {
            throw QwenRuntimeError.setupRequired("Choose a WAV voice sample for Qwen voice cloning.")
        }
        let attributes = try fileManager.attributesOfItem(atPath: sourceURL.path)
        let fileSize = (attributes[.size] as? NSNumber)?.int64Value ?? 0
        guard fileSize > 0, fileSize < QwenStudentReferenceVoiceDefaults.maximumFileBytes else {
            throw QwenRuntimeError.setupRequired("The voice sample must be a WAV file smaller than 10 MB.")
        }
        let file: AVAudioFile
        do {
            file = try AVAudioFile(forReading: sourceURL)
        } catch {
            throw QwenRuntimeError.setupRequired("The voice sample could not be read as audio.")
        }
        let sampleRate = file.fileFormat.sampleRate
        let channelCount = Int(file.fileFormat.channelCount)
        guard sampleRate >= QwenStudentReferenceVoiceDefaults.minimumSampleRate else {
            throw QwenRuntimeError.setupRequired("The voice sample must use a 24 kHz or higher sample rate.")
        }
        guard channelCount == 1 else {
            throw QwenRuntimeError.setupRequired("The voice sample must be mono.")
        }
        guard sampleRate > 0 else {
            throw QwenRuntimeError.setupRequired("The voice sample has an invalid sample rate.")
        }
        let durationSeconds = Double(file.length) / sampleRate
        guard durationSeconds >= QwenStudentReferenceVoiceDefaults.minimumDurationSeconds,
            durationSeconds <= QwenStudentReferenceVoiceDefaults.maximumDurationSeconds
        else {
            throw QwenRuntimeError.setupRequired("The voice sample must be 10 to 20 seconds long.")
        }
        let peakAmplitude = try peakAmplitude(in: file)
        guard peakAmplitude >= QwenStudentReferenceVoiceDefaults.minimumPeakAmplitude else {
            throw QwenRuntimeError.setupRequired("The voice sample is too quiet or silent.")
        }
        return QwenReferenceAudioValidation(
            durationSeconds: durationSeconds,
            sampleRate: sampleRate,
            channelCount: channelCount,
            peakAmplitude: peakAmplitude
        )
    }

    private func peakAmplitude(in file: AVAudioFile) throws -> Float {
        guard
            let buffer = AVAudioPCMBuffer(
                pcmFormat: file.processingFormat,
                frameCapacity: AVAudioFrameCount(file.length)
            )
        else {
            throw QwenRuntimeError.setupRequired("The voice sample could not be analyzed.")
        }
        try file.read(into: buffer)
        guard let channelData = buffer.floatChannelData else {
            throw QwenRuntimeError.setupRequired("The voice sample could not be analyzed.")
        }
        var peak: Float = 0
        for channel in 0..<Int(buffer.format.channelCount) {
            let samples = channelData[channel]
            for frame in 0..<Int(buffer.frameLength) {
                peak = max(peak, abs(samples[frame]))
            }
        }
        return peak
    }

    public func cancel() async {
        lastError = QwenRuntimeError.cancelled.localizedDescription
        await discardResidentHelpers()
        await nativeInferenceRuntime.unload()
    }

    public nonisolated var rootURL: URL { runtimeRoot }
    public nonisolated var logURL: URL { runtimeRoot.appendingPathComponent("logs", isDirectory: true) }

    private var binDirectory: URL { runtimeRoot.appendingPathComponent("bin", isDirectory: true) }
    private var cacheStateURL: URL { runtimeRoot.appendingPathComponent("cache-state.json") }
    private var cacheDirectory: URL { runtimeRoot.appendingPathComponent("cache", isDirectory: true) }
    private var helperDirectory: URL { runtimeRoot.appendingPathComponent("helper", isDirectory: true) }
    private var helperURL: URL { helperDirectory.appendingPathComponent("qwen_tts_helper.py") }
    private var logsDirectory: URL { runtimeRoot.appendingPathComponent("logs", isDirectory: true) }
    private var managedPythonURL: URL { runtimeRoot.appendingPathComponent("venv/bin/python") }
    private var modelRoot: URL { runtimeRoot.appendingPathComponent("models", isDirectory: true) }
    private var temporaryDirectory: URL { runtimeRoot.appendingPathComponent("tmp", isDirectory: true) }
    private var voicesDirectory: URL { runtimeRoot.appendingPathComponent("voices", isDirectory: true) }
    private var bundledReferenceVoiceDestinationURL: URL {
        voicesDirectory.appendingPathComponent(
            "\(QwenReferenceVoiceDefaults.bundledAudioResourceName).\(QwenReferenceVoiceDefaults.bundledAudioExtension)"
        )
    }

    private func nativeMetalLibraryURL() -> URL? {
        if let cachedNativeMetalLibraryURL,
           fileManager.fileExists(atPath: cachedNativeMetalLibraryURL.path) {
            return cachedNativeMetalLibraryURL
        }
        let libraryRoot = runtimeRoot.appendingPathComponent("venv/lib", isDirectory: true)
        guard let pythonDirectories = try? fileManager.contentsOfDirectory(
            at: libraryRoot,
            includingPropertiesForKeys: [.isDirectoryKey]
        ) else {
            return nil
        }
        let resolved = pythonDirectories
            .filter { $0.lastPathComponent.hasPrefix("python") }
            .map {
                $0.appendingPathComponent("site-packages/mlx/lib/mlx.metallib")
            }
            .first { fileManager.fileExists(atPath: $0.path) }
        cachedNativeMetalLibraryURL = resolved
        return resolved
    }

    private var helperEnvironment: [String: String] {
        [
            "HF_HOME": runtimeRoot.appendingPathComponent("huggingface", isDirectory: true).path,
            "PATH": [
                runtimeRoot.appendingPathComponent("venv/bin").path,
                binDirectory.path,
                "/opt/homebrew/bin",
                "/usr/local/bin",
                "/usr/bin",
                "/bin",
                "/usr/sbin",
                "/sbin",
            ].joined(separator: ":"),
        ]
    }

    private func createRuntimeDirectories() throws {
        if runtimeDirectoriesReady {
            return
        }
        for directory in [
            runtimeRoot, binDirectory, cacheDirectory, helperDirectory, logsDirectory, modelRoot, temporaryDirectory, voicesDirectory,
        ] {
            try fileManager.createDirectory(at: directory, withIntermediateDirectories: true)
        }
        runtimeDirectoriesReady = true
    }

    private func maintainCacheIfNeeded(now: Date) throws {
        let checkStartedAt = ContinuousClock.now
        if let lastCacheMaintenanceCheck,
           lastCacheMaintenanceCheck.duration(to: checkStartedAt) < Self.cacheMaintenanceCheckInterval {
            return
        }
        if let state = try readCacheMaintenanceState() {
            if now.timeIntervalSince(state.lastClearedAt) >= Self.cacheRetentionInterval {
                try clearCache()
            }
        } else {
            try writeCacheMaintenanceState(.init(lastClearedAt: now))
        }

        try maintainDiskSpaceIfNeeded()
        lastCacheMaintenanceCheck = checkStartedAt
    }

    private func maintainDiskSpaceIfNeeded() throws {
        guard let available = try availableCapacityProvider(runtimeRoot),
            available < Self.lowDiskCacheClearThresholdBytes
        else {
            return
        }

        try clearGeneratedRuntimeArtifactsForLowDisk()
        appendLog("low disk free bytes=\(available); cleared generated qwen artifacts")

        guard let remaining = try availableCapacityProvider(runtimeRoot),
            remaining < Self.minimumFreeDiskSpaceBytes
        else {
            return
        }

        throw QwenRuntimeError.commandFailed(
            "Not enough free disk space for Qwen narration. Salient cleared generated Qwen audio cache, but only \(Self.displayBytes(remaining)) remains available. Free at least \(Self.displayBytes(Self.minimumFreeDiskSpaceBytes)) and try again."
        )
    }

    private func clearGeneratedRuntimeArtifactsForLowDisk() throws {
        try clearCache()
        try clearDirectoryContents(temporaryDirectory)
        try clearDirectoryContents(logsDirectory)
    }

    private func clearDirectoryContents(_ directory: URL) throws {
        if fileManager.fileExists(atPath: directory.path) {
            let contents = try fileManager.contentsOfDirectory(
                at: directory,
                includingPropertiesForKeys: nil
            )
            for url in contents {
                try fileManager.removeItem(at: url)
            }
        }
        try fileManager.createDirectory(at: directory, withIntermediateDirectories: true)
    }

    private static func defaultAvailableCapacityProvider(for url: URL) throws -> Int64? {
        let values = try url.resourceValues(forKeys: [
            .volumeAvailableCapacityForImportantUsageKey,
            .volumeAvailableCapacityKey,
        ])
        if let capacity = values.volumeAvailableCapacityForImportantUsage {
            return capacity
        }
        if let capacity = values.volumeAvailableCapacity {
            return Int64(capacity)
        }
        let attributes = try FileManager.default.attributesOfFileSystem(forPath: url.path)
        return (attributes[.systemFreeSize] as? NSNumber)?.int64Value
    }

    private static func displayBytes(_ bytes: Int64) -> String {
        let gib = Double(bytes) / 1_073_741_824
        if gib >= 1 {
            return String(format: "%.1f GB", gib)
        }
        let mib = Double(bytes) / 1_048_576
        return String(format: "%.0f MB", mib)
    }

    private func readCacheMaintenanceState() throws -> CacheMaintenanceState? {
        guard fileManager.fileExists(atPath: cacheStateURL.path) else {
            return nil
        }
        let data = try Data(contentsOf: cacheStateURL)
        return try JSONDecoder().decode(CacheMaintenanceState.self, from: data)
    }

    private func writeCacheMaintenanceState(_ state: CacheMaintenanceState) throws {
        let data = try JSONEncoder().encode(state)
        try data.write(to: cacheStateURL, options: .atomic)
    }

    private func modelDirectory(for lane: QwenModelLane, useReferenceVoice: Bool = false) -> URL {
        if useReferenceVoice,
            lane == .best,
            containsInstalledModelFiles(in: legacyCloneModelDirectory)
        {
            return legacyCloneModelDirectory
        }
        return modelInstallDirectory(for: lane, useReferenceVoice: useReferenceVoice)
    }

    private func modelInstallDirectory(for lane: QwenModelLane, useReferenceVoice: Bool = false) -> URL {
        let suffix = useReferenceVoice ? "\(lane.rawValue)-reference" : lane.rawValue
        return modelRoot.appendingPathComponent(suffix, isDirectory: true)
    }

    private var legacyCloneModelDirectory: URL {
        modelRoot.appendingPathComponent("clone", isDirectory: true)
    }

    private func isModelInstalled(_ lane: QwenModelLane, useReferenceVoice: Bool = false) -> Bool {
        containsInstalledModelFiles(in: modelInstallDirectory(for: lane, useReferenceVoice: useReferenceVoice))
            || (useReferenceVoice && lane == .best && containsInstalledModelFiles(in: legacyCloneModelDirectory))
    }

    private func containsInstalledModelFiles(in directory: URL) -> Bool {
        let manifestURL = directory.appendingPathComponent(".salient-model-manifest.json")
        let validationFingerprint: String
        if let values = try? manifestURL.resourceValues(forKeys: [.fileSizeKey, .contentModificationDateKey]),
           let fileSize = values.fileSize,
           let modifiedAt = values.contentModificationDate {
            validationFingerprint = "manifest|\(fileSize)|\(modifiedAt.timeIntervalSince1970)"
        } else if let values = try? directory.resourceValues(forKeys: [.contentModificationDateKey]),
                  let modifiedAt = values.contentModificationDate {
            validationFingerprint = "legacy|\(modifiedAt.timeIntervalSince1970)"
        } else {
            validationFingerprint = "missing"
        }
        if let cached = installedModelValidationCache[directory.path],
           cached.fingerprint == validationFingerprint {
            return cached.isInstalled
        }

        let isInstalled: Bool
        if let data = try? Data(contentsOf: manifestURL),
            let manifest = try? JSONDecoder().decode(QwenModelInstallManifest.self, from: data)
        {
            isInstalled = !manifest.files.isEmpty && manifest.files.allSatisfy { file in
                let url = directory.appendingPathComponent(file.path)
                let byteCount = try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize
                return byteCount.map(Int64.init) == file.byteCount
            }
        } else if let enumerator = fileManager.enumerator(at: directory, includingPropertiesForKeys: [.fileSizeKey]) {
            var hasConfig = false
            var hasWeights = false
            for case let url as URL in enumerator {
                let name = url.lastPathComponent.lowercased()
                let size = (try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0
                if name == "config.json", size > 0 { hasConfig = true }
                if name.hasSuffix(".safetensors"), size > 0 { hasWeights = true }
            }
            isInstalled = hasConfig && hasWeights
        } else {
            isInstalled = false
        }
        installedModelValidationCache[directory.path] = QwenInstalledModelValidationCacheEntry(
            fingerprint: validationFingerprint,
            isInstalled: isInstalled
        )
        return isInstalled
    }

    private func removeTemporaryAudioIfNeeded(_ audio: QwenPreparedAudio) {
        guard audio.removeAfterPlayback else { return }
        try? fileManager.removeItem(at: audio.url)
    }

    private func syncHelperIfPossible() async {
        do {
            try createRuntimeDirectories()
            try await syncHelper()
        } catch {
            lastError = error.localizedDescription
        }
    }

    private func syncHelper() async throws {
        guard let source = Bundle.module.url(forResource: "qwen_tts_helper", withExtension: "py") else {
            throw QwenRuntimeError.helperMissing
        }
        try createRuntimeDirectories()
        if helperSynchronized, fileManager.fileExists(atPath: helperURL.path) {
            return
        }
        if fileManager.fileExists(atPath: helperURL.path) {
            let currentData = try? Data(contentsOf: helperURL)
            let sourceData = try Data(contentsOf: source)
            if currentData == sourceData {
                helperSynchronized = true
                return
            }
            await stopResidentHelpers()
            try fileManager.removeItem(at: helperURL)
            try sourceData.write(to: helperURL, options: .atomic)
            helperSynchronized = true
            return
        }
        try fileManager.copyItem(at: source, to: helperURL)
        helperSynchronized = true
    }

    private func syncBundledReferenceVoiceIfNeeded() throws {
        guard !fileManager.fileExists(atPath: bundledReferenceVoiceDestinationURL.path) else { return }
        try syncBundledReferenceVoice()
    }

    private func syncBundledReferenceVoice() throws {
        throw QwenRuntimeError.setupRequired(
            "The bundled Qwen reference voice is missing from the app. Record My Voice before using Qwen voice cloning.")
    }

    private func resolvedReferenceVoice(
        lane: QwenModelLane,
        useReferenceVoice: Bool,
        audioPath: String?,
        text: String?
    ) throws -> (audioURL: URL?, text: String?) {
        guard useReferenceVoice, lane.supportsReferenceVoice else {
            return (nil, nil)
        }

        let trimmedAudioPath = (audioPath ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        let audioURL: URL
        if trimmedAudioPath.isEmpty {
            try syncBundledReferenceVoiceIfNeeded()
            audioURL = bundledReferenceVoiceDestinationURL
        } else {
            audioURL = URL(fileURLWithPath: trimmedAudioPath)
        }

        guard fileManager.fileExists(atPath: audioURL.path) else {
            throw QwenRuntimeError.setupRequired("The Qwen reference voice audio is missing. Choose a WAV file again.")
        }

        let normalizedText = (text ?? QwenReferenceVoiceDefaults.referenceText)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return (
            audioURL,
            normalizedText.isEmpty ? QwenReferenceVoiceDefaults.referenceText : normalizedText
        )
    }

    private func referenceAudioSignature(for url: URL) throws -> String {
        let canonicalURL = url.standardizedFileURL.resolvingSymlinksInPath()
        let attributes = try fileManager.attributesOfItem(atPath: url.path)
        let byteCount = (attributes[.size] as? NSNumber)?.int64Value ?? -1
        let modifiedAt = (attributes[.modificationDate] as? Date)?.timeIntervalSince1970 ?? -1
        if let cached = referenceAudioSignatures[canonicalURL.path],
           cached.byteCount == byteCount,
           cached.modifiedAt == modifiedAt {
            return cached.signature
        }
        let digest = SHA256.hash(data: try Data(contentsOf: canonicalURL))
            .map { String(format: "%02x", $0) }
            .joined()
        let signature = "sha256=\(digest)|bytes=\(byteCount)"
        referenceAudioSignatures[canonicalURL.path] = QwenReferenceAudioSignatureCacheEntry(
            byteCount: byteCount,
            modifiedAt: modifiedAt,
            signature: signature
        )
        return signature
    }

    private func uvExecutableURL() -> URL? {
        let candidates =
            [
                binDirectory.appendingPathComponent("uv").path,
                "\(NSHomeDirectory())/.local/bin/uv",
                "/opt/homebrew/bin/uv",
                "/usr/local/bin/uv",
            ]
            + (ProcessInfo.processInfo.environment["PATH"] ?? "")
            .split(separator: ":")
            .map { String($0) + "/uv" }
        return candidates.first(where: { fileManager.isExecutableFile(atPath: $0) }).map(URL.init(fileURLWithPath:))
    }

    private func ensureUV(
        progress: (@Sendable (QwenInstallProgress) async -> Void)?,
        lane: QwenModelLane
    ) async throws {
        if uvExecutableURL() != nil {
            try await emit(.init(lane: lane, stage: "uv is ready", fractionCompleted: 0.15), progress)
            return
        }

        try await emit(.init(lane: lane, stage: "uv is required", fractionCompleted: 0.10), progress)
        throw QwenRuntimeError.setupRequired(
            "Install the verified uv command-line tool, then retry Qwen setup. Salient does not run remote installer scripts."
        )
    }

    private func ensurePythonEnvironment(
        progress: (@Sendable (QwenInstallProgress) async -> Void)?,
        lane: QwenModelLane
    ) async throws {
        guard let uv = uvExecutableURL() else {
            throw QwenRuntimeError.setupRequired("uv could not be installed for the managed Qwen runtime.")
        }

        let venvURL = runtimeRoot.appendingPathComponent("venv", isDirectory: true)
        if fileManager.isExecutableFile(atPath: managedPythonURL.path) {
            try await emit(.init(lane: lane, stage: "Python environment is ready", fractionCompleted: 0.30), progress)
        } else {
            if fileManager.fileExists(atPath: venvURL.path) {
                try fileManager.removeItem(at: venvURL)
            }

            try await emit(.init(lane: lane, stage: "Creating Python environment", fractionCompleted: 0.25), progress)
            try await runChecked(
                QwenShellCommand(
                    executable: uv.path,
                    arguments: ["venv", venvURL.path, "--python", "3.12", "--seed"],
                    environment: helperEnvironment,
                    redactedDescription: "create managed Python 3.12 environment"
                ))
        }

        if await mlxAudioImportWorks(), huggingFaceDownloadExecutableURL() != nil {
            try await emit(.init(lane: lane, stage: "MLX Audio is ready", fractionCompleted: 0.45), progress)
            return
        }

        try await emit(.init(lane: lane, stage: "Installing MLX Audio", fractionCompleted: 0.40), progress)
        try await runChecked(
            QwenShellCommand(
                executable: uv.path,
                arguments: [
                    "pip", "install",
                    "--python", managedPythonURL.path,
                    "mlx-audio[tts]==0.4.4",
                    "huggingface_hub[hf_xet]",
                    "numpy",
                    "soundfile",
                ],
                environment: helperEnvironment,
                redactedDescription: "install pinned MLX Audio and Hugging Face dependencies"
            ))
    }

    private func downloadModel(
        _ lane: QwenModelLane,
        useReferenceVoice: Bool,
        progress: (@Sendable (QwenInstallProgress) async -> Void)?
    ) async throws {
        try await emit(
            .init(lane: lane, stage: "Downloading \(lane.setupDisplayName(useReferenceVoice: useReferenceVoice))", fractionCompleted: 0.65),
            progress)
        let destination = modelInstallDirectory(for: lane, useReferenceVoice: useReferenceVoice)
        let stagingDirectory = modelRoot.appendingPathComponent(
            ".\(destination.lastPathComponent).\(UUID().uuidString).installing",
            isDirectory: true
        )
        defer { try? fileManager.removeItem(at: stagingDirectory) }
        try fileManager.createDirectory(at: stagingDirectory, withIntermediateDirectories: true)
        guard let huggingFaceCLI = huggingFaceDownloadExecutableURL() else {
            throw QwenRuntimeError.setupRequired("The managed Hugging Face downloader is missing. Retry Qwen setup to repair the runtime.")
        }
        let modelID = lane.modelID(useReferenceVoice: useReferenceVoice)
        try await runChecked(
            QwenShellCommand(
                executable: huggingFaceCLI.path,
                arguments: [
                    "download", modelID,
                    "--local-dir", stagingDirectory.path,
                ],
                environment: helperEnvironment,
                redactedDescription: "download \(modelID)"
            ))
        try writeModelInstallManifest(modelID: modelID, directory: stagingDirectory)
        installedModelValidationCache.removeValue(forKey: stagingDirectory.path)
        guard containsInstalledModelFiles(in: stagingDirectory) else {
            throw QwenRuntimeError.commandFailed("Downloaded Qwen package did not pass manifest verification.")
        }
        let synthesisLease = try await acquireSynthesisLease()
        defer { releaseSynthesisLease(synthesisLease) }
        await unloadResidentHelpers()
        try Task.checkCancellation()
        if fileManager.fileExists(atPath: destination.path) {
            _ = try fileManager.replaceItemAt(destination, withItemAt: stagingDirectory)
        } else {
            try fileManager.moveItem(at: stagingDirectory, to: destination)
        }
        installedModelValidationCache.removeValue(forKey: stagingDirectory.path)
        installedModelValidationCache.removeValue(forKey: destination.path)
    }

    private func writeModelInstallManifest(modelID: String, directory: URL) throws {
        let canonicalDirectory = directory.standardizedFileURL.resolvingSymlinksInPath()
        guard
            let enumerator = fileManager.enumerator(
                at: canonicalDirectory,
                includingPropertiesForKeys: [.isRegularFileKey, .fileSizeKey]
            )
        else {
            throw QwenRuntimeError.commandFailed("Downloaded Qwen package could not be verified.")
        }
        var files: [QwenModelInstallManifest.File] = []
        for case let url as URL in enumerator {
            guard !url.path.contains("/.cache/"), url.lastPathComponent != ".salient-model-manifest.json" else { continue }
            let values = try url.resourceValues(forKeys: [.isRegularFileKey, .fileSizeKey])
            guard values.isRegularFile == true, let fileSize = values.fileSize, fileSize > 0 else { continue }
            let canonicalURL = url.standardizedFileURL.resolvingSymlinksInPath()
            let prefix = canonicalDirectory.path + "/"
            guard canonicalURL.path.hasPrefix(prefix) else {
                throw QwenRuntimeError.commandFailed("Downloaded Qwen package contains an invalid file path.")
            }
            let relativePath = String(canonicalURL.path.dropFirst(prefix.count))
            files.append(.init(path: relativePath, byteCount: Int64(fileSize)))
        }
        let hasConfig = files.contains { $0.path.lowercased().hasSuffix("config.json") }
        let hasWeights = files.contains { $0.path.lowercased().hasSuffix(".safetensors") }
        guard hasConfig, hasWeights else {
            throw QwenRuntimeError.commandFailed("Downloaded Qwen package is missing its configuration or model weights.")
        }
        let manifest = QwenModelInstallManifest(modelID: modelID, files: files.sorted { $0.path < $1.path })
        let data = try JSONEncoder().encode(manifest)
        try data.write(to: canonicalDirectory.appendingPathComponent(".salient-model-manifest.json"), options: .atomic)
    }

    private func huggingFaceDownloadExecutableURL() -> URL? {
        let hf = runtimeRoot.appendingPathComponent("venv/bin/hf")
        if fileManager.isExecutableFile(atPath: hf.path) {
            return hf
        }

        let legacy = runtimeRoot.appendingPathComponent("venv/bin/huggingface-cli")
        if fileManager.isExecutableFile(atPath: legacy.path) {
            return legacy
        }

        return nil
    }

    private func mlxAudioImportWorks() async -> Bool {
        guard fileManager.isExecutableFile(atPath: managedPythonURL.path) else {
            return false
        }
        let command = QwenShellCommand(
            executable: managedPythonURL.path,
            arguments: ["-c", "import mlx_audio, huggingface_hub"],
            environment: helperEnvironment,
            redactedDescription: "check MLX Audio import"
        )
        do {
            let result = try await runner.run(command)
            return result.exitCode == 0
        } catch {
            return false
        }
    }

    private func runChecked(_ command: QwenShellCommand) async throws {
        try Task.checkCancellation()
        appendLog("start \(command.redactedDescription)")
        let result = try await runner.run(command)
        guard result.exitCode == 0 else {
            let message = [
                "\(command.redactedDescription) failed with status \(result.exitCode).",
                sanitizedTail(result.stderr.isEmpty ? result.stdout : result.stderr),
            ]
            .filter { !$0.isEmpty }
            .joined(separator: " ")
            appendLog("failed \(command.redactedDescription) status=\(result.exitCode)")
            throw QwenRuntimeError.commandFailed(message)
        }
        appendLog("ok \(command.redactedDescription)")
    }

    private func emit(
        _ update: QwenInstallProgress,
        _ progress: (@Sendable (QwenInstallProgress) async -> Void)?
    ) async throws {
        try Task.checkCancellation()
        appendLog("progress \(update.lane.rawValue) \(update.stage)")
        await progress?(update)
    }

    private func appendLog(_ message: String) {
        try? createRuntimeDirectories()
        let line = "\(ISO8601DateFormatter().string(from: Date())) \(message)\n"
        let url = logsDirectory.appendingPathComponent("qwen-runtime.log")
        if let data = line.data(using: .utf8) {
            if fileManager.fileExists(atPath: url.path),
                let handle = try? FileHandle(forWritingTo: url)
            {
                do {
                    try handle.seekToEnd()
                    try handle.write(contentsOf: data)
                    try handle.close()
                } catch {
                    try? handle.close()
                }
            } else {
                try? data.write(to: url)
            }
        }
    }

    private func sanitizedTail(_ output: String) -> String {
        output
            .split(separator: "\n")
            .suffix(8)
            .joined(separator: " ")
            .replacingOccurrences(of: temporaryDirectory.path, with: "<tmp>")
            .replacingOccurrences(of: cacheDirectory.path, with: "<cache>")
    }

    private func machineArchitecture() -> String {
        var systemInfo = utsname()
        uname(&systemInfo)
        let mirror = Mirror(reflecting: systemInfo.machine)
        return mirror.children.reduce(into: "") { result, element in
            guard let value = element.value as? Int8, value != 0 else { return }
            result.append(String(UnicodeScalar(UInt8(value))))
        }
    }
}

private enum QwenSynthesisPlan {
    case cached(QwenPreparedAudio)
    case pending(QwenPendingSynthesis)
}

private struct QwenPendingSynthesis: Sendable {
    var index: Int
    var request: QwenSynthesisRequest
    var modelURL: URL
    var referenceAudioURL: URL?
    var referenceAudioSignature: String
    var referenceText: String?
    var referenceTextURL: URL?
    var textURL: URL
    var rawURL: URL
    var outputURL: URL
    var removeAfterPlayback: Bool
}

private struct QwenResidentHelperRequest: Codable, Sendable {
    var id: String
    var mode: String?
    var streamingInterval: Double?
    var items: [QwenResidentHelperItem]

    init(
        id: String,
        mode: String? = nil,
        streamingInterval: Double? = nil,
        items: [QwenResidentHelperItem]
    ) {
        self.id = id
        self.mode = mode
        self.streamingInterval = streamingInterval
        self.items = items
    }

    enum CodingKeys: String, CodingKey {
        case id
        case mode
        case streamingInterval = "streaming_interval"
        case items
    }
}

private struct QwenResidentHelperItem: Codable, Sendable {
    var textFile: String
    var output: String
    var speaker: String
    var language: String
    var refAudio: String?
    var refTextFile: String?
    var itemIndex: Int?

    init(
        textFile: String,
        output: String,
        speaker: String,
        language: String,
        refAudio: String? = nil,
        refTextFile: String? = nil,
        itemIndex: Int? = nil
    ) {
        self.textFile = textFile
        self.output = output
        self.speaker = speaker
        self.language = language
        self.refAudio = refAudio
        self.refTextFile = refTextFile
        self.itemIndex = itemIndex
    }

    enum CodingKeys: String, CodingKey {
        case textFile = "text_file"
        case output
        case speaker
        case language
        case refAudio = "ref_audio"
        case refTextFile = "ref_text_file"
        case itemIndex = "item_index"
    }
}

private struct QwenResidentHelperResponse: Codable, Sendable {
    var id: String?
    var ok: Bool
    var event: String?
    var mode: String?
    var items: [QwenResidentHelperResponseItem]?
    var error: String?
    var processSeconds: Double?
    var modelLoadSeconds: Double?
}

private struct QwenResidentHelperResponseItem: Codable, Sendable {
    var output: String
    var bytes: Int?
}

private struct QwenResidentStreamingResponse: Codable, Sendable {
    var id: String?
    var requestID: String?
    var ok: Bool?
    var event: String?
    var error: String?
    var itemIndex: Int?
    var sequenceIndex: Int?
    var sampleRate: Double?
    var chunkDurationSeconds: Double?
    var audioBase64: String?
    var isFinalChunk: Bool?
    var elapsedSeconds: Double?
    var peakMemoryBytes: Int64?
    var mlxDevice: String?

    enum CodingKeys: String, CodingKey {
        case id
        case requestID = "request_id"
        case ok
        case event
        case error
        case itemIndex = "item_index"
        case sequenceIndex = "sequence_idx"
        case sampleRate = "sample_rate"
        case chunkDurationSeconds = "chunk_duration_seconds"
        case audioBase64 = "audio_b64"
        case isFinalChunk = "is_final_chunk"
        case elapsedSeconds = "elapsed_seconds"
        case peakMemoryBytes = "peak_mlx_memory_bytes"
        case mlxDevice = "mlx_device"
    }
}

private actor QwenResidentHelperSession {
    private let pythonURL: URL
    private let helperURL: URL
    private let modelURL: URL
    private let environment: [String: String]
    private var session: JSONLineProcessSession?
    private var requestOwner: UUID?
    private var requestWaiterOrder: [UUID] = []
    private var requestWaiters: [UUID: CheckedContinuation<UUID, Error>] = [:]
    private let encoder = JSONEncoder()

    init(
        pythonURL: URL,
        helperURL: URL,
        modelURL: URL,
        environment: [String: String]
    ) {
        self.pythonURL = pythonURL
        self.helperURL = helperURL
        self.modelURL = modelURL
        self.environment = environment
    }

    func isRunning() async -> Bool {
        guard let session else { return false }
        return await session.isRunning()
    }

    func synthesize(_ request: QwenResidentHelperRequest) async throws -> QwenResidentHelperResponse {
        try await sendAndRead(request)
    }

    func stream(
        _ request: QwenResidentHelperRequest,
        onChunk: @Sendable @escaping (QwenStreamingAudioChunk) async throws -> Void
    ) async throws {
        try await sendAndStream(request, onChunk: onChunk)
    }

    func stop() async {
        requestOwner = nil
        let waiting = Array(requestWaiters.values)
        requestWaiters.removeAll()
        requestWaiterOrder.removeAll()
        for continuation in waiting {
            continuation.resume(throwing: CancellationError())
        }
        let sessionToStop = session
        session = nil
        await sessionToStop?.stop()
    }

    private func sendAndRead(_ request: QwenResidentHelperRequest) async throws -> QwenResidentHelperResponse {
        try Task.checkCancellation()
        let requestLease = try await acquireRequestSlot()
        defer { releaseRequestSlot(requestLease) }
        return try await withTaskCancellationHandler {
            try Task.checkCancellation()
            try await startIfNeeded()
            guard let session else {
                throw QwenRuntimeError.commandFailed("Qwen resident helper is not connected.")
            }

            let data = try encoder.encode(request)
            let responseData: Data
            do {
                responseData = try await session.requestLine(data)
            } catch is CancellationError {
                throw CancellationError()
            } catch {
                throw QwenRuntimeError.commandFailed(error.localizedDescription)
            }

            let response: QwenResidentHelperResponse
            do {
                response = try JSONDecoder().decode(QwenResidentHelperResponse.self, from: responseData)
            } catch {
                await stopSession()
                throw QwenRuntimeError.commandFailed("Qwen resident helper returned invalid JSON.")
            }
            guard response.id == request.id else {
                await stopSession()
                throw QwenRuntimeError.commandFailed("Qwen resident helper returned an unexpected response.")
            }
            guard response.ok else {
                throw QwenRuntimeError.commandFailed(response.error ?? "Qwen resident helper failed.")
            }
            return response
        } onCancel: {
            Task {
                await self.cancelActiveRequest(requestLease)
            }
        }
    }

    private func sendAndStream(
        _ request: QwenResidentHelperRequest,
        onChunk: @Sendable @escaping (QwenStreamingAudioChunk) async throws -> Void
    ) async throws {
        try Task.checkCancellation()
        let requestLease = try await acquireRequestSlot()
        defer { releaseRequestSlot(requestLease) }
        try await withTaskCancellationHandler {
            try Task.checkCancellation()
            try await startIfNeeded()
            guard let session else {
                throw QwenRuntimeError.commandFailed("Qwen resident helper is not connected.")
            }

            let data = try encoder.encode(request)
            do {
                try await session.request(data) { line in
                let response: QwenResidentStreamingResponse
                do {
                    response = try JSONDecoder().decode(QwenResidentStreamingResponse.self, from: line)
                } catch {
                    throw QwenRuntimeError.commandFailed("Qwen resident helper returned invalid streaming JSON.")
                }
                guard response.id == request.id else {
                    throw QwenRuntimeError.commandFailed("Qwen resident helper returned an unexpected streaming response.")
                }
                guard response.ok != false else {
                    throw QwenRuntimeError.commandFailed(response.error ?? "Qwen resident helper streaming failed.")
                }
                switch response.event {
                case "audio_chunk":
                    guard let audioBase64 = response.audioBase64,
                        let audioData = Data(base64Encoded: audioBase64),
                        let itemIndex = response.itemIndex,
                        let sequenceIndex = response.sequenceIndex,
                        let sampleRate = response.sampleRate,
                        let durationSeconds = response.chunkDurationSeconds
                    else {
                        throw QwenRuntimeError.commandFailed("Qwen resident helper returned an incomplete audio chunk.")
                    }
                    try await onChunk(
                        QwenStreamingAudioChunk(
                            requestID: response.requestID ?? request.id,
                            itemIndex: itemIndex,
                            sequenceIndex: sequenceIndex,
                            sampleRate: sampleRate,
                            audioData: audioData,
                            durationSeconds: durationSeconds,
                            isFinal: response.isFinalChunk ?? false,
                            elapsedSeconds: response.elapsedSeconds,
                            peakMemoryBytes: response.peakMemoryBytes
                        ))
                    return .continueReading
                case "stream_done":
                    return .finish
                case "stream_start", "stream_item_done":
                    return .continueReading
                case "stream_error":
                    throw QwenRuntimeError.commandFailed(response.error ?? "Qwen resident helper streaming failed.")
                default:
                    return .continueReading
                }
                }
            } catch let error as QwenRuntimeError {
                throw error
            } catch is CancellationError {
                throw CancellationError()
            } catch {
                throw QwenRuntimeError.commandFailed(error.localizedDescription)
            }
        } onCancel: {
            Task {
                await self.cancelActiveRequest(requestLease)
            }
        }
    }

    private func acquireRequestSlot() async throws -> UUID {
        try Task.checkCancellation()
        let leaseID = UUID()
        if requestOwner == nil {
            requestOwner = leaseID
            return leaseID
        }

        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                if Task.isCancelled {
                    continuation.resume(throwing: CancellationError())
                } else {
                    requestWaiterOrder.append(leaseID)
                    requestWaiters[leaseID] = continuation
                }
            }
        } onCancel: {
            Task {
                await self.cancelRequestWaiter(leaseID)
            }
        }
    }

    private func releaseRequestSlot(_ leaseID: UUID) {
        guard requestOwner == leaseID else { return }
        while let nextLeaseID = requestWaiterOrder.first {
            requestWaiterOrder.removeFirst()
            guard let continuation = requestWaiters.removeValue(forKey: nextLeaseID) else {
                continue
            }
            requestOwner = nextLeaseID
            continuation.resume(returning: nextLeaseID)
            return
        }
        requestOwner = nil
    }

    private func cancelRequestWaiter(_ leaseID: UUID) {
        guard let continuation = requestWaiters.removeValue(forKey: leaseID) else { return }
        requestWaiterOrder.removeAll { $0 == leaseID }
        continuation.resume(throwing: CancellationError())
    }

    private func cancelActiveRequest(_ leaseID: UUID) async {
        guard requestOwner == leaseID else { return }
        await stopSession()
    }

    private func stopSession() async {
        let sessionToStop = session
        session = nil
        await sessionToStop?.stop()
    }

    private func startIfNeeded() async throws {
        if let session, await session.isRunning() {
            return
        }
        await stopSession()

        let session = JSONLineProcessSession(
            configuration: JSONLineProcessConfiguration(
                executableURL: pythonURL,
                arguments: [
                    helperURL.path,
                    "serve",
                    "--model", modelURL.path,
                ],
                environment: environment,
                startupTimeoutSeconds: 300,
                requestTimeoutSeconds: 900,
                maximumLineBytes: 67_108_864,
                redactedDescription: "Qwen resident helper"
            ))
        self.session = session
        do {
            guard let readyData = try await session.start() else {
                throw QwenRuntimeError.commandFailed("Qwen resident helper did not emit a ready response.")
            }
            let ready = try JSONDecoder().decode(QwenResidentHelperResponse.self, from: readyData)
            guard ready.ok, ready.event == "ready" else {
                throw QwenRuntimeError.commandFailed(ready.error ?? "Qwen resident helper did not become ready.")
            }
        } catch let error as QwenRuntimeError {
            await session.stop()
            if self.session === session {
                self.session = nil
            }
            throw error
        } catch {
            await session.stop()
            if self.session === session {
                self.session = nil
            }
            throw QwenRuntimeError.commandFailed(error.localizedDescription)
        }
        guard self.session === session else {
            await session.stop()
            throw CancellationError()
        }
    }
}

private struct CacheMaintenanceState: Codable {
    var lastClearedAt: Date
}

private struct QwenReferenceAudioSignatureCacheEntry {
    var byteCount: Int64
    var modifiedAt: TimeInterval
    var signature: String
}

private struct QwenInstalledModelValidationCacheEntry {
    var fingerprint: String
    var isInstalled: Bool
}

private struct QwenModelInstallManifest: Codable {
    struct File: Codable {
        var path: String
        var byteCount: Int64
    }

    var modelID: String
    var files: [File]
}
