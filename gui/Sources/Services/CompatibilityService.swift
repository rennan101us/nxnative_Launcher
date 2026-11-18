import Foundation
import Darwin

public final class CompatibilityService {
    public static let shared = CompatibilityService()
    
    private let githubRawURL = URL(string: "https://raw.githubusercontent.com/seedds/nxnative/main/dm/games/README.md")!
    private let nx2androidRawURL = URL(string: "https://raw.githubusercontent.com/shirai91/nx2android/main/README.md")!
    public private(set) var cachedGames: [CompatibleGameItem] = []
    
    // Switch Titles Master Database (memory-mapped compact TSV index, 0 KB heap allocation)
    private var resolvedTitleIdCache: [String: String] = [:]
    private var unresolvedTitleNames: Set<String> = []
    private var cachedIndexURL: URL?
    private let titlesIndexLock = NSLock()
    
    private init() {
        // Do not eagerly load 29,000 titles into RAM on startup; use memory-mapped TSV index on demand
    }
    
    public func purgeTransientCaches() {
        malloc_zone_pressure_relief(nil, 0)
    }
    
    public func loadTitlesDatabaseIfNeeded() {
        _ = ensureTitlesIndexURL()
    }

    private func ensureTitlesIndexURL() -> URL? {
        titlesIndexLock.lock()
        if let existing = cachedIndexURL, FileManager.default.fileExists(atPath: existing.path) {
            titlesIndexLock.unlock()
            return existing
        }
        titlesIndexLock.unlock()

        let fm = FileManager.default
        if let bundleTSV = Bundle.main.url(forResource: "titles_norm_index_v1", withExtension: "tsv"),
           fm.fileExists(atPath: bundleTSV.path) {
            titlesIndexLock.lock()
            cachedIndexURL = bundleTSV
            titlesIndexLock.unlock()
            return bundleTSV
        }

        let appSup = SystemDetector.shared.appSupportDirectory
        let indexURL = appSup.appendingPathComponent("titles_norm_index_v1.tsv")

        if let attrs = try? fm.attributesOfItem(atPath: indexURL.path),
           let size = attrs[.size] as? UInt64,
           size > 100_000 {
            titlesIndexLock.lock()
            cachedIndexURL = indexURL
            titlesIndexLock.unlock()
            return indexURL
        }

        let detectedRepoURL = URL(fileURLWithPath: SystemDetector.shared.detectNxnativeDirectory().path, isDirectory: true)
        let candidates = [
            appSup.appendingPathComponent("switch_titles_artwork.json"),
            appSup.appendingPathComponent("artwork/switch_titles_artwork.json"),
            detectedRepoURL.appendingPathComponent("docs/images/switch_titles_artwork.json"),
            Bundle.main.url(forResource: "switch_titles_artwork", withExtension: "json"),
            URL(fileURLWithPath: "/Volumes/SSD FN501 PRO/Emulations/NativePort/nxnative/docs/images/switch_titles_artwork.json")
        ].compactMap { $0 }

        guard let jsonURL = candidates.first(where: { fm.fileExists(atPath: $0.path) }) else {
            return nil
        }

        // Stream-parse switch_titles_artwork.json without materializing 29,000 dictionaries into the heap
        titlesIndexLock.lock()
        defer { titlesIndexLock.unlock() }
        if fm.fileExists(atPath: indexURL.path),
           let attrs = try? fm.attributesOfItem(atPath: indexURL.path),
           let size = attrs[.size] as? UInt64, size > 100_000 {
            cachedIndexURL = indexURL
            return indexURL
        }

        autoreleasepool {
            guard let data = try? Data(contentsOf: jsonURL, options: .mappedIfSafe),
                  let content = String(data: data, encoding: .utf8) else { return }
            try? fm.createDirectory(at: appSup, withIntermediateDirectories: true)
            var out = String()
            out.reserveCapacity(1_300_000)

            var currentTid: String? = nil
            for rawLine in content.split(omittingEmptySubsequences: true, whereSeparator: \.isNewline) {
                autoreleasepool {
                    let line = rawLine.trimmingCharacters(in: .whitespaces)
                    if line.count >= 20, line.first == "\"", line.hasSuffix("{") {
                        let start = line.index(after: line.startIndex)
                        if let endQuote = line[start...].firstIndex(of: "\"") {
                            let key = String(line[start..<endQuote]).uppercased()
                            if key.count == 16 {
                                currentTid = key
                            }
                        }
                    } else if let tid = currentTid, line.hasPrefix("\"name\":") {
                        if let colonIdx = line.firstIndex(of: ":") {
                            var valSlice = line[line.index(after: colonIdx)...].trimmingCharacters(in: .whitespaces)
                            if valSlice.hasSuffix(",") {
                                valSlice.removeLast()
                            }
                            if let jsonData = "[\(valSlice)]".data(using: .utf8),
                               let arr = (try? JSONSerialization.jsonObject(with: jsonData)) as? [String],
                               let decodedName = arr.first, !decodedName.isEmpty {
                                let words = tokenizeWords(decodedName)
                                var uniqueWords: [String] = []
                                for w in words where !uniqueWords.contains(w) {
                                    uniqueWords.append(w)
                                }
                                let norm = uniqueWords.joined(separator: " ")
                                if !norm.isEmpty {
                                    out.append(tid)
                                    out.append("\t")
                                    out.append(norm)
                                    out.append("\n")
                                }
                            }
                        }
                        currentTid = nil
                    }
                }
            }
            if !out.isEmpty {
                try? out.write(to: indexURL, atomically: true, encoding: .utf8)
                cachedIndexURL = indexURL
            }
        }
        malloc_zone_pressure_relief(nil, 0)
        return cachedIndexURL
    }
    
