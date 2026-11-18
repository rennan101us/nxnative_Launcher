import Foundation

public struct GitLabReleasePayload: Codable {
    public let tagName: String
    public let name: String
    public let description: String
    public let releasedAt: String?
    public let summary: String
    public let categories: [ReleaseHighlightCategory]
    public let fetchedAt: Date
    public let dmgAssetURL: String?
    public let sha256AssetURL: String?
    public let releaseWebURL: String?

    public init(
        tagName: String,
        name: String,
        description: String,
        releasedAt: String?,
        summary: String,
        categories: [ReleaseHighlightCategory],
        fetchedAt: Date,
        dmgAssetURL: String? = nil,
        sha256AssetURL: String? = nil,
        releaseWebURL: String? = nil
    ) {
        self.tagName = tagName
        self.name = name
        self.description = description
        self.releasedAt = releasedAt
        self.summary = summary
        self.categories = categories
        self.fetchedAt = fetchedAt
        self.dmgAssetURL = dmgAssetURL
        self.sha256AssetURL = sha256AssetURL
        self.releaseWebURL = releaseWebURL
    }
}

public final class GitLabReleaseNotesService {
    public static let shared = GitLabReleaseNotesService()
    private static let releasesAPIURL = "https://gitlab.com/api/v4/projects/88419597/releases?per_page=1"

    private let lock = NSLock()
    private var memoryCache: GitLabReleasePayload?
    private var rateLimitUntil: Date = .distantPast

    private init() {}

