import AppKit
import CryptoKit
import Foundation

public struct LauncherInstallPlan: Equatable {
    public let runningBundlePath: String
    public let canonicalTarget: String
    public let duplicatePaths: [String]
    public let leftoverPaths: [String]
    public let isTranslocated: Bool
    public let requiresAdminElevation: Bool

    public var totalCleanupCount: Int {
        duplicatePaths.count + leftoverPaths.count
    }
}

public enum LauncherUpdaterError: LocalizedError {
    case invalidURL
    case httpError(Int)
    case downloadFailed(String)
    case checksumMismatch(expected: String, actual: String)
    case mountFailed(String)
    case appNotFoundInDmg
    case copyFailed(String)
    case invalidBundle(String)
    case signatureInvalid(String)
    case authorizationCanceled

    public var errorDescription: String? {
        switch self {
        case .invalidURL:
            return "Invalid release package URL."
        case .httpError(let code):
            return "GitLab download returned HTTP \(code)."
        case .downloadFailed(let reason):
            return "Download failed: \(reason)"
        case .checksumMismatch(let expected, let actual):
            return "SHA-256 integrity check failed (expected \(expected.prefix(12))..., got \(actual.prefix(12))...)."
        case .mountFailed(let detail):
            return "Failed to mount update disk image: \(detail)"
        case .appNotFoundInDmg:
            return "NxNative_Launcher.app was not found inside the downloaded DMG."
        case .copyFailed(let detail):
            return "Failed to stage application bundle: \(detail)"
        case .invalidBundle(let detail):
            return "Downloaded application bundle is invalid: \(detail)"
        case .signatureInvalid(let detail):
            return "Code signature verification failed: \(detail)"
        case .authorizationCanceled:
            return "Administrator authorization was canceled; running app was left untouched."
        }
    }
}

/// Manages verified DMG downloading, pre-swap integrity verification, single canonical `/Applications`
/// bundle consolidation (including App Translocation escape and duplicate `org.nxnative.launcher` cleanup),
/// and safe detached relaunch.
public final class LauncherSelfUpdater: NSObject, URLSessionDownloadDelegate {
    public static let shared = LauncherSelfUpdater()
    public static let canonicalBundleIdentifier = "org.nxnative.launcher"
    public static let canonicalAppFilename = "NxNative_Launcher.app"

    private let stateLock = NSLock()
    private var activeTask: URLSessionDownloadTask?
    private var progressCallback: ((Double, String) -> Void)?
    private var downloadCompletion: ((Result<URL, Error>) -> Void)?
    private var stagedVersion: String = ""
    private var _stagedAppPath: String? = nil

    public var stagedAppPath: String? {
        get {
            stateLock.lock()
            defer { stateLock.unlock() }
            return _stagedAppPath
        }
        set {
            stateLock.lock()
            _stagedAppPath = newValue
            stateLock.unlock()
        }
    }

    private lazy var downloadSession: URLSession = {
        let cfg = URLSessionConfiguration.default
        cfg.timeoutIntervalForRequest = 30
        cfg.timeoutIntervalForResource = 900
        return URLSession(configuration: cfg, delegate: self, delegateQueue: nil)
    }()

    private override init() {
        super.init()
    }

    // MARK: - Canonical Cache Paths

