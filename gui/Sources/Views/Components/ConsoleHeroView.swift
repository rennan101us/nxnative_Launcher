import SwiftUI
import AppKit

// MARK: - Full Screen Cinematic Artwork Background with Black Fade Borders
public struct ConsoleHeroBackgroundView: View {
    private static let heroBlurRadius: CGFloat = 6

    public let game: PortedGame?
    public let unportedGame: SelectableGame?
    @ObservedObject public var viewModel: AppViewModel
    @ObservedObject internal var artworkStore = ArtworkStore.shared
    @Environment(\.nxLiquidGlass) internal var glassEnv

    public init(game: PortedGame? = nil, unportedGame: SelectableGame? = nil, viewModel: AppViewModel) {
        self.game = game
        self.unportedGame = (game == nil) ? unportedGame : nil
        self.viewModel = viewModel
    }

    private var heroImage: NSImage? {
        if let g = game {
            return ArtworkStore.shared.loadWidescreenHero(for: g)
        } else if let u = unportedGame {
            return ArtworkStore.shared.loadWidescreenHero(titleId: u.titleId, gameName: u.name)
        }
        return nil
    }

    private var stableId: String {
        game?.stableId ?? unportedGame?.id ?? "hero_empty"
    }

    public var body: some View {
        GeometryReader { geo in
            ZStack {
                // Base Artwork Layer with Cross-fade & Cinematic Blur
                if let img = heroImage {
                    Image(nsImage: img)
                        .resizable()
                        .aspectRatio(contentMode: .fill)
                        .frame(width: geo.size.width, height: geo.size.height)
                        .clipped()
                        .blur(radius: Self.heroBlurRadius, opaque: true)
                        .clipped()
                        .id(stableId)
                        .transition(.opacity)
                        .animation(.easeInOut(duration: 0.35), value: stableId)
                } else {
                    ZStack {
                        Color.nxCanvas
                        RadialGradient(
                            gradient: Gradient(colors: [NXTheme.primary.opacity(0.32), Color.nxCanvas.opacity(0.92)]),
                            center: .topTrailing,
                            startRadius: 50,
                            endRadius: 750
                        )
                    }
                }

                // MARK: - Borders Fade In Black (Consolidated Vertical & Horizontal Edge Vignettes)
                LinearGradient(
                    stops: [
                        .init(color: Color.black.opacity(0.85), location: 0.0),
                        .init(color: Color.black.opacity(0.40), location: 0.16),
                        .init(color: Color.clear, location: 0.35),
                        .init(color: Color.black.opacity(0.45), location: 0.60),
                        .init(color: Color.black.opacity(0.85), location: 0.82),
                        .init(color: Color.black.opacity(0.96), location: 1.0)
                    ],
                    startPoint: .top,
                    endPoint: .bottom
                )

                LinearGradient(
                    stops: [
                        .init(color: Color.black.opacity(0.82), location: 0.0),
                        .init(color: Color.black.opacity(0.45), location: 0.30),
                        .init(color: Color.clear, location: 0.65),
                        .init(color: Color.clear, location: 0.72),
                        .init(color: Color.black.opacity(0.60), location: 1.0)
                    ],
                    startPoint: .leading,
                    endPoint: .trailing
                )
            }
            .frame(width: geo.size.width, height: geo.size.height)
            .clipped()
        }
        .allowsHitTesting(false)
    }
}

// MARK: - Game Detail View (Revealed when user clicks on a game card)
public struct ConsoleGameDetailView: View {
    public let game: PortedGame?
    public let unportedGame: SelectableGame?
    @ObservedObject public var viewModel: AppViewModel
    @ObservedObject internal var deviceService = DeviceDeploymentService.shared
    @ObservedObject internal var deploymentTracker = IosDeploymentTracker.shared
    @ObservedObject internal var playTimeService = PlayTimeService.shared
    @Environment(\.nxLiquidGlass) internal var glassEnv

