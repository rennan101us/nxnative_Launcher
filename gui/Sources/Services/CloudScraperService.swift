import Foundation

public final class CloudScraperService {
    public static let shared = CloudScraperService()
    
    private let session: URLSession
    private let titleIdRegex = try? NSRegularExpression(pattern: "\\b((?:0100|0400)[0-9A-Fa-f]{12})\\b", options: [.caseInsensitive])
    private let versionRegex = try? NSRegularExpression(pattern: "\\[v?([0-9]+(\\.[0-9]+)*)\\]|\\bv?([0-9]+\\.[0-9]+(\\.[0-9]+)*)\\b", options: [])
    
    private init() {
        let config = URLSessionConfiguration.default
        config.timeoutIntervalForRequest = 10.0
        config.timeoutIntervalForResource = 15.0
        config.httpAdditionalHeaders = [
            "User-Agent": "Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/18.0 Safari/605.1.15",
            "Accept": "text/html,application/xhtml+xml,application/xml,application/json;q=0.9,*/*;q=0.8"
        ]
        self.session = URLSession(configuration: config)
    }
    
    public var defaultUnderTheHoodSources: [CloudGameSource] {
        [
            CloudGameSource(
                name: "Mirror Nuvem (Switch 2)",
                urlString: "https://www.blueroms.ws/switch2",
                isEnabled: true
            ),
            CloudGameSource(
                name: "Mirror Nuvem (Switch)",
                urlString: "https://www.blueroms.ws/switch",
                isEnabled: true
            )
        ]
    }
    
