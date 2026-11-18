import Foundation

public struct ProdKeysDetectionResult {
    public let path: String
    public let sourceName: String
    public let isValid: Bool
}

public struct NxNativeDetectionResult {
    public let path: String
    public let isValid: Bool
}

public struct PythonRuntimeInfo {
    public let path: String?
    public let version: String
    public let isSufficient: Bool
    public let isStable: Bool
    public let isBundled: Bool
    public let isExperimental: Bool
}

public final class SystemDetector {
    public static let shared = SystemDetector()
    public static let officialRepoURL = "https://gitlab.com/rennan-group2/nxnative_Launcher.git"
    public static let upstreamRepoURL = "https://github.com/seedds/nxnative.git"
    public static let mirrorRepoURL = "https://gitlab.com/rennan-group2/nxnative_Launcher.git"
    public static let savedNxnativePathKey = "NXNative_SavedNxnativePath"
    
    private init() {}
    
    /// Queries the Python version and compatibility for a given executable path.
    public static func queryPythonVersion(_ path: String) -> (major: Int, minor: Int, micro: Int, versionStr: String)? {
        let res = BoundedProcess.run(path, ["-B", "-c", "import sys; print(f'{sys.version_info.major}.{sys.version_info.minor}.{sys.version_info.micro}')"], extraEnv: ["PYTHONDONTWRITEBYTECODE": "1"], timeout: 3.0)
        guard res.success else { return nil }
        let str = res.output.trimmingCharacters(in: .whitespacesAndNewlines)
        let parts = str.split(separator: ".").compactMap { Int($0) }
        guard parts.count >= 2 else { return nil }
        let micro = parts.count > 2 ? parts[2] : 0
        return (parts[0], parts[1], micro, str)
    }
    
    /// Checks whether the specified Python interpreter has all required modules for building games (lz4, capstone, fontTools, zbic).
    public static func hasRequiredPythonModules(_ pyPath: String) -> Bool {
        let res = BoundedProcess.run(pyPath, ["-B", "-c", "import lz4.block, capstone, fontTools, zbic; print('OK')"], timeout: 3.0)
        return res.success && res.output.contains("OK")
    }
    
