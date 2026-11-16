import CoreServices
import Foundation

public enum BrowserAutomationPermissionService {
    private static let safariStatusQueue = DispatchQueue(label: "com.salient.permission-status.safari", qos: .utility)
    private static let chromeStatusQueue = DispatchQueue(label: "com.salient.permission-status.chrome", qos: .utility)
    private static let consentQueue = DispatchQueue(label: "com.salient.permission-consent", qos: .userInitiated)

    public static func statusAsync(browser: StudyBrowser = .safari) async -> AppleEventPermissionStatus {
        await withCheckedContinuation { continuation in
            let statusQueue = browser == .safari ? safariStatusQueue : chromeStatusQueue
            statusQueue.async { continuation.resume(returning: status(browser: browser)) }
        }
    }

    public static func requestAccess(browser: StudyBrowser = .safari) async -> AppleEventPermissionStatus {
        await requestAccess(bundleID: browser.bundleIdentifier)
    }

    public static func requestSystemEventsAccess() async -> AppleEventPermissionStatus {
        await requestAccess(bundleID: "com.apple.systemevents")
    }

    private static func requestAccess(bundleID: String) async -> AppleEventPermissionStatus {
        // Ask for this app's identity directly. A helper's harmless `get name`
        // event may not prompt for the app permission subsequently checked here.
        // The system can wait for user consent, so never do this on the UI actor.
        await withCheckedContinuation { continuation in
            consentQueue.async {
                continuation.resume(returning: status(bundleID: bundleID, askUserIfNeeded: true))
            }
        }
    }

    public static func status(browser: StudyBrowser = .safari, askUserIfNeeded: Bool = false) -> AppleEventPermissionStatus {
        status(bundleID: browser.bundleIdentifier, askUserIfNeeded: askUserIfNeeded)
    }

    public static func systemEventsStatus(askUserIfNeeded: Bool = false) -> AppleEventPermissionStatus {
        status(bundleID: "com.apple.systemevents", askUserIfNeeded: askUserIfNeeded)
    }

    private static func status(bundleID: String, askUserIfNeeded: Bool = false) -> AppleEventPermissionStatus {
        var target = AEAddressDesc()
        let createStatus = bundleID.withCString { pointer in
            AECreateDesc(
                DescType(typeApplicationBundleID),
                pointer,
                bundleID.utf8.count,
                &target
            )
        }
        guard createStatus == noErr else {
            return .unknown(OSStatus(createStatus))
        }
        defer {
            AEDisposeDesc(&target)
        }

        let status = AEDeterminePermissionToAutomateTarget(
            &target,
            AEEventClass(kCoreEventClass),
            AEEventID(kAEGetData),
            askUserIfNeeded
        )
        return AppleEventPermissionStatus(osStatus: status)
    }
}

public typealias SafariAutomationPermissionService = BrowserAutomationPermissionService
