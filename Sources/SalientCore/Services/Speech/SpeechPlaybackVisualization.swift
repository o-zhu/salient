import Foundation

public struct SpeechPlaybackVisualizationFrame: Equatable, Sendable {
    public var level: Double
    public var barLevels: [Double]
    public var brightness: Double

    public init(level: Double, barLevels: [Double], brightness: Double? = nil) {
        self.level = Self.clamped(level)
        self.barLevels = barLevels.map(Self.clamped)
        self.brightness = Self.clamped(brightness ?? Self.estimatedBrightness(from: self.barLevels))
    }

    public static func levelOnly(_ level: Double, barCount: Int = 16) -> SpeechPlaybackVisualizationFrame {
        let clampedLevel = Self.clamped(level)
        let profile = (0..<max(1, barCount)).map { index -> Double in
            let phase = Double(index) * 1.11
            return clampedLevel * (0.56 + 0.22 * (sin(phase) + 1))
        }
        return SpeechPlaybackVisualizationFrame(level: clampedLevel, barLevels: profile)
    }

    private static func clamped(_ value: Double) -> Double {
        guard value.isFinite else { return 0 }
        return min(1, max(0, value))
    }

    private static func estimatedBrightness(from barLevels: [Double]) -> Double {
        guard barLevels.count > 1 else { return 0 }
        var weighted = 0.0
        var total = 0.0
        for (index, level) in barLevels.enumerated() {
            let clampedLevel = Self.clamped(level)
            weighted += clampedLevel * Double(index)
            total += clampedLevel
        }
        guard total > 0 else { return 0 }
        return weighted / total / Double(barLevels.count - 1)
    }
}

@MainActor
public protocol SpeechPlaybackVisualizationSink: AnyObject {
    func speechPlaybackVisualizationDidStart()
    func speechPlaybackVisualizationAudioDidStart()
    func speechPlaybackVisualizationAudioDidStop()
    func speechPlaybackVisualizationLevelDidChange(_ level: Double)
    func speechPlaybackVisualizationFrameDidChange(_ frame: SpeechPlaybackVisualizationFrame)
    func speechPlaybackVisualizationDidEnd()
}

public extension SpeechPlaybackVisualizationSink {
    func speechPlaybackVisualizationAudioDidStart() {}
    func speechPlaybackVisualizationAudioDidStop() {}
    func speechPlaybackVisualizationFrameDidChange(_ frame: SpeechPlaybackVisualizationFrame) {
        speechPlaybackVisualizationLevelDidChange(frame.level)
    }
}

public enum SpeechPlaybackVisualizationContext: Equatable, Sendable {
    case neutral
    case question
    case explanation

    public init(readMode: CaptureMode) {
        switch readMode {
        case .question:
            self = .question
        case .explanation:
            self = .explanation
        }
    }
}

public enum SpeechPlaybackLevelNormalizer {
    public static func normalizedPower(decibels: Float) -> Double {
        guard decibels.isFinite else { return 0 }
        let floor: Float = -55
        guard decibels > floor else { return 0 }
        let clamped = min(0, max(floor, decibels))
        let normalized = pow(10, clamped / 38)
        return min(1, max(0, Double(normalized)))
    }
}