    /// Determines the best available Python interpreter with strict stability prioritization.
    public static func findBestPython() -> PythonRuntimeInfo {
        let fm = FileManager.default
        
        // 1. Check Bundled Standalone Python runtime (inside .app/Contents/Resources/python)
        var bundledCandidate: PythonRuntimeInfo? = nil
        if let bundled = BundledTools.python(), fm.fileExists(atPath: bundled),
           let ver = queryPythonVersion(bundled) {
            let hasModules = hasRequiredPythonModules(bundled)
            let info = PythonRuntimeInfo(path: bundled, version: "Python \(ver.versionStr)", isSufficient: hasModules, isStable: true, isBundled: true, isExperimental: false)
            if hasModules {
                return info
            }
            bundledCandidate = info
        }
        
        // 2. Custom user-specified Python override (via UserDefaults)
        if let custom = UserDefaults.standard.string(forKey: "nxnative_custom_python_path"),
           !custom.isEmpty, fm.fileExists(atPath: custom),
           let ver = queryPythonVersion(custom) {
            let isSufficient = (ver.major > 3) || (ver.major == 3 && ver.minor >= 12)
            let isStable = (ver.major == 3 && ver.minor >= 12 && ver.minor <= 14)
            let isExp = (ver.major == 3 && ver.minor >= 15)
            let hasModules = hasRequiredPythonModules(custom)
            return PythonRuntimeInfo(path: custom, version: "Python \(ver.versionStr)", isSufficient: isSufficient && !isExp && hasModules, isStable: isStable, isBundled: false, isExperimental: isExp)
        }
        
        // 3. Search system & environment paths in strict priority order (Stable versions 3.13, 3.14, 3.12 first)
        var prioritizedCandidates = [
            "/opt/homebrew/bin/python3.13", "/opt/homebrew/opt/python@3.13/libexec/bin/python3",
            "/opt/homebrew/opt/python@3.13/bin/python3.13", "/opt/homebrew/opt/python@3.13/bin/python3",
            "/usr/local/bin/python3.13", "/usr/local/opt/python@3.13/libexec/bin/python3",
            "/usr/local/opt/python@3.13/bin/python3.13", "/Library/Frameworks/Python.framework/Versions/3.13/bin/python3",
            "/opt/homebrew/bin/python3.14", "/opt/homebrew/opt/python@3.14/libexec/bin/python3",
            "/opt/homebrew/opt/python@3.14/bin/python3.14", "/opt/homebrew/opt/python@3.14/bin/python3",
            "/usr/local/bin/python3.14", "/usr/local/opt/python@3.14/libexec/bin/python3",
            "/usr/local/opt/python@3.14/bin/python3.14", "/Library/Frameworks/Python.framework/Versions/3.14/bin/python3",
            "/opt/homebrew/bin/python3.12", "/opt/homebrew/opt/python@3.12/libexec/bin/python3",
            "/opt/homebrew/opt/python@3.12/bin/python3.12", "/opt/homebrew/opt/python@3.12/bin/python3",
            "/usr/local/bin/python3.12", "/usr/local/opt/python@3.12/libexec/bin/python3",
            "/usr/local/opt/python@3.12/bin/python3.12", "/Library/Frameworks/Python.framework/Versions/3.12/bin/python3",
            "/opt/homebrew/bin/python3", "/usr/local/bin/python3", "/usr/bin/python3"
        ]
        
        // Include Pyenv shims and installed versions if present in user home
        if let home = ProcessInfo.processInfo.environment["HOME"] {
            prioritizedCandidates.insert("\(home)/.pyenv/shims/python3", at: 0)
            if let pyenvVersions = try? fm.contentsOfDirectory(atPath: "\(home)/.pyenv/versions") {
                for v in pyenvVersions.sorted().reversed() {
                    let pyBin = "\(home)/.pyenv/versions/\(v)/bin/python3"
                    if fm.isExecutableFile(atPath: pyBin) {
                        prioritizedCandidates.append(pyBin)
                    }
                }
            }
        }
        
        var workingSystemCandidate: PythonRuntimeInfo? = nil
        var fallbackStableCandidate: PythonRuntimeInfo? = nil
        var experimentalCandidate: (path: String, version: String)? = nil
        var outdatedCandidate: (path: String, version: String)? = nil
        
        for candidate in prioritizedCandidates where fm.isExecutableFile(atPath: candidate) {
            guard let ver = queryPythonVersion(candidate) else { continue }
            let verStr = "Python \(ver.versionStr)"
            if ver.major == 3 && ver.minor >= 12 && ver.minor <= 14 {
                let hasModules = hasRequiredPythonModules(candidate)
                let info = PythonRuntimeInfo(path: candidate, version: verStr, isSufficient: hasModules, isStable: true, isBundled: false, isExperimental: false)
                if hasModules {
                    workingSystemCandidate = info
                    break
                } else if fallbackStableCandidate == nil {
                    fallbackStableCandidate = info
                }
            } else if ver.major == 3 && ver.minor >= 15 {
                if experimentalCandidate == nil { experimentalCandidate = (candidate, verStr) }
            } else if ver.major == 3 && ver.minor < 12 {
                if outdatedCandidate == nil { outdatedCandidate = (candidate, verStr) }
            }
        }
        
        if let working = workingSystemCandidate {
            return working
        }
        if let bundled = bundledCandidate {
            return bundled
        }
        if let fallback = fallbackStableCandidate {
            return fallback
        }
        if let exp = experimentalCandidate {
            return PythonRuntimeInfo(path: exp.path, version: exp.version, isSufficient: false, isStable: false, isBundled: false, isExperimental: true)
        }
        if let old = outdatedCandidate {
            return PythonRuntimeInfo(path: old.path, version: old.version, isSufficient: false, isStable: false, isBundled: false, isExperimental: false)
        }
        return PythonRuntimeInfo(path: nil, version: "Not Found", isSufficient: false, isStable: false, isBundled: false, isExperimental: false)
    }
    
    /// Returns the active executable path for the best available Python interpreter.
    public static func findBestPythonPath() -> String {
        findBestPython().path ?? "/usr/bin/python3"
    }
    
    // MARK: - Customizable Workspace, Staging and AppSupport Directories
    public static let savedWorkspacePathKey = "NXNative_SavedWorkspacePath"
    public static let savedStagingPathKey = "NXNative_SavedStagingPath"
    public static let savedAppSupportPathKey = "NXNative_SavedAppSupportPath"

