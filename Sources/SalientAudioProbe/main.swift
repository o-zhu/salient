import Foundation
import SalientCore

#if os(macOS)
    import AudioToolbox
#endif

@main
struct SalientAudioProbe {
    static func main() async {
        do {
            let options = try ProbeOptions.parse(Array(CommandLine.arguments.dropFirst()))
            if options.showHelp {
                print(ProbeOptions.usage)
                return
            }
            if options.checkBrowserCapture {
                try await PocketAudioProbe.checkBrowserCapture(browser: options.browser)
                return
            }
            if options.engineID == .pocket {
                try await PocketAudioProbe.run(root: options.runtimeRoot, install: options.installPocket,
                    prewarm: options.prewarmModel, rate: options.rateMultiplier, volume: options.volume,
                    outDirectory: options.outDirectory, cancelAfterMilliseconds: options.cancelAfterMilliseconds)
                return
            }
            let output = try await ProbeRunner(options: options).run()
            print("Salient audio probe complete")
            print("manifest: \(output.manifestURL.path)")
            print("events: \(output.eventsURL.path)")
            print("summary: \(output.summaryURL.path)")
            if let firstAudio = output.summary.firstAudioSeconds {
                print("first_audio_seconds: \(String(format: "%.4f", firstAudio))")
            }
            if let maxGap = output.summary.maxInterItemGapSeconds {
                print("max_inter_item_gap_seconds: \(String(format: "%.4f", maxGap))")
            }
            print("underrun_wait_count: \(output.summary.underrunWaitCount)")
            print("technical_underrun_count: \(output.summary.technicalUnderrunCount)")
        } catch let error as ProbeError {
            fputs("error: \(error.localizedDescription)\n", stderr)
            fputs("\n\(ProbeOptions.usage)\n", stderr)
            exit(1)
        } catch {
            fputs("error: \(error.localizedDescription)\n", stderr)
            exit(1)
        }
    }
}

private struct ProbeRunner {
    var options: ProbeOptions

    func run() async throws -> ProbeOutput {
        let lane = try options.lane()
        let speaker = options.speaker ?? lane.defaultSpeaker
        let runtime = QwenRuntimeManager(runtimeRoot: options.runtimeRoot)
        try FileManager.default.createDirectory(at: options.outDirectory, withIntermediateDirectories: true)

        let outputRouter: AudioOutputDeviceRouter?
        if let requestedOutputDevice = options.outputDevice
            ?? ProcessInfo.processInfo.environment["SALIENT_AUDIO_OUTPUT_DEVICE"]
        {
            outputRouter = try AudioOutputDeviceRouter(requestedDevice: requestedOutputDevice)
        } else {
            outputRouter = nil
        }
        defer { outputRouter?.restore() }

        if options.clearCache {
            try await runtime.clearCache()
        }
        let shouldPrewarmModel = options.prewarmModel || options.prewarmStarters
        let shouldPrewarmStarters = options.prewarmStarters && options.usesQuestionPromptAudioLibrary
        if shouldPrewarmModel {
            let prewarmSpeaker = options.useReferenceVoice ? QwenReferenceVoiceDefaults.voiceName : speaker
            try await runtime.prewarm(
                lane: lane,
                speaker: prewarmSpeaker,
                useReferenceVoice: options.useReferenceVoice,
                referenceText: options.useReferenceVoice ? QwenReferenceVoiceDefaults.referenceText : nil
            )
        }
        if shouldPrewarmStarters {
            let prewarmSpeaker = options.useReferenceVoice ? QwenReferenceVoiceDefaults.voiceName : speaker
            try await runtime.prewarmQuestionStarters(
                lane: lane,
                speaker: prewarmSpeaker,
                useReferenceVoice: options.useReferenceVoice,
                rateMultiplier: options.rateMultiplier,
                qwenDeEsserStrengthDecibels: options.qwenDeEsserStrengthDecibels
            )
        }

        let trace = ProbeTraceRecorder()
        let settings = SpeechSettings(
            engineID: options.engineID,
            rateMultiplier: options.rateMultiplier,
            volume: options.volume,
            pitchMultiplier: 1.0,
            voiceIdentifier: nil,
            qwenSpeaker: speaker,
            qwenUseReferenceVoice: options.useReferenceVoice,
            qwenReferenceVoiceName: QwenReferenceVoiceDefaults.voiceName,
            qwenReferenceAudioPath: "",
            qwenReferenceText: QwenReferenceVoiceDefaults.referenceText,
            qwenDeEsserStrengthDecibels: options.qwenDeEsserStrengthDecibels,
            showPlaybackHUD: false,
            usesQuestionPromptAudioLibrary: options.usesQuestionPromptAudioLibrary
        )
        let backend = await QwenSpeechBackend(
            settings: settings,
            runtime: runtime,
            playback: QwenAudioPlayback(),
            traceSink: trace
        )
        let items = QwenAudioTroubleshootingFixture.syntheticQuestionPlaybackItems(
            options: settings.readPlanOptions
        )

        try await backend.speak(items) { _ in }

        let events = await trace.snapshot()
        let summary = QwenPlaybackTraceSummary(events: events, rateMultiplier: options.rateMultiplier)
        let manifest = ProbeManifest(
            createdAt: ISO8601DateFormatter().string(from: Date()),
            engineID: options.engineID.rawValue,
            rateMultiplier: options.rateMultiplier,
            volume: options.volume,
            qwenDeEsserStrengthDecibels: options.qwenDeEsserStrengthDecibels,
            speaker: speaker,
            useReferenceVoice: options.useReferenceVoice,
            clearCache: options.clearCache,
            prewarmModel: shouldPrewarmModel,
            prewarmStarters: shouldPrewarmStarters,
            usesQuestionPromptAudioLibrary: options.usesQuestionPromptAudioLibrary,
            itemSegmentIDs: items.map(\.segmentID)
        )

        let manifestURL = options.outDirectory.appendingPathComponent("probe-manifest.json")
        let eventsURL = options.outDirectory.appendingPathComponent("qwen-trace-events.json")
        let summaryURL = options.outDirectory.appendingPathComponent("qwen-trace-summary.json")
        try writeJSON(manifest, to: manifestURL)
        try writeJSON(events, to: eventsURL)
        try writeJSON(summary, to: summaryURL)
        return ProbeOutput(
            manifestURL: manifestURL,
            eventsURL: eventsURL,
            summaryURL: summaryURL,
            summary: summary
        )
    }

