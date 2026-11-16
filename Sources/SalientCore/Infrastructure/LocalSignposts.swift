import Foundation
import os.signpost

public enum SalientSignpostEvent: String, Sendable {
    case launch
    case libraryRefresh
    case modelLoad
    case capture
    case normalization
    case synthesis
    case firstAudio
}

public struct SalientSignpostInterval: @unchecked Sendable {
    fileprivate var event: SalientSignpostEvent
    fileprivate var id: OSSignpostID
}

public enum SalientSignposts {
    private static let log = OSLog(subsystem: "com.zhuou.salient", category: "LocalPerformance")

    public static func begin(_ event: SalientSignpostEvent) -> SalientSignpostInterval {
        let id = OSSignpostID(log: log)
        os_signpost(.begin, log: log, name: "SalientInterval", signpostID: id, "%{public}s", event.rawValue)
        return SalientSignpostInterval(event: event, id: id)
    }

    public static func end(_ interval: SalientSignpostInterval) {
        os_signpost(.end, log: log, name: "SalientInterval", signpostID: interval.id, "%{public}s", interval.event.rawValue)
    }

    public static func event(_ event: SalientSignpostEvent) {
        os_signpost(.event, log: log, name: "SalientEvent", "%{public}s", event.rawValue)
    }
}
