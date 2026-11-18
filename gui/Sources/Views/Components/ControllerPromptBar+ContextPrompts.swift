import SwiftUI

// MARK: - ControllerPromptBar Context-Sensitive Prompts
extension ControllerPromptBar {
    
    // MARK: - Controller Prompts
    @ViewBuilder
    var controllerPromptsForCurrentContext: some View {
        let isPS = controllerService.activeBrand == .playstation
        let confirmBtn = isPS ? "✕" : "A"
        let cancelBtn = isPS ? "○" : "B"
        let xBtn = isPS ? "□" : "X"
        let yBtn = isPS ? "△" : "Y"
        let optionsBtn = controllerService.activeBrand == .xbox ? "⧉" : (isPS ? "OPT" : "−")
        
        if viewModel.gameForSettingsSheet != nil {
            controllerPill(glyph: confirmBtn, action: "Adjust", color: brandAColor)
            controllerPill(glyph: cancelBtn, action: "Done", color: brandBColor)
            dpadPill(glyph: "↑/↓", action: "Navigate")
            dpadPill(glyph: "←/→", action: "Change")
        } else if viewModel.isAnyModalPresented {
            controllerPill(glyph: confirmBtn, action: "Select", color: brandAColor)
            controllerPill(glyph: cancelBtn, action: "Close", color: brandBColor)
            dpadPill(glyph: "↑/↓/←/→", action: "Navigate")
        } else {
            switch viewModel.focusZone {
            case .leftRail:
                dpadPill(glyph: "↑/↓", action: "Switch Tab")
                controllerPill(glyph: confirmBtn, action: "Enter", color: brandAColor)
                controllerPill(glyph: cancelBtn, action: "Back", color: brandBColor)
            case .topHeader:
                dpadPill(glyph: "←/→", action: "Header")
                controllerPill(glyph: confirmBtn, action: viewModel.headerFocusItem == .search ? "Type" : "Select", color: brandAColor)
                if viewModel.headerFocusItem == .search {
                    controllerPill(glyph: yBtn, action: "Clear", color: brandYColor)
                }
                controllerPill(glyph: cancelBtn, action: "Back", color: brandBColor)
            case .bottomZoom:
                dpadPill(glyph: "←/→", action: "Zoom")
                controllerPill(glyph: confirmBtn, action: "Reset 100%", color: brandAColor)
                controllerPill(glyph: cancelBtn, action: "Cards", color: brandBColor)
            case .content:
                switch viewModel.selectedTab {
                case 0: // My Games
                    if viewModel.isGameActionMenuPresented {
                        controllerPill(glyph: confirmBtn, action: "Execute", color: brandAColor)
                        controllerPill(glyph: cancelBtn, action: "Close", color: brandBColor)
                        dpadPill(glyph: "↑/↓", action: "Navigate")
                    } else if viewModel.isBuilding && viewModel.activeLibraryShelf == .unportedSwitch && (viewModel.buildingGameId == viewModel.focusedUnportedGame?.id || viewModel.selectedGame?.id == viewModel.focusedUnportedGame?.id) {
                        controllerPill(glyph: cancelBtn, action: viewModel.tr("library.cancel_port"), color: Color.red)
                        dpadPill(glyph: "←/→", action: "Browse")
                    } else if viewModel.isFocusOnHeroBar {
                        let isIOS = viewModel.currentFocusedGame?.platform == .ios
                        controllerPill(glyph: confirmBtn, action: isIOS ? "Deploy" : "Select", color: brandAColor)
                        controllerPill(glyph: cancelBtn, action: "Cards", color: brandBColor)
                        dpadPill(glyph: "←/→", action: "Actions")
                        dpadPill(glyph: "↑", action: "Header")
                    } else {
                        controllerPill(glyph: confirmBtn, action: "Play / Open", color: brandAColor)
                        dpadPill(glyph: "↑/↓", action: "Hero / Zoom")
                        dpadPill(glyph: "ZL/ZR", action: "Zoom")
                        optionsPill(glyph: optionsBtn, action: "Options")
                    }

                case 1: // Compatibility
                    if viewModel.compatibilityFocusArea == .filters {
                        dpadPill(glyph: "←/→", action: "Filter")
                        dpadPill(glyph: "↓", action: "Games")
                        controllerPill(glyph: confirmBtn, action: "Select", color: brandAColor)
                    } else {
                        dpadPill(glyph: "↑/↓", action: "Browse")
                        controllerPill(glyph: confirmBtn, action: "View Notes", color: brandAColor)
                        controllerPill(glyph: cancelBtn, action: "Filters", color: brandBColor)
                    }

                case 2: // Controls
                    if viewModel.isInsideControlsCard {
                        controllerPill(glyph: confirmBtn, action: "Select / Rebind", color: brandAColor)
                        controllerPill(glyph: cancelBtn, action: "Back to Cards", color: brandBColor)
                        dpadPill(glyph: "↑/↓/←/→", action: "Navigate")
                        controllerPill(glyph: yBtn, action: "Test Rumble", color: brandYColor)
                    } else {
                        controllerPill(glyph: confirmBtn, action: "Enter Card", color: brandAColor)
                        dpadPill(glyph: "↑/↓", action: "Select Card")
                        controllerPill(glyph: yBtn, action: "Test Rumble", color: brandYColor)
                    }

                case 3: // Personalize
                    if viewModel.isInsidePersonalizeCard {
                        controllerPill(glyph: confirmBtn, action: "Apply / Toggle", color: brandAColor)
                        controllerPill(glyph: cancelBtn, action: "Back to Cards", color: brandBColor)
                        dpadPill(glyph: "↑/↓/←/→", action: "Adjust")
                    } else {
                        controllerPill(glyph: confirmBtn, action: "Enter Card", color: brandAColor)
                        dpadPill(glyph: "↑/↓", action: "Select Card")
                        controllerPill(
                            glyph: xBtn,
                            action: viewModel.tr(viewModel.isLiquidGlassEnabled ? "personalization.liquid_glass_on" : "personalization.liquid_glass_off"),
                            color: brandXColor
                        )
                    }

                case 4: // Settings
                    controllerPill(glyph: confirmBtn, action: "Select / Open", color: brandAColor)
                    dpadPill(glyph: "←/→", action: "Category")
                    dpadPill(glyph: "↑/↓", action: "Navigate")
                    controllerPill(glyph: yBtn, action: "Dev Mode", color: brandYColor)

                case 5: // Console / Logs
                    dpadPill(glyph: "↑/↓", action: "Filter / Scroll")
                    controllerPill(glyph: confirmBtn, action: "Toggle / Follow", color: brandAColor)
                    controllerPill(glyph: xBtn, action: "Copy", color: brandXColor)
                    controllerPill(glyph: yBtn, action: "Clear", color: brandBColor)

                default:
                    EmptyView()
                }
            }
        }
    }
    
