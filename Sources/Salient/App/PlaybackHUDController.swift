import AppKit
import QuartzCore
import SalientCore
import SwiftUI

struct PlaybackHUDConfiguration {
    static let panelSize = NSSize(width: 380, height: 86)
    static let stageSize = CGSize(width: 164, height: 52)
    static let barWidth: CGFloat = 5.5
    static let barSpacing: CGFloat = 3.2
}

@MainActor
final class PlaybackHUDViewModel: ObservableObject {
    @Published var frame: SpeechPlaybackVisualizationFrame = .levelOnly(0)
    var level: Double { frame.level }
    @Published var mode: SpeechPlaybackVisualizationContext = .neutral
    @Published var isGenerating = false
    @Published var appearance: PlaybackHUDAppearance = .dark

    private var onStopPlayback: @MainActor () -> Void

    init(onStopPlayback: @escaping @MainActor () -> Void = {}) {
        self.onStopPlayback = onStopPlayback
    }

    func setStopPlaybackAction(_ action: @escaping @MainActor () -> Void) {
        onStopPlayback = action
    }

    func stopPlayback() {
        onStopPlayback()
    }
}

struct PlaybackHUDStopControlState: Equatable {
    private(set) var isPointerInside = false

    var opacity: Double {
        isPointerInside ? 1 : 0
    }

    var scale: CGFloat {
        isPointerInside ? 1 : 0.86
    }

    var allowsHitTesting: Bool {
        isPointerInside
    }

    mutating func setPointerInside(_ isInside: Bool) {
        isPointerInside = isInside
    }
}

@MainActor
final class PlaybackHUDController: ObservableObject {
    private let viewModel: PlaybackHUDViewModel
    private var panel: NSPanel?

    init(onStopPlayback: @escaping @MainActor () -> Void = {}) {
        self.viewModel = PlaybackHUDViewModel(onStopPlayback: onStopPlayback)
    }

    func updateStopPlaybackAction(_ action: @escaping @MainActor () -> Void) {
        viewModel.setStopPlaybackAction(action)
    }

    func setVisible(
        _ visible: Bool,
        level: Double,
        frame: SpeechPlaybackVisualizationFrame,
        mode: SpeechPlaybackVisualizationContext,
        isGenerating: Bool,
        appearance: PlaybackHUDAppearance
    ) {
        updateMode(mode)
        updateGenerating(isGenerating)
        updateAppearance(appearance)
        updateFrame(frame.level > 0 || !frame.barLevels.isEmpty ? frame : .levelOnly(level))
        visible ? show() : hide()
    }

    func updateLevel(_ level: Double) {
        let nextFrame = SpeechPlaybackVisualizationFrame.levelOnly(level)
        if viewModel.frame != nextFrame {
            viewModel.frame = nextFrame
        }
    }

    func updateFrame(_ frame: SpeechPlaybackVisualizationFrame) {
        if viewModel.frame != frame {
            viewModel.frame = frame
        }
    }

    func updateMode(_ mode: SpeechPlaybackVisualizationContext) {
        viewModel.mode = mode
    }

    func updateGenerating(_ isGenerating: Bool) {
        viewModel.isGenerating = isGenerating
    }

    func updateAppearance(_ appearance: PlaybackHUDAppearance) {
        viewModel.appearance = appearance
        panel?.appearance = NSAppearance(named: PlaybackHUDAppearanceDesign(appearance: appearance).panelAppearanceName)
    }

    private func show() {
        if panel != nil {
            positionPanel()
            return
        }

        let size = PlaybackHUDConfiguration.panelSize
        let panel = NSPanel(
            contentRect: NSRect(origin: .zero, size: size),
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = false
        panel.level = .floating
        panel.ignoresMouseEvents = false
        panel.acceptsMouseMovedEvents = true
        panel.appearance = NSAppearance(named: PlaybackHUDAppearanceDesign(appearance: viewModel.appearance).panelAppearanceName)
        panel.collectionBehavior = [.canJoinAllSpaces, .transient, .ignoresCycle]
        panel.contentView = NSHostingView(rootView: AudioPlaybackHUDView(model: viewModel))
        panel.alphaValue = 0
        self.panel = panel
        positionPanel()
        panel.orderFrontRegardless()

        NSAnimationContext.runAnimationGroup { context in
            context.duration = 0.16
            context.timingFunction = CAMediaTimingFunction(name: .easeOut)
            panel.animator().alphaValue = 1
        }
    }

    private func hide() {
        guard let panel else { return }
        self.panel = nil
        NSAnimationContext.runAnimationGroup { context in
            context.duration = 0.18
            context.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
            panel.animator().alphaValue = 0
        } completionHandler: {
            Task { @MainActor in
                panel.orderOut(nil)
            }
        }
    }

    private func positionPanel() {
        guard let panel else { return }
        let screen = NSApp.keyWindow?.screen ?? NSApp.mainWindow?.screen ?? NSScreen.main
        guard let screen else { return }
        let visibleFrame = screen.visibleFrame
        let frame = panel.frame
        let x = visibleFrame.midX - frame.width / 2
        let y = visibleFrame.minY + 44
        panel.setFrameOrigin(NSPoint(x: x, y: y))
    }
}

struct PlaybackHUDPresenter: View {
    @EnvironmentObject private var model: AppModel

