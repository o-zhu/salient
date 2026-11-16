import AppKit
import ApplicationServices
import Foundation
import SalientCore
import SwiftUI
import UniformTypeIdentifiers

enum ShortcutRegistrationState: Equatable {
    case disabled
    case registered
    case invalid(String)
    case failed(String)

    var label: String {
        switch self {
        case .disabled: "Off"
        case .registered: "Ready"
        case .invalid: "Needs Fix"
        case .failed: "Conflict"
        }
    }
}

@MainActor
final class AppModel: ObservableObject, SpeechPlaybackVisualizationSink, ReadAlongPresentationSink {
    /// The app name shown in the main window title, menu bar extra, and user-facing copy.
    static let displayName = "Salient"

    let state: AppState
    var openMainWindow: (@MainActor () -> Void)?
    @Published var readingText = ""
    @Published var selectedSection: AppSection = .reading {
        didSet {
            guard oldValue != selectedSection else { return }
            state.navigation.selectedSection = selectedSection
            handleSelectedSectionResidency()
        }
    }
    @Published var isBusy = false
    @Published var statusMessage = "Ready."
    @Published var lastAction = "No actions yet."
    @Published var lastError: String?
    private(set) var isPlaybackHUDVisible: Bool {
        get { state.playbackHUD.isVisible }
        set { state.playbackHUD.isVisible = newValue }
    }
    private(set) var playbackHUDFrame: SpeechPlaybackVisualizationFrame {
        get { state.playbackHUD.frame }
        set { state.playbackHUD.frame = newValue }
    }
    var playbackHUDLevel: Double { state.playbackHUD.level }
    private(set) var playbackHUDMode: SpeechPlaybackVisualizationContext {
        get { state.playbackHUD.mode }
        set { state.playbackHUD.mode = newValue }
    }
    private(set) var isPlaybackHUDGenerating: Bool {
        get { state.playbackHUD.isGenerating }
        set { state.playbackHUD.isGenerating = newValue }
    }
    private(set) var isRSVPReaderVisible: Bool {
        get { state.rsvpReader.isVisible }
        set { state.rsvpReader.isVisible = newValue }
    }
    private(set) var rsvpReadingPlan: RSVPReadingPlan? {
        get { state.rsvpReader.plan }
        set { state.rsvpReader.plan = newValue }
    }
    private(set) var rsvpReaderRequestedFrameIndex: Int {
        get { state.rsvpReader.requestedFrameIndex }
        set { state.rsvpReader.requestedFrameIndex = newValue }
    }
    private(set) var rsvpReaderSyncRevision: Int {
        get { state.rsvpReader.syncRevision }
        set { state.rsvpReader.syncRevision = newValue }
    }
    private(set) var isRSVPReaderFollowingNarration: Bool {
        get { state.rsvpReader.followsNarration }
        set { state.rsvpReader.followsNarration = newValue }
    }
    private(set) var isRSVPReaderPlaybackRequested: Bool {
        get { state.rsvpReader.isPlaybackRequested }
        set { state.rsvpReader.isPlaybackRequested = newValue }
    }
    @Published private(set) var selectedBrowser: StudyBrowser
    private let browserSession: StudyBrowserSession
    @Published var browserAutomationStatus: AppleEventPermissionStatus = .unknown(0)
    @Published private(set) var shortcuts: [StudyShortcutAction: HotKeyDefinition]
    @Published private(set) var shortcutRegistrationStates: [StudyShortcutAction: ShortcutRegistrationState] = [:]
    @Published private(set) var speechSettings: SpeechSettings
    @Published private(set) var rsvpReadingSettings: RSVPReadingSettings
    @Published private(set) var qwenRuntimeReport: QwenRuntimeReport
    @Published private(set) var qwenInstallProgress: QwenInstallProgress?
    @Published private(set) var pocketIsInstalled = false
    @Published private(set) var pocketHasLegacyInstallation = false
    @Published private(set) var pocketInstallProgress: PocketInstallProgress?
    @Published private(set) var pocketError: String?
    @Published private(set) var rsvpPrecisionAlignmentState: RSVPPrecisionAlignmentState = .notInstalled
    @Published private(set) var rsvpPrecisionAlignmentProgress: RSVPPrecisionAlignmentProgress?
    @Published private(set) var modelWarmPolicy: ModelWarmPolicy
    @Published private(set) var qwenResidencyState: ModelResidencyState = .idle
    @Published private(set) var availableSpeechVoices: [SpeechVoiceOption]
    @Published private(set) var isRequestingBrowserAccess = false
    private let speechVoiceProvider: @MainActor () -> [SpeechVoiceOption]
    private let browserPermissionStatusProvider: @Sendable (StudyBrowser) async -> AppleEventPermissionStatus
    private var browserReadinessTask: Task<Void, Never>?

    var selectedAppleVoiceIsUnavailable: Bool {
        guard let identifier = speechSettings.voiceIdentifier else { return false }
        return !availableSpeechVoices.contains { $0.identifier == identifier }
    }

    func refreshSpeechVoices() {
        let voices = speechVoiceProvider()
        if voices != availableSpeechVoices { availableSpeechVoices = voices }
    }

    func openAppleVoiceSettings() {
        openSystemSettings(path: "x-apple.systempreferences:com.apple.preference.universalaccess")
    }

    private let router: StudyActionRouter
    private let speechBackend: StudySpeechBackend?
    private let qwenRuntime: QwenRuntimeManager
    private let pocketRuntime: PocketRuntimeManager
    private let rsvpPrecisionAlignmentRuntime: RSVPPrecisionAlignmentRuntime
    private let userDefaults: UserDefaults
    private var registeredHotKeys: [StudyShortcutAction: GlobalHotKey] = [:]
    private var currentActionTask: Task<Void, Never>?
    private var qwenInstallTask: Task<Void, Never>?
    private var pocketInstallTask: Task<Void, Never>?
    private var pocketWarmupTask: Task<Void, Never>?
    private var lastPocketInteractionAt = Date()
    private var rsvpPrecisionAlignmentInstallTask: Task<Void, Never>?
    private var qwenWarmupTask: Task<Void, Never>?
    private var qwenIdleTask: Task<Void, Never>?
    private var playbackHUDDecayTask: Task<Void, Never>?
    private var lastQwenWarmupKey: QwenWarmupKey?
    private var pendingQwenWarmupKey: QwenWarmupKey?
    private var currentActionID: UUID?
    private var lastQwenInteractionAt = Date()
    private var isSpeechPlaybackActive = false
    private var readAlongFrameStartByItemID: [String: Int] = [:]
    private var readAlongPlaybackItems: [SpeechPlaybackItem] = []
    private var readAlongItemsByID: [String: SpeechPlaybackItem] = [:]
    private var readAlongTimingByItemID: [String: SpeechPlaybackItemTiming] = [:]
    private var readAlongCueTrackByItemID: [String: SpeechPlaybackWordCueTrack] = [:]
    private var frozenReadAlongCueTrackByItemID: [String: SpeechPlaybackWordCueTrack] = [:]
    private var readAlongClockActiveItemID: String?
    private var readAlongMode: CaptureMode?
    private var rsvpReaderDisplayedFrameIndex = 0
    private var rsvpReadAlongCloseTask: Task<Void, Never>?
    private var rsvpTimingCalibrationStore = RSVPTimingCalibrationStore()
    private var memoryPressureSource: DispatchSourceMemoryPressure?
    private let disablesAutomaticModelWarmup: Bool
    private let uiFixture: UIFixture?
    private static let modelWarmPolicyDefaultsKey = "modelWarmPolicy"

