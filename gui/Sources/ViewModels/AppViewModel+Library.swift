import Foundation
import AppKit
import UniformTypeIdentifiers

private var isSwitchingToManualOrder = false

extension AppViewModel {
    /// Switches from alphabetical sorting to manual/persisted order without re-sorting over a live drag-and-drop move.
    public func activateManualOrderMode() {
        guard activeSortOption != .lastPlayed else { return }
        isSwitchingToManualOrder = true
        activeSortOption = .lastPlayed
        isSwitchingToManualOrder = false
    }

    // MARK: - Library Operations (Privacy-guarded)
    private var libraryCacheURL: URL {
        let appSupport = SystemDetector.shared.appSupportDirectory
        return appSupport.appendingPathComponent("library_cache.json")
    }

    public func loadLibraryCache() {
        guard let data = try? Data(contentsOf: libraryCacheURL),
              let cached = try? JSONDecoder().decode([PortedGame].self, from: data),
              !cached.isEmpty else {
            return
        }
        let visible = LibraryOrder.apply(to: cached.filter {
            !self.hiddenGamePaths.contains($0.url.standardized.path) &&
            !self.removedGamePaths.contains($0.url.standardized.path)
        })
        self.libraryGames = visible
        self.reconcileLibraryFocusState()
    }

    public func saveLibraryCache(games: [PortedGame]) {
        DispatchQueue.global(qos: .utility).async {
            guard let data = try? JSONEncoder().encode(games) else { return }
            try? data.write(to: self.libraryCacheURL, options: .atomic)
        }
    }

