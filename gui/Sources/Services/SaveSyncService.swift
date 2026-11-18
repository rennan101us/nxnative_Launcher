import Foundation
import AppKit

public struct SaveComparisonInfo: Equatable {
    public let macSaveURL: URL
    public let macModificationDate: Date?
    public let macFileCount: Int
    public let hasDeviceSave: Bool
}

public final class SaveSyncService: ObservableObject {
    public static let shared = SaveSyncService()
    internal let fileManager = FileManager.default
    internal var cloudSyncActiveCache: [String: Bool] = [:]

    private static let iCloudSyncEnabledKey = "nxnative_icloud_sync_enabled"

    @Published public private(set) var isICloudDriveAvailable: Bool = false

    /// User setting controlling whether iCloud Sync and Cross-Save is enabled.
    /// Defaults to false to prevent unprompted consumption of users' iCloud quotas.
    @Published public var isICloudSyncEnabled: Bool {
        didSet {
            UserDefaults.standard.set(isICloudSyncEnabled, forKey: Self.iCloudSyncEnabledKey)
            cloudSyncActiveCache.removeAll()
            if !isICloudSyncEnabled {
                _ = disableCloudSyncAndRevertLocal()
            }
            DispatchQueue.main.async { self.objectWillChange.send() }
        }
    }

    private init() {
        self.isICloudSyncEnabled = UserDefaults.standard.object(forKey: Self.iCloudSyncEnabledKey) as? Bool ?? false
        checkICloudAvailability()
    }

    public func invalidateCloudSyncCache() {
        cloudSyncActiveCache.removeAll()
    }

    public func checkICloudAvailability() {
        let docs = fileManager.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Mobile Documents/com~apple~CloudDocs", isDirectory: true)
        self.isICloudDriveAvailable = fileManager.fileExists(atPath: docs.path)
    }

    // MARK: - iCloud Root Directory
    public var iCloudRootURL: URL {
        fileManager.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Mobile Documents/com~apple~CloudDocs/nxnative_launcher", isDirectory: true)
    }

    public func ensureRootFolderConfigured() {
        guard isICloudDriveAvailable else { return }
        let root = iCloudRootURL
        if !fileManager.fileExists(atPath: root.path) {
            try? fileManager.createDirectory(at: root, withIntermediateDirectories: true)
        }
        // Set official NxNative Launcher application icon on the root folder
        if let appIcon = NSApp.applicationIconImage {
            applyFolderIcon(image: appIcon, folderURL: root)
        }
    }

    // MARK: - Game iCloud Directories
    public func sanitizedGameName(_ game: PortedGame) -> String {
        let safe = game.name.replacingOccurrences(of: "[:/\\\\?*\"<>|]", with: " ", options: .regularExpression)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return safe.isEmpty ? (game.titleId ?? "UnknownGame") : safe
    }

    public func iCloudFolder(for game: PortedGame) -> URL {
        if let titleId = game.titleId, !titleId.isEmpty {
            return iCloudRootURL.appendingPathComponent(titleId.uppercased(), isDirectory: true)
        }
        let safe = sanitizedGameName(game)
        return iCloudRootURL.appendingPathComponent(safe.isEmpty ? "UnknownGame" : safe, isDirectory: true)
    }

    public func iCloudSaveDirectory(for game: PortedGame) -> URL {
        iCloudFolder(for: game).appendingPathComponent("save", isDirectory: true)
    }

    // MARK: - Per-Game iCloud Sync Configuration
    public func isICloudSyncEnabled(for game: PortedGame) -> Bool {
        guard isICloudDriveAvailable else { return false }
        let key = "nxnative_icloud_game_\(game.uniqueKey)"
        if let val = UserDefaults.standard.object(forKey: key) as? Bool {
            return val
        }
        if let titleId = game.titleId, !titleId.isEmpty {
            let titleKey = "nxnative_icloud_title_\(titleId.uppercased())"
            if let val = UserDefaults.standard.object(forKey: titleKey) as? Bool {
                return val
            }
            // Check if local save is already an active symlink into iCloud
            let localDir = macSaveDirectory(for: titleId)
            if let dest = try? fileManager.destinationOfSymbolicLink(atPath: localDir.path) {
                if dest.contains("nxnative_launcher") || dest.contains("CloudDocs") {
                    return true
                }
            }
        }
        return false
    }

    public func setICloudSyncEnabled(_ enabled: Bool, for game: PortedGame, cover: NSImage? = nil) {
        let key = "nxnative_icloud_game_\(game.uniqueKey)"
        UserDefaults.standard.set(enabled, forKey: key)
        if let titleId = game.titleId, !titleId.isEmpty {
            UserDefaults.standard.set(enabled, forKey: "nxnative_icloud_title_\(titleId.uppercased())")
        }
        cloudSyncActiveCache.removeValue(forKey: game.uniqueKey)

        if enabled {
            if !isICloudSyncEnabled {
                self.isICloudSyncEnabled = true
            }
            _ = ensureCloudSaveConfigured(for: game, cover: cover)
        } else {
            if let titleId = game.titleId {
                revertToLocalSave(for: titleId, game: game)
            }
        }
        DispatchQueue.main.async {
            self.objectWillChange.send()
        }
    }

