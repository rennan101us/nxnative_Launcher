import Foundation
import AppKit

public final class UpdateCheckerService {
    public static let shared = UpdateCheckerService()
    public static let launcherRepoURL = "https://gitlab.com/rennan-group2/nxnative_Launcher.git"
    public static let upstreamRepoURL = "https://github.com/seedds/nxnative.git"
    
    public weak var delegate: UpdateCheckerDelegate?
    private var isChecking = false
    private var isUpdating = false
    private var isRelaunching = false

    private let stagedLock = NSLock()
    private var _stagedUpdateAppPath: String? = nil
    public var stagedUpdateAppPath: String? {
        get {
            stagedLock.lock()
            defer { stagedLock.unlock() }
            return _stagedUpdateAppPath
        }
        set {
            stagedLock.lock()
            _stagedUpdateAppPath = newValue
            stagedLock.unlock()
        }
    }
    
    // In-memory cache & throttle to prevent GitLab IP rate-limiting (unauthenticated_traffic_per_ip)
    private let cacheLock = NSLock()
    private var lastCheckDate: Date? = nil
    private var cachedUpdateInfo: UpdateInfo? = nil
    private var apiRateLimitUntil: Date = .distantPast
    private static let apiRateLimitCooldown: TimeInterval = 3600
    
    // Concurrency lock preventing Git mutations during an active build
    private let buildLock = NSLock()
    private var _isBuildActive = false
    public var isBuildActive: Bool {
        get {
            buildLock.lock()
            defer { buildLock.unlock() }
            return _isBuildActive
        }
        set {
            buildLock.lock()
            _isBuildActive = newValue
            buildLock.unlock()
        }
    }
    
    private init() {}
    
    public func getLocalCommit(nxnativePath: String) -> String {
        guard !nxnativePath.isEmpty else { return "HEAD" }
        let localHead = runGit(["rev-parse", "--short", "HEAD"], in: nxnativePath).trimmingCharacters(in: .whitespacesAndNewlines)
        return localHead.isEmpty ? "HEAD" : localHead
    }
    
