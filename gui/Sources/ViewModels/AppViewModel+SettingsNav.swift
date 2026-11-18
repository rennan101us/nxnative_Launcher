import Foundation
import SwiftUI
import AppKit
import UniformTypeIdentifiers

extension AppViewModel {
    /// Ordered focusable row indices for the active game in GameSettingsSheetView.
    public func settingsModalRows(for game: PortedGame) -> [Int] {
        if game.platform == .nonSwitch {
            var rows = [1, 6]
            if activeSettingsConfig.enableGamepadProfile { rows.append(28) }
            rows.append(contentsOf: [11, 12, 8, 9, 10])
            return rows
        }
        let isOot = GameRuntimeConfig.isOotGame(game)
        if game.platform == .ios {
            if iosDeploymentTab == .multiPort {
                return [8, 9, 10]
            }
            var rows = [20, 0, 21, 2, 3, 4, 5]
            if isOot {
                if activeSettingsConfig.ootUpscalerMode != "game" { rows.append(22) }
                rows.append(contentsOf: [23, 24, 25, 26, 27, 13])
            }
            rows.append(contentsOf: [7, 11, 12, 8, 9, 10])
            return rows
        }
        var rows = [20, 0, 21, 1, 2, 3, 4, 5]
        if isOot {
            if activeSettingsConfig.ootUpscalerMode != "game" { rows.append(22) }
            rows.append(contentsOf: [23, 24, 25, 26, 27, 13])
        }
        rows.append(6)
        if activeSettingsConfig.enableGamepadProfile { rows.append(28) }
        rows.append(contentsOf: [7, 29, 11, 12, 8, 9, 10])
        return rows
    }

    /// Presents an image picker panel and applies a custom portrait cover for the game.
    public func selectCustomCover(for game: PortedGame) {
        guard let url = selectCustomArtworkImage(title: tr("settings_modal.cover_panel_title")) else { return }
        SoundEffectService.shared.play(.click)
        _ = GameCoverService.shared.setCustomCover(imageURL: url, for: game)
        SaveSyncService.shared.applySaveDirectoryIcons(for: game)
    }

    /// Presents an image picker panel and applies a custom widescreen background for the game.
    public func selectCustomBackground(for game: PortedGame) {
        guard let url = selectCustomArtworkImage(title: tr("settings_modal.background_panel_title")) else { return }
        SoundEffectService.shared.play(.click)
        _ = GameCoverService.shared.setCustomBackground(imageURL: url, for: game)
    }

    private func selectCustomArtworkImage(title: String) -> URL? {
        let panel = NSOpenPanel()
        panel.title = title
        panel.allowedContentTypes = [
            .jpeg,
            .png,
            .webP,
            UTType(filenameExtension: "svg") ?? .image,
            .image
        ]
        panel.allowsMultipleSelection = false
        panel.canChooseDirectories = false
        guard panel.runModal() == .OK else { return nil }
        return panel.url
    }