    public func isCloudSyncActive(for game: PortedGame) -> Bool {
        guard isICloudDriveAvailable && isICloudSyncEnabled(for: game) else {
            return false
        }
        let key = game.uniqueKey
        if let cached = cloudSyncActiveCache[key] {
            return cached
        }
        guard let titleId = game.titleId, !titleId.isEmpty else {
            cloudSyncActiveCache[key] = false
            return false
        }
        let localDir = macSaveDirectory(for: titleId)
        
        var isDir: ObjCBool = false
        if fileManager.fileExists(atPath: localDir.path, isDirectory: &isDir) {
            if let dest = try? fileManager.destinationOfSymbolicLink(atPath: localDir.path) {
                if dest.contains("nxnative_launcher") || dest.contains("CloudDocs") {
                    cloudSyncActiveCache[key] = true
                    return true
                }
            }
        }
        
        let cloudDir = iCloudSaveDirectory(for: game)
        let active = fileManager.fileExists(atPath: cloudDir.path)
        cloudSyncActiveCache[key] = active
        return active
    }

    // MARK: - Safe Setup & Migration
    @discardableResult
    public func ensureCloudSaveConfigured(for game: PortedGame, cover: NSImage?) -> Result<URL, Error> {
        guard isICloudDriveAvailable else {
            return .failure(NSError(domain: "SaveSyncService", code: 403, userInfo: [NSLocalizedDescriptionKey: "iCloud Drive is not available on this Mac"]))
        }
        ensureRootFolderConfigured()
        let gameFolder = iCloudFolder(for: game)
        let cloudSaveDir = iCloudSaveDirectory(for: game)

        do {
            try fileManager.createDirectory(at: cloudSaveDir, withIntermediateDirectories: true)

            // Pre-flight writability check verifying macOS TCC permits write access to this iCloud path
            let probeFile = cloudSaveDir.appendingPathComponent(".probe_\(UUID().uuidString)")
            do {
                try "probe".write(to: probeFile, atomically: true, encoding: .utf8)
                try fileManager.removeItem(at: probeFile)
            } catch {
                if let titleId = game.titleId {
                    revertToLocalSave(for: titleId)
                }
                return .failure(NSError(
                    domain: "SaveSyncService",
                    code: Int(EPERM),
                    userInfo: [NSLocalizedDescriptionKey: "iCloud Drive write permission denied or inaccessible (errno=1 EPERM). Safely reverting to local save storage."]
                ))
            }

            // Apply game's box art cover as custom folder icon in Finder and iCloud Drive
            if let coverImage = cover ?? GameCoverService.shared.coverImage(for: game) {
                applyFolderIcon(image: coverImage, folderURL: gameFolder)
            }

            guard let titleId = game.titleId, !titleId.isEmpty else {
                return .success(cloudSaveDir)
            }

            let upperTitle = titleId.uppercased()

            // 0. Synchronize with mobile save.dmsync if present (ensures iPhone's newer saves are pulled)
            syncWithCloudDMSyncIfNeeded(for: game)

            // v1.8.5 created symlink aliases here; iCloud Drive does not sync symlinks, so the iPhone never saw them.
            // The iPhone reads <root>/<TITLE_ID>/save.dmsync as a real folder (writeDMSync).
            for alias in [iCloudRootURL.appendingPathComponent(upperTitle), gameFolder.appendingPathComponent(upperTitle)] {
                if (try? fileManager.destinationOfSymbolicLink(atPath: alias.path)) != nil {
                    try? fileManager.removeItem(at: alias)
                }
            }

            let localSave = macSaveDirectory(for: titleId)
            let isSymlink: Bool = (try? fileManager.destinationOfSymbolicLink(atPath: localSave.path)) != nil

            // If local directory exists and is NOT a symlink, migrate existing saves to iCloud
            if fileManager.fileExists(atPath: localSave.path) && !isSymlink {
                _ = backupMacSave(titleId: titleId)
                try copyDirectoryContents(from: localSave, to: cloudSaveDir)
                // Safely remove local folder so ONLY the iCloud save exists (single copy, no duplicates)
                try? fileManager.removeItem(at: localSave)
            } else if isSymlink {
                // Remove legacy symlink if previously present
                try? fileManager.removeItem(at: localSave)
            } else if !fileManager.fileExists(atPath: localSave.path) {
                // Also check save.work in case it has uncommitted saves
                let workDir = SystemDetector.shared.appSupportDirectory.appendingPathComponent("\(upperTitle)/save.work", isDirectory: true)
                if fileManager.fileExists(atPath: workDir.path) {
                    try? copyDirectoryContents(from: workDir, to: cloudSaveDir)
                    try? fileManager.removeItem(at: workDir)
                }
            }

            // Write DM_SAVE and DM_SAVE_SYNC into env.txt so games run exclusively against iCloud
            updateEnvFileWithCloudSave(titleId: titleId, cloudSavePath: cloudSaveDir.path, cloudSyncPath: iCloudRootURL.path)

            // Make the save readable by the iPhone app right away, without waiting for the Mac game to run and exit.
            if case .failure(let err) = writeDMSync(for: game) {
                NSLog("[iCloud] save.dmsync not written: %@", err.localizedDescription)
            }

            // Stamp folder icons on iCloud folders and local title folder
            applySaveDirectoryIcons(for: game)

            cloudSyncActiveCache[game.uniqueKey] = true
            DispatchQueue.main.async { self.objectWillChange.send() }
            return .success(cloudSaveDir)
        } catch {
            if let titleId = game.titleId {
                revertToLocalSave(for: titleId, game: game)
            }
            return .failure(error)
        }
    }

