import SalientCore
import SwiftUI

struct KeyboardShortcutsView: View {
    @EnvironmentObject private var model: AppModel

    var body: some View {
        PageScaffold(
            title: "Keyboard Shortcuts",
            subtitle: "Global shortcuts for UWorld Study actions.",
            accent: SalientTheme.coral
        ) {
            SalientPageScrollView {
                VStack(alignment: .leading, spacing: SalientTheme.cardSpacing) {
                    shortcutSummary
                    ForEach(StudyShortcutAction.allCases) { action in
                        ShortcutAssignmentRow(action: action)
                    }
                }
            }
        }
    }

    private var shortcutSummary: some View {
        let active = StudyShortcutAction.allCases.filter { model.shortcut(for: $0).isEnabled }.count
        let attention = StudyShortcutAction.allCases.filter {
            switch model.shortcutRegistrationState(for: $0) {
            case .invalid, .failed: true
            case .disabled, .registered: false
            }
        }.count

        return GlassPanel(accent: attention == 0 ? SalientTheme.teal : SalientTheme.coral, padding: 14, isElevated: false) {
            HStack(spacing: 12) {
                StatusPill("\(active) active", systemImage: "keyboard", tint: SalientTheme.teal)
                StatusPill(attention == 0 ? "No conflicts" : "\(attention) need attention", systemImage: attention == 0 ? "checkmark.circle" : "exclamationmark.triangle", tint: attention == 0 ? SalientTheme.brass : SalientTheme.coral)
                Spacer()
                Text("Record, enable, and reset shortcuts from one aligned table.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }
        }
    }
}

private struct ShortcutAssignmentRow: View {
    @EnvironmentObject private var model: AppModel
    var action: StudyShortcutAction

    var body: some View {
        let shortcut = model.shortcut(for: action)
        let registrationState = model.shortcutRegistrationState(for: action)

        ViewThatFits(in: .horizontal) {
            HStack(alignment: .top, spacing: 12) {
                rowCopy(shortcut: shortcut, registrationState: registrationState)
                Spacer(minLength: 16)
                rowControls(shortcut: shortcut)
            }

            VStack(alignment: .leading, spacing: 10) {
                rowCopy(shortcut: shortcut, registrationState: registrationState)
                rowControls(shortcut: shortcut)
            }
        }
        .salientFlatRow(accent: registrationState.color, horizontalPadding: 14, verticalPadding: 14)
    }

    private func rowCopy(shortcut: HotKeyDefinition, registrationState: ShortcutRegistrationState) -> some View {
        HStack(alignment: .top, spacing: 12) {
            Image(systemName: action.systemImage)
                .frame(width: 24)
                .foregroundStyle(.secondary)
                .padding(.top, 3)

            VStack(alignment: .leading, spacing: 4) {
                HStack(spacing: 8) {
                    Text(action.title)
                        .font(.headline)
                    Text(registrationState.label)
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(registrationState.color)
                        .padding(.horizontal, 7)
                        .padding(.vertical, 2)
                        .background(registrationState.color.opacity(0.12))
                        .clipShape(Capsule())
                }
                if let detail = registrationState.detail {
                    Text(detail)
                        .font(.callout)
                        .foregroundStyle(.secondary)
                }
            }
        }
    }

    private func rowControls(shortcut: HotKeyDefinition) -> some View {
        HStack(spacing: 10) {
            KeyboardShortcutRecorder(shortcut: shortcut) { updated in
                model.setShortcut(updated, for: action)
            }
            .accessibilityLabel("Shortcut for \(action.title)")
            .frame(width: 150, height: 30)

            Toggle("Enabled", isOn: Binding(
                get: { model.shortcut(for: action).isEnabled },
                set: { model.setShortcutEnabled($0, for: action) }
            ))
            .toggleStyle(.switch)
            .accessibilityLabel("Enable \(action.title) shortcut")
            .frame(width: 118, alignment: .leading)

            Button {
                model.resetShortcut(for: action)
            } label: {
                Image(systemName: "arrow.counterclockwise")
                    .frame(width: 18)
            }
            .buttonStyle(.bordered)
            .accessibilityLabel("Reset \(action.title) shortcut")
            .help("Reset shortcut")
        }
    }
}

private extension StudyShortcutAction {
    var systemImage: String {
        switch self {
        case .readQuestion: "speaker.wave.2"
        case .readExplanation: "text.bubble"
        case .submit: "return"
        case .stopPlayback: "stop.circle"
        case .nextQuestionAndRead: "arrow.right.circle"
        }
    }
}

private extension ShortcutRegistrationState {
    var color: Color {
        switch self {
        case .disabled: .secondary
        case .registered: .green
        case .invalid: .orange
        case .failed: .red
        }
    }

    var detail: String? {
        switch self {
        case .disabled, .registered:
            nil
        case .invalid(let message), .failed(let message):
            message
        }
    }
}
