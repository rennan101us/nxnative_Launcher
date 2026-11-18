import Foundation
import SwiftUI
import AppKit

extension AppViewModel {
    public func setupControllerNavigation() {
        GameControllerService.shared.onAction = { [weak self] action in
            self?.handleGamepadAction(action)
        }
        GameControllerService.shared.onRightStickScroll = { [weak self] delta in
            self?.scrollActiveView(delta: delta)
        }
    }

    public func scrollActiveView(delta: CGFloat) {
        if let rootWindow = NSApp.keyWindow ?? NSApp.mainWindow {
            let targetView = rootWindow.attachedSheet?.contentView ?? rootWindow.contentView
            if let sv = findScrollableView(in: targetView) {
                let clipView = sv.contentView
                var origin = clipView.bounds.origin
                origin.y -= delta
                let maxHeight = max(0, (sv.documentView?.bounds.height ?? 0) - clipView.bounds.height)
                origin.y = max(0, min(origin.y, maxHeight))
                clipView.scroll(to: origin)
                sv.reflectScrolledClipView(clipView)
            }
        }
    }

    private func findScrollableView(in view: NSView?) -> NSScrollView? {
        guard let root = view else { return nil }
        var queue: [NSView] = [root]
        while !queue.isEmpty {
            let current = queue.removeFirst()
            if let sv = current as? NSScrollView {
                if sv.hasVerticalScroller || (sv.documentView?.bounds.height ?? 0) > sv.bounds.height {
                    return sv
                }
            }
            queue.append(contentsOf: current.subviews)
        }
        return nil
    }

    public func handleGamepadAction(_ action: GamepadAction) {
        handleUnifiedNavigation(UnifiedNavInput.from(gamepadAction: action))
    }

    // MARK: - Unified Gamepad & Keyboard Spatial Navigation
    public func handleUnifiedNavigation(_ input: UnifiedNavInput) {
        if isAnyModalPresented {
            handleModalUnifiedNavigation(input)
            return
        }

        if isShowingOnboarding {
            if let gpAction = input.asGamepadAction {
                handleOnboardingGamepadAction(gpAction)
            }
            return
        }

        let tabCount = isDeveloperMode ? 6 : 5

        switch input {
        case .tabPrevious:
            SoundEffectService.shared.play(.tabSwitch)
            focusZone = .content
            selectedTab = (selectedTab - 1 + tabCount) % tabCount
            return
        case .tabNext:
            SoundEffectService.shared.play(.tabSwitch)
            focusZone = .content
            selectedTab = (selectedTab + 1) % tabCount
            return
        case .subTabPrevious:
            if selectedTab == 0 {
                adjustLibraryCardScale(by: -0.05)
                return
            }
        case .subTabNext:
            if selectedTab == 0 {
                adjustLibraryCardScale(by: 0.05)
                return
            }
        case .zoomOut:
            if selectedTab == 0 {
                adjustLibraryCardScale(by: -0.05)
            }
            return
        case .zoomIn:
            if selectedTab == 0 {
                adjustLibraryCardScale(by: 0.05)
            }
            return
        case .focusSearch:
            SoundEffectService.shared.play(.click)
            if selectedTab != 0 && selectedTab != 1 {
                selectedTab = 0
            }
            focusZone = .topHeader
            headerFocusItem = .search
            isSearchFieldProgrammaticallyFocused = true
            return
        case .clearSearch:
            clearActiveHeaderSearch()
            return
        case .menu:
            SoundEffectService.shared.play(.click)
            if selectedTab == 0, let game = currentFocusedGame {
                gameForSettingsSheet = game
            } else {
                focusZone = .content
                selectedTab = 4
            }
            return
        case .options:
            handleOptionsAction()
            return
        default:
            break
        }

        switch focusZone {
        case .leftRail:
            handleLeftRailNavigation(input, tabCount: tabCount)
        case .topHeader:
            handleTopHeaderNavigation(input)
        case .bottomZoom:
            handleBottomZoomNavigation(input)
        case .content:
            handleContentNavigation(input)
        }
    }

    // MARK: - Spatial Zone Helpers
    public func visibleHeaderItems() -> [HeaderFocusItem] {
        var items: [HeaderFocusItem] = []
        if selectedTab == 0 {
            items.append(.addGame)
            items.append(.search)
        } else if selectedTab == 1 {
            items.append(.search)
        }
        if shouldShowProvisioningHeaderPill {
            items.append(.provisioningPill)
        }
        return items
    }

