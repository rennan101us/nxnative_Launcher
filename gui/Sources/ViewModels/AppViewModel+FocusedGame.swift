import Foundation
import SwiftUI
import AppKit

extension AppViewModel {
    /// Library games filtered identically to `LibraryView.filteredGames` so carousel focus matches the rendered items.
    public var visibleLibraryGamesForCarousel: [PortedGame] {
        let trimmed = librarySearchText.trimmingCharacters(in: .whitespaces)
        if trimmed.isEmpty { return libraryGames }
        return libraryGames.filter { $0.name.localizedCaseInsensitiveContains(librarySearchText) }
    }

    public var currentFocusedGame: PortedGame? {
        let items = unifiedItems(for: visibleLibraryGamesForCarousel)
        if items.indices.contains(focusedUnifiedIndex) {
            if case .ported(let game) = items[focusedUnifiedIndex] {
                return game
            }
            return nil
        }
        // When standing on AddGameCardView (focusedUnifiedIndex == items.count), keep nil if empty or fallback for action menus only if items non-empty?
        if focusedUnifiedIndex >= items.count {
            return nil
        }

        switch activeLibraryShelf {
        case .mac:
            let macs = switch1LibraryGames
            if !macs.isEmpty {
                let clamped = max(0, min(focusedMacIndex, macs.count - 1))
                return macs[clamped]
            }
            return switch2LibraryGames.first ?? iosLibraryGames.first
        case .switch2:
            let s2 = switch2LibraryGames
            if !s2.isEmpty {
                let clamped = max(0, min(focusedSwitch2Index, s2.count - 1))
                return s2[clamped]
            }
            return switch1LibraryGames.first ?? iosLibraryGames.first
        case .ios:
            let ioses = iosLibraryGames
            if !ioses.isEmpty {
                let clamped = max(0, min(focusedIosIndex, ioses.count - 1))
                return ioses[clamped]
            }
            return switch1LibraryGames.first ?? switch2LibraryGames.first
        case .nonSwitch:
            let nons = nonSwitchLibraryGames
            if !nons.isEmpty {
                let clamped = max(0, min(focusedNonSwitchIndex, nons.count - 1))
                return nons[clamped]
            }
            return switch1LibraryGames.first ?? switch2LibraryGames.first
        case .unportedSwitch:
            return nil
        }
    }

    public var currentHeroTarget: (ported: PortedGame?, unported: SelectableGame?) {
        let items = unifiedItems(for: visibleLibraryGamesForCarousel)
        if items.indices.contains(focusedUnifiedIndex) {
            switch items[focusedUnifiedIndex] {
            case .ported(let g): return (g, nil)
            case .unported(let u): return (nil, u)
            }
        }
        if let first = items.first {
            switch first {
            case .ported(let g): return (g, nil)
            case .unported(let u): return (nil, u)
            }
        }
        if let u = focusedUnportedGame ?? unportedGames.first { return (nil, u) }
        return (nil, nil)
    }

    public func executePrimaryUnifiedSelection() {
        let items = unifiedItems(for: visibleLibraryGamesForCarousel)
        if focusedUnifiedIndex == items.count {
            openUnifiedGamePicker()
            return
        }
        guard items.indices.contains(focusedUnifiedIndex) else { return }
        switch items[focusedUnifiedIndex] {
        case .ported(let game):
            if game.isPlayableLocally {
                launchGame(game)
            } else {
                gameForSettingsSheet = game
            }
        case .unported(let unported):
            selectedGame = unported
            gameForPortModal = unported
        }
    }

    public func executeFocusedGameAction() {
        guard let game = currentFocusedGame else { return }
        isGameActionMenuPresented = false
        switch gameActionFocusedIndex {
        case 0:
            if game.isPlayableLocally {
                launchGame(game)
            } else {
                gameForSettingsSheet = game
            }
        case 1:
            gameForSettingsSheet = game
        case 2:
            revealInFinder(url: game.url)
        case 3:
            let profile = GameDetailsProfile.inspect(for: game)
            revealSaveFolder(profile.saveDirectory)
        case 4:
            if game.platform == .ios {
                revealInFinder(url: game.url)
            } else {
                let cover = GameCoverService.shared.coverImage(for: game)
                SaveSyncService.shared.revealCloudGameFolder(for: game, cover: cover)
            }
        case 5:
            openNxDeploymentBatchModal()
        case 6:
            confirmDialogFocusIndex = 1
            gameToHide = game
            showHideConfirm = true
        case 7:
            confirmDialogFocusIndex = 1
            gameToRemove = game
            showRemoveConfirm = true
        case 8:
            confirmDialogFocusIndex = 1
            gameToTrash = game
            showTrashConfirm = true
        default:
            break
        }
    }
}
