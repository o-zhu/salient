import AppKit
import QuartzCore
import SalientCore
import SwiftUI

struct RSVPReaderPanelConfiguration {
    static let styleMask: NSWindow.StyleMask = [.borderless, .fullSizeContentView, .nonactivatingPanel]
    static let collectionBehavior: NSWindow.CollectionBehavior = [.canJoinAllSpaces, .transient, .ignoresCycle]
    static let level: NSWindow.Level = .floating
    static let ordersFrontWhenPanelAlreadyExists = true
    static let panelSize = NSSize(width: 590, height: 238)
    static let wordDisplayHeight: CGFloat = 102
    static let fixationGuideVerticalOutset: CGFloat = 12
}

struct RSVPReaderPlaybackTiming {
    static let minimumFrameDelaySeconds: TimeInterval = 0.04
    static let readAlongInitialAdvanceLeadSeconds: TimeInterval = 0.075

    static func displayDelay(
        for frame: RSVPReadingFrame?,
        planWordsPerMinute: Int,
        settings: RSVPReadingSettings,
        initialAdvanceLeadSeconds: TimeInterval = 0
    ) -> TimeInterval {
        guard let frame else { return 0.1 }
        let baseDelay: TimeInterval
        if frame.isDurationFixed {
            baseDelay = frame.durationSeconds
        } else {
            let plannedWPM = max(1, planWordsPerMinute)
            let currentWPM = max(1, settings.wordsPerMinute)
            baseDelay = frame.durationSeconds * Double(plannedWPM) / Double(currentWPM)
        }
        return max(minimumFrameDelaySeconds, baseDelay - max(0, initialAdvanceLeadSeconds))
    }
}

struct RSVPWordPresentation: Equatable {
    var prefix: String
    var pivot: String
    var suffix: String
    var isPivotHighlighted: Bool

    init(word: String, orpIndex: Int, isORPEnabled: Bool) {
        guard !word.isEmpty else {
            prefix = ""
            pivot = ""
            suffix = ""
            isPivotHighlighted = false
            return
        }
        guard isORPEnabled else {
            prefix = word
            pivot = ""
            suffix = ""
            isPivotHighlighted = false
            return
        }

        let characters = Array(word)
        let pivotIndex = min(max(orpIndex, 0), characters.count - 1)
        prefix = pivotIndex == 0 ? "" : String(characters[..<pivotIndex])
        pivot = String(characters[pivotIndex])
        let suffixStart = characters.index(after: pivotIndex)
        suffix = suffixStart < characters.endIndex ? String(characters[suffixStart...]) : ""
        isPivotHighlighted = true
    }

    var displayText: String {
        prefix + pivot + suffix
    }
}

struct RSVPWordDisplayStyle {
    struct WordLayout {
        var fontSize: CGFloat
        var textWidth: CGFloat
        var pivotCenterX: CGFloat
        var horizontalOffset: CGFloat
    }

    static let preferredFontName = "Helvetica"
    static let baseFontSize: CGFloat = 48
    static let minimumFontSize: CGFloat = 22
    static let pivotColorRed: CGFloat = 1.0
    static let pivotColorGreen: CGFloat = 0.64
    static let pivotColorBlue: CGFloat = 0.08
    static let pivotColor = Color(
        red: pivotColorRed,
        green: pivotColorGreen,
        blue: pivotColorBlue
    )
    static let pivotNSColor = NSColor(
        calibratedRed: pivotColorRed,
        green: pivotColorGreen,
        blue: pivotColorBlue,
        alpha: 1
    )

    static func displayFont(size: CGFloat) -> Font {
        .custom(preferredFontName, size: size)
    }

    static func highlightedWord(for presentation: RSVPWordPresentation) -> AttributedString {
        word(for: presentation, pivotColor: pivotColor)
    }

