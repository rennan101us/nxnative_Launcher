import Foundation

public final class DownloadEngineService: NSObject, URLSessionDownloadDelegate {
    public static let shared = DownloadEngineService()
    
    private var session: URLSession!
    private var activeTasks: [String: DownloadTaskItem] = [:] // [titleId: DownloadTaskItem]
    private var activeURLSessions: [Int: String] = [:] // [taskIdentifier: titleId]
    private var activeProcesses: [String: Process] = [:] // [titleId: Process]
    private var completionHandlers: [String: (Result<URL, Error>) -> Void] = [:]
    private var progressHandlers: [String: (DownloadTaskItem) -> Void] = [:]
    private let lock = NSLock()
    
    private override init() {
        super.init()
        let config = URLSessionConfiguration.default
        config.timeoutIntervalForRequest = 30.0
        config.timeoutIntervalForResource = 86400.0 // 24 hours for large downloads
        self.session = URLSession(configuration: config, delegate: self, delegateQueue: OperationQueue())
    }
    
    public func startDownload(
        game: CloudAvailableGame,
        destinationDirectory: URL,
        onProgress: @escaping (DownloadTaskItem) -> Void,
        onCompletion: @escaping (Result<URL, Error>) -> Void
    ) {
        lock.lock()
        defer { lock.unlock() }
        
        let titleId = game.titleId
        if let existing = activeTasks[titleId], existing.status == .downloading {
            return // Already downloading
        }
        
        let initialTask = DownloadTaskItem(
            id: UUID(),
            titleId: titleId,
            gameTitle: game.gameTitle,
            progress: 0.0,
            speedString: "0 KB/s",
            etaString: "--",
            downloadedBytes: 0,
            totalBytes: 0,
            status: .downloading
        )
        activeTasks[titleId] = initialTask
        progressHandlers[titleId] = onProgress
        completionHandlers[titleId] = onCompletion
        
        DispatchQueue.main.async {
            onProgress(initialTask)
        }
        
        if game.isTorrent || game.downloadURL.contains("blueroms.ws") {
            if game.downloadURL.contains("blueroms.ws") && !game.downloadURL.hasPrefix("magnet:") {
                Task.detached(priority: .utility) { [weak self] in
                    guard let self = self, let url = URL(string: game.downloadURL) else { return }
                    if let magnet = await self.resolveBlueRomsMagnetURL(pageURL: url) {
                        var torrentGame = game
                        torrentGame.downloadURL = magnet
                        torrentGame.isTorrent = true
                        self.startTorrentDownload(game: torrentGame, destinationDirectory: destinationDirectory)
                    } else {
                        self.failTask(titleId: game.titleId, error: NSError(domain: "DownloadEngine", code: -3, userInfo: [NSLocalizedDescriptionKey: "Não foi possível extrair o link magnet da página"]))
                    }
                }
            } else {
                startTorrentDownload(game: game, destinationDirectory: destinationDirectory)
            }
        } else if game.downloadURL.contains("nswpedia.com") {
            Task.detached(priority: .utility) { [weak self] in
                guard let self = self, let url = URL(string: game.downloadURL) else { return }
                if let direct = await self.resolveNswpediaDirectURL(pageURL: url) {
                    if direct.absoluteString.hasPrefix("magnet:") {
                        var torrentGame = game
                        torrentGame.downloadURL = direct.absoluteString
                        torrentGame.isTorrent = true
                        self.startTorrentDownload(game: torrentGame, destinationDirectory: destinationDirectory)
                    } else {
                        self.resumeHTTPDownload(url: direct, titleId: game.titleId)
                    }
                } else {
                    self.failTask(titleId: game.titleId, error: NSError(domain: "DownloadEngine", code: -4, userInfo: [NSLocalizedDescriptionKey: "Não foi possível extrair o link de download direto do NSWPedia"]))
                }
            }
        } else {
            startHTTPDownload(game: game, destinationDirectory: destinationDirectory)
        }
    }
    
