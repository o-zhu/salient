import Foundation

public enum QwenRuntimeStatusKind: String, Codable, Equatable, Sendable {
    case ready
    case needsSetup
    case installing
    case failed
}

public struct QwenRuntimeReport: Codable, Equatable, Sendable {
    public var runtimeRoot: String
    public var logsDirectory: String
    public var architecture: String
    public var uvAvailable: Bool
    public var pythonEnvironmentAvailable: Bool
    public var mlxAudioAvailable: Bool
    public var helperAvailable: Bool
    public var installedModelIDs: Set<String>
    public var installingLane: QwenModelLane?
    public var installingReferenceVoice: Bool
    public var lastError: String?

    public init(
        runtimeRoot: String,
        logsDirectory: String,
        architecture: String,
        uvAvailable: Bool,
        pythonEnvironmentAvailable: Bool,
        mlxAudioAvailable: Bool,
        helperAvailable: Bool,
        installedModelIDs: Set<String>,
        installingLane: QwenModelLane? = nil,
        installingReferenceVoice: Bool = false,
        lastError: String? = nil
    ) {
        self.runtimeRoot = runtimeRoot
        self.logsDirectory = logsDirectory
        self.architecture = architecture
        self.uvAvailable = uvAvailable
        self.pythonEnvironmentAvailable = pythonEnvironmentAvailable
        self.mlxAudioAvailable = mlxAudioAvailable
        self.helperAvailable = helperAvailable
        self.installedModelIDs = installedModelIDs
        self.installingLane = installingLane
        self.installingReferenceVoice = installingReferenceVoice
        self.lastError = lastError
    }

    public var isAppleSilicon: Bool {
        architecture == "arm64"
    }

    public func isInstalled(_ lane: QwenModelLane, useReferenceVoice: Bool = false) -> Bool {
        installedModelIDs.contains(lane.modelID(useReferenceVoice: useReferenceVoice))
    }

    public func status(for lane: QwenModelLane, useReferenceVoice: Bool = false) -> QwenRuntimeStatusKind {
        if installingLane == lane, installingReferenceVoice == useReferenceVoice {
            return .installing
        }
        if lastError != nil {
            return .failed
        }
        return isInstalled(lane, useReferenceVoice: useReferenceVoice) && pythonEnvironmentAvailable && mlxAudioAvailable && helperAvailable
            ? .ready : .needsSetup
    }

    public func readinessState(for lane: QwenModelLane, useReferenceVoice: Bool = false) -> ReadinessState {
        switch status(for: lane, useReferenceVoice: useReferenceVoice) {
        case .ready: .available
        case .needsSetup, .installing: .needsSetup
        case .failed: .unavailable
        }
    }
}

public struct QwenInstallProgress: Equatable, Sendable {
    public var lane: QwenModelLane
    public var stage: String
    public var fractionCompleted: Double?

    public init(lane: QwenModelLane, stage: String, fractionCompleted: Double? = nil) {
        self.lane = lane
        self.stage = stage
        self.fractionCompleted = fractionCompleted
    }

    public static func parse(line: String, lane: QwenModelLane) -> QwenInstallProgress? {
        guard let data = line.data(using: .utf8),
            let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
            let stage = object["stage"] as? String
        else {
            return nil
        }
        let fraction = object["fractionCompleted"] as? Double
        return QwenInstallProgress(lane: lane, stage: stage, fractionCompleted: fraction)
    }
}

public struct QwenPreparedAudio: Equatable, Sendable {
    public var url: URL
    public var durationSeconds: Double
    public var isFromCache: Bool
    public var removeAfterPlayback: Bool

    public init(
        url: URL,
        durationSeconds: Double,
        isFromCache: Bool,
        removeAfterPlayback: Bool = false
    ) {
        self.url = url
        self.durationSeconds = durationSeconds
        self.isFromCache = isFromCache
        self.removeAfterPlayback = removeAfterPlayback
    }
}

