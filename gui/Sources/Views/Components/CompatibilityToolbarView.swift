import SwiftUI
import AppKit

public struct CompatibilityToolbarView: View {
    @ObservedObject public var viewModel: AppViewModel
    @Namespace private var displayModeNamespace
    
    public init(viewModel: AppViewModel) {
        self.viewModel = viewModel
    }
    
    public var body: some View {
        NXGlassContainer(spacing: 10) {
            HStack(spacing: 12) {
                // Aligned to the left: Title "Compatibility" + New + All + RAM
                titleSection
                
                Rectangle()
                    .fill(Color.white.opacity(0.12))
                    .frame(width: 1, height: 16)
                
                filtersSection
                
                Spacer(minLength: 16)
                
                // Aligned on the right at the end of the container: Grid / List toggle + Cloud Sources + Refresh button
                HStack(spacing: 8) {
                    displayModeToggle
                    cloudSourcesIconButton
                    refreshIconButton
                }
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 7)
        }
    }
    
    // MARK: - Title Section
    private var titleSection: some View {
        let totalCount = viewModel.compatibleGames.count
        let filteredCount = viewModel.currentFilteredCompatibleGames().count
        let countText = filteredCount == totalCount ? "\(totalCount)" : "\(filteredCount)/\(totalCount)"

        return HStack(spacing: 8) {
            Text(viewModel.tr("nav.compatibility"))
                .font(.system(size: 15, weight: .bold, design: .rounded))
                .foregroundColor(NXTheme.textPrimary)
                .lineLimit(1)
                .minimumScaleFactor(0.85)
            
            Text(countText)
                .font(.system(size: 10, weight: .bold, design: .monospaced))
                .padding(.horizontal, 7)
                .padding(.vertical, 2)
                .background(NXTheme.primary.opacity(0.24))
                .foregroundColor(.white)
                .clipShape(Capsule())
                .overlay(
                    Capsule()
                        .strokeBorder(NXTheme.secondary.opacity(0.35), lineWidth: 0.7)
                )
        }
        .fixedSize(horizontal: true, vertical: false)
    }
    
    private var toolbarFocused: Bool {
        viewModel.focusZone == .content && viewModel.compatibilityFocusArea == .filters && !viewModel.isAnyModalPresented
    }

    // MARK: - Filters: New, All, Platform, RAM, Cloud
    private var filtersSection: some View {
        HStack(spacing: 6) {
            newFilterButton
            allGenerationDropdownMenu
            platformDropdownMenu
            ramDropdownMenu
            if !viewModel.cloudAvailableGames.isEmpty {
                cloudAvailableFilterButton
            }
        }
        .fixedSize(horizontal: true, vertical: false)
    }
    
    // MARK: - New Filter
    private var newFilterButton: some View {
        let isSelected = viewModel.compatibilityNameFilter == "New"
        let isFocused = toolbarFocused && viewModel.compatibilityToolbarFocusIndex == 0
        return Button(action: {
            SoundEffectService.shared.play(.click)
            withAnimation(.spring(response: 0.32, dampingFraction: 0.76)) {
                viewModel.compatibilityFocusArea = .filters
                viewModel.compatibilityToolbarFocusIndex = 0
                viewModel.compatibilityNameFilter = isSelected ? "All" : "New"
            }
        }) {
            HStack(spacing: 4) {
                Image(systemName: "sparkles")
                    .font(.system(size: 9, weight: .bold))
                    .foregroundColor(isSelected ? NXTheme.primary : NXTheme.secondary)
                Text(viewModel.tr("compatibility.new"))
                    .font(.system(size: 11, weight: isSelected ? .bold : .semibold, design: .rounded))
                    .foregroundColor(isSelected ? NXTheme.primary : .white)
            }
            .padding(.horizontal, 9)
            .padding(.vertical, 4)
            .nxGlassBar(
                in: Capsule(),
                fallbackFill: isSelected ? NXTheme.primary.opacity(0.24) : NXTheme.glassSurfaceElevated.opacity(0.65),
                fallbackStroke: isSelected ? NXTheme.primary.opacity(0.50) : NXTheme.borderSubtle
            )
            .nxGlassInteractive(
                in: Capsule(),
                tint: isSelected ? NXTheme.primary.opacity(0.35) : nil
            )
        }
        .buttonStyle(NXPressableButtonStyle())
        .nxNoFocusRing()
        .nxConsoleFocusRing(in: Capsule(), isFocused: isFocused)
        .help(viewModel.tr("hover.filter_new_verified"))
    }
    
