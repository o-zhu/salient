import AVFoundation
import XCTest

@testable import SalientCore

final class QwenAudioPostProcessorTests: XCTestCase {
    func testEdgePaddingStaysBelowPerceptibleInterItemPauseBudget() {
        XCTAssertEqual(QwenAudioPostProcessor.edgePaddingSeconds, 0.04)
    }

    func testFailedPostprocessingPreservesExistingDestination() throws {
        let root = temporaryRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let source = root.appendingPathComponent("valid-source.wav")
        let destination = root.appendingPathComponent("known-good.wav")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        try writeFixture(to: source)
        try writeFixture(to: destination)
        let original = try Data(contentsOf: destination)

        XCTAssertThrowsError(
            try QwenAudioPostProcessor.writeTrimmedCopy(from: source, to: destination) { _, _ in
                throw SyntheticPromotionError()
            }
        )

        XCTAssertEqual(try Data(contentsOf: destination), original)
        XCTAssertGreaterThan(try XCTUnwrap(QwenAudioPostProcessor.durationSeconds(of: destination)), 0)
    }

    func testTrimmedAudioUsesZeroValuedFadeEndpoints() throws {
        let root = temporaryRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let source = root.appendingPathComponent("source.wav")
        let destination = root.appendingPathComponent("trimmed.wav")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        try writeFadeFixture(to: source)

        try QwenAudioPostProcessor.writeTrimmedCopy(from: source, to: destination)

        XCTAssertTrue(QwenAudioPostProcessor.isWaveContainer(at: destination))
        XCTAssertEqual(String(decoding: try Data(contentsOf: destination).prefix(4), as: UTF8.self), "RIFF")
        let file = try AVAudioFile(forReading: destination)
        let buffer = try XCTUnwrap(
            AVAudioPCMBuffer(pcmFormat: file.processingFormat, frameCapacity: AVAudioFrameCount(file.length))
        )
        try file.read(into: buffer)
        let samples = try XCTUnwrap(buffer.floatChannelData?[0])
        XCTAssertGreaterThan(buffer.frameLength, 1)
        XCTAssertEqual(samples[0], 0, accuracy: 0.000_001)
        XCTAssertEqual(samples[Int(buffer.frameLength) - 1], 0, accuracy: 0.000_001)
        let duration = Double(buffer.frameLength) / file.processingFormat.sampleRate
        XCTAssertGreaterThan(duration, 0.25)
        XCTAssertLessThan(duration, 0.5)
    }

    func testSilentAudioIsRejected() throws {
        let root = temporaryRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let source = root.appendingPathComponent("silent.wav")
        let destination = root.appendingPathComponent("rejected.wav")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        try writeSilentFixture(to: source)

        XCTAssertFalse(QwenAudioPostProcessor.hasAudibleSignal(at: source))
        XCTAssertThrowsError(
            try QwenAudioPostProcessor.writeTrimmedCopy(from: source, to: destination)
        )
        XCTAssertFalse(FileManager.default.fileExists(atPath: destination.path))
    }

    func testCAFContainerDisguisedAsWAVIsRejected() throws {
        let root = temporaryRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let caf = root.appendingPathComponent("source.caf")
        let disguised = root.appendingPathComponent("source.wav")
        try writeFixture(to: caf)
        try FileManager.default.copyItem(at: caf, to: disguised)

        XCTAssertFalse(QwenAudioPostProcessor.isWaveContainer(at: disguised))
        XCTAssertNotNil(QwenAudioPostProcessor.durationSeconds(of: disguised))
    }

    func testDeEsserReducesSibilanceWithoutDullingVoiceBand() throws {
        let root = temporaryRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let source = root.appendingPathComponent("sibilant-source.wav")
        let destination = root.appendingPathComponent("de-essed.wav")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        try writeSibilanceFixture(to: source)

        try QwenAudioPostProcessor.writeTrimmedCopy(from: source, to: destination)

        let sourceSamples = try readSamples(from: source)
        let outputSamples = try readSamples(from: destination)
        let sampleRate = 24_000.0
        let measurementRange = Int(sampleRate * 0.25)..<Int(sampleRate * 0.45)
        let sourceVoice = sinusoidAmplitude(
            in: sourceSamples,
            frequency: 220,
            sampleRate: sampleRate,
            range: measurementRange
        )
        let outputVoice = sinusoidAmplitude(
            in: outputSamples,
            frequency: 220,
            sampleRate: sampleRate,
            range: measurementRange
        )
        let sourceSibilance = sinusoidAmplitude(
            in: sourceSamples,
            frequency: 7_000,
            sampleRate: sampleRate,
            range: measurementRange
        )
        let outputSibilance = sinusoidAmplitude(
            in: outputSamples,
            frequency: 7_000,
            sampleRate: sampleRate,
            range: measurementRange
        )

        XCTAssertLessThan(outputSibilance, sourceSibilance * 0.8)
        XCTAssertGreaterThan(outputVoice, sourceVoice * 0.95)
    }

