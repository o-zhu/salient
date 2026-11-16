import AppKit
import SwiftUI

extension View {
    @ViewBuilder
    func salientWindowToolbarTitleHidden() -> some View {
        if #available(macOS 15, *) {
            toolbar(removing: .title)
        } else {
            self
        }
    }
}

struct WindowTitleVisibilityAccessor: NSViewRepresentable {
    var refreshToken: String

    func makeNSView(context: Context) -> NSView {
        let view = NSView(frame: .zero)
        scheduleHideTitle(for: view)
        return view
    }

    func updateNSView(_ nsView: NSView, context: Context) {
        _ = refreshToken
        scheduleHideTitle(for: nsView)
    }

    private func scheduleHideTitle(for view: NSView) {
        DispatchQueue.main.async {
            hideTitle(for: view)
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.15) {
            hideTitle(for: view)
        }
    }

    private func hideTitle(for view: NSView) {
        guard let window = view.window else { return }
        window.titleVisibility = .hidden
        window.titlebarAppearsTransparent = true
        window.titlebarSeparatorStyle = .none
        window.styleMask.insert(.fullSizeContentView)
        window.backgroundColor = .clear
    }
}
