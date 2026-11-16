import Foundation

public enum StudyBrowser: String, CaseIterable, Codable, Identifiable, Sendable {
    case safari
    case chrome

    public var id: String { rawValue }
    public var title: String { self == .safari ? "Safari" : "Chrome" }
    public var applicationName: String { self == .safari ? "Safari" : "Google Chrome" }
    public var bundleIdentifier: String { self == .safari ? "com.apple.Safari" : "com.google.Chrome" }
    public var javaScriptSetup: String {
        switch self {
        case .safari:
            "In Safari Settings → Advanced, enable web developer features. Then choose Develop → Allow JavaScript from Apple Events."
        case .chrome:
            "In Chrome’s menu bar, choose View → Developer → Allow JavaScript from Apple Events."
        }
    }
}

/// Shared by capture, highlighting and navigation. Changing this
/// preference never searches for a tab or silently falls back to another browser.
@MainActor public final class StudyBrowserSession {
    public var browser: StudyBrowser
    public init(browser: StudyBrowser = .safari) { self.browser = browser }
}
