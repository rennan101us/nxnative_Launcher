import SwiftUI

// MARK: - Navigation Header and Island Views for MainView
extension MainView {
    internal var navigationHeader: some View {
        NXGlassContainer(spacing: 14) {
            HStack(spacing: 12) {
                // Left: Brand Logo & Title (without pill background)
                brandIsland
                
                Spacer(minLength: 8)
                
                // Compatibility Search Field (on tab 1, same line as NxNative Launcher)
                if viewModel.selectedTab == 1 {
                    let isCompatSearchFocused = viewModel.focusZone == .topHeader && viewModel.headerFocusItem == .search
                    NXLiquidGlassSearchField(
                        viewModel.tr("compatibility.search"),
                        text: $viewModel.compatibilitySearchText,
                        externalFocus: $viewModel.isSearchFieldProgrammaticallyFocused,
                        isHighlighted: isCompatSearchFocused,
                        onClear: { SoundEffectService.shared.play(.click) }
                    )
                    .padding(.horizontal, 12)
                    .padding(.vertical, 7)
                    .frame(maxWidth: 240)
                    .nxGlassCard(cornerRadius: 16, isNested: true)
                    .nxConsoleFocusRing(in: RoundedRectangle(cornerRadius: 16, style: .continuous), isFocused: isCompatSearchFocused)
                }

                // My Games Search Field & Add Game Button (on tab 0)
                if viewModel.selectedTab == 0 {
                    let isAddFocused = viewModel.focusZone == .topHeader && viewModel.headerFocusItem == .addGame
                    let isLibSearchFocused = viewModel.focusZone == .topHeader && viewModel.headerFocusItem == .search
                    HStack(spacing: 8) {
                        AddGameHeaderButton(viewModel: viewModel, isFocused: isAddFocused)

                        NXLiquidGlassSearchField(
                            viewModel.tr("library.search_placeholder"),
                            text: $viewModel.librarySearchText,
                            externalFocus: $viewModel.isSearchFieldProgrammaticallyFocused,
                            isHighlighted: isLibSearchFocused,
                            onClear: { SoundEffectService.shared.play(.click) }
                        )
                        .padding(.horizontal, 10)
                        .padding(.vertical, 5)
                        .frame(maxWidth: 220)
                        .nxGlassBar(
                            in: Capsule(),
                            fallbackFill: NXTheme.glassSurfaceElevated.opacity(0.85),
                            fallbackStroke: NXTheme.borderSubtle
                        )
                        .nxConsoleFocusRing(in: Capsule(), isFocused: isLibSearchFocused)
                    }
                }

                // Right: Build & Provisioning Status Indicator
                if viewModel.selectedTab != 0 || viewModel.isBuilding || viewModel.shouldShowProvisioningHeaderPill {
                    statusIsland
                }
            }
            .padding(.horizontal, 34)
            .padding(.vertical, 8)
            .frame(maxWidth: .infinity)
            .frame(minHeight: 48)
            .background(
                Group {
                    if viewModel.selectedTab == 0 {
                        Color.clear
                    } else if !useFloatingGlassBars {
                        ZStack {
                            NXTheme.canvasObsidian.opacity(0.85)
                            Rectangle().fill(.ultraThinMaterial)
                        }
                    }
                }
            )
            .overlay(
                Group {
                    if viewModel.selectedTab != 0 && !useFloatingGlassBars {
                        Rectangle()
                            .frame(height: 1)
                            .foregroundColor(NXTheme.borderSubtle)
                    }
                },
                alignment: .bottom
            )
        }
    }
    
    private var brandIsland: some View {
        HStack(spacing: 10) {
            AppLogoView(viewModel: viewModel)
            
            HStack(spacing: 6) {
                Text("NxNative Launcher")
                    .font(.system(size: 14, weight: .bold, design: .rounded))
                    .foregroundColor(NXTheme.textPrimary)
                    .lineLimit(1)
            }
        }
        .padding(.leading, 0)
        .padding(.trailing, 8)
        .padding(.vertical, 3)
    }
    
    internal var leftNavigationRail: some View {
        NXGlassContainer(spacing: 6) {
            VStack(spacing: 6) {
                ForEach(tabs, id: \.tag) { item in
                    let isSelected = viewModel.selectedTab == item.tag
                    let isRailFocused = viewModel.focusZone == .leftRail && isSelected
                    Button(action: {
                        guard !viewModel.isAnyModalPresented else { return }
                        viewModel.focusZone = .content
                        guard viewModel.selectedTab != item.tag else { return }
                        SoundEffectService.shared.play(.tabSwitch)
                        viewModel.selectedTab = item.tag
                    }) {
                        ZStack {
                            Image(systemName: item.icon)
                                .font(.system(size: 15, weight: isSelected ? .bold : .semibold))
                                .foregroundColor(isSelected ? .white : .white.opacity(0.78))
                                .frame(width: 38, height: 38)
                        }
                        .contentShape(Circle())
                    }
                    .buttonStyle(NXPressableButtonStyle())
                    .disabled(viewModel.isAnyModalPresented)
                    .help(item.title)
                    .nxNoFocusRing()
                    .matchedGeometryEffect(id: item.tag, in: navTabNamespace, isSource: true)
                    .nxConsoleFocusRing(in: Circle(), isFocused: isRailFocused)
                    .scaleEffect(isRailFocused ? 1.08 : 1.0)
                    .animation(.spring(response: 0.22, dampingFraction: 0.8), value: isRailFocused)
                }
            }
            .background {
                NXLiquidSlidingPill(
                    in: Circle(),
                    tint: NXTheme.primary.opacity(viewModel.liquidGlassEnvironment.mix(frosted: 0.86, liquid: 0.72))
                )
                .matchedGeometryEffect(
                    id: animatedTabPill,
                    in: navTabNamespace,
                    properties: .frame,
                    anchor: .center,
                    isSource: false
                )
            }
            .padding(4)
            .nxGlassBar(
                in: Capsule(),
                fallbackFill: NXTheme.glassSurfaceElevated.opacity(0.75),
                fallbackStroke: NXTheme.borderSubtle
            )
        }
    }
    
