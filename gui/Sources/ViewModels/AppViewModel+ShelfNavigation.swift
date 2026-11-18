import Foundation
import AppKit

extension AppViewModel {
    // MARK: - Unified Carousel & Action Menu Navigation
    public func handleLibraryNavigateLeft() {
        guard !isGameActionMenuPresented else { return }
        let items = unifiedItems(for: visibleLibraryGamesForCarousel)
        if focusedUnifiedIndex <= 0 || items.isEmpty && focusedUnifiedIndex == 0 {
            enterLeftRailFocus()
            return
        }
        handleUnifiedNavigateLeft(items: items)
    }

    public func handleLibraryNavigateRight() {
        guard !isGameActionMenuPresented else { return }
        let items = unifiedItems(for: visibleLibraryGamesForCarousel)
        handleUnifiedNavigateRight(items: items)
    }

    public func handleLibraryNavigateUp() {
        if isGameActionMenuPresented {
            if gameActionFocusedIndex > 0 {
                gameActionFocusedIndex -= 1
                SoundEffectService.shared.play(.focus)
            }
            return
        }
        let hasHeroTarget = currentHeroTarget.ported != nil || currentHeroTarget.unported != nil
        if hasHeroTarget {
            isFocusOnHeroBar = true
            heroActionFocusIndex = 0
            SoundEffectService.shared.play(.focus)
        } else {
            _ = enterTopHeaderFocus(preferred: .addGame)
        }
    }

    public func handleLibraryNavigateDown() {
        if isGameActionMenuPresented {
            if gameActionFocusedIndex < 8 {
                gameActionFocusedIndex += 1
                SoundEffectService.shared.play(.focus)
            }
            return
        }
        enterBottomZoomFocus()
    }
}
