import SwiftUI
import AppKit

public struct GameSettingsSheetView: View {
    @ObservedObject public var viewModel: AppViewModel
    @ObservedObject var controllerService = GameControllerService.shared
    @ObservedObject var profileManager = InputProfileManager.shared
    public let game: PortedGame
    
    @Environment(\.dismiss) internal var dismiss
    @Environment(\.nxLiquidGlass) internal var glassEnv
    @Environment(\.accessibilityReduceTransparency) internal var reduceTransparency
    
    public init(viewModel: AppViewModel, game: PortedGame) {
        self.viewModel = viewModel
        self.game = game
    }
    
    internal var useLiquidGlass: Bool {
        glassEnv.isSupportedAndEnabled && !reduceTransparency
    }
    
    internal var isOot: Bool {
        GameRuntimeConfig.isOotGame(game)
    }
    
    public var body: some View {
        ScrollViewReader { scrollProxy in
            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    if game.platform == .macApp || (game.platform == .ios && viewModel.iosDeploymentTab == .singleGame) {
                        if game.platform == .ios {
                            // iOS Port: Installation, AirDrop, Sideload & Config Sync
                            GameSettingsModsAndSavesView(game: game, viewModel: viewModel)
                                .id("setting_row_ios_mods")
                        }

                        // Presets Card (.nxn Encrypted Presets)
                        GameSettingsPresetsView(viewModel: viewModel, game: game, isOot: isOot)

                        // Section 0: Framerate (60 FPS) + Framegen
                        settingCard(
                            rowIndex: 0,
                            additionalFocusIndices: [21],
                            title: viewModel.tr("settings_modal.framerate_title"),
                            icon: "speedometer",
                            iconColor: Color(red: 0.13, green: 0.77, blue: 0.37)
                        ) {
                            let isRowFocused = viewModel.settingsModalFocusIndex == 0 || viewModel.settingsModalFocusIndex == 21
                            VStack(alignment: .leading, spacing: 10) {
                                modalSubRowFocus(rowIndex: 0) {
                                    HStack(alignment: .center, spacing: 12) {
                                        VStack(alignment: .leading, spacing: 3) {
                                            Text(viewModel.activeSettingsConfig.enable60FPS ? viewModel.tr("settings_modal.fps_60") : viewModel.tr("settings_modal.fps_30"))
                                                .font(.system(size: 13, weight: .semibold, design: .rounded))
                                                .foregroundColor(.white)
                                            Text(viewModel.tr("settings_modal.fps_desc"))
                                                .font(.system(size: 11, weight: .medium))
                                                .foregroundColor(isRowFocused ? .white : .white.opacity(0.88))
                                        }
                                        Spacer(minLength: 12)
                                        Toggle("", isOn: $viewModel.activeSettingsConfig.enable60FPS)
                                            .labelsHidden()
                                            .toggleStyle(.switch)
                                    }
                                }

                                Divider().background(Color.white.opacity(0.12))

                                modalSubRowFocus(rowIndex: 21) {
                                    framegenToggleSection(isRowFocused: viewModel.settingsModalFocusIndex == 21)
                                }
                            }
                        }

                        if game.platform != .ios {
                            // Section 1: macOS Game Mode (Modo Jogo & Fullscreen)
                            settingCard(
                                rowIndex: 1,
                                title: viewModel.tr("settings_modal.game_mode_title"),
                                icon: "gamecontroller.fill",
                                iconColor: Color(red: 0.25, green: 0.55, blue: 1.0)
                            ) {
                                let isRowFocused = viewModel.settingsModalFocusIndex == 1
                                HStack(alignment: .center, spacing: 12) {
                                    VStack(alignment: .leading, spacing: 3) {
                                        Text(viewModel.activeSettingsConfig.enableGameMode ? viewModel.tr("settings_modal.game_mode_enabled") : viewModel.tr("settings_modal.game_mode_disabled"))
                                            .font(.system(size: 13, weight: .semibold, design: .rounded))
                                            .foregroundColor(.white)
                                        Text(viewModel.tr("settings_modal.game_mode_desc"))
                                            .font(.system(size: 11, weight: .medium))
                                            .foregroundColor(isRowFocused ? .white : NXTheme.modalDescription)
                                    }
                                    Spacer(minLength: 12)
                                    Toggle("", isOn: $viewModel.activeSettingsConfig.enableGameMode)
                                        .labelsHidden()
                                        .toggleStyle(.switch)
                                }
                            }
                            .id("setting_row_1")
                        }
                    
                    // Section 2: Metal HUD
                    settingCard(
                        rowIndex: 2,
                        title: viewModel.tr("settings_modal.metal_hud_title"),
                        icon: "gauge.with.needle.fill",
                        iconColor: NXTheme.secondary
                    ) {
                        let isRowFocused = viewModel.settingsModalFocusIndex == 2
                        HStack(alignment: .center, spacing: 12) {
                            VStack(alignment: .leading, spacing: 3) {
                                Text(viewModel.activeSettingsConfig.enableMetalHUD ? viewModel.tr("settings_modal.metal_hud_enabled") : viewModel.tr("settings_modal.metal_hud_disabled"))
                                    .font(.system(size: 13, weight: .semibold, design: .rounded))
                                    .foregroundColor(.white)
                                Text(viewModel.tr("settings_modal.metal_hud_desc"))
                                    .font(.system(size: 11, weight: .medium))
                                    .foregroundColor(isRowFocused ? .white : NXTheme.modalDescription)
                            }
                            Spacer(minLength: 12)
                            Toggle("", isOn: $viewModel.activeSettingsConfig.enableMetalHUD)
                                .labelsHidden()
                                .toggleStyle(.switch)
                        }
                    }
                    .id("setting_row_2")
                    
                    // Section 3: Console Mode (Sliding Liquid Glass Segmented Picker)
                    settingCard(
                        rowIndex: 3,
                        title: viewModel.tr("settings_modal.console_mode_title"),
                        icon: "tv.and.mediabox",
                        iconColor: NXTheme.primary
                    ) {
                        let isRowFocused = viewModel.settingsModalFocusIndex == 3
                        VStack(alignment: .leading, spacing: 10) {
                            NXLiquidSegmentedPicker(
                                selection: $viewModel.activeSettingsConfig.isDockedMode,
                                options: [
                                    NXSegmentOption(value: true, title: viewModel.tr("settings_modal.docked_label"), icon: "tv.fill"),
                                    NXSegmentOption(value: false, title: viewModel.tr("settings_modal.handheld_label"), icon: "iphone.gen3.landscape")
                                ]
                            )
                            
                            Text(viewModel.activeSettingsConfig.isDockedMode
                                 ? viewModel.tr("settings_modal.docked_desc")
                                 : viewModel.tr("settings_modal.handheld_desc"))
                                .font(.system(size: 11, weight: .medium))
                                .foregroundColor(isRowFocused ? .white : NXTheme.modalDescription)
                        }
                    }
                    .id("setting_row_3")
                    
                    // Section 4: 3D Render Scale (Liquid Glass Slider)
                    settingCard(
                        rowIndex: 4,
                        title: viewModel.tr("settings_modal.render_scale_title"),
                        icon: "viewfinder.circle.fill",
                        iconColor: Color(red: 1.0, green: 0.65, blue: 0.35)
                    ) {
                        let isRowFocused = viewModel.settingsModalFocusIndex == 4
                        VStack(alignment: .leading, spacing: 10) {
                            HStack {
                                Text(viewModel.tr("settings_modal.render_scale_label"))
                                    .font(.system(size: 12, weight: .semibold))
                                    .foregroundColor(isRowFocused ? .white : NXTheme.modalDescription)
                                Spacer()
                                Text("\(Int(round(viewModel.activeSettingsConfig.renderScale * 100)))%")
                                    .font(.system(size: 13, weight: .bold, design: .monospaced))
                                    .foregroundColor(.white)
                            }
                            
                            NXLiquidGlassSlider(
                                value: $viewModel.activeSettingsConfig.renderScale,
                                in: 0.50...1.00,
                                step: 0.05,
                                accentColor: NXTheme.primary
                            )
                            
                            NXGlassContainer(spacing: 8) {
                                HStack(spacing: 8) {
                                    Button(viewModel.tr("settings_modal.scale_50")) {
                                        viewModel.activeSettingsConfig.renderScale = 0.50
                                    }
                                    .buttonStyle(NXSecondaryButtonStyle())
                                    .controlSize(.mini)
                                    
                                    Button(viewModel.tr("settings_modal.scale_75")) {
                                        viewModel.activeSettingsConfig.renderScale = 0.75
                                    }
                                    .buttonStyle(NXSecondaryButtonStyle())
                                    .controlSize(.mini)
                                    
                                    Button(viewModel.tr("settings_modal.resolution_native")) {
                                        viewModel.activeSettingsConfig.renderScale = 1.00
                                    }
                                    .buttonStyle(NXSecondaryButtonStyle())
                                    .controlSize(.mini)
                                }
                            }
                        }
                    }
                    .id("setting_row_4")
                    
                    // Section 5: MetalFX Upscaling / OoT Ultra Boost
                    if isOot {
                        ootEnhancedSection(rowIndex: 5)
                            .id("setting_row_5")

                        ootMotionBlurSection(rowIndex: 13)
                            .id("setting_row_13")
                    } else {
                        settingCard(
                            rowIndex: 5,
                            title: viewModel.tr("settings_modal.metalfx_title"),
                            icon: "sparkles.tv.fill",
                            iconColor: NXTheme.secondary
                        ) {
                            let isRowFocused = viewModel.settingsModalFocusIndex == 5
                            HStack(alignment: .center, spacing: 12) {
                                VStack(alignment: .leading, spacing: 3) {
                                    Text(viewModel.activeSettingsConfig.enableMetalFXUpscale ? viewModel.tr("settings_modal.metalfx_enabled") : viewModel.tr("settings_modal.metalfx_disabled"))
                                        .font(.system(size: 13, weight: .semibold, design: .rounded))
                                        .foregroundColor(.white)
                                    Text(viewModel.tr("settings_modal.metalfx_desc"))
                                        .font(.system(size: 11, weight: .medium))
                                        .foregroundColor(isRowFocused ? .white : NXTheme.modalDescription)
                                }
                                Spacer(minLength: 12)
                                Toggle("", isOn: $viewModel.activeSettingsConfig.enableMetalFXUpscale)
                                    .labelsHidden()
                                    .toggleStyle(.switch)
                            }
                        }
                        .id("setting_row_5")
                    }
                    
                    // Section 6: Controller Profile Override (Liquid Glass Dropdown)
                    if game.platform != .ios {
                        controllerProfileSection(rowIndex: 6, additionalFocusIndices: [28])
                    }
                    
                    // Section 7: Game Language Selection (Liquid Glass Dropdown from Info.plist)
                    gameLanguageSection(rowIndex: 7)
                        .id("setting_row_7")
                    
                    // Cover Artwork Customization
                    coverArtworkSection()
                        .id("setting_row_11")
                    
                    if game.platform == .macApp {
                        // Mods Management & Save Sync
                        GameSettingsModsAndSavesView(game: game, viewModel: viewModel)
                            .id("setting_row_mods")
                    }
                } else if game.platform == .nonSwitch {
                    // Section 1: macOS Game Mode (Modo Jogo & Fullscreen)
                    settingCard(
                        rowIndex: 1,
                        title: viewModel.tr("settings_modal.game_mode_title"),
                        icon: "gamecontroller.fill",
                        iconColor: Color(red: 0.25, green: 0.55, blue: 1.0)
                    ) {
                        let isRowFocused = viewModel.settingsModalFocusIndex == 1
                        HStack(alignment: .center, spacing: 12) {
                            VStack(alignment: .leading, spacing: 3) {
                                Text(viewModel.activeSettingsConfig.enableGameMode ? viewModel.tr("settings_modal.game_mode_enabled") : viewModel.tr("settings_modal.game_mode_disabled"))
                                    .font(.system(size: 13, weight: .semibold, design: .rounded))
                                    .foregroundColor(.white)
                                Text(viewModel.tr("settings_modal.game_mode_desc"))
                                    .font(.system(size: 11, weight: .medium))
                                    .foregroundColor(isRowFocused ? .white : NXTheme.modalDescription)
                            }
                            Spacer(minLength: 12)
                            Toggle("", isOn: $viewModel.activeSettingsConfig.enableGameMode)
                                .labelsHidden()
                                .toggleStyle(.switch)
                        }
                    }
                    .id("setting_row_1")
                    
                    // Section 6: Controller Profile Override (Liquid Glass Dropdown)
                    controllerProfileSection(rowIndex: 6, additionalFocusIndices: [28])
                    
                    // Section 7: Cover Artwork Customization
                    coverArtworkSection()
                        .id("setting_row_11")
                } else {
                    // iOS Multi-Port (NxN Launcher): Installation, Transfer & Saves
                    GameSettingsModsAndSavesView(game: game, viewModel: viewModel)
                        .id("setting_row_ios_mods")
                }
                
                // Section: Game Management (Hide / Remove / Trash) - only in Mac or Single Game mode
                if game.platform != .ios || viewModel.iosDeploymentTab == .singleGame {
                    gameManagementSection()
                        .id("setting_row_12")
                }
            }
            .padding(20)
            .padding(.bottom, game.platform != .ios ? 20 : 30)
            .frame(maxWidth: .infinity, alignment: .topLeading)
            .onChange(of: viewModel.settingsModalFocusIndex) { newIndex in
                withAnimation(.spring(response: 0.35, dampingFraction: 0.8)) {
                    scrollProxy.scrollTo("setting_row_\(newIndex)", anchor: .center)
                }
            }
        }
        }
        .nxScrollEdgeEffect(edges: [.top, .bottom])
        .safeAreaInset(edge: .top, spacing: 0) {
            settingsHeaderBar
        }
        .safeAreaInset(edge: .bottom, spacing: 0) {
            if game.platform != .ios || viewModel.iosDeploymentTab == .singleGame {
                footerBar(onDismiss: { dismiss() })
            }
        }
        .nxSheetSurface()
        .frame(minWidth: 640, idealWidth: 700, maxWidth: 780, minHeight: 580, idealHeight: 660, maxHeight: 780)
    }
    
    @ViewBuilder
    private func ootEnhancedSection(rowIndex: Int) -> some View {
        let subFocus = [22, 23, 24, 25, 26, 27]
        let isCardFocused = viewModel.settingsModalFocusIndex == rowIndex || subFocus.contains(viewModel.settingsModalFocusIndex)
        settingCard(
            rowIndex: rowIndex,
            additionalFocusIndices: subFocus,
            title: viewModel.tr("settings_modal.oot_upscaler_title"),
            icon: "bolt.badge.automatic.fill",
            iconColor: NXTheme.primary
        ) {
            VStack(alignment: .leading, spacing: 10) {
                // Upscaler Mode Segmented Picker
                modalSubRowFocus(rowIndex: rowIndex) {
                    VStack(alignment: .leading, spacing: 6) {
                        Text(viewModel.tr("settings_modal.oot_mode_label"))
                            .font(.system(size: 12, weight: .semibold))
                            .foregroundColor(viewModel.settingsModalFocusIndex == rowIndex ? .white : NXTheme.modalDescription)
                        
                        NXLiquidSegmentedPicker(
                            selection: $viewModel.activeSettingsConfig.ootUpscalerMode,
                            options: [
                                NXSegmentOption(value: "off", title: viewModel.tr("settings_modal.oot_mode_ultraboost"), icon: "bolt.fill"),
                                NXSegmentOption(value: "metalfx", title: viewModel.tr("settings_modal.oot_mode_metalfx"), icon: "sparkles"),
                                NXSegmentOption(value: "game", title: viewModel.tr("settings_modal.oot_mode_original"), icon: "gamecontroller")
                            ]
                        )
                        
                        Text(ootUpscalerDescription)
                            .font(.system(size: 11, weight: .medium))
                            .foregroundColor(NXTheme.modalDescription)
                    }
                }
                
                // CAS Sharpening Slider (when not game original)
                if viewModel.activeSettingsConfig.ootUpscalerMode != "game" {
                    modalSubRowFocus(rowIndex: 22) {
                        VStack(alignment: .leading, spacing: 8) {
                            HStack {
                                Text(viewModel.tr("settings_modal.oot_cas_label"))
                                    .font(.system(size: 12, weight: .semibold))
                                    .foregroundColor(viewModel.settingsModalFocusIndex == 22 ? .white : NXTheme.modalDescription)
                                Spacer()
                                Text("\(Int(round(viewModel.activeSettingsConfig.ootSharpen * 100)))%")
                                    .font(.system(size: 13, weight: .bold, design: .monospaced))
                                    .foregroundColor(.white)
                            }
                            
                            NXLiquidGlassSlider(
                                value: $viewModel.activeSettingsConfig.ootSharpen,
                                in: 0.00...1.00,
                                step: 0.05,
                                accentColor: NXTheme.secondary
                            )
                            
                            NXGlassContainer(spacing: 8) {
                                HStack(spacing: 8) {
                                    Button(viewModel.tr("settings_modal.oot_cas_subtle")) {
                                        viewModel.activeSettingsConfig.ootSharpen = 0.20
                                    }
                                    .buttonStyle(NXSecondaryButtonStyle())
                                    .controlSize(.mini)
                                    
                                    Button(viewModel.tr("settings_modal.oot_cas_recommended")) {
                                        viewModel.activeSettingsConfig.ootSharpen = 0.35
                                    }
                                    .buttonStyle(NXSecondaryButtonStyle())
                                    .controlSize(.mini)
                                    
                                    Button(viewModel.tr("settings_modal.oot_cas_crisp")) {
                                        viewModel.activeSettingsConfig.ootSharpen = 0.50
                                    }
                                    .buttonStyle(NXSecondaryButtonStyle())
                                    .controlSize(.mini)
                                }
                            }
                        }
                    }
                }
                
                Divider().background(Color.white.opacity(0.12))
                
                // Fixed Resolution Native
                modalSubRowFocus(rowIndex: 23) {
                    HStack(alignment: .center, spacing: 12) {
                        VStack(alignment: .leading, spacing: 3) {
                            Text(viewModel.tr("settings_modal.oot_fixed_res_title"))
                                .font(.system(size: 13, weight: .semibold, design: .rounded))
                                .foregroundColor(.white)
                            Text(viewModel.tr("settings_modal.oot_fixed_res_desc"))
                                .font(.system(size: 11, weight: .medium))
                                .foregroundColor(viewModel.settingsModalFocusIndex == 23 ? .white : NXTheme.modalDescription)
                        }
                        Spacer(minLength: 12)
                        Toggle("", isOn: $viewModel.activeSettingsConfig.ootFixedResolution)
                            .labelsHidden()
                            .toggleStyle(.switch)
                    }
                }
                
                Divider().background(Color.white.opacity(0.12))
                
                // Microphone Support
                modalSubRowFocus(rowIndex: 24) {
                    HStack(alignment: .center, spacing: 12) {
                        VStack(alignment: .leading, spacing: 3) {
                            Text(viewModel.tr("settings_modal.oot_mic_title"))
                                .font(.system(size: 13, weight: .semibold, design: .rounded))
                                .foregroundColor(.white)
                            Text(viewModel.tr("settings_modal.oot_mic_desc"))
                                .font(.system(size: 11, weight: .medium))
                                .foregroundColor(viewModel.settingsModalFocusIndex == 24 ? .white : NXTheme.modalDescription)
                        }
                        Spacer(minLength: 12)
                        Toggle("", isOn: $viewModel.activeSettingsConfig.ootMicrophone)
                            .labelsHidden()
                            .toggleStyle(.switch)
                    }
                }

                Divider().background(Color.white.opacity(0.12))

                // Resolution Preset (Normal vs Potato 2x lighter RomFS overlay)
                modalSubRowFocus(rowIndex: 25) {
                    VStack(alignment: .leading, spacing: 6) {
                        Text(viewModel.tr("settings_modal.oot_res_preset_title"))
                            .font(.system(size: 13, weight: .semibold, design: .rounded))
                            .foregroundColor(.white)

                        NXLiquidSegmentedPicker(
                            selection: $viewModel.activeSettingsConfig.ootResolutionPreset,
                            options: [
                                NXSegmentOption(value: "normal", title: viewModel.tr("settings_modal.oot_res_preset_normal"), icon: "sparkles.tv"),
                                NXSegmentOption(value: "potato", title: viewModel.tr("settings_modal.oot_res_preset_potato"), icon: "leaf.fill")
                            ]
                        )

                        Text(viewModel.tr("settings_modal.oot_res_preset_desc"))
                            .font(.system(size: 11, weight: .medium))
                            .foregroundColor(viewModel.settingsModalFocusIndex == 25 ? .white : NXTheme.modalDescription)
                    }
                }

                Divider().background(Color.white.opacity(0.12))

                // Internal Graphics Scale Tier (DM_GFX_SCALE: 0 Native 100%, 1 Low-RAM 0.8x, 2 Ultra Low-RAM 0.67x)
                modalSubRowFocus(rowIndex: 26) {
                    VStack(alignment: .leading, spacing: 6) {
                        Text(viewModel.tr("settings_modal.oot_gfx_scale_title"))
                            .font(.system(size: 13, weight: .semibold, design: .rounded))
                            .foregroundColor(.white)

                        NXLiquidSegmentedPicker(
                            selection: $viewModel.activeSettingsConfig.ootGfxScaleTier,
                            options: [
                                NXSegmentOption(value: 0, title: viewModel.tr("settings_modal.oot_gfx_scale_native"), icon: "1.circle.fill"),
                                NXSegmentOption(value: 1, title: viewModel.tr("settings_modal.oot_gfx_scale_lowram"), icon: "memorychip"),
                                NXSegmentOption(value: 2, title: viewModel.tr("settings_modal.oot_gfx_scale_ultralowram"), icon: "leaf.fill")
                            ]
                        )

                        Text(viewModel.tr("settings_modal.oot_gfx_scale_desc"))
                            .font(.system(size: 11, weight: .medium))
                            .foregroundColor(viewModel.settingsModalFocusIndex == 26 ? .white : NXTheme.modalDescription)
                    }
                }

                Divider().background(Color.white.opacity(0.12))

                // 16 GB RAM Optimization Mode (DM_TEX_RELEASE=0 + guarded DM_GUEST_FILE)
                let detectedRamGB = GameRuntimeConfig.systemPhysicalRamGB
                let freeDiskGB = GameRuntimeConfig.availableTempDiskBytes() / (1024 * 1024 * 1024)
                let guestFileReady = GameRuntimeConfig.tempHasSpaceForGuestFile
                modalSubRowFocus(rowIndex: 27) {
                    VStack(alignment: .leading, spacing: 8) {
                        HStack(alignment: .center, spacing: 12) {
                            VStack(alignment: .leading, spacing: 3) {
                                Text(viewModel.tr("settings_modal.oot_16gb_mode_title"))
                                    .font(.system(size: 13, weight: .semibold, design: .rounded))
                                    .foregroundColor(.white)
                                Text(viewModel.tr("settings_modal.oot_16gb_mode_desc"))
                                    .font(.system(size: 11, weight: .medium))
                                    .foregroundColor(viewModel.settingsModalFocusIndex == 27 ? .white : NXTheme.modalDescription)
                            }
                            Spacer(minLength: 12)
                            Toggle("", isOn: $viewModel.activeSettingsConfig.oot16GBRamMode)
                                .labelsHidden()
                                .toggleStyle(.switch)
                        }

                        let statusText = guestFileReady
                            ? viewModel.tr("settings_modal.oot_guest_file_ready")
                            : viewModel.tr("settings_modal.oot_guest_file_low_disk")
                        HStack(spacing: 6) {
                            Image(systemName: guestFileReady ? "memorychip.fill" : "exclamationmark.triangle.fill")
                                .font(.system(size: 11, weight: .bold))
                                .foregroundColor(guestFileReady ? Color(red: 0.13, green: 0.77, blue: 0.37) : Color.orange)
                            Text(viewModel.tr("settings_modal.oot_16gb_ram_badge", Int64(detectedRamGB), freeDiskGB, statusText))
                                .font(.system(size: 10, weight: .semibold))
                                .foregroundColor(.white.opacity(0.92))
                        }
                        .padding(.horizontal, 10)
                        .padding(.vertical, 5)
                        .background(
                            RoundedRectangle(cornerRadius: 8, style: .continuous)
                                .fill(Color.black.opacity(0.28))
                        )
                    }
                }

                // Badge indicating active enhancements
                HStack(spacing: 8) {
                    Image(systemName: "checkmark.seal.fill")
                        .font(.system(size: 12, weight: .bold))
                        .foregroundColor(Color(red: 0.13, green: 0.77, blue: 0.37))
                    Text(viewModel.tr("settings_modal.oot_status_active"))
                        .font(.system(size: 10, weight: .semibold))
                        .foregroundColor(.white.opacity(isCardFocused ? 0.96 : 0.92))
                }
                .padding(.horizontal, 10)
                .padding(.vertical, 6)
                .background(
                    RoundedRectangle(cornerRadius: 8, style: .continuous)
                        .fill(Color.black.opacity(0.28))
                )
            }
        }
    }
    
    @ViewBuilder
    private func ootMotionBlurSection(rowIndex: Int) -> some View {
        let isRowFocused = viewModel.settingsModalFocusIndex == rowIndex
        settingCard(
            rowIndex: rowIndex,
            title: viewModel.tr("settings_modal.oot_motion_blur_title"),
            icon: "camera.aperture",
            iconColor: Color(red: 0.35, green: 0.78, blue: 1.0)
        ) {
            HStack(alignment: .center, spacing: 12) {
                VStack(alignment: .leading, spacing: 3) {
                    Text(viewModel.activeSettingsConfig.ootMotionBlur
                         ? viewModel.tr("settings_modal.oot_motion_blur_enabled")
                         : viewModel.tr("settings_modal.oot_motion_blur_disabled"))
                        .font(.system(size: 13, weight: .semibold, design: .rounded))
                        .foregroundColor(.white)
                    Text(viewModel.tr("settings_modal.oot_motion_blur_desc"))
                        .font(.system(size: 11, weight: .medium))
                        .foregroundColor(isRowFocused ? .white : NXTheme.modalDescription)
                }
                Spacer(minLength: 12)
                Toggle("", isOn: $viewModel.activeSettingsConfig.ootMotionBlur)
                    .labelsHidden()
                    .toggleStyle(.switch)
            }
        }
    }

    @ViewBuilder
    private func framegenToggleSection(isRowFocused: Bool) -> some View {
        HStack(alignment: .center, spacing: 12) {
            VStack(alignment: .leading, spacing: 3) {
                Text(viewModel.tr("settings_modal.oot_framegen_title"))
                    .font(.system(size: 13, weight: .semibold, design: .rounded))
                    .foregroundColor(.white)
                Text(viewModel.tr("settings_modal.oot_framegen_desc"))
                    .font(.system(size: 11, weight: .medium))
                    .foregroundColor(isRowFocused ? .white : NXTheme.modalDescription)
            }
            Spacer(minLength: 12)
            Toggle("", isOn: $viewModel.activeSettingsConfig.ootExperimentalFrameGen)
                .labelsHidden()
                .toggleStyle(.switch)
        }
    }

    private var ootUpscalerDescription: String {
        switch viewModel.activeSettingsConfig.ootUpscalerMode {
        case "off":
            return viewModel.tr("settings_modal.oot_desc_ultraboost")
        case "metalfx":
            return viewModel.tr("settings_modal.oot_desc_metalfx")
        default:
            return viewModel.tr("settings_modal.oot_desc_original")
        }
    }
}
