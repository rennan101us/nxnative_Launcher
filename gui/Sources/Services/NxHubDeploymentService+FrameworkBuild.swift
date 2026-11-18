import Foundation
import AppKit

// MARK: - On-The-Fly Framework Building & Validation for NxN Launcher

extension NxHubDeploymentService {
    /// Normalizes a game title or filename for accent- and punctuation-insensitive matching.
    private func normalizedSearchTokens(_ value: String) -> String {
        let folded = value.folding(options: [.diacriticInsensitive, .caseInsensitive], locale: Locale(identifier: "en_US_POSIX"))
        let cleaned = folded.unicodeScalars.map { scalar -> Character in
            if CharacterSet.alphanumerics.contains(scalar) {
                return Character(scalar)
            }
            return " "
        }
        return String(cleaned)
            .split(whereSeparator: { $0.isWhitespace })
            .joined(separator: " ")
    }

    /// Reads the expected NVN shader translation chain hash from `dm/gfx/nvn/dmsh_chain.h`.
    public func expectedShaderChain() -> String? {
        let headerURL = URL(fileURLWithPath: BundledTools.nxnativeRootPath)
            .appendingPathComponent("dm/gfx/nvn/dmsh_chain.h")
        guard let content = try? String(contentsOf: headerURL, encoding: .utf8) else {
            return nil
        }
        for line in content.split(whereSeparator: \.isNewline) {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            guard trimmed.hasPrefix("#define DMSH_CHAIN ") else { continue }
            if let firstQuote = trimmed.firstIndex(of: "\""),
               let lastQuote = trimmed.lastIndex(of: "\""),
               firstQuote < lastQuote {
                let start = trimmed.index(after: firstQuote)
                let chain = String(trimmed[start..<lastQuote]).trimmingCharacters(in: .whitespacesAndNewlines)
                if !chain.isEmpty {
                    return chain
                }
            }
        }
        return nil
    }

    /// Resolves required modules for a game build by matching `dm/main.fixups.tsv`'s `BUILD_ID`
    /// against `dm/games/<TitleID>/game.tsv` and intersecting with its `modules` load-order row
    /// (mirroring `game.py :: build_modules()`), falling back safely for unrecorded/derived builds.
    private func expectedFrameworkModules(
        for titleId: String,
        manifestModules: [String],
        packageVersion: String?,
        frameworkURL: URL
    ) -> [String] {
        let upperTID = titleId.uppercased()
        let fixupsURL = frameworkURL.appendingPathComponent("dm/main.fixups.tsv")
        var mainBuildId: String? = nil
        if let fixupsText = try? String(contentsOf: fixupsURL, encoding: .utf8) {
            for rawLine in fixupsText.split(whereSeparator: \.isNewline) {
                let line = String(rawLine)
                if !line.hasPrefix("#") { break }
                let cols = line.split(separator: "\t").map { String($0).trimmingCharacters(in: .whitespaces) }
                if cols.count >= 2 && cols[0] == "# BUILD_ID" {
                    mainBuildId = cols[1].lowercased()
                    break
                }
            }
        }

        let profileURL = URL(fileURLWithPath: BundledTools.nxnativeRootPath)
            .appendingPathComponent("dm/games/\(upperTID)/game.tsv")
        guard let profileText = try? String(contentsOf: profileURL, encoding: .utf8) else {
            return manifestModules.isEmpty ? ["main", "sdk"] : manifestModules
        }

        var fallbackModules: [String] = []
        var allBuildModuleSets: [Set<String>] = []
        var matchedBuildModules: [String]? = nil

        for rawLine in profileText.split(whereSeparator: \.isNewline) {
            let line = String(rawLine).trimmingCharacters(in: .whitespacesAndNewlines)
            if line.isEmpty || line.hasPrefix("#") { continue }
            let cols = line.split(separator: "\t").map(String.init)
            guard !cols.isEmpty else { continue }

            if cols[0] == "modules", cols.count >= 2 {
                fallbackModules = cols[1].split(whereSeparator: \.isWhitespace).map(String.init)
            } else if cols[0] == "build", cols.count >= 4 {
                let pkgVer = cols[1]
                var buildMods: [String] = []
                var rowMainBid: String? = nil
                for token in cols.dropFirst(3) {
                    if let eq = token.firstIndex(of: "=") {
                        let modName = String(token[..<eq])
                        let bid = String(token[token.index(after: eq)...]).lowercased()
                        if !modName.isEmpty {
                            buildMods.append(modName)
                        }
                        if modName == "main" {
                            rowMainBid = bid
                        }
                    }
                }
                if !buildMods.isEmpty {
                    allBuildModuleSets.append(Set(buildMods))
                    if let mainBid = mainBuildId, rowMainBid == mainBid {
                        matchedBuildModules = buildMods
                    } else if mainBuildId == nil, let pkg = packageVersion, !pkg.isEmpty, pkgVer == pkg {
                        matchedBuildModules = buildMods
                    }
                }
            }
        }

        if let matched = matchedBuildModules, !matched.isEmpty {
            if !fallbackModules.isEmpty {
                let matchedSet = Set(matched)
                let filtered = fallbackModules.filter { matchedSet.contains($0) }
                if !filtered.isEmpty {
                    return filtered
                }
            }
            return matched
        }
        if !fallbackModules.isEmpty {
            if let firstSet = allBuildModuleSets.first {
                let commonBuildMods = allBuildModuleSets.dropFirst().reduce(firstSet) { $0.intersection($1) }
                let allowedMods = commonBuildMods.union(Set(manifestModules))
                let filtered = fallbackModules.filter { allowedMods.contains($0) }
                if !filtered.isEmpty {
                    return filtered
                }
            }
            return fallbackModules
        }
        return ["main", "sdk"]
    }

