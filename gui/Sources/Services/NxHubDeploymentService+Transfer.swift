import Foundation
import AppKit

// MARK: - NxN Launcher Route C Asset Transfer Extension

extension NxHubDeploymentService {
    /// Returns `url.resolvingSymlinksInPath()` only when it resolves to an existing non-empty regular file.
    private func resolvedNonEmptyFile(_ url: URL) -> (url: URL, size: Int64)? {
        let fm = FileManager.default
        guard !url.lastPathComponent.hasPrefix("._") else { return nil }
        let resolved = url.resolvingSymlinksInPath()
        var isDir: ObjCBool = false
        guard fm.fileExists(atPath: resolved.path, isDirectory: &isDir), !isDir.boolValue else {
            return nil
        }
        let size = (try? fm.attributesOfItem(atPath: resolved.path)[.size] as? Int64) ?? 0
        guard size > 0 else { return nil }
        return (resolved, size)
    }

    private func normalizedRomfsTokens(_ value: String) -> String {
        let folded = value.folding(options: [.diacriticInsensitive, .caseInsensitive], locale: Locale(identifier: "en_US_POSIX"))
        let cleaned = folded.unicodeScalars.map { scalar -> Character in
            CharacterSet.alphanumerics.contains(scalar) ? Character(scalar) : " "
        }
        return String(cleaned)
            .split(whereSeparator: { $0.isWhitespace })
            .joined(separator: " ")
    }

    /// Checks if `parentDir` contains at most one ported game bundle/package so bare `romfs.img`
    /// beside a game cannot accidentally match another game in a shared folder like `Nx Ports`.
    private func isSingleGameParentDirectory(_ parentDir: URL) -> Bool {
        if parentDir.lastPathComponent.caseInsensitiveCompare("Nx Ports") == .orderedSame {
            return false
        }
        guard let entries = try? FileManager.default.contentsOfDirectory(
            at: parentDir,
            includingPropertiesForKeys: nil,
            options: [.skipsHiddenFiles]
        ) else {
            return false
        }
        var gameEntryCount = 0
        for entry in entries {
            let ext = entry.pathExtension.lowercased()
            if ext == "app" || ext == "ipa" || ext == "nup" {
                gameEntryCount += 1
                if gameEntryCount > 1 { return false }
            }
        }
        return true
    }

