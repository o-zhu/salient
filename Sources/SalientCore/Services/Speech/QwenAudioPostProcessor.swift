import AVFoundation
import Accelerate
import Foundation

public enum QwenAudioPostProcessor {
    static let edgePaddingSeconds = 0.04
    static let deEsserCrossoverHz = 4_000.0
    static let deEsserThreshold: Float = 0.012

    public static func durationSeconds(of url: URL) -> Double? {
        guard let file = try? AVAudioFile(forReading: url) else {
            return nil
        }
        let sampleRate = file.fileFormat.sampleRate
        guard sampleRate > 0 else { return nil }
        return Double(file.length) / sampleRate
    }

    public static func audibleBoundsSeconds(of url: URL) -> (start: Double, end: Double)? {
        guard let file = try? AVAudioFile(forReading: url),
            let buffer = AVAudioPCMBuffer(
                pcmFormat: file.processingFormat,
                frameCapacity: AVAudioFrameCount(file.length)
            )
        else {
            return nil
        }
        try? file.read(into: buffer)
        let sampleRate = file.processingFormat.sampleRate
        guard sampleRate > 0,
            let range = audibleFrameRange(in: buffer, sampleRate: sampleRate)
        else {
            return nil
        }
        return (
            start: Double(range.lowerBound) / sampleRate,
            end: Double(range.upperBound) / sampleRate
        )
    }

