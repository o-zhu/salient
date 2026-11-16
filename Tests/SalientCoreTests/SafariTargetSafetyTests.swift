import Foundation
import JavaScriptCore
import XCTest
@testable import SalientCore

@MainActor final class SafariTargetSafetyTests: XCTestCase {
    func testGuardRejectsLookalikeUnrelatedFileAndHiddenPagesBeforeRunningAction() throws {
        for (url, visibility, permitted) in [
            ("https://apps.uworld.com/courseapp/usmle/v1/", "visible", true),
            ("https://uworld.com/", "visible", true),
            ("https://uworld.com.attacker.example/", "visible", false),
            ("https://example.com/?uworld", "visible", false),
            ("file:///tmp/two-pane.html", "visible", false),
            ("https://apps.uworld.com/", "hidden", false),
            (try XCTUnwrap(FixtureProvider.syntheticFixtureURL).absoluteString, "visible", true)
        ] {
            let context = try XCTUnwrap(JSContext())
            // JavaScriptCore has no browser URL class. Supply properties parsed by Foundation.
            let parsed = try XCTUnwrap(URL(string: url))
            let fixture: [String: String] = ["href": url, "protocol": (parsed.scheme ?? "") + ":", "hostname": parsed.host ?? ""]
            let json = String(decoding: try JSONEncoder().encode(fixture), as: UTF8.self)
            context.evaluateScript("var calls = 0; var window = {location: \(json)}; var document = {visibilityState: '\(visibility)'}; function URL() { return window.location; }")
            context.evaluateScript(SafariAutomationService.guardedJavaScript("(function(){ calls++; return 'clicked'; })()"))
            XCTAssertEqual(context.objectForKeyedSubscript("calls").toInt32(), permitted ? 1 : 0, url)
            XCTAssertEqual(context.exception == nil, permitted, url)
        }
    }

    func testScriptCompilesWithoutSearchingOrActivatingBackgroundTabs() throws {
        let source = SafariAutomationService.activeTabAppleScript(for: "'safe'")
        XCTAssertTrue(source.contains("current tab of front window"))
        XCTAssertFalse(source.contains("repeat with"))
        XCTAssertFalse(source.contains("activate"))
        var error: NSDictionary?
        XCTAssertTrue(try XCTUnwrap(NSAppleScript(source: source)).compileAndReturnError(&error), "\(String(describing: error))")
    }

    func testRunnerReceivesCancellableBoundedRequestWithoutPageTextInArguments() async {
        let runner = SafariRequestRecorder()
        let service = SafariAutomationService(runner: runner)
        let result = await service.executeJavaScriptInUWorldTab("'synthetic secret'")
        XCTAssertEqual(result, .success("clicked"))
        let request = await runner.lastRequest
        XCTAssertEqual(request?.timeoutSeconds, 12)
        XCTAssertFalse(request?.arguments.joined().contains("synthetic secret") ?? true)
        XCTAssertTrue(String(decoding: request?.standardInput ?? Data(), as: UTF8.self).contains("synthetic secret"))
    }

    func testChromeUsesOnlyActiveFrontTabAndCompiles() throws {
        let source = AppleEventBrowserAutomationService.activeTabAppleScript(for: "'safe'", browser: .chrome)
        XCTAssertTrue(source.contains("tell application \"Google Chrome\""))
        XCTAssertTrue(source.contains("active tab of front window"))
        XCTAssertTrue(source.contains("execute targetTab javascript jsCode"))
        XCTAssertFalse(source.contains("repeat with"))
        XCTAssertFalse(source.contains("activate"))
        var error: NSDictionary?
        XCTAssertTrue(try XCTUnwrap(NSAppleScript(source: source)).compileAndReturnError(&error), "\(String(describing: error))")
    }

    func testBrowserSwitchChangesNextRequestWithoutFallback() async {
        let session = StudyBrowserSession()
        let runner = SafariRequestRecorder()
        let service = AppleEventBrowserAutomationService(runner: runner, session: session)
        _ = await service.executeJavaScriptInUWorldTab("'synthetic'")
        var request = await runner.lastRequest
        XCTAssertTrue(String(decoding: request!.standardInput!, as: UTF8.self).contains("tell application \"Safari\""))
        session.browser = .chrome
        _ = await service.executeJavaScriptInUWorldTab("'synthetic'")
        request = await runner.lastRequest
        let script = String(decoding: request!.standardInput!, as: UTF8.self)
        XCTAssertTrue(script.contains("tell application \"Google Chrome\""))
        XCTAssertFalse(script.contains("tell application \"Safari\""))
        XCTAssertEqual(request?.timeoutSeconds, 12)
    }

    func testEmptySuccessfulAppleEventIsReportedAsARecoverableFailure() async {
        let service = AppleEventBrowserAutomationService(runner: EmptyBrowserResponseRunner())
        let result = await service.executeJavaScriptInUWorldTab("'synthetic'")
        guard case .failure(let message) = result else { return XCTFail("Empty output must not reach capture decoding") }
        XCTAssertTrue(message.contains("Select your UWorld tab"))
    }
}

private struct EmptyBrowserResponseRunner: AsyncProcessRunning {
    func run(_ request: AsyncProcessRequest) async throws -> AsyncProcessResult { .init(exitCode: 0, stdout: Data(), stderr: Data()) }
}

private actor SafariRequestRecorder: AsyncProcessRunning {
    var lastRequest: AsyncProcessRequest?
    func run(_ request: AsyncProcessRequest) async throws -> AsyncProcessResult {
        lastRequest = request
        return .init(exitCode: 0, stdout: Data("clicked\n".utf8), stderr: Data())
    }
}
