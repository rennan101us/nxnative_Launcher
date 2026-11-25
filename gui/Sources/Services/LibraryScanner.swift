import Foundation
import AppKit
import CryptoKit
import Darwin

public final class LibraryScanner {
    public static let shared = LibraryScanner()
    
    private var ipaMetadataCache: [String: (modDate: Date, ipaSize: Int64, game: PortedGame)] = [:]
    private var appSizeCache: [String: (modDate: Date, size: Int64)] = [:]
    private let cacheLock = NSLock()
    private let appSizeDefaultsKey = "nxnative_library_scanner_app_sizes_v2"
    
    private init() {
        if let saved = UserDefaults.standard.dictionary(forKey: appSizeDefaultsKey) as? [String: [Double]] {
            for (key, val) in saved {
                if val.count >= 2 {
                    appSizeCache[key] = (modDate: Date(timeIntervalSince1970: val[0]), size: Int64(val[1]))
                }
            }
        }
    }

    private func saveAppSizeCacheLocked() {
        var dict: [String: [Double]] = [:]
        for (key, val) in appSizeCache {
            dict[key] = [val.modDate.timeIntervalSince1970, Double(val.size)]
        }
        UserDefaults.standard.set(dict, forKey: appSizeDefaultsKey)
    }
    
    public func scan(directories: [URL], extraAppURLs: [URL] = []) -> [PortedGame] {
        let fm = FileManager.default
        var games: [PortedGame] = []
        var seenPaths = Set<String>()
        
        let home = NSHomeDirectory()
        let forbiddenPrefixes = [
            "/",
            home,
            home + "/Music",
            home + "/Pictures",
            home + "/Documents",
            home + "/Library"
        ]
        
        for dir in directories {
            let path = dir.standardizedFileURL.path
            
            // STRICT PRIVACY GUARD: Never scan filesystem root or user home folders directly
            if path == "/" || path == home || path.isEmpty {
                continue
            }
            
            // Don't scan forbidden media directories
            if forbiddenPrefixes.contains(where: { $0 == path && path != "/" }) {
                continue
            }
            
            guard fm.fileExists(atPath: path) else { continue }
            
            // If the folder itself is an .app package, parse it directly
            if dir.pathExtension.lowercased() == "app" {
                let stdPath = dir.standardizedFileURL.path
                if !seenPaths.contains(stdPath) {
                    if let game = parseMacApp(at: dir, isExplicit: true) {
                        seenPaths.insert(stdPath)
                        games.append(game)
                    }
                }
                continue
            }
            
            guard let enumerator = fm.enumerator(
                at: dir,
                includingPropertiesForKeys: [.isDirectoryKey, .contentModificationDateKey, .fileSizeKey],
                options: [.skipsHiddenFiles, .skipsPackageDescendants]
            ) else { continue }
            
            for case let itemURL as URL in enumerator {
                let itemName = itemURL.lastPathComponent
                if itemName.hasPrefix("._") { continue }
                let ext = itemURL.pathExtension.lowercased()
                let itemPath = itemURL.standardizedFileURL.path
                
                if ext == "app" {
                    enumerator.skipDescendants()
                    if !seenPaths.contains(itemPath) {
                        if let game = parseMacApp(at: itemURL, isExplicit: false) {
                            seenPaths.insert(itemPath)
                            games.append(game)
                        }
                    }
                } else if ext == "ipa" {
                    if !seenPaths.contains(itemPath) {
                        if let game = parseIPA(at: itemURL) {
                            seenPaths.insert(itemPath)
                            games.append(game)
                        }
                    }
                } else if (try? itemURL.resourceValues(forKeys: [.isDirectoryKey]))?.isDirectory == true {
                    let dirLower = itemName.lowercased()
                    if dirLower.hasSuffix("_build") ||
                       dirLower.hasSuffix("-work") ||
                       dirLower.hasSuffix("_survey") ||
                       dirLower.hasPrefix("patched_") ||
                       dirLower == "staging" ||
                       dirLower == "shader" ||
                       dirLower == "extract" ||
                       dirLower == "romfs" ||
                       dirLower == "exefs" ||
                       dirLower == ".git" ||
                       dirLower == "node_modules" {
                        enumerator.skipDescendants()
                    }
                }
            }
        }
        
        // Scan explicitly added Non-Switch Apps
        for appURL in extraAppURLs {
            let clean = appURL.standardizedFileURL
            let path = clean.path
            guard !seenPaths.contains(path), fm.fileExists(atPath: path), clean.pathExtension.lowercased() == "app" else { continue }
            if let game = parseMacApp(at: clean, isExplicit: true) {
                seenPaths.insert(path)
                games.append(game)
            }
        }
        
        return games.sorted { $0.modificationDate > $1.modificationDate }
    }
    
    private static let nonGameCategories: Set<String> = [
        "public.app-category.developer-tools",
        "public.app-category.productivity",
        "public.app-category.graphics-design",
        "public.app-category.utilities",
        "public.app-category.social-networking",
        "public.app-category.business",
        "public.app-category.finance",
        "public.app-category.lifestyle",
        "public.app-category.medical",
        "public.app-category.music",
        "public.app-category.news",
        "public.app-category.photography",
        "public.app-category.video",
        "public.app-category.weather",
        "public.app-category.education",
        "public.app-category.travel",
        "public.app-category.reference"
    ]

