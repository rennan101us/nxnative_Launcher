import Foundation
import AppKit

extension AppViewModel {
    public func selectUnifiedItem(at idx: Int, items: [UnifiedLibraryItem], playSound: Bool = true) {
        guard items.indices.contains(idx) else {
            let clamped = max(0, min(idx, items.count))
            focusedUnifiedIndex = clamped
            if playSound {
                SoundEffectService.shared.play(.focus)
            }
            return
        }
        focusedUnifiedIndex = idx
        let item = items[idx]
        switch item {
        case .ported(let game):
            let targetPath = game.url.standardizedFileURL.path
            if game.platform == .macApp {
                if game.isSwitch2 {
                    activeLibraryShelf = .switch2
                    if let sIdx = switch2LibraryGames.firstIndex(where: { $0.url.standardizedFileURL.path == targetPath || $0.id == game.id }) {
                        focusedSwitch2Index = sIdx
                    }
                } else {
                    activeLibraryShelf = .mac
                    if let mIdx = switch1LibraryGames.firstIndex(where: { $0.url.standardizedFileURL.path == targetPath || $0.id == game.id }) {
                        focusedMacIndex = mIdx
                    }
                }
            } else if game.platform == .ios {
                activeLibraryShelf = .ios
                if let iIdx = iosLibraryGames.firstIndex(where: { $0.url.standardizedFileURL.path == targetPath || $0.id == game.id }) {
                    focusedIosIndex = iIdx
                }
            } else {
                activeLibraryShelf = .nonSwitch
                if let nIdx = nonSwitchLibraryGames.firstIndex(where: { $0.url.standardizedFileURL.path == targetPath || $0.id == game.id }) {
                    focusedNonSwitchIndex = nIdx
                }
            }
            syncFocusedGameIndex()
        case .unported(let unported):
            activeLibraryShelf = .unportedSwitch
            if !isBuilding {
                selectedGame = unported
            }
            if let uIdx = unportedGames.firstIndex(where: { $0.id == unported.id }) {
                focusedUnportedGameIndex = uIdx
            }
        }
        if playSound {
            SoundEffectService.shared.play(.focus)
        }
    }

    /// Reconciles unified grid focus, shelf focus, and Hero selection after library scans, port completions, or filter changes.
    public func reconcileLibraryFocusState(preferredPortedURL: URL? = nil) {
        if focusedGameIndex >= libraryGames.count {
            focusedGameIndex = max(0, libraryGames.count - 1)
        }
        focusedMacIndex = max(0, min(focusedMacIndex, max(0, switch1LibraryGames.count - 1)))
        focusedSwitch2Index = max(0, min(focusedSwitch2Index, max(0, switch2LibraryGames.count - 1)))
        focusedIosIndex = max(0, min(focusedIosIndex, max(0, iosLibraryGames.count - 1)))
        focusedNonSwitchIndex = max(0, min(focusedNonSwitchIndex, max(0, nonSwitchLibraryGames.count - 1)))
        focusedUnportedGameIndex = max(0, min(focusedUnportedGameIndex, max(0, unportedGames.count - 1)))

        if !isBuilding, let sel = selectedGame, !unportedGames.contains(where: { $0.id == sel.id }) {
            selectedGame = unportedGames.first
        }

        let visibleGames: [PortedGame] = {
            let trimmed = librarySearchText.trimmingCharacters(in: .whitespaces)
            if trimmed.isEmpty { return libraryGames }
            return libraryGames.filter { $0.name.localizedCaseInsensitiveContains(trimmed) }
        }()
        let unified = unifiedItems(for: visibleGames)

        if let targetURL = preferredPortedURL {
            let targetStdPath = targetURL.standardizedFileURL.path
            let matchedGame = libraryGames.first(where: { $0.url.standardizedFileURL.path == targetStdPath })
                ?? libraryGames.first(where: {
                    $0.platform == self.platform &&
                    !self.appName.isEmpty &&
                    $0.name.caseInsensitiveCompare(self.appName) == .orderedSame
                })

            if let portedGame = matchedGame {
                let portedPath = portedGame.url.standardizedFileURL.path
                isFocusOnHeroBar = false
                heroActionFocusIndex = 0
                draggedGame = nil

                if portedGame.platform == .macApp {
                    if portedGame.isSwitch2 {
                        activeLibraryShelf = .switch2
                        if let sIdx = switch2LibraryGames.firstIndex(where: { $0.url.standardizedFileURL.path == portedPath }) {
                            focusedSwitch2Index = sIdx
                        }
                    } else {
                        activeLibraryShelf = .mac
                        if let mIdx = switch1LibraryGames.firstIndex(where: { $0.url.standardizedFileURL.path == portedPath }) {
                            focusedMacIndex = mIdx
                        }
                    }
                } else if portedGame.platform == .ios {
                    activeLibraryShelf = .ios
                    if let iIdx = iosLibraryGames.firstIndex(where: { $0.url.standardizedFileURL.path == portedPath }) {
                        focusedIosIndex = iIdx
                    }
                } else {
                    activeLibraryShelf = .nonSwitch
                    if let nIdx = nonSwitchLibraryGames.firstIndex(where: { $0.url.standardizedFileURL.path == portedPath }) {
                        focusedNonSwitchIndex = nIdx
                    }
                }

                if let uIdx = unified.firstIndex(where: {
                    if case .ported(let g) = $0 {
                        return g.url.standardizedFileURL.path == portedPath
                    }
                    return false
                }) {
                    focusedUnifiedIndex = uIdx
                }
                syncFocusedGameIndex()
                return
            }
        }

        if unified.isEmpty {
            focusedUnifiedIndex = 0
        } else {
            let clamped = max(0, min(focusedUnifiedIndex, unified.count))
            selectUnifiedItem(at: clamped, items: unified, playSound: false)
        }
    }

