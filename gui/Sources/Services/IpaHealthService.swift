import Foundation
import SwiftUI

/// Diagnostic defect categories detected inside a ported `.ipa` package or its cached Hub runtime.
public enum IpaHealthIssue: Hashable, Identifiable {
    case corruptedArchive(String)
    case missingBundleOrExecutable
    case obsoleteShaderChain(current: String?, expected: String)
    case oversizedEmbeddedRomfs(bytes: Int64)
    case hubFrameworkStale(reason: String)

    public var id: String {
        switch self {
        case .corruptedArchive(let msg): return "corrupted_\(msg)"
        case .missingBundleOrExecutable: return "missing_bundle"
        case .obsoleteShaderChain(let cur, let exp): return "chain_\(cur ?? "none")_\(exp)"
        case .oversizedEmbeddedRomfs(let bytes): return "romfs_\(bytes)"
        case .hubFrameworkStale(let reason): return "hub_\(reason)"
        }
    }

    /// True if the issue resides inside the `.ipa` itself and requires removing/re-porting the `.ipa`.
    public var requiresIpaRebuild: Bool {
        switch self {
        case .corruptedArchive, .missingBundleOrExecutable, .obsoleteShaderChain, .oversizedEmbeddedRomfs:
            return true
        case .hubFrameworkStale:
            return false
        }
    }

    public var localizedSummary: String {
        switch self {
        case .corruptedArchive(let detail):
            return L10n.t("ipa_health.issue_corrupted", detail)
        case .missingBundleOrExecutable:
            return L10n.t("ipa_health.issue_missing_bundle")
        case .obsoleteShaderChain(let current, let expected):
            return L10n.t("ipa_health.issue_obsolete_chain", current ?? "—", expected)
        case .oversizedEmbeddedRomfs(let bytes):
            let formatted = ByteCountFormatter.string(fromByteCount: bytes, countStyle: .file)
            return L10n.t("ipa_health.issue_oversized_romfs", formatted)
        case .hubFrameworkStale(let reason):
            return L10n.t("ipa_health.issue_hub_stale", reason)
        }
    }
}

/// Complete health report for an iOS `.ipa` package.
public struct IpaHealthReport: Identifiable, Hashable {
    public let id: String
    public let ipaURL: URL
    public let titleId: String?
    public let bundleId: String?
    public let expectedChain: String?
    public let detectedChain: String?
    public let embeddedRomfsBytes: Int64
    public let issues: [IpaHealthIssue]
    public let inspectedAt: Date

    /// True when the `.ipa` archive itself has defects causing 30+ min rebuilds, stalls, or install failures.
    public var hasIpaDefect: Bool {
        issues.contains { $0.requiresIpaRebuild }
    }

    /// True when no issues at all were detected.
    public var isHealthy: Bool {
        issues.isEmpty
    }

    /// True when extraction/install cannot succeed even standalone (corrupted archive or missing bundle).
    public var isUnusableArchive: Bool {
        issues.contains {
            if case .corruptedArchive = $0 { return true }
            if case .missingBundleOrExecutable = $0 { return true }
            return false
        }
    }

    public var shortBadgeText: String {
        if issues.contains(where: { if case .corruptedArchive = $0 { return true }; if case .missingBundleOrExecutable = $0 { return true }; return false }) {
            return L10n.t("ipa_health.badge_corrupted")
        }
        if issues.contains(where: { if case .obsoleteShaderChain = $0 { return true }; return false }) {
            return L10n.t("ipa_health.badge_obsolete_shader")
        }
        if issues.contains(where: { if case .oversizedEmbeddedRomfs = $0 { return true }; return false }) {
            return L10n.t("ipa_health.badge_bloated_romfs")
        }
        if issues.contains(where: { if case .hubFrameworkStale = $0 { return true }; return false }) {
            return L10n.t("ipa_health.badge_hub_stale")
        }
        return L10n.t("ipa_health.badge_ready")
    }