    public func copyDirectoryContents(from srcDir: URL, to dstDir: URL) throws {
        try fileManager.createDirectory(at: dstDir, withIntermediateDirectories: true)
        let entries = (try? fileManager.contentsOfDirectory(at: srcDir, includingPropertiesForKeys: nil, options: [])) ?? []
        for entry in entries {
            let destEntry = dstDir.appendingPathComponent(entry.lastPathComponent)
            var isDir: ObjCBool = false
            if fileManager.fileExists(atPath: entry.path, isDirectory: &isDir) {
                if isDir.boolValue {
                    try copyDirectoryContents(from: entry, to: destEntry)
                } else {
                    if fileManager.fileExists(atPath: destEntry.path) {
                        try? fileManager.removeItem(at: destEntry)
                    }
                    try fileManager.copyItem(at: entry, to: destEntry)
                }
            }
        }
    }

    /// Reverts an individual game from iCloud back to a genuine local directory in Application Support.
    public func revertToLocalSave(for titleId: String, game: PortedGame? = nil) {
        let upperTitle = titleId.uppercased()
        let titleFolder = SystemDetector.shared.appSupportDirectory.appendingPathComponent(upperTitle, isDirectory: true)
        let saveFolder = titleFolder.appendingPathComponent("save", isDirectory: true)
        
        // 1. Remove any legacy symlink at saveFolder
        if (try? fileManager.destinationOfSymbolicLink(atPath: saveFolder.path)) != nil {
            try? fileManager.removeItem(at: saveFolder)
        }
        try? fileManager.createDirectory(at: saveFolder, withIntermediateDirectories: true)
        
        // 2. Identify cloud save source
        var candidateCloudSaveDirs: [URL] = []
        if let g = game {
            candidateCloudSaveDirs.append(iCloudSaveDirectory(for: g))
        }
        candidateCloudSaveDirs.append(iCloudRootURL.appendingPathComponent(upperTitle, isDirectory: true).appendingPathComponent("save", isDirectory: true))
        
        if let existing = locateExistingSave(titleId: titleId, gameName: game?.name),
           (existing.path.contains("CloudDocs") || existing.path.contains("nxnative_launcher")) {
            var isDir: ObjCBool = false
            if fileManager.fileExists(atPath: existing.path, isDirectory: &isDir), isDir.boolValue {
                candidateCloudSaveDirs.insert(existing, at: 0)
            }
        }
        
        for cloudDir in candidateCloudSaveDirs {
            if fileManager.fileExists(atPath: cloudDir.path) {
                try? copyDirectoryContents(from: cloudDir, to: saveFolder)
                // Clean up cloud save folder so only the local copy remains active
                try? fileManager.removeItem(at: cloudDir)
                break
            }
        }
        
        // 3. Clean DM_SAVE and DM_SAVE_SYNC in env.txt
        let envFile = titleFolder.appendingPathComponent("env.txt")
        if let existing = try? String(contentsOf: envFile, encoding: .utf8) {
            let cleaned = existing.components(separatedBy: .newlines)
                .filter { !$0.hasPrefix("DM_SAVE=") && !$0.hasPrefix("DM_SAVE_SYNC=") }
                .joined(separator: "\n")
            try? cleaned.write(to: envFile, atomically: true, encoding: .utf8)
        }
        
        // 4. Update folder icons on the local save folder
        if let g = game {
            applySaveDirectoryIcons(for: g)
        }
    }

    private func updateEnvFileWithCloudSave(titleId: String, cloudSavePath: String, cloudSyncPath: String? = nil) {
        let envFile = SystemDetector.shared.appSupportDirectory.appendingPathComponent("\(titleId.uppercased())/env.txt")
        var lines: [String] = []
        if let existing = try? String(contentsOf: envFile, encoding: .utf8) {
            lines = existing.components(separatedBy: .newlines).filter { 
                !$0.hasPrefix("DM_SAVE=") && !$0.hasPrefix("DM_SAVE_SYNC=") 
            }
        }
        lines.append("DM_SAVE=\(cloudSavePath)")
        if let syncPath = cloudSyncPath, !syncPath.isEmpty {
            lines.append("DM_SAVE_SYNC=\(syncPath)")
        }
        try? lines.joined(separator: "\n").write(to: envFile, atomically: true, encoding: .utf8)
    }

