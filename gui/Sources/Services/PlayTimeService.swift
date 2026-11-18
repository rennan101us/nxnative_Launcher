import Foundation
import AppKit
import Darwin

public final class PlayTimeService: ObservableObject {
    public static let shared = PlayTimeService()
    
    private let userDefaultsKey = "nxnative_play_time_records"
    private let seededHistoryDefaultsKey = "nxnative_playtime_history_seeded_v1"
    private let fileManager = FileManager.default
    
    @Published public private(set) var refreshId: UUID = UUID()
    private var inMemoryCache: [String: TimeInterval] = [:]
    private var hydratedKeys: Set<String> = []
    private var iCloudCheckedKeys: Set<String> = []
    private var seededHistoryKeys: Set<String> = []

    private struct ActiveSession {
        let game: PortedGame
        let key: String
        let pid: pid_t
        let startDate: Date
        var lastCheckpointDate: Date
        var hasCommittedMinimum: Bool
    }

    private var activeSessions: [pid_t: ActiveSession] = [:]
    private var sessionTimer: DispatchSourceTimer?
    
    private init() {
        if let stored = UserDefaults.standard.dictionary(forKey: userDefaultsKey) as? [String: Double] {
            self.inMemoryCache = stored
        }
        if let seeded = UserDefaults.standard.stringArray(forKey: seededHistoryDefaultsKey) {
            self.seededHistoryKeys = Set(seeded)
        }
    }

    // MARK: - Key Normalization
    private func canonicalKey(for game: PortedGame) -> String {
        if let tid = game.titleId?.trimmingCharacters(in: .whitespacesAndNewlines), !tid.isEmpty {
            return tid.uppercased()
        }
        if let bid = game.bundleId?.trimmingCharacters(in: .whitespacesAndNewlines), !bid.isEmpty {
            return bid.lowercased()
        }
        return game.name
    }

    private func candidateCacheKeys(for game: PortedGame) -> [String] {
        var keys: [String] = []
        let canonical = canonicalKey(for: game)
        keys.append(canonical)
        let raw = game.uniqueKey
        for k in [raw, raw.uppercased(), raw.lowercased(), game.bundleId, game.name] {
            if let k = k, !k.isEmpty, !keys.contains(k) {
                keys.append(k)
            }
        }
        return keys
    }
    
    // MARK: - Query Play Time
    public func totalPlayTime(for game: PortedGame) -> TimeInterval {
        let key = canonicalKey(for: game)
        var total = candidateCacheKeys(for: game).compactMap { inMemoryCache[$0] }.max() ?? 0
        if inMemoryCache[key] != total && total > 0 {
            inMemoryCache[key] = total
            persistLocalCache()
        }

        if hydratedKeys.contains(key) {
            return total
        }
        hydratedKeys.insert(key)

        var didChange = false

        // 1. Check local playtime.json in AppSupport (survives UserDefaults resets & external SSD migrations)
        if let localFileSec = readLocalAppSupportPlayTime(for: game), localFileSec > total {
            total = localFileSec
            didChange = true
        }

        // 2. Check Ryujinx historical play time if titleId exists
        if let tid = game.titleId, !tid.isEmpty {
            if let ryujinxSec = readRyujinxPlayTime(titleId: tid), ryujinxSec > total {
                total = ryujinxSec
                didChange = true
            }
        }

        // 3. Reconstruct historical native session duration from local saves/snapshots/PSO/logs once
        if !seededHistoryKeys.contains(key) {
            seededHistoryKeys.insert(key)
            UserDefaults.standard.set(Array(seededHistoryKeys), forKey: seededHistoryDefaultsKey)
            if let estimatedSec = estimateHistoricalPlayTime(for: game), estimatedSec > total {
                total = estimatedSec
                didChange = true
            }
        }

        if didChange && total > 0 {
            inMemoryCache[key] = total
            persistLocalCache()
            writeLocalAppSupportPlayTime(for: game, seconds: total)
        }

        // 4. Refresh asynchronously from iCloud if available without blocking main-thread UI rendering
        if !iCloudCheckedKeys.contains(key) && SaveSyncService.shared.isICloudDriveAvailable {
            iCloudCheckedKeys.insert(key)
            DispatchQueue.global(qos: .utility).async { [weak self] in
                guard let self = self,
                      let cloudSec = self.readICloudPlayTime(for: game) else { return }
                DispatchQueue.main.async {
                    let current = self.inMemoryCache[key] ?? 0
                    if cloudSec > current {
                        self.inMemoryCache[key] = cloudSec
                        self.persistLocalCache()
                        self.writeLocalAppSupportPlayTime(for: game, seconds: cloudSec)
                        self.refreshId = UUID()
                        self.objectWillChange.send()
                    }
                }
            }
        }
        
        return total
    }
    