    private func tokenizeWords(_ raw: String) -> [String] {
        let folded = raw.folding(options: [.diacriticInsensitive, .caseInsensitive], locale: .current)
        let cleaned = folded
            .replacingOccurrences(of: "\u{2122}", with: "")
            .replacingOccurrences(of: "\u{00AE}", with: "")
            .replacingOccurrences(of: "\u{00A9}", with: "")
            .replacingOccurrences(of: ":", with: " ")
            .replacingOccurrences(of: "-", with: " ")
            .replacingOccurrences(of: "–", with: " ")
            .replacingOccurrences(of: "—", with: " ")
            .replacingOccurrences(of: "_", with: " ")
            .replacingOccurrences(of: "+", with: " ")
        
        let stopWords: Set<String> = [
            "the", "of", "and", "edition", "nintendo", "switch", "2", "hd",
            "remastered", "definitive", "complete", "reimagined", "asian", "release",
            "version", "bundle", "pack", "collection"
        ]
        
        let components = cleaned.components(separatedBy: CharacterSet.alphanumerics.inverted)
            .filter { !$0.isEmpty }
            .map { $0.lowercased() }
        
        let filtered = components.filter { !stopWords.contains($0) }
        return filtered.isEmpty ? components : filtered
    }
    
    public func fetchCompatibleGames(
        localNxnativePath: String? = nil,
        completion: @escaping ([CompatibleGameItem], Bool) -> Void
    ) {
        let group = DispatchGroup()
        let syncLock = NSLock()

        var seeddsMarkdown: String? = nil
        var nx2aMarkdown: String? = nil

        // 1. Fetch seedds/nxnative (Mac & iOS) live from GitHub
        var req1 = URLRequest(url: githubRawURL)
        req1.timeoutInterval = 7.0
        req1.cachePolicy = .reloadIgnoringLocalCacheData
        group.enter()
        URLSession.shared.dataTask(with: req1) { data, _, _ in
            defer { group.leave() }
            if let d = data, let text = String(data: d, encoding: .utf8), !text.isEmpty {
                syncLock.lock()
                seeddsMarkdown = text
                syncLock.unlock()
            }
        }.resume()

        // 2. Fetch shirai91/nx2android (Android) live from GitHub
        var req2 = URLRequest(url: nx2androidRawURL)
        req2.timeoutInterval = 7.0
        req2.cachePolicy = .reloadIgnoringLocalCacheData
        group.enter()
        URLSession.shared.dataTask(with: req2) { data, _, _ in
            defer { group.leave() }
            if let d = data, let text = String(data: d, encoding: .utf8), !text.isEmpty {
                syncLock.lock()
                nx2aMarkdown = text
                syncLock.unlock()
            }
        }.resume()

        group.notify(queue: DispatchQueue.global(qos: .userInitiated)) { [weak self] in
            guard let self = self else { return }

            let isOnline = (seeddsMarkdown != nil || nx2aMarkdown != nil)
            var baseGames: [CompatibleGameItem] = []

            if let text = seeddsMarkdown {
                baseGames = self.parseMarkdownTable(text)
            }

            self.loadFromLocal(nxnativePath: localNxnativePath) { localGames in
                if baseGames.isEmpty {
                    baseGames = localGames
                } else {
                    let existingIds = Set(baseGames.map { $0.titleId.uppercased() })
                    let extras = localGames.filter { !existingIds.contains($0.titleId.uppercased()) }
                    if !extras.isEmpty {
                        baseGames.append(contentsOf: extras)
                    }
                }

                let resolvedNx2aText = nx2aMarkdown ?? self.loadLocalNx2AndroidReadme(nxnativePath: localNxnativePath)
                let androidEntries = resolvedNx2aText.map { self.parseNx2AndroidMarkdown($0) } ?? []
                let merged = self.mergeAndroidCompatibility(
                    into: baseGames,
                    androidEntries: androidEntries,
                    nxnativePath: localNxnativePath
                )

                self.cachedGames = merged
                DispatchQueue.main.async {
                    completion(merged, isOnline)
                }
            }
        }
    }

    public struct AndroidCompatEntry {
        public let title: String
        public let versionSummary: String
        public let gpuTier: AndroidGpuTier
        public let androidReq: String
    }

    private func loadLocalNx2AndroidReadme(nxnativePath: String?) -> String? {
        var candidates: [String] = []
        if let p = nxnativePath, !p.isEmpty {
            candidates.append(URL(fileURLWithPath: p).appendingPathComponent("tools/nx2android/README.md").path)
        }
        let detected = SystemDetector.shared.detectNxnativeDirectory().path
        if !detected.isEmpty {
            candidates.append(URL(fileURLWithPath: detected).appendingPathComponent("tools/nx2android/README.md").path)
        }
        candidates.append(
            SystemDetector.shared.appSupportDirectory
                .deletingLastPathComponent()
                .appendingPathComponent("nx2android/README.md").path
        )
        candidates.append("/Volumes/SSD FN501 PRO/Emulations/NativePort/nxnative/tools/nx2android/README.md")

        for path in candidates where FileManager.default.fileExists(atPath: path) {
            if let text = try? String(contentsOfFile: path, encoding: .utf8), !text.isEmpty {
                return text
            }
        }
        return nil
    }