    // MARK: - Folder Icon Customization
    public func createFolderIconWithCover(coverImage: NSImage) -> NSImage? {
        let width = 512
        let height = 512
        let size = NSSize(width: width, height: height)

        // Render into an explicit 32-bit RGBA bitmap rep (never lockFocus) so IconServices/CarbonCore
        // receives a valid self-contained CGImage-backed representation without EXC_GUARD or Resource Manager faults.
        guard let bitmapRep = NSBitmapImageRep(
            bitmapDataPlanes: nil,
            pixelsWide: width,
            pixelsHigh: height,
            bitsPerSample: 8,
            samplesPerPixel: 4,
            hasAlpha: true,
            isPlanar: false,
            colorSpaceName: .deviceRGB,
            bytesPerRow: width * 4,
            bitsPerPixel: 32
        ), let ctx = NSGraphicsContext(bitmapImageRep: bitmapRep) else {
            return nil
        }

        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = ctx
        defer { NSGraphicsContext.restoreGraphicsState() }

        // 1. Base macOS folder icon
        let folderIcon = NSWorkspace.shared.icon(for: .folder)
        folderIcon.size = size
        folderIcon.draw(in: NSRect(origin: .zero, size: size), from: .zero, operation: .sourceOver, fraction: 1.0)

        // 2. Front pocket badge positioning for standard macOS folder
        let badgeSize: CGFloat = 185
        let badgeX: CGFloat = (size.width - badgeSize) / 2
        let badgeY: CGFloat = 118
        let badgeRect = NSRect(x: badgeX, y: badgeY, width: badgeSize, height: badgeSize)
        let cornerRadius: CGFloat = 36
        let clipPath = NSBezierPath(roundedRect: badgeRect, xRadius: cornerRadius, yRadius: cornerRadius)

        // Drop shadow for the badge
        NSGraphicsContext.saveGraphicsState()
        let shadow = NSShadow()
        shadow.shadowColor = NSColor.black.withAlphaComponent(0.42)
        shadow.shadowOffset = NSSize(width: 0, height: -3)
        shadow.shadowBlurRadius = 7
        shadow.set()
        NSColor.black.withAlphaComponent(0.3).setFill()
        clipPath.fill()
        NSGraphicsContext.restoreGraphicsState()

        // Clip and draw cover image inside badge with aspect fill & centering (no squishing/stretching)
        NSGraphicsContext.saveGraphicsState()
        clipPath.addClip()
        let imgSize = coverImage.size
        if imgSize.width > 0 && imgSize.height > 0 {
            let scale = max(badgeRect.width / imgSize.width, badgeRect.height / imgSize.height)
            let scaledW = imgSize.width * scale
            let scaledH = imgSize.height * scale
            let drawX = badgeRect.origin.x + (badgeRect.width - scaledW) / 2
            let drawY = badgeRect.origin.y + (badgeRect.height - scaledH) / 2
            let drawRect = NSRect(x: drawX, y: drawY, width: scaledW, height: scaledH)
            coverImage.draw(in: drawRect, from: .zero, operation: .sourceOver, fraction: 1.0)
        } else {
            coverImage.draw(in: badgeRect, from: .zero, operation: .sourceOver, fraction: 1.0)
        }
        NSGraphicsContext.restoreGraphicsState()

        // Subtle specular border around badge
        NSGraphicsContext.saveGraphicsState()
        NSColor.white.withAlphaComponent(0.24).setStroke()
        clipPath.lineWidth = 1.2
        clipPath.stroke()
        NSGraphicsContext.restoreGraphicsState()

        guard bitmapRep.cgImage != nil else { return nil }
        let composite = NSImage(size: size)
        composite.addRepresentation(bitmapRep)
        return composite
    }

    @discardableResult
    public func applyFolderIcon(image: NSImage?, folderURL: URL) -> Bool {
        guard let img = image, img.size.width > 0, img.size.height > 0 else { return false }

        let applyOnMain: () -> Bool = {
            autoreleasepool {
                let fm = FileManager.default
                var isDir: ObjCBool = false
                guard fm.fileExists(atPath: folderURL.path, isDirectory: &isDir),
                      isDir.boolValue,
                      fm.isWritableFile(atPath: folderURL.path),
                      let composite = self.createFolderIconWithCover(coverImage: img) else {
                    return false
                }
                return NSWorkspace.shared.setIcon(composite, forFile: folderURL.path, options: [])
            }
        }

        // Serialize AppKit/IconServices/CarbonCore setIcon calls strictly on the main thread
        if Thread.isMainThread {
            return applyOnMain()
        } else {
            DispatchQueue.main.async {
                _ = applyOnMain()
            }
            return true
        }
    }

