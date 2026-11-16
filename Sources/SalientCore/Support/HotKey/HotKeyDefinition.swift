@preconcurrency import Carbon.HIToolbox
import Foundation

public enum StudyShortcutAction: String, CaseIterable, Codable, Identifiable, Sendable {
    case readQuestion
    case readExplanation
    case submit
    case stopPlayback
    case nextQuestionAndRead

    public var id: String { rawValue }

    public var title: String {
        switch self {
        case .readQuestion: "Read Question"
        case .readExplanation: "Read Explanation"
        case .submit: "Submit"
        case .stopPlayback: "Stop Playback"
        case .nextQuestionAndRead: "Next + Read"
        }
    }

    public var studyAction: StudyAction {
        switch self {
        case .readQuestion: .readQuestion
        case .readExplanation: .readExplanation
        case .submit: .submit
        case .stopPlayback: .stopSpeech
        case .nextQuestionAndRead: .nextQuestionAndRead
        }
    }

    public var defaultShortcut: HotKeyDefinition {
        switch self {
        case .readQuestion:
            HotKeyDefinition(keyCode: UInt32(kVK_ANSI_R), modifiers: HotKeyDefinition.commandOption, isEnabled: false)
        case .readExplanation:
            HotKeyDefinition(keyCode: UInt32(kVK_ANSI_E), modifiers: HotKeyDefinition.commandOption, isEnabled: false)
        case .submit:
            HotKeyDefinition(keyCode: UInt32(kVK_Return), modifiers: HotKeyDefinition.commandShift, isEnabled: false)
        case .stopPlayback:
            HotKeyDefinition(keyCode: UInt32(kVK_ANSI_Period), modifiers: HotKeyDefinition.commandOption, isEnabled: false)
        case .nextQuestionAndRead:
            HotKeyDefinition(keyCode: UInt32(kVK_RightArrow), modifiers: HotKeyDefinition.commandOption, isEnabled: false)
        }
    }

    public var hotKeyID: UInt32 {
        switch self {
        case .readQuestion: 11
        case .readExplanation: 12
        case .submit: 13
        case .stopPlayback: 14
        case .nextQuestionAndRead: 15
        }
    }
}

public struct HotKeyDefinition: Codable, Equatable, Sendable {
    public static let command = UInt32(cmdKey)
    public static let shift = UInt32(shiftKey)
    public static let option = UInt32(optionKey)
    public static let control = UInt32(controlKey)
    private static let appKitCommand: UInt32 = 1 << 20
    private static let appKitOption: UInt32 = 1 << 19
    private static let appKitControl: UInt32 = 1 << 18

    public static let commandShift = command | shift
    public static let commandOption = command | option

    public var effectiveModifiers: UInt32 {
        var normalized = modifiers
        if modifiers & Self.appKitCommand != 0 { normalized |= Self.command }
        if modifiers & Self.appKitOption != 0 { normalized |= Self.option }
        if modifiers & Self.appKitControl != 0 { normalized |= Self.control }
        return normalized
    }

    public var keyCode: UInt32
    public var modifiers: UInt32
    public var isEnabled: Bool

    public init(keyCode: UInt32, modifiers: UInt32, isEnabled: Bool) {
        self.keyCode = keyCode
        self.modifiers = modifiers
        self.isEnabled = isEnabled
    }

    public var displayString: String {
        let prefix = modifierDisplayString(for: effectiveModifiers)
        let key = Self.keyName(for: keyCode)
        return prefix.isEmpty ? key : prefix + key
    }

    public var isUsableGlobalShortcut: Bool {
        effectiveModifiers & (Self.command | Self.option | Self.control) != 0
    }

    private func modifierDisplayString(for modifiers: UInt32) -> String {
        var value = ""
        if modifiers & Self.control != 0 { value += "⌃" }
        if modifiers & Self.option != 0 { value += "⌥" }
        if modifiers & Self.shift != 0 { value += "⇧" }
        if modifiers & Self.command != 0 { value += "⌘" }
        return value
    }

    private static func keyName(for keyCode: UInt32) -> String {
        keyNames[keyCode] ?? "Key \(keyCode)"
    }

    private static let keyNames: [UInt32: String] = [
        UInt32(kVK_ANSI_A): "A",
        UInt32(kVK_ANSI_B): "B",
        UInt32(kVK_ANSI_C): "C",
        UInt32(kVK_ANSI_D): "D",
        UInt32(kVK_ANSI_E): "E",
        UInt32(kVK_ANSI_F): "F",
        UInt32(kVK_ANSI_G): "G",
        UInt32(kVK_ANSI_H): "H",
        UInt32(kVK_ANSI_I): "I",
        UInt32(kVK_ANSI_J): "J",
        UInt32(kVK_ANSI_K): "K",
        UInt32(kVK_ANSI_L): "L",
        UInt32(kVK_ANSI_M): "M",
        UInt32(kVK_ANSI_N): "N",
        UInt32(kVK_ANSI_O): "O",
        UInt32(kVK_ANSI_P): "P",
        UInt32(kVK_ANSI_Q): "Q",
        UInt32(kVK_ANSI_R): "R",
        UInt32(kVK_ANSI_S): "S",
        UInt32(kVK_ANSI_T): "T",
        UInt32(kVK_ANSI_U): "U",
        UInt32(kVK_ANSI_V): "V",
        UInt32(kVK_ANSI_W): "W",
        UInt32(kVK_ANSI_X): "X",
        UInt32(kVK_ANSI_Y): "Y",
        UInt32(kVK_ANSI_Z): "Z",
        UInt32(kVK_ANSI_0): "0",
        UInt32(kVK_ANSI_1): "1",
        UInt32(kVK_ANSI_2): "2",
        UInt32(kVK_ANSI_3): "3",
        UInt32(kVK_ANSI_4): "4",
        UInt32(kVK_ANSI_5): "5",
        UInt32(kVK_ANSI_6): "6",
        UInt32(kVK_ANSI_7): "7",
        UInt32(kVK_ANSI_8): "8",
        UInt32(kVK_ANSI_9): "9",
        UInt32(kVK_ANSI_Minus): "-",
        UInt32(kVK_ANSI_Equal): "=",
        UInt32(kVK_ANSI_LeftBracket): "[",
        UInt32(kVK_ANSI_RightBracket): "]",
        UInt32(kVK_ANSI_Backslash): "\\",
        UInt32(kVK_ANSI_Semicolon): ";",
        UInt32(kVK_ANSI_Quote): "'",
        UInt32(kVK_ANSI_Comma): ",",
        UInt32(kVK_ANSI_Period): ".",
        UInt32(kVK_ANSI_Slash): "/",
        UInt32(kVK_ANSI_Grave): "`",
        UInt32(kVK_Return): "Return",
        UInt32(kVK_Tab): "Tab",
        UInt32(kVK_Space): "Space",
        UInt32(kVK_Delete): "Delete",
        UInt32(kVK_Escape): "Esc",
        UInt32(kVK_LeftArrow): "←",
        UInt32(kVK_RightArrow): "→",
        UInt32(kVK_DownArrow): "↓",
        UInt32(kVK_UpArrow): "↑"
    ]
}
