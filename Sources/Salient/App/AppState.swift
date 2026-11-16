import Foundation
import Observation
import SalientCore

@MainActor
@Observable
final class NavigationFeatureModel {
    var selectedSection: AppSection = .reading
}

@MainActor
@Observable
final class StudySessionFeatureModel {
    var isBusy = false
    var statusMessage = "Ready."
    var lastError: String?
}

@MainActor
@Observable
final class NarrationFeatureModel {
    var settings: SpeechSettings
    var rsvpSettings: RSVPReadingSettings
    var residencyState: ModelResidencyState = .idle

    init(settings: SpeechSettings = .default, rsvpSettings: RSVPReadingSettings = .default) {
        self.settings = settings
        self.rsvpSettings = rsvpSettings
    }
}

@MainActor
@Observable
final class PlaybackHUDFeatureModel {
    var isVisible = false
    var frame = SpeechPlaybackVisualizationFrame.levelOnly(0)
    var mode: SpeechPlaybackVisualizationContext = .neutral
    var isGenerating = false

    var level: Double { frame.level }
}

@MainActor
@Observable
final class RSVPReaderFeatureModel {
    var isVisible = false
    var plan: RSVPReadingPlan?
    var requestedFrameIndex = 0
    var syncRevision = 0
    var followsNarration = false
    var isPlaybackRequested = false
}

@MainActor
@Observable
final class ReadinessFeatureModel {
    var safariAutomationStatus: AppleEventPermissionStatus = .unknown(0)
    var qwenResidencyState: ModelResidencyState = .idle
    var warmPolicy: ModelWarmPolicy = .adaptive
}

@MainActor
@Observable
final class AppState {
    let navigation = NavigationFeatureModel()
    let studySession = StudySessionFeatureModel()
    let narration: NarrationFeatureModel
    let playbackHUD = PlaybackHUDFeatureModel()
    let rsvpReader = RSVPReaderFeatureModel()
    let readiness = ReadinessFeatureModel()

    init(
        speechSettings: SpeechSettings = .default,
        rsvpSettings: RSVPReadingSettings = .default
    ) {
        narration = NarrationFeatureModel(settings: speechSettings, rsvpSettings: rsvpSettings)
    }
}