    private func writeJSON<T: Encodable>(_ value: T, to url: URL) throws {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        let data = try encoder.encode(value)
        try data.write(to: url, options: .atomic)
    }
}

private struct ProbeOutput {
    var manifestURL: URL
    var eventsURL: URL
    var summaryURL: URL
    var summary: QwenPlaybackTraceSummary
}

private struct ProbeManifest: Codable {
    var createdAt: String
    var engineID: String
    var rateMultiplier: Double
    var volume: Double
    var qwenDeEsserStrengthDecibels: Double
    var speaker: String
    var useReferenceVoice: Bool
    var clearCache: Bool
    var prewarmModel: Bool
    var prewarmStarters: Bool
    var usesQuestionPromptAudioLibrary: Bool
    var itemSegmentIDs: [String]
}

private actor ProbeTraceRecorder: QwenPlaybackTracing {
    private var events: [QwenPlaybackTraceEvent] = []

    func record(_ event: QwenPlaybackTraceEvent) {
        events.append(event)
    }

    func snapshot() -> [QwenPlaybackTraceEvent] {
        events
    }
}

private struct ProbeOptions {
    var engineID: SpeechEngineID = .qwenSmall
    var rateMultiplier = SpeechSettings.default.rateMultiplier
    var volume = 1.0
    var qwenDeEsserStrengthDecibels = SpeechSettings.defaultQwenDeEsserStrengthDecibels
    var speaker: String?
    var outputDevice: String?
    var useReferenceVoice = false
    var clearCache = false
    var prewarmStarters = false
    var prewarmModel = false
    var usesQuestionPromptAudioLibrary = true
    var runtimeRoot: URL?
    var outDirectory = FileManager.default.temporaryDirectory
        .appendingPathComponent("salient-audio-probe-\(Int(Date().timeIntervalSince1970))", isDirectory: true)
    var showHelp = false
    var installPocket = false
    var checkBrowserCapture = false
    var browser: StudyBrowser = .safari
    var cancelAfterMilliseconds: Double?

    static let usage = """
        usage: swift run SalientAudioProbe [options]

        Developer-only Qwen audio timing probe. It speaks a synthetic question plan and writes privacy-safe trace JSON.

          --engine pocket|qwenSmall|qwenBest   Engine to test. Default: qwenSmall
          --install-pocket              Install and verify Pocket without playing audio
          --check-browser-capture       Read-only front-tab control-label check; no text is printed
          --browser safari|chrome       Browser for the capture check
          --cancel-after-ms value       Pocket playback or installation interruption check
          --rate value                  Playback rate multiplier. Default: 2.4
          --volume value                Playback volume from 0.0 to 1.0. Default: 1.0
          --de-esser-db value           Maximum high-frequency reduction, 0 to 20 dB. Default: 6
          --speaker name                Qwen speaker name. Default: lane default
          --output-device name|index    Audio output device used while probing (Codex TTS Sink recommended)
          --use-reference-voice         Use the bundled reference voice settings
          --clear-cache                 Clear the Qwen audio cache before running
          --prewarm-model               Load and compile the selected model before the timed request
          --prewarm-starters            Prewarm common question starters before running
          --disable-prompt-audio-library
          --runtime-root path            Isolated Qwen runtime root (models/venv may be symlinked)
          --out-dir path                Directory for probe JSON artifacts
          --help                        Show this help
        """