    /// Scrapes all enabled sources in background and returns matched compatible games mapped by Title ID and all streams list.
    public func syncSources(
        _ sources: [CloudGameSource],
        compatibleGames: [CompatibleGameItem]
    ) async -> (matches: [String: CloudAvailableGame], streams: [String: [CloudAvailableGame]], updatedSources: [CloudGameSource]) {
        var results: [String: CloudAvailableGame] = [:]
        var streams: [String: [CloudAvailableGame]] = [:]
        var updatedSources: [CloudGameSource] = []
        
        // Ensure we have a populated compatible games list even if async fetch is still in flight
        var activeCompatList = compatibleGames
        if activeCompatList.isEmpty {
            activeCompatList = CompatibilityService.shared.cachedGames
        }
        if activeCompatList.isEmpty {
            let repoPath = SystemDetector.shared.detectNxnativeDirectory().path
            let localReadme = URL(fileURLWithPath: repoPath).appendingPathComponent("dm/games/README.md")
            if let text = try? String(contentsOfFile: localReadme.path, encoding: .utf8) {
                activeCompatList = CompatibilityService.shared.parseMarkdownTable(text)
            }
        }
        
        // Fast lookup index by upper-cased Title ID and normalized Title
        var compatByTitleId: [String: CompatibleGameItem] = [:]
        var compatByNormalizedTitle: [String: CompatibleGameItem] = [:]
        for game in activeCompatList {
            let tid = game.titleId.uppercased()
            compatByTitleId[tid] = game
            let norm = normalizeTitle(game.title)
            if !norm.isEmpty {
                compatByNormalizedTitle[norm] = game
            }
        }
        
        let userSourceIds = Set(sources.map { $0.id })
        var sourcesToProcess = sources
        for def in defaultUnderTheHoodSources {
            if !sourcesToProcess.contains(where: { $0.urlString == def.urlString }) {
                sourcesToProcess.append(def)
            }
        }
        
        for var source in sourcesToProcess {
            guard source.isEnabled else {
                if userSourceIds.contains(source.id) { updatedSources.append(source) }
                continue
            }
            
            // 1. Direct Magnet Link
            if source.urlString.hasPrefix("magnet:") {
                let sourceMatches = resolveDirectMagnet(
                    magnet: source.urlString,
                    source: source,
                    compatByTitleId: compatByTitleId,
                    compatByNormalizedTitle: compatByNormalizedTitle
                )
                for (tid, item) in sourceMatches {
                    if results[tid] == nil { results[tid] = item }
                    if streams[tid] == nil { streams[tid] = [] }
                    if !(streams[tid]?.contains(where: { $0.downloadURL == item.downloadURL }) ?? false) {
                        streams[tid]?.append(item)
                    }
                }
                source.lastItemCount = sourceMatches.count
                source.lastSyncDate = Date()
                source.lastErrorMessage = sourceMatches.isEmpty ? "Nenhum jogo compatível identificado no magnet" : nil
                if userSourceIds.contains(source.id) { updatedSources.append(source) }
                continue
            }
            
            guard let url = URL(string: source.urlString) else {
                source.lastErrorMessage = "URL inválida"
                if userSourceIds.contains(source.id) { updatedSources.append(source) }
                continue
            }
            
            do {
                var sourceMatches: [String: CloudAvailableGame] = [:]
                
                if isMediaFireFolder(url: url), let folderKey = extractMediaFireFolderKey(from: url) {
                    sourceMatches = try await resolveMediaFireFolder(
                        folderKey: folderKey,
                        source: source,
                        compatByTitleId: compatByTitleId,
                        compatByNormalizedTitle: compatByNormalizedTitle
                    )
                } else if isGoogleDriveFile(url: url), let fileId = extractGoogleDriveFileId(from: url) {
                    sourceMatches = try await resolveGoogleDriveFile(
                        fileId: fileId,
                        originalURL: url,
                        source: source,
                        compatByTitleId: compatByTitleId,
                        compatByNormalizedTitle: compatByNormalizedTitle
                    )
                } else {
                    // Check if BlueRoms root or categories
                    var urlsToFetch: [URL] = [url]
                    if (url.host?.contains("blueroms.ws") == true) && (url.path == "/" || url.path.isEmpty) {
                        if let s2 = URL(string: "https://www.blueroms.ws/switch2"),
                           let s1 = URL(string: "https://www.blueroms.ws/switch") {
                            urlsToFetch = [s2, s1]
                        }
                    } else if (url.host?.contains("nswpedia.com") == true) {
                        let subCategories = [
                            "https://nswpedia.com/nintendo-switch-roms",
                            "https://nswpedia.com/nintendo-switch-roms/adventure",
                            "https://nswpedia.com/nintendo-switch-roms/action",
                            "https://nswpedia.com/nintendo-switch-roms/rpg",
                            "https://nswpedia.com/nintendo-switch-roms/arcade"
                        ]
                        for sub in subCategories {
                            if let subU = URL(string: sub), !urlsToFetch.contains(subU) {
                                urlsToFetch.append(subU)
                            }
                        }
                    }
                    
                    for targetURL in urlsToFetch {
                        let (data, response) = try await session.data(from: targetURL)
                        let statusCode = (response as? HTTPURLResponse)?.statusCode ?? 200
                        guard statusCode >= 200 && statusCode < 400 else {
                            if sourceMatches.isEmpty {
                                source.lastErrorMessage = "HTTP \(statusCode)"
                            }
                            continue
                        }
                        
                        let subMatches = parseData(
                            data,
                            baseURL: targetURL,
                            source: source,
                            compatByTitleId: compatByTitleId,
                            compatByNormalizedTitle: compatByNormalizedTitle
                        )
                        for (tid, item) in subMatches {
                            if sourceMatches[tid] == nil {
                                sourceMatches[tid] = item
                            }
                        }
                    }
                }
                
                for (tid, item) in sourceMatches {
                    if results[tid] == nil {
                        results[tid] = item
                    }
                    if streams[tid] == nil { streams[tid] = [] }
                    if !(streams[tid]?.contains(where: { $0.downloadURL == item.downloadURL }) ?? false) {
                        streams[tid]?.append(item)
                    }
                }
                
                source.lastItemCount = sourceMatches.count
                source.lastSyncDate = Date()
                source.lastErrorMessage = nil
            } catch {
                source.lastErrorMessage = error.localizedDescription
            }
            if userSourceIds.contains(source.id) { updatedSources.append(source) }
        }
        
        return (results, streams, updatedSources)
    }
    
