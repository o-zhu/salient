import Foundation

enum UIFixture: String, CaseIterable, Sendable {
    case empty
    case ready
    case processing
    case error
    case populated
}

enum UIFixtureAppearance: String, Sendable {
    case light
    case dark
}

struct AppLaunchConfiguration: Equatable, Sendable {
    var uiFixture: UIFixture?
    var disablesModelWarmup: Bool
    var uiAppearance: UIFixtureAppearance?
    var usesIncreasedContrast: Bool

    init(
        uiFixture: UIFixture?,
        disablesModelWarmup: Bool,
        uiAppearance: UIFixtureAppearance? = nil,
        usesIncreasedContrast: Bool = false
    ) {
        self.uiFixture = uiFixture
        self.disablesModelWarmup = disablesModelWarmup
        self.uiAppearance = uiAppearance
        self.usesIncreasedContrast = usesIncreasedContrast
    }

    static func parse(arguments: [String] = CommandLine.arguments) -> AppLaunchConfiguration {
        var fixture: UIFixture?
        var disablesModelWarmup = false
        var appearance: UIFixtureAppearance?
        var usesIncreasedContrast = false
        var index = arguments.startIndex
        while index < arguments.endIndex {
            let argument = arguments[index]
            if argument == "--disable-model-warmup" {
                disablesModelWarmup = true
            } else if argument == "--ui-increased-contrast" {
                usesIncreasedContrast = true
            } else if argument == "--ui-fixture", arguments.indices.contains(index + 1) {
                fixture = UIFixture(rawValue: arguments[index + 1])
                index += 1
            } else if argument.hasPrefix("--ui-fixture=") {
                fixture = UIFixture(rawValue: String(argument.dropFirst("--ui-fixture=".count)))
            } else if argument == "--ui-appearance", arguments.indices.contains(index + 1) {
                appearance = UIFixtureAppearance(rawValue: arguments[index + 1])
                index += 1
            } else if argument.hasPrefix("--ui-appearance=") {
                appearance = UIFixtureAppearance(rawValue: String(argument.dropFirst("--ui-appearance=".count)))
            }
            index += 1
        }
        return AppLaunchConfiguration(
            uiFixture: fixture,
            disablesModelWarmup: disablesModelWarmup,
            uiAppearance: appearance,
            usesIncreasedContrast: usesIncreasedContrast
        )
    }
}
