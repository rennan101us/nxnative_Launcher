import SwiftUI
import AppKit

public struct CompatibleGameGridCard: View {
    public let item: CompatibleGameItem
    public let isCardFocused: Bool
    public let focusedButton: CompatibilityButtonFocus?
    public let viewModel: AppViewModel?
    public let onNotes: () -> Void
    @ObservedObject private var coverService = GameCoverService.shared
    @ObservedObject private var artworkStore = ArtworkStore.shared
    
    public init(
        item: CompatibleGameItem,
        isCardFocused: Bool = false,
        focusedButton: CompatibilityButtonFocus? = nil,
        viewModel: AppViewModel? = nil,
        onNotes: @escaping () -> Void = {}
    ) {
        self.item = item
        self.isCardFocused = isCardFocused
        self.focusedButton = focusedButton
        self.viewModel = viewModel
        self.onNotes = onNotes
    }
    
    public var body: some View {
        GlassCard(padding: 8, tint: isCardFocused ? NXTheme.primary.opacity(0.28) : nil) {
            VStack(alignment: .leading, spacing: 6) {
                // MARK: - Game Cover Art in Portrait (1:1.35 ratio)
                coverArtView
                    .overlay(
                        RoundedRectangle(cornerRadius: 10, style: .continuous)
                            .stroke(NXTheme.specularRim, lineWidth: 0.8)
                    )
                    .overlay(alignment: .topTrailing) {
                        if item.isNew {
                            Text(L10n.t("compatibility.new_badge"))
                                .font(.system(size: 8, weight: .heavy, design: .rounded))
                                .foregroundColor(.white)
                                .padding(.horizontal, 5)
                                .padding(.vertical, 2)
                                .background(
                                    Capsule()
                                        .fill(NXTheme.primaryGradient)
                                )
                                .shadow(color: Color.black.opacity(0.45), radius: 3, x: 0, y: 1)
                                .padding(5)
                        }
                    }
                
                // MARK: - Title (Fixed height for uniform grid)
                Text(item.title)
                    .font(.system(size: 11, weight: .bold, design: .rounded))
                    .foregroundColor(isCardFocused ? .white : NXTheme.textPrimary)
                    .lineLimit(2)
                    .frame(height: 28, alignment: .topLeading)
                
                // MARK: - Hardware Requirements (Mac, iOS & Android Specs)
                VStack(alignment: .leading, spacing: 2.5) {
                    HStack(spacing: 3) {
                        if item.isSwitch2 {
                            Text("Switch 2")
                                .font(.system(size: 7.5, weight: .bold, design: .rounded))
                                .padding(.horizontal, 4.5)
                                .padding(.vertical, 1.5)
                                .background(Color(red: 0.95, green: 0.48, blue: 0.16).opacity(0.85))
                                .foregroundColor(.white)
                                .clipShape(RoundedRectangle(cornerRadius: 3.5))
                        }

                        if item.isMacSupported {
                            let isMacReady = item.minRamGB <= Int(ProcessInfo.processInfo.physicalMemory / (1024 * 1024 * 1024))
                            HStack(spacing: 2.5) {
                                if isMacReady {
                                    Image(systemName: "checkmark")
                                        .font(.system(size: 6.5, weight: .bold))
                                }
                                Text(isMacReady ? "Mac" : item.macReq)
                            }
                            .font(.system(size: 7.5, weight: .semibold, design: .rounded))
                            .padding(.horizontal, 4.5)
                            .padding(.vertical, 1.5)
                            .background(isMacReady ? Color(red: 0.13, green: 0.77, blue: 0.37).opacity(0.40) : Color.blue.opacity(0.35))
                            .foregroundColor(.white)
                            .clipShape(RoundedRectangle(cornerRadius: 3.5))
                        }
                        
                        Text(item.storageReq)
                            .font(.system(size: 7.5, weight: .semibold, design: .monospaced))
                            .padding(.horizontal, 4.5)
                            .padding(.vertical, 1.5)
                            .background(Color.purple.opacity(0.35))
                            .foregroundColor(.white)
                            .clipShape(RoundedRectangle(cornerRadius: 3.5))
                    }
                    
                    HStack(spacing: 3) {
                        if item.isIosSupported && !item.iosReq.isEmpty {
                            Text(item.iosReq)
                                .font(.system(size: 7.5, weight: .medium, design: .rounded))
                                .lineLimit(1)
                                .minimumScaleFactor(0.75)
                                .padding(.horizontal, 4.5)
                                .padding(.vertical, 1.5)
                                .background(Color.orange.opacity(0.35))
                                .foregroundColor(.white)
                                .clipShape(RoundedRectangle(cornerRadius: 3.5))
                        }
                        
                        if item.isAndroidSupported {
                            Text("Android: \(item.androidGpuTier.shortName)")
                                .font(.system(size: 7.5, weight: .medium, design: .rounded))
                                .lineLimit(1)
                                .minimumScaleFactor(0.70)
                                .padding(.horizontal, 4.5)
                                .padding(.vertical, 1.5)
                                .background(Color.green.opacity(0.35))
                                .foregroundColor(.white)
                                .clipShape(RoundedRectangle(cornerRadius: 3.5))
                        }
                    }
                }
                .frame(height: 32, alignment: .leading)
                
                Divider().opacity(0.2)
                
                // MARK: - Footer: Action Button (Download if available in cloud + Notes)
                HStack(spacing: 5) {
                    if let vm = viewModel {
                        let tid = item.titleId.uppercased()
                        if let task = vm.downloadTaskForGame(titleId: tid) {
                            HStack(spacing: 4) {
                                ProgressView()
                                    .controlSize(.mini)
                                Text(String(format: "%.0f%%", task.progress * 100))
                                    .font(.system(size: 8.5, weight: .bold, design: .monospaced))
                                    .foregroundColor(NXTheme.primary)
                                Button(action: {
                                    vm.cancelCloudDownload(titleId: tid)
                                }) {
                                    Image(systemName: "xmark.circle.fill")
                                        .font(.system(size: 9))
                                        .foregroundColor(NXTheme.textMuted)
                                }
                                .buttonStyle(PlainButtonStyle())
                            }
                            .padding(.horizontal, 5)
                            .padding(.vertical, 2)
                            .background(NXTheme.glassSurfaceElevated.opacity(0.60))
                            .clipShape(Capsule())
                        } else {
                            let streams = vm.streamsForGame(titleId: tid)
                            Button(action: {
                                SoundEffectService.shared.play(.click)
                                vm.selectedGameForStreams = item
                            }) {
                                Image(systemName: streams.isEmpty ? "bolt.horizontal" : "bolt.horizontal.fill")
                                    .font(.system(size: 10, weight: .bold))
                                    .foregroundColor(streams.isEmpty ? NXTheme.textSecondary : NXTheme.primary)
                            }
                            .buttonStyle(NXSecondaryButtonStyle())
                            .controlSize(.mini)
                            .help(streams.isEmpty ? "Ver torrents ou colar magnet para este jogo" : "\(streams.count) torrent(s) disponível(is)")
                        }
                    }

                    if item.githubUrl != nil {
                        Button(action: {
                            SoundEffectService.shared.play(.click)
                            onNotes()
                        }) {
                            Image(systemName: "doc.text.fill")
                                .font(.system(size: 10, weight: .semibold))
                        }
                        .buttonStyle(NXSecondaryButtonStyle())
                        .controlSize(.mini)
                        .overlay(
                            RoundedRectangle(cornerRadius: 6)
                                .stroke(isCardFocused && focusedButton == .notes ? Color.white : Color.clear, lineWidth: 1.5)
                        )
                        .help(L10n.t("compatibility.upstream_notes_help"))
                    }
                    
                    Spacer()
                    
                    Text("v\(item.versionTested)")
                        .font(.system(size: 8.5, design: .monospaced))
                        .foregroundColor(NXTheme.textMuted)
                }
            }
        }
        .frame(maxWidth: .infinity)
        .overlay(
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .stroke(isCardFocused ? AnyShapeStyle(NXTheme.primaryGradient) : AnyShapeStyle(Color.clear), lineWidth: 2)
        )
        .shadow(color: isCardFocused ? NXTheme.primary.opacity(0.4) : Color.clear, radius: 8, x: 0, y: 3)
    }
    
