import Foundation

public enum SelfCheck {
    public static func run() -> Int32 {
        let submitScriptReady = !SubmitJavaScript.build().isEmpty
        let captureScriptReady = CaptureJavaScript.build(mode: .question).contains("captureUWorldSegments")
        let appSupport = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
        return submitScriptReady && captureScriptReady && appSupport != nil ? 0 : 1
    }
}
