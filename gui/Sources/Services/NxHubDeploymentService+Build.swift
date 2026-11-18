import Foundation
import AppKit

// MARK: - Route C Shell Library & Build Orchestration

public struct ShellLibraryState: Codable {
    public struct GameEntry: Codable, Equatable {
        public var titleID: String
        public var name: String
        public var framework: String

        public init(titleID: String, name: String, framework: String) {
            self.titleID = titleID
            self.name = name
            self.framework = framework
        }
    }

    public static var defaultBundleId: String {
        NxHubDeploymentService.hubBundleId
    }

    public var bundleID: String = defaultBundleId
    public var team: String = ""
    public var games: [GameEntry] = []

    public init(bundleID: String = defaultBundleId, team: String = "", games: [GameEntry] = []) {
        self.bundleID = bundleID
        self.team = team
        self.games = games
    }
}

extension NxHubDeploymentService {
    public var hubRootURL: URL {
        SystemDetector.shared.appSupportDirectory.appendingPathComponent("MobileHub", isDirectory: true)
    }

    public var hubFrameworksURL: URL {
        hubRootURL.appendingPathComponent("Frameworks", isDirectory: true)
    }

    public var hubProjectURL: URL {
        hubRootURL.appendingPathComponent("project", isDirectory: true)
    }

    public var hubDerivedDataURL: URL {
        hubRootURL.appendingPathComponent("dd", isDirectory: true)
    }

    public var shellJsonURL: URL {
        hubRootURL.appendingPathComponent("shell.json")
    }

    public func loadShellLibrary() -> ShellLibraryState {
        let fm = FileManager.default
        guard fm.fileExists(atPath: shellJsonURL.path),
              let data = try? Data(contentsOf: shellJsonURL),
              var state = try? JSONDecoder().decode(ShellLibraryState.self, from: data) else {
            return ShellLibraryState()
        }
        var didMutate = false
        if state.bundleID == "org.nxnative.shell" {
            state.bundleID = ShellLibraryState.defaultBundleId
            didMutate = true
        }
        // Automatically relocate framework paths if the Launcher installation folder moved
        for i in state.games.indices {
            let fwName = URL(fileURLWithPath: state.games[i].framework).lastPathComponent
            let expectedFw = hubFrameworksURL.appendingPathComponent(fwName).path
            if state.games[i].framework != expectedFw && fm.fileExists(atPath: expectedFw) {
                state.games[i].framework = expectedFw
                didMutate = true
            }
        }
        if didMutate {
            try? saveShellLibrary(state)
        }
        return state
    }

    public func saveShellLibrary(_ state: ShellLibraryState) throws {
        let fm = FileManager.default
        try fm.createDirectory(at: hubRootURL, withIntermediateDirectories: true)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        let data = try encoder.encode(state)
        try data.write(to: shellJsonURL, options: .atomic)
    }

    /// Registers a game in the Hub's `shell.json` registry.
    @discardableResult
    public func registerGameInHub(titleId: String, name: String, frameworkPath: String) throws -> ShellLibraryState {
        var state = loadShellLibrary()
        let cleanId = titleId.uppercased()
        let entry = ShellLibraryState.GameEntry(titleID: cleanId, name: name, framework: frameworkPath)
        if let idx = state.games.firstIndex(where: { $0.titleID == cleanId }) {
            state.games[idx] = entry
        } else {
            state.games.append(entry)
        }
        try saveShellLibrary(state)
        return state
    }

    /// Describes another registered Hub game whose framework fails strict validation and would trigger a rebuild.
    public struct StaleHubGameEntry: Identifiable, Hashable {
        public let titleID: String
        public let name: String
        public let frameworkPath: String
        public let reason: String
        public let hasPortedGameInLibrary: Bool

        public var id: String { titleID }
    }