    public func cancelDownload(titleId: String) {
        lock.lock()
        defer { lock.unlock() }
        
        if let proc = activeProcesses[titleId] {
            proc.terminate()
            activeProcesses.removeValue(forKey: titleId)
        }
        
        for (taskIdentifier, tId) in activeURLSessions where tId == titleId {
            session.getAllTasks { tasks in
                for task in tasks where task.taskIdentifier == taskIdentifier {
                    task.cancel()
                }
            }
            activeURLSessions.removeValue(forKey: taskIdentifier)
        }
        
        if var task = activeTasks[titleId] {
            task.status = .cancelled
            activeTasks.removeValue(forKey: titleId)
            let handler = progressHandlers.removeValue(forKey: titleId)
            DispatchQueue.main.async {
                handler?(task)
            }
        }
        completionHandlers.removeValue(forKey: titleId)
    }
    
    // MARK: - HTTP Download
    private func startHTTPDownload(game: CloudAvailableGame, destinationDirectory: URL) {
        guard let url = URL(string: game.downloadURL) else {
            failTask(titleId: game.titleId, error: NSError(domain: "DownloadEngine", code: -1, userInfo: [NSLocalizedDescriptionKey: "URL inválida"]))
            return
        }
        
        let titleId = game.titleId
        
        // If it's a MediaFire file page, resolve direct download button first
        if (url.host?.contains("mediafire.com") == true) && url.path.contains("/file/") {
            Task.detached(priority: .utility) { [weak self] in
                if let direct = await self?.resolveMediaFireDirectURL(pageURL: url) {
                    self?.resumeHTTPDownload(url: direct, titleId: titleId)
                } else {
                    self?.resumeHTTPDownload(url: url, titleId: titleId)
                }
            }
            return
        }
        
        resumeHTTPDownload(url: url, titleId: titleId)
    }
    
    private func resumeHTTPDownload(url: URL, titleId: String) {
        lock.lock()
        defer { lock.unlock() }
        var request = URLRequest(url: url)
        request.setValue("Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/605.1.15", forHTTPHeaderField: "User-Agent")
        
        let downloadTask = session.downloadTask(with: request)
        activeURLSessions[downloadTask.taskIdentifier] = titleId
        downloadTask.resume()
    }
    
    private func resolveMediaFireDirectURL(pageURL: URL) async -> URL? {
        var req = URLRequest(url: pageURL)
        req.setValue("Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/605.1.15", forHTTPHeaderField: "User-Agent")
        guard let (data, _) = try? await session.data(for: req),
              let html = String(data: data, encoding: .utf8) else {
            return nil
        }
        
        let pattern = "id=[\"']downloadButton[\"'][^>]*href=[\"']([^\"']+)[\"']|href=[\"'](https?://download[^\"']+mediafire\\.com[^\"']+)[\"']"
        guard let regex = try? NSRegularExpression(pattern: pattern, options: .caseInsensitive) else { return nil }
        let nsHtml = html as NSString
        let range = NSRange(location: 0, length: nsHtml.length)
        if let match = regex.firstMatch(in: html, options: [], range: range) {
            for i in 1..<match.numberOfRanges {
                let r = match.range(at: i)
                if r.location != NSNotFound {
                    let directStr = nsHtml.substring(with: r)
                    return URL(string: directStr)
                }
            }
        }
        return nil
    }
    
