import Foundation
import AppKit
import SwiftUI

public final class ArtworkStore: ObservableObject {
    public static let shared = ArtworkStore()

    private let memoryCache = NSCache<NSString, NSImage>()
    private let heroCache = NSCache<NSString, NSImage>()
    private let fileManager = FileManager.default
    private let artworkDir: URL
    private let localRepoDir: URL
    private let lock = NSLock()

    private var inFlightDownloads = Set<String>()
    private var failedLookups = Set<String>()
    private var galleryMapByTitle: [String: String] = [:]
    private var galleryMapByTid: [String: String] = [:]
    private var resolvedTitleEntries: [String: [String: String]] = [:]

    private lazy var urlSession: URLSession = {
        let config = URLSessionConfiguration.ephemeral
        config.timeoutIntervalForRequest = 4.0
        config.timeoutIntervalForResource = 8.0
        config.httpMaximumConnectionsPerHost = 4
        return URLSession(configuration: config)
    }()

    private var notifyDebounceTimer: Timer? = nil

    @Published public var refreshTrigger: Int = 0

    private init() {
        artworkDir = SystemDetector.shared.appSupportDirectory.appendingPathComponent("artwork", isDirectory: true)
        
        let detected = SystemDetector.shared.detectNxnativeDirectory().path
        let repoBase = URL(fileURLWithPath: detected).appendingPathComponent("docs/images")
        if fileManager.fileExists(atPath: repoBase.path) {
            localRepoDir = repoBase
        } else {
            localRepoDir = URL(fileURLWithPath: "/Volumes/SSD FN501 PRO/Emulations/NativePort/nxnative/docs/images")
        }
        
        try? fileManager.createDirectory(at: artworkDir, withIntermediateDirectories: true)
        
        // Compact memory bounds: 40 square icons (max 12 MB) and 2 active widescreen heroes (max 8 MB)
        memoryCache.countLimit = 40
        memoryCache.totalCostLimit = 12 * 1024 * 1024
        heroCache.countLimit = 2
        heroCache.totalCostLimit = 8 * 1024 * 1024

        loadLocalGalleryIndex()
    }

    public func purgeMemoryCaches() {
        memoryCache.removeAllObjects()
        heroCache.removeAllObjects()
    }

    private func cacheImage(_ img: NSImage, forKey key: NSString) {
        let approxBytes = Int(img.size.width * img.size.height * 4)
        memoryCache.setObject(img, forKey: key, cost: max(approxBytes, 1024))
    }

    private func cacheHero(_ img: NSImage, forKey key: NSString) {
        let approxBytes = Int(img.size.width * img.size.height * 4)
        heroCache.setObject(img, forKey: key, cost: max(approxBytes, 1024))
    }