    init(
        router: StudyActionRouter? = nil,
        userDefaults: UserDefaults = .standard,
        qwenRuntime injectedQwenRuntime: QwenRuntimeManager? = nil,
        pocketRuntime injectedPocketRuntime: PocketRuntimeManager? = nil,
        rsvpPrecisionAlignmentRuntime injectedRSVPPrecisionAlignmentRuntime: RSVPPrecisionAlignmentRuntime? = nil,
        disablesAutomaticModelWarmup: Bool = false,
        launchConfiguration: AppLaunchConfiguration? = nil,
        speechVoiceProvider: @escaping @MainActor () -> [SpeechVoiceOption] = { AVFoundationSpeechBackend.availableVoices() },
        browserPermissionStatusProvider: @escaping @Sendable (StudyBrowser) async -> AppleEventPermissionStatus = { await BrowserAutomationPermissionService.statusAsync(browser: $0) }
    ) {
        let launchInterval = SalientSignposts.begin(.launch)
        let launchConfiguration = launchConfiguration ?? AppLaunchConfiguration.parse(arguments: [])
        let loadedSpeechSettingsResult = Self.loadSpeechSettings(from: userDefaults)
        let loadedSpeechSettings = loadedSpeechSettingsResult.settings
        let loadedRSVPReadingSettingsResult = Self.loadRSVPReadingSettings(from: userDefaults)
        let loadedRSVPReadingSettings = loadedRSVPReadingSettingsResult.settings
        let availableSpeechVoices = speechVoiceProvider()
        let speechSettings = loadedSpeechSettings.clamped
        let qwenRuntime = injectedQwenRuntime ?? QwenRuntimeManager()
        let pocketRuntime = injectedPocketRuntime ?? PocketRuntimeManager()
        let rsvpPrecisionAlignmentRuntime =
            injectedRSVPPrecisionAlignmentRuntime ?? RSVPPrecisionAlignmentRuntime()
        self.userDefaults = userDefaults
        let browserSession = StudyBrowserSession(browser: StudyBrowser(rawValue: userDefaults.string(forKey: "study.browser") ?? "") ?? .safari)
        self.browserSession = browserSession
        self.selectedBrowser = browserSession.browser
        self.shortcuts = Self.loadShortcuts(from: userDefaults)
        self.speechSettings = speechSettings
        self.rsvpReadingSettings = loadedRSVPReadingSettings
        self.state = AppState(speechSettings: speechSettings, rsvpSettings: loadedRSVPReadingSettings)
        self.rsvpTimingCalibrationStore = Self.loadRSVPTimingCalibrationStore(from: userDefaults)
        self.availableSpeechVoices = availableSpeechVoices
        self.speechVoiceProvider = speechVoiceProvider
        self.browserPermissionStatusProvider = browserPermissionStatusProvider
        self.qwenRuntime = qwenRuntime
        self.pocketRuntime = pocketRuntime
        self.rsvpPrecisionAlignmentRuntime = rsvpPrecisionAlignmentRuntime
        self.modelWarmPolicy =
            ModelWarmPolicy(
                rawValue: userDefaults.string(forKey: Self.modelWarmPolicyDefaultsKey) ?? ""
            ) ?? .adaptive
        self.uiFixture = launchConfiguration.uiFixture
        self.disablesAutomaticModelWarmup =
            disablesAutomaticModelWarmup
            || launchConfiguration.disablesModelWarmup
            || launchConfiguration.uiFixture != nil
        self.qwenRuntimeReport = Self.initialQwenRuntimeReport(runtime: qwenRuntime)

        if let router {
            self.router = router
            self.speechBackend = nil
        } else {
            let speechBackend = StudySpeechBackend(
                settings: speechSettings,
                qwen: QwenSpeechBackend(
                    settings: speechSettings,
                    runtime: qwenRuntime,
                    wordAligner: rsvpPrecisionAlignmentRuntime
                ),
                pocket: PocketSpeechBackend(settings: speechSettings, runtime: pocketRuntime)
            )
            self.speechBackend = speechBackend
            self.router = StudyActionRouter(
                browser: AppleEventBrowserAutomationService(session: browserSession),
                speech: speechBackend,
                readPlanBuilder: ReadPlanBuilder(options: speechSettings.readPlanOptions)
            )
            speechBackend.visualizationSink = self
        }
        self.router.updateReadPlanOptions(speechSettings.readPlanOptions)
        self.router.readAlongPresentationSink = self
        self.state.readiness.warmPolicy = self.modelWarmPolicy

        if loadedSpeechSettingsResult.requiresSave || speechSettings != loadedSpeechSettings {
            saveSpeechSettings(speechSettings)
        }
        if loadedRSVPReadingSettingsResult.requiresSave {
            saveRSVPReadingSettings(rsvpReadingSettings)
        }
        state.navigation.selectedSection = selectedSection
        refreshReadiness()
        refreshRSVPPrecisionAlignmentState()
        registerConfiguredHotKeys(reportStatus: false)
        if launchConfiguration.uiFixture != nil {
            applyLaunchFixture(launchConfiguration.uiFixture)
        }
        configureMemoryPressureMonitoring()
        SalientSignposts.end(launchInterval)
    }

    var permissionReport: PermissionCenterReport {
        PermissionCenterReport.current(
            safariAutomation: browserAutomationStatus,
            globalHotKeyEnabled: globalShortcutsEnabled,
            browser: selectedBrowser
        )
    }

    var globalShortcutsEnabled: Bool {
        shortcuts.values.contains { $0.isEnabled }
    }

    func showMainWindow(section: AppSection? = nil) {
        if let section {
            selectedSection = section
        }
        openMainWindow?()
        NSApp.activate(ignoringOtherApps: true)
        let candidate =
            NSApp.windows.first { window in
                window.isVisible && window.canBecomeKey && window.title == Self.displayName
            } ?? NSApp.windows.first { $0.canBecomeKey }
        candidate?.makeKeyAndOrderFront(nil)
    }

    func run(_ action: StudyAction) {
        noteQwenInteraction(triggerWarmup: false)
        if action.interruptsQwenWarmup {
            qwenWarmupTask?.cancel()
        }
        let actionID = UUID()
        let previousActionTask = currentActionTask
        currentActionID = actionID
        previousActionTask?.cancel()

        let task = Task {
            // Stop audible playback before waiting for cancelled generation to unwind.
            if action.interruptsQwenWarmup { await speechBackend?.stop() }
            _ = await previousActionTask?.value
            guard !Task.isCancelled, currentActionID == actionID else { return }
            await runAction(action, actionID: actionID)
        }
        currentActionTask = task
    }

    func runAction(_ action: StudyAction) async {
        noteQwenInteraction(triggerWarmup: false)
        await runAction(action, actionID: nil)
    }

    private func runAction(_ action: StudyAction, actionID: UUID?) async {
        guard actionID == nil || currentActionID == actionID else { return }

        isBusy = true
        lastError = nil
        statusMessage = "\(action.title) running..."
        playbackHUDMode = action.playbackVisualizationContext

        let result = await router.run(action)

        guard actionID == nil || currentActionID == actionID else { return }

        isBusy = false
        lastAction = action.title
        statusMessage = result.message
        lastError = result.status == .failed ? result.message : nil
        playbackHUDMode = .neutral
        if actionID != nil {
            currentActionID = nil
            currentActionTask = nil
        }
        refreshReadiness()
        scheduleQwenIdleUnload()
    }

    func openSyntheticFixture() {
        guard let url = FixtureProvider.syntheticFixtureURL else {
            lastError = "Synthetic fixture is missing from the app bundle."
            statusMessage = lastError ?? "Fixture missing."
            return
        }
        openInStudyBrowser(
            url,
            successMessage: "Synthetic fixture opened in \(selectedBrowser.title).",
            failureMessage: "Could not open \(selectedBrowser.title) fixture."
        )
    }

    func openUWorldLogin() {
        noteQwenInteraction(triggerWarmup: true)
        guard let url = URL(string: "https://www.uworld.com/app/index.html#/login/") else {
            lastError = "The UWorld login URL is invalid."
            statusMessage = "Could not open UWorld login."
            return
        }
        openInStudyBrowser(
            url,
            successMessage: "UWorld login opened in \(selectedBrowser.title).",
            failureMessage: "Could not open UWorld login."
        )
    }

    func shortcut(for action: StudyShortcutAction) -> HotKeyDefinition {
        shortcuts[action] ?? action.defaultShortcut
    }

    func shortcutRegistrationState(for action: StudyShortcutAction) -> ShortcutRegistrationState {
        shortcutRegistrationStates[action] ?? .disabled
    }

    func setShortcut(_ shortcut: HotKeyDefinition, for action: StudyShortcutAction) {
        var updated = shortcuts
        updated[action] = shortcut
        shortcuts = updated
        saveShortcut(shortcut, for: action)
        registerConfiguredHotKeys(reportStatus: true)
    }

    func setShortcutEnabled(_ enabled: Bool, for action: StudyShortcutAction) {
        var shortcut = shortcut(for: action)
        shortcut.isEnabled = enabled
        setShortcut(shortcut, for: action)
    }

    func resetShortcut(for action: StudyShortcutAction) {
        setShortcut(action.defaultShortcut, for: action)
    }

    func setSpeechRateMultiplier(_ value: Double) {
        var settings = speechSettings
        settings.rateMultiplier = value
        updateSpeechSettings(settings)
    }

    func setSpeechVolume(_ value: Double) {
        var settings = speechSettings
        settings.volume = value
        updateSpeechSettings(settings)
    }

    func setSpeechPitchMultiplier(_ value: Double) {
        var settings = speechSettings
        settings.pitchMultiplier = value
        updateSpeechSettings(settings)
    }

    func setQwenDeEsserStrengthDecibels(_ value: Double) {
        var settings = speechSettings
        settings.qwenDeEsserStrengthDecibels = value
        updateSpeechSettings(settings)
    }

    func setSpeechVoiceIdentifier(_ identifier: String?) {
        var settings = speechSettings
        settings.voiceIdentifier = identifier
        updateSpeechSettings(settings)
    }

    func setSpeechEngineID(_ engineID: SpeechEngineID) {
        var settings = speechSettings
        settings.engineID = engineID
        if let lane = engineID.qwenLane,
            !lane.presetSpeakers.contains(settings.qwenSpeaker)
        {
            settings.qwenSpeaker = lane.defaultSpeaker
        }
        if engineID.qwenLane != nil, !settings.qwenUseReferenceVoice {
            settings.qwenUseReferenceVoice = true
            if settings.qwenReferenceVoiceID == .studentClone, settings.hasQwenStudentReferenceVoice {
                settings.qwenReferenceVoiceID = .studentClone
            } else {
                settings.qwenReferenceVoiceID = .crispStudyVoice
            }
        }
        updateSpeechSettings(settings)
    }

    func setQwenSpeaker(_ speaker: String) {
        var settings = speechSettings
        settings.qwenSpeaker = speaker
        updateSpeechSettings(settings)
    }