    func testDeEsserStrengthControlsMaximumReductionAndCanBeDisabled() throws {
        let root = temporaryRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let source = root.appendingPathComponent("sibilant-source.wav")
        let disabled = root.appendingPathComponent("de-esser-off.wav")
        let moderate = root.appendingPathComponent("de-esser-12db.wav")
        let strongest = root.appendingPathComponent("de-esser-strongest.wav")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        try writeSibilanceFixture(to: source)

        try QwenAudioPostProcessor.writeTrimmedCopy(
            from: source,
            to: disabled,
            qwenDeEsserStrengthDecibels: 0
        )
        try QwenAudioPostProcessor.writeTrimmedCopy(
            from: source,
            to: moderate,
            qwenDeEsserStrengthDecibels: 12
        )
        try QwenAudioPostProcessor.writeTrimmedCopy(
            from: source,
            to: strongest,
            qwenDeEsserStrengthDecibels: SpeechSettings.maximumQwenDeEsserStrengthDecibels
        )

        let sampleRate = 24_000.0
        let measurementRange = Int(sampleRate * 0.25)..<Int(sampleRate * 0.45)
        let sourceSibilance = sinusoidAmplitude(
            in: try readSamples(from: source),
            frequency: 7_000,
            sampleRate: sampleRate,
            range: measurementRange
        )
        let disabledSibilance = sinusoidAmplitude(
            in: try readSamples(from: disabled),
            frequency: 7_000,
            sampleRate: sampleRate,
            range: measurementRange
        )
        let strongestSibilance = sinusoidAmplitude(
            in: try readSamples(from: strongest),
            frequency: 7_000,
            sampleRate: sampleRate,
            range: measurementRange
        )
        let moderateSibilance = sinusoidAmplitude(
            in: try readSamples(from: moderate),
            frequency: 7_000,
            sampleRate: sampleRate,
            range: measurementRange
        )

        XCTAssertEqual(disabledSibilance, sourceSibilance, accuracy: 0.001)
        XCTAssertLessThan(moderateSibilance, disabledSibilance * 0.4)
        XCTAssertLessThan(strongestSibilance, disabledSibilance * 0.3)
        XCTAssertLessThan(strongestSibilance, moderateSibilance * 0.75)
    }

    private func temporaryRoot() -> URL {
        FileManager.default.temporaryDirectory
            .appendingPathComponent("salient-qwen-postprocessor-tests-\(UUID().uuidString)", isDirectory: true)
    }

    private func writeFixture(to url: URL) throws {
        let sampleRate = 24_000.0
        let format = AVAudioFormat(standardFormatWithSampleRate: sampleRate, channels: 1)!
        let file = try AVAudioFile(forWriting: url, settings: format.settings)
        let frameCount = AVAudioFrameCount(sampleRate * 0.6)
        let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: frameCount)!
        buffer.frameLength = frameCount
        let samples = buffer.floatChannelData![0]
        for frame in 0..<Int(frameCount) {
            let time = Double(frame) / sampleRate
            samples[frame] =
                time >= 0.2 && time < 0.4
                ? Float(sin(2 * Double.pi * 440 * time) * 0.1)
                : 0
        }
        try file.write(from: buffer)
    }

    private func writeFadeFixture(to url: URL) throws {
        let sampleRate = 24_000.0
        let format = AVAudioFormat(standardFormatWithSampleRate: sampleRate, channels: 1)!
        let file = try AVAudioFile(forWriting: url, settings: format.settings)
        let frameCount = AVAudioFrameCount(sampleRate * 0.6)
        let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: frameCount)!
        buffer.frameLength = frameCount
        let samples = buffer.floatChannelData![0]
        for frame in 0..<Int(frameCount) {
            let time = Double(frame) / sampleRate
            samples[frame] =
                time < 0.30
                ? Float(cos(2 * Double.pi * 440 * time) * 0.1)
                : 0
        }
        try file.write(from: buffer)
    }

    private func writeSilentFixture(to url: URL) throws {
        let format = AVAudioFormat(standardFormatWithSampleRate: 24_000, channels: 1)!
        let file = try AVAudioFile(forWriting: url, settings: format.settings)
        let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 2_400)!
        buffer.frameLength = 2_400
        let samples = buffer.floatChannelData![0]
        for frame in 0..<2_400 {
            samples[frame] = 0
        }
        try file.write(from: buffer)
    }

    private func writeSibilanceFixture(to url: URL) throws {
        let sampleRate = 24_000.0
        let format = AVAudioFormat(standardFormatWithSampleRate: sampleRate, channels: 1)!
        let file = try AVAudioFile(forWriting: url, settings: format.settings)
        let frameCount = AVAudioFrameCount(sampleRate * 0.7)
        let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: frameCount)!
        buffer.frameLength = frameCount
        let samples = buffer.floatChannelData![0]
        for frame in 0..<Int(frameCount) {
            let time = Double(frame) / sampleRate
            let voice = sin(2 * Double.pi * 220 * time) * 0.05
            let sibilance =
                time >= 0.2 && time < 0.5
                ? sin(2 * Double.pi * 7_000 * time) * 0.20
                : 0
            samples[frame] = Float(voice + sibilance)
        }
        try file.write(from: buffer)
    }

    private func readSamples(from url: URL) throws -> [Float] {
        let file = try AVAudioFile(forReading: url)
        let buffer = try XCTUnwrap(
            AVAudioPCMBuffer(pcmFormat: file.processingFormat, frameCapacity: AVAudioFrameCount(file.length))
        )
        try file.read(into: buffer)
        let samples = try XCTUnwrap(buffer.floatChannelData?[0])
        return Array(UnsafeBufferPointer(start: samples, count: Int(buffer.frameLength)))
    }

    private func sinusoidAmplitude(
        in samples: [Float],
        frequency: Double,
        sampleRate: Double,
        range: Range<Int>
    ) -> Double {
        var sineProjection = 0.0
        var cosineProjection = 0.0
        for frame in range {
            let phase = 2 * Double.pi * frequency * Double(frame) / sampleRate
            sineProjection += Double(samples[frame]) * sin(phase)
            cosineProjection += Double(samples[frame]) * cos(phase)
        }
        return 2 * hypot(sineProjection, cosineProjection) / Double(range.count)
    }
}

private struct SyntheticPromotionError: Error {}