    public static func hasAudibleSignal(at url: URL) -> Bool {
        guard let file = try? AVAudioFile(forReading: url), file.length > 0 else {
            return false
        }
        let format = file.processingFormat
        let chunkFrames: AVAudioFrameCount = 8_192
        while file.framePosition < file.length {
            let remaining = file.length - file.framePosition
            let capacity = AVAudioFrameCount(min(Int64(chunkFrames), remaining))
            guard let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: capacity) else {
                return false
            }
            do {
                try file.read(into: buffer)
            } catch {
                return false
            }
            guard let channels = buffer.floatChannelData else { return false }
            let frameCount = vDSP_Length(buffer.frameLength)
            guard frameCount > 0 else { break }
            for channel in 0..<Int(format.channelCount) {
                var peak: Float = 0
                vDSP_maxmgv(channels[channel], 1, &peak, frameCount)
                if peak >= 0.0005 {
                    return true
                }
            }
        }
        return false
    }

    public static func isWaveContainer(at url: URL) -> Bool {
        guard let handle = try? FileHandle(forReadingFrom: url) else { return false }
        defer { try? handle.close() }
        guard let header = try? handle.read(upToCount: 12),
            header.count == 12
        else {
            return false
        }
        let container = String(decoding: header.prefix(4), as: UTF8.self)
        let form = String(decoding: header.suffix(4), as: UTF8.self)
        return (container == "RIFF" || container == "RF64") && form == "WAVE"
    }

    public static func writeTrimmedCopy(
        from source: URL,
        to destination: URL,
        qwenDeEsserStrengthDecibels: Double = SpeechSettings.defaultQwenDeEsserStrengthDecibels
    ) throws {
        try writeTrimmedCopy(
            from: source,
            to: destination,
            qwenDeEsserStrengthDecibels: qwenDeEsserStrengthDecibels
        ) { temporaryURL, destinationURL in
            if FileManager.default.fileExists(atPath: destinationURL.path) {
                _ = try FileManager.default.replaceItemAt(destinationURL, withItemAt: temporaryURL)
            } else {
                try FileManager.default.moveItem(at: temporaryURL, to: destinationURL)
            }
        }
    }

    static func writeTrimmedCopy(
        from source: URL,
        to destination: URL,
        qwenDeEsserStrengthDecibels: Double = SpeechSettings.defaultQwenDeEsserStrengthDecibels,
        promote: (URL, URL) throws -> Void
    ) throws {
        let parent = destination.deletingLastPathComponent()
        try FileManager.default.createDirectory(at: parent, withIntermediateDirectories: true)
        // AVAudioFile chooses its container from the extension. Retain `.wav`
        // on the staging file so a CAF payload is never published as a WAV.
        let temporaryURL = parent.appendingPathComponent(
            ".\(destination.lastPathComponent).\(UUID().uuidString).processing.wav"
        )
        defer { try? FileManager.default.removeItem(at: temporaryURL) }

        try writeTrimmedCopyNonatomically(
            from: source,
            to: temporaryURL,
            qwenDeEsserStrengthDecibels: qwenDeEsserStrengthDecibels
        )
        guard let duration = durationSeconds(of: temporaryURL),
            duration.isFinite,
            duration > 0,
            isWaveContainer(at: temporaryURL),
            hasAudibleSignal(at: temporaryURL)
        else {
            throw QwenRuntimeError.commandFailed("Qwen audio post-processing produced invalid audio.")
        }
        try promote(temporaryURL, destination)
    }

    private static func writeTrimmedCopyNonatomically(
        from source: URL,
        to destination: URL,
        qwenDeEsserStrengthDecibels: Double
    ) throws {
        guard let file = try? AVAudioFile(forReading: source),
            let buffer = AVAudioPCMBuffer(
                pcmFormat: file.processingFormat,
                frameCapacity: AVAudioFrameCount(file.length)
            )
        else {
            throw QwenRuntimeError.commandFailed("Qwen audio could not be decoded for post-processing.")
        }

        try file.read(into: buffer)
        guard let range = audibleFrameRange(in: buffer, sampleRate: file.processingFormat.sampleRate) else {
            throw QwenRuntimeError.commandFailed("Qwen synthesis produced silent audio.")
        }

        let isTrimmed = range.lowerBound != 0 || range.upperBound != Int(buffer.frameLength)
        guard let output = copyFrames(buffer, range: range, applyEdgeFade: isTrimmed) else {
            throw QwenRuntimeError.commandFailed("Qwen audio could not be prepared for post-processing.")
        }
        applyDeEsser(to: output, maximumReductionDecibels: qwenDeEsserStrengthDecibels)

        let outputFile = try AVAudioFile(forWriting: destination, settings: file.fileFormat.settings)
        try outputFile.write(from: output)
    }

    private static func audibleFrameRange(in buffer: AVAudioPCMBuffer, sampleRate: Double) -> Range<Int>? {
        guard let channelData = buffer.floatChannelData else {
            return nil
        }
        let frameCount = Int(buffer.frameLength)
        guard frameCount > 0 else { return nil }
        let channelCount = Int(buffer.format.channelCount)
        let threshold: Float = 0.0005
        // Preserve enough context for consonant onsets and the short safety
        // fade without inserting a perceptible pause at every chunk boundary.
        let keepFrames = max(0, Int(sampleRate * edgePaddingSeconds))

        var peakByFrame = [Float](repeating: 0, count: frameCount)
        vDSP_vabs(channelData[0], 1, &peakByFrame, 1, vDSP_Length(frameCount))
        if channelCount > 1 {
            var channelMagnitudes = [Float](repeating: 0, count: frameCount)
            for channel in 1..<channelCount {
                vDSP_vabs(channelData[channel], 1, &channelMagnitudes, 1, vDSP_Length(frameCount))
                vDSP_vmax(
                    peakByFrame, 1,
                    channelMagnitudes, 1,
                    &peakByFrame, 1,
                    vDSP_Length(frameCount)
                )
            }
        }

        var firstAudible: Int?
        var lastAudible: Int?
        for (frame, peak) in peakByFrame.enumerated() {
            if peak >= threshold {
                if firstAudible == nil {
                    firstAudible = frame
                }
                lastAudible = frame
            }
        }

        guard let firstAudible, let lastAudible else {
            return nil
        }

        let lower = max(0, firstAudible - keepFrames)
        let upper = min(frameCount, lastAudible + keepFrames + 1)
        return lower..<upper
    }

    private static func copyFrames(
        _ buffer: AVAudioPCMBuffer,
        range: Range<Int>,
        applyEdgeFade: Bool
    ) -> AVAudioPCMBuffer? {
        guard let sourceData = buffer.floatChannelData,
            let output = AVAudioPCMBuffer(
                pcmFormat: buffer.format,
                frameCapacity: AVAudioFrameCount(range.count)
            ),
            let outputData = output.floatChannelData
        else {
            return nil
        }
        output.frameLength = AVAudioFrameCount(range.count)
        let fadeFrames =
            applyEdgeFade
            ? min(range.count / 2, max(0, Int(buffer.format.sampleRate * 0.005)))
            : 0
        let fadeIn = (0..<fadeFrames).map { frame in
            fadeFrames == 1 ? 0 : Float(frame) / Float(fadeFrames - 1)
        }
        let fadeOut = Array(fadeIn.reversed())
        for channel in 0..<Int(buffer.format.channelCount) {
            outputData[channel].update(from: sourceData[channel].advanced(by: range.lowerBound), count: range.count)
            if fadeFrames > 0 {
                fadeIn.withUnsafeBufferPointer { ramp in
                    vDSP_vmul(outputData[channel], 1, ramp.baseAddress!, 1, outputData[channel], 1, vDSP_Length(fadeFrames))
                }
                fadeOut.withUnsafeBufferPointer { ramp in
                    vDSP_vmul(
                        outputData[channel].advanced(by: range.count - fadeFrames), 1,
                        ramp.baseAddress!, 1,
                        outputData[channel].advanced(by: range.count - fadeFrames), 1,
                        vDSP_Length(fadeFrames)
                    )
                }
            }
        }
        return output
    }

    /// A linked split-band de-esser. Two cascaded Butterworth biquads form
    /// fourth-order Linkwitz-Riley low/high branches so the selected reduction
    /// remains effective well above 4 kHz without changing stereo balance.
    static func applyDeEsser(
        to buffer: AVAudioPCMBuffer,
        maximumReductionDecibels: Double = SpeechSettings.defaultQwenDeEsserStrengthDecibels
    ) {
        guard let channels = buffer.floatChannelData else { return }
        let sampleRate = buffer.format.sampleRate
        let frameCount = Int(buffer.frameLength)
        let channelCount = Int(buffer.format.channelCount)
        let clampedMaximumReduction = min(
            max(maximumReductionDecibels, 0),
            SpeechSettings.maximumQwenDeEsserStrengthDecibels
        )
        guard clampedMaximumReduction > 0,
            sampleRate > deEsserCrossoverHz * 2,
            frameCount > 0,
            channelCount > 0
        else { return }

        let lowPassCoefficients = DeEsserBiquadCoefficients.lowPass(
            cutoffHz: deEsserCrossoverHz,
            sampleRate: sampleRate
        )
        let highPassCoefficients = DeEsserBiquadCoefficients.highPass(
            cutoffHz: deEsserCrossoverHz,
            sampleRate: sampleRate
        )
        let attackCoefficient = Float(exp(-1 / (0.002 * sampleRate)))
        let releaseCoefficient = Float(exp(-1 / (0.070 * sampleRate)))
        let ratio = 4.0
        let crossoverSectionCount = 2
        var lowPassStates = Array(
            repeating: Array(repeating: DeEsserBiquadState(), count: crossoverSectionCount),
            count: channelCount
        )
        var highPassStates = Array(
            repeating: Array(repeating: DeEsserBiquadState(), count: crossoverSectionCount),
            count: channelCount
        )
        var lowBand = [Float](repeating: 0, count: channelCount)
        var highBand = [Float](repeating: 0, count: channelCount)
        var envelope: Float = 0

        for frame in 0..<frameCount {
            var detector: Float = 0
            for channel in 0..<channelCount {
                let sample = channels[channel][frame]
                var lowSample = sample
                var highSample = sample
                for section in 0..<crossoverSectionCount {
                    lowSample = lowPassStates[channel][section].process(
                        lowSample,
                        coefficients: lowPassCoefficients
                    )
                    highSample = highPassStates[channel][section].process(
                        highSample,
                        coefficients: highPassCoefficients
                    )
                }
                lowBand[channel] = lowSample
                highBand[channel] = highSample
                detector = max(detector, abs(highBand[channel]))
            }

            let envelopeCoefficient = detector > envelope ? attackCoefficient : releaseCoefficient
            envelope = envelopeCoefficient * envelope + (1 - envelopeCoefficient) * detector
            let levelRatio = max(1, Double(envelope / deEsserThreshold))
            let overThresholdDecibels = 20 * log10(levelRatio)
            let reductionDecibels = min(
                clampedMaximumReduction,
                overThresholdDecibels * (1 - 1 / ratio)
            )
            let highBandGain = Float(pow(10, -reductionDecibels / 20))

            for channel in 0..<channelCount {
                channels[channel][frame] = lowBand[channel] + highBand[channel] * highBandGain
            }
        }
    }
}

