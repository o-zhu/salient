import AVFoundation
import Foundation

protocol PlaybackAudioMetering {
    var numberOfChannels: Int { get }
    func averagePower(forChannel channelNumber: Int) -> Float
}

extension AVAudioPlayer: PlaybackAudioMetering {}

private let qwenVisualizationFrameInterval = 1.0 / 60.0
private let qwenPlaybackProgressPollInterval = 1.0 / 120.0
private let qwenVisualizationDispatchInterval = 1.0 / 60.0
private let qwenVisualizationPostAudioDecayTimeConstant = 0.075
private let qwenSpectralVisualizationMaxQueuedItemCount = 3
private let qwenSpectralVisualizationMaxQueuedDurationSeconds = 12.0
private let qwenStreamingPlaybackPollNanoseconds: UInt64 = 10_000_000

private final class QwenVisualizationFrameCache: @unchecked Sendable {
    private let lock = NSLock()
    private let analysisQueue = DispatchQueue(
        label: "com.salient.qwen-visualization-analysis",
        qos: .utility
    )
    private var framesByPath: [String: [SpeechPlaybackVisualizationFrame]] = [:]
    private var pathsInFlight: [String: Int] = [:]
    private var insertionOrder: [String] = []
    private var generation = 0
    private let maximumEntryCount = 64
    private let frameLoader: @Sendable (URL) -> [SpeechPlaybackVisualizationFrame]?

    init(
        frameLoader: @escaping @Sendable (URL) -> [SpeechPlaybackVisualizationFrame]? = { url in
            try? QwenAudioPlayback.estimatedFastSpectrumVisualizationFrames(fromAudioAt: url)
        }
    ) {
        self.frameLoader = frameLoader
    }

    func frames(for url: URL) -> [SpeechPlaybackVisualizationFrame]? {
        lock.lock()
        defer { lock.unlock() }
        return framesByPath[url.path]
    }

    func prewarm(_ audio: QwenPreparedAudio) {
        let path = audio.url.path
        lock.lock()
        let taskGeneration = generation
        let shouldStart = framesByPath[path] == nil && pathsInFlight[path] == nil
        if shouldStart {
            pathsInFlight[path] = taskGeneration
        }
        lock.unlock()
        guard shouldStart else { return }

        analysisQueue.async { [weak self, frameLoader] in
            guard self?.shouldAnalyze(path: path, generation: taskGeneration) == true else {
                return
            }
            let frames = frameLoader(audio.url)
            self?.finish(path: path, generation: taskGeneration, frames: frames)
        }
    }

    func clear() {
        lock.lock()
        generation &+= 1
        framesByPath.removeAll()
        pathsInFlight.removeAll()
        insertionOrder.removeAll()
        lock.unlock()
    }

    private func shouldAnalyze(path: String, generation: Int) -> Bool {
        lock.lock()
        defer { lock.unlock() }
        return self.generation == generation && pathsInFlight[path] == generation
    }

    private func finish(
        path: String,
        generation: Int,
        frames: [SpeechPlaybackVisualizationFrame]?
    ) {
        lock.lock()
        defer { lock.unlock() }
        if pathsInFlight[path] == generation {
            pathsInFlight.removeValue(forKey: path)
        }
        guard self.generation == generation else { return }
        guard let frames, !frames.isEmpty else { return }
        framesByPath[path] = frames
        insertionOrder.removeAll { $0 == path }
        insertionOrder.append(path)
        while insertionOrder.count > maximumEntryCount {
            framesByPath.removeValue(forKey: insertionOrder.removeFirst())
        }
    }
}

private final class QwenQueuedAudioFileCache: @unchecked Sendable {
    private let lock = NSLock()
    private let preparationQueue = DispatchQueue(
        label: "com.salient.qwen-playback-file-preparation",
        qos: .userInitiated
    )
    private var filesByPath: [String: AVAudioFile] = [:]
    private var pathsInFlight: Set<String> = []
    private var pathsToDiscardWhenReady: Set<String> = []
    private var insertionOrder: [String] = []
    private let maximumEntryCount = 16

    func prewarm(_ audio: QwenPreparedAudio) {
        let path = audio.url.path
        lock.lock()
        let shouldStart = filesByPath[path] == nil && pathsInFlight.insert(path).inserted
        lock.unlock()
        guard shouldStart else { return }

        preparationQueue.async { [weak self] in
            let file = try? AVAudioFile(forReading: audio.url)
            self?.finish(path: path, file: file)
        }
    }

    func take(for url: URL) -> AVAudioFile? {
        let path = url.path
        lock.lock()
        defer { lock.unlock() }
        if let file = filesByPath.removeValue(forKey: path) {
            insertionOrder.removeAll { $0 == path }
            file.framePosition = 0
            return file
        }
        if pathsInFlight.contains(path) {
            pathsToDiscardWhenReady.insert(path)
        }
        return nil
    }

    func clear() {
        lock.lock()
        filesByPath.removeAll()
        insertionOrder.removeAll()
        pathsToDiscardWhenReady.formUnion(pathsInFlight)
        lock.unlock()
    }

    private func finish(path: String, file: AVAudioFile?) {
        lock.lock()
        defer { lock.unlock() }
        pathsInFlight.remove(path)
        if pathsToDiscardWhenReady.remove(path) != nil {
            return
        }
        guard let file else { return }
        filesByPath[path] = file
        insertionOrder.removeAll { $0 == path }
        insertionOrder.append(path)
        while insertionOrder.count > maximumEntryCount {
            filesByPath.removeValue(forKey: insertionOrder.removeFirst())
        }
    }
}

@MainActor
public final class QwenAudioPlayback: NSObject, @preconcurrency AVAudioPlayerDelegate {
    public weak var visualizationSink: (any SpeechPlaybackVisualizationSink)?
    public weak var timingSink: (any SpeechPlaybackTimingSink)?

    private var player: AVAudioPlayer?
    private var engine: AVAudioEngine?
    private var playerNode: AVAudioPlayerNode?
    private var rateProcessor: AVAudioUnit?
    private var streamingEngineFormat: AVAudioFormat?
    private var streamingEngineRate: Double?
    private var playbackToken: UUID?
    private var continuation: CheckedContinuation<Void, Error>?
    private var boundaryTask: Task<Void, Never>?
    private var meteringTask: Task<Void, Never>?
    private var queuedAudioFiles: [AVAudioFile] = []
    private var queuedTemporaryAudioURLs: [URL] = []
    private var streamingPlaybackDurations: [Double] = []
    private var streamingMeterFrames: [[SpeechPlaybackVisualizationFrame]] = []
    private var streamingScheduledBufferCount = 0
    private var streamingPlayedBufferCount = 0
    private var performanceEvents: [QwenPlaybackPerformanceEvent] = []
    private let visualizationFrameCache: QwenVisualizationFrameCache
    private let queuedAudioFileCache = QwenQueuedAudioFileCache()
    private var visualizationAudioSessionIsActive = false
    private var completeFileCallbackToken: UUID?
    private var completeFileCallbackTasks: [Task<Void, Never>] = []

    public override init() {
        visualizationFrameCache = QwenVisualizationFrameCache()
        super.init()
    }

    init(
        visualizationFrameLoader: @escaping @Sendable (URL) -> [SpeechPlaybackVisualizationFrame]?
    ) {
        visualizationFrameCache = QwenVisualizationFrameCache(frameLoader: visualizationFrameLoader)
        super.init()
    }

    func prewarmVisualization(for audio: QwenPreparedAudio) {
        guard visualizationSink != nil else { return }
        visualizationFrameCache.prewarm(audio)
    }

    func finishNarration() {
        meteringTask?.cancel()
        meteringTask = nil
        cancelCompleteFileCallbacks()
        if visualizationAudioSessionIsActive {
            visualizationSink?.speechPlaybackVisualizationAudioDidStop()
            visualizationAudioSessionIsActive = false
        }
        resetQueuedPlayback()
        visualizationFrameCache.clear()
        queuedAudioFileCache.clear()
    }

    public func play(url: URL, rateMultiplier: Double, volume: Double) async throws {
        let item = SpeechPlaybackItem(
            id: url.lastPathComponent,
            segmentID: url.lastPathComponent,
            text: ""
        )
        let prepared = QwenPreparedPlaybackItem(
            index: 0,
            item: item,
            audio: QwenPreparedAudio(
                url: url,
                durationSeconds: QwenAudioPostProcessor.durationSeconds(of: url) ?? 0,
                isFromCache: false
            )
        )
        try await play(
            [prepared],
            rateMultiplier: rateMultiplier,
            volume: volume,
            onStartItem: { _ in },
            onBufferEnqueue: { _ in },
            onRenderStart: {},
            onFinish: {}
        )
    }

    func play(
        _ items: [QwenPreparedPlaybackItem],
        rateMultiplier: Double,
        volume: Double,
        onStartItem: @escaping @MainActor @Sendable (SpeechPlaybackItem) async -> Void
    ) async throws {
        try await play(
            items,
            rateMultiplier: rateMultiplier,
            volume: volume,
            onStartItem: onStartItem,
            onBufferEnqueue: { _ in },
            onRenderStart: {},
            onFinish: {}
        )
    }

    func play(
        _ items: [QwenPreparedPlaybackItem],
        rateMultiplier: Double,
        volume: Double,
        onStartItem: @escaping @MainActor @Sendable (SpeechPlaybackItem) async -> Void,
        onBufferEnqueue: @escaping @MainActor @Sendable (SpeechPlaybackItem) async -> Void,
        onRenderStart: @escaping @MainActor @Sendable () async -> Void,
        onFinish: @escaping @MainActor @Sendable () async -> Void
    ) async throws {
        try await play(
            items,
            rateMultiplier: rateMultiplier,
            volume: volume,
            onStartItem: onStartItem,
            onBufferEnqueue: onBufferEnqueue,
            onRenderStart: onRenderStart,
            onFinish: onFinish,
            onItemEnd: { _ in }
        )
    }

