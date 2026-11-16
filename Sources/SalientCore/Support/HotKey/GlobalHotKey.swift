@preconcurrency import Carbon.HIToolbox
import Foundation

public final class GlobalHotKey {
    public enum HotKeyError: Error, LocalizedError {
        case installFailed(OSStatus)
        case registerFailed(OSStatus)

        public var errorDescription: String? {
            switch self {
            case .installFailed(let status):
                "Could not install hotkey handler (\(status))."
            case .registerFailed(let status):
                if status == -9878 {
                    "Could not register hotkey because it is already used by macOS or another app."
                } else {
                    "Could not register hotkey (\(status))."
                }
            }
        }
    }

    private let keyCode: UInt32
    private let modifiers: UInt32
    private let identifier: UInt32
    private let action: () -> Void
    private var hotKeyRef: EventHotKeyRef?
    private var handlerRef: EventHandlerRef?

    public init(id: UInt32 = 1, keyCode: UInt32, modifiers: UInt32, action: @escaping () -> Void) {
        self.identifier = id
        self.keyCode = keyCode
        self.modifiers = modifiers
        self.action = action
    }

    deinit {
        unregister()
    }

    public static func submitHotKey(action: @escaping () -> Void) -> GlobalHotKey {
        GlobalHotKey(
            id: StudyShortcutAction.submit.hotKeyID,
            keyCode: UInt32(kVK_Return),
            modifiers: UInt32(cmdKey | shiftKey),
            action: action
        )
    }

    public func register() throws {
        unregister()

        var eventType = EventTypeSpec(
            eventClass: OSType(kEventClassKeyboard),
            eventKind: OSType(kEventHotKeyPressed)
        )

        let installStatus = InstallEventHandler(
            GetApplicationEventTarget(),
            { _, event, userData in
                guard let event, let userData else { return OSStatus(eventNotHandledErr) }
                let hotKey = Unmanaged<GlobalHotKey>.fromOpaque(userData).takeUnretainedValue()

                var eventHotKeyID = EventHotKeyID()
                let parameterStatus = GetEventParameter(
                    event,
                    EventParamName(kEventParamDirectObject),
                    EventParamType(typeEventHotKeyID),
                    nil,
                    MemoryLayout<EventHotKeyID>.size,
                    nil,
                    &eventHotKeyID
                )
                guard parameterStatus == noErr else { return parameterStatus }
                guard eventHotKeyID.signature == fourCharCode("MSUT"),
                      eventHotKeyID.id == hotKey.identifier else {
                    return OSStatus(eventNotHandledErr)
                }

                hotKey.action()
                return noErr
            },
            1,
            &eventType,
            Unmanaged.passUnretained(self).toOpaque(),
            &handlerRef
        )
        guard installStatus == noErr else {
            throw HotKeyError.installFailed(installStatus)
        }

        let hotKeyID = EventHotKeyID(signature: fourCharCode("MSUT"), id: identifier)
        let registerStatus = RegisterEventHotKey(
            keyCode,
            modifiers,
            hotKeyID,
            GetApplicationEventTarget(),
            UInt32(kEventHotKeyExclusive),
            &hotKeyRef
        )
        guard registerStatus == noErr else {
            unregister()
            throw HotKeyError.registerFailed(registerStatus)
        }
    }

    public func unregister() {
        if let hotKeyRef {
            UnregisterEventHotKey(hotKeyRef)
            self.hotKeyRef = nil
        }
        if let handlerRef {
            RemoveEventHandler(handlerRef)
            self.handlerRef = nil
        }
    }
}

private func fourCharCode(_ string: String) -> OSType {
    string.utf8.reduce(0) { result, character in
        (result << 8) + OSType(character)
    }
}