    private static func word(
        for presentation: RSVPWordPresentation,
        pivotColor: Color
    ) -> AttributedString {
        var word = AttributedString(presentation.displayText)
        guard presentation.isPivotHighlighted,
            let start = word.characters.index(
                word.startIndex,
                offsetBy: presentation.prefix.count,
                limitedBy: word.endIndex
            ),
            start < word.endIndex
        else {
            return word
        }
        let end = word.characters.index(after: start)
        word[start..<end].foregroundColor = pivotColor
        return word
    }

    static func wordLayout(
        for presentation: RSVPWordPresentation,
        availableWidth: CGFloat
    ) -> WordLayout {
        let baseMeasurement = measurement(for: presentation, fontSize: baseFontSize)
        let maxExtentFromPivot = max(
            baseMeasurement.pivotCenterX,
            baseMeasurement.textWidth - baseMeasurement.pivotCenterX,
            1
        )
        let fittingScale = max(0.01, availableWidth) / (2 * maxExtentFromPivot)
        let fontSize = min(baseFontSize, max(minimumFontSize, baseFontSize * fittingScale))
        let measurement = measurement(for: presentation, fontSize: fontSize)
        return WordLayout(
            fontSize: fontSize,
            textWidth: measurement.textWidth,
            pivotCenterX: measurement.pivotCenterX,
            horizontalOffset: (measurement.textWidth / 2) - measurement.pivotCenterX
        )
    }

    private static func measurement(
        for presentation: RSVPWordPresentation,
        fontSize: CGFloat
    ) -> (textWidth: CGFloat, pivotCenterX: CGFloat) {
        let textWidth = measuredWidth(of: presentation.displayText, fontSize: fontSize)
        guard presentation.isPivotHighlighted else {
            return (textWidth, textWidth / 2)
        }
        let prefixWidth = measuredWidth(of: presentation.prefix, fontSize: fontSize)
        let prefixAndPivotWidth = measuredWidth(
            of: presentation.prefix + presentation.pivot,
            fontSize: fontSize
        )
        return (
            textWidth,
            prefixWidth + max(0, prefixAndPivotWidth - prefixWidth) / 2
        )
    }

    private static func measuredWidth(of text: String, fontSize: CGFloat) -> CGFloat {
        guard !text.isEmpty else { return 0 }
        let font =
            NSFont(name: preferredFontName, size: fontSize)
            ?? NSFont.systemFont(ofSize: fontSize)
        return ceil((text as NSString).size(withAttributes: [.font: font]).width)
    }
}

@MainActor
final class RSVPReaderViewModel: ObservableObject {
    @Published var plan = RSVPReadingPlan(title: "", frames: [])
    @Published var settings = RSVPReadingSettings.default
    @Published var currentIndex = 0 {
        didSet {
            guard oldValue != currentIndex else { return }
            onDisplayedFrameChange(currentIndex)
        }
    }
    @Published var isPlaying = false
    @Published var followsNarration = false

    private var playbackTask: Task<Void, Never>?
    private var pendingInitialAdvanceLeadSeconds: TimeInterval = 0
    private var onClose: @MainActor () -> Void = {}
    private var onWordsPerMinuteChange: @MainActor (Int) -> Void = { _ in }
    private var onDisplayedFrameChange: @MainActor (Int) -> Void = { _ in }

    var currentFrame: RSVPReadingFrame? {
        guard plan.frames.indices.contains(currentIndex) else { return nil }
        return plan.frames[currentIndex]
    }

    var progressLabel: String {
        guard !plan.frames.isEmpty else { return "0 / 0" }
        return "\(currentIndex + 1) / \(plan.frames.count)"
    }

    func setActions(
        onClose: @escaping @MainActor () -> Void,
        onWordsPerMinuteChange: @escaping @MainActor (Int) -> Void,
        onDisplayedFrameChange: @escaping @MainActor (Int) -> Void
    ) {
        self.onClose = onClose
        self.onWordsPerMinuteChange = onWordsPerMinuteChange
        self.onDisplayedFrameChange = onDisplayedFrameChange
    }

