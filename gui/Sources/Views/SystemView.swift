import SwiftUI

public struct SystemView: View {
    @ObservedObject public var viewModel: AppViewModel
    @Namespace private var categoryNamespace
    
    public init(viewModel: AppViewModel) {
        self.viewModel = viewModel
    }
    
    public var body: some View {
        ScrollViewReader { proxy in
            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    // Header & Global Quick Actions
                    headerView
                        .frame(maxWidth: .infinity)
                    
                    // Category Navigation Tabs (Console Style)
                    categoryTabBar
                        .frame(maxWidth: .infinity)
                    
                    // Active Category Content
                    categoryContentView
                        .frame(maxWidth: .infinity)
                }
                .padding(20)
                .frame(maxWidth: .infinity, alignment: .topLeading)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .nxScrollEdgeEffect(edges: [.top, .bottom])
            .onChange(of: viewModel.isDeveloperMode) { isDev in
                if !isDev && viewModel.activeSettingsCategory == .developer {
                    withAnimation(.spring(response: 0.32, dampingFraction: 0.78)) {
                        viewModel.activeSettingsCategory = .general
                        viewModel.settingsItemFocusIndex = 0
                    }
                }
            }
        }
        .sheet(isPresented: $viewModel.showRyujinxNotFoundSheet) {
            RyujinxKeyMissingSheet(viewModel: viewModel)
                .environment(\.nxLiquidGlass, viewModel.liquidGlassEnvironment)
        }
    }
    
    // MARK: - Header View
    private var headerView: some View {
        let isSystemActive = viewModel.focusZone == .content && !viewModel.isAnyModalPresented
        let isDevToggleFocused = isSystemActive && viewModel.systemHeaderFocusIndex == 0
        let isQuickActionFocused = isSystemActive && viewModel.systemHeaderFocusIndex == 1
        return HStack(spacing: 12) {
            Text(viewModel.tr("system.title"))
                .font(.system(size: 18, weight: .bold, design: .rounded))
                .foregroundColor(NXTheme.textPrimary)
            
            Spacer()
            
            // Developer Mode Switch Capsule
            HStack(spacing: 8) {
                Image(systemName: "hammer.fill")
                    .font(.system(size: 11, weight: .bold))
                    .foregroundColor(viewModel.isDeveloperMode ? NXTheme.primary : NXTheme.textSecondary)
                
                Text(viewModel.tr("build.dev_mode_title"))
                    .font(.system(size: 11, weight: .semibold, design: .rounded))
                    .foregroundColor(NXTheme.textPrimary)
                
                Toggle("", isOn: $viewModel.isDeveloperMode)
                    .labelsHidden()
                    .toggleStyle(.switch)
                    .controlSize(.mini)
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 5)
            .nxGlassBar(
                in: Capsule(),
                fallbackFill: NXTheme.glassSurfaceElevated.opacity(0.65),
                fallbackStroke: NXTheme.borderSubtle
            )
            .nxConsoleFocusRing(in: Capsule(), isFocused: isDevToggleFocused)
            
            // Developer Mode Quick Actions
            if viewModel.isDeveloperMode {
                let scopedMissing = viewModel.prerequisites.missingList(for: viewModel.selectedOnboardingPlatforms)
                if !scopedMissing.isEmpty {
                    Button(action: {
                        SoundEffectService.shared.play(.click)
                        viewModel.installAllMissingDependencies()
                    }) {
                        HStack(spacing: 6) {
                            Image(systemName: "arrow.down.circle.fill")
                            Text(viewModel.tr("system.install_all_missing", scopedMissing.count))
                        }
                    }
                    .buttonStyle(NXAccentButtonStyle())
                    .nxConsoleFocusRing(in: RoundedRectangle(cornerRadius: 10, style: .continuous), isFocused: isQuickActionFocused)
                    .help(viewModel.tr("system.install_all_help"))
                } else {
                    Button(action: {
                        SoundEffectService.shared.play(.click)
                        viewModel.repairAllDependencies()
                    }) {
                        HStack(spacing: 6) {
                            Image(systemName: "arrow.triangle.2.circlepath")
                            Text(viewModel.tr("system.repair_all"))
                        }
                    }
                    .buttonStyle(NXSecondaryButtonStyle())
                    .nxConsoleFocusRing(in: RoundedRectangle(cornerRadius: 10, style: .continuous), isFocused: isQuickActionFocused)
                    .help(viewModel.tr("system.repair_all_help"))
                }
            }
        }
    }
    
    // MARK: - Category Tab Bar
    private var categoryTabBar: some View {
        HStack(spacing: 8) {
            ForEach(viewModel.availableSettingsCategories) { category in
                let isSelected = viewModel.activeSettingsCategory == category
                Button(action: {
                    SoundEffectService.shared.play(.tabSwitch)
                    withAnimation(.spring(response: 0.32, dampingFraction: 0.78)) {
                        viewModel.activeSettingsCategory = category
                        viewModel.settingsItemFocusIndex = 0
                    }
                }) {
                    HStack(spacing: 6) {
                        Image(systemName: category.iconName)
                            .font(.system(size: 12, weight: .semibold))
                        Text(category.title(viewModel: viewModel))
                            .font(.system(size: 11.5, weight: isSelected ? .bold : .medium, design: .rounded))
                    }
                    .foregroundColor(isSelected ? .white : NXTheme.textSecondary)
                    .padding(.horizontal, 14)
                    .padding(.vertical, 7)
                    .background(
                        Group {
                            if isSelected {
                                Capsule()
                                    .fill(NXTheme.primary.opacity(0.85))
                                    .matchedGeometryEffect(id: "category_pill", in: categoryNamespace)
                            } else {
                                Capsule()
                                    .fill(NXTheme.glassSurfaceElevated.opacity(0.40))
                            }
                        }
                    )
                    .overlay(
                        Capsule()
                            .strokeBorder(isSelected ? Color.white.opacity(0.25) : NXTheme.borderSubtle, lineWidth: 0.8)
                    )
                }
                .buttonStyle(PlainButtonStyle())
                .nxNoFocusRing()
            }
            Spacer()
        }
        .padding(.vertical, 2)
    }
    
    // MARK: - Category Content View
    private func isCardFocused(_ index: Int) -> Bool {
        viewModel.focusZone == .content &&
        !viewModel.isAnyModalPresented &&
        viewModel.systemHeaderFocusIndex < 0 &&
        viewModel.settingsItemFocusIndex == index
    }

    @ViewBuilder
    private var categoryContentView: some View {
        switch viewModel.activeSettingsCategory {
        case .general:
            SystemDirectoriesCard(viewModel: viewModel)
                .nxConsoleFocusRing(in: RoundedRectangle(cornerRadius: 16, style: .continuous), isFocused: isCardFocused(0))
        case .updates:
            SystemUpdatesCard(viewModel: viewModel)
                .nxConsoleFocusRing(in: RoundedRectangle(cornerRadius: 16, style: .continuous), isFocused: isCardFocused(0))
        case .toolchain:
            VStack(spacing: 14) {
                SystemKeysCard(viewModel: viewModel)
                    .nxConsoleFocusRing(in: RoundedRectangle(cornerRadius: 16, style: .continuous), isFocused: isCardFocused(0) && !viewModel.isInsideSystemCard)
                
                SystemToolsCard(viewModel: viewModel)
                    .nxConsoleFocusRing(in: RoundedRectangle(cornerRadius: 16, style: .continuous), isFocused: isCardFocused(1))
            }
        case .developer:
            if viewModel.isDeveloperMode {
                VStack(spacing: 14) {
                    SystemRepoCard(viewModel: viewModel)
                        .nxConsoleFocusRing(in: RoundedRectangle(cornerRadius: 16, style: .continuous), isFocused: isCardFocused(0))
                    
                    SystemStorageAndDiagnosticsCard(viewModel: viewModel)
                        .nxConsoleFocusRing(in: RoundedRectangle(cornerRadius: 16, style: .continuous), isFocused: isCardFocused(1))
                }
            } else {
                SystemDirectoriesCard(viewModel: viewModel)
            }
        }
    }
}