    public var badgeColor: Color {
        if isUnusableArchive {
            return Color.red
        }
        if hasIpaDefect {
            return Color.orange
        }
        if !issues.isEmpty {
            return Color.yellow
        }
        return Color(red: 0.13, green: 0.77, blue: 0.37)
    }

    public var detailedExplanation: String {
        issues.map { "• \($0.localizedSummary)" }.joined(separator: "\n")
    }
}

/// Inspects `.ipa` archives for corruption, obsolete NVN shader chains (`DMSH_CHAIN`), bloated embedded RomFS,
/// and safely trashes defective `.ipa` artifacts while preserving `_build` shader caches for fast re-porting.
public final class IpaHealthService: ObservableObject {
    public static let shared = IpaHealthService()

    @Published public private(set) var cachedReportsByPath: [String: IpaHealthReport] = [:]

    private let cacheLock = NSLock()
    private var cacheKeys: [String: String] = [:]

    private init() {}

    /// Clears cached health inspection results (e.g. after a re-port, Trash cleanup, or core repo update).
    public func invalidateCache(for url: URL? = nil) {
        cacheLock.lock()
        if let u = url {
            let path = u.standardizedFileURL.path
            cacheKeys.removeValue(forKey: path)
            DispatchQueue.main.async {
                self.cachedReportsByPath.removeValue(forKey: path)
            }
        } else {
            cacheKeys.removeAll()
            DispatchQueue.main.async {
                self.cachedReportsByPath.removeAll()
            }
        }
        cacheLock.unlock()
    }

    /// Returns an already cached report matching the current `.ipa` size, mtime, and `DMSH_CHAIN`, if available.
    public func cachedReport(for game: PortedGame) -> IpaHealthReport? {
        let ipaURL = resolveIpaURL(for: game)
        guard ipaURL.pathExtension.lowercased() == "ipa" else { return nil }
        let key = cacheFingerprint(for: ipaURL)
        let stdPath = ipaURL.standardizedFileURL.path
        cacheLock.lock()
        let matches = (cacheKeys[stdPath] == key)
        cacheLock.unlock()
        guard matches else { return nil }
        return cachedReportsByPath[stdPath]
    }