    func start(
        plan: RSVPReadingPlan,
        settings: RSVPReadingSettings,
        frameIndex: Int,
        playImmediately: Bool,
        initialAdvanceLeadSeconds: TimeInterval = 0
    ) {
        pause()
        self.plan = plan
        self.settings = settings.clamped
        currentIndex = clampedIndex(frameIndex)
        if playImmediately {
            play(initialAdvanceLeadSeconds: initialAdvanceLeadSeconds)
        }
    }

    func updateSettings(_ settings: RSVPReadingSettings) {
        self.settings = settings.clamped
        if isPlaying {
            play()
        }
    }

    func setFollowsNarration(_ followsNarration: Bool) {
        self.followsNarration = followsNarration
        if followsNarration {
            pause()
        }
    }

    func togglePlayback() {
        isPlaying ? pause() : play()
    }

    func play(initialAdvanceLeadSeconds: TimeInterval = 0) {
        guard !plan.frames.isEmpty else { return }
        pendingInitialAdvanceLeadSeconds = max(0, initialAdvanceLeadSeconds)
        playbackTask?.cancel()
        isPlaying = true
        playbackTask = Task { @MainActor [weak self] in
            while let self, !Task.isCancelled, self.isPlaying {
                let initialAdvanceLeadSeconds = self.pendingInitialAdvanceLeadSeconds
                self.pendingInitialAdvanceLeadSeconds = 0
                let delay = self.currentDelay(initialAdvanceLeadSeconds: initialAdvanceLeadSeconds)
                try? await Task.sleep(nanoseconds: UInt64(delay * 1_000_000_000))
                guard !Task.isCancelled, self.isPlaying else { return }
                guard self.currentIndex < self.plan.frames.count - 1 else {
                    self.isPlaying = false
                    self.playbackTask = nil
                    return
                }
                self.currentIndex += 1
            }
        }
    }

    func pause() {
        playbackTask?.cancel()
        playbackTask = nil
        pendingInitialAdvanceLeadSeconds = 0
        isPlaying = false
    }

    func rewind() {
        jump(to: currentIndex - 10, play: isPlaying)
    }

    func advance() {
        jump(to: currentIndex + 10, play: isPlaying)
    }

    func restart() {
        jump(to: 0, play: true)
    }

    func jump(
        to frameIndex: Int,
        play shouldPlay: Bool,
        initialAdvanceLeadSeconds: TimeInterval = 0
    ) {
        currentIndex = clampedIndex(frameIndex)
        if shouldPlay {
            play(initialAdvanceLeadSeconds: initialAdvanceLeadSeconds)
        }
    }

    func setWordsPerMinute(_ value: Double) {
        let rounded = Int((value / 10).rounded() * 10)
        var next = settings
        next.wordsPerMinute = rounded
        settings = next.clamped
        onWordsPerMinuteChange(settings.wordsPerMinute)
        if isPlaying {
            play()
        }
    }

    func close() {
        clear()
        onClose()
    }

    func clear() {
        pause()
        plan = RSVPReadingPlan(title: "", frames: [])
        currentIndex = 0
    }

    var currentDelay: TimeInterval {
        currentDelay(initialAdvanceLeadSeconds: 0)
    }

    private func currentDelay(initialAdvanceLeadSeconds: TimeInterval) -> TimeInterval {
        RSVPReaderPlaybackTiming.displayDelay(
            for: currentFrame,
            planWordsPerMinute: plan.wordsPerMinute,
            settings: settings,
            initialAdvanceLeadSeconds: initialAdvanceLeadSeconds
        )
    }

    private func clampedIndex(_ index: Int) -> Int {
        guard !plan.frames.isEmpty else { return 0 }
        return min(max(index, 0), plan.frames.count - 1)
    }
}

@MainActor
final class RSVPReaderPanelController: ObservableObject {
    private let viewModel = RSVPReaderViewModel()
    private var panel: NSPanel?
    private var lastPlan: RSVPReadingPlan?
    private var lastSyncRevision = -1
    private var lastPlaybackRequest = false
    private var isPositionedForNarration = false

