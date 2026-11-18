import Foundation
import SwiftUI

extension AppViewModel {
    
    // MARK: - Card 2: Deadzone
    internal func handleControlsDeadzoneAction(_ action: GamepadAction) {
        let pm = InputProfileManager.shared
        var prof = pm.activeProfile
        switch action {
        case .navigateLeft:
            SoundEffectService.shared.play(.click)
            prof.analogDeadzone = max(0.02, min(0.35, round((prof.analogDeadzone - 0.02) * 100) / 100))
            pm.updateProfile(prof)
        case .navigateRight:
            SoundEffectService.shared.play(.click)
            prof.analogDeadzone = max(0.02, min(0.35, round((prof.analogDeadzone + 0.02) * 100) / 100))
            pm.updateProfile(prof)
        default:
            break
        }
    }
    
    // MARK: - Card 3: Rumble / Haptics
    internal func handleControlsHapticsAction(_ action: GamepadAction) {
        let pm = InputProfileManager.shared
        var prof = pm.activeProfile
        switch action {
        case .navigateUp:
            SoundEffectService.shared.play(.focus)
            controlsHapticsFocus = (controlsHapticsFocus - 1 + 4) % 4
            if !prof.enableRumble && (controlsHapticsFocus == 1 || controlsHapticsFocus == 2) {
                controlsHapticsFocus = 0
            }
        case .navigateDown:
            SoundEffectService.shared.play(.focus)
            controlsHapticsFocus = (controlsHapticsFocus + 1) % 4
            if !prof.enableRumble && (controlsHapticsFocus == 1 || controlsHapticsFocus == 2) {
                controlsHapticsFocus = 3
            }
        case .navigateLeft:
            if controlsHapticsFocus == 1 {
                SoundEffectService.shared.play(.click)
                prof.rumbleStrength = max(0.10, min(2.0, round((prof.rumbleStrength - 0.05) * 100) / 100))
                pm.updateProfile(prof)
            }
        case .navigateRight:
            if controlsHapticsFocus == 1 {
                SoundEffectService.shared.play(.click)
                prof.rumbleStrength = max(0.10, min(2.0, round((prof.rumbleStrength + 0.05) * 100) / 100))
                pm.updateProfile(prof)
            }
        case .confirm:
            SoundEffectService.shared.play(.click)
            switch controlsHapticsFocus {
            case 0:
                prof.enableRumble.toggle()
                pm.updateProfile(prof)
            case 2:
                prof.rumbleFloorBoost.toggle()
                pm.updateProfile(prof)
            case 3:
                GameControllerService.shared.testRumble(strength: prof.rumbleStrength, floorBoost: prof.rumbleFloorBoost)
            default:
                break
            }
        default:
            break
        }
    }
    