    public static var updatesCacheDirectory: URL {
        let caches = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask).first
            ?? URL(fileURLWithPath: NSTemporaryDirectory())
        let dir = caches.appendingPathComponent("\(canonicalBundleIdentifier)/Updates", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    public static var stagedAppDirectory: URL {
        updatesCacheDirectory.appendingPathComponent("Staged", isDirectory: true)
    }

    // MARK: - Canonical Target & Duplicate Discovery

    /// Resolves ONE canonical install destination and discovers all duplicate `org.nxnative.launcher`
    /// bundles and stray `.updating.*` / `.backup.*` remnants in Applications directories.
    public func resolveInstallPlan(
        runningBundleURL: URL = Bundle.main.bundleURL,
        nxnativePath: String = "",
        searchDirectories: [String]? = nil
    ) -> LauncherInstallPlan {
        let fm = FileManager.default
        let standardizedRunning = runningBundleURL.standardizedFileURL.path
        let systemAppsDir = "/Applications"
        let userAppsDir = fm.homeDirectoryForCurrentUser.appendingPathComponent("Applications").standardizedFileURL.path
        let systemCanonical = URL(fileURLWithPath: systemAppsDir).appendingPathComponent(Self.canonicalAppFilename).path
        let userCanonical = URL(fileURLWithPath: userAppsDir).appendingPathComponent(Self.canonicalAppFilename).path

        let isAppBundle = standardizedRunning.hasSuffix(".app")
        let isTranslocated = Self.isTranslocatedOrEphemeralApp(bundleURL: runningBundleURL)

        let canonicalTarget: String = {
            if Self.isInsideDirectory(standardizedRunning, directory: systemAppsDir) {
                return systemCanonical
            }
            if Self.isInsideDirectory(standardizedRunning, directory: userAppsDir) {
                return userCanonical
            }
            if !isAppBundle || isTranslocated {
                if !Self.canWriteOrCreate(targetBundlePath: systemCanonical, fileManager: fm),
                   fm.fileExists(atPath: userCanonical) {
                    return userCanonical
                }
                return systemCanonical
            }
            // Developer / portable workspace copy outside Applications (e.g. ~/NativePort/NxNative_Launcher.app)
            if !nxnativePath.isEmpty {
                let workspaceRoot = URL(fileURLWithPath: nxnativePath).deletingLastPathComponent().standardizedFileURL.path
                if Self.isInsideDirectory(standardizedRunning, directory: workspaceRoot) {
                    return standardizedRunning
                }
            }
            return systemCanonical
        }()

        let scanRoots = searchDirectories ?? [systemAppsDir, userAppsDir]
        let (duplicates, leftovers) = Self.findDuplicatesAndLeftovers(
            canonicalTarget: canonicalTarget,
            searchDirectories: scanRoots,
            fileManager: fm
        )

        let pathsRequiringWrite = [canonicalTarget] + duplicates + leftovers
        let needsAdmin = !pathsRequiringWrite.allSatisfy { Self.canWriteOrReplace(path: $0, fileManager: fm) }

        return LauncherInstallPlan(
            runningBundlePath: standardizedRunning,
            canonicalTarget: canonicalTarget,
            duplicatePaths: duplicates,
            leftoverPaths: leftovers,
            isTranslocated: isTranslocated,
            requiresAdminElevation: needsAdmin
        )
    }

    public static func isTranslocatedOrEphemeralApp(bundleURL: URL) -> Bool {
        let path = bundleURL.standardizedFileURL.path
        if path.contains("/AppTranslocation/") { return true }
        if path.hasPrefix("/private/tmp/") || path.hasPrefix("/tmp/") || path.hasPrefix("/private/var/folders/") {
            return true
        }
        let downloadsDir = FileManager.default.urls(for: .downloadsDirectory, in: .userDomainMask).first?.standardizedFileURL.path ?? ""
        if !downloadsDir.isEmpty && isInsideDirectory(path, directory: downloadsDir) {
            return true
        }
        if let values = try? bundleURL.resourceValues(forKeys: [.volumeIsReadOnlyKey]),
           values.volumeIsReadOnly == true {
            return true
        }
        if path.hasPrefix("/Volumes/NxNative") {
            return true
        }
        return false
    }

    private static func isInsideDirectory(_ path: String, directory: String) -> Bool {
        let normDir = directory.hasSuffix("/") ? directory : directory + "/"
        return path.hasPrefix(normDir)
    }

    public static func canWriteOrCreate(targetBundlePath: String, fileManager: FileManager = .default) -> Bool {
        if fileManager.fileExists(atPath: targetBundlePath) {
            return canWriteOrReplace(path: targetBundlePath, fileManager: fileManager)
        }
        let parent = URL(fileURLWithPath: targetBundlePath).deletingLastPathComponent().path
        return fileManager.isWritableFile(atPath: parent)
    }

    public static func canWriteOrReplace(path: String, fileManager: FileManager = .default) -> Bool {
        let parent = URL(fileURLWithPath: path).deletingLastPathComponent().path
        guard fileManager.fileExists(atPath: parent) else {
            let grandParent = URL(fileURLWithPath: parent).deletingLastPathComponent().path
            return fileManager.isWritableFile(atPath: grandParent)
        }
        guard fileManager.isWritableFile(atPath: parent) else { return false }
        if fileManager.fileExists(atPath: path) {
            guard fileManager.isWritableFile(atPath: path) else { return false }
            let contentsDir = URL(fileURLWithPath: path).appendingPathComponent("Contents").path
            if fileManager.fileExists(atPath: contentsDir), !fileManager.isWritableFile(atPath: contentsDir) {
                return false
            }
            let execFile = URL(fileURLWithPath: path).appendingPathComponent("Contents/MacOS/NXNativeGUI").path
            if fileManager.fileExists(atPath: execFile), !fileManager.isWritableFile(atPath: execFile) {
                return false
            }
        }
        return true
    }

    public static func findDuplicatesAndLeftovers(
        canonicalTarget: String,
        searchDirectories: [String],
        fileManager: FileManager = .default
    ) -> (duplicates: [String], leftovers: [String]) {
        let normCanonical = URL(fileURLWithPath: canonicalTarget).standardizedFileURL.path
        var duplicates: [String] = []
        var leftovers: [String] = []
        var seen = Set<String>()

        for dir in searchDirectories {
            guard let items = try? fileManager.contentsOfDirectory(atPath: dir) else { continue }
            for name in items {
                let fullPath = URL(fileURLWithPath: dir).appendingPathComponent(name).standardizedFileURL.path
                if fullPath == normCanonical || seen.contains(fullPath) { continue }

                let lower = name.lowercased()
                if (lower.hasPrefix("nxnative_launcher") || lower.hasPrefix("nxnative launcher")) &&
                    (lower.contains(".app.updating") || lower.contains(".app.backup")) {
                    seen.insert(fullPath)
                    leftovers.append(fullPath)
                    continue
                }

                guard lower.hasSuffix(".app") else { continue }
                let infoPlistPath = URL(fileURLWithPath: fullPath).appendingPathComponent("Contents/Info.plist").path
                if let dict = NSDictionary(contentsOfFile: infoPlistPath),
                   let bid = dict["CFBundleIdentifier"] as? String,
                   bid == canonicalBundleIdentifier {
                    seen.insert(fullPath)
                    duplicates.append(fullPath)
                }
            }
        }

        return (duplicates.sorted(), leftovers.sorted())
    }

    // MARK: - Download, Verify & Stage

    public func downloadVerifyAndStage(
        version: String,
        dmgURLString: String?,
        sha256URLString: String?,
        token: String?,
        progress: @escaping (Double, String) -> Void,
        log: @escaping (String) -> Void,
        completion: @escaping (Result<String, Error>) -> Void
    ) {
        let cleanVer = version.trimmingCharacters(in: CharacterSet(charactersIn: "vV"))
        let fallbackURL = "https://gitlab.com/api/v4/projects/88419597/packages/generic/nxnative-launcher/\(cleanVer)/NxNative_Launcher.dmg"
        let resolvedURLStr = (dmgURLString?.isEmpty == false) ? dmgURLString! : fallbackURL
        guard let downloadURL = URL(string: resolvedURLStr) else {
            DispatchQueue.main.async { completion(.failure(LauncherUpdaterError.invalidURL)) }
            return
        }

        log("==> Downloading official DMG update from GitLab (v\(cleanVer))...")
        log("    URL: \(resolvedURLStr)")
        DispatchQueue.main.async { progress(0.05, "Downloading update package...") }

        stateLock.lock()
        activeTask?.cancel()
        stagedVersion = cleanVer
        progressCallback = progress
        downloadCompletion = { [weak self] dlResult in
            guard let self = self else { return }
            switch dlResult {
            case .failure(let err):
                completion(.failure(err))
            case .success(let cachedDmgURL):
                self.verifyMountAndStage(
                    dmgURL: cachedDmgURL,
                    version: cleanVer,
                    sha256URLString: sha256URLString,
                    token: token,
                    progress: progress,
                    log: log,
                    completion: completion
                )
            }
        }
        var request = URLRequest(url: downloadURL)
        if let token = token, !token.isEmpty {
            request.addValue(token, forHTTPHeaderField: "PRIVATE-TOKEN")
        }
        let task = downloadSession.downloadTask(with: request)
        activeTask = task
        stateLock.unlock()

        task.resume()
    }

    // MARK: URLSessionDownloadDelegate

    public func urlSession(
        _ session: URLSession,
        downloadTask: URLSessionDownloadTask,
        didWriteData bytesWritten: Int64,
        totalBytesWritten: Int64,
        totalBytesExpectedToWrite: Int64
    ) {
        stateLock.lock()
        let cb = progressCallback
        stateLock.unlock()

        if totalBytesExpectedToWrite > 0 {
            let rawFrac = Double(totalBytesWritten) / Double(totalBytesExpectedToWrite)
            let uiFrac = 0.05 + min(1.0, max(0.0, rawFrac)) * 0.70
            let mbDone = Double(totalBytesWritten) / (1024 * 1024)
            let mbTotal = Double(totalBytesExpectedToWrite) / (1024 * 1024)
            let label = String(format: "Downloading update package (%.1f / %.1f MB)...", mbDone, mbTotal)
            DispatchQueue.main.async { cb?(uiFrac, label) }
        } else {
            let mbDone = Double(totalBytesWritten) / (1024 * 1024)
            let label = String(format: "Downloading update package (%.1f MB)...", mbDone)
            DispatchQueue.main.async { cb?(0.30, label) }
        }
    }

    public func urlSession(
        _ session: URLSession,
        downloadTask: URLSessionDownloadTask,
        didFinishDownloadingTo location: URL
    ) {
        if let http = downloadTask.response as? HTTPURLResponse, http.statusCode != 200 {
            finishDownload(.failure(LauncherUpdaterError.httpError(http.statusCode)))
            return
        }

        let fm = FileManager.default
        let cacheDir = Self.updatesCacheDirectory
        stateLock.lock()
        let ver = stagedVersion.isEmpty ? "latest" : stagedVersion
        stateLock.unlock()

        let destDmg = cacheDir.appendingPathComponent("NxNative_Launcher_\(ver).dmg")
        try? fm.removeItem(at: destDmg)
        do {
            try fm.moveItem(at: location, to: destDmg)
            finishDownload(.success(destDmg))
        } catch {
            do {
                try fm.copyItem(at: location, to: destDmg)
                finishDownload(.success(destDmg))
            } catch {
                finishDownload(.failure(LauncherUpdaterError.copyFailed(error.localizedDescription)))
            }
        }
    }

    public func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        guard let error = error else { return }
        finishDownload(.failure(LauncherUpdaterError.downloadFailed(error.localizedDescription)))
    }