    func setQwenUseReferenceVoice(_ useReferenceVoice: Bool) {
        var settings = speechSettings
        settings.qwenUseReferenceVoice = useReferenceVoice
        if useReferenceVoice {
            if settings.engineID.qwenLane == nil {
                settings.engineID = .qwenBest
            }
            if settings.qwenReferenceVoiceID == .studentClone, !settings.hasQwenStudentReferenceVoice {
                settings.qwenReferenceVoiceID = .crispStudyVoice
            }
        }
        updateSpeechSettings(settings)
    }

    func setQwenReferenceVoiceID(_ voiceID: QwenReferenceVoiceID) {
        var settings = speechSettings
        if settings.engineID.qwenLane == nil {
            settings.engineID = .qwenBest
        }
        settings.qwenReferenceVoiceID = voiceID
        settings.qwenUseReferenceVoice = true
        if voiceID == .crispStudyVoice {
            settings.qwenSpeaker = settings.engineID.qwenLane?.defaultSpeaker ?? QwenModelLane.small.defaultSpeaker
        }
        updateSpeechSettings(settings)
        if speechSettings.qwenReferenceVoiceID == .crispStudyVoice {
            statusMessage = "\(QwenReferenceVoiceDefaults.displayName) selected."
            lastError = nil
        } else {
            statusMessage = "My Voice selected."
            lastError = nil
        }
    }

    func usePreviousQwenReferenceVoice() {
        var settings = speechSettings
        if settings.engineID.qwenLane == nil {
            settings.engineID = .qwenBest
        }
        settings.qwenUseReferenceVoice = true
        settings.qwenReferenceVoiceID = .crispStudyVoice
        settings.qwenSpeaker = settings.engineID.qwenLane?.defaultSpeaker ?? QwenModelLane.small.defaultSpeaker
        updateSpeechSettings(settings)
        statusMessage = "\(QwenReferenceVoiceDefaults.displayName) selected."
        lastError = nil
    }

    func chooseQwenReferenceAudio() {
        let panel = NSOpenPanel()
        panel.title = "Choose Reference Voice"
        panel.allowedContentTypes = [.wav]
        panel.allowsMultipleSelection = false
        panel.canChooseDirectories = false
        panel.canChooseFiles = true

        guard panel.runModal() == .OK, let url = panel.url else { return }
        Task {
            do {
                let studentVoice = try await qwenRuntime.importStudentReferenceVoice(from: url)
                await MainActor.run {
                    var settings = self.speechSettings
                    if settings.engineID.qwenLane == nil {
                        settings.engineID = .qwenBest
                    }
                    settings.qwenUseReferenceVoice = true
                    settings.qwenReferenceVoiceID = .studentClone
                    settings.qwenStudentReferenceVoice = studentVoice
                    self.updateSpeechSettings(settings)
                    self.statusMessage = "Reference voice imported."
                    self.lastError = nil
                }
            } catch {
                await MainActor.run {
                    self.statusMessage = "Could not import reference voice."
                    self.lastError = error.localizedDescription
                }
            }
        }
    }

    @discardableResult
    func saveQwenStudentReferenceVoice(from url: URL) async -> Bool {
        do {
            let studentVoice = try await qwenRuntime.importStudentReferenceVoice(from: url)
            var settings = speechSettings
            if settings.engineID.qwenLane == nil {
                settings.engineID = .qwenBest
            }
            settings.qwenUseReferenceVoice = true
            settings.qwenReferenceVoiceID = .studentClone
            settings.qwenStudentReferenceVoice = studentVoice
            updateSpeechSettings(settings)
            statusMessage = "My Voice saved."
            lastError = nil
            return true
        } catch {
            statusMessage = "Could not save My Voice."
            lastError = error.localizedDescription
            return false
        }
    }

    private func scheduleSelectedQwenWarmupIfReady(settings: SpeechSettings) {
        guard !disablesAutomaticModelWarmup else { return }
        guard modelWarmPolicy == .alwaysWarm || (modelWarmPolicy == .adaptive && selectedSectionTriggersQwenWarmup) else {
            return
        }
        guard let key = QwenWarmupKey(settings: settings),
            qwenRuntimeReport.status(for: key.lane, useReferenceVoice: key.useReferenceVoice) == .ready
        else {
            return
        }
        guard lastQwenWarmupKey != key, pendingQwenWarmupKey != key else { return }
        qwenWarmupTask?.cancel()
        pendingQwenWarmupKey = key
        qwenWarmupTask = Task { [weak self, key] in
            guard let self else { return }
            await self.prewarmSelectedQwenIfReady(key: key)
        }
    }

    private func prewarmSelectedQwenIfReady(key: QwenWarmupKey) async {
        defer {
            if pendingQwenWarmupKey == key {
                pendingQwenWarmupKey = nil
                qwenWarmupTask = nil
            }
        }
        guard QwenWarmupKey(settings: speechSettings) == key else { return }
        guard qwenRuntimeReport.status(for: key.lane, useReferenceVoice: key.useReferenceVoice) == .ready else {
            return
        }
        let settings = speechSettings
        let voice = settings.effectiveQwenReferenceVoice
        let displayName = key.useReferenceVoice ? voice.displayName : key.lane.displayName
        statusMessage = "Warming \(displayName)..."
        qwenResidencyState = .warming
        let modelLoadInterval = SalientSignposts.begin(.modelLoad)
        defer { SalientSignposts.end(modelLoadInterval) }
        do {
            try await qwenRuntime.prewarm(
                lane: key.lane,
                speaker: key.speaker,
                useReferenceVoice: key.useReferenceVoice,
                referenceAudioPath: key.referenceAudioPath,
                referenceText: key.referenceText
            )
            if key.usesQuestionPromptAudioLibrary {
                try await qwenRuntime.prewarmQuestionStarters(
                    lane: key.lane,
                    speaker: key.speaker,
                    useReferenceVoice: key.useReferenceVoice,
                    rateMultiplier: key.rateMultiplier,
                    qwenDeEsserStrengthDecibels: settings.qwenDeEsserStrengthDecibels,
                    referenceAudioPath: key.referenceAudioPath,
                    referenceText: key.referenceText
                )
            }
            lastQwenWarmupKey = key
            qwenResidencyState = await qwenRuntime.isResident() ? .resident : .selected
            statusMessage =
                qwenResidencyState == .resident
                ? "\(displayName) is resident."
                : "\(displayName) is selected."
            lastError = nil
            lastQwenInteractionAt = Date()
            scheduleQwenIdleUnload()
        } catch is CancellationError {
            qwenResidencyState = await qwenRuntime.isResident() ? .resident : .selected
        } catch {
            qwenResidencyState = .selected
            statusMessage = "\(displayName) is selected."
            lastError = error.localizedDescription
        }
    }

    func setShowPlaybackHUD(_ showPlaybackHUD: Bool) {
        var settings = speechSettings
        settings.showPlaybackHUD = showPlaybackHUD
        updateSpeechSettings(settings)
        if !showPlaybackHUD {
            isPlaybackHUDVisible = false
            playbackHUDFrame = .levelOnly(0)
            playbackHUDMode = .neutral
            isPlaybackHUDGenerating = false
        }
    }

    func setPlaybackHUDAppearance(_ appearance: PlaybackHUDAppearance) {
        var settings = speechSettings
        settings.playbackHUDAppearance = appearance
        updateSpeechSettings(settings)
    }

    func setRSVPWordsPerMinute(_ wordsPerMinute: Int) {
        var settings = rsvpReadingSettings
        settings.wordsPerMinute = wordsPerMinute
        updateRSVPReadingSettings(settings)
    }

    func setShowRSVPDuringNarration(_ showsDuringNarration: Bool) {
        var settings = rsvpReadingSettings
        settings.showsDuringNarration = showsDuringNarration
        userDefaults.set(true, forKey: Self.rsvpReadingNarrationPreferenceDefaultsKey)
        updateRSVPReadingSettings(settings)
    }

    func setRSVPORPEnabled(_ isEnabled: Bool) {
        var settings = rsvpReadingSettings
        settings.isORPEnabled = isEnabled
        updateRSVPReadingSettings(settings)
    }

    func setRSVPPunctuationPausesEnabled(_ isEnabled: Bool) {
        var settings = rsvpReadingSettings
        settings.usesPunctuationPauses = isEnabled
        updateRSVPReadingSettings(settings)
    }

    func setRSVPSectionPausesEnabled(_ isEnabled: Bool) {
        var settings = rsvpReadingSettings
        settings.usesSectionPauses = isEnabled
        updateRSVPReadingSettings(settings)
    }

    func closeRSVPReader() {
        cancelRSVPReadAlongDeferredClose()
        isRSVPReaderVisible = false
        isRSVPReaderFollowingNarration = false
        isRSVPReaderPlaybackRequested = false
        rsvpReadingPlan = nil
        readAlongFrameStartByItemID = [:]
        readAlongPlaybackItems = []
        readAlongItemsByID = [:]
        readAlongTimingByItemID = [:]
        readAlongCueTrackByItemID = [:]
        frozenReadAlongCueTrackByItemID = [:]
        readAlongClockActiveItemID = nil
        readAlongMode = nil
        rsvpReaderDisplayedFrameIndex = 0
    }