    // MARK: - All Generation Dropdown Menu
    private var allGenerationDropdownMenu: some View {
        let gen = viewModel.compatibilityGenerationFilter
        let isFiltered = gen != .all
        let displayText: String = {
            switch gen {
            case .all: return viewModel.tr("compatibility.all")
            case .switch1: return "Switch 1"
            case .switch2: return "Switch 2"
            }
        }()
        
        return Menu {
            Button(action: {
                SoundEffectService.shared.play(.click)
                withAnimation(.spring(response: 0.32, dampingFraction: 0.76)) {
                    viewModel.compatibilityFocusArea = .filters
                    viewModel.compatibilityNameFilter = "All"
                    viewModel.compatibilityGenerationFilter = .all
                }
            }) {
                HStack {
                    Text(viewModel.tr("compatibility.switch_all"))
                    if gen == .all { Image(systemName: "checkmark") }
                }
            }
            Button(action: {
                SoundEffectService.shared.play(.click)
                withAnimation(.spring(response: 0.32, dampingFraction: 0.76)) {
                    viewModel.compatibilityFocusArea = .filters
                    viewModel.compatibilityNameFilter = "All"
                    viewModel.compatibilityGenerationFilter = .switch1
                }
            }) {
                HStack {
                    Text(viewModel.tr("compatibility.switch1"))
                    if gen == .switch1 { Image(systemName: "checkmark") }
                }
            }
            Button(action: {
                SoundEffectService.shared.play(.click)
                withAnimation(.spring(response: 0.32, dampingFraction: 0.76)) {
                    viewModel.compatibilityFocusArea = .filters
                    viewModel.compatibilityNameFilter = "All"
                    viewModel.compatibilityGenerationFilter = .switch2
                }
            }) {
                HStack {
                    Text(viewModel.tr("compatibility.switch2"))
                    if gen == .switch2 { Image(systemName: "checkmark") }
                }
            }
        } label: {
            HStack(spacing: 4) {
                Text(displayText)
                    .font(.system(size: 11, weight: isFiltered ? .bold : .semibold, design: .rounded))
                    .foregroundColor(isFiltered ? NXTheme.primary : .white)
                Image(systemName: "chevron.down")
                    .font(.system(size: 7, weight: .bold))
                    .foregroundColor(isFiltered ? NXTheme.primary.opacity(0.85) : .white.opacity(0.65))
            }
            .padding(.horizontal, 9)
            .padding(.vertical, 4)
            .nxGlassBar(
                in: Capsule(),
                fallbackFill: isFiltered ? NXTheme.primary.opacity(0.24) : NXTheme.glassSurfaceElevated.opacity(0.65),
                fallbackStroke: isFiltered ? NXTheme.primary.opacity(0.50) : NXTheme.borderSubtle
            )
            .nxGlassInteractive(
                in: Capsule(),
                tint: isFiltered ? NXTheme.primary.opacity(0.35) : nil
            )
        }
        .menuStyle(.borderlessButton)
        .menuIndicator(.hidden)
        .fixedSize()
        .nxNoFocusRing()
        .nxConsoleFocusRing(in: Capsule(), isFocused: toolbarFocused && viewModel.compatibilityToolbarFocusIndex == 1)
        .help(viewModel.tr("hover.filter_switch_gen"))
    }
    