    /// Resolves all available streams for a specific game on demand across enabled sources.
    public func resolveStreamsForSingleGame(
        game: CompatibleGameItem,
        sources: [CloudGameSource]
    ) async -> [CloudAvailableGame] {
        var streams: [CloudAvailableGame] = []
        let tid = game.titleId.uppercased()
        let norm = normalizeTitle(game.title)
        
        var sourcesToQuery = sources.filter { $0.isEnabled }
        for def in defaultUnderTheHoodSources {
            if !sourcesToQuery.contains(where: { $0.urlString == def.urlString }) {
                sourcesToQuery.append(def)
            }
        }
        
        for source in sourcesToQuery {
            if source.urlString.hasPrefix("magnet:") {
                let found = resolveDirectMagnet(
                    magnet: source.urlString,
                    source: source,
                    compatByTitleId: [tid: game],
                    compatByNormalizedTitle: [norm: game]
                )
                if let item = found[tid] {
                    streams.append(item)
                }
            } else if let url = URL(string: source.urlString) {
                if isMediaFireFolder(url: url), let folderKey = extractMediaFireFolderKey(from: url) {
                    if let found = try? await resolveMediaFireFolder(
                        folderKey: folderKey,
                        source: source,
                        compatByTitleId: [tid: game],
                        compatByNormalizedTitle: [norm: game]
                    ), let item = found[tid] {
                        streams.append(item)
                    }
                } else {
                    var urlsToFetch: [URL] = [url]
                    if (url.host?.contains("blueroms.ws") == true) && (url.path == "/" || url.path.isEmpty) {
                        if let s2 = URL(string: "https://www.blueroms.ws/switch2"),
                           let s1 = URL(string: "https://www.blueroms.ws/switch") {
                            urlsToFetch = [s2, s1]
                        }
                    }
                    for targetURL in urlsToFetch {
                        guard let (data, resp) = try? await session.data(from: targetURL),
                              let http = resp as? HTTPURLResponse, http.statusCode < 400 else { continue }
                        let subMatches = parseData(
                            data,
                            baseURL: targetURL,
                            source: source,
                            compatByTitleId: [tid: game],
                            compatByNormalizedTitle: [norm: game]
                        )
                        if let item = subMatches[tid] {
                            if !streams.contains(where: { $0.downloadURL == item.downloadURL }) {
                                streams.append(item)
                            }
                        }
                    }
                }
            }
        }
        
        return streams
    }
    
    // MARK: - Direct Magnet Resolver
    public func resolveDirectMagnet(
        magnet: String,
        source: CloudGameSource,
        compatByTitleId: [String: CompatibleGameItem],
        compatByNormalizedTitle: [String: CompatibleGameItem]
    ) -> [String: CloudAvailableGame] {
        var matches: [String: CloudAvailableGame] = [:]
        
        // Extract dn= parameter
        var displayName = ""
        let pattern = "dn=([^&]+)"
        if let regex = try? NSRegularExpression(pattern: pattern, options: .caseInsensitive) {
            let nsStr = magnet as NSString
            let range = NSRange(location: 0, length: nsStr.length)
            if let match = regex.firstMatch(in: magnet, options: [], range: range), match.numberOfRanges > 1 {
                let rawDn = nsStr.substring(with: match.range(at: 1))
                displayName = rawDn.removingPercentEncoding ?? rawDn
            }
        }
        if displayName.isEmpty {
            displayName = source.name
        }
        
        // Find Title ID in magnet or dn
        var foundTitleId: String? = nil
        if let tidRegex = titleIdRegex {
            let targetSearch = displayName + " " + magnet
            let range = NSRange(location: 0, length: (targetSearch as NSString).length)
            if let tidMatch = tidRegex.firstMatch(in: targetSearch, options: [], range: range) {
                foundTitleId = (targetSearch as NSString).substring(with: tidMatch.range(at: 1)).uppercased()
            }
        }
        
        let matchedGame: CompatibleGameItem?
        if let tid = foundTitleId, let found = compatByTitleId[tid] {
            matchedGame = found
        } else {
            matchedGame = compatByNormalizedTitle[normalizeTitle(displayName)]
        }
        
        if let target = matchedGame {
            matches[target.titleId] = CloudAvailableGame(
                titleId: target.titleId,
                gameTitle: target.title,
                matchedVersion: target.versionTested,
                downloadURL: magnet,
                isTorrent: true,
                fileSizeFormatted: "",
                sourceId: source.id,
                sourceName: source.name
            )
        }
        
        return matches
    }
    
    // MARK: - Parser
    private func parseData(
        _ data: Data,
        baseURL: URL,
        source: CloudGameSource,
        compatByTitleId: [String: CompatibleGameItem],
        compatByNormalizedTitle: [String: CompatibleGameItem]
    ) -> [String: CloudAvailableGame] {
        var matches: [String: CloudAvailableGame] = [:]
        
        // 1. Try parsing as JSON Manifest
        if let json = try? JSONSerialization.jsonObject(with: data) {
            parseJSON(
                json,
                source: source,
                compatByTitleId: compatByTitleId,
                compatByNormalizedTitle: compatByNormalizedTitle,
                matches: &matches
            )
            if !matches.isEmpty {
                return matches
            }
        }
        
        // 2. Fallback to HTML / Open Directory scraping
        guard let html = String(data: data, encoding: .utf8) ?? String(data: data, encoding: .ascii) else {
            return matches
        }
        
        parseHTML(
            html,
            baseURL: baseURL,
            source: source,
            compatByTitleId: compatByTitleId,
            compatByNormalizedTitle: compatByNormalizedTitle,
            matches: &matches
        )
        
        return matches
    }
    