    /// Returns all Hub entries (excluding `excludingTitleIds`) whose frameworks fail strict ABI/chain/shader validation.
    public func staleOtherHubGames(
        excludingTitleIds: Set<String> = [],
        knownPortedGames: [PortedGame] = []
    ) -> [StaleHubGameEntry] {
        let excluded = Set(excludingTitleIds.map { $0.uppercased() })
        let library = loadShellLibrary()
        var result: [StaleHubGameEntry] = []

        for entry in library.games {
            let upperTID = entry.titleID.uppercased()
            guard !excluded.contains(upperTID) else { continue }
            let fwURL = URL(fileURLWithPath: entry.framework)
            let check = validateFramework(at: fwURL, titleId: upperTID)
            guard !check.valid else { continue }
            let hasInLib = knownPortedGames.contains { ($0.titleId ?? "").uppercased() == upperTID }
            result.append(StaleHubGameEntry(
                titleID: upperTID,
                name: entry.name,
                frameworkPath: entry.framework,
                reason: check.reason ?? "desatualizado",
                hasPortedGameInLibrary: hasInLib
            ))
        }
        return result
    }

    /// Removes specified Title IDs from `shell.json` and moves any stale/orphaned `.framework` bundles to Trash.
    @discardableResult
    public func pruneGamesFromHub(titleIds: Set<String>) -> ShellLibraryState {
        let upperSet = Set(titleIds.map { $0.uppercased() })
        guard !upperSet.isEmpty else { return loadShellLibrary() }

        let fm = FileManager.default
        var state = loadShellLibrary()
        var surviving: [ShellLibraryState.GameEntry] = []
        for entry in state.games {
            if upperSet.contains(entry.titleID.uppercased()) {
                let fwURL = URL(fileURLWithPath: entry.framework)
                if fm.fileExists(atPath: fwURL.path) {
                    var trashedURL: NSURL?
                    try? fm.trashItem(at: fwURL, resultingItemURL: &trashedURL)
                }
            } else {
                surviving.append(entry)
            }
        }
        state.games = surviving
        try? saveShellLibrary(state)
        return state
    }

    /// Sanitizes and validates all registered frameworks in `library` before shell build,
    /// pruning stale entries whose `.framework` directories no longer exist on disk.
    private func validatedShellFrameworkPaths(for library: ShellLibraryState) -> (paths: [String]?, error: String?) {
        let fm = FileManager.default
        var validFwPaths: [String] = []
        var survivingEntries: [ShellLibraryState.GameEntry] = []
        var didPrune = false

        for entry in library.games {
            let fwURL = URL(fileURLWithPath: entry.framework)
            guard fm.fileExists(atPath: fwURL.path) else {
                didPrune = true
                continue
            }
            sanitizeFrameworkArtifacts(at: fwURL)
            let check = validateFramework(at: fwURL, titleId: entry.titleID)
            guard check.valid else {
                return (nil, "Framework inválido/desatualizado para \(entry.name) (\(entry.titleID)): \(check.reason ?? "desconhecido").")
            }
            survivingEntries.append(entry)
            validFwPaths.append(fwURL.path)
        }

        if didPrune {
            var updated = library
            updated.games = survivingEntries
            try? saveShellLibrary(updated)
        }

        guard !validFwPaths.isEmpty else {
            return (nil, "No valid game frameworks found in Hub registry.")
        }
        return (validFwPaths, nil)
    }