    private static let excludedToolBundleIds: [String] = [
        "com.valvesoftware.steam",
        "com.epicgames.EpicGamesLauncher",
        "com.codeweavers.CrossOver",
        "com.heroicgameslauncher.hgl",
        "org.ryujinx.",
        "org.ryubing.",
        "com.rileytestut.AltServer",
        "org.nxnative."
    ]

    private func parseMacApp(at url: URL, isExplicit: Bool = false) -> PortedGame? {
        let fm = FileManager.default
        let plistURL = url.appendingPathComponent("Contents/Info.plist")
        let plistExists = fm.fileExists(atPath: plistURL.path)
        
        // Exclude the builder app itself
        let appFileName = url.lastPathComponent
        if appFileName == "NXNative.app" || appFileName == "NxNative_Launcher.app" { return nil }
        
        var name = url.deletingPathExtension().lastPathComponent
        var bundleId: String? = nil
        var titleId: String? = nil
        var version: String? = nil
        
        var rawPlist: [String: Any]? = nil
        if plistExists,
           let data = try? Data(contentsOf: plistURL),
           let plist = (try? PropertyListSerialization.propertyList(from: data, options: [], format: nil)) as? [String: Any] {
            rawPlist = plist
            if let dispName = plist["CFBundleDisplayName"] as? String, !dispName.isEmpty {
                name = dispName
            } else if let bundleName = plist["CFBundleName"] as? String, !bundleName.isEmpty {
                name = bundleName
            }
            bundleId = plist["CFBundleIdentifier"] as? String
            titleId = plist["DMTitleID"] as? String
            version = plist["CFBundleShortVersionString"] as? String
        } else if !plistExists {
            let macosDir = url.appendingPathComponent("Contents/MacOS")
            let hasExecutable = (try? fm.contentsOfDirectory(atPath: macosDir.path))?.contains { !$0.hasPrefix(".") } ?? false
            if !hasExecutable && !isExplicit {
                return nil
            }
        }
        
        let hasDmhost = fm.fileExists(atPath: url.appendingPathComponent("Contents/MacOS/dmhost").path)
        let hasExplicitDmTitleId = rawPlist?["DMTitleID"] != nil
        
        // Secondary titleId extraction if missing from DMTitleID (only if it has dmhost or DMTitleID)
        if hasDmhost || hasExplicitDmTitleId {
            if titleId == nil || titleId?.isEmpty == true {
                if let bid = bundleId {
                    let range = NSRange(bid.startIndex..., in: bid)
                    if let regex = try? NSRegularExpression(pattern: "((?:0100|0400)[0-9A-Fa-f]{12})", options: [.caseInsensitive]),
                       let match = regex.firstMatch(in: bid, range: range),
                       let r = Range(match.range(at: 1), in: bid) {
                        titleId = String(bid[r]).uppercased()
                    }
                }
            }
            if titleId == nil || titleId?.isEmpty == true {
                let fname = url.lastPathComponent
                let range = NSRange(fname.startIndex..., in: fname)
                if let regex = try? NSRegularExpression(pattern: "\\[((?:0100|0400)[0-9A-Fa-f]{12})\\]", options: [.caseInsensitive]),
                   let match = regex.firstMatch(in: fname, range: range),
                   let r = Range(match.range(at: 1), in: fname) {
                    titleId = String(fname[r]).uppercased()
                }
            }
            if titleId == nil || titleId?.isEmpty == true {
                titleId = CompatibilityService.shared.findTitleId(forGameTitle: name)?.uppercased()
            }
        } else {
            // Non-Switch Game: do not force a Switch Title ID
            titleId = nil
        }
        
        let isSwitchPort = hasDmhost || hasExplicitDmTitleId || (titleId != nil && (titleId?.hasPrefix("0100") == true || titleId?.hasPrefix("0400") == true))
        
        // Filter out system utilities and helper apps for automatic folder scans
        if !isSwitchPort && !isExplicit {
            let helperSuffixes = ["Helper.app", "CrashHandler.app", "CrashReporter.app", "Updater.app", "Uninstall.app", "Service.app"]
            if helperSuffixes.contains(where: { appFileName.hasSuffix($0) }) || appFileName.hasPrefix(".") {
                return nil
            }
            
            let bid = bundleId?.lowercased() ?? ""
            let category = (rawPlist?["LSApplicationCategoryType"] as? String)?.lowercased() ?? ""
            
            // Exclude Apple system utilities unless Apple Arcade / game
            if bid.hasPrefix("com.apple.") && !category.contains("game") && !bid.contains("arcade") && !bid.contains("game") {
                return nil
            }
            
            // Exclude known launchers, translation tools and emulators
            if Self.excludedToolBundleIds.contains(where: { bid.hasPrefix($0.lowercased()) }) {
                return nil
            }
            
            // Non-game category rejection only if explicitly declared
            if !category.isEmpty && Self.nonGameCategories.contains(category) {
                return nil
            }
        }
        
        let targetPlatform: TargetPlatform = isSwitchPort ? .macApp : .nonSwitch
        
        let baseModDate = (try? url.resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate ?? Date()
        let resourcesModDate = (try? url.appendingPathComponent("Contents/Resources").resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate ?? .distantPast
        let modDate = max(baseModDate, resourcesModDate)
        let pathKey = url.standardized.path

        // Accurate full on-disk bundle size with cache
        var size: Int64 = 0
        cacheLock.lock()
        if let cached = appSizeCache[pathKey], cached.modDate == modDate {
            size = cached.size
        }
        cacheLock.unlock()

        if size <= 0 {
            size = calculateDirectorySize(url: url)
            if size == 0 {
                let romfsImg = url.appendingPathComponent("Contents/Resources/romfs.img")
                if let imgSize = (try? romfsImg.resourceValues(forKeys: [.fileSizeKey]))?.fileSize {
                    size = Int64(imgSize)
                } else if let exeSize = (try? url.appendingPathComponent("Contents/MacOS/dmhost").resourceValues(forKeys: [.fileSizeKey]))?.fileSize {
                    size = Int64(exeSize)
                } else if let exeName = rawPlist?["CFBundleExecutable"] as? String,
                          let exeSize = (try? url.appendingPathComponent("Contents/MacOS/\(exeName)").resourceValues(forKeys: [.fileSizeKey]))?.fileSize {
                    size = Int64(exeSize)
                } else if let appSize = (try? url.resourceValues(forKeys: [.fileSizeKey]))?.fileSize {
                    size = Int64(appSize)
                }
            }
            if size > 0 {
                cacheLock.lock()
                appSizeCache[pathKey] = (modDate: modDate, size: size)
                saveAppSizeCacheLocked()
                cacheLock.unlock()
            }
        }
        
        if isSwitchPort && isOcarinaOfTime(at: url) {
            sanitizeOoTEnvIfNeeded(at: url)
        }

        return PortedGame(
            name: name,
            url: url,
            platform: targetPlatform,
            sizeBytes: size,
            modificationDate: modDate,
            bundleId: bundleId,
            titleId: titleId?.uppercased(),
            versionString: version
        )
    }
    
    private func parseIPA(at url: URL) -> PortedGame? {
        let values = try? url.resourceValues(forKeys: [.fileSizeKey, .contentModificationDateKey])
        let ipaSize = Int64(values?.fileSize ?? 0)
        let modDate = values?.contentModificationDate ?? Date()
        let pathKey = url.standardized.path
        
        cacheLock.lock()
        if let cached = ipaMetadataCache[pathKey], cached.modDate == modDate, cached.ipaSize == ipaSize {
            cacheLock.unlock()
            let totalSize = ipaSize + companionFilesSize(forIPA: url, titleId: cached.game.titleId)
            return PortedGame(
                name: cached.game.name,
                url: cached.game.url,
                platform: cached.game.platform,
                sizeBytes: totalSize,
                modificationDate: cached.game.modificationDate,
                bundleId: cached.game.bundleId,
                titleId: cached.game.titleId,
                versionString: cached.game.versionString
            )
        }
        cacheLock.unlock()

        var name = url.deletingPathExtension().lastPathComponent
        var bundleId: String? = nil
        var titleId: String? = nil
        var version: String? = nil
        
        // Fast inspect Payload/*/Info.plist from inside the IPA (zip archive) with bounded timeout
        let unzipRes = BoundedProcess.run("/usr/bin/unzip", ["-p", url.path, "Payload/*/Info.plist"], timeout: 2.0)
        if unzipRes.success, let data = unzipRes.data, !data.isEmpty,
           let plist = (try? PropertyListSerialization.propertyList(from: data, options: [], format: nil)) as? [String: Any] {
            if let dispName = plist["CFBundleDisplayName"] as? String, !dispName.isEmpty {
                name = dispName
            } else if let bundleName = plist["CFBundleName"] as? String, !bundleName.isEmpty && bundleName != "DmIOS" {
                name = bundleName
            }
            bundleId = plist["CFBundleIdentifier"] as? String
            titleId = plist["DMTitleID"] as? String
            version = plist["CFBundleShortVersionString"] as? String
        }
        
        // Extract TitleID from CFBundleIdentifier if needed
        if titleId == nil || titleId?.isEmpty == true {
            if let bid = bundleId {
                let range = NSRange(bid.startIndex..., in: bid)
                if let regex = try? NSRegularExpression(pattern: "((?:0100|0400)[0-9A-Fa-f]{12})", options: [.caseInsensitive]),
                   let match = regex.firstMatch(in: bid, range: range),
                   let r = Range(match.range(at: 1), in: bid) {
                    titleId = String(bid[r]).uppercased()
                }
            }
        }
        
        // Extract TitleID from filename regex [0100...] or [0400...]
        if titleId == nil || titleId?.isEmpty == true {
            let fname = url.lastPathComponent
            let range = NSRange(fname.startIndex..., in: fname)
            if let regex = try? NSRegularExpression(pattern: "\\[((?:0100|0400)[0-9A-Fa-f]{12})\\]", options: [.caseInsensitive]),
               let match = regex.firstMatch(in: fname, range: range),
               let r = Range(match.range(at: 1), in: fname) {
                titleId = String(fname[r]).uppercased()
            }
        }
        
        // Fall back to title database matching across 29,000+ Switch titles
        if titleId == nil || titleId?.isEmpty == true {
            titleId = CompatibilityService.shared.findTitleId(forGameTitle: name)?.uppercased()
        }
        
        if bundleId == nil, let tid = titleId {
            bundleId = "org.nxnative.\(tid.lowercased())"
        }
        
        let normalizedTitleId = titleId?.uppercased()
        let totalSize = ipaSize + companionFilesSize(forIPA: url, titleId: normalizedTitleId)

        let game = PortedGame(
            name: name,
            url: url,
            platform: .ios,
            sizeBytes: totalSize,
            modificationDate: modDate,
            bundleId: bundleId,
            titleId: normalizedTitleId,
            versionString: version
        )
        cacheLock.lock()
        ipaMetadataCache[pathKey] = (modDate: modDate, ipaSize: ipaSize, game: game)
        cacheLock.unlock()
        return game
    }

    /// Computes total on-disk size of game-specific companion files next to an `.ipa`
    /// (`<stem>.romfs.img`, `<titleId>.romfs.img`, `<stem>.ipa.idx`), avoiding double counting on APFS.
    private func companionFilesSize(forIPA ipaURL: URL, titleId: String?) -> Int64 {
        let fm = FileManager.default
        let dir = ipaURL.deletingLastPathComponent()
        let stem = ipaURL.deletingPathExtension().lastPathComponent
        let stemAlt1 = stem.replacingOccurrences(of: "’", with: "'")
        let stemAlt2 = stem.replacingOccurrences(of: "'", with: "’")
        var candidates: [URL] = []
        for s in Set([stem, stemAlt1, stemAlt2]) where !s.isEmpty {
            candidates.append(dir.appendingPathComponent("\(s).romfs.img"))
            candidates.append(dir.appendingPathComponent("\(s).RomFS.img"))
            candidates.append(dir.appendingPathComponent("\(s).ipa.idx"))
        }
        if let tid = titleId?.trimmingCharacters(in: .whitespacesAndNewlines), !tid.isEmpty {
            candidates.append(dir.appendingPathComponent("\(tid).romfs.img"))
            candidates.append(dir.appendingPathComponent("\(tid.lowercased()).romfs.img"))
            candidates.append(dir.appendingPathComponent("\(tid).RomFS.img"))
        }

        var seenPaths = Set<String>()
        var extraBytes: Int64 = 0
        for candidate in candidates {
            guard fm.fileExists(atPath: candidate.path) else { continue }
            let resolved = candidate.resolvingSymlinksInPath()
            let key = resolved.standardizedFileURL.path.lowercased()
            guard !seenPaths.contains(key) else { continue }
            seenPaths.insert(key)
            if let vals = try? resolved.resourceValues(forKeys: [.fileSizeKey, .isRegularFileKey]),
               vals.isRegularFile == true,
               let fileSize = vals.fileSize {
                extraBytes += Int64(fileSize)
            }
        }
        return extraBytes
    }

    /// Fast POSIX directory size calculator using `fts_open` without per-file Foundation URL overhead.
    public static func fastDirectorySize(at url: URL, skipPackageDescendants: Bool = false) -> Int64 {
        let resolvedPath = url.resolvingSymlinksInPath().path
        var isDir: ObjCBool = false
        guard FileManager.default.fileExists(atPath: resolvedPath, isDirectory: &isDir) else { return 0 }
        if !isDir.boolValue {
            let size = (try? FileManager.default.attributesOfItem(atPath: resolvedPath)[.size] as? Int64) ?? 0
            return size
        }

        guard let rootDup = strdup(resolvedPath) else { return 0 }
        defer { free(rootDup) }
        var argv: [UnsafeMutablePointer<CChar>?] = [rootDup, nil]
        guard let fts = argv.withUnsafeMutableBufferPointer({ buf in
            fts_open(buf.baseAddress, FTS_PHYSICAL | FTS_NOCHDIR, nil)
        }) else {
            return 0
        }
        defer { fts_close(fts) }

        var total: Int64 = 0
        while let ent = fts_read(fts) {
            let info = Int32(ent.pointee.fts_info)
            if info == FTS_F {
                total += Int64(ent.pointee.fts_statp.pointee.st_size)
            } else if skipPackageDescendants, info == FTS_D, ent.pointee.fts_level > 0, let pathPtr = ent.pointee.fts_path {
                let pathStr = String(cString: pathPtr)
                if pathStr.hasSuffix(".app") {
                    fts_set(fts, ent, FTS_SKIP)
                }
            }
        }
        return total
    }

    public func calculateDirectorySize(url: URL) -> Int64 {
        Self.fastDirectorySize(at: url, skipPackageDescendants: false)
    }
    
    // MARK: - Zelda OoT Engine Hot-Patching
    public func isOcarinaOfTime(at url: URL) -> Bool {
        let name = url.lastPathComponent
        if name.localizedCaseInsensitiveContains("Ocarina") { return true }
        if name.contains("0400486024DEC000") || name.contains("0400486024dec000") { return true }
        
        let plistURL = url.appendingPathComponent("Contents/Info.plist")
        if let data = try? Data(contentsOf: plistURL),
           let plist = (try? PropertyListSerialization.propertyList(from: data, options: [], format: nil)) as? [String: Any] {
            if let tid = plist["DMTitleID"] as? String, tid.uppercased() == "0400486024DEC000" {
                return true
            }
            if let bid = plist["CFBundleIdentifier"] as? String, bid.localizedCaseInsensitiveContains("0400486024dec000") {
                return true
            }
        }
        
        let envURL = url.appendingPathComponent("Contents/Resources/dm/env.txt")
        if let envText = try? String(contentsOf: envURL, encoding: .utf8), envText.contains("0400486024DEC000") {
            return true
        }
        return false
    }

    private static func isValidShaderChainHex(_ value: String) -> Bool {
        let count = value.count
        guard count >= 8 && count <= 16 else { return false }
        return value.unicodeScalars.allSatisfy {
            ($0.value >= 48 && $0.value <= 57) || // 0-9
            ($0.value >= 97 && $0.value <= 102)   // a-f
        }
    }

    /// Detects the compiled shader translation chain (DMSH_CHAIN) expected by a ported `.app` bundle.
    /// Reads `Contents/Resources/msl/b-<chain>[.img]` and validates against `Contents/Resources/dm/c1_full.tsv` (`# chain b-<chain>`).
    public func detectedShaderChain(at url: URL) -> String? {
        let fm = FileManager.default
        let mslDir = url.appendingPathComponent("Contents/Resources/msl")
        var mslChains: [String] = []
        if let entries = try? fm.contentsOfDirectory(atPath: mslDir.path) {
            for entry in entries.sorted() {
                guard entry.hasPrefix("b-") else { continue }
                var trimmed = String(entry.dropFirst(2))
                if trimmed.hasSuffix(".img") {
                    trimmed = String(trimmed.dropLast(4))
                }
                trimmed = trimmed.lowercased()
                if Self.isValidShaderChainHex(trimmed) && !mslChains.contains(trimmed) {
                    mslChains.append(trimmed)
                }
            }
        }

        let c1URL = url.appendingPathComponent("Contents/Resources/dm/c1_full.tsv")
        var c1Chain: String?
        if let c1Handle = try? FileHandle(forReadingFrom: c1URL) {
            defer { try? c1Handle.close() }
            if let chunk = try? c1Handle.read(upToCount: 256),
               let firstLine = String(data: chunk, encoding: .utf8)?.components(separatedBy: .newlines).first,
               let range = firstLine.range(of: "# chain b-") {
                let tail = String(firstLine[range.upperBound...])
                let token = tail.split(separator: " ", maxSplits: 1).first.map(String.init)?.lowercased() ?? ""
                if Self.isValidShaderChainHex(token) {
                    c1Chain = token
                }
            }
        }

        if let c1 = c1Chain {
            if mslChains.isEmpty || mslChains.contains(c1) {
                return c1
            }
        }
        return mslChains.first ?? c1Chain
    }

    /// Verifies that a Mach-O `dmhost` binary supports universal bundled chain loading (`g_active_chain` in `shader_load`) or embeds the exact null-terminated `DMSH_CHAIN` literal.
    public static func binarySupportsShaderChain(_ binaryData: Data, chain: String) -> Bool {
        if let universalMarker = "universal host compatibility v2".data(using: .utf8),
           binaryData.range(of: universalMarker) != nil {
            return true
        }
        let lowerChain = chain.lowercased()
        guard isValidShaderChainHex(lowerChain) else { return false }
        var needleBytes: [UInt8] = [0]
        needleBytes.append(contentsOf: lowerChain.utf8)
        needleBytes.append(0)
        return binaryData.range(of: Data(needleBytes)) != nil
    }

    /// Replaces legacy `DM_TEX_RELEASE=1` or `2` in OoT `env.txt` files with `DM_TEX_RELEASE=0` to prevent pink/black/invisible texture corruption.
    public func sanitizeOoTEnvIfNeeded(at appURL: URL) {
        let titleId = "0400486024DEC000"
        var candidates: [URL] = [
            appURL.appendingPathComponent("Contents/Resources/dm/env.txt")
        ]
        let baseDirs = [
            SystemDetector.shared.appSupportDirectory,
            SystemDetector.shared.defaultAppSupportDirectory
        ]
        for baseDir in baseDirs {
            for tid in Set([titleId, titleId.uppercased(), titleId.lowercased()]) {
                candidates.append(baseDir.appendingPathComponent(tid).appendingPathComponent("env.txt"))
            }
        }
        var seen = Set<String>()
        for url in candidates {
            let stdPath = url.standardizedFileURL.path
            guard seen.insert(stdPath).inserted else { continue }
            sanitizeLegacyTexRelease2(in: url)
        }
    }

    private func sanitizeLegacyTexRelease2(in envURL: URL) {
        guard FileManager.default.fileExists(atPath: envURL.path),
              let content = try? String(contentsOf: envURL, encoding: .utf8) else {
            return
        }
        let lines = content.components(separatedBy: .newlines)
        var changed = false
        let updatedLines = lines.map { line -> String in
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            if trimmed == "DM_TEX_RELEASE=2" || trimmed == "DM_TEX_RELEASE=1" {
                changed = true
                return "DM_TEX_RELEASE=0"
            }
            return line
        }
        guard changed else { return }
        let updatedContent = updatedLines.joined(separator: "\n")
        try? updatedContent.write(to: envURL, atomically: true, encoding: .utf8)
    }

    @discardableResult
    public func hotPatchOoTEngineIfNeeded(at url: URL) -> Bool {
        guard isOcarinaOfTime(at: url) else { return false }
        sanitizeOoTEnvIfNeeded(at: url)
        
        let fm = FileManager.default
        let targetHost = url.appendingPathComponent("Contents/MacOS/dmhost")
        guard fm.fileExists(atPath: targetHost.path) else { return false }

        // Strictly require a verified shader chain match so future upstream chain bumps
        // NEVER overwrite an existing ported .app with an incompatible dmhost binary (black screen).
        guard let appChain = detectedShaderChain(at: url) else {
            print("[OoT HotPatch] Skipping hot-patch for \(url.lastPathComponent): could not verify bundle shader chain.")
            return false
        }

        var searchRoots: [URL] = []
        if let resURL = Bundle.main.resourceURL {
            searchRoots.append(resURL)
        }
        searchRoots.append(Bundle.main.bundleURL.appendingPathComponent("Contents/Resources"))
        let detectedRepo = SystemDetector.shared.detectNxnativeDirectory()
        if detectedRepo.isValid {
            searchRoots.append(URL(fileURLWithPath: detectedRepo.path).appendingPathComponent("gui/Resources"))
        }
        searchRoots.append(URL(fileURLWithPath: "/Volumes/SSD FN501 PRO/Emulations/NativePort/nxnative/gui/Resources"))
        searchRoots.append(URL(fileURLWithPath: "/Volumes/SSD FN501 PRO/Emulations/NativePort/NxNative_Launcher.app/Contents/Resources"))

        // Sync updated prewarm manifest only for bundles without a prebuilt .mtl4a archive (and remove previously synced 3 MB manifest from .mtl4a bundles so startup stays <0.3s)
        let targetPsoManifest = url.appendingPathComponent("Contents/Resources/dm/pso_manifest.tsv")
        let bundledPsoDir = url.appendingPathComponent("Contents/Resources/pso")
        let hasBundledMtl4a = ((try? fm.contentsOfDirectory(atPath: bundledPsoDir.path)) ?? []).contains { $0.hasSuffix(".mtl4a") }
        if fm.fileExists(atPath: targetPsoManifest.deletingLastPathComponent().path) {
            for root in searchRoots {
                let srcManifest = root.appendingPathComponent("engine/0400486024DEC000/pso_manifest.tsv")
                guard fm.fileExists(atPath: srcManifest.path),
                      let srcData = try? Data(contentsOf: srcManifest) else {
                    continue
                }
                let srcDigest = SHA256.hash(data: srcData)
                let dstData = try? Data(contentsOf: targetPsoManifest)
                let dstDigest = dstData.map { SHA256.hash(data: $0) }
                if hasBundledMtl4a {
                    if dstDigest == srcDigest {
                        try? fm.removeItem(at: targetPsoManifest)
                    }
                } else if dstDigest != srcDigest && srcData.count >= (dstData?.count ?? 0) {
                    try? fm.removeItem(at: targetPsoManifest)
                    try? fm.copyItem(at: srcManifest, to: targetPsoManifest)
                }
                break
            }
        }

        var candidateSources: [URL] = []
        for root in searchRoots {
            candidateSources.append(root.appendingPathComponent("engine/0400486024DEC000/dmhost"))
        }
        for root in searchRoots {
            candidateSources.append(root.appendingPathComponent("engine/0400486024DEC000/dmhost-\(appChain)"))
        }

        var matchedSource: (url: URL, data: Data)?
        for candidate in candidateSources {
            guard fm.fileExists(atPath: candidate.path),
                  let data = try? Data(contentsOf: candidate),
                  Self.binarySupportsShaderChain(data, chain: appChain) else {
                continue
            }
            matchedSource = (candidate, data)
            break
        }

        guard let sourceHost = matchedSource else {
            print("[OoT HotPatch] Skipping hot-patch for \(url.lastPathComponent): no bundled dmhost supports shader chain b-\(appChain).")
            return false
        }

        let sourceDigest = SHA256.hash(data: sourceHost.data)
        if let targetData = try? Data(contentsOf: targetHost) {
            let targetDigest = SHA256.hash(data: targetData)
            if sourceDigest == targetDigest {
                return false
            }
        }
        
        do {
            try? fm.removeItem(at: targetHost)
            try fm.copyItem(at: sourceHost.url, to: targetHost)
            try? fm.setAttributes([.posixPermissions: 0o755], ofItemAtPath: targetHost.path)
            _ = self.runProcessWithTimeout(executable: "/usr/bin/xattr", arguments: ["-d", "com.apple.quarantine", targetHost.path], timeoutSeconds: 1.0)
            _ = self.runProcessWithTimeout(executable: "/usr/bin/codesign", arguments: ["--force", "--sign", "-", targetHost.path], timeoutSeconds: 2.0)
            return true
        } catch {
            return false
        }
    }

    public func launchGame(at url: URL, env: [String: String]? = nil, completion: @escaping (Bool, String?) -> Void) {
        guard url.pathExtension.lowercased() == "app" else {
            completion(false, "Cannot launch non-macOS application bundle locally.")
            return
        }

        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            guard let self = self else {
                DispatchQueue.main.async {
                    completion(false, "Internal error: LibraryScanner unavailable.")
                }
                return
            }

            // 0. Sanitize legacy OoT env.txt settings without modifying the app's dmhost binary
            if self.isOcarinaOfTime(at: url) {
                self.sanitizeOoTEnvIfNeeded(at: url)
            }

            // 0.5 Ensure macOS Game Mode (LSSupportsGameMode in Info.plist) and DMLanguage match runtime environment
            let wantGameMode = (env?["DM_FULLSCREEN"] != "0")
            self.synchronizeGameModeInfoPlist(at: url, enableGameMode: wantGameMode, gameLanguage: env?["DM_LANG"])

            // 1. Remove macOS quarantine attribute safely with timeout to satisfy Gatekeeper
            self.runProcessWithTimeout(executable: "/usr/bin/xattr", arguments: ["-d", "com.apple.quarantine", url.path], timeoutSeconds: 2.0)
            self.runProcessWithTimeout(executable: "/usr/bin/xattr", arguments: ["-cr", url.appendingPathComponent("Contents/MacOS").path], timeoutSeconds: 2.0)

            // 2. Ensure executable permissions and ad-hoc sign Mach-O binaries in Contents/MacOS (fast ~0.02s, not deep bundle hashing)
            let fm = FileManager.default
            let macosDir = url.appendingPathComponent("Contents/MacOS")
            let dmhostURL = macosDir.appendingPathComponent("dmhost")
            if fm.fileExists(atPath: dmhostURL.path) {
                try? fm.setAttributes([.posixPermissions: 0o755], ofItemAtPath: dmhostURL.path)
                self.runProcessWithTimeout(executable: "/usr/bin/codesign", arguments: ["--force", "--sign", "-", dmhostURL.path], timeoutSeconds: 2.0)
            }

            if let binFiles = try? fm.contentsOfDirectory(at: macosDir, includingPropertiesForKeys: nil) {
                for bin in binFiles where bin.lastPathComponent != "dmhost" {
                    try? fm.setAttributes([.posixPermissions: 0o755], ofItemAtPath: bin.path)
                    self.runProcessWithTimeout(executable: "/usr/bin/codesign", arguments: ["--force", "--sign", "-", bin.path], timeoutSeconds: 2.0)
                }
            }

            // Remove any stale/partial bundle-level _CodeSignature left by interrupted bundle signing
            // (signing the top-level .app hashes all of Contents/Resources/ which can be 40+ GB; Mach-O binaries in Contents/MacOS carry their own embedded LC_CODE_SIGNATURE)
            let codeSigDir = url.appendingPathComponent("Contents/_CodeSignature")
            if fm.fileExists(atPath: codeSigDir.path) {
                try? fm.removeItem(at: codeSigDir)
            }

            DispatchQueue.main.async {
                let config = NSWorkspace.OpenConfiguration()
                config.activates = true
                
                // MANDATORY ZERO-HANG RULE: Inherit system environment (PATH, HOME, USER)
                // dmhost and system libraries crash or abort if HOME/USER/PATH are missing!
                var envDict = ProcessInfo.processInfo.environment
                if let env = env {
                    for (k, v) in env { envDict[k] = v }
                }
                if envDict["DM_LAUNCHER"] == nil {
                    envDict["DM_LAUNCHER"] = "0"
                }
                config.environment = envDict
                
                NSWorkspace.shared.openApplication(at: url, configuration: config) { app, error in
                    if let err = error {
                        completion(false, err.localizedDescription)
                    } else {
                        GameControllerService.shared.activeRunningGameApp = app
                        completion(true, nil)
                    }
                }
            }
        }
    }

    // MARK: - Game Language Discovery & Info.plist Synchronization
    public static let allSwitchLanguageCodes: [String] = [
        "en-US", "en-GB", "ja", "fr", "de", "es-419", "es", "it",
        "nl", "fr-CA", "pt", "ru", "ko", "zh-Hant", "zh-Hans", "pt-BR"
    ]

    private func normalizedLanguageCodes(_ rawCodes: [String], ensuringIncluded defaultCode: String? = nil) -> [String] {
        var result: [String] = []
        var seen = Set<String>()
        for raw in rawCodes {
            let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
            if !trimmed.isEmpty, seen.insert(trimmed).inserted {
                result.append(trimmed)
            }
        }
        if let def = defaultCode?.trimmingCharacters(in: .whitespacesAndNewlines), !def.isEmpty, !seen.contains(def) {
            result.insert(def, at: 0)
        }
        return result
    }

    public func defaultGameLanguage(at url: URL) -> String {
        guard url.pathExtension.lowercased() == "app" else { return "en-US" }
        let plistURL = url.appendingPathComponent("Contents/Info.plist")
        guard let data = try? Data(contentsOf: plistURL),
              let plist = (try? PropertyListSerialization.propertyList(from: data, options: [], format: nil)) as? [String: Any],
              let lang = (plist["DMLanguage"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines),
              !lang.isEmpty else {
            return "en-US"
        }
        return lang
    }

    public func supportedGameLanguages(at url: URL) -> [String] {
        guard url.pathExtension.lowercased() == "app" else {
            return Self.allSwitchLanguageCodes
        }

        var plistDefault: String?
        let plistURL = url.appendingPathComponent("Contents/Info.plist")
        if let data = try? Data(contentsOf: plistURL),
           let plist = (try? PropertyListSerialization.propertyList(from: data, options: [], format: nil)) as? [String: Any] {
            if let lang = (plist["DMLanguage"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines), !lang.isEmpty {
                plistDefault = lang
            }
            if let dmSettings = plist["DMSettings"] as? [[String: Any]],
               let langEntry = dmSettings.first(where: { ($0["env"] as? String) == "DM_LANG" }),
               let values = langEntry["values"] as? [String] {
                let declared = normalizedLanguageCodes(values, ensuringIncluded: plistDefault)
                if !declared.isEmpty {
                    return declared
                }
            }
        }

        // Fallback 1: Check Contents/Resources/dm/launcher.json for DM_LANG values or options
        let launcherJSONURL = url.appendingPathComponent("Contents/Resources/dm/launcher.json")
        if let jsonData = try? Data(contentsOf: launcherJSONURL),
           let json = (try? JSONSerialization.jsonObject(with: jsonData, options: [])) as? [String: Any],
           let settings = json["settings"] as? [[String: Any]],
           let langEntry = settings.first(where: { ($0["env"] as? String) == "DM_LANG" }) {
            var rawValues: [String] = []
            if let values = langEntry["values"] as? [String] {
                rawValues = values
            } else if let options = langEntry["options"] as? [[Any]] {
                rawValues = options.compactMap { $0.first as? String }
            }
            let declared = normalizedLanguageCodes(rawValues, ensuringIncluded: plistDefault)
            if !declared.isEmpty {
                return declared
            }
        }

        // Fallback 2: Ports without DM_LANG in DMSettings / launcher.json get all 16 Switch languages
        return normalizedLanguageCodes(Self.allSwitchLanguageCodes, ensuringIncluded: plistDefault)
    }

    // MARK: - macOS Game Mode & Language Info.plist Synchronization
    @discardableResult
    public func synchronizeGameModeInfoPlist(at url: URL, enableGameMode: Bool, gameLanguage: String? = nil) -> Bool {
        guard url.pathExtension.lowercased() == "app" else { return false }
        let plistURL = url.appendingPathComponent("Contents/Info.plist")
        let fm = FileManager.default
        guard fm.fileExists(atPath: plistURL.path) else { return false }

        guard let data = try? Data(contentsOf: plistURL),
              var plist = (try? PropertyListSerialization.propertyList(from: data, options: .mutableContainersAndLeaves, format: nil)) as? [String: Any] else {
            return false
        }

        let currentVal = plist["LSSupportsGameMode"] as? Bool
        let gameModeChanged: Bool
        if enableGameMode {
            // Game Mode ON: ensure LSSupportsGameMode is true and category is a game
            gameModeChanged = (currentVal != true)
            if gameModeChanged {
                plist["LSSupportsGameMode"] = true
            }
            if plist["LSApplicationCategoryType"] == nil {
                plist["LSApplicationCategoryType"] = "public.app-category.games"
            }
        } else {
            // Game Mode OFF: explicitly opt out so macOS does not engage Game Mode
            gameModeChanged = (currentVal != false)
            if gameModeChanged {
                plist["LSSupportsGameMode"] = false
            }
        }

        var langChanged = false
        if let lang = gameLanguage?.trimmingCharacters(in: .whitespacesAndNewlines), !lang.isEmpty {
            if (plist["DMLanguage"] as? String) != lang {
                plist["DMLanguage"] = lang
                langChanged = true
            }
        }

        guard gameModeChanged || langChanged else { return true }

        do {
            let outData = try PropertyListSerialization.data(fromPropertyList: plist, format: .xml, options: 0)
            try outData.write(to: plistURL, options: .atomic)

            // Re-register bundle with macOS LaunchServices only when LSSupportsGameMode changed
            if gameModeChanged {
                let lsregisterCandidates = [
                    "/System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister",
                    "/System/Library/Frameworks/CoreServices.framework/Versions/A/Frameworks/LaunchServices.framework/Versions/A/Support/lsregister"
                ]
                if let lsregister = lsregisterCandidates.first(where: { fm.fileExists(atPath: $0) }) {
                    _ = self.runProcessWithTimeout(executable: lsregister, arguments: ["-f", url.path], timeoutSeconds: 2.0)
                }
            }
            return true
        } catch {
            return false
        }
    }

    @discardableResult
    private func runProcessWithTimeout(executable: String, arguments: [String], timeoutSeconds: Double = 3.0) -> Bool {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: executable)
        process.arguments = arguments
        process.standardOutput = Pipe()
        process.standardError = Pipe()

        do {
            try process.run()
            let deadline = DispatchTime.now() + timeoutSeconds
            while process.isRunning && DispatchTime.now() < deadline {
                usleep(30_000) // 30ms polling
            }
            if process.isRunning {
                process.terminate()
                return false
            }
            return process.terminationStatus == 0
        } catch {
            return false
        }
    }
}
