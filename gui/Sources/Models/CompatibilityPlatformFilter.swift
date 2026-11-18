import Foundation

public enum CompatibilityPlatformFilter: String, CaseIterable, Identifiable, Hashable {
    case all = "All"
    case macOS = "macOS"
    case iOS = "iOS"
    case iPadOS = "iPadOS"
    case android = "Android"

    public var id: String { rawValue }

    public var iconName: String {
        switch self {
        case .all: return "square.grid.2x2"
        case .macOS: return "laptopcomputer"
        case .iOS: return "iphone"
        case .iPadOS: return "ipad"
        case .android: return "candybarphone"
        }
    }
}