    // MARK: - Platform Dropdown (macOS, iOS, iPadOS, Android)
    private var platformDropdownMenu: some View {
        let selected = viewModel.compatibilityPlatformFilter
        let isFiltered = selected != .all
        let displayText: String = isFiltered ? selected.rawValue : viewModel.tr("compatibility.platform_filter")

        return Menu {
            Button {
                SoundEffectService.shared.play(.click)
                withAnimation(.spring(response: 0.34, dampingFraction: 0.76)) {
                    viewModel.compatibilityFocusArea = .filters
                    viewModel.compatibilityToolbarFocusIndex = 2
                    viewModel.compatibilityPlatformFilter = .all
                    viewModel.focusedCompatibilityIndex = 0
                }
            } label: {
                HStack {
                    Text("\(viewModel.tr("compatibility.all")) (\(viewModel.compatibleGames.count))")
                    if selected == .all {
                        Image(systemName: "checkmark")
                    }
                }
            }

            Divider()

            ForEach([CompatibilityPlatformFilter.macOS, .iOS, .iPadOS, .android]) { platform in
                let count = viewModel.compatibleGames.filter { $0.supports(platform) }.count
                Button {
                    SoundEffectService.shared.play(.click)
                    withAnimation(.spring(response: 0.34, dampingFraction: 0.76)) {
                        viewModel.compatibilityFocusArea = .filters
                        viewModel.compatibilityToolbarFocusIndex = 2
                        viewModel.compatibilityPlatformFilter = platform
                        viewModel.focusedCompatibilityIndex = 0
                    }
                } label: {
                    HStack {
                        Image(systemName: platform.iconName)
                        Text("\(platform.rawValue) (\(count))")
                        if selected == platform {
                            Image(systemName: "checkmark")
                        }
                    }
                }
            }
        } label: {
            HStack(spacing: 4) {
                Image(systemName: isFiltered ? selected.iconName : "desktopcomputer")
                    .font(.system(size: 10, weight: .semibold))
                    .foregroundColor(isFiltered ? NXTheme.primary : NXTheme.secondary)
                Text(displayText)
                    .font(.system(size: 11, weight: isFiltered ? .bold : .semibold, design: .rounded))
                    .foregroundColor(isFiltered ? NXTheme.primary : .white)
                Image(systemName: "chevron.down")
                    .font(.system(size: 7, weight: .bold))
                    .foregroundColor(isFiltered ? NXTheme.primary.opacity(0.85) : .white.opacity(0.65))
            }
            .padding(.horizontal, 9)
            .padding(.vertical, 4)
            .nxGlassBar(
                in: Capsule(),
                fallbackFill: isFiltered ? NXTheme.primary.opacity(0.24) : NXTheme.glassSurfaceElevated.opacity(0.65),
                fallbackStroke: isFiltered ? NXTheme.primary.opacity(0.50) : NXTheme.borderSubtle
            )
            .nxGlassInteractive(
                in: Capsule(),
                tint: isFiltered ? NXTheme.primary.opacity(0.35) : nil
            )
        }
        .menuStyle(.borderlessButton)
        .menuIndicator(.hidden)
        .fixedSize()
        .nxNoFocusRing()
        .nxConsoleFocusRing(in: Capsule(), isFocused: toolbarFocused && viewModel.compatibilityToolbarFocusIndex == 2)
        .help(viewModel.tr("hover.filter_platform"))
    }