    private func loadNx2AndroidLocalTitleIdMap(nxnativePath: String?) -> [String: String] {
        var baseCandidates: [String] = []
        if let p = nxnativePath, !p.isEmpty {
            baseCandidates.append(URL(fileURLWithPath: p).appendingPathComponent("tools/nx2android/nxnative/dm/games").path)
        }
        let detected = SystemDetector.shared.detectNxnativeDirectory().path
        if !detected.isEmpty {
            baseCandidates.append(URL(fileURLWithPath: detected).appendingPathComponent("tools/nx2android/nxnative/dm/games").path)
        }
        baseCandidates.append("/Volumes/SSD FN501 PRO/Emulations/NativePort/nxnative/tools/nx2android/nxnative/dm/games")

        let fm = FileManager.default
        var map: [String: String] = [:]
        guard let gamesDir = baseCandidates.first(where: { fm.fileExists(atPath: $0) }),
              let subdirs = try? fm.contentsOfDirectory(atPath: gamesDir) else {
            return map
        }

        for dir in subdirs {
            let tid = dir.uppercased()
            guard tid.count == 16 else { continue }
            let gameTsv = URL(fileURLWithPath: gamesDir).appendingPathComponent(dir).appendingPathComponent("game.tsv").path
            guard let content = try? String(contentsOfFile: gameTsv, encoding: .utf8) else { continue }
            for line in content.components(separatedBy: .newlines) {
                if line.hasPrefix("name\t") {
                    let rawName = String(line.dropFirst(5)).trimmingCharacters(in: .whitespacesAndNewlines)
                    let norm = strictAlphaNum(rawName)
                    if !norm.isEmpty {
                        map[norm] = tid
                    }
                    // Handle multilingual titles like "歧路旅人0 OCTOPATH TRAVELER 0"
                    let asciiParts = rawName.components(separatedBy: CharacterSet(charactersIn: "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789:-' ").inverted)
                        .joined(separator: " ")
                        .trimmingCharacters(in: .whitespacesAndNewlines)
                    let asciiNorm = strictAlphaNum(asciiParts)
                    if !asciiNorm.isEmpty && map[asciiNorm] == nil {
                        map[asciiNorm] = tid
                    }
                    break
                }
            }
        }
        return map
    }

    public func parseNx2AndroidMarkdown(_ markdown: String) -> [AndroidCompatEntry] {
        // Scope strictly to the ## Games section of shirai91/nx2android README.md
        let sectionText: String
        if let startRange = markdown.range(of: "## Games") {
            let tail = markdown[startRange.upperBound...]
            if let endRange = tail.range(of: "\n## ") {
                sectionText = String(tail[..<endRange.lowerBound])
            } else {
                sectionText = String(tail)
            }
        } else {
            sectionText = markdown
        }

        let pattern = #"!\[[^\]]*\]\([^)]+\)<br>([^<\n]+)<br><sub>([^<]+)</sub>"#
        guard let regex = try? NSRegularExpression(pattern: pattern, options: []) else {
            return []
        }

        let ns = sectionText as NSString
        let matches = regex.matches(in: sectionText, options: [], range: NSRange(location: 0, length: ns.length))
        var results: [AndroidCompatEntry] = []

        for m in matches {
            guard m.numberOfRanges >= 3 else { continue }
            let rawTitle = ns.substring(with: m.range(at: 1)).trimmingCharacters(in: .whitespacesAndNewlines)
            let rawSub = ns.substring(with: m.range(at: 2))
                .replacingOccurrences(of: "`", with: "")
                .trimmingCharacters(in: .whitespacesAndNewlines)

            guard !rawTitle.isEmpty else { continue }

            let subLower = rawSub.lowercased()
            let gpuTier: AndroidGpuTier
            if subLower.contains("adreno 830") || subLower.contains("snapdragon 8 elite") {
                gpuTier = .adrenoElite
            } else if subLower.contains("adreno 640") || subLower.contains("adreno 6xx") {
                gpuTier = .adrenoMid
            } else if subLower.contains("xclipse") {
                gpuTier = .xclipse
            } else {
                gpuTier = .adrenoHigh
            }

            // Build concise version string (e.g. "v0.4.0 · update 1.0.7")
            let parts = rawSub.components(separatedBy: " · ")
            let conciseVer = parts.prefix(2).joined(separator: " · ").trimmingCharacters(in: .whitespacesAndNewlines)

            results.append(
                AndroidCompatEntry(
                    title: rawTitle,
                    versionSummary: conciseVer.isEmpty ? "nx2android" : conciseVer,
                    gpuTier: gpuTier,
                    androidReq: "Android: \(gpuTier.rawValue)"
                )
            )
        }
        return results
    }

    private func strictAlphaNum(_ raw: String) -> String {
        raw.folding(options: [.diacriticInsensitive, .caseInsensitive], locale: .current)
            .unicodeScalars
            .filter { CharacterSet.alphanumerics.contains($0) }
            .map { String($0).lowercased() }
            .joined()
    }