    public func isParentVolumeMounted(for url: URL) -> Bool {
        let components = url.standardizedFileURL.pathComponents
        if components.count >= 3, components[1] == "Volumes" {
            let mountPoint = "/Volumes/\(components[2])"
            return FileManager.default.fileExists(atPath: mountPoint)
        }
        return true
    }

    /// Returns a standardized directory URL if it exists or can be created on a mounted volume.
    public func resolveDirectoryIfAvailable(atPath rawPath: String?) -> URL? {
        guard let trimmed = rawPath?.trimmingCharacters(in: .whitespacesAndNewlines), !trimmed.isEmpty else { return nil }
        let url = URL(fileURLWithPath: trimmed, isDirectory: true).standardizedFileURL
        let fm = FileManager.default
        var isDir: ObjCBool = false
        if fm.fileExists(atPath: url.path, isDirectory: &isDir), isDir.boolValue {
            return url
        }
        // Keep honoring the user's configured folder if its volume is mounted even if the folder was cleaned up
        if !fm.fileExists(atPath: url.path) && isParentVolumeMounted(for: url) {
            try? fm.createDirectory(at: url, withIntermediateDirectories: true)
            if fm.fileExists(atPath: url.path, isDirectory: &isDir), isDir.boolValue {
                return url
            }
        }
        return nil
    }

    private func resolveCustomDirectory(forKey key: String) -> URL? {
        resolveDirectoryIfAvailable(atPath: UserDefaults.standard.string(forKey: key))
    }

    public func getCustomWorkspaceDirectory() -> URL? {
        resolveCustomDirectory(forKey: Self.savedWorkspacePathKey)
    }

    public func saveCustomWorkspaceDirectory(_ url: URL?) {
        if let url = url {
            let standardized = url.standardizedFileURL.path
            UserDefaults.standard.set(standardized, forKey: Self.savedWorkspacePathKey)
        } else {
            UserDefaults.standard.removeObject(forKey: Self.savedWorkspacePathKey)
        }
    }

    public func getCustomStagingDirectory() -> URL? {
        resolveCustomDirectory(forKey: Self.savedStagingPathKey)
    }

    public func saveCustomStagingDirectory(_ url: URL?) {
        if let url = url {
            let standardized = url.standardizedFileURL.path
            UserDefaults.standard.set(standardized, forKey: Self.savedStagingPathKey)
        } else {
            UserDefaults.standard.removeObject(forKey: Self.savedStagingPathKey)
        }
    }

    public func getCustomAppSupportDirectory() -> URL? {
        resolveCustomDirectory(forKey: Self.savedAppSupportPathKey)
    }

    public func saveCustomAppSupportDirectory(_ url: URL?) {
        if let url = url {
            let standardized = url.standardizedFileURL.path
            UserDefaults.standard.set(standardized, forKey: Self.savedAppSupportPathKey)
        } else {
            UserDefaults.standard.removeObject(forKey: Self.savedAppSupportPathKey)
        }
    }

    private func inferExternalWorkspaceRoot() -> URL? {
        let fm = FileManager.default
        let home = URL(fileURLWithPath: NSHomeDirectory()).standardizedFileURL.path
        let desktop = URL(fileURLWithPath: home).appendingPathComponent("Desktop").path
        let downloads = URL(fileURLWithPath: home).appendingPathComponent("Downloads").path
        let documents = URL(fileURLWithPath: home).appendingPathComponent("Documents").path

        let candidates: [(key: String, requireExternalOrWorkspace: Bool)] = [
            (Self.savedNxnativePathKey, false),
            (Self.savedStagingPathKey, false),
            ("NXNative_SavedLibraryFolder", true),
            ("NXNative_SavedCustomOutputFolder", true)
        ]

        for entry in candidates {
            guard let raw = UserDefaults.standard.string(forKey: entry.key)?
                .trimmingCharacters(in: .whitespacesAndNewlines), !raw.isEmpty else { continue }
            let url = URL(fileURLWithPath: raw, isDirectory: true).standardizedFileURL
            guard isParentVolumeMounted(for: url) else { continue }
            let parent = url.deletingLastPathComponent().standardizedFileURL
            let p = parent.path
            guard p != "/", p != "/Volumes", p != home,
                  !p.hasPrefix("/Applications"), !p.hasPrefix("/System") else {
                continue
            }
            if entry.requireExternalOrWorkspace {
                let isExternal = p.hasPrefix("/Volumes/")
                let hasWorkspaceSiblings = fm.fileExists(atPath: parent.appendingPathComponent("nxnative").path) ||
                                           fm.fileExists(atPath: parent.appendingPathComponent("Staging").path) ||
                                           fm.fileExists(atPath: parent.appendingPathComponent("NxNative_Data").path)
                guard isExternal || hasWorkspaceSiblings else { continue }
            } else {
                guard p != desktop && p != downloads && p != documents else { continue }
            }
            if fm.isWritableFile(atPath: p) {
                return parent
            }
        }
        return nil
    }

