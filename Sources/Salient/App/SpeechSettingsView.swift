import SalientCore
import SwiftUI

enum SpeechSettingsCopy {
    static let pageSubtitle = "Your voice, your pace, and a reader that follows along."
    static let voiceCloningSectionTitle = "Voice Cloning"
    static let voiceCloningSectionSubtitle =
        "Use an optional local recording for Qwen voice cloning while keeping preset voices as the default."
    static let useMyVoiceTitle = "Use My Voice"
    static let useMyVoiceSubtitle = "Use Crisp Study Voice by default, or replace it with one local recording saved on this Mac."
}

struct SpeechSettingsView: View {
    @EnvironmentObject private var model: AppModel
    @State private var isAdvancedSettingsExpanded = false

    var body: some View {
        PageScaffold(
            title: "Narration Settings",
            subtitle: SpeechSettingsCopy.pageSubtitle,
            accent: SalientTheme.coral
        ) {
            SalientPageScrollView {
                VStack(alignment: .leading, spacing: 30) {
                    VoiceSummaryPanel()

                    SettingsSection(
                        title: "Voice",
                        subtitle: "Choose how your study material sounds.",
                        accent: SalientTheme.coral
                    ) {
                        EnginePickerRow()
                        if model.speechSettings.engineID == .apple {
                            VoicePickerRow()
                        } else if model.speechSettings.engineID == .pocket {
                            PocketVoicePanel()
                        } else if !model.speechSettings.qwenUseReferenceVoice {
                            QwenVoiceRow()
                                .transition(.opacity.combined(with: .move(edge: .top)))
                        }
                    }

                    SettingsSection(
                        title: "Playback",
                        subtitle: "Set a comfortable speaking pace and volume.",
                        accent: SalientTheme.teal
                    ) {
                        SpeechSliderRow(
                            title: "Narration Speed",
                            valueText: "\(model.speechSettings.rateMultiplier.formatted(.number.precision(.fractionLength(1))))x",
                            value: Binding(
                                get: { model.speechSettings.rateMultiplier },
                                set: { model.setSpeechRateMultiplier($0) }
                            ),
                            range: 0.5...2.4,
                            step: 0.1
                        )

                        SpeechSliderRow(
                            title: "Volume",
                            valueText: model.speechSettings.volume.formatted(.percent.precision(.fractionLength(0))),
                            value: Binding(
                                get: { model.speechSettings.volume },
                                set: { model.setSpeechVolume($0) }
                            ),
                            range: 0...1,
                            step: 0.05
                        )

                        if model.speechSettings.engineID == .apple {
                            SpeechSliderRow(
                                title: "Pitch",
                                valueText: model.speechSettings.pitchMultiplier.formatted(.number.precision(.fractionLength(2))),
                                value: Binding(
                                    get: { model.speechSettings.pitchMultiplier },
                                    set: { model.setSpeechPitchMultiplier($0) }
                                ),
                                range: 0.5...2.0,
                                step: 0.05
                            )
                        } else if model.speechSettings.engineID.qwenLane != nil {
                            SpeechSliderRow(
                                title: "De-esser Strength",
                                valueText: deEsserStrengthText,
                                value: Binding(
                                    get: { model.speechSettings.qwenDeEsserStrengthDecibels },
                                    set: { model.setQwenDeEsserStrengthDecibels($0) }
                                ),
                                range: 0...SpeechSettings.maximumQwenDeEsserStrengthDecibels,
                                step: 0.5
                            )
                        }
                    }
                    .animation(.easeInOut(duration: 0.18), value: model.speechSettings.qwenUseReferenceVoice)

                    SettingsSection(
                        title: "Visual Reader",
                        subtitle: "Read one word at a time, with speech or in silence.",
                        accent: SalientTheme.brass
                    ) {
                        RSVPReaderNarrationToggleRow()
                        RSVPReaderSpeedRow()
                    }

                    SettingsSection(
                        title: "Narration Flow",
                        subtitle: "Adjust how captured study text is prepared before speech begins.",
                        accent: SalientTheme.teal
                    ) {
                        NarrationBehaviorToggleRow(
                            title: "Read Last Sentence First",
                            subtitle: "Start each question with the final task sentence, then narrate the stem.",
                            isOn: Binding(
                                get: { model.speechSettings.readsLastSentenceFirst },
                                set: { model.setReadsLastSentenceFirst($0) }
                            )
                        )
                        if model.speechSettings.engineID.qwenLane != nil {
                            NarrationBehaviorToggleRow(
                                title: "Prompt Audio Library",
                                subtitle: "Reuse local Qwen prompt audio to smooth the final task sentence.",
                                isOn: Binding(
                                    get: { model.speechSettings.usesQuestionPromptAudioLibrary },
                                    set: { model.setUsesQuestionPromptAudioLibrary($0) }
                                )
                            )
                        }
                        NarrationBehaviorToggleRow(
                            title: "Skip Parentheses",
                            subtitle: "Omit parenthetical asides and abbreviations from narration.",
                            isOn: Binding(
                                get: { model.speechSettings.skipsParentheticalContent },
                                set: { model.setSkipsParentheticalContent($0) }
                            )
                        )
                    }

                    advancedSettings
                    NarrationResetPanel()
                }
            }
        }
    }

