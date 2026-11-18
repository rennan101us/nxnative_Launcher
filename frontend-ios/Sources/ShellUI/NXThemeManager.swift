import SwiftUI

// MARK: - Highlight Theme (Matching nxnative_launcher)

public enum LauncherHighlightTheme: String, CaseIterable, Identifiable, Sendable {
    case electricPurple = "Electric Purple"
    case nintendoRed = "Switch Neon Red"
    case neonBlue = "Switch Neon Blue"
    case emeraldGreen = "Emerald Green"
    case sunsetOrange = "Sunset Orange"
    case cyberRose = "Cyber Rose"
    case hyruleGold = "Hyrule Gold"
    case deepCobalt = "Deep Cobalt"
    case neonBlack = "Neon Black"
    
    public var id: String { rawValue }
    
    public var subtitle: String {
        switch self {
        case .electricPurple: return "Default Signature Violet"
        case .nintendoRed:    return "Classic Joy-Con Red"
        case .neonBlue:       return "Classic Joy-Con Blue"
        case .emeraldGreen:   return "Vibrant Cyber Emerald"
        case .sunsetOrange:   return "Warm Solar Accent"
        case .cyberRose:      return "Neon Magenta & Pink"
        case .hyruleGold:     return "Royal Triforce Amber"
        case .deepCobalt:     return "Clean iOS Sapphire"
        case .neonBlack:      return "Stealth Onyx & Neon Silver"
        }
    }
    
    public var hexLabel: String {
        switch self {
        case .electricPurple: return "#6F31FF"
        case .nintendoRed:    return "#E60012"
        case .neonBlue:       return "#0084FF"
        case .emeraldGreen:   return "#10B981"
        case .sunsetOrange:   return "#F97316"
        case .cyberRose:      return "#EC4899"
        case .hyruleGold:     return "#D97706"
        case .deepCobalt:     return "#3B82F6"
        case .neonBlack:      return "#141418"
        }
    }
    
    public var primaryColor: Color {
        switch self {
        case .electricPurple:
            return Color(red: 0x6F / 255.0, green: 0x31 / 255.0, blue: 0xFF / 255.0)
        case .nintendoRed:
            return Color(red: 0xE6 / 255.0, green: 0x00 / 255.0, blue: 0x12 / 255.0)
        case .neonBlue:
            return Color(red: 0x00 / 255.0, green: 0x84 / 255.0, blue: 0xFF / 255.0)
        case .emeraldGreen:
            return Color(red: 0x10 / 255.0, green: 0xB9 / 255.0, blue: 0x81 / 255.0)
        case .sunsetOrange:
            return Color(red: 0xF9 / 255.0, green: 0x73 / 255.0, blue: 0x16 / 255.0)
        case .cyberRose:
            return Color(red: 0xEC / 255.0, green: 0x48 / 255.0, blue: 0x99 / 255.0)
        case .hyruleGold:
            return Color(red: 0xD9 / 255.0, green: 0x77 / 255.0, blue: 0x06 / 255.0)
        case .deepCobalt:
            return Color(red: 0x3B / 255.0, green: 0x82 / 255.0, blue: 0xF6 / 255.0)
        case .neonBlack:
            return Color(red: 0x22 / 255.0, green: 0x22 / 255.0, blue: 0x28 / 255.0)
        }
    }
    
    public var secondaryColor: Color {
        switch self {
        case .electricPurple:
            return Color(red: 0x8B / 255.0, green: 0x5C / 255.0, blue: 0xF6 / 255.0)
        case .nintendoRed:
            return Color(red: 0xFF / 255.0, green: 0x4B / 255.0, blue: 0x55 / 255.0)
        case .neonBlue:
            return Color(red: 0x00 / 255.0, green: 0xC2 / 255.0, blue: 0xFF / 255.0)
        case .emeraldGreen:
            return Color(red: 0x34 / 255.0, green: 0xD3 / 255.0, blue: 0x99 / 255.0)
        case .sunsetOrange:
            return Color(red: 0xFB / 255.0, green: 0x92 / 255.0, blue: 0x3C / 255.0)
        case .cyberRose:
            return Color(red: 0xF4 / 255.0, green: 0x72 / 255.0, blue: 0xB6 / 255.0)
        case .hyruleGold:
            return Color(red: 0xF5 / 255.0, green: 0x9E / 255.0, blue: 0x0B / 255.0)
        case .deepCobalt:
            return Color(red: 0x60 / 255.0, green: 0xA5 / 255.0, blue: 0xFA / 255.0)
        case .neonBlack:
            return Color(red: 0x8E / 255.0, green: 0x92 / 255.0, blue: 0xA0 / 255.0)
        }
    }
}

// MARK: - Supported App Languages (Matching nxnative_launcher)

public enum AppLanguage: String, CaseIterable, Identifiable, Codable, Sendable {
    case system = "system"
    case en = "en"
    case ptBR = "pt-BR"
    case ptPT = "pt-PT"
    case es = "es"
    case ja = "ja"
    case fr = "fr"
    case de = "de"
    case it = "it"
    case zhHans = "zh-Hans"
    case zhHant = "zh-Hant"
    case ko = "ko"
    case pl = "pl"
    case ru = "ru"
    case sv = "sv"
    
