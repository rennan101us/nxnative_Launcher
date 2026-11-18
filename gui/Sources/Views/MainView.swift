import SwiftUI

public struct MainView: View {
    @ObservedObject public var viewModel: AppViewModel
    @ObservedObject private var menuBarManager = MenuBarManager.shared
    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency
    @State private var windowWidth: CGFloat = 1180
    @State private var windowHeight: CGFloat = 760
    @State internal var animatedTabPill: Int = 0
    @State private var isWindowDropTargeted: Bool = false
    @Namespace internal var navTabNamespace
    
    public init(viewModel: AppViewModel) {
        self.viewModel = viewModel
    }
    
    internal var tabs: [(tag: Int, title: String, icon: String)] {
        var items: [(tag: Int, title: String, icon: String)] = [
            (0, viewModel.tr("nav.my_games"), "gamecontroller.fill"),
            (1, viewModel.tr("nav.compatibility"), "books.vertical.fill"),
            (2, viewModel.tr("nav.controls"), "arcade.stick.console.fill"),
            (3, viewModel.tr("nav.personalize"), "paintpalette.fill"),
            (4, viewModel.tr("nav.settings"), "gearshape.fill")
        ]
        if viewModel.isDeveloperMode {
            items.append((5, viewModel.tr("nav.console"), "terminal.fill"))
        }
        return items
    }
    
    internal var isCompactNav: Bool {
        windowWidth < 1100
    }
    
