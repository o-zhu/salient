import Foundation

public enum ReadinessState: String, Equatable, Sendable {
    case available
    case needsSetup
    case installing
    case failed
    case optional
    case unavailable

    public var label: String {
        switch self {
        case .available: "Ready"
        case .needsSetup: "Needs Setup"
        case .installing: "Installing"
        case .failed: "Failed"
        case .optional: "Optional"
        case .unavailable: "Unavailable"
        }
    }
}

public struct ReadinessItem: Equatable, Identifiable, Sendable {
    public var id: String
    public var title: String
    public var detail: String
    public var state: ReadinessState
    public var primaryActionTitle: String?

    public init(
        id: String,
        title: String,
        detail: String,
        state: ReadinessState,
        primaryActionTitle: String? = nil
    ) {
        self.id = id
        self.title = title
        self.detail = detail
        self.state = state
        self.primaryActionTitle = primaryActionTitle
    }
}

public enum AppleEventPermissionStatus: Equatable, Sendable {
    case authorized
    case notDetermined
    case denied
    case blocked
    case unknown(OSStatus)

    public init(osStatus: OSStatus) {
        switch osStatus {
        case noErr:
            self = .authorized
        case OSStatus(errAEEventNotPermitted):
            self = .denied
        case OSStatus(errAEEventWouldRequireUserConsent):
            self = .notDetermined
        case OSStatus(errAETargetAddressNotPermitted):
            self = .blocked
        default:
            self = .unknown(osStatus)
        }
    }

    public var readinessState: ReadinessState {
        switch self {
        case .authorized:
            .available
        case .notDetermined, .denied, .blocked, .unknown:
            .needsSetup
        }
    }

    public var label: String {
        switch self {
        case .authorized:
            "Authorized"
        case .notDetermined:
            "Not Requested"
        case .denied:
            "Denied"
        case .blocked:
            "Blocked"
        case .unknown(let status):
            "Unknown (\(status))"
        }
    }

    public var guidance: String { guidance(for: .safari) }

    public func guidance(for browser: StudyBrowser) -> String {
        switch self {
        case .authorized:
            "This app can send \(browser.title) the Apple Events needed for Submit and Read Question."
        case .notDetermined:
            "Click Request Access and approve \(browser.title) automation when macOS asks."
        case .denied:
            "Open System Settings > Privacy & Security > Automation, then allow this app to control \(browser.title)."
        case .blocked:
            "macOS blocked \(browser.title) automation for this app. Check Automation privacy settings and app signing."
        case .unknown:
            "Refresh after opening \(browser.title). If this persists, open System Settings > Privacy & Security > Automation."
        }
    }
}

public struct DependencyCenterReport: Equatable, Sendable {
    public var summary: String
    public var items: [ReadinessItem]

    public static func current(
        safariAutomation: AppleEventPermissionStatus,
        globalHotKeyEnabled: Bool,
        qwenRuntime: QwenRuntimeReport? = nil,
        selectedSpeechEngine: SpeechEngineID = .apple,
        selectedQwenUsesReferenceVoice: Bool = false,
        browser: StudyBrowser = .safari
    ) -> DependencyCenterReport {
        let qwenItem = Self.qwenReadinessItem(
            qwenRuntime: qwenRuntime,
            selectedSpeechEngine: selectedSpeechEngine,
            selectedQwenUsesReferenceVoice: selectedQwenUsesReferenceVoice
        )
        return DependencyCenterReport(
            summary: "Reading runs on this Mac. Submit, Read Question, built-in speech, and optional Qwen TTS need no cloud service.",
            items: [
                ReadinessItem(
                    id: "safari-submit",
                    title: "\(browser.title) Submit Automation",
                    detail: "Uses native Apple Events and bundled JavaScript to click a visible Submit button.",
                    state: safariAutomation.readinessState,
                    primaryActionTitle: safariAutomation == .authorized ? nil : "Open Permissions"
                ),
                ReadinessItem(
                    id: "native-speech",
                    title: "Built-in macOS Speech",
                    detail: "Uses AVFoundation speech built into macOS. No TTS model download is needed.",
                    state: .available
                ),
                ReadinessItem(
                    id: "global-hotkey",
                    title: "Global Study Shortcuts",
                    detail: globalHotKeyEnabled ? "Registered in this app session." : "Optional shortcuts for UWorld Study actions.",
                    state: globalHotKeyEnabled ? .available : .optional
                ),
                qwenItem
            ]
        )
    }

