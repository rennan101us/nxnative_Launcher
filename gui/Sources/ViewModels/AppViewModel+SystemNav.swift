import Foundation
import SwiftUI
import AppKit

extension AppViewModel {
    public var availableSettingsCategories: [SettingsCategory] {
        isDeveloperMode ? SettingsCategory.allCases : [.general, .updates, .toolchain]
    }

    private func maxCardCount(for category: SettingsCategory) -> Int {
        switch category {
        case .general: return 1
        case .updates: return 1
        case .toolchain: return 2
        case .developer: return 2
        }
    }

    public func handleSystemGamepadAction(_ action: GamepadAction) {
        // Quick Shortcuts available anywhere in System tab
        if action == .contextAction { // Y / △ -> Toggle Developer Mode
            SoundEffectService.shared.play(.click)
            withAnimation(.spring(response: 0.32, dampingFraction: 0.78)) {
                isDeveloperMode.toggle()
                if !isDeveloperMode && activeSettingsCategory == .developer {
                    activeSettingsCategory = .general
                    settingsItemFocusIndex = 0
                }
                if !isDeveloperMode && systemHeaderFocusIndex > 0 {
                    systemHeaderFocusIndex = 0
                }
            }
            return
        }
        if action == .secondaryAction { // X / □ -> Quick Action / Updates
            SoundEffectService.shared.play(.click)
            if activeSettingsCategory == .toolchain {
                repairAllDependencies()
            } else {
                openUpdateCheckerAndAutoInstall()
            }
            return
        }

        // Category switching with ZL / ZR ([ / ])
        if action == .subTabPrevious {
            cycleSystemCategory(forward: false, allowLeftRailEscape: false)
            return
        }
        if action == .subTabNext {
            cycleSystemCategory(forward: true, allowLeftRailEscape: false)
            return
        }

        // Level 2: Inside a System Card (e.g., SystemKeysCard: Choose File / Find in Ryujinx)
        if isInsideSystemCard {
            handleSystemInnerCardAction(action)
            return
        }

        // Level 1: Header controls (DevMode toggle & Quick Repair button)
        if systemHeaderFocusIndex >= 0 {
            handleSystemHeaderAction(action)
            return
        }

        // Level 1: Category bar & cards
        let cardCount = maxCardCount(for: activeSettingsCategory)
        switch action {
        case .navigateLeft:
            cycleSystemCategory(forward: false, allowLeftRailEscape: true)
        case .navigateRight:
            cycleSystemCategory(forward: true, allowLeftRailEscape: false)
        case .navigateUp:
            if settingsItemFocusIndex > 0 {
                SoundEffectService.shared.play(.focus)
                settingsItemFocusIndex -= 1
            } else {
                SoundEffectService.shared.play(.focus)
                withAnimation(.easeInOut(duration: 0.16)) {
                    systemHeaderFocusIndex = 0
                }
            }
        case .navigateDown:
            if settingsItemFocusIndex < cardCount - 1 {
                SoundEffectService.shared.play(.focus)
                settingsItemFocusIndex += 1
            }
        case .confirm:
            handleSystemOuterConfirm()
        default:
            break
        }
    }

    private func cycleSystemCategory(forward: Bool, allowLeftRailEscape: Bool) {
        let cats = availableSettingsCategories
        guard let idx = cats.firstIndex(of: activeSettingsCategory) else { return }
        if !forward && idx == 0 && allowLeftRailEscape {
            enterLeftRailFocus()
            return
        }
        let targetIdx = forward ? (idx + 1) % cats.count : (idx - 1 + cats.count) % cats.count
        SoundEffectService.shared.play(.tabSwitch)
        withAnimation(.spring(response: 0.32, dampingFraction: 0.78)) {
            activeSettingsCategory = cats[targetIdx]
            settingsItemFocusIndex = 0
            isInsideSystemCard = false
            systemSubItemFocusIndex = 0
        }
    }

    private func handleSystemHeaderAction(_ action: GamepadAction) {
        switch action {
        case .navigateLeft:
            if systemHeaderFocusIndex > 0 {
                SoundEffectService.shared.play(.focus)
                systemHeaderFocusIndex -= 1
            } else {
                systemHeaderFocusIndex = -1
                enterLeftRailFocus()
            }
        case .navigateRight:
            if isDeveloperMode && systemHeaderFocusIndex == 0 {
                SoundEffectService.shared.play(.focus)
                systemHeaderFocusIndex = 1
            }
        case .navigateUp:
            if enterTopHeaderFocus(preferred: .provisioningPill) {
                systemHeaderFocusIndex = -1
            }
        case .navigateDown, .cancel:
            SoundEffectService.shared.play(.focus)
            withAnimation(.easeInOut(duration: 0.16)) {
                systemHeaderFocusIndex = -1
                settingsItemFocusIndex = 0
            }
        case .confirm:
            SoundEffectService.shared.play(.click)
            if systemHeaderFocusIndex == 0 {
                withAnimation(.spring(response: 0.32, dampingFraction: 0.78)) {
                    isDeveloperMode.toggle()
                    if !isDeveloperMode && activeSettingsCategory == .developer {
                        activeSettingsCategory = .general
                        settingsItemFocusIndex = 0
                    }
                }
            } else if systemHeaderFocusIndex == 1 && isDeveloperMode {
                if !prerequisites.missingList(for: selectedOnboardingPlatforms).isEmpty {
                    installAllMissingDependencies()
                } else {
                    repairAllDependencies()
                }
            }
        default:
            break
        }
    }

    private func handleSystemOuterConfirm() {
        SoundEffectService.shared.play(.click)
        switch activeSettingsCategory {
        case .general:
            selectAdditionalGameFolder()
        case .updates:
            if let info = updateInfo, info.hasUpdate {
                applyUpdate(autoRelaunch: true)
            } else {
                checkForUpdates(force: true)
            }
        case .toolchain:
            if settingsItemFocusIndex == 0 {
                // Enter SystemKeysCard so user can pick between Choose File (0) and Find in Ryujinx (1)
                withAnimation(.easeInOut(duration: 0.16)) {
                    systemSubItemFocusIndex = 0
                    isInsideSystemCard = true
                }
            } else {
                if !prerequisites.allSatisfied(for: selectedOnboardingPlatforms) {
                    installAllMissingDependencies()
                } else {
                    repairAllDependencies()
                }
            }
        case .developer:
            switch settingsItemFocusIndex {
            case 0:
                openUpdateCheckerAndAutoInstall()
            case 1:
                _ = BuildCleanupService.shared.cleanImageCache()
            default:
                break
            }
        }
    }

    private func handleSystemInnerCardAction(_ action: GamepadAction) {
        switch action {
        case .cancel:
            SoundEffectService.shared.play(.click)
            withAnimation(.easeInOut(duration: 0.16)) {
                isInsideSystemCard = false
            }
        case .navigateLeft, .navigateUp:
            if systemSubItemFocusIndex > 0 {
                SoundEffectService.shared.play(.focus)
                systemSubItemFocusIndex -= 1
            } else {
                SoundEffectService.shared.play(.focus)
                systemSubItemFocusIndex = 1
            }
        case .navigateRight, .navigateDown:
            SoundEffectService.shared.play(.focus)
            systemSubItemFocusIndex = (systemSubItemFocusIndex + 1) % 2
        case .confirm:
            SoundEffectService.shared.play(.click)
            if activeSettingsCategory == .toolchain && settingsItemFocusIndex == 0 {
                if systemSubItemFocusIndex == 0 {
                    selectProdKeysFile()
                } else {
                    findInRyujinx()
                }
            }
        default:
            break
        }
    }
}
