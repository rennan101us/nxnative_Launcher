import Foundation
import SwiftUI
import AppKit

extension AppViewModel {
    
    public func currentFilteredCompatibleGames() -> [CompatibleGameItem] {
        var list = compatibleGames
        let query = compatibilitySearchText.trimmingCharacters(in: .whitespaces).lowercased()
        if !query.isEmpty {
            list = list.filter {
                $0.title.lowercased().contains(query) ||
                $0.titleId.lowercased().contains(query) ||
                $0.engine.lowercased().contains(query) ||
                $0.graphicsApi.lowercased().contains(query)
            }
        }
        
        if let maxRam = compatibilityRamFilter {
            list = list.filter { $0.minRamGB <= maxRam }
        }
        
        if let maxChip = compatibilityChipFilter {
            list = list.filter { $0.minChipTier <= maxChip }
        }

        if let targetGpu = compatibilityAndroidGpuFilter {
            list = list.filter { game in
                game.isAndroidSupported && game.androidGpuTier <= targetGpu
            }
        }

        if compatibilityGenerationFilter == .switch1 {
            list = list.filter { $0.isSwitch1 }
        } else if compatibilityGenerationFilter == .switch2 {
            list = list.filter { $0.isSwitch2 }
        }

        if compatibilityPlatformFilter != .all {
            let platformFilter = compatibilityPlatformFilter
            list = list.filter { $0.supports(platformFilter) }
        }

        if compatibilityOnlyMyDevice {
            let myRam = macPhysicalMemoryGB
            list = list.filter { $0.minRamGB <= myRam }
        }
        
        if filterOnlyAvailableInCloud {
            list = list.filter { cloudAvailableGames[$0.titleId.uppercased()] != nil }
        }
        
        if compatibilityNameFilter == "New" {
            list = list.sorted { lhs, rhs in
                if lhs.addedTimestamp != rhs.addedTimestamp {
                    return lhs.addedTimestamp > rhs.addedTimestamp
                }
                return lhs.title.localizedCaseInsensitiveCompare(rhs.title) == .orderedAscending
            }
        } else if compatibilityNameFilter != "All" && !compatibilityNameFilter.isEmpty {
            if compatibilityNameFilter == "#" {
                list = list.filter { game in
                    guard let first = game.title.trimmingCharacters(in: .whitespaces).first else { return false }
                    return !first.isLetter
                }
            } else {
                list = list.filter { game in
                    let title = game.title.trimmingCharacters(in: .whitespaces)
                    return title.prefix(1).localizedCaseInsensitiveCompare(compatibilityNameFilter) == .orderedSame
                }
            }
        }
        
        return list
    }
    
    public func handleCompatibilityNavigateLeft() {
        if compatibilityFocusArea == .filters {
            if compatibilityToolbarFocusIndex > 0 {
                compatibilityToolbarFocusIndex -= 1
                SoundEffectService.shared.play(.focus)
            } else {
                enterLeftRailFocus()
            }
        } else {
            if compatibilityDisplayMode == .list {
                enterLeftRailFocus()
            } else {
                let columns = max(1, compatibilityGridColumnCount)
                if focusedCompatibilityIndex % columns == 0 {
                    enterLeftRailFocus()
                } else if focusedCompatibilityIndex > 0 {
                    focusedCompatibilityIndex -= 1
                    SoundEffectService.shared.play(.focus)
                }
            }
        }
    }

    public func handleCompatibilityNavigateRight() {
        if compatibilityFocusArea == .filters {
            if compatibilityToolbarFocusIndex < 5 {
                compatibilityToolbarFocusIndex += 1
                SoundEffectService.shared.play(.focus)
            }
        } else {
            let games = currentFilteredCompatibleGames()
            if focusedCompatibilityIndex < games.count - 1 {
                focusedCompatibilityIndex += 1
                SoundEffectService.shared.play(.focus)
            }
        }
    }

    public func handleCompatibilityNavigateUp() {
        if compatibilityFocusArea == .filters {
            _ = enterTopHeaderFocus(preferred: .search)
            return
        }
        if compatibilityDisplayMode == .list {
            if focusedCompatibilityIndex > 0 {
                focusedCompatibilityIndex -= 1
                SoundEffectService.shared.play(.focus)
            } else {
                compatibilityFocusArea = .filters
                SoundEffectService.shared.play(.focus)
            }
        } else {
            let columns = max(1, compatibilityGridColumnCount)
            let currentRow = focusedCompatibilityIndex / columns
            let currentCol = focusedCompatibilityIndex % columns
            if currentRow > 0 {
                let targetIndex = (currentRow - 1) * columns + currentCol
                let games = currentFilteredCompatibleGames()
                focusedCompatibilityIndex = min(targetIndex, games.count - 1)
                SoundEffectService.shared.play(.focus)
            } else {
                compatibilityFocusArea = .filters
                SoundEffectService.shared.play(.focus)
            }
        }
    }
    