    static func parse(_ arguments: [String]) throws -> ProbeOptions {
        var options = ProbeOptions()
        var index = 0
        while index < arguments.count {
            let argument = arguments[index]
            switch argument {
            case "--help", "-h":
                options.showHelp = true
            case "--engine":
                let value = try value(after: argument, in: arguments, at: &index)
                guard let engine = SpeechEngineID(rawValue: value), (engine.qwenLane != nil || engine == .pocket) else {
                    throw ProbeError.invalidArgument("--engine must be pocket, qwenSmall or qwenBest")
                }
                options.engineID = engine
            case "--check-browser-capture":
                options.checkBrowserCapture = true
            case "--browser":
                let value = try value(after: argument, in: arguments, at: &index)
                guard let browser = StudyBrowser(rawValue: value) else { throw ProbeError.invalidArgument("Unknown browser") }
                options.browser = browser
            case "--install-pocket":
                options.installPocket = true
            case "--cancel-after-ms":
                options.cancelAfterMilliseconds = try doubleValue(after: argument, in: arguments, at: &index)
            case "--rate":
                options.rateMultiplier = try doubleValue(after: argument, in: arguments, at: &index)
            case "--volume":
                options.volume = try doubleValue(after: argument, in: arguments, at: &index)
            case "--de-esser-db":
                options.qwenDeEsserStrengthDecibels = try doubleValue(after: argument, in: arguments, at: &index)
            case "--speaker":
                options.speaker = try value(after: argument, in: arguments, at: &index)
            case "--output-device":
                options.outputDevice = try value(after: argument, in: arguments, at: &index)
            case "--use-reference-voice":
                options.useReferenceVoice = true
            case "--clear-cache":
                options.clearCache = true
            case "--prewarm-starters":
                options.prewarmStarters = true
            case "--prewarm-model":
                options.prewarmModel = true
            case "--disable-prompt-audio-library":
                options.usesQuestionPromptAudioLibrary = false
            case "--runtime-root":
                let value = try value(after: argument, in: arguments, at: &index)
                options.runtimeRoot = URL(fileURLWithPath: value, isDirectory: true)
            case "--out-dir":
                let value = try value(after: argument, in: arguments, at: &index)
                options.outDirectory = URL(fileURLWithPath: value, isDirectory: true)
            default:
                throw ProbeError.invalidArgument("unknown argument: \(argument)")
            }
            index += 1
        }
        options.rateMultiplier = min(max(options.rateMultiplier, 0.5), 2.4)
        options.volume = min(max(options.volume, 0), 1)
        options.qwenDeEsserStrengthDecibels = min(
            max(options.qwenDeEsserStrengthDecibels, 0),
            SpeechSettings.maximumQwenDeEsserStrengthDecibels
        )
        return options
    }

    func lane() throws -> QwenModelLane {
        guard let lane = engineID.qwenLane else {
            throw ProbeError.invalidArgument("audio probe only supports Qwen engines")
        }
        return lane
    }

    private static func value(after option: String, in arguments: [String], at index: inout Int) throws -> String {
        let valueIndex = index + 1
        guard valueIndex < arguments.count else {
            throw ProbeError.invalidArgument("missing value after \(option)")
        }
        index = valueIndex
        return arguments[valueIndex]
    }

    private static func doubleValue(after option: String, in arguments: [String], at index: inout Int) throws -> Double {
        let rawValue = try value(after: option, in: arguments, at: &index)
        guard let value = Double(rawValue) else {
            throw ProbeError.invalidArgument("\(option) requires a numeric value")
        }
        return value
    }
}

private enum ProbeError: LocalizedError {
    case invalidArgument(String)
    case audioRoutingFailed(String)

    var errorDescription: String? {
        switch self {
        case .invalidArgument(let message):
            message
        case .audioRoutingFailed(let message):
            message
        }
    }
}

