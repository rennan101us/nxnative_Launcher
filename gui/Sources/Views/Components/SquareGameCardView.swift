import SwiftUI
import AppKit

public struct SquareGameCardView: View {
    public let game: PortedGame
    @ObservedObject public var viewModel: AppViewModel
    public let isFocused: Bool
    public let isDropTarget: Bool
    public let baseSize: CGFloat
    public let onSelect: () -> Void
    @ObservedObject private var deploymentTracker = IosDeploymentTracker.shared
    @ObservedObject private var deviceService = DeviceDeploymentService.shared
    @ObservedObject private var artworkStore = ArtworkStore.shared
    @ObservedObject private var coverService = GameCoverService.shared

    public init(
        game: PortedGame,
        viewModel: AppViewModel,
        isFocused: Bool,
        isDropTarget: Bool = false,
        baseSize: CGFloat = 170,
        onSelect: @escaping () -> Void
    ) {
        self.game = game
        self.viewModel = viewModel
        self.isFocused = isFocused
        self.isDropTarget = isDropTarget
        self.baseSize = baseSize
        self.onSelect = onSelect
    }

    private var cardScale: CGFloat {
        max(0.65, min(1.65, baseSize / 144.0))
    }

    private var cardCornerRadius: CGFloat {
        max(8.0, 14.0 * cardScale)
    }

    private var iconImage: NSImage {
        _ = artworkStore.refreshTrigger
        _ = coverService.refreshRevision
        return artworkStore.loadSquareIcon(for: game)
    }

    private var isBeingDragged: Bool {
        viewModel.draggedGame?.url.standardized.path == game.url.standardized.path
    }

    private var isBeingPorted: Bool {
        if viewModel.isBuilding {
            if let bId = viewModel.buildingGameId {
                if bId == game.uniqueKey || bId == game.titleId || bId == game.bundleId { return true }
            }
            if let sel = viewModel.selectedGame {
                if viewModel.deduplicationKey(for: game) == viewModel.deduplicationKey(for: sel) { return true }
            }
        }
        return false
    }

    private var isBeingDeployed: Bool {
        if deviceService.activeDeployment.isRunning, let dGame = deviceService.currentDeployingGame {
            return viewModel.deduplicationKey(for: game) == viewModel.deduplicationKey(for: dGame)
        }
        return false
    }

    private var isBusyWithTask: Bool {
        isBeingPorted || isBeingDeployed
    }

    private var progress: Double {
        if isBeingDeployed {
            return max(0.0, min(1.0, deviceService.activeDeployment.progressFraction))
        }
        return max(0.0, min(1.0, viewModel.progressFraction))
    }

    private var stageText: String {
        if isBeingDeployed {
            return deviceService.activeDeployment.phase.rawValue
        }
        let current = max(1, viewModel.stageIndex + 1)
        let total = viewModel.totalStages > 0 ? viewModel.totalStages : 10
        return String(format: "Stage %02d/%02d", current, total)
    }

    private var singleTileArt: some View {
        ZStack(alignment: .bottomTrailing) {
            Image(nsImage: iconImage)
                .resizable()
                .scaledToFill()
                .frame(width: baseSize, height: baseSize, alignment: .top)
                .clipped()
                .clipShape(RoundedRectangle(cornerRadius: cardCornerRadius, style: .continuous))

            LinearGradient(
                colors: [Color.clear, Color.black.opacity(0.35)],
                startPoint: .center,
                endPoint: .bottom
            )
            .clipShape(RoundedRectangle(cornerRadius: cardCornerRadius, style: .continuous))
        }
    }

    private var cardTileStack: some View {
        ZStack(alignment: .bottomTrailing) {
            if isBusyWithTask {
                ZStack {
                    singleTileArt.opacity(0.50)
                    singleTileArt.opacity(1.0)
                        .mask(
                            VStack(spacing: 0) {
                                Spacer(minLength: 0)
                                Rectangle().frame(height: baseSize * CGFloat(progress))
                            }
                        )
                }
            } else {
                singleTileArt
            }

            if isBusyWithTask {
                inProgressOverlay
            }

            if isBeingPorted && isFocused {
                VStack {
                    HStack {
                        Spacer()
                        cancelPortButton
                    }
                    Spacer()
                }
                .transition(.scale.combined(with: .opacity))
            }
        }
    }

    private var cardInteractiveFrame: some View {
        cardTileStack
            .frame(width: baseSize, height: baseSize)
            .opacity(isBeingDragged ? 0.35 : 1.0)
            .overlay(alignment: .bottomTrailing) { cardBadgesOverlay }
            .overlay(alignment: .topTrailing) { cardRenewalOverlay }
            .overlay { cardBorderStroke }
    }

