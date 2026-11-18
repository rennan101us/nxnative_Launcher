import Foundation
import SwiftUI

extension AppViewModel {
    /// Unified gamepad/keyboard navigation handler for Tab 5 (Console / Logs).
    public func handleLogsNavigation(_ input: UnifiedNavInput) {
        switch input {
        case .navigateLeft:
            if logsFocusIndex > 0 {
                logsFocusIndex -= 1
                SoundEffectService.shared.play(.focus)
            } else {
                enterLeftRailFocus()
            }
        case .navigateRight:
            if logsFocusIndex < 2 {
                logsFocusIndex += 1
                SoundEffectService.shared.play(.focus)
            }
        case .navigateUp, .pageUp, .home:
            if logsFocusIndex == 0 && input == .navigateUp && shouldShowProvisioningHeaderPill {
                _ = enterTopHeaderFocus(preferred: .provisioningPill)
            } else {
                SoundEffectService.shared.play(.focus)
                logsScrollTrigger = -abs(logsScrollTrigger == 0 ? 1 : logsScrollTrigger + 1)
            }
        case .navigateDown, .pageDown, .end:
            SoundEffectService.shared.play(.focus)
            logsScrollTrigger = abs(logsScrollTrigger) + 1
        case .confirm:
            SoundEffectService.shared.play(.click)
            switch logsFocusIndex {
            case 0:
                logsAutoScroll.toggle()
            case 1:
                handleSecondaryAction()
            case 2:
                handleContextAction()
            default:
                break
            }
        case .secondaryAction:
            SoundEffectService.shared.play(.click)
            handleSecondaryAction()
        case .contextAction:
            handleContextAction()
        default:
            break
        }
    }
}