    func updateActions(
        onClose: @escaping @MainActor () -> Void,
        onWordsPerMinuteChange: @escaping @MainActor (Int) -> Void,
        onDisplayedFrameChange: @escaping @MainActor (Int) -> Void
    ) {
        viewModel.setActions(
            onClose: onClose,
            onWordsPerMinuteChange: onWordsPerMinuteChange,
            onDisplayedFrameChange: onDisplayedFrameChange
        )
    }

    func setVisible(
        _ visible: Bool,
        plan: RSVPReadingPlan?,
        settings: RSVPReadingSettings,
        requestedFrameIndex: Int,
        syncRevision: Int,
        playImmediately: Bool,
        followsNarration: Bool
    ) {
        guard visible, let plan else {
            hide()
            lastPlan = nil
            lastSyncRevision = -1
            lastPlaybackRequest = false
            viewModel.clear()
            return
        }

        show(followsNarration: followsNarration)
        viewModel.setFollowsNarration(followsNarration)
        viewModel.updateSettings(settings)
        let planChanged = lastPlan != plan
        let syncChanged = lastSyncRevision != syncRevision
        let playbackRequestChanged = lastPlaybackRequest != playImmediately
        let syncInitialAdvanceLeadSeconds = Self.readAlongInitialAdvanceLeadSeconds(
            followsNarration: followsNarration,
            playImmediately: playImmediately
        )
        if planChanged {
            viewModel.start(
                plan: plan,
                settings: settings,
                frameIndex: requestedFrameIndex,
                playImmediately: playImmediately,
                initialAdvanceLeadSeconds: syncChanged ? syncInitialAdvanceLeadSeconds : 0
            )
            lastPlan = plan
        }
        if syncChanged {
            viewModel.jump(
                to: requestedFrameIndex,
                play: playImmediately,
                initialAdvanceLeadSeconds: syncInitialAdvanceLeadSeconds
            )
            lastSyncRevision = syncRevision
        } else if playbackRequestChanged {
            if playImmediately {
                viewModel.play()
            } else {
                viewModel.pause()
            }
        }
        lastPlaybackRequest = playImmediately
        if isPositionedForNarration != followsNarration {
            isPositionedForNarration = followsNarration
            positionPanel(followsNarration: followsNarration)
        }
    }

    /// Applies the high-frequency audio-clock update without reconfiguring or
    /// reordering the panel. Narration can advance several words between main
    /// actor turns, so this deliberately jumps straight to the requested frame.
    func synchronizePlaybackFrame(
        requestedFrameIndex: Int,
        syncRevision: Int,
        playImmediately: Bool,
        followsNarration: Bool
    ) {
        guard panel != nil, lastPlan != nil else { return }
        let syncChanged = lastSyncRevision != syncRevision
        let playbackRequestChanged = lastPlaybackRequest != playImmediately
        if syncChanged {
            viewModel.jump(
                to: requestedFrameIndex,
                play: playImmediately,
                initialAdvanceLeadSeconds: Self.readAlongInitialAdvanceLeadSeconds(
                    followsNarration: followsNarration,
                    playImmediately: playImmediately
                )
            )
            lastSyncRevision = syncRevision
        } else if playbackRequestChanged {
            if playImmediately {
                viewModel.play()
            } else {
                viewModel.pause()
            }
        }
        lastPlaybackRequest = playImmediately
    }

    static func readAlongInitialAdvanceLeadSeconds(
        followsNarration: Bool,
        playImmediately: Bool
    ) -> TimeInterval {
        guard followsNarration, playImmediately else { return 0 }
        return RSVPReaderPlaybackTiming.readAlongInitialAdvanceLeadSeconds
    }

    func updateSettings(_ settings: RSVPReadingSettings) {
        viewModel.updateSettings(settings)
    }

    func jump(to frameIndex: Int, play: Bool) {
        viewModel.jump(to: frameIndex, play: play)
    }