    private var deEsserStrengthText: String {
        let strength = model.speechSettings.qwenDeEsserStrengthDecibels
        return strength == 0
            ? "Off"
            : "\(strength.formatted(.number.precision(.fractionLength(1)))) dB"
    }

    private var advancedSettings: some View {
        SettingsSection(
            title: "Advanced",
            subtitle: model.speechSettings.engineID.qwenLane == nil
                ? "Adjust the playback pop-up and reader pauses."
                : "Voice cloning, the playback pop-up, and precise reading controls.",
            accent: SalientTheme.brass
        ) {
            DisclosureGroup(isExpanded: $isAdvancedSettingsExpanded) {
                VStack(alignment: .leading, spacing: 22) {
                    if model.speechSettings.engineID.qwenLane?.supportsReferenceVoice == true {
                        advancedHeader(
                            title: SpeechSettingsCopy.voiceCloningSectionTitle,
                            subtitle: SpeechSettingsCopy.voiceCloningSectionSubtitle
                        )
                        QwenCloneVoicePanel()
                        Divider()
                    }

                    advancedHeader(
                        title: "Playback Pop-Up",
                        subtitle: "Control the floating audio visualizer."
                    )
                    PlaybackHUDToggleRow()
                    PlaybackHUDAppearanceRow()

                    Divider()

                    advancedHeader(
                        title: "Reader Timing",
                        subtitle: model.speechSettings.engineID.qwenLane == nil
                            ? "Fine-tune word pauses."
                            : "Fine-tune alignment and pauses."
                    )
                    if model.speechSettings.engineID.qwenLane != nil {
                        RSVPPrecisionAlignmentRow()
                    }
                    RSVPReaderBehaviorRow()
                }
                .padding(.top, 16)
            } label: {
                Label(
                    isAdvancedSettingsExpanded ? "Hide advanced controls" : "Show advanced controls",
                    systemImage: "slider.horizontal.3"
                )
                .font(.headline)
            }
            .narrationSettingsBox(accent: SalientTheme.brass)
        }
    }

    private func advancedHeader(title: String, subtitle: String) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(title)
                .font(.headline)
            Text(subtitle)
                .font(.callout)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }
}

extension View {
    fileprivate func narrationSettingsBox(
        accent: Color,
        horizontalPadding: CGFloat = 16,
        verticalPadding: CGFloat = 13
    ) -> some View {
        salientFlatRow(
            accent: accent,
            outline: Color.primary.opacity(0.32),
            fillsWidth: true,
            horizontalPadding: horizontalPadding,
            verticalPadding: verticalPadding
        )
    }
}

private struct VoiceSummaryPanel: View {
    @EnvironmentObject private var model: AppModel

    var body: some View {
        GlassPanel(accent: SalientTheme.coral, outline: SalientTheme.outlineGold, padding: 14, isElevated: false) {
            ViewThatFits(in: .horizontal) {
                HStack(alignment: .center, spacing: 12) {
                    summaryCopy
                    Spacer(minLength: 12)
                    summaryPills
                }

                VStack(alignment: .leading, spacing: 12) {
                    summaryCopy
                    summaryPills
                }
            }
        }
    }

