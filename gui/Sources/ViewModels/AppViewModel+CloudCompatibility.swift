import Foundation
import AppKit

extension AppViewModel {
    
    // MARK: - Cloud Sources Management
    public func loadCloudSources() {
        self.cloudSources = CloudSourceManager.shared.loadSources()
        syncCloudSources()
    }
    
    public func addCloudSource(name: String, urlString: String) {
        _ = CloudSourceManager.shared.addSource(name: name, urlString: urlString)
        self.cloudSources = CloudSourceManager.shared.loadSources()
        SoundEffectService.shared.play(.click)
        syncCloudSources()
    }
    
    public func removeCloudSource(id: UUID) {
        CloudSourceManager.shared.removeSource(id: id)
        self.cloudSources = CloudSourceManager.shared.loadSources()
        SoundEffectService.shared.play(.click)
        syncCloudSources()
    }
    
    public func toggleCloudSource(id: UUID, isEnabled: Bool) {
        if let idx = cloudSources.firstIndex(where: { $0.id == id }) {
            var updated = cloudSources[idx]
            updated.isEnabled = isEnabled
            CloudSourceManager.shared.updateSource(updated)
            self.cloudSources[idx] = updated
            syncCloudSources()
        }
    }
    
    public func syncCloudSources() {
        guard !isSyncingCloudSources else { return }
        isSyncingCloudSources = true
        
        let sourcesToSync = self.cloudSources
        let compatList = self.compatibleGames
        
        Task.detached(priority: .utility) { [weak self] in
            let (matches, streams, updatedSources) = await CloudScraperService.shared.syncSources(
                sourcesToSync,
                compatibleGames: compatList
            )
            
            await MainActor.run { [weak self] in
                guard let self = self else { return }
                self.cloudAvailableGames = matches
                self.cloudStreamsByTitleId = streams
                self.cloudSources = updatedSources
                self.isSyncingCloudSources = false
                CloudSourceManager.shared.saveSources(updatedSources)
            }
        }
    }
    
    // MARK: - Query Status
    public func isGameAvailableInCloud(titleId: String) -> CloudAvailableGame? {
        cloudAvailableGames[titleId.uppercased()]
    }
    
    public func streamsForGame(titleId: String) -> [CloudAvailableGame] {
        let tid = titleId.uppercased()
        if let list = cloudStreamsByTitleId[tid], !list.isEmpty {
            return list
        }
        if let single = cloudAvailableGames[tid] {
            return [single]
        }
        return []
    }
    
    public func downloadTaskForGame(titleId: String) -> DownloadTaskItem? {
        activeCloudDownloads[titleId.uppercased()]
    }
    
    public func addCustomMagnetToGame(game: CompatibleGameItem, magnet: String) {
        let tid = game.titleId.uppercased()
        let cleanMagnet = magnet.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !cleanMagnet.isEmpty else { return }
        
        let customSource = CloudGameSource(
            id: UUID(),
            name: "Magnet Manual",
            urlString: cleanMagnet,
            isEnabled: true,
            lastSyncDate: Date(),
            lastItemCount: 1
        )
        let stream = CloudAvailableGame(
            titleId: tid,
            gameTitle: game.title,
            matchedVersion: game.versionTested,
            downloadURL: cleanMagnet,
            isTorrent: true,
            fileSizeFormatted: "",
            sourceId: customSource.id,
            sourceName: "Magnet Manual"
        )
        if cloudStreamsByTitleId[tid] == nil {
            cloudStreamsByTitleId[tid] = []
        }
        cloudStreamsByTitleId[tid]?.insert(stream, at: 0)
        cloudAvailableGames[tid] = stream
        startDownloadingCloudGame(stream)
    }
    
    // MARK: - Download Action
    public func startDownloadingCompatibleGame(game: CompatibleGameItem) {
        let tid = game.titleId.uppercased()
        guard let cloudGame = cloudAvailableGames[tid] else { return }
        startDownloadingCloudGame(cloudGame)
    }
    
    public func startDownloadingCloudGame(_ cloudGame: CloudAvailableGame) {
        let tid = cloudGame.titleId.uppercased()
        SoundEffectService.shared.play(.click)
        
        let downloadsFolder = FileManager.default.urls(for: .downloadsDirectory, in: .userDomainMask).first ?? URL(fileURLWithPath: NSHomeDirectory()).appendingPathComponent("Downloads")
        let nxDownloads = downloadsFolder.appendingPathComponent("NxNative")
        try? FileManager.default.createDirectory(at: nxDownloads, withIntermediateDirectories: true)
        
        DownloadEngineService.shared.startDownload(
            game: cloudGame,
            destinationDirectory: nxDownloads,
            onProgress: { [weak self] task in
                DispatchQueue.main.async {
                    self?.activeCloudDownloads[tid] = task
                }
            },
            onCompletion: { [weak self] result in
                DispatchQueue.main.async {
                    guard let self = self else { return }
                    self.activeCloudDownloads.removeValue(forKey: tid)
                    
                    switch result {
                    case .success(let downloadedURL):
                        SoundEffectService.shared.play(.click)
                        NSLog("[AppViewModel] Download concluído com sucesso: %@", downloadedURL.path)
                        
                        let ext = downloadedURL.pathExtension.lowercased()
                        if ext == "nsp" || ext == "xci" || ext == "nsz" || ext == "zip" {
                            self.handleDroppedURLs([downloadedURL], openPortModalForSingleGame: true)
                        }
                    case .failure(let error):
                        SoundEffectService.shared.play(.error)
                        NSLog("[AppViewModel] Erro no download do jogo (%@): %@", tid, error.localizedDescription)
                    }
                }
            }
        )
    }
    
    public func cancelCloudDownload(titleId: String) {
        let tid = titleId.uppercased()
        DownloadEngineService.shared.cancelDownload(titleId: tid)
        activeCloudDownloads.removeValue(forKey: tid)
        SoundEffectService.shared.play(.click)
    }
}
