import SwiftUI
import AppKit

public struct UnportedGameCardView: View {
    public let game: SelectableGame
    @ObservedObject public var viewModel: AppViewModel
    public let isFocused: Bool
    public let baseSize: CGFloat
    public let onSelect: () -> Void
    @ObservedObject private var coverService = GameCoverService.shared
    @ObservedObject private var deviceService = DeviceDeploymentService.shared
    
    public init(
        game: SelectableGame,
        viewModel: AppViewModel,
        isFocused: Bool,
        baseSize: CGFloat = 170,
        onSelect: @escaping () -> Void
    ) {
        self.game = game
        self.viewModel = viewModel
        self.isFocused = isFocused
        self.baseSize = baseSize
        self.onSelect = onSelect
    }

    private var cardScale: CGFloat {
        max(0.65, min(1.65, baseSize / 144.0))
    }

    private var cardCornerRadius: CGFloat {
        max(8.0, 14.0 * cardScale)
    }
    
    private var isBeingDeployed: Bool {
        if deviceService.activeDeployment.isRunning, let dGame = deviceService.currentDeployingGame {
            return viewModel.deduplicationKey(for: dGame) == viewModel.deduplicationKey(for: game)
        }
        return false
    }

    private var isBeingPorted: Bool {
        let isBuildActive = viewModel.isBuilding && (viewModel.buildingGameId == game.id || viewModel.selectedGame?.id == game.id || (viewModel.selectedGame != nil && viewModel.deduplicationKey(for: viewModel.selectedGame!) == viewModel.deduplicationKey(for: game)))
        return isBuildActive || isBeingDeployed
    }
    
    private var progress: Double {
        if isBeingDeployed {
            return max(0.0, min(1.0, deviceService.activeDeployment.progressFraction))
        }
        return max(0.0, min(1.0, viewModel.progressFraction))
    }
    
    private var coverImage: NSImage? {
        coverService.coverImage(titleId: game.titleId, gameName: game.name)
    }
    
    private var stageText: String {
        if isBeingDeployed {
            return deviceService.activeDeployment.phase.rawValue
        }
        let current = max(1, viewModel.stageIndex + 1)
        let total = viewModel.totalStages > 0 ? viewModel.totalStages : 10
        return String(format: "Stage %02d/%02d", current, total)
    }
    