    /// Stamps save directories for a game with a custom folder badge containing the game's icon/cover
    public func applySaveDirectoryIcons(for game: PortedGame) {
        // Use the exact same icon/cover displayed in My Tab View (Library)
        let coverImg = ArtworkStore.shared.loadSquareIcon(for: game)

        let fm = fileManager
        let appSup = SystemDetector.shared.appSupportDirectory
        if let titleId = game.titleId, !titleId.isEmpty {
            let upperTitle = titleId.uppercased()

            // 1. Current App Support title directory and save directory
            let titleDir = appSup.appendingPathComponent(upperTitle, isDirectory: true)
            if fm.fileExists(atPath: titleDir.path) {
                applyFolderIcon(image: coverImg, folderURL: titleDir)
            }
            let saveDir = titleDir.appendingPathComponent("save", isDirectory: true)
            if fm.fileExists(atPath: saveDir.path) {
                applyFolderIcon(image: coverImg, folderURL: saveDir)
            }

            // 2. Default App Support directory if user configured a custom location
            let defAppSup = SystemDetector.shared.defaultAppSupportDirectory
            if defAppSup.path != appSup.path {
                let defTitleDir = defAppSup.appendingPathComponent(upperTitle, isDirectory: true)
                if fm.fileExists(atPath: defTitleDir.path) {
                    applyFolderIcon(image: coverImg, folderURL: defTitleDir)
                }
                let defSaveDir = defTitleDir.appendingPathComponent("save", isDirectory: true)
                if fm.fileExists(atPath: defSaveDir.path) {
                    applyFolderIcon(image: coverImg, folderURL: defSaveDir)
                }
            }

            // 3. Custom / alternate save location if configured ("caso o save seja em outro lugar")
            let resolvedSave = resolvedSaveDirectory(forTitleId: upperTitle)
            if resolvedSave.path != saveDir.path && fm.fileExists(atPath: resolvedSave.path) {
                applyFolderIcon(image: coverImg, folderURL: resolvedSave)
                let parentDir = resolvedSave.deletingLastPathComponent()
                if fm.fileExists(atPath: parentDir.path) {
                    applyFolderIcon(image: coverImg, folderURL: parentDir)
                }
            }

            // 4. iCloud Title ID folder (used for mobile and cross-save)
            if isICloudDriveAvailable {
                let cloudTitleDir = iCloudRootURL.appendingPathComponent(upperTitle, isDirectory: true)
                if fm.fileExists(atPath: cloudTitleDir.path) {
                    applyFolderIcon(image: coverImg, folderURL: cloudTitleDir)
                }
                let cloudSaveDir = cloudTitleDir.appendingPathComponent("save", isDirectory: true)
                if fm.fileExists(atPath: cloudSaveDir.path) {
                    applyFolderIcon(image: coverImg, folderURL: cloudSaveDir)
                }
            }
        }
    }

    /// Asynchronously refreshes folder badges across all games in the library and iCloud folders
    public func refreshAllFolderIcons(games: [PortedGame]) {
        DispatchQueue.global(qos: .utility).async { [weak self] in
            guard let self = self else { return }
            for game in games {
                self.applySaveDirectoryIcons(for: game)
            }

            // Also scan all folders in iCloudRootURL and stamp any Title ID folder!
            guard self.isICloudDriveAvailable else { return }
            let root = self.iCloudRootURL
            guard let items = try? self.fileManager.contentsOfDirectory(atPath: root.path) else { return }
            for item in items {
                guard !item.hasPrefix(".") && item != "Icon\r" && item != "Ports" && item != "ports" else { continue }
                let folderURL = root.appendingPathComponent(item, isDirectory: true)
                var isDir: ObjCBool = false
                guard self.fileManager.fileExists(atPath: folderURL.path, isDirectory: &isDir), isDir.boolValue else { continue }

                // If it is a 16-hex Title ID (canonical cross-save folder)
                if item.count == 16 && item.allSatisfy({ $0.isHexDigit }) {
                    let tid = item.uppercased()
                    let cover = games.first(where: { $0.titleId?.uppercased() == tid }).map { ArtworkStore.shared.loadSquareIcon(for: $0) }
                        ?? ArtworkStore.shared.loadSquareIcon(titleId: tid, gameName: "")
                        ?? GameCoverService.shared.coverImage(titleId: tid, gameName: "")
                    if let cover = cover {
                        self.applyFolderIcon(image: cover, folderURL: folderURL)
                    }
                }
            }
        }
    }