    // MARK: - Game Cover Art (Clean Steam / Playnite / RetroArch style)
    @ViewBuilder
    private var coverArtView: some View {
        let _ = coverService.refreshRevision
        let _ = artworkStore.refreshTrigger
        let coverImg = coverService.coverImage(titleId: item.titleId, gameName: item.title)
            ?? artworkStore.loadSquareIcon(titleId: item.titleId, gameName: item.title)
        
        Color.clear
            .aspectRatio(1.0, contentMode: .fit)
            .overlay(
                GeometryReader { geo in
                    let side = min(geo.size.width, geo.size.height)
                    Group {
                        if let img = coverImg {
                            Image(nsImage: img)
                                .resizable()
                                .scaledToFill()
                                .frame(width: side, height: side, alignment: .center)
                                .clipped()
                        } else {
                            fallbackIcon
                                .frame(width: side, height: side)
                        }
                    }
                    .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
                }
            )
            .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: 10, style: .continuous)
                    .stroke(NXTheme.specularRim, lineWidth: 0.8)
            )
    }
    
    private var fallbackIcon: some View {
        ZStack {
            NXTheme.primary.opacity(0.2)
            VStack(spacing: 6) {
                Image(systemName: "gamecontroller.fill")
                    .font(.system(size: 26))
                    .foregroundColor(NXTheme.secondary)
                Text(item.title)
                    .font(.system(size: 10, weight: .bold))
                    .foregroundColor(.white)
                    .multilineTextAlignment(.center)
                    .padding(.horizontal, 8)
                    .lineLimit(2)
            }
        }
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