    private func show(followsNarration: Bool) {
        if let panel {
            positionPanel(followsNarration: followsNarration)
            if RSVPReaderPanelConfiguration.ordersFrontWhenPanelAlreadyExists {
                panel.orderFrontRegardless()
            }
            return
        }

        let panel = RSVPReaderPanel(
            contentRect: NSRect(origin: .zero, size: RSVPReaderPanelConfiguration.panelSize),
            styleMask: RSVPReaderPanelConfiguration.styleMask,
            backing: .buffered,
            defer: false
        )
        panel.isOpaque = false
        panel.title = "Visual Reader"
        panel.setAccessibilityLabel("Salient Visual Reader")
        panel.backgroundColor = .clear
        panel.hasShadow = false
        panel.appearance = NSAppearance(named: .darkAqua)
        panel.level = RSVPReaderPanelConfiguration.level
        panel.isMovableByWindowBackground = true
        panel.hidesOnDeactivate = false
        panel.collectionBehavior = RSVPReaderPanelConfiguration.collectionBehavior
        panel.contentView = NSHostingView(rootView: RSVPReaderPanelView(model: viewModel))
        panel.alphaValue = 0
        self.panel = panel
        isPositionedForNarration = followsNarration
        positionPanel(followsNarration: followsNarration)
        panel.orderFrontRegardless()

        NSAnimationContext.runAnimationGroup { context in
            context.duration = NSWorkspace.shared.accessibilityDisplayShouldReduceMotion ? 0 : 0.16
            context.timingFunction = CAMediaTimingFunction(name: .easeOut)
            panel.animator().alphaValue = 1
        }
    }

    private func hide() {
        guard let panel else { return }
        self.panel = nil
        NSAnimationContext.runAnimationGroup { context in
            context.duration = NSWorkspace.shared.accessibilityDisplayShouldReduceMotion ? 0 : 0.16
            context.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
            panel.animator().alphaValue = 0
        } completionHandler: {
            Task { @MainActor in
                panel.orderOut(nil)
            }
        }
    }

    private func positionPanel(followsNarration: Bool) {
        guard let panel else { return }
        let screen = NSApp.keyWindow?.screen ?? NSApp.mainWindow?.screen ?? NSScreen.main
        guard let screen else { return }
        let visibleFrame = screen.visibleFrame
        let frame = panel.frame
        let x = visibleFrame.midX - frame.width / 2
        let y =
            followsNarration
            ? visibleFrame.minY + 134
            : visibleFrame.minY + max(110, visibleFrame.height * 0.28)
        panel.setFrameOrigin(NSPoint(x: x, y: y))
    }
}

private final class RSVPReaderPanel: NSPanel {
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { false }
}

struct RSVPReaderPresenter: View {
    @EnvironmentObject private var model: AppModel

    var body: some View {
        RSVPReaderStatePresenter(
            state: model.state.rsvpReader,
            settings: model.rsvpReadingSettings,
            onClose: { model.closeRSVPReader() },
            onWordsPerMinuteChange: { model.setRSVPWordsPerMinute($0) },
            onDisplayedFrameChange: { model.rsvpReaderDisplayedFrameDidChange($0) }
        )
    }
}

private struct RSVPReaderStatePresenter: View {
    @Bindable var state: RSVPReaderFeatureModel
    let settings: RSVPReadingSettings
    let onClose: @MainActor () -> Void
    let onWordsPerMinuteChange: @MainActor (Int) -> Void
    let onDisplayedFrameChange: @MainActor (Int) -> Void
    @StateObject private var controller = RSVPReaderPanelController()

    var body: some View {
        Color.clear
            .frame(width: 0, height: 0)
            .onAppear {
                controller.updateActions(
                    onClose: onClose,
                    onWordsPerMinuteChange: onWordsPerMinuteChange,
                    onDisplayedFrameChange: onDisplayedFrameChange
                )
                syncPanel()
            }
            .onChange(of: state.isVisible) { _, _ in
                syncPanel()
            }
            .onChange(of: state.plan) { _, _ in
                syncPanel()
            }
            .onChange(of: settings) { _, settings in
                controller.updateSettings(settings)
                syncPanel()
            }
            .onChange(of: state.syncRevision) { _, _ in
                syncPlaybackFrame()
            }
            .onChange(of: state.isPlaybackRequested) { _, _ in
                syncPlaybackFrame()
            }
            .onChange(of: state.followsNarration) { _, _ in
                syncPanel()
            }
    }

