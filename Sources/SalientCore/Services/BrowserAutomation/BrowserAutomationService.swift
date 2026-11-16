import Foundation

public enum BrowserAutomationResult: Equatable, Sendable {
    case success(String)
    case failure(String)
}

@MainActor
public protocol BrowserAutomationService: AnyObject {
    func executeJavaScriptInUWorldTab(_ javaScript: String) async -> BrowserAutomationResult
}