public enum QwenInferenceBackend: String, Codable, Equatable, Sendable {
    case cache
    case nativeMLX
    case pythonMLX
}

enum QwenNativeStreamingPolicy {
    static let environmentKey = "SALIENT_QWEN_NATIVE_STREAMING"
    static let fastLaneValue = "fast"
    static let allLanesValue = "all"

    static func isEnabled(
        environment: [String: String] = ProcessInfo.processInfo.environment
    ) -> Bool {
        guard let configuredValue = environment[environmentKey] else { return false }
        switch configuredValue.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() {
        case "0", "false", "no", "off":
            return false
        default:
            return true
        }
    }

    static func isInteractiveStreamingEnabled(
        lane: QwenModelLane,
        useReferenceVoice: Bool,
        environment: [String: String] = ProcessInfo.processInfo.environment
    ) -> Bool {
        guard isEnabled(environment: environment) else { return false }
        let configuredValue = environment[environmentKey]?
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased()
        if configuredValue == allLanesValue {
            return true
        }
        return configuredValue != nil && lane == .small && !useReferenceVoice
    }
}

public enum QwenRuntimeResidencyState: String, Codable, Equatable, Sendable {
    case cacheHit
    case warm
    case cold
}

public enum QwenInferenceFallbackReason: String, Codable, Equatable, Sendable {
    case nativeUnavailable
    case nativeLoadFailed
    case nativeGenerationFailedBeforeAudio
}

public struct QwenStreamingAudioChunk: Codable, Equatable, Sendable {
    public var requestID: String
    public var itemIndex: Int
    public var sequenceIndex: Int
    public var sampleRate: Double
    public var audioData: Data
    public var durationSeconds: Double
    public var isFinal: Bool
    public var elapsedSeconds: Double?
    public var peakMemoryBytes: Int64?
    public var backend: QwenInferenceBackend?
    public var residencyState: QwenRuntimeResidencyState?
    public var modelLoadSeconds: Double?
    public var warmupSeconds: Double?
    public var realTimeFactor: Double?
    public var device: String?
    public var fallbackReason: QwenInferenceFallbackReason?

    public init(
        requestID: String,
        itemIndex: Int,
        sequenceIndex: Int,
        sampleRate: Double,
        audioData: Data,
        durationSeconds: Double,
        isFinal: Bool,
        elapsedSeconds: Double? = nil,
        peakMemoryBytes: Int64? = nil,
        backend: QwenInferenceBackend? = nil,
        residencyState: QwenRuntimeResidencyState? = nil,
        modelLoadSeconds: Double? = nil,
        warmupSeconds: Double? = nil,
        realTimeFactor: Double? = nil,
        device: String? = nil,
        fallbackReason: QwenInferenceFallbackReason? = nil
    ) {
        self.requestID = requestID
        self.itemIndex = itemIndex
        self.sequenceIndex = sequenceIndex
        self.sampleRate = sampleRate
        self.audioData = audioData
        self.durationSeconds = durationSeconds
        self.isFinal = isFinal
        self.elapsedSeconds = elapsedSeconds
        self.peakMemoryBytes = peakMemoryBytes
        self.backend = backend
        self.residencyState = residencyState
        self.modelLoadSeconds = modelLoadSeconds
        self.warmupSeconds = warmupSeconds
        self.realTimeFactor = realTimeFactor
        self.device = device
        self.fallbackReason = fallbackReason
    }
}

public enum QwenAudioCachePolicy: String, Codable, Equatable, Sendable {
    case automatic
    case persistent
    case transient
}

public struct QwenReferenceAudioValidation: Equatable, Sendable {
    public var durationSeconds: Double
    public var sampleRate: Double
    public var channelCount: Int
    public var peakAmplitude: Float

    public init(
        durationSeconds: Double,
        sampleRate: Double,
        channelCount: Int,
        peakAmplitude: Float
    ) {
        self.durationSeconds = durationSeconds
        self.sampleRate = sampleRate
        self.channelCount = channelCount
        self.peakAmplitude = peakAmplitude
    }
}