    public func enterLeftRailFocus() {
        railFocusIndex = selectedTab
        focusZone = .leftRail
        SoundEffectService.shared.play(.focus)
    }

    public func enterTopHeaderFocus(preferred: HeaderFocusItem? = nil) -> Bool {
        let items = visibleHeaderItems()
        guard !items.isEmpty else { return false }
        if let preferred = preferred, items.contains(preferred) {
            headerFocusItem = preferred
        } else if !items.contains(headerFocusItem) {
            headerFocusItem = items.first ?? .search
        }
        focusZone = .topHeader
        SoundEffectService.shared.play(.focus)
        return true
    }

    public func enterBottomZoomFocus() {
        guard selectedTab == 0 else { return }
        focusZone = .bottomZoom
        SoundEffectService.shared.play(.focus)
    }

    public func adjustLibraryCardScale(by delta: Double) {
        let updated = max(0.70, min(1.50, round((libraryCardScale + delta) * 100) / 100))
        if abs(updated - libraryCardScale) > 0.001 {
            libraryCardScale = updated
            SoundEffectService.shared.play(.click)
        }
    }

    private func clearActiveHeaderSearch() {
        if selectedTab == 0 && !librarySearchText.isEmpty {
            SoundEffectService.shared.play(.click)
            librarySearchText = ""
            reconcileLibraryFocusState()
        } else if selectedTab == 1 && !compatibilitySearchText.isEmpty {
            SoundEffectService.shared.play(.click)
            compatibilitySearchText = ""
            focusedCompatibilityIndex = 0
        }
    }

    private func handleLeftRailNavigation(_ input: UnifiedNavInput, tabCount: Int) {
        switch input {
        case .navigateUp:
            SoundEffectService.shared.play(.tabSwitch)
            let prev = (selectedTab - 1 + tabCount) % tabCount
            selectedTab = prev
            railFocusIndex = prev
        case .navigateDown:
            SoundEffectService.shared.play(.tabSwitch)
            let next = (selectedTab + 1) % tabCount
            selectedTab = next
            railFocusIndex = next
        case .navigateRight, .confirm:
            SoundEffectService.shared.play(.focus)
            focusZone = .content
        case .cancel:
            SoundEffectService.shared.play(.click)
            focusZone = .content
        default:
            break
        }
    }

    private func handleTopHeaderNavigation(_ input: UnifiedNavInput) {
        let items = visibleHeaderItems()
        guard !items.isEmpty else {
            focusZone = .content
            return
        }
        let currentIdx = items.firstIndex(of: headerFocusItem) ?? 0

        switch input {
        case .navigateLeft:
            if currentIdx == 0 {
                isSearchFieldProgrammaticallyFocused = false
                enterLeftRailFocus()
            } else {
                SoundEffectService.shared.play(.focus)
                headerFocusItem = items[currentIdx - 1]
            }
        case .navigateRight:
            if currentIdx < items.count - 1 {
                SoundEffectService.shared.play(.focus)
                headerFocusItem = items[currentIdx + 1]
            }
        case .navigateDown, .cancel:
            SoundEffectService.shared.play(.focus)
            isSearchFieldProgrammaticallyFocused = false
            focusZone = .content
            if selectedTab == 0 {
                let hasHeroTarget = currentHeroTarget.ported != nil || currentHeroTarget.unported != nil
                isFocusOnHeroBar = hasHeroTarget
                heroActionFocusIndex = 0
            }
        case .confirm:
            switch headerFocusItem {
            case .addGame:
                SoundEffectService.shared.play(.click)
                focusZone = .content
                openUnifiedGamePicker()
            case .search:
                SoundEffectService.shared.play(.click)
                isSearchFieldProgrammaticallyFocused = true
            case .provisioningPill:
                SoundEffectService.shared.play(.click)
                let needsClt = !prerequisites.xcode.isAvailable &&
                    !isInstallingDependency &&
                    !isCloningRepository &&
                    !isProvisioningBusy
                focusZone = .content
                if needsClt {
                    selectedTab = 4
                    activeSettingsCategory = .toolchain
                } else {
                    showInstallerSheet = true
                }
            }
        case .contextAction:
            if headerFocusItem == .search {
                clearActiveHeaderSearch()
            }
        default:
            break
        }
    }

