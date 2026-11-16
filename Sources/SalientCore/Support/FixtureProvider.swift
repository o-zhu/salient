import Foundation

public enum FixtureProvider {
    public static var syntheticFixtureURL: URL? {
        Bundle.module.url(forResource: "two-pane", withExtension: "html")
    }
}