    private func stripRegionalSuffix(_ title: String) -> String {
        var s = title
        let suffixes = [
            ", Asian release",
            ", Japanese release",
            ", Chinese release",
            " (Asian release)",
            " (Japanese release)",
            " (Chinese release)",
            " (Asian)",
            " (Japan)"
        ]
        for sfx in suffixes {
            s = s.replacingOccurrences(of: sfx, with: "", options: .caseInsensitive)
        }
        return s.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private func mergeAndroidCompatibility(
        into baseGames: [CompatibleGameItem],
        androidEntries: [AndroidCompatEntry],
        nxnativePath: String?
    ) -> [CompatibleGameItem] {
        var merged = baseGames.map { item -> CompatibleGameItem in
            var copy = item
            copy.isAndroidSupported = false
            return copy
        }

        // If nx2android list couldn't be parsed at all, return baseGames with isAndroidSupported = false
        guard !androidEntries.isEmpty else {
            return merged
        }

        let nx2aTidMap = loadNx2AndroidLocalTitleIdMap(nxnativePath: nxnativePath)
        var tidToIndex: [String: Int] = [:]
        var normToIndex: [String: Int] = [:]
        for (idx, item) in merged.enumerated() {
            tidToIndex[item.titleId.uppercased()] = idx
            let lowerTitle = item.title.lowercased()
            let isRegionalVariant = lowerTitle.contains("asian release") || lowerTitle.contains("japanese release") || lowerTitle.contains("chinese release")
            if !isRegionalVariant {
                let n = strictAlphaNum(item.title)
                if !n.isEmpty && normToIndex[n] == nil {
                    normToIndex[n] = idx
                }
            }
        }

        for entry in androidEntries {
            let entryLower = entry.title.lowercased()
            let isChinese = entryLower.contains("chinese release")
            let isAsian = entryLower.contains("asian release")
            let isJapanese = entryLower.contains("japanese release")
            let cleanTitle = stripRegionalSuffix(entry.title)
            let entryStrictNorm = strictAlphaNum(cleanTitle)

            var matchedIdx: Int? = nil

            // 1. Direct normalized match against seedds/nxnative items (skip regional override unless entry specifies region)
            if !isChinese && !isAsian && !isJapanese {
                matchedIdx = normToIndex[entryStrictNorm]
            }

            // 2. Try local nx2android game.tsv Title ID lookup (handles Chinese/regional releases and exact profiles)
            var resolvedTid: String? = nil
            if isChinese {
                // e.g. "OCTOPATH TRAVELER 0 (Chinese release)" -> 01001300232F4000
                for (k, tid) in nx2aTidMap where k.contains(entryStrictNorm) && tid != "01005270232F2000" {
                    resolvedTid = tid
                    break
                }
            }
            if resolvedTid == nil {
                resolvedTid = nx2aTidMap[entryStrictNorm]
            }
            if resolvedTid == nil, let colonIdx = cleanTitle.firstIndex(of: ":") {
                let prefixNorm = strictAlphaNum(String(cleanTitle[..<colonIdx]))
                if prefixNorm.count >= 5 {
                    resolvedTid = nx2aTidMap[prefixNorm]
                }
            }

            if matchedIdx == nil, let tid = resolvedTid {
                matchedIdx = tidToIndex[tid.uppercased()]
            }

            // 3. Fallback Title ID resolution via 29k Switch Titles database (only for non-seedds items)
            if matchedIdx == nil && resolvedTid == nil {
                if let tid = findTitleId(forGameTitle: cleanTitle)?.uppercased() {
                    resolvedTid = tid
                    matchedIdx = tidToIndex[tid]
                } else if let colonIdx = cleanTitle.firstIndex(of: ":") {
                    let prefixTitle = String(cleanTitle[..<colonIdx]).trimmingCharacters(in: .whitespaces)
                    if prefixTitle.count >= 5, let tid = findTitleId(forGameTitle: prefixTitle)?.uppercased() {
                        resolvedTid = tid
                        matchedIdx = tidToIndex[tid]
                    }
                }
            }

            if let idx = matchedIdx {
                merged[idx].isAndroidSupported = true
                merged[idx].androidGpuTier = entry.gpuTier
                merged[idx].androidReq = entry.androidReq
            } else {
                let finalTid = resolvedTid ?? "NX2A-\(entryStrictNorm.uppercased())"
                // Avoid duplicate if same Title ID was already inserted
                if let existingIdx = tidToIndex[finalTid.uppercased()] {
                    merged[existingIdx].isAndroidSupported = true
                    merged[existingIdx].androidGpuTier = entry.gpuTier
                    merged[existingIdx].androidReq = entry.androidReq
                } else {
                    let newItem = CompatibleGameItem(
                        title: entry.title,
                        titleId: finalTid,
                        versionTested: entry.versionSummary,
                        sdk: "nx2android",
                        engine: "NVN / Vulkan",
                        graphicsApi: "Vulkan",
                        readmeRelPath: "https://github.com/shirai91/nx2android#games",
                        macReq: "",
                        iosReq: "",
                        androidReq: entry.androidReq,
                        androidGpuTier: entry.gpuTier,
                        storageReq: "HD: ~6 GB",
                        minRamGB: 8,
                        minChipTier: .a17Pro,
                        isNew: false,
                        addedTimestamp: 0,
                        isMacSupported: false,
                        isIosSupported: false,
                        isIpadOsSupported: false,
                        isAndroidSupported: true
                    )
                    tidToIndex[finalTid.uppercased()] = merged.count
                    merged.append(newItem)
                }
            }
        }

        merged.sort { $0.title.localizedCaseInsensitiveCompare($1.title) == .orderedAscending }
        return merged
    }
    
    public func loadFromLocal(nxnativePath: String?, completion: @escaping ([CompatibleGameItem]) -> Void) {
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            guard let self = self else { return }
            var candidatePaths: [String] = []
            
            if let p = nxnativePath, !p.isEmpty {
                candidatePaths.append(URL(fileURLWithPath: p).appendingPathComponent("dm/games/README.md").path)
            }
            let detectedRepoPath = SystemDetector.shared.detectNxnativeDirectory().path
            if !detectedRepoPath.isEmpty {
                candidatePaths.append(URL(fileURLWithPath: detectedRepoPath).appendingPathComponent("dm/games/README.md").path)
            }
            candidatePaths.append("/Volumes/SSD FN501 PRO/Emulations/NativePort/nxnative/dm/games/README.md")
            
            let fm = FileManager.default
            for path in candidatePaths {
                if fm.fileExists(atPath: path),
                   let text = try? String(contentsOfFile: path, encoding: .utf8) {
                    let items = self.parseMarkdownTable(text)
                    if !items.isEmpty {
                        completion(items)
                        return
                    }
                }
            }
            completion([])
        }
    }
    