    public func checkForUpdates(nxnativePath: String, force: Bool = false, completion: @escaping (UpdateInfo?) -> Void) {
        cacheLock.lock()
        if !force, let last = lastCheckDate, Date().timeIntervalSince(last) < 900, let cached = cachedUpdateInfo {
            cacheLock.unlock()
            completion(cached)
            return
        }
        guard !isChecking else {
            let cached = cachedUpdateInfo
            cacheLock.unlock()
            completion(cached)
            return
        }
        isChecking = true
        cacheLock.unlock()
        
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            guard let self = self else { return }
            
            let fm = FileManager.default
            let gitDir = URL(fileURLWithPath: nxnativePath).appendingPathComponent(".git").path
            let currentAppVer = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "2.2.4"
            guard fm.fileExists(atPath: gitDir) else {
                self.checkGitLabApiDirectly(currentVersion: currentAppVer, nxnativePath: nxnativePath, force: force) { info in
                    self.finishCheck(info: info, completion: completion)
                }
                return
            }
            
            // Automatically migrate origin and ensure upstream
            let remoteURL = self.ensureOfficialRemote(in: nxnativePath)
            
            // 1. git fetch origin main and tags (GitLab Launcher)
            var fetchRes = self.runGitWithStatus(
                ["fetch", "origin", "+refs/heads/main:refs/remotes/origin/main", "--tags", "--force", "--quiet"],
                in: nxnativePath,
                timeout: 30.0
            )
            if fetchRes.exitCode != 0 {
                fetchRes = self.runGitWithStatus(["fetch", "origin", "--force", "--quiet"], in: nxnativePath, timeout: 30.0)
            }
            
            // 2. git fetch upstream main (seedds/nxnative GitHub Core Engine)
            let upstreamFetchRes = self.runGitWithStatus(
                ["fetch", "upstream", "+refs/heads/main:refs/remotes/upstream/main", "--force", "--quiet"],
                in: nxnativePath,
                timeout: 45.0
            )
            
            if fetchRes.exitCode != 0 && upstreamFetchRes.exitCode != 0 {
                // Git transport unavailable: fall back to GitLab REST API before returning cached info
                self.checkGitLabApiDirectly(currentVersion: currentAppVer, nxnativePath: nxnativePath, force: force) { apiInfo in
                    self.finishCheck(info: apiInfo ?? self.cachedUpdateInfo, completion: completion)
                }
                return
            }
            
            // 3. Determine running app baseline commit (NXBuildCommit / version tag / HEAD) vs remote HEAD
            var localHead = self.runGit(["rev-parse", "--short", "HEAD"], in: nxnativePath).trimmingCharacters(in: .whitespacesAndNewlines)
            let remoteHead = self.runGit(["rev-parse", "--short", "origin/main"], in: nxnativePath).trimmingCharacters(in: .whitespacesAndNewlines)
            
            let builtCommit = (Bundle.main.infoDictionary?["NXBuildCommit"] as? String ?? "")
                .trimmingCharacters(in: .whitespacesAndNewlines)
            let hasValidBuiltCommit = !builtCommit.isEmpty && builtCommit != "unknown"
                && self.runGitWithStatus(["cat-file", "-e", "\(builtCommit)^{commit}"], in: nxnativePath).exitCode == 0
            let currentVerTag = "v\(currentAppVer.trimmingCharacters(in: CharacterSet(charactersIn: "vV")))"
            let hasCurrentVerTag = !currentVerTag.isEmpty
                && self.runGitWithStatus(["rev-parse", "-q", "--verify", "refs/tags/\(currentVerTag)"], in: nxnativePath).exitCode == 0
            let appBaseRef = hasValidBuiltCommit ? builtCommit : (hasCurrentVerTag ? currentVerTag : "HEAD")
            let appBaseShort = appBaseRef == "HEAD"
                ? localHead
                : self.runGit(["rev-parse", "--short", appBaseRef], in: nxnativePath).trimmingCharacters(in: .whitespacesAndNewlines)
            
            // 4. Upstream checks (seedds/nxnative from GitHub)
            let upstreamCountStr = self.runGit(["rev-list", "--count", "HEAD..upstream/main"], in: nxnativePath).trimmingCharacters(in: .whitespacesAndNewlines)
            let upstreamAheadCount = Int(upstreamCountStr) ?? 0
            
            let upstreamLogOutput = self.runGit(["log", "HEAD..upstream/main", "--oneline", "-n", "10"], in: nxnativePath).trimmingCharacters(in: .whitespacesAndNewlines)
            let upstreamCommits = upstreamLogOutput.isEmpty ? [] : upstreamLogOutput.components(separatedBy: .newlines).filter { !$0.isEmpty }
            
            // 5. Fetch GitLab Release API + compare against Git tags and running app baseline
            let token = self.extractGitLabToken(in: nxnativePath)
            GitLabReleaseNotesService.shared.fetchLatestRelease(token: token, force: force) { releasePayload in
                let gitRemoteTag = self.runGit(["describe", "--tags", "--abbrev=0", "origin/main"], in: nxnativePath)
                    .trimmingCharacters(in: .whitespacesAndNewlines)
                let apiRemoteTag = (releasePayload?.tagName ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
                
                let latestRemoteTag: String = {
                    if !gitRemoteTag.isEmpty && !apiRemoteTag.isEmpty {
                        return Self.isVersion(apiRemoteTag, newerThan: gitRemoteTag) ? apiRemoteTag : gitRemoteTag
                    }
                    return !apiRemoteTag.isEmpty ? apiRemoteTag : gitRemoteTag
                }()
                
                let isNewerTag = !latestRemoteTag.isEmpty && Self.isVersion(latestRemoteTag, newerThan: currentAppVer)
                let commitsAfterTag: Int = {
                    guard !gitRemoteTag.isEmpty else {
                        let s = self.runGit(["rev-list", "--count", "HEAD..origin/main"], in: nxnativePath).trimmingCharacters(in: .whitespacesAndNewlines)
                        return Int(s) ?? 0
                    }
                    let str = self.runGit(["rev-list", "--count", "\(gitRemoteTag)..origin/main"], in: nxnativePath).trimmingCharacters(in: .whitespacesAndNewlines)
                    return Int(str) ?? 0
                }()
                
                // If CoreRepoAutoUpdater already fast-forwarded HEAD to origin/main while the running .app
                // is from an older commit/tag, diff against appBaseRef so commit logs still reflect what's new.
                let useAppBaseRange = (localHead == remoteHead && appBaseRef != "HEAD" && !appBaseShort.isEmpty && appBaseShort != remoteHead)
                let diffBase = useAppBaseRange ? appBaseRef : "HEAD"
                
                let countStr = self.runGit(["rev-list", "--count", "\(diffBase)..origin/main"], in: nxnativePath).trimmingCharacters(in: .whitespacesAndNewlines)
                var aheadCount = Int(countStr) ?? 0
                
                let logOutput = self.runGit(["log", "\(diffBase)..origin/main", "--oneline"], in: nxnativePath).trimmingCharacters(in: .whitespacesAndNewlines)
                var commits = logOutput.isEmpty ? [] : logOutput.components(separatedBy: .newlines).filter { !$0.isEmpty }
                
                // When running .app is already at (or newer than) the latest release tag and origin/main
                // has no commits past that tag, only the local checkout fell behind (e.g. DMG update).
                // Silently sync checkout so users aren't prompted with a false-positive update.
                let appAtRemote = !isNewerTag && (appBaseRef == "HEAD" || appBaseShort == remoteHead)
                if aheadCount > 0 && !latestRemoteTag.isEmpty && appAtRemote && commitsAfterTag == 0 {
                    if !self.isBuildActive && !self.isUpdating {
                        _ = self.runGitWithStatus(["checkout", "--", "."], in: nxnativePath)
                        let syncMerge = self.runGitWithStatus(["merge", "-X", "theirs", "--no-edit", "origin/main"], in: nxnativePath)
                        if syncMerge.exitCode != 0 {
                            _ = self.runGitWithStatus(["merge", "--abort"], in: nxnativePath)
                            _ = self.runGitWithStatus(["reset", "--hard", "origin/main"], in: nxnativePath)
                        }
                        _ = PatchService.shared.applyPatchesIfNeeded(nxnativePath: nxnativePath)
                        localHead = self.runGit(["rev-parse", "--short", "HEAD"], in: nxnativePath).trimmingCharacters(in: .whitespacesAndNewlines)
                    }
                    aheadCount = 0
                    commits = []
                }
                
                let baselineCommit = useAppBaseRange ? appBaseShort : localHead
                let isBehindOrigin = !baselineCommit.isEmpty && !remoteHead.isEmpty && baselineCommit != remoteHead
                let hasUnreleasedRemoteCommits = commitsAfterTag > 0 && aheadCount > 0 && !commits.isEmpty && isBehindOrigin
                let hasLauncherUpdate = isNewerTag || (latestRemoteTag.isEmpty && aheadCount > 0 && !commits.isEmpty && isBehindOrigin) || hasUnreleasedRemoteCommits
                
                let displayLocalCommit: String = {
                    if !baselineCommit.isEmpty { return baselineCommit }
                    return currentAppVer != "0.0.0" ? "v\(currentAppVer)" : "HEAD"
                }()
                
                let info = UpdateInfo(
                    hasUpdate: hasLauncherUpdate,
                    localCommit: displayLocalCommit,
                    remoteCommit: latestRemoteTag.isEmpty ? remoteHead : latestRemoteTag,
                    commitMessages: commits,
                    checkDate: Date(),
                    repoURL: remoteURL.isEmpty ? Self.launcherRepoURL : remoteURL,
                    upstreamBehindCount: upstreamAheadCount,
                    upstreamCommitMessages: upstreamCommits,
                    upstreamRepoURL: Self.upstreamRepoURL,
                    releaseName: releasePayload?.name,
                    releaseSummary: releasePayload?.summary,
                    releaseCategories: releasePayload?.categories ?? [],
                    releaseMarkdown: releasePayload?.description
                )
                self.finishCheck(info: info, completion: completion)
            }
        }
    }
    
