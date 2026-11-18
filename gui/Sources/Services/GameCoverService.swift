import Foundation
import AppKit
import SwiftUI
import Vision

public final class GameCoverService: ObservableObject {
    public static let shared = GameCoverService()

    private let memoryCache = NSCache<NSString, NSImage>()
    private let fileManager = FileManager.default
    private let cacheDirectory: URL
    private let coversRepoDirectory: URL
    private let lock = NSLock()

    private var inFlightDownloads = Set<String>()
    private var failedLookups = Set<String>()

    @Published public var refreshRevision: Int = 0

    /// Verified Title ID -> GameTDB 5-letter IDs (checked against official switchtdb.txt)
    public static var verifiedGameTDBIds: [String: [String]] {
        GameTDBVerifiedDatabase.ids
    }

    private init() {
        let appSup = SystemDetector.shared.appSupportDirectory
            .appendingPathComponent("covers", isDirectory: true)
        try? fileManager.createDirectory(at: appSup, withIntermediateDirectories: true)
        self.cacheDirectory = appSup

        let detected = SystemDetector.shared.detectNxnativeDirectory().path
        let repoImages = URL(fileURLWithPath: detected).appendingPathComponent("docs/images")
        if fileManager.fileExists(atPath: repoImages.path) {
            self.coversRepoDirectory = repoImages
        } else {
            self.coversRepoDirectory = URL(fileURLWithPath: "/Volumes/SSD FN501 PRO/Emulations/NativePort/nxnative/docs/images")
        }

        // Compact memory bounds: 40 covers or 10 MB max
        memoryCache.countLimit = 40
        memoryCache.totalCostLimit = 10 * 1024 * 1024
    }

    public func purgeMemoryCaches() {
        memoryCache.removeAllObjects()
    }

    private func cacheImage(_ img: NSImage, forKeys keys: [String]) {
        let approxBytes = Int(img.size.width * img.size.height * 4)
        var seen = Set<String>()
        for key in keys {
            let upper = key.uppercased()
            if seen.insert(upper).inserted {
                memoryCache.setObject(img, forKey: upper as NSString, cost: max(approxBytes, 1024))
            }
        }
    }

    private func getCachedImage(forKeys keys: [String]) -> NSImage? {
        for key in keys {
            if let cached = memoryCache.object(forKey: key.uppercased() as NSString) {
                return cached
            }
        }
        return nil
    }

    public func customCoverURL(for game: PortedGame) -> URL {
        let titleId: String? = (game.platform == .nonSwitch)
            ? nil
            : (game.titleId ?? CompatibilityService.shared.findTitleId(forGameTitle: game.name))?.uppercased()
        let key = (titleId ?? game.uniqueKey).uppercased()
        return cacheDirectory.appendingPathComponent("\(key).custom.jpg")
    }

    public func hasCustomCover(for game: PortedGame) -> Bool {
        fileManager.fileExists(atPath: customCoverURL(for: game).path)
    }

    public func setCustomCover(imageURL: URL, for game: PortedGame) -> Bool {
        let image: NSImage? = {
            if imageURL.pathExtension.lowercased() == "svg" {
                return NSImage(contentsOf: imageURL)
            }
            return ImageDownsampler.downsample(url: imageURL, maxPixelSize: 512) ?? NSImage(contentsOf: imageURL)
        }()
        guard let image = image else { return false }
        let titleId: String? = (game.platform == .nonSwitch)
            ? nil
            : (game.titleId ?? CompatibilityService.shared.findTitleId(forGameTitle: game.name))?.uppercased()
        let key = (titleId ?? game.uniqueKey).uppercased()
        let dest = customCoverURL(for: game)

        guard let jpgData = renderImageToJpegData(image: image, maxDimension: 512) else {
            return false
        }

        do {
            try jpgData.write(to: dest, options: .atomic)
            injectCoverIfPossible(sourceImageData: jpgData, targetAppURL: game.url)

            var keysToCache = [key]
            if let tid = titleId { keysToCache.append(tid) }
            cacheImage(image, forKeys: keysToCache)

            DispatchQueue.main.async {
                self.refreshRevision += 1
                self.objectWillChange.send()
                ArtworkStore.shared.notifyArtworkUpdated(for: key, titleId: titleId)
            }
            return true
        } catch {
            return false
        }
    }

    // MARK: - Custom Background Artwork

    public func customBackgroundURL(for game: PortedGame) -> URL {
        let titleId: String? = (game.platform == .nonSwitch)
            ? nil
            : (game.titleId ?? CompatibilityService.shared.findTitleId(forGameTitle: game.name))?.uppercased()
        let key = (titleId ?? game.uniqueKey).uppercased()
        return cacheDirectory.appendingPathComponent("\(key).custom_bg.jpg")
    }

    public func customBackgroundURL(titleId: String?, gameName: String) -> URL? {
        let tid = (titleId ?? CompatibilityService.shared.findTitleId(forGameTitle: gameName))?.uppercased()
        let key = (tid ?? (gameName.isEmpty ? nil : gameName.uppercased()))
        guard let validKey = key else { return nil }
        return cacheDirectory.appendingPathComponent("\(validKey).custom_bg.jpg")
    }

    public func hasCustomBackground(for game: PortedGame) -> Bool {
        fileManager.fileExists(atPath: customBackgroundURL(for: game).path)
    }

    public func hasCustomBackground(titleId: String?, gameName: String) -> Bool {
        guard let url = customBackgroundURL(titleId: titleId, gameName: gameName) else { return false }
        return fileManager.fileExists(atPath: url.path)
    }

