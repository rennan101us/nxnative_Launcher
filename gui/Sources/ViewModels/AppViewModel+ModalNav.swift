import Foundation
import SwiftUI
import AppKit

public extension Notification.Name {
    static let nxBatchModalExecute = Notification.Name("NXBatchModalExecuteCommand")
    static let nxUpdateModalScroll = Notification.Name("NXUpdateModalScrollDelta")
}

extension AppViewModel {
    /// Unified modal router handling both Gamepad and Keyboard navigation while any modal/dialog is presented.
    public func handleModalUnifiedNavigation(_ input: UnifiedNavInput) {
        if isGameActionMenuPresented {
            handleGameActionMenuNav(input)
            return
        }

        if isAnyConfirmationDialogPresented {
            handleConfirmationDialogNav(input)
            return
        }

        if let game = gameForSettingsSheet {
            if game.platform == .ios && (input == .subTabPrevious || input == .subTabNext) {
                SoundEffectService.shared.play(.tabSwitch)
                withAnimation(.spring(response: 0.30, dampingFraction: 0.78)) {
                    iosDeploymentTab = (iosDeploymentTab == .singleGame) ? .multiPort : .singleGame
                }
                return
            }
            if let gpAction = input.asGamepadAction {
                handleSettingsModalGamepadAction(gpAction)
            }
            return
        }

        if gameForPortModal != nil {
            if let gpAction = input.asGamepadAction {
                handlePortModalGamepadAction(gpAction)
            }
            return
        }

        if isBuildErrorModalPresented {
            handleBuildErrorModalNav(input)
            return
        }

        if showNewControllerProfileModal {
            handleNewProfileModalNav(input)
            return
        }

        if showControlsPlayerModal {
            if let gpAction = input.asGamepadAction {
                handleControlsPlayerModalGamepadAction(gpAction)
            }
            return
        }

        if showControlsProfileModal {
            if let gpAction = input.asGamepadAction {
                handleControlsProfileModalGamepadAction(gpAction)
            }
            return
        }

        if showUpdateSheet {
            handleUpdateModalNav(input)
            return
        }

        if showAboutSheet {
            handleAboutModalNav(input)
            return
        }

        if showControlsGuideSheet {
            handleControlsGuideModalNav(input)
            return
        }

        if showNxDeploymentBatchModal {
            handleBatchDeploymentModalNav(input)
            return
        }

        if showInstallerSheet {
            handleInstallerModalNav(input)
            return
        }

        if showRyujinxNotFoundSheet {
            handleRyujinxMissingModalNav(input)
            return
        }
    }

    // MARK: - 1. Compact Console Action Sheet
    private func handleGameActionMenuNav(_ input: UnifiedNavInput) {
        let maxRow = 8
        switch input {
        case .navigateUp:
            if gameActionFocusedIndex > 0 {
                gameActionFocusedIndex -= 1
                SoundEffectService.shared.play(.focus)
            }
        case .navigateDown:
            if gameActionFocusedIndex < maxRow {
                gameActionFocusedIndex += 1
                SoundEffectService.shared.play(.focus)
            }
        case .confirm:
            SoundEffectService.shared.play(.click)
            executeFocusedGameAction()
        case .cancel:
            SoundEffectService.shared.play(.click)
            withAnimation(.easeInOut(duration: 0.18)) {
                isGameActionMenuPresented = false
            }
        default:
            break
        }
    }

    // MARK: - 2. Confirmation Overlays (Liquid Glass)
    private func handleConfirmationDialogNav(_ input: UnifiedNavInput) {
        if showCltInstallAlert {
            if input == .confirm || input == .cancel {
                SoundEffectService.shared.play(.click)
                showCltInstallAlert = false
            }
            return
        }

        switch input {
        case .navigateLeft, .navigateUp:
            if confirmDialogFocusIndex != 0 {
                confirmDialogFocusIndex = 0
                SoundEffectService.shared.play(.focus)
            }
        case .navigateRight, .navigateDown:
            if confirmDialogFocusIndex != 1 {
                confirmDialogFocusIndex = 1
                SoundEffectService.shared.play(.focus)
            }
        case .confirm:
            SoundEffectService.shared.play(.click)
            if confirmDialogFocusIndex == 0 {
                executeActiveConfirmationAction()
            } else {
                dismissActiveConfirmationDialogs()
            }
        case .cancel:
            SoundEffectService.shared.play(.click)
            dismissActiveConfirmationDialogs()
        default:
            break
        }
    }