    private func finishCheck(info: UpdateInfo?, completion: @escaping (UpdateInfo?) -> Void) {
        cacheLock.lock()
        self.isChecking = false
        if let info = info {
            self.lastCheckDate = Date()
            self.cachedUpdateInfo = info
        }
        cacheLock.unlock()
        
        DispatchQueue.main.async {
            if let info = info, info.hasUpdate {
                self.delegate?.updateCheckerDidFindUpdate(info)
            }
            completion(info)
        }
    }
    
    /// Pulls latest changes from GitHub, applies engine patches, and rebuilds + installs NxNative_Launcher.app automatically
    public func applyUpdate(
        nxnativePath: String,
        rebuildLauncher: Bool = true,
        progressHandler: ((String) -> Void)? = nil,
        completion: @escaping (Bool, String) -> Void
    ) {
        guard !isBuildActive else {
            let msg = "Update blocked: A compilation process is currently active. Repository updates are paused during build to prevent toolchain and shader hash mismatch."
            delegate?.updateCheckerDidProduceLog(msg)
            completion(false, msg)
            return
        }
        guard !isUpdating else {
            completion(false, "Update already in progress")
            return
        }
        let gitDir = URL(fileURLWithPath: nxnativePath).appendingPathComponent(".git").path
        guard FileManager.default.fileExists(atPath: gitDir) else {
            completion(false, "Directory is not a Git repository. Please install updates using the official DMG release.")
            return
        }
        isUpdating = true
        
        let reportProgress: (String) -> Void = { [weak self] msg in
            DispatchQueue.main.async {
                self?.delegate?.updateCheckerDidProduceLog(msg)
                progressHandler?(msg)
            }
        }
        
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            guard let self = self else { return }
            
            if self.isBuildActive {
                self.isUpdating = false
                reportProgress("==> Update aborted: A build process has started.")
                DispatchQueue.main.async { completion(false, "Update cancelled: Build in progress.") }
                return
            }
            
            reportProgress("==> Preparing repository for update...")
            _ = self.runGitWithStatus(["rebase", "--abort"], in: nxnativePath)
            _ = self.runGitWithStatus(["merge", "--abort"], in: nxnativePath)
            _ = self.ensureOfficialRemote(in: nxnativePath, reportProgress: reportProgress)
            
            // Discard auto-patched tracked modifications so git pull/merge never conflicts with PatchService edits
            _ = self.runGitWithStatus(["checkout", "--", "."], in: nxnativePath)
            
            reportProgress("==> Downloading latest version from GitLab (rennan-group2/nxnative_Launcher)...")
            let fetchRes = self.runGitWithStatus(
                ["fetch", "origin", "+refs/heads/main:refs/remotes/origin/main", "--tags", "--force"],
                in: nxnativePath,
                timeout: 45.0
            )
            if !fetchRes.output.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                reportProgress(fetchRes.output.trimmingCharacters(in: .whitespacesAndNewlines))
            }
            