    public func setCustomBackground(imageURL: URL, for game: PortedGame) -> Bool {
        let image: NSImage? = {
            if imageURL.pathExtension.lowercased() == "svg" {
                return NSImage(contentsOf: imageURL)
            }
            return ImageDownsampler.downsample(url: imageURL, maxPixelSize: 1920) ?? NSImage(contentsOf: imageURL)
        }()
        guard let image = image else { return false }

        let titleId: String? = (game.platform == .nonSwitch)
            ? nil
            : (game.titleId ?? CompatibilityService.shared.findTitleId(forGameTitle: game.name))?.uppercased()
        let key = (titleId ?? game.uniqueKey).uppercased()
        let dest = customBackgroundURL(for: game)

        guard let jpgData = renderImageToJpegData(image: image, maxDimension: 1920) else {
            return false
        }

        do {
            try jpgData.write(to: dest, options: .atomic)

            DispatchQueue.main.async {
                self.refreshRevision += 1
                self.objectWillChange.send()
                ArtworkStore.shared.notifyArtworkUpdated(for: key, titleId: titleId)
            }
            return true
        } catch {
            return false
        }
    }

    public func resetCustomBackground(for game: PortedGame) {
        let titleId: String? = (game.platform == .nonSwitch)
            ? nil
            : (game.titleId ?? CompatibilityService.shared.findTitleId(forGameTitle: game.name))?.uppercased()
        let key = (titleId ?? game.uniqueKey).uppercased()
        let dest = customBackgroundURL(for: game)
        try? fileManager.removeItem(at: dest)

        DispatchQueue.main.async {
            self.refreshRevision += 1
            self.objectWillChange.send()
            ArtworkStore.shared.notifyArtworkUpdated(for: key, titleId: titleId)
        }
    }

    public func backgroundImage(for game: PortedGame) -> NSImage? {
        if hasCustomBackground(for: game) {
            let customFile = customBackgroundURL(for: game)
            if let img = ImageDownsampler.downsample(url: customFile, maxPixelSize: 1920) ?? NSImage(contentsOf: customFile),
               img.isValid {
                return img
            }
        }
        return ArtworkStore.shared.loadWidescreenHero(for: game)
    }

    public func renderImageToJpegData(image: NSImage, maxDimension: CGFloat) -> Data? {
        let size = image.size
        guard size.width > 0, size.height > 0 else { return nil }
        let scale = min(1.0, maxDimension / max(size.width, size.height))
        let targetSize = NSSize(width: max(1, round(size.width * scale)), height: max(1, round(size.height * scale)))

        if let rep = NSBitmapImageRep(
            bitmapDataPlanes: nil,
            pixelsWide: Int(targetSize.width),
            pixelsHigh: Int(targetSize.height),
            bitsPerSample: 8,
            samplesPerPixel: 4,
            hasAlpha: true,
            isPlanar: false,
            colorSpaceName: .deviceRGB,
            bytesPerRow: 0,
            bitsPerPixel: 0
        ) {
            rep.size = targetSize
            NSGraphicsContext.saveGraphicsState()
            let ctx = NSGraphicsContext(bitmapImageRep: rep)
            NSGraphicsContext.current = ctx
            image.draw(in: NSRect(origin: .zero, size: targetSize), from: .zero, operation: .copy, fraction: 1.0)
            NSGraphicsContext.restoreGraphicsState()
            return rep.representation(using: .jpeg, properties: [.compressionFactor: 0.90])
        }

        guard let tiffData = image.tiffRepresentation,
              let bitmap = NSBitmapImageRep(data: tiffData) else {
            return nil
        }
        return bitmap.representation(using: .jpeg, properties: [.compressionFactor: 0.90])
    }

    public func resetCustomCover(for game: PortedGame) {
        let titleId: String? = (game.platform == .nonSwitch)
            ? nil
            : (game.titleId ?? CompatibilityService.shared.findTitleId(forGameTitle: game.name))?.uppercased()
        let key = (titleId ?? game.uniqueKey).uppercased()
        let dest = customCoverURL(for: game)
        try? fileManager.removeItem(at: dest)

        if game.url.pathExtension.lowercased() == "app" {
            let bundleCover = game.url.appendingPathComponent("Contents/Resources/cover.jpg")
            try? fileManager.removeItem(at: bundleCover)
        }

        memoryCache.removeObject(forKey: key as NSString)
        if let tid = titleId {
            memoryCache.removeObject(forKey: tid as NSString)
        }

        _ = coverImage(for: game)
        DispatchQueue.main.async {
            self.refreshRevision += 1
            self.objectWillChange.send()
            ArtworkStore.shared.notifyArtworkUpdated(for: key, titleId: titleId)
        }
    }

    public func isScreenshotImage(_ img: NSImage, titleId: String? = nil) -> Bool {
        // Switch 2 titles (0400...) use official 16:9 promotional key visual artwork
        if let tid = titleId?.uppercased(), tid.hasPrefix("0400") {
            return false
        }
        let w = img.size.width
        let h = img.size.height
        guard w > 0, h > 0 else { return false }
        let ratio = w / h
        return ratio >= 1.45 && ratio <= 1.95
    }