    private func resolveBlueRomsMagnetURL(pageURL: URL) async -> String? {
        var req = URLRequest(url: pageURL)
        req.setValue("Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/605.1.15", forHTTPHeaderField: "User-Agent")
        guard let (pageData, _) = try? await session.data(for: req),
              let pageHtml = String(data: pageData, encoding: .utf8) else {
            return nil
        }
        
        // Find href="(/download/[^"]+)"
        let dlPattern = "href=[\"'](/download/[^\"']+)[\"']"
        guard let dlRegex = try? NSRegularExpression(pattern: dlPattern, options: .caseInsensitive) else { return nil }
        let nsHtml = pageHtml as NSString
        let range = NSRange(location: 0, length: nsHtml.length)
        guard let match = dlRegex.firstMatch(in: pageHtml, options: [], range: range), match.numberOfRanges > 1 else {
            return nil
        }
        let dlPath = nsHtml.substring(with: match.range(at: 1))
        guard let dlURL = URL(string: dlPath, relativeTo: pageURL) else { return nil }
        
        var dlReq = URLRequest(url: dlURL)
        dlReq.setValue("Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/605.1.15", forHTTPHeaderField: "User-Agent")
        guard let (dlData, _) = try? await session.data(for: dlReq),
              let dlHtml = String(data: dlData, encoding: .utf8) else {
            return nil
        }
        
        // Extract data-link="([^"]+)"
        let magnetPattern = "data-link=[\"']([^\"']+)[\"']"
        guard let magnetRegex = try? NSRegularExpression(pattern: magnetPattern, options: .caseInsensitive) else { return nil }
        let nsDlHtml = dlHtml as NSString
        let dlRange = NSRange(location: 0, length: nsDlHtml.length)
        guard let mMatch = magnetRegex.firstMatch(in: dlHtml, options: [], range: dlRange), mMatch.numberOfRanges > 1 else {
            return nil
        }
        let b64 = nsDlHtml.substring(with: mMatch.range(at: 1))
        if let decodedData = Data(base64Encoded: b64), let magnet = String(data: decodedData, encoding: .utf8) {
            return magnet
        }
        return nil
    }
    
    private func resolveNswpediaDirectURL(pageURL: URL) async -> URL? {
        var req = URLRequest(url: pageURL)
        req.setValue("Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/605.1.15", forHTTPHeaderField: "User-Agent")
        guard let (data, _) = try? await session.data(for: req),
              let html = String(data: data, encoding: .utf8) else {
            return nil
        }
        
        let dlPagePattern = #"href=["\x27](https?://nswpedia\.com/download/[^"\x27]+)["\x27]"#
        guard let regex = try? NSRegularExpression(pattern: dlPagePattern) else { return nil }
        let nsHtml = html as NSString
        let range = NSRange(location: 0, length: nsHtml.length)
        guard let match = regex.firstMatch(in: html, options: [], range: range) else { return nil }
        let dlPageStr = nsHtml.substring(with: match.range(at: 1))
        guard let dlPageURL = URL(string: dlPageStr) else { return nil }
        
        var dlReq = URLRequest(url: dlPageURL)
        dlReq.setValue("Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/605.1.15", forHTTPHeaderField: "User-Agent")
        guard let (dlData, _) = try? await session.data(for: dlReq),
              let dlHtml = String(data: dlData, encoding: .utf8) else {
            return nil
        }
        
        let directPattern = #"id=["\x27]download-link["\x27][^>]*href=["\x27]([^"\x27]+)["\x27]"#
        if let directRegex = try? NSRegularExpression(pattern: directPattern, options: .caseInsensitive) {
            let nsDl = dlHtml as NSString
            let dlRange = NSRange(location: 0, length: nsDl.length)
            if let dMatch = directRegex.firstMatch(in: dlHtml, options: [], range: dlRange), dMatch.numberOfRanges > 1 {
                let found = nsDl.substring(with: dMatch.range(at: 1))
                if let u = URL(string: found) { return u }
            }
        }
        
        let listPattern = #"href=["\x27](https?://nswpedia\.com/download/[^"\x27]+/download_list[^"\x27]*)["\x27]"#
        if let listRegex = try? NSRegularExpression(pattern: listPattern) {
            let nsDl = dlHtml as NSString
            let dlRange = NSRange(location: 0, length: nsDl.length)
            let listMatches = listRegex.matches(in: dlHtml, options: [], range: dlRange)
            for lm in listMatches {
                let listURLStr = nsDl.substring(with: lm.range(at: 1))
                if let listURL = URL(string: listURLStr) {
                    var lReq = URLRequest(url: listURL)
                    lReq.setValue("Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/605.1.15", forHTTPHeaderField: "User-Agent")
                    if let (lData, _) = try? await session.data(for: lReq),
                       let lHtml = String(data: lData, encoding: .utf8) {
                        if let directRegex = try? NSRegularExpression(pattern: directPattern, options: .caseInsensitive) {
                            let nsL = lHtml as NSString
                            if let m = directRegex.firstMatch(in: lHtml, options: [], range: NSRange(location: 0, length: nsL.length)), m.numberOfRanges > 1 {
                                let linkStr = nsL.substring(with: m.range(at: 1))
                                if let u = URL(string: linkStr) { return u }
                            }
                        }
                    }
                }
            }
        }
        
        return nil
    }
    
