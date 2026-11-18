import Foundation

/// Top-level spatial navigation zone across the main launcher window.
public enum LauncherFocusZone: String, Equatable, Sendable {
    case leftRail
    case topHeader
    case content
    case bottomZoom
}

/// Interactive items hosted in MainView's top navigation header.
public enum HeaderFocusItem: Int, CaseIterable, Equatable, Sendable {
    case addGame = 0
    case search = 1
    case provisioningPill = 2
}

/// Canonical navigation & action inputs emitted by both Gamepad and Keyboard bridges.
public enum UnifiedNavInput: Equatable, Sendable {
    case navigateLeft
    case navigateRight
    case navigateUp
    case navigateDown
    case confirm
    case cancel
    case secondaryAction
    case contextAction
    case tabPrevious
    case tabNext
    case subTabPrevious
    case subTabNext
    case menu
    case options
    case pageUp
    case pageDown
    case home
    case end
    case zoomIn
    case zoomOut
    case focusSearch
    case clearSearch

    public static func from(gamepadAction: GamepadAction) -> UnifiedNavInput {
        switch gamepadAction {
        case .navigateLeft: return .navigateLeft
        case .navigateRight: return .navigateRight
        case .navigateUp: return .navigateUp
        case .navigateDown: return .navigateDown
        case .confirm: return .confirm
        case .cancel: return .cancel
        case .secondaryAction: return .secondaryAction
        case .contextAction: return .contextAction
        case .tabPrevious: return .tabPrevious
        case .tabNext: return .tabNext
        case .subTabPrevious: return .subTabPrevious
        case .subTabNext: return .subTabNext
        case .menu: return .menu
        case .options: return .options
        }
    }

    public var asGamepadAction: GamepadAction? {
        switch self {
        case .navigateLeft: return .navigateLeft
        case .navigateRight: return .navigateRight
        case .navigateUp: return .navigateUp
        case .navigateDown: return .navigateDown
        case .confirm: return .confirm
        case .cancel: return .cancel
        case .secondaryAction: return .secondaryAction
        case .contextAction: return .contextAction
        case .tabPrevious: return .tabPrevious
        case .tabNext: return .tabNext
        case .subTabPrevious: return .subTabPrevious
        case .subTabNext: return .subTabNext
        case .menu: return .menu
        case .options: return .options
        default: return nil
        }
    }
}