    public func coverImage(for game: PortedGame) -> NSImage? {
        let titleId: String? = (game.platform == .nonSwitch)
            ? nil
            : (game.titleId ?? CompatibilityService.shared.findTitleId(forGameTitle: game.name))?.uppercased()
        let key = (titleId ?? game.uniqueKey).uppercased()
        let isSwitch2 = game.isSwitch2 || (titleId?.hasPrefix("0400") == true)
        var lookupKeys = [key]
        if let tid = titleId { lookupKeys.append(tid) }

        if let memoryImage = getCachedImage(forKeys: lookupKeys) {
            return memoryImage
        }

        // 1. User custom cover
        let customFile = customCoverURL(for: game)
        if fileManager.fileExists(atPath: customFile.path),
           let img = ImageDownsampler.downsample(url: customFile, maxPixelSize: 384) ?? NSImage(contentsOf: customFile) {
            cacheImage(img, forKeys: lookupKeys)
            return img
        }

        // 2. Check disk cache in ~/Library/Application Support/nxnative/covers/<TitleID>.jpg (clean official artwork)
        if let tid = titleId, !tid.isEmpty {
            let cached = cacheDirectory.appendingPathComponent("\(tid).jpg")
            if fileManager.fileExists(atPath: cached.path),
               let rawImg = ImageDownsampler.downsample(url: cached, maxPixelSize: 384) ?? NSImage(contentsOf: cached),
               rawImg.isValid, rawImg.size.width >= 32, rawImg.size.height >= 32 {
                if !isSwitch2 && isScreenshotImage(rawImg, titleId: titleId) {
                    try? fileManager.removeItem(at: cached)
                } else {
                    let img: NSImage
                    if rawImg.size.height >= rawImg.size.width * 1.45, let rawData = try? Data(contentsOf: cached) {
                        let cleaned = cleanArtworkForCleanPresentation(from: rawImg, originalData: rawData)
                        img = cleaned.1
                        try? cleaned.0.write(to: cached, options: .atomic)
                    } else {
                        img = rawImg
                    }
                    cacheImage(img, forKeys: lookupKeys)
                    injectCoverIfPossible(sourceImageURL: cached, targetAppURL: game.url)
                    return img
                }
            }
        }

        // 3. Check game bundle's Contents/Resources for cover art
        let bundleResources = game.url.appendingPathComponent("Contents/Resources")
        for filename in ["cover.jpg", "cover.png", "coverHQ.jpg", "boxart.jpg"] {
            let bundleCover = bundleResources.appendingPathComponent(filename)
            if fileManager.fileExists(atPath: bundleCover.path),
               let rawImg = ImageDownsampler.downsample(url: bundleCover, maxPixelSize: 384) ?? NSImage(contentsOf: bundleCover),
               rawImg.isValid, rawImg.size.width >= 32, rawImg.size.height >= 32 {
                if isSwitch2 || !isScreenshotImage(rawImg, titleId: titleId) {
                    let img: NSImage
                    if rawImg.size.height >= rawImg.size.width * 1.45, let rawData = try? Data(contentsOf: bundleCover) {
                        let cleaned = cleanArtworkForCleanPresentation(from: rawImg, originalData: rawData)
                        img = cleaned.1
                        try? cleaned.0.write(to: bundleCover, options: .atomic)
                    } else {
                        img = rawImg
                    }
                    cacheImage(img, forKeys: lookupKeys)
                    return img
                }
            }
        }

        // 3.5 Check Switch 2 local promotional artwork repository (docs/images & gallery.tsv)
        if isSwitch2 {
            if let localCover = findLocalSwitch2Cover(forGameName: game.name, titleId: titleId) {
                if let rawImg = ImageDownsampler.downsample(url: localCover, maxPixelSize: 384) ?? NSImage(contentsOf: localCover),
                   rawImg.isValid, rawImg.size.width >= 32, rawImg.size.height >= 32 {
                    cacheImage(rawImg, forKeys: lookupKeys)
                    injectCoverIfPossible(sourceImageURL: localCover, targetAppURL: game.url)
                    return rawImg
                }
            }
        }

        // 4. For Non-Switch games, use high-resolution macOS application bundle icon
        if game.platform == .nonSwitch {
            let icon = NSWorkspace.shared.icon(forFile: game.url.path)
            icon.size = NSSize(width: 256, height: 256)
            cacheImage(icon, forKeys: lookupKeys)
            return icon
        }

        // 5. Asynchronously fetch from online databases (Prioritizing clean official box arts)
        fetchOfficialCoverAsync(titleId: titleId, gameName: game.name, targetAppURL: game.url, gameKey: key)
        return nil
    }

    public func ensureCover(for game: PortedGame) {
        if game.platform == .nonSwitch { return }
        if hasCustomCover(for: game) { return }
        let titleId = (game.titleId ?? CompatibilityService.shared.findTitleId(forGameTitle: game.name))?.uppercased()
        if let tid = titleId, !tid.isEmpty {
            let cached = cacheDirectory.appendingPathComponent("\(tid).jpg")
            if fileManager.fileExists(atPath: cached.path) {
                injectCoverIfPossible(sourceImageURL: cached, targetAppURL: game.url)
                return
            }
        }
        let bundleCover = game.url.appendingPathComponent("Contents/Resources/cover.jpg")
        if fileManager.fileExists(atPath: bundleCover.path) { return }
        _ = coverImage(for: game)
    }