    var body: some View {
        PlaybackHUDStatePresenter(
            state: model.state.playbackHUD,
            appearance: model.speechSettings.playbackHUDAppearance,
            onStopPlayback: { model.run(.stopSpeech) }
        )
    }
}

private struct PlaybackHUDStatePresenter: View {
    @Bindable var state: PlaybackHUDFeatureModel
    let appearance: PlaybackHUDAppearance
    let onStopPlayback: @MainActor () -> Void
    @StateObject private var controller = PlaybackHUDController()

    var body: some View {
        Color.clear
            .frame(width: 0, height: 0)
            .onAppear {
                controller.updateStopPlaybackAction(onStopPlayback)
                controller.setVisible(
                    state.isVisible,
                    level: state.level,
                    frame: state.frame,
                    mode: state.mode,
                    isGenerating: state.isGenerating,
                    appearance: appearance
                )
            }
            .onChange(of: state.isVisible) { _, isVisible in
                controller.setVisible(
                    isVisible,
                    level: state.level,
                    frame: state.frame,
                    mode: state.mode,
                    isGenerating: state.isGenerating,
                    appearance: appearance
                )
            }
            .onChange(of: state.frame) { _, frame in
                controller.updateFrame(frame)
            }
            .onChange(of: state.mode) { _, mode in
                controller.updateMode(mode)
            }
            .onChange(of: state.isGenerating) { _, isGenerating in
                controller.updateGenerating(isGenerating)
            }
            .onChange(of: appearance) { _, appearance in
                controller.updateAppearance(appearance)
            }
    }
}

struct AudioPlaybackHUDView: View {
    @ObservedObject var model: PlaybackHUDViewModel
    @State private var stopControlState = PlaybackHUDStopControlState()

    private let barBaselines: [CGFloat] = [
        18, 24, 28, 25, 20, 16, 14, 15, 18, 23, 29, 34, 38, 40, 39, 36,
    ]
    private var palette: PlaybackHUDPalette {
        PlaybackHUDPalette(appearance: model.appearance)
    }

    var body: some View {
        ZStack {
            HUDGlassSurface(appearance: model.appearance)

            HStack(spacing: 22) {
                modeGlyph("Q", isActive: model.mode == .question)

                ZStack {
                    RoundedRectangle(
                        cornerRadius: SalientFloatingOverlayDesign.innerCornerRadius,
                        style: .continuous
                    )
                    .fill(stageFillColor)
                    .overlay {
                        RoundedRectangle(
                            cornerRadius: SalientFloatingOverlayDesign.innerCornerRadius,
                            style: .continuous
                        )
                        .stroke(stageStrokeColor, lineWidth: 1)
                    }

                    if model.isGenerating {
                        GeneratingLabel(appearance: model.appearance)
                            .opacity(stopControlState.isPointerInside ? 0.20 : 1)
                            .transition(.opacity.combined(with: .scale(scale: 0.98)))
                    } else {
                        HStack(alignment: .center, spacing: PlaybackHUDConfiguration.barSpacing) {
                            ForEach(barBaselines.indices, id: \.self) { index in
                                Capsule()
                                    .fill(barFill(for: index))
                                    .frame(width: PlaybackHUDConfiguration.barWidth, height: height(for: index))
                                    .shadow(color: palette.barShadow.opacity(0.08 + 0.10 * barValue(for: index)), radius: 2)
                            }
                        }
                        .frame(width: 148, height: 46)
                        .opacity(stopControlState.isPointerInside ? 0.24 : 1)
                        .transition(.opacity)
                    }

                    Button {
                        model.stopPlayback()
                    } label: {
                        HUDStopPlaybackButton(appearance: model.appearance)
                    }
                    .buttonStyle(.plain)
                    .help("Stop Playback")
                    .accessibilityLabel("Stop Playback")
                    .opacity(stopControlState.opacity)
                    .scaleEffect(stopControlState.scale)
                    .allowsHitTesting(stopControlState.allowsHitTesting)
                }
                .frame(
                    width: PlaybackHUDConfiguration.stageSize.width,
                    height: PlaybackHUDConfiguration.stageSize.height
                )

                modeGlyph("E", isActive: model.mode == .explanation)
            }
            .padding(.horizontal, 24)
        }
        .frame(width: PlaybackHUDConfiguration.panelSize.width, height: PlaybackHUDConfiguration.panelSize.height)
        .contentShape(
            RoundedRectangle(
                cornerRadius: SalientFloatingOverlayDesign.cornerRadius,
                style: .continuous
            )
        )
        .onHover { isInside in
            stopControlState.setPointerInside(isInside)
        }
        .animation(.easeOut(duration: 0.04), value: model.frame)
        .animation(.easeInOut(duration: 0.16), value: model.mode)
        .animation(.easeInOut(duration: 0.22), value: model.isGenerating)
        .animation(.easeInOut(duration: 0.14), value: stopControlState)
        .preferredColorScheme(model.appearance == .light ? .light : .dark)
    }