    // MARK: - RAM Dropdown
    private var ramDropdownMenu: some View {
        let isFiltered = viewModel.compatibilityRamFilter != nil
        let displayText: String = {
            if let ram = viewModel.compatibilityRamFilter {
                return "\(ram)GB RAM"
            } else {
                return "RAM"
            }
        }()
        
        return Menu {
            Button {
                SoundEffectService.shared.play(.click)
                withAnimation(.spring(response: 0.34, dampingFraction: 0.76)) {
                    viewModel.compatibilityFocusArea = .filters
                    viewModel.compatibilityRamFilter = nil
                }
            } label: {
                HStack {
                    Text("\(viewModel.tr("compatibility.all")) (\(viewModel.compatibleGames.count))")
                    if viewModel.compatibilityRamFilter == nil {
                        Image(systemName: "checkmark")
                    }
                }
            }
            
            Divider()
            
            ForEach([4, 6, 8, 16], id: \.self) { ram in
                let count = viewModel.compatibleGames.filter { $0.minRamGB <= ram }.count
                Button {
                    SoundEffectService.shared.play(.click)
                    withAnimation(.spring(response: 0.34, dampingFraction: 0.76)) {
                        viewModel.compatibilityFocusArea = .filters
                        viewModel.compatibilityRamFilter = ram
                    }
                } label: {
                    HStack {
                        Text("\(ram)GB RAM (\(count))")
                        if viewModel.compatibilityRamFilter == ram {
                            Image(systemName: "checkmark")
                        }
                    }
                }
            }
        } label: {
            HStack(spacing: 4) {
                Image(systemName: "memorychip")
                    .font(.system(size: 10, weight: .semibold))
                    .foregroundColor(isFiltered ? NXTheme.primary : NXTheme.secondary)
                Text(displayText)
                    .font(.system(size: 11, weight: isFiltered ? .bold : .semibold, design: .rounded))
                    .foregroundColor(isFiltered ? NXTheme.primary : .white)
                Image(systemName: "chevron.down")
                    .font(.system(size: 7, weight: .bold))
                    .foregroundColor(isFiltered ? NXTheme.primary.opacity(0.85) : .white.opacity(0.65))
            }
            .padding(.horizontal, 9)
            .padding(.vertical, 4)
            .nxGlassBar(
                in: Capsule(),
                fallbackFill: isFiltered ? NXTheme.primary.opacity(0.24) : NXTheme.glassSurfaceElevated.opacity(0.65),
                fallbackStroke: isFiltered ? NXTheme.primary.opacity(0.50) : NXTheme.borderSubtle
            )
            .nxGlassInteractive(
                in: Capsule(),
                tint: isFiltered ? NXTheme.primary.opacity(0.35) : nil
            )
        }
        .menuStyle(.borderlessButton)
        .menuIndicator(.hidden)
        .fixedSize()
        .nxNoFocusRing()
        .nxConsoleFocusRing(in: Capsule(), isFocused: toolbarFocused && viewModel.compatibilityToolbarFocusIndex == 3)
        .help(viewModel.compatibilityRamFilter == nil ? viewModel.tr("hover.filter_min_ram") : viewModel.tr("hover.filtered_ram_limit", viewModel.compatibilityRamFilter!))
    }

    // MARK: - Display Mode Toggle
    private var displayModeToggle: some View {
        NXGlassContainer(spacing: 4) {
            HStack(spacing: 3) {
                modeToggleButton(
                    mode: .list,
                    icon: "list.bullet",
                    helpText: L10n.t("compatibility.list_view")
                )
                modeToggleButton(
                    mode: .grid,
                    icon: "square.grid.2x2",
                    helpText: L10n.t("compatibility.grid_view")
                )
            }
            .background {
                NXLiquidSlidingPill(in: RoundedRectangle(cornerRadius: 7, style: .continuous))
                    .matchedGeometryEffect(
                        id: viewModel.compatibilityDisplayMode,
                        in: displayModeNamespace,
                        properties: .frame,
                        anchor: .center,
                        isSource: false
                    )
                    .animation(.spring(response: 0.32, dampingFraction: 0.76), value: viewModel.compatibilityDisplayMode)
            }
            .padding(2)
            .nxGlassCard(cornerRadius: 9, isNested: true)
            .nxConsoleFocusRing(in: RoundedRectangle(cornerRadius: 9, style: .continuous), isFocused: toolbarFocused && viewModel.compatibilityToolbarFocusIndex == 4)
        }
    }
    
    private func modeToggleButton(mode: CompatibilityDisplayMode, icon: String, helpText: String) -> some View {
        let isSelected = viewModel.compatibilityDisplayMode == mode
        return Button(action: {
            guard viewModel.compatibilityDisplayMode != mode else { return }
            SoundEffectService.shared.play(.click)
            withAnimation(.spring(response: 0.32, dampingFraction: 0.76)) {
                viewModel.compatibilityDisplayMode = mode
            }
        }) {
            Image(systemName: icon)
                .font(.system(size: 11, weight: isSelected ? .bold : .semibold))
                .foregroundColor(.white)
                .padding(.horizontal, 8)
                .padding(.vertical, 4.5)
                .contentShape(RoundedRectangle(cornerRadius: 7, style: .continuous))
        }
        .buttonStyle(NXPressableButtonStyle())
        .help(helpText)
        .nxNoFocusRing()
        .matchedGeometryEffect(id: mode, in: displayModeNamespace, isSource: true)
    }
    