    public func executeActiveConfirmationAction() {
        if showHideConfirm {
            showHideConfirm = false
            if let g = gameToHide { hideGameFromLibrary(g) }
            gameToHide = nil
        } else if showRemoveConfirm {
            showRemoveConfirm = false
            if let g = gameToRemove { removeGameFromLibrary(g) }
            gameToRemove = nil
        } else if showTrashConfirm {
            showTrashConfirm = false
            if let g = gameToTrash { deleteGameToTrash(g) }
            gameToTrash = nil
        } else if showDeleteConfirm {
            showDeleteConfirm = false
            if let g = gameToDelete { deleteGameToTrash(g) }
            gameToDelete = nil
        } else if showUninstallConfirm {
            showUninstallConfirm = false
            executeUninstall()
        } else if showCltInstallAlert {
            showCltInstallAlert = false
        }
    }

    public func dismissActiveConfirmationDialogs() {
        showHideConfirm = false
        showRemoveConfirm = false
        showTrashConfirm = false
        showDeleteConfirm = false
        showUninstallConfirm = false
        showCltInstallAlert = false
    }

    // MARK: - 3. Build Error Banner
    private func handleBuildErrorModalNav(_ input: UnifiedNavInput) {
        let count = isMetalCompilerMismatchError ? 3 : 2
        switch input {
        case .navigateLeft, .navigateUp:
            SoundEffectService.shared.play(.focus)
            buildErrorFocusIndex = (buildErrorFocusIndex - 1 + count) % count
        case .navigateRight, .navigateDown:
            SoundEffectService.shared.play(.focus)
            buildErrorFocusIndex = (buildErrorFocusIndex + 1) % count
        case .cancel:
            SoundEffectService.shared.play(.click)
            buildError = nil
        case .confirm:
            SoundEffectService.shared.play(.click)
            if isMetalCompilerMismatchError {
                switch buildErrorFocusIndex {
                case 0:
                    buildError = nil
                    enableAllowOtherMetalAndRetry()
                case 1:
                    if let err = buildError {
                        NSPasteboard.general.clearContents()
                        NSPasteboard.general.setString(err, forType: .string)
                    }
                default:
                    buildError = nil
                }
            } else {
                if buildErrorFocusIndex == 0, let err = buildError {
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString(err, forType: .string)
                } else {
                    buildError = nil
                }
            }
        default:
            break
        }
    }

    // MARK: - 4. New Controller Profile Sheet
    private func handleNewProfileModalNav(_ input: UnifiedNavInput) {
        switch input {
        case .navigateUp:
            SoundEffectService.shared.play(.focus)
            newProfileModalFocusIndex = 0
        case .navigateDown:
            SoundEffectService.shared.play(.focus)
            if newProfileModalFocusIndex == 0 {
                isNewProfileTextFocused = false
                newProfileModalFocusIndex = 2
            }
        case .navigateLeft:
            if newProfileModalFocusIndex == 2 {
                SoundEffectService.shared.play(.focus)
                newProfileModalFocusIndex = 1
            }
        case .navigateRight:
            if newProfileModalFocusIndex == 1 {
                SoundEffectService.shared.play(.focus)
                newProfileModalFocusIndex = 2
            }
        case .cancel:
            SoundEffectService.shared.play(.click)
            isNewProfileTextFocused = false
            showNewControllerProfileModal = false
        case .confirm:
            SoundEffectService.shared.play(.click)
            switch newProfileModalFocusIndex {
            case 0:
                isNewProfileTextFocused = true
            case 1:
                isNewProfileTextFocused = false
                showNewControllerProfileModal = false
            default:
                let trimmed = newProfileNameInput.trimmingCharacters(in: .whitespaces)
                if trimmed.isEmpty {
                    isNewProfileTextFocused = true
                } else {
                    let pm = InputProfileManager.shared
                    let created = pm.createProfile(name: trimmed, basedOn: pm.activeProfile)
                    pm.setProfile(created, forPlayer: pm.activePlayerIndex)
                    isNewProfileTextFocused = false
                    showNewControllerProfileModal = false
                }
            }
        default:
            break
        }
    }