    /// Generates the DmShell Xcode project using `build_shell.sh --prepare-xcode`.
    public func prepareShellProject(
        library: ShellLibraryState,
        teamId: String,
        completion: @escaping (Bool, String) -> Void
    ) {
        let fm = FileManager.default
        do {
            try fm.createDirectory(at: hubProjectURL, withIntermediateDirectories: true)
            try fm.createDirectory(at: hubFrameworksURL, withIntermediateDirectories: true)
            try fm.createDirectory(at: hubDerivedDataURL, withIntermediateDirectories: true)
        } catch {
            completion(false, "Failed to create Hub directories: \(error.localizedDescription)")
            return
        }

        let repoPath = BundledTools.nxnativeRootPath
        let scriptPath = (repoPath as NSString).appendingPathComponent("dm/ios/tools/build_shell.sh")
        let packagePath = (repoPath as NSString).appendingPathComponent("frontend-ios")

        guard fm.fileExists(atPath: scriptPath) else {
            completion(false, "build_shell.sh not found at \(scriptPath)")
            return
        }

        let fwValidation = validatedShellFrameworkPaths(for: library)
        guard let validFwPaths = fwValidation.paths else {
            completion(false, fwValidation.error ?? "No valid game frameworks found in Hub registry.")
            return
        }

        var env = ProcessInfo.processInfo.environment
        env["SHELL_DIR"] = hubProjectURL.path
        env["DM_SHELL_FRAMEWORKS"] = validFwPaths.joined(separator: "\n")
        env["DM_BUNDLE_ID"] = library.bundleID
        env["DM_TEAM_ID"] = teamId
        env["DM_SHELL_NAME"] = "NxN Launcher"
        env["DM_SHELL_PACKAGE"] = packagePath
        env["DM_XCODE_DERIVED_DATA"] = hubDerivedDataURL.path
        let tempDirPath = SystemDetector.shared.tempDirectory.path
        env["TMPDIR"] = tempDirPath
        env["TEMP"] = tempDirPath
        env["TMP"] = tempDirPath

        let pythonPath = SystemDetector.findBestPythonPath()
        env["FONT_PY"] = pythonPath
        let brewPaths = "/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin:/usr/sbin:/sbin"
        let basePaths = env["PATH"] != nil ? "\(brewPaths):\(env["PATH"]!)" : brewPaths
        env["PATH"] = BundledTools.augmentedPath(base: basePaths, python: pythonPath)
        for (k, v) in BundledTools.environment(for: pythonPath) {
            env[k] = v
        }

        DispatchQueue.global(qos: .userInitiated).async {
            let proc = Process()
            let pipe = Pipe()
            proc.executableURL = URL(fileURLWithPath: "/bin/bash")
            proc.arguments = [scriptPath, "--prepare-xcode"]
            proc.environment = env
            proc.standardOutput = pipe
            proc.standardError = pipe

            let watchdog = DispatchSource.makeTimerSource(queue: DispatchQueue.global())
            watchdog.schedule(deadline: .now() + 30.0)
            watchdog.setEventHandler { [weak proc] in
                if let p = proc, p.isRunning {
                    p.terminate()
                }
            }
            watchdog.resume()

            do {
                try proc.run()
                proc.waitUntilExit()
                watchdog.cancel()

                let outData = pipe.fileHandleForReading.readDataToEndOfFile()
                let output = String(data: outData, encoding: .utf8) ?? ""

                if proc.terminationStatus == 0 {
                    DispatchQueue.main.async { completion(true, "Shell project prepared successfully.") }
                } else {
                    DispatchQueue.main.async { completion(false, "Project preparation failed (\(proc.terminationStatus)): \(output)") }
                }
            } catch {
                watchdog.cancel()
                DispatchQueue.main.async { completion(false, "Failed to execute build_shell.sh: \(error.localizedDescription)") }
            }
        }
    }