    private var summaryCopy: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text("Current narrator")
                .font(.system(.title3, design: .serif).weight(.semibold))
            Text("Used for browser reading and your own text.")
                .font(.callout)
                .foregroundStyle(.secondary)
        }
    }

    private var summaryPills: some View {
        ViewThatFits(in: .horizontal) {
            HStack(spacing: 8) { summaryPillContent }
            VStack(alignment: .leading, spacing: 8) { summaryPillContent }
        }
    }

    @ViewBuilder
    private var summaryPillContent: some View {
        StatusPill(model.speechSettings.engineID.title, systemImage: "waveform", tint: SalientTheme.coral)
        StatusPill(
            "\(model.speechSettings.rateMultiplier.formatted(.number.precision(.fractionLength(1))))x",
            systemImage: "speedometer",
            tint: SalientTheme.teal
        )
        StatusPill(
            model.speechSettings.volume.formatted(.percent.precision(.fractionLength(0))),
            systemImage: "speaker.wave.2",
            tint: SalientTheme.brass
        )
        StatusPill(
            model.speechSettings.showPlaybackHUD ? "\(model.speechSettings.playbackHUDAppearance.title) pop-up" : "Pop-up off",
            systemImage: "waveform.path",
            tint: SalientTheme.teal
        )
    }
}

private struct EnginePickerRow: View {
    @EnvironmentObject private var model: AppModel

    var body: some View {
        HStack(spacing: 14) {
            Text("Engine")
                .font(.headline)
                .frame(width: 90, alignment: .leading)

            Picker(
                "Engine",
                selection: Binding(
                    get: { model.speechSettings.engineID },
                    set: { model.setSpeechEngineID($0) }
                )
            ) {
                ForEach(SpeechEngineID.allCases) { engine in
                    Text(engine.title).tag(engine)
                }
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .controlSize(.large)
        }
        .narrationSettingsBox(accent: SalientTheme.coral)
    }
}

private struct PocketVoicePanel: View {
    @EnvironmentObject private var model: AppModel

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack(spacing: 14) {
                Image(systemName: "waveform.circle.fill")
                    .font(.system(size: 34))
                    .foregroundStyle(SalientTheme.teal)
                VStack(alignment: .leading, spacing: 4) {
                    Text("Alba").font(.headline)
                    Text(model.pocketIsInstalled ? "Pocket \(PocketRuntimeManager.version) · Ready offline" : "Download once for natural, offline speech.")
                        .font(.callout).foregroundStyle(.secondary)
                }
                Spacer(minLength: 8)
                if model.pocketInstallProgress == nil {
                    if model.pocketIsInstalled, model.pocketError == nil {
                        Button("Preview voice", systemImage: "play.fill") { model.previewSpeech() }
                            .buttonStyle(.borderedProminent).tint(SalientTheme.teal)
                    } else {
                        Button(model.pocketError != nil ? "Retry Download" : (model.pocketHasLegacyInstallation ? "Update Pocket" : "Download Pocket")) { model.installPocket() }
                            .buttonStyle(.borderedProminent).tint(SalientTheme.teal)
                    }
                }
            }
            if let progress = model.pocketInstallProgress {
                HStack(spacing: 12) {
                    VStack(alignment: .leading, spacing: 6) {
                        Text(progress.stage).font(.callout)
                        ProgressView(value: progress.fraction)
                        if let bytes = progress.downloadedBytes, let total = progress.totalBytes {
                            Text("\(ByteCountFormatter.string(fromByteCount: bytes, countStyle: .file)) of \(ByteCountFormatter.string(fromByteCount: total, countStyle: .file))")
                                .font(.caption).foregroundStyle(.secondary).monospacedDigit()
                        }
                    }
                    Button("Cancel") { model.cancelPocketInstall() }
                }
            } else if let error = model.pocketError {
                Label(error, systemImage: "exclamationmark.circle").font(.callout).foregroundStyle(.orange)
            } else if !model.pocketIsInstalled {
                Text("Native Apple reads until Pocket is installed.").font(.callout).foregroundStyle(.secondary)
            }
            if model.pocketIsInstalled, model.pocketHasLegacyInstallation, model.pocketInstallProgress == nil {
                Button("Remove old Pocket setup", systemImage: "trash") { model.removeLegacyPocket() }
                    .help("Move the previous Python runtime to Trash. The new Pocket voice stays installed.")
            }
        }
        .narrationSettingsBox(accent: SalientTheme.teal)
        .task { await model.refreshPocketReadiness() }
    }
}

private struct PlaybackHUDToggleRow: View {
    @EnvironmentObject private var model: AppModel