    func setReadsLastSentenceFirst(_ readsLastSentenceFirst: Bool) {
        var settings = speechSettings
        settings.readsLastSentenceFirst = readsLastSentenceFirst
        updateSpeechSettings(settings)
    }

    func setSkipsParentheticalContent(_ skipsParentheticalContent: Bool) {
        var settings = speechSettings
        settings.skipsParentheticalContent = skipsParentheticalContent
        updateSpeechSettings(settings)
    }

    func setUsesQuestionPromptAudioLibrary(_ usesQuestionPromptAudioLibrary: Bool) {
        var settings = speechSettings
        settings.usesQuestionPromptAudioLibrary = usesQuestionPromptAudioLibrary
        updateSpeechSettings(settings)
    }

    func resetSpeechSettings() {
        updateSpeechSettings(.firstLaunch)
        statusMessage = "Narration settings reset."
    }

    private func applyLaunchFixture(_ fixture: UIFixture?) {
        guard let fixture else { return }
        readingText = fixture == .empty ? "" : ReadingWorkspaceView.sampleText
        if fixture == .error { lastError = "Could not read the text. Choose a voice and try again." }
    }

    func previewSpeech() {
        run(.readText("This is the current study voice."))
    }

    func readEnteredText() {
        run(.readText(readingText))
    }