    private func syncPanel() {
        controller.setVisible(
            state.isVisible,
            plan: state.plan,
            settings: settings,
            requestedFrameIndex: state.requestedFrameIndex,
            syncRevision: state.syncRevision,
            playImmediately: state.isPlaybackRequested,
            followsNarration: state.followsNarration
        )
    }

    private func syncPlaybackFrame() {
        controller.synchronizePlaybackFrame(
            requestedFrameIndex: state.requestedFrameIndex,
            syncRevision: state.syncRevision,
            playImmediately: state.isPlaybackRequested,
            followsNarration: state.followsNarration
        )
    }
}

private struct RSVPReaderPanelView: View {
    @ObservedObject var model: RSVPReaderViewModel

    var body: some View {
        ZStack {
            RSVPReaderGlassBackground()
            VStack(spacing: 13) {
                header
                RSVPWordDisplay(frame: model.currentFrame, settings: model.settings)
                    .frame(height: RSVPReaderPanelConfiguration.wordDisplayHeight)
                    .padding(.horizontal, 10)
                    .background(
                        Color.black.opacity(0.16),
                        in: RoundedRectangle(
                            cornerRadius: SalientFloatingOverlayDesign.innerCornerRadius,
                            style: .continuous
                        )
                    )
                    .overlay {
                        RoundedRectangle(
                            cornerRadius: SalientFloatingOverlayDesign.innerCornerRadius,
                            style: .continuous
                        )
                        .stroke(Color.white.opacity(0.09), lineWidth: 1)
                    }
                progress
                controls
            }
            .padding(.horizontal, 18)
            .padding(.vertical, 14)
        }
        .frame(
            width: RSVPReaderPanelConfiguration.panelSize.width,
            height: RSVPReaderPanelConfiguration.panelSize.height
        )
        .preferredColorScheme(.dark)
    }

    private var header: some View {
        HStack(spacing: 10) {
            Label(model.currentFrame?.sectionLabel ?? "Visual Reader", systemImage: "textformat.size")
                .font(.caption.weight(.bold))
                .foregroundStyle(RSVPWordDisplayStyle.pivotColor)
                .lineLimit(1)
            Text(model.plan.title)
                .font(.callout.weight(.semibold))
                .foregroundStyle(.primary)
                .lineLimit(1)
                .truncationMode(.middle)
            Spacer(minLength: 10)
            if model.settings.showsComprehensionWarning {
                Image(systemName: "exclamationmark.triangle.fill")
                    .foregroundStyle(.yellow)
                    .help("High RSVP speeds can reduce comprehension and increase fatigue.")
            }
            Text(model.followsNarration ? "Following audio" : "\(model.settings.wordsPerMinute) WPM")
                .font(.system(.callout, design: .monospaced).weight(.semibold))
                .foregroundStyle(.primary)
                .padding(.horizontal, 8)
                .padding(.vertical, 4)
                .background(Color.black.opacity(0.14), in: Capsule())
                .overlay { Capsule().stroke(Color.white.opacity(0.10), lineWidth: 1) }
        }
    }

    private var progress: some View {
        HStack(spacing: 10) {
            ProgressView(
                value: Double(model.currentIndex + 1),
                total: Double(max(model.plan.frames.count, 1))
            )
            .tint(RSVPWordDisplayStyle.pivotColor)
            Text(model.progressLabel)
                .font(.system(.caption, design: .monospaced))
                .foregroundStyle(.secondary)
                .frame(width: 72, alignment: .trailing)
        }
    }

