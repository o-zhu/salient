import Foundation

enum AppSectionGroup: String, CaseIterable, Identifiable {
    case work
    case setup

    var id: String { rawValue }

    var title: String {
        switch self {
        case .work: "Work"
        case .setup: "Setup"
        }
    }

}

enum AppSection: String, CaseIterable, Identifiable {
    case reading
    case keyboardShortcuts
    case speech
    case permissions

    var id: String { rawValue }

    static var workSections: [AppSection] {
        allCases.filter { $0.group == .work }
    }

    static var setupSections: [AppSection] {
        allCases.filter { $0.group == .setup }
    }

    var group: AppSectionGroup {
        switch self {
        case .reading:
            .work
        case .keyboardShortcuts, .speech, .permissions:
            .setup
        }
    }

    var title: String {
        switch self {
        case .reading: "Read"
        case .keyboardShortcuts: "Keyboard Shortcuts"
        case .speech: "Narration Settings"
        case .permissions: "Permissions"
        }
    }

    var sidebarTitle: String {
        switch self {
        case .keyboardShortcuts: "Shortcuts"
        case .speech: "Narration"
        default: title
        }
    }

    var systemImage: String {
        switch self {
        case .reading: "text.book.closed"
        case .keyboardShortcuts: "keyboard"
        case .speech: "speaker.wave.2"
        case .permissions: "lock.shield"
        }
    }
}
