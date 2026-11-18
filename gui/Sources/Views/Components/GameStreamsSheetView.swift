import SwiftUI
import AppKit

public struct GameStreamsSheetView: View {
    public let game: CompatibleGameItem
    @ObservedObject public var viewModel: AppViewModel
    @ObservedObject private var coverService = GameCoverService.shared
    @ObservedObject private var artworkStore = ArtworkStore.shared
    @Environment(\.dismiss) private var dismiss
    
    @State private var customMagnetInput: String = ""
    @State private var isFetchingLiveStreams: Bool = false
    @State private var onDemandStreams: [CloudAvailableGame] = []
    
    public init(game: CompatibleGameItem, viewModel: AppViewModel) {
        self.game = game
        self.viewModel = viewModel
    }
    
    private var allStreams: [CloudAvailableGame] {
        var list = viewModel.streamsForGame(titleId: game.titleId)
        for s in onDemandStreams {
            if !list.contains(where: { $0.downloadURL == s.downloadURL }) {
                list.append(s)
            }
        }
        return list
    }
    
    private var activeDownload: DownloadTaskItem? {
        viewModel.downloadTaskForGame(titleId: game.titleId)
    }
    
    public var body: some View {
        VStack(spacing: 16) {
            headerView
            streamsSection
            manualInputSection
        }
        .padding(20)
        .frame(width: 580)
        .background(NXWindowGlassBackground(viewModel: viewModel))
        .onAppear {
            if allStreams.isEmpty {
                refreshStreams()
            }
        }
    }
    
    // MARK: - Header
    @ViewBuilder
    private var headerView: some View {
        let _ = coverService.refreshRevision
        let _ = artworkStore.refreshTrigger
        let coverImg = coverService.coverImage(titleId: game.titleId, gameName: game.title)
            ?? artworkStore.loadSquareIcon(titleId: game.titleId, gameName: game.title)
        
        HStack(alignment: .top, spacing: 14) {
            Group {
                if let img = coverImg {
                    Image(nsImage: img)
                        .resizable()
                        .scaledToFill()
                        .frame(width: 64, height: 64)
                        .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
                } else {
                    RoundedRectangle(cornerRadius: 12, style: .continuous)
                        .fill(NXTheme.primary.opacity(0.20))
                        .frame(width: 64, height: 64)
                        .overlay(
                            Image(systemName: "gamecontroller.fill")
                                .font(.system(size: 24))
                                .foregroundColor(NXTheme.primary)
                        )
                }
            }
            .overlay(
                RoundedRectangle(cornerRadius: 12, style: .continuous)
                    .strokeBorder(NXTheme.specularRim, lineWidth: 1)
            )
            
            VStack(alignment: .leading, spacing: 4) {
                Text(game.title)
                    .font(.system(size: 16, weight: .heavy, design: .rounded))
                    .foregroundColor(.white)
                    .lineLimit(2)
                
                HStack(spacing: 6) {
                    Text(game.isSwitch2 ? "Nintendo Switch 2" : "Nintendo Switch")
                        .font(.system(size: 9.5, weight: .bold, design: .rounded))
                        .foregroundColor(game.isSwitch2 ? Color(red: 0.95, green: 0.48, blue: 0.16) : NXTheme.primary)
                        .padding(.horizontal, 6)
                        .padding(.vertical, 2)
                        .background(NXTheme.glassSurfaceElevated.opacity(0.70))
                        .clipShape(Capsule())
                    
                    Text("v\(game.versionTested)")
                        .font(.system(size: 9.5, weight: .semibold, design: .monospaced))
                        .foregroundColor(NXTheme.textSecondary)
                        .padding(.horizontal, 6)
                        .padding(.vertical, 2)
                        .background(NXTheme.glassSurfaceElevated.opacity(0.50))
                        .clipShape(Capsule())
                    
                    Text(game.graphicsApi)
                        .font(.system(size: 9, weight: .bold, design: .monospaced))
                        .foregroundColor(NXTheme.secondary)
                        .padding(.horizontal, 6)
                        .padding(.vertical, 2)
                        .background(NXTheme.glassSurfaceElevated.opacity(0.50))
                        .clipShape(Capsule())
                }
                
                Text("Title ID: \(game.titleId)")
                    .font(.system(size: 9.5, design: .monospaced))
                    .foregroundColor(NXTheme.textMuted)
            }
            
            Spacer()
            
            Button(action: {
                SoundEffectService.shared.play(.click)
                dismiss()
            }) {
                Image(systemName: "xmark.circle.fill")
                    .font(.system(size: 20))
                    .foregroundColor(NXTheme.textSecondary)
            }
            .buttonStyle(PlainButtonStyle())
        }
        .padding(.horizontal, 2)
    }
    
