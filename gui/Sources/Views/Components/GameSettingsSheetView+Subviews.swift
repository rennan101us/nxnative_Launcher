import SwiftUI
import AppKit
import UniformTypeIdentifiers

// MARK: - Subviews and Card Helpers for GameSettingsSheetView
extension GameSettingsSheetView {
    
    func controllerProfileSection(rowIndex: Int, additionalFocusIndices: [Int] = []) -> some View {
        settingCard(
            rowIndex: rowIndex,
            additionalFocusIndices: additionalFocusIndices,
            title: viewModel.tr("settings_modal.controller_profile_title"),
            icon: "gamecontroller.fill",
            iconColor: Color(red: 0.58, green: 0.42, blue: 1.0)
        ) {
            GameSettingsControllerSection(viewModel: viewModel, game: game, rowIndex: rowIndex)
        }
    }
    
    func gameLanguageSection(rowIndex: Int) -> some View {
        let supportedCodes = LibraryScanner.shared.supportedGameLanguages(at: game.url)
        let defaultCode = LibraryScanner.shared.defaultGameLanguage(at: game.url)
        let rawSelected = viewModel.activeSettingsConfig.gameLanguage?.trimmingCharacters(in: .whitespacesAndNewlines)
        let currentCode: String = {
            if let selected = rawSelected, !selected.isEmpty, supportedCodes.contains(selected) {
                return selected
            }
            if supportedCodes.contains(defaultCode) {
                return defaultCode
            }
            return supportedCodes.first ?? "en-US"
        }()
        let currentInfo = GameRuntimeConfig.languageDisplayInfo(for: currentCode)

        return settingCard(
            rowIndex: rowIndex,
            title: viewModel.tr("settings_modal.game_language_title"),
            icon: "globe",
            iconColor: Color(red: 0.20, green: 0.78, blue: 0.90)
        ) {
            let isRowFocused = viewModel.settingsModalFocusIndex == rowIndex
            HStack(alignment: .center, spacing: 12) {
                VStack(alignment: .leading, spacing: 3) {
                    Text(viewModel.tr("settings_modal.game_language_label"))
                        .font(.system(size: 13, weight: .semibold, design: .rounded))
                        .foregroundColor(.white)
                    Text(viewModel.tr("settings_modal.game_language_desc"))
                        .font(.system(size: 11, weight: .medium))
                        .foregroundColor(isRowFocused ? .white : NXTheme.modalDescription)
                }

                Spacer(minLength: 12)

                Menu {
                    ForEach(supportedCodes, id: \.self) { code in
                        let info = GameRuntimeConfig.languageDisplayInfo(for: code)
                        let itemTitle = "\(info.flag)  \(info.name)  [\(info.code)]"
                        Button(action: {
                            SoundEffectService.shared.play(.click)
                            viewModel.activeSettingsConfig.gameLanguage = code
                        }) {
                            if code == currentCode {
                                Label(itemTitle, systemImage: "checkmark")
                            } else {
                                Text(itemTitle)
                            }
                        }
                    }
                } label: {
                    HStack(spacing: 8) {
                        Text(currentInfo.flag)
                            .font(.system(size: 13))
                        Text(currentInfo.name)
                            .font(.system(size: 12, weight: .bold, design: .rounded))
                            .foregroundColor(.white)
                            .lineLimit(1)
                        Text(currentInfo.code)
                            .font(.system(size: 10, weight: .bold, design: .monospaced))
                            .foregroundColor(.white.opacity(0.85))
                            .padding(.horizontal, 6)
                            .padding(.vertical, 2)
                            .background(Capsule().fill(NXTheme.primary.opacity(0.28)))
                        Image(systemName: "chevron.up.chevron.down")
                            .font(.system(size: 9, weight: .bold))
                            .foregroundColor(.white.opacity(0.75))
                    }
                    .padding(.horizontal, 14)
                    .padding(.vertical, 8)
                    .contentShape(Capsule())
                    .nxGlassInteractive(in: Capsule(), fallbackFill: NXTheme.glassSurfaceElevated)
                    .overlay(
                        Capsule()
                            .stroke(NXTheme.primary.opacity(0.35), lineWidth: 1)
                    )
                }
                .menuStyle(.button)
                .buttonStyle(NXPressableButtonStyle())
                .menuIndicator(.hidden)
                .fixedSize()
                .nxNoFocusRing()
            }
        }
    }