    public func refreshLibrary(focusOnOutputURL: URL? = nil) {
        isScanningLibrary = true
        var searchDirs: [URL] = []
        
        let root = URL(fileURLWithPath: defaultInstallPath)
        let gamesDir = root.appendingPathComponent("Games")
        searchDirs.append(gamesDir)

        let nxPortsDir = URL(fileURLWithPath: "/Volumes/SSD FN501 PRO/Emulations/Nx Ports")
        if FileManager.default.fileExists(atPath: nxPortsDir.path) {
            searchDirs.append(nxPortsDir)
        }
        
        if let custom = libraryFolder, custom.path != "/" && custom.path != gamesDir.path {
            searchDirs.append(custom)
        }
        
        if useCustomOutputFolder, let customOut = customOutputFolder {
            let stdOut = customOut.standardizedFileURL
            if !searchDirs.contains(where: { $0.standardizedFileURL.path == stdOut.path }) {
                searchDirs.append(stdOut)
            }
        }
        
        for folder in nonSwitchGameFolders {
            let std = folder.standardizedFileURL
            if !searchDirs.contains(where: { $0.standardizedFileURL.path == std.path }) {
                searchDirs.append(std)
            }
        }
        
        for folder in gameFolders {
            let std = folder.standardizedFileURL
            if !searchDirs.contains(where: { $0.standardizedFileURL.path == std.path }) {
                searchDirs.append(std)
            }
        }
        
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            guard let self = self else { return }
            let extraURLs = self.savedNonSwitchAppPaths.map { URL(fileURLWithPath: $0) }
            let games = LibraryScanner.shared.scan(directories: searchDirs, extraAppURLs: extraURLs)
            DispatchQueue.main.async {
                let visible = LibraryOrder.apply(to: games.filter {
                    !self.hiddenGamePaths.contains($0.url.standardized.path) &&
                    !self.removedGamePaths.contains($0.url.standardized.path)
                })
                self.libraryGames = visible
                self.saveLibraryCache(games: visible)
                self.reconcileLibraryFocusState(preferredPortedURL: focusOnOutputURL)
                self.isScanningLibrary = false
                
                // Automatically ensure every game in the library has its correct official cover, input mapping, and folder icons
                DispatchQueue.global(qos: .utility).async {
                    InputProfileManager.shared.exportActiveMappingToDisk(libraryFolder: self.libraryFolder)
                    for game in visible {
                        GameCoverService.shared.ensureCover(for: game)
                        if GameRuntimeConfig.isOotGame(game) {
                            _ = GameRuntimeConfig.load(for: game)
                        }
                    }
                    SaveSyncService.shared.cleanupLegacyCloudSaveFolders(games: visible)
                    SaveSyncService.shared.refreshAllFolderIcons(games: visible)
                    DeviceDeploymentService.shared.syncInstalledApps(with: visible)
                    MemoryOptimizer.shared.scheduleIdleOptimization(viewModel: self, delay: 2.0, purgeThumbnails: false)
                }
            }
        }
    }

    public func selectLibraryFolder() {
        let panel = NSOpenPanel()
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.allowsMultipleSelection = false
        panel.prompt = "Select Library Folder"
        panel.message = "Choose a folder containing your built Mac Apps or IPAs."
        
        if panel.runModal() == .OK, let url = panel.url {
            self.libraryFolder = url
            if self.useCustomOutputFolder {
                self.customOutputFolder = url
            }
            self.defaultInstallPath = SystemDetector.shared.resolveRootDirectory().path
            refreshLibrary()
        }
    }
    
    public func revealInFinder(url: URL) {
        NSWorkspace.shared.activateFileViewerSelecting([url])
    }
    
    public func revealSaveFolder(_ url: URL) {
        let fm = FileManager.default
        if !fm.fileExists(atPath: url.path) {
            try? fm.createDirectory(at: url, withIntermediateDirectories: true)
        }
        if let game = self.libraryGames.first(where: {
            guard let tid = $0.titleId?.uppercased() else { return false }
            return url.path.uppercased().contains(tid)
        }) {
            SaveSyncService.shared.applySaveDirectoryIcons(for: game)
        }
        NSWorkspace.shared.activateFileViewerSelecting([url])
    }
    
    public func hideGameFromLibrary(_ game: PortedGame) {
        hiddenGamePaths.insert(game.url.standardized.path)
        SoundEffectService.shared.play(.click)
        logs.append(LogEntry(level: .info, message: "Hidden from library: \(game.name) (can be restored in Settings)"))
        refreshLibrary()
    }

    public func removeGameFromLibrary(_ game: PortedGame) {
        let stdPath = game.url.standardized.path
        removedGamePaths.insert(stdPath)
        hiddenGamePaths.remove(stdPath)
        savedNonSwitchAppPaths.removeAll { $0 == stdPath || $0 == game.url.path }
        SoundEffectService.shared.play(.click)
        logs.append(LogEntry(level: .warning, message: "Removed from library: \(game.name) (files preserved on disk)"))
        refreshLibrary()
    }

    public func restoreHiddenGame(path: String) {
        hiddenGamePaths.remove(path)
        SoundEffectService.shared.play(.click)
        logs.append(LogEntry(level: .success, message: "Restored game to library"))
        refreshLibrary()
    }

    public func restoreAllHiddenGames() {
        let count = hiddenGamePaths.count
        hiddenGamePaths.removeAll()
        SoundEffectService.shared.play(.click)
        logs.append(LogEntry(level: .success, message: "Restored \(count) hidden games to library"))
        refreshLibrary()
    }

    public func restoreAllRemovedGames() {
        let count = removedGamePaths.count
        removedGamePaths.removeAll()
        SoundEffectService.shared.play(.click)
        logs.append(LogEntry(level: .success, message: "Restored \(count) removed games to library"))
        refreshLibrary()
    }

    public func deleteGameToTrash(_ game: PortedGame) {
        do {
            var resultingURL: NSURL?
            try FileManager.default.trashItem(at: game.url, resultingItemURL: &resultingURL)
            hiddenGamePaths.remove(game.url.standardized.path)
            removedGamePaths.remove(game.url.standardized.path)
            savedNonSwitchAppPaths.removeAll { $0 == game.url.standardized.path || $0 == game.url.path }
            ArtworkStore.shared.clearCache(for: game)
            SoundEffectService.shared.play(.click)
            logs.append(LogEntry(level: .warning, message: "Moved game to Trash: \(game.name)"))
            refreshLibrary()
        } catch {
            SoundEffectService.shared.play(.error)
            logs.append(LogEntry(level: .error, message: "Failed to move game to Trash: \(error.localizedDescription)"))
        }
    }

    public func deletePortedGame(_ game: PortedGame) { deleteGameToTrash(game) }
    
    // MARK: - Multiple Game Folders & Subfolder Scanning
    public func addGameFolder(
        _ url: URL,
        preferredFileURL: URL? = nil,
        preferredFolderURL: URL? = nil,
        openPortModalIfFound: Bool = false
    ) {
        var isDir: ObjCBool = false
        let clean = url.standardizedFileURL
        let exists = FileManager.default.fileExists(atPath: clean.path, isDirectory: &isDir)
        let folderURL: URL
        let targetFileURL: URL?
        if exists && !isDir.boolValue {
            folderURL = clean.deletingLastPathComponent().standardizedFileURL
            targetFileURL = preferredFileURL ?? clean
        } else if clean.pathExtension.lowercased() == "app" {
            folderURL = clean.deletingLastPathComponent().standardizedFileURL
            targetFileURL = preferredFileURL ?? clean
            addNonSwitchGame(url: clean, autoRefresh: false)
        } else {
            folderURL = clean
            targetFileURL = preferredFileURL
        }

        if !gameFolders.contains(where: { $0.standardizedFileURL.path == folderURL.path }) {
            gameFolders.append(folderURL)
        }
        if !nonSwitchGameFolders.contains(where: { $0.standardizedFileURL.path == folderURL.path }) {
            nonSwitchGameFolders.append(folderURL)
        }
        isUpdatingSelectedGameFolderFromAdd = true
        selectedGameFolder = folderURL
        isUpdatingSelectedGameFolderFromAdd = false

        scanAllGameFolders(
            preferredFileURL: targetFileURL,
            preferredFolderURL: preferredFolderURL ?? (isDir.boolValue ? folderURL : nil),
            openPortModalIfFound: openPortModalIfFound
        )
        refreshLibrary(focusOnOutputURL: targetFileURL)
    }
    
    public func removeGameFolder(_ url: URL) {
        let path = url.standardizedFileURL.path
        gameFolders.removeAll { $0.standardizedFileURL.path == path }
        if selectedGameFolder?.standardizedFileURL.path == path {
            isUpdatingSelectedGameFolderFromAdd = true
            selectedGameFolder = gameFolders.first
            isUpdatingSelectedGameFolderFromAdd = false
        }
        scanAllGameFolders()
    }
    
    public func scanAllGameFolders(
        preferredFileURL: URL? = nil,
        preferredFolderURL: URL? = nil,
        openPortModalIfFound: Bool = false
    ) {
        var allFolders = gameFolders
        for folder in nonSwitchGameFolders {
            let std = folder.standardizedFileURL
            if !allFolders.contains(where: { $0.standardizedFileURL.path == std.path }) {
                allFolders.append(std)
            }
        }
        guard !allFolders.isEmpty || preferredFileURL != nil else {
            detectedFiles = []
            detectedGames = []
            if !isBuilding {
                selectedGame = nil
            }
            reconcileLibraryFocusState()
            return
        }
        let folders = allFolders
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            var files = GameScanner.shared.scan(directories: folders)
            if let prefFile = preferredFileURL {
                let prefStdPath = prefFile.standardizedFileURL.path
                if !files.contains(where: { $0.url.standardizedFileURL.path == prefStdPath }) {
                    let extraItems = GameScanner.shared.scan(directory: prefFile)
                    for item in extraItems where !files.contains(where: { $0.url.standardizedFileURL.path == item.url.standardizedFileURL.path }) {
                        files.append(item)
                    }
                }
            }
            let games = GameScanner.shared.groupFilesIntoGames(files: files)
            DispatchQueue.main.async {
                guard let self = self else { return }
                self.detectedFiles = files
                self.detectedGames = games
                if !self.isBuilding {
                    var explicitlyMatched: SelectableGame? = nil
                    if let prefFile = preferredFileURL {
                        let prefStdPath = prefFile.standardizedFileURL.path
                        explicitlyMatched = games.first(where: { game in
                            game.files.contains(where: { $0.url.standardizedFileURL.path == prefStdPath })
                        })
                    } else if let prefFolder = preferredFolderURL {
                        let folderPrefix = prefFolder.standardizedFileURL.path
                        let gamesInFolder = games.filter { game in
                            game.files.contains { file in
                                let filePath = file.url.standardizedFileURL.path
                                return filePath == folderPrefix || filePath.hasPrefix(folderPrefix + "/")
                            }
                        }
                        explicitlyMatched = gamesInFolder.first(where: { !self.isGameAlreadyPorted($0) }) ?? gamesInFolder.first
                    }

                    if let matched = explicitlyMatched {
                        self.selectedGame = matched
                        self.appName = matched.name
                        if let uIdx = self.unportedGames.firstIndex(where: { $0.id == matched.id }) {
                            self.activeLibraryShelf = .unportedSwitch
                            self.focusedUnportedGameIndex = uIdx
                        }
                        if openPortModalIfFound && self.selectedTab == 0 {
                            self.gameForPortModal = matched
                        }
                    } else {
                        if self.selectedGame == nil || !games.contains(where: { $0.id == self.selectedGame?.id }) {
                            self.selectedGame = self.unportedGames.first ?? games.first
                        }
                        if let firstGame = (self.unportedGames.first ?? games.first), self.appName.isEmpty {
                            self.appName = firstGame.name
                        }
                    }
                }
                self.reconcileLibraryFocusState()
            }
        }
    }
    
    public func scanGameFolder(_ folder: URL) {
        addGameFolder(folder)
    }
    
    public func selectAdditionalGameFolder() {
        let panel = NSOpenPanel()
        panel.canChooseFiles = true
        panel.canChooseDirectories = true
        panel.allowsMultipleSelection = true
        panel.treatsFilePackagesAsDirectories = false
        panel.delegate = GameFilePickerDelegate.sharedWithApps
        
        var allowedTypes: [UTType] = [.application, .package, .folder, .zip]
        for ext in ["nsp", "nsz", "nzs", "xci", "xcz", "nup", "nca", "ipa"] {
            if let t = UTType(filenameExtension: ext) {
                allowedTypes.append(t)
            }
        }
        panel.allowedContentTypes = allowedTypes
        
        panel.prompt = tr("common.choose")
        panel.message = "Select game files (.nsp, .nsz, .nzs, .xci, .xcz, .nup, .nca, .app) or folders holding them."
        
        if panel.runModal() == .OK {
            handleDroppedURLs(panel.urls, openPortModalForSingleGame: selectedTab == 0)
        }
    }
    
    // MARK: - Sorting Helpers & Unified Items
    public func resetLibraryOrganization() {
        activeGroupFilter = .categories
        activeSortOption = .lastPlayed
        applyActiveSorting()
    }

    public func applyActiveSorting() {
        guard !isSwitchingToManualOrder else { return }
        switch activeSortOption {
        case .lastPlayed:
            libraryGames.sort { a, b in
                let dateA = lastPlayedDate(for: a) ?? Date.distantPast
                let dateB = lastPlayedDate(for: b) ?? Date.distantPast
                if dateA != dateB {
                    return dateA > dateB
                }
                return a.modificationDate > b.modificationDate
            }
            detectedGames.sort { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
        case .name:
            libraryGames.sort { a, b in
                a.name.localizedStandardCompare(b.name) == .orderedAscending
            }
            detectedGames.sort { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
        }
        LibraryOrder.save(libraryGames)
        reconcileLibraryFocusState()
    }

    public func sortGames(_ games: [PortedGame]) -> [PortedGame] {
        switch activeSortOption {
        case .lastPlayed:
            return games.sorted { a, b in
                let dateA = lastPlayedDate(for: a) ?? Date.distantPast
                let dateB = lastPlayedDate(for: b) ?? Date.distantPast
                if dateA != dateB {
                    return dateA > dateB
                }
                return a.modificationDate > b.modificationDate
            }
        case .name:
            return games.sorted { a, b in
                a.name.localizedStandardCompare(b.name) == .orderedAscending
            }
        }
    }
    
    public func sortUnportedGames(_ games: [SelectableGame]) -> [SelectableGame] {
        return games.sorted { a, b in
            a.name.localizedStandardCompare(b.name) == .orderedAscending
        }
    }

    // MARK: - Game Deduplication & Unification Helpers
    public func deduplicationKey(for game: PortedGame) -> String {
        if let tid = game.titleId?.uppercased().trimmingCharacters(in: .whitespacesAndNewlines), !tid.isEmpty {
            return tid
        }
        return GameScanner.shared.cleanGameTitle(game.name).lowercased()
    }

    public func deduplicationKey(for unported: SelectableGame) -> String {
        if let tid = unported.titleId?.uppercased().trimmingCharacters(in: .whitespacesAndNewlines), !tid.isEmpty {
            return tid
        }
        return GameScanner.shared.cleanGameTitle(unported.name).lowercased()
    }

    public func macPort(for game: PortedGame) -> PortedGame? {
        if game.isPlayableLocally { return game }
        let key = deduplicationKey(for: game)
        return libraryGames.first { $0.isPlayableLocally && deduplicationKey(for: $0) == key }
    }

    public func iosPort(for game: PortedGame) -> PortedGame? {
        if game.platform == .ios { return game }
        let key = deduplicationKey(for: game)
        return libraryGames.first { $0.platform == .ios && deduplicationKey(for: $0) == key }
    }

    public func unportedGame(for game: PortedGame) -> SelectableGame? {
        let key = deduplicationKey(for: game)
        return unportedGames.first { deduplicationKey(for: $0) == key }
    }

    public func openPortModal(for game: PortedGame, targetPlatform: TargetPlatform) {
        self.platform = targetPlatform
        if let u = unportedGame(for: game) {
            self.selectedGame = u
            self.gameForPortModal = u
        } else {
            let dummy = SelectableGame(
                id: game.uniqueKey,
                name: game.name,
                titleId: game.titleId,
                files: []
            )
            self.selectedGame = dummy
            self.gameForPortModal = dummy
        }
    }

    public func unifiedItems(for games: [PortedGame]) -> [UnifiedLibraryItem] {
        let query = librarySearchText.trimmingCharacters(in: .whitespacesAndNewlines)
        var combined: [UnifiedLibraryItem] = []
        var seenKeys = Set<String>()

        // 1. Process ported games (prefer local macApp/nonSwitch first so primary launch button is Play)
        let sortedPorted = games.sorted { (a, b) -> Bool in
            if a.isPlayableLocally && !b.isPlayableLocally { return true }
            if !a.isPlayableLocally && b.isPlayableLocally { return false }
            return a.name.localizedStandardCompare(b.name) == .orderedAscending
        }

        for game in sortedPorted {
            let key = deduplicationKey(for: game)
            if !key.isEmpty {
                if seenKeys.contains(key) { continue }
                seenKeys.insert(key)
            }
            combined.append(.ported(game))
        }

        // 2. Process unported games (ROMs) - exclude games that are already ported
        for unported in unportedGames {
            let key = deduplicationKey(for: unported)
            if !key.isEmpty {
                if seenKeys.contains(key) { continue }
                seenKeys.insert(key)
            }
            combined.append(.unported(unported))
        }

        // 3. Search filter
        if !query.isEmpty {
            combined = combined.filter { item in
                switch item {
                case .ported(let g):
                    return g.name.localizedCaseInsensitiveContains(query) ||
                           (g.titleId?.localizedCaseInsensitiveContains(query) == true)
                case .unported(let u):
                    return u.name.localizedCaseInsensitiveContains(query) ||
                           (u.titleId?.localizedCaseInsensitiveContains(query) == true)
                }
            }
        }

        // 4. Sort
        switch activeSortOption {
        case .name:
            combined.sort { a, b in
                a.name.localizedStandardCompare(b.name) == .orderedAscending
            }
        case .lastPlayed:
            combined = LibraryOrder.applyUnified(to: combined)
        }

        return combined
    }
}