    /// Automatically cleans up legacy human-readable folders from iCloud Drive (migrating/backing up saves safely)
    /// leaving exclusively the canonical 16-hex Title ID folders matching iOS and dmhost cross-save standards.
    public func cleanupLegacyCloudSaveFolders(games: [PortedGame]) {
        guard isICloudDriveAvailable else { return }
        let root = iCloudRootURL
        guard let items = try? fileManager.contentsOfDirectory(atPath: root.path) else { return }

        let appSup = SystemDetector.shared.appSupportDirectory
        let backupDir = appSup.appendingPathComponent("legacy_icloud_backups", isDirectory: true)

        for item in items {
            // Skip hidden items (.DS_Store, .probe, Icon\r) and system/protected folders
            guard !item.hasPrefix(".") && item != "Icon\r" && item != "Ports" && item != "ports" else { continue }
            let itemURL = root.appendingPathComponent(item, isDirectory: true)
            var isDir: ObjCBool = false
            guard fileManager.fileExists(atPath: itemURL.path, isDirectory: &isDir), isDir.boolValue else { continue }

            // If item is already a canonical 16-hex Title ID, skip it
            if item.count == 16 && item.allSatisfy({ $0.isHexDigit }) {
                continue
            }

            NSLog("[iCloud] Found legacy save folder to clean up: %@", item)

            // 1. Identify matching Title ID
            let matchingGame = games.first { game in
                sanitizedGameName(game).lowercased() == item.lowercased() ||
                game.name.lowercased() == item.lowercased() ||
                (game.titleId != nil && item.lowercased().contains(game.name.lowercased()))
            }
            let tid = matchingGame?.titleId?.uppercased()
                ?? CompatibilityService.shared.findTitleId(forGameTitle: item)?.uppercased()

            // 2. Check if legacy folder has a save directory
            let legacySaveDir = itemURL.appendingPathComponent("save", isDirectory: true)
            if fileManager.fileExists(atPath: legacySaveDir.path) {
                // Ensure local safety backup
                let destBackup = backupDir.appendingPathComponent(item, isDirectory: true)
                if !fileManager.fileExists(atPath: destBackup.path) {
                    try? fileManager.createDirectory(at: backupDir, withIntermediateDirectories: true)
                    try? fileManager.copyItem(at: itemURL, to: destBackup)
                }

                // If we have a matching Title ID, verify if canonical save exists
                if let upperTitle = tid {
                    let canonicalLocalSave = macSaveDirectory(for: upperTitle)
                    let cloudDMSync = root.appendingPathComponent("\(upperTitle)/save.dmsync")

                    let localCount = (try? fileManager.contentsOfDirectory(atPath: canonicalLocalSave.path).count) ?? 0
                    let hasDMSync = fileManager.fileExists(atPath: cloudDMSync.path)

                    if localCount == 0 && !hasDMSync {
                        try? fileManager.createDirectory(at: canonicalLocalSave, withIntermediateDirectories: true)
                        try? copyDirectoryContents(from: legacySaveDir, to: canonicalLocalSave)
                        if let g = matchingGame {
                            _ = writeDMSync(for: g)
                        }
                    }
                }
            }

            // 3. Remove legacy folder from iCloud Drive
            do {
                try fileManager.removeItem(at: itemURL)
                NSLog("[iCloud] Successfully removed legacy folder: %@", item)
            } catch {
                NSLog("[iCloud] Error removing legacy folder %@: %@", item, error.localizedDescription)
            }

            // 4. Clean up any env.txt referencing this legacy path or any iCloud path in DM_SAVE
            if let titles = try? fileManager.contentsOfDirectory(atPath: appSup.path) {
                for titleDirName in titles {
                    let envFile = appSup.appendingPathComponent("\(titleDirName)/env.txt")
                    if let content = try? String(contentsOf: envFile, encoding: .utf8) {
                        let lines = content.components(separatedBy: .newlines)
                        let filtered = lines.filter { line in
                            // Remove DM_SAVE if it points to iCloud/CloudDocs
                            if line.hasPrefix("DM_SAVE=") && (line.contains("CloudDocs") || line.contains("nxnative_launcher")) {
                                return false
                            }
                            return true
                        }
                        if filtered.count != lines.count {
                            try? filtered.joined(separator: "\n").write(to: envFile, atomically: true, encoding: .utf8)
                            NSLog("[iCloud] Cleaned legacy DM_SAVE from env.txt in %@", titleDirName)
                        }
                    }
                }
            }
        }
    }

    public func revealCloudGameFolder(for game: PortedGame, cover: NSImage?) {
        if isICloudSyncEnabled(for: game) && isICloudDriveAvailable {
            _ = ensureCloudSaveConfigured(for: game, cover: cover)
            let folder = iCloudFolder(for: game)
            applySaveDirectoryIcons(for: game)
            NSWorkspace.shared.activateFileViewerSelecting([folder])
        } else if let titleId = game.titleId {
            let local = macSaveDirectory(for: titleId)
            try? fileManager.createDirectory(at: local, withIntermediateDirectories: true)
            applySaveDirectoryIcons(for: game)
            NSWorkspace.shared.activateFileViewerSelecting([local])
        }
    }