    public func loadSquareIcon(for game: PortedGame) -> NSImage {
        let tid: String? = (game.platform == .nonSwitch)
            ? nil
            : (game.titleId ?? CompatibilityService.shared.findTitleId(forGameTitle: game.name))?.uppercased()
        let cacheKey = "icon_\(tid ?? game.uniqueKey.uppercased())" as NSString
        if let cached = memoryCache.object(forKey: cacheKey) {
            return cached
        }

        // 0. User custom cover art has absolute top priority
        if GameCoverService.shared.hasCustomCover(for: game) {
            let customFile = GameCoverService.shared.customCoverURL(for: game)
            if let img = ImageDownsampler.downsample(url: customFile, maxPixelSize: 384) ?? NSImage(contentsOf: customFile) {
                cacheImage(img, forKey: cacheKey)
                return img
            }
        }

        // 1. Non-Switch games MUST use the artwork of their own app icon
        if game.platform == .nonSwitch {
            if let icon = extractAppBundleIcon(from: game.url) {
                cacheImage(icon, forKey: cacheKey)
                return icon
            }
        }

        // 2. Switch 1 games (Mac app ports: platform == .macApp && !isSwitch2) MUST use their app icon
        if game.platform == .macApp && !game.isSwitch2 {
            if let icon = extractAppBundleIcon(from: game.url) {
                cacheImage(icon, forKey: cacheKey)
                return icon
            }
        }

        // 3. Ported iPhone / iPad games (platform == .ios / .ipa) MUST use their app icon
        if game.platform == .ios {
            if let ipaIcon = extractIpaIcon(from: game.url) {
                cacheImage(ipaIcon, forKey: cacheKey)
                return ipaIcon
            }
        }

        // 4. Switch 2 games (isSwitch2 == true) use clean cover art from GameCoverService or bundle
        if game.isSwitch2 {
            let resCover = game.url.appendingPathComponent("Contents/Resources/cover.jpg")
            if fileManager.fileExists(atPath: resCover.path),
               let img = ImageDownsampler.downsample(url: resCover, maxPixelSize: 384) ?? NSImage(contentsOf: resCover),
               img.isValid {
                cacheImage(img, forKey: cacheKey)
                return img
            }
            if let icon = extractAppBundleIcon(from: game.url) {
                cacheImage(icon, forKey: cacheKey)
                return icon
            }
            if let cover = GameCoverService.shared.coverImage(for: game) {
                cacheImage(cover, forKey: cacheKey)
                return cover
            }
            if let tid = tid, let fn = galleryFilename(for: tid) ?? galleryFilename(for: game.name) {
                let u = localRepoDir.appendingPathComponent(fn)
                if fileManager.fileExists(atPath: u.path),
                   let img = ImageDownsampler.downsample(url: u, maxPixelSize: 384) ?? NSImage(contentsOf: u),
                   img.isValid {
                    cacheImage(img, forKey: cacheKey)
                    return img
                }
            }
        }

        // 5. Fallback for any unhandled state: system workspace icon
        let wsIcon = NSWorkspace.shared.icon(forFile: game.url.path)
        wsIcon.size = NSSize(width: 256, height: 256)
        cacheImage(wsIcon, forKey: cacheKey)
        return wsIcon
    }

    private func extractAppBundleIcon(from url: URL) -> NSImage? {
        guard url.pathExtension.lowercased() == "app" else { return nil }
        let fm = FileManager.default
        let res = url.appendingPathComponent("Contents/Resources")
        
        // 1. Check Info.plist CFBundleIconFile / CFBundleIconName
        let infoPlist = url.appendingPathComponent("Contents/Info.plist")
        if let data = try? Data(contentsOf: infoPlist),
           let plist = (try? PropertyListSerialization.propertyList(from: data, options: [], format: nil)) as? [String: Any] {
            if var iconFile = (plist["CFBundleIconFile"] as? String) ?? (plist["CFBundleIconName"] as? String) {
                if !iconFile.hasSuffix(".icns") && !iconFile.hasSuffix(".png") {
                    iconFile += ".icns"
                }
                let target = res.appendingPathComponent(iconFile)
                if fm.fileExists(atPath: target.path),
                   let img = ImageDownsampler.downsample(url: target, maxPixelSize: 384) ?? NSImage(contentsOf: target),
                   img.isValid {
                    img.size = NSSize(width: 256, height: 256)
                    return img
                }
            }
        }
        
        // 2. Check standard application icon files in Contents/Resources
        for name in ["AppIcon.icns", "icon.icns", "AppIcon.png", "icon.png"] {
            let target = res.appendingPathComponent(name)
            if fm.fileExists(atPath: target.path),
               let img = ImageDownsampler.downsample(url: target, maxPixelSize: 384) ?? NSImage(contentsOf: target),
               img.isValid {
                img.size = NSSize(width: 256, height: 256)
                return img
            }
        }
        
        // 3. Fallback to NSWorkspace high-resolution file icon
        let wsIcon = NSWorkspace.shared.icon(forFile: url.path)
        wsIcon.size = NSSize(width: 256, height: 256)
        return wsIcon
    }