    public var body: some View {
        cardInteractiveFrame
            .shadow(
                color: isDropTarget ? NXTheme.primary.opacity(0.85) : (isFocused ? NXTheme.primary.opacity(0.65) : Color.black.opacity(0.35)),
                radius: (isDropTarget || isFocused) ? max(5.0, 8.0 * cardScale) : max(2.5, 4.0 * cardScale),
                x: 0,
                y: 2
            )
            .shadow(
                color: (isDropTarget || isFocused) ? NXTheme.primary.opacity(0.35) : Color.clear,
                radius: (isDropTarget || isFocused) ? max(10.0, 18.0 * cardScale) : 0,
                x: 0,
                y: (isDropTarget || isFocused) ? 3 : 0
            )
            .scaleEffect(isDropTarget ? 1.05 : (isFocused ? 1.08 : 1.0))
            .animation(.spring(response: 0.28, dampingFraction: 0.76), value: isFocused)
            .animation(.spring(response: 0.24, dampingFraction: 0.80), value: isDropTarget)
            .animation(.easeInOut(duration: 0.20), value: isBeingDragged)
            .contentShape(RoundedRectangle(cornerRadius: cardCornerRadius, style: .continuous))
            .onTapGesture {
                onSelect()
            }
            .contextMenu {
                primaryActionMenuButtons
                fileManagementMenuButtons
                Divider()
                removalMenuButtons
            }
    }

    @ViewBuilder
    private var cardBadgesOverlay: some View {
        if !isBusyWithTask {
            NXGlassContainer(spacing: max(2.0, 4.0 * cardScale)) {
                HStack(spacing: max(2.0, 4.0 * cardScale)) {
                    let isApplePlatform = game.platform == .macApp || game.platform == .nonSwitch
                    let badgeColor: Color = {
                        if NXTheme.isNeonBlack { return Color(white: 0.32) }
                        return isApplePlatform ? NXTheme.primary : NXTheme.secondary
                    }()

                    Group {
                        if isApplePlatform {
                            Image(systemName: "apple.logo")
                        } else {
                            Image(systemName: "iphone")
                        }
                    }
                    .font(.system(size: max(6.5, 8.5 * cardScale), weight: .bold))
                    .foregroundColor(.white)
                    .padding(.horizontal, max(4.0, 6.0 * cardScale))
                    .padding(.vertical, max(2.5, 3.5 * cardScale))
                    .nxGlassBar(
                        in: Capsule(),
                        tint: badgeColor.opacity(0.68),
                        fallbackFill: badgeColor.opacity(0.85),
                        fallbackStroke: Color.white.opacity(0.22)
                    )

                    if game.platform != .ios, viewModel.iosPort(for: game) != nil {
                        Image(systemName: "iphone")
                            .font(.system(size: max(6.5, 8.5 * cardScale), weight: .bold))
                            .foregroundColor(.white)
                            .padding(.horizontal, max(4.0, 6.0 * cardScale))
                            .padding(.vertical, max(2.5, 3.5 * cardScale))
                            .nxGlassBar(
                                in: Capsule(),
                                tint: NXTheme.secondary.opacity(0.68),
                                fallbackFill: NXTheme.secondary.opacity(0.85),
                                fallbackStroke: Color.white.opacity(0.22)
                            )
                    }

                    if SaveSyncService.shared.isCloudSyncActive(for: game) {
                        Image(systemName: "icloud.fill")
                            .font(.system(size: max(5.5, 8.0 * cardScale), weight: .bold))
                            .foregroundColor(.white)
                            .padding(.horizontal, max(3.0, 5.0 * cardScale))
                            .padding(.vertical, max(1.5, 2.5 * cardScale))
                            .nxGlassBar(
                                in: Capsule(),
                                tint: Color.blue.opacity(0.68),
                                fallbackFill: Color.blue.opacity(0.85),
                                fallbackStroke: Color.white.opacity(0.22)
                            )
                    }
                }
                .padding(max(4.0, 8.0 * cardScale))
            }
        }
    }

    @ViewBuilder
    private var cardRenewalOverlay: some View {
        if !isBusyWithTask, let record = deploymentTracker.deploymentRecord(for: game) {
            IosRenewalBadgeView(record: record, scale: cardScale)
                .padding(max(4.0, 8.0 * cardScale))
        }
    }

    private var cardBorderStroke: some View {
        let isSpecial = isDropTarget || isFocused || isBusyWithTask
        let strokeWidth = isSpecial ? max(2.2, 3.5 * cardScale) : max(0.75, 1.0 * cardScale)

        return RoundedRectangle(cornerRadius: cardCornerRadius, style: .continuous)
            .strokeBorder(
                isDropTarget
                    ? AnyShapeStyle(NXTheme.primary)
                    : (isFocused
                        ? AnyShapeStyle(LinearGradient(colors: [Color.white.opacity(0.95), NXTheme.primary], startPoint: .topLeading, endPoint: .bottomTrailing))
                        : (isBusyWithTask ? AnyShapeStyle(NXTheme.primary.opacity(0.85)) : AnyShapeStyle(Color.white.opacity(0.16)))),
                lineWidth: strokeWidth
            )
    }