    // MARK: - Torrent Download (aria2c)
    private func startTorrentDownload(game: CloudAvailableGame, destinationDirectory: URL) {
        let titleId = game.titleId
        let aria2Path = findAria2Binary()
        
        guard let aria2 = aria2Path else {
            failTask(titleId: titleId, error: NSError(
                domain: "DownloadEngine",
                code: -2,
                userInfo: [NSLocalizedDescriptionKey: "Suporte a torrents requer o utilitário 'aria2c' instalado no Mac (/opt/homebrew/bin/aria2c)."]
            ))
            return
        }
        
        try? FileManager.default.createDirectory(at: destinationDirectory, withIntermediateDirectories: true)
        
        let trackers = [
            "udp://tracker.opentrackr.org:1337/announce",
            "udp://open.tracker.cl:1337/announce",
            "udp://tracker.torrent.eu.org:451/announce",
            "udp://open.stealth.si:80/announce",
            "udp://explodie.org:6969/announce",
            "udp://tracker.tiny-vps.com:6969/announce",
            "udp://tracker.moeking.me:6969/announce",
            "udp://tracker.openbittorrent.com:6969/announce",
            "http://tracker.openbittorrent.com:80/announce"
        ].joined(separator: ",")
        
        let proc = Process()
        proc.executableURL = URL(fileURLWithPath: aria2)
        proc.arguments = [
            "--seed-time=0",
            "--max-connection-per-server=8",
            "--split=8",
            "--dir=\(destinationDirectory.path)",
            "--summary-interval=1",
            "--file-allocation=none",
            "--enable-dht=true",
            "--bt-enable-lpd=true",
            "--enable-peer-exchange=true",
            "--follow-torrent=mem",
            "--bt-max-peers=60",
            "--bt-tracker=\(trackers)",
            game.downloadURL
        ]
        
        let outPipe = Pipe()
        proc.standardOutput = outPipe
        proc.standardError = outPipe
        
        outPipe.fileHandleForReading.readabilityHandler = { [weak self] handle in
            let data = handle.availableData
            guard !data.isEmpty, let output = String(data: data, encoding: .utf8) else { return }
            self?.parseAria2Output(output, titleId: titleId)
        }
        
        proc.terminationHandler = { [weak self] p in
            self?.lock.lock()
            defer { self?.lock.unlock() }
            self?.activeProcesses.removeValue(forKey: titleId)
            
            if p.terminationStatus == 0 {
                // Find downloaded file in directory
                if let files = try? FileManager.default.contentsOfDirectory(at: destinationDirectory, includingPropertiesForKeys: nil) {
                    let matching = files.first(where: {
                        let ext = $0.pathExtension.lowercased()
                        return ext == "nsp" || ext == "xci" || ext == "nsz" || ext == "zip"
                    })
                    if let finalURL = matching {
                        self?.completeTask(titleId: titleId, fileURL: finalURL)
                        return
                    }
                }
                self?.completeTask(titleId: titleId, fileURL: destinationDirectory)
            } else {
                self?.failTask(titleId: titleId, error: NSError(domain: "DownloadEngine", code: Int(p.terminationStatus), userInfo: [NSLocalizedDescriptionKey: "Download via aria2c encerrou com erro (código \(p.terminationStatus))"]))
            }
        }
        
        activeProcesses[titleId] = proc
        do {
            try proc.run()
        } catch {
            failTask(titleId: titleId, error: error)
        }
    }
    