    private static let fallbackRecentPortTimestamps: [String: TimeInterval] = [
        "0100A3900C3E2000": 1793207710, // Paper Mario: The Origami King
        "01002E7016C46000": 1793201662, // Cult of the Lamb
        "01001F5010DFA000": 1793195846, // Pokémon Legends: Arceus
        "0100965017338000": 1793195495, // Super Mario Party Jamboree
        "0100FF500E34A000": 1793183436, // Xenoblade Chronicles: Definitive Edition
        "0100B8A026F14000": 1793180603, // FINAL FANTASY RESONANCE (Asian)
        "0100606026F12000": 1793180600, // FINAL FANTASY RESONANCE
        "010062B01525C000": 1793176619, // Persona 4 Golden
        "0100B8E016F76000": 1793158157, // NieR:Automata (Asian)
        "010056B015FE8000": 1793158150, // NieR:Automata
        "010067300059A000": 1793147162, // Mario + Rabbids Kingdom Battle
        "0100BC300CB48000": 1793142784, // FINAL FANTASY X/X-2 HD Remaster
        "0100D5B026844000": 1793128039, // Silver Pines
        "0100698009C6E000": 1793127142, // Blasphemous
        "010040801A4C8000": 1793123718, // Blasphemous 2
        "010032E00E6E2000": 1793123433, // Return of the Obra Dinn
        "0100E95004038000": 1793102788, // Xenoblade Chronicles 2
        "010045C014650000": 1793098225, // 13 Sentinels (JP)
        "0100CE4010AAC000": 1793097474, // FINAL FANTASY CRYSTAL CHRONICLES
        "0100A3D008C5C000": 1793085542, // Pokémon Scarlet
        "01006000040C2000": 1793070812, // Yoshi's Crafted World
        "010074F013262000": 1793059085, // Xenoblade Chronicles 3
        "0100317013770000": 1793056426, // Mario + Rabbids Sparks of Hope
        "01004D300C5AE000": 1793040665, // Kirby and the Forgotten Land
        "01009D901BC56000": 1793031222  // Donkey Kong Country Returns HD
    ]

    private func loadAddedTimestamps() -> [String: TimeInterval] {
        var result = Self.fallbackRecentPortTimestamps
        let detectedRepo = SystemDetector.shared.detectNxnativeDirectory().path
        let devFallback = "/Volumes/SSD FN501 PRO/Emulations/NativePort/nxnative"
        let repoPath = FileManager.default.fileExists(atPath: detectedRepo + "/.git") ? detectedRepo : devFallback
        guard FileManager.default.fileExists(atPath: repoPath) else {
            return result
        }

        let proc = Process()
        proc.executableURL = URL(fileURLWithPath: "/usr/bin/git")
        proc.arguments = [
            "-C", repoPath,
            "log",
            "--diff-filter=A",
            "--name-only",
            "--format=TS:%ct",
            "--",
            "dm/games/*/game.tsv"
        ]
        let pipe = Pipe()
        proc.standardOutput = pipe
        proc.standardError = FileHandle.nullDevice

        do {
            try proc.run()
            let data = pipe.fileHandleForReading.readDataToEndOfFile()
            proc.waitUntilExit()
            if let output = String(data: data, encoding: .utf8) {
                var currentTimestamp: TimeInterval = 0
                for rawLine in output.components(separatedBy: .newlines) {
                    let line = rawLine.trimmingCharacters(in: .whitespacesAndNewlines)
                    if line.hasPrefix("TS:") {
                        if let ts = TimeInterval(line.dropFirst(3)) {
                            currentTimestamp = ts
                        }
                    } else if line.hasPrefix("dm/games/") && line.hasSuffix("/game.tsv") && currentTimestamp > 0 {
                        let parts = line.components(separatedBy: "/")
                        if parts.count >= 3 {
                            let tid = parts[2].uppercased()
                            if result[tid] == nil || currentTimestamp > (result[tid] ?? 0) {
                                result[tid] = currentTimestamp
                            }
                        }
                    }
                }
            }
        } catch {
            // Fall back to static recent timestamps if git invocation fails
        }
        return result
    }

    public func parseMarkdownTable(_ markdown: String) -> [CompatibleGameItem] {
        var items: [CompatibleGameItem] = []
        let pattern = #"^\|\s*\[([^\]]+)\]\(([^)]+)\)\s*\|\s*`?([0-9A-Fa-f]{16})`?\s*\|\s*([^|]+)\s*\|\s*([^|]+)\s*\|\s*([^|]+)\s*\|\s*([^|]+)\s*\|"#
        
        guard let regex = try? NSRegularExpression(pattern: pattern, options: [.anchorsMatchLines]) else {
            return []
        }
        
        let addedTimestamps = loadAddedTimestamps()
        let sortedTimestamps = addedTimestamps.values.sorted(by: >)
        let newThreshold: TimeInterval = sortedTimestamps.count >= 15
            ? sortedTimestamps[14]
            : (sortedTimestamps.last ?? 1)
        
        let nsString = markdown as NSString
        let matches = regex.matches(in: markdown, options: [], range: NSRange(location: 0, length: nsString.length))
        
        for m in matches {
            guard m.numberOfRanges >= 8 else { continue }
            
            let title = nsString.substring(with: m.range(at: 1)).trimmingCharacters(in: .whitespaces)
            let path = nsString.substring(with: m.range(at: 2)).trimmingCharacters(in: .whitespaces)
            let tid = nsString.substring(with: m.range(at: 3)).trimmingCharacters(in: .whitespaces)
            let ver = nsString.substring(with: m.range(at: 4)).trimmingCharacters(in: .whitespaces)
            let sdk = nsString.substring(with: m.range(at: 5)).trimmingCharacters(in: .whitespaces)
            let engine = nsString.substring(with: m.range(at: 6)).trimmingCharacters(in: .whitespaces)
            let api = nsString.substring(with: m.range(at: 7)).trimmingCharacters(in: .whitespaces)
            
            let specs = self.resolveSpecs(titleId: tid, readmeRelPath: path, engine: engine)
            let upperTid = tid.uppercased()
            let addedTs = addedTimestamps[upperTid] ?? 0
            let isNewGame = addedTs > 0 && addedTs >= newThreshold
            
            items.append(
                CompatibleGameItem(
                    title: title,
                    titleId: tid,
                    versionTested: ver,
                    sdk: sdk,
                    engine: engine,
                    graphicsApi: api,
                    readmeRelPath: path,
                    macReq: specs.mac,
                    iosReq: specs.ios,
                    storageReq: specs.storage,
                    minRamGB: specs.minRamGB,
                    minChipTier: specs.minChipTier,
                    isNew: isNewGame,
                    addedTimestamp: addedTs
                )
            )
        }
        
        self.cachedGames = items
        return items
    }
    
