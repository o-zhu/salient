import Foundation

public final class AppleEventBrowserAutomationService: BrowserAutomationService {
    private let runner: any AsyncProcessRunning
    private let session: StudyBrowserSession

    public init(runner: any AsyncProcessRunning = AsyncProcessRunner(), session: StudyBrowserSession = StudyBrowserSession()) {
        self.runner = runner
        self.session = session
    }

    public func executeJavaScriptInUWorldTab(_ javaScript: String) async -> BrowserAutomationResult {
        let browser = session.browser
        do {
            try Task.checkCancellation()
            let result = try await runner.run(AsyncProcessRequest(
                executableURL: URL(fileURLWithPath: "/usr/bin/osascript"),
                arguments: ["-l", "AppleScript", "-"],
                standardInput: Data(Self.activeTabAppleScript(for: javaScript, browser: browser).utf8),
                timeoutSeconds: 12,
                maximumRetainedOutputBytes: 4_194_304,
                redactedDescription: "\(browser.title) action"
            ))
            try Task.checkCancellation()
            guard result.exitCode == 0 else {
                let message = String(decoding: result.stderr, as: UTF8.self)
                return .failure(SafariAutomationErrorInterpreter.userMessage(errorNumber: nil, rawMessage: message, browser: browser))
            }
            let output = String(decoding: result.stdout, as: UTF8.self).trimmingCharacters(in: .newlines)
            // Safari may turn a JavaScript guard exception into an empty, successful
            // Apple Event response. Keep it a failure with useful recovery copy.
            guard !output.isEmpty else {
                return .failure("\(browser.title) returned no readable response. Select your UWorld tab or Salient practice page, then try again.")
            }
            return .success(output)
        } catch is CancellationError {
            return .failure("\(browser.title) action cancelled.")
        } catch {
            return .failure("\(browser.title) did not respond. Bring your study tab to the front, check \(browser.title) Automation in Permissions, and try again.")
        }
    }

    public static func activeTabAppleScript(for javaScript: String, browser: StudyBrowser = .safari) -> String {
        let guarded = guardedJavaScript(javaScript, browser: browser)
        let command = browser == .safari
            ? "set targetTab to current tab of front window\n    return do JavaScript jsCode in targetTab"
            : "set targetTab to active tab of front window\n    return execute targetTab javascript jsCode"
        return """
        set jsCode to \(appleScriptStringLiteral(guarded))
        with timeout of 10 seconds
          tell application "\(browser.applicationName)"
            if (count of windows) is 0 then error "Open your study tab in \(browser.title) first."
            \(command)
          end tell
        end timeout
        """
    }

    static func guardedJavaScript(_ javaScript: String, browser: StudyBrowser = .safari) -> String {
        let fixture = FixtureProvider.syntheticFixtureURL?.absoluteString ?? ""
        let fixtureLiteral = String(decoding: try! JSONEncoder().encode(fixture), as: UTF8.self)
        return """
        (function () {
          const page = new URL(window.location.href);
          const isStudy = page.protocol === 'https:' &&
            (page.hostname === 'uworld.com' || page.hostname.endsWith('.uworld.com'));
          const isPractice = page.href === \(fixtureLiteral);
          if ((!isStudy && !isPractice) || document.visibilityState !== 'visible') {
            throw new Error('Select your UWorld tab or Salient practice page in \(browser.title), then try again.');
          }
          return \(javaScript);
        })()
        """
    }

    private static func appleScriptStringLiteral(_ value: String) -> String {
        "\"" + value
            .replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "\"", with: "\\\"")
            .replacingOccurrences(of: "\r", with: "\\r")
            .replacingOccurrences(of: "\n", with: "\\n") + "\""
    }
}

/// Source compatibility for existing callers; new code uses the browser-neutral name.
public typealias SafariAutomationService = AppleEventBrowserAutomationService