private struct DeEsserBiquadCoefficients {
    var b0: Float
    var b1: Float
    var b2: Float
    var a1: Float
    var a2: Float

    static func lowPass(cutoffHz: Double, sampleRate: Double) -> Self {
        coefficients(cutoffHz: cutoffHz, sampleRate: sampleRate, isHighPass: false)
    }

    static func highPass(cutoffHz: Double, sampleRate: Double) -> Self {
        coefficients(cutoffHz: cutoffHz, sampleRate: sampleRate, isHighPass: true)
    }

    private static func coefficients(
        cutoffHz: Double,
        sampleRate: Double,
        isHighPass: Bool
    ) -> Self {
        let omega = 2 * Double.pi * cutoffHz / sampleRate
        let cosine = cos(omega)
        let alpha = sin(omega) / (2 * sqrt(0.5))
        let a0 = 1 + alpha
        let numerator = isHighPass ? 1 + cosine : 1 - cosine
        return Self(
            b0: Float((numerator / 2) / a0),
            b1: Float((isHighPass ? -numerator : numerator) / a0),
            b2: Float((numerator / 2) / a0),
            a1: Float((-2 * cosine) / a0),
            a2: Float((1 - alpha) / a0)
        )
    }
}

private struct DeEsserBiquadState {
    var x1: Float = 0
    var x2: Float = 0
    var y1: Float = 0
    var y2: Float = 0

    mutating func process(
        _ input: Float,
        coefficients: DeEsserBiquadCoefficients
    ) -> Float {
        let output =
            coefficients.b0 * input
            + coefficients.b1 * x1
            + coefficients.b2 * x2
            - coefficients.a1 * y1
            - coefficients.a2 * y2
        x2 = x1
        x1 = input
        y2 = y1
        y1 = output
        return output
    }
}
