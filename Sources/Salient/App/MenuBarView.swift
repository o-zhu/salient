import AppKit
import SalientCore
import SwiftUI

struct MenuBarView: View {
    @EnvironmentObject private var model: AppModel

    var body: some View {
        Button("Open \(AppModel.displayName)") { model.showMainWindow() }
        Divider()
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
        Button("Read Text") { model.showMainWindow(section: .reading) }
        Button("Keyboard Shortcuts") { model.showMainWindow(section: .keyboardShortcuts) }
        Button("Narration Settings") { model.showMainWindow(section: .speech) }
        Button("Permissions") { model.showMainWindow(section: .permissions) }
        Divider()
        Button("Quit \(AppModel.displayName)") { NSApplication.shared.terminate(nil) }
        Text(shortStatus)
            .foregroundStyle(.secondary)
    }

    private var shortStatus: String {
        let trimmed = model.statusMessage.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.count > 32 else { return trimmed }
        return "\(trimmed.prefix(29))..."
    }
}