    func openEnteredTextInRSVP() {
        let text = readingText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return }
        openRSVPReadingPlan(
            RSVPReadingPlanBuilder(settings: rsvpReadingSettings).plan(
                title: "Read", sections: [.init(label: "Text", text: text)]
            ),
            followsNarration: false, requestedFrameIndex: 0, status: "Visual reader opened."
        )
    }

    func enableEssentialShortcuts() {
        for action in StudyShortcutAction.allCases {
            var shortcut = shortcut(for: action)
            shortcut.isEnabled = true
            shortcuts[action] = shortcut
            saveShortcut(shortcut, for: action)
        }
        registerConfiguredHotKeys(reportStatus: true)
    }

    func refreshReadiness() {
        guard uiFixture == nil else { return }
        if browserReadinessTask == nil, !isRequestingBrowserAccess {
            let provider = browserPermissionStatusProvider
            let browser = selectedBrowser
            browserReadinessTask = Task { [weak self] in
                let status = await provider(browser)
                guard let self, !Task.isCancelled else { return }
                self.browserReadinessTask = nil
                guard !self.isRequestingBrowserAccess, self.selectedBrowser == browser, !Task.isCancelled else { return }
                self.browserAutomationStatus = status
            }
        }
        Task { await refreshQwenReadiness() }
        Task { await refreshPocketReadiness() }
    }

    func refreshQwenReadiness() async {
        qwenRuntimeReport = await qwenRuntime.doctor()
        let isResident = await qwenRuntime.isResident()
        if qwenRuntimeReport.lastError != nil {
            qwenResidencyState = .failed
        } else if isResident {
            qwenResidencyState = .resident
        } else if qwenInstallProgress != nil || qwenRuntimeReport.installingLane != nil {
            qwenResidencyState = .warming
        } else if let key = QwenWarmupKey(settings: speechSettings),
            qwenRuntimeReport.isInstalled(key.lane, useReferenceVoice: key.useReferenceVoice)
        {
            qwenResidencyState = .selected
        } else if !qwenRuntimeReport.installedModelIDs.isEmpty {
            qwenResidencyState = .installed
        } else {
            qwenResidencyState = .idle
        }
        scheduleSelectedQwenWarmupIfReady(settings: speechSettings)
    }

    func refreshRSVPPrecisionAlignmentState() {
        Task { [weak self] in
            guard let self else { return }
            let state = await self.rsvpPrecisionAlignmentRuntime.currentState()
            await MainActor.run {
                self.rsvpPrecisionAlignmentState = state
            }
        }
    }

    func installRSVPPrecisionAlignment() {
        rsvpPrecisionAlignmentInstallTask?.cancel()
        rsvpPrecisionAlignmentState = .installing
        rsvpPrecisionAlignmentProgress = .init(
            stage: "Preparing precision sync",
            fractionCompleted: 0
        )
        rsvpPrecisionAlignmentInstallTask = Task { [weak self] in
            guard let self else { return }
            do {
                try await self.rsvpPrecisionAlignmentRuntime.install { [weak self] progress in
                    await MainActor.run {
                        self?.rsvpPrecisionAlignmentProgress = progress
                    }
                }
                let state = await self.rsvpPrecisionAlignmentRuntime.currentState()
                await MainActor.run {
                    self.rsvpPrecisionAlignmentState = state
                    self.rsvpPrecisionAlignmentProgress = nil
                    self.statusMessage = "RSVP precision sync is ready."
                    self.lastError = nil
                }
            } catch is CancellationError {
                let state = await self.rsvpPrecisionAlignmentRuntime.currentState()
                await MainActor.run {
                    self.rsvpPrecisionAlignmentState = state
                    self.rsvpPrecisionAlignmentProgress = nil
                }
            } catch {
                await MainActor.run {
                    self.rsvpPrecisionAlignmentState = .failed
                    self.rsvpPrecisionAlignmentProgress = nil
                    self.statusMessage = "RSVP precision sync setup failed."
                    self.lastError = error.localizedDescription
                }
            }
        }
    }

    func setModelWarmPolicy(_ policy: ModelWarmPolicy) {
        modelWarmPolicy = policy
        state.readiness.warmPolicy = policy
        userDefaults.set(policy.rawValue, forKey: Self.modelWarmPolicyDefaultsKey)
        qwenIdleTask?.cancel()
        statusMessage = "Model residency set to \(policy.displayName)."
        lastError = nil
        schedulePocketWarmupIfReady()

        switch policy {
        case .alwaysWarm:
            guard !disablesAutomaticModelWarmup else { return }
            scheduleSelectedQwenWarmupIfReady(settings: speechSettings)
        case .adaptive:
            handleSelectedSectionResidency()
            scheduleQwenIdleUnload()
        case .onDemand:
            Task { [weak self] in
                await self?.evaluateModelResidency()
            }
        }
    }

    private var selectedSectionTriggersQwenWarmup: Bool {
        selectedSection == .reading || selectedSection == .speech
    }

    private func handleSelectedSectionResidency() {
        switch selectedSection {
        case .reading, .speech:
            noteQwenInteraction(triggerWarmup: true)
        case .keyboardShortcuts, .permissions:
            break
        }
    }

    private func noteQwenInteraction(triggerWarmup: Bool) {
        lastQwenInteractionAt = Date()
        scheduleQwenIdleUnload()
        guard triggerWarmup else { return }
        scheduleSelectedQwenWarmupIfReady(settings: speechSettings)
    }

    private func scheduleQwenIdleUnload() {
        qwenIdleTask?.cancel()
        guard modelWarmPolicy != .alwaysWarm else { return }
        let delay: TimeInterval = modelWarmPolicy == .onDemand ? 0 : 15 * 60
        qwenIdleTask = Task { [weak self] in
            guard let self else { return }
            if delay > 0 {
                try? await Task.sleep(for: .seconds(delay))
            }
            guard !Task.isCancelled else { return }
            await self.evaluateModelResidency()
        }
    }

    private func configureMemoryPressureMonitoring() {
        let source = DispatchSource.makeMemoryPressureSource(
            eventMask: [.warning, .critical],
            queue: .main
        )
        source.setEventHandler { [weak self] in
            Task { @MainActor in
                await self?.evaluateModelResidency(memoryPressure: true)
            }
        }
        source.resume()
        memoryPressureSource = source
    }

    private func evaluateModelResidency(memoryPressure: Bool = false) async {
        let qwenResident = await qwenRuntime.isResident()
        let workload = ModelResidencyWorkload(
            isSpeechActive: isSpeechPlaybackActive,
            isSynthesisActive: isBusy,
            isDownloadActive: qwenInstallProgress != nil
        )
        let decision = ModelResidencyPolicyEvaluator.decision(
            policy: modelWarmPolicy,
            now: Date(),
            lastQwenInteractionAt: lastQwenInteractionAt,
            qwenInstalled: !qwenRuntimeReport.installedModelIDs.isEmpty,
            qwenResident: qwenResident,
            memoryPressure: memoryPressure,
            workload: workload
        )

        if decision.shouldUnloadQwen {
            qwenWarmupTask?.cancel()
            await qwenRuntime.unloadResidentHelpers()
            pendingQwenWarmupKey = nil
            lastQwenWarmupKey = nil
            qwenResidencyState = .idle
        }
        let pocketDecision = ModelResidencyPolicyEvaluator.decision(
            policy: modelWarmPolicy, now: Date(), lastQwenInteractionAt: lastPocketInteractionAt,
            qwenInstalled: pocketIsInstalled,
            qwenResident: await pocketRuntime.isResident(),
            memoryPressure: memoryPressure, workload: workload
        )
        if pocketDecision.shouldUnloadQwen, pocketInstallProgress == nil {
            await pocketRuntime.unload()
        }
        if pocketDecision.shouldWarmQwen { schedulePocketWarmupIfReady() }
        if decision.shouldWarmQwen, !disablesAutomaticModelWarmup {
            scheduleSelectedQwenWarmupIfReady(settings: speechSettings)
        }
        if memoryPressure {
            await rsvpPrecisionAlignmentRuntime.unload()
            rsvpPrecisionAlignmentState = await rsvpPrecisionAlignmentRuntime.currentState()
        }
    }

    func refreshPocketReadiness() async {
        pocketIsInstalled = await pocketRuntime.isInstalled()
        pocketHasLegacyInstallation = await pocketRuntime.hasLegacyInstallation()
        schedulePocketWarmupIfReady()
    }

    func removeLegacyPocket() {
        Task {
            do {
                let removed = try await pocketRuntime.removeLegacyInstallation()
                await refreshPocketReadiness()
                statusMessage = removed ? "The old Pocket setup was moved to Trash." : "The old setup contains files to review manually. Pocket is ready to use."
            } catch { statusMessage = "The old setup could not be moved to Trash. You can continue using Pocket." }
        }
    }

    private func schedulePocketWarmupIfReady() {
        guard speechSettings.engineID == .pocket, pocketIsInstalled, pocketInstallProgress == nil,
              modelWarmPolicy != .onDemand, !disablesAutomaticModelWarmup, pocketWarmupTask == nil else { return }
        lastPocketInteractionAt = Date()
        pocketWarmupTask = Task { [weak self] in
            guard let self else { return }
            defer { self.pocketWarmupTask = nil }
            do {
                try await self.pocketRuntime.warm()
                self.pocketError = nil
            } catch is CancellationError {
                // Stop or memory pressure invalidated warmup.
            } catch {
                self.pocketError = error.localizedDescription
            }
        }
    }

    func installPocket() {
        guard pocketInstallTask == nil else { return }
        pocketError = nil
        pocketInstallProgress = .init(stage: "Preparing Pocket", fraction: 0)
        pocketInstallTask = Task { [weak self] in
            guard let self else { return }
            defer { self.pocketInstallTask = nil }
            do {
                try await self.pocketRuntime.install { [weak self] progress in
                    await MainActor.run { self?.pocketInstallProgress = progress }
                }
                self.pocketInstallProgress = nil
                self.statusMessage = "Pocket TTS is ready."
                await self.refreshPocketReadiness()
            } catch is CancellationError {
                self.pocketInstallProgress = nil
                self.statusMessage = "Pocket download cancelled."
            } catch {
                self.pocketInstallProgress = nil
                self.pocketError = error.localizedDescription
            }
        }
    }

    func cancelPocketInstall() { pocketInstallTask?.cancel() }

    func installQwen(_ lane: QwenModelLane) {
        qwenInstallTask?.cancel()
        let useReferenceVoice = speechSettings.qwenUseReferenceVoice
        let referenceVoice = speechSettings.effectiveQwenReferenceVoice
        let setupName = lane.setupDisplayName(useReferenceVoice: useReferenceVoice)
        qwenInstallProgress = QwenInstallProgress(lane: lane, stage: "Starting setup", fractionCompleted: 0)
        statusMessage = "Installing \(setupName)..."
        lastError = nil
        qwenInstallTask = Task { [weak self] in
            guard let self else { return }
            do {
                try await self.qwenRuntime.install(
                    lane: lane,
                    useReferenceVoice: useReferenceVoice,
                    referenceAudioPath: useReferenceVoice ? referenceVoice.audioPath : nil,
                    referenceText: useReferenceVoice ? referenceVoice.transcript : nil
                ) { [weak self] progress in
                    await MainActor.run {
                        self?.qwenInstallProgress = progress
                        self?.statusMessage = progress.stage
                    }
                }
                await MainActor.run {
                    self.qwenInstallProgress = nil
                    self.statusMessage = "\(setupName) is ready."
                    self.lastError = nil
                }
                await self.refreshQwenReadiness()
            } catch is CancellationError {
                await MainActor.run {
                    self.qwenInstallProgress = nil
                    self.statusMessage = "Qwen setup cancelled."
                    self.lastError = nil
                }
                await self.refreshQwenReadiness()
            } catch {
                await MainActor.run {
                    self.qwenInstallProgress = nil
                    self.statusMessage = "Qwen setup failed."
                    self.lastError = error.localizedDescription
                }
                await self.refreshQwenReadiness()
            }
        }
    }

    func cancelQwenInstall() {
        qwenInstallTask?.cancel()
        qwenInstallTask = nil
        qwenInstallProgress = nil
        statusMessage = "Qwen setup cancelled."
    }

    private func noteSpeechPlaybackActivity(didEnd: Bool = false) {
        if speechSettings.engineID == .pocket { lastPocketInteractionAt = Date() }
        if speechSettings.engineID.qwenLane != nil {
            lastQwenInteractionAt = Date()
        }
        if didEnd {
            isSpeechPlaybackActive = false
            scheduleQwenIdleUnload()
        } else {
            isSpeechPlaybackActive = true
        }
    }

    func requestBrowserAutomationAccess() {
        guard !isRequestingBrowserAccess else { return }
        isRequestingBrowserAccess = true
        statusMessage = "Waiting for \(selectedBrowser.title) Automation approval…"
        Task {
            defer { isRequestingBrowserAccess = false }
            browserAutomationStatus = await BrowserAutomationPermissionService.requestAccess(browser: selectedBrowser)
            switch browserAutomationStatus {
            case .authorized:
                lastError = nil
                statusMessage = "\(selectedBrowser.title) Automation is authorized."
            case .notDetermined:
                lastError = "\(selectedBrowser.title) Automation still needs approval."
                statusMessage = "\(selectedBrowser.title) Automation needs approval."
            case .denied, .blocked:
                lastError = browserAutomationStatus.guidance(for: selectedBrowser)
                statusMessage = "\(selectedBrowser.title) Automation is not authorized."
                openAutomationSettings()
            case .unknown:
                lastError = browserAutomationStatus.guidance(for: selectedBrowser)
                statusMessage = "Could not confirm \(selectedBrowser.title) Automation."
            }
        }
    }

    func openAutomationSettings() {
        openSystemSettings(path: "x-apple.systempreferences:com.apple.preference.security?Privacy_Automation")
    }

    func openAccessibilitySettings() {
        openSystemSettings(path: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility")
    }

    func openStudyBrowser() {
        guard let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: selectedBrowser.bundleIdentifier) else {
            lastError = "Install \(selectedBrowser.title) or choose a different browser."
            return
        }
        NSWorkspace.shared.openApplication(at: url, configuration: NSWorkspace.OpenConfiguration())
    }

    func setStudyBrowser(_ browser: StudyBrowser) {
        guard browser != selectedBrowser, !isBusy, !isRequestingBrowserAccess else { return }
        browserReadinessTask?.cancel()
        browserReadinessTask = nil
        selectedBrowser = browser
        browserSession.browser = browser
        userDefaults.set(browser.rawValue, forKey: "study.browser")
        browserAutomationStatus = .unknown(0)
        lastError = nil
        statusMessage = "Study actions now use the front tab in \(browser.title)."
        refreshReadiness()
    }

    func showCurrentAppInFinder() {
        NSWorkspace.shared.activateFileViewerSelecting([Bundle.main.bundleURL])
    }

    func resetBrowserAutomationPermission() {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/tccutil")
        process.arguments = ["reset", "AppleEvents", Bundle.main.bundleIdentifier ?? "com.zhuou.salient.mini"]
        do {
            try process.run()
            process.waitUntilExit()
            refreshReadiness()
            statusMessage =
                process.terminationStatus == 0
                ? "Automation permission reset. Click Request Access again."
                : "Automation reset command finished with status \(process.terminationStatus)."
        } catch {
            lastError = error.localizedDescription
            statusMessage = "Could not reset Automation permission."
        }
    }

    private func openSystemSettings(path: String) {
        guard let url = URL(string: path) else { return }
        NSWorkspace.shared.open(url)
    }

    private func openInStudyBrowser(
        _ url: URL,
        successMessage: String,
        failureMessage: String
    ) {
        guard let applicationURL = NSWorkspace.shared.urlForApplication(withBundleIdentifier: selectedBrowser.bundleIdentifier) else {
            lastError = "Install \(selectedBrowser.title) or choose a different browser."
            return
        }
        NSWorkspace.shared.open(
            [url],
            withApplicationAt: applicationURL,
            configuration: NSWorkspace.OpenConfiguration()
        ) { _, error in
            Task { @MainActor in
                if let error {
                    self.lastError = error.localizedDescription
                    self.statusMessage = failureMessage
                } else {
                    self.lastError = nil
                    self.statusMessage = successMessage
                }
            }
        }
    }

    private func updateSpeechSettings(_ settings: SpeechSettings) {
        let clamped = settings.clamped
        speechSettings = clamped
        speechBackend?.settings = clamped
        router.updateReadPlanOptions(clamped.readPlanOptions)
        saveSpeechSettings(clamped)
        statusMessage = "Narration settings updated."
        lastError = nil
        scheduleSelectedQwenWarmupIfReady(settings: clamped)
        schedulePocketWarmupIfReady()
    }

    private func updateRSVPReadingSettings(_ settings: RSVPReadingSettings) {
        let clamped = settings.clamped
        rsvpReadingSettings = clamped
        saveRSVPReadingSettings(clamped)
        statusMessage = "Visual reader settings updated."
        lastError = nil
    }

    private func openRSVPReadingPlan(
        _ plan: RSVPReadingPlan,
        followsNarration: Bool,
        requestedFrameIndex: Int,
        status: String,
        playImmediately: Bool = true
    ) {
        guard !plan.frames.isEmpty else {
            cancelRSVPReadAlongDeferredClose()
            isRSVPReaderVisible = false
            rsvpReadingPlan = nil
            isRSVPReaderFollowingNarration = false
            isRSVPReaderPlaybackRequested = false
            statusMessage = "No readable text was found for the visual reader."
            return
        }
        rsvpReadingPlan = plan
        isRSVPReaderFollowingNarration = followsNarration
        isRSVPReaderPlaybackRequested = playImmediately
        isRSVPReaderVisible = true
        rsvpReaderDisplayedFrameIndex = min(max(requestedFrameIndex, 0), max(0, plan.frames.count - 1))
        requestRSVPReaderFrame(requestedFrameIndex)
        statusMessage = status
        lastError = nil
    }

    private func requestRSVPReaderFrame(_ frameIndex: Int) {
        let maxIndex = max(0, (rsvpReadingPlan?.frames.count ?? 1) - 1)
        rsvpReaderRequestedFrameIndex = min(max(frameIndex, 0), maxIndex)
        rsvpReaderDisplayedFrameIndex = rsvpReaderRequestedFrameIndex
        rsvpReaderSyncRevision &+= 1
    }

    func readAlongPresentationWillStart(items: [SpeechPlaybackItem], mode: CaptureMode) {
        guard rsvpReadingSettings.showsDuringNarration else { return }
        startReadAlongPresentation(items: items, mode: mode)
    }

    func readAlongPresentationDidReceiveFinalPlaybackItems(_ items: [SpeechPlaybackItem], mode: CaptureMode) {
        guard isRSVPReaderFollowingNarration, rsvpReadingSettings.showsDuringNarration else { return }
        startReadAlongPresentation(
            items: items,
            mode: mode,
            requestedFrameIndex: rsvpReaderRequestedFrameIndex,
            status: "Visual reader following narration.",
            playImmediately: isRSVPReaderPlaybackRequested
        )
    }

    func readAlongPresentationDidReceiveTiming(_ timing: SpeechPlaybackItemTiming) {
        guard isRSVPReaderFollowingNarration else { return }
        guard timing.durationSeconds.isFinite, timing.durationSeconds > 0 else { return }
        readAlongTimingByItemID[timing.itemID] = timing
        if let item = readAlongItemsByID[timing.itemID],
           let sourceDuration = timing.sourceAudioDurationSeconds,
           let track = RSVPReadAlongCueTrackBuilder().weightedFallbackTrack(
               item: item,
               itemIndex: timing.itemIndex,
               settings: rsvpReadingSettings,
               sourceAudioDurationSeconds: sourceDuration,
               audibleStartSeconds: timing.audibleStartSeconds,
               audibleEndSeconds: timing.audibleEndSeconds
           ) {
            readAlongPresentationDidReceiveWordCueTrack(track)
        }
    }

    func readAlongPresentationDidReceiveWordCueTrack(_ track: SpeechPlaybackWordCueTrack) {
        guard isRSVPReaderFollowingNarration,
              readAlongItemsByID[track.itemID] != nil,
              !track.cues.isEmpty else {
            return
        }
        if let current = readAlongCueTrackByItemID[track.itemID],
           current.source == .forcedAligned,
           track.source != .forcedAligned {
            return
        }
        readAlongCueTrackByItemID[track.itemID] = track
    }

    func readAlongPresentationDidReceiveProgress(_ progress: SpeechPlaybackProgress) {
        guard isRSVPReaderFollowingNarration,
              let itemStartIndex = readAlongFrameStartByItemID[progress.itemID] else {
            return
        }
        readAlongClockActiveItemID = progress.itemID
        if let tokenIndex = progress.currentTokenIndex {
            let requestedIndex = itemStartIndex + max(0, tokenIndex)
            if isRSVPReaderPlaybackRequested {
                isRSVPReaderPlaybackRequested = false
            }
            if requestedIndex != rsvpReaderRequestedFrameIndex {
                requestRSVPReaderFrame(requestedIndex)
            }
            return
        }
        let track: SpeechPlaybackWordCueTrack
        if let frozen = frozenReadAlongCueTrackByItemID[progress.itemID] {
            track = frozen
        } else if let available = readAlongCueTrackByItemID[progress.itemID] {
            frozenReadAlongCueTrackByItemID[progress.itemID] = available
            track = available
        } else {
            return
        }
        guard let cueIndex = track.cueIndex(
            at: progress.sourcePositionSeconds,
            visualOffset: .effectiveDeveloperOverride,
            playbackRate: progress.playbackRate
        ),
              track.cues.indices.contains(cueIndex) else {
            return
        }
        let requestedIndex = itemStartIndex + track.cues[cueIndex].tokenIndex
        if isRSVPReaderPlaybackRequested {
            isRSVPReaderPlaybackRequested = false
        }
        if requestedIndex != rsvpReaderRequestedFrameIndex {
            requestRSVPReaderFrame(requestedIndex)
        }
    }

    private func startReadAlongPresentation(
        items: [SpeechPlaybackItem],
        mode: CaptureMode,
        requestedFrameIndex: Int = 0,
        status: String = "Visual reader following narration.",
        playImmediately: Bool = false
    ) {
        cancelRSVPReadAlongDeferredClose()
        let title: String
        switch mode {
        case .question:
            title = "Question Narration"
        case .explanation:
            title = "Explanation Narration"
        }
        readAlongMode = mode
        readAlongPlaybackItems = items
        readAlongItemsByID = Dictionary(uniqueKeysWithValues: items.map { ($0.id, $0) })
        readAlongFrameStartByItemID = Self.readAlongFrameStarts(for: items)
        readAlongTimingByItemID = readAlongTimingByItemID.filter { readAlongItemsByID[$0.key] != nil }
        readAlongCueTrackByItemID = readAlongCueTrackByItemID.filter { readAlongItemsByID[$0.key] != nil }
        frozenReadAlongCueTrackByItemID = [:]
        readAlongClockActiveItemID = nil
        let plan = makeReadAlongPlan(items: items, title: title)
        openRSVPReadingPlan(
            plan,
            followsNarration: true,
            requestedFrameIndex: requestedFrameIndex,
            status: status,
            playImmediately: playImmediately
        )
    }

    func readAlongPresentationWillSpeak(item: SpeechPlaybackItem, itemIndex: Int) {
        guard isRSVPReaderFollowingNarration else { return }
        cancelRSVPReadAlongDeferredClose()
        let requestedIndex = readAlongFrameStartByItemID[item.id] ?? itemIndex
        if let track = readAlongCueTrackByItemID[item.id] {
            frozenReadAlongCueTrackByItemID[item.id] = track
        }
        isRSVPReaderPlaybackRequested = false
        guard readAlongClockActiveItemID != item.id else { return }
        requestRSVPReaderFrame(requestedIndex)
    }

    func readAlongPresentationDidFinishItem(item: SpeechPlaybackItem, itemIndex: Int) {
        guard isRSVPReaderFollowingNarration else { return }
        guard let itemEndIndex = readAlongEndFrameIndex(for: item.id),
            rsvpReaderDisplayedFrameIndex < itemEndIndex
        else {
            return
        }
        isRSVPReaderPlaybackRequested = false
    }

    func readAlongPresentationDidEnd() {
        guard isRSVPReaderFollowingNarration else { return }
        if hasDisplayedFinalRSVPReadAlongFrame {
            closeRSVPReader()
            return
        }
        isRSVPReaderPlaybackRequested = false
        scheduleRSVPReadAlongDeferredClose()
    }

    func rsvpReaderDisplayedFrameDidChange(_ frameIndex: Int) {
        guard let frames = rsvpReadingPlan?.frames, !frames.isEmpty else {
            rsvpReaderDisplayedFrameIndex = 0
            return
        }
        rsvpReaderDisplayedFrameIndex = min(max(frameIndex, 0), frames.count - 1)
        if rsvpReadAlongCloseTask != nil,
            hasDisplayedFinalRSVPReadAlongFrame
        {
            closeRSVPReader()
        }
    }

    private func rebuildReadAlongPlan(requestedFrameIndex: Int) {
        guard let mode = readAlongMode else { return }
        let title: String
        switch mode {
        case .question:
            title = "Question Narration"
        case .explanation:
            title = "Explanation Narration"
        }
        rsvpReadingPlan = makeReadAlongPlan(items: readAlongPlaybackItems, title: title)
        requestRSVPReaderFrame(requestedFrameIndex)
    }

    private func makeReadAlongPlan(items: [SpeechPlaybackItem], title: String) -> RSVPReadingPlan {
        let basePlan = RSVPReadingPlanBuilder(settings: rsvpReadingSettings).plan(from: items, title: title)
        return planByApplyingReadAlongTiming(to: basePlan, items: items)
    }

    func speechPlaybackVisualizationDidStart() {
        noteSpeechPlaybackActivity()
        guard speechSettings.showPlaybackHUD else { return }
        playbackHUDDecayTask?.cancel()
        playbackHUDDecayTask = nil
        playbackHUDFrame = .levelOnly(0)
        isPlaybackHUDGenerating = true
        isPlaybackHUDVisible = true
    }

    func speechPlaybackVisualizationAudioDidStart() {
        noteSpeechPlaybackActivity()
        guard speechSettings.showPlaybackHUD else { return }
        playbackHUDDecayTask?.cancel()
        playbackHUDDecayTask = nil
        isPlaybackHUDGenerating = false
    }

    func speechPlaybackVisualizationAudioDidStop() {
        guard speechSettings.showPlaybackHUD else { return }
        guard isPlaybackHUDVisible, !isPlaybackHUDGenerating else { return }
        startPlaybackHUDDecay(from: playbackHUDFrame)
    }

    func speechPlaybackVisualizationLevelDidChange(_ level: Double) {
        guard speechSettings.showPlaybackHUD else { return }
        guard !isPlaybackHUDGenerating else { return }
        playbackHUDDecayTask?.cancel()
        playbackHUDDecayTask = nil
        applyPlaybackHUDFrame(.levelOnly(level))
    }

    func speechPlaybackVisualizationFrameDidChange(_ frame: SpeechPlaybackVisualizationFrame) {
        guard speechSettings.showPlaybackHUD else { return }
        playbackHUDDecayTask?.cancel()
        playbackHUDDecayTask = nil
        applyPlaybackHUDFrame(frame)
    }

    func speechPlaybackVisualizationDidEnd() {
        noteSpeechPlaybackActivity(didEnd: true)
        playbackHUDDecayTask?.cancel()
        playbackHUDDecayTask = nil
        isPlaybackHUDVisible = false
        playbackHUDFrame = .levelOnly(0)
        playbackHUDMode = .neutral
        isPlaybackHUDGenerating = false
    }

    private func startPlaybackHUDDecay(from frame: SpeechPlaybackVisualizationFrame) {
        playbackHUDDecayTask?.cancel()
        playbackHUDDecayTask = nil
        let startingLevel = max(frame.level, frame.barLevels.max() ?? 0)
        guard startingLevel > 0 else {
            applyPlaybackHUDFrame(.levelOnly(0, barCount: max(1, frame.barLevels.count)))
            return
        }

        playbackHUDDecayTask = Task { @MainActor [weak self] in
            let interval = 1.0 / 30.0
            let duration = 0.34
            let timeConstant = 0.075
            var elapsed = interval
            while !Task.isCancelled, elapsed <= duration {
                guard let self else { return }
                let scale = exp(-elapsed / timeConstant)
                self.applyPlaybackHUDFrame(Self.decayedPlaybackHUDFrame(frame, scale: scale))
                try? await Task.sleep(nanoseconds: UInt64(interval * 1_000_000_000))
                elapsed += interval
            }
            guard let self, !Task.isCancelled else { return }
            self.applyPlaybackHUDFrame(.levelOnly(0, barCount: max(1, frame.barLevels.count)))
            self.playbackHUDDecayTask = nil
        }
    }

    private func applyPlaybackHUDFrame(_ frame: SpeechPlaybackVisualizationFrame) {
        if playbackHUDFrame != frame {
            playbackHUDFrame = frame
        }
    }

    private static func decayedPlaybackHUDFrame(
        _ frame: SpeechPlaybackVisualizationFrame,
        scale: Double
    ) -> SpeechPlaybackVisualizationFrame {
        let clampedScale = scale.isFinite ? min(1, max(0, scale)) : 0
        return SpeechPlaybackVisualizationFrame(
            level: frame.level * clampedScale,
            barLevels: frame.barLevels.map { $0 * clampedScale }
        )
    }

    private static func readAlongFrameStarts(for items: [SpeechPlaybackItem]) -> [String: Int] {
        var starts: [String: Int] = [:]
        var offset = 0
        for item in items {
            starts[item.id] = offset
            offset += RSVPReadingPlanBuilder.tokenCount(in: item.text)
        }
        return starts
    }

    private func readAlongEndFrameIndex(for itemID: String) -> Int? {
        guard let start = readAlongFrameStartByItemID[itemID],
            let item = readAlongItemsByID[itemID]
        else {
            return nil
        }
        let tokenCount = RSVPReadingPlanBuilder.tokenCount(in: item.text)
        guard tokenCount > 0 else { return nil }
        return start + tokenCount - 1
    }

    private var hasDisplayedFinalRSVPReadAlongFrame: Bool {
        guard let finalFrameIndex = rsvpReadingPlan?.frames.indices.last else { return true }
        return rsvpReaderDisplayedFrameIndex >= finalFrameIndex
    }

    private func scheduleRSVPReadAlongDeferredClose() {
        rsvpReadAlongCloseTask?.cancel()
        rsvpReadAlongCloseTask = Task { @MainActor [weak self] in
            try? await Task.sleep(nanoseconds: 1_200_000_000)
            guard let self, !Task.isCancelled else { return }
            self.closeRSVPReader()
        }
    }

    private func cancelRSVPReadAlongDeferredClose() {
        rsvpReadAlongCloseTask?.cancel()
        rsvpReadAlongCloseTask = nil
    }

    private func planByApplyingReadAlongTiming(
        to plan: RSVPReadingPlan,
        items: [SpeechPlaybackItem]
    ) -> RSVPReadingPlan {
        var timedPlan = plan
        let calibrationKey = rsvpTimingCalibrationKey()
        let profile = rsvpTimingCalibrationStore.profiles[calibrationKey]
        for item in items {
            if let timing = readAlongTimingByItemID[item.id],
                timing.durationSeconds.isFinite,
                timing.durationSeconds > 0,
                let adjustment = Self.rsvpReadAlongTimingAdjustment(for: timing, item: item)
            {
                timedPlan.applyFixedDuration(adjustment.visualDurationSeconds, toPlaybackItemID: item.id)
            } else if let scale = profile?.durationScaleEMA,
                scale.isFinite,
                scale > 0,
                let plannedDuration = timedPlan.durationSeconds(forPlaybackItemID: item.id),
                plannedDuration > 0
            {
                timedPlan.applyFixedDuration(plannedDuration * scale, toPlaybackItemID: item.id)
            }
        }
        return timedPlan
    }

    private func recordRSVPTimingCalibration(_ timing: SpeechPlaybackItemTiming) {
        guard let item = readAlongItemsByID[timing.itemID] else { return }
        let basePlan = RSVPReadingPlanBuilder(settings: rsvpReadingSettings)
            .plan(from: readAlongPlaybackItems, title: "Narration")
        guard let plannedDuration = basePlan.durationSeconds(forPlaybackItemID: item.id),
            plannedDuration > 0
        else { return }
        let tokenCount = RSVPReadingPlanBuilder.tokenCount(in: item.text)
        guard let adjustment = Self.rsvpReadAlongTimingAdjustment(for: timing, item: item) else { return }
        let key = rsvpTimingCalibrationKey()
        rsvpTimingCalibrationStore.record(
            key: key,
            tokenCount: tokenCount,
            plannedDurationSeconds: plannedDuration,
            observedDurationSeconds: adjustment.visualDurationSeconds
        )
        saveRSVPTimingCalibrationStore(rsvpTimingCalibrationStore)
    }

    private static func rsvpReadAlongTimingAdjustment(
        for timing: SpeechPlaybackItemTiming,
        item: SpeechPlaybackItem
    ) -> RSVPReadAlongTimingAdjustment? {
        RSVPReadAlongTimingPolicy.default.adjustment(
            observedDurationSeconds: timing.durationSeconds,
            tokenCount: RSVPReadingPlanBuilder.tokenCount(in: item.text)
        )
    }

    private func registerConfiguredHotKeys(reportStatus: Bool) {
        for hotKey in registeredHotKeys.values {
            hotKey.unregister()
        }
        registeredHotKeys.removeAll()
        var states: [StudyShortcutAction: ShortcutRegistrationState] = [:]
        if reportStatus {
            lastError = nil
            statusMessage = "Keyboard shortcuts updated."
        }

        for action in StudyShortcutAction.allCases {
            let shortcut = shortcut(for: action)
            guard shortcut.isEnabled else {
                states[action] = .disabled
                continue
            }
            guard shortcut.isUsableGlobalShortcut else {
                let message = "\(action.title) needs Command, Option, or Control in its shortcut."
                states[action] = .invalid(message)
                lastError = message
                statusMessage = "Shortcut needs a modifier."
                continue
            }

            let hotKey = GlobalHotKey(
                id: action.hotKeyID,
                keyCode: shortcut.keyCode,
                modifiers: shortcut.effectiveModifiers
            ) { [weak self] in
                Task { @MainActor in
                    self?.run(action.studyAction)
                }
            }

            do {
                try hotKey.register()
                registeredHotKeys[action] = hotKey
                states[action] = .registered
                if reportStatus {
                    lastError = nil
                    statusMessage = "Keyboard shortcuts updated."
                }
            } catch {
                let message = error.localizedDescription
                states[action] = .failed(message)
                lastError = message
                statusMessage = "Could not register \(action.title) shortcut."
            }
        }
        shortcutRegistrationStates = states
    }

    private func saveShortcut(_ shortcut: HotKeyDefinition, for action: StudyShortcutAction) {
        guard let data = try? JSONEncoder().encode(shortcut) else { return }
        userDefaults.set(data, forKey: Self.shortcutDefaultsKey(for: action))
    }

    private func saveSpeechSettings(_ settings: SpeechSettings) {
        guard let data = try? JSONEncoder().encode(settings) else { return }
        userDefaults.set(data, forKey: Self.speechSettingsDefaultsKey)
    }

    private func saveRSVPReadingSettings(_ settings: RSVPReadingSettings) {
        guard let data = try? JSONEncoder().encode(settings) else { return }
        userDefaults.set(data, forKey: Self.rsvpReadingSettingsDefaultsKey)
    }

    private func saveRSVPTimingCalibrationStore(_ store: RSVPTimingCalibrationStore) {
        guard let data = try? JSONEncoder().encode(store) else { return }
        userDefaults.set(data, forKey: Self.rsvpTimingCalibrationDefaultsKey)
    }

    private static func loadShortcuts(from userDefaults: UserDefaults) -> [StudyShortcutAction: HotKeyDefinition] {
        var loaded: [StudyShortcutAction: HotKeyDefinition] = [:]
        for action in StudyShortcutAction.allCases {
            if let data = userDefaults.data(forKey: shortcutDefaultsKey(for: action)),
                let shortcut = try? JSONDecoder().decode(HotKeyDefinition.self, from: data)
            {
                loaded[action] = shortcut
            } else {
                var shortcut = action.defaultShortcut
                if action == .submit, userDefaults.bool(forKey: "submitHotKeyEnabled") {
                    shortcut.isEnabled = true
                }
                loaded[action] = shortcut
            }
        }
        return loaded
    }

    private static func loadSpeechSettings(from userDefaults: UserDefaults) -> (settings: SpeechSettings, requiresSave: Bool) {
        guard let data = userDefaults.data(forKey: speechSettingsDefaultsKey),
            let settings = try? JSONDecoder().decode(SpeechSettings.self, from: data)
        else {
            return (.firstLaunch, false)
        }
        let clamped = settings.clamped
        let encoded = try? JSONEncoder().encode(clamped)
        return (clamped, encoded != data)
    }

    private static func loadRSVPReadingSettings(from userDefaults: UserDefaults) -> (settings: RSVPReadingSettings, requiresSave: Bool) {
        guard let data = userDefaults.data(forKey: rsvpReadingSettingsDefaultsKey),
            let settings = try? JSONDecoder().decode(RSVPReadingSettings.self, from: data)
        else {
            return (.default, false)
        }
        var clamped = settings.clamped
        var requiresSave = (try? JSONEncoder().encode(clamped)) != data
        if !userDefaults.bool(forKey: rsvpReadingNarrationPreferenceDefaultsKey),
            !clamped.showsDuringNarration
        {
            clamped.showsDuringNarration = true
            requiresSave = true
        }
        return (clamped, requiresSave)
    }

    private static func loadRSVPTimingCalibrationStore(from userDefaults: UserDefaults) -> RSVPTimingCalibrationStore {
        guard let data = userDefaults.data(forKey: rsvpTimingCalibrationDefaultsKey),
            let store = try? JSONDecoder().decode(RSVPTimingCalibrationStore.self, from: data)
        else {
            return RSVPTimingCalibrationStore()
        }
        return store
    }

    private func rsvpTimingCalibrationKey() -> String {
        let rate = String(format: "%.2f", speechSettings.rateMultiplier)
        let voice: String
        if speechSettings.engineID == .pocket {
            voice = "alba"
        } else if speechSettings.engineID == .apple {
            voice = speechSettings.voiceIdentifier ?? "system"
        } else if speechSettings.qwenUseReferenceVoice {
            voice = "reference:\(speechSettings.effectiveQwenReferenceVoice.voiceName)"
        } else {
            voice = "speaker:\(speechSettings.qwenSpeaker)"
        }
        return [
            speechSettings.engineID.rawValue,
            rate,
            voice,
        ].joined(separator: "|")
    }

    private static func shortcutDefaultsKey(for action: StudyShortcutAction) -> String {
        "keyboardShortcut.\(action.rawValue)"
    }

    private static let speechSettingsDefaultsKey = "speech.settings"
    private static let rsvpReadingSettingsDefaultsKey = "rsvpReading.settings"
    private static let rsvpReadingNarrationPreferenceDefaultsKey = "rsvpReading.showsDuringNarrationPreferenceSet"
    private static let rsvpTimingCalibrationDefaultsKey = "rsvpReading.timingCalibration"

    private static func initialQwenRuntimeReport(runtime: QwenRuntimeManager) -> QwenRuntimeReport {
        QwenRuntimeReport(
            runtimeRoot: runtime.rootURL.path,
            logsDirectory: runtime.logURL.path,
            architecture: "unknown",
            uvAvailable: false,
            pythonEnvironmentAvailable: false,
            mlxAudioAvailable: false,
            helperAvailable: false,
            installedModelIDs: []
        )
    }
}