    // MARK: - 5. Launcher Update Sheet
    private func updateModalButtonCount() -> Int {
        if updateCompletedReadyToRelaunch { return 1 }
        if isApplyingUpdate || isSyncingUpstream { return 0 }
        let hasAction = (updateInfo?.hasUpdate == true) || ((updateInfo?.upstreamBehindCount ?? 0) > 0)
        return (isCheckingUpdate ? 0 : 1) + 1 + (hasAction ? 1 : 0)
    }

    private func handleUpdateModalNav(_ input: UnifiedNavInput) {
        let btnCount = max(1, updateModalButtonCount())
        switch input {
        case .subTabPrevious, .subTabNext:
            SoundEffectService.shared.play(.tabSwitch)
            withAnimation(.spring(response: 0.30, dampingFraction: 0.78)) {
                updateModalTabIndex = (updateModalTabIndex == 0) ? 1 : 0
            }
        case .navigateUp, .pageUp:
            scrollActiveView(delta: 120)
            updateModalScrollTrigger -= 1
        case .navigateDown, .pageDown:
            scrollActiveView(delta: -120)
            updateModalScrollTrigger += 1
        case .navigateLeft:
            SoundEffectService.shared.play(.focus)
            updateModalFocusIndex = (updateModalFocusIndex - 1 + btnCount) % btnCount
        case .navigateRight:
            SoundEffectService.shared.play(.focus)
            updateModalFocusIndex = (updateModalFocusIndex + 1) % btnCount
        case .cancel:
            SoundEffectService.shared.play(.click)
            showUpdateSheet = false
        case .confirm:
            SoundEffectService.shared.play(.click)
            if updateCompletedReadyToRelaunch {
                relaunchUpdatedLauncher()
                return
            }
            if isApplyingUpdate || isSyncingUpstream { return }
            let hasRecheck = !isCheckingUpdate
            let closeIdx = hasRecheck ? 1 : 0
            let actionIdx = closeIdx + 1
            if hasRecheck && updateModalFocusIndex == 0 {
                openUpdateCheckerAndAutoInstall()
            } else if updateModalFocusIndex == closeIdx {
                showUpdateSheet = false
            } else if updateModalFocusIndex == actionIdx {
                if let info = updateInfo, info.hasUpdate, !isBuilding {
                    applyUpdate(autoRelaunch: true)
                } else if let info = updateInfo, info.upstreamBehindCount > 0, !isBuilding {
                    syncUpstreamEngine()
                }
            }
        default:
            break
        }
    }

