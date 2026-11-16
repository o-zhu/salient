import Foundation

/// A bounded PCM handoff that preserves speech when cold audio-device setup
/// temporarily runs behind the native generator.
enum PocketAudioStream {
    typealias Stream = AsyncThrowingStream<QwenStreamingAudioChunk, Error>

    static func makeStream() -> (stream: Stream, continuation: Stream.Continuation) {
        Stream.makeStream(bufferingPolicy: .bufferingOldest(128))
    }

    static func send(_ chunk: QwenStreamingAudioChunk, to continuation: Stream.Continuation) async throws {
        while true {
            try Task.checkCancellation()
            switch continuation.yield(chunk) {
            case .enqueued:
                return
            case .dropped:
                // bufferingOldest rejects this new value, leaving queued values
                // intact. Retain and retry it; never skip or duplicate PCM.
                // Sleep yields the actor and remains promptly cancellable.
                try await Task.sleep(for: .milliseconds(5))
            case .terminated:
                throw CancellationError()
            @unknown default:
                throw PocketRuntimeError.invalidAudio
            }
        }
    }
}
