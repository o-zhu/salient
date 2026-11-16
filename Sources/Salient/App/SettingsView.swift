import SalientCore
import SwiftUI

struct SettingsView: View {
    @EnvironmentObject private var model: AppModel

    var body: some View {
        TabView {
            narrationTab
                .tabItem { Label("Narration", systemImage: "speaker.wave.2") }
            shortcutsTab
                .tabItem { Label("Shortcuts", systemImage: "keyboard") }
            privacyTab
                .tabItem { Label("Privacy", systemImage: "lock.shield") }
        }
        .padding(24)
        .frame(width: 640, height: 520)
    }

    private var narrationTab: some View {
        Form {
            Section("Common narration preferences") {
                Picker(
                    "Narrator",
                    selection: Binding(
                        get: { model.speechSettings.engineID },
                        set: { model.setSpeechEngineID($0) }
                    )
                ) {
                    ForEach(SpeechEngineID.allCases, id: \.self) { engine in
                        Text(engine.title).tag(engine)
                    }
                }

                LabeledContent("Speed") {
                    HStack {
                        Slider(
                            value: Binding(
                                get: { model.speechSettings.rateMultiplier },
                                set: { model.setSpeechRateMultiplier($0) }
                            ),
                            in: 0.5...2.4,
                            step: 0.1
                        )
                        .frame(width: 220)
                        Text("\(model.speechSettings.rateMultiplier.formatted(.number.precision(.fractionLength(1))))×")
                            .monospacedDigit()
                            .frame(width: 42, alignment: .trailing)
                    }
                }

                Toggle(
                    "Show playback HUD",
                    isOn: Binding(
                        get: { model.speechSettings.showPlaybackHUD },
                        set: { model.setShowPlaybackHUD($0) }
                    ))

                Picker(
                    "Model residency",
                    selection: Binding(
                        get: { model.modelWarmPolicy },
                        set: { model.setModelWarmPolicy($0) }
                    )
                ) {
                    ForEach(ModelWarmPolicy.allCases, id: \.self) { policy in
                        Text(policy.displayName).tag(policy)
                    }
                }
                Text("Adaptive warms narration only when UWorld or narration work is active, then releases idle helpers.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Section {
                Button("Open Narration Workspace") {
                    model.showMainWindow(section: .speech)
                }
            }
        }
        .formStyle(.grouped)
    }

    private var shortcutsTab: some View {
        Form {
            Section("Study browser") { BrowserPreferencePicker() }
            Section("Global study shortcuts") {
                ForEach(StudyShortcutAction.allCases) { action in
                    Toggle(
                        isOn: Binding(
                            get: { model.shortcut(for: action).isEnabled },
                            set: { model.setShortcutEnabled($0, for: action) }
                        )
                    ) {
                        LabeledContent(action.title, value: model.shortcut(for: action).displayString)
                    }
                }
            }
            Section {
                Button("Edit key combinations and resolve conflicts") {
                    model.showMainWindow(section: .keyboardShortcuts)
                }
            }
        }
        .formStyle(.grouped)
    }

    private var privacyTab: some View {
        Form {
            Section("Local processing") {
                LabeledContent("Qwen residency", value: model.qwenResidencyState.rawValue.capitalized)
            }

            Section("Privacy boundary") {
                Label("Study content, model inference, traces, and generated audio stay on this Mac.", systemImage: "checkmark.shield")
                    .foregroundStyle(.secondary)
                Text("Salient does not add telemetry, analytics, crash reporting, or external logging.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Section {
                HStack {
                    Button("Open Permissions") { model.showMainWindow(section: .permissions) }
                }
            }
        }
        .formStyle(.grouped)
    }
}