    private func modeGlyph(_ text: String, isActive: Bool) -> some View {
        Text(text)
            .font(.system(size: 30, weight: .black, design: .rounded))
            .monospaced()
            .foregroundStyle(isActive ? palette.activeGlyph : palette.inactiveGlyph)
            .shadow(color: isActive ? palette.activeGlow : .clear, radius: 8)
            .frame(width: 44, height: 48)
            .overlay(alignment: .bottom) {
                Capsule()
                    .fill(isActive ? palette.activeGlyph : Color.clear)
                    .frame(width: 18, height: 2)
                    .shadow(color: isActive ? palette.activeGlow : .clear, radius: 4)
            }
            .accessibilityLabel(text == "Q" ? "Question" : "Explanation")
    }

    private var stageFillColor: Color {
        switch model.appearance {
        case .dark:
            .black.opacity(0.16)
        case .light:
            .white.opacity(0.22)
        }
    }

    private var stageStrokeColor: Color {
        switch model.appearance {
        case .dark:
            .white.opacity(0.10)
        case .light:
            .black.opacity(0.09)
        }
    }

    private func height(for index: Int) -> CGFloat {
        let baseline = barBaselines[index]
        let level = min(1, max(0, model.level))
        let barLevel = barValue(for: index)
        let energized = CGFloat(pow(max(level * 0.18, barLevel), 0.68))
        let baselineShape = 0.68 + 0.32 * (baseline / 40)
        let centroidAccent = 0.90 + 0.16 * CGFloat(model.frame.brightness)
        let accent = (0.86 + 0.14 * CGFloat((sin(Double(index) * 1.17) + 1) / 2)) * centroidAccent
        let envelope = 0.08 + 0.92 * energized
        let height = 6 + 38 * envelope * baselineShape * accent
        return max(6, min(44, height))
    }

    private func barValue(for index: Int) -> Double {
        let levels = model.frame.barLevels
        guard levels.indices.contains(index) else { return model.level }
        return min(1, max(0, levels[index]))
    }

    private func barFill(for index: Int) -> LinearGradient {
        let brightness = min(1, max(0, model.frame.brightness))
        let energy = barValue(for: index)
        let warm = palette.barWarm(brightness: brightness)
        return LinearGradient(
            colors: [
                palette.barTop.opacity(0.82 + 0.16 * energy),
                warm.opacity(0.16 + 0.18 * brightness),
            ],
            startPoint: .top,
            endPoint: .bottom
        )
    }
}

private struct HUDStopPlaybackButton: View {
    var appearance: PlaybackHUDAppearance

    private var palette: PlaybackHUDPalette {
        PlaybackHUDPalette(appearance: appearance)
    }

    var body: some View {
        ZStack {
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .fill(backgroundColor)
                .overlay(
                    RoundedRectangle(cornerRadius: 8, style: .continuous)
                        .strokeBorder(strokeColor, lineWidth: 1)
                )
                .shadow(color: palette.barShadow.opacity(appearance == .dark ? 0.20 : 0.10), radius: 6, y: 2)

            Image(systemName: "stop.fill")
                .font(.system(size: 15, weight: .black))
                .foregroundStyle(iconColor)
                .shadow(color: palette.barShadow.opacity(appearance == .dark ? 0.18 : 0.08), radius: 3)
        }
        .frame(width: 36, height: 36)
        .contentShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
    }