    // MARK: - Keyboard Prompts (When no controller is connected)
    @ViewBuilder
    var keyboardPromptsForCurrentContext: some View {
        if viewModel.gameForSettingsSheet != nil {
            keyboardKeyBadge(glyph: "↑/↓", action: "Navigate")
            keyboardKeyBadge(glyph: "←/→", action: "Change")
            keyboardKeyBadge(glyph: "↵ Enter", action: "Adjust")
            keyboardKeyBadge(glyph: "⎋ Esc", action: "Done")
        } else if viewModel.isAnyModalPresented {
            keyboardKeyBadge(glyph: "↑/↓/←/→", action: "Navigate")
            keyboardKeyBadge(glyph: "↵ Enter", action: "Select")
            keyboardKeyBadge(glyph: "⎋ Esc", action: "Close")
        } else {
            switch viewModel.focusZone {
            case .leftRail:
                keyboardKeyBadge(glyph: "↑/↓", action: "Switch Tab")
                keyboardKeyBadge(glyph: "↵ / →", action: "Focus")
                keyboardKeyBadge(glyph: "⎋ Esc", action: "Back")
            case .topHeader:
                keyboardKeyBadge(glyph: "← / →", action: "Header")
                keyboardKeyBadge(glyph: "↵ Enter", action: viewModel.headerFocusItem == .search ? "Type" : "Open")
                if viewModel.headerFocusItem == .search {
                    keyboardKeyBadge(glyph: "⌫", action: "Clear")
                }
                keyboardKeyBadge(glyph: "⎋ Esc", action: "Back")
            case .bottomZoom:
                keyboardKeyBadge(glyph: "← / →", action: "Zoom")
                keyboardKeyBadge(glyph: "↵ Enter", action: "Reset 100%")
                keyboardKeyBadge(glyph: "⎋ Esc", action: "Cards")
            case .content:
                switch viewModel.selectedTab {
                case 0: // My Games
                    if viewModel.isGameActionMenuPresented {
                        keyboardKeyBadge(glyph: "↑/↓", action: "Navigate")
                        keyboardKeyBadge(glyph: "↵ Enter", action: "Execute")
                        keyboardKeyBadge(glyph: "⎋ Esc", action: "Close")
                    } else if viewModel.isBuilding && viewModel.activeLibraryShelf == .unportedSwitch && (viewModel.buildingGameId == viewModel.focusedUnportedGame?.id || viewModel.selectedGame?.id == viewModel.focusedUnportedGame?.id) {
                        keyboardKeyBadge(glyph: "⎋ Esc", action: viewModel.tr("library.cancel_port"))
                        keyboardKeyBadge(glyph: "← / →", action: "Browse")
                    } else {
                        let isIOS = viewModel.currentFocusedGame?.platform == .ios
                        keyboardKeyBadge(glyph: "← / →", action: "Browse")
                        keyboardKeyBadge(glyph: "↵ Enter", action: isIOS ? "Install / Options" : "Play")
                        keyboardKeyBadge(glyph: "/", action: "Search")
                        keyboardKeyBadge(glyph: "- / +", action: "Zoom")
                        keyboardKeyBadge(glyph: ",", action: "Settings")
                    }

                case 1: // Compatibility
                    if viewModel.compatibilityFocusArea == .filters {
                        keyboardKeyBadge(glyph: "← / →", action: "Filter")
                        keyboardKeyBadge(glyph: "↓", action: "Browse Games")
                    } else {
                        keyboardKeyBadge(glyph: "↑/↓", action: "Browse")
                        keyboardKeyBadge(glyph: "↵ Enter", action: "View Notes")
                        keyboardKeyBadge(glyph: "⎋ Esc", action: "Filters")
                    }
                    keyboardKeyBadge(glyph: "R", action: "Refresh")

                case 2: // Controls
                    keyboardKeyBadge(glyph: "Space", action: "Calibrate")

                case 3: // Personalize
                    keyboardKeyBadge(glyph: "← / →", action: "Highlight Color")
                    keyboardKeyBadge(
                        glyph: "G",
                        action: viewModel.tr(viewModel.isLiquidGlassEnabled ? "personalization.liquid_glass_on" : "personalization.liquid_glass_off")
                    )
                    keyboardKeyBadge(
                        glyph: "M",
                        action: viewModel.tr(viewModel.liquidGlassAppearance.titleLocalizationKey)
                    )

                case 4: // Settings
                    keyboardKeyBadge(glyph: "I", action: "Install Tools")
                    keyboardKeyBadge(glyph: "U", action: "Check Updates")

                case 5: // Console
                    keyboardKeyBadge(glyph: "↑/↓", action: "Navigate")
                    keyboardKeyBadge(glyph: "C", action: "Copy Logs")
                    keyboardKeyBadge(glyph: "K", action: "Clear")

                default:
                    EmptyView()
                }
            }
        }
    }
}
