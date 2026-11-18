import Foundation
import SwiftUI

extension AppViewModel {
    
    public func handlePersonalizeGamepadAction(_ action: GamepadAction) {
        // Quick Shortcuts
        if action == .secondaryAction { // X / Square -> Quick Toggle Liquid Glass
            SoundEffectService.shared.play(.click)
            withAnimation(.spring(response: 0.32, dampingFraction: 0.78)) {
                isLiquidGlassEnabled.toggle()
            }
            return
        }
        if action == .contextAction { // Y / Triangle -> Quick Cycle Appearance
            SoundEffectService.shared.play(.click)
            withAnimation(.spring(response: 0.32, dampingFraction: 0.78)) {
                liquidGlassAppearance = (liquidGlassAppearance == .liquid) ? .frosted : .liquid
            }
            return
        }
        
        // Level 1: Outer Card Selection Mode (Language & Sound Left, Colors & Icons Right)
        if !isInsidePersonalizeCard {
            switch action {
            case .navigateUp:
                if personalizeCardIndex == 0 {
                    _ = enterTopHeaderFocus(preferred: .provisioningPill)
                    return
                }
                SoundEffectService.shared.play(.focus)
                withAnimation(.easeInOut(duration: 0.16)) {
                    if personalizeCardIndex == 4 {
                        personalizeCardIndex = 1
                    } else if personalizeCardIndex == 3 {
                        personalizeCardIndex = 2
                    } else if personalizeCardIndex == 1 || personalizeCardIndex == 2 {
                        personalizeCardIndex = 0
                    }
                }
            case .navigateDown:
                SoundEffectService.shared.play(.focus)
                withAnimation(.easeInOut(duration: 0.16)) {
                    if personalizeCardIndex == 0 {
                        personalizeCardIndex = 1
                    } else if personalizeCardIndex == 1 {
                        personalizeCardIndex = 4
                    } else if personalizeCardIndex == 2 {
                        personalizeCardIndex = 3
                    }
                }
            case .navigateLeft:
                if personalizeCardIndex == 2 {
                    SoundEffectService.shared.play(.focus)
                    withAnimation(.easeInOut(duration: 0.16)) {
                        personalizeCardIndex = 1
                    }
                } else if personalizeCardIndex == 3 {
                    SoundEffectService.shared.play(.focus)
                    withAnimation(.easeInOut(duration: 0.16)) {
                        personalizeCardIndex = 4
                    }
                } else {
                    enterLeftRailFocus()
                }
            case .navigateRight:
                if personalizeCardIndex == 1 {
                    SoundEffectService.shared.play(.focus)
                    withAnimation(.easeInOut(duration: 0.16)) {
                        personalizeCardIndex = 2
                    }
                } else if personalizeCardIndex == 4 {
                    SoundEffectService.shared.play(.focus)
                    withAnimation(.easeInOut(duration: 0.16)) {
                        personalizeCardIndex = 3
                    }
                }
            case .confirm:
                SoundEffectService.shared.play(.click)
                handlePersonalizeOuterConfirm()
            default:
                break
            }
            return
        }
        
        // Level 2: Inside Card Mode
        if action == .cancel {
            SoundEffectService.shared.play(.click)
            withAnimation(.easeInOut(duration: 0.16)) {
                isInsidePersonalizeCard = false
            }
            return
        }
        
        switch personalizeCardIndex {
        case 1:
            handlePersonalizeLanguageAction(action)
        case 2:
            handlePersonalizeColorAndGlassAction(action)
        case 3:
            handlePersonalizeAppearanceAction(action)
        default:
            break
        }
    }
    
    private func handlePersonalizeOuterConfirm() {
        switch personalizeCardIndex {
        case 0: // Reset Defaults
            withAnimation(.spring(response: 0.30, dampingFraction: 0.80)) {
                highlightTheme = .electricPurple
                iconAppearanceMode = .default
                SoundEffectService.shared.isSoundEnabled = true
                launcherLanguage = .system
                isLiquidGlassEnabled = true
                liquidGlassIntensity = 1.0
                liquidGlassAppearance = .liquid
            }
        case 4: // Sound Effects Toggle
            withAnimation(.spring(response: 0.30, dampingFraction: 0.80)) {
                SoundEffectService.shared.isSoundEnabled.toggle()
            }
        default: // Cards 1, 2, 3: Enter Card
            if personalizeCardIndex == 1 {
                let langs = AppLanguage.sortedForDisplay
                personalizeLangFocus = langs.firstIndex(of: launcherLanguage) ?? 0
            }
            withAnimation(.easeInOut(duration: 0.16)) {
                isInsidePersonalizeCard = true
            }
        }
    }
    
    // MARK: - Card 1: Launcher Language
    private func handlePersonalizeLanguageAction(_ action: GamepadAction) {
        let langs = AppLanguage.sortedForDisplay
        let count = langs.count
        guard count > 0 else { return }
        switch action {
        case .navigateUp, .navigateLeft:
            SoundEffectService.shared.play(.click)
            let cur = langs.firstIndex(of: launcherLanguage) ?? personalizeLangFocus
            let prev = (cur - 1 + count) % count
            personalizeLangFocus = prev
            withAnimation(.spring(response: 0.28, dampingFraction: 0.78)) {
                launcherLanguage = langs[prev]
            }
        case .navigateDown, .navigateRight, .confirm:
            SoundEffectService.shared.play(.click)
            let cur = langs.firstIndex(of: launcherLanguage) ?? personalizeLangFocus
            let next = (cur + 1) % count
            personalizeLangFocus = next
            withAnimation(.spring(response: 0.28, dampingFraction: 0.78)) {
                launcherLanguage = langs[next]
            }
        default:
            break
        }
    }
    
