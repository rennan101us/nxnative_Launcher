import Foundation
import SwiftUI

extension AppViewModel {
    public func validPortModalIndices() -> [Int] {
        var indices = [0, 1, 2] // Platform macOS / iOS/iPadOS / Android
        if platform == .ios {
            indices.append(contentsOf: [3, 4]) // Deploy Now / Later
            if autoDeployToDeviceOnFinish {
                indices.append(13) // Target iOS Device / Refresh
                if !DeviceDeploymentService.shared.signingTeams.isEmpty {
                    indices.append(14) // Signing Team
                }
            }
            indices.append(15) // SSD USB-C Storage toggle
        }
        indices.append(5) // Advanced toggle
        if isPortAdvancedExpanded {
            indices.append(contentsOf: [6, 7, 8, 9, 10, 16]) // RomFS, toggles, Output folder
        }
        indices.append(contentsOf: [11, 12]) // Cancel / Start Port
        return indices
    }

    public func handlePortModalGamepadAction(_ action: GamepadAction) {
        guard gameForPortModal != nil else { return }
        switch action {
        case .navigateUp:
            navigatePortModalFocus(direction: -1)
        case .navigateDown:
            navigatePortModalFocus(direction: 1)
        case .navigateLeft:
            handlePortModalLeft()
        case .navigateRight:
            handlePortModalRight()
        case .confirm:
            handlePortModalConfirm()
        case .cancel:
            SoundEffectService.shared.play(.click)
            gameForPortModal = nil
        default:
            break
        }
    }

    public func handlePortModalKeyboardKey(_ key: String) {
        guard gameForPortModal != nil else { return }
        switch key {
        case "up":
            navigatePortModalFocus(direction: -1)
        case "down":
            navigatePortModalFocus(direction: 1)
        case "left":
            handlePortModalLeft()
        case "right":
            handlePortModalRight()
        case "return", "space":
            handlePortModalConfirm()
        case "escape":
            SoundEffectService.shared.play(.click)
            gameForPortModal = nil
        default:
            break
        }
    }

    private func navigatePortModalFocus(direction: Int) {
        let valid = validPortModalIndices()
        guard !valid.isEmpty else { return }
        SoundEffectService.shared.play(.focus)
        
        if let currentPos = valid.firstIndex(of: portModalFocusIndex) {
            let nextPos = (currentPos + direction + valid.count) % valid.count
            portModalFocusIndex = valid[nextPos]
        } else {
            portModalFocusIndex = valid.first ?? 0
        }
    }

    private func handlePortModalLeft() {
        SoundEffectService.shared.play(.click)
        withAnimation(.easeInOut(duration: 0.15)) {
            switch portModalFocusIndex {
            case 1:
                platform = .macApp
                portModalFocusIndex = 0
            case 2:
                platform = .ios
                portModalFocusIndex = 1
            case 4:
                autoDeployToDeviceOnFinish = true
                portModalFocusIndex = 3
            case 6:
                autoRomfsSplitLimitGB = max(2.0, autoRomfsSplitLimitGB - 1.0)
            case 7:
                showFps.toggle()
            case 8:
                keepExtracted.toggle()
            case 9:
                allowOtherMetal.toggle()
            case 10:
                surveyOnly.toggle()
            case 13:
                cycleConnectedIosDevice(step: -1)
            case 14:
                cycleIosSigningTeam(step: -1)
            case 15:
                NxHubDeploymentService.shared.useExternalStorage.toggle()
            case 12:
                portModalFocusIndex = 11
            default:
                break
            }
        }
    }

    private func handlePortModalRight() {
        SoundEffectService.shared.play(.click)
        withAnimation(.easeInOut(duration: 0.15)) {
            switch portModalFocusIndex {
            case 0:
                platform = .ios
                portModalFocusIndex = 1
            case 1:
                platform = .android
                portModalFocusIndex = 2
            case 3:
                autoDeployToDeviceOnFinish = false
                portModalFocusIndex = 4
            case 6:
                autoRomfsSplitLimitGB = min(16.0, autoRomfsSplitLimitGB + 1.0)
            case 7:
                showFps.toggle()
            case 8:
                keepExtracted.toggle()
            case 9:
                allowOtherMetal.toggle()
            case 10:
                surveyOnly.toggle()
            case 13:
                cycleConnectedIosDevice(step: 1)
            case 14:
                cycleIosSigningTeam(step: 1)
            case 15:
                NxHubDeploymentService.shared.useExternalStorage.toggle()
            case 11:
                portModalFocusIndex = 12
            default:
                break
            }
        }
    }

    private func handlePortModalConfirm() {
        SoundEffectService.shared.play(.click)
        withAnimation(.easeInOut(duration: 0.15)) {
            switch portModalFocusIndex {
            case 0:
                platform = .macApp
            case 1:
                platform = .ios
            case 2:
                platform = .android
            case 3:
                autoDeployToDeviceOnFinish = true
            case 4:
                autoDeployToDeviceOnFinish = false
            case 13:
                if DeviceDeploymentService.shared.connectedDevices.count > 1 {
                    cycleConnectedIosDevice(step: 1)
                } else {
                    DeviceDeploymentService.shared.refreshDevicesAndTeams()
                }
            case 14:
                cycleIosSigningTeam(step: 1)
            case 15:
                NxHubDeploymentService.shared.useExternalStorage.toggle()
            case 5:
                isPortAdvancedExpanded.toggle()
            case 6:
                if autoRomfsSplitLimitGB >= 16.0 {
                    autoRomfsSplitLimitGB = 2.0
                } else {
                    autoRomfsSplitLimitGB += 1.0
                }
            case 7:
                showFps.toggle()
            case 8:
                keepExtracted.toggle()
            case 9:
                allowOtherMetal.toggle()
            case 10:
                surveyOnly.toggle()
            case 16:
                selectOutputFolder()
            case 11:
                gameForPortModal = nil
            case 12:
                if canStartBuild {
                    let targetGame = gameForPortModal
                    gameForPortModal = nil
                    if let targetGame = targetGame {
                        selectedGame = targetGame
                    }
                    startBuild()
                }
            default:
                break
            }
        }
    }

    private func cycleConnectedIosDevice(step: Int) {
        let ds = DeviceDeploymentService.shared
        let devs = ds.connectedDevices
        guard !devs.isEmpty else { return }
        let idx = devs.firstIndex(where: { $0.id == ds.selectedDevice?.id }) ?? 0
        let next = (idx + step + devs.count) % devs.count
        ds.selectedDevice = devs[next]
    }

    private func cycleIosSigningTeam(step: Int) {
        let ds = DeviceDeploymentService.shared
        let options: [DeveloperSigningTeam?] = [nil] + ds.signingTeams.map { Optional($0) }
        guard !options.isEmpty else { return }
        let idx = options.firstIndex(where: { $0?.id == ds.selectedSigningTeam?.id }) ?? 0
        let next = (idx + step + options.count) % options.count
        ds.selectedSigningTeam = options[next]
    }
}