    private func extractIpaIcon(from url: URL) -> NSImage? {
        guard url.pathExtension.lowercased() == "ipa" else { return nil }
        
        // Fast listing of files inside the IPA archive (< 15ms)
        let listRes = BoundedProcess.run("/usr/bin/unzip", ["-Z1", url.path], timeout: 2.0)
        guard listRes.success, !listRes.output.isEmpty else { return nil }
        
        let lines = listRes.output.components(separatedBy: "\n")
        let candidates = lines.filter { line in
            let l = line.lowercased().trimmingCharacters(in: .whitespacesAndNewlines)
            return (l.hasPrefix("payload/") && (l.hasSuffix(".png") || l.hasSuffix(".jpg")) && (l.contains("appicon") || l.contains("icon")))
                || l.contains("itunesartwork")
        }
        
        // Prioritize higher-resolution icon entries
        let sorted = candidates.sorted { a, b in
            func score(_ s: String) -> Int {
                let l = s.lowercased()
                if l.contains("76x76@2x") || l.contains("83.5x83.5") || l.contains("1024") { return 100 }
                if l.contains("@3x") { return 90 }
                if l.contains("@2x") { return 80 }
                if l.contains("itunesartwork") { return 70 }
                return 10
            }
            return score(a) > score(b)
        }
        
        for iconPath in sorted {
            let res = BoundedProcess.run("/usr/bin/unzip", ["-p", url.path, iconPath], timeout: 2.0)
            if res.success, let data = res.data, !data.isEmpty,
               let img = ImageDownsampler.downsample(data: data, maxPixelSize: 384) ?? NSImage(data: data),
               img.isValid {
                img.size = NSSize(width: 256, height: 256)
                return img
            }
        }
        
        let wsIcon = NSWorkspace.shared.icon(forFile: url.path)
        wsIcon.size = NSSize(width: 256, height: 256)
        return wsIcon
    }

    public func loadSquareIcon(titleId: String?, gameName: String) -> NSImage? {
        let tid = (titleId ?? CompatibilityService.shared.findTitleId(forGameTitle: gameName))?.uppercased()
        let cacheKey = "icon_\(tid ?? gameName.uppercased())" as NSString
        if let cached = memoryCache.object(forKey: cacheKey) {
            return cached
        }

        // 1. Clean Steam / Playnite / RetroArch style cover from GameCoverService (no console headers, no eShop badges)
        if let cover = GameCoverService.shared.coverImage(titleId: tid, gameName: gameName) {
            cacheImage(cover, forKey: cacheKey)
            return cover
        }

        return nil
    }

    public func loadWidescreenHero(for game: PortedGame) -> NSImage? {
        let tid = (game.platform == .nonSwitch)
            ? nil
            : (game.titleId ?? CompatibilityService.shared.findTitleId(forGameTitle: game.name))?.uppercased()
        let cacheKey = "hero_\(tid ?? game.uniqueKey.uppercased())" as NSString
        if let cached = heroCache.object(forKey: cacheKey) {
            return cached
        }

        // 0. User custom background artwork has absolute top priority
        if GameCoverService.shared.hasCustomBackground(for: game) {
            let customBg = GameCoverService.shared.customBackgroundURL(for: game)
            if let img = ImageDownsampler.downsample(url: customBg, maxPixelSize: 1920) ?? NSImage(contentsOf: customBg),
               img.isValid {
                cacheHero(img, forKey: cacheKey)
                return img
            }
        }

        if game.platform == .nonSwitch {
            let bundleCover = game.url.appendingPathComponent("Contents/Resources/cover.jpg")
            if fileManager.fileExists(atPath: bundleCover.path),
               let img = ImageDownsampler.downsample(url: bundleCover, maxPixelSize: 1024) ?? NSImage(contentsOf: bundleCover),
               img.isValid {
                cacheHero(img, forKey: cacheKey)
                return img
            }
            let icon = loadSquareIcon(for: game)
            cacheHero(icon, forKey: cacheKey)
            return icon
        }

        // For Switch 2 games, the 16:9 promotional key visual is the primary hero artwork
        if game.isSwitch2 {
            if let hero = loadWidescreenHero(titleId: game.titleId, gameName: game.name) {
                cacheHero(hero, forKey: cacheKey)
                return hero
            }
        }

        // Check if game bundle has Contents/Resources/cover.jpg
        let bundleCover = game.url.appendingPathComponent("Contents/Resources/cover.jpg")
        if fileManager.fileExists(atPath: bundleCover.path),
           let img = ImageDownsampler.downsample(url: bundleCover, maxPixelSize: 1024) ?? NSImage(contentsOf: bundleCover),
           img.isValid {
            // For wide covers, use it directly as the hero background
            if img.size.width >= img.size.height * 1.25 {
                cacheHero(img, forKey: cacheKey)
                return img
            }
        }

        return loadWidescreenHero(titleId: game.titleId, gameName: game.name)
    }