    // MARK: - 6. About Sheet
    private func handleAboutModalNav(_ input: UnifiedNavInput) {
        switch input {
        case .navigateLeft, .navigateUp:
            if aboutModalFocusIndex != 0 {
                aboutModalFocusIndex = 0
                SoundEffectService.shared.play(.focus)
            }
        case .navigateRight, .navigateDown:
            if aboutModalFocusIndex != 1 {
                aboutModalFocusIndex = 1
                SoundEffectService.shared.play(.focus)
            }
        case .cancel:
            SoundEffectService.shared.play(.click)
            showAboutSheet = false
        case .confirm:
            SoundEffectService.shared.play(.click)
            if aboutModalFocusIndex == 0 {
                showAboutSheet = false
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.15) {
                    self.openUpdateCheckerAndAutoInstall()
                }
            } else {
                showAboutSheet = false
            }
        default:
            break
        }
    }

    // MARK: - 7. Controls Guide Sheet
    private func handleControlsGuideModalNav(_ input: UnifiedNavInput) {
        switch input {
        case .navigateLeft, .navigateUp:
            if controlsGuideFocusIndex != 0 {
                controlsGuideFocusIndex = 0
                SoundEffectService.shared.play(.focus)
            }
        case .navigateRight, .navigateDown:
            if controlsGuideFocusIndex != 1 {
                controlsGuideFocusIndex = 1
                SoundEffectService.shared.play(.focus)
            }
        case .cancel:
            SoundEffectService.shared.play(.click)
            showControlsGuideSheet = false
        case .confirm:
            SoundEffectService.shared.play(.click)
            showControlsGuideSheet = false
            if controlsGuideFocusIndex == 0 {
                focusZone = .content
                selectedTab = 2
            }
        default:
            break
        }
    }

    // MARK: - 8. Batch iOS Deployment Modal
    private var batchModalAvailableGames: [PortedGame] {
        libraryGames.filter { game in
            game.platform == .ios || game.url.pathExtension.lowercased() == "ipa"
        }
    }

    private func handleBatchDeploymentModalNav(_ input: UnifiedNavInput) {
        let games = batchModalAvailableGames
        let footerStart = games.count
        let maxIdx = footerStart + 3 // Cancel, Export Data, Export IPA, Deploy

        switch input {
        case .navigateUp:
            SoundEffectService.shared.play(.focus)
            if batchModalFocusIndex >= footerStart {
                batchModalFocusIndex = max(0, games.count - 1)
            } else if batchModalFocusIndex > 0 {
                batchModalFocusIndex -= 1
            }
        case .navigateDown:
            SoundEffectService.shared.play(.focus)
            if batchModalFocusIndex < games.count - 1 {
                batchModalFocusIndex += 1
            } else {
                batchModalFocusIndex = footerStart + 3
            }
        case .navigateLeft:
            if batchModalFocusIndex > footerStart {
                SoundEffectService.shared.play(.focus)
                batchModalFocusIndex -= 1
            }
        case .navigateRight:
            if batchModalFocusIndex >= footerStart && batchModalFocusIndex < maxIdx {
                SoundEffectService.shared.play(.focus)
                batchModalFocusIndex += 1
            }
        case .cancel:
            SoundEffectService.shared.play(.click)
            showNxDeploymentBatchModal = false
        case .confirm:
            SoundEffectService.shared.play(.click)
            if batchModalFocusIndex < games.count {
                let id = games[batchModalFocusIndex].stableId
                if batchSelectedGameIds.contains(id) {
                    batchSelectedGameIds.remove(id)
                } else {
                    batchSelectedGameIds.insert(id)
                }
            } else {
                let btn = batchModalFocusIndex - footerStart
                if btn == 0 {
                    showNxDeploymentBatchModal = false
                } else {
                    NotificationCenter.default.post(name: .nxBatchModalExecute, object: btn)
                }
            }
        default:
            break
        }
    }

    // MARK: - 9. Dependency Installer Sheet
    private func handleInstallerModalNav(_ input: UnifiedNavInput) {
        switch input {
        case .navigateUp, .pageUp:
            scrollActiveView(delta: 120)
        case .navigateDown, .pageDown:
            scrollActiveView(delta: -120)
        case .confirm, .cancel:
            if !isInstallingDependency {
                SoundEffectService.shared.play(.click)
                showInstallerSheet = false
            }
        default:
            break
        }
    }

    // MARK: - 10. Ryujinx Missing Sheet
    private func handleRyujinxMissingModalNav(_ input: UnifiedNavInput) {
        switch input {
        case .navigateLeft, .navigateUp:
            SoundEffectService.shared.play(.focus)
            ryujinxSheetFocusIndex = (ryujinxSheetFocusIndex - 1 + 3) % 3
        case .navigateRight, .navigateDown:
            SoundEffectService.shared.play(.focus)
            ryujinxSheetFocusIndex = (ryujinxSheetFocusIndex + 1) % 3
        case .cancel:
            SoundEffectService.shared.play(.click)
            showRyujinxNotFoundSheet = false
        case .confirm:
            SoundEffectService.shared.play(.click)
            switch ryujinxSheetFocusIndex {
            case 0:
                showRyujinxNotFoundSheet = false
            case 1:
                selectRyujinxFolder()
                if isProdKeysValid { showRyujinxNotFoundSheet = false }
            default:
                selectProdKeysFile()
                if isProdKeysValid { showRyujinxNotFoundSheet = false }
            }
        default:
            break
        }
    }
}
