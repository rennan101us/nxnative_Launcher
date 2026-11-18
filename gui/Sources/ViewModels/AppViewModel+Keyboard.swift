import Foundation
import SwiftUI
import AppKit

extension AppViewModel {
    
    // MARK: - Global Keyboard Navigation Handler
    public func handleKeyboardKey(_ key: String) {
        // Modal Navigation: traps all keyboard navigation while any modal is opened
        if isAnyModalPresented {
            if let input = mapKeyToUnifiedInput(key) {
                handleModalUnifiedNavigation(input)
            }
            return
        }

        // Navigation hotkeys guard: ensure hotkeys are enabled and no text input is active
        guard isNavigationHotkeysEnabled else { return }

        if isShowingOnboarding {
            handleOnboardingKeyboardKey(key)
            return
        }

        let tabCount = isDeveloperMode ? 6 : 5
        // Tab switching: Direct number keys
        if let num = Int(key), (1...tabCount).contains(num) {
            SoundEffectService.shared.play(.tabSwitch)
            selectedTab = num - 1
            return
        }

        // Main tab cycling: Tab / Shift+Tab
        if key == "tab" {
            SoundEffectService.shared.play(.tabSwitch)
            selectedTab = (selectedTab + 1) % tabCount
            return
        }
        if key == "shifttab" {
            SoundEffectService.shared.play(.tabSwitch)
            selectedTab = (selectedTab - 1 + tabCount) % tabCount
            return
        }

        switch key {
        case "left":
            handleUnifiedNavigation(.navigateLeft)
        case "right":
            handleUnifiedNavigation(.navigateRight)
        case "up":
            handleUnifiedNavigation(.navigateUp)
        case "down":
            handleUnifiedNavigation(.navigateDown)
        case "return":
            handleUnifiedNavigation(.confirm)
        case "escape":
            handleUnifiedNavigation(.cancel)
        case "backspace":
            handleUnifiedNavigation(.clearSearch)
        case "[":
            handleUnifiedNavigation(.subTabPrevious)
        case "]":
            handleUnifiedNavigation(.subTabNext)
        case "zoomin":
            handleUnifiedNavigation(.zoomIn)
        case "zoomout":
            handleUnifiedNavigation(.zoomOut)
        case "/":
            handleUnifiedNavigation(.focusSearch)
        case "pageup":
            handleUnifiedNavigation(.pageUp)
        case "pagedown":
            handleUnifiedNavigation(.pageDown)
        case "home":
            handleUnifiedNavigation(.home)
        case "end":
            handleUnifiedNavigation(.end)
        case "o":
            handleUnifiedNavigation(.options)
        case ",":
            if selectedTab == 0, let g = currentFocusedGame {
                SoundEffectService.shared.play(.click)
                gameForSettingsSheet = g
            }
        case "r":
            if selectedTab == 1 {
                loadCompatibleGames(forceRefresh: true)
            }
        case "c":
            if selectedTab == 5 {
                handleSecondaryAction()
            }
        case "k":
            if selectedTab == 5 {
                handleContextAction()
            }
        case "i":
            if selectedTab == 4 {
                showInstallerSheet = true
            }
        case "u":
            if selectedTab == 4 {
                checkForUpdates()
            }
        case "x":
            handleUnifiedNavigation(.secondaryAction)
        case "y":
            if selectedTab == 4 {
                handleSystemGamepadAction(.secondaryAction)
            } else {
                handleUnifiedNavigation(.contextAction)
            }
        case "space":
            if selectedTab == 2 {
                var prof = InputProfileManager.shared.activeProfile
                prof.swapFaceButtons()
                InputProfileManager.shared.updateProfile(prof)
            } else {
                handleUnifiedNavigation(.confirm)
            }
        case "g":
            if selectedTab == 3 {
                handleSecondaryAction()
            }
        case "m":
            if selectedTab == 3 {
                handleContextAction()
            }
        default:
            break
        }
    }

    private func mapKeyToUnifiedInput(_ key: String) -> UnifiedNavInput? {
        switch key {
        case "left": return .navigateLeft
        case "right": return .navigateRight
        case "up": return .navigateUp
        case "down": return .navigateDown
        case "return", "space": return .confirm
        case "escape": return .cancel
        case "backspace": return .clearSearch
        case "[": return .subTabPrevious
        case "]": return .subTabNext
        case "tab": return .tabNext
        case "shifttab": return .tabPrevious
        case "pageup": return .pageUp
        case "pagedown": return .pageDown
        case "home": return .home
        case "end": return .end
        case "x": return .secondaryAction
        case "y": return .contextAction
        case "o": return .options
        default: return nil
        }
    }
}