private struct RSVPTimingCalibrationStore: Codable, Equatable {
    var profiles: [String: RSVPTimingCalibrationProfile] = [:]

    mutating func record(
        key: String,
        tokenCount: Int,
        plannedDurationSeconds: TimeInterval,
        observedDurationSeconds: TimeInterval
    ) {
        guard plannedDurationSeconds.isFinite,
            plannedDurationSeconds > 0,
            observedDurationSeconds.isFinite,
            observedDurationSeconds > 0
        else {
            return
        }
        var profile = profiles[key] ?? RSVPTimingCalibrationProfile()
        profile.record(
            tokenCount: tokenCount,
            plannedDurationSeconds: plannedDurationSeconds,
            observedDurationSeconds: observedDurationSeconds
        )
        profiles[key] = profile
    }
}

private struct RSVPTimingCalibrationProfile: Codable, Equatable {
    var sampleCount = 0
    var tokenCount = 0
    var observedSeconds: TimeInterval = 0
    var durationScaleEMA: Double = 1

    mutating func record(
        tokenCount: Int,
        plannedDurationSeconds: TimeInterval,
        observedDurationSeconds: TimeInterval
    ) {
        let scale = observedDurationSeconds / plannedDurationSeconds
        guard scale.isFinite, scale > 0 else { return }
        durationScaleEMA =
            sampleCount == 0
            ? scale
            : (durationScaleEMA * 0.8) + (scale * 0.2)
        sampleCount += 1
        self.tokenCount += max(0, tokenCount)
        observedSeconds += observedDurationSeconds
    }
}

