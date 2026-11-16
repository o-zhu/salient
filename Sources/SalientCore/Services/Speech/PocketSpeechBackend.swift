import Foundation

@MainActor
public protocol PocketAudioPlaying: AnyObject {
    var underrunCount: Int { get }
    var timingSink: (any SpeechPlaybackTimingSink)? { get set }
    var visualizationSink: (any SpeechPlaybackVisualizationSink)? { get set }
    func play(item: SpeechPlaybackItem, chunks: AsyncThrowingStream<QwenStreamingAudioChunk, Error>, settings: SpeechSettings,
              willSpeak: @escaping @MainActor (SpeechPlaybackItem) async -> Void) async throws
    func stop()
}

extension PocketAudioPlaying { public var underrunCount: Int { 0 } }

@MainActor
public final class PocketSpeechBackend: SpeechBackend, SpeechPlaybackTimingReporting {
    public private(set) var playbackUnderrunCount = 0
    public var settings: SpeechSettings {
        didSet { (fallback as? AVFoundationSpeechBackend)?.settings = settings.clamped }
    }
    public weak var timingSink: (any SpeechPlaybackTimingSink)? {
        didSet {
            playback.timingSink = timingSink
            (fallback as? any SpeechPlaybackTimingReporting)?.timingSink = timingSink
        }
    }
    public weak var visualizationSink: (any SpeechPlaybackVisualizationSink)? {
        didSet { playback.visualizationSink = visualizationSink }
    }
    private let runtime: any PocketSynthesizing
    private let playback: any PocketAudioPlaying
    private let fallback: any SpeechBackend
    private var generation = UUID()
    private var activeRequestID: UUID?

    public init(settings: SpeechSettings = .firstLaunch, runtime: any PocketSynthesizing = PocketRuntimeManager(),
                playback: (any PocketAudioPlaying)? = nil, fallback: (any SpeechBackend)? = nil) {
        self.settings = settings.clamped
        self.runtime = runtime
        self.playback = playback ?? PocketStreamPlayback()
        self.fallback = fallback ?? AVFoundationSpeechBackend(settings: settings.clamped)
    }

    public func speak(_ text: String) async throws {
        try await speak([.init(id: "pocket-text", segmentID: "pocket-text", text: text)], willSpeak: { _ in })
    }

    public func speak(_ items: [SpeechPlaybackItem], willSpeak: @escaping @MainActor (SpeechPlaybackItem) async -> Void) async throws {
        await stop()
        let token = UUID()
        generation = token
        playbackUnderrunCount = 0
        let currentSettings = settings.clamped
        let items = PocketSpeechChunker.items(from: items)
        try await withTaskCancellationHandler {
            let installed = await runtime.isInstalled()
            try Task.checkCancellation()
            guard generation == token else { throw CancellationError() }
            // Packaged apps include Pocket. Unbundled source builds can still read
            // through Apple while the optional managed download is pending.
            if !installed {
                try await fallback.speak(items, willSpeak: willSpeak)
                return
            }
            timingSink?.speechPlaybackWillUseFinalItems(items)
            for (index, item) in items.enumerated() {
                try Task.checkCancellation()
                guard generation == token else { throw CancellationError() }
                let requestID = UUID()
                activeRequestID = requestID
                do {
                    let chunks = try await runtime.stream(text: item.text, requestID: requestID)
                    guard generation == token else { throw CancellationError() }
                    let pair = PocketAudioStream.makeStream()
                    let relay = Task { @MainActor in
                        do {
                            for try await chunk in chunks {
                                try Task.checkCancellation()
                                guard generation == token else { throw CancellationError() }
                                if chunk.isFinal {
                                    timingSink?.speechPlaybackDidReceiveTiming(.init(itemID: item.id, segmentID: item.segmentID,
                                        itemIndex: index, durationSeconds: chunk.durationSeconds / currentSettings.rateMultiplier,
                                        source: .pocketStream, sourceAudioDurationSeconds: chunk.durationSeconds))
                                    if let track = RSVPReadAlongCueTrackBuilder().weightedFallbackTrack(item: item, itemIndex: index,
                                        settings: .default, sourceAudioDurationSeconds: chunk.durationSeconds) {
                                        timingSink?.speechPlaybackDidReceiveWordCueTrack(track)
                                    }
                                }
                                try await PocketAudioStream.send(chunk, to: pair.continuation)
                            }
                            pair.continuation.finish()
                        } catch { pair.continuation.finish(throwing: error) }
                    }
                    defer { relay.cancel() }
                    try await playback.play(item: item, chunks: pair.stream, settings: currentSettings, willSpeak: willSpeak)
                    await relay.value
                    guard generation == token else { throw CancellationError() }
                    playbackUnderrunCount += playback.underrunCount
                    timingSink?.speechPlaybackDidFinishItem(itemID: item.id, segmentID: item.segmentID, itemIndex: index)
                    activeRequestID = nil
                } catch {
                    if generation == token { playback.stop(); activeRequestID = nil }
                    await runtime.cancel(requestID: requestID)
                    if generation != token || Task.isCancelled { throw CancellationError() }
                    throw error
                }
            }
        } onCancel: {
            Task { @MainActor in
                guard self.generation == token else { return }
                await self.stop()
            }
        }
    }