    // MARK: - Gamepad Settings Modal Navigation
    public func handleSettingsModalGamepadAction(_ action: GamepadAction) {
        guard let game = gameForSettingsSheet else { return }
        let isOot = (game.titleId?.uppercased() == "0400486024DEC000") || game.name.localizedCaseInsensitiveContains("Ocarina")
        let validRows = settingsModalRows(for: game)
        let currentPos = validRows.firstIndex(of: settingsModalFocusIndex) ?? 0
        
        switch action {
        case .navigateUp:
            SoundEffectService.shared.play(.focus)
            withAnimation(.easeInOut(duration: 0.15)) {
                let nextPos = (currentPos - 1 + validRows.count) % validRows.count
                settingsModalFocusIndex = validRows[nextPos]
                settingsModalSubFocusIndex = 0
            }
            
        case .navigateDown:
            SoundEffectService.shared.play(.focus)
            withAnimation(.easeInOut(duration: 0.15)) {
                let nextPos = (currentPos + 1) % validRows.count
                settingsModalFocusIndex = validRows[nextPos]
                settingsModalSubFocusIndex = 0
            }
            
        case .navigateLeft:
            SoundEffectService.shared.play(.click)
            withAnimation(.easeInOut(duration: 0.15)) {
                switch settingsModalFocusIndex {
                case 20:
                    cycleGamePreset(for: game, isOot: isOot, step: -1)
                case 0:
                    activeSettingsConfig.enable60FPS.toggle()
                case 21:
                    activeSettingsConfig.ootExperimentalFrameGen.toggle()
                case 1:
                    activeSettingsConfig.enableGameMode.toggle()
                case 2:
                    activeSettingsConfig.enableMetalHUD.toggle()
                case 3:
                    activeSettingsConfig.isDockedMode = false
                case 4:
                    let current = activeSettingsConfig.renderScale
                    let updated = max(0.50, round((current - 0.05) * 100) / 100)
                    activeSettingsConfig.renderScale = updated
                case 5:
                    if isOot {
                        let modes = ["off", "metalfx", "game"]
                        let curIdx = modes.firstIndex(of: activeSettingsConfig.ootUpscalerMode) ?? 0
                        let nextIdx = (curIdx - 1 + modes.count) % modes.count
                        activeSettingsConfig.ootUpscalerMode = modes[nextIdx]
                    } else {
                        activeSettingsConfig.enableMetalFXUpscale.toggle()
                    }
                case 22:
                    activeSettingsConfig.ootSharpen = max(0.00, round((activeSettingsConfig.ootSharpen - 0.05) * 100) / 100)
                case 23:
                    activeSettingsConfig.ootFixedResolution.toggle()
                case 24:
                    activeSettingsConfig.ootMicrophone.toggle()
                case 25:
                    activeSettingsConfig.ootResolutionPreset = (activeSettingsConfig.ootResolutionPreset == "potato") ? "normal" : "potato"
                case 26:
                    activeSettingsConfig.ootGfxScaleTier = (activeSettingsConfig.ootGfxScaleTier - 1 + 3) % 3
                case 27:
                    activeSettingsConfig.oot16GBRamMode.toggle()
                case 13:
                    activeSettingsConfig.ootMotionBlur.toggle()
                case 6:
                    activeSettingsConfig.enableGamepadProfile.toggle()
                case 28:
                    cycleGameControllerProfile(step: -1)
                case 7:
                    cycleGameLanguage(for: game, step: -1)
                case 29:
                    toggleICloudSync(for: game)
                case 11:
                    settingsModalSubFocusIndex = (settingsModalSubFocusIndex == 0) ? 1 : 0
                case 12:
                    settingsModalSubFocusIndex = (settingsModalSubFocusIndex - 1 + 3) % 3
                case 8:
                    settingsModalFocusIndex = 10
                case 9:
                    settingsModalFocusIndex = 8
                case 10:
                    settingsModalFocusIndex = 9
                default:
                    break
                }
            }
            
        case .navigateRight:
            SoundEffectService.shared.play(.click)
            withAnimation(.easeInOut(duration: 0.15)) {
                switch settingsModalFocusIndex {
                case 20:
                    cycleGamePreset(for: game, isOot: isOot, step: 1)
                case 0:
                    activeSettingsConfig.enable60FPS.toggle()
                case 21:
                    activeSettingsConfig.ootExperimentalFrameGen.toggle()
                case 1:
                    activeSettingsConfig.enableGameMode.toggle()
                case 2:
                    activeSettingsConfig.enableMetalHUD.toggle()
                case 3:
                    activeSettingsConfig.isDockedMode = true
                case 4:
                    let current = activeSettingsConfig.renderScale
                    let updated = min(1.00, round((current + 0.05) * 100) / 100)
                    activeSettingsConfig.renderScale = updated
                case 5:
                    if isOot {
                        let modes = ["off", "metalfx", "game"]
                        let curIdx = modes.firstIndex(of: activeSettingsConfig.ootUpscalerMode) ?? 0
                        let nextIdx = (curIdx + 1) % modes.count
                        activeSettingsConfig.ootUpscalerMode = modes[nextIdx]
                    } else {
                        activeSettingsConfig.enableMetalFXUpscale.toggle()
                    }
                case 22:
                    activeSettingsConfig.ootSharpen = min(1.00, round((activeSettingsConfig.ootSharpen + 0.05) * 100) / 100)
                case 23:
                    activeSettingsConfig.ootFixedResolution.toggle()
                case 24:
                    activeSettingsConfig.ootMicrophone.toggle()
                case 25:
                    activeSettingsConfig.ootResolutionPreset = (activeSettingsConfig.ootResolutionPreset == "potato") ? "normal" : "potato"
                case 26:
                    activeSettingsConfig.ootGfxScaleTier = (activeSettingsConfig.ootGfxScaleTier + 1) % 3
                case 27:
                    activeSettingsConfig.oot16GBRamMode.toggle()
                case 13:
                    activeSettingsConfig.ootMotionBlur.toggle()
                case 6:
                    activeSettingsConfig.enableGamepadProfile.toggle()
                case 28:
                    cycleGameControllerProfile(step: 1)
                case 7:
                    cycleGameLanguage(for: game, step: 1)
                case 29:
                    toggleICloudSync(for: game)
                case 11:
                    settingsModalSubFocusIndex = (settingsModalSubFocusIndex == 0) ? 1 : 0
                case 12:
                    settingsModalSubFocusIndex = (settingsModalSubFocusIndex + 1) % 3
                case 8:
                    settingsModalFocusIndex = 9
                case 9:
                    settingsModalFocusIndex = 10
                case 10:
                    settingsModalFocusIndex = 8
                default:
                    break
                }
            }
            
        case .confirm:
            SoundEffectService.shared.play(.click)
            withAnimation(.easeInOut(duration: 0.15)) {
                switch settingsModalFocusIndex {
                case 20:
                    cycleGamePreset(for: game, isOot: isOot, step: 1)
                case 0:
                    activeSettingsConfig.enable60FPS.toggle()
                case 21:
                    activeSettingsConfig.ootExperimentalFrameGen.toggle()
                case 1:
                    activeSettingsConfig.enableGameMode.toggle()
                case 2:
                    activeSettingsConfig.enableMetalHUD.toggle()
                case 3:
                    activeSettingsConfig.isDockedMode.toggle()
                case 4:
                    if activeSettingsConfig.renderScale < 0.70 {
                        activeSettingsConfig.renderScale = 0.75
                    } else if activeSettingsConfig.renderScale < 0.95 {
                        activeSettingsConfig.renderScale = 1.00
                    } else {
                        activeSettingsConfig.renderScale = 0.50
                    }
                case 5:
                    if isOot {
                        let modes = ["off", "metalfx", "game"]
                        let curIdx = modes.firstIndex(of: activeSettingsConfig.ootUpscalerMode) ?? 0
                        let nextIdx = (curIdx + 1) % modes.count
                        activeSettingsConfig.ootUpscalerMode = modes[nextIdx]
                    } else {
                        activeSettingsConfig.enableMetalFXUpscale.toggle()
                    }
                case 22:
                    if activeSettingsConfig.ootSharpen < 0.30 {
                        activeSettingsConfig.ootSharpen = 0.35
                    } else if activeSettingsConfig.ootSharpen < 0.45 {
                        activeSettingsConfig.ootSharpen = 0.50
                    } else {
                        activeSettingsConfig.ootSharpen = 0.20
                    }
                case 23:
                    activeSettingsConfig.ootFixedResolution.toggle()
                case 24:
                    activeSettingsConfig.ootMicrophone.toggle()
                case 25:
                    activeSettingsConfig.ootResolutionPreset = (activeSettingsConfig.ootResolutionPreset == "potato") ? "normal" : "potato"
                case 26:
                    activeSettingsConfig.ootGfxScaleTier = (activeSettingsConfig.ootGfxScaleTier + 1) % 3
                case 27:
                    activeSettingsConfig.oot16GBRamMode.toggle()
                case 13:
                    activeSettingsConfig.ootMotionBlur.toggle()
                case 6:
                    activeSettingsConfig.enableGamepadProfile.toggle()
                case 28:
                    cycleGameControllerProfile(step: 1)
                case 7:
                    cycleGameLanguage(for: game, step: 1)
                case 29:
                    toggleICloudSync(for: game)
                case 11:
                    if settingsModalSubFocusIndex == 0 {
                        selectCustomCover(for: game)
                    } else {
                        selectCustomBackground(for: game)
                    }
                case 12:
                    let subAction = settingsModalSubFocusIndex
                    gameForSettingsSheet = nil
                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.25) {
                        self.confirmDialogFocusIndex = 1
                        switch subAction {
                        case 0:
                            self.gameToHide = game
                            self.showHideConfirm = true
                        case 1:
                            self.gameToRemove = game
                            self.showRemoveConfirm = true
                        default:
                            self.gameToTrash = game
                            self.showTrashConfirm = true
                        }
                    }
                case 8:
                    var resetCfg = isOot ? GameRuntimeConfig.defaultOotConfig() : GameRuntimeConfig()
                    resetCfg.gameLanguage = LibraryScanner.shared.defaultGameLanguage(at: game.url)
                    activeSettingsConfig = resetCfg
                case 9:
                    gameForSettingsSheet = nil
                case 10:
                    saveRuntimeConfig(activeSettingsConfig, for: game)
                    gameForSettingsSheet = nil
                default:
                    break
                }
            }
            
        case .secondaryAction, .options:
            SoundEffectService.shared.play(.click)
            saveRuntimeConfig(activeSettingsConfig, for: game)
            gameForSettingsSheet = nil
            
        case .cancel:
            SoundEffectService.shared.play(.click)
            gameForSettingsSheet = nil
            
        case .contextAction:
            SoundEffectService.shared.play(.click)
            var resetCfg = isOot ? GameRuntimeConfig.defaultOotConfig() : GameRuntimeConfig()
            resetCfg.gameLanguage = LibraryScanner.shared.defaultGameLanguage(at: game.url)
            activeSettingsConfig = resetCfg
            
        default:
            break
        }
    }

    private func cycleGameLanguage(for game: PortedGame, step: Int) {
        let options = LibraryScanner.shared.supportedGameLanguages(at: game.url)
        guard !options.isEmpty else { return }
        let fallback = LibraryScanner.shared.defaultGameLanguage(at: game.url)
        let rawCurrent = activeSettingsConfig.gameLanguage?.trimmingCharacters(in: .whitespacesAndNewlines)
        let currentCode = (rawCurrent.flatMap { options.contains($0) ? $0 : nil })
            ?? (options.contains(fallback) ? fallback : options[0])
        let currentIdx = options.firstIndex(of: currentCode) ?? 0
        let nextIdx = (currentIdx + step + options.count) % options.count
        activeSettingsConfig.gameLanguage = options[nextIdx]
    }

    private func cycleGamePreset(for game: PortedGame, isOot: Bool, step: Int) {
        let presets = GamePresetService.shared.allPresets(for: game)
        guard !presets.isEmpty else { return }
        let matchedIdx = presets.firstIndex { preset in
            activeSettingsConfig.matchesPerformanceSettings(of: preset.config, isOot: isOot)
        }
        let nextIdx: Int
        if let cur = matchedIdx {
            nextIdx = (cur + step + presets.count) % presets.count
        } else {
            nextIdx = (step >= 0) ? 0 : (presets.count - 1)
        }
        activeSettingsConfig.applyPerformanceSettings(from: presets[nextIdx].config, isOot: isOot)
    }

    private func toggleICloudSync(for game: PortedGame) {
        let saveService = SaveSyncService.shared
        let next = !saveService.isICloudSyncEnabled(for: game)
        let cover = GameCoverService.shared.coverImage(for: game)
        saveService.setICloudSyncEnabled(next, for: game, cover: cover)
    }

    private func cycleGameControllerProfile(step: Int) {
        let profiles = InputProfileManager.shared.profiles
        let options: [String?] = [nil] + profiles.map { $0.id.uuidString }
        guard !options.isEmpty else { return }
        let currentVal = activeSettingsConfig.playerProfileIds?["0"] ?? activeSettingsConfig.controllerProfileId
        let currentIdx = options.firstIndex(where: { $0 == currentVal }) ?? 0
        let nextIdx = (currentIdx + step + options.count) % options.count
        let chosen = options[nextIdx]
        activeSettingsConfig.controllerProfileId = chosen
        var map = activeSettingsConfig.playerProfileIds ?? [:]
        if let chosen {
            map["0"] = chosen
        } else {
            map.removeValue(forKey: "0")
        }
        activeSettingsConfig.playerProfileIds = map.isEmpty ? nil : map
    }
}