    /// Strips exFAT AppleDouble (`._*`) / `.DS_Store` files, empty shadowed shader dirs, and extended attributes.
    public func sanitizeFrameworkArtifacts(at fwURL: URL) {
        let fm = FileManager.default
        guard fm.fileExists(atPath: fwURL.path) else { return }

        if let enumerator = fm.enumerator(
            at: fwURL,
            includingPropertiesForKeys: [.isDirectoryKey],
            options: [.skipsPackageDescendants]
        ) {
            var toDelete: [URL] = []
            for case let itemURL as URL in enumerator {
                let name = itemURL.lastPathComponent
                if name.hasPrefix("._") || name == ".DS_Store" {
                    toDelete.append(itemURL)
                }
            }
            for junk in toDelete {
                try? fm.removeItem(at: junk)
            }
        }

        let mslURL = fwURL.appendingPathComponent("msl")
        if let mslEntries = try? fm.contentsOfDirectory(
            at: mslURL,
            includingPropertiesForKeys: [.isDirectoryKey, .fileSizeKey]
        ) {
            for entry in mslEntries {
                let isDir = (try? entry.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) ?? false
                guard isDir else { continue }
                let imgSibling = mslURL.appendingPathComponent("\(entry.lastPathComponent).img")
                let imgSize = (try? imgSibling.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0
                guard imgSize > 0 else { continue }
                let subFiles = (try? fm.contentsOfDirectory(atPath: entry.path))?.filter {
                    !$0.hasPrefix("._") && $0 != ".DS_Store"
                } ?? []
                if subFiles.isEmpty {
                    try? fm.removeItem(at: entry)
                }
            }
        }

        let proc = Process()
        proc.executableURL = URL(fileURLWithPath: "/usr/bin/xattr")
        proc.arguments = ["-cr", fwURL.path]
        proc.standardOutput = Pipe()
        proc.standardError = Pipe()
        let watchdog = DispatchSource.makeTimerSource(queue: DispatchQueue.global())
        watchdog.schedule(deadline: .now() + 3.0)
        watchdog.setEventHandler { [weak proc] in
            if let p = proc, p.isRunning { p.terminate() }
        }
        watchdog.resume()
        do {
            try proc.run()
            proc.waitUntilExit()
        } catch {
            // Best effort
        }
        watchdog.cancel()
    }

    /// Strictly validates a cached or freshly generated `DmGame<TitleID>.framework` bundle.
    public func validateFramework(at fwURL: URL, titleId: String) -> (valid: Bool, reason: String?) {
        let fm = FileManager.default
        let upperTID = titleId.uppercased()
        var isDir: ObjCBool = false
        guard fm.fileExists(atPath: fwURL.path, isDirectory: &isDir), isDir.boolValue else {
            return (false, "framework ausente")
        }

        let manifestURL = fwURL.appendingPathComponent("game.manifest.json")
        guard let manifestData = try? Data(contentsOf: manifestURL),
              let manifest = try? JSONSerialization.jsonObject(with: manifestData) as? [String: Any] else {
            return (false, "game.manifest.json ausente ou inválido")
        }

        guard (manifest["schema"] as? Int) == 1 else {
            return (false, "schema de game.manifest.json inválido")
        }

        let manifestTID = ((manifest["title_id"] as? String) ?? "").uppercased()
        guard manifestTID == upperTID else {
            return (false, "title_id divergente (\(manifestTID) != \(upperTID))")
        }

        let execName = (manifest["framework_executable"] as? String) ?? "DmGame\(upperTID)"
        let execURL = fwURL.appendingPathComponent(execName)
        let execSize = (try? execURL.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0
        guard fm.fileExists(atPath: execURL.path), execSize > 0 else {
            return (false, "executável \(execName) ausente ou vazio")
        }

        let profileRel = (manifest["profile"] as? String) ?? "profile.tsv"
        let profileURL = fwURL.appendingPathComponent(profileRel)
        let profileSize = (try? profileURL.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0
        guard profileSize > 0 else {
            return (false, "\(profileRel) ausente ou vazio")
        }

        let launcherRel = (manifest["launcher"] as? String) ?? "dm/launcher.json"
        guard fm.fileExists(atPath: fwURL.appendingPathComponent(launcherRel).path) else {
            return (false, "\(launcherRel) ausente")
        }

        let shmapRel = (manifest["shader_map"] as? String) ?? "dm/shader_map.tsv"
        guard fm.fileExists(atPath: fwURL.appendingPathComponent(shmapRel).path) else {
            return (false, "\(shmapRel) ausente")
        }

        let manifestMods = (manifest["modules"] as? [String]) ?? []
        let packageVersion = manifest["package_version"] as? String
        let requiredMods = expectedFrameworkModules(
            for: upperTID,
            manifestModules: manifestMods,
            packageVersion: packageVersion,
            frameworkURL: fwURL
        )
        let manifestModSet = Set(manifestMods)
        var verifiedFixupMods = Set<String>()
        for mod in requiredMods {
            if !manifestModSet.contains(mod) {
                return (false, "módulo obrigatório '\(mod)' ausente em game.manifest.json (encontrados: \(manifestMods.joined(separator: ", ")))")
            }
            let fixupPath = fwURL.appendingPathComponent("dm/\(mod).fixups.tsv").path
            if !fm.fileExists(atPath: fixupPath) {
                return (false, "tabela de relocação dm/\(mod).fixups.tsv ausente")
            }
            verifiedFixupMods.insert(mod)
        }
        for mod in manifestMods where !verifiedFixupMods.contains(mod) {
            let fixupPath = fwURL.appendingPathComponent("dm/\(mod).fixups.tsv").path
            if !fm.fileExists(atPath: fixupPath) {
                return (false, "tabela de relocação dm/\(mod).fixups.tsv ausente")
            }
            verifiedFixupMods.insert(mod)
        }

        guard let fwChain = manifest["chain"] as? String, !fwChain.isEmpty else {
            return (false, "chain de shaders ausente em game.manifest.json")
        }
        if let expectedChain = expectedShaderChain() {
            let expectedTag = "b-\(expectedChain)"
            if fwChain != expectedTag {
                return (false, "ABI/chain de shaders desatualizada (\(fwChain), esperado \(expectedTag))")
            }
        }

        let mslURL = fwURL.appendingPathComponent("msl")
        let chainImgURL = mslURL.appendingPathComponent("\(fwChain).img")
        let chainImgSize = (try? chainImgURL.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0

        let chainDirURL = mslURL.appendingPathComponent(fwChain)
        var chainDirIsDir: ObjCBool = false
        let chainDirExists = fm.fileExists(atPath: chainDirURL.path, isDirectory: &chainDirIsDir) && chainDirIsDir.boolValue
        var chainDirMetallibCount = 0
        var chainDirRealEntries = 0
        if chainDirExists, let entries = try? fm.contentsOfDirectory(at: chainDirURL, includingPropertiesForKeys: [.fileSizeKey]) {
            for entry in entries {
                let name = entry.lastPathComponent
                if name.hasPrefix("._") || name == ".DS_Store" { continue }
                chainDirRealEntries += 1
                if entry.pathExtension.lowercased() == "metallib" {
                    let fSize = (try? entry.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0
                    if fSize > 0 { chainDirMetallibCount += 1 }
                }
            }
        }

        if chainDirExists && chainDirRealEntries == 0 && chainImgSize > 0 {
            return (false, "diretório msl/\(fwChain)/ vazio sombreando \(fwChain).img")
        }

        let vkLibSize = (try? mslURL.appendingPathComponent("vk/vk_shaders.metallib").resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0
        let glLibSize = (try? mslURL.appendingPathComponent("gl/gl_shaders.metallib").resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0

        let hasShaders = (chainImgSize > 0) || (chainDirMetallibCount > 0) || (vkLibSize > 0) || (glLibSize > 0)
        if !hasShaders {
            return (false, "nenhuma biblioteca de shaders válida (.img / .metallib) em msl/\(fwChain)")
        }

        return (true, nil)
    }

    private func candidateSearchDirectories(for game: PortedGame) -> [URL] {
        let fm = FileManager.default
        var orderedDirs: [URL] = []
        var seenPaths = Set<String>()

        func appendDir(_ url: URL) {
            let stdPath = url.standardizedFileURL.path
            guard !seenPaths.contains(stdPath) else { return }
            var isDir: ObjCBool = false
            guard fm.fileExists(atPath: stdPath, isDirectory: &isDir), isDir.boolValue else { return }
            seenPaths.insert(stdPath)
            orderedDirs.append(url)
        }

        let stagingBase = SystemDetector.shared.stagingDirectory
        appendDir(stagingBase)
        if let subs = try? fm.contentsOfDirectory(at: stagingBase, includingPropertiesForKeys: [.isDirectoryKey]) {
            for sub in subs where !sub.lastPathComponent.hasPrefix(".") {
                appendDir(sub)
            }
        }

        let parent = game.url.deletingLastPathComponent()
        appendDir(parent)
        if let parentSubs = try? fm.contentsOfDirectory(at: parent, includingPropertiesForKeys: [.isDirectoryKey]) {
            for sub in parentSubs where !sub.lastPathComponent.hasPrefix(".") && sub.pathExtension.lowercased() != "app" {
                appendDir(sub)
            }
        }

        let nintendoBase = URL(fileURLWithPath: "/Volumes/Nintendo/Games")
        appendDir(nintendoBase)
        if let entries = try? fm.contentsOfDirectory(at: nintendoBase, includingPropertiesForKeys: [.isDirectoryKey]) {
            for folder in entries where !folder.lastPathComponent.hasPrefix(".") {
                appendDir(folder)
                if !folder.lastPathComponent.hasSuffix("_build"),
                   let subEntries = try? fm.contentsOfDirectory(at: folder, includingPropertiesForKeys: [.isDirectoryKey]) {
                    for sub in subEntries where !sub.lastPathComponent.hasPrefix(".") && !sub.lastPathComponent.hasSuffix("_build") {
                        appendDir(sub)
                    }
                }
            }
        }

        return orderedDirs
    }

    /// Discovers candidate NSP, build directory, or source folder for the given game.
    private func locateSourceOrBuildDirectory(for game: PortedGame) -> URL? {
        let fm = FileManager.default
        let titleId = (game.titleId ?? "").uppercased()
        let normalizedName = normalizedSearchTokens(game.name)
        let dirs = candidateSearchDirectories(for: game)

        // Pass 1: Prefer directories containing <TitleID>_build
        if !titleId.isEmpty {
            for dir in dirs {
                let buildDir = dir.appendingPathComponent("\(titleId)_build")
                if fm.fileExists(atPath: buildDir.path) {
                    return dir
                }
            }
        }

        // Pass 2: Prefer directories holding an .nsp/.nsz/.nup matching TitleID
        let pkgExts: Set<String> = ["nsp", "nsz", "nup"]
        if !titleId.isEmpty {
            for dir in dirs {
                if let files = try? fm.contentsOfDirectory(at: dir, includingPropertiesForKeys: nil) {
                    for f in files {
                        let fname = f.lastPathComponent
                        guard !fname.hasPrefix("._"), pkgExts.contains(f.pathExtension.lowercased()) else { continue }
                        if fname.uppercased().contains(titleId) {
                            return dir
                        }
                    }
                }
            }
        }

        // Pass 3: Fallback to normalized game title match on .nsp/.nsz/.nup
        if normalizedName.count >= 4 {
            for dir in dirs {
                if let files = try? fm.contentsOfDirectory(at: dir, includingPropertiesForKeys: nil) {
                    for f in files {
                        let fname = f.lastPathComponent
                        guard !fname.hasPrefix("._"), pkgExts.contains(f.pathExtension.lowercased()) else { continue }
                        if normalizedSearchTokens(fname).contains(normalizedName) {
                            return dir
                        }
                    }
                }
            }
        }

        return nil
    }

    /// Locates an `.ipa` on disk matching `game` or `titleId` that already carries the current shader chain (`DMSH_CHAIN`).
    private func resolveCompatibleIpaForFastConversion(for game: PortedGame, titleId: String) -> URL? {
        var candidates: [URL] = []
        if game.url.pathExtension.lowercased() == "ipa" {
            candidates.append(game.url)
        }
        if let appVM = AppViewModel.shared {
            if let iosMatch = appVM.iosPort(for: game), iosMatch.url.pathExtension.lowercased() == "ipa" {
                candidates.append(iosMatch.url)
            }
            for libGame in appVM.libraryGames where libGame.url.pathExtension.lowercased() == "ipa" {
                if let tid = libGame.titleId, tid.caseInsensitiveCompare(titleId) == .orderedSame {
                    candidates.append(libGame.url)
                }
            }
        }
        var seen = Set<String>()
        for candidate in candidates {
            let std = candidate.standardizedFileURL.path
            guard !seen.contains(std) else { continue }
            seen.insert(std)
            let report = IpaHealthService.shared.inspectSync(ipaURL: candidate, titleIdHint: titleId)
            let isIncompatibleIpa = report.issues.contains {
                switch $0 {
                case .corruptedArchive, .missingBundleOrExecutable, .obsoleteShaderChain:
                    return true
                case .oversizedEmbeddedRomfs, .hubFrameworkStale:
                    return false
                }
            }
            if !isIncompatibleIpa {
                return candidate
            }
        }
        return nil
    }

    /// Fast path converting an up-to-date `.ipa` into `DmGame<TitleID>.framework` via `ipa_to_framework.py`
    /// without re-extracting NSPs or recompiling shaders.
    private func convertIpaToFramework(
        ipaURL: URL,
        titleId: String,
        displayName: String,
        targetFrameworkURL: URL,
        progressRange: ClosedRange<Double>,
        completion: @escaping (Bool, String?) -> Void
    ) {
        let fm = FileManager.default
        let scriptURL = URL(fileURLWithPath: BundledTools.nxnativeRootPath)
            .appendingPathComponent("dm/ios/tools/ipa_to_framework.py")
        guard fm.fileExists(atPath: scriptURL.path) else {
            completion(false, "ipa_to_framework.py not found")
            return
        }

        let detectedPython = SystemDetector.findBestPython().path ?? ""
        let pythonExec = detectedPython.isEmpty ? "/usr/bin/python3" : detectedPython

        DispatchQueue.main.async {
            let startFrac = progressRange.lowerBound + (progressRange.upperBound - progressRange.lowerBound) * 0.15
            DeviceDeploymentService.shared.activeDeployment.phase = .compiling
            DeviceDeploymentService.shared.activeDeployment.progressFraction = max(
                DeviceDeploymentService.shared.activeDeployment.progressFraction,
                startFrac
            )
            DeviceDeploymentService.shared.activeDeployment.statusMessage = "Convertendo \(ipaURL.lastPathComponent) para NxN Launcher..."
            DeviceDeploymentService.shared.activeDeployment.detailMessage = "Extração rápida de framework (shaders compatíveis reutilizados)..."
            DeviceDeploymentService.shared.activeDeployment.logLines.append("==> Fast-converting compatible IPA via ipa_to_framework.py: \(ipaURL.lastPathComponent)")
        }

        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            guard let self = self else {
                DispatchQueue.main.async { completion(false, "Service released") }
                return
            }

            try? fm.createDirectory(at: self.hubFrameworksURL, withIntermediateDirectories: true)
            let proc = Process()
            proc.executableURL = URL(fileURLWithPath: pythonExec)
            proc.currentDirectoryURL = URL(fileURLWithPath: BundledTools.nxnativeRootPath)
            var args = [
                scriptURL.path,
                ipaURL.path,
                "--out", self.hubFrameworksURL.path,
                "--name", displayName
            ]
            if !titleId.isEmpty {
                args.append(contentsOf: ["--title-id", titleId])
            }
            proc.arguments = args

            var env = ProcessInfo.processInfo.environment
            let brewPaths = "/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin:/usr/sbin:/sbin"
            let basePaths = env["PATH"] != nil ? "\(brewPaths):\(env["PATH"]!)" : brewPaths
            env["PATH"] = BundledTools.augmentedPath(base: basePaths, python: pythonExec)
            env["PYTHONUNBUFFERED"] = "1"
            let tempDirPath = SystemDetector.shared.tempDirectory.path
            env["TMPDIR"] = tempDirPath
            env["TEMP"] = tempDirPath
            env["TMP"] = tempDirPath
            for (k, v) in BundledTools.environment(for: pythonExec) {
                env[k] = v
            }
            proc.environment = env

            let outPipe = Pipe()
            proc.standardOutput = outPipe
            proc.standardError = outPipe

            let wd = DispatchSource.makeTimerSource(queue: DispatchQueue.global())
            wd.schedule(deadline: .now() + 120.0)
            wd.setEventHandler { [weak proc] in
                if let p = proc, p.isRunning { p.terminate() }
            }

            do {
                try proc.run()
                wd.resume()
                proc.waitUntilExit()
                wd.cancel()

                let outputData = outPipe.fileHandleForReading.readDataToEndOfFile()
                let outputText = String(data: outputData, encoding: .utf8) ?? ""

                guard proc.terminationStatus == 0 && fm.fileExists(atPath: targetFrameworkURL.path) else {
                    try? fm.removeItem(at: targetFrameworkURL)
                    let tail = outputText.split(whereSeparator: \.isNewline).suffix(4).joined(separator: " | ")
                    DispatchQueue.main.async {
                        DeviceDeploymentService.shared.activeDeployment.logLines.append("[WARN] Conversão rápida ipa_to_framework.py falhou (\(tail)); usando build por origem...")
                        completion(false, tail.isEmpty ? "ipa_to_framework.py exit \(proc.terminationStatus)" : tail)
                    }
                    return
                }

                self.sanitizeFrameworkArtifacts(at: targetFrameworkURL)
                let postCheck = self.validateFramework(at: targetFrameworkURL, titleId: titleId)
                guard postCheck.valid else {
                    try? fm.removeItem(at: targetFrameworkURL)
                    DispatchQueue.main.async {
                        completion(false, postCheck.reason ?? "framework inválido")
                    }
                    return
                }

                DispatchQueue.main.async {
                    DeviceDeploymentService.shared.activeDeployment.progressFraction = max(
                        DeviceDeploymentService.shared.activeDeployment.progressFraction,
                        progressRange.upperBound
                    )
                    DeviceDeploymentService.shared.activeDeployment.logLines.append("[OK] DmGame\(titleId).framework convertido rapidamente a partir do .ipa!")
                    completion(true, nil)
                }
            } catch {
                wd.cancel()
                DispatchQueue.main.async {
                    completion(false, error.localizedDescription)
                }
            }
        }
    }

    private func formatEtaSeconds(_ eta: Double?) -> String? {
        guard let eta = eta, eta.isFinite, eta >= 1.0 else { return nil }
        let secs = Int(eta.rounded())
        if secs >= 60 {
            return "\(secs / 60)m \(secs % 60)s"
        }
        return "\(secs)s"
    }

    private func resolveSourceIpaForFreshnessCheck(for game: PortedGame, titleId: String) -> URL? {
        if game.url.pathExtension.lowercased() == "ipa" {
            return game.url
        }
        if let appVM = AppViewModel.shared {
            if let iosMatch = appVM.iosPort(for: game), iosMatch.url.pathExtension.lowercased() == "ipa" {
                return iosMatch.url
            }
            if let byTid = appVM.libraryGames.first(where: {
                $0.url.pathExtension.lowercased() == "ipa" &&
                ($0.titleId ?? "").caseInsensitiveCompare(titleId) == .orderedSame
            }) {
                return byTid.url
            }
        }
        return resolveCompatibleIpaForFastConversion(for: game, titleId: titleId)
    }

    /// Verifies both structural validity AND freshness against the active `.ipa` (`romfs_identity` and mtime),
    /// preventing an older cached `DmGame<TID>.framework` (e.g. v1.0.0) from shadowing a newly updated/re-ported game.
    internal func isCachedFrameworkUpToDate(
        at fwURL: URL,
        for game: PortedGame,
        titleId: String
    ) -> (upToDate: Bool, reason: String?) {
        sanitizeFrameworkArtifacts(at: fwURL)
        let check = validateFramework(at: fwURL, titleId: titleId)
        guard check.valid else {
            return (false, check.reason)
        }

        guard let ipaURL = resolveSourceIpaForFreshnessCheck(for: game, titleId: titleId) else {
            return (true, nil)
        }

        let ipaIdentity = RomfsIdentityVerifier.readIdentity(fromIpa: ipaURL)
        let fwIdentity = RomfsIdentityVerifier.readIdentity(fromFramework: fwURL)
        if let ipaId = ipaIdentity {
            guard let fwId = fwIdentity else {
                return (false, "game.manifest.json em cache sem romfs_identity da versão atual do .ipa")
            }
            if ipaId.expectedSize != fwId.expectedSize || ipaId.expectedIndex != fwId.expectedIndex {
                return (false, "romfs_identity do cache difere do .ipa atual (\(fwId.expectedSize) vs \(ipaId.expectedSize) bytes)")
            }
            if let v1 = ipaId.displayVersion, let v2 = fwId.displayVersion, !v1.isEmpty, v1 != v2 {
                return (false, "versão do cache (\(v2)) difere do .ipa atual (\(v1))")
            }
        }

        let fwManifestURL = fwURL.appendingPathComponent("game.manifest.json")
        if let ipaDate = (try? ipaURL.resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate,
           let fwDate = (try? fwManifestURL.resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate,
           ipaDate.timeIntervalSince(fwDate) > 2.0 {
            return (false, "arquivo .ipa foi atualizado após o cache do framework")
        }

        return (true, nil)
    }

    /// Ensures that DmGame<TitleID>.framework exists and passes chain/module/shader and freshness validation.
    /// If missing or stale, converts a compatible `.ipa`, copies a validated candidate, or compiles it on-the-fly with live JSON progress.
    public func ensureFramework(
        for game: PortedGame,
        device: ConnectedAppleDevice,
        team: DeveloperSigningTeam?,
        progressRange: ClosedRange<Double> = 0.12...0.38,
        completion: @escaping (Bool, URL?, String?) -> Void
    ) {
        let fm = FileManager.default
        let titleId = (game.titleId ?? "0100000000000000").uppercased()
        let fw = hubFrameworksURL.appendingPathComponent("DmGame\(titleId).framework")

        let completionLock = NSLock()
        var didComplete = false
        func finish(_ ok: Bool, _ url: URL?, _ err: String?) {
            completionLock.lock()
            if didComplete {
                completionLock.unlock()
                return
            }
            didComplete = true
            completionLock.unlock()
            DispatchQueue.main.async {
                completion(ok, url, err)
            }
        }

        // 1. Check if already in Hub frameworks directory and passes strict ABI/module/shader AND freshness validation
        var staleReason: String? = nil
        if fm.fileExists(atPath: fw.path) {
            let freshness = isCachedFrameworkUpToDate(at: fw, for: game, titleId: titleId)
            if freshness.upToDate {
                finish(true, fw, nil)
                return
            }
            staleReason = freshness.reason
            DispatchQueue.main.async {
                DeviceDeploymentService.shared.activeDeployment.logLines.append(
                    "[WARN] Cache DmGame\(titleId).framework inválido ou desatualizado (\(freshness.reason ?? "desconhecido")); reconstruindo..."
                )
            }
        }

        // 2. Check temporary build caches & staging/source directories for already-built valid & up-to-date frameworks
        let tempFrameworksDir = SystemDetector.shared.tempDirectory.appendingPathComponent("hub_frameworks")
        var candidateFrameworkPaths: [URL] = [
            tempFrameworksDir.appendingPathComponent("DmGame\(titleId).framework")
        ]
        for dir in candidateSearchDirectories(for: game) {
            candidateFrameworkPaths.append(dir.appendingPathComponent("\(titleId)_build/ipa/build/ios/pkg/dd/Build/Products/Release-iphoneos/DmGame\(titleId).framework"))
            candidateFrameworkPaths.append(dir.appendingPathComponent("\(titleId)_build/DmGame\(titleId).framework"))
        }

        for tempFw in candidateFrameworkPaths where fm.fileExists(atPath: tempFw.path) {
            let candidateCheck = validateFramework(at: tempFw, titleId: titleId)
            // Also allow copying if only issue on source candidate is an empty shadowed shader subdir (cleaned after copy)
            let isOnlyEmptyDirShadow = (candidateCheck.reason?.contains("diretório msl/") == true)
            guard candidateCheck.valid || isOnlyEmptyDirShadow else {
                continue
            }

            try? fm.createDirectory(at: hubFrameworksURL, withIntermediateDirectories: true)
            if fm.fileExists(atPath: fw.path) {
                try? fm.removeItem(at: fw)
            }
            try? fm.copyItem(at: tempFw, to: fw)
            if fm.fileExists(atPath: fw.path) {
                let postCopyFreshness = isCachedFrameworkUpToDate(at: fw, for: game, titleId: titleId)
                if postCopyFreshness.upToDate {
                    finish(true, fw, nil)
                    return
                }
                try? fm.removeItem(at: fw)
            }
        }

        func runFullSourceBuild() {
            // 3. Locate source directory to compile framework
            guard let sourceDir = locateSourceOrBuildDirectory(for: game) else {
                let reasonSuffix = staleReason.map { " Framework em cache inválido (\($0))." } ?? ""
                let errorMsg = "Não foi encontrada pasta de origem ou NSP para \(game.name) (\(titleId)).\(reasonSuffix)"
                finish(false, nil, errorMsg)
                return
            }

            DispatchQueue.main.async {
                DeviceDeploymentService.shared.activeDeployment.phase = .compiling
                DeviceDeploymentService.shared.activeDeployment.progressFraction = max(
                    DeviceDeploymentService.shared.activeDeployment.progressFraction,
                    progressRange.lowerBound
                )
                DeviceDeploymentService.shared.activeDeployment.statusMessage = "Compilando framework para NxN Launcher..."
                DeviceDeploymentService.shared.activeDeployment.detailMessage = "Gerando DmGame\(titleId).framework a partir de \(sourceDir.lastPathComponent)..."
                DeviceDeploymentService.shared.activeDeployment.logLines.append("==> Compilando DmGame\(titleId).framework para NxN Launcher...")
            }

            // 4. Run build_ipa_from_nsp.py with --shell-framework & full JSON progress streaming
            DispatchQueue.global(qos: .userInitiated).async { [weak self] in
                guard let self = self else {
                    finish(false, nil, "Serviço encerrado durante a compilação do framework.")
                    return
                }

                // Remove broken cached framework before rebuilding so stale modules/shaders cannot linger
                if fm.fileExists(atPath: fw.path) {
                    try? fm.removeItem(at: fw)
                }
                try? fm.createDirectory(at: self.hubFrameworksURL, withIntermediateDirectories: true)

                let scriptURL = URL(fileURLWithPath: BundledTools.nxnativeRootPath).appendingPathComponent("scripts/build_ipa_from_nsp.py")
                let defaultRyujinxKeys = fm.homeDirectoryForCurrentUser.appendingPathComponent("Library/Application Support/Ryujinx/system/prod.keys").path
                let keysPath = AppViewModel.shared?.prodKeysPath ?? SystemDetector.shared.detectProdKeys()?.path ?? defaultRyujinxKeys
                let keysURL = URL(fileURLWithPath: keysPath)

                let detectedPython = SystemDetector.findBestPython().path ?? ""
                let pythonExec = detectedPython.isEmpty ? "/usr/bin/python3" : detectedPython

                let proc = Process()
                proc.executableURL = URL(fileURLWithPath: pythonExec)
                proc.currentDirectoryURL = URL(fileURLWithPath: BundledTools.nxnativeRootPath)
                var args = [
                    scriptURL.path,
                    sourceDir.path,
                    "--shell-framework", self.hubFrameworksURL.path,
                    "--progress", "json"
                ]
                if !titleId.isEmpty {
                    args.append(contentsOf: ["--title-id", titleId])
                }
                if fm.fileExists(atPath: keysURL.path) {
                    args.append(contentsOf: ["-k", keysURL.path])
                }
                proc.arguments = args

                var env = ProcessInfo.processInfo.environment
                let brewPaths = "/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin:/usr/sbin:/sbin"
                let basePaths = env["PATH"] != nil ? "\(brewPaths):\(env["PATH"]!)" : brewPaths
                env["PATH"] = BundledTools.augmentedPath(base: basePaths, python: pythonExec)
                env["PYTHONUNBUFFERED"] = "1"
                env["DM_UPDATE_PROFILE_TABLES"] = "1"
                env["LC_ALL"] = "en_US.UTF-8"
                env["LANG"] = "en_US.UTF-8"
                env["J"] = "\(ProcessInfo.processInfo.activeProcessorCount)"
                let tempDirPath = SystemDetector.shared.tempDirectory.path
                env["TMPDIR"] = tempDirPath
                env["TEMP"] = tempDirPath
                env["TMP"] = tempDirPath
                env["NXNATIVE_DATA_DIR"] = SystemDetector.shared.appSupportDirectory.path
                for (k, v) in BundledTools.environment(for: pythonExec) {
                    env[k] = v
                }
                proc.environment = env

                let stdoutPipe = Pipe()
                let stderrPipe = Pipe()
                proc.standardOutput = stdoutPipe
                proc.standardError = stderrPipe
                var tailLogs: [String] = []
                let stateLock = NSLock()
                var stdoutBuffer = ""
                var lastRedError: String? = nil
                var currentStageK = 1
                var currentStageTotal = 1
                var currentStageName = "Preparando framework"
                let decoder = JSONDecoder()
                let startTime = Date()
                var lastOutputTime = Date()

                func mapNormalizedProgress(_ norm: Double) -> Double {
                    let clamped = min(1.0, max(0.0, norm))
                    return progressRange.lowerBound + (progressRange.upperBound - progressRange.lowerBound) * clamped
                }

                func processStdoutLine(_ rawLine: String) {
                    let line = rawLine.trimmingCharacters(in: .whitespacesAndNewlines)
                    guard !line.isEmpty else { return }

                    if line.hasPrefix("{"), line.hasSuffix("}"),
                       let jsonData = line.data(using: .utf8),
                       let ev = try? decoder.decode(ProgressEvent.self, from: jsonData) {
                        switch ev.ev {
                        case "stage":
                            let k = ev.k ?? currentStageK
                            let n = max(1, ev.n ?? currentStageTotal)
                            let name = ev.name ?? currentStageName
                            stateLock.lock()
                            currentStageK = k
                            currentStageTotal = n
                            currentStageName = name
                            stateLock.unlock()

                            let stageNorm = Double(max(0, k - 1)) / Double(n)
                            let mapped = mapNormalizedProgress(stageNorm)
                            let stepDesc = ev.step ?? ""
                            DispatchQueue.main.async {
                                DeviceDeploymentService.shared.activeDeployment.phase = .compiling
                                DeviceDeploymentService.shared.activeDeployment.progressFraction = max(
                                    DeviceDeploymentService.shared.activeDeployment.progressFraction,
                                    mapped
                                )
                                DeviceDeploymentService.shared.activeDeployment.statusMessage = "[\(k)/\(n)] \(name)"
                                if !stepDesc.isEmpty {
                                    DeviceDeploymentService.shared.activeDeployment.detailMessage = stepDesc
                                }
                                DeviceDeploymentService.shared.activeDeployment.logLines.append("==> [\(k)/\(n)] \(name)")
                            }
                        case "step":
                            if let step = ev.step {
                                DispatchQueue.main.async {
                                    DeviceDeploymentService.shared.activeDeployment.detailMessage = step
                                    DeviceDeploymentService.shared.activeDeployment.logLines.append("↳ \(step)")
                                }
                            }
                        case "progress":
                            stateLock.lock()
                            let k = ev.k ?? currentStageK
                            let n = max(1, currentStageTotal)
                            let stageName = ev.name ?? currentStageName
                            stateLock.unlock()

                            let frac = min(1.0, max(0.0, ev.frac ?? 0.0))
                            let overallNorm = (Double(max(0, k - 1)) + frac) / Double(n)
                            let mapped = mapNormalizedProgress(overallNorm)
                            let step = ev.step ?? ""
                            let etaSuffix = self.formatEtaSeconds(ev.eta).map { " · ETA ~\($0)" } ?? ""
                            let detailText = step.isEmpty ? stageName + etaSuffix : "\(step)\(etaSuffix)"

                            DispatchQueue.main.async {
                                DeviceDeploymentService.shared.activeDeployment.phase = .compiling
                                DeviceDeploymentService.shared.activeDeployment.progressFraction = max(
                                    DeviceDeploymentService.shared.activeDeployment.progressFraction,
                                    mapped
                                )
                                DeviceDeploymentService.shared.activeDeployment.statusMessage = "[\(k)/\(n)] \(stageName)"
                                DeviceDeploymentService.shared.activeDeployment.detailMessage = detailText
                            }
                        case "stage_end":
                            let k = ev.k ?? currentStageK
                            stateLock.lock()
                            let n = max(1, currentStageTotal)
                            stateLock.unlock()
                            let stageDoneNorm = Double(min(k, n)) / Double(n)
                            let mapped = mapNormalizedProgress(stageDoneNorm)
                            let name = ev.name ?? ""
                            let summary = ev.summary ?? ""
                            let ok = ev.ok ?? true
                            DispatchQueue.main.async {
                                DeviceDeploymentService.shared.activeDeployment.progressFraction = max(
                                    DeviceDeploymentService.shared.activeDeployment.progressFraction,
                                    mapped
                                )
                                DeviceDeploymentService.shared.activeDeployment.logLines.append(
                                    ok ? "[OK] \(name) \(summary)" : "[FAIL] \(name) \(summary)"
                                )
                            }
                        case "say":
                            if let msg = ev.msg {
                                if msg.hasPrefix("[RED]") {
                                    let cleanErr = String(msg.dropFirst(5)).trimmingCharacters(in: .whitespacesAndNewlines)
                                    if !cleanErr.isEmpty {
                                        stateLock.lock()
                                        lastRedError = cleanErr
                                        stateLock.unlock()
                                    }
                                }
                                DispatchQueue.main.async {
                                    DeviceDeploymentService.shared.activeDeployment.logLines.append(msg)
                                }
                            }
                        default:
                            break
                        }
                    } else {
                        stateLock.lock()
                        tailLogs.append(line)
                        if tailLogs.count > 20 { tailLogs.removeFirst(tailLogs.count - 20) }
                        stateLock.unlock()
                    }
                }

                stdoutPipe.fileHandleForReading.readabilityHandler = { handle in
                    let data = handle.availableData
                    guard !data.isEmpty, let text = String(data: data, encoding: .utf8) else { return }
                    var completeLines: [String] = []
                    stateLock.lock()
                    lastOutputTime = Date()
                    stdoutBuffer += text
                    while let nl = stdoutBuffer.range(of: "\n") {
                        completeLines.append(String(stdoutBuffer[..<nl.lowerBound]))
                        stdoutBuffer.removeSubrange(..<nl.upperBound)
                    }
                    stateLock.unlock()
                    for line in completeLines {
                        processStdoutLine(line)
                    }
                }

                stderrPipe.fileHandleForReading.readabilityHandler = { handle in
                    let data = handle.availableData
                    guard !data.isEmpty, let text = String(data: data, encoding: .utf8) else { return }
                    stateLock.lock()
                    lastOutputTime = Date()
                    for raw in text.split(whereSeparator: \.isNewline) {
                        let s = String(raw)
                        tailLogs.append(s)
                        if tailLogs.count > 20 { tailLogs.removeFirst(tailLogs.count - 20) }
                    }
                    stateLock.unlock()
                    let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
                    if trimmed.contains("error:") || trimmed.contains("Error:") || trimmed.contains("[RED]") {
                        DispatchQueue.main.async {
                            DeviceDeploymentService.shared.activeDeployment.logLines.append(trimmed)
                        }
                    }
                }

                // Activity-aware watchdog: kill if silent for 10 min or exceeding 90 min hard cap
                let timer = DispatchSource.makeTimerSource(queue: DispatchQueue.global())
                timer.schedule(deadline: .now() + 30.0, repeating: 30.0)
                timer.setEventHandler { [weak proc] in
                    guard let p = proc, p.isRunning else { return }
                    let now = Date()
                    stateLock.lock()
                    let idleSeconds = now.timeIntervalSince(lastOutputTime)
                    stateLock.unlock()
                    let elapsedSeconds = now.timeIntervalSince(startTime)
                    if idleSeconds >= 600.0 || elapsedSeconds >= 5400.0 {
                        p.terminate()
                    }
                }
                timer.resume()

                do {
                    try proc.run()
                    proc.waitUntilExit()
                    timer.cancel()
                    stdoutPipe.fileHandleForReading.readabilityHandler = nil
                    stderrPipe.fileHandleForReading.readabilityHandler = nil

                    let remData = stdoutPipe.fileHandleForReading.readDataToEndOfFile()
                    if !remData.isEmpty, let remText = String(data: remData, encoding: .utf8) {
                        stateLock.lock()
                        stdoutBuffer += remText
                        let leftover = stdoutBuffer
                        stdoutBuffer = ""
                        stateLock.unlock()
                        for raw in leftover.split(whereSeparator: \.isNewline) {
                            processStdoutLine(String(raw))
                        }
                    }

                    guard proc.terminationStatus == 0 && fm.fileExists(atPath: fw.path) else {
                        try? fm.removeItem(at: fw)
                        stateLock.lock()
                        let red = lastRedError
                        let tail = tailLogs.suffix(5).joined(separator: "\n")
                        stateLock.unlock()
                        let reasonDetail = red ?? tail
                        let failMsg = "Falha ao gerar DmGame\(titleId).framework (código de saída: \(proc.terminationStatus)). \(reasonDetail)"
                        finish(false, nil, failMsg)
                        return
                    }

                    self.sanitizeFrameworkArtifacts(at: fw)
                    let postBuildCheck = self.validateFramework(at: fw, titleId: titleId)
                    guard postBuildCheck.valid else {
                        try? fm.removeItem(at: fw)
                        let failMsg = "DmGame\(titleId).framework gerado falhou na validação: \(postBuildCheck.reason ?? "desconhecido")."
                        finish(false, nil, failMsg)
                        return
                    }

                    DispatchQueue.main.async {
                        DeviceDeploymentService.shared.activeDeployment.progressFraction = max(
                            DeviceDeploymentService.shared.activeDeployment.progressFraction,
                            progressRange.upperBound
                        )
                        DeviceDeploymentService.shared.activeDeployment.logLines.append("[OK] DmGame\(titleId).framework validado e gerado com sucesso!")
                    }
                    finish(true, fw, nil)
                } catch {
                    timer.cancel()
                    stdoutPipe.fileHandleForReading.readabilityHandler = nil
                    stderrPipe.fileHandleForReading.readabilityHandler = nil
                    finish(false, nil, error.localizedDescription)
                }
            }
        }

        // 2.5. Fast path: if a compatible up-to-date .ipa exists on disk, convert directly via ipa_to_framework.py
        if let compatibleIpa = resolveCompatibleIpaForFastConversion(for: game, titleId: titleId) {
            convertIpaToFramework(
                ipaURL: compatibleIpa,
                titleId: titleId,
                displayName: game.name,
                targetFrameworkURL: fw,
                progressRange: progressRange
            ) { fastOk, _ in
                if fastOk && fm.fileExists(atPath: fw.path) {
                    finish(true, fw, nil)
                } else {
                    runFullSourceBuild()
                }
            }
            return
        }

        runFullSourceBuild()
    }

    /// Validates all registered Hub games and automatically rebuilds any stale or broken frameworks
    /// (excluding games just built if specified) before compiling the shared `NxN Launcher` IPA.
    public func refreshFrameworksForHub(
        games: [ShellLibraryState.GameEntry],
        device: ConnectedAppleDevice,
        team: DeveloperSigningTeam?,
        excludingTitleIds: Set<String> = [],
        knownPortedGames: [PortedGame] = [],
        completion: @escaping (Bool, String?) -> Void
    ) {
        let fm = FileManager.default
        let excluded = Set(excludingTitleIds.map { $0.uppercased() })
        let targets = games.filter { !excluded.contains($0.titleID.uppercased()) }

        func step(index: Int) {
            guard index < targets.count else {
                DispatchQueue.main.async { completion(true, nil) }
                return
            }

            let entry = targets[index]
            let fwURL = URL(fileURLWithPath: entry.framework)
            let matchedPortedGame = knownPortedGames.first {
                ($0.titleId ?? "").uppercased() == entry.titleID.uppercased()
            }
            let checkReason: String?
            let isUpToDate: Bool
            if let matchedGame = matchedPortedGame {
                let freshness = isCachedFrameworkUpToDate(at: fwURL, for: matchedGame, titleId: entry.titleID)
                isUpToDate = freshness.upToDate
                checkReason = freshness.reason
            } else {
                sanitizeFrameworkArtifacts(at: fwURL)
                let check = validateFramework(at: fwURL, titleId: entry.titleID)
                isUpToDate = check.valid
                checkReason = check.reason
            }
            if isUpToDate {
                step(index: index + 1)
                return
            }

            // If the framework bundle was removed and the game is no longer present in the library,
            // skip rebuilding it so `validatedShellFrameworkPaths` can prune the orphaned entry cleanly.
            if !fm.fileExists(atPath: fwURL.path), matchedPortedGame == nil {
                step(index: index + 1)
                return
            }

            let targetGame = matchedPortedGame ?? PortedGame(
                name: entry.name,
                url: self.hubFrameworksURL,
                platform: .ios,
                sizeBytes: 0,
                modificationDate: Date(),
                bundleId: nil,
                titleId: entry.titleID,
                versionString: nil
            )

            // If a previously registered Hub game has neither an .ipa in the library nor a locateable NSP source on disk,
            // prune the unrecoverable stale Hub entry cleanly instead of blocking the current deployment.
            if matchedPortedGame == nil && locateSourceOrBuildDirectory(for: targetGame) == nil {
                DispatchQueue.main.async {
                    DeviceDeploymentService.shared.activeDeployment.logLines.append(
                        "[WARN] Entrada órfã/antiga '\(entry.name)' (\(entry.titleID)) sem origem no disco foi removida do shell.json."
                    )
                }
                _ = pruneGamesFromHub(titleIds: [entry.titleID])
                step(index: index + 1)
                return
            }

            DispatchQueue.main.async {
                DeviceDeploymentService.shared.activeDeployment.logLines.append(
                    "[WARN] Jogo registrado \(entry.name) (\(entry.titleID)) tem framework desatualizado (\(checkReason ?? "")). Atualizando..."
                )
            }

            let sliceBase = 0.20
            let sliceWidth = 0.15 / Double(max(1, targets.count))
            let sliceStart = sliceBase + Double(index) * sliceWidth
            let sliceEnd = sliceStart + sliceWidth

            ensureFramework(for: targetGame, device: device, team: team, progressRange: sliceStart...sliceEnd) { ok, _, err in
                if !ok {
                    // Self-heal: do not let an unselected corrupted/legacy entry in shell.json block deploying
                    // other valid games. Prune the unrecoverable legacy entry and continue cleanly.
                    DispatchQueue.main.async {
                        DeviceDeploymentService.shared.activeDeployment.logLines.append(
                            "[WARN] Removendo entrada antiga irrecuperável '\(entry.name)' (\(entry.titleID)) do shell.json para não bloquear o deploy atual (\(err ?? "erro desconhecido"))."
                        )
                    }
                    _ = self.pruneGamesFromHub(titleIds: [entry.titleID])
                }
                step(index: index + 1)
            }
        }

        step(index: 0)
    }
}