    // MARK: - Cloud Sources Icon Button
    private var cloudSourcesIconButton: some View {
        Button(action: {
            SoundEffectService.shared.play(.click)
            viewModel.showCloudSourcesSheet = true
        }) {
            ZStack {
                if viewModel.isSyncingCloudSources {
                    ProgressView().controlSize(.small)
                } else {
                    Image(systemName: "icloud.and.arrow.down.fill")
                        .font(.system(size: 11, weight: .bold))
                        .foregroundColor(viewModel.cloudSources.isEmpty ? .white.opacity(0.85) : NXTheme.primary)
                }
            }
            .frame(width: 26, height: 26)
            .contentShape(Circle())
            .nxGlassBar(
                in: Circle(),
                fallbackFill: viewModel.cloudSources.isEmpty ? NXTheme.glassSurfaceElevated.opacity(0.65) : NXTheme.primary.opacity(0.24),
                fallbackStroke: viewModel.cloudSources.isEmpty ? NXTheme.borderSubtle : NXTheme.primary.opacity(0.45)
            )
            .nxGlassInteractive(in: Circle())
        }
        .buttonStyle(NXPressableButtonStyle())
        .help("Links dos seus jogos na Nuvem")
        .nxNoFocusRing()
    }

    // MARK: - Cloud Available Filter Button
    private var cloudAvailableFilterButton: some View {
        let isSelected = viewModel.filterOnlyAvailableInCloud
        return Button(action: {
            SoundEffectService.shared.play(.click)
            withAnimation(.spring(response: 0.32, dampingFraction: 0.76)) {
                viewModel.filterOnlyAvailableInCloud.toggle()
            }
        }) {
            HStack(spacing: 4) {
                Image(systemName: "arrow.down.circle.fill")
                    .font(.system(size: 9, weight: .bold))
                    .foregroundColor(isSelected ? NXTheme.primary : NXTheme.secondary)
                Text("Disponíveis na Nuvem (\(viewModel.cloudAvailableGames.count))")
                    .font(.system(size: 11, weight: isSelected ? .bold : .semibold, design: .rounded))
                    .foregroundColor(isSelected ? NXTheme.primary : .white)
            }
            .padding(.horizontal, 9)
            .padding(.vertical, 4)
            .nxGlassBar(
                in: Capsule(),
                fallbackFill: isSelected ? NXTheme.primary.opacity(0.24) : NXTheme.glassSurfaceElevated.opacity(0.65),
                fallbackStroke: isSelected ? NXTheme.primary.opacity(0.50) : NXTheme.borderSubtle
            )
            .nxGlassInteractive(
                in: Capsule(),
                tint: isSelected ? NXTheme.primary.opacity(0.35) : nil
            )
        }
        .buttonStyle(NXPressableButtonStyle())
        .nxNoFocusRing()
        .help("Exibir apenas jogos compatíveis encontrados nas suas fontes da nuvem")
    }

    // MARK: - Refresh Button (Icon Only)
    private var refreshIconButton: some View {
        Button(action: {
            SoundEffectService.shared.play(.click)
            viewModel.loadCompatibleGames(forceRefresh: true)
        }) {
            ZStack {
                if viewModel.isLoadingCompatibility {
                    ProgressView().controlSize(.small)
                } else {
                    Image(systemName: "arrow.clockwise")
                        .font(.system(size: 11, weight: .bold))
                        .foregroundColor(.white)
                }
            }
            .frame(width: 26, height: 26)
            .contentShape(Circle())
            .nxGlassBar(
                in: Circle(),
                fallbackFill: NXTheme.glassSurfaceElevated.opacity(0.65),
                fallbackStroke: NXTheme.borderSubtle
            )
            .nxGlassInteractive(in: Circle())
        }
        .buttonStyle(NXPressableButtonStyle())
        .help(viewModel.tr("common.refresh"))
        .nxNoFocusRing()
        .nxConsoleFocusRing(in: Circle(), isFocused: toolbarFocused && viewModel.compatibilityToolbarFocusIndex == 5)
    }
}