    public func formattedPlayTime(for game: PortedGame) -> String {
        let seconds = totalPlayTime(for: game)
        return formatTimeInterval(seconds)
    }
    
    public func formatTimeInterval(_ seconds: TimeInterval) -> String {
        guard seconds >= 60 else {
            return "0 min"
        }
        
        let totalMinutes = Int(seconds / 60)
        let hours = totalMinutes / 60
        let minutes = totalMinutes % 60
        
        if hours > 0 {
            if minutes > 0 {
                return "\(hours)h \(minutes)m"
            } else {
                return "\(hours)h"
            }
        } else {
            return "\(minutes) min"
        }
    }

    // MARK: - Live Session Tracking & Periodic Checkpointing
    public func startSession(for game: PortedGame, pid: pid_t) {
        let block = { [weak self] in
            guard let self = self else { return }
            _ = self.totalPlayTime(for: game)
            let key = self.canonicalKey(for: game)
            let now = Date()
            self.activeSessions[pid] = ActiveSession(
                game: game,
                key: key,
                pid: pid,
                startDate: now,
                lastCheckpointDate: now,
                hasCommittedMinimum: false
            )
            self.ensureSessionTimerRunning()
        }
        if Thread.isMainThread {
            block()
        } else {
            DispatchQueue.main.async(execute: block)
        }
    }

    public func endSession(forPid pid: pid_t) {
        let block = { [weak self] in
            guard let self = self,
                  let session = self.activeSessions.removeValue(forKey: pid) else { return }
            if self.activeSessions.isEmpty {
                self.sessionTimer?.cancel()
                self.sessionTimer = nil
            }

            let now = Date()
            let totalSessionElapsed = now.timeIntervalSince(session.startDate)
            let delta = max(0, now.timeIntervalSince(session.lastCheckpointDate))

            guard session.hasCommittedMinimum || totalSessionElapsed > 5.0 else {
                return
            }

            _ = self.totalPlayTime(for: session.game)
            let current = self.inMemoryCache[session.key] ?? 0
            let updated = current + delta
            self.inMemoryCache[session.key] = updated
            self.persistLocalCache()
            self.writeLocalAppSupportPlayTime(for: session.game, seconds: updated)
            self.writeICloudPlayTime(for: session.game, seconds: updated)

            self.refreshId = UUID()
            self.objectWillChange.send()
        }
        if Thread.isMainThread {
            block()
        } else {
            DispatchQueue.main.async(execute: block)
        }
    }

    private func ensureSessionTimerRunning() {
        guard sessionTimer == nil else { return }
        let timer = DispatchSource.makeTimerSource(queue: DispatchQueue.main)
        timer.schedule(deadline: .now() + 15.0, repeating: 15.0)
        timer.setEventHandler { [weak self] in
            self?.checkpointActiveSessions()
        }
        sessionTimer = timer
        timer.resume()
    }

    private func isProcessAlive(pid: pid_t) -> Bool {
        if let runningApp = NSRunningApplication(processIdentifier: pid) {
            return !runningApp.isTerminated
        }
        return kill(pid, 0) == 0 || errno == EPERM
    }