    private func parseJSON(
        _ json: Any,
        source: CloudGameSource,
        compatByTitleId: [String: CompatibleGameItem],
        compatByNormalizedTitle: [String: CompatibleGameItem],
        matches: inout [String: CloudAvailableGame]
    ) {
        let items: [[String: Any]]
        if let array = json as? [[String: Any]] {
            items = array
        } else if let dict = json as? [String: Any], let games = dict["games"] as? [[String: Any]] {
            items = games
        } else {
            return
        }
        
        for dict in items {
            let title = (dict["title"] as? String) ?? (dict["name"] as? String) ?? ""
            let tid = (dict["titleId"] as? String) ?? (dict["title_id"] as? String) ?? (dict["id"] as? String) ?? ""
            let url = (dict["url"] as? String) ?? (dict["downloadUrl"] as? String) ?? (dict["magnet"] as? String) ?? ""
            let ver = (dict["version"] as? String) ?? ""
            let size = (dict["size"] as? String) ?? ""
            
            guard !url.isEmpty else { continue }
            
            let matchedGame: CompatibleGameItem?
            if !tid.isEmpty, let found = compatByTitleId[tid.uppercased()] {
                matchedGame = found
            } else {
                matchedGame = compatByNormalizedTitle[normalizeTitle(title)]
            }
            
            if let target = matchedGame {
                let isTorrent = url.hasPrefix("magnet:") || url.hasSuffix(".torrent")
                matches[target.titleId] = CloudAvailableGame(
                    titleId: target.titleId,
                    gameTitle: target.title,
                    matchedVersion: ver.isEmpty ? target.versionTested : ver,
                    downloadURL: url,
                    isTorrent: isTorrent,
                    fileSizeFormatted: size,
                    sourceId: source.id,
                    sourceName: source.name
                )
            }
        }
    }
    