    private func handleBottomZoomNavigation(_ input: UnifiedNavInput) {
        switch input {
        case .navigateLeft:
            adjustLibraryCardScale(by: -0.05)
        case .navigateRight:
            adjustLibraryCardScale(by: 0.05)
        case .navigateUp, .cancel:
            SoundEffectService.shared.play(.focus)
            focusZone = .content
            isFocusOnHeroBar = false
        case .confirm:
            SoundEffectService.shared.play(.click)
            libraryCardScale = 1.0
        default:
            break
        }
    }

    private func handleContentNavigation(_ input: UnifiedNavInput) {
        switch selectedTab {
        case 2:
            if let gpAction = input.asGamepadAction {
                handleControlsGamepadAction(gpAction)
            }
            return
        case 3:
            if let gpAction = input.asGamepadAction {
                handlePersonalizeGamepadAction(gpAction)
            }
            return
        case 4:
            if let gpAction = input.asGamepadAction {
                handleSystemGamepadAction(gpAction)
            }
            return
        case 5:
            handleLogsNavigation(input)
            return
        default:
            break
        }

        switch input {
        case .navigateLeft:
            handleNavigateLeft()
        case .navigateRight:
            handleNavigateRight()
        case .navigateUp:
            handleNavigateUp()
        case .navigateDown:
            handleNavigateDown()
        case .confirm:
            handleConfirm()
        case .cancel:
            handleCancel()
        case .secondaryAction:
            handleSecondaryAction()
        case .contextAction:
            handleContextAction()
        case .pageUp:
            if selectedTab == 1 { handleCompatibilityPageUp() }
        case .pageDown:
            if selectedTab == 1 { handleCompatibilityPageDown() }
        case .home:
            if selectedTab == 1 { handleCompatibilityHome() }
        case .end:
            if selectedTab == 1 { handleCompatibilityEnd() }
        default:
            break
        }
    }

    // MARK: - Navigation Handlers Across Tabs 0 & 1
    public func heroActionCount() -> Int {
        if currentFocusedGame != nil {
            // PortedActionBar always renders 3 actions: 0 (Play/iOS), 1 (Port/iOS/Mac), 2 (Settings ≡)
            return 3
        } else if let u = focusedUnportedGame ?? currentHeroTarget.unported {
            return u.baseFile != nil ? 2 : 1
        }
        return 0
    }

    func handleNavigateLeft() {
        switch selectedTab {
        case 0:
            if isFocusOnHeroBar {
                if heroActionFocusIndex > 0 {
                    heroActionFocusIndex -= 1
                    SoundEffectService.shared.play(.focus)
                } else {
                    enterLeftRailFocus()
                }
            } else {
                handleLibraryNavigateLeft()
            }
        case 1:
            handleCompatibilityNavigateLeft()
        default:
            break
        }
    }

    func handleNavigateRight() {
        switch selectedTab {
        case 0:
            if isFocusOnHeroBar {
                let maxIdx = max(0, heroActionCount() - 1)
                if heroActionFocusIndex < maxIdx {
                    heroActionFocusIndex += 1
                    SoundEffectService.shared.play(.focus)
                }
            } else {
                handleLibraryNavigateRight()
            }
        case 1:
            handleCompatibilityNavigateRight()
        default:
            break
        }
    }

    func handleNavigateUp() {
        switch selectedTab {
        case 0:
            if isFocusOnHeroBar {
                _ = enterTopHeaderFocus(preferred: .search)
            } else {
                handleLibraryNavigateUp()
            }
        case 1:
            handleCompatibilityNavigateUp()
        default:
            break
        }
    }

    func handleNavigateDown() {
        switch selectedTab {
        case 0:
            if isFocusOnHeroBar {
                isFocusOnHeroBar = false
                SoundEffectService.shared.play(.focus)
            } else {
                handleLibraryNavigateDown()
            }
        case 1:
            handleCompatibilityNavigateDown()
        default:
            break
        }
    }

    func handleConfirm() {
        switch selectedTab {
        case 0:
            if isGameActionMenuPresented {
                SoundEffectService.shared.play(.click)
                executeFocusedGameAction()
            } else if isFocusOnHeroBar {
                SoundEffectService.shared.play(.click)
                executeFocusedHeroBarAction()
            } else {
                SoundEffectService.shared.play(.click)
                executePrimaryUnifiedSelection()
            }
        case 1:
            handleCompatibilityConfirm()
        case 2:
            handleControlsGamepadAction(.confirm)
        case 3:
            handlePersonalizeGamepadAction(.confirm)
        case 4:
            handleSystemGamepadAction(.confirm)
        case 5:
            handleLogsNavigation(.confirm)
        default:
            SoundEffectService.shared.play(.click)
        }
    }
}