    public func loadWidescreenHero(titleId: String?, gameName: String) -> NSImage? {
        let tid = (titleId ?? CompatibilityService.shared.findTitleId(forGameTitle: gameName))?.uppercased()
        let cacheKey = "hero_\(tid ?? gameName)" as NSString
        if let cached = heroCache.object(forKey: cacheKey) {
            return cached
        }

        // 0. User custom background artwork by title ID or game name
        if let customUrl = GameCoverService.shared.customBackgroundURL(titleId: tid, gameName: gameName),
           fileManager.fileExists(atPath: customUrl.path),
           let img = ImageDownsampler.downsample(url: customUrl, maxPixelSize: 1920) ?? NSImage(contentsOf: customUrl),
           img.isValid {
            cacheHero(img, forKey: cacheKey)
            return img
        }

        let isSwitch2 = (tid?.hasPrefix("0400") == true)

        // 1. Switch 2 promotional artwork from localRepoDir (docs/images & gallery.tsv)
        if isSwitch2 {
            if let tid = tid, let fn = galleryFilename(for: tid) ?? galleryFilename(for: gameName) {
                for dir in [localRepoDir, localRepoDir.appendingPathComponent("covers")] {
                    let u = dir.appendingPathComponent(fn)
                    if fileManager.fileExists(atPath: u.path),
                       let img = ImageDownsampler.downsample(url: u, maxPixelSize: 1024) ?? NSImage(contentsOf: u),
                       img.isValid {
                        cacheHero(img, forKey: cacheKey)
                        return img
                    }
                }
            }
        }

        // 2. Local disk cache in artwork/ or heroes repository
        if let tid = tid {
            let diskPath = artworkDir.appendingPathComponent("\(tid).jpg")
            if fileManager.fileExists(atPath: diskPath.path),
               let img = ImageDownsampler.downsample(url: diskPath, maxPixelSize: 1024) ?? NSImage(contentsOf: diskPath),
               img.isValid, img.size.width >= 32, img.size.height >= 32 {
                if !isSwitch2 && GameCoverService.shared.isScreenshotImage(img, titleId: tid) {
                    try? fileManager.removeItem(at: diskPath)
                } else {
                    cacheHero(img, forKey: cacheKey)
                    return img
                }
            }
            let repoHero = localRepoDir.appendingPathComponent("heroes/\(tid).jpg")
            if fileManager.fileExists(atPath: repoHero.path),
               let img = ImageDownsampler.downsample(url: repoHero, maxPixelSize: 1024) ?? NSImage(contentsOf: repoHero),
               img.isValid, img.size.width >= 32, img.size.height >= 32 {
                if isSwitch2 || !GameCoverService.shared.isScreenshotImage(img, titleId: tid) {
                    cacheHero(img, forKey: cacheKey)
                    return img
                }
            }
        }

        // 3. Async background fetch from official Nintendo eShop database (for Switch 1)
        if let tid = tid, !isSwitch2 {
            fetchWidescreenHeroAsync(titleId: tid)
        }

        // 4. Immediate fallback: return cover art so full-screen background is always vibrant
        if let cover = GameCoverService.shared.coverImage(titleId: tid, gameName: gameName) {
            cacheHero(cover, forKey: cacheKey)
            return cover
        }

        return nil
    }

    private func findLocalRepoHero(for gameName: String, titleId: String?) -> NSImage? {
        if let tid = titleId, let filename = galleryMapByTid[tid] {
            let u = localRepoDir.appendingPathComponent(filename)
            if fileManager.fileExists(atPath: u.path),
               let img = ImageDownsampler.downsample(url: u, maxPixelSize: 1280) ?? NSImage(contentsOf: u) {
                return img
            }
        }

        let normName = normalizeString(gameName)
        if let filename = galleryMapByTitle[normName] {
            let u = localRepoDir.appendingPathComponent(filename)
            if fileManager.fileExists(atPath: u.path),
               let img = ImageDownsampler.downsample(url: u, maxPixelSize: 1280) ?? NSImage(contentsOf: u) {
                return img
            }
        }

        for (name, filename) in galleryMapByTitle {
            if normName.contains(name) || name.contains(normName) {
                let u = localRepoDir.appendingPathComponent(filename)
                if fileManager.fileExists(atPath: u.path),
                   let img = ImageDownsampler.downsample(url: u, maxPixelSize: 1280) ?? NSImage(contentsOf: u) {
                    return img
                }
            }
        }

        return nil
    }

