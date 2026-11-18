import Foundation

public struct TranslatedReleaseNotes: Codable {
    public let tagName: String
    public let languageCode: String
    public let summary: String
    public let categories: [ReleaseHighlightCategory]
    public let cachedAt: Date
}

public final class ReleaseNotesTranslator {
    public static let shared = ReleaseNotesTranslator()
    private let lock = NSLock()
    private var memoryCache: [String: TranslatedReleaseNotes] = [:]
    private var inFlightKeys: Set<String> = []

    private init() {}

    private func cacheDirectory() -> URL {
        let appSupport = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? URL(fileURLWithPath: NSHomeDirectory()).appendingPathComponent("Library/Application Support")
        let dir = appSupport.appendingPathComponent("nxnative", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    private func cacheFileURL(tag: String, langCode: String) -> URL {
        let safeTag = tag.replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: ":", with: "_")
        let safeLang = langCode.replacingOccurrences(of: "/", with: "_")
        return cacheDirectory().appendingPathComponent("release_notes_l10n_\(safeTag)_\(safeLang).json")
    }

    public static func targetLanguageCode(for language: AppLanguage) -> String? {
        let resolved = (language == .system) ? AppLanguage.resolve() : language
        switch resolved {
        case .system, .en: return nil
        case .ptBR: return "pt"
        case .ptPT: return "pt-PT"
        case .es: return "es"
        case .ja: return "ja"
        case .fr: return "fr"
        case .de: return "de"
        case .it: return "it"
        case .zhHans: return "zh-CN"
        case .zhHant: return "zh-TW"
        case .ko: return "ko"
        case .pl: return "pl"
        case .ru: return "ru"
        case .sv: return "sv"
        }
    }

    public func cachedTranslation(tag: String, language: AppLanguage) -> TranslatedReleaseNotes? {
        guard let langCode = Self.targetLanguageCode(for: language) else { return nil }
        let key = "\(tag)|\(langCode)"

        lock.lock()
        if let mem = memoryCache[key] {
            lock.unlock()
            return mem
        }
        lock.unlock()

        let fileURL = cacheFileURL(tag: tag, langCode: langCode)
        guard let data = try? Data(contentsOf: fileURL),
              let decoded = try? JSONDecoder().decode(TranslatedReleaseNotes.self, from: data) else {
            return nil
        }

        lock.lock()
        memoryCache[key] = decoded
        lock.unlock()
        return decoded
    }

    /// Translates GitLab release summary + categories asynchronously, caching results per (tag, language).
    /// Returns nil gracefully if the target language is English, offline, or translation times out.
    public func translate(
        tag: String,
        summary: String,
        categories: [ReleaseHighlightCategory],
        to language: AppLanguage,
        completion: @escaping (TranslatedReleaseNotes?) -> Void
    ) {
        guard let langCode = Self.targetLanguageCode(for: language), !categories.isEmpty else {
            DispatchQueue.main.async { completion(nil) }
            return
        }

        if let cached = cachedTranslation(tag: tag, language: language) {
            DispatchQueue.main.async { completion(cached) }
            return
        }

        let key = "\(tag)|\(langCode)"
        lock.lock()
        if inFlightKeys.contains(key) {
            lock.unlock()
            return
        }
        inFlightKeys.insert(key)
        lock.unlock()

        // Flatten all strings into a single ordered array (guaranteed single-line entries)
        var lines: [String] = [summary.replacingOccurrences(of: "\n", with: " ")]
        for cat in categories {
            lines.append(cat.title.replacingOccurrences(of: "\n", with: " "))
            for pt in cat.summaryPoints {
                lines.append(pt.replacingOccurrences(of: "\n", with: " "))
            }
            for pt in cat.detailedPoints {
                lines.append(pt.replacingOccurrences(of: "\n", with: " "))
            }
        }

        // Chunk into batches <= 2400 characters so URL query length stays well within limits
        let chunks = Self.buildChunks(from: lines, maxChars: 2400)
        var translatedChunks = Array<String?>(repeating: nil, count: chunks.count)
        let group = DispatchGroup()
        let chunkLock = NSLock()

        for (idx, chunk) in chunks.enumerated() {
            group.enter()
            let joined = chunk.joined(separator: "\n")
            Self.requestTranslation(text: joined, targetLang: langCode) { translated in
                chunkLock.lock()
                translatedChunks[idx] = translated
                chunkLock.unlock()
                group.leave()
            }
        }

        group.notify(queue: .global(qos: .utility)) { [weak self] in
            guard let self = self else { return }
            defer {
                self.lock.lock()
                self.inFlightKeys.remove(key)
                self.lock.unlock()
            }

            // Reassemble lines, falling back to original English line-by-line if any chunk fails
            var finalLines: [String] = []
            for (idx, originalChunk) in chunks.enumerated() {
                if let translatedText = translatedChunks[idx] {
                    let split = translatedText.components(separatedBy: "\n")
                    if split.count == originalChunk.count {
                        finalLines.append(contentsOf: split.map { $0.trimmingCharacters(in: .whitespaces) })
                    } else {
                        finalLines.append(contentsOf: originalChunk)
                    }
                } else {
                    finalLines.append(contentsOf: originalChunk)
                }
            }

            guard finalLines.count == lines.count else {
                DispatchQueue.main.async { completion(nil) }
                return
            }

            // If nothing changed (e.g. completely offline), do not cache English as translated
            if finalLines == lines {
                DispatchQueue.main.async { completion(nil) }
                return
            }

            var cursor = 0
            let translatedSummary = finalLines[cursor]
            cursor += 1

            var translatedCategories: [ReleaseHighlightCategory] = []
            for cat in categories {
                let title = finalLines[cursor]
                cursor += 1
                let sPoints = Array(finalLines[cursor..<(cursor + cat.summaryPoints.count)])
                cursor += cat.summaryPoints.count
                let dPoints = Array(finalLines[cursor..<(cursor + cat.detailedPoints.count)])
                cursor += cat.detailedPoints.count

                translatedCategories.append(
                    ReleaseHighlightCategory(
                        title: title,
                        icon: cat.icon,
                        colorKey: cat.colorKey,
                        summaryPoints: sPoints,
                        detailedPoints: dPoints,
                        isPrimarySection: cat.isPrimarySection
                    )
                )
            }

            let result = TranslatedReleaseNotes(
                tagName: tag,
                languageCode: langCode,
                summary: translatedSummary,
                categories: translatedCategories,
                cachedAt: Date()
            )

            self.lock.lock()
            self.memoryCache[key] = result
            self.lock.unlock()

            if let data = try? JSONEncoder().encode(result) {
                try? data.write(to: self.cacheFileURL(tag: tag, langCode: langCode), options: .atomic)
            }

            DispatchQueue.main.async {
                completion(result)
            }
        }
    }

    private static func buildChunks(from lines: [String], maxChars: Int) -> [[String]] {
        var chunks: [[String]] = []
        var current: [String] = []
        var currentLen = 0
        for line in lines {
            let addLen = line.count + 1
            if !current.isEmpty && (currentLen + addLen > maxChars) {
                chunks.append(current)
                current = [line]
                currentLen = addLen
            } else {
                current.append(line)
                currentLen += addLen
            }
        }
        if !current.isEmpty {
            chunks.append(current)
        }
        return chunks
    }

    private static func requestTranslation(
        text: String,
        targetLang: String,
        completion: @escaping (String?) -> Void
    ) {
        var components = URLComponents(string: "https://translate.googleapis.com/translate_a/single")
        components?.queryItems = [
            URLQueryItem(name: "client", value: "gtx"),
            URLQueryItem(name: "sl", value: "en"),
            URLQueryItem(name: "tl", value: targetLang),
            URLQueryItem(name: "dt", value: "t"),
            URLQueryItem(name: "q", value: text),
        ]
        guard let url = components?.url else {
            completion(nil)
            return
        }

        var req = URLRequest(url: url)
        req.timeoutInterval = 4.5
        URLSession.shared.dataTask(with: req) { data, response, _ in
            guard let http = response as? HTTPURLResponse,
                  (200...299).contains(http.statusCode),
                  let data = data,
                  let json = try? JSONSerialization.jsonObject(with: data) as? [Any],
                  let sentences = json.first as? [Any] else {
                completion(nil)
                return
            }

            var output = ""
            for item in sentences {
                if let pair = item as? [Any], let translatedPart = pair.first as? String {
                    output += translatedPart
                }
            }
            completion(output.isEmpty ? nil : output)
        }.resume()
    }
}