    private static func qwenReadinessItem(
        qwenRuntime: QwenRuntimeReport?,
        selectedSpeechEngine: SpeechEngineID,
        selectedQwenUsesReferenceVoice: Bool
    ) -> ReadinessItem {
        guard let qwenRuntime else {
            return ReadinessItem(
                id: "qwen-tts",
                title: "Qwen TTS",
                detail: "Optional local MLX voice engine. Open Narration Settings to install Qwen Fast or Qwen Best.",
                state: .optional,
                primaryActionTitle: "Open Narration Settings"
            )
        }

        let selectedLane = selectedSpeechEngine.qwenLane
        let laneForState = selectedLane ?? QwenModelLane.allCases.first { lane in
            qwenRuntime.isInstalled(lane) || qwenRuntime.isInstalled(lane, useReferenceVoice: true)
        }
        let state: ReadinessState
        if let laneForState {
            let useReferenceVoice = selectedLane == nil ? qwenRuntime.isInstalled(laneForState, useReferenceVoice: true) : selectedQwenUsesReferenceVoice
            switch qwenRuntime.status(for: laneForState, useReferenceVoice: useReferenceVoice) {
            case .ready:
                state = .available
            case .needsSetup:
                state = selectedLane == nil ? .optional : .needsSetup
            case .installing:
                state = .installing
            case .failed:
                state = .failed
            }
        } else if qwenRuntime.installingLane != nil {
            state = .installing
        } else if qwenRuntime.lastError != nil {
            state = .failed
        } else {
            state = selectedLane == nil ? .optional : .needsSetup
        }

        let installed = QwenModelLane.allCases
            .flatMap { lane -> [String] in
                [
                    qwenRuntime.isInstalled(lane) ? lane.displayName : nil,
                    qwenRuntime.isInstalled(lane, useReferenceVoice: true) ? lane.setupDisplayName(useReferenceVoice: true) : nil
                ].compactMap { $0 }
            }
        let installedText = installed.isEmpty ? "No Qwen model is installed." : "Installed: \(installed.joined(separator: ", "))."
        let detail: String
        if let lastError = qwenRuntime.lastError {
            detail = "\(installedText) Last setup issue: \(lastError)"
        } else {
            detail = "\(installedText) Runtime: \(qwenRuntime.runtimeRoot)."
        }
        return ReadinessItem(
            id: "qwen-tts",
            title: "Qwen TTS",
            detail: detail,
            state: state,
            primaryActionTitle: state == .available ? nil : "Open Narration Settings"
        )
    }
}

public struct PermissionCenterReport: Equatable, Sendable {
    public var items: [ReadinessItem]

    public static func current(
        safariAutomation: AppleEventPermissionStatus,
        globalHotKeyEnabled: Bool,
        browser: StudyBrowser = .safari
    ) -> PermissionCenterReport {
        PermissionCenterReport(items: [
            ReadinessItem(
                id: "safari-automation",
                title: "\(browser.title) Automation",
                detail: "Required for Submit, Read Question, and Read Explanation in \(browser.title). \(safariAutomation.guidance(for: browser)) If no prompt appears, quit and reopen the app from Applications, then try Request Access again.",
                state: safariAutomation.readinessState,
                primaryActionTitle: safariAutomation == .authorized ? nil : "Request Access"
            ),
            ReadinessItem(
                id: "safari-javascript-events",
                title: "\(browser.title) JavaScript from Apple Events",
                detail: browser.javaScriptSetup,
                state: safariAutomation == .authorized ? .available : .needsSetup,
                primaryActionTitle: "Open \(browser.title)"
            ),
            ReadinessItem(
                id: "global-hotkey-permission",
                title: "Global Study Shortcuts",
                detail: globalHotKeyEnabled ? "Enabled for this app session." : "Optional shortcuts for UWorld Study actions.",
                state: globalHotKeyEnabled ? .available : .optional
            )
        ])
    }
}

public enum SafariAutomationErrorInterpreter {
    public static func userMessage(errorNumber: Int?, rawMessage: String, browser: StudyBrowser = .safari) -> String {
        let lowercased = rawMessage.lowercased()
        if errorNumber == -1712 || lowercased.contains("(-1712)") || lowercased.contains("appleevent timed out") {
            return "\(browser.title) did not respond. Open Permissions and connect \(browser.title), then keep your study tab selected and try again."
        }
        if errorNumber == Int(errAEEventNotPermitted)
            || lowercased.contains("not authorized to send apple events")
            || lowercased.contains("not authorised to send apple events") {
            return "\(browser.title) Automation is not authorized. Open Permissions, click Request Access, then enable \(browser.title) under this app in System Settings > Privacy & Security > Automation."
        }

        if errorNumber == Int(errAEEventWouldRequireUserConsent) {
            return "\(browser.title) Automation needs your approval. Open the Permissions Center and click Request Access."
        }

        if lowercased.contains("javascript from apple events") {
            return "\(browser.title) is blocking JavaScript from Apple Events. \(browser.javaScriptSetup)"
        }

        return rawMessage
    }
}