    private func finishDownload(_ result: Result<URL, Error>) {
        stateLock.lock()
        let cb = downloadCompletion
        downloadCompletion = nil
        progressCallback = nil
        activeTask = nil
        stateLock.unlock()
        cb?(result)
    }

    // MARK: Pre-Swap Verification & Staging

    private func verifyMountAndStage(
        dmgURL: URL,
        version: String,
        sha256URLString: String?,
        token: String?,
        progress: @escaping (Double, String) -> Void,
        log: @escaping (String) -> Void,
        completion: @escaping (Result<String, Error>) -> Void
    ) {
        DispatchQueue.main.async { progress(0.77, "Verifying package checksum (SHA-256)...") }

        GitLabReleaseNotesService.shared.fetchExpectedSHA256(for: version, sha256URL: sha256URLString, token: token) { [weak self] expectedDigest in
            guard let self = self else { return }
            DispatchQueue.global(qos: .userInitiated).async {
                let fm = FileManager.default

                if let expected = expectedDigest {
                    do {
                        let actual = try Self.computeSHA256(fileURL: dmgURL)
                        if actual.lowercased() != expected.lowercased() {
                            try? fm.removeItem(at: dmgURL)
                            completion(.failure(LauncherUpdaterError.checksumMismatch(expected: expected, actual: actual)))
                            return
                        }
                        log("==> SHA-256 verified: \(actual.prefix(16))...")
                    } catch {
                        try? fm.removeItem(at: dmgURL)
                        completion(.failure(error))
                        return
                    }
                } else {
                    log("==> SHA-256 digest unavailable for v\(version); continuing with codesign verification...")
                }

                DispatchQueue.main.async { progress(0.84, "Mounting update disk image...") }
                log("==> Mounting disk image...")
                let mountRes = BoundedProcess.run("/usr/bin/hdiutil", ["attach", dmgURL.path, "-nobrowse", "-readonly", "-plist"], timeout: 25.0)
                guard mountRes.success else {
                    try? fm.removeItem(at: dmgURL)
                    completion(.failure(LauncherUpdaterError.mountFailed(mountRes.output)))
                    return
                }

                var mountedAppURL: URL? = nil
                var mountPoint: String? = nil
                if let mountData = mountRes.data,
                   let plist = try? PropertyListSerialization.propertyList(from: mountData, options: [], format: nil) as? [String: Any],
                   let entities = plist["system-entities"] as? [[String: Any]] {
                    for entity in entities {
                        if let mp = entity["mount-point"] as? String {
                            mountPoint = mp
                            let candidate = URL(fileURLWithPath: mp).appendingPathComponent(Self.canonicalAppFilename)
                            if fm.fileExists(atPath: candidate.path) {
                                mountedAppURL = candidate
                                break
                            }
                        }
                    }
                }
                if mountedAppURL == nil {
                    for fallback in ["/Volumes/NxNative_Launcher", "/Volumes/NxNative Launcher"] {
                        let candidate = URL(fileURLWithPath: fallback).appendingPathComponent(Self.canonicalAppFilename)
                        if fm.fileExists(atPath: candidate.path) {
                            mountPoint = mountPoint ?? fallback
                            mountedAppURL = candidate
                            break
                        }
                    }
                }

                defer {
                    if let mp = mountPoint {
                        _ = BoundedProcess.run("/usr/bin/hdiutil", ["detach", mp, "-force"], timeout: 10.0)
                    }
                    try? fm.removeItem(at: dmgURL)
                }

                guard let validMountedApp = mountedAppURL else {
                    completion(.failure(LauncherUpdaterError.appNotFoundInDmg))
                    return
                }

                DispatchQueue.main.async { progress(0.90, "Staging & validating bundle...") }
                let stagedRoot = Self.stagedAppDirectory
                let stagedApp = stagedRoot.appendingPathComponent(Self.canonicalAppFilename)
                try? fm.removeItem(at: stagedRoot)
                try? fm.createDirectory(at: stagedRoot, withIntermediateDirectories: true)

                let dittoRes = BoundedProcess.run("/usr/bin/ditto", [validMountedApp.path, stagedApp.path], timeout: 30.0)
                if !dittoRes.success {
                    try? fm.removeItem(at: stagedApp)
                    let cpRes = BoundedProcess.run("/bin/cp", ["-Rf", validMountedApp.path, stagedApp.path], timeout: 30.0)
                    guard cpRes.success else {
                        completion(.failure(LauncherUpdaterError.copyFailed(dittoRes.output)))
                        return
                    }
                }

                _ = BoundedProcess.run("/usr/bin/xattr", ["-dr", "com.apple.quarantine", stagedApp.path], timeout: 10.0)

                // Verify bundle identifier, executable presence, and strict code signature
                let infoPlistPath = stagedApp.appendingPathComponent("Contents/Info.plist").path
                guard let infoDict = NSDictionary(contentsOfFile: infoPlistPath),
                      let bid = infoDict["CFBundleIdentifier"] as? String,
                      bid == Self.canonicalBundleIdentifier else {
                    try? fm.removeItem(at: stagedApp)
                    completion(.failure(LauncherUpdaterError.invalidBundle("Unexpected CFBundleIdentifier.")))
                    return
                }
                let execName = (infoDict["CFBundleExecutable"] as? String) ?? "NXNativeGUI"
                let execPath = stagedApp.appendingPathComponent("Contents/MacOS/\(execName)").path
                guard fm.isExecutableFile(atPath: execPath) else {
                    try? fm.removeItem(at: stagedApp)
                    completion(.failure(LauncherUpdaterError.invalidBundle("Missing executable at Contents/MacOS/\(execName).")))
                    return
                }

                DispatchQueue.main.async { progress(0.96, "Verifying code signature...") }
                let signRes = BoundedProcess.run("/usr/bin/codesign", ["--verify", "--deep", "--strict", stagedApp.path], timeout: 20.0)
                if !signRes.success {
                    try? fm.removeItem(at: stagedApp)
                    completion(.failure(LauncherUpdaterError.signatureInvalid(signRes.output)))
                    return
                }

                self.stagedAppPath = stagedApp.path
                log("==> Verified & staged update bundle cleanly at \(stagedApp.path)")
                completion(.success(stagedApp.path))
            }
        }
    }