    private func parseAria2Output(_ rawText: String, titleId: String) {
        // Handle carriage returns and newlines in aria2c terminal output
        let lines = rawText.components(separatedBy: CharacterSet(charactersIn: "\r\n"))
        for line in lines {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            guard trimmed.hasPrefix("[#") else { continue }
            
            var pct: Double? = nil
            if let pctStart = trimmed.range(of: "("), let pctEnd = trimmed.range(of: "%)") {
                let pctSub = trimmed[pctStart.upperBound..<pctEnd.lowerBound]
                if let p = Double(pctSub) {
                    pct = p
                }
            }
            
            var speed: String = ""
            if let dlRange = trimmed.range(of: "DL:") {
                let afterDL = trimmed[dlRange.upperBound...]
                if let spaceIdx = afterDL.firstIndex(where: { $0 == " " || $0 == "]" }) {
                    speed = String(afterDL[..<spaceIdx])
                }
            }
            
            var eta: String = ""
            if let etaRange = trimmed.range(of: "ETA:") {
                let afterETA = trimmed[etaRange.upperBound...]
                if let spaceIdx = afterETA.firstIndex(where: { $0 == " " || $0 == "]" }) {
                    eta = String(afterETA[..<spaceIdx])
                }
            }
            
            var peers: Int = 0
            if let cnRange = trimmed.range(of: "CN:") {
                let afterCN = trimmed[cnRange.upperBound...]
                let digits = afterCN.prefix(while: { $0.isNumber })
                if let count = Int(digits) {
                    peers = count
                }
            }
            
            lock.lock()
            defer { lock.unlock() }
            if var task = activeTasks[titleId] {
                if let pct = pct {
                    task.progress = pct / 100.0
                }
                if !speed.isEmpty && speed != "0B" {
                    task.speedString = speed + "/s"
                } else if peers > 0 {
                    task.speedString = "\(peers) peers"
                } else {
                    task.speedString = "Conectando..."
                }
                if !eta.isEmpty {
                    task.etaString = eta
                }
                activeTasks[titleId] = task
                let handler = progressHandlers[titleId]
                DispatchQueue.main.async {
                    handler?(task)
                }
            }
        }
    }
    
    private func findAria2Binary() -> String? {
        let candidates = [
            BundledTools.tool("aria2c"),
            "/opt/homebrew/bin/aria2c",
            "/usr/local/bin/aria2c",
            "/usr/bin/aria2c"
        ]
        return candidates.compactMap { $0 }.first(where: { FileManager.default.isExecutableFile(atPath: $0) })
    }
    