    public func coverImage(titleId: String?, gameName: String) -> NSImage? {
        let resolvedId = (titleId ?? CompatibilityService.shared.findTitleId(forGameTitle: gameName))?.uppercased()
        let key = (resolvedId ?? gameName).uppercased()
        let isSwitch2 = (resolvedId?.hasPrefix("0400") == true)
        var lookupKeys = [key]
        if let tid = resolvedId { lookupKeys.append(tid) }

        if let memoryImage = getCachedImage(forKeys: lookupKeys) {
            return memoryImage
        }

        if let tid = resolvedId, !tid.isEmpty {
            let cached = cacheDirectory.appendingPathComponent("\(tid).jpg")
            if fileManager.fileExists(atPath: cached.path),
               let rawImg = ImageDownsampler.downsample(url: cached, maxPixelSize: 384) ?? NSImage(contentsOf: cached),
               rawImg.isValid, rawImg.size.width >= 32, rawImg.size.height >= 32 {
                if !isSwitch2 && isScreenshotImage(rawImg, titleId: resolvedId) {
                    try? fileManager.removeItem(at: cached)
                } else {
                    let img: NSImage
                    if rawImg.size.height >= rawImg.size.width * 1.45, let rawData = try? Data(contentsOf: cached) {
                        let cleaned = cleanArtworkForCleanPresentation(from: rawImg, originalData: rawData)
                        img = cleaned.1
                        try? cleaned.0.write(to: cached, options: .atomic)
                    } else {
                        img = rawImg
                    }
                    cacheImage(img, forKeys: lookupKeys)
                    return img
                }
            }
        }

        // Local repo clean covers check (docs/images/covers)
        if let localRepoCover = findLocalRepoCover(forGameName: gameName, titleId: resolvedId),
           let rawImg = ImageDownsampler.downsample(url: localRepoCover, maxPixelSize: 384) ?? NSImage(contentsOf: localRepoCover),
           rawImg.isValid, rawImg.size.width >= 32, rawImg.size.height >= 32 {
            if let tid = resolvedId, !tid.isEmpty {
                let cached = cacheDirectory.appendingPathComponent("\(tid).jpg")
                if !fileManager.fileExists(atPath: cached.path) {
                    try? fileManager.copyItem(at: localRepoCover, to: cached)
                }
            }
            cacheImage(rawImg, forKeys: lookupKeys)
            return rawImg
        }

        // Switch 2 local promotional artwork check
        if isSwitch2 {
            if let localCover = findLocalSwitch2Cover(forGameName: gameName, titleId: resolvedId) {
                if let rawImg = ImageDownsampler.downsample(url: localCover, maxPixelSize: 384) ?? NSImage(contentsOf: localCover),
                   rawImg.isValid, rawImg.size.width >= 32, rawImg.size.height >= 32 {
                    cacheImage(rawImg, forKeys: lookupKeys)
                    return rawImg
                }
            }
        }

        fetchOfficialCoverAsync(titleId: resolvedId, gameName: gameName, targetAppURL: nil, gameKey: key)
        return nil
    }

    public func injectCoverIntoBundle(at appURL: URL, gameName: String, titleId: String?) {
        let resolvedId = (titleId ?? CompatibilityService.shared.findTitleId(forGameTitle: gameName))?.uppercased()
        if let localCover = findLocalRepoCover(forGameName: gameName, titleId: resolvedId) {
            injectCoverIfPossible(sourceImageURL: localCover, targetAppURL: appURL)
        } else if let tid = resolvedId, !tid.isEmpty {
            let cached = cacheDirectory.appendingPathComponent("\(tid).jpg")
            if fileManager.fileExists(atPath: cached.path) {
                injectCoverIfPossible(sourceImageURL: cached, targetAppURL: appURL)
            }
        }
    }

    private func injectCoverIfPossible(sourceImageURL: URL, targetAppURL: URL) {
        guard targetAppURL.pathExtension.lowercased() == "app" else { return }
        let resources = targetAppURL.appendingPathComponent("Contents/Resources")
        let targetCover = resources.appendingPathComponent("cover.jpg")

        if !fileManager.fileExists(atPath: targetCover.path) && fileManager.fileExists(atPath: resources.path) {
            try? fileManager.copyItem(at: sourceImageURL, to: targetCover)
        }
    }

    private func injectCoverIfPossible(sourceImageData: Data, targetAppURL: URL) {
        guard targetAppURL.pathExtension.lowercased() == "app" else { return }
        let resources = targetAppURL.appendingPathComponent("Contents/Resources")
        let targetCover = resources.appendingPathComponent("cover.jpg")

        if !fileManager.fileExists(atPath: targetCover.path) && fileManager.fileExists(atPath: resources.path) {
            try? sourceImageData.write(to: targetCover)
        }
    }

    private func findLocalRepoCover(forGameName name: String, titleId: String?) -> URL? {
        let tidUpper = titleId?.uppercased()

        // Only check explicit clean covers directory, strictly rejecting in-game screenshots
        let coversDir = coversRepoDirectory.appendingPathComponent("covers")
        guard fileManager.fileExists(atPath: coversDir.path) else { return nil }

        if let tid = tidUpper, !tid.isEmpty {
            for ext in ["jpg", "png", "jpeg"] {
                let byId = coversDir.appendingPathComponent("\(tid).\(ext)")
                if fileManager.fileExists(atPath: byId.path),
                   let dims = ImageDownsampler.pixelDimensions(url: byId),
                   dims.width >= 32, dims.height >= 32 {
                    let ratio = dims.width / dims.height
                    let isScreenshot = !(tid.hasPrefix("0400")) && (ratio >= 1.45 && ratio <= 1.95)
                    if !isScreenshot {
                        return byId
                    }
                }
            }
        }

        let slug = slugify(name)
        if !slug.isEmpty {
            for ext in ["jpg", "png", "jpeg"] {
                let bySlug = coversDir.appendingPathComponent("\(slug).\(ext)")
                if fileManager.fileExists(atPath: bySlug.path),
                   let dims = ImageDownsampler.pixelDimensions(url: bySlug),
                   dims.width >= 32, dims.height >= 32 {
                    let ratio = dims.width / dims.height
                    let isScreenshot = (tidUpper?.hasPrefix("0400") != true) && (ratio >= 1.45 && ratio <= 1.95)
                    if !isScreenshot {
                        return bySlug
                    }
                }
            }
        }

        return nil
    }

    public func findLocalSwitch2Cover(forGameName name: String, titleId: String?) -> URL? {
        let tidUpper = titleId?.uppercased()

        // 1. Direct gallery mapping (gallery.tsv) for Switch 2 titles
        if let fn = ArtworkStore.shared.galleryFilename(for: tidUpper ?? name) ?? ArtworkStore.shared.galleryFilename(for: name) {
            for dir in [coversRepoDirectory, coversRepoDirectory.appendingPathComponent("covers")] {
                let localGallery = dir.appendingPathComponent(fn)
                if fileManager.fileExists(atPath: localGallery.path) {
                    return localGallery
                }
            }
        }

        // 2. Direct Title ID match in images or covers
        if let tid = tidUpper, !tid.isEmpty {
            for dir in [coversRepoDirectory, coversRepoDirectory.appendingPathComponent("covers")] {
                for ext in ["png", "jpg", "jpeg"] {
                    let byId = dir.appendingPathComponent("\(tid).\(ext)")
                    if fileManager.fileExists(atPath: byId.path) {
                        return byId
                    }
                }
            }
        }

        // 3. Slug match
        let slug = slugify(name)
        if !slug.isEmpty {
            for dir in [coversRepoDirectory, coversRepoDirectory.appendingPathComponent("covers")] {
                for ext in ["png", "jpg", "jpeg"] {
                    let bySlug = dir.appendingPathComponent("\(slug).\(ext)")
                    if fileManager.fileExists(atPath: bySlug.path) {
                        return bySlug
                    }
                }
            }
        }

        return nil
    }