    func footerBar(onDismiss: @escaping () -> Void) -> some View {
        let footerContent = VStack(spacing: 10) {
            NXGlassContainer(spacing: 10) {
                HStack(spacing: 12) {
                    Button(viewModel.tr("personalization.reset_defaults")) {
                        var resetCfg = isOot ? GameRuntimeConfig.defaultOotConfig() : GameRuntimeConfig()
                        resetCfg.gameLanguage = LibraryScanner.shared.defaultGameLanguage(at: game.url)
                        viewModel.activeSettingsConfig = resetCfg
                    }
                    .buttonStyle(NXSecondaryButtonStyle())
                    .controlSize(.regular)
                    .overlay(
                        Capsule()
                            .stroke(viewModel.settingsModalFocusIndex == 8 ? NXTheme.secondary : Color.clear, lineWidth: 2)
                    )
                    
                    Spacer()
                    
                    Button(viewModel.tr("common.cancel")) {
                        viewModel.gameForSettingsSheet = nil
                        onDismiss()
                    }
                    .buttonStyle(NXSecondaryButtonStyle())
                    .controlSize(.regular)
                    .overlay(
                        Capsule()
                            .stroke(viewModel.settingsModalFocusIndex == 9 ? NXTheme.secondary : Color.clear, lineWidth: 2)
                    )
                    
                    Button(viewModel.tr("common.save")) {
                        viewModel.saveRuntimeConfig(viewModel.activeSettingsConfig, for: game)
                        viewModel.gameForSettingsSheet = nil
                        onDismiss()
                    }
                    .buttonStyle(NXPrimaryButtonStyle())
                    .controlSize(.regular)
                    .overlay(
                        Capsule()
                            .stroke(viewModel.settingsModalFocusIndex == 10 ? Color.white : Color.clear, lineWidth: 2)
                    )
                    .shadow(color: viewModel.settingsModalFocusIndex == 10 ? NXTheme.primary.opacity(0.8) : Color.clear, radius: 8)
                }
            }
            
            // Controller navigation hints strip
            HStack(spacing: 12) {
                hintBadge(glyph: "↑/↓", text: viewModel.tr("controls.hint_navigate"), isPill: true)
                hintBadge(glyph: "←/→", text: viewModel.tr("controls.hint_adjust"), isPill: true)
                hintBadge(
                    glyph: controllerService.activeBrand == .playstation ? "✕" : "A",
                    text: viewModel.tr("controls.hint_toggle"),
                    bgColor: Color(red: 0.06, green: 0.49, blue: 0.06)
                )
                hintBadge(
                    glyph: controllerService.activeBrand == .playstation ? "□" : "X",
                    text: viewModel.tr("settings_modal.save_and_close"),
                    bgColor: Color(red: 0.0, green: 0.47, blue: 0.84)
                )
                hintBadge(
                    glyph: controllerService.activeBrand == .playstation ? "○" : "B",
                    text: viewModel.tr("common.close"),
                    bgColor: Color(red: 0.91, green: 0.07, blue: 0.14)
                )
            }
            .padding(.top, 2)
        }
        
        return Group {
            if useLiquidGlass {
                footerContent
                    .padding(.horizontal, 16)
                    .padding(.vertical, 12)
                    .nxGlassBar(in: RoundedRectangle(cornerRadius: 18, style: .continuous))
                    .padding(.horizontal, 14)
                    .padding(.top, 8)
                    .padding(.bottom, 10)
                    .frame(maxWidth: .infinity)
                    .background(
                        ZStack {
                            NXTheme.canvasObsidian
                            LinearGradient(
                                colors: [Color.black.opacity(0.85), Color.black.opacity(0.95)],
                                startPoint: .bottom,
                                endPoint: .top
                            )
                        }
                        .ignoresSafeArea(edges: .bottom)
                    )
                    .overlay(
                        Rectangle()
                            .fill(NXTheme.borderSubtle.opacity(0.7))
                            .frame(height: 1),
                        alignment: .top
                    )
                    .shadow(color: Color.black.opacity(0.6), radius: 8, x: 0, y: -3)
            } else {
                footerContent
                    .padding(.horizontal, 20)
                    .padding(.vertical, 14)
                    .background(
                        ZStack {
                            NXTheme.glassSurfaceElevated.opacity(0.85)
                            Rectangle().fill(.ultraThinMaterial)
                        }
                    )
                    .overlay(
                        Rectangle()
                            .frame(height: 1)
                            .foregroundColor(NXTheme.borderSubtle),
                        alignment: .top
                    )
            }
        }
    }
    
