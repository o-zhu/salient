import Foundation
import JavaScriptCore
import WebKit
import XCTest
@testable import SalientCore

@MainActor final class UWorldInterfaceLabelTests: XCTestCase {
    func testRenderedCheckboxIsExcludedFromQuestionReadPlan() async throws {
        let ready = expectation(description: "Synthetic question DOM loaded")
        let delegate = SyntheticCaptureNavigation { ready.fulfill() }
        let web = WKWebView(frame: .init(x: 0, y: 0, width: 1400, height: 900))
        web.navigationDelegate = delegate
        web.loadHTMLString("""
        <html><body style="margin:180px 160px;width:520px;font:18px sans-serif">
        <label><input type="checkbox">Mark Question</label>
        <label><input type="checkbox"><span>Suggested </span><span>Highlights</span></label>
        <p>A student reads a synthetic question about a patient with a cough.</p>
        <p>The suggested highlights are discussed with the patient.</p>
        <p>Which diagnosis is most likely?</p>
        </body></html>
        """, baseURL: nil)
        await fulfillment(of: [ready], timeout: 10)
        let captured = try await web.evaluateJavaScript(CaptureJavaScript.build(mode: .question))
        let json = try XCTUnwrap(captured as? String)
        let payload = try UWorldCapturePayload.decode(json: json)
        let labels = payload.segments.filter { ["Suggested", "Highlights"].contains($0.text.trimmingCharacters(in: .whitespacesAndNewlines)) }
        XCTAssertEqual(labels.count, 2)
        XCTAssertTrue(labels.allSatisfy { $0.role == .ui })
        let text = ReadPlanBuilder().questionPlan(from: payload).items.map(\.text).joined(separator: " ")
        XCTAssertFalse(text.contains("Suggested Highlights"))
        XCTAssertTrue(text.contains("The suggested highlights are discussed with the patient."))
        XCTAssertTrue(text.contains("synthetic question"))
    }
    func testSuggestedHighlightsIsInterfaceTextIncludingSplitLabelAndWhitespace() throws {
        let context = try captureContext()
        for label in ["Suggested Highlights", "Suggested\u{00a0}Highlights", "  SUGGESTED\n HIGHLIGHTS  "] {
            context.setObject(label, forKeyedSubscript: "label" as NSString)
            XCTAssertTrue(context.evaluateScript("window.__uworldTTSCaptureInternals.isLikelyInterfaceText(label, null)").toBool())
        }
        context.evaluateScript("""
        var wrapper = {textContent: 'Suggested Highlights', parentElement: document.body};
        var child = {textContent: 'Suggested', parentElement: wrapper};
        """)
        for word in ["Suggested", "Highlights"] {
            context.setObject(word, forKeyedSubscript: "word" as NSString)
            let role = context.evaluateScript("window.__uworldTTSCaptureInternals.classifyRole(word, 'left', child, word, [], 0, word)").toString()
            XCTAssertEqual(role, "ui")
        }
        XCTAssertNil(context.exception)
    }

    func testProseContainingTheWordsIsPreserved() throws {
        let context = try captureContext()
        context.evaluateScript("var paragraph = {textContent: 'The suggested highlights are discussed with the patient.', parentElement: document.body};")
        XCTAssertFalse(context.evaluateScript("window.__uworldTTSCaptureInternals.isLikelyInterfaceText(paragraph.textContent, paragraph)").toBool())
        XCTAssertFalse(context.evaluateScript("window.__uworldTTSCaptureInternals.isLikelyInterfaceText('Highlights', paragraph)").toBool())
        XCTAssertNil(context.exception)
    }

    private func captureContext() throws -> JSContext {
        let context = try XCTUnwrap(JSContext())
        context.evaluateScript("var window = {}; var document = {body: {}};")
        let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        context.evaluateScript(try String(contentsOf: root.appendingPathComponent("Sources/SalientCore/Resources/safari_capture.js"), encoding: .utf8))
        XCTAssertNil(context.exception)
        return context
    }
}

@MainActor private final class SyntheticCaptureNavigation: NSObject, WKNavigationDelegate {
    let ready: () -> Void
    init(ready: @escaping () -> Void) { self.ready = ready }
    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) { ready() }
}
