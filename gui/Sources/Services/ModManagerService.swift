import Foundation
import AppKit

public struct GameModItem: Identifiable, Equatable {
    public let id: String
    public let name: String
    public let folderURL: URL
    public var isEnabled: Bool
    public let hasCodePatches: Bool
    public let hasAssetPatches: Bool
    public let resolvedRomfsURL: URL?
    public let sourcePath: String

    public init(
        id: String,
        name: String,
        folderURL: URL,
        isEnabled: Bool,
        hasCodePatches: Bool,
        hasAssetPatches: Bool,
        resolvedRomfsURL: URL? = nil,
        sourcePath: String = ""
    ) {
        self.id = id
        self.name = name
        self.folderURL = folderURL
        self.isEnabled = isEnabled
        self.hasCodePatches = hasCodePatches
        self.hasAssetPatches = hasAssetPatches
        self.resolvedRomfsURL = resolvedRomfsURL
        self.sourcePath = sourcePath
    }
}

public final class ModManagerService: ObservableObject {
    public static let shared = ModManagerService()
    private let fileManager = FileManager.default

    @Published public var refreshTrigger: Int = 0

    private init() {}

    /// Canonical primary directory for storing and installing mods for a specific game.
    public func modsDirectory(for titleId: String) -> URL {
        let dir = SystemDetector.shared.appSupportDirectory.appendingPathComponent("\(titleId.uppercased())/mods", isDirectory: true)
        try? fileManager.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    /// All directories searched for mods for maximum compatibility with nx2apple, standard nxnative, and portable game bundles.
    public func scanDirectories(for titleId: String, appURL: URL? = nil) -> [URL] {
        let cleanTid = titleId.uppercased()
        let lowerTid = titleId.lowercased()
        var dirs: [URL] = [modsDirectory(for: cleanTid)]

        let home = fileManager.homeDirectoryForCurrentUser
        let docsGamesUpper = home.appendingPathComponent("Documents/games/\(cleanTid)/mods", isDirectory: true)
        let docsGamesLower = home.appendingPathComponent("Documents/games/\(lowerTid)/mods", isDirectory: true)
        let stdAppSupUpper = home.appendingPathComponent("Library/Application Support/nxnative/\(cleanTid)/mods", isDirectory: true)
        let stdAppSupLower = home.appendingPathComponent("Library/Application Support/nxnative/\(lowerTid)/mods", isDirectory: true)

        for d in [docsGamesUpper, docsGamesLower, stdAppSupUpper, stdAppSupLower] {
            if !dirs.contains(where: { $0.standardizedFileURL.path == d.standardizedFileURL.path }) {
                dirs.append(d)
            }
        }

        if let app = appURL {
            let bundleMods = app.appendingPathComponent("Contents/Resources/mods", isDirectory: true)
            dirs.append(bundleMods)
        }

        return dirs
    }

    /// Resolves the actual RomFS asset directory inside a mod folder, supporting Atmosphere hierarchies, nested zip extractions, and loose asset folders.
    public func findRomfsFolder(in dir: URL, titleId: String, depth: Int = 0) -> URL? {
        if depth > 2 { return nil }
        let fm = fileManager
        let upperTid = titleId.uppercased()
        let lowerTid = titleId.lowercased()

        // 1. Direct candidate directories
        let directCandidates = [
            dir.appendingPathComponent("romfs", isDirectory: true),
            dir.appendingPathComponent("atmosphere/contents/\(upperTid)/romfs", isDirectory: true),
            dir.appendingPathComponent("atmosphere/contents/\(lowerTid)/romfs", isDirectory: true),
            dir.appendingPathComponent("contents/\(upperTid)/romfs", isDirectory: true),
            dir.appendingPathComponent("contents/\(lowerTid)/romfs", isDirectory: true)
        ]
        for c in directCandidates {
            var isDir: ObjCBool = false
            if fm.fileExists(atPath: c.path, isDirectory: &isDir) && isDir.boolValue {
                return c
            }
        }

        // 2. Generic atmosphere/contents/*/romfs or contents/*/romfs
        for containerName in ["atmosphere/contents", "contents"] {
            let container = dir.appendingPathComponent(containerName, isDirectory: true)
            if let subdirs = try? fm.contentsOfDirectory(at: container, includingPropertiesForKeys: [.isDirectoryKey]) {
                for sub in subdirs {
                    let subRomfs = sub.appendingPathComponent("romfs", isDirectory: true)
                    var isDir: ObjCBool = false
                    if fm.fileExists(atPath: subRomfs.path, isDirectory: &isDir) && isDir.boolValue {
                        return subRomfs
                    }
                }
            }
        }

        // 3. Loose asset folders check:
        // Detect known Nintendo Switch RomFS top-level directory names or resource extensions
        let knownRomfsDirs: Set<String> = [
            "actor", "anim", "animation", "audio", "bg", "bootup", "camera", "common", "data",
            "effect", "event", "font", "font2", "gamedata", "layout", "map", "message", "model",
            "movie", "nav", "pack", "param", "particles", "physics", "player", "region", "resource",
            "scene", "sound", "stage", "stream", "system", "terrain", "text", "texture", "ui", "voice"
        ]
        if let entries = try? fm.contentsOfDirectory(atPath: dir.path) {
            let clean = entries.filter { !$0.hasPrefix(".") }
            let hasKnownDir = clean.contains { knownRomfsDirs.contains($0.lowercased()) }
            let hasAssetExt = clean.contains {
                let ext = ($0 as NSString).pathExtension.lowercased()
                return ["zs", "blarc", "bntx", "bfotf", "sarc", "bars", "bfres", "bwav", "pack", "szs", "arc"].contains(ext)
            }
            let codeOnly = !clean.isEmpty && clean.allSatisfy { ["exefs", "patches", "main.npdm", "subsdk"].contains($0.lowercased()) }
            if (hasKnownDir || hasAssetExt) && !codeOnly {
                return dir
            }
        }

        // 4. Check if immediate children contain a wrapper folder (e.g., zip extracted as <mod>/<inner>/romfs)
        if let children = try? fm.contentsOfDirectory(at: dir, includingPropertiesForKeys: [.isDirectoryKey]) {
            let childDirs = children.filter { child in
                var isDir: ObjCBool = false
                let name = child.lastPathComponent.lowercased()
                return !name.hasPrefix(".") &&
                       fm.fileExists(atPath: child.path, isDirectory: &isDir) && isDir.boolValue &&
                       !["atmosphere", "contents", "exefs", "romfs"].contains(name) &&
                       !knownRomfsDirs.contains(name)
            }
            for child in childDirs {
                if let found = findRomfsFolder(in: child, titleId: titleId, depth: depth + 1) {
                    return found
                }
            }
        }

        return nil
    }

    /// Detects if a mod contains Switch code/executable patches (exefs)
    public func findExefsFolder(in dir: URL, titleId: String) -> URL? {
        let fm = fileManager
        let upperTid = titleId.uppercased()
        let lowerTid = titleId.lowercased()

        let candidates = [
            dir.appendingPathComponent("exefs", isDirectory: true),
            dir.appendingPathComponent("atmosphere/contents/\(upperTid)/exefs", isDirectory: true),
            dir.appendingPathComponent("atmosphere/contents/\(lowerTid)/exefs", isDirectory: true),
            dir.appendingPathComponent("contents/\(upperTid)/exefs", isDirectory: true),
            dir.appendingPathComponent("contents/\(lowerTid)/exefs", isDirectory: true),
            dir.appendingPathComponent("patches", isDirectory: true)
        ]
        for c in candidates {
            var isDir: ObjCBool = false
            if fm.fileExists(atPath: c.path, isDirectory: &isDir) && isDir.boolValue {
                return c
            }
        }
        return nil
    }

    public func discoverMods(for titleId: String, appURL: URL? = nil) -> [GameModItem] {
        let searchDirs = scanDirectories(for: titleId, appURL: appURL)
        var results: [GameModItem] = []
        var seenIds = Set<String>()

        for dir in searchDirs {
            guard let entries = try? fileManager.contentsOfDirectory(at: dir, includingPropertiesForKeys: [.isDirectoryKey]) else {
                continue
            }
            for url in entries {
                var isDir: ObjCBool = false
                guard fileManager.fileExists(atPath: url.path, isDirectory: &isDir), isDir.boolValue else { continue }

                let rawName = url.lastPathComponent
                if rawName.hasPrefix(".") { continue }

                let isDisabled = rawName.hasSuffix(".disabled")
                let cleanName = isDisabled ? String(rawName.dropLast(9)) : rawName

                if seenIds.contains(cleanName) { continue }
                seenIds.insert(cleanName)

                let resolvedRomfs = findRomfsFolder(in: url, titleId: titleId)
                let resolvedExefs = findExefsFolder(in: url, titleId: titleId)

                results.append(
                    GameModItem(
                        id: cleanName,
                        name: cleanName.replacingOccurrences(of: "_", with: " "),
                        folderURL: url,
                        isEnabled: !isDisabled,
                        hasCodePatches: resolvedExefs != nil,
                        hasAssetPatches: resolvedRomfs != nil,
                        resolvedRomfsURL: resolvedRomfs,
                        sourcePath: url.path
                    )
                )
            }
        }
        return results.sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
    }

    /// Builds the colon-separated `DM_ROMFS_OVERLAY` string for all active mods in alphabetical order.
    /// Preserves internal game bundle overlays (`<app>/Contents/Resources/romfs_overlay`) as a fallback layer.
    public func buildRomfsOverlayString(for titleId: String, appURL: URL? = nil) -> String? {
        let mods = discoverMods(for: titleId, appURL: appURL)
        var overlayPaths: [String] = []

        for mod in mods where mod.isEnabled {
            if let romfs = mod.resolvedRomfsURL {
                let path = romfs.standardizedFileURL.path
                if !overlayPaths.contains(path) {
                    overlayPaths.append(path)
                }
            }
        }

        // If the app bundle has an internal romfs_overlay (e.g. OoT dynamic resolution presets),
        // append it as the final fallback layer so built-in engine optimizations continue working alongside user mods.
        if let app = appURL {
            let bundleOverlay = app.appendingPathComponent("Contents/Resources/romfs_overlay", isDirectory: true)
            var isDir: ObjCBool = false
            if fileManager.fileExists(atPath: bundleOverlay.path, isDirectory: &isDir), isDir.boolValue {
                let bPath = bundleOverlay.standardizedFileURL.path
                if !overlayPaths.contains(bPath) {
                    overlayPaths.append(bPath)
                }
            }
        }

        if overlayPaths.isEmpty {
            return nil
        }
        return overlayPaths.joined(separator: ":")
    }

    public func toggleMod(_ mod: GameModItem, in titleId: String) -> Bool {
        let parent = mod.folderURL.deletingLastPathComponent()
        let isCurrentlyDisabled = mod.folderURL.lastPathComponent.hasSuffix(".disabled")
        let baseName = isCurrentlyDisabled ? String(mod.folderURL.lastPathComponent.dropLast(9)) : mod.folderURL.lastPathComponent
        let newName = isCurrentlyDisabled ? baseName : "\(baseName).disabled"
        let targetURL = parent.appendingPathComponent(newName)

        do {
            try fileManager.moveItem(at: mod.folderURL, to: targetURL)
            DispatchQueue.main.async {
                self.refreshTrigger += 1
            }
            return true
        } catch {
            return false
        }
    }

    public func deleteMod(_ mod: GameModItem) -> Bool {
        do {
            try fileManager.removeItem(at: mod.folderURL)
            DispatchQueue.main.async {
                self.refreshTrigger += 1
            }
            return true
        } catch {
            return false
        }
    }

    /// Installs a mod archive (.zip) or folder into the primary game mods directory.
    public func installMod(from sourceURL: URL, for titleId: String, completion: @escaping (Result<GameModItem, Error>) -> Void) {
        let targetParent = modsDirectory(for: titleId)
        let ext = sourceURL.pathExtension.lowercased()
        let rawBaseName = sourceURL.deletingPathExtension().lastPathComponent
        let cleanBaseName = rawBaseName.trimmingCharacters(in: .whitespacesAndNewlines).replacingOccurrences(of: "/", with: "-")
        let destDir = targetParent.appendingPathComponent(cleanBaseName, isDirectory: true)

        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            guard let self = self else { return }
            do {
                if self.fileManager.fileExists(atPath: destDir.path) {
                    try? self.fileManager.removeItem(at: destDir)
                }

                if ext == "zip" {
                    try self.fileManager.createDirectory(at: destDir, withIntermediateDirectories: true)
                    let success = self.runProcessWithTimeout(
                        executable: "/usr/bin/unzip",
                        arguments: ["-q", "-o", sourceURL.path, "-d", destDir.path],
                        timeoutSeconds: 8.0
                    )
                    guard success else {
                        try? self.fileManager.removeItem(at: destDir)
                        throw NSError(domain: "NxNative.ModManager", code: -1, userInfo: [NSLocalizedDescriptionKey: "Failed to unzip mod archive."])
                    }
                } else {
                    var isDir: ObjCBool = false
                    if self.fileManager.fileExists(atPath: sourceURL.path, isDirectory: &isDir), isDir.boolValue {
                        try self.fileManager.copyItem(at: sourceURL, to: destDir)
                    } else {
                        throw NSError(domain: "NxNative.ModManager", code: -2, userInfo: [NSLocalizedDescriptionKey: "Selected item is neither a zip file nor a folder."])
                    }
                }

                let discovered = self.discoverMods(for: titleId)
                let installedItem = discovered.first(where: { $0.id == cleanBaseName }) ??
                    GameModItem(
                        id: cleanBaseName,
                        name: cleanBaseName.replacingOccurrences(of: "_", with: " "),
                        folderURL: destDir,
                        isEnabled: true,
                        hasCodePatches: self.findExefsFolder(in: destDir, titleId: titleId) != nil,
                        hasAssetPatches: self.findRomfsFolder(in: destDir, titleId: titleId) != nil,
                        resolvedRomfsURL: self.findRomfsFolder(in: destDir, titleId: titleId),
                        sourcePath: destDir.path
                    )

                DispatchQueue.main.async {
                    self.refreshTrigger += 1
                    completion(.success(installedItem))
                }
            } catch {
                DispatchQueue.main.async {
                    completion(.failure(error))
                }
            }
        }
    }

    private func runProcessWithTimeout(executable: String, arguments: [String], timeoutSeconds: Double = 5.0) -> Bool {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: executable)
        process.arguments = arguments
        process.standardOutput = Pipe()
        process.standardError = Pipe()

        do {
            try process.run()
        } catch {
            return false
        }

        let deadline = Date().addingTimeInterval(timeoutSeconds)
        while process.isRunning && Date() < deadline {
            Thread.sleep(forTimeInterval: 0.05)
        }

        if process.isRunning {
            process.terminate()
            return false
        }

        return process.terminationStatus == 0
    }

    public func openModsFolder(for titleId: String) {
        let dir = modsDirectory(for: titleId)
        NSWorkspace.shared.open(dir)
    }
}