            reportProgress("==> Merging GitLab updates into local branch...")
            let mergeRes = self.runGitWithStatus(["merge", "-X", "theirs", "--no-edit", "origin/main"], in: nxnativePath)
            if !mergeRes.output.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                reportProgress(mergeRes.output.trimmingCharacters(in: .whitespacesAndNewlines))
            }
            
            var isMergeSuccess = (mergeRes.exitCode == 0) &&
                !mergeRes.output.localizedCaseInsensitiveContains("fatal:") &&
                !mergeRes.output.localizedCaseInsensitiveContains("Automatic merge failed")
            
            if !isMergeSuccess {
                _ = self.runGitWithStatus(["merge", "--abort"], in: nxnativePath)
                reportProgress("==> Fast-forwarding local repository to origin/main...")
                let resetRes = self.runGitWithStatus(["reset", "--hard", "origin/main"], in: nxnativePath)
                isMergeSuccess = (resetRes.exitCode == 0)
            }
            
            _ = self.runGitWithStatus(["submodule", "update", "--init", "--recursive"], in: nxnativePath)
            
            guard isMergeSuccess else {
                self.isUpdating = false
                let errOut = mergeRes.output.trimmingCharacters(in: .whitespacesAndNewlines)
                DispatchQueue.main.async {
                    completion(false, "Git update failed: \(errOut.isEmpty ? "Merge conflict or network error" : errOut)")
                }
                return
            }
            
            // Re-apply compatibility patches
            reportProgress("==> Verifying & applying engine compatibility patches...")
            _ = PatchService.shared.applyPatchesIfNeeded(nxnativePath: nxnativePath)
            
            // Rebuild & install NxNative_Launcher.app if requested
            if rebuildLauncher {
                // Remove any prior DMG staging bundle so relaunch uses the freshly compiled bundle
                let tempStaged = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("NxNative_Launcher_Update.app").path
                try? FileManager.default.removeItem(atPath: tempStaged)
                self.stagedUpdateAppPath = nil
                
                let buildScript = URL(fileURLWithPath: nxnativePath).appendingPathComponent("scripts/build_gui.sh").path
                if FileManager.default.fileExists(atPath: buildScript) {
                    reportProgress("==> Compiling & installing new NxNative Launcher (.app)...")
                    let buildRes = self.runShellScript(buildScript, workingDir: nxnativePath) { line in
                        reportProgress(line)
                    }
                    if buildRes != 0 {
                        self.isUpdating = false
                        DispatchQueue.main.async {
                            completion(false, "Git updated, but compiling NxNative Launcher failed (exit code \(buildRes)).")
                        }
                        return
                    }
                    
                    let workspaceBundle = URL(fileURLWithPath: nxnativePath).deletingLastPathComponent().appendingPathComponent("NxNative_Launcher.app").path
                    if FileManager.default.fileExists(atPath: workspaceBundle) {
                        self.stagedUpdateAppPath = workspaceBundle
                    }
                    self.syncUpdatedBundleToRunningAppIfNeeded(nxnativePath: nxnativePath, reportProgress: reportProgress)
                }
            }
            
            let newHead = self.runGit(["rev-parse", "--short", "HEAD"], in: nxnativePath).trimmingCharacters(in: .whitespacesAndNewlines)
            self.cacheLock.lock()
            self.lastCheckDate = nil
            if let existing = self.cachedUpdateInfo {
                self.cachedUpdateInfo = UpdateInfo(
                    hasUpdate: false,
                    localCommit: newHead.isEmpty ? existing.localCommit : newHead,
                    remoteCommit: existing.remoteCommit,
                    commitMessages: [],
                    checkDate: Date(),
                    repoURL: existing.repoURL,
                    upstreamBehindCount: existing.upstreamBehindCount,
                    upstreamCommitMessages: existing.upstreamCommitMessages,
                    upstreamRepoURL: existing.upstreamRepoURL
                )
            }
            self.cacheLock.unlock()
            self.isUpdating = false
            
            DispatchQueue.main.async {
                completion(true, "NxNative Launcher updated & installed successfully (commit [\(newHead)])!")
            }
        }
    }
    
    /// Safely fetches and merges upstream engine updates from seedds/nxnative (GitHub) into the local repository,
    /// re-applies compatibility patches, and rebuilds the launcher if requested.
    public func syncUpstream(
        nxnativePath: String,
        rebuildLauncher: Bool = true,
        progressHandler: ((String) -> Void)? = nil,
        completion: @escaping (Bool, String) -> Void
    ) {
        guard !isBuildActive else {
            let msg = "Sync blocked: A compilation process is currently active."
            delegate?.updateCheckerDidProduceLog(msg)
            completion(false, msg)
            return
        }
        guard !isUpdating else {
            completion(false, "Update or sync already in progress")
            return
        }
        let gitDir = URL(fileURLWithPath: nxnativePath).appendingPathComponent(".git").path
        guard FileManager.default.fileExists(atPath: gitDir) else {
            completion(false, "Directory is not a Git repository. Cloning the repository is required to sync upstream commits.")
            return
        }
        isUpdating = true
        
        let reportProgress: (String) -> Void = { [weak self] msg in
            DispatchQueue.main.async {
                self?.delegate?.updateCheckerDidProduceLog(msg)
                progressHandler?(msg)
            }
        }
        
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            guard let self = self else { return }
            
            if self.isBuildActive {
                self.isUpdating = false
                reportProgress("==> Sync aborted: A build process has started.")
                DispatchQueue.main.async { completion(false, "Sync cancelled: Build in progress.") }
                return
            }
            
            let countStr = self.runGit(["rev-list", "--count", "HEAD..upstream/main"], in: nxnativePath).trimmingCharacters(in: .whitespacesAndNewlines)
            let count = Int(countStr) ?? 0
            
            // Discard auto-applied PatchService edits cleanly before sync_upstream.sh runs so they never enter git stash
            self.prepareRepoForCleanSync(in: nxnativePath)
            
            let syncScript = URL(fileURLWithPath: nxnativePath).appendingPathComponent("scripts/sync_upstream.sh").path
            if FileManager.default.fileExists(atPath: syncScript) {
                reportProgress("==> Synchronizing upstream engine using sync_upstream.sh...")
                let syncRes = self.runShellScript(syncScript, workingDir: nxnativePath) { line in
                    reportProgress(line)
                }
                if syncRes != 0 {
                    _ = PatchService.shared.applyPatchesIfNeeded(nxnativePath: nxnativePath)
                    self.isUpdating = false
                    DispatchQueue.main.async {
                        completion(false, "Upstream sync script failed with exit code \(syncRes).")
                    }
                    return
                }
            } else {
                reportProgress("==> Fetching upstream engine commits from GitHub (seedds/nxnative)...")
                _ = self.runGitWithStatus(["rebase", "--abort"], in: nxnativePath)
                _ = self.runGitWithStatus(["merge", "--abort"], in: nxnativePath)
                _ = self.ensureOfficialRemote(in: nxnativePath, reportProgress: reportProgress)
                let fetchRes = self.runGitWithStatus(
                    ["fetch", "upstream", "+refs/heads/main:refs/remotes/upstream/main", "--force"],
                    in: nxnativePath,
                    timeout: 60.0
                )
                if fetchRes.exitCode != 0 {
                    self.isUpdating = false
                    let err = fetchRes.output.trimmingCharacters(in: .whitespacesAndNewlines)
                    DispatchQueue.main.async {
                        completion(false, "Failed to reach upstream GitHub: \(err.isEmpty ? "Network error" : err)")
                    }
                    return
                }
                
                let freshCountStr = self.runGit(["rev-list", "--count", "HEAD..upstream/main"], in: nxnativePath).trimmingCharacters(in: .whitespacesAndNewlines)
                let freshCount = Int(freshCountStr) ?? 0
                if freshCount == 0 {
                    self.cacheLock.lock()
                    self.lastCheckDate = nil
                    if let existing = self.cachedUpdateInfo {
                        self.cachedUpdateInfo = UpdateInfo(
                            hasUpdate: existing.hasUpdate,
                            localCommit: existing.localCommit,
                            remoteCommit: existing.remoteCommit,
                            commitMessages: existing.commitMessages,
                            checkDate: Date(),
                            repoURL: existing.repoURL,
                            upstreamBehindCount: 0,
                            upstreamCommitMessages: [],
                            upstreamRepoURL: existing.upstreamRepoURL
                        )
                    }
                    self.cacheLock.unlock()
                    self.isUpdating = false
                    reportProgress("✅ Core engine is already 100% up to date with seedds/nxnative (GitHub)!")
                    DispatchQueue.main.async {
                        completion(true, "Core engine is already up to date with seedds/nxnative.")
                    }
                    return
                }
                
                reportProgress("==> Merging \(freshCount) upstream commits from seedds/nxnative...")
                let mergeRes = self.runGitWithStatus(["merge", "upstream/main", "--no-edit", "-m", "chore(sync): merge upstream updates from seedds/nxnative"], in: nxnativePath, timeout: 60.0)
                
                var isMergeSuccess = (mergeRes.exitCode == 0) &&
                    !mergeRes.output.localizedCaseInsensitiveContains("fatal:") &&
                    !mergeRes.output.localizedCaseInsensitiveContains("Automatic merge failed") &&
                    !mergeRes.output.localizedCaseInsensitiveContains("CONFLICT")
                
                if !isMergeSuccess {
                    // Auto-resolve any file conflicts: preserve local GUI/Launcher & isolated Zelda OoT files, accept upstream engine improvements
                    let conflictFiles = self.runGit(["diff", "--name-only", "--diff-filter=U"], in: nxnativePath)
                        .components(separatedBy: .newlines).filter { !$0.isEmpty }
                    if !conflictFiles.isEmpty {
                        reportProgress("==> Auto-resolving engine updates while safeguarding launcher & Zelda OoT customizations...")
                        for file in conflictFiles {
                            let keepOurs = file.hasPrefix("gui/") ||
                                file.hasPrefix("frontend-ios/") ||
                                file == "README.md" ||
                                file == "GEMINI.md" ||
                                file.hasPrefix(".gitlab") ||
                                file.hasPrefix("scripts/") ||
                                file == "dm/gfx/nvn/oot_enhancements.inc" ||
                                file.hasPrefix("dm/games/0400486024DEC000/") ||
                                file == "dm/games/game.py" ||
                                file == "dm/tools/tests/test_oot_render_scale.py"
                            if keepOurs {
                                _ = self.runGitWithStatus(["checkout", "HEAD", "--", file], in: nxnativePath)
                            } else {
                                _ = self.runGitWithStatus(["checkout", "--theirs", "--", file], in: nxnativePath)
                            }
                            _ = self.runGitWithStatus(["add", file], in: nxnativePath)
                        }
                        let commitRes = self.runGitWithStatus(["commit", "--no-edit", "-m", "chore(sync): merge upstream updates from seedds/nxnative (auto-resolved)"], in: nxnativePath, timeout: 30.0)
                        isMergeSuccess = (commitRes.exitCode == 0)
                    }
                }
                
                if !isMergeSuccess {
                    _ = self.runGitWithStatus(["merge", "--abort"], in: nxnativePath)
                    self.isUpdating = false
                    reportProgress("⚠️ Merge conflict detected when syncing upstream. Aborted to protect local customizations.")
                    DispatchQueue.main.async {
                        completion(false, "Merge conflict detected while syncing upstream. Aborted to safeguard local code.")
                    }
                    return
                }
            }
            
            reportProgress("==> Verifying & re-applying engine compatibility patches (including isolated Zelda OoT)...")
            let patchOutcome = PatchService.shared.applyPatchesIfNeeded(nxnativePath: nxnativePath) { msg, _ in
                reportProgress(msg)
            }
            if !patchOutcome.errors.isEmpty {
                for err in patchOutcome.errors {
                    reportProgress("⚠️ \(err)")
                }
            }
            
            if rebuildLauncher {
                let tempStaged = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("NxNative_Launcher_Update.app").path
                try? FileManager.default.removeItem(atPath: tempStaged)
                self.stagedUpdateAppPath = nil
                
                let buildScript = URL(fileURLWithPath: nxnativePath).appendingPathComponent("scripts/build_gui.sh").path
                if FileManager.default.fileExists(atPath: buildScript) {
                    reportProgress("==> Compiling & reinstalling updated NxNative Launcher (.app)...")
                    let buildRes = self.runShellScript(buildScript, workingDir: nxnativePath) { line in
                        reportProgress(line)
                    }
                    if buildRes != 0 {
                        self.isUpdating = false
                        DispatchQueue.main.async {
                            completion(false, "Upstream synced, but compiling launcher failed (code \(buildRes)).")
                        }
                        return
                    }
                    let workspaceBundle = URL(fileURLWithPath: nxnativePath).deletingLastPathComponent().appendingPathComponent("NxNative_Launcher.app").path
                    if FileManager.default.fileExists(atPath: workspaceBundle) {
                        self.stagedUpdateAppPath = workspaceBundle
                    }
                    self.syncUpdatedBundleToRunningAppIfNeeded(nxnativePath: nxnativePath, reportProgress: reportProgress)
                }
            }
            
            let newHead = self.runGit(["rev-parse", "--short", "HEAD"], in: nxnativePath).trimmingCharacters(in: .whitespacesAndNewlines)
            let remainingStr = self.runGit(["rev-list", "--count", "HEAD..upstream/main"], in: nxnativePath).trimmingCharacters(in: .whitespacesAndNewlines)
            let remainingCount = Int(remainingStr) ?? 0
            
            self.cacheLock.lock()
            self.lastCheckDate = nil
            if let existing = self.cachedUpdateInfo {
                self.cachedUpdateInfo = UpdateInfo(
                    hasUpdate: existing.hasUpdate,
                    localCommit: newHead.isEmpty ? existing.localCommit : newHead,
                    remoteCommit: existing.remoteCommit,
                    commitMessages: existing.commitMessages,
                    checkDate: Date(),
                    repoURL: existing.repoURL,
                    upstreamBehindCount: remainingCount,
                    upstreamCommitMessages: remainingCount == 0 ? [] : existing.upstreamCommitMessages,
                    upstreamRepoURL: existing.upstreamRepoURL,
                    releaseName: existing.releaseName,
                    releaseSummary: existing.releaseSummary,
                    releaseCategories: existing.releaseCategories,
                    releaseMarkdown: existing.releaseMarkdown
                )
            }
            self.cacheLock.unlock()
            self.isUpdating = false
            let summaryMsg = count > 0
                ? "Successfully merged \(count) upstream commits from seedds/nxnative (commit [\(newHead)])!"
                : "Core engine synchronized and up to date with seedds/nxnative (commit [\(newHead)])!"
            DispatchQueue.main.async {
                completion(true, summaryMsg)
            }
        }
    }
    
    /// Relaunches the updated NxNative_Launcher.app bundle into its canonical destination and terminates safely.
    public func relaunchLauncher(
        nxnativePath: String,
        sourceAppPath: String? = nil,
        onErrorBeforeExit: ((String) -> Void)? = nil
    ) {
        if isRelaunching { return }
        isRelaunching = true

        LauncherSelfUpdater.shared.installAndRelaunch(
            nxnativePath: nxnativePath,
            sourceAppPath: sourceAppPath ?? self.stagedUpdateAppPath
        ) { [weak self] errorMsg in
            self?.isRelaunching = false
            onErrorBeforeExit?(errorMsg)
        }
    }
    
    /// Checks if the remote `origin/main` branch has unreleased commits newer than the supplied release tag.
    public func hasUnreleasedCommitsAfterTag(_ tag: String, nxnativePath: String) -> Bool {
        let gitDir = URL(fileURLWithPath: nxnativePath).appendingPathComponent(".git").path
        guard FileManager.default.fileExists(atPath: gitDir) else { return false }
        let trimmed = tag.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, Self.isSemverTag(trimmed) else { return true }
        let vTag = trimmed.hasPrefix("v") || trimmed.hasPrefix("V") ? trimmed : "v\(trimmed)"
        let refToCheck: String
        if runGitWithStatus(["rev-parse", "-q", "--verify", "refs/tags/\(trimmed)"], in: nxnativePath).exitCode == 0 {
            refToCheck = trimmed
        } else if runGitWithStatus(["rev-parse", "-q", "--verify", "refs/tags/\(vTag)"], in: nxnativePath).exitCode == 0 {
            refToCheck = vTag
        } else {
            return false
        }
        let countStr = runGit(["rev-list", "--count", "\(refToCheck)..origin/main"], in: nxnativePath)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return (Int(countStr) ?? 0) > 0
    }
    
    public static func isSemverTag(_ raw: String) -> Bool {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.range(of: "^[vV]?\\d+\\.\\d+(?:\\.\\d+)?(?:[-+][A-Za-z0-9._-]+)?$", options: .regularExpression) != nil
    }
    
    public static func isVersion(_ lhs: String, newerThan rhs: String) -> Bool {
        let cleanL = lhs.trimmingCharacters(in: CharacterSet(charactersIn: "vV \n\r\t"))
        let cleanR = rhs.trimmingCharacters(in: CharacterSet(charactersIn: "vV \n\r\t"))
        guard !cleanL.isEmpty else { return false }
        guard !cleanR.isEmpty else { return true }
        return cleanL.compare(cleanR, options: .numeric) == .orderedDescending
    }
    
    private func prepareRepoForCleanSync(in nxnativePath: String) {
        let patchedPaths = [
            "dm/gfx/nvn/nvn_mtl.m",
            "dm/gfx/msl/present.metal",
            "dm/gfx/msl/copy.metal",
            "dm/hle/nvn/hle_nvn.c",
            "dm/gfx/nvn/hle_nvn.c",
            "dm/host/hle_fpslock.c",
            "dm/host/front_mac.m",
            "dm/mac/pack_app.py",
            "scripts/build_ipa_from_nsp.py",
            "dm/games/0100A9D01C446000/game.tsv",
            "dm/games/01002DA013484000/game.tsv"
        ]
        _ = runGitWithStatus(["checkout", "--"] + patchedPaths, in: nxnativePath, timeout: 10.0)
    }
    
    internal func extractGitLabToken(in nxnativePath: String) -> String? {
        if let envTok = ProcessInfo.processInfo.environment["GITLAB_TOKEN"], !envTok.isEmpty {
            return envTok
        }
        let originURL = runGit(["remote", "get-url", "origin"], in: nxnativePath)
        let gitlabURL = runGit(["remote", "get-url", "gitlab"], in: nxnativePath)
        for u in [originURL, gitlabURL] {
            if let range = u.range(of: "(glpat-[a-zA-Z0-9_.-]+)", options: .regularExpression) {
                return String(u[range])
            }
        }
        return nil
    }
    
    private func checkGitLabApiDirectly(currentVersion: String, nxnativePath: String, force: Bool = false, completion: @escaping (UpdateInfo?) -> Void) {
        let token = extractGitLabToken(in: nxnativePath)
        GitLabReleaseNotesService.shared.fetchLatestRelease(token: token, force: force) { [weak self] payload in
            guard let self = self else {
                completion(nil)
                return
            }
            if let payload = payload {
                let cleanRemote = payload.tagName.trimmingCharacters(in: CharacterSet(charactersIn: "vV"))
                let cleanLocal = currentVersion.trimmingCharacters(in: CharacterSet(charactersIn: "vV"))
                let isNewer = cleanRemote.compare(cleanLocal, options: .numeric) == .orderedDescending
                let info = UpdateInfo(
                    hasUpdate: isNewer,
                    localCommit: currentVersion,
                    remoteCommit: payload.tagName,
                    commitMessages: payload.summary.isEmpty ? [] : [payload.summary],
                    checkDate: Date(),
                    repoURL: Self.launcherRepoURL,
                    releaseName: payload.name,
                    releaseSummary: payload.summary,
                    releaseCategories: payload.categories,
                    releaseMarkdown: payload.description
                )
                completion(info)
                return
            }
            self.checkGitLabTagsFallback(currentVersion: currentVersion, token: token, completion: completion)
        }
    }

    private func checkGitLabTagsFallback(currentVersion: String, token: String?, completion: @escaping (UpdateInfo?) -> Void) {
        cacheLock.lock()
        let isRateLimited = Date() < apiRateLimitUntil
        let cached = cachedUpdateInfo
        cacheLock.unlock()

        if isRateLimited {
            completion(cached)
            return
        }

        guard let url = URL(string: "https://gitlab.com/api/v4/projects/88419597/repository/tags?per_page=5") else {
            completion(nil)
            return
        }
        var req = URLRequest(url: url)
        req.timeoutInterval = 4.0
        if let tok = token {
            req.addValue(tok, forHTTPHeaderField: "PRIVATE-TOKEN")
        }
        URLSession.shared.dataTask(with: req) { [weak self] data, response, _ in
            guard let self = self else {
                completion(nil)
                return
            }
            if let http = response as? HTTPURLResponse, http.statusCode == 429 {
                let retryHeader = http.value(forHTTPHeaderField: "Retry-After")
                let parsedRetry = retryHeader.flatMap(TimeInterval.init) ?? Self.apiRateLimitCooldown
                let cooldown = min(max(parsedRetry, 60), 7200)
                self.cacheLock.lock()
                self.apiRateLimitUntil = Date().addingTimeInterval(cooldown)
                self.lastCheckDate = Date()
                let fallback = self.cachedUpdateInfo
                self.cacheLock.unlock()
                // Rate limited on unauthenticated IP; fail gracefully and do not spam
                completion(fallback)
                return
            }
            guard let data = data,
                  let json = try? JSONSerialization.jsonObject(with: data) as? [[String: Any]],
                  let firstTag = json.first,
                  let tagName = firstTag["name"] as? String else {
                self.cacheLock.lock()
                self.lastCheckDate = Date()
                self.cacheLock.unlock()
                completion(nil)
                return
            }
            let cleanRemote = tagName.trimmingCharacters(in: CharacterSet(charactersIn: "vV"))
            let cleanLocal = currentVersion.trimmingCharacters(in: CharacterSet(charactersIn: "vV"))
            let isNewer = cleanRemote.compare(cleanLocal, options: .numeric) == .orderedDescending
            let msg = firstTag["message"] as? String ?? ""
            let info = UpdateInfo(
                hasUpdate: isNewer,
                localCommit: currentVersion,
                remoteCommit: tagName,
                commitMessages: msg.isEmpty ? [] : [msg],
                checkDate: Date(),
                repoURL: Self.launcherRepoURL
            )
            completion(info)
        }.resume()
    }
}
