import Foundation
import SalientCore

@MainActor
enum PocketAudioProbe {
    static func checkBrowserCapture(browser: StudyBrowser) async throws {
        let service = AppleEventBrowserAutomationService(session: StudyBrowserSession(browser: browser))
        let result = await service.executeJavaScriptInUWorldTab(CaptureJavaScript.build(mode: .question))
        guard case .success(let json) = result else {
            throw BrowserCaptureProbeError.noSupportedFrontTab(browser)
        }
        let payload: UWorldCapturePayload
        do { payload = try UWorldCapturePayload.decode(json: json) }
        catch {
            let emptyKind = ["", "missing value", "undefined", "null"].first { $0 == json } ?? "nonempty response"
            print("Capture decoding failed; response bytes: \(json.utf8.count), kind: \(emptyKind).")
            if case DecodingError.dataCorrupted(let context) = error {
                print("Invalid field: \(context.codingPath.map(\.stringValue).joined(separator: "."))")
            }
            throw error
        }
        let labels = payload.segments.filter {
            ["suggested highlights", "suggested", "highlights"].contains($0.text.trimmingCharacters(in: .whitespacesAndNewlines).lowercased())
        }
        let plan = ReadPlanBuilder().questionPlan(from: payload)
        let resultJSON: [String: Any] = [
            "browser": browser.rawValue, "readOnly": true, "capturedSegmentCount": payload.segments.count,
            "controlLabelSegments": labels.count, "controlLabelSegmentsClassifiedAsUI": labels.filter { $0.role == .ui }.count,
            "narrationItemCount": plan.items.count,
            "narrationContainsSuggestedHighlights": plan.items.contains { $0.text.localizedCaseInsensitiveContains("Suggested Highlights") }
        ]
        print(String(decoding: try JSONSerialization.data(withJSONObject: resultJSON, options: [.prettyPrinted, .sortedKeys]), as: UTF8.self))
    }

    static func run(root: URL?, install: Bool, prewarm: Bool, rate: Double, volume: Double,
                    outDirectory: URL, cancelAfterMilliseconds: Double?) async throws {
        let runtime = PocketRuntimeManager(root: root)
        if install {
            let installation = Task {
                try await runtime.install { progress in
                    if let bytes = progress.downloadedBytes, let total = progress.totalBytes {
                        print("\(progress.stage): \(bytes) / \(total) bytes")
                    } else { print(progress.stage) }
                }
            }
            if let delay = cancelAfterMilliseconds {
                try await Task.sleep(for: .milliseconds(max(0, delay)))
                installation.cancel()
                do { try await installation.value; throw ProbeInstallError.completedBeforeCancellation }
                catch is CancellationError { print("Pocket installation cancelled cleanly; no audio played.") }
                return
            }
            try await installation.value
            print("Pocket installation verified; no audio played.")
            return
        }
        guard await runtime.isInstalled() else { throw PocketRuntimeError.needsSetup }
        if prewarm { try await runtime.warm() }
        var settings = SpeechSettings.firstLaunch
        settings.rateMultiplier = rate
        settings.volume = volume
        settings.showPlaybackHUD = false
        let backend = PocketSpeechBackend(settings: settings, runtime: runtime)
        let trace = PocketProbeClock()
        backend.timingSink = trace
        let items = QwenAudioTroubleshootingFixture.syntheticQuestionPlaybackItems(options: settings.readPlanOptions)
        let start = Date()
        trace.started = start
        let playback = Task { try await backend.speak(items, willSpeak: { _ in }) }
        var stopLatency: Double?
        if let delay = cancelAfterMilliseconds {
            try await Task.sleep(for: .milliseconds(max(0, delay)))
            let stop = Date()
            await backend.stop()
            playback.cancel()
            do { try await playback.value } catch is CancellationError {}
            stopLatency = Date().timeIntervalSince(stop)
        } else {
            try await playback.value
        }
        await runtime.unload()
        let report = PocketProbeReport(prewarmed: prewarm, rate: rate, elapsedSeconds: Date().timeIntervalSince(start),
            firstPlaybackClockSeconds: trace.firstProgress, completedItems: trace.completedItems,
            expectedItems: items.count, stopLatencySeconds: stopLatency, underruns: backend.playbackUnderrunCount, timings: trace.timings)
        try FileManager.default.createDirectory(at: outDirectory, withIntermediateDirectories: true)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        let output = outDirectory.appendingPathComponent("pocket-playback.json")
        try encoder.encode(report).write(to: output)
        print(String(decoding: try encoder.encode(report), as: UTF8.self))
    }
}

private enum ProbeInstallError: Error { case completedBeforeCancellation }

private enum BrowserCaptureProbeError: LocalizedError {
    case noSupportedFrontTab(StudyBrowser)
    var errorDescription: String? {
        switch self {
        case .noSupportedFrontTab(let browser):
            "The read-only check could not capture \(browser.title)'s selected front tab. Select an active UWorld question or the Salient practice page, then retry."
        }
    }
}

private struct PocketProbeReport: Encodable {
    let prewarmed: Bool
    let rate: Double
    let elapsedSeconds: Double
    let firstPlaybackClockSeconds: Double?
    let completedItems: Int
    let expectedItems: Int
    let stopLatencySeconds: Double?
    let underruns: Int
    let timings: [SpeechPlaybackItemTiming]
}

@MainActor
private final class PocketProbeClock: SpeechPlaybackTimingSink {
    var started = Date()
    var firstProgress: Double?
    var completedItems = 0
    var timings: [SpeechPlaybackItemTiming] = []
    func speechPlaybackDidReceiveTiming(_ timing: SpeechPlaybackItemTiming) { timings.append(timing) }
    func speechPlaybackDidReceiveProgress(_ progress: SpeechPlaybackProgress) {
        if firstProgress == nil, progress.sourcePositionSeconds > 0 { firstProgress = Date().timeIntervalSince(started) }
    }
    func speechPlaybackDidFinishItem(itemID: String, segmentID: String, itemIndex: Int?) { completedItems += 1 }
}