    private func checkpointActiveSessions() {
        let now = Date()
        var exitedPids: [pid_t] = []
        var anyMinuteChanged = false

        for pid in Array(activeSessions.keys) {
            guard var session = activeSessions[pid] else { continue }
            let alive = isProcessAlive(pid: pid)
            let totalElapsed = now.timeIntervalSince(session.startDate)

            if session.hasCommittedMinimum || totalElapsed >= 5.0 {
                let delta = max(0, now.timeIntervalSince(session.lastCheckpointDate))
                if delta > 0 {
                    let prev = inMemoryCache[session.key] ?? 0
                    let next = prev + delta
                    inMemoryCache[session.key] = next
                    session.lastCheckpointDate = now
                    session.hasCommittedMinimum = true
                    activeSessions[pid] = session
                    persistLocalCache()
                    writeLocalAppSupportPlayTime(for: session.game, seconds: next)
                    if Int(prev / 60) != Int(next / 60) {
                        anyMinuteChanged = true
                    }
                }
            }

            if !alive {
                exitedPids.append(pid)
            }
        }

        for pid in exitedPids {
            endSession(forPid: pid)
        }

        if anyMinuteChanged && exitedPids.isEmpty {
            self.refreshId = UUID()
            self.objectWillChange.send()
        }
    }
    
    // MARK: - Session Recording
    public func recordSession(for game: PortedGame, duration: TimeInterval) {
        guard duration > 5 else { return } // ignore accidental instant launches
        let key = canonicalKey(for: game)
        let current = totalPlayTime(for: game)
        let updated = current + duration
        
        inMemoryCache[key] = updated
        persistLocalCache()
        writeLocalAppSupportPlayTime(for: game, seconds: updated)
        
        // Asynchronously update iCloud playtime file if enabled
        writeICloudPlayTime(for: game, seconds: updated)
        
        DispatchQueue.main.async {
            self.refreshId = UUID()
            self.objectWillChange.send()
        }
    }
    
    private func persistLocalCache() {
        UserDefaults.standard.set(inMemoryCache, forKey: userDefaultsKey)
    }

    // MARK: - Local AppSupport PlayTime Persistence
    private func gameSupportFolders(for game: PortedGame) -> [URL] {
        var candidates: [URL] = []
        let bases = [
            SystemDetector.shared.appSupportDirectory,
            SystemDetector.shared.defaultAppSupportDirectory
        ]
        var names: [String] = []
        if let tid = game.titleId?.trimmingCharacters(in: .whitespacesAndNewlines), !tid.isEmpty {
            names.append(tid.uppercased())
            if tid.lowercased() != tid.uppercased() {
                names.append(tid.lowercased())
            }
        } else if let bid = game.bundleId?.trimmingCharacters(in: .whitespacesAndNewlines), !bid.isEmpty {
            names.append(bid)
        }
        var seen = Set<String>()
        for base in bases {
            for name in names {
                let url = base.appendingPathComponent(name, isDirectory: true).standardizedFileURL
                if seen.insert(url.path).inserted {
                    candidates.append(url)
                }
            }
        }
        return candidates
    }

    private func readPlayTimeJSON(at fileURL: URL) -> TimeInterval? {
        guard fileManager.fileExists(atPath: fileURL.path),
              let data = try? Data(contentsOf: fileURL),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let sec = json["totalSeconds"] as? Double,
              sec > 0 else {
            return nil
        }
        return sec
    }

    private func encodePlayTimePayload(for game: PortedGame, seconds: TimeInterval) -> Data? {
        let payload: [String: Any] = [
            "uniqueKey": canonicalKey(for: game),
            "titleId": game.titleId ?? "",
            "gameName": game.name,
            "totalSeconds": seconds,
            "lastUpdated": Date().timeIntervalSince1970
        ]
        return try? JSONSerialization.data(withJSONObject: payload, options: [.prettyPrinted])
    }

    public func readLocalAppSupportPlayTime(for game: PortedGame) -> TimeInterval? {
        for folder in gameSupportFolders(for: game) {
            if let sec = readPlayTimeJSON(at: folder.appendingPathComponent("playtime.json")) {
                return sec
            }
        }
        return nil
    }