    // MARK: - Card 2: Highlight Color & Liquid Glass
    private func handlePersonalizeColorAndGlassAction(_ action: GamepadAction) {
        let themes = LauncherHighlightTheme.allCases
        let maxThemeIdx = themes.count - 1 // 8
        switch action {
        case .navigateUp:
            SoundEffectService.shared.play(.focus)
            if personalizeColorFocus > 4 && personalizeColorFocus <= maxThemeIdx {
                personalizeColorFocus -= 5
            } else if personalizeColorFocus == 9 {
                personalizeColorFocus = maxThemeIdx
            } else if personalizeColorFocus == 10 {
                personalizeColorFocus = 9
            }
        case .navigateDown:
            SoundEffectService.shared.play(.focus)
            if personalizeColorFocus <= 3 {
                personalizeColorFocus += 5
                if personalizeColorFocus > maxThemeIdx { personalizeColorFocus = maxThemeIdx }
            } else if personalizeColorFocus <= maxThemeIdx {
                personalizeColorFocus = 9
            } else if personalizeColorFocus == 9 {
                personalizeColorFocus = 10
            }
        case .navigateLeft:
            if personalizeColorFocus <= maxThemeIdx {
                SoundEffectService.shared.play(.focus)
                personalizeColorFocus = max(0, personalizeColorFocus - 1)
            } else if personalizeColorFocus == 9 {
                SoundEffectService.shared.play(.click)
                liquidGlassIntensity = max(0.0, round((liquidGlassIntensity - 0.05) * 100) / 100)
            } else if personalizeColorFocus == 10 {
                SoundEffectService.shared.play(.click)
                isLiquidGlassEnabled.toggle()
            }
        case .navigateRight:
            if personalizeColorFocus <= maxThemeIdx {
                SoundEffectService.shared.play(.focus)
                personalizeColorFocus = min(maxThemeIdx, personalizeColorFocus + 1)
            } else if personalizeColorFocus == 9 {
                SoundEffectService.shared.play(.click)
                liquidGlassIntensity = min(1.0, round((liquidGlassIntensity + 0.05) * 100) / 100)
            } else if personalizeColorFocus == 10 {
                SoundEffectService.shared.play(.click)
                isLiquidGlassEnabled.toggle()
            }
        case .confirm:
            SoundEffectService.shared.play(.click)
            if personalizeColorFocus <= maxThemeIdx {
                withAnimation(.spring(response: 0.28, dampingFraction: 0.78)) {
                    highlightTheme = themes[personalizeColorFocus]
                }
            } else if personalizeColorFocus == 9 {
                withAnimation(.spring(response: 0.28, dampingFraction: 0.78)) {
                    liquidGlassIntensity = (liquidGlassIntensity >= 0.5) ? 0.0 : 1.0
                }
            } else if personalizeColorFocus == 10 {
                withAnimation(.spring(response: 0.28, dampingFraction: 0.78)) {
                    isLiquidGlassEnabled.toggle()
                }
            }
        default:
            break
        }
    }
    
    // MARK: - Card 3: System Appearance (App Icon & Menu Bar Icon)
    private func handlePersonalizeAppearanceAction(_ action: GamepadAction) {
        let iconModes = AppIconAppearanceMode.allCases
        let menuModes = MenuBarIconStyle.allCases
        
        switch action {
        case .navigateUp, .navigateDown:
            SoundEffectService.shared.play(.focus)
            // Toggle between Icon row (0) and Menu Bar row (1)
            // We use personalizeMenuBarFocus >= 0 to track section: 0 for icon, 1 for menubar
            if personalizeLangFocus == 0 {
                personalizeLangFocus = 1
            } else {
                personalizeLangFocus = 0
            }
        case .navigateLeft:
            SoundEffectService.shared.play(.focus)
            if personalizeLangFocus == 0 {
                personalizeIconFocus = (personalizeIconFocus - 1 + iconModes.count) % iconModes.count
            } else {
                personalizeMenuBarFocus = (personalizeMenuBarFocus - 1 + menuModes.count) % menuModes.count
            }
        case .navigateRight:
            SoundEffectService.shared.play(.focus)
            if personalizeLangFocus == 0 {
                personalizeIconFocus = (personalizeIconFocus + 1) % iconModes.count
            } else {
                personalizeMenuBarFocus = (personalizeMenuBarFocus + 1) % menuModes.count
            }
        case .confirm:
            SoundEffectService.shared.play(.click)
            if personalizeLangFocus == 0 {
                if personalizeIconFocus < iconModes.count {
                    withAnimation(.spring(response: 0.28, dampingFraction: 0.78)) {
                        iconAppearanceMode = iconModes[personalizeIconFocus]
                    }
                }
            } else {
                if personalizeMenuBarFocus < menuModes.count {
                    withAnimation(.spring(response: 0.28, dampingFraction: 0.78)) {
                        menuBarIconStyle = menuModes[personalizeMenuBarFocus]
                    }
                }
            }
        default:
            break
        }
    }
}