extension RSVPReadingPlan {
    fileprivate func durationSeconds(forPlaybackItemID playbackItemID: String) -> TimeInterval? {
        let matching = frames.filter { $0.playbackItemID == playbackItemID }
        guard !matching.isEmpty else { return nil }
        return matching.reduce(0) { $0 + $1.durationSeconds }
    }

    fileprivate mutating func applyFixedDuration(_ durationSeconds: TimeInterval, toPlaybackItemID playbackItemID: String) {
        guard durationSeconds.isFinite, durationSeconds > 0 else { return }
        let indices = frames.indices.filter { frames[$0].playbackItemID == playbackItemID }
        guard !indices.isEmpty else { return }
        let currentTotal = indices.reduce(0) { $0 + frames[$1].durationSeconds }
        guard currentTotal.isFinite, currentTotal > 0 else { return }
        for index in indices {
            let share = frames[index].durationSeconds / currentTotal
            frames[index].durationSeconds = durationSeconds * share
            frames[index].isDurationFixed = true
        }
    }
}

private struct QwenWarmupKey: Equatable, Sendable {
    var lane: QwenModelLane
    var speaker: String
    var rateMultiplier: Double
    var qwenDeEsserStrengthDecibels: Double
    var useReferenceVoice: Bool
    var referenceAudioPath: String?
    var referenceText: String?
    var usesQuestionPromptAudioLibrary: Bool

