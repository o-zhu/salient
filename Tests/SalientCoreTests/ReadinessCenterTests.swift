import XCTest
@testable import SalientCore

final class ReadinessCenterTests: XCTestCase {
    func testChromePermissionGuidanceTargetsSelectedBrowser() {
        let report = PermissionCenterReport.current(safariAutomation: .denied, globalHotKeyEnabled: false, browser: .chrome)
        XCTAssertTrue(report.items[0].title.contains("Chrome"))
        XCTAssertTrue(report.items[0].detail.contains("Chrome"))
        XCTAssertFalse(report.items[0].detail.contains("Safari"))
        XCTAssertTrue(report.items[1].detail.contains("View → Developer"))
        let message = SafariAutomationErrorInterpreter.userMessage(errorNumber: nil, rawMessage: "JavaScript from Apple Events disabled", browser: .chrome)
        XCTAssertTrue(message.contains("Chrome"))
        XCTAssertFalse(message.contains("Safari"))
    }
    func testDependencyReportIncludesOnlyReaderFeaturesWhenRuntimeStatusIsUnavailable() {
        let report = DependencyCenterReport.current(
            safariAutomation: .authorized,
            globalHotKeyEnabled: false
        )

        XCTAssertEqual(report.items.first { $0.id == "safari-submit" }?.state, .available)
        XCTAssertEqual(report.items.first { $0.id == "native-speech" }?.state, .available)
        XCTAssertEqual(report.items.first { $0.id == "qwen-tts" }?.state, .optional)
        XCTAssertEqual(Set(report.items.map(\.id)), ["safari-submit", "native-speech", "global-hotkey", "qwen-tts"])
    }

    func testPermissionReportMapsSafariAutomationStatusToActionableRow() {
        let report = PermissionCenterReport.current(
            safariAutomation: .notDetermined,
            globalHotKeyEnabled: false
        )
        let safari = report.items.first { $0.id == "safari-automation" }

        XCTAssertEqual(safari?.state, .needsSetup)
        XCTAssertEqual(safari?.primaryActionTitle, "Request Access")
        XCTAssertTrue(safari?.detail.contains("Submit") == true)
        XCTAssertTrue(safari?.detail.contains("reopen the app from Applications") == true)
    }

    func testAppleEventPermissionStatusMapsSystemCodes() {
        XCTAssertEqual(AppleEventPermissionStatus(osStatus: 0), .authorized)
        XCTAssertEqual(AppleEventPermissionStatus(osStatus: -1743), .denied)
        XCTAssertEqual(AppleEventPermissionStatus(osStatus: -1744), .notDetermined)
        XCTAssertEqual(AppleEventPermissionStatus(osStatus: -1742), .blocked)
    }

    func testSafariAutomationErrorMessageExplainsHowToFixAppleEventsDenial() {
        let message = SafariAutomationErrorInterpreter.userMessage(
            errorNumber: -1743,
            rawMessage: "Not authorized to send Apple events to Safari."
        )

        XCTAssertTrue(message.contains("Safari Automation is not authorized"))
        XCTAssertTrue(message.contains("Open Permissions"))
        XCTAssertTrue(message.contains("System Settings"))
    }
}