    public var body: some View {
        ZStack(alignment: .bottomTrailing) {
            ZStack(alignment: .bottomTrailing) {
                // Visual Card Content with Progressive Vertical Opacity
                cardVisualStack

                // Bottom Right Badges (Switch Pill + Updates/DLCs count)
                if !isBeingPorted {
                    bottomBadges
                }

                // In-Progress Centered Percentage & Bottom Stage Pill
                if isBeingPorted {
                    inProgressOverlay
                }

                // Top Right: Cancel Port Button (Only when being ported & focused)
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
            .frame(width: baseSize, height: baseSize)
            .opacity(isBeingPorted ? 1.0 : (isFocused ? 0.85 : 0.50))
        }
        .frame(width: baseSize, height: baseSize)
        .overlay(
            RoundedRectangle(cornerRadius: cardCornerRadius, style: .continuous)
                .strokeBorder(
                    isFocused
                        ? AnyShapeStyle(LinearGradient(colors: [Color.white.opacity(0.95), NXTheme.secondary], startPoint: .topLeading, endPoint: .bottomTrailing))
                        : (isBeingPorted ? AnyShapeStyle(NXTheme.primary.opacity(0.85)) : AnyShapeStyle(Color.white.opacity(0.14))),
                    lineWidth: (isFocused || isBeingPorted) ? max(2.0, 3.0 * cardScale) : max(0.75, 1.0 * cardScale)
                )
        )
        .shadow(
            color: isFocused ? NXTheme.secondary.opacity(0.55) : (isBeingPorted ? NXTheme.primary.opacity(0.40) : Color.black.opacity(0.30)),
            radius: isFocused ? max(5.0, 8.0 * cardScale) : max(2.5, 4.0 * cardScale),
            x: 0,
            y: 2
        )
        .scaleEffect(isFocused ? 1.08 : 1.0)
        .animation(.spring(response: 0.28, dampingFraction: 0.76), value: isFocused)
        .animation(.easeInOut(duration: 0.22), value: isBeingPorted)
        .contentShape(RoundedRectangle(cornerRadius: cardCornerRadius, style: .continuous))
        .onTapGesture {
            onSelect()
        }
        .contextMenu {
            Button {
                viewModel.selectedGame = game
                viewModel.gameForPortModal = game
            } label: {
                Label(viewModel.tr("library.port_now"), systemImage: "play.circle.fill")
            }
            
            if let file = game.baseFile {
                Button {
                    NSWorkspace.shared.activateFileViewerSelecting([file.url])
                } label: {
                    Label(viewModel.tr("actions.app_files"), systemImage: "folder")
                }
            }
        }
    }
    
    // MARK: - Progressive Vertical Opacity Stack
    @ViewBuilder
    private var cardVisualStack: some View {
        if isBeingPorted {
            ZStack {
                // Base at 50% opacity
                singleTileArt
                    .opacity(0.50)
                
                // Rising 100% solid opacity layer from bottom to top
                singleTileArt
                    .opacity(1.0)
                    .mask(
                        VStack(spacing: 0) {
                            Spacer(minLength: 0)
                            Rectangle()
                                .frame(height: baseSize * CGFloat(progress))
                        }
                    )
            }
        } else {
            // Idle unported state: steady 50% opacity
            singleTileArt
                .opacity(0.50)
        }
    }
    
    // MARK: - 1:1 Tile Art
    @ViewBuilder
    private var singleTileArt: some View {
        ZStack {
            if let img = coverImage {
                Image(nsImage: img)
                    .resizable()
                    .scaledToFill()
                    .frame(width: baseSize, height: baseSize)
                    .clipped()
            } else {
                ZStack {
                    RoundedRectangle(cornerRadius: cardCornerRadius, style: .continuous)
                        .fill(NXTheme.glassSurfaceElevated)
                    
                    VStack(spacing: max(3.0, 6.0 * cardScale)) {
                        Image(systemName: "gamecontroller")
                            .font(.system(size: max(18.0, 32.0 * cardScale)))
                            .foregroundColor(NXTheme.isNeonBlack ? .white : NXTheme.secondary.opacity(0.8))
                        
                        Text(game.name)
                            .font(.system(size: max(8.0, 11.0 * cardScale), weight: .bold, design: .rounded))
                            .foregroundColor(NXTheme.textPrimary)
                            .multilineTextAlignment(.center)
                            .lineLimit(2)
                            .padding(.horizontal, max(4.0, 8.0 * cardScale))
                    }
                }
            }
            
            // Ambient vignette
            LinearGradient(
                colors: [Color.clear, Color.black.opacity(0.40)],
                startPoint: .center,
                endPoint: .bottom
            )
        }
        .clipShape(RoundedRectangle(cornerRadius: cardCornerRadius, style: .continuous))
    }

    // MARK: - Bottom Badges
    private var bottomBadges: some View {
        HStack(spacing: max(2.0, 4.0 * cardScale)) {
            if game.isNup || game.isSwitch2 {
                Text(game.isNup ? "NUP" : "SW2")
                    .font(.system(size: max(5.5, 8.0 * cardScale), weight: .black, design: .rounded))
                    .foregroundColor(.white)
                    .padding(.horizontal, max(3.5, 6.0 * cardScale))
                    .padding(.vertical, max(1.5, 2.5 * cardScale))
                    .nxGlassBar(
                        in: Capsule(),
                        tint: Color(red: 0.95, green: 0.48, blue: 0.16).opacity(0.85),
                        fallbackFill: Color(red: 0.95, green: 0.48, blue: 0.16).opacity(0.92),
                        fallbackStroke: Color.white.opacity(0.25)
                    )
            }

            Text(viewModel.tr("library.unported_badge"))
                .font(.system(size: max(5.5, 8.0 * cardScale), weight: .black, design: .rounded))
                .foregroundColor(.white)
                .padding(.horizontal, max(3.5, 6.0 * cardScale))
                .padding(.vertical, max(1.5, 2.5 * cardScale))
                .nxGlassBar(
                    in: Capsule(),
                    tint: NXTheme.secondary.opacity(0.75),
                    fallbackFill: NXTheme.secondary.opacity(0.85),
                    fallbackStroke: Color.white.opacity(0.20)
                )
            
            if game.updateCount > 0 || game.dlcCount > 0 {
                HStack(spacing: max(1.5, 2.0 * cardScale)) {
                    if game.updateCount > 0 {
                        Text("+\(game.updateCount)U")
                    }
                    if game.dlcCount > 0 {
                        Text("+\(game.dlcCount)D")
                    }
                }
                .font(.system(size: max(5.5, 8.0 * cardScale), weight: .bold, design: .monospaced))
                .foregroundColor(.white)
                .padding(.horizontal, max(3.0, 5.0 * cardScale))
                .padding(.vertical, max(1.5, 2.5 * cardScale))
                .nxGlassBar(
                    in: Capsule(),
                    tint: Color.blue.opacity(0.65),
                    fallbackFill: Color.blue.opacity(0.75),
                    fallbackStroke: Color.white.opacity(0.20)
                )
            }
            
            let tid = (game.titleId ?? "").uppercased()
            if let task = viewModel.downloadTaskForGame(titleId: tid) {
                HStack(spacing: max(1.5, 2.0 * cardScale)) {
                    ProgressView()
                        .controlSize(.mini)
                    Text(String(format: "%.0f%%", task.progress * 100))
                }
                .font(.system(size: max(5.5, 8.0 * cardScale), weight: .bold, design: .monospaced))
                .foregroundColor(.white)
                .padding(.horizontal, max(3.0, 5.0 * cardScale))
                .padding(.vertical, max(1.5, 2.5 * cardScale))
                .nxGlassBar(
                    in: Capsule(),
                    tint: NXTheme.primary.opacity(0.85),
                    fallbackFill: NXTheme.primary.opacity(0.90),
                    fallbackStroke: Color.white.opacity(0.20)
                )
            } else if !tid.isEmpty && viewModel.cloudAvailableGames[tid] != nil {
                Image(systemName: "icloud.and.arrow.down.fill")
                    .font(.system(size: max(5.5, 8.0 * cardScale), weight: .bold))
                    .foregroundColor(.white)
                    .padding(.horizontal, max(3.0, 5.0 * cardScale))
                    .padding(.vertical, max(1.5, 2.5 * cardScale))
                    .nxGlassBar(
                        in: Capsule(),
                        tint: NXTheme.primary.opacity(0.85),
                        fallbackFill: NXTheme.primary.opacity(0.90),
                        fallbackStroke: Color.white.opacity(0.20)
                    )
            }
        }
        .padding(max(4.0, 8.0 * cardScale))
    }
    
    // MARK: - Active Build Overlay (% Center + Stage Bottom)
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
