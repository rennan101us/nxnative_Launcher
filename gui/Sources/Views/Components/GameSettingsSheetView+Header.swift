import SwiftUI
import AppKit
import UniformTypeIdentifiers

// MARK: - Header, Game Management & Modal Dismiss Handlers
extension GameSettingsSheetView {
    internal var settingsHeaderBar: some View {
        let headerContent = HStack(spacing: 14) {
            let icon = GameCoverService.shared.coverImage(for: game) ?? NSWorkspace.shared.icon(forFile: game.url.path)
            Image(nsImage: icon)
                .resizable()
                .aspectRatio(contentMode: .fit)
                .frame(width: 52, height: 52)
                .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
                .shadow(color: NXTheme.primary.opacity(0.35), radius: 8, x: 0, y: 3)
                .overlay(
                    RoundedRectangle(cornerRadius: 12, style: .continuous)
                        .stroke(NXTheme.specularRim, lineWidth: 1)
                )
            
            VStack(alignment: .leading, spacing: 3) {
                Text(game.name)
                    .font(.system(size: 16, weight: .bold, design: .rounded))
                    .foregroundColor(NXTheme.textPrimary)
                    .lineLimit(1)
                
                HStack(spacing: 6) {
                    Text(game.platform == .macApp ? "Mac Port" : (game.platform == .nonSwitch ? "Mac Native" : (game.isSwitch2 ? "iOS (Switch 2)" : "iOS IPA")))
                        .font(.system(size: 10, weight: .bold))
                        .padding(.horizontal, 6)
                        .padding(.vertical, 2)
                        .background(game.platform == .nonSwitch ? Color(red: 0.20, green: 0.82, blue: 0.60).opacity(0.25) : (game.platform == .macApp ? NXTheme.primary.opacity(0.25) : NXTheme.secondary.opacity(0.25)))
                        .foregroundColor(.white)
                        .clipShape(Capsule())
                    
                    if let ver = game.versionString {
                        Text("v\(ver)")
                            .font(.system(size: 11, design: .monospaced))
                            .foregroundColor(NXTheme.textSecondary)
                    }
                    
                    if let tid = game.titleId {
                        Text("[\(tid)]")
                            .font(.system(size: 10, design: .monospaced))
                            .foregroundColor(NXTheme.textMuted)
                    }
                }
            }
            
            Spacer()
            
            NXModalCloseButton(size: 30) {
                viewModel.gameForSettingsSheet = nil
                dismiss()
            }
        }
        
        return VStack(spacing: 0) {
            headerContent
                .padding(.horizontal, 16)
                .padding(.vertical, 10)
                .nxGlassBar(in: RoundedRectangle(cornerRadius: 18, style: .continuous))
                .padding(.horizontal, 14)
                .padding(.top, 10)
                .padding(.bottom, game.platform == .ios ? 6 : 10)

            if game.platform == .ios {
                NXLiquidSegmentedPicker(
                    selection: $viewModel.iosDeploymentTab,
                    options: [
                        NXSegmentOption(value: IosDeploymentTab.singleGame, title: L10n.t("nxn_launcher.tab_single"), icon: "iphone.gen3"),
                        NXSegmentOption(value: IosDeploymentTab.multiPort, title: L10n.t("nxn_launcher.tab_multi"), icon: "square.stack.3d.up.fill")
                    ]
                )
                .padding(.horizontal, 16)
                .padding(.bottom, 10)
            }
        }
        .frame(maxWidth: .infinity)
        .background(
            ZStack {
                NXTheme.canvasObsidian
                LinearGradient(
                    colors: [Color.black.opacity(0.85), Color.black.opacity(0.95)],
                    startPoint: .top,
                    endPoint: .bottom
                )
            }
            .ignoresSafeArea(edges: .top)
        )
        .overlay(
            Rectangle()
                .fill(NXTheme.borderSubtle.opacity(0.7))
                .frame(height: 1),
            alignment: .bottom
        )
        .shadow(color: Color.black.opacity(0.5), radius: 6, x: 0, y: 3)
    }
    