    private func slugify(_ str: String) -> String {
        let folded = str.folding(options: [.diacriticInsensitive, .caseInsensitive], locale: .current)
        let allowed = CharacterSet.alphanumerics
        let clean = folded.unicodeScalars.map { allowed.contains($0) ? Character($0) : "-" }
        return String(clean)
            .components(separatedBy: "-")
            .filter { !$0.isEmpty }
            .joined(separator: "-")
            .lowercased()
    }

    private lazy var urlSession: URLSession = {
        let config = URLSessionConfiguration.ephemeral
        config.timeoutIntervalForRequest = 6.0
        config.timeoutIntervalForResource = 12.0
        config.httpMaximumConnectionsPerHost = 8
        return URLSession(configuration: config)
    }()

    private let prefetchQueue = DispatchQueue(label: "com.nxnative.coverPrefetch", qos: .utility)

    private struct CoverCandidate {
        let url: URL
        let skipStoreBrandingCheck: Bool
    }

    private var updateTimer: Timer? = nil
    private func scheduleBatchUpdateNotification() {
        DispatchQueue.main.async { [weak self] in
            guard let self = self else { return }
            self.updateTimer?.invalidate()
            self.updateTimer = Timer.scheduledTimer(withTimeInterval: 0.15, repeats: false) { [weak self] _ in
                self?.refreshRevision += 1
                self?.objectWillChange.send()
            }
        }
    }

    /// Proactively searches and caches cover artwork for any compatible game that does not have a cover on disk yet.
    public func ensureCoversForCompatibleGames(_ games: [CompatibleGameItem], forceRetryFailed: Bool = false) {
        if forceRetryFailed {
            lock.lock()
            failedLookups.removeAll()
            lock.unlock()
        }

        prefetchQueue.async { [weak self] in
            guard let self = self else { return }
            let semaphore = DispatchSemaphore(value: 4)

            for game in games {
                let tid = game.titleId.uppercased()
                let cached = self.cacheDirectory.appendingPathComponent("\(tid).jpg")
                if self.fileManager.fileExists(atPath: cached.path) {
                    continue
                }

                // Check local repo clean cover first (zero network needed)
                if let localRepoCover = self.findLocalRepoCover(forGameName: game.title, titleId: tid),
                   let data = try? Data(contentsOf: localRepoCover),
                   let img = ImageDownsampler.downsample(data: data, maxPixelSize: 384) ?? NSImage(data: data),
                   img.isValid, img.size.width >= 32, img.size.height >= 32 {
                    try? data.write(to: cached, options: .atomic)
                    self.cacheImage(img, forKeys: [tid])
                    self.scheduleBatchUpdateNotification()
                    ArtworkStore.shared.notifyArtworkUpdated(for: tid, titleId: tid)
                    continue
                }

                self.lock.lock()
                let shouldSkip = self.inFlightDownloads.contains(tid) || self.failedLookups.contains(tid)
                self.lock.unlock()
                if shouldSkip { continue }

                semaphore.wait()
                self.fetchOfficialCoverAsync(titleId: tid, gameName: game.title, targetAppURL: nil, gameKey: tid) {
                    semaphore.signal()
                }
            }
        }
    }