    public func handleUnifiedNavigateLeft(items: [UnifiedLibraryItem]) {
        if focusedUnifiedIndex <= 0 {
            enterLeftRailFocus()
            return
        }
        let target = focusedUnifiedIndex - 1
        selectUnifiedItem(at: target, items: items)
    }

    public func handleUnifiedNavigateRight(items: [UnifiedLibraryItem]) {
        let target = min(items.count, focusedUnifiedIndex + 1) // index items.count is AddGameCardView
        if target != focusedUnifiedIndex {
            selectUnifiedItem(at: target, items: items)
        }
    }

    public func handleUnifiedNavigateUp(columns: Int = 1, items: [UnifiedLibraryItem]) {
        guard !items.isEmpty else { return }
        if !isFocusOnHeroBar {
            isFocusOnHeroBar = true
            heroActionFocusIndex = 0
            SoundEffectService.shared.play(.focus)
        }
    }

    public func handleUnifiedNavigateDown(columns: Int = 1, items: [UnifiedLibraryItem]) {
        guard !items.isEmpty else { return }
        if isFocusOnHeroBar {
            isFocusOnHeroBar = false
            SoundEffectService.shared.play(.focus)
        }
    }

    public func moveUnifiedItem(fromPath: String, onto targetPath: String, items: [UnifiedLibraryItem]) {
        guard fromPath != targetPath,
              let from = items.firstIndex(where: { $0.path == fromPath }),
              let to = items.firstIndex(where: { $0.path == targetPath }) else { return }

        activateManualOrderMode()

        var newItems = items
        let moved = newItems.remove(at: from)
        newItems.insert(moved, at: to)
        LibraryOrder.saveUnified(newItems)

        if let fromPorted = libraryGames.firstIndex(where: { $0.url.standardized.path == fromPath }),
           let toPorted = libraryGames.firstIndex(where: { $0.url.standardized.path == targetPath }) {
            var games = libraryGames
            let movedGame = games.remove(at: fromPorted)
            games.insert(movedGame, at: toPorted)
            libraryGames = games
            LibraryOrder.save(games)
        }

        selectUnifiedItem(at: to, items: newItems, playSound: false)
        objectWillChange.send()
        SoundEffectService.shared.play(.focus)
    }
}