    /// Fast, non-blocking search for a game's canonical `romfs.img` across local ports, sidecars,
    /// `deploy_cache`, staging folders, external Nintendo storage, or `.app` bundle resources.
    /// Does not spawn `unzip` so it is safe for synchronous/UI size checks.
    public func quickLocateRomfsImage(for game: PortedGame) -> URL? {
        let fm = FileManager.default
        let titleId = (game.titleId ?? "0100000000000000").uppercased()
        let parentDir = game.url.deletingLastPathComponent()
        let stem = game.url.deletingPathExtension().lastPathComponent
        let alt1 = game.name.replacingOccurrences(of: "’", with: "'")
        let alt2 = game.name.replacingOccurrences(of: "'", with: "’")
        let namesToCheck = Array(Set([game.name, stem, alt1, alt2]))
        let normalizedName = normalizedRomfsTokens(game.name)

        // 1. Direct candidates beside the .app/.ipa, inside it, or in Nx Ports
        var candidates: [URL] = []
        for n in namesToCheck where !n.isEmpty {
            candidates.append(parentDir.appendingPathComponent("\(n).romfs.img"))
            candidates.append(URL(fileURLWithPath: "/Volumes/SSD FN501 PRO/Emulations/Nx Ports/\(n).romfs.img"))
        }
        candidates.append(parentDir.appendingPathComponent("\(titleId).romfs.img"))
        if isSingleGameParentDirectory(parentDir) {
            candidates.append(parentDir.appendingPathComponent("RomFS.img"))
            candidates.append(parentDir.appendingPathComponent("romfs.img"))
        }
        candidates.append(URL(fileURLWithPath: "/Volumes/SSD FN501 PRO/Emulations/Nx Ports/\(titleId).romfs.img"))
        candidates.append(game.url.appendingPathComponent("Contents/Resources/romfs.img"))
        candidates.append(game.url.appendingPathComponent("romfs.img"))

        for c in candidates {
            if let hit = resolvedNonEmptyFile(c) {
                return hit.url
            }
        }

        // 2. Fuzzy match inside parentDir or Nx Ports (skipping AppleDouble ._ files)
        for searchDir in [parentDir, URL(fileURLWithPath: "/Volumes/SSD FN501 PRO/Emulations/Nx Ports")] {
            if let dirContents = try? fm.contentsOfDirectory(at: searchDir, includingPropertiesForKeys: nil) {
                for fileURL in dirContents {
                    let fname = fileURL.lastPathComponent
                    guard !fname.hasPrefix("._"), fname.lowercased().contains("romfs.img") else { continue }
                    let normFile = normalizedRomfsTokens(fname)
                    if (!titleId.isEmpty && fname.uppercased().contains(titleId))
                        || (!normalizedName.isEmpty && normFile.contains(normalizedName)) {
                        if let hit = resolvedNonEmptyFile(fileURL) {
                            return hit.url
                        }
                    }
                }
            }
        }

        // 3. Check DeviceDeploymentService's deploy_cache (newest matching folder with valid romfs.img)
        let deployCacheDir = SystemDetector.shared.cachesDirectory.appendingPathComponent("deploy_cache", isDirectory: true)
        if let cacheEntries = try? fm.contentsOfDirectory(
            at: deployCacheDir,
            includingPropertiesForKeys: [.isDirectoryKey, .contentModificationDateKey]
        ) {
            var matchedCaches: [(url: URL, modDate: Date)] = []
            for entry in cacheEntries {
                let isDir = (try? entry.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) ?? false
                guard isDir, !entry.lastPathComponent.hasPrefix(".") else { continue }
                let romfsCandidate = entry.appendingPathComponent("romfs.img")
                guard let hit = resolvedNonEmptyFile(romfsCandidate) else { continue }

                var matches = false
                let infoPlist = entry.appendingPathComponent("Payload/DmIOS.app/Info.plist")
                if let data = try? Data(contentsOf: infoPlist),
                   let plist = try? PropertyListSerialization.propertyList(from: data, options: [], format: nil) as? [String: Any] {
                    let bid = (plist["CFBundleIdentifier"] as? String ?? "").uppercased()
                    let disp = normalizedRomfsTokens((plist["CFBundleDisplayName"] as? String) ?? (plist["CFBundleName"] as? String) ?? "")
                    if (!titleId.isEmpty && bid.contains(titleId))
                        || (!normalizedName.isEmpty && !disp.isEmpty && (disp == normalizedName || disp.contains(normalizedName) || normalizedName.contains(disp))) {
                        matches = true
                    }
                }
                if !matches {
                    let folderNorm = normalizedRomfsTokens(entry.lastPathComponent)
                    if (!titleId.isEmpty && entry.lastPathComponent.uppercased().contains(titleId))
                        || (normalizedName.count >= 4 && folderNorm.contains(normalizedName)) {
                        matches = true
                    }
                }
                if matches {
                    let mdate = (try? entry.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? Date.distantPast
                    matchedCaches.append((hit.url, mdate))
                }
            }
            if let newest = matchedCaches.sorted(by: { $0.modDate > $1.modDate }).first {
                return newest.url
            }
        }

        // 4. Check staging & Nintendo Games <TitleID>_build/extract/<ver>/RomFS.img (2 levels deep)
        var buildSearchRoots: [URL] = [SystemDetector.shared.stagingDirectory, parentDir]
        let nintendoBase = URL(fileURLWithPath: "/Volumes/Nintendo/Games")
        buildSearchRoots.append(nintendoBase)
        for root in [SystemDetector.shared.stagingDirectory, nintendoBase] {
            if let subs = try? fm.contentsOfDirectory(at: root, includingPropertiesForKeys: nil) {
                for sub in subs where !sub.lastPathComponent.hasPrefix(".") && !sub.lastPathComponent.hasSuffix("_build") {
                    buildSearchRoots.append(sub)
                    if let sub2 = try? fm.contentsOfDirectory(at: sub, includingPropertiesForKeys: nil) {
                        for deep in sub2 where !deep.lastPathComponent.hasPrefix(".") && !deep.lastPathComponent.hasSuffix("_build") {
                            buildSearchRoots.append(deep)
                        }
                    }
                }
            }
        }

        for folder in buildSearchRoots where !titleId.isEmpty {
            let buildRoot = folder.appendingPathComponent("\(titleId)_build")
            let extractDir = buildRoot.appendingPathComponent("extract")
            if let vers = try? fm.contentsOfDirectory(at: extractDir, includingPropertiesForKeys: nil) {
                for ver in vers where !ver.lastPathComponent.hasPrefix("._") {
                    if let hit = resolvedNonEmptyFile(ver.appendingPathComponent("RomFS.img")) { return hit.url }
                    if let hit = resolvedNonEmptyFile(ver.appendingPathComponent("romfs.img")) { return hit.url }
                }
            }
            if let hit = resolvedNonEmptyFile(buildRoot.appendingPathComponent("RomFS.img")) { return hit.url }
            if let hit = resolvedNonEmptyFile(buildRoot.appendingPathComponent("romfs.img")) { return hit.url }
        }

        return nil
    }

    private struct VerifiedRomfsSearchResult {
        let url: URL?
        let size: Int64
        let expectedIdentity: RomfsExpectedIdentity?
        let mismatchDiagnostic: String?
    }

    private func resolveAssociatedIpaURLs(for game: PortedGame, titleId: String) -> [URL] {
        var urls: [URL] = []
        if game.url.pathExtension.lowercased() == "ipa" {
            urls.append(game.url)
        }
        if let appVM = AppViewModel.shared {
            if let iosMatch = appVM.iosPort(for: game), iosMatch.url.pathExtension.lowercased() == "ipa" {
                urls.append(iosMatch.url)
            }
            for item in appVM.libraryGames where item.url.pathExtension.lowercased() == "ipa" {
                if !titleId.isEmpty, (item.titleId ?? "").caseInsensitiveCompare(titleId) == .orderedSame {
                    urls.append(item.url)
                }
            }
        }
        let deployable = DeviceDeploymentService.shared.resolveDeployableURL(for: game)
        if deployable.pathExtension.lowercased() == "ipa" {
            urls.append(deployable)
        }
        var seen = Set<String>()
        return urls.filter { seen.insert($0.standardizedFileURL.path).inserted }
    }

    private func sanitizedSearchTokens(_ text: String) -> String {
        let decomposed = text.precomposedStringWithCanonicalMapping
            .folding(options: [.diacriticInsensitive, .caseInsensitive], locale: .current)
        let scalars = decomposed.unicodeScalars.filter { CharacterSet.alphanumerics.contains($0) }
        return String(String.UnicodeScalarView(scalars))
    }

    /// Resolves the canonical `DMROMFSID1` identity that `NxN Launcher` (`DataLocator.isComplete`) requires.
    public func expectedRomfsIdentity(for game: PortedGame, allowIpaInspect: Bool = false) -> RomfsExpectedIdentity? {
        let tid = (game.titleId ?? "").uppercased()
        if !tid.isEmpty {
            let fwURL = hubFrameworksURL.appendingPathComponent("DmGame\(tid).framework")
            if let fwId = RomfsIdentityVerifier.readIdentity(fromFramework: fwURL) {
                return fwId
            }
        }
        if allowIpaInspect {
            for ipaURL in resolveAssociatedIpaURLs(for: game, titleId: tid) {
                if let ipaId = RomfsIdentityVerifier.readIdentity(fromIpa: ipaURL) {
                    return ipaId
                }
            }
        }
        return nil
    }

    /// Authoritative verified RomFS lookup prioritizing Staging/`_build` (newest patch first),
    /// exact `.romfs.img` sidecars, and exact current-IPA `deploy_cache`, strictly rejecting stale/truncated mismatches.
    private func searchVerifiedRomfsImage(
        for game: PortedGame,
        expectedIdentity: RomfsExpectedIdentity?,
        allowIpaInspect: Bool,
        allowUnpack: Bool
    ) -> VerifiedRomfsSearchResult {
        let fm = FileManager.default
        let tid = (game.titleId ?? "").uppercased()
        let effectiveExpected = expectedIdentity ?? expectedRomfsIdentity(for: game, allowIpaInspect: allowIpaInspect)
        let associatedIpas = resolveAssociatedIpaURLs(for: game, titleId: tid)

        var embeddedExpectedSize: Int64? = nil
        if effectiveExpected == nil && allowIpaInspect {
            for ipaURL in associatedIpas {
                if let emb = RomfsIdentityVerifier.readEmbeddedRomfsSize(inIpa: ipaURL) {
                    embeddedExpectedSize = emb
                    break
                }
            }
        }

        let parentDir = game.url.deletingLastPathComponent()
        let nxPortsDir = URL(fileURLWithPath: "/Volumes/SSD FN501 PRO/Emulations/Nx Ports")
        let nintendoBase = URL(fileURLWithPath: "/Volumes/Nintendo/Games")
        let deployCacheDir = SystemDetector.shared.cachesDirectory.appendingPathComponent("deploy_cache", isDirectory: true)

        var currentIpaCacheNames = Set<String>()
        var allGameCachePrefixes: [String] = []
        for nameVariant in RomfsIdentityVerifier.filenameVariants(of: game.name) {
            let p = nameVariant.replacingOccurrences(of: " ", with: "_") + "_"
            if p.count > 1 { allGameCachePrefixes.append(p) }
        }
        for ipaURL in associatedIpas {
            let rawStem = ipaURL.deletingPathExtension().lastPathComponent
            let vals = try? ipaURL.resourceValues(forKeys: [.fileSizeKey, .contentModificationDateKey])
            let sz = vals?.fileSize ?? 0
            let mtime = Int(vals?.contentModificationDate?.timeIntervalSince1970 ?? 0)
            for stemVar in RomfsIdentityVerifier.filenameVariants(of: rawStem) {
                let safe = stemVar.replacingOccurrences(of: " ", with: "_")
                if sz > 0 && mtime > 0 {
                    currentIpaCacheNames.insert("\(safe)_\(sz)_\(mtime)")
                }
                if !safe.isEmpty {
                    allGameCachePrefixes.append(safe + "_")
                }
            }
        }

        var orderedCandidates: [URL] = []
        var seenPaths = Set<String>()
        func addCandidate(_ url: URL) {
            let std = url.standardizedFileURL.path
            if seenPaths.insert(std).inserted {
                orderedCandidates.append(url)
            }
        }

        // Priority 1: Staging & _build/extract/<highest ver>/RomFS.img (canonical output of port build)
        var buildSearchRoots: [URL] = [SystemDetector.shared.stagingDirectory, parentDir, nintendoBase]
        for root in [SystemDetector.shared.stagingDirectory, nintendoBase] {
            if let subs = try? fm.contentsOfDirectory(at: root, includingPropertiesForKeys: nil) {
                for sub in subs where !sub.lastPathComponent.hasPrefix(".") && !sub.lastPathComponent.hasSuffix("_build") {
                    buildSearchRoots.append(sub)
                    if let sub2 = try? fm.contentsOfDirectory(at: sub, includingPropertiesForKeys: nil) {
                        for deep in sub2 where !deep.lastPathComponent.hasPrefix(".") && !deep.lastPathComponent.hasSuffix("_build") {
                            buildSearchRoots.append(deep)
                        }
                    }
                }
            }
        }

        if !tid.isEmpty {
            var rootSeen = Set<String>()
            for folder in buildSearchRoots where rootSeen.insert(folder.standardizedFileURL.path).inserted {
                let buildRoot = folder.appendingPathComponent("\(tid)_build")
                let extractDir = buildRoot.appendingPathComponent("extract")
                if let vers = try? fm.contentsOfDirectory(at: extractDir, includingPropertiesForKeys: [.contentModificationDateKey]) {
                    let sortedVers = vers
                        .filter { !$0.lastPathComponent.hasPrefix(".") && !$0.lastPathComponent.hasPrefix("._") }
                        .sorted {
                            let r0 = RomfsIdentityVerifier.parseBuildVersionRank($0.lastPathComponent)
                            let r1 = RomfsIdentityVerifier.parseBuildVersionRank($1.lastPathComponent)
                            if r0 != r1 { return r0 > r1 }
                            let d0 = (try? $0.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? .distantPast
                            let d1 = (try? $1.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? .distantPast
                            return d0 > d1
                        }
                    for ver in sortedVers {
                        addCandidate(ver.appendingPathComponent("RomFS.img"))
                        addCandidate(ver.appendingPathComponent("romfs.img"))
                    }
                }
                addCandidate(buildRoot.appendingPathComponent("RomFS.img"))
                addCandidate(buildRoot.appendingPathComponent("romfs.img"))
            }
        }

        // Priority 2: Exact sidecar .romfs.img next to IPA / in Nx Ports (including NFD/NFC variants)
        var nameStems: [String] = [game.name]
        for ipa in associatedIpas {
            nameStems.append(ipa.deletingPathExtension().lastPathComponent)
        }
        nameStems.append(game.url.deletingPathExtension().lastPathComponent)
        var sidecarDirs: [URL] = [parentDir]
        if nxPortsDir.standardizedFileURL.path != parentDir.standardizedFileURL.path {
            sidecarDirs.append(nxPortsDir)
        }
        for dir in sidecarDirs {
            for stem in nameStems {
                for variant in RomfsIdentityVerifier.filenameVariants(of: stem) {
                    addCandidate(dir.appendingPathComponent("\(variant).romfs.img"))
                    addCandidate(dir.appendingPathComponent("\(variant).RomFS.img"))
                }
            }
            if !tid.isEmpty {
                addCandidate(dir.appendingPathComponent("\(tid).romfs.img"))
                addCandidate(dir.appendingPathComponent("\(tid.lowercased()).romfs.img"))
                addCandidate(dir.appendingPathComponent("\(tid).RomFS.img"))
            }
        }
        // Only accept bare RomFS.img / romfs.img if parentDir holds at most one game package (never in shared Nx Ports!)
        let siblingGamesCount = (try? fm.contentsOfDirectory(at: parentDir, includingPropertiesForKeys: nil))?.filter {
            let ext = $0.pathExtension.lowercased()
            return ext == "ipa" || ext == "app"
        }.count ?? 0
        if siblingGamesCount <= 1 {
            addCandidate(parentDir.appendingPathComponent("RomFS.img"))
            addCandidate(parentDir.appendingPathComponent("romfs.img"))
        }

        // Priority 3: Exact current-IPA deploy_cache entries (matching current IPA <size>_<mtime>)
        if let cacheEntries = try? fm.contentsOfDirectory(at: deployCacheDir, includingPropertiesForKeys: [.contentModificationDateKey]) {
            let matchingCurrent = cacheEntries.filter { entry in
                let n = entry.lastPathComponent
                return currentIpaCacheNames.contains(n)
                    || currentIpaCacheNames.contains(n.precomposedStringWithCanonicalMapping)
                    || currentIpaCacheNames.contains(n.decomposedStringWithCanonicalMapping)
            }
            for entry in matchingCurrent {
                addCandidate(entry.appendingPathComponent("romfs.img"))
                addCandidate(entry.appendingPathComponent("RomFS.img"))
            }

            // Priority 4 & 5: Fuzzy sidecar .romfs.img + older deploy_cache entries (validated strictly against expected!)
            let normTarget = sanitizedSearchTokens(game.name)
            if normTarget.count >= 4 {
                for dir in sidecarDirs {
                    if let items = try? fm.contentsOfDirectory(at: dir, includingPropertiesForKeys: nil) {
                        for item in items where item.lastPathComponent.lowercased().hasSuffix(".romfs.img") {
                            let itemStem = String(item.lastPathComponent.dropLast(".romfs.img".count))
                            if sanitizedSearchTokens(itemStem).contains(normTarget) {
                                addCandidate(item)
                            }
                        }
                    }
                }
            }

            // Older deploy_cache entries sorted newest-first, ONLY valid when identity matches or no conflicting current-IPA cache
            let legacyCaches = cacheEntries
                .filter { entry in
                    let n = entry.lastPathComponent
                    guard !currentIpaCacheNames.contains(n) else { return false }
                    let forms = [n, n.precomposedStringWithCanonicalMapping, n.decomposedStringWithCanonicalMapping]
                    return allGameCachePrefixes.contains { pref in forms.contains { $0.hasPrefix(pref) } }
                }
                .sorted {
                    let d0 = (try? $0.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? .distantPast
                    let d1 = (try? $1.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? .distantPast
                    return d0 > d1
                }
            for entry in legacyCaches {
                // Never blindly fall back to an older deploy_cache entry unless we can verify identity or size!
                guard effectiveExpected != nil || embeddedExpectedSize != nil else { continue }
                addCandidate(entry.appendingPathComponent("romfs.img"))
                addCandidate(entry.appendingPathComponent("RomFS.img"))
            }
        } else {
            let normTarget = sanitizedSearchTokens(game.name)
            if normTarget.count >= 4 {
                for dir in sidecarDirs {
                    if let items = try? fm.contentsOfDirectory(at: dir, includingPropertiesForKeys: nil) {
                        for item in items where item.lastPathComponent.lowercased().hasSuffix(".romfs.img") {
                            let itemStem = String(item.lastPathComponent.dropLast(".romfs.img".count))
                            if sanitizedSearchTokens(itemStem).contains(normTarget) {
                                addCandidate(item)
                            }
                        }
                    }
                }
            }
        }

        var firstMismatch: String? = nil
        for candidate in orderedCandidates {
            let resolved = candidate.resolvingSymlinksInPath()
            guard fm.fileExists(atPath: resolved.path) else { continue }
            let check = RomfsIdentityVerifier.verifyLocalImage(at: resolved, expected: effectiveExpected)
            if !check.valid {
                if check.size > 0, firstMismatch == nil, let reason = check.reason {
                    firstMismatch = "\(candidate.lastPathComponent): \(reason)"
                }
                continue
            }
            if effectiveExpected == nil, let embSz = embeddedExpectedSize, embSz > 0, check.size != embSz {
                if firstMismatch == nil {
                    firstMismatch = "\(candidate.lastPathComponent): tamanho divergente do romfs embutido no .ipa (\(check.size) vs \(embSz) bytes)"
                }
                continue
            }
            return VerifiedRomfsSearchResult(url: resolved, size: check.size, expectedIdentity: effectiveExpected, mismatchDiagnostic: nil)
        }

        // Fallback Step 5 (only when allowUnpack == true): unpack embedded romfs.img directly from current IPA
        if allowUnpack {
            for ipaURL in associatedIpas {
                let extractedDest = parentDir.appendingPathComponent("\(game.name).romfs.img")
                let tempUnpackDir = fm.temporaryDirectory.appendingPathComponent("nx_romfs_unpack_\(UUID().uuidString)", isDirectory: true)
                try? fm.createDirectory(at: tempUnpackDir, withIntermediateDirectories: true)
                defer { try? fm.removeItem(at: tempUnpackDir) }

                let proc = Process()
                proc.executableURL = URL(fileURLWithPath: "/usr/bin/unzip")
                proc.arguments = ["-j", "-o", ipaURL.path, "Payload/*.app/romfs.img", "-d", tempUnpackDir.path]
                proc.standardOutput = Pipe()
                proc.standardError = Pipe()
                let watchdog = DispatchSource.makeTimerSource(queue: DispatchQueue.global())
                watchdog.schedule(deadline: .now() + 180.0)
                watchdog.setEventHandler { [weak proc] in
                    if let p = proc, p.isRunning { p.terminate() }
                }
                watchdog.resume()
                do {
                    try proc.run()
                    proc.waitUntilExit()
                } catch {
                    // ignore
                }
                watchdog.cancel()

                let unpacked = tempUnpackDir.appendingPathComponent("romfs.img")
                if fm.fileExists(atPath: unpacked.path) {
                    let check = RomfsIdentityVerifier.verifyLocalImage(at: unpacked, expected: effectiveExpected)
                    if check.valid {
                        try? fm.removeItem(at: extractedDest)
                        try? fm.moveItem(at: unpacked, to: extractedDest)
                        if let movedHit = resolvedNonEmptyFile(extractedDest) {
                            return VerifiedRomfsSearchResult(
                                url: movedHit.url,
                                size: movedHit.size,
                                expectedIdentity: effectiveExpected,
                                mismatchDiagnostic: nil
                            )
                        }
                    } else if firstMismatch == nil, let reason = check.reason {
                        firstMismatch = "romfs extraído do .ipa: \(reason)"
                    }
                }
            }
        }

        return VerifiedRomfsSearchResult(url: nil, size: 0, expectedIdentity: effectiveExpected, mismatchDiagnostic: firstMismatch)
    }

    public func hasExternalRomfsAsset(for game: PortedGame) -> Bool {
        searchVerifiedRomfsImage(for: game, expectedIdentity: nil, allowIpaInspect: false, allowUnpack: false).url != nil
    }

    public func estimatedTransferSizeBytes(for game: PortedGame) -> Int64 {
        if game.sizeBytes > 0 {
            return game.sizeBytes
        }
        let resolvedURL = game.url.resolvingSymlinksInPath()
        let baseFileSize = resolvedNonEmptyFile(resolvedURL)?.size ?? 0
        if let romfsURL = searchVerifiedRomfsImage(for: game, expectedIdentity: nil, allowIpaInspect: false, allowUnpack: false).url,
           let romfsHit = resolvedNonEmptyFile(romfsURL) {
            if romfsHit.url.standardizedFileURL.path.hasPrefix(resolvedURL.standardizedFileURL.path + "/") {
                return max(baseFileSize, romfsHit.size)
            }
            return baseFileSize + romfsHit.size
        }
        return baseFileSize
    }

    /// Locates the canonical, verified `romfs.img` for a ported Switch game matching `expectedIdentity`
    /// across Staging/`_build`, sidecars, `deploy_cache`, external storage, or inside an IPA bundle.
    public func locateRomfsImage(for game: PortedGame, expectedIdentity: RomfsExpectedIdentity? = nil) -> URL? {
        searchVerifiedRomfsImage(for: game, expectedIdentity: expectedIdentity, allowIpaInspect: true, allowUnpack: true).url
    }

    internal func executeHotDropTransfer(
        game: PortedGame,
        device: ConnectedAppleDevice,
        isBatchMode: Bool = false,
        batchProgressRange: ClosedRange<Double>? = nil,
        suppressFailureUI: Bool = false,
        completion: @escaping (Bool, String) -> Void
    ) {
        let fm = FileManager.default
        let titleId = (game.titleId ?? "0100000000000000").uppercased()
        let isExternal = self.useExternalStorage
        let hubBid = self.resolveHubBundleId(for: game, on: device)

        let mapProgress: (Double) -> Double = { localFraction in
            let clamped = max(0.0, min(1.0, localFraction))
            guard let range = batchProgressRange else { return clamped }
            return range.lowerBound + (range.upperBound - range.lowerBound) * clamped
        }

        let stageDir = fm.temporaryDirectory.appendingPathComponent("hub_stage_\(UUID().uuidString)", isDirectory: true)
        let completionLock = NSLock()
        var didComplete = false
        let finish: (Bool, String) -> Void = { success, message in
            try? fm.removeItem(at: stageDir)
            completionLock.lock()
            if didComplete {
                completionLock.unlock()
                return
            }
            didComplete = true
            completionLock.unlock()
            DispatchQueue.main.async {
                completion(success, message)
            }
        }

        let expectedIdentity = self.expectedRomfsIdentity(for: game, allowIpaInspect: true)
        let romfsSearch = self.searchVerifiedRomfsImage(
            for: game,
            expectedIdentity: expectedIdentity,
            allowIpaInspect: true,
            allowUnpack: true
        )
        let romfsURL = romfsSearch.url
        let romfsSize = romfsSearch.size

        // Clean up any stale/mismatched deploy_cache folders for this game so old versions cannot linger on disk
        if !isExternal, let validRomfsURL = romfsURL, romfsSize > 0 {
            let deployCacheDir = SystemDetector.shared.cachesDirectory.appendingPathComponent("deploy_cache", isDirectory: true)
            let gamePrefixes = RomfsIdentityVerifier.filenameVariants(of: game.name)
                .map { $0.replacingOccurrences(of: " ", with: "_") + "_" }
            if let entries = try? fm.contentsOfDirectory(at: deployCacheDir, includingPropertiesForKeys: nil) {
                for entry in entries {
                    let entryName = entry.lastPathComponent
                    let entryForms = [entryName, entryName.precomposedStringWithCanonicalMapping, entryName.decomposedStringWithCanonicalMapping]
                    guard gamePrefixes.contains(where: { p in entryForms.contains(where: { $0.hasPrefix(p) }) }) else { continue }
                    let cachedImg = entry.appendingPathComponent("romfs.img")
                    if fm.fileExists(atPath: cachedImg.path),
                       cachedImg.standardizedFileURL.path != validRomfsURL.standardizedFileURL.path,
                       !RomfsIdentityVerifier.verifyLocalImage(at: cachedImg, expected: expectedIdentity).valid {
                        try? fm.removeItem(at: entry)
                    }
                }
            }
        }

        if !isExternal && (romfsURL == nil || romfsSize <= 0) {
            let parentDir = game.url.deletingLastPathComponent()
            let siblingSym = parentDir.appendingPathComponent("\(game.name).romfs.img")
            var symlinkHint = ""
            if let target = try? fm.destinationOfSymbolicLink(atPath: siblingSym.path),
               !fm.fileExists(atPath: target) {
                symlinkHint = " O atalho aponta para '\(target)', que não está acessível (verifique se o disco externo está conectado)."
            }
            let mismatchHint = romfsSearch.mismatchDiagnostic.map {
                " Arquivo incompatível encontrado: \($0). Remova o cache/IPA antigo ou gere um novo port."
            } ?? ""
            let errMsg = "Imagem romfs.img compatível não encontrada para \(game.name) (\(titleId)).\(symlinkHint)\(mismatchHint)"
            DispatchQueue.main.async {
                DeviceDeploymentService.shared.activeDeployment.detailMessage = errMsg
                DeviceDeploymentService.shared.activeDeployment.logLines.append("[ERROR] \(errMsg)")
                if !isBatchMode && !suppressFailureUI {
                    self.isHotDropping = false
                    DeviceDeploymentService.shared.failDeployment(
                        category: .generic(errMsg),
                        title: "RomFS Incompatível ou Não Encontrado",
                        detail: errMsg
                    )
                }
            }
            finish(false, errMsg)
            return
        }

        if let validRomfs = romfsURL, romfsSize > 0 {
            let humanRomfs = ByteCountFormatter.string(fromByteCount: romfsSize, countStyle: .file)
            DispatchQueue.main.async {
                DeviceDeploymentService.shared.activeDeployment.logLines.append(
                    "[OK] RomFS verificado (\(validRomfs.lastPathComponent), \(humanRomfs)) compatível com \(game.name)."
                )
            }
        }

        let hasSave = SaveSyncService.shared.locateExistingSave(titleId: titleId, gameName: game.name) != nil

        DispatchQueue.main.async {
            let mapped = mapProgress(0.35)
            self.hotDropProgress = mapped
            self.currentActionMessage = "Staging game folder for NxN Launcher..."
            DeviceDeploymentService.shared.activeDeployment.phase = .transferring
            DeviceDeploymentService.shared.activeDeployment.progressFraction = mapped
            if !isBatchMode {
                DeviceDeploymentService.shared.activeDeployment.statusMessage = "Preparando pasta no NxN Launcher..."
            }
            DeviceDeploymentService.shared.activeDeployment.detailMessage = "Enviando manifesto e saves de \(game.name)..."
            DeviceDeploymentService.shared.activeDeployment.logLines.append("==> Preparando estrutura de pasta para \(game.name)...")
        }

        let gamesFolder = stageDir.appendingPathComponent("games", isDirectory: true)
        let thisGameFolder = gamesFolder.appendingPathComponent(titleId, isDirectory: true)
        try? fm.createDirectory(at: thisGameFolder, withIntermediateDirectories: true)

        let effectiveDisplayVersion = expectedIdentity?.displayVersion?.isEmpty == false
            ? expectedIdentity!.displayVersion!
            : (game.versionString ?? "1.0.0")
        let manifest = NxHubGameItem(
            titleId: titleId,
            name: game.name,
            displayVersion: effectiveDisplayVersion,
            romfsSize: expectedIdentity?.expectedSize ?? romfsSize,
            hasPatch: false,
            hasDLC: false,
            isSwitch2: game.name.contains("Switch 2") || game.name.contains("NUP"),
            storageLocation: isExternal ? .externalDrive(bookmarkData: Data(), pathDisplay: "SSD USB-C") : .internalContainer,
            launchSettings: NxHubGameSettings(),
            hasSave: hasSave
        )

        let manifestFile = thisGameFolder.appendingPathComponent("manifest.json")
        if let data = try? JSONEncoder().encode(manifest) {
            try? data.write(to: manifestFile)
        }

        // Write per-game iOS runtime configuration (OoT presets, FPS, FrameGen, Upscaler, Language)
        let syncToken = String(Int64(Date().timeIntervalSince1970 * 1000))
        let runtimeConfig = GameRuntimeConfig.load(for: game)
        let stagedEnvURL = thisGameFolder.appendingPathComponent("env.txt")
        let envText = runtimeConfig.iosEnvFileContent(for: game, syncToken: syncToken)
        try? envText.write(to: stagedEnvURL, atomically: true, encoding: .utf8)

        // Copy existing save into staged folder if found
        var didStageSaveInFolder = false
        if let saveSource = SaveSyncService.shared.locateExistingSave(titleId: titleId, gameName: game.name) {
            let stagedGameSave = thisGameFolder.appendingPathComponent("save", isDirectory: true)
            var isDir: ObjCBool = false
            if fm.fileExists(atPath: saveSource.path, isDirectory: &isDir), isDir.boolValue {
                try? fm.copyItem(at: saveSource, to: stagedGameSave)
                didStageSaveInFolder = true
            } else if saveSource.lastPathComponent.hasSuffix(".dmsync") {
                SaveSyncService.shared.unpackDMSync(at: saveSource, into: stagedGameSave)
                try? fm.copyItem(at: saveSource, to: thisGameFolder.appendingPathComponent("save.dmsync"))
                didStageSaveInFolder = true
            }
            let parentDmsync = saveSource.deletingLastPathComponent().appendingPathComponent("save.dmsync")
            let targetDmsync = thisGameFolder.appendingPathComponent("save.dmsync")
            if fm.fileExists(atPath: parentDmsync.path), !fm.fileExists(atPath: targetDmsync.path) {
                try? fm.copyItem(at: parentDmsync, to: targetDmsync)
            }
        }

        // 1. Copy staged games folder to Documents (USB AFC first when available, creates Documents/games/<TitleId>)
        let stagedSaveURL = thisGameFolder.appendingPathComponent("save", isDirectory: true)
        self.copyFileToHub(
            sourceURL: stageDir,
            destinationSubpath: "Documents",
            device: device,
            game: game
        ) { [weak self] folderSuccess, folderErr in
            guard let self = self else {
                finish(false, "Serviço encerrado durante envio da pasta.")
                return
            }

            let continueAfterManifest: () -> Void = { [weak self] in
                guard let self = self else {
                    finish(false, "Serviço encerrado.")
                    return
                }
                DispatchQueue.main.async {
                    DeviceDeploymentService.shared.activeDeployment.logLines.append("[OK] Estrutura Documents/games/\(titleId) criada com sucesso.")
                }

                if isExternal {
                    DispatchQueue.main.async {
                        let mappedDone = mapProgress(1.0)
                        self.hotDropProgress = mappedDone
                        DeviceDeploymentService.shared.activeDeployment.progressFraction = mappedDone
                        DeviceDeploymentService.shared.activeDeployment.detailMessage = "\(game.name) configurado para rodar direto do SSD USB-C no \(device.name)."
                        DeviceDeploymentService.shared.activeDeployment.logLines.append("[SUCCESS] \(game.name) pronto para inicialização via SSD externo!")
                        if !isBatchMode {
                            self.isHotDropping = false
                            DeviceDeploymentService.shared.stopElapsedTimer()
                            DeviceDeploymentService.shared.activeDeployment.isRunning = false
                            DeviceDeploymentService.shared.activeDeployment.phase = .completed
                            DeviceDeploymentService.shared.activeDeployment.statusMessage = "Pronto no NxN Launcher via SSD!"
                            SoundEffectService.shared.play(.click)
                        }
                    }
                    finish(true, "Configured \(game.name) for external SSD play on \(device.name).")
                    return
                }

                guard let romfs = romfsURL, romfsSize > 0 else {
                    let errMsg = "Imagem romfs.img inválida para \(game.name)."
                    DispatchQueue.main.async {
                        DeviceDeploymentService.shared.activeDeployment.detailMessage = errMsg
                        DeviceDeploymentService.shared.activeDeployment.logLines.append("[ERROR] \(errMsg)")
                        if !isBatchMode && !suppressFailureUI {
                            self.isHotDropping = false
                        }
                    }
                    finish(false, errMsg)
                    return
                }

                let humanSize = ByteCountFormatter.string(fromByteCount: romfsSize, countStyle: .file)

                // Check if exact-byte romfs.img already exists in container after folder staging
                DispatchQueue.global(qos: .userInitiated).async { [weak self] in
                    guard let self = self else {
                        finish(false, "Serviço encerrado.")
                        return
                    }

                    // Clean up any abandoned .part upload before inspecting or streaming.
                    AppleAfcTransferService.removeContainerFileIfPresent(
                        bundleId: hubBid,
                        subpath: "Documents/games/\(titleId)/romfs.img.part",
                        device: device
                    )

                    let existingRemoteSize = self.checkHubContainerFileSize(
                        bundleId: hubBid,
                        subdirectory: "Documents/games/\(titleId)",
                        searchName: "romfs.img",
                        device: device
                    )

                    let targetExpectedBytes = expectedIdentity?.expectedSize ?? romfsSize
                    let finishTransferSuccess: () -> Void = {
                        // Independent final container contract check: confirm BOTH romfs.img exact byte size
                        // (matching NxN Launcher DataLocator.isComplete) and manifest.json exist on the device
                        // BEFORE claiming success.
                        let verifiedRemoteRomfs = self.checkHubContainerFileSize(
                            bundleId: hubBid,
                            subdirectory: "Documents/games/\(titleId)",
                            searchName: "romfs.img",
                            device: device
                        )
                        guard verifiedRemoteRomfs == targetExpectedBytes else {
                            let gotDesc = verifiedRemoteRomfs.map { "\($0) bytes" } ?? "ausente"
                            let errMsg = "Verificação final no iPhone falhou para \(game.name): Documents/games/\(titleId)/romfs.img tem \(gotDesc), mas o NxN Launcher exige \(targetExpectedBytes) bytes."
                            AppleAfcTransferService.removeContainerFileIfPresent(
                                bundleId: hubBid,
                                subpath: "Documents/games/\(titleId)/romfs.img",
                                device: device
                            )
                            DispatchQueue.main.async {
                                DeviceDeploymentService.shared.activeDeployment.detailMessage = errMsg
                                DeviceDeploymentService.shared.activeDeployment.logLines.append("[ERROR] \(errMsg)")
                                if !isBatchMode && !suppressFailureUI {
                                    self.isHotDropping = false
                                    DeviceDeploymentService.shared.failDeployment(
                                        category: .generic("RomFS Verification Failed"),
                                        title: "Falha na Verificação Final do RomFS",
                                        detail: errMsg
                                    )
                                }
                            }
                            finish(false, errMsg)
                            return
                        }

                        var verifiedManifest = self.checkHubContainerFileSize(
                            bundleId: hubBid,
                            subdirectory: "Documents/games/\(titleId)",
                            searchName: "manifest.json",
                            device: device
                        )
                        if (verifiedManifest ?? 0) <= 0 {
                            let manSema = DispatchSemaphore(value: 0)
                            self.copyFileToHub(
                                sourceURL: manifestFile,
                                destinationSubpath: "Documents/games/\(titleId)/manifest.json",
                                device: device,
                                game: game
                            ) { _, _ in
                                manSema.signal()
                            }
                            _ = manSema.wait(timeout: .now() + 25.0)
                            verifiedManifest = self.checkHubContainerFileSize(
                                bundleId: hubBid,
                                subdirectory: "Documents/games/\(titleId)",
                                searchName: "manifest.json",
                                device: device
                            )
                        }

                        let completeUI: (Bool) -> Void = { saveRestored in
                            DispatchQueue.main.async {
                                let mappedDone = mapProgress(1.0)
                                self.hotDropProgress = mappedDone
                                DeviceDeploymentService.shared.activeDeployment.progressFraction = mappedDone
                                DeviceDeploymentService.shared.activeDeployment.detailMessage = "\(game.name) foi adicionado e verificado no NxN Launcher (\(humanSize)) em \(device.name)."
                                DeviceDeploymentService.shared.activeDeployment.logLines.append("[SUCCESS] \(game.name) verificado no container (\(verifiedRemoteRomfs ?? targetExpectedBytes) bytes) e pronto no NxN Launcher!")
                                if saveRestored {
                                    DeviceDeploymentService.shared.activeDeployment.logLines.append("[OK] Save do iCloud sincronizado com o dispositivo.")
                                }
                                if !isBatchMode {
                                    self.isHotDropping = false
                                    DeviceDeploymentService.shared.stopElapsedTimer()
                                    self.currentActionMessage = "Game ready in NxN Launcher!"
                                    DeviceDeploymentService.shared.activeDeployment.isRunning = false
                                    DeviceDeploymentService.shared.activeDeployment.phase = .completed
                                    DeviceDeploymentService.shared.activeDeployment.statusMessage = "Jogo pronto no NxN Launcher!"
                                    SoundEffectService.shared.play(.click)
                                }
                            }
                            finish(true, "Successfully added \(game.name) to NxN Launcher on \(device.name)!")
                        }

                        if didStageSaveInFolder {
                            completeUI(true)
                            return
                        }

                        SaveSyncService.shared.restoreICloudSaveToDevice(
                            titleId: titleId,
                            gameName: game.name,
                            bundleId: hubBid,
                            device: device
                        ) { saveOk, _ in
                            completeUI(saveOk)
                        }
                    }

                    if let existing = existingRemoteSize, existing == targetExpectedBytes {
                        DispatchQueue.main.async {
                            DeviceDeploymentService.shared.activeDeployment.logLines.append(
                                "[OK] romfs.img já verificado no dispositivo (\(humanSize)); pulando re-envio."
                            )
                        }
                        finishTransferSuccess()
                        return
                    }

                    if let existing = existingRemoteSize, existing != targetExpectedBytes {
                        DispatchQueue.main.async {
                            DeviceDeploymentService.shared.activeDeployment.logLines.append(
                                "[WARN] romfs.img parcial/divergente detectado no iPhone (\(existing) bytes vs \(targetExpectedBytes)); removendo antes de reenviar..."
                            )
                        }
                        AppleAfcTransferService.removeContainerFileIfPresent(
                            bundleId: hubBid,
                            subpath: "Documents/games/\(titleId)/romfs.img",
                            device: device
                        )
                    }

                    DispatchQueue.main.async {
                        let mappedStart = mapProgress(0.55)
                        self.hotDropProgress = mappedStart
                        self.currentActionMessage = "Transferring game data (romfs.img) to NxN Launcher..."
                        DeviceDeploymentService.shared.activeDeployment.phase = .copyingRomFS
                        DeviceDeploymentService.shared.activeDeployment.progressFraction = mappedStart
                        if !isBatchMode {
                            DeviceDeploymentService.shared.activeDeployment.statusMessage = "Transferindo RomFS (\(humanSize)) para o NxN Launcher..."
                        }
                        DeviceDeploymentService.shared.activeDeployment.detailMessage = "Iniciando envio de romfs.img (\(humanSize))..."
                        DeviceDeploymentService.shared.activeDeployment.logLines.append("==> Transferindo RomFS (\(romfs.lastPathComponent), \(humanSize))...")
                    }

                    self.copyFileToHub(
                        sourceURL: romfs,
                        destinationSubpath: "Documents/games/\(titleId)/romfs.img",
                        device: device,
                        game: game,
                        onProgress: { pct, speed in
                            let scaled = mapProgress(min(0.98, 0.55 + (0.43 * pct)))
                            self.hotDropProgress = scaled
                            DeviceDeploymentService.shared.activeDeployment.progressFraction = scaled
                            if !speed.isEmpty {
                                DeviceDeploymentService.shared.activeDeployment.detailMessage = "USB streaming: \(Int(pct * 100))% (\(speed)) — \(humanSize)"
                            } else {
                                DeviceDeploymentService.shared.activeDeployment.detailMessage = "USB streaming: \(Int(pct * 100))% — \(humanSize)"
                            }
                        }
                    ) { romfsSuccess, transferErr in
                        guard romfsSuccess else {
                            let detailMsg = transferErr ?? "Houve um erro ao transferir romfs.img para a pasta do jogo no Hub."
                            DispatchQueue.main.async {
                                DeviceDeploymentService.shared.activeDeployment.detailMessage = detailMsg
                                DeviceDeploymentService.shared.activeDeployment.logLines.append("[ERROR] \(detailMsg)")
                                if !isBatchMode && !suppressFailureUI {
                                    self.isHotDropping = false
                                    DeviceDeploymentService.shared.failDeployment(
                                        category: .generic("RomFS Transfer Failed"),
                                        title: "Falha ao Copiar RomFS",
                                        detail: detailMsg
                                    )
                                }
                            }
                            finish(false, detailMsg)
                            return
                        }
                        finishTransferSuccess()
                    }
                }
            }

            if folderSuccess {
                continueAfterManifest()
                return
            }

            // Self-heal fallback: attempt direct single-file manifest.json upload (and save folder if staged)
            // in case bulk directory copy failed on container mount lag or AFC directory creation glitch.
            DispatchQueue.main.async {
                DeviceDeploymentService.shared.activeDeployment.detailMessage = "Recuperando envio do manifesto para \(game.name)..."
                DeviceDeploymentService.shared.activeDeployment.logLines.append(
                    "[WARN] Cópia de pasta staging falhou (\(folderErr ?? "erro")); tentando envio direto de manifest.json..."
                )
            }
            AppleAfcTransferService.invalidateUDIDCache(for: device.id)
            self.copyFileToHub(
                sourceURL: manifestFile,
                destinationSubpath: "Documents/games/\(titleId)/manifest.json",
                device: device,
                game: game
            ) { manifestOk, manifestErr in
                guard manifestOk else {
                    let errDetail = manifestErr ?? folderErr ?? "Não foi possível criar a pasta do jogo no container do NxN Launcher."
                    DispatchQueue.main.async {
                        DeviceDeploymentService.shared.activeDeployment.detailMessage = errDetail
                        DeviceDeploymentService.shared.activeDeployment.logLines.append("[ERROR] \(errDetail)")
                        if !isBatchMode && !suppressFailureUI {
                            self.isHotDropping = false
                            DeviceDeploymentService.shared.failDeployment(
                                category: .generic("Folder Creation Failed"),
                                title: "Falha na Criação da Pasta",
                                detail: errDetail
                            )
                        }
                    }
                    finish(false, errDetail)
                    return
                }
                let finishAfterOptionalSave: () -> Void = {
                    if fm.fileExists(atPath: stagedSaveURL.path) {
                        self.copyFileToHub(
                            sourceURL: stagedSaveURL,
                            destinationSubpath: "Documents/games/\(titleId)/save",
                            device: device,
                            game: nil
                        ) { _, _ in
                            continueAfterManifest()
                        }
                    } else {
                        continueAfterManifest()
                    }
                }
                if fm.fileExists(atPath: stagedEnvURL.path) {
                    self.copyFileToHub(
                        sourceURL: stagedEnvURL,
                        destinationSubpath: "Documents/games/\(titleId)/env.txt",
                        device: device,
                        game: nil
                    ) { _, _ in
                        finishAfterOptionalSave()
                    }
                } else {
                    finishAfterOptionalSave()
                }
            }
        }
    }

    internal func checkHubContainerFileSize(
        bundleId: String,
        subdirectory: String,
        searchName: String,
        device: ConnectedAppleDevice
    ) -> Int64? {
        AppleAfcTransferService.checkContainerFileSize(
            bundleId: bundleId,
            subdirectory: subdirectory,
            searchName: searchName,
            device: device
        )
    }

    internal func copyFileToHub(
        sourceURL: URL,
        destinationSubpath: String,
        device: ConnectedAppleDevice,
        game: PortedGame? = nil,
        onProgress: ((Double, String) -> Void)? = nil,
        completion: @escaping (Bool, String?) -> Void
    ) {
        let domainId: String
        if let detected = self.detectedHubBundleId, !detected.isEmpty {
            domainId = detected
        } else if let g = game {
            domainId = self.resolveHubBundleId(for: g, on: device)
        } else {
            domainId = Self.hubBundleId
        }

        let fm = FileManager.default
        let resolvedSource = sourceURL.resolvingSymlinksInPath()
        var isDir: ObjCBool = false
        guard fm.fileExists(atPath: resolvedSource.path, isDirectory: &isDir) else {
            DispatchQueue.main.async {
                completion(false, "Arquivo de origem ausente: \(resolvedSource.path)")
            }
            return
        }

        let isDirectory = isDir.boolValue
        let expectedSize: Int64 = isDirectory
            ? 0
            : ((try? fm.attributesOfItem(atPath: resolvedSource.path)[.size] as? Int64) ?? 0)
        if !isDirectory && expectedSize <= 0 {
            DispatchQueue.main.async {
                completion(false, "Arquivo de origem vazio (0 bytes): \(resolvedSource.lastPathComponent)")
            }
            return
        }

        DispatchQueue.global(qos: .userInitiated).async {
            let afcPath = AppleAfcTransferService.resolveAfcClientTool()
            if let afc = afcPath, let udid = AppleAfcTransferService.resolveHardwareUDID(for: device) {
                if isDirectory {
                    let dirOk = AppleAfcTransferService.transferDirectoryViaAfcClient(
                        afcPath: afc,
                        udid: udid,
                        domainId: domainId,
                        localDirectoryURL: resolvedSource,
                        destinationSubpath: destinationSubpath,
                        onLog: { line in
                            DispatchQueue.main.async {
                                DeviceDeploymentService.shared.activeDeployment.logLines.append(line)
                            }
                        }
                    )
                    if dirOk {
                        if let g = game, let tid = g.titleId?.uppercased(), !tid.isEmpty {
                            let mSize = self.checkHubContainerFileSize(
                                bundleId: domainId,
                                subdirectory: "Documents/games/\(tid)",
                                searchName: "manifest.json",
                                device: device
                            )
                            if let ms = mSize, ms > 0 {
                                DispatchQueue.main.async { completion(true, nil) }
                                return
                            }
                        } else {
                            DispatchQueue.main.async { completion(true, nil) }
                            return
                        }
                    }
                    DispatchQueue.main.async {
                        DeviceDeploymentService.shared.activeDeployment.logLines.append(
                            "[WARN] afcclient directory transfer incomplete; trying devicectl..."
                        )
                    }
                } else {
                    if AppleAfcTransferService.transferFileViaAfcClient(
                        afcPath: afc,
                        udid: udid,
                        domainId: domainId,
                        resolvedSourceURL: resolvedSource,
                        destinationSubpath: destinationSubpath,
                        expectedSize: expectedSize,
                        device: device,
                        onProcessChanged: { proc in
                            DispatchQueue.main.async {
                                DeviceDeploymentService.shared.currentRunningProcess = proc
                            }
                        },
                        onProgress: onProgress,
                        onLog: { line in
                            DispatchQueue.main.async {
                                DeviceDeploymentService.shared.activeDeployment.logLines.append(line)
                            }
                        }
                    ) {
                        DispatchQueue.main.async { completion(true, nil) }
                        return
                    }
                    DispatchQueue.main.async {
                        DeviceDeploymentService.shared.activeDeployment.logLines.append(
                            "[WARN] afcclient falhou ou não concluiu; tentando via devicectl..."
                        )
                    }
                }
            }

            let timeoutSeconds = max(180.0, (Double(expectedSize) / (15.0 * 1024.0 * 1024.0)) + 120.0)
            let destNS = destinationSubpath as NSString
            let verifySubdir = destNS.deletingLastPathComponent
            let verifyName = destNS.lastPathComponent

            var lastObservedSize: Int64? = nil
            var lastCmdError: String = ""

            for attempt in 1...2 {
                let res = BoundedProcess.run(
                    "/usr/bin/xcrun",
                    [
                        "devicectl", "device", "copy", "to",
                        "--device", device.id,
                        "--domain-type", "appDataContainer",
                        "--domain-identifier", domainId,
                        "--source", resolvedSource.path,
                        "--destination", destinationSubpath,
                        "-q"
                    ],
                    timeout: timeoutSeconds
                )

                if res.success {
                    if isDirectory {
                        // Verify staged game manifest landed when copying stageDir -> Documents
                        if let g = game, let tid = g.titleId?.uppercased(), !tid.isEmpty {
                            let mSize = self.checkHubContainerFileSize(
                                bundleId: domainId,
                                subdirectory: "Documents/games/\(tid)",
                                searchName: "manifest.json",
                                device: device
                            )
                            if let ms = mSize, ms > 0 {
                                DispatchQueue.main.async { completion(true, nil) }
                                return
                            }
                            lastCmdError = "manifest.json não encontrado no container após cópia."
                        } else {
                            DispatchQueue.main.async { completion(true, nil) }
                            return
                        }
                    } else {
                        let verifiedSize = self.checkHubContainerFileSize(
                            bundleId: domainId,
                            subdirectory: verifySubdir,
                            searchName: verifyName,
                            device: device
                        )
                        lastObservedSize = verifiedSize
                        if let vs = verifiedSize, vs == expectedSize {
                            DispatchQueue.main.async { completion(true, nil) }
                            return
                        }
                        lastCmdError = "Tamanho no iPhone divergente (\(verifiedSize.map(String.init) ?? "ausente") bytes vs esperado \(expectedSize) bytes)."
                    }
                } else {
                    lastCmdError = res.output.trimmingCharacters(in: .whitespacesAndNewlines)
                    if !isDirectory {
                        lastObservedSize = self.checkHubContainerFileSize(
                            bundleId: domainId,
                            subdirectory: verifySubdir,
                            searchName: verifyName,
                            device: device
                        )
                        if let vs = lastObservedSize, vs == expectedSize {
                            DispatchQueue.main.async { completion(true, nil) }
                            return
                        }
                    }
                }

                if attempt == 1 {
                    DispatchQueue.main.async {
                        DeviceDeploymentService.shared.activeDeployment.logLines.append(
                            "[WARN] Verificação pós-transferência falhou (\(lastCmdError)); limpando resíduo e tentando novamente..."
                        )
                    }
                    if !isDirectory {
                        AppleAfcTransferService.removeContainerFileIfPresent(
                            bundleId: domainId,
                            subpath: destinationSubpath,
                            device: device
                        )
                    }
                    AppleAfcTransferService.invalidateUDIDCache(for: device.id)
                    usleep(800_000)
                }
            }

            var finalMsg = "Falha ao transferir \(verifyName) para \(device.name): \(lastCmdError)"
            if !isDirectory && expectedSize >= 3_500_000_000 && afcPath == nil {
                finalMsg += " Dica: arquivos >= 4 GB podem chegar com 0 bytes via devicectl em Macs de 16 GB; instale 'brew install libimobiledevice' para transferência streaming USB via afcclient."
            } else if let obs = lastObservedSize, obs == 0 {
                finalMsg += " O arquivo ficou corrompido com 0 bytes no dispositivo."
            }
            DispatchQueue.main.async { completion(false, finalMsg) }
        }
    }
}
