import Foundation

/// Silent, bounded, best-effort auto-updater for the `shirai91/nx2android` engine (`tools/nx2android`
/// or `~/Library/Application Support/nx2android`), invoked only when Android support is installed.
public final class Nx2AndroidAutoUpdater {
    public static let shared = Nx2AndroidAutoUpdater()

    private static let repoURL = "https://github.com/shirai91/nx2android.git"
    private static let archiveURL = "https://github.com/shirai91/nx2android/archive/refs/heads/main.tar.gz"
    private static let apiCommitURL = "https://api.github.com/repos/shirai91/nx2android/commits/main"
    private static let syncShaFile = ".nx2a_sync_sha"
    private static let successCooldown: TimeInterval = 1800
    private static let rateLimitCooldown: TimeInterval = 3600

    private let stateLock = NSLock()
    private var consecutiveFailures = 0
    private var nextAllowed = Date.distantPast

    private init() {}

    public var isInBackoff: Bool {
        stateLock.lock()
        defer { stateLock.unlock() }
        return Date() < nextAllowed
    }

    public static func userAppSupportNx2AndroidPath() -> String {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Application Support/nx2android", isDirectory: true)
            .path
    }

    public static func hasLocalInstall(nxnativePath: String) -> Bool {
        let fm = FileManager.default
        if !nxnativePath.isEmpty {
            let repoToolsPorter = URL(fileURLWithPath: nxnativePath)
                .appendingPathComponent("tools/nx2android/porter").path
            if fm.fileExists(atPath: repoToolsPorter) {
                return true
            }
        }
        let userPorter = URL(fileURLWithPath: userAppSupportNx2AndroidPath())
            .appendingPathComponent("porter").path
        return fm.fileExists(atPath: userPorter)
    }

    public static func resolveTargetDirectory(nxnativePath: String) -> String {
        let fm = FileManager.default
        if !nxnativePath.isEmpty {
            let repoToolsDir = URL(fileURLWithPath: nxnativePath)
                .appendingPathComponent("tools/nx2android", isDirectory: true).path
            if fm.fileExists(atPath: repoToolsDir + "/porter") {
                return repoToolsDir
            }
        }
        let userDir = userAppSupportNx2AndroidPath()
        if fm.fileExists(atPath: userDir + "/porter") {
            return userDir
        }
        if !nxnativePath.isEmpty, fm.isWritableFile(atPath: nxnativePath) {
            return URL(fileURLWithPath: nxnativePath)
                .appendingPathComponent("tools/nx2android", isDirectory: true).path
        }
        return userDir
    }

    /// Blocking: call from a background queue only.
    public func updateIfNeeded(nxnativePath: String) -> CoreRepoUpdateResult {
        if isInBackoff { return .skipped("cooldown") }

        let targetDir = Self.resolveTargetDirectory(nxnativePath: nxnativePath)
        let fm = FileManager.default
        let git = BoundedProcess.gitPath()
        let extraEnv = buildGitEnvironment()

        // Case 1: targetDir is a git clone -> fast-forward via git fetch + merge
        if fm.fileExists(atPath: targetDir + "/.git") {
            return updateViaGitClone(targetDir: targetDir, git: git, extraEnv: extraEnv)
        }

        // Case 2: targetDir does not exist yet -> shallow git clone if git is available, else tarball
        if !fm.fileExists(atPath: targetDir + "/porter") {
            return installFresh(targetDir: targetDir, git: git, extraEnv: extraEnv)
        }

        // Case 3: targetDir exists as a non-git directory (e.g. bundled tools/nx2android) -> SHA check + tarball sync
        return updateNonGitDirectory(targetDir: targetDir, git: git, extraEnv: extraEnv)
    }