    private func cleanTitleForArtworkSearch(_ title: String) -> String {
        var cleaned = title
        let suffixes = [
            ", Asian release",
            ", Japanese release",
            ", Chinese release",
            " (Asian release)",
            " (Japanese release)",
            " (Chinese release)",
            " (Asian)",
            " (Japan)",
            " (base)"
        ]
        for sfx in suffixes {
            cleaned = cleaned.replacingOccurrences(of: sfx, with: "", options: .caseInsensitive)
        }
        return cleaned
            .replacingOccurrences(of: "\u{2122}", with: "")
            .replacingOccurrences(of: "\u{00AE}", with: "")
            .replacingOccurrences(of: "\u{00A9}", with: "")
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private func normalizeForTitleMatch(_ raw: String) -> String {
        raw.folding(options: [.diacriticInsensitive, .caseInsensitive], locale: .current)
            .unicodeScalars
            .filter { CharacterSet.alphanumerics.contains($0) }
            .map { String($0).lowercased() }
            .joined()
    }

    private func fetchOfficialCoverAsync(
        titleId: String?,
        gameName: String,
        targetAppURL: URL?,
        gameKey: String? = nil,
        onComplete: (() -> Void)? = nil
    ) {
        let tidUpper = titleId?.uppercased()
        let searchKey = (gameKey ?? tidUpper ?? gameName).uppercased()

        lock.lock()
        if inFlightDownloads.contains(searchKey) || failedLookups.contains(searchKey) {
            lock.unlock()
            onComplete?()
            return
        }
        inFlightDownloads.insert(searchKey)
        lock.unlock()

        DispatchQueue.global(qos: .utility).async { [weak self] in
            guard let self = self else {
                onComplete?()
                return
            }

            let cleanedName = self.cleanTitleForArtworkSearch(gameName)
            var candidates: [CoverCandidate] = []

            // 1. TOP PRIORITY: Official Nintendo CDN clean promotional icon & banner (switch_titles_artwork.json)
            var lookupTids: [String] = []
            if let tid = tidUpper { lookupTids.append(tid) }
            if !cleanedName.isEmpty,
               let baseTid = CompatibilityService.shared.findTitleId(forGameTitle: cleanedName)?.uppercased(),
               !lookupTids.contains(baseTid) {
                lookupTids.append(baseTid)
            }

            for lookupTid in lookupTids {
                if let entry = ArtworkStore.shared.lookupTitleDbEntry(for: lookupTid) {
                    if let iconUrlStr = entry["icon"], let iconUrl = URL(string: iconUrlStr) {
                        candidates.append(CoverCandidate(url: iconUrl, skipStoreBrandingCheck: true))
                    }
                    if let bannerUrlStr = entry["banner"], let bannerUrl = URL(string: bannerUrlStr) {
                        candidates.append(CoverCandidate(url: bannerUrl, skipStoreBrandingCheck: true))
                    }
                }
            }

            // 2. Upstream nxnative clean covers directory
            if let tid = tidUpper, !tid.isEmpty,
               let repoCoverURL = URL(string: "https://raw.githubusercontent.com/seedds/nxnative/main/docs/images/covers/\(tid).jpg") {
                candidates.append(CoverCandidate(url: repoCoverURL, skipStoreBrandingCheck: true))
            }

            // 3. High-Probability Libretro Named_Boxarts (Clean box arts)
            let libretroTitle = cleanedName.replacingOccurrences(of: ":", with: " -")
            if !libretroTitle.isEmpty {
                for suffix in ["", " (World)", " (USA)"] {
                    if let encoded = "\(libretroTitle)\(suffix).png".addingPercentEncoding(withAllowedCharacters: .urlPathAllowed),
                       let libretroURL = URL(string: "https://thumbnails.libretro.com/Nintendo%20-%20Switch/Named_Boxarts/\(encoded)") {
                        candidates.append(CoverCandidate(url: libretroURL, skipStoreBrandingCheck: false))
                    }
                }
            }

            // 4. Fallback GameTDB Box Arts (Switch 1 only, priority: coverHQ then cover)
            for lookupTid in lookupTids where lookupTid.hasPrefix("0100") {
                let gids = Self.verifiedGameTDBIds[lookupTid] ?? []
                for gid in gids {
                    for sub in ["coverHQ", "cover"] {
                        for reg in ["US", "EN", "JA"] {
                            if let u = URL(string: "https://art.gametdb.com/switch/\(sub)/\(reg)/\(gid).jpg") {
                                candidates.append(CoverCandidate(url: u, skipStoreBrandingCheck: false))
                            }
                        }
                    }
                }
            }

            let finishWithResult: (Data?, NSImage?) -> Void = { [weak self] data, img in
                guard let self = self else {
                    onComplete?()
                    return
                }
                defer {
                    self.lock.lock()
                    self.inFlightDownloads.remove(searchKey)
                    self.lock.unlock()
                    onComplete?()
                }

                guard let data = data, let img = img else {
                    self.lock.lock()
                    self.failedLookups.insert(searchKey)
                    self.lock.unlock()
                    return
                }

                if let tid = tidUpper {
                    let target = self.cacheDirectory.appendingPathComponent("\(tid).jpg")
                    try? data.write(to: target, options: .atomic)
                }
                if let appURL = targetAppURL {
                    self.injectCoverIfPossible(sourceImageData: data, targetAppURL: appURL)
                }

                var keysToCache = [searchKey]
                if let tid = tidUpper { keysToCache.append(tid) }
                self.cacheImage(img, forKeys: keysToCache)

                DispatchQueue.main.async {
                    self.scheduleBatchUpdateNotification()
                    ArtworkStore.shared.notifyArtworkUpdated(for: searchKey, titleId: tidUpper)
                }
            }

            self.tryFetchCandidate(candidates: candidates, index: 0, titleId: tidUpper) { [weak self] data, img in
                guard let self = self else {
                    onComplete?()
                    return
                }
                if let data = data, let img = img {
                    finishWithResult(data, img)
                    return
                }

                // 5. Dynamic Online Search Fallback (Nintendo eShop EU + Steam Store) for newly added titles
                self.searchOnlineCoverCandidates(gameName: cleanedName, titleId: tidUpper) { dynamicCandidates in
                    guard !dynamicCandidates.isEmpty else {
                        // Last-resort Switch 2 local promotional key art
                        if let tid = tidUpper, tid.hasPrefix("0400"),
                           let switch2URL = self.findLocalSwitch2Cover(forGameName: gameName, titleId: tid) {
                            self.tryFetchCandidate(
                                candidates: [CoverCandidate(url: switch2URL, skipStoreBrandingCheck: true)],
                                index: 0,
                                titleId: tidUpper,
                                completion: finishWithResult
                            )
                            return
                        }
                        finishWithResult(nil, nil)
                        return
                    }

                    self.tryFetchCandidate(candidates: dynamicCandidates, index: 0, titleId: tidUpper) { dynData, dynImg in
                        if let dynData = dynData, let dynImg = dynImg {
                            finishWithResult(dynData, dynImg)
                            return
                        }
                        if let tid = tidUpper, tid.hasPrefix("0400"),
                           let switch2URL = self.findLocalSwitch2Cover(forGameName: gameName, titleId: tid) {
                            self.tryFetchCandidate(
                                candidates: [CoverCandidate(url: switch2URL, skipStoreBrandingCheck: true)],
                                index: 0,
                                titleId: tidUpper,
                                completion: finishWithResult
                            )
                            return
                        }
                        finishWithResult(nil, nil)
                    }
                }
            }
        }
    }

    private func searchOnlineCoverCandidates(
        gameName: String,
        titleId: String?,
        completion: @escaping ([CoverCandidate]) -> Void
    ) {
        let targetNorm = normalizeForTitleMatch(gameName)
        guard !targetNorm.isEmpty,
              let encodedQuery = gameName.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) else {
            completion([])
            return
        }

        let isSwitch2 = (titleId?.hasPrefix("0400") == true)
        var results: [CoverCandidate] = []
        let group = DispatchGroup()
        let resultsLock = NSLock()

        // A. Nintendo Europe Official Search (supports Switch 1 & Switch 2)
        if let nintendoSearchURL = URL(string: "https://searching.nintendo-europe.com/en/select?q=\(encodedQuery)&fq=type:GAME&rows=8&wt=json") {
            group.enter()
            var req = URLRequest(url: nintendoSearchURL)
            req.setValue("Mozilla/5.0", forHTTPHeaderField: "User-Agent")
            urlSession.dataTask(with: req) { [weak self] data, response, _ in
                defer { group.leave() }
                guard let self = self,
                      let http = response as? HTTPURLResponse, http.statusCode == 200,
                      let data = data,
                      let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                      let respObj = json["response"] as? [String: Any],
                      let docs = respObj["docs"] as? [[String: Any]] else {
                    return
                }

                var scored: [(score: Int, urls: [URL])] = []
                for doc in docs {
                    let docTitle = (doc["title"] as? String) ?? ""
                    let docNorm = self.normalizeForTitleMatch(docTitle)
                    guard !docNorm.isEmpty else { continue }

                    var score = 0
                    if docNorm == targetNorm {
                        score += 100
                    } else if docNorm.hasPrefix(targetNorm) || targetNorm.hasPrefix(docNorm) {
                        let minLen = min(docNorm.count, targetNorm.count)
                        let maxLen = max(docNorm.count, targetNorm.count)
                        guard maxLen > 0, Double(minLen) / Double(maxLen) >= 0.72 else { continue }
                        score += 65
                    } else if (docNorm.contains(targetNorm) && targetNorm.count >= 6) || (targetNorm.contains(docNorm) && docNorm.count >= 6) {
                        score += 45
                    } else {
                        continue
                    }

                    let systems = (doc["system_names_txt"] as? [String]) ?? []
                    let hasSwitch2 = systems.contains { $0.localizedCaseInsensitiveContains("Switch 2") }
                    let hasSwitch1 = systems.contains { $0.localizedCaseInsensitiveContains("Nintendo Switch") && !$0.localizedCaseInsensitiveContains("Switch 2") }
                    if isSwitch2 && hasSwitch2 {
                        score += 30
                    } else if !isSwitch2 && hasSwitch1 {
                        score += 30
                    } else if hasSwitch1 || hasSwitch2 {
                        score += 15
                    }

                    var docUrls: [URL] = []
                    for field in ["image_url_sq_s", "image_url"] {
                        if var rawStr = doc[field] as? String, !rawStr.isEmpty {
                            if rawStr.hasPrefix("//") { rawStr = "https:" + rawStr }
                            if let u = URL(string: rawStr) {
                                docUrls.append(u)
                            }
                        }
                    }
                    if !docUrls.isEmpty {
                        scored.append((score: score, urls: docUrls))
                    }
                }

                scored.sort { $0.score > $1.score }
                let picked = scored.prefix(2).flatMap { $0.urls }.map { CoverCandidate(url: $0, skipStoreBrandingCheck: true) }
                resultsLock.lock()
                results.insert(contentsOf: picked, at: 0)
                resultsLock.unlock()
            }.resume()
        }

        // B. Steam Store Search API (multiplatform fallback for portrait 600x900 library covers)
        if let steamSearchURL = URL(string: "https://store.steampowered.com/api/storesearch/?term=\(encodedQuery)&l=english&cc=US") {
            group.enter()
            var req = URLRequest(url: steamSearchURL)
            req.setValue("Mozilla/5.0", forHTTPHeaderField: "User-Agent")
            urlSession.dataTask(with: req) { [weak self] data, response, _ in
                defer { group.leave() }
                guard let self = self,
                      let http = response as? HTTPURLResponse, http.statusCode == 200,
                      let data = data,
                      let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                      let items = json["items"] as? [[String: Any]] else {
                    return
                }

                var steamCandidates: [CoverCandidate] = []
                for item in items.prefix(5) {
                    guard let appId = item["id"] as? Int,
                          let itemName = item["name"] as? String else { continue }
                    let itemNorm = self.normalizeForTitleMatch(itemName)
                    let isCloseMatch = itemNorm == targetNorm ||
                        (targetNorm.count >= 6 && (itemNorm.hasPrefix(targetNorm) || targetNorm.hasPrefix(itemNorm)))
                    guard isCloseMatch else { continue }

                    if let u2x = URL(string: "https://shared.fastly.steamstatic.com/store_item_assets/steam/apps/\(appId)/library_600x900_2x.jpg") {
                        steamCandidates.append(CoverCandidate(url: u2x, skipStoreBrandingCheck: true))
                    }
                    if let uCap = URL(string: "https://shared.fastly.steamstatic.com/store_item_assets/steam/apps/\(appId)/library_capsule.jpg") {
                        steamCandidates.append(CoverCandidate(url: uCap, skipStoreBrandingCheck: true))
                    }
                    break
                }

                if !steamCandidates.isEmpty {
                    resultsLock.lock()
                    results.append(contentsOf: steamCandidates)
                    resultsLock.unlock()
                }
            }.resume()
        }

        group.notify(queue: DispatchQueue.global(qos: .utility)) {
            completion(results)
        }
    }