    func play(
        _ items: [QwenPreparedPlaybackItem],
        rateMultiplier: Double,
        volume: Double,
        onStartItem: @escaping @MainActor @Sendable (SpeechPlaybackItem) async -> Void,
        onBufferEnqueue: @escaping @MainActor @Sendable (SpeechPlaybackItem) async -> Void,
        onRenderStart: @escaping @MainActor @Sendable () async -> Void,
        onFinish: @escaping @MainActor @Sendable () async -> Void,
        onItemEnd: @escaping @MainActor @Sendable (SpeechPlaybackItem) async -> Void
    ) async throws {
        try Task.checkCancellation()
        guard !items.isEmpty else { return }
        let playbackRate = Self.completeFilePlaybackRate(for: rateMultiplier)
        let playbackVolume = Float(min(max(volume, 0.0), 1.0))
        var queued: [PreparedAVAudioPlayer]
        do {
            queued = try prepareAVAudioPlayers(
                items,
                rate: playbackRate,
                volume: playbackVolume
            )
            try Task.checkCancellation()
        } catch {
            removeTemporaryAudioFiles(in: items)
            throw error
        }
        if playbackToken != nil || player != nil || continuation != nil {
            stop()
        }
        let playbackID = UUID()
        playbackToken = playbackID
        beginCompleteFileCallbacks(playbackToken: playbackID)
        var didCompletePlayback = false
        defer {
            for entry in queued {
                entry.player.stop()
                entry.player.delegate = nil
            }
            queued.removeAll(keepingCapacity: false)
            if self.playbackToken == playbackID {
                self.playbackToken = nil
            }
            if didCompletePlayback {
                clearCompleteFileCallbacks(playbackToken: playbackID)
            } else {
                cancelCompleteFileCallbacks(playbackToken: playbackID)
            }
            removeTemporaryAudioFiles(in: items)
        }

        try await withTaskCancellationHandler {
            var callbackTasks: [Task<Void, Never>] = []
            var didNotifyRenderStart = false
            for entry in queued {
                try ensureCompleteFilePlaybackIsActive(playbackID)
                await onBufferEnqueue(entry.item.item)
                try ensureCompleteFilePlaybackIsActive(playbackID)
            }
            for entry in queued {
                try ensureCompleteFilePlaybackIsActive(playbackID)
                let callbackItem = entry.item.item
                let startTask = Task { @MainActor [weak self] in
                    guard !Task.isCancelled,
                          self?.playbackToken == playbackID else {
                        return
                    }
                    await onStartItem(callbackItem)
                }
                callbackTasks.append(startTask)
                registerCompleteFileCallback(startTask, playbackToken: playbackID)
                if !didNotifyRenderStart {
                    await onRenderStart()
                    try ensureCompleteFilePlaybackIsActive(playbackID)
                    didNotifyRenderStart = true
                }
                try await playPreparedAVAudioPlayer(
                    entry,
                    playbackID: playbackID,
                    rate: playbackRate
                )
                try ensureCompleteFilePlaybackIsActive(playbackID)
                let endTask = Task { @MainActor [weak self] in
                    await startTask.value
                    guard !Task.isCancelled,
                          self?.playbackToken == playbackID else {
                        return
                    }
                    await onItemEnd(callbackItem)
                }
                callbackTasks.append(endTask)
                registerCompleteFileCallback(endTask, playbackToken: playbackID)
            }
            for task in callbackTasks {
                try ensureCompleteFilePlaybackIsActive(playbackID)
                await task.value
            }
            try ensureCompleteFilePlaybackIsActive(playbackID)
            await onFinish()
            try ensureCompleteFilePlaybackIsActive(playbackID)
            didCompletePlayback = true
        } onCancel: {
            Task { @MainActor in
                guard self.playbackToken == playbackID else { return }
                self.stop()
            }
        }
    }

    func playStream(
        item: SpeechPlaybackItem,
        chunks: AsyncThrowingStream<QwenStreamingAudioChunk, Error>,
        rateMultiplier: Double,
        volume: Double,
        minimumBufferedPlaybackSeconds: Double,
        targetRunwayPlaybackSeconds: Double,
        onStartItem: @escaping @MainActor @Sendable (SpeechPlaybackItem) async -> Void,
        onBufferEnqueue: @escaping @MainActor @Sendable (SpeechPlaybackItem) async -> Void,
        onRenderStart: @escaping @MainActor @Sendable () async -> Void,
        onFinish: @escaping @MainActor @Sendable () async -> Void,
        onItemEnd: @escaping @MainActor @Sendable (SpeechPlaybackItem) async -> Void
    ) async throws {
        try Task.checkCancellation()
        let playbackRate = min(max(rateMultiplier, 0.5), 2.4)
        let playbackVolume = Float(min(max(volume, 0.0), 1.0))
        let playbackToken = UUID()
        let startThreshold = min(
            max(0.05, minimumBufferedPlaybackSeconds),
            max(0.05, targetRunwayPlaybackSeconds)
        )

        try await withTaskCancellationHandler {
            resetQueuedPlayback(preserveStreamingEngine: true)
            self.playbackToken = playbackToken
            streamingPlaybackDurations.removeAll()
            streamingScheduledBufferCount = 0
            streamingPlayedBufferCount = 0
            performanceEvents.removeAll(keepingCapacity: true)

            var pendingBuffers: [StreamingPlaybackBuffer] = []
            var expectedFormat: AVAudioFormat?
            var didStartPlayback = false
            var didEnqueueFirstBuffer = false
            var receivedFinalChunk = false
            var isRebuffering = false

            do {
                for try await chunk in chunks {
                    try Task.checkCancellation()
                    guard self.playbackToken == playbackToken else { throw CancellationError() }
                    if chunk.isFinal {
                        receivedFinalChunk = true
                    }
                    guard let streamingBuffer = try await Task.detached(priority: .userInitiated, operation: {
                        try Self.streamingBuffer(from: chunk, expectedFormat: nil)
                    }).value else {
                        if receivedFinalChunk {
                            break
                        }
                        continue
                    }
                    guard self.playbackToken == playbackToken else { throw CancellationError() }
                    if let expectedFormat,
                       !Self.formatsAreCompatible(streamingBuffer.buffer.format, expectedFormat) {
                        throw QwenRuntimeError.commandFailed("Qwen streaming chunks use incompatible PCM formats.")
                    }
                    if expectedFormat == nil {
                        expectedFormat = streamingBuffer.buffer.format
                        try configureStreamingPlaybackEngine(
                            format: streamingBuffer.buffer.format,
                            rate: playbackRate,
                            volume: playbackVolume
                        )
                    }
                    if !didEnqueueFirstBuffer {
                        await onBufferEnqueue(item)
                        didEnqueueFirstBuffer = true
                    }

                    if didStartPlayback {
                        let queueDrained = streamingPlayedBufferCount >= streamingScheduledBufferCount
                        if isRebuffering || queueDrained {
                            if !isRebuffering {
                                performanceEvents.append(.init(kind: .underrun, runwaySeconds: 0))
                                isRebuffering = true
                            }
                            pendingBuffers.append(streamingBuffer)
                            let pendingPlaybackDuration = pendingBuffers
                                .map(\.durationSeconds)
                                .reduce(0, +) / playbackRate
                            if pendingPlaybackDuration >= 0.25 || receivedFinalChunk {
                                for buffer in pendingBuffers {
                                    scheduleStreamingBuffer(buffer, playbackToken: playbackToken)
                                }
                                pendingBuffers.removeAll()
                                playerNode?.play()
                                performanceEvents.append(.init(
                                    kind: .rebuffer,
                                    runwaySeconds: pendingPlaybackDuration
                                ))
                                isRebuffering = false
                            }
                        } else {
                            scheduleStreamingBuffer(streamingBuffer, playbackToken: playbackToken)
                        }
                    } else {
                        pendingBuffers.append(streamingBuffer)
                        let pendingPlaybackDuration =
                            pendingBuffers
                            .map(\.durationSeconds)
                            .reduce(0, +) / playbackRate
                        if pendingPlaybackDuration >= startThreshold || receivedFinalChunk {
                            for buffer in pendingBuffers {
                                scheduleStreamingBuffer(buffer, playbackToken: playbackToken)
                            }
                            pendingBuffers.removeAll()
                            try await startStreamingPlayback(
                                playbackToken: playbackToken,
                                item: item,
                                rate: playbackRate,
                                onStartItem: onStartItem,
                                onRenderStart: onRenderStart
                            )
                            didStartPlayback = true
                        }
                    }
                    if receivedFinalChunk {
                        break
                    }
                }

                if didStartPlayback, !pendingBuffers.isEmpty {
                    let pendingPlaybackDuration = pendingBuffers
                        .map(\.durationSeconds)
                        .reduce(0, +) / playbackRate
                    for buffer in pendingBuffers {
                        scheduleStreamingBuffer(buffer, playbackToken: playbackToken)
                    }
                    pendingBuffers.removeAll()
                    playerNode?.play()
                    performanceEvents.append(.init(
                        kind: .rebuffer,
                        runwaySeconds: pendingPlaybackDuration
                    ))
                }

                if !didStartPlayback, !pendingBuffers.isEmpty {
                    for buffer in pendingBuffers {
                        scheduleStreamingBuffer(buffer, playbackToken: playbackToken)
                    }
                    pendingBuffers.removeAll()
                    try await startStreamingPlayback(
                        playbackToken: playbackToken,
                        item: item,
                        rate: playbackRate,
                        onStartItem: onStartItem,
                        onRenderStart: onRenderStart
                    )
                    didStartPlayback = true
                }

                guard didStartPlayback, streamingScheduledBufferCount > 0 else {
                    throw QwenRuntimeError.commandFailed("Qwen streaming audio produced no playable chunks.")
                }

                while playbackToken == self.playbackToken,
                    streamingPlayedBufferCount < streamingScheduledBufferCount
                {
                    try Task.checkCancellation()
                    try await Task.sleep(nanoseconds: qwenStreamingPlaybackPollNanoseconds)
                }

                guard playbackToken == self.playbackToken else { throw CancellationError() }
                await onItemEnd(item)
                meteringTask?.cancel()
                meteringTask = nil
                resetQueuedPlayback(preserveStreamingEngine: true)
                startInterBatchVisualizationDecay()
                await onFinish()
            } catch {
                if self.playbackToken == playbackToken { resetQueuedPlayback() }
                throw error
            }
        } onCancel: {
            Task { @MainActor in
                guard self.playbackToken == playbackToken else { return }
                self.stop()
            }
        }
    }