    private func updateViaGitClone(targetDir: String, git: String, extraEnv: [String: String]) -> CoreRepoUpdateResult {
        let branch = BoundedProcess.run(git, ["rev-parse", "--abbrev-ref", "HEAD"], cwd: targetDir, extraEnv: extraEnv, timeout: 5)
            .output.trimmingCharacters(in: .whitespacesAndNewlines)
        guard branch == "main" else { return .skipped("branch '\(branch)' is not main") }

        let fetched = BoundedProcess.run(
            git,
            ["fetch", "--quiet", "--tags", "--force", "origin", "+refs/heads/main:refs/remotes/origin/main"],
            cwd: targetDir,
            extraEnv: extraEnv,
            timeout: 60
        )
        guard fetched.success else {
            registerFailure(rateLimited: isRateLimitError(fetched.output))
            return .failed(fetched.timedOut ? "fetch timed out" : fetched.output)
        }

        registerSuccess()

        let behind = Int(
            BoundedProcess.run(git, ["rev-list", "--count", "HEAD..origin/main"], cwd: targetDir, extraEnv: extraEnv, timeout: 5)
                .output.trimmingCharacters(in: .whitespacesAndNewlines)
        ) ?? 0
        if behind == 0 { return .upToDate }

        let ahead = Int(
            BoundedProcess.run(git, ["rev-list", "--count", "origin/main..HEAD"], cwd: targetDir, extraEnv: extraEnv, timeout: 5)
                .output.trimmingCharacters(in: .whitespacesAndNewlines)
        ) ?? 0
        if ahead > 0 { return .skipped("local commits ahead of remote") }

        let merge = BoundedProcess.run(git, ["merge", "--ff-only", "origin/main"], cwd: targetDir, extraEnv: extraEnv, timeout: 60)
        guard merge.success else { return .skipped("fast-forward blocked by local changes") }

        let head = BoundedProcess.run(git, ["rev-parse", "--short", "HEAD"], cwd: targetDir, extraEnv: extraEnv, timeout: 5)
            .output.trimmingCharacters(in: .whitespacesAndNewlines)
        return .updated(head)
    }

    private func installFresh(targetDir: String, git: String, extraEnv: [String: String]) -> CoreRepoUpdateResult {
        let fm = FileManager.default
        let parentDir = URL(fileURLWithPath: targetDir).deletingLastPathComponent().path
        try? fm.createDirectory(atPath: parentDir, withIntermediateDirectories: true)

        // If targetDir exists (e.g. contains `toolchains/`) without `porter/`, sync tarball to preserve `toolchains/`
        if fm.fileExists(atPath: targetDir) {
            return updateNonGitDirectory(targetDir: targetDir, git: git, extraEnv: extraEnv)
        }

        if fm.isExecutableFile(atPath: git) {
            let clone = BoundedProcess.run(
                git,
                ["clone", "--depth", "1", "--branch", "main", Self.repoURL, targetDir],
                extraEnv: extraEnv,
                timeout: 180
            )
            if clone.success {
                registerSuccess()
                let head = BoundedProcess.run(git, ["rev-parse", "--short", "HEAD"], cwd: targetDir, extraEnv: extraEnv, timeout: 5)
                    .output.trimmingCharacters(in: .whitespacesAndNewlines)
                return .updated(head.isEmpty ? "main" : head)
            }
            try? fm.removeItem(atPath: targetDir)
            if isRateLimitError(clone.output) {
                registerFailure(rateLimited: true)
                return .failed(clone.output)
            }
        }

        return updateNonGitDirectory(targetDir: targetDir, git: git, extraEnv: extraEnv)
    }

