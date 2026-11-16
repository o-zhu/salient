import SalientCore
import AVFoundation
import SwiftUI

struct ContentView: View {
    @EnvironmentObject private var model: AppModel
    @Environment(\.openWindow) private var openWindow

    var body: some View {
        NavigationSplitView {
            List(selection: $model.selectedSection) {
                Section(AppSectionGroup.work.title) {
                    ForEach(AppSection.workSections) { section in
                        sidebarRow(section)
                    }
                }

                Section(AppSectionGroup.setup.title) {
                    ForEach(AppSection.setupSections) { section in
                        sidebarRow(section)
                    }
                }
            }
            .listStyle(.sidebar)
            .navigationSplitViewColumnWidth(min: 180, ideal: 210)
        } detail: {
            switch model.selectedSection {
            case .reading:
                ReadingWorkspaceView()
            case .keyboardShortcuts:
                KeyboardShortcutsView()
            case .speech:
                SpeechSettingsView()
            case .permissions:
                PermissionCenterView()
            }
        }
        .toolbarBackground(.hidden, for: .windowToolbar)
        .salientWindowToolbarTitleHidden()
        .toolbar {
            ToolbarItemGroup(placement: .primaryAction) {
                contextualToolbarItems
            }
        }
        .background(SalientBackground().ignoresSafeArea())
        .background(WindowTitleVisibilityAccessor(refreshToken: model.selectedSection.rawValue))
        .onAppear {
            let windowAction = openWindow
            model.openMainWindow = { windowAction(id: "main") }
            AppDelegate.reopenMainWindow = { [weak model = model] in model?.showMainWindow() }
            model.refreshSpeechVoices()
        }
        .onReceive(NotificationCenter.default.publisher(for: AVSpeechSynthesizer.availableVoicesDidChangeNotification).receive(on: RunLoop.main)) { _ in
            model.refreshSpeechVoices()
        }
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in
            model.refreshSpeechVoices()
        }
    }

    private func sidebarRow(_ section: AppSection) -> some View {
        Label(section.sidebarTitle, systemImage: section.systemImage)
            .tag(section)
    }

    @ViewBuilder
    private var contextualToolbarItems: some View {
        switch model.selectedSection {
        case .reading:
            EmptyView()

        case .keyboardShortcuts:
            Button {
                model.refreshReadiness()
            } label: {
                Label("Refresh", systemImage: "arrow.clockwise")
            }

        case .speech:
            Button {
                model.previewSpeech()
            } label: {
                Label("Test Voice", systemImage: "play.circle")
            }
            Button {
                model.run(.stopSpeech)
            } label: {
                Label("Stop", systemImage: "stop.circle")
            }

        case .permissions:
            Button {
                model.requestBrowserAutomationAccess()
            } label: {
                Label("Request Access", systemImage: "safari")
            }
            Button {
                model.refreshReadiness()
            } label: {
                Label("Refresh", systemImage: "arrow.clockwise")
            }
        }
    }
}

struct PermissionCenterView: View {
    @EnvironmentObject private var model: AppModel
    @State private var isResetConfirmationPresented = false

    var body: some View {
        PageScaffold(
            title: "Permissions",
            subtitle: "Set up the permissions for your chosen browser and study tools.",
            accent: SalientTheme.teal
        ) {
            SalientPageScrollView {
                VStack(alignment: .leading, spacing: SalientTheme.sectionSpacing) {
                    BrowserPreferencePicker()
                    if model.isRequestingBrowserAccess {
                        HStack {
                            ProgressView().controlSize(.small)
                            Text("Waiting for the macOS \(model.selectedBrowser.title) permission prompt… You can keep using the reader.")
                        }
                    } else if let error = model.lastError {
                        Label(error, systemImage: "exclamationmark.triangle")
                            .foregroundStyle(.secondary)
                    }
                    VStack(spacing: SalientTheme.cardSpacing) {
                        ForEach(model.permissionReport.items) { item in
                            ReadinessRow(item: item) {
                                handleAction(for: item)
                            }
                        }
                    }

                    ViewThatFits(in: .horizontal) {
                        HStack(spacing: 10) { permissionActions }
                        VStack(alignment: .leading, spacing: 10) { permissionActions }
                    }
                }
                .confirmationDialog("Reset browser automation permissions?", isPresented: $isResetConfirmationPresented) {
                    Button("Reset Automation Permission", role: .destructive) {
                        model.resetBrowserAutomationPermission()
                    }
                    Button("Cancel", role: .cancel) {}
                } message: {
                    Text("macOS will ask for browser automation access again the next time \(AppModel.displayName) reads or controls a study tab.")
                }
            }
        }
    }