    public static func computeSHA256(fileURL: URL) throws -> String {
        let handle = try FileHandle(forReadingFrom: fileURL)
        defer { try? handle.close() }
        var hasher = SHA256()
        while autoreleasepool(invoking: {
            let chunk = handle.readData(ofLength: 1024 * 1024)
            if chunk.isEmpty { return false }
            hasher.update(data: chunk)
            return true
        }) {}
        let digest = hasher.finalize()
        return digest.map { String(format: "%02x", $0) }.joined()
    }

    // MARK: - Option 1 Atomic Install & Relaunch

    public func installAndRelaunch(
        nxnativePath: String,
        sourceAppPath: String? = nil,
        onErrorBeforeExit: ((String) -> Void)? = nil
    ) {
        let fm = FileManager.default
        let sourceApp: String = {
            if let custom = sourceAppPath, !custom.isEmpty, fm.fileExists(atPath: custom) { return custom }
            if let staged = stagedAppPath, !staged.isEmpty, fm.fileExists(atPath: staged) { return staged }
            let fallbackStaged = Self.stagedAppDirectory.appendingPathComponent(Self.canonicalAppFilename).path
            if fm.fileExists(atPath: fallbackStaged) { return fallbackStaged }
            if !nxnativePath.isEmpty {
                let workspaceApp = URL(fileURLWithPath: nxnativePath).deletingLastPathComponent().appendingPathComponent(Self.canonicalAppFilename).path
                if fm.fileExists(atPath: workspaceApp) { return workspaceApp }
            }
            return Bundle.main.bundleURL.standardizedFileURL.path
        }()

        let plan = resolveInstallPlan(runningBundleURL: Bundle.main.bundleURL, nxnativePath: nxnativePath)
        let pid = ProcessInfo.processInfo.processIdentifier
        let logDir = fm.homeDirectoryForCurrentUser.appendingPathComponent("Library/Logs/nxnative").path
        try? fm.createDirectory(atPath: logDir, withIntermediateDirectories: true)
        let logFile = URL(fileURLWithPath: logDir).appendingPathComponent("updater.log").path

        let targetApp = plan.canonicalTarget
        let targetIsSameAsSource = URL(fileURLWithPath: targetApp).standardizedFileURL.path == URL(fileURLWithPath: sourceApp).standardizedFileURL.path
        let shouldCleanStagedRoot = sourceApp.hasPrefix(Self.updatesCacheDirectory.standardizedFileURL.path)

        let swapCore = buildSwapShellCommands(
            sourceApp: sourceApp,
            canonicalTarget: targetApp,
            duplicates: plan.duplicatePaths,
            leftovers: plan.leftoverPaths,
            logFile: logFile,
            trashDir: fm.homeDirectoryForCurrentUser.appendingPathComponent(".Trash").path,
            skipReplaceWhenSame: targetIsSameAsSource
        )

        // Option 1: Whenever /Applications (and existing bundle/duplicates) is writable by the current user,
        // perform silent atomic replacement with zero prompts.
        if !plan.requiresAdminElevation {
            launchDetachedUpdaterScript(
                pid: pid,
                swapCommands: swapCore,
                canonicalTarget: targetApp,
                cleanupStagedDir: shouldCleanStagedRoot ? Self.stagedAppDirectory.path : nil,
                logFile: logFile
            )
            terminateForRelaunch()
            return
        }

        // Fallback when /Applications requires administrator authorization:
        // Execute swap via macOS auth prompt BEFORE quitting so canceling leaves the current app safe.
        DispatchQueue.global(qos: .userInitiated).async {
            let elevatedRes = self.runElevatedInstallScript(swapCore)
            if elevatedRes.success {
                if shouldCleanStagedRoot {
                    try? fm.removeItem(atPath: Self.stagedAppDirectory.path)
                }
                _ = BoundedProcess.run("/usr/bin/open", [targetApp], timeout: 10.0)
                self.terminateForRelaunch()
            } else {
                // If user canceled elevation and running outside /Applications wasn't possible, fall back or notify
                let userMsg = elevatedRes.output.localizedCaseInsensitiveContains("User canceled")
                    ? LauncherUpdaterError.authorizationCanceled.localizedDescription
                    : "Failed to replace \(targetApp): \(elevatedRes.output)"
                DispatchQueue.main.async {
                    onErrorBeforeExit?(userMsg)
                }
            }
        }
    }