    private var backgroundColor: Color {
        switch appearance {
        case .dark:
            .white.opacity(0.13)
        case .light:
            .black.opacity(0.06)
        }
    }

    private var strokeColor: Color {
        switch appearance {
        case .dark:
            .white.opacity(0.34)
        case .light:
            .black.opacity(0.16)
        }
    }

    private var iconColor: Color {
        switch appearance {
        case .dark:
            palette.barTop.opacity(0.94)
        case .light:
            palette.barTop.opacity(0.82)
        }
    }
}

struct PlaybackHUDAppearanceDesign {
    enum GlyphTone: Equatable {
        case warmOrange
        case lightOrange
        case lightGray
        case dark
        case mutedLight
    }

    var panelAppearanceName: NSAppearance.Name
    var capsuleFillOpacity: Double
    var nativeGlassTintOpacity: Double
    var fallbackShadowOpacity: Double
    var usesDarkForeground: Bool
    var activeGlyphTone: GlyphTone
    var inactiveGlyphTone: GlyphTone

    init(appearance: PlaybackHUDAppearance) {
        switch appearance {
        case .dark:
            panelAppearanceName = .darkAqua
            capsuleFillOpacity = 0.64
            nativeGlassTintOpacity = 0.55
            fallbackShadowOpacity = 0.34
            usesDarkForeground = false
            activeGlyphTone = .warmOrange
            inactiveGlyphTone = .mutedLight
        case .light:
            panelAppearanceName = .aqua
            capsuleFillOpacity = 0.18
            nativeGlassTintOpacity = 0.16
            fallbackShadowOpacity = 0.16
            usesDarkForeground = true
            activeGlyphTone = .warmOrange
            inactiveGlyphTone = .lightGray
        }
    }
}

private struct PlaybackHUDPalette {
    var appearance: PlaybackHUDAppearance
    var design: PlaybackHUDAppearanceDesign
    var activeGlyph: Color
    var inactiveGlyph: Color
    var activeGlow: Color
    var barTop: Color
    var barShadow: Color
    var generatingText: Color
    var generatingShadow: Color

    init(appearance: PlaybackHUDAppearance) {
        self.appearance = appearance
        self.design = PlaybackHUDAppearanceDesign(appearance: appearance)
        switch appearance {
        case .dark:
            let gold = Color(red: 1.0, green: 0.76, blue: 0.18)
            activeGlyph = gold
            inactiveGlyph = Color.white.opacity(0.34)
            activeGlow = gold.opacity(0.42)
            barTop = .white
            barShadow = .white
            generatingText = .white
            generatingShadow = .white
        case .light:
            activeGlyph = Color(red: 1.0, green: 0.50, blue: 0.05)
            inactiveGlyph = Color(red: 0.54, green: 0.56, blue: 0.58).opacity(0.74)
            activeGlow = Color(red: 1.0, green: 0.56, blue: 0.10).opacity(0.28)
            barTop = Color(red: 0.03, green: 0.05, blue: 0.07)
            barShadow = Color.black
            generatingText = Color(red: 0.08, green: 0.10, blue: 0.13)
            generatingShadow = .white
        }
    }

    func barWarm(brightness: Double) -> Color {
        switch appearance {
        case .light:
            Color.black.opacity(0.74 + 0.10 * brightness)
        case .dark:
            Color(red: 1.0, green: 0.78 + 0.12 * brightness, blue: 0.30 + 0.18 * brightness)
        }
    }
}

private struct GeneratingLabel: View {
    var appearance: PlaybackHUDAppearance

    var body: some View {
        TimelineView(.animation(minimumInterval: 1.0 / 30.0)) { timeline in
            let pulse = (sin(timeline.date.timeIntervalSinceReferenceDate * 2.8) + 1) / 2
            let palette = PlaybackHUDPalette(appearance: appearance)
            Text("Generating")
                .font(.system(size: 17, weight: .semibold, design: .rounded))
                .foregroundStyle(palette.generatingText.opacity(0.52 + 0.30 * pulse))
                .shadow(color: palette.generatingShadow.opacity(0.10 + 0.12 * pulse), radius: 6)
                .scaleEffect(0.985 + 0.015 * pulse)
        }
        .frame(width: 148, height: 46)
    }
}

private struct HUDGlassSurface: View {
    var appearance: PlaybackHUDAppearance

    var body: some View {
        SalientFloatingOverlayChrome(
            appearance: appearance,
            shape: RoundedRectangle(
                cornerRadius: SalientFloatingOverlayDesign.cornerRadius,
                style: .continuous
            )
        )
    }
}