    func coverArtworkSection() -> some View {
        let isCustomCover = GameCoverService.shared.hasCustomCover(for: game)
        let currentCover = GameCoverService.shared.coverImage(for: game) ?? NSWorkspace.shared.icon(forFile: game.url.path)
        let isCustomBg = GameCoverService.shared.hasCustomBackground(for: game)
        let currentBg = GameCoverService.shared.backgroundImage(for: game)

        return settingCard(
            rowIndex: 11,
            title: viewModel.tr("settings_modal.cover_title"),
            icon: "photo.on.rectangle.angled",
            iconColor: Color(red: 0.95, green: 0.45, blue: 0.75)
        ) {
            let isRowFocused = viewModel.settingsModalFocusIndex == 11
            VStack(alignment: .leading, spacing: 14) {
                // MARK: - 1. Cover Artwork (Portrait)
                HStack(spacing: 16) {
                    Image(nsImage: currentCover)
                        .resizable()
                        .aspectRatio(contentMode: .fit)
                        .frame(width: 55, height: 78)
                        .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
                        .overlay(
                            RoundedRectangle(cornerRadius: 8, style: .continuous)
                                .stroke(NXTheme.specularRim, lineWidth: 1)
                        )
                        .shadow(color: Color.black.opacity(0.4), radius: 6, x: 0, y: 2)

                    VStack(alignment: .leading, spacing: 5) {
                        HStack(spacing: 6) {
                            Text(isCustomCover ? viewModel.tr("settings_modal.cover_custom_active") : viewModel.tr("settings_modal.cover_auto_active"))
                                .font(.system(size: 12, weight: .bold, design: .rounded))
                                .foregroundColor(isCustomCover ? NXTheme.secondary : NXTheme.textPrimary)

                            if isCustomCover {
                                Text(viewModel.tr("settings_modal.cover_custom_badge"))
                                    .font(.system(size: 8, weight: .heavy, design: .monospaced))
                                    .padding(.horizontal, 4)
                                    .padding(.vertical, 1)
                                    .background(NXTheme.secondary.opacity(0.25))
                                    .foregroundColor(NXTheme.secondary)
                                    .clipShape(Capsule())
                            }
                        }

                        Text(isCustomCover
                             ? viewModel.tr("settings_modal.cover_custom_desc")
                             : viewModel.tr("settings_modal.cover_auto_desc"))
                            .font(.system(size: 11, weight: .medium))
                            .foregroundColor(NXTheme.modalDescription)
                            .fixedSize(horizontal: false, vertical: true)

                        NXGlassContainer(spacing: 8) {
                            HStack(spacing: 8) {
                                Button(viewModel.tr("settings_modal.cover_choose_btn")) {
                                    viewModel.selectCustomCover(for: game)
                                }
                                .buttonStyle(NXSecondaryButtonStyle())
                                .controlSize(.small)
                                .nxConsoleFocusRing(in: Capsule(), isFocused: isRowFocused && viewModel.settingsModalSubFocusIndex == 0)

                                if isCustomCover {
                                    Button(viewModel.tr("settings_modal.cover_reset_btn")) {
                                        SoundEffectService.shared.play(.click)
                                        GameCoverService.shared.resetCustomCover(for: game)
                                        SaveSyncService.shared.applySaveDirectoryIcons(for: game)
                                    }
                                    .buttonStyle(NXSecondaryButtonStyle())
                                    .controlSize(.small)
                                    .foregroundColor(Color(red: 1.0, green: 0.4, blue: 0.4))
                                }
                            }
                        }
                        .padding(.top, 2)
                    }
                    Spacer()
                }

                Divider().background(Color.white.opacity(0.12))

                // MARK: - 2. Background Artwork (Widescreen 16:9)
                HStack(spacing: 16) {
                    Group {
                        if let bgImg = currentBg {
                            Image(nsImage: bgImg)
                                .resizable()
                                .aspectRatio(contentMode: .fill)
                                .frame(width: 96, height: 54)
                                .clipped()
                        } else {
                            ZStack {
                                LinearGradient(
                                    colors: [Color.black.opacity(0.7), NXTheme.primary.opacity(0.3)],
                                    startPoint: .topLeading,
                                    endPoint: .bottomTrailing
                                )
                                VStack(spacing: 3) {
                                    Image(systemName: "photo.badge.plus")
                                        .font(.system(size: 15))
                                        .foregroundColor(NXTheme.textMuted)
                                    Text(viewModel.tr("settings_modal.background_no_image"))
                                        .font(.system(size: 8, weight: .bold))
                                        .foregroundColor(NXTheme.textMuted)
                                }
                            }
                            .frame(width: 96, height: 54)
                        }
                    }
                    .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
                    .overlay(
                        RoundedRectangle(cornerRadius: 8, style: .continuous)
                            .stroke(NXTheme.specularRim, lineWidth: 1)
                    )
                    .shadow(color: Color.black.opacity(0.4), radius: 6, x: 0, y: 2)

                    VStack(alignment: .leading, spacing: 5) {
                        HStack(spacing: 6) {
                            Text(isCustomBg ? viewModel.tr("settings_modal.background_custom_active") : viewModel.tr("settings_modal.background_auto_active"))
                                .font(.system(size: 12, weight: .bold, design: .rounded))
                                .foregroundColor(isCustomBg ? NXTheme.secondary : NXTheme.textPrimary)

                            if isCustomBg {
                                Text(viewModel.tr("settings_modal.cover_custom_badge"))
                                    .font(.system(size: 8, weight: .heavy, design: .monospaced))
                                    .padding(.horizontal, 4)
                                    .padding(.vertical, 1)
                                    .background(NXTheme.secondary.opacity(0.25))
                                    .foregroundColor(NXTheme.secondary)
                                    .clipShape(Capsule())
                            }
                        }

                        Text(isCustomBg
                             ? viewModel.tr("settings_modal.background_custom_desc")
                             : viewModel.tr("settings_modal.background_auto_desc"))
                            .font(.system(size: 11, weight: .medium))
                            .foregroundColor(NXTheme.modalDescription)
                            .fixedSize(horizontal: false, vertical: true)

                        NXGlassContainer(spacing: 8) {
                            HStack(spacing: 8) {
                                Button(viewModel.tr("settings_modal.background_choose_btn")) {
                                    viewModel.selectCustomBackground(for: game)
                                }
                                .buttonStyle(NXSecondaryButtonStyle())
                                .controlSize(.small)
                                .nxConsoleFocusRing(in: Capsule(), isFocused: isRowFocused && viewModel.settingsModalSubFocusIndex == 1)

                                if isCustomBg {
                                    Button(viewModel.tr("settings_modal.background_reset_btn")) {
                                        SoundEffectService.shared.play(.click)
                                        GameCoverService.shared.resetCustomBackground(for: game)
                                    }
                                    .buttonStyle(NXSecondaryButtonStyle())
                                    .controlSize(.small)
                                    .foregroundColor(Color(red: 1.0, green: 0.4, blue: 0.4))
                                }
                            }
                        }
                        .padding(.top, 2)
                    }
                    Spacer()
                }
            }
        }
    }