    public func writeLocalAppSupportPlayTime(for game: PortedGame, seconds: TimeInterval) {
        guard seconds > 0, let data = encodePlayTimePayload(for: game, seconds: seconds) else { return }
        let targetFolder = gameSupportFolders(for: game).first
            ?? SystemDetector.shared.appSupportDirectory.appendingPathComponent(canonicalKey(for: game), isDirectory: true)
        try? fileManager.createDirectory(at: targetFolder, withIntermediateDirectories: true)
        let fileURL = targetFolder.appendingPathComponent("playtime.json")
        try? data.write(to: fileURL, options: .atomic)
    }

    // MARK: - Historical Play Time Reconstruction from Local Save/PSO/Log Timestamps
    public func estimateHistoricalPlayTime(for game: PortedGame) -> TimeInterval? {
        var dirsToInspect = gameSupportFolders(for: game)
        let legacyBackupDir = SystemDetector.shared.appSupportDirectory
            .appendingPathComponent("legacy_icloud_backups", isDirectory: true)
            .appendingPathComponent(game.name, isDirectory: true)
            .standardizedFileURL
        if fileManager.fileExists(atPath: legacyBackupDir.path) {
            dirsToInspect.append(legacyBackupDir)
        }
        if SaveSyncService.shared.isICloudDriveAvailable {
            let cloudDir = SaveSyncService.shared.iCloudFolder(for: game).standardizedFileURL
            if fileManager.fileExists(atPath: cloudDir.path) {
                dirsToInspect.append(cloudDir)
            }
        }

        var timestamps: [TimeInterval] = []
        let subdirsToScan = ["save", "save.work", "backups", "pso_archive"]

        for dir in dirsToInspect where fileManager.fileExists(atPath: dir.path) {
            let psoUser = dir.appendingPathComponent("pso_user.tsv")
            if let attrs = try? fileManager.attributesOfItem(atPath: psoUser.path),
               let mdate = attrs[.modificationDate] as? Date {
                timestamps.append(mdate.timeIntervalSince1970)
            }
            for sub in subdirsToScan {
                let subURL = dir.appendingPathComponent(sub, isDirectory: true)
                guard fileManager.fileExists(atPath: subURL.path),
                      let enumerator = fileManager.enumerator(
                        at: subURL,
                        includingPropertiesForKeys: [.contentModificationDateKey, .isRegularFileKey],
                        options: [.skipsHiddenFiles]
                      ) else {
                    continue
                }
                var scanned = 0
                for case let fileURL as URL in enumerator {
                    scanned += 1
                    if scanned > 1000 { break }
                    let name = fileURL.lastPathComponent
                    if name.hasPrefix("Icon") || name == ".DS_Store" { continue }
                    if let vals = try? fileURL.resourceValues(forKeys: [.isRegularFileKey, .contentModificationDateKey]),
                       vals.isRegularFile == true,
                       let mdate = vals.contentModificationDate {
                        timestamps.append(mdate.timeIntervalSince1970)
                    }
                }
            }
        }

        if let tid = game.titleId?.trimmingCharacters(in: .whitespacesAndNewlines), !tid.isEmpty {
            let logsDir = SystemDetector.shared.logsDirectory
            let logNames = ["\(tid.uppercased()).log", "\(tid.uppercased()).prev.log", "\(tid.lowercased()).log", "\(tid.lowercased()).prev.log"]
            var seenLogPaths = Set<String>()
            for name in logNames {
                let logURL = logsDir.appendingPathComponent(name).standardizedFileURL
                guard seenLogPaths.insert(logURL.path).inserted,
                      fileManager.fileExists(atPath: logURL.path) else { continue }
                if let vals = try? logURL.resourceValues(forKeys: [.creationDateKey, .contentModificationDateKey]) {
                    if let cdate = vals.creationDate { timestamps.append(cdate.timeIntervalSince1970) }
                    if let mdate = vals.contentModificationDate { timestamps.append(mdate.timeIntervalSince1970) }
                }
            }
        }

        guard !timestamps.isEmpty else { return nil }
        let sorted = Array(Set(timestamps)).sorted()
        let maxGapSeconds: TimeInterval = 3600.0
        let minClusterSeconds: TimeInterval = 300.0

        var clusters: [(start: TimeInterval, end: TimeInterval)] = []
        for ts in sorted {
            if let last = clusters.last, (ts - last.end) <= maxGapSeconds {
                clusters[clusters.count - 1].end = ts
            } else {
                clusters.append((ts, ts))
            }
        }

        let estimated = clusters.reduce(0.0) { acc, cluster in
            acc + max(cluster.end - cluster.start, minClusterSeconds)
        }
        return estimated > 0 ? estimated : nil
    }
    