    private func normalizeTitle(_ raw: String) -> String {
        let folded = raw.folding(options: [.diacriticInsensitive, .caseInsensitive], locale: .current)
        let stopWords = Set(["the", "of", "and", "edition", "collection", "remastered", "definitive", "complete", "reimagined", "asian", "release"])
        let words = folded
            .components(separatedBy: CharacterSet.alphanumerics.inverted)
            .filter { !$0.isEmpty }
        let filtered = words.filter { !stopWords.contains($0) }
        let chosen = filtered.isEmpty ? words : filtered
        return chosen.joined()
    }
    
    public func findTitleId(forGameTitle cleanTitle: String) -> String? {
        titlesIndexLock.lock()
        if let cached = resolvedTitleIdCache[cleanTitle] {
            titlesIndexLock.unlock()
            return cached
        }
        if unresolvedTitleNames.contains(cleanTitle) {
            titlesIndexLock.unlock()
            return nil
        }
        titlesIndexLock.unlock()

        let rawNorm = cleanTitle
            .folding(options: [.diacriticInsensitive, .caseInsensitive], locale: .current)
            .filter { $0.isLetter || $0.isNumber }
        let semanticNorm = normalizeTitle(cleanTitle)
        guard !rawNorm.isEmpty else {
            titlesIndexLock.lock()
            unresolvedTitleNames.insert(cleanTitle)
            titlesIndexLock.unlock()
            return nil
        }
        
        var list = cachedGames
        if list.isEmpty {
            let detectedReadme = URL(fileURLWithPath: SystemDetector.shared.detectNxnativeDirectory().path)
                .appendingPathComponent("dm/games/README.md").path
            let fallbackReadme = "/Volumes/SSD FN501 PRO/Emulations/NativePort/nxnative/dm/games/README.md"
            let localPath = FileManager.default.fileExists(atPath: detectedReadme) ? detectedReadme : fallbackReadme
            if let text = try? String(contentsOfFile: localPath, encoding: .utf8) {
                list = parseMarkdownTable(text)
            }
        }
        
        // 1. Exact folded match against profile games
        for game in list {
            let normGame = game.title
                .folding(options: [.diacriticInsensitive, .caseInsensitive], locale: .current)
                .filter { $0.isLetter || $0.isNumber }
            if normGame == rawNorm {
                let tid = game.titleId.uppercased()
                titlesIndexLock.lock()
                resolvedTitleIdCache[cleanTitle] = tid
                titlesIndexLock.unlock()
                return tid
            }
        }
        
        // 2. Semantic word match against profile games
        for game in list {
            let semGame = normalizeTitle(game.title)
            if !semGame.isEmpty && (semGame == semanticNorm || (semGame.contains(semanticNorm) && semanticNorm.count >= 5) || (semanticNorm.contains(semGame) && semGame.count >= 5)) {
                let tid = game.titleId.uppercased()
                titlesIndexLock.lock()
                resolvedTitleIdCache[cleanTitle] = tid
                titlesIndexLock.unlock()
                return tid
            }
        }
        
        // 3. Search 29,000+ official Nintendo Switch title database via memory-mapped TSV index (0 KB heap)
        var uniqueQWords: [String] = []
        for w in tokenizeWords(cleanTitle) where !uniqueQWords.contains(w) {
            uniqueQWords.append(w)
        }
        let qNorm = uniqueQWords.joined(separator: " ")
        if !uniqueQWords.isEmpty,
           let matched = searchMemoryMappedTitlesIndex(qWords: uniqueQWords, qNorm: qNorm) {
            titlesIndexLock.lock()
            resolvedTitleIdCache[cleanTitle] = matched
            titlesIndexLock.unlock()
            return matched
        }
        
        // 4. Substring match on folded characters from profiles
        for game in list {
            let normGame = game.title
                .folding(options: [.diacriticInsensitive, .caseInsensitive], locale: .current)
                .filter { $0.isLetter || $0.isNumber }
            if (normGame.contains(rawNorm) && rawNorm.count >= 5) || (rawNorm.contains(normGame) && normGame.count >= 5) {
                let tid = game.titleId.uppercased()
                titlesIndexLock.lock()
                resolvedTitleIdCache[cleanTitle] = tid
                titlesIndexLock.unlock()
                return tid
            }
        }
        
        titlesIndexLock.lock()
        unresolvedTitleNames.insert(cleanTitle)
        titlesIndexLock.unlock()
        return nil
    }

