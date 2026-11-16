import AVFoundation
import Foundation

@MainActor
public final class AVFoundationSpeechBackend: NSObject, SpeechBackend, SpeechPlaybackTimingReporting, @preconcurrency AVSpeechSynthesizerDelegate {
    private let synthesizer = AVSpeechSynthesizer()
    private var continuations: [ObjectIdentifier: CheckedContinuation<Void, Error>] = [:]
    private var itemContexts: [ObjectIdentifier: AppleSpeechItemContext] = [:]
    public var settings: SpeechSettings
    public weak var timingSink: (any SpeechPlaybackTimingSink)?

    public init(settings: SpeechSettings = .default) {
        self.settings = settings.clamped
        super.init()
        synthesizer.delegate = self
    }

    public static func availableVoices() -> [SpeechVoiceOption] {
        SpeechVoiceOption.studyVoices(from: AVSpeechSynthesisVoice.speechVoices()
            .map { voice in
                SpeechVoiceOption(
                    identifier: voice.identifier, name: voice.name, language: voice.language,
                    quality: .init(rawValue: voice.quality.rawValue) ?? .standard,
                    isNovelty: voice.voiceTraits.contains(.isNoveltyVoice),
                    isPersonal: voice.voiceTraits.contains(.isPersonalVoice)
                )
            })
    }

    public func speak(_ text: String) async throws {
        try await speak(text, context: nil)
    }

    private func speak(
        _ text: String,
        context: AppleSpeechItemContext?
    ) async throws {
        try Task.checkCancellation()

        let utterance = Self.makeUtterance(text, settings: settings)

        let identifier = ObjectIdentifier(utterance)
        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
                if Task.isCancelled {
                    continuation.resume(throwing: CancellationError())
                    return
                }
                continuations[identifier] = continuation
                itemContexts[identifier] = context
                synthesizer.speak(utterance)
            }
        } onCancel: {
            Task { @MainActor in
                self.cancelUtterance(identifier)
            }
        }
    }

    static func makeUtterance(_ text: String, settings: SpeechSettings) -> AVSpeechUtterance {
        let currentSettings = settings.clamped
        let utterance = AVSpeechUtterance(string: text)
        utterance.rate = min(
            AVSpeechUtteranceMaximumSpeechRate,
            max(AVSpeechUtteranceMinimumSpeechRate, AVSpeechUtteranceDefaultSpeechRate * Float(currentSettings.rateMultiplier))
        )
        utterance.volume = Float(currentSettings.volume)
        utterance.pitchMultiplier = Float(currentSettings.pitchMultiplier)
        if let voiceIdentifier = currentSettings.voiceIdentifier,
           let voice = AVSpeechSynthesisVoice(identifier: voiceIdentifier) {
            utterance.voice = voice
        }
        // Salient exposes its own voice, pace and volume controls. Letting
        // VoiceOver silently override these would make those controls misleading.
        utterance.prefersAssistiveTechnologySettings = false
        return utterance
    }

    public func speak(
        _ items: [SpeechPlaybackItem],
        willSpeak: @escaping @MainActor (SpeechPlaybackItem) async -> Void
    ) async throws {
        timingSink?.speechPlaybackWillUseFinalItems(items)
        let playbackID = UUID()
        for (index, item) in items.enumerated() {
            try Task.checkCancellation()
            await willSpeak(item)
            let startedAt = Date()
            let tokenKeys = RSVPReadingPlanBuilder(settings: .default)
                .plan(from: [item])
                .frames
                .map { Self.alignmentKey($0.displayText) }
            try await speak(item.text, context: AppleSpeechItemContext(
                playbackID: playbackID,
                item: item,
                itemIndex: index,
                startedAt: startedAt,
                playbackRate: settings.clamped.rateMultiplier,
                tokenKeys: tokenKeys
            ))
            let duration = Date().timeIntervalSince(startedAt)
            if duration.isFinite, duration > 0 {
                timingSink?.speechPlaybackDidReceiveTiming(SpeechPlaybackItemTiming(
                    itemID: item.id,
                    segmentID: item.segmentID,
                    itemIndex: index,
                    durationSeconds: duration,
                    source: .appleObserved
                ))
            }
            timingSink?.speechPlaybackDidFinishItem(
                itemID: item.id,
                segmentID: item.segmentID,
                itemIndex: index
            )
        }
    }

    public func stop() async {
        let pending = Array(continuations.values)
        continuations.removeAll()
        itemContexts.removeAll()
        synthesizer.stopSpeaking(at: .immediate)
        for continuation in pending {
            continuation.resume(throwing: CancellationError())
        }
    }

    public func speechSynthesizer(_ synthesizer: AVSpeechSynthesizer, didFinish utterance: AVSpeechUtterance) {
        let identifier = ObjectIdentifier(utterance)
        itemContexts.removeValue(forKey: identifier)
        continuations.removeValue(forKey: identifier)?.resume()
    }

    public func speechSynthesizer(_ synthesizer: AVSpeechSynthesizer, didCancel utterance: AVSpeechUtterance) {
        let identifier = ObjectIdentifier(utterance)
        itemContexts.removeValue(forKey: identifier)
        continuations.removeValue(forKey: identifier)?.resume(throwing: CancellationError())
    }

    public func speechSynthesizer(
        _ synthesizer: AVSpeechSynthesizer,
        willSpeakRangeOfSpeechString characterRange: NSRange,
        utterance: AVSpeechUtterance
    ) {
        let identifier = ObjectIdentifier(utterance)
        guard var context = itemContexts[identifier] else { return }
        let speech = utterance.speechString as NSString
        guard NSMaxRange(characterRange) <= speech.length else { return }
        let key = Self.alignmentKey(speech.substring(with: characterRange))
        let searchRange = context.nextTokenSearchIndex..<context.tokenKeys.count
        let matchedIndex = context.tokenKeys[searchRange].firstIndex(of: key)
            ?? (context.nextTokenSearchIndex < context.tokenKeys.count
                ? context.nextTokenSearchIndex
                : nil)
        guard let tokenIndex = matchedIndex else { return }
        context.nextTokenSearchIndex = min(context.tokenKeys.count, tokenIndex + 1)
        itemContexts[identifier] = context
        timingSink?.speechPlaybackDidReceiveProgress(SpeechPlaybackProgress(
            playbackID: context.playbackID,
            itemID: context.item.id,
            segmentID: context.item.segmentID,
            itemIndex: context.itemIndex,
            sourcePositionSeconds: Date().timeIntervalSince(context.startedAt),
            sourceDurationSeconds: 0,
            currentTokenIndex: tokenIndex,
            playbackRate: context.playbackRate
        ))
    }

    private func cancelUtterance(_ identifier: ObjectIdentifier) {
        guard let continuation = continuations.removeValue(forKey: identifier) else { return }
        itemContexts.removeValue(forKey: identifier)
        synthesizer.stopSpeaking(at: .immediate)
        continuation.resume(throwing: CancellationError())
    }

    private static func alignmentKey(_ text: String) -> String {
        text.lowercased().filter { character in
            character.isLetter || character.isNumber || character == "'"
        }
    }
}

private struct AppleSpeechItemContext {
    var playbackID: UUID
    var item: SpeechPlaybackItem
    var itemIndex: Int
    var startedAt: Date
    var playbackRate: Double
    var tokenKeys: [String]
    var nextTokenSearchIndex = 0
}