    private func buildSwapShellCommands(
        sourceApp: String,
        canonicalTarget: String,
        duplicates: [String],
        leftovers: [String],
        logFile: String,
        trashDir: String,
        skipReplaceWhenSame: Bool
    ) -> String {
        let esc: (String) -> String = { "'" + $0.replacingOccurrences(of: "'", with: "'\\''") + "'" }
        let lsregister = "/System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister"

        var lines: [String] = []
        lines.append("TRASH_DIR=\(esc(trashDir))")
        lines.append("LSREG=\(esc(lsregister))")
        lines.append("LOG=\(esc(logFile))")
        lines.append("mkdir -p \"$(dirname \(esc(canonicalTarget)))\" 2>/dev/null || true")
        lines.append("""
        trash_or_remove() {
          target="$1"
          [ -e "$target" ] || return 0
          [ -x "$LSREG" ] && "$LSREG" -u "$target" >/dev/null 2>&1 || true
          base="$(basename "$target" .app)"
          trash_dst="$TRASH_DIR/${base}_$(date +%Y%m%d_%H%M%S)_$$.app"
          if [ -d "$TRASH_DIR" ] && mv "$target" "$trash_dst" 2>>"$LOG"; then
            echo "[updater] Moved old bundle to Trash: $target" >>"$LOG"
            return 0
          fi
          rm -rf "$target" 2>>"$LOG" && echo "[updater] Removed old bundle: $target" >>"$LOG" && return 0
          return 1
        }
        """)

        for left in leftovers {
            lines.append("rm -rf \(esc(left)) 2>>\"$LOG\" || true")
        }
        for dup in duplicates {
            lines.append("trash_or_remove \(esc(dup)) || true")
        }

        if !skipReplaceWhenSame {
            let targetDir = URL(fileURLWithPath: canonicalTarget).deletingLastPathComponent().path
            lines.append("STAGED_TMP=\"\(targetDir)/.nxnative_install_tmp_$$.app\"")
            lines.append("rm -rf \"$STAGED_TMP\" 2>/dev/null || true")
            lines.append("""
            if /usr/bin/ditto \(esc(sourceApp)) "$STAGED_TMP" 2>>"$LOG" || /bin/cp -Rf \(esc(sourceApp)) "$STAGED_TMP" 2>>"$LOG"; then
              /usr/bin/xattr -dr com.apple.quarantine "$STAGED_TMP" 2>/dev/null || true
              if [ -e \(esc(canonicalTarget)) ]; then
                trash_or_remove \(esc(canonicalTarget)) || true
              fi
              if [ ! -e \(esc(canonicalTarget)) ] && mv "$STAGED_TMP" \(esc(canonicalTarget)) 2>>"$LOG"; then
                echo "[updater] Installed canonical bundle at \(canonicalTarget)" >>"$LOG"
              else
                echo "[updater] Failed to replace canonical target (still exists or move failed) at \(canonicalTarget)" >>"$LOG"
                rm -rf "$STAGED_TMP" 2>/dev/null || true
              fi
            else
              echo "[updater] Failed to copy source bundle \(sourceApp)" >>"$LOG"
              rm -rf "$STAGED_TMP" 2>/dev/null || true
            fi
            """)
        }
        lines.append("[ -x \"$LSREG\" ] && \"$LSREG\" -f \(esc(canonicalTarget)) >/dev/null 2>&1 || true")
        return lines.joined(separator: "\n")
    }