    /// Strips retail plastic console header banners, age ratings, and console logos from box arts,
    /// ensuring only pure game illustration and title logo are displayed (matching Steam Grid / Playnite clean room style).
    public func cleanArtworkForCleanPresentation(from image: NSImage, originalData: Data) -> (Data, NSImage) {
        return autoreleasepool {
            guard let cgImage = image.cgImage(forProposedRect: nil, context: nil, hints: nil) else {
                return (originalData, image)
            }
            let width = CGFloat(cgImage.width)
            let height = CGFloat(cgImage.height)
            
            // Only crop retail box art scans where aspect ratio indicates a vertical case (height >= width * 1.05)
            guard height >= width * 1.05 else {
                return (originalData, image)
            }
            
            let rep = NSBitmapImageRep(cgImage: cgImage)
            let w = rep.pixelsWide
            let h = rep.pixelsHigh
            
            // Dynamic Red Console Header Detection (Nintendo Switch red bar #E60012) with horizontal stride to avoid 350k NSColor allocations
            var lastRedY = 0
            let scanLimit = Int(Double(h) * 0.35)
            let xStep = max(1, w / 96)
            let sampleCount = max(1, (w + xStep - 1) / xStep)
            for y in 0..<scanLimit {
                var redCount = 0
                for x in stride(from: 0, to: w, by: xStep) {
                    if let c = rep.colorAt(x: x, y: y),
                       c.redComponent > 0.55 && c.greenComponent < 0.35 && c.blueComponent < 0.35 {
                        redCount += 1
                    }
                }
                if Double(redCount) / Double(sampleCount) > 0.55 {
                    lastRedY = y
                }
            }
            
            // Top cut: if solid red header found, cut through the last red row + 6px safety padding into the illustration.
            // If no solid red detected (e.g. monochromatic or dark header), enforce universal 18.5% console header standard.
            var topCut = CGFloat(lastRedY > 0 ? lastRedY + 6 : Int(Double(h) * 0.185))
            topCut = max(CGFloat(h) * 0.18, min(topCut, CGFloat(h) * 0.33))
            
            // Bottom cut: 9% removes publisher logos, Nintendo red oval mark, and ESRB/PEGI rating boxes.
            let bottomCut = CGFloat(h) * 0.09
            
            // Side cut: 2.5% removes plastic case bevel, shadows, and spine edges.
            let sideCut = CGFloat(w) * 0.025
            
            let cropRect = CGRect(
                x: sideCut,
                y: topCut,
                width: max(10, CGFloat(w) - (sideCut * 2)),
                height: max(10, CGFloat(h) - topCut - bottomCut)
            )
            
            guard let croppedCg = cgImage.cropping(to: cropRect) else {
                return (originalData, image)
            }
            
            let croppedRep = NSBitmapImageRep(cgImage: croppedCg)
            guard let jpgData = croppedRep.representation(using: .jpeg, properties: [.compressionFactor: 0.88]) else {
                return (originalData, image)
            }
            let cleanedImage = ImageDownsampler.downsample(data: jpgData, maxPixelSize: 384)
                ?? NSImage(cgImage: croppedCg, size: NSSize(width: cropRect.width, height: cropRect.height))
            return (jpgData, cleanedImage)
        }
    }