    // MARK: - Safety Snapshots (Strictly Local Storage)
    @discardableResult
    public func createSafetySnapshot(for game: PortedGame, label: String = "auto") -> URL? {
        guard let titleId = game.titleId, !titleId.isEmpty else { return nil }
        let srcDir = resolvedSaveDirectory(forTitleId: titleId)
        guard fileManager.fileExists(atPath: srcDir.path) else { return nil }

        let backupsDir = SystemDetector.shared.appSupportDirectory.appendingPathComponent("\(titleId.uppercased())/backups", isDirectory: true)
        try? fileManager.createDirectory(at: backupsDir, withIntermediateDirectories: true)

        let timestamp = ISO8601DateFormatter().string(from: Date()).replacingOccurrences(of: ":", with: "-")
        let destination = backupsDir.appendingPathComponent("save_snapshot_\(timestamp)_\(label)")

        do {
            try fileManager.copyItem(at: srcDir, to: destination)
            pruneOldBackups(in: backupsDir, maxKeep: 5)
            return destination
        } catch {
            return nil
        }
    }

    // MARK: - Local Save Compatibility
    public func macSaveDirectory(for titleId: String) -> URL {
        let base = SystemDetector.shared.appSupportDirectory.appendingPathComponent(titleId.uppercased(), isDirectory: true)
        let saveDir = base.appendingPathComponent("save", isDirectory: true)
        let workDir = base.appendingPathComponent("save.work", isDirectory: true)

        if fileManager.fileExists(atPath: saveDir.path) {
            return saveDir
        }
        if fileManager.fileExists(atPath: workDir.path) {
            return workDir
        }
        return saveDir
    }

    public func resolvedSaveDirectory(forTitleId titleId: String) -> URL {
        let localDir = macSaveDirectory(for: titleId)
        if let dest = try? fileManager.destinationOfSymbolicLink(atPath: localDir.path) {
            return URL(fileURLWithPath: dest)
        }
        
        // If localDir already exists and has actual save files, use it directly
        let localEntries = ((try? fileManager.contentsOfDirectory(atPath: localDir.path)) ?? []).filter { $0 != ".DS_Store" && $0 != "Icon\r" }
        if !localEntries.isEmpty {
            return localDir
        }

        let envFile = SystemDetector.shared.appSupportDirectory.appendingPathComponent("\(titleId.uppercased())/env.txt")
        if let content = try? String(contentsOf: envFile, encoding: .utf8) {
            for line in content.components(separatedBy: .newlines) {
                if line.hasPrefix("DM_SAVE=") {
                    let path = String(line.dropFirst("DM_SAVE=".count)).trimmingCharacters(in: .whitespacesAndNewlines)
                    if !path.isEmpty && fileManager.fileExists(atPath: path) {
                        return URL(fileURLWithPath: path, isDirectory: true)
                    }
                }
            }
        }

        // Check alternate candidate locations where the save might reside (e.g. subfolder nxnative/ or default App Support)
        let upper = titleId.uppercased()
        let lower = titleId.lowercased()
        let candidates = [
            SystemDetector.shared.appSupportDirectory.appendingPathComponent("nxnative/\(lower)/save", isDirectory: true),
            SystemDetector.shared.appSupportDirectory.appendingPathComponent("nxnative/\(upper)/save", isDirectory: true),
            SystemDetector.shared.appSupportDirectory.appendingPathComponent("\(lower)/save", isDirectory: true),
            SystemDetector.shared.defaultAppSupportDirectory.appendingPathComponent("\(upper)/save", isDirectory: true),
            SystemDetector.shared.defaultAppSupportDirectory.appendingPathComponent("\(lower)/save", isDirectory: true),
            SystemDetector.shared.defaultAppSupportDirectory.appendingPathComponent("nxnative/\(lower)/save", isDirectory: true)
        ]

        for candidate in candidates {
            if candidate.standardizedFileURL.path != localDir.standardizedFileURL.path,
               let items = try? fileManager.contentsOfDirectory(atPath: candidate.path),
               !items.filter({ $0 != ".DS_Store" && $0 != "Icon\r" }).isEmpty {
                // Found candidate with actual save files! Copy into localDir so it's restored
                try? fileManager.createDirectory(at: localDir, withIntermediateDirectories: true)
                try? copyDirectoryContents(from: candidate, to: localDir)
                return localDir
            }
        }

        return localDir
    }

    public func inspectMacSave(for titleId: String) -> SaveComparisonInfo {
        let dir = resolvedSaveDirectory(forTitleId: titleId)
        guard fileManager.fileExists(atPath: dir.path) else {
            return SaveComparisonInfo(macSaveURL: dir, macModificationDate: nil, macFileCount: 0, hasDeviceSave: false)
        }

        let contents = (try? fileManager.contentsOfDirectory(atPath: dir.path)) ?? []
        let newest = contents.compactMap { name -> Date? in
            let path = dir.appendingPathComponent(name).path
            return (try? fileManager.attributesOfItem(atPath: path)[.modificationDate]) as? Date
        }.max()

        return SaveComparisonInfo(
            macSaveURL: dir,
            macModificationDate: newest,
            macFileCount: contents.count,
            hasDeviceSave: false
        )
    }