    public func galleryFilename(for key: String) -> String? {
        let upper = key.uppercased()
        if let fn = galleryMapByTid[upper] { return fn }
        let norm = normalizeString(key)
        if let fn = galleryMapByTitle[norm] { return fn }
        
        let cleaned = cleanRegionalSuffix(from: key)
        let normCleaned = normalizeString(cleaned)
        if let fn = galleryMapByTitle[normCleaned] { return fn }
        return nil
    }

    private func cleanRegionalSuffix(from title: String) -> String {
        return title
            .replacingOccurrences(of: ", Asian release", with: "", options: .caseInsensitive)
            .replacingOccurrences(of: ", Japanese release", with: "", options: .caseInsensitive)
            .replacingOccurrences(of: " (Asian release)", with: "", options: .caseInsensitive)
            .replacingOccurrences(of: " (Japanese release)", with: "", options: .caseInsensitive)
            .replacingOccurrences(of: " (Asian)", with: "", options: .caseInsensitive)
            .replacingOccurrences(of: " (Japan)", with: "", options: .caseInsensitive)
            .trimmingCharacters(in: .whitespaces)
    }

    private func loadLocalGalleryIndex() {
        let tsvPath = localRepoDir.appendingPathComponent("gallery.tsv")
        guard let content = try? String(contentsOf: tsvPath, encoding: .utf8) else { return }
        let lines = content.components(separatedBy: .newlines)
        for line in lines {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            if trimmed.isEmpty || trimmed.hasPrefix("#") { continue }
            let parts = trimmed.components(separatedBy: "\t")
            guard parts.count >= 2 else { continue }
            let filename = parts[0]
            let name = parts[1]
            let cleanName = normalizeString(name)
            galleryMapByTitle[cleanName] = filename
            if parts.count >= 4 {
                let tidCandidate = parts[3].trimmingCharacters(in: .whitespaces).uppercased()
                if tidCandidate.hasPrefix("0100") || tidCandidate.hasPrefix("0400") {
                    galleryMapByTid[tidCandidate] = filename
                }
            }
        }
    }

    /// On-demand lookup of TitleID entry from switch_titles_artwork.json using memory mapping.
    /// Does not materialize the 29,000-entry JSON into heap.
    public func lookupTitleDbEntry(for titleId: String) -> [String: String]? {
        let tidUpper = titleId.uppercased()
        lock.lock()
        if let cached = resolvedTitleEntries[tidUpper] {
            lock.unlock()
            return cached
        }
        lock.unlock()

        let candidates = [
            self.artworkDir.appendingPathComponent("switch_titles_artwork.json"),
            self.artworkDir.deletingLastPathComponent().appendingPathComponent("switch_titles_artwork.json"),
            self.localRepoDir.appendingPathComponent("switch_titles_artwork.json")
        ]
        guard let url = candidates.first(where: { fileManager.fileExists(atPath: $0.path) }),
              let fileData = try? Data(contentsOf: url, options: .mappedIfSafe) else {
            return nil
        }

        guard let needle = "\"\(tidUpper)\"".data(using: .utf8),
              let range = fileData.range(of: needle) else {
            return nil
        }

        let subdata = fileData[range.upperBound...]
        guard let openBraceIndex = subdata.firstIndex(of: UInt8(ascii: "{")) else {
            return nil
        }
        var depth = 0
        var closeBraceIndex: Data.Index? = nil
        for idx in openBraceIndex..<fileData.endIndex {
            let byte = fileData[idx]
            if byte == UInt8(ascii: "{") {
                depth += 1
            } else if byte == UInt8(ascii: "}") {
                depth -= 1
                if depth == 0 {
                    closeBraceIndex = idx
                    break
                }
            }
        }

        guard let endIdx = closeBraceIndex else { return nil }
        let objectSlice = fileData[openBraceIndex...endIdx]
        guard let obj = try? JSONSerialization.jsonObject(with: objectSlice) as? [String: Any] else {
            return nil
        }

        var result: [String: String] = [:]
        if let b = obj["banner"] as? String { result["banner"] = b }
        if let i = obj["icon"] as? String { result["icon"] = i }
        if let n = obj["name"] as? String { result["name"] = n }

        lock.lock()
        resolvedTitleEntries[tidUpper] = result
        lock.unlock()

        return result
    }