    private func launchDetachedUpdaterScript(
        pid: Int32,
        swapCommands: String,
        canonicalTarget: String,
        cleanupStagedDir: String?,
        logFile: String
    ) {
        let esc: (String) -> String = { "'" + $0.replacingOccurrences(of: "'", with: "'\\''") + "'" }
        let helperPath = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("nxnative_relaunch_\(pid).sh").path
        let cleanupLine = cleanupStagedDir.map { "rm -rf \(esc($0)) 2>/dev/null || true" } ?? ""

        let script = """
        #!/bin/sh
        echo "[updater] Waiting for PID \(pid) to exit..." >>\(esc(logFile))
        waited=0
        while kill -0 \(pid) 2>/dev/null; do
          sleep 0.1
          waited=$((waited + 1))
          if [ "$waited" -ge 100 ]; then
            echo "[updater] PID \(pid) still alive after 10s; sending SIGKILL" >>\(esc(logFile))
            kill -9 \(pid) 2>/dev/null || true
            sleep 0.2
            break
          fi
        done
        \(swapCommands)
        \(cleanupLine)
        sleep 0.25
        echo "[updater] Launching canonical app: \(canonicalTarget)" >>\(esc(logFile))
        /usr/bin/open \(esc(canonicalTarget)) >>\(esc(logFile)) 2>&1 || /usr/bin/open -a \(esc(canonicalTarget)) >>\(esc(logFile)) 2>&1
        rm -f \(esc(helperPath)) 2>/dev/null || true
        """
        try? script.write(toFile: helperPath, atomically: true, encoding: .utf8)
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/sh")
        process.arguments = ["-c", "nohup /bin/sh \(esc(helperPath)) </dev/null >>\(esc(logFile)) 2>&1 &"]
        process.standardInput = FileHandle.nullDevice
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        try? process.run()
    }

