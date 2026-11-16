@preconcurrency import Carbon.HIToolbox
import AppKit
import SalientCore
import SwiftUI

struct KeyboardShortcutRecorder: NSViewRepresentable {
    var shortcut: HotKeyDefinition
    var onRecord: (HotKeyDefinition) -> Void

    func makeNSView(context: Context) -> RecorderButton {
        let button = RecorderButton()
        button.onRecord = onRecord
        button.shortcut = shortcut
        return button
    }

    func updateNSView(_ nsView: RecorderButton, context: Context) {
        nsView.onRecord = onRecord
        nsView.shortcut = shortcut
    }
}

final class RecorderButton: NSButton {
    var onRecord: ((HotKeyDefinition) -> Void)?
    var shortcut: HotKeyDefinition = StudyShortcutAction.submit.defaultShortcut {
        didSet { updateTitle() }
    }

    private var isRecordingShortcut = false {
        didSet { updateTitle() }
    }

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        bezelStyle = .rounded
        setButtonType(.momentaryPushIn)
        target = self
        action = #selector(beginRecording)
        font = .monospacedSystemFont(ofSize: NSFont.systemFontSize, weight: .medium)
        alignment = .center
        translatesAutoresizingMaskIntoConstraints = false
        widthAnchor.constraint(greaterThanOrEqualToConstant: 132).isActive = true
        updateTitle()
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override var acceptsFirstResponder: Bool { true }

    @objc private func beginRecording() {
        isRecordingShortcut = true
        window?.makeFirstResponder(self)
    }

    override func keyDown(with event: NSEvent) {
        if event.keyCode == UInt16(kVK_Escape) {
            isRecordingShortcut = false
            window?.makeFirstResponder(nil)
            return
        }

        let modifiers = carbonModifiers(from: event.modifierFlags)
        guard modifiers & (HotKeyDefinition.command | HotKeyDefinition.option | HotKeyDefinition.control) != 0 else {
            NSSound.beep()
            return
        }

        isRecordingShortcut = false
        window?.makeFirstResponder(nil)
        onRecord?(HotKeyDefinition(keyCode: UInt32(event.keyCode), modifiers: modifiers, isEnabled: true))
    }

    override func resignFirstResponder() -> Bool {
        isRecordingShortcut = false
        return super.resignFirstResponder()
    }

    private func updateTitle() {
        title = isRecordingShortcut ? "Press shortcut..." : shortcut.displayString
    }

    private func carbonModifiers(from flags: NSEvent.ModifierFlags) -> UInt32 {
        var modifiers: UInt32 = 0
        if flags.contains(.command) { modifiers |= HotKeyDefinition.command }
        if flags.contains(.shift) { modifiers |= HotKeyDefinition.shift }
        if flags.contains(.option) { modifiers |= HotKeyDefinition.option }
        if flags.contains(.control) { modifiers |= HotKeyDefinition.control }
        return modifiers
    }
}
