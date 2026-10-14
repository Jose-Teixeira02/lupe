import AppKit
import Combine
import Foundation
import LupeCore

/// Which key you hold to look words up under the mouse.
enum HoverModifier: String, CaseIterable, Identifiable {
    case control, option, command, function

    var id: String { rawValue }

    var label: String {
        switch self {
        case .control: "⌃ Control"
        case .option: "⌥ Option"
        case .command: "⌘ Command"
        case .function: "fn Function"
        }
    }

    var flag: NSEvent.ModifierFlags {
        switch self {
        case .control: .control
        case .option: .option
        case .command: .command
        case .function: .function
        }
    }
}

enum SprinkleStyle: String, CaseIterable, Identifiable {
    case auto, above, replace
    var id: String { rawValue }
    var label: String {
        switch self {
        case .auto: "Automatic (tag where there's room)"
        case .above: "Small tag above the word"
        case .replace: "Cover the word"
        }
    }
}

/// User preferences, persisted in UserDefaults. Every property saves on change.
@MainActor
final class LupeSettings: ObservableObject {
    let defaults: UserDefaults

    @Published var hasOnboarded: Bool { didSet { save("hasOnboarded", hasOnboarded) } }
    /// Target language pack code ("de").
    @Published var targetLanguage: String { didSet { save("targetLanguage", targetLanguage) } }
    /// Language explanations and meanings are shown in first ("en" or "pt").
    @Published var primaryHelper: String { didSet { save("primaryHelper", primaryHelper) } }
    /// CEFR level picked in onboarding: "none", "A1", "A2", "B1", "B2".
    @Published var placementLevel: String { didSet { save("placementLevel", placementLevel) } }

    @Published var hoverEnabled: Bool { didSet { save("hoverEnabled", hoverEnabled) } }
    @Published var hoverModifier: HoverModifier { didSet { save("hoverModifier", hoverModifier.rawValue) } }
    /// Milliseconds the mouse must rest before a lookup.
    @Published var hoverDwellMs: Double { didSet { save("hoverDwellMs", hoverDwellMs) } }
    @Published var autoSaveLookups: Bool { didSet { save("autoSaveLookups", autoSaveLookups) } }
    @Published var speakOnLookup: Bool { didSet { save("speakOnLookup", speakOnLookup) } }
    @Published var preferAccessibilityText: Bool { didSet { save("preferAccessibilityText", preferAccessibilityText) } }

    @Published var sprinklesEnabled: Bool { didSet { save("sprinklesEnabled", sprinklesEnabled) } }
    @Published var sprinkleBudget: Int { didSet { save("sprinkleBudget", sprinkleBudget) } }
    @Published var sprinkleStyle: SprinkleStyle { didSet { save("sprinkleStyle", sprinkleStyle.rawValue) } }
    @Published var sprinkleAssistGerman: Bool { didSet { save("sprinkleAssistGerman", sprinkleAssistGerman) } }
    @Published var sprinkleTeach: Bool { didSet { save("sprinkleTeach", sprinkleTeach) } }
    @Published var sprinkleIntervalSec: Double { didSet { save("sprinkleIntervalSec", sprinkleIntervalSec) } }
    @Published var excludedApps: [String] { didSet { save("excludedApps", excludedApps) } }

    @Published var dailyNewCards: Int { didSet { save("dailyNewCards", dailyNewCards) } }
    @Published var reminderEnabled: Bool { didSet { save("reminderEnabled", reminderEnabled) } }
    @Published var reminderHour: Int { didSet { save("reminderHour", reminderHour) } }
    @Published var reminderMinute: Int { didSet { save("reminderMinute", reminderMinute) } }
    @Published var slowSpeech: Bool { didSet { save("slowSpeech", slowSpeech) } }
    /// "device" (Apple Intelligence, default) or "claude" (Anthropic API with your own key).
    @Published var tutorProvider: String { didSet { save("tutorProvider", tutorProvider) } }