    private func parseHTML(
        _ html: String,
        baseURL: URL,
        source: CloudGameSource,
        compatByTitleId: [String: CompatibleGameItem],
        compatByNormalizedTitle: [String: CompatibleGameItem],
        matches: inout [String: CloudAvailableGame]
    ) {
        // Match all <a ... href="..." ...>(.*?)</a>
        let anchorPattern = "<a\\s+[^>]*href=[\"']([^\"']+)[\"'][^>]*>(.*?)</a>"
        guard let anchorRegex = try? NSRegularExpression(pattern: anchorPattern, options: [.caseInsensitive, .dotMatchesLineSeparators]) else {
            return
        }
        
        let nsString = html as NSString
        let matchesRange = anchorRegex.matches(in: html, options: [], range: NSRange(location: 0, length: nsString.length))
        
        for match in matchesRange {
            guard match.numberOfRanges > 2 else { continue }
            let link = nsString.substring(with: match.range(at: 1))
            let innerHTML = nsString.substring(with: match.range(at: 2))
            
            // Clean HTML tags from inner text & entities
            var cleanText = innerHTML.replacingOccurrences(of: "<[^>]+>", with: "", options: .regularExpression).trimmingCharacters(in: .whitespacesAndNewlines)
            cleanText = cleanText.replacingOccurrences(of: "&#[0-9]+;", with: " ", options: .regularExpression)
            cleanText = cleanText.replacingOccurrences(of: "&[a-zA-Z]+;", with: " ", options: .regularExpression)
            cleanText = cleanText.trimmingCharacters(in: .whitespacesAndNewlines)
            
            let isGameFile = link.hasSuffix(".nsp") || link.hasSuffix(".xci") || link.hasSuffix(".nsz") || link.hasSuffix(".zip") || link.hasSuffix(".7z") || link.hasPrefix("magnet:?xt=")
            let isGamePortal = link.contains("/game/") || link.contains("/rom/") || link.contains("/switch/") || link.contains("/switch2/") || link.contains("/games/") || link.contains("/nintendo-switch-roms/")
            
            guard isGameFile || isGamePortal else { continue }
            
            let resolvedURL: String
            if link.hasPrefix("http://") || link.hasPrefix("https://") || link.hasPrefix("magnet:") {
                resolvedURL = link
            } else if let abs = URL(string: link, relativeTo: baseURL) {
                resolvedURL = abs.absoluteString
            } else {
                resolvedURL = link
            }
            
            // 1. Try Title ID matching
            var foundTitleId: String? = nil
            if let tidRegex = titleIdRegex {
                let range = NSRange(location: 0, length: (link as NSString).length)
                if let tidMatch = tidRegex.firstMatch(in: link, options: [], range: range) {
                    foundTitleId = (link as NSString).substring(with: tidMatch.range(at: 1)).uppercased()
                }
            }
            
            var matchedGame: CompatibleGameItem? = nil
            if let tid = foundTitleId, let found = compatByTitleId[tid] {
                matchedGame = found
            } else {
                // 2. Try cleanText matching
                if !cleanText.isEmpty {
                    let normText = normalizeTitle(cleanText)
                    matchedGame = compatByNormalizedTitle[normText]
                }
                
                // 3. Try URL slug matching (e.g. /game/switch2/the_legend_of_zelda_ocarina_of_time_ or /nintendo-switch-roms/adventure/pokemon-legends-arceus-nsp-64)
                if matchedGame == nil {
                    let decoded = link.removingPercentEncoding ?? link
                    let lastComp = (decoded as NSString).lastPathComponent
                    var slugText = lastComp.replacingOccurrences(of: "_", with: " ").replacingOccurrences(of: "-", with: " ")
                    slugText = slugText.replacingOccurrences(of: "\\b(nsp|xci|nsz|rom|game)\\b", with: "", options: .regularExpression)
                    slugText = slugText.replacingOccurrences(of: "\\b\\d+\\b", with: "", options: .regularExpression)
                    matchedGame = compatByNormalizedTitle[normalizeTitle(slugText)]
                }
            }
            
            if let target = matchedGame {
                let isTorrent = resolvedURL.hasPrefix("magnet:") ||
                                resolvedURL.hasSuffix(".torrent") ||
                                (baseURL.host?.contains("blueroms.ws") == true) ||
                                resolvedURL.contains("blueroms.ws")
                
                // Don't overwrite if already matched
                if matches[target.titleId] == nil {
                    matches[target.titleId] = CloudAvailableGame(
                        titleId: target.titleId,
                        gameTitle: target.title,
                        matchedVersion: target.versionTested,
                        downloadURL: resolvedURL,
                        isTorrent: isTorrent,
                        fileSizeFormatted: "",
                        sourceId: source.id,
                        sourceName: source.name
                    )
                }
            }
        }
    }
    
    public func normalizeTitle(_ raw: String) -> String {
        var str = raw.lowercased()
        let patterns = [
            "\\.nsp$", "\\.xci$", "\\.nsz$", "\\.zip$", "\\.7z$",
            "\\[[^\\]]+\\]", "\\([^\\)]+\\)"
        ]
        for p in patterns {
            if let regex = try? NSRegularExpression(pattern: p, options: .caseInsensitive) {
                str = regex.stringByReplacingMatches(in: str, options: [], range: NSRange(location: 0, length: (str as NSString).length), withTemplate: "")
            }
        }
        let allowed = CharacterSet.alphanumerics
        return str.unicodeScalars.filter { allowed.contains($0) }.map(String.init).joined()
    }
    
    // MARK: - MediaFire Resolver (Free & Public Folder API)
    private func isMediaFireFolder(url: URL) -> Bool {
        (url.host?.contains("mediafire.com") == true) && url.path.contains("/folder/")
    }

    private func extractMediaFireFolderKey(from url: URL) -> String? {
        let components = url.pathComponents
        if let idx = components.firstIndex(of: "folder"), idx + 1 < components.count {
            return components[idx + 1]
        }
        return nil
    }