    internal var useFloatingGlassBars: Bool {
        if #available(macOS 26.0, *) {
            return viewModel.isLiquidGlassEnabled && !reduceTransparency
        }
        return false
    }
    
    public var body: some View {
        Group {
            if menuBarManager.isMinimizedToMenuBar {
                Color.clear
                    .frame(width: 1, height: 1)
            } else {
                GeometryReader { windowGeo in
                    let currentSize = windowGeo.size

                    ZStack {
                        NXWindowGlassBackground(viewModel: viewModel)
                            .ignoresSafeArea()

                        if viewModel.selectedTab == 0 && !viewModel.isShowingOnboarding {
                            let heroTarget = viewModel.currentHeroTarget
                            ConsoleHeroBackgroundView(
                                game: heroTarget.ported,
                                unportedGame: heroTarget.unported,
                                viewModel: viewModel
                            )
                            .ignoresSafeArea()
                            .transition(.opacity)
                        } else {
                            atmosphericGlows(in: currentSize)
                        }

                        if viewModel.isShowingOnboarding {
                            VStack(spacing: 0) {
                                OnboardingFlowView(viewModel: viewModel)
                                    .frame(maxWidth: .infinity, maxHeight: .infinity)

                                ControllerPromptBar(viewModel: viewModel)
                                    .frame(maxWidth: .infinity)
                                    .zIndex(10)
                            }
                            .frame(maxWidth: .infinity, maxHeight: .infinity)
                            .transition(.opacity)
                        } else {
                            VStack(spacing: 0) {
                                HStack(spacing: 0) {
                                    leftNavigationRail
                                        .padding(.leading, 14)
                                        .padding(.trailing, 10)
                                        .padding(.top, 42)
                                        .zIndex(20)

                                    ZStack(alignment: .topLeading) {
                                        selectedTabContent(containerHeight: max(560, currentSize.height - 48))
                                            .padding(.top, viewModel.selectedTab == 0 ? 0 : 54)
                                            .frame(maxWidth: .infinity, maxHeight: .infinity)
                                            .clipped()

                                        navigationHeader
                                            .frame(maxWidth: .infinity)
                                            .zIndex(10)
                                    }
                                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                                }
                                .frame(maxWidth: .infinity, maxHeight: .infinity)

                                ControllerPromptBar(viewModel: viewModel)
                                    .frame(maxWidth: .infinity)
                                    .zIndex(10)
                            }
                            .frame(maxWidth: .infinity, maxHeight: .infinity)
                            .id(viewModel.launcherLanguage)

                            BuildErrorBannerView(viewModel: viewModel)
                                .zIndex(100)
                            
                            NXConfirmationOverlayView(viewModel: viewModel)
                                .zIndex(110)
                            
                            ShaderPrebuildHUDView(viewModel: viewModel)
                                .zIndex(120)
                        }

                        if isWindowDropTargeted && !viewModel.isShowingOnboarding {
                            ZStack {
                                Color.black.opacity(0.40)
                                    .ignoresSafeArea()
                                
                                VStack(spacing: 12) {
                                    Image(systemName: "arrow.down.doc.fill")
                                        .font(.system(size: 44, weight: .bold))
                                        .foregroundColor(NXTheme.primary)
                                    Text(viewModel.tr("library.empty_drop_title"))
                                        .font(.system(size: 18, weight: .bold, design: .rounded))
                                        .foregroundColor(NXTheme.textPrimary)
                                    Text("NSP, NSZ, NZS, XCI, XCZ, NUP, APP")
                                        .font(.system(size: 11, weight: .bold, design: .monospaced))
                                        .foregroundColor(NXTheme.secondary)
                                }
                                .padding(32)
                                .nxGlassCard(cornerRadius: 20)
                                .overlay(
                                    RoundedRectangle(cornerRadius: 20, style: .continuous)
                                        .strokeBorder(NXTheme.secondary, style: StrokeStyle(lineWidth: 2, dash: [8]))
                                )
                            }
                            .allowsHitTesting(false)
                            .transition(.opacity)
                            .zIndex(150)
                        }
                    }
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .onDrop(
                        of: AppViewModel.acceptedDropTypes,
                        isTargeted: Binding(
                            get: { isWindowDropTargeted && !viewModel.isShowingOnboarding },
                            set: { isWindowDropTargeted = viewModel.isShowingOnboarding ? false : $0 }
                        )
                    ) { providers in
                        guard !viewModel.isShowingOnboarding else { return false }
                        AppViewModel.extractURLs(from: providers) { urls in
                            if !urls.isEmpty {
                                SoundEffectService.shared.play(.click)
                                viewModel.handleDroppedURLs(urls, openPortModalForSingleGame: viewModel.selectedTab != 0)
                            }
                        }
                        return true
                    }
                    .onAppear {
                        self.windowWidth = currentSize.width
                        self.windowHeight = currentSize.height
                        self.animatedTabPill = viewModel.selectedTab
                    }
                    .onChange(of: currentSize.width) { newW in
                        self.windowWidth = newW
                    }
                    .onChange(of: currentSize.height) { newH in
                        self.windowHeight = newH
                    }
                    .onChange(of: viewModel.selectedTab) { newTab in
                        withAnimation(.spring(response: 0.34, dampingFraction: 0.76, blendDuration: 0.10)) {
                            self.animatedTabPill = newTab
                        }
                    }
                }
            }
        }
        .frame(minWidth: 880, idealWidth: 1280, maxWidth: .infinity, minHeight: 620, idealHeight: 800, maxHeight: .infinity)
        .environment(\.nxLiquidGlass, viewModel.liquidGlassEnvironment)
        .preferredColorScheme(.dark)
        .background(
            KeyboardNavBridge(viewModel: viewModel) { key in
                viewModel.handleKeyboardKey(key)
            }
        )
        .sheet(isPresented: $viewModel.showAboutSheet) {
            AboutLauncherView(viewModel: viewModel)
                .id(viewModel.launcherLanguage)
                .environment(\.nxLiquidGlass, viewModel.liquidGlassEnvironment)
        }
        .sheet(isPresented: $viewModel.showUpdateSheet) {
            LauncherUpdateSheet(viewModel: viewModel)
                .id(viewModel.launcherLanguage)
                .environment(\.nxLiquidGlass, viewModel.liquidGlassEnvironment)
        }
        .sheet(isPresented: $viewModel.showControlsGuideSheet) {
            UniversalControlsGuideView(viewModel: viewModel)
                .id(viewModel.launcherLanguage)
                .environment(\.nxLiquidGlass, viewModel.liquidGlassEnvironment)
        }
        .sheet(isPresented: $viewModel.showNxDeploymentBatchModal) {
            NxDeploymentBatchModalView(viewModel: viewModel)
                .id(viewModel.launcherLanguage)
                .environment(\.nxLiquidGlass, viewModel.liquidGlassEnvironment)
        }
        .sheet(isPresented: $viewModel.showInstallerSheet) {
            InstallerSheetView(viewModel: viewModel)
                .id(viewModel.launcherLanguage)
                .environment(\.nxLiquidGlass, viewModel.liquidGlassEnvironment)
        }
        .onChange(of: viewModel.selectedTab) { _ in
            DispatchQueue.main.async {
                NSApp.keyWindow?.makeFirstResponder(nil)
            }
        }
        .onAppear {
            DispatchQueue.main.async {
                NSApp.keyWindow?.makeFirstResponder(nil)
            }
        }
    }
    
    @ViewBuilder
    private func atmosphericGlows(in size: CGSize) -> some View {
        let env = viewModel.liquidGlassEnvironment
        let primaryOpacity: Double = {
            if !viewModel.isLiquidGlassEnabled { return 0.14 }
            return env.mix(frosted: 0.17, liquid: 0.26)
        }()
        let secondaryOpacity: Double = {
            if !viewModel.isLiquidGlassEnabled { return 0.06 }
            return env.mix(frosted: 0.09, liquid: 0.16)
        }()
        let tertiaryOpacity: Double = {
            if !viewModel.isLiquidGlassEnabled { return 0.07 }
            return env.mix(frosted: 0.07, liquid: 0.12)
        }()
        
        ZStack {
            RadialGradient(
                gradient: Gradient(colors: [
                    NXTheme.primary.opacity(primaryOpacity),
                    NXTheme.primary.opacity(primaryOpacity * 0.35),
                    Color.clear
                ]),
                center: .center,
                startRadius: 10,
                endRadius: 340
            )
            .frame(width: 680, height: 680)
            .position(x: 120, y: 50)
            
            RadialGradient(
                gradient: Gradient(colors: [
                    NXTheme.secondary.opacity(secondaryOpacity),
                    NXTheme.secondary.opacity(secondaryOpacity * 0.35),
                    Color.clear
                ]),
                center: .center,
                startRadius: 10,
                endRadius: 320
            )
            .frame(width: 640, height: 640)
            .position(x: size.width * 0.52, y: 90)
            
            RadialGradient(
                gradient: Gradient(colors: [
                    NXTheme.tertiary.opacity(tertiaryOpacity),
                    NXTheme.tertiary.opacity(tertiaryOpacity * 0.35),
                    Color.clear
                ]),
                center: .center,
                startRadius: 10,
                endRadius: 320
            )
            .frame(width: 640, height: 640)
            .position(x: size.width - 80, y: size.height - 60)
        }
        .animation(.easeInOut(duration: 0.35), value: viewModel.highlightTheme)
        .animation(.easeInOut(duration: 0.30), value: viewModel.isLiquidGlassEnabled)
        .allowsHitTesting(false)
        .ignoresSafeArea()
    }
    
    @ViewBuilder
    private func selectedTabContent(containerHeight: CGFloat) -> some View {
        let libraryContainerHeight = containerHeight
        switch viewModel.selectedTab {
        case 0:
            LibraryView(viewModel: viewModel, containerHeight: libraryContainerHeight)
        case 1:
            CompatibilityView(viewModel: viewModel)
        case 2:
            ControlsView(viewModel: viewModel)
        case 3:
            PersonalizationView(viewModel: viewModel)
        case 4:
            SystemView(viewModel: viewModel)
        case 5:
            if viewModel.isDeveloperMode {
                LogsView(viewModel: viewModel)
            } else {
                LibraryView(viewModel: viewModel, containerHeight: libraryContainerHeight)
            }
        default:
            LibraryView(viewModel: viewModel, containerHeight: libraryContainerHeight)
        }
    }
}