    private var cacheFileURL: URL {
        let appSupport = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? URL(fileURLWithPath: NSHomeDirectory()).appendingPathComponent("Library/Application Support")
        let dir = appSupport.appendingPathComponent("nxnative", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir.appendingPathComponent("gitlab_release_cache.json")
    }

    public func cachedPayload() -> GitLabReleasePayload? {
        lock.lock()
        if let mem = memoryCache {
            lock.unlock()
            return mem
        }
        lock.unlock()

        guard let data = try? Data(contentsOf: cacheFileURL),
              let decoded = try? JSONDecoder().decode(GitLabReleasePayload.self, from: data) else {
            return nil
        }

        lock.lock()
        memoryCache = decoded
        lock.unlock()
        return decoded
    }

    private func saveCache(_ payload: GitLabReleasePayload) {
        lock.lock()
        memoryCache = payload
        lock.unlock()

        if let data = try? JSONEncoder().encode(payload) {
            try? data.write(to: cacheFileURL, options: .atomic)
        }
    }

    /// Fetches the latest GitLab release (with 15-minute memory cache, 429 rate-limit protection, and disk fallback).
    public func fetchLatestRelease(
        token: String? = nil,
        force: Bool = false,
        completion: @escaping (GitLabReleasePayload?) -> Void
    ) {
        let cached = cachedPayload()
        lock.lock()
        let now = Date()
        let isRateLimited = now < rateLimitUntil
        let isFresh = !force && cached != nil && now.timeIntervalSince(cached!.fetchedAt) < 900
        lock.unlock()

        if isRateLimited || isFresh {
            completion(cached)
            return
        }

        guard let url = URL(string: Self.releasesAPIURL) else {
            completion(cached)
            return
        }

        var req = URLRequest(url: url)
        req.timeoutInterval = 4.0
        if let token = token, !token.isEmpty {
            req.addValue(token, forHTTPHeaderField: "PRIVATE-TOKEN")
        }

        URLSession.shared.dataTask(with: req) { [weak self] data, response, _ in
            guard let self = self else {
                completion(cached)
                return
            }

            if let http = response as? HTTPURLResponse, http.statusCode == 429 {
                let retryHeader = http.value(forHTTPHeaderField: "Retry-After")
                let cooldown = min(max(retryHeader.flatMap(TimeInterval.init) ?? 3600, 60), 7200)
                self.lock.lock()
                self.rateLimitUntil = Date().addingTimeInterval(cooldown)
                self.lock.unlock()
                completion(cached)
                return
            }

            guard let data = data,
                  let json = try? JSONSerialization.jsonObject(with: data) as? [[String: Any]],
                  let latest = json.first,
                  let tagName = latest["tag_name"] as? String else {
                completion(cached)
                return
            }

            let name = (latest["name"] as? String) ?? "NxNative Launcher \(tagName)"
            let description = (latest["description"] as? String) ?? ""
            let releasedAt = latest["released_at"] as? String
            let parsed = Self.parseReleaseMarkdown(description, tagName: tagName)
            let releaseWebURL = (latest["_links"] as? [String: Any])?["self"] as? String

            var dmgAssetURL: String? = nil
            var sha256AssetURL: String? = nil
            if let assets = latest["assets"] as? [String: Any],
               let links = assets["links"] as? [[String: Any]] {
                for link in links {
                    let linkName = ((link["name"] as? String) ?? "").lowercased()
                    let filepath = ((link["filepath"] as? String) ?? "").lowercased()
                    let direct = (link["direct_asset_url"] as? String) ?? (link["url"] as? String)
                    guard let resolvedURL = direct, !resolvedURL.isEmpty else { continue }
                    if sha256AssetURL == nil && (filepath.hasSuffix(".sha256") || linkName.hasSuffix(".sha256") || resolvedURL.lowercased().hasSuffix(".sha256")) {
                        sha256AssetURL = resolvedURL
                    } else if dmgAssetURL == nil && (filepath.hasSuffix(".dmg") || resolvedURL.lowercased().hasSuffix(".dmg") || linkName.contains(".dmg")) {
                        dmgAssetURL = resolvedURL
                    }
                }
            }

            let payload = GitLabReleasePayload(
                tagName: tagName,
                name: name,
                description: description,
                releasedAt: releasedAt,
                summary: parsed.summary,
                categories: parsed.categories,
                fetchedAt: Date(),
                dmgAssetURL: dmgAssetURL,
                sha256AssetURL: sha256AssetURL,
                releaseWebURL: releaseWebURL
            )
            self.saveCache(payload)
            completion(payload)
        }.resume()
    }

    /// Resolves the expected 64-hex SHA-256 digest for `version` via `.dmg.sha256` asset or GitLab Package Registry API.
    public func fetchExpectedSHA256(
        for version: String,
        sha256URL: String?,
        token: String? = nil,
        completion: @escaping (String?) -> Void
    ) {
        let cleanVer = version.trimmingCharacters(in: CharacterSet(charactersIn: "vV"))
        if let shaURLStr = sha256URL, !shaURLStr.isEmpty, let shaURL = URL(string: shaURLStr) {
            var req = URLRequest(url: shaURL)
            req.timeoutInterval = 8.0
            if let token = token, !token.isEmpty {
                req.addValue(token, forHTTPHeaderField: "PRIVATE-TOKEN")
            }
            URLSession.shared.dataTask(with: req) { [weak self] data, response, _ in
                if let http = response as? HTTPURLResponse, http.statusCode == 200,
                   let data = data,
                   let text = String(data: data, encoding: .utf8),
                   let digest = Self.extractHexSHA256(from: text) {
                    completion(digest)
                    return
                }
                self?.fetchPackageFileSHA256(version: cleanVer, token: token, completion: completion)
            }.resume()
            return
        }
        fetchPackageFileSHA256(version: cleanVer, token: token, completion: completion)
    }

    private func fetchPackageFileSHA256(
        version: String,
        token: String?,
        completion: @escaping (String?) -> Void
    ) {
        guard let encodedVer = version.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed),
              let pkgListURL = URL(string: "https://gitlab.com/api/v4/projects/88419597/packages?package_name=nxnative-launcher&package_version=\(encodedVer)") else {
            completion(nil)
            return
        }
        var req = URLRequest(url: pkgListURL)
        req.timeoutInterval = 6.0
        if let token = token, !token.isEmpty {
            req.addValue(token, forHTTPHeaderField: "PRIVATE-TOKEN")
        }
        URLSession.shared.dataTask(with: req) { data, response, _ in
            guard let http = response as? HTTPURLResponse, http.statusCode == 200,
                  let data = data,
                  let packages = try? JSONSerialization.jsonObject(with: data) as? [[String: Any]],
                  let pkgId = packages.first?["id"] as? Int,
                  let filesURL = URL(string: "https://gitlab.com/api/v4/projects/88419597/packages/\(pkgId)/package_files") else {
                completion(nil)
                return
            }
            var freq = URLRequest(url: filesURL)
            freq.timeoutInterval = 6.0
            if let token = token, !token.isEmpty {
                freq.addValue(token, forHTTPHeaderField: "PRIVATE-TOKEN")
            }
            URLSession.shared.dataTask(with: freq) { fdata, fresp, _ in
                guard let fhttp = fresp as? HTTPURLResponse, fhttp.statusCode == 200,
                      let fdata = fdata,
                      let files = try? JSONSerialization.jsonObject(with: fdata) as? [[String: Any]] else {
                    completion(nil)
                    return
                }
                for f in files {
                    let fname = ((f["file_name"] as? String) ?? "").lowercased()
                    if fname.hasSuffix(".dmg"), let sha = f["file_sha256"] as? String, sha.count == 64 {
                        completion(sha.lowercased())
                        return
                    }
                }
                completion(nil)
            }.resume()
        }.resume()
    }

