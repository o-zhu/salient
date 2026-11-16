import AppKit
import SalientCore
import SwiftUI

@MainActor
public final class AppDelegate: NSObject, NSApplicationDelegate {
    static var reopenMainWindow: (@MainActor () -> Void)?

    public func applicationDidFinishLaunching(_ notification: Notification) {
        ProcessInfo.processInfo.disableAutomaticTermination(
            "Salient remains available through its menu bar controls."
        )
        NSApp.setActivationPolicy(.regular)
        NSApp.activate(ignoringOtherApps: true)
    }

    public func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        false
    }

    public func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        guard let reopenMainWindow = Self.reopenMainWindow else { return true }
        // A floating reader or Settings window can be visible while the main
        // window is closed. A Dock/Finder reopen should still restore it.
        reopenMainWindow()
        return false
    }
}

public struct SalientScene: Scene {
    @StateObject private var model: AppModel
    private let launchConfiguration: AppLaunchConfiguration

    public init() {
        if CommandLine.arguments.contains("--pocket-bundle-check") {
            PocketBundleCheck.runAndExit(playback: CommandLine.arguments.contains("--play-pocket-bundle-check"))
        }
        if CommandLine.arguments.contains("--self-check") {
            Foundation.exit(SelfCheck.run())
        }
        let launchConfiguration = AppLaunchConfiguration.parse()
        self.launchConfiguration = launchConfiguration
        _model = StateObject(wrappedValue: AppModel(launchConfiguration: launchConfiguration))
    }

    public var body: some Scene {
        Window(AppModel.displayName, id: "main") {
            ContentView()
                .environmentObject(model)
                .fixtureColorScheme(launchConfiguration.preferredColorScheme)
                .environment(\.salientIncreasedContrast, launchConfiguration.usesIncreasedContrast)
                .background(
                    ZStack {
                        PlaybackHUDPresenter()
                            .environmentObject(model)
                        RSVPReaderPresenter()
                            .environmentObject(model)
                    }
                )
        }
        .commands {
            CommandMenu("UWorld Study") {
                Button("Read Question") { model.run(.readQuestion) }
                    .disabled(model.isBusy)
                Button("Read Explanation") { model.run(.readExplanation) }
                    .disabled(model.isBusy)
                Button("Next + Read") { model.run(.nextQuestionAndRead) }
                    .disabled(model.isBusy)
                Button("Submit") { model.run(.submit) }
                    .disabled(model.isBusy)
                Button("Stop Playback") { model.run(.stopSpeech) }
                Divider()
                Button("Open UWorld Login") { model.openUWorldLogin() }
            }
        }
        .defaultSize(width: 940, height: 740)

        Settings {
            SettingsView()
                .environmentObject(model)
                .fixtureColorScheme(launchConfiguration.preferredColorScheme)
                .environment(\.salientIncreasedContrast, launchConfiguration.usesIncreasedContrast)
        }

        MenuBarExtra(AppModel.displayName, systemImage: "waveform") {
            MenuBarView()
                .environmentObject(model)
                .fixtureColorScheme(launchConfiguration.preferredColorScheme)
                .environment(\.salientIncreasedContrast, launchConfiguration.usesIncreasedContrast)
        }
    }
}

extension AppLaunchConfiguration {
    fileprivate var preferredColorScheme: ColorScheme? {
        switch uiAppearance {
        case .light: .light
        case .dark: .dark
        case nil: nil
        }
    }

}

extension View {
    @ViewBuilder
    fileprivate func fixtureColorScheme(_ colorScheme: ColorScheme?) -> some View {
        if let colorScheme {
            environment(\.colorScheme, colorScheme)
        } else {
            self
        }
    }
}
