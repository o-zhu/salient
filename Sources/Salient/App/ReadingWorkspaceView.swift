import AppKit
import SalientCore
import SwiftUI

/// The reader's home workspace: browser study actions, settings shortcuts, and free text reading.
struct ReadingWorkspaceView: View {
    @EnvironmentObject private var model: AppModel
    @Environment(\.colorScheme) private var colorScheme
    @FocusState private var editorFocused: Bool

    private var hasText: Bool { !model.readingText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
    private var accent: Color { colorScheme == .dark ? Color(red: 0.49, green: 0.79, blue: 0.72) : SalientTheme.teal }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 22) {
                header.padding(.bottom, 6)
                browserCard
                settingsCards
                textCard
                if model.isBusy || model.lastError != nil { status }
            }
            .padding(28)
            .padding(.bottom, 12)
            .frame(maxWidth: 1080, alignment: .leading)
            .frame(maxWidth: .infinity)
        }
        .frame(minWidth: 560, minHeight: 580)
        .salientScrollTopFade()
        .background(SalientBackground().ignoresSafeArea())
    }

    private var header: some View {
        HStack(spacing: 16) {
            Image(nsImage: Self.brandImage)
                .resizable()
                .interpolation(.high)
                .frame(width: 64, height: 64)
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 7) {
                Text("Make room to focus.")
                    .font(.system(size: 32, weight: .semibold, design: .serif))
                    .accessibilityAddTraits(.isHeader)
                Text("Listen naturally. Read clearly. Keep your place.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    private static let brandImage: NSImage = {
        if let url = Bundle.main.url(forResource: "Salient", withExtension: "icns"),
           let image = NSImage(contentsOf: url) { return image }
        return NSApplication.shared.applicationIconImage
    }()

    private var browserCard: some View {
        GlassPanel(accent: accent, padding: 22, isElevated: false, cornerRadius: 16) {
            VStack(alignment: .leading, spacing: 20) {
                ViewThatFits(in: .horizontal) {
                    HStack(alignment: .center, spacing: 22) {
                        browserHeading
                        Spacer(minLength: 0)
                        browserPicker
                    }
                    VStack(alignment: .leading, spacing: 14) {
                        browserHeading
                        browserPicker
                    }
                }
                ViewThatFits(in: .horizontal) {
                    HStack(spacing: 10) { browserActions }
                    LazyVGrid(columns: [GridItem(.flexible()), GridItem(.flexible())], spacing: 10) {
                        browserActions
                    }
                }
            }
        }
    }

    @ViewBuilder private var browserActions: some View {
        browserAction(.readQuestion, title: "Read question", symbol: "play.fill", prominent: true)
        browserAction(.readExplanation, title: "Explanation", symbol: "text.bubble")
        browserAction(.submit, title: "Submit answer", symbol: "return")
        browserAction(.nextQuestionAndRead, title: "Next + read", symbol: "arrow.right")
    }

    private var browserHeading: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("Study in Browser")
                .font(.system(size: 21, weight: .semibold, design: .serif))
                .accessibilityAddTraits(.isHeader)
            Text("Listen to your UWorld tab and move through questions.")
                .font(.callout)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private var browserPicker: some View {
        BrowserPreferencePicker(showsTargetHint: false)
            .labelsHidden()
            .frame(width: 180)
            .help("Uses the front tab in \(model.selectedBrowser.title).")
    }

    private var settingsCards: some View {
        LazyVGrid(columns: [GridItem(.adaptive(minimum: 180), spacing: 14)], spacing: 14) {
            ReadingFeatureCard(
                title: "Browser shortcuts", symbol: "keyboard", accent: accent,
                detail: "Read, submit, and move on from your keyboard.",
                buttonTitle: "Set shortcuts"
            ) { model.showMainWindow(section: .keyboardShortcuts) }
            ReadingFeatureCard(
                title: "Narration", symbol: "waveform", accent: colorScheme == .dark ? .orange : SalientTheme.coral,
                detail: "Find your voice and pace. Follow along one word at a time.",
                buttonTitle: "Adjust narration"
            ) { model.showMainWindow(section: .speech) }
            ReadingFeatureCard(
                title: "Permissions", symbol: "lock.shield", accent: colorScheme == .dark ? .yellow : SalientTheme.brass,
                detail: "Connect your browser and get ready to study.",
                buttonTitle: "Manage access"
            ) { model.showMainWindow(section: .permissions) }
        }
    }

    private var textCard: some View {
        GlassPanel(accent: accent, padding: 22, isElevated: false, cornerRadius: 16) {
            VStack(alignment: .leading, spacing: 16) {
                HStack {
                    Text("Read your own text")
                        .font(.system(size: 21, weight: .semibold, design: .serif))
                        .accessibilityAddTraits(.isHeader)
                    Spacer()
                    if hasText {
                        Button("Clear") { model.readingText = ""; editorFocused = true }
                            .buttonStyle(.borderless)
                            .disabled(model.isBusy)
                    } else {
                        Button("Try a sample") { model.readingText = Self.sampleText; editorFocused = true }
                            .buttonStyle(.borderless)
                    }
                }
                ZStack(alignment: .topLeading) {
                    TextEditor(text: $model.readingText)
                        .font(.system(size: 16))
                        .scrollContentBackground(.hidden)
                        .focused($editorFocused)
                        .accessibilityLabel("Text to read")
                        .padding(8)
                    if !hasText {
                        Text("Paste something you’d like to read…")
                            .font(.system(size: 16))
                            .foregroundStyle(.secondary)
                            .padding(14)
                            .allowsHitTesting(false)
                            .accessibilityHidden(true)
                    }
                }
                .frame(height: 142)
                .background(.background.opacity(0.35), in: RoundedRectangle(cornerRadius: 10))
                .overlay(RoundedRectangle(cornerRadius: 10).stroke(.primary.opacity(0.10)))
                HStack(spacing: 10) {
                    Button { model.readEnteredText() } label: {
                        Label("Read aloud", systemImage: "play.fill")
                    }
                    .buttonStyle(.borderedProminent)
                    .tint(SalientTheme.teal)
                    .keyboardShortcut(.return, modifiers: .command)
                    .disabled(!hasText || model.isBusy)
                    Button { model.openEnteredTextInRSVP() } label: {
                        Label("Visual reader", systemImage: "text.viewfinder")
                    }
                    .buttonStyle(.bordered)
                    .disabled(!hasText || model.isBusy)
                    Spacer(minLength: 0)
                    Button { model.run(.stopSpeech) } label: {
                        Image(systemName: "stop.fill")
                    }
                    .accessibilityLabel("Stop playback")
                    .help("Stop playback (⌘.)")
                    .keyboardShortcut(".", modifiers: .command)
                    .buttonStyle(.bordered)
                }
                .controlSize(.large)
            }
        }
    }

    private func browserAction(_ action: StudyShortcutAction, title: String, symbol: String, prominent: Bool = false) -> some View {
        let shortcut = model.shortcut(for: action)
        return Button { model.run(action.studyAction) } label: {
            VStack(alignment: .leading, spacing: 10) {
                HStack {
                    Image(systemName: symbol).font(.system(size: 16, weight: .medium))
                    Spacer(minLength: 0)
                    if shortcut.isEnabled {
                        Text(shortcut.displayString)
                            .font(.system(size: 11, weight: .medium, design: .monospaced))
                            .opacity(0.75)
                    }
                }
                Text(title).font(.system(size: 13, weight: .semibold))
                    .lineLimit(1)
            }
            .frame(maxWidth: .infinity, minHeight: 46, alignment: .leading)
        }
        .buttonStyle(ReadingActionButtonStyle(accent: accent, prominent: prominent))
        .frame(minWidth: 124)
        .accessibilityLabel(action == .submit ? "Submit answer" : action.title)
        .help(shortcut.isEnabled ? "\(action.title) (\(shortcut.displayString))" : action.title)
        .disabled(model.isBusy)
    }

    private var status: some View {
        HStack(alignment: .top, spacing: 9) {
            if model.isBusy { ProgressView().controlSize(.small) }
            else { Image(systemName: "exclamationmark.circle") }
            Text(model.lastError ?? model.statusMessage).font(.callout).textSelection(.enabled)
            Spacer()
        }
        .foregroundStyle(model.lastError == nil ? Color.secondary : .red)
        .accessibilityElement(children: .combine)
    }

    static let sampleText = "A little space can make a big difference. Listen to the sentence, follow each word, and settle into a pace that feels comfortable.\n\nWhen you are ready, bring your own text or read directly from your study tab in your preferred browser."
}

private struct ReadingFeatureCard: View {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var isHovered = false
    var title: String
    var symbol: String
    var accent: Color
    var detail: String
    var buttonTitle: String
    var action: () -> Void

    var body: some View {
        Button(action: action) {
            VStack(alignment: .leading, spacing: 12) {
                Image(systemName: symbol)
                    .font(.system(size: 21, weight: .regular))
                    .foregroundStyle(accent)
                    .frame(height: 25, alignment: .leading)
                Text(title).font(.headline)
                Text(detail)
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                    .frame(maxWidth: .infinity, minHeight: 52, alignment: .topLeading)
                HStack {
                    Text(buttonTitle).font(.callout.weight(.medium))
                    Spacer(minLength: 4)
                    Image(systemName: "arrow.up.right").font(.system(size: 11, weight: .semibold))
                }
                .foregroundStyle(accent)
                .padding(.top, 4)
            }
            .padding(20)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(.primary.opacity(isHovered ? 0.065 : 0.025), in: RoundedRectangle(cornerRadius: 14))
            .overlay(RoundedRectangle(cornerRadius: 14).stroke(isHovered ? accent.opacity(0.5) : .primary.opacity(0.09)))
            .contentShape(RoundedRectangle(cornerRadius: 14))
        }
        .buttonStyle(.plain)
        .onHover { isHovered = $0 }
        .animation(reduceMotion ? nil : .easeOut(duration: 0.15), value: isHovered)
        .accessibilityLabel(buttonTitle)
        .accessibilityHint(detail)
    }
}

private struct ReadingActionButtonStyle: ButtonStyle {
    @Environment(\.isEnabled) private var isEnabled
    @Environment(\.colorScheme) private var colorScheme
    var accent: Color
    var prominent: Bool

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .padding(13)
            .foregroundStyle(prominent && colorScheme == .dark ? Color.black.opacity(0.85) : prominent ? .white : .primary)
            .background {
                RoundedRectangle(cornerRadius: 10)
                    .fill(prominent ? accent : .primary.opacity(configuration.isPressed ? 0.12 : 0.055))
            }
            .overlay(RoundedRectangle(cornerRadius: 10).stroke(.primary.opacity(prominent ? 0 : 0.08)))
            .opacity(isEnabled ? (configuration.isPressed ? 0.8 : 1) : 0.45)
            .contentShape(RoundedRectangle(cornerRadius: 10))
    }
}