    public static func extractHexSHA256(from text: String) -> String? {
        let pattern = "\\b([0-9a-fA-F]{64})\\b"
        guard let regex = try? NSRegularExpression(pattern: pattern) else { return nil }
        let range = NSRange(text.startIndex..<text.endIndex, in: text)
        guard let match = regex.firstMatch(in: text, range: range),
              let hexRange = Range(match.range(at: 1), in: text) else {
            return nil
        }
        return String(text[hexRange]).lowercased()
    }

    // MARK: - Markdown Parser

    public static func parseReleaseMarkdown(
        _ markdown: String,
        tagName: String
    ) -> (summary: String, categories: [ReleaseHighlightCategory]) {
        let lines = markdown.components(separatedBy: .newlines)
        var categories: [ReleaseHighlightCategory] = []

        var inRelevantSection = false
        var isPrimarySection = false
        var currentSectionTitle = ""

        var currentCategoryTitle: String?
        var currentCategorySummary: [String] = []
        var currentCategoryDetails: [String] = []
        var flatSectionItems: [(summary: String, detail: String)] = []

        func flushCurrentCategory() {
            if let title = currentCategoryTitle {
                let cleanTitle = stripMarkdown(title)
                let (icon, colorKey) = iconAndColor(for: cleanTitle)
                let summary = currentCategorySummary.isEmpty ? [cleanTitle] : Array(currentCategorySummary.prefix(4))
                let details = currentCategoryDetails.isEmpty ? [cleanTitle] : currentCategoryDetails
                categories.append(
                    ReleaseHighlightCategory(
                        title: cleanTitle,
                        icon: icon,
                        colorKey: colorKey,
                        summaryPoints: summary,
                        detailedPoints: details,
                        isPrimarySection: isPrimarySection
                    )
                )
                currentCategoryTitle = nil
                currentCategorySummary = []
                currentCategoryDetails = []
            }
        }

        func flushFlatSectionIfNeeded() {
            guard currentCategoryTitle == nil, !flatSectionItems.isEmpty, !currentSectionTitle.isEmpty else {
                flatSectionItems = []
                return
            }
            let cleanTitle = stripMarkdown(currentSectionTitle)
            let (icon, colorKey) = iconAndColor(for: cleanTitle)
            categories.append(
                ReleaseHighlightCategory(
                    title: cleanTitle,
                    icon: icon,
                    colorKey: colorKey,
                    summaryPoints: Array(flatSectionItems.map(\.summary).prefix(4)),
                    detailedPoints: flatSectionItems.map(\.detail),
                    isPrimarySection: isPrimarySection
                )
            )
            flatSectionItems = []
        }

        for rawLine in lines {
            let trimmed = rawLine.trimmingCharacters(in: .whitespaces)
            if trimmed.isEmpty || trimmed == "---" { continue }

            // Stop before user setup instructions
            if trimmed.hasPrefix("### ") {
                flushCurrentCategory()
                flushFlatSectionIfNeeded()

                let heading = trimmed.dropFirst(4).trimmingCharacters(in: .whitespaces)
                let lower = heading.lowercased()

                if lower.contains("user instructions") || lower.contains("first-time setup") {
                    inRelevantSection = false
                    continue
                }
                if lower.contains("official release") {
                    inRelevantSection = false
                    continue
                }

                inRelevantSection = true
                currentSectionTitle = heading
                isPrimarySection = lower.contains("highlights") || lower.contains("fixes in")
                continue
            }

            guard inRelevantSection else { continue }
            if trimmed.hasPrefix("#### ") { continue }

            // Indented sub-bullet: "  - **Title**: Description"
            if rawLine.hasPrefix("  - ") || rawLine.hasPrefix("    - ") || rawLine.hasPrefix("\t- ") {
                let content = trimmed.dropFirst(2).trimmingCharacters(in: .whitespaces)
                let (shortText, fullText) = splitSummaryAndDetail(from: content)
                if currentCategoryTitle != nil {
                    currentCategorySummary.append(shortText)
                    currentCategoryDetails.append(fullText)
                } else {
                    flatSectionItems.append((shortText, fullText))
                }
                continue
            }

            // Top-level bullet: "- **Title**: Description" or "- **Category**:"
            if trimmed.hasPrefix("- ") {
                let content = trimmed.dropFirst(2).trimmingCharacters(in: .whitespaces)

                // A category header ends with ":" (e.g., "- **🛡️ The Legend of Zelda...**:")
                if content.hasSuffix(":") {
                    flushCurrentCategory()
                    flushFlatSectionIfNeeded()
                    currentCategoryTitle = String(content.dropLast()).trimmingCharacters(in: .whitespaces)
                } else if let cat = currentCategoryTitle, !currentCategoryDetails.isEmpty {
                    // Switching from a category with sub-bullets to a standalone bullet
                    _ = cat
                    flushCurrentCategory()
                    let (shortText, fullText) = splitSummaryAndDetail(from: content)
                    flatSectionItems.append((shortText, fullText))
                } else if currentCategoryTitle != nil {
                    // Previous header had no sub-bullets yet; treat as a flat section item if it has body text
                    let prev = currentCategoryTitle!
                    currentCategoryTitle = nil
                    flatSectionItems.append((stripMarkdown(prev), stripMarkdown(prev)))
                    let (shortText, fullText) = splitSummaryAndDetail(from: content)
                    flatSectionItems.append((shortText, fullText))
                } else {
                    let (shortText, fullText) = splitSummaryAndDetail(from: content)
                    flatSectionItems.append((shortText, fullText))
                }
            }
        }

        flushCurrentCategory()
        flushFlatSectionIfNeeded()

        let primaryTitles = categories
            .filter(\.isPrimarySection)
            .map { stripLeadingEmoji($0.title) }
            .prefix(3)

        let summary: String
        if !primaryTitles.isEmpty {
            summary = primaryTitles.joined(separator: " • ")
        } else if let first = categories.first {
            summary = stripLeadingEmoji(first.title)
        } else {
            summary = "NxNative Launcher \(tagName)"
        }

        return (summary, categories)
    }