    public func backupMacSave(titleId: String) -> URL? {
        let saveDir = resolvedSaveDirectory(forTitleId: titleId)
        guard fileManager.fileExists(atPath: saveDir.path) else { return nil }

        let backupRoot = SystemDetector.shared.appSupportDirectory.appendingPathComponent("\(titleId.uppercased())/backups", isDirectory: true)
        try? fileManager.createDirectory(at: backupRoot, withIntermediateDirectories: true)

        let timestamp = ISO8601DateFormatter().string(from: Date()).replacingOccurrences(of: ":", with: "-")
        let destination = backupRoot.appendingPathComponent("save_backup_\(timestamp)")

        do {
            try fileManager.copyItem(at: saveDir, to: destination)
            pruneOldBackups(in: backupRoot, maxKeep: 5)
            return destination
        } catch {
            return nil
        }
    }

    // MARK: - Backup Retention & Pruning (Max 5 Snapshots)
    public func pruneOldBackups(in directory: URL, maxKeep: Int = 5) {
        guard let entries = try? fileManager.contentsOfDirectory(at: directory, includingPropertiesForKeys: [.contentModificationDateKey, .isDirectoryKey], options: .skipsHiddenFiles) else { return }
        
        let sorted = entries.sorted { a, b in
            let dateA = (try? a.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? Date.distantPast
            let dateB = (try? b.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? Date.distantPast
            return dateA > dateB // newest first
        }
        
        if sorted.count > maxKeep {
            for stale in sorted.dropFirst(maxKeep) {
                try? fileManager.removeItem(at: stale)
            }
        }
    }

    // MARK: - Safe iCloud Disabling & Reversion to Local Storage
    @discardableResult
    public func disableCloudSyncAndRevertLocal() -> Int {
        let nxRoot = SystemDetector.shared.appSupportDirectory
        guard let titleDirs = try? fileManager.contentsOfDirectory(atPath: nxRoot.path) else { return 0 }
        
        var revertedCount = 0
        for title in titleDirs {
            let titleFolder = nxRoot.appendingPathComponent(title, isDirectory: true)
            let saveFolder = titleFolder.appendingPathComponent("save", isDirectory: true)
            
            if let dest = try? fileManager.destinationOfSymbolicLink(atPath: saveFolder.path) {
                let cloudDestURL = URL(fileURLWithPath: dest)
                // Remove the symlink safely
                try? fileManager.removeItem(at: saveFolder)
                // Re-create genuine local directory
                try? fileManager.createDirectory(at: saveFolder, withIntermediateDirectories: true)
                // Copy files back from iCloud if available
                if fileManager.fileExists(atPath: cloudDestURL.path),
                   let contents = try? fileManager.contentsOfDirectory(atPath: cloudDestURL.path) {
                    for file in contents {
                        let src = cloudDestURL.appendingPathComponent(file)
                        let dst = saveFolder.appendingPathComponent(file)
                        try? fileManager.copyItem(at: src, to: dst)
                    }
                }
                revertedCount += 1
            }
            
            // Clean DM_SAVE in env.txt if present
            let envFile = titleFolder.appendingPathComponent("env.txt")
            if let existing = try? String(contentsOf: envFile, encoding: .utf8) {
                let cleaned = existing.components(separatedBy: .newlines)
                    .filter { !$0.hasPrefix("DM_SAVE=") }
                    .joined(separator: "\n")
                try? cleaned.write(to: envFile, atomically: true, encoding: .utf8)
            }
        }
        
        cloudSyncActiveCache.removeAll()
        return revertedCount
    }

    // MARK: - iCloud Storage Measurement & Reclamation
    public func calculateICloudStorageBytes() -> Int64 {
        guard isICloudDriveAvailable else { return 0 }
        let root = iCloudRootURL
        guard fileManager.fileExists(atPath: root.path) else { return 0 }
        
        guard let enumerator = fileManager.enumerator(at: root, includingPropertiesForKeys: [.fileSizeKey], options: []) else { return 0 }
        var total: Int64 = 0
        for case let fileURL as URL in enumerator {
            if let size = (try? fileURL.resourceValues(forKeys: [.fileSizeKey]))?.fileSize {
                total += Int64(size)
            }
        }
        return total
    }

    @discardableResult
    public func purgeICloudFolder() throws -> Int64 {
        let bytes = calculateICloudStorageBytes()
        let root = iCloudRootURL
        if fileManager.fileExists(atPath: root.path) {
            try fileManager.removeItem(at: root)
        }
        cloudSyncActiveCache.removeAll()
        DispatchQueue.main.async { self.objectWillChange.send() }
        return bytes
    }
}