    @ViewBuilder
    private var permissionActions: some View {
        Button {
            model.requestBrowserAutomationAccess()
        } label: {
            Label("Connect \(model.selectedBrowser.title)", systemImage: "safari")
        }
        .buttonStyle(.borderedProminent)
        .tint(SalientTheme.teal)

        Button {
            model.refreshReadiness()
        } label: {
            Label("Refresh", systemImage: "arrow.clockwise")
        }
        .buttonStyle(.bordered)

        Button {
            model.openAutomationSettings()
        } label: {
            Label("Open System Settings", systemImage: "gear")
        }
        .buttonStyle(.bordered)

        Button {
            model.showCurrentAppInFinder()
        } label: {
            Label("Show App", systemImage: "app.dashed")
        }
        .buttonStyle(.bordered)

        Button(role: .destructive) {
            isResetConfirmationPresented = true
        } label: {
            Label("Reset Automation", systemImage: "arrow.counterclockwise")
        }
        .buttonStyle(.bordered)
    }

    private func handleAction(for item: ReadinessItem) {
        switch item.id {
        case "safari-automation":
            model.requestBrowserAutomationAccess()
        case "safari-javascript-events":
            model.openStudyBrowser()
        default:
            break
        }
    }
}

struct ReadinessRow: View {
    var item: ReadinessItem
    var action: () -> Void

    var body: some View {
        GlassPanel(accent: iconColor, padding: 16, isElevated: false) {
            HStack(alignment: .top, spacing: 12) {
                Image(systemName: iconName)
                    .foregroundStyle(iconColor)
                    .frame(width: 22)
                    .padding(.top, 1)

                VStack(alignment: .leading, spacing: 5) {
                    HStack(spacing: 8) {
                        Text(item.title)
                            .font(.headline)
                        StatusPill(item.state.label, tint: iconColor)
                    }
                    Text(item.detail)
                        .font(.callout)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                    if item.state != .available, let recoveryHint {
                        Text(recoveryHint)
                            .font(.caption)
                            .foregroundStyle(iconColor)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }

                Spacer(minLength: 12)

                if let title = item.primaryActionTitle {
                    Button(title) {
                        action()
                    }
                    .buttonStyle(.bordered)
                }
            }
        }
    }

    private var iconName: String {
        switch item.state {
        case .available: "checkmark.circle.fill"
        case .needsSetup: "exclamationmark.triangle.fill"
        case .installing: "arrow.down.circle.fill"
        case .failed: "xmark.octagon.fill"
        case .optional: "circle.dashed"
        case .unavailable: "xmark.circle.fill"
        }
    }

    private var iconColor: Color {
        switch item.state {
        case .available: .green
        case .needsSetup: .orange
        case .installing: .blue
        case .failed: .red
        case .optional: .secondary
        case .unavailable: .red
        }
    }

    private var recoveryHint: String? {
        switch item.state {
        case .available:
            nil
        case .needsSetup:
            item.primaryActionTitle.map { "Next: \($0)." }
        case .installing:
            "Setup is running. Refresh after it finishes."
        case .failed:
            item.primaryActionTitle.map { "Try \($0), then refresh readiness." } ?? "Refresh after resolving this item."
        case .optional:
            nil
        case .unavailable:
            "This dependency is unavailable on the current system."
        }
    }
}
