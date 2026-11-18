import Foundation
import AppKit
import UniformTypeIdentifiers

public final class GameFilePickerDelegate: NSObject, NSOpenSavePanelDelegate {
    public static let sharedWithApps = GameFilePickerDelegate(allowApps: true)
    public static let sharedRomsOnly = GameFilePickerDelegate(allowApps: false)

    private let allowedExtensions: Set<String>
    private let allowApps: Bool

    public init(allowApps: Bool) {
        self.allowApps = allowApps
        var exts: Set<String> = ["nsp", "nsz", "nzs", "xci", "xcz", "nup", "nca", "zip"]
        if allowApps {
            exts.insert("app")
            exts.insert("ipa")
        }
        self.allowedExtensions = exts
        super.init()
    }

    public func panel(_ sender: Any, shouldEnable url: URL) -> Bool {
        let clean = url.standardizedFileURL
        let ext = clean.pathExtension.lowercased()
        if allowedExtensions.contains(ext) {
            return true
        }
        var isDir: ObjCBool = false
        guard FileManager.default.fileExists(atPath: clean.path, isDirectory: &isDir) else {
            return false
        }
        if isDir.boolValue {
            if ext == "app" {
                return allowApps
            }
            let excludedBundleExts: Set<String> = ["framework", "xcarchive", "bundle", "plugin", "kext", "dSYM"]
            if excludedBundleExts.contains(ext) {
                return false
            }
            return true
        }
        return false
    }
}

extension AppViewModel {
    /// Supported UTI types for Drag & Drop onto Library and Port drop areas
    public static let acceptedDropTypes: [UTType] = [
        .fileURL,
        .application,
        .package,
        .folder,
        .item
    ]

    /// Robust multi-source URL extractor from NSItemProviders supporting .app packages, folders and ROMs
    public static func extractURLs(from providers: [NSItemProvider], completion: @escaping ([URL]) -> Void) {
        var collectedURLs: [URL] = []
        let group = DispatchGroup()
        let lock = NSLock()

        for provider in providers {
            group.enter()

            // 1. Try public.file-url first (most reliable for files, packages, and apps in Finder)
            if provider.hasItemConformingToTypeIdentifier(UTType.fileURL.identifier) {
                provider.loadItem(forTypeIdentifier: UTType.fileURL.identifier, options: nil) { item, _ in
                    defer { group.leave() }
                    var resolvedURL: URL? = nil
                    if let url = item as? URL {
                        resolvedURL = url.standardizedFileURL
                    } else if let nsurl = item as? NSURL {
                        resolvedURL = (nsurl as URL).standardizedFileURL
                    } else if let data = item as? Data {
                        if let u = URL(dataRepresentation: data, relativeTo: nil) {
                            resolvedURL = u.standardizedFileURL
                        } else if let str = String(data: data, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines) {
                            if str.hasPrefix("file://"), let u = URL(string: str) {
                                resolvedURL = u.standardizedFileURL
                            } else if FileManager.default.fileExists(atPath: str) {
                                resolvedURL = URL(fileURLWithPath: str).standardizedFileURL
                            }
                        }
                    } else if let str = item as? String {
                        let trimmed = str.trimmingCharacters(in: .whitespacesAndNewlines)
                        if trimmed.hasPrefix("file://"), let u = URL(string: trimmed) {
                            resolvedURL = u.standardizedFileURL
                        } else if FileManager.default.fileExists(atPath: trimmed) {
                            resolvedURL = URL(fileURLWithPath: trimmed).standardizedFileURL
                        }
                    }
                    if let u = resolvedURL {
                        lock.lock()
                        collectedURLs.append(u)
                        lock.unlock()
                    }
                }
                continue
            }

            // 2. Try URL.self object loader
            if provider.canLoadObject(ofClass: URL.self) {
                _ = provider.loadObject(ofClass: URL.self) { url, _ in
                    defer { group.leave() }
                    if let u = url {
                        lock.lock()
                        collectedURLs.append(u)
                        lock.unlock()
                    }
                }
                continue
            }

            // 3. Fallback: plain text (e.g. dragged file path string)
            let textType = UTType.plainText.identifier
            if provider.hasItemConformingToTypeIdentifier(textType) {
                provider.loadItem(forTypeIdentifier: textType, options: nil) { item, _ in
                    defer { group.leave() }
                    if let str = item as? String {
                        let trimmed = str.trimmingCharacters(in: .whitespacesAndNewlines)
                        var resolvedURL: URL? = nil
                        if trimmed.hasPrefix("file://"), let u = URL(string: trimmed) {
                            resolvedURL = u
                        } else if FileManager.default.fileExists(atPath: trimmed) {
                            resolvedURL = URL(fileURLWithPath: trimmed)
                        }
                        if let u = resolvedURL {
                            lock.lock()
                            collectedURLs.append(u)
                            lock.unlock()
                        }
                    }
                }
                continue
            }

            group.leave()
        }

        group.notify(queue: .main) {
            completion(collectedURLs)
        }
    }