    static let defaultExcludedApps = [
        "com.bitwarden.desktop", "com.1password.1password", "com.agilebits.onepassword7",
        "com.apple.keychainaccess", "com.apple.Passwords",
    ]

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        defaults.register(defaults: [
            "hasOnboarded": false,
            "targetLanguage": "de",
            "primaryHelper": Self.guessHelper(),
            "placementLevel": "none",
            "hoverEnabled": true,
            "hoverModifier": HoverModifier.control.rawValue,
            "hoverDwellMs": 180.0,
            "autoSaveLookups": true,
            "speakOnLookup": false,
            "preferAccessibilityText": true,
            "sprinklesEnabled": false,
            "sprinkleBudget": 6,
            "sprinkleStyle": SprinkleStyle.auto.rawValue,
            "sprinkleAssistGerman": true,
            "sprinkleTeach": true,
            "sprinkleIntervalSec": 1.5,
            "excludedApps": Self.defaultExcludedApps,
            "dailyNewCards": 10,
            "reminderEnabled": false,
            "reminderHour": 19,
            "reminderMinute": 0,
            "slowSpeech": false,
            "tutorProvider": "device",
        ])
        hasOnboarded = defaults.bool(forKey: "hasOnboarded")
        targetLanguage = defaults.string(forKey: "targetLanguage") ?? "de"
        primaryHelper = defaults.string(forKey: "primaryHelper") ?? "en"
        placementLevel = defaults.string(forKey: "placementLevel") ?? "none"
        hoverEnabled = defaults.bool(forKey: "hoverEnabled")
        hoverModifier = HoverModifier(rawValue: defaults.string(forKey: "hoverModifier") ?? "") ?? .control
        hoverDwellMs = defaults.double(forKey: "hoverDwellMs")
        autoSaveLookups = defaults.bool(forKey: "autoSaveLookups")
        speakOnLookup = defaults.bool(forKey: "speakOnLookup")
        preferAccessibilityText = defaults.bool(forKey: "preferAccessibilityText")
        sprinklesEnabled = defaults.bool(forKey: "sprinklesEnabled")
        sprinkleBudget = defaults.integer(forKey: "sprinkleBudget")
        sprinkleStyle = SprinkleStyle(rawValue: defaults.string(forKey: "sprinkleStyle") ?? "") ?? .auto
        sprinkleAssistGerman = defaults.bool(forKey: "sprinkleAssistGerman")
        sprinkleTeach = defaults.bool(forKey: "sprinkleTeach")
        sprinkleIntervalSec = defaults.double(forKey: "sprinkleIntervalSec")
        excludedApps = defaults.stringArray(forKey: "excludedApps") ?? Self.defaultExcludedApps
        dailyNewCards = defaults.integer(forKey: "dailyNewCards")
        reminderEnabled = defaults.bool(forKey: "reminderEnabled")
        reminderHour = defaults.integer(forKey: "reminderHour")
        reminderMinute = defaults.integer(forKey: "reminderMinute")
        slowSpeech = defaults.bool(forKey: "slowSpeech")
        tutorProvider = defaults.string(forKey: "tutorProvider") ?? "device"
    }

    private func save(_ key: String, _ value: Any) {
        defaults.set(value, forKey: key)
    }

    /// Portuguese if the Mac lists Portuguese before English, else English.
    static func guessHelper() -> String {
        for lang in Locale.preferredLanguages {
            if lang.hasPrefix("pt") { return "pt" }
            if lang.hasPrefix("en") { return "en" }
        }
        return "en"
    }

    var helpers: [String] {
        primaryHelper == "pt" ? ["pt", "en"] : ["en", "pt"]
    }

    var knownLevels: Set<String> { CEFR.known(upTo: placementLevel) }
    var nextLevel: String? { CEFR.next(after: placementLevel) }
}