    private func resolveMediaFireFolder(
        folderKey: String,
        source: CloudGameSource,
        compatByTitleId: [String: CompatibleGameItem],
        compatByNormalizedTitle: [String: CompatibleGameItem]
    ) async throws -> [String: CloudAvailableGame] {
        guard let apiURL = URL(string: "https://www.mediafire.com/api/1.4/folder/get_content.php?folder_key=\(folderKey)&content_type=files&response_format=json") else {
            return [:]
        }
        let (data, _) = try await session.data(from: apiURL)
        guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let resp = json["response"] as? [String: Any],
              let folderContent = resp["folder_content"] as? [String: Any],
              let files = folderContent["files"] as? [[String: Any]] else {
            return [:]
        }
        
        var matches: [String: CloudAvailableGame] = [:]
        for file in files {
            guard let filename = file["filename"] as? String else { continue }
            let isGame = filename.hasSuffix(".nsp") || filename.hasSuffix(".xci") || filename.hasSuffix(".nsz") || filename.hasSuffix(".zip")
            guard isGame else { continue }
            
            let links = file["links"] as? [String: Any]
            let quickkey = file["quickkey"] as? String ?? ""
            let downloadLink = (links?["normal_download"] as? String) ?? "https://www.mediafire.com/file/\(quickkey)/\(filename)/file"
            
            let sizeBytesStr = (file["size"] as? String) ?? ""
            let sizeFormatted: String
            if let bytes = Int64(sizeBytesStr) {
                sizeFormatted = String(format: "%.1f GB", Double(bytes) / (1024 * 1024 * 1024))
            } else {
                sizeFormatted = ""
            }
            
            var foundTitleId: String? = nil
            if let tidRegex = titleIdRegex {
                let range = NSRange(location: 0, length: (filename as NSString).length)
                if let tidMatch = tidRegex.firstMatch(in: filename, options: [], range: range) {
                    foundTitleId = (filename as NSString).substring(with: tidMatch.range(at: 1)).uppercased()
                }
            }
            
            let matchedGame: CompatibleGameItem?
            if let tid = foundTitleId, let found = compatByTitleId[tid] {
                matchedGame = found
            } else {
                matchedGame = compatByNormalizedTitle[normalizeTitle(filename)]
            }
            
            if let target = matchedGame {
                matches[target.titleId] = CloudAvailableGame(
                    titleId: target.titleId,
                    gameTitle: target.title,
                    matchedVersion: target.versionTested,
                    downloadURL: downloadLink,
                    isTorrent: false,
                    fileSizeFormatted: sizeFormatted,
                    sourceId: source.id,
                    sourceName: source.name
                )
            }
        }
        return matches
    }

    // MARK: - Google Drive Resolver (Free & Public Direct File)
    private func isGoogleDriveFile(url: URL) -> Bool {
        (url.host?.contains("drive.google.com") == true) && (url.path.contains("/file/d/") || url.query?.contains("id=") == true)
    }

    private func extractGoogleDriveFileId(from url: URL) -> String? {
        let pattern = "(?:/file/d/|id=)([a-zA-Z0-9_-]{25,})"
        guard let regex = try? NSRegularExpression(pattern: pattern) else { return nil }
        let str = url.absoluteString
        let range = NSRange(location: 0, length: (str as NSString).length)
        if let match = regex.firstMatch(in: str, options: [], range: range), match.numberOfRanges > 1 {
            return (str as NSString).substring(with: match.range(at: 1))
        }
        return nil
    }

    private func resolveGoogleDriveFile(
        fileId: String,
        originalURL: URL,
        source: CloudGameSource,
        compatByTitleId: [String: CompatibleGameItem],
        compatByNormalizedTitle: [String: CompatibleGameItem]
    ) async throws -> [String: CloudAvailableGame] {
        let directURL = "https://drive.google.com/uc?export=download&id=\(fileId)&confirm=t"
        
        let (data, _) = try await session.data(from: originalURL)
        guard let html = String(data: data, encoding: .utf8) else { return [:] }
        
        var filename = ""
        if let titleStart = html.range(of: "<title>"), let titleEnd = html.range(of: " - Google Drive</title>") {
            filename = String(html[titleStart.upperBound..<titleEnd.lowerBound])
        }
        if filename.isEmpty {
            filename = source.name
        }
        
        var foundTitleId: String? = nil
        if let tidRegex = titleIdRegex {
            let range = NSRange(location: 0, length: (filename as NSString).length)
            if let tidMatch = tidRegex.firstMatch(in: filename, options: [], range: range) {
                foundTitleId = (filename as NSString).substring(with: tidMatch.range(at: 1)).uppercased()
            }
        }
        
        let matchedGame: CompatibleGameItem?
        if let tid = foundTitleId, let found = compatByTitleId[tid] {
            matchedGame = found
        } else {
            matchedGame = compatByNormalizedTitle[normalizeTitle(filename)]
        }
        
        guard let target = matchedGame else { return [:] }
        
        return [
            target.titleId: CloudAvailableGame(
                titleId: target.titleId,
                gameTitle: target.title,
                matchedVersion: target.versionTested,
                downloadURL: directURL,
                isTorrent: false,
                fileSizeFormatted: "",
                sourceId: source.id,
                sourceName: source.name
            )
        ]
    }
}
