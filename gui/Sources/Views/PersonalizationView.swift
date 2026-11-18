import SwiftUI

public struct PersonalizationView: View {
    @ObservedObject public var viewModel: AppViewModel
    @ObservedObject internal var soundService = SoundEffectService.shared
    @Namespace internal var glassAppearanceNamespace
    @Namespace internal var colorSelectionNamespace
    
    public init(viewModel: AppViewModel) {
        self.viewModel = viewModel
    }
    
    private var hasNonDefaultSettings: Bool {
        viewModel.highlightTheme != .electricPurple
            || viewModel.iconAppearanceMode != .default
            || !soundService.isSoundEnabled
            || viewModel.launcherLanguage != .system
            || !viewModel.isLiquidGlassEnabled
            || abs(viewModel.liquidGlassIntensity - 1.0) > 0.01
    }
    
    private func cardStroke(for index: Int, cornerRadius: CGFloat = 16) -> some View {
        let isZoneActive = viewModel.focusZone == .content && !viewModel.isAnyModalPresented
        let isSelected = isZoneActive && viewModel.personalizeCardIndex == index
        let isInside = viewModel.isInsidePersonalizeCard
        return RoundedRectangle(cornerRadius: cornerRadius)
            .stroke(
                isSelected ? (isInside ? NXTheme.secondary.opacity(0.85) : NXTheme.primary) : Color.clear,
                lineWidth: isSelected ? (isInside ? 1.5 : 2.5) : 0
            )
            .shadow(
                color: (isSelected && !isInside) ? NXTheme.primary.opacity(0.45) : Color.clear,
                radius: 8
            )
    }