    public init(game: PortedGame? = nil, unportedGame: SelectableGame? = nil, viewModel: AppViewModel) {
        self.game = game
        self.unportedGame = (game == nil) ? unportedGame : nil
        self.viewModel = viewModel
    }

    private var config: GameRuntimeConfig {
        if let g = game {
            return viewModel.loadRuntimeConfig(for: g)
        }
        return GameRuntimeConfig()
    }

    private var isLaunching: Bool {
        guard let g = game else { return false }
        return viewModel.launchingGameId == g.id
    }

    private var isUnportedBuilding: Bool {
        guard let u = unportedGame else { return false }
        return viewModel.isBuilding && (viewModel.buildingGameId == u.id || viewModel.selectedGame?.id == u.id)
    }

    public var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            // Game Title (Large Heavy Typography with Ambient Shadow)
            Text(game?.name ?? unportedGame?.name ?? "")
                .font(.system(size: 30, weight: .heavy, design: .rounded))
                .foregroundColor(.white)
                .lineLimit(1)
                .minimumScaleFactor(0.70)
                .shadow(color: Color.black.opacity(0.90), radius: 10, x: 0, y: 3)

            // MARK: - PS5-Style Metadata Statistics Columns (Played For | Storage | Platform | Performance)
            HStack(spacing: 22) {
                // Column 1: Played For / Play Time
                let _ = playTimeService.refreshId
                metadataStatColumn(
                    label: "PLAYED FOR",
                    value: game != nil ? playTimeService.formattedPlayTime(for: game!) : "New",
                    icon: "clock.fill"
                )

                // Column 2: Storage Size
                let storageTitle: String = {
                    if let g = game {
                        let mac = viewModel.macPort(for: g)
                        let ios = viewModel.iosPort(for: g)
                        if let mac = mac, let ios = ios, mac.url != ios.url, mac.sizeBytes > 0 || ios.sizeBytes > 0 {
                            let macStr = mac.sizeBytes > 0 ? mac.formattedSize : "—"
                            let iosStr = ios.sizeBytes > 0 ? ios.formattedSize : "—"
                            return "Mac: \(macStr) · iOS: \(iosStr)"
                        } else if let mac = mac, mac.sizeBytes > 0 {
                            return mac.formattedSize
                        } else if let ios = ios, ios.sizeBytes > 0 {
                            return "iOS: \(ios.formattedSize)"
                        } else if g.sizeBytes > 0 {
                            return g.formattedSize
                        }
                    } else if let u = unportedGame, u.totalSizeBytes > 0 {
                        return u.formattedSize
                    }
                    return "—"
                }()
                metadataStatColumn(
                    label: viewModel.tr("hero.storage"),
                    value: storageTitle,
                    icon: "internaldrive.fill"
                )

                // Column 3: Platform / Generation
                let platformTitle: String = {
                    if let g = game {
                        if g.platform == .macApp {
                            return g.isSwitch2 ? "Nintendo Switch 2" : "Nintendo Switch"
                        } else if g.platform == .nonSwitch {
                            return "Mac Native"
                        } else {
                            return g.isSwitch2 ? "iOS (Switch 2)" : "iOS & iPadOS IPA"
                        }
                    } else if let u = unportedGame {
                        return u.isSwitch2 ? "Nintendo Switch 2" : "Nintendo Switch"
                    }
                    return "Switch"
                }()
                metadataStatColumn(
                    label: "PLATFORM",
                    value: platformTitle,
                    icon: game?.platform == .nonSwitch ? "gamecontroller.fill" : (game?.platform == .ios ? "iphone.gen3" : "cube.fill")
                )

                // Column 4: Performance / Mode
                let performanceTitle: String = {
                    if let g = game {
                        if g.platform == .macApp {
                            let fps = config.enable60FPS ? "60 FPS" : "30 FPS"
                            let mode = config.isDockedMode ? "Docked" : "Handheld"
                            return "\(fps) · \(mode)"
                        } else if g.platform == .nonSwitch {
                            return config.enableGameMode ? "Game Mode Active" : "Native macOS"
                        } else {
                            return "Handheld IPA"
                        }
                    } else if let u = unportedGame {
                        if u.updateCount > 0 || u.dlcCount > 0 {
                            return "+\(u.updateCount) Updates · +\(u.dlcCount) DLCs"
                        }
                        return "Ready to Port"
                    }
                    return "Standard"
                }()
                metadataStatColumn(
                    label: "PERFORMANCE",
                    value: performanceTitle,
                    icon: "speedometer"
                )
            }
            .padding(.vertical, 2)