    private func playChunk(
        _ chunk: DecodedPlaybackChunk,
        playbackID: UUID,
        rate: Double,
        volume: Float
    ) async throws {
        guard let player = try? AVAudioPlayer(contentsOf: chunk.item.audio.url) else {
            throw QwenRuntimeError.commandFailed("Could not prepare Qwen audio chunk.")
        }
        player.prepareToPlay()
        player.enableRate = true
        player.rate = Float(rate)
        player.volume = volume
        player.isMeteringEnabled = true

        self.player = player
        if !player.play() {
            self.player = nil
            throw QwenRuntimeError.commandFailed("Could not start Qwen audio playback.")
        }
        emitInitialVisualizationFrame(
            meterFrames: [chunk.meterFrames],
            durations: [chunk.durationSeconds],
            rate: rate
        )
        SalientSignposts.event(.firstAudio)
        if !visualizationAudioSessionIsActive {
            visualizationSink?.speechPlaybackVisualizationAudioDidStart()
            visualizationAudioSessionIsActive = true
        }
        startFileMetering([chunk], playbackID: playbackID, rate: rate)
        while player.isPlaying {
            try Task.checkCancellation()
            try await Task.sleep(nanoseconds: 20_000_000)
        }
        self.player = nil
    }

    nonisolated static func completeFilePlaybackRate(for requestedRate: Double) -> Double {
        guard requestedRate.isFinite else { return 1.0 }
        return min(max(requestedRate, 0.5), 2.0)
    }

    func effectiveCompleteFilePlaybackRate(for requestedRate: Double) -> Double {
        Self.completeFilePlaybackRate(for: requestedRate)
    }

    private func ensureCompleteFilePlaybackIsActive(_ playbackID: UUID) throws {
        try Task.checkCancellation()
        guard playbackToken == playbackID else { throw CancellationError() }
    }

    private func beginCompleteFileCallbacks(playbackToken: UUID) {
        cancelCompleteFileCallbacks()
        completeFileCallbackToken = playbackToken
    }

    private func registerCompleteFileCallback(
        _ task: Task<Void, Never>,
        playbackToken: UUID
    ) {
        guard completeFileCallbackToken == playbackToken else {
            task.cancel()
            return
        }
        completeFileCallbackTasks.append(task)
    }

    private func clearCompleteFileCallbacks(playbackToken: UUID) {
        guard completeFileCallbackToken == playbackToken else { return }
        completeFileCallbackTasks.removeAll(keepingCapacity: false)
        completeFileCallbackToken = nil
    }

    private func cancelCompleteFileCallbacks(playbackToken: UUID? = nil) {
        if let playbackToken,
           completeFileCallbackToken != playbackToken {
            return
        }
        completeFileCallbackTasks.forEach { $0.cancel() }
        completeFileCallbackTasks.removeAll(keepingCapacity: false)
        completeFileCallbackToken = nil
    }