    private func fetchWidescreenHeroAsync(titleId: String) {
        let flightKey = "hero_\(titleId)"
        lock.lock()
        if inFlightDownloads.contains(flightKey) {
            lock.unlock()
            return
        }
        inFlightDownloads.insert(flightKey)
        lock.unlock()

        DispatchQueue.global(qos: .utility).async { [weak self] in
            guard let self = self else { return }
            guard let entry = self.lookupTitleDbEntry(for: titleId) else {
                self.lock.lock()
                self.inFlightDownloads.remove(flightKey)
                self.lock.unlock()
                return
            }
            // Strict clean presentation: use official high-res promotional banner or clean key icon; NEVER random ingame screenshots
            let bannerUrlString = entry["banner"] ?? entry["icon"]
            guard let urlStr = bannerUrlString, let url = URL(string: urlStr) else {
                self.lock.lock()
                self.inFlightDownloads.remove(flightKey)
                self.lock.unlock()
                return
            }

            let task = self.urlSession.dataTask(with: url) { [weak self] data, response, _ in
                guard let self = self else { return }
                defer {
                    self.lock.lock()
                    self.inFlightDownloads.remove(flightKey)
                    self.lock.unlock()
                }

                guard let http = response as? HTTPURLResponse, http.statusCode == 200,
                      let data = data,
                      let img = ImageDownsampler.downsample(data: data, maxPixelSize: 1024) ?? NSImage(data: data),
                      img.isValid, img.size.width >= 32, img.size.height >= 32,
                      !GameCoverService.shared.isScreenshotImage(img) else {
                    return
                }

                let destination = self.artworkDir.appendingPathComponent("\(titleId).jpg")
                try? data.write(to: destination, options: .atomic)

                DispatchQueue.main.async {
                    self.cacheHero(img, forKey: "hero_\(titleId)" as NSString)
                    self.refreshTrigger += 1
                }
            }
            task.resume()
        }
    }

    public func artworkUrls(for titleId: String) -> (icon: URL?, banner: URL?)? {
        let tid = titleId.uppercased()
        guard let entry = lookupTitleDbEntry(for: tid) else { return nil }
        let iconURL = entry["icon"].flatMap { URL(string: $0) }
        let bannerURL = (entry["banner"] ?? entry["icon"]).flatMap { URL(string: $0) }
        return (icon: iconURL, banner: bannerURL)
    }

    public func notifyArtworkUpdated(for key: String, titleId: String?) {
        let normalizedKey = key.uppercased()
        memoryCache.removeObject(forKey: "icon_\(normalizedKey)" as NSString)
        heroCache.removeObject(forKey: "hero_\(normalizedKey)" as NSString)
        if let tid = titleId?.uppercased() {
            memoryCache.removeObject(forKey: "icon_\(tid)" as NSString)
            heroCache.removeObject(forKey: "hero_\(tid)" as NSString)
        }
        DispatchQueue.main.async { [weak self] in
            guard let self = self else { return }
            self.refreshTrigger += 1
            self.notifyDebounceTimer?.invalidate()
            self.notifyDebounceTimer = Timer.scheduledTimer(withTimeInterval: 0.15, repeats: false) { [weak self] _ in
                self?.objectWillChange.send()
            }
        }
    }

    public func clearCache(for game: PortedGame) {
        let tid: String? = (game.platform == .nonSwitch)
            ? nil
            : (game.titleId ?? CompatibilityService.shared.findTitleId(forGameTitle: game.name))?.uppercased()
        let iconKey = "icon_\(tid ?? game.uniqueKey.uppercased())" as NSString
        let heroKey = "hero_\(tid ?? game.uniqueKey.uppercased())" as NSString
        memoryCache.removeObject(forKey: iconKey)
        heroCache.removeObject(forKey: heroKey)
        refreshTrigger += 1
        objectWillChange.send()
    }

    private func normalizeString(_ str: String) -> String {
        str.folding(options: [.diacriticInsensitive, .caseInsensitive], locale: .current)
            .components(separatedBy: CharacterSet.alphanumerics.inverted)
            .joined()
    }
}