    /// Resolves the true workspace directory (custom workspace, inferred external drive workspace, folder containing NxNative_Launcher.app, or ~/NativePort fallback)
    public func resolveRootDirectory() -> URL {
        if let custom = getCustomWorkspaceDirectory() {
            return custom
        }

        let bundleURL = Bundle.main.bundleURL
        let bundleDir = bundleURL.deletingLastPathComponent()
        let fm = FileManager.default
        let bundlePath = bundleDir.path
        
        // Never treat /Applications or /System/Applications as the workspace or root data directory
        let isSystemAppDir = bundlePath == "/Applications" ||
                             bundlePath.hasPrefix("/Applications/") ||
                             bundlePath == "/System/Applications" ||
                             bundlePath.hasPrefix("/System/Applications/")
        
        if isSystemAppDir {
            if let inferred = inferExternalWorkspaceRoot() {
                return inferred
            }
            return URL(fileURLWithPath: NSHomeDirectory()).appendingPathComponent("NativePort", isDirectory: true)
        }
        
        if bundleURL.pathExtension.lowercased() == "app" && bundlePath != "/" {
            if fm.isWritableFile(atPath: bundlePath) ||
               fm.fileExists(atPath: bundleDir.appendingPathComponent("NxNative_Data").path) {
                return bundleDir
            }
            if let inferred = inferExternalWorkspaceRoot() {
                return inferred
            }
            return URL(fileURLWithPath: NSHomeDirectory()).appendingPathComponent("NativePort", isDirectory: true)
        }
        
        if fm.fileExists(atPath: bundleDir.appendingPathComponent("nxnative").path) ||
           fm.fileExists(atPath: bundleDir.appendingPathComponent("NxNative_Launcher.app").path) {
            return bundleDir
        }
        
        let ssdPath = URL(fileURLWithPath: "/Volumes/SSD FN501 PRO/Emulations/NativePort")
        if fm.fileExists(atPath: ssdPath.path) {
            return ssdPath
        }
        
        if bundlePath != "/" && !isSystemAppDir && !bundlePath.contains("/.build/") {
            return bundleDir
        }
        
        if let inferred = inferExternalWorkspaceRoot() {
            return inferred
        }
        return URL(fileURLWithPath: NSHomeDirectory()).appendingPathComponent("NativePort", isDirectory: true)
    }