#if os(macOS)
    private struct AudioOutputDeviceRouter {
        private var originalDeviceID: AudioObjectID?

        init(requestedDevice: String) throws {
            let targetDeviceID = try AudioOutputRouting.deviceID(matching: requestedDevice)
            let currentDeviceID = try AudioOutputRouting.currentDefaultOutputDeviceID()
            originalDeviceID = currentDeviceID
            if targetDeviceID != currentDeviceID {
                try AudioOutputRouting.setDefaultOutput(deviceID: targetDeviceID)
            }
        }

        func restore() {
            guard let originalDeviceID else { return }
            try? AudioOutputRouting.setDefaultOutput(deviceID: originalDeviceID)
        }
    }

    private enum AudioOutputRouting {
        static func currentDefaultOutputDeviceID() throws -> AudioObjectID {
            var deviceID: AudioObjectID = kAudioObjectUnknown
            var size = UInt32(MemoryLayout<AudioObjectID>.size)
            var propertyAddress = AudioObjectPropertyAddress(
                mSelector: kAudioHardwarePropertyDefaultOutputDevice,
                mScope: kAudioObjectPropertyScopeGlobal,
                mElement: kAudioObjectPropertyElementMain
            )
            let status = AudioObjectGetPropertyData(
                AudioObjectID(kAudioObjectSystemObject),
                &propertyAddress,
                0,
                nil,
                &size,
                &deviceID
            )
            guard status == noErr else {
                throw ProbeError.audioRoutingFailed("Could not read default output device (status \(status)).")
            }
            return deviceID
        }

        static func setDefaultOutput(deviceID: AudioObjectID) throws {
            var nextDeviceID = deviceID
            let size = UInt32(MemoryLayout<AudioObjectID>.size)
            var propertyAddress = AudioObjectPropertyAddress(
                mSelector: kAudioHardwarePropertyDefaultOutputDevice,
                mScope: kAudioObjectPropertyScopeGlobal,
                mElement: kAudioObjectPropertyElementMain
            )
            let status = AudioObjectSetPropertyData(
                AudioObjectID(kAudioObjectSystemObject),
                &propertyAddress,
                0,
                nil,
                size,
                &nextDeviceID
            )
            guard status == noErr else {
                throw ProbeError.audioRoutingFailed("Could not set default output device (status \(status)).")
            }
        }

        static func deviceID(matching specifier: String) throws -> AudioObjectID {
            let requested = specifier.trimmingCharacters(in: .whitespacesAndNewlines)
            let available = try listOutputDevices()
            if let requestedIndex = Int(requested),
                requestedIndex >= 0,
                requestedIndex < available.count
            {
                return available[requestedIndex].id
            }

            let requestedLower = requested.lowercased()
            if let exact = available.first(where: { $0.name.lowercased() == requestedLower }) {
                return exact.id
            }
            if let contains = available.first(where: { $0.name.lowercased().contains(requestedLower) }) {
                return contains.id
            }
            throw ProbeError.invalidArgument("No audio output device matched '\(specifier)'.")
        }

        private static func listOutputDevices() throws -> [(id: AudioObjectID, name: String)] {
            var propertyAddress = AudioObjectPropertyAddress(
                mSelector: kAudioHardwarePropertyDevices,
                mScope: kAudioObjectPropertyScopeGlobal,
                mElement: kAudioObjectPropertyElementMain
            )
            var dataSize: UInt32 = 0
            var status = AudioObjectGetPropertyDataSize(
                AudioObjectID(kAudioObjectSystemObject),
                &propertyAddress,
                0,
                nil,
                &dataSize
            )
            guard status == noErr else {
                throw ProbeError.audioRoutingFailed("Could not list audio devices (status \(status)).")
            }

            let deviceCount = Int(dataSize / UInt32(MemoryLayout<AudioObjectID>.size))
            var audioDevices = [AudioObjectID](repeating: kAudioObjectUnknown, count: max(deviceCount, 0))
            status = AudioObjectGetPropertyData(
                AudioObjectID(kAudioObjectSystemObject),
                &propertyAddress,
                0,
                nil,
                &dataSize,
                &audioDevices
            )
            guard status == noErr else {
                throw ProbeError.audioRoutingFailed("Could not read audio device list (status \(status)).")
            }

            var entries: [(id: AudioObjectID, name: String)] = []
            for deviceID in audioDevices.prefix(deviceCount) {
                var unmanagedName: Unmanaged<CFString>?
                var nameSize = UInt32(MemoryLayout<Unmanaged<CFString>?>.size)
                var nameAddress = AudioObjectPropertyAddress(
                    mSelector: kAudioDevicePropertyDeviceNameCFString,
                    mScope: kAudioObjectPropertyScopeGlobal,
                    mElement: kAudioObjectPropertyElementMain
                )
                status = AudioObjectGetPropertyData(
                    deviceID,
                    &nameAddress,
                    0,
                    nil,
                    &nameSize,
                    &unmanagedName
                )
                guard status == noErr else {
                    continue
                }
                guard let name = unmanagedName?.takeUnretainedValue() else { continue }
                entries.append((id: deviceID, name: name as String))
            }
            return entries
        }
    }
#endif