    public var body: some View {
        ScrollViewReader { proxy in
            ScrollView {
                VStack(alignment: .leading, spacing: 20) {
                    headerView
                        .frame(maxWidth: .infinity)
                        .id("personalize_card_0")
                        .overlay(cardStroke(for: 0, cornerRadius: 16))

                    // MARK: - Responsive Layout: Language & Sound (Left) | Colors & App Icon (Wide Right)
                    HStack(alignment: .top, spacing: 18) {
                        // Left Column: Launcher Language on top, Sound Control card bellow it
                        VStack(spacing: 18) {
                            launcherLanguageCard
                                .id("personalize_card_1")
                                .overlay(cardStroke(for: 1, cornerRadius: 16))

                            soundEffectsCard
                                .id("personalize_card_4")
                                .overlay(cardStroke(for: 4, cornerRadius: 16))
                        }
                        .frame(minWidth: 260, idealWidth: 300, maxWidth: 330)

                        // Right Column: Color Appearance & App Icon (wider, fulfilling the window)
                        VStack(spacing: 18) {
                            highlightColorCard
                                .frame(maxWidth: .infinity)
                                .id("personalize_card_2")
                                .overlay(cardStroke(for: 2, cornerRadius: 18))

                            SystemAppearanceCard(viewModel: viewModel)
                                .frame(maxWidth: .infinity)
                                .id("personalize_card_3")
                                .overlay(cardStroke(for: 3, cornerRadius: 16))
                        }
                        .frame(maxWidth: .infinity)
                    }
                }
                .padding(20)
                .frame(maxWidth: .infinity, alignment: .topLeading)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .nxScrollEdgeEffect(edges: [.top, .bottom])
            .onChange(of: viewModel.personalizeCardIndex) { newIdx in
                withAnimation(.easeInOut(duration: 0.25)) {
                    proxy.scrollTo("personalize_card_\(newIdx)", anchor: .center)
                }
            }
        }
    }
    
    private var headerView: some View {
        HStack {
            Text(viewModel.tr("personalization.title"))
                .font(.system(size: 18, weight: .bold, design: .rounded))
                .foregroundColor(NXTheme.textPrimary)
            
            Spacer()
            
            if hasNonDefaultSettings {
                NXGlassContainer(spacing: 8) {
                    Button(action: {
                        SoundEffectService.shared.play(.click)
                        withAnimation(.spring(response: 0.30, dampingFraction: 0.80)) {
                            viewModel.highlightTheme = .electricPurple
                            viewModel.iconAppearanceMode = .default
                            soundService.isSoundEnabled = true
                            viewModel.launcherLanguage = .system
                            viewModel.isLiquidGlassEnabled = true
                            viewModel.liquidGlassIntensity = 1.0
                            viewModel.liquidGlassAppearance = .liquid
                        }
                    }) {
                        HStack(spacing: 6) {
                            Image(systemName: "arrow.counterclockwise")
                            Text(viewModel.tr("personalization.reset_defaults"))
                        }
                    }
                    .buttonStyle(NXSecondaryButtonStyle())
                    .nxGlassTransition(.materialize)
                }
            }
        }
    }
    
    private var launcherLanguageCard: some View {
        GlassCard(cornerRadius: 16, padding: 18) {
            VStack(alignment: .leading, spacing: 14) {
                HStack(spacing: 8) {
                    Image(systemName: "globe")
                        .font(.system(size: 14, weight: .bold))
                        .foregroundColor(viewModel.highlightTheme.primaryColor)
                    
                    Text(viewModel.tr("personalization.launcher_language"))
                        .font(.system(size: 14, weight: .bold, design: .rounded))
                        .foregroundColor(NXTheme.textPrimary)
                    
                    Spacer()
                }
                
                Text(viewModel.tr("personalization.launcher_language_subtitle"))
                    .font(.system(size: 11))
                    .foregroundColor(NXTheme.textSecondary)
                
                languageDropdownMenu
            }
        }
    }
    
    private var languageDropdownMenu: some View {
        let isFocused = viewModel.isInsidePersonalizeCard && viewModel.personalizeCardIndex == 1
        
        return Picker(selection: Binding(
            get: { viewModel.launcherLanguage },
            set: { newLang in
                SoundEffectService.shared.play(.click)
                withAnimation(.spring(response: 0.28, dampingFraction: 0.78)) {
                    viewModel.launcherLanguage = newLang
                }
            }
        )) {
            ForEach(AppLanguage.sortedForDisplay, id: \.id) { lang in
                Text("\(lang.flag)  \(lang == .system ? viewModel.tr("personalization.icon_auto") : lang.nativeName)")
                    .tag(lang)
            }
        } label: {
            HStack(spacing: 10) {
                Text(viewModel.launcherLanguage.flag)
                    .font(.system(size: 18))
                
                Text(viewModel.launcherLanguage == .system ? viewModel.tr("personalization.icon_auto") : viewModel.launcherLanguage.nativeName)
                    .font(.system(size: 13, weight: .semibold, design: .rounded))
                    .foregroundColor(.white)
                
                Spacer()
                
                Image(systemName: "chevron.up.chevron.down")
                    .font(.system(size: 10, weight: .bold))
                    .foregroundColor(.white.opacity(0.75))
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 10)
            .frame(maxWidth: .infinity)
            .nxGlassBar(
                in: RoundedRectangle(cornerRadius: 12, style: .continuous),
                fallbackFill: NXTheme.glassSurfaceElevated.opacity(0.65),
                fallbackStroke: NXTheme.borderSubtle
            )
            .nxGlassInteractive(
                in: RoundedRectangle(cornerRadius: 12, style: .continuous),
                tint: viewModel.highlightTheme.primaryColor.opacity(0.35)
            )
            .overlay(
                RoundedRectangle(cornerRadius: 12, style: .continuous)
                    .stroke(isFocused ? NXTheme.secondary : Color.clear, lineWidth: 1.5)
            )
            .nxConsoleFocusRing(in: RoundedRectangle(cornerRadius: 12, style: .continuous), isFocused: viewModel.focusZone == .content && isFocused)
        }
        .pickerStyle(.menu)
        .labelsHidden()
        .nxNoFocusRing()
    }
}