    // MARK: - Unified Game / ROM / NUP / Folder Picker
    public func openUnifiedGamePicker() {
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
        panel.message = tr("library.empty_drop_subtitle")

        if panel.runModal() == .OK {
            handleDroppedURLs(panel.urls, openPortModalForSingleGame: true)
        }
    }

    // MARK: - Native Mac Game Folders (Non-Switch Games)
    public func addNonSwitchGameFolder(_ url: URL, autoRefresh: Bool = true) {
        let standardized = url.standardizedFileURL
        if !nonSwitchGameFolders.contains(where: { $0.standardizedFileURL.path == standardized.path }) {
            nonSwitchGameFolders.append(standardized)
        }
        if !gameFolders.contains(where: { $0.standardizedFileURL.path == standardized.path }) {
            gameFolders.append(standardized)
        }
        if autoRefresh {
            DispatchQueue.main.async {
                self.refreshLibrary()
                self.scanAllGameFolders()
            }
        }
    }

    public func removeNonSwitchGameFolder(_ url: URL) {
        let path = url.standardizedFileURL.path
        nonSwitchGameFolders.removeAll { $0.standardizedFileURL.path == path }
        refreshLibrary()
    }

    public func clearAllNonSwitchGameFolders() {
        nonSwitchGameFolders.removeAll()
        refreshLibrary()
    }

    public func selectAdditionalNonSwitchGameFolder() {
        let panel = NSOpenPanel()
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.allowsMultipleSelection = true
        panel.prompt = tr("system.add_folder")
        panel.message = tr("system.select_nonswitch_folder_message")

        if panel.runModal() == .OK {
            for url in panel.urls {
                addNonSwitchGameFolder(url, autoRefresh: false)
            }
            refreshLibrary()
        }
    }

    public func selectSingleNonSwitchGameFile() {
        let panel = NSOpenPanel()
        panel.canChooseFiles = true
        panel.canChooseDirectories = false
        panel.allowsMultipleSelection = true
        panel.treatsFilePackagesAsDirectories = false
        panel.allowedContentTypes = [.application, .package]
        panel.delegate = GameFilePickerDelegate.sharedWithApps
        panel.prompt = tr("system.add_nonswitch_single_app")
        panel.message = tr("system.select_nonswitch_app_message")

        if panel.runModal() == .OK {
            handleDroppedURLs(panel.urls, openPortModalForSingleGame: false)
        }
    }