    func gameManagementSection() -> some View {
        settingCard(
            rowIndex: 12,
            title: viewModel.tr("settings_modal.management_title"),
            icon: "gearshape.2.fill",
            iconColor: NXTheme.modalIconColor
        ) {
            let isRowFocused = viewModel.settingsModalFocusIndex == 12
            VStack(alignment: .leading, spacing: 10) {
                Text(viewModel.tr("settings_modal.management_desc"))
                    .font(.system(size: 11, weight: .medium))
                    .foregroundColor(isRowFocused ? .white : NXTheme.modalDescription)
                
                HStack(spacing: 12) {
                    Spacer()
                    
                    NXGlassContainer(spacing: 12) {
                        HStack(spacing: 12) {
                            Button(action: {
                                dismissSettingsAndShowHide()
                            }) {
                                HStack(spacing: 6) {
                                    Image(systemName: "eye.slash")
                                    Text(viewModel.tr("actions.hide_from_library"))
                                }
                            }
                            .buttonStyle(NXSecondaryButtonStyle())
                            .nxConsoleFocusRing(in: Capsule(), isFocused: isRowFocused && viewModel.settingsModalSubFocusIndex == 0)
                            
                            Button(action: {
                                dismissSettingsAndShowRemove()
                            }) {
                                HStack(spacing: 6) {
                                    Image(systemName: "folder.badge.minus")
                                    Text(viewModel.tr("actions.remove_from_library"))
                                }
                            }
                            .buttonStyle(NXSecondaryButtonStyle())
                            .nxConsoleFocusRing(in: Capsule(), isFocused: isRowFocused && viewModel.settingsModalSubFocusIndex == 1)
                            
                            Button(action: {
                                dismissSettingsAndShowTrash()
                            }) {
                                HStack(spacing: 6) {
                                    Image(systemName: "trash.fill")
                                    Text(viewModel.tr("actions.move_to_trash"))
                                }
                                .foregroundColor(Color(red: 0.95, green: 0.35, blue: 0.35))
                            }
                            .buttonStyle(NXSecondaryButtonStyle())
                            .nxConsoleFocusRing(in: Capsule(), isFocused: isRowFocused && viewModel.settingsModalSubFocusIndex == 2)
                        }
                    }
                }
                .padding(.top, 2)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }
    
    func dismissSettingsAndShowHide() {
        let target = game
        viewModel.gameForSettingsSheet = nil
        dismiss()
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.25) {
            viewModel.confirmDialogFocusIndex = 1
            viewModel.gameToHide = target
            viewModel.showHideConfirm = true
        }
    }
    
    func dismissSettingsAndShowRemove() {
        let target = game
        viewModel.gameForSettingsSheet = nil
        dismiss()
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.25) {
            viewModel.confirmDialogFocusIndex = 1
            viewModel.gameToRemove = target
            viewModel.showRemoveConfirm = true
        }
    }
    
    func dismissSettingsAndShowTrash() {
        let target = game
        viewModel.gameForSettingsSheet = nil
        dismiss()
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.25) {
            viewModel.confirmDialogFocusIndex = 1
            viewModel.gameToTrash = target
            viewModel.showTrashConfirm = true
        }
    }
}