    private var controls: some View {
        HStack(spacing: 10) {
            Group {
                RSVPReaderIconButton(systemName: "arrow.counterclockwise", help: "Restart") {
                    model.restart()
                }
                RSVPReaderIconButton(systemName: "gobackward.10", help: "Back 10 words") {
                    model.rewind()
                }
                RSVPReaderIconButton(
                    systemName: model.isPlaying ? "pause.fill" : "play.fill",
                    help: model.isPlaying ? "Pause" : "Play",
                    isProminent: true
                ) {
                    model.togglePlayback()
                }
                RSVPReaderIconButton(systemName: "goforward.10", help: "Forward 10 words") {
                    model.advance()
                }

                Slider(
                    value: Binding(
                        get: { Double(model.settings.wordsPerMinute) },
                        set: { model.setWordsPerMinute($0) }
                    ),
                    in: Double(RSVPReadingSettings.minimumWordsPerMinute)...Double(RSVPReadingSettings.maximumWordsPerMinute),
                    step: 10
                )
                .controlSize(.small)
                .tint(RSVPWordDisplayStyle.pivotColor)
                .frame(width: 160)
                .help("Words per minute")

                Stepper(
                    "WPM",
                    value: Binding(
                        get: { model.settings.wordsPerMinute },
                        set: { model.setWordsPerMinute(Double($0)) }
                    ),
                    in: RSVPReadingSettings.minimumWordsPerMinute...RSVPReadingSettings.maximumWordsPerMinute,
                    step: 10
                )
                .labelsHidden()
                .frame(width: 48)
            }
            .disabled(model.followsNarration)

            Spacer(minLength: 0)

            RSVPReaderIconButton(systemName: "xmark", help: "Close") {
                model.close()
            }
        }
    }
}

struct RSVPWordDisplay: View {
    var frame: RSVPReadingFrame?
    var settings: RSVPReadingSettings
    var showsFixationGuides = true

    var body: some View {
        Group {
            if let presentation = fixedORPPresentation {
                fixedORPText(presentation)
            } else {
                plainText
            }
        }
        .accessibilityLabel(frame?.displayText ?? "")
    }

    private var fixedORPPresentation: RSVPWordPresentation? {
        let presentation = RSVPWordPresentation(
            word: frame?.displayText ?? "",
            orpIndex: frame?.orpIndex ?? 0,
            isORPEnabled: settings.isORPEnabled
        )
        guard presentation.isPivotHighlighted else {
            return nil
        }
        return presentation
    }

    private var plainText: some View {
        let presentation = RSVPWordPresentation(
            word: frame?.displayText ?? "",
            orpIndex: 0,
            isORPEnabled: false
        )
        return generatedWordText(presentation)
    }

    private func fixedORPText(_ presentation: RSVPWordPresentation) -> some View {
        generatedWordText(presentation)
    }

    private func generatedWordText(_ presentation: RSVPWordPresentation) -> some View {
        GeometryReader { proxy in
            let layout = RSVPWordDisplayStyle.wordLayout(
                for: presentation,
                availableWidth: max(1, proxy.size.width)
            )
            ZStack {
                if showsFixationGuides {
                    RSVPFixationGuides()
                }
                RSVPGeneratedWordText(presentation: presentation, layout: layout)
            }
        }
    }
}

private struct RSVPGeneratedWordText: NSViewRepresentable {
    var presentation: RSVPWordPresentation
    var layout: RSVPWordDisplayStyle.WordLayout

    func makeNSView(context: Context) -> RSVPGeneratedWordTextView {
        let view = RSVPGeneratedWordTextView()
        view.setAccessibilityElement(true)
        view.setAccessibilityRole(.staticText)
        view.presentation = presentation
        view.layout = layout
        view.setAccessibilityValue(presentation.prefix + presentation.pivot + presentation.suffix)
        return view
    }

    func updateNSView(_ nsView: RSVPGeneratedWordTextView, context: Context) {
        nsView.presentation = presentation
        nsView.layout = layout
        nsView.setAccessibilityValue(presentation.prefix + presentation.pivot + presentation.suffix)
    }
}

private final class RSVPGeneratedWordTextView: NSView {
    var presentation = RSVPWordPresentation(word: "", orpIndex: 0, isORPEnabled: false) {
        didSet { needsDisplay = true }
    }
    var layout = RSVPWordDisplayStyle.WordLayout(
        fontSize: RSVPWordDisplayStyle.baseFontSize,
        textWidth: 0,
        pivotCenterX: 0,
        horizontalOffset: 0
    ) {
        didSet { needsDisplay = true }
    }