    // MARK: - Drag and Drop & ZIP
    public func handleDroppedURLs(_ urls: [URL], openPortModalForSingleGame: Bool = false) {
        dropErrorMessage = nil
        let isSingleItem = (urls.count == 1)
        let romExts: Set<String> = ["nsp", "nsz", "nzs", "xci", "xcz", "nup", "nca"]
        var addedAppURLs: [URL] = []
        var addedFolders: [URL] = []

        for rawURL in urls {
            let url = rawURL.standardizedFileURL
            var isDir: ObjCBool = false
            guard FileManager.default.fileExists(atPath: url.path, isDirectory: &isDir) else { continue }
            
            let ext = url.pathExtension.lowercased()
            if ext == "app" {
                addNonSwitchGame(url: url, autoRefresh: false)
                addedAppURLs.append(url)
            } else if ext == "zip" {
                extractDroppedZip(zipURL: url)
            } else if isDir.boolValue {
                let isDumpDir = GameScanner.shared.inspectDumpFolder(url: url) != nil ||
                                FileManager.default.fileExists(atPath: url.appendingPathComponent("base/exefs/main.npdm").path) ||
                                FileManager.default.fileExists(atPath: url.appendingPathComponent("exefs/main.npdm").path)
                if isDumpDir {
                    addGameFolder(
                        url.deletingLastPathComponent(),
                        preferredFileURL: url,
                        openPortModalIfFound: isSingleItem && (openPortModalForSingleGame || selectedTab == 0)
                    )
                } else {
                    addNonSwitchGameFolder(url, autoRefresh: false)
                    addGameFolder(
                        url,
                        preferredFolderURL: isSingleItem ? url : nil,
                        openPortModalIfFound: isSingleItem && openPortModalForSingleGame
                    )
                    addedFolders.append(url)
                }
            } else if romExts.contains(ext) {
                let parent = url.deletingLastPathComponent()
                addNonSwitchGameFolder(parent, autoRefresh: false)
                addGameFolder(
                    parent,
                    preferredFileURL: url,
                    openPortModalIfFound: isSingleItem && (openPortModalForSingleGame || selectedTab == 0)
                )
            } else {
                let parent = url.deletingLastPathComponent()
                addNonSwitchGameFolder(parent, autoRefresh: false)
                addGameFolder(parent)
            }
        }
        
        if !addedAppURLs.isEmpty || !addedFolders.isEmpty {
            DispatchQueue.main.async {
                self.selectedTab = 0
                self.refreshLibrary(focusOnOutputURL: addedAppURLs.first)
                SoundEffectService.shared.play(.click)
                if let first = addedAppURLs.first {
                    let name = first.deletingPathExtension().lastPathComponent
                    let count = addedAppURLs.count
                    let msg = count == 1 ? "Added \(name) to Library." : "Added \(count) applications to Library."
                    self.logs.append(LogEntry(level: .success, message: msg))
                } else if let firstFolder = addedFolders.first {
                    self.logs.append(LogEntry(level: .success, message: "Added folder \(firstFolder.lastPathComponent) to Library."))
                }
            }
        }
    }
    
    private func containsMacApps(in directory: URL) -> Bool {
        guard let enumerator = FileManager.default.enumerator(
            at: directory,
            includingPropertiesForKeys: [.isDirectoryKey],
            options: [.skipsHiddenFiles, .skipsPackageDescendants]
        ) else { return false }
        
        var count = 0
        for case let fileURL as URL in enumerator {
            count += 1
            if count > 2000 { break }
            if fileURL.pathExtension.lowercased() == "app" {
                return true
            }
        }
        return false
    }

    private func containsSwitchRoms(in directory: URL) -> Bool {
        if GameScanner.shared.inspectDumpFolder(url: directory) != nil ||
           FileManager.default.fileExists(atPath: directory.appendingPathComponent("base/exefs/main.npdm").path) ||
           FileManager.default.fileExists(atPath: directory.appendingPathComponent("exefs/main.npdm").path) {
            return true
        }
        guard let enumerator = FileManager.default.enumerator(
            at: directory,
            includingPropertiesForKeys: [.isDirectoryKey],
            options: [.skipsHiddenFiles, .skipsPackageDescendants]
        ) else { return false }
        
        let romExts: Set<String> = ["nsp", "nsz", "nzs", "xci", "xcz", "nup", "nca"]
        var count = 0
        for case let fileURL as URL in enumerator {
            count += 1
            if count > 2000 { break }
            if romExts.contains(fileURL.pathExtension.lowercased()) {
                return true
            }
            if GameScanner.shared.inspectDumpFolder(url: fileURL) != nil ||
               FileManager.default.fileExists(atPath: fileURL.appendingPathComponent("base/exefs/main.npdm").path) ||
               FileManager.default.fileExists(atPath: fileURL.appendingPathComponent("exefs/main.npdm").path) {
                return true
            }
        }
        return false
    }
    
    private func extractDroppedZip(zipURL: URL) {
        let gamesDir = URL(fileURLWithPath: defaultInstallPath).appendingPathComponent("Games")
        isExtractingZip = true
        zipExtractionMessage = "Analyzing ZIP archive..."
        
        ZipExtractor.shared.extract(
            zipURL: zipURL,
            destinationFolder: gamesDir,
            progressCallback: { [weak self] msg in
                self?.zipExtractionMessage = msg
            },
            completion: { [weak self] result in
                guard let self = self else { return }
                self.isExtractingZip = false
                
                switch result {
                case .success(let extractedDir):
                    self.selectedGameFolder = extractedDir
                    self.logs.append(LogEntry(level: .success, message: "Archive extracted to: \(extractedDir.path)"))
                case .failure(let error):
                    self.dropErrorMessage = error.localizedDescription
                    self.logs.append(LogEntry(level: .error, message: "Failed to extract archive: \(error.localizedDescription)"))
                }
            }
        )
    }
}