    /// Builds and packages the complete multi-game shell into an .ipa file.
    public func buildShellIPA(
        library: ShellLibraryState,
        outputIPAURL: URL,
        teamId: String,
        progressHandler: @escaping (String) -> Void,
        completion: @escaping (Bool, String) -> Void
    ) {
        let fm = FileManager.default
        do {
            try fm.createDirectory(at: hubProjectURL, withIntermediateDirectories: true)
            try fm.createDirectory(at: hubFrameworksURL, withIntermediateDirectories: true)
            try fm.createDirectory(at: hubDerivedDataURL, withIntermediateDirectories: true)
            try fm.createDirectory(at: outputIPAURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        } catch {
            completion(false, "Failed to create directories: \(error.localizedDescription)")
            return
        }

        let repoPath = BundledTools.nxnativeRootPath
        let scriptPath = (repoPath as NSString).appendingPathComponent("dm/ios/tools/build_shell.sh")
        let packagePath = (repoPath as NSString).appendingPathComponent("frontend-ios")

        guard fm.fileExists(atPath: scriptPath) else {
            completion(false, "build_shell.sh not found at \(scriptPath)")
            return
        }

        let fwValidation = validatedShellFrameworkPaths(for: library)
        guard let fwPaths = fwValidation.paths else {
            completion(false, fwValidation.error ?? "No valid game frameworks found in Hub registry.")
            return
        }

        var env = ProcessInfo.processInfo.environment
        env["SHELL_DIR"] = hubProjectURL.path
        env["DM_SHELL_FRAMEWORKS"] = fwPaths.joined(separator: "\n")
        env["DM_BUNDLE_ID"] = library.bundleID
        env["DM_TEAM_ID"] = teamId.isEmpty ? "0000000000" : teamId
        env["DM_SHELL_NAME"] = "NxN Launcher"
        env["DM_SHELL_PACKAGE"] = packagePath
        env["DM_XCODE_DERIVED_DATA"] = hubDerivedDataURL.path
        let tempDirPath = SystemDetector.shared.tempDirectory.path
        env["TMPDIR"] = tempDirPath
        env["TEMP"] = tempDirPath
        env["TMP"] = tempDirPath
        env["DM_PACK_IPA"] = outputIPAURL.path

        let pythonPath = SystemDetector.findBestPythonPath()
        env["FONT_PY"] = pythonPath
        let brewPaths = "/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin:/usr/sbin:/sbin"
        let basePaths = env["PATH"] != nil ? "\(brewPaths):\(env["PATH"]!)" : brewPaths
        env["PATH"] = BundledTools.augmentedPath(base: basePaths, python: pythonPath)
        for (k, v) in BundledTools.environment(for: pythonPath) {
            env[k] = v
        }

        progressHandler("Compilando NxN Launcher IPA com \(fwPaths.count) jogo(s)...")

        DispatchQueue.global(qos: .userInitiated).async {
            let proc = Process()
            let pipe = Pipe()
            proc.executableURL = URL(fileURLWithPath: "/bin/bash")
            proc.arguments = [scriptPath, "--build"]
            proc.environment = env
            proc.standardOutput = pipe
            proc.standardError = pipe

            // Watchdog: 180 seconds bounded timeout
            let watchdog = DispatchSource.makeTimerSource(queue: DispatchQueue.global())
            watchdog.schedule(deadline: .now() + 180.0)
            watchdog.setEventHandler { [weak proc] in
                if let p = proc, p.isRunning {
                    p.terminate()
                }
            }
            watchdog.resume()

            do {
                try proc.run()
                proc.waitUntilExit()
                watchdog.cancel()

                let outData = pipe.fileHandleForReading.readDataToEndOfFile()
                let output = String(data: outData, encoding: .utf8) ?? ""

                if proc.terminationStatus == 0 && fm.fileExists(atPath: outputIPAURL.path) {
                    DispatchQueue.main.async {
                        completion(true, "NxN Launcher IPA gerado com sucesso em \(outputIPAURL.lastPathComponent)")
                    }
                } else {
                    DispatchQueue.main.async {
                        completion(false, "Falha na geração do IPA (\(proc.terminationStatus)): \(output.suffix(400))")
                    }
                }
            } catch {
                watchdog.cancel()
                DispatchQueue.main.async {
                    completion(false, "Erro ao executar build_shell.sh: \(error.localizedDescription)")
                }
            }
        }
    }

    internal func hubSignatureDefaultsKey(deviceId: String, bundleId: String) -> String {
        "nxnative_hub_deployed_sig_\(deviceId)_\(bundleId)"
    }

    public func computeHubDeploymentSignature(library: ShellLibraryState, teamId: String) -> String? {
        guard let fwPaths = validatedShellFrameworkPaths(for: library).paths else { return nil }
        let fm = FileManager.default
        let builtApp = hubDerivedDataURL.appendingPathComponent("Build/Products/Release-iphoneos/DmShell.app")
        let builtExec = builtApp.appendingPathComponent("DmShell")
        guard fm.fileExists(atPath: builtExec.path) else { return nil }
        guard shellBinaryHasIncreasedMemoryLimit(at: builtApp) else { return nil }

        let repoPath = BundledTools.nxnativeRootPath
        let shellScript = URL(fileURLWithPath: (repoPath as NSString).appendingPathComponent("dm/ios/tools/build_shell.sh"))
        let scriptMtime = (try? shellScript.resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate?.timeIntervalSince1970 ?? 0

        let frontendSources = URL(fileURLWithPath: (repoPath as NSString).appendingPathComponent("frontend-ios/Sources"))
        var latestFrontendMtime: Double = 0
        if let en = fm.enumerator(at: frontendSources, includingPropertiesForKeys: [.contentModificationDateKey]) {
            for case let file as URL in en {
                if let dt = (try? file.resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate?.timeIntervalSince1970 {
                    latestFrontendMtime = max(latestFrontendMtime, dt)
                }
            }
        }

        let dmHostExec = hubFrameworksURL.appendingPathComponent("DmHost.framework/DmHost")
        let dmHostMtime = (try? dmHostExec.resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate?.timeIntervalSince1970 ?? 0

        var fwTokens: [String] = []
        let embeddedFwDir = builtApp.appendingPathComponent("Frameworks")
        for path in fwPaths.sorted() {
            let fwURL = URL(fileURLWithPath: path)
            let fwName = fwURL.lastPathComponent
            let embeddedFw = embeddedFwDir.appendingPathComponent(fwName)
            guard fm.fileExists(atPath: embeddedFw.path) else { return nil }
            let binName = fwURL.deletingPathExtension().lastPathComponent
            let binURL = fwURL.appendingPathComponent(binName)
            let vals = try? binURL.resourceValues(forKeys: [.fileSizeKey, .contentModificationDateKey])
            let mtime = Int(vals?.contentModificationDate?.timeIntervalSince1970 ?? 0)
            let sz = vals?.fileSize ?? 0
            let manVals = try? fwURL.appendingPathComponent("game.manifest.json").resourceValues(forKeys: [.fileSizeKey, .contentModificationDateKey])
            let manMtime = Int(manVals?.contentModificationDate?.timeIntervalSince1970 ?? 0)
            let manSz = manVals?.fileSize ?? 0
            let profVals = try? fwURL.appendingPathComponent("profile.tsv").resourceValues(forKeys: [.fileSizeKey, .contentModificationDateKey])
            let profMtime = Int(profVals?.contentModificationDate?.timeIntervalSince1970 ?? 0)
            fwTokens.append("\(fwName):\(sz):\(mtime):m\(manSz)_\(manMtime):p\(profMtime)")
        }

        return [
            "bid=\(library.bundleID)",
            "team=\(teamId)",
            "script=\(Int(scriptMtime))",
            "fe=\(Int(latestFrontendMtime))",
            "host=\(Int(dmHostMtime))",
            "fws=\(fwTokens.joined(separator: ","))"
        ].joined(separator: "|")
    }

    /// Checks whether the compiled DmShell.app carries the Increased Memory Limit entitlement.
    private func shellBinaryHasIncreasedMemoryLimit(at appURL: URL) -> Bool {
        let res = BoundedProcess.run(
            "/usr/bin/codesign",
            ["-d", "--entitlements", ":-", appURL.path],
            timeout: 4.0
        )
        return res.success && res.output.contains("com.apple.developer.kernel.increased-memory-limit")
    }

    public func isHubUpToDateOnDevice(device: ConnectedAppleDevice, library: ShellLibraryState, teamId: String) -> Bool {
        guard let currentSig = computeHubDeploymentSignature(library: library, teamId: teamId) else {
            return false
        }
        let saved = UserDefaults.standard.string(forKey: hubSignatureDefaultsKey(deviceId: device.id, bundleId: library.bundleID))
        return saved == currentSig
    }

    public func recordHubDeployedOnDevice(device: ConnectedAppleDevice, library: ShellLibraryState, teamId: String) {
        if let sig = computeHubDeploymentSignature(library: library, teamId: teamId) {
            UserDefaults.standard.set(sig, forKey: hubSignatureDefaultsKey(deviceId: device.id, bundleId: library.bundleID))
        }
    }
}