struct QwenSynthesisRequest: Equatable, Sendable {
    var text: String
    var lane: QwenModelLane
    var speaker: String
    var language: String
    var rateMultiplier: Double
    var cachePolicy: QwenAudioCachePolicy
    var useReferenceVoice: Bool
    var referenceAudioPath: String?
    var referenceText: String?
    var qwenDeEsserStrengthDecibels: Double = SpeechSettings.defaultQwenDeEsserStrengthDecibels
}

struct QwenStreamingSynthesisRequest: Equatable, Sendable {
    var id: String
    var itemIndex: Int
    var request: QwenSynthesisRequest

    init(
        id: String = UUID().uuidString,
        itemIndex: Int,
        request: QwenSynthesisRequest
    ) {
        self.id = id
        self.itemIndex = itemIndex
        self.request = request
    }
}

protocol QwenAudioStreaming: Sendable {
    func streamAudio(
        _ request: QwenStreamingSynthesisRequest,
        onChunk: @Sendable @escaping (QwenStreamingAudioChunk) async throws -> Void
    ) async throws
}

public enum QwenRuntimeError: LocalizedError, Equatable, Sendable {
    case setupRequired(String)
    case commandFailed(String)
    case helperMissing
    case cancelled

    public var errorDescription: String? {
        switch self {
        case .setupRequired(let message):
            message
        case .commandFailed(let message):
            message
        case .helperMissing:
            "The bundled Qwen helper is missing from the app."
        case .cancelled:
            "Qwen setup or playback was cancelled."
        }
    }
}

public struct QwenShellCommand: Equatable, Sendable {
    public var executable: String
    public var arguments: [String]
    public var environment: [String: String]
    public var workingDirectory: String?
    public var redactedDescription: String

    public init(
        executable: String,
        arguments: [String],
        environment: [String: String] = [:],
        workingDirectory: String? = nil,
        redactedDescription: String
    ) {
        self.executable = executable
        self.arguments = arguments
        self.environment = environment
        self.workingDirectory = workingDirectory
        self.redactedDescription = redactedDescription
    }
}

public struct QwenCommandResult: Equatable, Sendable {
    public var exitCode: Int32
    public var stdout: String
    public var stderr: String

    public init(exitCode: Int32, stdout: String, stderr: String) {
        self.exitCode = exitCode
        self.stdout = stdout
        self.stderr = stderr
    }
}

public protocol QwenCommandRunning: Sendable {
    func run(_ command: QwenShellCommand) async throws -> QwenCommandResult
}

public struct ProcessQwenCommandRunner: QwenCommandRunning {
    private let runner: any AsyncProcessRunning
    private let timeoutSeconds: TimeInterval
    private let maximumRetainedOutputBytes: Int

    public init(
        runner: any AsyncProcessRunning = AsyncProcessRunner(),
        timeoutSeconds: TimeInterval = 3_600,
        maximumRetainedOutputBytes: Int = 1_048_576
    ) {
        self.runner = runner
        self.timeoutSeconds = timeoutSeconds
        self.maximumRetainedOutputBytes = maximumRetainedOutputBytes
    }

    public func run(_ command: QwenShellCommand) async throws -> QwenCommandResult {
        let result = try await runner.run(
            AsyncProcessRequest(
                executableURL: URL(fileURLWithPath: command.executable),
                arguments: command.arguments,
                environment: command.environment,
                currentDirectoryURL: command.workingDirectory.map(URL.init(fileURLWithPath:)),
                timeoutSeconds: timeoutSeconds,
                maximumRetainedOutputBytes: maximumRetainedOutputBytes,
                redactedDescription: command.redactedDescription
            ))
        return QwenCommandResult(
            exitCode: result.exitCode,
            stdout: String(decoding: result.stdout, as: UTF8.self),
            stderr: String(decoding: result.stderr, as: UTF8.self)
        )
    }
}