    private func updateNonGitDirectory(targetDir: String, git: String, extraEnv: [String: String]) -> CoreRepoUpdateResult {
        guard let remoteSha = fetchRemoteMainSha(git: git, extraEnv: extraEnv) else {
            registerFailure(rateLimited: false)
            return .failed("unable to resolve remote shirai91/nx2android commit")
        }

        let shaFilePath = URL(fileURLWithPath: targetDir).appendingPathComponent(Self.syncShaFile).path
        if let localSha = (try? String(contentsOfFile: shaFilePath, encoding: .utf8))?
            .trimmingCharacters(in: .whitespacesAndNewlines),
           !localSha.isEmpty,
           localSha.caseInsensitiveCompare(remoteSha) == .orderedSame {
            registerSuccess()
            return .upToDate
        }

        let fm = FileManager.default
        let tempRoot = fm.temporaryDirectory.appendingPathComponent("nx2a_sync_\(UUID().uuidString)", isDirectory: true)
        defer { try? fm.removeItem(at: tempRoot) }

        do {
            try fm.createDirectory(at: tempRoot, withIntermediateDirectories: true)
        } catch {
            registerFailure(rateLimited: false)
            return .failed(error.localizedDescription)
        }

        let tarballPath = tempRoot.appendingPathComponent("main.tar.gz").path
        let download = BoundedProcess.run(
            "/usr/bin/curl",
            ["-fsSL", "--connect-timeout", "10", "--max-time", "180", "-o", tarballPath, Self.archiveURL],
            extraEnv: extraEnv,
            timeout: 190
        )
        guard download.success, fm.fileExists(atPath: tarballPath) else {
            registerFailure(rateLimited: isRateLimitError(download.output))
            return .failed(download.timedOut ? "archive download timed out" : download.output)
        }

        let extractDir = tempRoot.appendingPathComponent("extracted", isDirectory: true)
        try? fm.createDirectory(at: extractDir, withIntermediateDirectories: true)
        let extract = BoundedProcess.run(
            "/usr/bin/tar",
            ["-xzf", tarballPath, "-C", extractDir.path],
            timeout: 60
        )
        guard extract.success else {
            registerFailure(rateLimited: false)
            return .failed(extract.timedOut ? "archive extraction timed out" : extract.output)
        }

        let extractedEntries = (try? fm.contentsOfDirectory(atPath: extractDir.path)) ?? []
        guard let sourceFolder = extractedEntries
            .map({ extractDir.appendingPathComponent($0, isDirectory: true) })
            .first(where: { fm.fileExists(atPath: $0.appendingPathComponent("porter").path) }) else {
            registerFailure(rateLimited: false)
            return .failed("extracted nx2android archive missing porter/")
        }

        try? fm.createDirectory(atPath: targetDir, withIntermediateDirectories: true)

        let sync = BoundedProcess.run(
            "/usr/bin/rsync",
            [
                "-a",
                "--delete",
                "--exclude", "toolchains",
                "--exclude", Self.syncShaFile,
                sourceFolder.path + "/",
                targetDir + "/"
            ],
            timeout: 90
        )
        guard sync.success else {
            registerFailure(rateLimited: false)
            return .failed(sync.timedOut ? "sync timed out" : sync.output)
        }

        try? (remoteSha + "\n").write(toFile: shaFilePath, atomically: true, encoding: .utf8)
        registerSuccess()
        return .updated(String(remoteSha.prefix(7)))
    }

    private func fetchRemoteMainSha(git: String, extraEnv: [String: String]) -> String? {
        if FileManager.default.isExecutableFile(atPath: git) {
            let res = BoundedProcess.run(
                git,
                ["ls-remote", Self.repoURL, "refs/heads/main"],
                extraEnv: extraEnv,
                timeout: 15
            )
            if res.success {
                let firstToken = res.output
                    .components(separatedBy: .whitespacesAndNewlines)
                    .first(where: { !$0.isEmpty }) ?? ""
                if firstToken.count >= 7 {
                    return firstToken
                }
            }
        }

        guard let url = URL(string: Self.apiCommitURL) else { return nil }
        var req = URLRequest(url: url)
        req.timeoutInterval = 8.0
        req.setValue("application/vnd.github.sha", forHTTPHeaderField: "Accept")
        req.setValue("NxNativeLauncher", forHTTPHeaderField: "User-Agent")

        let semaphore = DispatchSemaphore(value: 0)
        var resolvedSha: String? = nil
        URLSession.shared.dataTask(with: req) { data, response, _ in
            defer { semaphore.signal() }
            guard let http = response as? HTTPURLResponse, http.statusCode == 200,
                  let data = data,
                  let text = String(data: data, encoding: .utf8)?
                    .trimmingCharacters(in: .whitespacesAndNewlines),
                  text.count >= 7 else {
                return
            }
            resolvedSha = text
        }.resume()
        _ = semaphore.wait(timeout: .now() + 9.0)
        return resolvedSha
    }

    private func buildGitEnvironment() -> [String: String] {
        var extraEnv: [String: String] = ["GIT_TERMINAL_PROMPT": "0"]
        if (ProcessInfo.processInfo.environment["HOME"] ?? "").isEmpty {
            extraEnv["HOME"] = FileManager.default.homeDirectoryForCurrentUser.path
        }
        return extraEnv
    }

    private func registerSuccess() {
        stateLock.lock()
        defer { stateLock.unlock() }
        consecutiveFailures = 0
        nextAllowed = Date().addingTimeInterval(Self.successCooldown)
    }

    private func registerFailure(rateLimited: Bool) {
        stateLock.lock()
        defer { stateLock.unlock() }
        consecutiveFailures += 1
        let delay = rateLimited
            ? Self.rateLimitCooldown
            : min(60.0 * pow(2.0, Double(consecutiveFailures - 1)), Self.rateLimitCooldown)
        nextAllowed = Date().addingTimeInterval(delay)
    }

    private func isRateLimitError(_ output: String) -> Bool {
        let lower = output.lowercased()
        return lower.contains("429") || lower.contains("too many requests") || lower.contains("rate limit")
    }
}