    @ViewBuilder
    private var primaryActionMenuButtons: some View {
        if game.isPlayableLocally {
            Button {
                viewModel.launchGame(game)
            } label: {
                Label(viewModel.tr("common.play"), systemImage: "play.fill")
            }
        } else {
            let isDeployed = deploymentTracker.isGameDeployed(game)
            Button {
                viewModel.gameForSettingsSheet = game
            } label: {
                Label(
                    isDeployed ? viewModel.tr("actions.renew_ios") : viewModel.tr("actions.send_ios"),
                    systemImage: isDeployed ? "arrow.triangle.2.circlepath" : "arrow.up.forward.app"
                )
            }
        }
    }

    @ViewBuilder
    private var fileManagementMenuButtons: some View {
        Button {
            viewModel.gameForSettingsSheet = game
        } label: {
            Label(viewModel.tr("actions.game_settings"), systemImage: "slider.horizontal.3")
        }

        Button {
            viewModel.revealInFinder(url: game.url)
        } label: {
            Label(viewModel.tr("actions.app_files"), systemImage: "folder")
        }

        Button {
            let profile = GameDetailsProfile.inspect(for: game)
            viewModel.revealSaveFolder(profile.saveDirectory)
        } label: {
            Label(viewModel.tr("actions.save_location"), systemImage: "internaldrive")
        }
    }

    @ViewBuilder
    private var removalMenuButtons: some View {
        Button {
            viewModel.confirmDialogFocusIndex = 1
            viewModel.gameToHide = game
            viewModel.showHideConfirm = true
        } label: {
            Label(viewModel.tr("actions.hide_from_library"), systemImage: "eye.slash")
        }

        Button {
            viewModel.confirmDialogFocusIndex = 1
            viewModel.gameToRemove = game
            viewModel.showRemoveConfirm = true
        } label: {
            Label(viewModel.tr("actions.remove_from_library"), systemImage: "folder.badge.minus")
        }

        Button(role: .destructive) {
            viewModel.confirmDialogFocusIndex = 1
            viewModel.gameToTrash = game
            viewModel.showTrashConfirm = true
        } label: {
            Label(viewModel.tr("actions.move_to_trash"), systemImage: "trash")
        }
    }

    // MARK: - Active Build & Deploy Overlay (% Center + Stage Bottom)
    private var inProgressOverlay: some View {
        ZStack {
            // Centered Bold Percentage
            VStack(spacing: max(2.0, 4.0 * cardScale)) {
                Text("\(Int(progress * 100))%")
                    .font(.system(size: max(15.0, 26.0 * cardScale), weight: .black, design: .rounded))
                    .foregroundColor(.white)
                    .shadow(color: Color.black.opacity(0.85), radius: 6, x: 0, y: 2)
            }
            .padding(.horizontal, max(8.0, 14.0 * cardScale))
            .padding(.vertical, max(3.5, 6.0 * cardScale))
            .background(
                Capsule()
                    .fill(Color.black.opacity(0.72))
                    .overlay(
                        Capsule()
                            .strokeBorder(NXTheme.primary.opacity(0.85), lineWidth: max(0.8, 1.2 * cardScale))
                    )
            )
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .center)
            
            // Bottom Discrete Stage Indicator
            VStack {
                Spacer()
                Text(stageText)
                    .font(.system(size: max(6.0, 8.5 * cardScale), weight: .bold, design: .monospaced))
                    .foregroundColor(.white.opacity(0.92))
                    .padding(.horizontal, max(4.0, 7.0 * cardScale))
                    .padding(.vertical, max(1.5, 2.5 * cardScale))
                    .background(
                        Capsule()
                            .fill(Color.black.opacity(0.75))
                            .overlay(
                                Capsule()
                                    .strokeBorder(Color.white.opacity(0.18), lineWidth: 0.8)
                            )
                    )
                    .padding(.bottom, max(4.0, 7.0 * cardScale))
            }
            .frame(maxWidth: .infinity, alignment: .center)
        }
    }

    // MARK: - Top Right Cancel Button
    private var cancelPortButton: some View {
        Button(action: {
            SoundEffectService.shared.play(.click)
            viewModel.cancelBuild()
        }) {
            HStack(spacing: max(2.0, 3.5 * cardScale)) {
                Image(systemName: "xmark")
                    .font(.system(size: max(6.0, 8.5 * cardScale), weight: .black))
                Text(viewModel.tr("library.cancel_port"))
                    .font(.system(size: max(6.0, 8.5 * cardScale), weight: .bold, design: .rounded))
                if GameControllerService.shared.isGamepadConnected {
                    Text("(B)")
                        .font(.system(size: max(5.5, 7.5 * cardScale), weight: .black, design: .monospaced))
                        .opacity(0.9)
                }
            }
            .foregroundColor(.white)
            .padding(.horizontal, max(4.0, 7.0 * cardScale))
            .padding(.vertical, max(2.0, 3.5 * cardScale))
            .background(
                Capsule()
                    .fill(Color(red: 0.85, green: 0.18, blue: 0.18).opacity(0.92))
                    .overlay(
                        Capsule().strokeBorder(Color.white.opacity(0.35), lineWidth: 1)
                    )
            )
            .contentShape(Capsule())
        }
        .buttonStyle(NXPressableButtonStyle())
        .padding(max(3.5, 6.0 * cardScale))
    }
}