    private func runElevatedInstallScript(_ swapCommands: String) -> BoundedProcess.Result {
        let tmpScript = FileManager.default.temporaryDirectory.appendingPathComponent("nxnative_admin_install_\(UUID().uuidString).sh")
        let full = "#!/bin/sh\nset -e\n\(swapCommands)\n"
        try? full.write(to: tmpScript, atomically: true, encoding: .utf8)
        _ = BoundedProcess.run("/bin/chmod", ["+x", tmpScript.path], timeout: 5.0)
        defer { try? FileManager.default.removeItem(at: tmpScript) }

        let escapedPath = tmpScript.path.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "\"", with: "\\\"")
        let appleScript = "do shell script \"/bin/sh \\\"\(escapedPath)\\\"\" with administrator privileges"
        return BoundedProcess.run("/usr/bin/osascript", ["-e", appleScript], timeout: 120.0)
    }

    private func terminateForRelaunch() {
        DispatchQueue.main.async {
            for window in NSApplication.shared.windows {
                for sheet in window.sheets {
                    window.endSheet(sheet)
                }
                if let attached = window.attachedSheet {
                    window.endSheet(attached)
                }
            }
            if NSApplication.shared.modalWindow != nil {
                NSApplication.shared.abortModal()
            }
            NSApplication.shared.terminate(nil)
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.8) {
                exit(0)
            }
        }
    }
}