    private func playPreparedAVAudioPlayer(
        _ entry: PreparedAVAudioPlayer,
        playbackID: UUID,
        rate: Double
    ) async throws {
        try ensureCompleteFilePlaybackIsActive(playbackID)
        let player = entry.player
        player.delegate = self
        self.player = player

        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            guard self.continuation == nil else {
                player.delegate = nil
                self.player = nil
                continuation.resume(
                    throwing: QwenRuntimeError.commandFailed("Qwen audio playback was already active.")
                )
                return
            }
            guard self.playbackToken == playbackID, !Task.isCancelled else {
                player.delegate = nil
                self.player = nil
                continuation.resume(throwing: CancellationError())
                return
            }
            self.continuation = continuation
            guard player.play() else {
                self.continuation = nil
                player.delegate = nil
                self.player = nil
                continuation.resume(
                    throwing: QwenRuntimeError.commandFailed("Could not start Qwen audio playback.")
                )
                return
            }

            emitInitialVisualizationFrame(
                meterFrames: [entry.meterFrames],
                durations: [entry.durationSeconds],
                rate: rate
            )
            SalientSignposts.event(.firstAudio)
            if !visualizationAudioSessionIsActive {
                visualizationSink?.speechPlaybackVisualizationAudioDidStart()
                visualizationAudioSessionIsActive = true
            }
            startFileMetering(entry, playbackID: playbackID, rate: rate)
            startCompleteFilePlaybackWatchdog(
                entry,
                playbackID: playbackID,
                rate: rate
            )
        }
        try ensureCompleteFilePlaybackIsActive(playbackID)
    }

    private func startCompleteFilePlaybackWatchdog(
        _ entry: PreparedAVAudioPlayer,
        playbackID: UUID,
        rate: Double
    ) {
        boundaryTask?.cancel()
        let expectedPlaybackSeconds = max(0, entry.durationSeconds) / max(0.5, rate)
        let watchdogSeconds = max(0.5, expectedPlaybackSeconds + 1.0)
        boundaryTask = Task { @MainActor [weak self, weak player = entry.player] in
            do {
                try await Task.sleep(for: .seconds(watchdogSeconds))
            } catch {
                return
            }
            guard let self,
                  let player,
                  self.playbackToken == playbackID,
                  self.player === player else {
                return
            }
            player.delegate = nil
            player.stop()
            self.player = nil
            self.meteringTask?.cancel()
            self.meteringTask = nil
            self.boundaryTask = nil
            let continuation = self.continuation
            self.continuation = nil
            continuation?.resume(
                throwing: QwenRuntimeError.commandFailed(
                    "Qwen audio playback exceeded its expected duration."
                )
            )
        }
    }

    private func prepareAVAudioPlayers(
        _ items: [QwenPreparedPlaybackItem],
        rate: Double,
        volume: Float
    ) throws -> [PreparedAVAudioPlayer] {
        try items.map { item in
            let player = try AVAudioPlayer(contentsOf: item.audio.url)
            player.enableRate = true
            player.rate = Float(rate)
            player.volume = volume
            player.isMeteringEnabled = true
            guard player.prepareToPlay() else {
                throw QwenRuntimeError.commandFailed("Could not prepare Qwen audio playback.")
            }
            let duration = item.audio.durationSeconds > 0
                ? item.audio.durationSeconds
                : player.duration
            let cachedFrames = visualizationFrameCache.frames(for: item.audio.url)
            if visualizationSink != nil, cachedFrames == nil {
                visualizationFrameCache.prewarm(item.audio)
            }
            return PreparedAVAudioPlayer(
                item: item,
                player: player,
                durationSeconds: duration,
                meterFrames: cachedFrames ?? []
            )
        }
    }

    private func startFileMetering(
        _ entry: PreparedAVAudioPlayer,
        playbackID: UUID,
        rate: Double
    ) {
        startMetering(
            meterFrames: [entry.meterFrames],
            durations: [entry.durationSeconds],
            items: [entry.item],
            playbackID: playbackID,
            rate: rate,
            timeProvider: { [weak player = entry.player] startedAt in
                guard let player else { return nil }
                return (
                    audioElapsedSeconds: player.currentTime,
                    playbackElapsedSeconds: Date().timeIntervalSince(startedAt)
                )
            },
            isPlaying: { [weak player = entry.player] in
                player?.isPlaying == true
            }
        )
    }

    public func stop() {
        boundaryTask?.cancel()
        boundaryTask = nil
        meteringTask?.cancel()
        meteringTask = nil
        cancelCompleteFileCallbacks()
        let activePlayer = player
        activePlayer?.delegate = nil
        activePlayer?.stop()
        player = nil
        let continuation = continuation
        self.continuation = nil
        playerNode?.stop()
        engine?.stop()
        resetQueuedPlayback()
        visualizationFrameCache.clear()
        queuedAudioFileCache.clear()
        if visualizationAudioSessionIsActive {
            visualizationSink?.speechPlaybackVisualizationAudioDidStop()
            visualizationAudioSessionIsActive = false
        }
        self.playbackToken = nil
        continuation?.resume(throwing: CancellationError())
    }

    func consumePerformanceEvents() -> [QwenPlaybackPerformanceEvent] {
        let events = performanceEvents
        performanceEvents.removeAll(keepingCapacity: true)
        return events
    }

    public func audioPlayerDidFinishPlaying(_ player: AVAudioPlayer, successfully flag: Bool) {
        guard self.player === player else { return }
        boundaryTask?.cancel()
        boundaryTask = nil
        meteringTask?.cancel()
        meteringTask = nil
        self.player = nil
        player.delegate = nil
        let continuation = continuation
        self.continuation = nil
        if flag {
            continuation?.resume()
        } else {
            continuation?.resume(throwing: QwenRuntimeError.commandFailed("Qwen audio playback stopped unexpectedly."))
        }
    }

    public func audioPlayerDecodeErrorDidOccur(_ player: AVAudioPlayer, error: (any Error)?) {
        guard self.player === player else { return }
        boundaryTask?.cancel()
        boundaryTask = nil
        meteringTask?.cancel()
        meteringTask = nil
        self.player = nil
        player.delegate = nil
        let continuation = continuation
        self.continuation = nil
        continuation?.resume(throwing: error ?? QwenRuntimeError.commandFailed("Could not decode Qwen audio."))
    }

    private func startMetering(_ player: AVAudioPlayer) {
        meteringTask?.cancel()
        meteringTask = Task { @MainActor [weak self, weak player] in
            while !Task.isCancelled,
                let self,
                let player,
                self.player === player,
                player.isPlaying
            {
                player.updateMeters()
                let level = Self.normalizedLevel(from: player)
                self.visualizationSink?.speechPlaybackVisualizationFrameDidChange(.levelOnly(level))
                try? await Task.sleep(nanoseconds: 50_000_000)
            }
        }
    }

    private func startQueuedPlayback(
        playbackToken: UUID,
        _ decoded: [DecodedPlaybackChunk],
        rate: Double,
        volume: Float,
        continuation: CheckedContinuation<Void, Error>,
        onStartItem: @escaping @MainActor @Sendable (SpeechPlaybackItem) async -> Void,
        onBufferEnqueue: @escaping @MainActor @Sendable (SpeechPlaybackItem) async -> Void,
        onRenderStart: @escaping @MainActor @Sendable () async -> Void,
        onFinish: @escaping @MainActor @Sendable () async -> Void,
        onItemEnd: @escaping @MainActor @Sendable (SpeechPlaybackItem) async -> Void
    ) throws {
        resetQueuedPlayback()
        self.playbackToken = playbackToken
        self.continuation = continuation

        let engine = AVAudioEngine()
        let playerNode = AVAudioPlayerNode()
        let rateProcessor = Self.makeRateProcessor(rateMultiplier: rate)
        playerNode.volume = volume

        engine.attach(playerNode)
        engine.attach(rateProcessor)
        let playbackFormat = decoded[0].buffer.format
        engine.connect(playerNode, to: rateProcessor, format: playbackFormat)
        // Route through the main mixer so Core Audio owns the conversion from
        // 24 kHz mono synthesis to the hardware/Loopback device format. A
        // direct output-node connection can expose render-block discontinuities.
        engine.connect(rateProcessor, to: engine.mainMixerNode, format: playbackFormat)

        self.engine = engine
        self.playerNode = playerNode
        self.rateProcessor = rateProcessor

        let maxExpectedPlaybackSeconds = decoded.map(\.durationSeconds).reduce(0, +) / rate
        let watchdogDelay = max(0.5, maxExpectedPlaybackSeconds + 0.75)

        for (index, chunk) in decoded.enumerated() {
            let isLast = index == decoded.count - 1
            let nextItem = index + 1 < decoded.count ? decoded[index + 1].item.item : nil
            let callbackItem = chunk.item.item
            Task { @MainActor in
                await onBufferEnqueue(chunk.item.item)
            }
            playerNode.scheduleBuffer(chunk.buffer, completionCallbackType: .dataPlayedBack) { [weak self, nextItem, callbackItem] _ in
                Task { @MainActor in
                    guard let self, self.playbackToken == playbackToken else { return }
                    if let nextItem {
                        await onStartItem(nextItem)
                        guard self.playbackToken == playbackToken else { return }
                    }
                    await onItemEnd(callbackItem)
                    if isLast {
                        await self.finishQueuedPlayback(
                            playbackToken: playbackToken,
                            onFinish: onFinish
                        )
                    }
                }
            }
        }

        Task { [weak self] in
            try? await Task.sleep(nanoseconds: UInt64(watchdogDelay * 1_000_000_000))
            await MainActor.run {
                guard let self else { return }
                if self.playbackToken == playbackToken {
                    Task {
                        await self.finishQueuedPlayback(
                            playbackToken: playbackToken,
                            onFinish: onFinish
                        )
                    }
                }
            }
        }

        engine.prepare()
        try engine.start()

        boundaryTask?.cancel()
        boundaryTask = Task { @MainActor [weak self] in
            guard let self, self.playbackToken == playbackToken else { return }
            guard let playerNode = self.playerNode else {
                let continuation = self.continuation
                self.continuation = nil
                continuation?.resume(throwing: QwenRuntimeError.commandFailed("Qwen playback engine failed to initialize."))
                return
            }
            let playbackEngineMissing = playerNode.engine == nil
            if playbackEngineMissing {
                print("QwenAudioPlayback startQueuedPlayback playerNode.engine is nil before play()")
            }
            let firstItem = decoded[0].item.item
            Task { @MainActor in
                await onStartItem(firstItem)
            }
            await onRenderStart()
            playerNode.play()
            self.emitInitialVisualizationFrame(
                meterFrames: decoded.map(\.meterFrames),
                durations: decoded.map(\.durationSeconds),
                rate: rate
            )
            if !self.visualizationAudioSessionIsActive {
                self.visualizationSink?.speechPlaybackVisualizationAudioDidStart()
                self.visualizationAudioSessionIsActive = true
            }
            self.startSequenceMetering(decoded, playbackID: playbackToken, rate: rate)
        }
    }

    private func startQueuedFilePlayback(
        playbackToken: UUID,
        _ queued: [QueuedPlaybackFile],
        rate: Double,
        volume: Float,
        continuation: CheckedContinuation<Void, Error>,
        onStartItem: @escaping @MainActor @Sendable (SpeechPlaybackItem) async -> Void,
        onBufferEnqueue: @escaping @MainActor @Sendable (SpeechPlaybackItem) async -> Void,
        onRenderStart: @escaping @MainActor @Sendable () async -> Void,
        onFinish: @escaping @MainActor @Sendable () async -> Void,
        onItemEnd: @escaping @MainActor @Sendable (SpeechPlaybackItem) async -> Void
    ) throws {
        self.playbackToken = playbackToken
        self.continuation = continuation
        let playbackFormat = queued[0].file.processingFormat
        try configureStreamingPlaybackEngine(
            format: playbackFormat,
            rate: rate,
            volume: volume
        )
        self.queuedAudioFiles = queued.map(\.file)
        self.queuedTemporaryAudioURLs =
            queued
            .filter(\.item.audio.removeAfterPlayback)
            .map(\.item.audio.url)
        guard let engine, let playerNode else {
            throw QwenRuntimeError.commandFailed("Qwen playback engine failed to initialize.")
        }

        let maxExpectedPlaybackSeconds = queued.map(\.durationSeconds).reduce(0, +) / rate
        let watchdogDelay = max(0.5, maxExpectedPlaybackSeconds + 0.75)

        for (index, chunk) in queued.enumerated() {
            let isLast = index == queued.count - 1
            let nextItem = index + 1 < queued.count ? queued[index + 1].item.item : nil
            let callbackItem = chunk.item.item
            Task { @MainActor in
                await onBufferEnqueue(chunk.item.item)
            }
            playerNode.scheduleFile(chunk.file, at: nil, completionCallbackType: .dataPlayedBack) { [weak self, nextItem, callbackItem] _ in
                Task { @MainActor in
                    guard let self, self.playbackToken == playbackToken else { return }
                    if let nextItem {
                        await onStartItem(nextItem)
                        guard self.playbackToken == playbackToken else { return }
                    }
                    await onItemEnd(callbackItem)
                    if isLast {
                        await self.finishQueuedPlayback(
                            playbackToken: playbackToken,
                            onFinish: onFinish
                        )
                    }
                }
            }
        }

        Task { [weak self] in
            try? await Task.sleep(nanoseconds: UInt64(watchdogDelay * 1_000_000_000))
            await MainActor.run {
                guard let self else { return }
                if self.playbackToken == playbackToken {
                    Task {
                        await self.finishQueuedPlayback(
                            playbackToken: playbackToken,
                            onFinish: onFinish
                        )
                    }
                }
            }
        }

        if !engine.isRunning {
            engine.prepare()
            try engine.start()
        }

        boundaryTask?.cancel()
        boundaryTask = Task { @MainActor [weak self] in
            guard let self, self.playbackToken == playbackToken else { return }
            guard let playerNode = self.playerNode else {
                let continuation = self.continuation
                self.continuation = nil
                continuation?.resume(throwing: QwenRuntimeError.commandFailed("Qwen playback engine failed to initialize."))
                return
            }
            let playbackEngineMissing = playerNode.engine == nil
            if playbackEngineMissing {
                print("QwenAudioPlayback startQueuedFilePlayback playerNode.engine is nil before play()")
            }
            let firstItem = queued[0].item.item
            Task { @MainActor in
                await onStartItem(firstItem)
            }
            await onRenderStart()
            playerNode.play()
            self.emitInitialVisualizationFrame(
                meterFrames: queued.map(\.meterFrames),
                durations: queued.map(\.durationSeconds),
                rate: rate
            )
            if !self.visualizationAudioSessionIsActive {
                self.visualizationSink?.speechPlaybackVisualizationAudioDidStart()
                self.visualizationAudioSessionIsActive = true
            }
            self.startSequenceMetering(queued, playbackID: playbackToken, rate: rate)
        }
    }

    private func finishQueuedPlayback(
        playbackToken: UUID,
        onFinish: @escaping @MainActor @Sendable () async -> Void
    ) async {
        guard self.playbackToken == playbackToken else { return }
        let continuation = continuation
        self.continuation = nil
        boundaryTask?.cancel()
        boundaryTask = nil
        meteringTask?.cancel()
        meteringTask = nil
        self.playbackToken = nil
        resetQueuedPlayback(preserveStreamingEngine: true)
        startInterBatchVisualizationDecay()
        await onFinish()
        continuation?.resume()
    }

    private func resetQueuedPlayback(preserveStreamingEngine: Bool = false) {
        playbackToken = nil
        playerNode?.stop()
        if preserveStreamingEngine {
            // The engine is intentionally kept warm between prepared batches,
            // but the time-pitch unit must not carry phase-vocoder history from
            // one discontinuous batch into the next.
            rateProcessor?.reset()
        }
        if !preserveStreamingEngine {
            engine?.stop()
            if let engine, let playerNode {
                engine.detach(playerNode)
            }
            if let engine, let rateProcessor {
                engine.detach(rateProcessor)
            }
            playerNode = nil
            rateProcessor = nil
            engine = nil
            streamingEngineFormat = nil
            streamingEngineRate = nil
        }
        queuedAudioFiles.removeAll()
        for url in queuedTemporaryAudioURLs {
            try? FileManager.default.removeItem(at: url)
        }
        queuedTemporaryAudioURLs.removeAll()
        streamingPlaybackDurations.removeAll()
        streamingMeterFrames.removeAll()
        streamingScheduledBufferCount = 0
        streamingPlayedBufferCount = 0
    }

    private func configureStreamingPlaybackEngine(
        format: AVAudioFormat,
        rate: Double,
        volume: Float
    ) throws {
        if let engine,
           let playerNode,
           let existingFormat = streamingEngineFormat,
           Self.formatsAreCompatible(existingFormat, format),
           streamingEngineRate == rate {
            playerNode.volume = volume
            if !engine.isRunning {
                engine.prepare()
                try engine.start()
            }
            return
        }

        let currentPlaybackToken = playbackToken
        resetQueuedPlayback()
        playbackToken = currentPlaybackToken
        let engine = AVAudioEngine()
        let playerNode = AVAudioPlayerNode()
        let rateProcessor = Self.makeRateProcessor(rateMultiplier: rate)
        playerNode.volume = volume

        engine.attach(playerNode)
        engine.attach(rateProcessor)
        engine.connect(playerNode, to: rateProcessor, format: format)
        engine.connect(rateProcessor, to: engine.mainMixerNode, format: format)

        self.engine = engine
        self.playerNode = playerNode
        self.rateProcessor = rateProcessor
        streamingEngineFormat = format
        streamingEngineRate = rate
    }

    private func scheduleStreamingBuffer(
        _ streamingBuffer: StreamingPlaybackBuffer,
        playbackToken: UUID
    ) {
        guard let playerNode else { return }
        streamingPlaybackDurations.append(streamingBuffer.durationSeconds)
        streamingMeterFrames.append(streamingBuffer.meterFrames)
        streamingScheduledBufferCount += 1
        playerNode.scheduleBuffer(streamingBuffer.buffer, completionCallbackType: .dataPlayedBack) { [weak self] _ in
            Task { @MainActor in
                guard let self,
                    self.playbackToken == playbackToken
                else {
                    return
                }
                self.streamingPlayedBufferCount += 1
            }
        }
    }

    private func startStreamingPlayback(
        playbackToken: UUID,
        item: SpeechPlaybackItem,
        rate: Double,
        onStartItem: @escaping @MainActor @Sendable (SpeechPlaybackItem) async -> Void,
        onRenderStart: @escaping @MainActor @Sendable () async -> Void
    ) async throws {
        guard let engine, let playerNode else {
            throw QwenRuntimeError.commandFailed("Qwen streaming playback engine failed to initialize.")
        }
        if !engine.isRunning {
            engine.prepare()
            try engine.start()
        }
        guard playbackToken == self.playbackToken else { throw CancellationError() }
        await onStartItem(item)
        await onRenderStart()
        playerNode.play()
        emitInitialVisualizationFrame(
            meterFrames: streamingMeterFrames,
            durations: streamingPlaybackDurations,
            rate: rate
        )
        if !visualizationAudioSessionIsActive {
            visualizationSink?.speechPlaybackVisualizationAudioDidStart()
            visualizationAudioSessionIsActive = true
        }
        startStreamingMetering(item: item, playbackID: playbackToken, rate: rate)
    }

    private func startStreamingMetering(
        item: SpeechPlaybackItem,
        playbackID: UUID,
        rate: Double
    ) {
        meteringTask?.cancel()
        let playbackRate = max(0.01, rate)
        meteringTask = Task { @MainActor [weak self] in
            let startedAt = Date()
            var lastVisualizationDispatch = -Double.infinity
            while !Task.isCancelled,
                let self,
                self.playerNode?.isPlaying == true
            {
                let playbackElapsed = Date().timeIntervalSince(startedAt)
                let audioElapsed =
                    Self.audioElapsedSeconds(
                        from: self.playerNode!,
                        fallbackSampleRate: 24_000
                    ) ?? (playbackElapsed * playbackRate)
                let sourceDuration = self.streamingPlaybackDurations.reduce(0, +)
                self.timingSink?.speechPlaybackDidReceiveProgress(SpeechPlaybackProgress(
                    playbackID: playbackID,
                    itemID: item.id,
                    segmentID: item.segmentID,
                    sourcePositionSeconds: min(sourceDuration, max(0, audioElapsed)),
                    sourceDurationSeconds: sourceDuration,
                    playbackRate: playbackRate
                ))
                if playbackElapsed - lastVisualizationDispatch >= qwenVisualizationDispatchInterval,
                   let frame = Self.meteredVisualizationFrame(
                       meterFrames: self.streamingMeterFrames,
                       durations: self.streamingPlaybackDurations,
                       rate: playbackRate,
                       audioElapsedSeconds: audioElapsed,
                       playbackElapsedSeconds: playbackElapsed
                   ) {
                    self.visualizationSink?.speechPlaybackVisualizationFrameDidChange(frame)
                    lastVisualizationDispatch = playbackElapsed
                }
                try? await Task.sleep(nanoseconds: Self.nanoseconds(for: qwenPlaybackProgressPollInterval))
            }
        }
    }

    private func decode(_ items: [QwenPreparedPlaybackItem]) throws -> [DecodedPlaybackChunk] {
        var expectedFormat: AVAudioFormat?
        return try items.map { item in
            let file = try AVAudioFile(forReading: item.audio.url)
            let format = file.processingFormat
            if let expectedFormat, !Self.formatsAreCompatible(format, expectedFormat) {
                throw QwenRuntimeError.commandFailed("Qwen audio chunks use incompatible PCM formats.")
            }
            expectedFormat = expectedFormat ?? format

            guard
                let buffer = AVAudioPCMBuffer(
                    pcmFormat: format,
                    frameCapacity: AVAudioFrameCount(file.length)
                )
            else {
                throw QwenRuntimeError.commandFailed("Could not allocate Qwen audio buffer.")
            }
            try file.read(into: buffer)
            guard buffer.frameLength > 0, format.sampleRate > 0 else {
                throw QwenRuntimeError.commandFailed("Qwen audio chunk was empty.")
            }
            return DecodedPlaybackChunk(
                item: item,
                buffer: buffer,
                durationSeconds: Double(buffer.frameLength) / format.sampleRate,
                meterFrames: Self.estimatedVisualizationFrames(
                    from: buffer,
                    windowSeconds: qwenVisualizationFrameInterval
                )
            )
        }
    }

    private func loadQueuedFiles(_ items: [QwenPreparedPlaybackItem]) async throws -> [QueuedPlaybackFile] {
        var expectedFormat: AVAudioFormat?
        var loaded: [(item: QwenPreparedPlaybackItem, file: AVAudioFile, durationSeconds: Double, format: AVAudioFormat)] = []
        loaded.reserveCapacity(items.count)
        for item in items {
            try Task.checkCancellation()
            let file: AVAudioFile
            if let preparedFile = queuedAudioFileCache.take(for: item.audio.url) {
                file = preparedFile
            } else {
                let url = item.audio.url
                file = try await Task.detached(priority: .userInitiated) {
                    try SendableAudioFile(file: AVAudioFile(forReading: url))
                }.value.file
            }
            try Task.checkCancellation()
            let format = file.processingFormat
            if let expectedFormat, !Self.formatsAreCompatible(format, expectedFormat) {
                throw QwenRuntimeError.commandFailed("Qwen audio chunks use incompatible PCM formats.")
            }
            expectedFormat = expectedFormat ?? format
            let measuredDuration = format.sampleRate > 0 ? Double(file.length) / format.sampleRate : 0
            loaded.append(
                (
                    item: item,
                    file: file,
                    durationSeconds: item.audio.durationSeconds > 0 ? item.audio.durationSeconds : measuredDuration,
                    format: format
                ))
        }

        let shouldLoadMeterFrames = visualizationSink != nil

        return loaded.map { entry in
            let meterFrames: [SpeechPlaybackVisualizationFrame]
            if shouldLoadMeterFrames {
                meterFrames = visualizationFrameCache.frames(for: entry.item.audio.url) ?? []
                if meterFrames.isEmpty {
                    visualizationFrameCache.prewarm(entry.item.audio)
                }
            } else {
                meterFrames = []
            }
            return QueuedPlaybackFile(
                item: entry.item,
                file: entry.file,
                durationSeconds: entry.durationSeconds,
                meterFrames: meterFrames
            )
        }
    }

    private func removeTemporaryAudioFiles(in items: [QwenPreparedPlaybackItem]) {
        for item in items where item.audio.removeAfterPlayback {
            try? FileManager.default.removeItem(at: item.audio.url)
        }
    }

    private func startInterBatchVisualizationDecay() {
        guard visualizationAudioSessionIsActive else { return }
        meteringTask?.cancel()
        meteringTask = Task { @MainActor [weak self] in
            let startedAt = ProcessInfo.processInfo.systemUptime
            let duration = 0.15
            while !Task.isCancelled, let self, self.visualizationAudioSessionIsActive {
                if self.playerNode?.isPlaying == true {
                    return
                }
                let elapsed = ProcessInfo.processInfo.systemUptime - startedAt
                guard elapsed < duration else {
                    self.visualizationSink?.speechPlaybackVisualizationFrameDidChange(.levelOnly(0))
                    return
                }
                let level = max(0, 0.28 * (1 - elapsed / duration))
                self.visualizationSink?.speechPlaybackVisualizationFrameDidChange(
                    Self.durationOnlyVisualizationFrame(
                        elapsedSeconds: elapsed,
                        chunkIndex: 0,
                        level: level
                    )
                )
                try? await Task.sleep(
                    nanoseconds: Self.nanoseconds(for: qwenVisualizationDispatchInterval)
                )
            }
        }
    }

    private func startSequenceMetering(
        _ decoded: [DecodedPlaybackChunk],
        playbackID: UUID,
        rate: Double
    ) {
        meteringTask?.cancel()
        let sampleRate = decoded.first?.buffer.format.sampleRate ?? 0
        startMetering(
            meterFrames: decoded.map(\.meterFrames),
            durations: decoded.map(\.durationSeconds),
            items: decoded.map(\.item),
            playbackID: playbackID,
            rate: rate,
            timeProvider: { [weak self] startedAt in
                let playbackElapsed = Date().timeIntervalSince(startedAt)
                guard let self, let playerNode = self.playerNode else { return nil }
                if let audioElapsed = Self.audioElapsedSeconds(
                    from: playerNode,
                    fallbackSampleRate: sampleRate
                ) {
                    return (audioElapsedSeconds: audioElapsed, playbackElapsedSeconds: playbackElapsed)
                }
                return (
                    audioElapsedSeconds: playbackElapsed * max(0.01, rate),
                    playbackElapsedSeconds: playbackElapsed
                )
            },
            isPlaying: { [weak self] in
                self?.playerNode?.isPlaying == true
            }
        )
    }

    private func startSequenceMetering(
        _ queued: [QueuedPlaybackFile],
        playbackID: UUID,
        rate: Double
    ) {
        meteringTask?.cancel()
        let sampleRate = queued.first?.file.processingFormat.sampleRate ?? 0
        startMetering(
            meterFrames: queued.map(\.meterFrames),
            durations: queued.map(\.durationSeconds),
            items: queued.map(\.item),
            playbackID: playbackID,
            rate: rate,
            timeProvider: { [weak self] startedAt in
                let playbackElapsed = Date().timeIntervalSince(startedAt)
                guard let self, let playerNode = self.playerNode else { return nil }
                if let audioElapsed = Self.audioElapsedSeconds(
                    from: playerNode,
                    fallbackSampleRate: sampleRate
                ) {
                    return (audioElapsedSeconds: audioElapsed, playbackElapsedSeconds: playbackElapsed)
                }
                return (
                    audioElapsedSeconds: playbackElapsed * max(0.01, rate),
                    playbackElapsedSeconds: playbackElapsed
                )
            },
            isPlaying: { [weak self] in
                self?.playerNode?.isPlaying == true
            }
        )
    }

    private func startSequenceMetering(
        _ durations: [Double],
        items: [QwenPreparedPlaybackItem],
        playbackID: UUID,
        rate: Double
    ) {
        meteringTask?.cancel()
        let playbackRate = max(0.01, Double(rate))
        let playbackDurations = durations.map { max(qwenVisualizationFrameInterval, $0 / playbackRate) }
        let playbackEndTimes = playbackDurations.reduce(into: [Double]()) { ends, duration in
            ends.append((ends.last ?? 0) + duration)
        }
        meteringTask = Task { @MainActor [weak self] in
            var chunkIndex = 0
            let startedAt = Date()
            var lastVisualizationDispatch = -Double.infinity
            while !Task.isCancelled,
                let self,
                self.playerNode?.isPlaying == true
            {
                let elapsedTotal = Date().timeIntervalSince(startedAt)
                let audioElapsed = elapsedTotal * playbackRate
                self.publishProgress(
                    playbackID: playbackID,
                    items: items,
                    durations: durations,
                    audioElapsedSeconds: audioElapsed,
                    playbackRate: playbackRate
                )
                if elapsedTotal - lastVisualizationDispatch >= qwenVisualizationDispatchInterval {
                    self.visualizationSink?.speechPlaybackVisualizationFrameDidChange(
                        Self.durationOnlyVisualizationFrame(
                            elapsedSeconds: elapsedTotal,
                            chunkIndex: chunkIndex,
                            level: 0.35
                        ))
                    lastVisualizationDispatch = elapsedTotal
                }
                try? await Task.sleep(nanoseconds: Self.nanoseconds(for: qwenPlaybackProgressPollInterval))
                if chunkIndex < playbackDurations.count - 1,
                    elapsedTotal >= playbackEndTimes[chunkIndex]
                {
                    chunkIndex += 1
                }
            }
        }
    }

    private func startFileMetering(
        _ decoded: [DecodedPlaybackChunk],
        playbackID: UUID,
        rate: Double
    ) {
        meteringTask?.cancel()
        startMetering(
            meterFrames: decoded.map(\.meterFrames),
            durations: decoded.map(\.durationSeconds),
            items: decoded.map(\.item),
            playbackID: playbackID,
            rate: rate,
            timeProvider: { [weak player] startedAt in
                let playbackElapsed = Date().timeIntervalSince(startedAt)
                guard let player else { return nil }
                return (
                    audioElapsedSeconds: player.currentTime,
                    playbackElapsedSeconds: playbackElapsed
                )
            },
            isPlaying: { [weak self] in
                self?.player?.isPlaying == true
            }
        )
    }

    private func startMetering(
        meterFrames: [[SpeechPlaybackVisualizationFrame]],
        durations: [Double],
        items: [QwenPreparedPlaybackItem],
        playbackID: UUID,
        rate: Double,
        timeProvider:
            @escaping @MainActor @Sendable (_ startedAt: Date) -> (
                audioElapsedSeconds: Double,
                playbackElapsedSeconds: Double
            )?,
        isPlaying: @escaping @MainActor @Sendable () -> Bool
    ) {
        guard !meterFrames.isEmpty else { return }
        meteringTask = Task { @MainActor [weak self] in
            let startedAt = Date()
            var resolvedFrames = meterFrames
            var lastVisualizationDispatch = -Double.infinity
            while !Task.isCancelled,
                let self,
                isPlaying()
            {
                if let elapsed = timeProvider(startedAt) {
                    self.publishProgress(
                        playbackID: playbackID,
                        items: items,
                        durations: durations,
                        audioElapsedSeconds: elapsed.audioElapsedSeconds,
                        playbackRate: rate
                    )
                    if elapsed.playbackElapsedSeconds - lastVisualizationDispatch
                        >= qwenVisualizationDispatchInterval
                    {
                        let activeIndex = Self.activeItemIndex(
                            durations: durations,
                            audioElapsedSeconds: elapsed.audioElapsedSeconds
                        )
                        if resolvedFrames.indices.contains(activeIndex),
                           resolvedFrames[activeIndex].isEmpty,
                           items.indices.contains(activeIndex),
                           let cached = self.visualizationFrameCache.frames(
                               for: items[activeIndex].audio.url
                           ) {
                            resolvedFrames[activeIndex] = cached
                        }
                        let frame: SpeechPlaybackVisualizationFrame
                        if resolvedFrames.indices.contains(activeIndex),
                           !resolvedFrames[activeIndex].isEmpty,
                           let metered = Self.meteredVisualizationFrame(
                               meterFrames: resolvedFrames.map { frames in
                                   frames.isEmpty ? [.levelOnly(0.12)] : frames
                               },
                               durations: durations,
                               rate: rate,
                               audioElapsedSeconds: elapsed.audioElapsedSeconds,
                               playbackElapsedSeconds: elapsed.playbackElapsedSeconds
                           ) {
                            frame = metered
                        } else {
                            frame = Self.durationOnlyVisualizationFrame(
                                elapsedSeconds: elapsed.playbackElapsedSeconds,
                                chunkIndex: activeIndex,
                                level: 0.35
                            )
                        }
                        self.visualizationSink?.speechPlaybackVisualizationFrameDidChange(frame)
                        lastVisualizationDispatch = elapsed.playbackElapsedSeconds
                    }
                }
                try? await Task.sleep(nanoseconds: Self.nanoseconds(for: qwenPlaybackProgressPollInterval))
            }
        }
    }

    private nonisolated static func activeItemIndex(
        durations: [Double],
        audioElapsedSeconds: Double
    ) -> Int {
        guard !durations.isEmpty else { return 0 }
        let elapsed = max(0, audioElapsedSeconds)
        var itemEnd = 0.0
        for index in durations.indices {
            itemEnd += max(0, durations[index])
            if elapsed < itemEnd || index == durations.indices.last {
                return index
            }
        }
        return durations.count - 1
    }

    private func publishProgress(
        playbackID: UUID,
        items: [QwenPreparedPlaybackItem],
        durations: [Double],
        audioElapsedSeconds: TimeInterval,
        playbackRate: Double
    ) {
        guard !items.isEmpty,
              items.count == durations.count,
              audioElapsedSeconds.isFinite else {
            return
        }
        let elapsed = max(0, audioElapsedSeconds)
        var itemStart: TimeInterval = 0
        for index in items.indices {
            let duration = max(0, durations[index])
            let itemEnd = itemStart + duration
            if elapsed < itemEnd || index == items.indices.last {
                let prepared = items[index]
                timingSink?.speechPlaybackDidReceiveProgress(SpeechPlaybackProgress(
                    playbackID: playbackID,
                    itemID: prepared.item.id,
                    segmentID: prepared.item.segmentID,
                    itemIndex: prepared.index,
                    sourcePositionSeconds: min(duration, max(0, elapsed - itemStart)),
                    sourceDurationSeconds: duration,
                    playbackRate: playbackRate
                ))
                return
            }
            itemStart = itemEnd
        }
    }

    private func emitInitialVisualizationFrame(
        meterFrames: [[SpeechPlaybackVisualizationFrame]],
        durations: [Double],
        rate: Double
    ) {
        let frame = Self.meteredVisualizationFrame(
                meterFrames: meterFrames,
                durations: durations,
                rate: rate,
                audioElapsedSeconds: 0,
                playbackElapsedSeconds: 0
            )
            ?? Self.durationOnlyVisualizationFrame(
                elapsedSeconds: 0,
                chunkIndex: 0,
                level: 0.35
            )
        visualizationSink?.speechPlaybackVisualizationFrameDidChange(frame)
    }

    private static func audioElapsedSeconds(
        from playerNode: AVAudioPlayerNode,
        fallbackSampleRate: Double
    ) -> Double? {
        guard let renderTime = playerNode.lastRenderTime,
            let playerTime = playerNode.playerTime(forNodeTime: renderTime),
            playerTime.isSampleTimeValid,
            playerTime.sampleTime >= 0
        else {
            return nil
        }
        let sampleRate = playerTime.sampleRate > 0 ? playerTime.sampleRate : fallbackSampleRate
        guard sampleRate > 0 else { return nil }
        return Double(playerTime.sampleTime) / sampleRate
    }

    private nonisolated static func formatsAreCompatible(_ lhs: AVAudioFormat, _ rhs: AVAudioFormat) -> Bool {
        lhs.sampleRate == rhs.sampleRate && lhs.channelCount == rhs.channelCount && lhs.commonFormat == rhs.commonFormat
            && lhs.isInterleaved == rhs.isInterleaved
    }

    private nonisolated static func streamingBuffer(
        from chunk: QwenStreamingAudioChunk,
        expectedFormat: AVAudioFormat?
    ) throws -> StreamingPlaybackBuffer? {
        guard chunk.sampleRate.isFinite, chunk.sampleRate > 0 else {
            throw QwenRuntimeError.commandFailed("Qwen streaming chunk used an invalid sample rate.")
        }
        guard !chunk.audioData.isEmpty else {
            return nil
        }
        let stride = MemoryLayout<Float>.stride
        guard chunk.audioData.count.isMultiple(of: stride) else {
            throw QwenRuntimeError.commandFailed("Qwen streaming chunk contained malformed PCM data.")
        }
        let frameCount = chunk.audioData.count / stride
        guard frameCount > 0 else { return nil }
        guard
            let format = AVAudioFormat(
                standardFormatWithSampleRate: chunk.sampleRate,
                channels: 1
            )
        else {
            throw QwenRuntimeError.commandFailed("Could not create Qwen streaming audio format.")
        }
        if let expectedFormat, !formatsAreCompatible(format, expectedFormat) {
            throw QwenRuntimeError.commandFailed("Qwen streaming chunks use incompatible PCM formats.")
        }
        guard
            let buffer = AVAudioPCMBuffer(
                pcmFormat: format,
                frameCapacity: AVAudioFrameCount(frameCount)
            )
        else {
            throw QwenRuntimeError.commandFailed("Could not allocate Qwen streaming buffer.")
        }
        buffer.frameLength = AVAudioFrameCount(frameCount)
        guard let destination = buffer.floatChannelData?[0] else {
            throw QwenRuntimeError.commandFailed("Could not write Qwen streaming buffer.")
        }
        try chunk.audioData.withUnsafeBytes { rawBuffer in
            let source = rawBuffer.bindMemory(to: Float.self)
            guard let sourceBase = source.baseAddress else {
                throw QwenRuntimeError.commandFailed("Could not read Qwen streaming PCM data.")
            }
            destination.update(from: sourceBase, count: frameCount)
        }
        let duration =
            chunk.durationSeconds > 0
            ? chunk.durationSeconds
            : Double(frameCount) / chunk.sampleRate
        return StreamingPlaybackBuffer(
            buffer: buffer,
            durationSeconds: duration,
            meterFrames: estimatedFastSpectrumVisualizationFrames(
                from: buffer,
                windowSeconds: qwenVisualizationFrameInterval
            )
        )
    }

    nonisolated static func makeRateProcessor(rateMultiplier: Double) -> AVAudioUnit {
        let timePitch = AVAudioUnitTimePitch()
        let rate = min(max(rateMultiplier, 0.5), 2.4)
        timePitch.rate = Float(rate)
        timePitch.pitch = 0
        // Apple's time-pitch unit documents that more overlap trades modest CPU
        // for fewer stretch artifacts. Scale it only as playback moves away from 1x.
        let stretchSeverity = min(1, abs(log2(rate)) / log2(2.4))
        timePitch.overlap = Float(8 + 24 * stretchSeverity)
        return timePitch
    }

    nonisolated static func estimatedLevels(
        from buffer: AVAudioPCMBuffer,
        windowSeconds: Double = 0.05
    ) -> [Double] {
        estimatedVisualizationFrames(from: buffer, windowSeconds: windowSeconds).map(\.level)
    }

    nonisolated static func estimatedVisualizationFrames(
        from buffer: AVAudioPCMBuffer,
        windowSeconds: Double = qwenVisualizationFrameInterval,
        barCount: Int = 16
    ) -> [SpeechPlaybackVisualizationFrame] {
        guard let data = buffer.floatChannelData else {
            return [.levelOnly(0.12, barCount: barCount)]
        }
        let frameCount = Int(buffer.frameLength)
        let channelCount = Int(buffer.format.channelCount)
        let sampleRate = buffer.format.sampleRate
        guard frameCount > 0, channelCount > 0, sampleRate > 0 else {
            return [.levelOnly(0.12, barCount: barCount)]
        }

        let framesPerWindow = max(1, Int(sampleRate * max(0.01, windowSeconds)))
        let resolvedBarCount = max(1, barCount)
        var frames: [SpeechPlaybackVisualizationFrame] = []
        var previousBars = Array(repeating: 0.0, count: resolvedBarCount)
        var windowStart = 0
        while windowStart < frameCount {
            let windowEnd = min(frameCount, windowStart + framesPerWindow)
            let samples = Self.mixedSamples(
                from: data,
                channelCount: channelCount,
                start: windowStart,
                end: windowEnd
            )
            let level = Self.level(fromLinearPeak: Self.linearPeak(in: samples))
            let centeredSamples = Self.removingDCOffset(from: samples)
            let rawBars = Self.spectralBarLevels(
                from: centeredSamples,
                sampleRate: sampleRate,
                barCount: resolvedBarCount
            )
            let bars = rawBars.enumerated().map { index, current in
                let smoothed = 0.22 * previousBars[index] + 0.78 * current
                return min(1, max(0, level * (0.06 + 0.94 * smoothed)))
            }
            previousBars = bars
            frames.append(SpeechPlaybackVisualizationFrame(level: level, barLevels: bars))
            windowStart = windowEnd
        }
        return frames.isEmpty ? [.levelOnly(0.12, barCount: resolvedBarCount)] : frames
    }

    nonisolated static func estimatedVisualizationFrames(
        fromAudioAt url: URL,
        expectedFormat: AVAudioFormat? = nil,
        barCount: Int = 16
    ) throws -> [SpeechPlaybackVisualizationFrame] {
        let file = try AVAudioFile(forReading: url)
        let format = file.processingFormat
        if let expectedFormat, !Self.formatsAreCompatible(format, expectedFormat) {
            throw QwenRuntimeError.commandFailed("Qwen audio chunks use incompatible PCM formats.")
        }
        guard
            let buffer = AVAudioPCMBuffer(
                pcmFormat: format,
                frameCapacity: AVAudioFrameCount(file.length)
            )
        else {
            throw QwenRuntimeError.commandFailed("Could not allocate Qwen audio meter buffer.")
        }
        try file.read(into: buffer)
        guard buffer.frameLength > 0, format.sampleRate > 0 else {
            return [.levelOnly(0.12, barCount: barCount)]
        }
        return estimatedVisualizationFrames(
            from: buffer,
            windowSeconds: qwenVisualizationFrameInterval,
            barCount: barCount
        )
    }

    nonisolated static func estimatedFastSpectrumVisualizationFrames(
        from buffer: AVAudioPCMBuffer,
        windowSeconds: Double = qwenVisualizationFrameInterval,
        barCount: Int = 16
    ) -> [SpeechPlaybackVisualizationFrame] {
        guard let data = buffer.floatChannelData else {
            return [.levelOnly(0.12, barCount: barCount)]
        }
        let frameCount = Int(buffer.frameLength)
        let channelCount = Int(buffer.format.channelCount)
        let sampleRate = buffer.format.sampleRate
        guard frameCount > 0, channelCount > 0, sampleRate > 0 else {
            return [.levelOnly(0.12, barCount: barCount)]
        }

        let framesPerWindow = max(1, Int(sampleRate * max(0.01, windowSeconds)))
        let resolvedBarCount = max(1, barCount)
        let sampleStride = Self.fastSpectrumSampleStride(for: sampleRate)
        let analysisSampleRate = sampleRate / Double(sampleStride)
        var frames: [SpeechPlaybackVisualizationFrame] = []
        frames.reserveCapacity(max(1, frameCount / framesPerWindow))
        var previousBars = Array(repeating: 0.0, count: resolvedBarCount)
        var windowStart = 0
        while windowStart < frameCount {
            let windowEnd = min(frameCount, windowStart + framesPerWindow)
            let level = Self.level(
                fromLinearPeak: Self.mixedLinearPeak(
                    from: data,
                    channelCount: channelCount,
                    start: windowStart,
                    end: windowEnd
                ))
            let samples = Self.mixedSamples(
                from: data,
                channelCount: channelCount,
                start: windowStart,
                end: windowEnd,
                stride: sampleStride
            )
            let rawBars = Self.spectralBarLevels(
                from: Self.removingDCOffset(from: samples),
                sampleRate: analysisSampleRate,
                barCount: resolvedBarCount
            )
            let targetBars = rawBars.map { min(1, max(0, level * (0.08 + 0.92 * $0))) }
            let bars = targetBars.enumerated().map { index, target in
                let previous = previousBars[index]
                let coefficient = target > previous ? 0.34 : 0.22
                return min(1, max(0, previous + (target - previous) * coefficient))
            }
            previousBars = bars
            frames.append(SpeechPlaybackVisualizationFrame(level: level, barLevels: bars))
            windowStart = windowEnd
        }
        return frames.isEmpty ? [.levelOnly(0.12, barCount: resolvedBarCount)] : frames
    }

    nonisolated static func estimatedFastSpectrumVisualizationFrames(
        fromAudioAt url: URL,
        expectedFormat: AVAudioFormat? = nil,
        barCount: Int = 16
    ) throws -> [SpeechPlaybackVisualizationFrame] {
        let file = try AVAudioFile(forReading: url)
        let format = file.processingFormat
        if let expectedFormat, !Self.formatsAreCompatible(format, expectedFormat) {
            throw QwenRuntimeError.commandFailed("Qwen audio chunks use incompatible PCM formats.")
        }
        guard
            let buffer = AVAudioPCMBuffer(
                pcmFormat: format,
                frameCapacity: AVAudioFrameCount(file.length)
            )
        else {
            throw QwenRuntimeError.commandFailed("Could not allocate Qwen audio meter buffer.")
        }
        try file.read(into: buffer)
        guard buffer.frameLength > 0, format.sampleRate > 0 else {
            return [.levelOnly(0.12, barCount: barCount)]
        }
        return estimatedFastSpectrumVisualizationFrames(
            from: buffer,
            windowSeconds: qwenVisualizationFrameInterval,
            barCount: barCount
        )
    }

    private nonisolated static func level(fromLinearPeak peak: Float) -> Double {
        guard peak.isFinite, peak > 0 else { return 0 }
        return min(1, max(0.04, Double(peak) * 8))
    }

    private nonisolated static func mixedLinearPeak(
        from data: UnsafePointer<UnsafeMutablePointer<Float>>,
        channelCount: Int,
        start: Int,
        end: Int
    ) -> Float {
        let frameCount = max(0, end - start)
        guard frameCount > 0, channelCount > 0 else { return 0 }
        var peak = Float(0)
        let divisor = Float(channelCount)
        for frame in start..<end {
            var mixed = Float(0)
            for channel in 0..<channelCount {
                mixed += data[channel][frame] / divisor
            }
            peak = max(peak, abs(mixed))
        }
        return peak
    }

    private nonisolated static func mixedSamples(
        from data: UnsafePointer<UnsafeMutablePointer<Float>>,
        channelCount: Int,
        start: Int,
        end: Int,
        stride: Int = 1
    ) -> [Float] {
        let resolvedStride = max(1, stride)
        let frameCount = max(0, (end - start + resolvedStride - 1) / resolvedStride)
        guard frameCount > 0 else { return [] }
        var samples: [Float] = []
        samples.reserveCapacity(frameCount)
        var frame = start
        while frame < end {
            var mixed = Float(0)
            for channel in 0..<channelCount {
                mixed += data[channel][frame] / Float(channelCount)
            }
            samples.append(mixed)
            frame += resolvedStride
        }
        return samples
    }

    private nonisolated static func linearPeak(in samples: [Float]) -> Float {
        samples.reduce(Float(0)) { max($0, abs($1)) }
    }

    private nonisolated static func removingDCOffset(from samples: [Float]) -> [Float] {
        guard !samples.isEmpty else { return samples }
        let mean = samples.reduce(Float(0), +) / Float(samples.count)
        guard mean != 0 else { return samples }
        return samples.map { $0 - mean }
    }

    private nonisolated static func spectralBarLevels(
        from samples: [Float],
        sampleRate: Double,
        barCount: Int
    ) -> [Double] {
        guard !samples.isEmpty, sampleRate > 0, barCount > 0 else {
            return Array(repeating: 0, count: max(1, barCount))
        }
        let nyquist = sampleRate / 2
        guard nyquist > 20 else {
            return Array(repeating: 0, count: barCount)
        }

        let minimumFrequency = min(80, max(20, nyquist * 0.08))
        let maximumFrequency = min(8_000, max(minimumFrequency * 1.5, nyquist * 0.92))
        let logMinimum = log(minimumFrequency)
        let logMaximum = log(maximumFrequency)
        let logStep = (logMaximum - logMinimum) / Double(barCount)

        let rawBars = (0..<barCount).map { index -> Double in
            let lower = exp(logMinimum + logStep * Double(index))
            let upper = exp(logMinimum + logStep * Double(index + 1))
            let center = sqrt(lower * upper)
            let probes = [
                max(minimumFrequency, lower * 0.72 + upper * 0.28),
                center,
                min(maximumFrequency, lower * 0.28 + upper * 0.72),
            ]
            return
                probes
                .map { Self.goertzelMagnitude(samples: samples, sampleRate: sampleRate, frequency: $0) }
                .max() ?? 0
        }

        guard let strongest = rawBars.max(), strongest > 0 else {
            return Array(repeating: 0, count: barCount)
        }
        return rawBars.map { pow(min(1, max(0, $0 / strongest)), 0.48) }
    }

    private nonisolated static func goertzelMagnitude(
        samples: [Float],
        sampleRate: Double,
        frequency: Double
    ) -> Double {
        guard !samples.isEmpty, sampleRate > 0, frequency > 0 else { return 0 }
        let angularFrequency = 2 * Double.pi * frequency / sampleRate
        let coefficient = 2 * cos(angularFrequency)
        var previous = 0.0
        var previousPrevious = 0.0

        for sample in samples {
            let current = Double(sample) + coefficient * previous - previousPrevious
            previousPrevious = previous
            previous = current
        }

        let power =
            previousPrevious * previousPrevious
            + previous * previous
            - coefficient * previous * previousPrevious
        return sqrt(max(0, power)) / Double(samples.count)
    }

    nonisolated static func meteredVisualizationFrame(
        meterFrames: [[SpeechPlaybackVisualizationFrame]],
        durations: [Double],
        rate: Double,
        elapsedSeconds: Double
    ) -> SpeechPlaybackVisualizationFrame? {
        let playbackRate = max(0.01, rate.isFinite ? rate : 1.0)
        let safeElapsed = elapsedSeconds.isFinite ? max(0, elapsedSeconds) : 0
        return meteredVisualizationFrame(
            meterFrames: meterFrames,
            durations: durations,
            rate: playbackRate,
            audioElapsedSeconds: safeElapsed * playbackRate,
            playbackElapsedSeconds: safeElapsed
        )
    }

    nonisolated static func meteredVisualizationFrame(
        meterFrames: [[SpeechPlaybackVisualizationFrame]],
        durations: [Double],
        rate: Double,
        audioElapsedSeconds: Double,
        playbackElapsedSeconds: Double
    ) -> SpeechPlaybackVisualizationFrame? {
        let frames = meterFrames.map { chunkFrames in
            chunkFrames.isEmpty ? [.levelOnly(0.12)] : chunkFrames
        }
        guard !frames.isEmpty else { return nil }

        let playbackRate = max(0.01, rate.isFinite ? rate : 1.0)
        let safeAudioElapsed = audioElapsedSeconds.isFinite ? max(0, audioElapsedSeconds) : 0
        let safePlaybackElapsed = playbackElapsedSeconds.isFinite ? max(0, playbackElapsedSeconds) : 0
        var audioElapsedAtChunkStart = 0.0
        var playbackElapsedAtChunkStart = 0.0
        for chunkIndex in frames.indices {
            let chunkFrames = frames[chunkIndex]
            let audioDuration =
                durations.indices.contains(chunkIndex)
                ? max(0, durations[chunkIndex])
                : 0
            let resolvedAudioDuration =
                audioDuration > 0
                ? audioDuration
                : Double(chunkFrames.count) * qwenVisualizationFrameInterval
            let playbackDuration = max(
                qwenVisualizationFrameInterval,
                resolvedAudioDuration / playbackRate
            )
            let audioElapsedInChunk = safeAudioElapsed - audioElapsedAtChunkStart
            if audioElapsedInChunk < resolvedAudioDuration || chunkIndex == frames.indices.last {
                return Self.meteredVisualizationFrame(
                    in: chunkFrames,
                    audioDuration: resolvedAudioDuration,
                    playbackRate: playbackRate,
                    audioElapsedInChunk: audioElapsedInChunk,
                    playbackElapsedInChunk: safePlaybackElapsed - playbackElapsedAtChunkStart
                )
            }
            audioElapsedAtChunkStart += resolvedAudioDuration
            playbackElapsedAtChunkStart += playbackDuration
        }
        return frames.last.flatMap { chunkFrames in
            Self.decayedVisualizationFrame(
                from: chunkFrames.last ?? .levelOnly(0),
                elapsedSeconds: safePlaybackElapsed - playbackElapsedAtChunkStart
            )
        }
    }

    private nonisolated static func meteredVisualizationFrame(
        in frames: [SpeechPlaybackVisualizationFrame],
        audioDuration: Double,
        playbackRate: Double,
        audioElapsedInChunk: Double,
        playbackElapsedInChunk: Double
    ) -> SpeechPlaybackVisualizationFrame {
        guard !frames.isEmpty else { return .levelOnly(0.12) }
        let safeAudioElapsed = max(0, audioElapsedInChunk)
        let safePlaybackElapsed = max(0, playbackElapsedInChunk)
        let playbackDuration = max(qwenVisualizationFrameInterval, max(0, audioDuration) / playbackRate)
        if safePlaybackElapsed > playbackDuration {
            return decayedVisualizationFrame(
                from: frames[frames.count - 1],
                elapsedSeconds: safePlaybackElapsed - playbackDuration
            )
        }
        let frameIndex = Int(safeAudioElapsed / qwenVisualizationFrameInterval)
        if frames.indices.contains(frameIndex) {
            return frames[frameIndex]
        }
        let framePlaybackDuration = Double(frames.count) * qwenVisualizationFrameInterval / playbackRate
        let overrun = max(0, safePlaybackElapsed - framePlaybackDuration)
        return decayedVisualizationFrame(from: frames[frames.count - 1], elapsedSeconds: overrun)
    }

    private nonisolated static func decayedVisualizationFrame(
        from frame: SpeechPlaybackVisualizationFrame,
        elapsedSeconds: Double
    ) -> SpeechPlaybackVisualizationFrame {
        let safeElapsed = elapsedSeconds.isFinite ? max(0, elapsedSeconds) : 0
        let scale = exp(-safeElapsed / qwenVisualizationPostAudioDecayTimeConstant)
        return SpeechPlaybackVisualizationFrame(
            level: frame.level * scale,
            barLevels: frame.barLevels.map { $0 * scale }
        )
    }

    private static func nanoseconds(for seconds: Double) -> UInt64 {
        UInt64(max(0, seconds) * 1_000_000_000)
    }

    nonisolated static func durationOnlyVisualizationFrame(
        elapsedSeconds: Double,
        chunkIndex: Int,
        level: Double = 0.35,
        barCount: Int = 16
    ) -> SpeechPlaybackVisualizationFrame {
        let resolvedBarCount = max(1, barCount)
        let clampedLevel = min(1, max(0, level.isFinite ? level : 0))
        let safeElapsed = elapsedSeconds.isFinite ? max(0, elapsedSeconds) : 0
        let phase = safeElapsed * 9.0 + Double(max(0, chunkIndex)) * 0.73
        let bars = (0..<resolvedBarCount).map { index -> Double in
            let position = Double(index)
            let primary = (sin(phase + position * 0.88) + 1) / 2
            let secondary = (sin(phase * 1.63 - position * 0.41) + 1) / 2
            let envelope = 0.36 + 0.42 * primary + 0.18 * secondary
            return min(1, max(0, clampedLevel * envelope))
        }
        return SpeechPlaybackVisualizationFrame(level: clampedLevel, barLevels: bars)
    }

    nonisolated static func usesFastSpectrumVisualization(
        itemCount: Int,
        totalDurationSeconds: Double
    ) -> Bool {
        itemCount > qwenSpectralVisualizationMaxQueuedItemCount
            || totalDurationSeconds > qwenSpectralVisualizationMaxQueuedDurationSeconds
    }

    private nonisolated static func fastSpectrumSampleStride(for sampleRate: Double) -> Int {
        if sampleRate >= 44_100 {
            return 4
        }
        if sampleRate >= 24_000 {
            return 2
        }
        return 1
    }

    nonisolated static func normalizedLevel(from meter: any PlaybackAudioMetering) -> Double {
        guard meter.numberOfChannels > 0 else { return 0 }
        var peak: Double = 0
        for channel in 0..<meter.numberOfChannels {
            peak = max(
                peak,
                SpeechPlaybackLevelNormalizer.normalizedPower(
                    decibels: meter.averagePower(forChannel: channel)
                )
            )
        }
        return peak
    }
}

private struct DecodedPlaybackChunk {
    var item: QwenPreparedPlaybackItem
    var buffer: AVAudioPCMBuffer
    var durationSeconds: Double
    var meterFrames: [SpeechPlaybackVisualizationFrame]
}

private struct QueuedPlaybackFile {
    var item: QwenPreparedPlaybackItem
    var file: AVAudioFile
    var durationSeconds: Double
    var meterFrames: [SpeechPlaybackVisualizationFrame]
}

private struct PreparedAVAudioPlayer {
    var item: QwenPreparedPlaybackItem
    var player: AVAudioPlayer
    var durationSeconds: Double
    var meterFrames: [SpeechPlaybackVisualizationFrame]
}

private struct SendableAudioFile: @unchecked Sendable {
    var file: AVAudioFile
}

private struct StreamingPlaybackBuffer: @unchecked Sendable {
    var buffer: AVAudioPCMBuffer
    var durationSeconds: Double
    var meterFrames: [SpeechPlaybackVisualizationFrame]
}