    public func containsForbiddenStoreBranding(in image: NSImage) -> Bool {
        // Never block the main UI thread with Vision OCR
        if Thread.isMainThread { return false }
        guard let cg = image.cgImage(forProposedRect: nil, context: nil, hints: nil) else { return false }
        let request = VNRecognizeTextRequest()
        request.recognitionLevel = .fast
        request.usesLanguageCorrection = false
        let handler = VNImageRequestHandler(cgImage: cg, options: [:])
        try? handler.perform([request])
        let forbidden = ["nintendo", "switch", "eshop", "e-shop", "joy-con", "joycon"]
        for obs in request.results ?? [] {
            let text = (obs.topCandidates(1).first?.string ?? "").lowercased()
            for word in forbidden {
                if text.contains(word) {
                    return true
                }
            }
        }
        return false
    }

    private func tryFetchCandidate(
        candidates: [CoverCandidate],
        index: Int,
        titleId: String? = nil,
        completion: @escaping (Data?, NSImage?) -> Void
    ) {
        guard index < candidates.count else {
            completion(nil, nil)
            return
        }
        let candidate = candidates[index]
        let url = candidate.url

        let processLoadedData: (Data) -> Void = { [weak self] d in
            guard let self = self else { return }
            guard !d.isEmpty,
                  let rawImg = ImageDownsampler.downsample(data: d, maxPixelSize: 512) ?? NSImage(data: d),
                  rawImg.isValid, rawImg.size.width >= 32, rawImg.size.height >= 32 else {
                self.tryFetchCandidate(candidates: candidates, index: index + 1, titleId: titleId, completion: completion)
                return
            }

            // Real-time Guard: reject in-game screenshots for non-Switch-2 titles
            if self.isScreenshotImage(rawImg, titleId: titleId) {
                self.tryFetchCandidate(candidates: candidates, index: index + 1, titleId: titleId, completion: completion)
                return
            }

            let (cleanedData, cleanedImg): (Data, NSImage)
            if rawImg.size.height >= rawImg.size.width * 1.15 {
                (cleanedData, cleanedImg) = self.cleanArtworkForCleanPresentation(from: rawImg, originalData: d)
            } else {
                (cleanedData, cleanedImg) = (d, rawImg)
            }

            // Real-time Vision Guard for retail box art scans (Libretro/GameTDB)
            if !candidate.skipStoreBrandingCheck && self.containsForbiddenStoreBranding(in: cleanedImg) {
                self.tryFetchCandidate(candidates: candidates, index: index + 1, titleId: titleId, completion: completion)
                return
            }

            completion(cleanedData, cleanedImg)
        }

        if url.isFileURL {
            if let d = try? Data(contentsOf: url) {
                processLoadedData(d)
            } else {
                tryFetchCandidate(candidates: candidates, index: index + 1, titleId: titleId, completion: completion)
            }
            return
        }

        let task = urlSession.dataTask(with: url) { [weak self] data, response, _ in
            guard let self = self else { return }
            if let http = response as? HTTPURLResponse, http.statusCode == 200, let d = data {
                processLoadedData(d)
            } else {
                self.tryFetchCandidate(candidates: candidates, index: index + 1, titleId: titleId, completion: completion)
            }
        }
        task.resume()
    }
}