    private func searchMemoryMappedTitlesIndex(qWords: [String], qNorm: String) -> String? {
        guard let indexURL = ensureTitlesIndexURL(),
              let data = try? Data(contentsOf: indexURL, options: .mappedIfSafe) else {
            return nil
        }

        let qNormBytes = Array(qNorm.utf8)
        let qWordsBytes: [[UInt8]] = Array(qWords.prefix(64)).map { Array($0.utf8) }
        let qWordCount = qWordsBytes.count
        guard qWordCount > 0 else { return nil }

        return data.withUnsafeBytes { (raw: UnsafeRawBufferPointer) -> String? in
            guard let base = raw.baseAddress?.assumingMemoryBound(to: UInt8.self) else { return nil }
            let count = raw.count
            var bestTidOffset: Int = -1
            var bestScore: Double = 0.0

            var lineStart = 0
            while lineStart < count {
                var lineEnd = lineStart
                while lineEnd < count && base[lineEnd] != 0x0A {
                    lineEnd += 1
                }
                // Expected format: <16-char TID>\t<norm words>
                if lineEnd - lineStart > 17 && base[lineStart + 16] == 0x09 {
                    let normStart = lineStart + 17
                    let normLen = lineEnd - normStart

                    // Fast exact normalized string check
                    if normLen == qNormBytes.count && memcmp(base + normStart, qNormBytes, normLen) == 0 {
                        let tidPtr = UnsafeBufferPointer(start: base + lineStart, count: 16)
                        return String(decoding: tidPtr, as: UTF8.self)
                    }

                    // Zero-allocation word-set comparison using a 64-bit bitmask
                    var itemWordCount = 0
                    var matchedMask: UInt64 = 0
                    var tokStart = normStart
                    while tokStart < lineEnd {
                        var tokEnd = tokStart
                        while tokEnd < lineEnd && base[tokEnd] != 0x20 {
                            tokEnd += 1
                        }
                        let tokLen = tokEnd - tokStart
                        if tokLen > 0 {
                            itemWordCount += 1
                            for wi in 0..<qWordCount {
                                let bit: UInt64 = 1 << UInt64(wi)
                                if (matchedMask & bit) == 0 && qWordsBytes[wi].count == tokLen {
                                    if memcmp(base + tokStart, qWordsBytes[wi], tokLen) == 0 {
                                        matchedMask |= bit
                                        break
                                    }
                                }
                            }
                        }
                        tokStart = tokEnd + 1
                    }

                    let matchedCount = matchedMask.nonzeroBitCount
                    if matchedCount == qWordCount && itemWordCount == qWordCount {
                        let tidPtr = UnsafeBufferPointer(start: base + lineStart, count: 16)
                        return String(decoding: tidPtr, as: UTF8.self)
                    }

                    if matchedCount == qWordCount && itemWordCount > 0 {
                        let score = Double(qWordCount) / Double(itemWordCount)
                        if score > bestScore {
                            bestScore = score
                            bestTidOffset = lineStart
                        }
                    } else if matchedCount == itemWordCount && itemWordCount >= 2 {
                        let score = Double(itemWordCount) / Double(qWordCount)
                        if score > bestScore {
                            bestScore = score
                            bestTidOffset = lineStart
                        }
                    }
                }
                lineStart = lineEnd + 1
            }

            if bestTidOffset >= 0 && bestScore >= 0.5 {
                let tidPtr = UnsafeBufferPointer(start: base + bestTidOffset, count: 16)
                return String(decoding: tidPtr, as: UTF8.self)
            }
            return nil
        }
    }

