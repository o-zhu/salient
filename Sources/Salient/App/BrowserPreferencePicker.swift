import SalientCore
import SwiftUI

struct BrowserPreferencePicker: View {
    @EnvironmentObject private var model: AppModel
    var showsTargetHint = true

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Picker("Study browser", selection: Binding(
                get: { model.selectedBrowser }, set: { model.setStudyBrowser($0) }
            )) {
                ForEach(StudyBrowser.allCases) { browser in
                    Text(browser.title).tag(browser)
                }
            }
            .pickerStyle(.segmented)
            .frame(maxWidth: 320)
            .disabled(model.isBusy || model.isRequestingBrowserAccess)
            if showsTargetHint {
                Text("Uses only the front tab in \(model.selectedBrowser.title).")
                    .font(.caption).foregroundStyle(.secondary)
            }
        }
    }
}