    func hintBadge(glyph: String, text: String, isPill: Bool = false, bgColor: Color = Color(white: 0.25)) -> some View {
        HStack(spacing: 4) {
            if isPill {
                Text(glyph)
                    .font(.system(size: 9, weight: .bold, design: .rounded))
                    .foregroundColor(.white)
                    .padding(.horizontal, 5)
                    .padding(.vertical, 2)
                    .background(Capsule().fill(bgColor))
            } else {
                Text(glyph)
                    .font(.system(size: 9, weight: .black, design: .rounded))
                    .foregroundColor(.white)
                    .frame(width: 16, height: 16)
                    .background(Circle().fill(bgColor))
            }
            Text(text)
                .font(.system(size: 10, weight: .medium, design: .rounded))
                .foregroundColor(NXTheme.modalDescription)
        }
    }
    
    func settingCard<Content: View>(
        rowIndex: Int,
        additionalFocusIndices: [Int] = [],
        title: String,
        icon: String,
        iconColor: Color,
        @ViewBuilder content: () -> Content
    ) -> some View {
        let isFocused = (rowIndex >= 0 && viewModel.settingsModalFocusIndex == rowIndex)
            || additionalFocusIndices.contains(viewModel.settingsModalFocusIndex)
        
        return VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 8) {
                Image(systemName: icon)
                    .font(.system(size: 13, weight: .bold))
                    .foregroundColor(NXTheme.isNeonBlack ? .white : iconColor)
                Text(title)
                    .font(.system(size: 13, weight: .bold, design: .rounded))
                    .foregroundColor(NXTheme.textPrimary)
                
                Spacer()
            }
            
            content()
        }
        .padding(14)
        .nxGlassCard(
            cornerRadius: 14,
            tint: isFocused ? NXTheme.primary.opacity(0.28) : nil
        )
        .overlay(
            Group {
                if isFocused {
                    RoundedRectangle(cornerRadius: 14, style: .continuous)
                        .strokeBorder(NXTheme.primaryGradient, lineWidth: 2.2)
                }
            }
        )
        .shadow(color: isFocused ? NXTheme.primary.opacity(0.4) : Color.clear, radius: 8, x: 0, y: 2)
        .animation(.easeInOut(duration: 0.15), value: isFocused)
        .onTapGesture {
            if rowIndex >= 0 {
                viewModel.settingsModalFocusIndex = rowIndex
            }
        }
    }

    func modalSubRowFocus<Content: View>(
        rowIndex: Int,
        @ViewBuilder content: () -> Content
    ) -> some View {
        let isSubFocused = viewModel.settingsModalFocusIndex == rowIndex
        return content()
            .padding(.horizontal, 10)
            .padding(.vertical, 8)
            .background(
                RoundedRectangle(cornerRadius: 10, style: .continuous)
                    .fill(isSubFocused ? NXTheme.secondary.opacity(0.16) : Color.clear)
            )
            .overlay(
                RoundedRectangle(cornerRadius: 10, style: .continuous)
                    .strokeBorder(isSubFocused ? NXTheme.secondary : Color.clear, lineWidth: 1.6)
            )
            .contentShape(Rectangle())
            .onTapGesture {
                viewModel.settingsModalFocusIndex = rowIndex
            }
            .id("setting_row_\(rowIndex)")
    }
}