    /// Resolves minimum Mac and iOS hardware specs (RAM, Storage, minRamGB tier: 4, 6, 8, or 16, and iPhone chip tier) from nxnative game profiles and README notes.
    private func resolveSpecs(titleId: String, readmeRelPath: String, engine: String = "") -> (mac: String, ios: String, storage: String, minRamGB: Int, minChipTier: IphoneChipTier) {
        let detectedBase = URL(fileURLWithPath: SystemDetector.shared.detectNxnativeDirectory().path)
            .appendingPathComponent("dm/games/\(titleId)").path
        let fallbackBase = "/Volumes/SSD FN501 PRO/Emulations/NativePort/nxnative/dm/games/\(titleId)"
        let baseDir = FileManager.default.fileExists(atPath: detectedBase) ? detectedBase : fallbackBase
        let tsvPath = "\(baseDir)/game.tsv"
        let readmePath = "\(baseDir)/README.md"
        
        var memReserve: UInt64 = 0x100000000
        var appPool: UInt64 = 0xCD500000
        var sysResource: UInt64 = 0
        
        if let tsvContent = try? String(contentsOfFile: tsvPath, encoding: .utf8) {
            for line in tsvContent.components(separatedBy: .newlines) {
                let trimmed = line.trimmingCharacters(in: .whitespaces)
                if trimmed.isEmpty || trimmed.hasPrefix("#") { continue }
                let parts = line.components(separatedBy: "\t")
                guard parts.count >= 2 else { continue }
                let key = parts[0].trimmingCharacters(in: .whitespaces)
                let valStr = parts[1].components(separatedBy: "#")[0].trimmingCharacters(in: .whitespaces)
                let cleanHex = valStr.lowercased().replacingOccurrences(of: "0x", with: "")
                if key == "mem_reserve", let v = UInt64(cleanHex, radix: 16) {
                    memReserve = v
                } else if key == "app_pool", let v = UInt64(cleanHex, radix: 16) {
                    appPool = v
                } else if key == "sys_resource" {
                    if let v = UInt64(cleanHex, radix: 16) {
                        sysResource = v
                    } else if let v = UInt64(valStr) {
                        sysResource = v
                    }
                }
            }
        }
        
        var storage = "HD: ~6 GB"
        var maxResidentGB: Double? = nil
        if let rmContent = try? String(contentsOfFile: readmePath, encoding: .utf8) {
            let storagePattern = #"(?:IPA|RomFS|app|game)[^\n\r]{0,35}?(?:at about|is about|about|is)?\s*([0-9]+(?:\.[0-9]+)?)\s*GB"#
            if let regex = try? NSRegularExpression(pattern: storagePattern, options: [.caseInsensitive]) {
                let ns = rmContent as NSString
                if let match = regex.firstMatch(in: rmContent, options: [], range: NSRange(location: 0, length: ns.length)), match.numberOfRanges >= 2 {
                    let gbVal = ns.substring(with: match.range(at: 1))
                    storage = "HD: ~\(gbVal) GB"
                }
            }
            
            let resPattern = #"([0-9]+(?:\.[0-9]+)?)\s*GB\s*(?:resident|of GPU)"#
            if let resRegex = try? NSRegularExpression(pattern: resPattern, options: [.caseInsensitive]) {
                let ns = rmContent as NSString
                let matches = resRegex.matches(in: rmContent, options: [], range: NSRange(location: 0, length: ns.length))
                for m in matches where m.numberOfRanges >= 2 {
                    if let val = Double(ns.substring(with: m.range(at: 1))) {
                        maxResidentGB = max(maxResidentGB ?? 0, val)
                    }
                }
            }
        }
        
        // Determine RAM tier: 4, 6, 8, or 16 GB
        let minRamGB: Int
        let isUnreal = engine.localizedCaseInsensitiveContains("unreal")
        
        if let res = maxResidentGB, res <= 1.35 {
            minRamGB = 4
        } else if appPool <= 0x40000000 || (memReserve < 0x100000000 && sysResource == 0) {
            minRamGB = 4
        } else if memReserve == 0x100000000 && sysResource == 0 {
            if let res = maxResidentGB, res >= 2.6 {
                minRamGB = 8
            } else if titleId == "01007EF00011E000" || titleId == "0100E95004038000" || titleId == "0100FF500E34A000" {
                // Breath of the Wild, Xenoblade 1 & 2
                minRamGB = 8
            } else {
                minRamGB = 6
            }
        } else if memReserve >= 0x140000000 || sysResource >= 0x2000000 || (isUnreal && sysResource > 0) {
            if appPool <= 0x80000000 {
                minRamGB = 8
            } else if let res = maxResidentGB, res <= 2.55 && !isUnreal {
                minRamGB = 8
            } else if titleId == "010015100B514000" || titleId == "0100ECD018EBE000" || titleId == "01009D901BC56000" || titleId == "010086A022444000" {
                // Super Mario Wonder, Paper Mario TTYD, DKC Returns HD, BALL x PIT
                minRamGB = 8
            } else {
                minRamGB = 16
            }
        } else {
            minRamGB = 8
        }
        
        let upperTid = titleId.uppercased()
        let a18OptimizedTitles: Set<String> = [
            "0100FF500E34A000", // Xenoblade Chronicles: Definitive Edition
            "0100E95004038000", // Xenoblade Chronicles 2
            "0100B04011742000", // Monster Hunter Rise
            "0100965017338000", // Super Mario Party Jamboree
            "01001F5010DFA000", // Pokémon Legends: Arceus
            "0100A3D008C5C000", // Pokémon Scarlet
            "01006A800016E000", // Super Smash Bros. Ultimate
            "01004A4010FEA000", // Bayonetta 3
            "01002B00111A2000", // Hyrule Warriors: Age of Calamity
            "0100A3501946E000", // OCTOPATH TRAVELER II
            "01006C300E9F0000"  // DRAGON QUEST XI S
        ]
        
        if upperTid.hasPrefix("0400") {
            let s2Storage = storage == "HD: ~6 GB" ? "HD: ~10-16 GB" : storage
            return (mac: "Mac: 16GB RAM", ios: "iPhone: A18 Pro (Switch 2 Exp.)", storage: s2Storage, minRamGB: 16, minChipTier: .a18Pro)
        }
        
        let mac: String
        let ios: String
        let minChipTier: IphoneChipTier
        switch minRamGB {
        case 4:
            mac = "Mac: 4GB+ RAM"
            ios = "iPhone: A17 Pro+ (8GB)"
            minChipTier = .a17Pro
            if storage == "HD: ~6 GB" { storage = "HD: ~2-4 GB" }
        case 6:
            mac = "Mac: 8GB RAM"
            ios = "iPhone: A17 Pro+ (8GB)"
            minChipTier = .a17Pro
        case 8:
            mac = "Mac: 8GB+ RAM"
            if isUnreal || a18OptimizedTitles.contains(upperTid) || (maxResidentGB ?? 0) >= 2.75 {
                ios = "iPhone: A18+ (8GB)"
                minChipTier = .a18
            } else {
                ios = "iPhone: A17 Pro+ (8GB)"
                minChipTier = .a17Pro
            }
            if storage == "HD: ~6 GB" { storage = "HD: ~8-12 GB" }
        default: // 16
            mac = "Mac: 16GB RAM"
            ios = "iPhone: A18 Pro (8GB)"
            minChipTier = .a18Pro
            if storage == "HD: ~6 GB" { storage = "HD: ~12-16 GB" }
        }
        
        return (mac: mac, ios: ios, storage: storage, minRamGB: minRamGB, minChipTier: minChipTier)
    }
}