            // MARK: - Action Buttons Deck (Start Game, Port, Options)
            NXGlassContainer(spacing: 10) {
                HStack(spacing: 10) {
                    if let g = game {
                        portedActionBar(for: g)
                    } else if let u = unportedGame {
                        unportedActionBar(for: u)
                    }
                }
                .padding(.top, 2)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func metadataStatColumn(label: String, value: String, icon: String) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            HStack(spacing: 4) {
                Image(systemName: icon)
                    .font(.system(size: 8, weight: .bold))
                    .foregroundColor(NXTheme.isNeonBlack ? .white.opacity(0.85) : NXTheme.secondary)
                Text(label)
                    .font(.system(size: 8.5, weight: .bold, design: .rounded))
                    .foregroundColor(.white.opacity(0.65))
            }

            Text(value)
                .font(.system(size: 13.5, weight: .heavy, design: .rounded))
                .foregroundColor(.white)
                .lineLimit(1)
                .minimumScaleFactor(0.80)
                .shadow(color: Color.black.opacity(0.85), radius: 5, x: 0, y: 1.5)
        }
    }

    @ViewBuilder
    private func portedActionBar(for g: PortedGame) -> some View {
        let isPlayFocused = viewModel.focusZone == .content && viewModel.isFocusOnHeroBar && viewModel.heroActionFocusIndex == 0
        if g.isPlayableLocally {
            HeroPrimaryPlayButton(
                isLaunching: isLaunching,
                isFocused: isPlayFocused,
                action: { viewModel.launchGame(g) }
            )

            if let iosPort = viewModel.iosPort(for: g) {
                let isDeployed = deploymentTracker.isGameDeployed(iosPort)
                let record = deploymentTracker.deploymentRecord(for: iosPort)
                let isExpired = record?.isExpired ?? false

                heroSecondaryButton(
                    icon: isDeployed ? (isExpired ? "exclamationmark.triangle.fill" : "iphone.badge.play") : "arrow.up.forward.app",
                    title: isDeployed ? (isExpired ? viewModel.tr("console.renew_ios_expired") : viewModel.tr("console.renew_ios")) : viewModel.tr("console.send_ios"),
                    index: 1
                ) {
                    SoundEffectService.shared.play(.click)
                    viewModel.gameForSettingsSheet = iosPort
                }
            } else {
                heroSecondaryButton(
                    icon: "iphone.gen3",
                    title: viewModel.tr("common.port"),
                    index: 1
                ) {
                    SoundEffectService.shared.play(.click)
                    viewModel.openPortModal(for: g, targetPlatform: .ios)
                }
            }

            heroIconButton(
                icon: "line.3.horizontal",
                index: 2,
                helpText: viewModel.tr("console.options")
            ) {
                SoundEffectService.shared.play(.click)
                viewModel.gameForSettingsSheet = g
            }
        } else {
            HeroIosDeviceButton(
                game: g,
                isFocused: isPlayFocused,
                action: {
                    SoundEffectService.shared.play(.click)
                    viewModel.gameForSettingsSheet = g
                }
            )

            if let macPort = viewModel.macPort(for: g) {
                heroSecondaryButton(
                    icon: "play.fill",
                    title: viewModel.tr("common.play"),
                    index: 1
                ) {
                    viewModel.launchGame(macPort)
                }
            } else {
                heroSecondaryButton(
                    icon: "laptopcomputer",
                    title: viewModel.tr("common.port"),
                    index: 1
                ) {
                    SoundEffectService.shared.play(.click)
                    viewModel.openPortModal(for: g, targetPlatform: .macApp)
                }
            }

            heroIconButton(
                icon: "line.3.horizontal",
                index: 2,
                helpText: viewModel.tr("console.options")
            ) {
                SoundEffectService.shared.play(.click)
                viewModel.gameForSettingsSheet = g
            }
        }
    }

    @ViewBuilder
    private func unportedActionBar(for u: SelectableGame) -> some View {
        let isPortFocused = viewModel.focusZone == .content && viewModel.isFocusOnHeroBar && viewModel.heroActionFocusIndex == 0
        HeroPortNowButton(
            isBuilding: isUnportedBuilding,
            progressFraction: viewModel.progressFraction,
            isFocused: isPortFocused,
            action: {
                SoundEffectService.shared.play(.click)
                viewModel.selectedGame = u
                viewModel.gameForPortModal = u
            }
        )

        if let base = u.baseFile {
            heroSecondaryButton(icon: "folder.fill", title: viewModel.tr("actions.app_files"), index: 1) {
                SoundEffectService.shared.play(.click)
                NSWorkspace.shared.activateFileViewerSelecting([base.url])
            }
        }
        
        let tid = (u.titleId ?? "").uppercased()
        if !tid.isEmpty, let cloud = viewModel.cloudAvailableGames[tid] {
            if let task = viewModel.downloadTaskForGame(titleId: tid) {
                heroSecondaryButton(
                    icon: "arrow.down.circle",
                    title: "\(String(format: "%.0f%%", task.progress * 100)) · \(task.speedString)",
                    index: 2
                ) {
                    viewModel.cancelCloudDownload(titleId: tid)
                }
            } else {
                heroSecondaryButton(
                    icon: "arrow.down.circle.fill",
                    title: "Baixar da Nuvem",
                    index: 2
                ) {
                    SoundEffectService.shared.play(.click)
                    viewModel.startDownloadingCloudGame(cloud)
                }
            }
        }
    }

    private func heroSecondaryButton(icon: String, title: String, index: Int, action: @escaping () -> Void) -> some View {
        let isFocused = viewModel.focusZone == .content && viewModel.isFocusOnHeroBar && viewModel.heroActionFocusIndex == index
        return HeroHoverSecondaryButton(
            icon: icon,
            title: title,
            isFocused: isFocused,
            action: action
        )
    }

    private func heroIconButton(icon: String, index: Int, helpText: String, action: @escaping () -> Void) -> some View {
        let isFocused = viewModel.focusZone == .content && viewModel.isFocusOnHeroBar && viewModel.heroActionFocusIndex == index
        return HeroHoverIconButton(
            icon: icon,
            isFocused: isFocused,
            helpText: helpText,
            action: action
        )
    }
}

// MARK: - Legacy Wrapper for ConsoleHeroView (Maintains compatibility)
public struct ConsoleHeroView: View {
    public let game: PortedGame?
    public let unportedGame: SelectableGame?
    @ObservedObject public var viewModel: AppViewModel
    public let height: CGFloat

    public init(game: PortedGame? = nil, unportedGame: SelectableGame? = nil, viewModel: AppViewModel, height: CGFloat = 340) {
        self.game = game
        self.unportedGame = (game == nil) ? unportedGame : nil
        self.viewModel = viewModel
        self.height = height
    }

    public var body: some View {
        ZStack(alignment: .bottomLeading) {
            ConsoleHeroBackgroundView(game: game, unportedGame: unportedGame, viewModel: viewModel)
            ConsoleGameDetailView(game: game, unportedGame: unportedGame, viewModel: viewModel)
                .padding(.horizontal, 34)
                .padding(.bottom, 22)
        }
        .frame(maxWidth: .infinity, minHeight: height, maxHeight: height, alignment: .bottomLeading)
        .clipped()
    }
}