    init?(settings: SpeechSettings) {
        guard let lane = settings.engineID.qwenLane else { return nil }
        let voice = settings.effectiveQwenReferenceVoice
        self.lane = lane
        self.speaker =
            settings.qwenUseReferenceVoice
            ? voice.voiceName
            : (settings.qwenSpeaker.isEmpty ? lane.defaultSpeaker : settings.qwenSpeaker)
        self.rateMultiplier = settings.rateMultiplier
        self.qwenDeEsserStrengthDecibels = settings.qwenDeEsserStrengthDecibels
        self.useReferenceVoice = settings.qwenUseReferenceVoice
        self.referenceAudioPath = settings.qwenUseReferenceVoice ? voice.audioPath : nil
        self.referenceText = settings.qwenUseReferenceVoice ? voice.transcript : nil
        self.usesQuestionPromptAudioLibrary = settings.usesQuestionPromptAudioLibrary
    }
}

extension StudyAction {
    fileprivate var interruptsQwenWarmup: Bool {
        switch self {
        case .readText, .readQuestion, .readExplanation, .nextQuestionAndRead, .stopSpeech:
            return true
        case .submit:
            return false
        }
    }

    fileprivate var playbackVisualizationContext: SpeechPlaybackVisualizationContext {
        switch self {
        case .readQuestion:
            return .question
        case .readExplanation:
            return .explanation
        case .nextQuestionAndRead:
            return .question
        case .readText, .submit, .stopSpeech:
            return .neutral
        }
    }
}