    var body: some View {
        HStack(spacing: 14) {
            VStack(alignment: .leading, spacing: 3) {
                Text("Show Playback Pop-Up")
                    .font(.headline)
                Text("Display the floating audio visualizer while \(AppModel.displayName) is narrating.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }

            Spacer(minLength: 16)

            Toggle(
                "Show Playback Pop-Up",
                isOn: Binding(
                    get: { model.speechSettings.showPlaybackHUD },
                    set: { model.setShowPlaybackHUD($0) }
                )
            )
            .labelsHidden()
            .toggleStyle(.switch)
            .controlSize(.large)
        }
        .narrationSettingsBox(accent: SalientTheme.coral)
    }
}

private struct PlaybackHUDAppearanceRow: View {
    @EnvironmentObject private var model: AppModel

    var body: some View {
        HStack(spacing: 14) {
            Text("Pop-Up Style")
                .font(.headline)
                .frame(width: 140, alignment: .leading)

            Picker(
                "Pop-Up Style",
                selection: Binding(
                    get: { model.speechSettings.playbackHUDAppearance },
                    set: { model.setPlaybackHUDAppearance($0) }
                )
            ) {
                ForEach(PlaybackHUDAppearance.allCases) { appearance in
                    Text(appearance.title).tag(appearance)
                }
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .controlSize(.large)
            .disabled(!model.speechSettings.showPlaybackHUD)
            .opacity(model.speechSettings.showPlaybackHUD ? 1 : 0.55)

            Spacer(minLength: 0)
        }
        .narrationSettingsBox(accent: SalientTheme.coral)
    }
}

private struct RSVPPrecisionAlignmentRow: View {
    @EnvironmentObject private var model: AppModel

    var body: some View {
        HStack(spacing: 14) {
            VStack(alignment: .leading, spacing: 3) {
                Text("Precision Word Sync")
                    .font(.headline)
                Text(subtitle)
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }

            Spacer(minLength: 16)

            if let progress = model.rsvpPrecisionAlignmentProgress {
                VStack(alignment: .trailing, spacing: 4) {
                    ProgressView(value: progress.fractionCompleted)
                        .frame(width: 150)
                    Text(progress.stage)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
            } else if model.rsvpPrecisionAlignmentState == .ready
                || model.rsvpPrecisionAlignmentState == .installed
            {
                Label("Installed", systemImage: "checkmark.circle.fill")
                    .foregroundStyle(.green)
            } else {
                Button("Install ~1 GB") {
                    model.installRSVPPrecisionAlignment()
                }
                .buttonStyle(.borderedProminent)
                .disabled(model.rsvpPrecisionAlignmentState == .installing)
            }
        }
        .narrationSettingsBox(accent: SalientTheme.brass)
    }

    private var subtitle: String {
        switch model.rsvpPrecisionAlignmentState {
        case .ready:
            "Uses local forced alignment when it can finish ahead of playback; audio never waits."
        case .installed, .loading:
            "Installed locally and loaded only on demand. Audio-clock fallback remains active."
        case .installing:
            "Downloading the optional local alignment model."
        case .failed:
            "Setup failed; audio-clock fallback remains active. Retry when convenient."
        case .notInstalled:
            "Optional local word timestamps improve later items and cached replays without delaying audio."
        }
    }
}

private struct RSVPReaderNarrationToggleRow: View {
    @EnvironmentObject private var model: AppModel

    var body: some View {
        HStack(spacing: 14) {
            VStack(alignment: .leading, spacing: 3) {
                Text("Follow Speech")
                    .font(.headline)
                Text("Show each word as it is spoken.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }

            Spacer(minLength: 16)

            Toggle(
                "Follow Speech",
                isOn: Binding(
                    get: { model.rsvpReadingSettings.showsDuringNarration },
                    set: { model.setShowRSVPDuringNarration($0) }
                )
            )
            .labelsHidden()
            .toggleStyle(.switch)
            .controlSize(.large)
        }
        .narrationSettingsBox(accent: SalientTheme.brass)
    }
}

private struct RSVPReaderSpeedRow: View {
    @EnvironmentObject private var model: AppModel

    var body: some View {
        HStack(spacing: 14) {
            Text("Silent Reading")
                .font(.headline)
                .frame(width: 140, alignment: .leading)

            Slider(
                value: Binding(
                    get: { Double(model.rsvpReadingSettings.wordsPerMinute) },
                    set: { model.setRSVPWordsPerMinute(Int(($0 / 10).rounded() * 10)) }
                ),
                in: Double(RSVPReadingSettings.minimumWordsPerMinute)...Double(RSVPReadingSettings.maximumWordsPerMinute),
                step: 10
            )
            .controlSize(.large)
            .accessibilityLabel("Silent reading words per minute")

            if model.rsvpReadingSettings.showsComprehensionWarning {
                Image(systemName: "exclamationmark.triangle.fill")
                    .foregroundStyle(.yellow)
                    .help("High RSVP speeds can reduce comprehension and increase fatigue.")
            }

            Text("\(model.rsvpReadingSettings.wordsPerMinute) WPM")
                .font(.system(.body, design: .monospaced))
                .foregroundStyle(.secondary)
                .frame(width: 88, alignment: .trailing)
        }
        .narrationSettingsBox(accent: SalientTheme.brass)
    }
}

private struct RSVPReaderBehaviorRow: View {
    @EnvironmentObject private var model: AppModel

    var body: some View {
        HStack(spacing: 14) {
            Text("Reader Timing")
                .font(.headline)
                .frame(width: 140, alignment: .leading)

            Toggle(
                "ORP",
                isOn: Binding(
                    get: { model.rsvpReadingSettings.isORPEnabled },
                    set: { model.setRSVPORPEnabled($0) }
                )
            )
            .toggleStyle(.checkbox)

            Toggle(
                "Punctuation Pauses",
                isOn: Binding(
                    get: { model.rsvpReadingSettings.usesPunctuationPauses },
                    set: { model.setRSVPPunctuationPausesEnabled($0) }
                )
            )
            .toggleStyle(.checkbox)

            Toggle(
                "Section Pauses",
                isOn: Binding(
                    get: { model.rsvpReadingSettings.usesSectionPauses },
                    set: { model.setRSVPSectionPausesEnabled($0) }
                )
            )
            .toggleStyle(.checkbox)

            Spacer(minLength: 0)
        }
        .narrationSettingsBox(accent: SalientTheme.brass)
    }
}

private struct NarrationBehaviorToggleRow: View {
    var title: String
    var subtitle: String
    @Binding var isOn: Bool

    var body: some View {
        HStack(spacing: 14) {
            VStack(alignment: .leading, spacing: 3) {
                Text(title)
                    .font(.headline)
                Text(subtitle)
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }

            Spacer(minLength: 16)

            Toggle(title, isOn: $isOn)
                .labelsHidden()
                .toggleStyle(.switch)
                .controlSize(.large)
        }
        .narrationSettingsBox(accent: SalientTheme.teal)
    }
}

private struct SpeechSliderRow: View {
    var title: String
    var valueText: String
    @Binding var value: Double
    var range: ClosedRange<Double>
    var step: Double

    var body: some View {
        HStack(spacing: 14) {
            Text(title)
                .font(.headline)
                .frame(width: 140, alignment: .leading)
            Slider(value: $value, in: range, step: step)
                .controlSize(.large)
            Text(valueText)
                .font(.system(.body, design: .monospaced))
                .foregroundStyle(.secondary)
                .frame(width: 72, alignment: .trailing)
        }
        .narrationSettingsBox(accent: SalientTheme.teal)
    }
}

private struct QwenVoiceRow: View {
    @EnvironmentObject private var model: AppModel

    var body: some View {
        if let lane = model.speechSettings.engineID.qwenLane {
            HStack(spacing: 14) {
                Text("Qwen Voice")
                    .font(.headline)
                    .frame(width: 140, alignment: .leading)

                Picker(
                    "Qwen Voice",
                    selection: Binding(
                        get: { model.speechSettings.qwenSpeaker },
                        set: { model.setQwenSpeaker($0) }
                    )
                ) {
                    ForEach(lane.presetSpeakers, id: \.self) { speaker in
                        Text(lane.title(for: speaker)).tag(speaker)
                    }
                }
                .labelsHidden()
                .controlSize(.large)

                Text(lane.displayName)
                    .foregroundStyle(.secondary)
                    .frame(minWidth: 150, alignment: .leading)
            }
            .narrationSettingsBox(accent: SalientTheme.coral)
        }
    }
}

private struct QwenCloneVoicePanel: View {
    @EnvironmentObject private var model: AppModel
    @State private var isCloneSheetPresented = false

    var body: some View {
        let hasStudentVoice = model.speechSettings.hasQwenStudentReferenceVoice
        VStack(alignment: .leading, spacing: 14) {
            HStack(alignment: .center, spacing: 14) {
                VStack(alignment: .leading, spacing: 3) {
                    Text(SpeechSettingsCopy.useMyVoiceTitle)
                        .font(.headline)
                    Text(SpeechSettingsCopy.useMyVoiceSubtitle)
                        .font(.callout)
                        .foregroundStyle(.secondary)
                }

                Spacer(minLength: 16)

                Toggle(
                    SpeechSettingsCopy.useMyVoiceTitle,
                    isOn: Binding(
                        get: { model.speechSettings.qwenUseReferenceVoice },
                        set: { model.setQwenUseReferenceVoice($0) }
                    )
                )
                .labelsHidden()
                .toggleStyle(.switch)
                .controlSize(.large)
            }

            HStack(alignment: .center, spacing: 14) {
                Text("Reference Voice")
                    .font(.headline)
                    .frame(width: 140, alignment: .leading)

                if model.speechSettings.qwenUseReferenceVoice {
                    Picker(
                        "Reference Voice",
                        selection: Binding(
                            get: { model.speechSettings.qwenReferenceVoiceID },
                            set: { model.setQwenReferenceVoiceID($0) }
                        )
                    ) {
                        ForEach(model.speechSettings.availableQwenReferenceVoiceIDs) { voiceID in
                            Text(voiceID.title).tag(voiceID)
                        }
                    }
                    .labelsHidden()
                    .controlSize(.large)
                } else {
                    Text(hasStudentVoice ? "Voice cloning off" : "Crisp Study Voice available")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                }

                Spacer(minLength: 16)

                Text(referenceDetail)
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .frame(minWidth: 150, alignment: .leading)

                Button {
                    isCloneSheetPresented = true
                } label: {
                    Label("Clone Voice Now", systemImage: "mic.circle")
                        .frame(minWidth: 160)
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.large)
            }
        }
        .narrationSettingsBox(accent: SalientTheme.brass, verticalPadding: 14)
        .sheet(isPresented: $isCloneSheetPresented) {
            QwenVoiceCloneSheet()
                .environmentObject(model)
        }
    }

    private var referenceDetail: String {
        let voice = model.speechSettings.effectiveQwenReferenceVoice
        if voice.id == .studentClone,
            let duration = model.speechSettings.qwenStudentReferenceVoice?.durationSeconds,
            duration > 0
        {
            return "\(duration.formatted(.number.precision(.fractionLength(1)))) sec sample"
        }
        return model.speechSettings.engineID.qwenLane?.displayName ?? "Qwen"
    }
}

private struct QwenSetupPanel: View {
    @EnvironmentObject private var model: AppModel

    var body: some View {
        if let lane = model.speechSettings.engineID.qwenLane {
            let useReferenceVoice = model.speechSettings.qwenUseReferenceVoice
            let status = model.qwenRuntimeReport.status(for: lane, useReferenceVoice: useReferenceVoice)
            VStack(alignment: .leading, spacing: 14) {
                HStack(alignment: .top, spacing: 12) {
                    Image(systemName: iconName(for: status))
                        .foregroundStyle(color(for: status))
                        .frame(width: 22)

                    VStack(alignment: .leading, spacing: 4) {
                        Text(lane.setupDisplayName(useReferenceVoice: useReferenceVoice))
                            .font(.headline)
                        Text(statusText(for: status, lane: lane, useReferenceVoice: useReferenceVoice))
                            .font(.callout)
                            .foregroundStyle(.secondary)
                            .textSelection(.enabled)
                            .lineLimit(3)
                    }

                    Spacer()
                }

                if let progress = model.qwenInstallProgress, progress.lane == lane {
                    ProgressView(value: progress.fractionCompleted ?? 0)
                    Text(progress.stage)
                        .font(.callout)
                        .foregroundStyle(.secondary)
                }

                HStack(spacing: 12) {
                    if status != .ready {
                        Button {
                            model.installQwen(lane)
                        } label: {
                            Label(
                                status == .failed ? "Retry Setup" : installButtonTitle(useReferenceVoice: useReferenceVoice),
                                systemImage: "arrow.down.circle"
                            )
                            .frame(minWidth: 150)
                        }
                        .buttonStyle(.borderedProminent)
                        .controlSize(.large)
                        .disabled(model.qwenInstallProgress?.lane == lane)
                    }

                    if model.qwenInstallProgress?.lane == lane {
                        Button {
                            model.cancelQwenInstall()
                        } label: {
                            Label("Cancel", systemImage: "xmark.circle")
                                .frame(minWidth: 100)
                        }
                        .buttonStyle(.bordered)
                        .controlSize(.large)
                    }
                }
            }
            .narrationSettingsBox(accent: SalientTheme.brass, verticalPadding: 14)
        }
    }

    private func installButtonTitle(useReferenceVoice: Bool) -> String {
        useReferenceVoice ? "Install Cloning" : "Install Qwen"
    }

    private func statusText(for status: QwenRuntimeStatusKind, lane: QwenModelLane, useReferenceVoice: Bool) -> String {
        switch status {
        case .ready:
            "\(lane.modelID(useReferenceVoice: useReferenceVoice)) is installed in the managed local runtime."
        case .needsSetup:
            "Downloads \(lane.approximateDownloadSize(useReferenceVoice: useReferenceVoice)) plus a managed Python/MLX Audio runtime into Application Support. Study text stays local."
        case .installing:
            "Setup is running in the background."
        case .failed:
            model.qwenRuntimeReport.lastError ?? "Setup failed. Logs are available for troubleshooting."
        }
    }

    private func iconName(for status: QwenRuntimeStatusKind) -> String {
        switch status {
        case .ready: "checkmark.circle.fill"
        case .needsSetup: "arrow.down.circle.fill"
        case .installing: "hourglass.circle.fill"
        case .failed: "xmark.octagon.fill"
        }
    }

    private func color(for status: QwenRuntimeStatusKind) -> Color {
        switch status {
        case .ready: .green
        case .needsSetup: .orange
        case .installing: .blue
        case .failed: .red
        }
    }
}

private struct VoicePickerRow: View {
    @EnvironmentObject private var model: AppModel

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 14) {
                Text("Voice")
                    .font(.headline)
                    .frame(width: 140, alignment: .leading)
                AppleSpeechVoicePicker()
                    .controlSize(.large)
            }
            HStack {
                Button("Download Apple voices…") { model.openAppleVoiceSettings() }
                Button("Refresh voices") { model.refreshSpeechVoices() }
            }
            Text("In Accessibility, open Read & Speak → System voice. Downloaded voices appear here automatically; availability varies by Mac and language.")
                .font(.caption).foregroundStyle(.secondary)
        }
        .narrationSettingsBox(accent: SalientTheme.coral)
    }
}

struct AppleSpeechVoicePicker: View {
    @EnvironmentObject private var model: AppModel

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Picker(
                "Voice",
                selection: Binding(
                    get: { model.speechSettings.voiceIdentifier },
                    set: { model.setSpeechVoiceIdentifier($0) }
                )
            ) {
                Text("Default Apple Voice").tag(Optional<String>.none)
                if model.selectedAppleVoiceIsUnavailable {
                    Text("Selected voice unavailable").tag(model.speechSettings.voiceIdentifier)
                }
                ForEach(model.availableSpeechVoices) { voice in
                    Text(voice.displayName)
                        .tag(Optional(voice.identifier))
                }
            }
            .labelsHidden()
            .accessibilityLabel("Apple voice")
            if model.selectedAppleVoiceIsUnavailable {
                Text("Using the default voice until your selected voice is available again.")
                    .font(.caption).foregroundStyle(.secondary)
            }
        }
    }
}

private struct NarrationResetPanel: View {
    @EnvironmentObject private var model: AppModel
    @State private var isResetConfirmationPresented = false

    var body: some View {
        GlassPanel(accent: SalientTheme.coral, padding: 14, isElevated: false) {
            HStack(alignment: .center, spacing: 14) {
                VStack(alignment: .leading, spacing: 3) {
                    Text("Restore narration defaults")
                        .font(.headline)
                    Text("Test Voice and Stop Playback remain available in the window toolbar.")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                }

                Spacer(minLength: 16)

                Button(role: .destructive) {
                    isResetConfirmationPresented = true
                } label: {
                    Label("Reset", systemImage: "arrow.counterclockwise")
                        .frame(minWidth: 100)
                }
                .buttonStyle(.bordered)
                .controlSize(.large)
            }
        }
        .confirmationDialog("Reset narration settings?", isPresented: $isResetConfirmationPresented) {
            Button(role: .destructive) {
                model.resetSpeechSettings()
            } label: {
                Text("Reset Narration Settings")
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("This restores the local narrator, narration speed, volume, and Qwen voice preferences to their defaults.")
        }
    }
}