    private var statusIsland: some View {
        HStack(spacing: 8) {
            if viewModel.shouldShowProvisioningHeaderPill {
                let isPillFocused = viewModel.focusZone == .topHeader && viewModel.headerFocusItem == .provisioningPill
                let needsClt = !viewModel.prerequisites.xcode.isAvailable &&
                    !viewModel.isInstallingDependency &&
                    !viewModel.isCloningRepository &&
                    !viewModel.isProvisioningBusy
                let statusText = viewModel.provisioningStatus.isEmpty
                    ? (viewModel.installerCurrentItem.map { viewModel.tr("provisioning.installing_item", $0) } ?? viewModel.tr("common.installing"))
                    : viewModel.provisioningStatus

                Button(action: {
                    SoundEffectService.shared.play(.click)
                    if needsClt {
                        viewModel.selectedTab = 4
                        viewModel.activeSettingsCategory = .toolchain
                    } else {
                        viewModel.showInstallerSheet = true
                    }
                }) {
                    HStack(spacing: 6) {
                        if needsClt {
                            Image(systemName: "wrench.and.screwdriver.fill")
                                .font(.system(size: 11, weight: .bold))
                                .foregroundColor(NXTheme.tertiary)
                        } else {
                            ProgressView()
                                .controlSize(.small)
                        }
                        Text(statusText)
                            .font(.system(size: 11, weight: .semibold, design: .rounded))
                            .foregroundColor(.white)
                            .lineLimit(1)
                    }
                    .padding(.horizontal, 10)
                    .padding(.vertical, 6)
                    .nxGlassBar(
                        in: Capsule(),
                        tint: (needsClt ? NXTheme.tertiary : NXTheme.secondary).opacity(0.32),
                        fallbackFill: NXTheme.glassSurfaceElevated.opacity(0.82),
                        fallbackStroke: (needsClt ? NXTheme.tertiary : NXTheme.secondary).opacity(0.55)
                    )
                }
                .buttonStyle(NXPressableButtonStyle())
                .help(viewModel.tr("provisioning.pill_help"))
                .nxNoFocusRing()
                .nxConsoleFocusRing(in: Capsule(), isFocused: isPillFocused)
                .nxGlassTransition(.materialize)
            }

            if viewModel.isBuilding {
                HStack(spacing: 6) {
                    ProgressView()
                        .controlSize(.small)
                    Text(viewModel.tr("status.building"))
                        .font(.system(size: 11, weight: .bold, design: .rounded))
                        .foregroundColor(.white)
                }
                .padding(.horizontal, 10)
                .padding(.vertical, 6)
                .nxGlassBar(
                    in: Capsule(),
                    tint: NXTheme.primary.opacity(0.50),
                    fallbackFill: NXTheme.primary.opacity(0.35),
                    fallbackStroke: NXTheme.secondary.opacity(0.6)
                )
                .nxGlassTransition(.materialize)
            }
        }
        .fixedSize(horizontal: true, vertical: false)
    }
}

internal struct BrandIslandCapsuleModifier: ViewModifier {
    let isEnabled: Bool
    
    func body(content: Content) -> some View {
        if isEnabled {
            content.nxGlassBar(in: Capsule())
        } else {
            content
        }
    }
}

internal struct AddGameHeaderButton: View {
    @ObservedObject var viewModel: AppViewModel
    var isFocused: Bool = false
    @State private var isHovered: Bool = false

    private var isActive: Bool { isFocused || isHovered }

    var body: some View {
        Button(action: {
            SoundEffectService.shared.play(.click)
            viewModel.openUnifiedGamePicker()
        }) {
            Image(systemName: "plus")
                .font(.system(size: 12, weight: .bold))
                .foregroundColor(isActive ? NXTheme.primary : NXTheme.textPrimary)
                .frame(width: 28, height: 28)
                .contentShape(Circle())
                .background(
                    Circle()
                        .fill(isActive ? NXTheme.primary.opacity(0.22) : NXTheme.glassSurfaceElevated.opacity(0.85))
                )
                .overlay(
                    Circle()
                        .strokeBorder(
                            isActive ? NXTheme.primary : NXTheme.borderSubtle,
                            lineWidth: isFocused ? 1.8 : 1
                        )
                )
                .nxConsoleFocusRing(in: Circle(), isFocused: isFocused)
                .animation(.easeInOut(duration: 0.18), value: isActive)
        }
        .buttonStyle(.plain)
        .nxNoFocusRing()
        .help(viewModel.tr("library.add_game_card"))
        .onHover { isHovered = $0 }
    }
}