    public var id: String { rawValue }

    public static var sortedForDisplay: [AppLanguage] {
        let rest = allCases.filter { $0 != .system }
            .sorted { $0.nativeName.localizedStandardCompare($1.nativeName) == .orderedAscending }
        return [.system] + rest
    }
    
    public var displayName: String {
        switch self {
        case .system: return "System Default"
        case .en: return "English"
        case .ptBR: return "Portuguese (Brazil)"
        case .ptPT: return "Portuguese (Portugal)"
        case .es: return "Spanish"
        case .ja: return "Japanese"
        case .fr: return "French"
        case .de: return "German"
        case .it: return "Italian"
        case .zhHans: return "Chinese (Simplified)"
        case .zhHant: return "Chinese (Traditional)"
        case .ko: return "Korean"
        case .pl: return "Polish"
        case .ru: return "Russian"
        case .sv: return "Swedish"
        }
    }
    
    public var nativeName: String {
        switch self {
        case .system: return "System Default"
        case .en: return "English (US)"
        case .ptBR: return "Português (Brasil)"
        case .ptPT: return "Português (Portugal)"
        case .es: return "Español"
        case .ja: return "日本語"
        case .fr: return "Français"
        case .de: return "Deutsch"
        case .it: return "Italiano"
        case .zhHans: return "简体中文"
        case .zhHant: return "繁體中文"
        case .ko: return "한국어"
        case .pl: return "Polski"
        case .ru: return "Русский"
        case .sv: return "Svenska"
        }
    }
    
    public var flag: String {
        switch self {
        case .system: return "🌐"
        case .en: return "🇺🇸"
        case .ptBR: return "🇧🇷"
        case .ptPT: return "🇵🇹"
        case .es: return "🇪🇸"
        case .ja: return "🇯🇵"
        case .fr: return "🇫🇷"
        case .de: return "🇩🇪"
        case .it: return "🇮🇹"
        case .zhHans: return "🇨🇳"
        case .zhHant: return "🇹🇼"
        case .ko: return "🇰🇷"
        case .pl: return "🇵🇱"
        case .ru: return "🇷🇺"
        case .sv: return "🇸🇪"
        }
    }

    fileprivate static var isRunningTests: Bool {
        let env = ProcessInfo.processInfo.environment
        if env["XCTestConfigurationFilePath"] != nil || env["XCTestBundlePath"] != nil || env["SWIFTPM_TESTING_HELPER"] != nil {
            return true
        }
        let proc = ProcessInfo.processInfo.processName
        return Bundle.main.bundlePath.hasSuffix(".xctest") || proc.contains("xctest") || proc.contains("testing-helper")
    }

    public static func resolve() -> AppLanguage {
        if isRunningTests {
            return .en
        }
        let pref = Locale.preferredLanguages.first ?? "en"
        let lower = pref.lowercased()
        if lower.hasPrefix("pt-br") { return .ptBR }
        if lower.hasPrefix("pt") { return .ptPT }
        if lower.hasPrefix("es") { return .es }
        if lower.hasPrefix("ja") { return .ja }
        if lower.hasPrefix("fr") { return .fr }
        if lower.hasPrefix("de") { return .de }
        if lower.hasPrefix("it") { return .it }
        if lower.hasPrefix("zh-hant") || lower.hasPrefix("zh-tw") || lower.hasPrefix("zh-hk") { return .zhHant }
        if lower.hasPrefix("zh") { return .zhHans }
        if lower.hasPrefix("ko") { return .ko }
        if lower.hasPrefix("pl") { return .pl }
        if lower.hasPrefix("ru") { return .ru }
        if lower.hasPrefix("sv") { return .sv }
        return .en
    }
}

// MARK: - Central Theme & Language Manager

public final class NXThemeManager: ObservableObject, @unchecked Sendable {
    public static let shared = NXThemeManager()

    @Published public var currentTheme: LauncherHighlightTheme {
        didSet {
            UserDefaults.standard.set(currentTheme.rawValue, forKey: "nx_highlight_theme")
        }
    }

    @Published public var currentLanguage: AppLanguage {
        didSet {
            UserDefaults.standard.set(currentLanguage.rawValue, forKey: "nx_language")
        }
    }

    private init() {
        if let savedTheme = UserDefaults.standard.string(forKey: "nx_highlight_theme"),
           let theme = LauncherHighlightTheme(rawValue: savedTheme) {
            self.currentTheme = theme
        } else {
            self.currentTheme = .electricPurple
        }

        if !AppLanguage.isRunningTests,
           let savedLang = UserDefaults.standard.string(forKey: "nx_language"),
           let lang = AppLanguage(rawValue: savedLang) {
            self.currentLanguage = lang
        } else {
            self.currentLanguage = .system
        }
    }

    public var effectiveLanguage: AppLanguage {
        currentLanguage == .system ? AppLanguage.resolve() : currentLanguage
    }
}
