import Salient
import SwiftUI

@main
struct SalientMiniApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var delegate

    var body: some Scene {
        SalientScene()
    }
}