    // MARK: - Card 4: Mouse Look
    internal func handleControlsMouseAction(_ action: GamepadAction) {
        let pm = InputProfileManager.shared
        var prof = pm.activeProfile
        let maxFocus = (controlsMouseTab == 0) ? 5 : 6 // Switch 1 has 5 sub-items, Switch 2 has 6
        switch action {
        case .navigateUp:
            SoundEffectService.shared.play(.focus)
            controlsMouseFocus = (controlsMouseFocus - 1 + maxFocus) % maxFocus
        case .navigateDown:
            SoundEffectService.shared.play(.focus)
            controlsMouseFocus = (controlsMouseFocus + 1) % maxFocus
        case .navigateLeft:
            if controlsMouseFocus == 0 {
                SoundEffectService.shared.play(.click)
                controlsMouseTab = (controlsMouseTab == 0) ? 1 : 0
            } else if controlsMouseTab == 0 {
                if controlsMouseFocus == 1 {
                    SoundEffectService.shared.play(.click)
                    prof.mouseSensitivity = max(0.5, min(100.0, round((prof.mouseSensitivity - 0.5) * 10) / 10))
                    pm.updateProfile(prof)
                } else if controlsMouseFocus == 4 {
                    SoundEffectService.shared.play(.click)
                    prof.mouseRightStickMode = (prof.mouseRightStickMode == "cursorLock") ? "rightDrag" : "cursorLock"
                    pm.updateProfile(prof)
                }
            } else {
                if controlsMouseFocus == 1 {
                    SoundEffectService.shared.play(.click)
                    prof.mouseSwitch2PointerSpeed = max(0.2, min(5.0, round((prof.mouseSwitch2PointerSpeed - 0.1) * 10) / 10))
                    pm.updateProfile(prof)
                } else if controlsMouseFocus == 3 {
                    SoundEffectService.shared.play(.click)
                    prof.mouseSwitch2PrimaryButton = (prof.mouseSwitch2PrimaryButton == "left") ? "right" : "left"
                    pm.updateProfile(prof)
                } else if controlsMouseFocus == 4 {
                    SoundEffectService.shared.play(.click)
                    prof.mouseSwitch2Side = (prof.mouseSwitch2Side == "right") ? "left" : "right"
                    pm.updateProfile(prof)
                }
            }
        case .navigateRight:
            if controlsMouseFocus == 0 {
                SoundEffectService.shared.play(.click)
                controlsMouseTab = (controlsMouseTab == 0) ? 1 : 0
            } else if controlsMouseTab == 0 {
                if controlsMouseFocus == 1 {
                    SoundEffectService.shared.play(.click)
                    prof.mouseSensitivity = max(0.5, min(100.0, round((prof.mouseSensitivity + 0.5) * 10) / 10))
                    pm.updateProfile(prof)
                } else if controlsMouseFocus == 4 {
                    SoundEffectService.shared.play(.click)
                    prof.mouseRightStickMode = (prof.mouseRightStickMode == "cursorLock") ? "rightDrag" : "cursorLock"
                    pm.updateProfile(prof)
                }
            } else {
                if controlsMouseFocus == 1 {
                    SoundEffectService.shared.play(.click)
                    prof.mouseSwitch2PointerSpeed = max(0.2, min(5.0, round((prof.mouseSwitch2PointerSpeed + 0.1) * 10) / 10))
                    pm.updateProfile(prof)
                } else if controlsMouseFocus == 3 {
                    SoundEffectService.shared.play(.click)
                    prof.mouseSwitch2PrimaryButton = (prof.mouseSwitch2PrimaryButton == "left") ? "right" : "left"
                    pm.updateProfile(prof)
                } else if controlsMouseFocus == 4 {
                    SoundEffectService.shared.play(.click)
                    prof.mouseSwitch2Side = (prof.mouseSwitch2Side == "right") ? "left" : "right"
                    pm.updateProfile(prof)
                }
            }
        case .confirm:
            SoundEffectService.shared.play(.click)
            if controlsMouseFocus == 0 {
                controlsMouseTab = (controlsMouseTab == 0) ? 1 : 0
            } else if controlsMouseTab == 0 {
                switch controlsMouseFocus {
                case 1:
                    prof.mouseAsRightStick.toggle()
                case 2:
                    prof.mouseInvertX.toggle()
                case 3:
                    prof.mouseInvertY.toggle()
                case 4:
                    prof.mouseRightStickMode = (prof.mouseRightStickMode == "cursorLock") ? "rightDrag" : "cursorLock"
                default:
                    break
                }
                pm.updateProfile(prof)
            } else {
                switch controlsMouseFocus {
                case 1:
                    prof.mouseSwitch2Enabled.toggle()
                case 2:
                    prof.mouseSwitch2LockCursor.toggle()
                case 3:
                    prof.mouseSwitch2PrimaryButton = (prof.mouseSwitch2PrimaryButton == "left") ? "right" : "left"
                case 4:
                    prof.mouseSwitch2Side = (prof.mouseSwitch2Side == "right") ? "left" : "right"
                case 5:
                    prof.mouseSwitch2InvertY.toggle()
                default:
                    break
                }
                pm.updateProfile(prof)
            }
        default:
            break
        }
    }
    
    // MARK: - Modal Navigation
    public func handleControlsPlayerModalGamepadAction(_ action: GamepadAction) {
        let pm = InputProfileManager.shared
        switch action {
        case .navigateLeft, .navigateUp:
            SoundEffectService.shared.play(.focus)
            controlsPlayerModalFocus = (controlsPlayerModalFocus - 1 + 8) % 8
        case .navigateRight, .navigateDown:
            SoundEffectService.shared.play(.focus)
            controlsPlayerModalFocus = (controlsPlayerModalFocus + 1) % 8
        case .confirm:
            SoundEffectService.shared.play(.click)
            pm.activePlayerIndex = controlsPlayerModalFocus
            let assigned = pm.profile(forPlayer: controlsPlayerModalFocus)
            pm.activeProfileId = assigned.id
            showControlsPlayerModal = false
        case .cancel:
            SoundEffectService.shared.play(.click)
            showControlsPlayerModal = false
        default:
            break
        }
    }
    
    public func handleControlsProfileModalGamepadAction(_ action: GamepadAction) {
        let pm = InputProfileManager.shared
        let count = pm.profiles.count
        guard count > 0 else { return }
        switch action {
        case .navigateUp:
            SoundEffectService.shared.play(.focus)
            controlsProfileModalFocus = (controlsProfileModalFocus - 1 + count) % count
        case .navigateDown:
            SoundEffectService.shared.play(.focus)
            controlsProfileModalFocus = (controlsProfileModalFocus + 1) % count
        case .confirm:
            SoundEffectService.shared.play(.click)
            let prof = pm.profiles[controlsProfileModalFocus]
            pm.setProfile(prof, forPlayer: pm.activePlayerIndex)
            showControlsProfileModal = false
        case .cancel:
            SoundEffectService.shared.play(.click)
            showControlsProfileModal = false
        default:
            break
        }
    }
}