    public func handleCompatibilityNavigateDown() {
        let games = currentFilteredCompatibleGames()
        guard !games.isEmpty else { return }
        
        if compatibilityFocusArea == .filters {
            compatibilityFocusArea = .games
            focusedCompatibilityIndex = min(focusedCompatibilityIndex, games.count - 1)
            SoundEffectService.shared.play(.focus)
        } else {
            if compatibilityDisplayMode == .list {
                if focusedCompatibilityIndex < games.count - 1 {
                    focusedCompatibilityIndex += 1
                    SoundEffectService.shared.play(.focus)
                }
            } else {
                let columns = max(1, compatibilityGridColumnCount)
                let currentRow = focusedCompatibilityIndex / columns
                let currentCol = focusedCompatibilityIndex % columns
                let targetSameCol = (currentRow + 1) * columns + currentCol
                
                if targetSameCol < games.count {
                    focusedCompatibilityIndex = targetSameCol
                    SoundEffectService.shared.play(.focus)
                } else {
                    // Check if the next row exists (even if partially filled)
                    let nextRowStart = (currentRow + 1) * columns
                    if nextRowStart < games.count {
                        focusedCompatibilityIndex = games.count - 1
                        SoundEffectService.shared.play(.focus)
                    }
                    // Already at the bottom row: do nothing, do not jump or wrap
                }
            }
        }
    }
    
    public func handleCompatibilityPageUp() {
        let games = currentFilteredCompatibleGames()
        guard !games.isEmpty else { return }
        let columns = max(1, compatibilityGridColumnCount)
        let stride = compatibilityDisplayMode == .list ? 6 : (columns * 4)
        if focusedCompatibilityIndex >= stride {
            focusedCompatibilityIndex -= stride
            SoundEffectService.shared.play(.focus)
        } else {
            focusedCompatibilityIndex = 0
            SoundEffectService.shared.play(.focus)
        }
    }
    
    public func handleCompatibilityPageDown() {
        let games = currentFilteredCompatibleGames()
        guard !games.isEmpty else { return }
        let columns = max(1, compatibilityGridColumnCount)
        let stride = compatibilityDisplayMode == .list ? 6 : (columns * 4)
        if focusedCompatibilityIndex + stride < games.count {
            focusedCompatibilityIndex += stride
            SoundEffectService.shared.play(.focus)
        } else {
            focusedCompatibilityIndex = games.count - 1
            SoundEffectService.shared.play(.focus)
        }
    }
    
    public func handleCompatibilityHome() {
        if compatibilityFocusArea == .games {
            focusedCompatibilityIndex = 0
            SoundEffectService.shared.play(.focus)
        }
    }
    
    public func handleCompatibilityEnd() {
        let games = currentFilteredCompatibleGames()
        guard !games.isEmpty else { return }
        if compatibilityFocusArea == .games {
            focusedCompatibilityIndex = games.count - 1
            SoundEffectService.shared.play(.focus)
        }
    }
    
    public func handleCompatibilityConfirm() {
        let games = currentFilteredCompatibleGames()
        if compatibilityFocusArea == .filters {
            SoundEffectService.shared.play(.click)
            switch compatibilityToolbarFocusIndex {
            case 0:
                compatibilityNameFilter = (compatibilityNameFilter == "New") ? "All" : "New"
                focusedCompatibilityIndex = 0
            case 1:
                let order: [SwitchGenerationFilter] = [.all, .switch1, .switch2]
                let idx = order.firstIndex(of: compatibilityGenerationFilter) ?? 0
                compatibilityGenerationFilter = order[(idx + 1) % order.count]
                compatibilityNameFilter = "All"
                focusedCompatibilityIndex = 0
            case 2:
                let platforms = CompatibilityPlatformFilter.allCases
                let idx = platforms.firstIndex(of: compatibilityPlatformFilter) ?? 0
                compatibilityPlatformFilter = platforms[(idx + 1) % platforms.count]
                focusedCompatibilityIndex = 0
            case 3:
                let rams: [Int?] = [nil, 4, 6, 8, 16]
                let idx = rams.firstIndex(where: { $0 == compatibilityRamFilter }) ?? 0
                compatibilityRamFilter = rams[(idx + 1) % rams.count]
                focusedCompatibilityIndex = 0
            case 4:
                compatibilityDisplayMode = (compatibilityDisplayMode == .list) ? .grid : .list
            case 5:
                loadCompatibleGames(forceRefresh: true)
            default:
                if !games.isEmpty {
                    compatibilityFocusArea = .games
                    focusedCompatibilityIndex = 0
                }
            }
        } else {
            guard focusedCompatibilityIndex >= 0 && focusedCompatibilityIndex < games.count else { return }
            let targetGame = games[focusedCompatibilityIndex]

            SoundEffectService.shared.play(.click)
            if let url = targetGame.githubUrl {
                NSWorkspace.shared.open(url)
            }
        }
    }
    
    public func handleCompatibilityCancel() {
        if compatibilityFocusArea == .games {
            SoundEffectService.shared.play(.click)
            compatibilityFocusArea = .filters
        }
    }
    
    public func handleCompatibilitySecondaryAction() {
        let games = currentFilteredCompatibleGames()
        guard focusedCompatibilityIndex >= 0 && focusedCompatibilityIndex < games.count else { return }
        let targetGame = games[focusedCompatibilityIndex]
        if let url = targetGame.githubUrl {
            SoundEffectService.shared.play(.click)
            NSWorkspace.shared.open(url)
        }
    }
}