    /// Asynchronously inspects an iOS game's `.ipa` package and updates `cachedReportsByPath`.
    public func inspectAsync(game: PortedGame, forceRefresh: Bool = false, completion: ((IpaHealthReport?) -> Void)? = nil) {
        let ipaURL = resolveIpaURL(for: game)
        guard ipaURL.pathExtension.lowercased() == "ipa" else {
            DispatchQueue.main.async { completion?(nil) }
            return
        }
        if !forceRefresh, let existing = cachedReport(for: game) {
            DispatchQueue.main.async { completion?(existing) }
            return
        }
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            guard let self = self else { return }
            let report = self.inspectSync(ipaURL: ipaURL, titleIdHint: game.titleId, romfsThresholdGB: AppViewModel.shared?.autoRomfsSplitLimitGB ?? 2.0)
            DispatchQueue.main.async {
                completion?(report)
            }
        }
    }

    /// Synchronously inspects a list of `.ipa` games in parallel on a background queue and invokes completion on the main queue.
    public func inspectBatchAsync(games: [PortedGame], forceRefresh: Bool = false, completion: (([String: IpaHealthReport]) -> Void)? = nil) {
        let ipaGames = games.filter { resolveIpaURL(for: $0).pathExtension.lowercased() == "ipa" }
        guard !ipaGames.isEmpty else {
            DispatchQueue.main.async { completion?([:]) }
            return
        }

        let thresholdGB = AppViewModel.shared?.autoRomfsSplitLimitGB ?? 2.0
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            guard let self = self else { return }
            var results: [String: IpaHealthReport] = [:]
            for g in ipaGames {
                let url = self.resolveIpaURL(for: g)
                if !forceRefresh, let cached = self.cachedReport(for: g) {
                    results[url.standardizedFileURL.path] = cached
                } else {
                    let report = self.inspectSync(ipaURL: url, titleIdHint: g.titleId, romfsThresholdGB: thresholdGB)
                    results[url.standardizedFileURL.path] = report
                }
            }
            DispatchQueue.main.async {
                completion?(results)
            }
        }
    }

    /// Synchronously validates a `.ipa` file (bounded subprocesses with strict 2.5s timeouts).
    public func inspectSync(
        ipaURL: URL,
        titleIdHint: String? = nil,
        romfsThresholdGB: Double = 2.0
    ) -> IpaHealthReport {
        let fm = FileManager.default
        let stdPath = ipaURL.standardizedFileURL.path
        let expectedChain = NxHubDeploymentService.shared.expectedShaderChain()

        guard fm.fileExists(atPath: stdPath) else {
            let report = IpaHealthReport(
                id: stdPath,
                ipaURL: ipaURL,
                titleId: titleIdHint?.uppercased(),
                bundleId: nil,
                expectedChain: expectedChain,
                detectedChain: nil,
                embeddedRomfsBytes: 0,
                issues: [.corruptedArchive("Arquivo .ipa não encontrado em disco.")],
                inspectedAt: Date()
            )
            storeReport(report, for: ipaURL)
            return report
        }

        let fileSize = (try? ipaURL.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0
        guard fileSize > 4096 else {
            let report = IpaHealthReport(
                id: stdPath,
                ipaURL: ipaURL,
                titleId: titleIdHint?.uppercased(),
                bundleId: nil,
                expectedChain: expectedChain,
                detectedChain: nil,
                embeddedRomfsBytes: 0,
                issues: [.corruptedArchive("Arquivo .ipa vazio ou truncado (\(fileSize) bytes).")],
                inspectedAt: Date()
            )
            storeReport(report, for: ipaURL)
            return report
        }

        var issues: [IpaHealthIssue] = []

        // 1. Inspect central directory via `unzip -l` (bounded 2.5s)
        let listResult = runBoundedUnzip(arguments: ["-l", stdPath], timeout: 2.5)
        guard listResult.exitCode == 0, !listResult.timedOut else {
            let msg = listResult.timedOut
                ? "Tempo limite excedido ao inspecionar o catálogo ZIP do .ipa."
                : "Arquivo .ipa corrompido (catálogo ZIP inválido, código \(listResult.exitCode))."
            let report = IpaHealthReport(
                id: stdPath,
                ipaURL: ipaURL,
                titleId: titleIdHint?.uppercased(),
                bundleId: nil,
                expectedChain: expectedChain,
                detectedChain: nil,
                embeddedRomfsBytes: 0,
                issues: [.corruptedArchive(msg)],
                inspectedAt: Date()
            )
            storeReport(report, for: ipaURL)
            return report
        }

        let entries = parseUnzipListing(listResult.stdoutText)
        let infoPlistEntry = entries.first(where: { entry in
            let parts = entry.path.split(separator: "/")
            return parts.count == 3 && parts[0] == "Payload" && parts[1].hasSuffix(".app") && parts[2] == "Info.plist"
        })

        guard let plistPath = infoPlistEntry?.path else {
            let report = IpaHealthReport(
                id: stdPath,
                ipaURL: ipaURL,
                titleId: titleIdHint?.uppercased(),
                bundleId: nil,
                expectedChain: expectedChain,
                detectedChain: nil,
                embeddedRomfsBytes: 0,
                issues: [.missingBundleOrExecutable],
                inspectedAt: Date()
            )
            storeReport(report, for: ipaURL)
            return report
        }

        let appPrefix = String(plistPath.dropLast("Info.plist".count)) // e.g. Payload/DmIOS.app/

        // 2. Read Info.plist directly from archive (bounded 2.0s)
        let plistResult = runBoundedUnzip(arguments: ["-p", stdPath, plistPath], timeout: 2.0)
        var bundleId: String? = nil
        var plistTitleId: String? = nil
        var plistChain: String? = nil
        var executableName: String? = nil

        if plistResult.exitCode == 0,
           !plistResult.stdoutData.isEmpty,
           let plistObj = try? PropertyListSerialization.propertyList(from: plistResult.stdoutData, format: nil) as? [String: Any] {
            bundleId = plistObj["CFBundleIdentifier"] as? String
            executableName = plistObj["CFBundleExecutable"] as? String
            if let tid = plistObj["DMTitleID"] as? String, !tid.isEmpty {
                plistTitleId = tid.uppercased()
            } else if let bid = bundleId,
                      let range = bid.range(of: "(?:0100|0400)[0-9A-Fa-f]{12}", options: .regularExpression) {
                plistTitleId = String(bid[range]).uppercased()
            }
            if let ch = plistObj["DMChain"] as? String, !ch.isEmpty {
                plistChain = ch.hasPrefix("b-") ? String(ch.dropFirst(2)) : ch
            }
        } else {
            issues.append(.corruptedArchive("Falha ao ler Payload/*.app/Info.plist."))
        }

        if let exe = executableName, !exe.isEmpty {
            let expectedExePath = "\(appPrefix)\(exe)"
            if !entries.contains(where: { $0.path == expectedExePath && $0.size > 0 }) {
                issues.append(.missingBundleOrExecutable)
            }
        } else if !issues.contains(where: { if case .corruptedArchive = $0 { return true }; return false }) {
            issues.append(.missingBundleOrExecutable)
        }

        // 3. Detect NVN shader chain from msl/b-* folder/file or Info.plist DMChain
        var mslChains = Set<String>()
        var usesNonNvnBackend = false
        for entry in entries where entry.path.hasPrefix("\(appPrefix)msl/") {
            let suffix = String(entry.path.dropFirst("\(appPrefix)msl/".count))
            let topComponent = suffix.split(separator: "/").first.map(String.init) ?? ""
            if topComponent.hasPrefix("b-") {
                let raw = topComponent.replacingOccurrences(of: ".img", with: "").replacingOccurrences(of: ".key", with: "")
                mslChains.insert(String(raw.dropFirst(2)))
            } else if topComponent == "vk" || topComponent == "gl" {
                usesNonNvnBackend = true
            }
        }

        let detectedChain = plistChain ?? mslChains.sorted().first
        if let exp = expectedChain {
            if let det = detectedChain {
                if det != exp || (mslChains.count > 0 && !mslChains.contains(exp)) {
                    issues.append(.obsoleteShaderChain(current: "b-\(det)", expected: "b-\(exp)"))
                }
            } else if !usesNonNvnBackend {
                issues.append(.obsoleteShaderChain(current: nil, expected: "b-\(exp)"))
            }
        }

        // 4. Detect bloated embedded RomFS inside Payload/*.app/romfs.img
        let embeddedRomfsEntry = entries.first(where: { $0.path == "\(appPrefix)romfs.img" })
        let embeddedBytes = embeddedRomfsEntry?.size ?? 0
        let hasCompanionRomfs = hasSiblingRomfsImage(for: ipaURL)
        let thresholdBytes = Int64(max(0.5, romfsThresholdGB) * 1024.0 * 1024.0 * 1024.0)
        if embeddedBytes > 0 && ((hasCompanionRomfs && embeddedBytes > 256 * 1024 * 1024) || embeddedBytes >= thresholdBytes) {
            issues.append(.oversizedEmbeddedRomfs(bytes: embeddedBytes))
        }

        // 5. Inspect associated Hub framework cache status if it exists in MobileHub/Frameworks
        let resolvedTitleId = (plistTitleId ?? titleIdHint)?.uppercased()
        if let tid = resolvedTitleId, !tid.isEmpty {
            let fwURL = NxHubDeploymentService.shared.hubFrameworksURL.appendingPathComponent("DmGame\(tid).framework")
            if fm.fileExists(atPath: fwURL.path) {
                let fwCheck = NxHubDeploymentService.shared.validateFramework(at: fwURL, titleId: tid)
                if !fwCheck.valid {
                    issues.append(.hubFrameworkStale(reason: fwCheck.reason ?? "desatualizado"))
                }
            }
        }

        let report = IpaHealthReport(
            id: stdPath,
            ipaURL: ipaURL,
            titleId: resolvedTitleId,
            bundleId: bundleId,
            expectedChain: expectedChain,
            detectedChain: detectedChain,
            embeddedRomfsBytes: embeddedBytes,
            issues: issues,
            inspectedAt: Date()
        )
        storeReport(report, for: ipaURL)
        return report
    }

    /// Safely moves a failing `.ipa` and its deploy artifacts (`.ipa.idx`, `deploy_cache`, and invalid Hub framework)
    /// to macOS Trash while **strictly preserving** `<TitleID>_build/` shader caches and companion `.romfs.img`.
    @discardableResult
    public func trashFailedIpaArtifacts(
        for game: PortedGame,
        purgeStaleFramework: Bool = true
    ) -> (trashedPaths: [String], errors: [String]) {
        let fm = FileManager.default
        let ipaURL = resolveIpaURL(for: game)
        var trashed: [String] = []
        var errors: [String] = []

        func moveToTrashIfExists(_ url: URL) {
            guard fm.fileExists(atPath: url.path) else { return }
            do {
                var resulting: NSURL?
                try fm.trashItem(at: url, resultingItemURL: &resulting)
                trashed.append(url.path)
            } catch {
                errors.append("Falha ao mover \(url.lastPathComponent) para o Lixo: \(error.localizedDescription)")
            }
        }

        // 1. Trash failing .ipa and .ipa.idx only (keep <Name>.romfs.img and <TitleID>_build intact!)
        if ipaURL.pathExtension.lowercased() == "ipa" {
            moveToTrashIfExists(ipaURL)
            moveToTrashIfExists(URL(fileURLWithPath: ipaURL.path + ".idx"))
        }

        // 2. Trash matching deploy_cache entries (stale unzipped Bundles / rewritten Info.plists / old romfs.img)
        let deployCacheDir = SystemDetector.shared.cachesDirectory.appendingPathComponent("deploy_cache")
        let stemRaw = ipaURL.deletingPathExtension().lastPathComponent
        let stemVariants = RomfsIdentityVerifier.filenameVariants(of: stemRaw) + RomfsIdentityVerifier.filenameVariants(of: game.name)
        let safePrefixes = stemVariants.map { $0.replacingOccurrences(of: " ", with: "_") + "_" }.filter { $0.count > 1 }
        if let cacheEntries = try? fm.contentsOfDirectory(at: deployCacheDir, includingPropertiesForKeys: nil) {
            for entry in cacheEntries {
                let name = entry.lastPathComponent
                let nameVariants = [name, name.precomposedStringWithCanonicalMapping, name.decomposedStringWithCanonicalMapping]
                if safePrefixes.contains(where: { prefix in nameVariants.contains(where: { $0.hasPrefix(prefix) }) }) {
                    moveToTrashIfExists(entry)
                }
            }
        }

        // 3. Trash Hub framework when stale/invalid (or unconditionally when preparing a clean re-port)
        if purgeStaleFramework, let tid = game.titleId?.uppercased(), !tid.isEmpty {
            let fwURL = NxHubDeploymentService.shared.hubFrameworksURL.appendingPathComponent("DmGame\(tid).framework")
            if fm.fileExists(atPath: fwURL.path) {
                moveToTrashIfExists(fwURL)
            }
        }

        invalidateCache(for: ipaURL)
        return (trashed, errors)
    }

    // MARK: - Helpers
    public func resolveIpaURL(for game: PortedGame) -> URL {
        if game.url.pathExtension.lowercased() == "ipa" {
            return game.url
        }
        let candidate = DeviceDeploymentService.shared.resolveDeployableURL(for: game)
        if candidate.pathExtension.lowercased() == "ipa" {
            return candidate
        }
        if let appViewModel = AppViewModel.shared,
           let matchedIos = appViewModel.iosPort(for: game) {
            return matchedIos.url
        }
        return game.url
    }

    private func hasSiblingRomfsImage(for ipaURL: URL) -> Bool {
        let fm = FileManager.default
        let dir = ipaURL.deletingLastPathComponent()
        let stem = ipaURL.deletingPathExtension().lastPathComponent
        let variants = Set([
            stem,
            stem.replacingOccurrences(of: "’", with: "'"),
            stem.replacingOccurrences(of: "'", with: "’")
        ])
        for v in variants {
            let c1 = dir.appendingPathComponent("\(v).romfs.img")
            let c2 = dir.appendingPathComponent("\(v).RomFS.img")
            if fm.fileExists(atPath: c1.path) || fm.fileExists(atPath: c2.path) {
                return true
            }
        }
        return false
    }

    private func cacheFingerprint(for ipaURL: URL) -> String {
        let values = try? ipaURL.resourceValues(forKeys: [.fileSizeKey, .contentModificationDateKey])
        let size = values?.fileSize ?? 0
        let mtime = Int(values?.contentModificationDate?.timeIntervalSince1970 ?? 0)
        let exp = NxHubDeploymentService.shared.expectedShaderChain() ?? "none"
        return "v2_\(size)_\(mtime)_\(exp)"
    }

    private func storeReport(_ report: IpaHealthReport, for ipaURL: URL) {
        let stdPath = ipaURL.standardizedFileURL.path
        let fp = cacheFingerprint(for: ipaURL)
        cacheLock.lock()
        cacheKeys[stdPath] = fp
        cacheLock.unlock()
        DispatchQueue.main.async {
            self.cachedReportsByPath[stdPath] = report
        }
    }

    private struct ZipEntry {
        let size: Int64
        let path: String
    }

    private func parseUnzipListing(_ output: String) -> [ZipEntry] {
        var entries: [ZipEntry] = []
        for rawLine in output.split(whereSeparator: \.isNewline) {
            let line = String(rawLine).trimmingCharacters(in: .whitespaces)
            // Standard unzip -l line starts with length, date, time, name
            let parts = line.split(maxSplits: 3, omittingEmptySubsequences: true, whereSeparator: \.isWhitespace)
            guard parts.count == 4, let size = Int64(parts[0]) else { continue }
            let path = String(parts[3]).trimmingCharacters(in: .whitespacesAndNewlines)
            guard !path.isEmpty else { continue }
            entries.append(ZipEntry(size: size, path: path))
        }
        return entries
    }

    private func runBoundedUnzip(arguments: [String], timeout: TimeInterval) -> (exitCode: Int32, timedOut: Bool, stdoutData: Data, stdoutText: String) {
        let proc = Process()
        proc.executableURL = URL(fileURLWithPath: "/usr/bin/unzip")
        proc.arguments = arguments

        let outPipe = Pipe()
        let errPipe = Pipe()
        proc.standardOutput = outPipe
        proc.standardError = errPipe

        var stdoutData = Data()
        let dataLock = NSLock()
        outPipe.fileHandleForReading.readabilityHandler = { handle in
            let chunk = handle.availableData
            if !chunk.isEmpty {
                dataLock.lock()
                stdoutData.append(chunk)
                dataLock.unlock()
            }
        }

        let flagLock = NSLock()
        var timedOut = false
        let watchdog = DispatchSource.makeTimerSource(queue: DispatchQueue.global())
        watchdog.schedule(deadline: .now() + timeout)
        watchdog.setEventHandler { [weak proc] in
            guard let p = proc, p.isRunning else { return }
            flagLock.lock()
            timedOut = true
            flagLock.unlock()
            p.terminate()
        }

        do {
            try proc.run()
            watchdog.resume()
            proc.waitUntilExit()
            watchdog.cancel()
            outPipe.fileHandleForReading.readabilityHandler = nil
            let rem = outPipe.fileHandleForReading.readDataToEndOfFile()
            if !rem.isEmpty {
                dataLock.lock()
                stdoutData.append(rem)
                dataLock.unlock()
            }
            flagLock.lock()
            let didTimeout = timedOut
            flagLock.unlock()
            let text = String(data: stdoutData, encoding: .utf8) ?? ""
            return (proc.terminationStatus, didTimeout, stdoutData, text)
        } catch {
            watchdog.cancel()
            outPipe.fileHandleForReading.readabilityHandler = nil
            return (-1, false, Data(), "")
        }
    }
}