    // MARK: - Streams Section
    @ViewBuilder
    private var streamsSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                HStack(spacing: 6) {
                    Image(systemName: "bolt.horizontal.fill")
                        .font(.system(size: 12, weight: .bold))
                        .foregroundColor(NXTheme.primary)
                    Text("Torrents e Links de Download (Streams)")
                        .font(.system(size: 12.5, weight: .bold, design: .rounded))
                        .foregroundColor(NXTheme.textPrimary)
                }
                
                Spacer()
                
                if isFetchingLiveStreams {
                    HStack(spacing: 4) {
                        ProgressView()
                            .controlSize(.mini)
                        Text("Buscando...")
                            .font(.system(size: 9.5))
                            .foregroundColor(NXTheme.textSecondary)
                    }
                } else {
                    Button(action: {
                        refreshStreams()
                    }) {
                        HStack(spacing: 4) {
                            Image(systemName: "arrow.clockwise")
                            Text("Atualizar")
                        }
                        .font(.system(size: 10, weight: .semibold))
                    }
                    .buttonStyle(NXSecondaryButtonStyle())
                    .controlSize(.mini)
                }
            }
            
            if let task = activeDownload {
                activeDownloadBanner(task: task)
            }
            
            if allStreams.isEmpty {
                emptyStreamsView
            } else {
                ScrollView {
                    VStack(spacing: 8) {
                        ForEach(allStreams) { stream in
                            streamCard(stream)
                        }
                    }
                }
                .frame(maxHeight: 220)
            }
        }
    }
    
    @ViewBuilder
    private func activeDownloadBanner(task: DownloadTaskItem) -> some View {
        HStack(spacing: 12) {
            ProgressView()
                .controlSize(.regular)
            
            VStack(alignment: .leading, spacing: 3) {
                Text("Baixando \(game.title)...")
                    .font(.system(size: 12, weight: .bold, design: .rounded))
                    .foregroundColor(.white)
                Text("\(String(format: "%.0f%%", task.progress * 100)) concluído • \(task.speedString) • ETA: \(task.etaString)")
                    .font(.system(size: 10, design: .monospaced))
                    .foregroundColor(NXTheme.primary)
            }
            
            Spacer()
            
            Button(action: {
                viewModel.cancelCloudDownload(titleId: game.titleId)
            }) {
                Text("Cancelar")
                    .font(.system(size: 10, weight: .bold))
                    .foregroundColor(.red)
            }
            .buttonStyle(NXSecondaryButtonStyle())
            .controlSize(.small)
        }
        .padding(12)
        .background(NXTheme.primary.opacity(0.12))
        .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .strokeBorder(NXTheme.primary.opacity(0.40), lineWidth: 1)
        )
    }
    
    @ViewBuilder
    private var emptyStreamsView: some View {
        VStack(spacing: 8) {
            Image(systemName: "tray.fill")
                .font(.system(size: 26))
                .foregroundColor(NXTheme.textMuted)
            Text("Nenhum torrent ou link encontrado nas fontes ativas.")
                .font(.system(size: 12, weight: .medium, design: .rounded))
                .foregroundColor(NXTheme.textSecondary)
            Text("Adicione uma fonte personalizada ou cole o link magnet diretamente abaixo.")
                .font(.system(size: 10))
                .foregroundColor(NXTheme.textMuted)
                .multilineTextAlignment(.center)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 22)
        .nxGlassCard(cornerRadius: 12)
    }
    
    // MARK: - Stream Card (Stremio style)
    @ViewBuilder
    private func streamCard(_ stream: CloudAvailableGame) -> some View {
        HStack(spacing: 12) {
            ZStack {
                Circle()
                    .fill(stream.isTorrent ? Color.green.opacity(0.18) : NXTheme.primary.opacity(0.18))
                    .frame(width: 34, height: 34)
                Image(systemName: stream.isTorrent ? "bolt.fill" : "arrow.down.circle.fill")
                    .font(.system(size: 14, weight: .bold))
                    .foregroundColor(stream.isTorrent ? Color.green : NXTheme.primary)
            }
            
            VStack(alignment: .leading, spacing: 3) {
                HStack(spacing: 6) {
                    Text(stream.sourceName)
                        .font(.system(size: 12, weight: .bold, design: .rounded))
                        .foregroundColor(.white)
                    
                    Text(stream.isTorrent ? "TORRENT / MAGNET" : "DIRETO")
                        .font(.system(size: 8.5, weight: .heavy, design: .rounded))
                        .foregroundColor(stream.isTorrent ? Color.green : NXTheme.primary)
                        .padding(.horizontal, 5)
                        .padding(.vertical, 1)
                        .background((stream.isTorrent ? Color.green : NXTheme.primary).opacity(0.18))
                        .clipShape(Capsule())
                    
                    if !stream.fileSizeFormatted.isEmpty {
                        Text(stream.fileSizeFormatted)
                            .font(.system(size: 9, design: .monospaced))
                            .foregroundColor(NXTheme.textSecondary)
                    }
                }
                
                Text(stream.downloadURL)
                    .font(.system(size: 9.5, design: .monospaced))
                    .foregroundColor(NXTheme.textMuted)
                    .lineLimit(1)
                    .truncationMode(.middle)
            }
            
            Spacer()
            
            Button(action: {
                viewModel.startDownloadingCloudGame(stream)
            }) {
                HStack(spacing: 4) {
                    Image(systemName: "arrow.down.circle.fill")
                    Text("Baixar")
                }
                .font(.system(size: 10.5, weight: .bold))
            }
            .buttonStyle(NXAccentButtonStyle())
            .controlSize(.small)
            .disabled(activeDownload != nil)
        }
        .padding(10)
        .background(NXTheme.glassSurfaceElevated.opacity(0.40))
        .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .strokeBorder(NXTheme.borderSubtle, lineWidth: 1)
        )
    }
    
    // MARK: - Manual Magnet Input
    @ViewBuilder
    private var manualInputSection: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("Adicionar Magnet / Torrent Avulso para este Jogo")
                .font(.system(size: 10.5, weight: .semibold, design: .rounded))
                .foregroundColor(NXTheme.textSecondary)
            
            HStack(spacing: 8) {
                TextField("magnet:?xt=urn:btih:... ou link direto", text: $customMagnetInput)
                    .textFieldStyle(PlainTextFieldStyle())
                    .font(.system(size: 11, design: .monospaced))
                    .padding(.horizontal, 10)
                    .padding(.vertical, 7)
                    .background(NXTheme.glassSurfaceElevated.opacity(0.50))
                    .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
                    .overlay(
                        RoundedRectangle(cornerRadius: 8, style: .continuous)
                            .strokeBorder(NXTheme.borderSubtle, lineWidth: 1)
                    )
                
                Button(action: {
                    let magnet = customMagnetInput.trimmingCharacters(in: .whitespacesAndNewlines)
                    guard !magnet.isEmpty else { return }
                    viewModel.addCustomMagnetToGame(game: game, magnet: magnet)
                    customMagnetInput = ""
                }) {
                    HStack(spacing: 4) {
                        Image(systemName: "arrow.down.circle.fill")
                        Text("Baixar")
                    }
                    .font(.system(size: 11, weight: .bold))
                }
                .buttonStyle(NXAccentButtonStyle())
                .disabled(customMagnetInput.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }
        }
        .padding(12)
        .nxGlassCard(cornerRadius: 12)
    }
    
    private func refreshStreams() {
        guard !isFetchingLiveStreams else { return }
        isFetchingLiveStreams = true
        let targetGame = game
        let activeSources = viewModel.cloudSources
        
        Task.detached(priority: .utility) {
            let found = await CloudScraperService.shared.resolveStreamsForSingleGame(
                game: targetGame,
                sources: activeSources
            )
            await MainActor.run {
                self.onDemandStreams = found
                self.isFetchingLiveStreams = false
            }
        }
    }
}