    public func stop() async {
        generation = UUID()
        playback.stop()
        let request = activeRequestID
        activeRequestID = nil
        await fallback.stop()
        if let request { await runtime.cancel(requestID: request) }
    }
}

enum PocketSpeechChunker {
    static func items(from source: [SpeechPlaybackItem]) -> [SpeechPlaybackItem] {
        source.flatMap { item in
            guard item.text.count > 800 else { return [item] }
            var remaining = item.text[...]
            var chunks: [SpeechPlaybackItem] = []
            while !remaining.isEmpty {
                var end = remaining.index(remaining.startIndex, offsetBy: 800, limitedBy: remaining.endIndex) ?? remaining.endIndex
                if end != remaining.endIndex, let boundary = remaining[..<end].lastIndex(where: { $0.isWhitespace }) {
                    end = remaining.index(after: boundary)
                }
                let text = String(remaining[..<end]).trimmingCharacters(in: .whitespacesAndNewlines)
                if !text.isEmpty {
                    chunks.append(.init(id: "\(item.id)#pocket-\(chunks.count)", segmentID: item.segmentID,
                        sourceText: text, text: text, audioCachePolicy: .transient))
                }
                remaining = remaining[end...]
            }
            return chunks
        }
    }
}

/// The existing PCM player supplies pitch-preserving pace, volume, metering,
/// output-device handling and playback-clock progress for both neural engines.
@MainActor
final class PocketStreamPlayback: PocketAudioPlaying {
    private let player = QwenAudioPlayback()
    private(set) var underrunCount = 0
    var timingSink: (any SpeechPlaybackTimingSink)? {
        get { player.timingSink }
        set { player.timingSink = newValue }
    }
    var visualizationSink: (any SpeechPlaybackVisualizationSink)? {
        get { player.visualizationSink }
        set { player.visualizationSink = newValue }
    }
    func play(item: SpeechPlaybackItem, chunks: AsyncThrowingStream<QwenStreamingAudioChunk, Error>, settings: SpeechSettings,
              willSpeak: @escaping @MainActor (SpeechPlaybackItem) async -> Void) async throws {
        underrunCount = 0
        try await player.playStream(item: item, chunks: chunks, rateMultiplier: settings.rateMultiplier, volume: settings.volume,
            minimumBufferedPlaybackSeconds: 0.16, targetRunwayPlaybackSeconds: 0.24,
            onStartItem: willSpeak, onBufferEnqueue: { _ in }, onRenderStart: {}, onFinish: {}, onItemEnd: { _ in })
        underrunCount = player.consumePerformanceEvents().filter { $0.kind == .underrun }.count
    }
    func stop() { player.stop() }
}