    // MARK: - Ryujinx Import
    public func readRyujinxPlayTime(titleId: String) -> TimeInterval? {
        let tidLower = titleId.lowercased()
        let home = fileManager.homeDirectoryForCurrentUser
        let metadataURL = home
            .appendingPathComponent("Library/Application Support/Ryujinx/games", isDirectory: true)
            .appendingPathComponent(tidLower, isDirectory: true)
            .appendingPathComponent("gui/metadata.json")
        
        guard fileManager.fileExists(atPath: metadataURL.path),
              let data = try? Data(contentsOf: metadataURL),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let timespanStr = json["timespan_played"] as? String else {
            return nil
        }
        
        let seconds = Self.parseDotNetTimeSpan(timespanStr)
        return seconds > 0 ? seconds : nil
    }
    
    // MARK: - iCloud Integration
    public func readICloudPlayTime(for game: PortedGame) -> TimeInterval? {
        guard SaveSyncService.shared.isICloudDriveAvailable else { return nil }
        
        var candidateURLs: [URL] = []
        candidateURLs.append(SaveSyncService.shared.iCloudFolder(for: game).appendingPathComponent("playtime.json"))
        if let tid = game.titleId, !tid.isEmpty {
            candidateURLs.append(SaveSyncService.shared.iCloudRootURL.appendingPathComponent(tid.uppercased(), isDirectory: true).appendingPathComponent("playtime.json"))
        }
        
        for url in candidateURLs {
            if let sec = readPlayTimeJSON(at: url) {
                return sec
            }
        }
        return nil
    }
    
    public func writeICloudPlayTime(for game: PortedGame, seconds: TimeInterval) {
        guard seconds > 0, SaveSyncService.shared.isICloudDriveAvailable,
              let data = encodePlayTimePayload(for: game, seconds: seconds) else { return }
        
        DispatchQueue.global(qos: .utility).async { [weak self] in
            guard let self = self else { return }
            let folder = SaveSyncService.shared.iCloudFolder(for: game)
            try? self.fileManager.createDirectory(at: folder, withIntermediateDirectories: true)
            let fileURL = folder.appendingPathComponent("playtime.json")
            try? data.write(to: fileURL, options: .atomic)
            
            // Also duplicate under TITLE_ID directory if available
            if let tid = game.titleId, !tid.isEmpty {
                let tidFolder = SaveSyncService.shared.iCloudRootURL.appendingPathComponent(tid.uppercased(), isDirectory: true)
                try? self.fileManager.createDirectory(at: tidFolder, withIntermediateDirectories: true)
                let tidFileURL = tidFolder.appendingPathComponent("playtime.json")
                try? data.write(to: tidFileURL, options: .atomic)
            }
        }
    }
    
    // MARK: - Helper TimeSpan Parser
    public static func parseDotNetTimeSpan(_ raw: String) -> TimeInterval {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return 0 }
        
        var days: Double = 0
        var timePart = trimmed
        
        // Handle "D.HH:MM:SS" or "D.HH:MM:SS.fff"
        if let dotIndex = timePart.firstIndex(of: ".") {
            let prefix = String(timePart[..<dotIndex])
            if let d = Double(prefix) {
                days = d
                timePart = String(timePart[timePart.index(after: dotIndex)...])
            }
        }
        
        // Strip fractional seconds if any
        if let fracDot = timePart.firstIndex(of: ".") {
            timePart = String(timePart[..<fracDot])
        }
        
        let components = timePart.split(separator: ":").compactMap { Double($0) }
        var seconds: Double = days * 86400
        if components.count == 3 {
            seconds += components[0] * 3600 + components[1] * 60 + components[2]
        } else if components.count == 2 {
            seconds += components[0] * 60 + components[1]
        }
        return seconds
    }
}