    /// Canonical default application support directory (~/Library/Application Support/nxnative)
    public var defaultAppSupportDirectory: URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Application Support/nxnative", isDirectory: true)
    }

    /// Persistent application support directory (Defaults to standard macOS ~/Library/Application Support/nxnative for backups)
    public var appSupportDirectory: URL {
        if let custom = getCustomAppSupportDirectory() {
            try? FileManager.default.createDirectory(at: custom, withIntermediateDirectories: true)
            return custom
        }
        let standard = defaultAppSupportDirectory
        try? FileManager.default.createDirectory(at: standard, withIntermediateDirectories: true)
        return standard
    }

    /// Safely copies and migrates all existing game folders, saves, covers, and configs from source to target directory
    public func migrateAppSupportDirectoryContents(from sourceURL: URL, to targetURL: URL, completion: @escaping (Bool, String?) -> Void) {
        let sourceStandardized = sourceURL.standardizedFileURL
        let targetStandardized = targetURL.standardizedFileURL
        guard sourceStandardized.path != targetStandardized.path else {
            completion(true, nil)
            return
        }

        // If target is a subfolder of source (e.g. /Volumes/.../Library/nxnative inside /Volumes/.../Library)
        // or source is a subfolder of target:
        // They share the same filesystem hierarchy. Bypassing recursive duplicate copy to avoid infinite loops.
        if targetStandardized.path.hasPrefix(sourceStandardized.path + "/") ||
           sourceStandardized.path.hasPrefix(targetStandardized.path + "/") {
            NSLog("[Storage] Source and target are parent/child directories. Bypassing recursive duplicate copy.")
            DispatchQueue.main.async { completion(true, nil) }
            return
        }

        DispatchQueue.global(qos: .userInitiated).async {
            let fm = FileManager.default
            do {
                try fm.createDirectory(at: targetStandardized, withIntermediateDirectories: true)
                guard fm.fileExists(atPath: sourceStandardized.path) else {
                    DispatchQueue.main.async { completion(true, nil) }
                    return
                }

                let entries = (try? fm.contentsOfDirectory(at: sourceStandardized, includingPropertiesForKeys: nil, options: [.skipsHiddenFiles])) ?? []
                for entry in entries {
                    // Safety guard: NEVER copy target into itself
                    if entry.standardizedFileURL.path == targetStandardized.path ||
                       targetStandardized.path.hasPrefix(entry.standardizedFileURL.path + "/") {
                        continue
                    }
                    let dest = targetStandardized.appendingPathComponent(entry.lastPathComponent)
                    var isDir: ObjCBool = false
                    if fm.fileExists(atPath: entry.path, isDirectory: &isDir) {
                        if isDir.boolValue {
                            try? fm.createDirectory(at: dest, withIntermediateDirectories: true)
                            Self.recursiveCopyContents(from: entry, to: dest, fileManager: fm)
                        } else {
                            if fm.fileExists(atPath: dest.path) {
                                try? fm.removeItem(at: dest)
                            }
                            try fm.copyItem(at: entry, to: dest)
                        }
                    }
                }
                DispatchQueue.main.async {
                    completion(true, nil)
                }
            } catch {
                DispatchQueue.main.async {
                    completion(false, error.localizedDescription)
                }
            }
        }
    }

    private static func recursiveCopyContents(from src: URL, to dst: URL, fileManager fm: FileManager) {
        guard let items = try? fm.contentsOfDirectory(at: src, includingPropertiesForKeys: nil, options: []) else { return }
        for item in items {
            let destItem = dst.appendingPathComponent(item.lastPathComponent)
            var isDir: ObjCBool = false
            if fm.fileExists(atPath: item.path, isDirectory: &isDir) {
                if isDir.boolValue {
                    try? fm.createDirectory(at: destItem, withIntermediateDirectories: true)
                    recursiveCopyContents(from: item, to: destItem, fileManager: fm)
                } else {
                    if fm.fileExists(atPath: destItem.path) {
                        try? fm.removeItem(at: destItem)
                    }
                    try? fm.copyItem(at: item, to: destItem)
                }
            }
        }
    }

    /// Default Staging directory for port builds (never placed in /Applications)
    public var stagingDirectory: URL {
        if let custom = getCustomStagingDirectory() {
            try? FileManager.default.createDirectory(at: custom, withIntermediateDirectories: true)
            return custom
        }
        let dir = resolveRootDirectory().appendingPathComponent("Staging", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    /// Root storage folder located inside the safe workspace directory
    public var dataRootDirectory: URL {
        let dir = resolveRootDirectory().appendingPathComponent("NxNative_Data", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    /// Deployment & build cache directory located inside ~/Library/Caches/nxnative
    public var cachesDirectory: URL {
        let dir = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Caches/nxnative", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    /// Temporary working directory (TMPDIR) for port/compilation located inside the active Staging directory
    public var tempDirectory: URL {
        let dir = stagingDirectory.appendingPathComponent(".tmp", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    /// Runtime logs directory located inside ~/Library/Logs/nxnative
    public var logsDirectory: URL {
        let dir = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Logs/nxnative", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    /// Ensures standard macOS storage directories exist and safely unwraps any legacy symlink in ~/Library
    public func ensureStorageDirectoriesAndSymlinks() {
        let fm = FileManager.default
        let home = fm.homeDirectoryForCurrentUser
        let standardAppSupport = home.appendingPathComponent("Library/Application Support/nxnative")
        let standardCaches = home.appendingPathComponent("Library/Caches/nxnative")
        let standardLogs = home.appendingPathComponent("Library/Logs/nxnative")
        _ = tempDirectory
        _ = stagingDirectory

        // 1. If standardAppSupport is a symlink, unwrap it into a real folder and migrate existing saves
        if let dest = try? fm.destinationOfSymbolicLink(atPath: standardAppSupport.path) {
            let destURL = URL(fileURLWithPath: dest)
            let tempDir = fm.temporaryDirectory.appendingPathComponent("nxnative_appsupport_migration_\(UUID().uuidString)")
            if fm.fileExists(atPath: destURL.path) {
                try? fm.copyItem(at: destURL, to: tempDir)
            }
            try? fm.removeItem(at: standardAppSupport)
            try? fm.createDirectory(at: standardAppSupport, withIntermediateDirectories: true)
            if fm.fileExists(atPath: tempDir.path) {
                if let entries = try? fm.contentsOfDirectory(atPath: tempDir.path) {
                    for entry in entries {
                        let src = tempDir.appendingPathComponent(entry)
                        let dst = standardAppSupport.appendingPathComponent(entry)
                        if !fm.fileExists(atPath: dst.path) {
                            try? fm.moveItem(at: src, to: dst)
                        }
                    }
                }
                try? fm.removeItem(at: tempDir)
            }
        } else {
            try? fm.createDirectory(at: standardAppSupport, withIntermediateDirectories: true)
        }

        // 2. Ensure Caches and Logs are real directories in ~/Library (no broken symlinks)
        if (try? fm.destinationOfSymbolicLink(atPath: standardCaches.path)) != nil {
            try? fm.removeItem(at: standardCaches)
        }
        try? fm.createDirectory(at: standardCaches, withIntermediateDirectories: true)

        if (try? fm.destinationOfSymbolicLink(atPath: standardLogs.path)) != nil {
            try? fm.removeItem(at: standardLogs)
        }
        try? fm.createDirectory(at: standardLogs, withIntermediateDirectories: true)

        // 3. Clean up any empty NxNative_Data or Staging mistakenly left inside /Applications
        let appData = URL(fileURLWithPath: "/Applications/NxNative_Data")
        if (try? fm.contentsOfDirectory(atPath: appData.path))?.isEmpty == true {
            try? fm.removeItem(at: appData)
        }
        let appStaging = URL(fileURLWithPath: "/Applications/Staging")
        if (try? fm.contentsOfDirectory(atPath: appStaging.path))?.isEmpty == true {
            try? fm.removeItem(at: appStaging)
        }
    }
    
    /// Validates whether a directory is a usable nxnative Core repository root.
    public static func isValidNxnativeDirectory(_ path: String) -> Bool {
        guard !path.isEmpty else { return false }
        let fm = FileManager.default
        let baseURL = URL(fileURLWithPath: path)
        let scriptPath = baseURL.appendingPathComponent("scripts/build_ipa_from_nsp.py").path
        let dmPath = baseURL.appendingPathComponent("dm").path
        return fm.fileExists(atPath: scriptPath) && fm.fileExists(atPath: dmPath)
    }

    /// Persists or clears the user-selected Core repository directory.
    public func saveCustomNxnativeDirectory(_ path: String?) {
        if let path, !path.isEmpty {
            let standardized = URL(fileURLWithPath: path).standardized.path
            UserDefaults.standard.set(standardized, forKey: Self.savedNxnativePathKey)
        } else {
            UserDefaults.standard.removeObject(forKey: Self.savedNxnativePathKey)
        }
    }

    /// Returns the persisted custom Core repository directory if set.
    public var savedCustomNxnativeDirectory: String? {
        guard let saved = UserDefaults.standard.string(forKey: Self.savedNxnativePathKey)?
            .trimmingCharacters(in: .whitespacesAndNewlines),
              !saved.isEmpty else {
            return nil
        }
        return saved
    }

    /// Locates the nxnative repository directory (honoring explicit selection, then saved preference, then standard locations).
    public func detectNxnativeDirectory(customDir: String? = nil) -> NxNativeDetectionResult {
        if let custom = customDir?.trimmingCharacters(in: .whitespacesAndNewlines), !custom.isEmpty {
            let direct = URL(fileURLWithPath: custom).standardized.path
            let nested = URL(fileURLWithPath: direct).appendingPathComponent("nxnative").standardized.path
            for candidate in [direct, nested] {
                if Self.isValidNxnativeDirectory(candidate) {
                    return NxNativeDetectionResult(path: candidate, isValid: true)
                }
            }
            return NxNativeDetectionResult(path: direct, isValid: false)
        }

        let root = resolveRootDirectory()
        let bundleDir = Bundle.main.bundleURL.deletingLastPathComponent()

        var candidatePaths: [String] = []
        if let saved = savedCustomNxnativeDirectory {
            candidatePaths.append(saved)
            candidatePaths.append(URL(fileURLWithPath: saved).appendingPathComponent("nxnative").standardized.path)
        }
        candidatePaths.append(contentsOf: [
            root.appendingPathComponent("nxnative").standardized.path,
            bundleDir.appendingPathComponent("nxnative").standardized.path,
            root.standardized.path,
            Bundle.main.resourceURL?.appendingPathComponent("nxnative").path ?? ""
        ])

        var seen = Set<String>()
        for path in candidatePaths where !path.isEmpty && seen.insert(path).inserted {
            if Self.isValidNxnativeDirectory(path) {
                return NxNativeDetectionResult(path: path, isValid: true)
            }
        }

        let fallbackPath = savedCustomNxnativeDirectory ?? root.appendingPathComponent("nxnative").path
        return NxNativeDetectionResult(path: fallbackPath, isValid: false)
    }
    
    /// Clones the official nxnative_Launcher repository if missing and registers seedds/nxnative as upstream
    public func cloneNxnativeRepository(to destinationURL: URL, completion: @escaping (Bool, String) -> Void) {
        cloneNxnativeRepositoryWithProgress(to: destinationURL, onProgress: nil, completion: completion)
    }

    /// Clones the official nxnative_Launcher repository while streaming Git `--progress` fractions (`0.0 ... 1.0`).
    public func cloneNxnativeRepositoryWithProgress(
        to destinationURL: URL,
        onProgress: ((Double, String) -> Void)?,
        completion: @escaping (Bool, String) -> Void
    ) {
        DispatchQueue.global(qos: .userInitiated).async {
            let gitBin = BoundedProcess.gitPath()
            let fm = FileManager.default
            if fm.fileExists(atPath: destinationURL.path) &&
               !fm.fileExists(atPath: destinationURL.appendingPathComponent(".git").path) {
                try? fm.removeItem(at: destinationURL)
            }

            let cloneRes = BoundedProcess.runStreaming(
                gitBin,
                ["clone", "--progress", Self.officialRepoURL, destinationURL.path],
                timeout: 180.0
            ) { line in
                guard let onProgress else { return }
                let fraction = Self.parseGitCloneProgress(from: line)
                DispatchQueue.main.async {
                    onProgress(fraction, line)
                }
            }

            if cloneRes.success {
                _ = BoundedProcess.run(gitBin, ["remote", "add", "upstream", Self.upstreamRepoURL], cwd: destinationURL.path, timeout: 5.0)
                DispatchQueue.main.async {
                    onProgress?(1.0, "Repository ready")
                }
            }
            DispatchQueue.main.async {
                completion(cloneRes.success, cloneRes.output)
            }
        }
    }

    private static func parseGitCloneProgress(from line: String) -> Double {
        let lower = line.lowercased()
        guard let percentIdx = line.firstIndex(of: "%") else {
            if lower.contains("cloning into") { return 0.02 }
            if lower.contains("enumerating objects") { return 0.04 }
            if lower.contains("counting objects") { return 0.06 }
            return -1
        }
        let prefix = line[..<percentIdx]
        let digits = prefix.reversed().prefix(while: { $0.isNumber }).reversed()
        guard let pct = Int(String(digits)) else { return -1 }
        let norm = Double(min(max(pct, 0), 100)) / 100.0
        if lower.contains("receiving objects") {
            return 0.08 + norm * 0.72
        } else if lower.contains("resolving deltas") {
            return 0.80 + norm * 0.16
        } else if lower.contains("updating files") {
            return 0.96 + norm * 0.04
        }
        return -1
    }
    
    /// Auto-detects prod.keys from Ryujinx and Switch homebrew locations
    public func detectProdKeys(additionalSearchDir: String? = nil) -> ProdKeysDetectionResult? {
        var candidateLocations: [(path: String, name: String)] = [
            (NSString(string: "~/Library/Application Support/Ryujinx/system/prod.keys").expandingTildeInPath, "Ryujinx (App Support)"),
            (NSString(string: "~/Library/Application Support/ryujinx/system/prod.keys").expandingTildeInPath, "Ryujinx (App Support)"),
            (NSString(string: "~/Library/Application Support/Ryubing/system/prod.keys").expandingTildeInPath, "Ryubing (App Support)"),
            (NSString(string: "~/Library/Application Support/ryubing/system/prod.keys").expandingTildeInPath, "Ryubing (App Support)"),
            (NSString(string: "~/.config/Ryujinx/system/prod.keys").expandingTildeInPath, "Ryujinx Config"),
            (NSString(string: "~/.config/ryujinx/system/prod.keys").expandingTildeInPath, "Ryujinx Config"),
            (NSString(string: "~/.config/Ryubing/system/prod.keys").expandingTildeInPath, "Ryubing Config"),
            (NSString(string: "~/.config/ryubing/system/prod.keys").expandingTildeInPath, "Ryubing Config")
        ]
        
        let root = resolveRootDirectory()
        let siblingCandidates = [
            root.deletingLastPathComponent().appendingPathComponent("Riujinx/system/prod.keys").path,
            root.deletingLastPathComponent().appendingPathComponent("Riujinx/ProdKeys.Net-21.2.0/prod.keys").path,
            root.appendingPathComponent("Riujinx/system/prod.keys").path
        ]
        for p in siblingCandidates {
            candidateLocations.append((p, "Ryujinx Folder"))
        }
        
        if let customDir = additionalSearchDir, !customDir.isEmpty {
            let direct = URL(fileURLWithPath: customDir).appendingPathComponent("prod.keys").path
            let systemSub = URL(fileURLWithPath: customDir).appendingPathComponent("system/prod.keys").path
            candidateLocations.insert((direct, "Selected Directory"), at: 0)
            candidateLocations.insert((systemSub, "Selected Directory/system"), at: 0)
        }
        
        candidateLocations.append((NSString(string: "~/.switch/prod.keys").expandingTildeInPath, "Switch Homebrew"))
        
        let fileManager = FileManager.default
        for candidate in candidateLocations {
            var isDir: ObjCBool = false
            if fileManager.fileExists(atPath: candidate.path, isDirectory: &isDir) && !isDir.boolValue,
               let attrs = try? fileManager.attributesOfItem(atPath: candidate.path),
               let size = attrs[.size] as? Int64, size > 100 {
                return ProdKeysDetectionResult(path: candidate.path, sourceName: candidate.name, isValid: true)
            }
        }
        return nil
    }

    public func isRyujinxOrRyubingInstalled() -> Bool {
        let appPaths = [
            "/Applications/Ryujinx.app",
            "/Applications/Ryubing.app",
            NSString(string: "~/Applications/Ryujinx.app").expandingTildeInPath,
            NSString(string: "~/Applications/Ryubing.app").expandingTildeInPath,
            NSString(string: "~/Library/Application Support/Ryujinx").expandingTildeInPath,
            NSString(string: "~/Library/Application Support/ryujinx").expandingTildeInPath,
            NSString(string: "~/Library/Application Support/Ryubing").expandingTildeInPath,
            NSString(string: "~/Library/Application Support/ryubing").expandingTildeInPath
        ]
        let fm = FileManager.default
        for path in appPaths where fm.fileExists(atPath: path) {
            return true
        }
        return false
    }
    
    internal func runQuickCommand(_ cmd: String, args: [String]) -> (output: String, success: Bool) {
        return runQuickCommandWithTimeout(cmd, args: args, timeoutSeconds: 3.0)
    }
    
    internal func runQuickCommandWithTimeout(_ cmd: String, args: [String], timeoutSeconds: Double = 2.0) -> (output: String, success: Bool) {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: cmd)
        process.arguments = args
        
        var env = ProcessInfo.processInfo.environment
        let extraPaths = "/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin:/usr/sbin:/sbin"
        env["PATH"] = env["PATH"].map { "\(extraPaths):\($0)" } ?? extraPaths
        env["PYTHONDONTWRITEBYTECODE"] = "1"
        process.environment = env
        
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = Pipe()
        
        do {
            try process.run()
            let deadline = DispatchTime.now() + timeoutSeconds
            while process.isRunning && DispatchTime.now() < deadline {
                usleep(30_000) // 30ms polling
            }
            if process.isRunning {
                process.terminate()
                return ("", false)
            }
            let data = pipe.fileHandleForReading.readDataToEndOfFile()
            let str = String(data: data, encoding: .utf8) ?? ""
            return (str.trimmingCharacters(in: .whitespacesAndNewlines), process.terminationStatus == 0)
        } catch {
            return (error.localizedDescription, false)
        }
    }
}