    // MARK: - URLSessionDownloadDelegate
    public func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask, didWriteData bytesWritten: Int64, totalBytesWritten: Int64, totalBytesExpectedToWrite: Int64) {
        lock.lock()
        defer { lock.unlock() }
        guard let titleId = activeURLSessions[downloadTask.taskIdentifier], var task = activeTasks[titleId] else { return }
        
        task.downloadedBytes = totalBytesWritten
        task.totalBytes = totalBytesExpectedToWrite
        if totalBytesExpectedToWrite > 0 {
            task.progress = Double(totalBytesWritten) / Double(totalBytesExpectedToWrite)
        }
        
        let mb = Double(totalBytesWritten) / (1024 * 1024)
        task.speedString = String(format: "%.1f MB", mb)
        
        activeTasks[titleId] = task
        let handler = progressHandlers[titleId]
        DispatchQueue.main.async {
            handler?(task)
        }
    }
    
    public func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask, didFinishDownloadingTo location: URL) {
        lock.lock()
        defer { lock.unlock() }
        guard let titleId = activeURLSessions.removeValue(forKey: downloadTask.taskIdentifier) else { return }
        
        // Handle Google Drive virus scan warning page (>100MB files)
        if let data = try? Data(contentsOf: location, options: .alwaysMapped), data.count < 60_000,
           let text = String(data: data, encoding: .utf8),
           (text.contains("uc-download-link") || text.contains("download-form")) {
            if let confirmURL = extractGoogleDriveConfirmationURL(from: text, originalURL: downloadTask.originalRequest?.url) {
                var newReq = URLRequest(url: confirmURL)
                newReq.setValue("Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/605.1.15", forHTTPHeaderField: "User-Agent")
                let newTask = session.downloadTask(with: newReq)
                activeURLSessions[newTask.taskIdentifier] = titleId
                newTask.resume()
                return
            }
        }
        
        // Move file from temporary location to user downloads
        let downloadsFolder = FileManager.default.urls(for: .downloadsDirectory, in: .userDomainMask).first ?? URL(fileURLWithPath: NSHomeDirectory()).appendingPathComponent("Downloads")
        let nxDownloads = downloadsFolder.appendingPathComponent("NxNative")
        try? FileManager.default.createDirectory(at: nxDownloads, withIntermediateDirectories: true)
        
        let suggestedName = downloadTask.response?.suggestedFilename ?? "\(titleId).nsp"
        let destURL = nxDownloads.appendingPathComponent(suggestedName)
        
        try? FileManager.default.removeItem(at: destURL)
        do {
            try FileManager.default.moveItem(at: location, to: destURL)
            completeTask(titleId: titleId, fileURL: destURL)
        } catch {
            failTask(titleId: titleId, error: error)
        }
    }
    
    private func extractGoogleDriveConfirmationURL(from html: String, originalURL: URL?) -> URL? {
        // Pattern 1: form action="https://drive.usercontent.google.com/download?..."
        let formActionPattern = "action=[\"']([^\"']+)[\"']"
        if let regex = try? NSRegularExpression(pattern: formActionPattern) {
            let nsHtml = html as NSString
            let matches = regex.matches(in: html, options: [], range: NSRange(location: 0, length: nsHtml.length))
            for m in matches where m.numberOfRanges > 1 {
                let action = nsHtml.substring(with: m.range(at: 1)).replacingOccurrences(of: "&amp;", with: "&")
                if action.contains("confirm=") || action.contains("id=") {
                    return URL(string: action, relativeTo: originalURL)
                }
            }
        }
        
        // Pattern 2: a href="https://drive.usercontent.google.com/..."
        let linkPattern = "id=[\"']uc-download-link[\"'][^>]*href=[\"']([^\"']+)[\"']"
        if let regex = try? NSRegularExpression(pattern: linkPattern) {
            let nsHtml = html as NSString
            if let m = regex.firstMatch(in: html, options: [], range: NSRange(location: 0, length: nsHtml.length)), m.numberOfRanges > 1 {
                let link = nsHtml.substring(with: m.range(at: 1)).replacingOccurrences(of: "&amp;", with: "&")
                return URL(string: link, relativeTo: originalURL)
            }
        }
        return nil
    }
    
    public func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        lock.lock()
        defer { lock.unlock() }
        guard let titleId = activeURLSessions.removeValue(forKey: task.taskIdentifier) else { return }
        if let err = error {
            failTask(titleId: titleId, error: err)
        }
    }
    
    private func completeTask(titleId: String, fileURL: URL) {
        if var task = activeTasks[titleId] {
            task.progress = 1.0
            task.status = .completed
            task.localDestinationURL = fileURL
            activeTasks.removeValue(forKey: titleId)
            let pHandler = progressHandlers.removeValue(forKey: titleId)
            let cHandler = completionHandlers.removeValue(forKey: titleId)
            DispatchQueue.main.async {
                pHandler?(task)
                cHandler?(.success(fileURL))
            }
        }
    }
    
    private func failTask(titleId: String, error: Error) {
        if var task = activeTasks[titleId] {
            task.status = .failed
            task.errorMessage = error.localizedDescription
            activeTasks.removeValue(forKey: titleId)
            let pHandler = progressHandlers.removeValue(forKey: titleId)
            let cHandler = completionHandlers.removeValue(forKey: titleId)
            DispatchQueue.main.async {
                pHandler?(task)
                cHandler?(.failure(error))
            }
        }
    }
}