    override var isFlipped: Bool { true }
    override var isOpaque: Bool { false }

    override func draw(_ dirtyRect: NSRect) {
        super.draw(dirtyRect)

        guard !presentation.displayText.isEmpty else { return }
        let font =
            NSFont(name: RSVPWordDisplayStyle.preferredFontName, size: layout.fontSize)
            ?? NSFont.systemFont(ofSize: layout.fontSize)
        let word = NSMutableAttributedString(
            string: presentation.displayText,
            attributes: [
                .font: font,
                .foregroundColor: NSColor(calibratedWhite: 0.94, alpha: 1),
                .kern: 0,
            ]
        )
        if presentation.isPivotHighlighted {
            let range = NSRange(
                location: presentation.prefix.utf16.count,
                length: presentation.pivot.utf16.count
            )
            if NSMaxRange(range) <= word.length {
                word.addAttribute(
                    .foregroundColor,
                    value: RSVPWordDisplayStyle.pivotNSColor,
                    range: range
                )
            }
        }

        let size = word.size()
        let origin = NSPoint(
            x: bounds.midX - size.width / 2 + layout.horizontalOffset,
            y: bounds.midY - size.height / 2
        )
        word.draw(at: origin)
    }
}

private struct RSVPFixationGuides: View {
    private let guideWidth: CGFloat = 3
    private let guideHeight: CGFloat = 14

    var body: some View {
        GeometryReader { proxy in
            ZStack {
                centerRule(height: proxy.size.height)
                    .position(x: proxy.size.width / 2, y: proxy.size.height / 2)
                guide
                    .position(
                        x: proxy.size.width / 2,
                        y: -RSVPReaderPanelConfiguration.fixationGuideVerticalOutset + guideHeight / 2
                    )
                guide
                    .position(
                        x: proxy.size.width / 2,
                        y: proxy.size.height
                            + RSVPReaderPanelConfiguration.fixationGuideVerticalOutset
                            - guideHeight / 2
                    )
            }
            .frame(width: proxy.size.width, height: proxy.size.height)
        }
        .accessibilityHidden(true)
    }

    private func centerRule(height: CGFloat) -> some View {
        Rectangle()
            .fill(Color.white.opacity(0.12))
            .frame(
                width: 1,
                height: height + RSVPReaderPanelConfiguration.fixationGuideVerticalOutset * 2
            )
    }

    private var guide: some View {
        RoundedRectangle(cornerRadius: 1.5, style: .continuous)
            .fill(RSVPWordDisplayStyle.pivotColor.opacity(0.92))
            .frame(width: guideWidth, height: guideHeight)
    }
}

private struct RSVPReaderIconButton: View {
    var systemName: String
    var help: String
    var isProminent = false
    var action: () -> Void

    var body: some View {
        Button(action: action) {
            Image(systemName: systemName)
                .font(.system(size: 14, weight: .semibold))
                .foregroundStyle(isProminent ? RSVPWordDisplayStyle.pivotColor : Color.primary)
                .frame(width: 28, height: 28)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help(help)
        .accessibilityLabel(help)
        .background(
            isProminent ? RSVPWordDisplayStyle.pivotColor.opacity(0.14) : Color.white.opacity(0.075),
            in: RoundedRectangle(cornerRadius: 8, style: .continuous)
        )
        .overlay {
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .stroke(
                    isProminent ? RSVPWordDisplayStyle.pivotColor.opacity(0.42) : Color.white.opacity(0.14),
                    lineWidth: 1
                )
        }
    }
}

private struct RSVPReaderGlassBackground: View {
    var body: some View {
        SalientFloatingOverlayChrome(
            appearance: .dark,
            shape: RoundedRectangle(
                cornerRadius: SalientFloatingOverlayDesign.cornerRadius,
                style: .continuous
            )
        )
    }
}
