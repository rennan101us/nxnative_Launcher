import Foundation

public enum CoreRepoUpdateResult {
    case notARepo
    case upToDate
    case updated(String)       // new short commit
    case skipped(String)       // reason (dirty tree / diverged / etc.)
    case failed(String)
}

/// Silent, bounded, best-effort Core Repository updater (fetch + fast-forward only).
/// Never rebuilds or relaunches the launcher and never discards local changes.
public final class CoreRepoAutoUpdater {
    public static let shared = CoreRepoAutoUpdater()
    private static let successCooldown: TimeInterval = 1800 // 30 min between successful GitLab fetches
    private static let rateLimitCooldown: TimeInterval = 3600 // 1 h cooldown on HTTP 429 / rate limits

    private let stateLock = NSLock()
    private var consecutiveFailures = 0
    private var nextAllowed = Date.distantPast

    /// Cooldown after a completed check (30 min) or exponential backoff after failures (1 min → max 1 h).
    public var isInBackoff: Bool {
        stateLock.lock()
        defer { stateLock.unlock() }
        return Date() < nextAllowed
    }

    /// Blocking: call from a background queue only.
    public func updateIfNeeded(repoPath: String) -> CoreRepoUpdateResult {
        let git = BoundedProcess.gitPath()
        guard FileManager.default.fileExists(atPath: repoPath + "/.git") else { return .notARepo }
        if isInBackoff { return .skipped("cooldown") }

        let branch = BoundedProcess.run(git, ["rev-parse", "--abbrev-ref", "HEAD"], cwd: repoPath, timeout: 5)
            .output.trimmingCharacters(in: .whitespacesAndNewlines)
        guard branch == "main" else { return .skipped("branch '\(branch)' is not main") }

        var extraEnv: [String: String] = [:]
        if (ProcessInfo.processInfo.environment["HOME"] ?? "").isEmpty {
            extraEnv["HOME"] = FileManager.default.homeDirectoryForCurrentUser.path
        }
        if ProcessInfo.processInfo.environment["GIT_AUTHOR_NAME"] == nil {
            extraEnv["GIT_AUTHOR_NAME"] = "NxNative Updater"
            extraEnv["GIT_AUTHOR_EMAIL"] = "updater@nxnative.local"
            extraEnv["GIT_COMMITTER_NAME"] = "NxNative Updater"
            extraEnv["GIT_COMMITTER_EMAIL"] = "updater@nxnative.local"
        }

        let originURL = BoundedProcess.run(git, ["config", "--get", "remote.origin.url"], cwd: repoPath, extraEnv: extraEnv, timeout: 5)
            .output.trimmingCharacters(in: .whitespacesAndNewlines)

        // Ensure wildcard refspec so single-branch clones still update origin/main on fetch
        _ = BoundedProcess.run(git, ["config", "remote.origin.fetch", "+refs/heads/*:refs/remotes/origin/*"], cwd: repoPath, extraEnv: extraEnv, timeout: 5)

        // Fetch from origin with explicit refspec and forced tags; only fall back to mirror when it points to a distinct host/repo and origin wasn't rate-limited.
        var usedMirror = false
        var fetched = BoundedProcess.run(git, ["fetch", "--quiet", "--tags", "--force", "origin", "+refs/heads/main:refs/remotes/origin/main"], cwd: repoPath, extraEnv: extraEnv, timeout: 60)
        if !fetched.success && !isRateLimitError(fetched.output) {
            let mirrorURL = SystemDetector.mirrorRepoURL
            if Self.normalizedRepoIdentity(originURL) != Self.normalizedRepoIdentity(mirrorURL) {
                usedMirror = true
                fetched = BoundedProcess.run(git, ["fetch", "--quiet", "--tags", "--force", mirrorURL, "main"], cwd: repoPath, extraEnv: extraEnv, timeout: 60)
            }
        }
        guard fetched.success else {
            registerFailure(rateLimited: isRateLimitError(fetched.output))
            return .failed(fetched.timedOut ? "fetch timed out" : fetched.output)
        }

        stateLock.lock()
        consecutiveFailures = 0
        nextAllowed = Date().addingTimeInterval(Self.successCooldown)
        stateLock.unlock()

        let targetRef = usedMirror ? "FETCH_HEAD" : "origin/main"
        let behind = Int(BoundedProcess.run(git, ["rev-list", "--count", "HEAD..\(targetRef)"], cwd: repoPath, extraEnv: extraEnv, timeout: 5)
            .output.trimmingCharacters(in: .whitespacesAndNewlines)) ?? 0
        if behind == 0 { return .upToDate }
        let ahead = Int(BoundedProcess.run(git, ["rev-list", "--count", "\(targetRef)..HEAD"], cwd: repoPath, extraEnv: extraEnv, timeout: 5)
            .output.trimmingCharacters(in: .whitespacesAndNewlines)) ?? 0
        if ahead > 0 { return .skipped("local commits ahead of remote") }

        // ff-only never overwrites uncommitted work: it aborts if files conflict.
        let merge = BoundedProcess.run(git, ["merge", "--ff-only", targetRef], cwd: repoPath, extraEnv: extraEnv, timeout: 60)
        guard merge.success else { return .skipped("fast-forward blocked by local changes") }
        let head = BoundedProcess.run(git, ["rev-parse", "--short", "HEAD"], cwd: repoPath, extraEnv: extraEnv, timeout: 5)
            .output.trimmingCharacters(in: .whitespacesAndNewlines)
        return .updated(head)
    }

    private func registerFailure(rateLimited: Bool = false) {
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

    private static func normalizedRepoIdentity(_ raw: String) -> String {
        var s = raw.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        if let atIdx = s.firstIndex(of: "@"), let schemeEnd = s.range(of: "://") {
            s = String(s[..<schemeEnd.upperBound]) + String(s[s.index(after: atIdx)...])
        }
        if s.hasSuffix(".git") {
            s.removeLast(4)
        }
        return s.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
    }
}