    private static func splitSummaryAndDetail(from markdownLine: String) -> (summary: String, detail: String) {
        let cleanFull = stripMarkdown(markdownLine)
        // Extract bold lead-in if present: "**Title**: Rest of description"
        if markdownLine.hasPrefix("**"),
           let endBold = markdownLine.range(of: "**", range: markdownLine.index(markdownLine.startIndex, offsetBy: 2)..<markdownLine.endIndex) {
            let lead = stripMarkdown(String(markdownLine[markdownLine.index(markdownLine.startIndex, offsetBy: 2)..<endBold.lowerBound]))
                .trimmingCharacters(in: CharacterSet(charactersIn: ": "))
            let afterBold = String(markdownLine[endBold.upperBound...])
                .trimmingCharacters(in: CharacterSet(charactersIn: ": "))
            let firstSentence = afterBold.components(separatedBy: ". ").first ?? afterBold
            let conciseBody = firstSentence.count > 95
                ? String(firstSentence.prefix(92)).trimmingCharacters(in: .whitespaces) + "..."
                : firstSentence
            let concise = lead.isEmpty ? conciseBody : (conciseBody.isEmpty ? lead : "\(lead): \(conciseBody)")
            return (concise, cleanFull)
        }

        let firstSentence = cleanFull.components(separatedBy: ". ").first ?? cleanFull
        let concise = firstSentence.count > 105
            ? String(firstSentence.prefix(102)).trimmingCharacters(in: .whitespaces) + "..."
            : firstSentence
        return (concise, cleanFull)
    }

    private static func stripMarkdown(_ text: String) -> String {
        var s = text
        // Convert [label](url) -> label
        if let regex = try? NSRegularExpression(pattern: "\\[([^\\]]+)\\]\\([^\\)]+\\)") {
            let range = NSRange(s.startIndex..<s.endIndex, in: s)
            s = regex.stringByReplacingMatches(in: s, range: range, withTemplate: "$1")
        }
        s = s.replacingOccurrences(of: "**", with: "")
        s = s.replacingOccurrences(of: "`", with: "")
        return s.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private static func stripLeadingEmoji(_ text: String) -> String {
        var scalars = text.unicodeScalars
        while let first = scalars.first,
              !first.isASCII && (first.properties.isEmojiPresentation || first.properties.isEmoji || first.value == 0xFE0F) {
            scalars.removeFirst()
        }
        return String(scalars).trimmingCharacters(in: .whitespaces)
    }

    private static func iconAndColor(for title: String) -> (icon: String, colorKey: String) {
        let lower = title.lowercased()
        if lower.contains("zelda") || lower.contains("oot") || lower.contains("shader") {
            return ("sparkles.tv", "blue")
        }
        if lower.contains("audit") || lower.contains("diag") || lower.contains("upstream") || lower.contains("sync") {
            return ("shield.lefthalf.filled.badge.checkmark", "green")
        }
        if lower.contains("diablo") || lower.contains("game") || lower.contains("controller") || lower.contains("gamepad") {
            return ("gamecontroller.fill", "pink")
        }
        if lower.contains("ios") || lower.contains("ipad") || lower.contains("afc") {
            return ("ipad.and.iphone", "purple")
        }
        if lower.contains("cloud") || lower.contains("save") || lower.contains("storage") {
            return ("icloud.and.arrow.up.fill", "teal")
        }
        if lower.contains("architecture") || lower.contains("liquid glass") || lower.contains("zero-hang") {
            return ("lock.shield.fill", "teal")
        }
        if lower.contains("engine") || lower.contains("metal") || lower.contains("performance") {
            return ("bolt.fill", "yellow")
        }
        return ("sparkles", "blue")
    }
}
