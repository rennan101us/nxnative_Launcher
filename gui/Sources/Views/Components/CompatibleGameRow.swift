import SwiftUI
import AppKit

public struct CompatibleGameRow: View {
    public let game: CompatibleGameItem
    public let isRowFocused: Bool
    public let focusedButton: CompatibilityButtonFocus?
    public let viewModel: AppViewModel?
    public let onNotes: () -> Void
    @ObservedObject private var coverService = GameCoverService.shared
    @ObservedObject private var artworkStore = ArtworkStore.shared
    
    public init(
        game: CompatibleGameItem,
        isRowFocused: Bool = false,
        focusedButton: CompatibilityButtonFocus? = nil,
        viewModel: AppViewModel? = nil,
        onNotes: @escaping () -> Void = {}
    ) {
        self.game = game
        self.isRowFocused = isRowFocused
        self.focusedButton = focusedButton
        self.viewModel = viewModel
        self.onNotes = onNotes
    }
    
    public var body: some View {
        GlassCard(padding: 10, tint: isRowFocused ? NXTheme.primary.opacity(0.28) : nil) {
            HStack(spacing: 14) {
                // Official Cover Art / Box Art
                coverArtView
                
                // Game Details
                VStack(alignment: .leading, spacing: 4) {
                    HStack(spacing: 6) {
                        Text(game.title)
                            .font(.system(size: 13, weight: .bold, design: .rounded))
                            .foregroundColor(isRowFocused ? .white : NXTheme.textPrimary)
                            .lineLimit(1)
                        
                        if game.isNew {
                            Text(L10n.t("compatibility.new_badge"))
                                .font(.system(size: 8.5, weight: .heavy, design: .rounded))
                                .foregroundColor(.white)
                                .padding(.horizontal, 5)
                                .padding(.vertical, 1.5)
                                .background(
                                    Capsule()
                                        .fill(NXTheme.primaryGradient)
                                )
                        }
                    }
                    
                    Text("Ver: \(game.versionTested)")
                        .font(.system(size: 10, design: .monospaced))
                        .foregroundColor(NXTheme.textSecondary)
                }
                
                Spacer(minLength: 12)
                
                // Hardware Specs Badges (Switch 2, Mac, iOS, Android, Storage)
                HStack(spacing: 6) {
                    if game.isSwitch2 {
                        Text("Switch 2")
                            .font(.system(size: 9, weight: .bold, design: .rounded))
                            .padding(.horizontal, 6)
                            .padding(.vertical, 3)
                            .background(Color(red: 0.95, green: 0.48, blue: 0.16).opacity(0.85))
                            .foregroundColor(.white)
                            .clipShape(RoundedRectangle(cornerRadius: 5))
                    }

                    if game.isMacSupported {
                        let isMacReady = game.minRamGB <= Int(ProcessInfo.processInfo.physicalMemory / (1024 * 1024 * 1024))
                        HStack(spacing: 3) {
                            if isMacReady {
                                Image(systemName: "checkmark")
                                    .font(.system(size: 7.5, weight: .bold))
                            }
                            Text(game.macReq)
                        }
                        .font(.system(size: 9, weight: .semibold, design: .rounded))
                        .padding(.horizontal, 6)
                        .padding(.vertical, 3)
                        .background(isMacReady ? Color(red: 0.13, green: 0.77, blue: 0.37).opacity(0.40) : Color.blue.opacity(0.35))
                        .foregroundColor(.white)
                        .clipShape(RoundedRectangle(cornerRadius: 5))
                    }
                    
                    if game.isIosSupported && !game.iosReq.isEmpty {
                        Text(game.iosReq)
                            .font(.system(size: 9, weight: .semibold, design: .rounded))
                            .padding(.horizontal, 6)
                            .padding(.vertical, 3)
                            .background(Color.orange.opacity(0.35))
                            .foregroundColor(.white)
                            .clipShape(RoundedRectangle(cornerRadius: 5))
                    }
                    
                    if game.isAndroidSupported {
                        Text("Android: \(game.androidGpuTier.shortName)")
                            .font(.system(size: 9, weight: .semibold, design: .rounded))
                            .padding(.horizontal, 6)
                            .padding(.vertical, 3)
                            .background(Color.green.opacity(0.35))
                            .foregroundColor(.white)
                            .clipShape(RoundedRectangle(cornerRadius: 5))
                    }
                    
                    Text(game.storageReq)
                        .font(.system(size: 9, weight: .semibold, design: .monospaced))
                        .padding(.horizontal, 6)
                        .padding(.vertical, 3)
                        .background(Color.purple.opacity(0.35))
                        .foregroundColor(.white)
                        .clipShape(RoundedRectangle(cornerRadius: 5))
                }
                
                // Action Buttons: Baixar (se disponível na nuvem) + Notas
                HStack(spacing: 8) {
                    if let vm = viewModel {
                        let tid = game.titleId.uppercased()
                        if let task = vm.downloadTaskForGame(titleId: tid) {
                            HStack(spacing: 6) {
                                ProgressView()
                                    .controlSize(.mini)
                                Text(String(format: "%.0f%%", task.progress * 100))
                                    .font(.system(size: 10.5, weight: .bold, design: .monospaced))
                                    .foregroundColor(NXTheme.primary)
                                if !task.speedString.isEmpty {
                                    Text(task.speedString)
                                        .font(.system(size: 9.5, design: .monospaced))
                                        .foregroundColor(NXTheme.textSecondary)
                                }
                                Button(action: {
                                    vm.cancelCloudDownload(titleId: tid)
                                }) {
                                    Image(systemName: "xmark.circle.fill")
                                        .font(.system(size: 12))
                                        .foregroundColor(NXTheme.textMuted)
                                }
                                .buttonStyle(PlainButtonStyle())
                            }
                            .padding(.horizontal, 9)
                            .padding(.vertical, 4)
                            .background(NXTheme.glassSurfaceElevated.opacity(0.60))
                            .clipShape(Capsule())
                            .overlay(
                                Capsule()
                                    .strokeBorder(NXTheme.primary.opacity(0.35), lineWidth: 1)
                            )
                        } else {
                            let streams = vm.streamsForGame(titleId: tid)
                            Button(action: {
                                SoundEffectService.shared.play(.click)
                                vm.selectedGameForStreams = game
                            }) {
                                Image(systemName: streams.isEmpty ? "bolt.horizontal" : "bolt.horizontal.fill")
                                    .font(.system(size: 11.5, weight: .bold))
                                    .foregroundColor(streams.isEmpty ? NXTheme.textSecondary : NXTheme.primary)
                            }
                            .buttonStyle(NXSecondaryButtonStyle())
                            .controlSize(.small)
                            .help(streams.isEmpty ? "Ver torrents ou colar magnet para este jogo" : "\(streams.count) torrent(s) disponível(is)")
                        }
                    }

                    if game.githubUrl != nil {
                        Button(action: {
                            SoundEffectService.shared.play(.click)
                            onNotes()
                        }) {
                            Image(systemName: "doc.text.fill")
                                .font(.system(size: 11, weight: .semibold))
                        }
                        .buttonStyle(NXSecondaryButtonStyle())
                        .controlSize(.small)
                        .overlay(
                            RoundedRectangle(cornerRadius: 8)
                                .stroke(isRowFocused && focusedButton == .notes ? Color.white : Color.clear, lineWidth: 1.5)
                        )
                        .help(L10n.t("compatibility.upstream_notes_help"))
                    }
                }
            }
            .frame(minHeight: 48)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .frame(maxWidth: .infinity)
        .overlay(
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .stroke(isRowFocused ? AnyShapeStyle(NXTheme.primaryGradient) : AnyShapeStyle(Color.clear), lineWidth: 2)
        )
        .shadow(color: isRowFocused ? NXTheme.primary.opacity(0.4) : Color.clear, radius: 8, x: 0, y: 2)
    }
    
    // MARK: - Cover Art Loader
    @ViewBuilder
    private var coverArtView: some View {
        let _ = coverService.refreshRevision
        let _ = artworkStore.refreshTrigger
        if let localImg = coverService.coverImage(titleId: game.titleId, gameName: game.title)
            ?? artworkStore.loadSquareIcon(titleId: game.titleId, gameName: game.title) {
            Image(nsImage: localImg)
                .resizable()
                .aspectRatio(contentMode: .fill)
                .frame(width: 44, height: 44)
                .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
                .overlay(
                    RoundedRectangle(cornerRadius: 10, style: .continuous)
                        .stroke(NXTheme.specularRim, lineWidth: 0.8)
                )
        } else {
            fallbackIcon
                .frame(width: 44, height: 44)
        }
    }
    
    private var fallbackIcon: some View {
        ZStack {
            NXTheme.glassSurfaceElevated
            Image(systemName: "gamecontroller.fill")
                .font(.system(size: 18))
                .foregroundColor(NXTheme.secondary)
        }
        .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
    }
    
    private func apiColor(_ api: String) -> Color {
        switch api.uppercased() {
        case "NVN": return Color(red: 0.13, green: 0.77, blue: 0.37)
        case "VULKAN": return NXTheme.tertiary
        case "OPENGL": return NXTheme.primary
        default: return NXTheme.secondary
        }
    }
}
