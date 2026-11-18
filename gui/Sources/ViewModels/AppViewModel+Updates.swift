import Foundation
import AppKit
import SwiftUI

extension AppViewModel {
    // MARK: - GitLab Updates & Auto-Installer
    public func checkForUpdates(showModalIfAvailable: Bool = false, force: Bool = false) {
        isCheckingUpdate = true
        updateChecker.checkForUpdates(nxnativePath: nxnativePath, force: force) { [weak self] info in
            guard let self = self else { return }
            self.isCheckingUpdate = false
            self.updateInfo = info
            self.refreshReleaseNotesTranslation()
            
            if let info = info, info.hasUpdate {
                if showModalIfAvailable && !self.isBuilding {
                    DispatchQueue.main.async {
                        self.showUpdateSheet = true
                    }
                }
            }
        }
    }
    
    /// Triggered from the macOS Menu Bar ("Check for Updates...") or Settings tab:
    /// Opens the Update modal, checks GitLab (rennan-group2/nxnative_Launcher), and if a new version is found, downloads & installs it automatically.
    public func openUpdateCheckerAndAutoInstall() {
        showUpdateSheet = true
        updateErrorBanner = nil
        updateSuccessBanner = nil
        updateCompletedReadyToRelaunch = false
        
        guard !isBuilding else {
            let msg = tr("build.update_locked_during_build")
            updateErrorBanner = msg
            logs.append(LogEntry(level: .warning, message: "[Update] \(msg)"))
            return
        }
        
        isCheckingUpdate = true
        updateChecker.checkForUpdates(nxnativePath: nxnativePath, force: true) { [weak self] info in
            guard let self = self else { return }
            self.isCheckingUpdate = false
            self.updateInfo = info
            self.refreshReleaseNotesTranslation()
        }
    }
    
    public func applyUpdate(autoRelaunch: Bool = false) {
        guard !isBuilding else {
            let msg = tr("build.update_locked_during_build")
            self.updateErrorBanner = msg
            self.logs.append(LogEntry(level: .warning, message: "[Update] \(msg)"))
            return
        }
        
        let gitDir = URL(fileURLWithPath: nxnativePath).appendingPathComponent(".git").path
        let isGitRepo = FileManager.default.fileExists(atPath: gitDir)
        if !isNxnativeValid || nxnativePath.isEmpty || !isGitRepo {
            downloadAndInstallDmgUpdate(autoRelaunch: autoRelaunch, allowSourceBuildFallback: false)
            return
        }
        
        let candidateTag: String? = {
            if let remote = updateInfo?.remoteCommit, UpdateCheckerService.isSemverTag(remote) {
                return remote
            }
            if let cachedTag = GitLabReleaseNotesService.shared.cachedPayload()?.tagName,
               UpdateCheckerService.isSemverTag(cachedTag) {
                return cachedTag
            }
            return nil
        }()
        if !isDeveloperMode, let _ = candidateTag {
            // Normal users install directly from the verified GitLab DMG so no duplicate workspace .app is built
            downloadAndInstallDmgUpdate(autoRelaunch: autoRelaunch, allowSourceBuildFallback: false)
            return
        }
        let hasUnreleasedCommits = candidateTag.map {
            updateChecker.hasUnreleasedCommitsAfterTag($0, nxnativePath: nxnativePath)
        } ?? true
        let useDmgAfterGitSync = !isDeveloperMode && candidateTag != nil && !hasUnreleasedCommits
        
        runGitUpdateFlow(autoRelaunch: autoRelaunch, rebuildLauncher: !useDmgAfterGitSync, useDmgAfterGitSync: useDmgAfterGitSync)
    }
    
    private func runGitUpdateFlow(autoRelaunch: Bool, rebuildLauncher: Bool, useDmgAfterGitSync: Bool) {
        isApplyingUpdate = true
        if updateProgressFraction < 0.08 {
            updateProgressFraction = 0.08
        }
        updateStatusText = "Preparing update..."
        updateErrorBanner = nil
        updateSuccessBanner = nil
        updateCompletedReadyToRelaunch = false
        if !useDmgAfterGitSync && rebuildLauncher && updateInstallLogs.isEmpty {
            updateInstallLogs.removeAll()
        } else if !updateInstallLogs.isEmpty && !rebuildLauncher {
            // Keep clean log state at start of fresh update
            updateInstallLogs.removeAll()
        }
        
        updateChecker.applyUpdate(
            nxnativePath: nxnativePath,
            rebuildLauncher: rebuildLauncher,
            progressHandler: { [weak self] line in
                guard let self = self else { return }
                self.updateInstallLogs.append(line)
                
                let lower = line.lowercased()
                if lower.contains("preparing") {
                    self.updateProgressFraction = max(self.updateProgressFraction, 0.15)
                    self.updateStatusText = "Preparing repository..."
                } else if lower.contains("downloading") || lower.contains("fetch") {
                    self.updateProgressFraction = max(self.updateProgressFraction, 0.28)
                    self.updateStatusText = "Synchronizing repository..."
                } else if lower.contains("merging") || lower.contains("fast-forward") {
                    self.updateProgressFraction = max(self.updateProgressFraction, 0.38)
                    self.updateStatusText = "Merging update files..."
                } else if lower.contains("patches") {
                    self.updateProgressFraction = max(self.updateProgressFraction, 0.48)
                    self.updateStatusText = "Applying engine patches..."
                } else if lower.contains("compiling") || lower.contains("build_gui") || lower.contains("compilando") {
                    self.updateProgressFraction = max(self.updateProgressFraction, 0.80)
                    self.updateStatusText = "Compiling NxNative Launcher..."
                } else if rebuildLauncher && (lower.contains("sucesso") || lower.contains("updated & installed")) {
                    self.updateProgressFraction = 1.0
                    self.updateStatusText = "Update complete!"
                }
            },
            completion: { [weak self] success, message in
                guard let self = self else { return }
                if success && useDmgAfterGitSync {
                    // Repository synced cleanly; now download & stage the signed official DMG release
                    self.downloadAndInstallDmgUpdate(
                        autoRelaunch: autoRelaunch,
                        fallbackAfterGitSync: true,
                        allowSourceBuildFallback: true
                    )
                    return
                }
                
                self.isApplyingUpdate = false
                if success {
                    self.updateProgressFraction = 1.0
                    self.updateStatusText = "Update complete!"
                    self.updateSuccessBanner = message
                    self.updateErrorBanner = nil
                    self.updateCompletedReadyToRelaunch = true
                    if let current = self.updateInfo {
                        let updatedHead = self.updateChecker.getLocalCommit(nxnativePath: self.nxnativePath)
                        self.updateInfo = UpdateInfo(
                            hasUpdate: false,
                            localCommit: updatedHead,
                            remoteCommit: current.remoteCommit,
                            commitMessages: [],
                            checkDate: Date(),
                            repoURL: current.repoURL,
                            upstreamBehindCount: current.upstreamBehindCount,
                            upstreamCommitMessages: current.upstreamCommitMessages,
                            upstreamRepoURL: current.upstreamRepoURL,
                            releaseName: current.releaseName,
                            releaseSummary: current.releaseSummary,
                            releaseCategories: current.releaseCategories,
                            releaseMarkdown: current.releaseMarkdown
                        )
                    }
                    self.checkForUpdates(force: true)
                    self.refreshEnginePatches()
                    self.refreshPrerequisites()
                    self.logs.append(LogEntry(level: .success, message: message))
                    
                    if autoRelaunch {
                        self.updateInstallLogs.append("==> Automatic update finished! Relaunching NxNative Launcher in 2 seconds...")
                        DispatchQueue.main.asyncAfter(deadline: .now() + 2.0) { [weak self] in
                            self?.relaunchUpdatedLauncher()
                        }
                    }
                } else {
                    if message.localizedCaseInsensitiveContains("compiling NxNative Launcher failed") {
                        self.updateInstallLogs.append("==> Local Swift compilation unavailable (\(message)); falling back to official prebuilt DMG installer...")
                        self.logs.append(LogEntry(level: .warning, message: "Local compilation unavailable; falling back to prebuilt DMG installer."))
                        self.downloadAndInstallDmgUpdate(autoRelaunch: autoRelaunch, fallbackAfterGitSync: true, allowSourceBuildFallback: false)
                    } else {
                        self.updateErrorBanner = message
                        self.logs.append(LogEntry(level: .error, message: message))
                    }
                }
            }
        )
    }
    
    public func downloadAndInstallDmgUpdate(
        autoRelaunch: Bool = false,
        fallbackAfterGitSync: Bool = false,
        allowSourceBuildFallback: Bool = false
    ) {
        guard !isBuilding else {
            let msg = tr("build.update_locked_during_build")
            self.updateErrorBanner = msg
            self.logs.append(LogEntry(level: .warning, message: "[Update] \(msg)"))
            return
        }
        
        let resolvedTag: String? = {
            if let info = updateInfo, (info.hasUpdate || fallbackAfterGitSync),
               !info.remoteCommit.isEmpty, UpdateCheckerService.isSemverTag(info.remoteCommit) {
                return info.remoteCommit
            }
            if let cachedTag = GitLabReleaseNotesService.shared.cachedPayload()?.tagName,
               UpdateCheckerService.isSemverTag(cachedTag) {
                return cachedTag
            }
            if UpdateCheckerService.isSemverTag(effectiveReleaseTag) {
                return effectiveReleaseTag
            }
            return nil
        }()
        
        isApplyingUpdate = true
        updateProgressFraction = max(updateProgressFraction, fallbackAfterGitSync ? 0.50 : 0.05)
        updateStatusText = "Preparing DMG download..."
        updateErrorBanner = nil
        updateSuccessBanner = nil
        updateCompletedReadyToRelaunch = false
        if !fallbackAfterGitSync {
            updateInstallLogs.removeAll()
        }
        
        if let rawTag = resolvedTag, !rawTag.isEmpty {
            performDmgDownload(rawTag: rawTag, autoRelaunch: autoRelaunch, allowSourceBuildFallback: allowSourceBuildFallback)
        } else {
            // Never use a raw commit SHA as DMG package version: fetch latest tag from GitLab API first
            updateInstallLogs.append("==> Resolving latest release tag from GitLab...")
            GitLabReleaseNotesService.shared.fetchLatestRelease(force: true) { [weak self] payload in
                DispatchQueue.main.async {
                    guard let self = self else { return }
                    if let tagName = payload?.tagName, UpdateCheckerService.isSemverTag(tagName) {
                        self.performDmgDownload(rawTag: tagName, autoRelaunch: autoRelaunch, allowSourceBuildFallback: allowSourceBuildFallback)
                    } else if allowSourceBuildFallback && !self.nxnativePath.isEmpty {
                        self.updateInstallLogs.append("==> No DMG release tag available; compiling locally from repository...")
                        self.runGitUpdateFlow(autoRelaunch: autoRelaunch, rebuildLauncher: true, useDmgAfterGitSync: false)
                    } else {
                        self.isApplyingUpdate = false
                        self.updateErrorBanner = "No release tag available to download."
                    }
                }
            }
        }
    }
    
    private func performDmgDownload(rawTag: String, autoRelaunch: Bool, allowSourceBuildFallback: Bool) {
        let targetVersion = rawTag.trimmingCharacters(in: CharacterSet(charactersIn: "vV"))
        let gitDir = URL(fileURLWithPath: nxnativePath).appendingPathComponent(".git").path
        let hasGitRepo = isNxnativeValid && !nxnativePath.isEmpty && FileManager.default.fileExists(atPath: gitDir)
        let cachedRelease = GitLabReleaseNotesService.shared.cachedPayload()
        let token = updateChecker.extractGitLabToken(in: nxnativePath)

        LauncherSelfUpdater.shared.downloadVerifyAndStage(
            version: targetVersion,
            dmgURLString: cachedRelease?.dmgAssetURL,
            sha256URLString: cachedRelease?.sha256AssetURL,
            token: token,
            progress: { [weak self] frac, status in
                guard let self = self else { return }
                self.updateProgressFraction = max(self.updateProgressFraction, frac)
                self.updateStatusText = status
            },
            log: { [weak self] line in
                DispatchQueue.main.async {
                    self?.updateInstallLogs.append(line)
                }
            },
            completion: { [weak self] result in
                DispatchQueue.main.async {
                    guard let self = self else { return }
                    switch result {
                    case .success(let stagedAppPath):
                        self.updateChecker.stagedUpdateAppPath = stagedAppPath
                        self.updateProgressFraction = 1.0
                        self.updateStatusText = "Update verified and ready!"
                        self.updateSuccessBanner = "NxNative Launcher v\(targetVersion) verified and ready to launch!"
                        self.updateCompletedReadyToRelaunch = true
                        self.isApplyingUpdate = false

                        if autoRelaunch {
                            self.updateInstallLogs.append("==> Installing update & relaunching NxNative Launcher...")
                            DispatchQueue.main.asyncAfter(deadline: .now() + 0.8) { [weak self] in
                                self?.relaunchUpdatedLauncher(sourceAppPath: stagedAppPath)
                            }
                        }
                    case .failure(let error):
                        if allowSourceBuildFallback && hasGitRepo && self.isDeveloperMode {
                            self.updateInstallLogs.append("==> DMG install fallback (\(error.localizedDescription)); compiling locally via build_gui.sh...")
                            self.runGitUpdateFlow(autoRelaunch: autoRelaunch, rebuildLauncher: true, useDmgAfterGitSync: false)
                        } else {
                            self.isApplyingUpdate = false
                            self.updateErrorBanner = error.localizedDescription
                            self.logs.append(LogEntry(level: .error, message: "[Update] \(error.localizedDescription)"))
                        }
                    }
                }
            }
        )
    }
    
    public func relaunchUpdatedLauncher(sourceAppPath: String? = nil) {
        updateChecker.relaunchLauncher(
            nxnativePath: nxnativePath,
            sourceAppPath: sourceAppPath ?? updateChecker.stagedUpdateAppPath
        ) { [weak self] errorMsg in
            guard let self = self else { return }
            self.isApplyingUpdate = false
            self.updateCompletedReadyToRelaunch = false
            self.updateErrorBanner = errorMsg
            self.showUpdateSheet = true
            self.logs.append(LogEntry(level: .error, message: "[Updater] \(errorMsg)"))
        }
    }
    
    /// Syncs upstream engine updates from seedds/nxnative (GitHub) into the local repository
    public func syncUpstreamEngine() {
        guard !isBuilding else {
            let msg = tr("build.update_locked_during_build")
            self.updateErrorBanner = msg
            self.logs.append(LogEntry(level: .warning, message: "[Sync] \(msg)"))
            return
        }
        guard isNxnativeValid, !nxnativePath.isEmpty else { return }
        let gitDir = URL(fileURLWithPath: nxnativePath).appendingPathComponent(".git").path
        guard FileManager.default.fileExists(atPath: gitDir) else {
            let msg = "Syncing upstream requires a Git repository clone."
            self.updateErrorBanner = msg
            self.logs.append(LogEntry(level: .warning, message: "[Sync] \(msg)"))
            return
        }
        isSyncingUpstream = true
        updateProgressFraction = 0.08
        updateStatusText = "Preparing upstream synchronization..."
        updateErrorBanner = nil
        updateSuccessBanner = nil
        updateCompletedReadyToRelaunch = false
        updateInstallLogs.removeAll()
        
        updateChecker.syncUpstream(
            nxnativePath: nxnativePath,
            rebuildLauncher: false,
            progressHandler: { [weak self] line in
                guard let self = self else { return }
                self.updateInstallLogs.append(line)
                self.logs.append(LogEntry(level: .info, message: line))
                
                let lower = line.lowercased()
                if lower.contains("fetching") || lower.contains("synchronizing") {
                    self.updateProgressFraction = max(self.updateProgressFraction, 0.25)
                    self.updateStatusText = "Fetching upstream commits..."
                } else if lower.contains("merging") || lower.contains("auto-resolving") {
                    self.updateProgressFraction = max(self.updateProgressFraction, 0.45)
                    self.updateStatusText = "Merging upstream engine..."
                } else if lower.contains("re-applying") || lower.contains("patches") {
                    self.updateProgressFraction = max(self.updateProgressFraction, 0.65)
                    self.updateStatusText = "Verifying compatibility patches..."
                } else if lower.contains("dmhost") || lower.contains("unit tests") || lower.contains("verification") {
                    self.updateProgressFraction = max(self.updateProgressFraction, 0.82)
                    self.updateStatusText = "Verifying & rebuilding engine host..."
                } else if lower.contains("merge completed") || lower.contains("promoting") {
                    self.updateProgressFraction = 1.0
                    self.updateStatusText = "Upstream synchronization complete!"
                }
            },
            completion: { [weak self] success, message in
                guard let self = self else { return }
                self.isSyncingUpstream = false
                if success {
                    self.updateProgressFraction = 1.0
                    self.updateStatusText = "Upstream synchronization complete!"
                    self.updateSuccessBanner = message
                    if let current = self.updateInfo {
                        let updatedHead = self.updateChecker.getLocalCommit(nxnativePath: self.nxnativePath)
                        self.updateInfo = UpdateInfo(
                            hasUpdate: current.hasUpdate,
                            localCommit: updatedHead,
                            remoteCommit: current.remoteCommit,
                            commitMessages: current.commitMessages,
                            checkDate: Date(),
                            repoURL: current.repoURL,
                            upstreamBehindCount: 0,
                            upstreamCommitMessages: [],
                            upstreamRepoURL: current.upstreamRepoURL,
                            releaseName: current.releaseName,
                            releaseSummary: current.releaseSummary,
                            releaseCategories: current.releaseCategories,
                            releaseMarkdown: current.releaseMarkdown
                        )
                    }
                    self.checkForUpdates(force: true)
                    self.refreshEnginePatches()
                    self.refreshPrerequisites()
                    self.logs.append(LogEntry(level: .success, message: message))
                } else {
                    self.updateErrorBanner = message
                    self.logs.append(LogEntry(level: .error, message: message))
                }
            }
        )
    }
    
    // MARK: - Delegate Implementations
    public func installerDidProduceOutput(_ line: String) {
        installerLogs.append(line)
        if onboardingIsInstalling {
            handleOnboardingInstallerOutput(line)
        }
    }
    
    public func installerDidStartItem(_ name: String) {
        installerCurrentItem = name
        if onboardingIsInstalling {
            onboardingSubstatusMessage = name
        } else if isAutoProvisioningDependencies {
            provisioningStatus = tr("provisioning.installing_item", name)
        }
    }
    
    public func installerDidFinishItem(_ name: String, success: Bool) {}
    
    public func installerDidCompleteAll(allSuccess: Bool) {
        installerCurrentItem = nil
        if isAutoProvisioningDependencies || (!isCloningRepository && !isProvisioningBusy) {
            provisioningStatus = ""
        }
    }
    
    public func updateCheckerDidFindUpdate(_ info: UpdateInfo) {
        if isBuilding {
            self.logs.append(LogEntry(level: .info, message: "nxnative update available: \(info.commitMessages.count) new commits (update deferred until current build finishes)."))
        } else {
            self.logs.append(LogEntry(level: .info, message: "nxnative update available: \(info.commitMessages.count) new commits."))
        }
    }
    
    public func updateCheckerDidProduceLog(_ message: String) {
        self.logs.append(LogEntry(level: .info, message: message))
    }

    // MARK: - Dynamic GitLab Release Notes & Localization

    public var rawReleaseCategories: [ReleaseHighlightCategory] {
        if let cats = updateInfo?.releaseCategories, !cats.isEmpty {
            return cats
        }
        return GitLabReleaseNotesService.shared.cachedPayload()?.categories ?? []
    }

    public var rawReleaseSummary: String? {
        if let summary = updateInfo?.releaseSummary, !summary.isEmpty {
            return summary
        }
        return GitLabReleaseNotesService.shared.cachedPayload()?.summary
    }

    public var effectiveReleaseTag: String {
        if let remote = updateInfo?.remoteCommit, !remote.isEmpty {
            return remote
        }
        if let cachedTag = GitLabReleaseNotesService.shared.cachedPayload()?.tagName, !cachedTag.isEmpty {
            return cachedTag
        }
        let ver = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "2.2.4"
        return "v\(ver)"
    }

    public var canToggleReleaseTranslation: Bool {
        LocalizationService.shared.effectiveLanguage != .en && translatedReleaseCategories != nil
    }

    public var effectiveReleaseCategories: [ReleaseHighlightCategory] {
        if !showOriginalReleaseNotes,
           LocalizationService.shared.effectiveLanguage != .en,
           let translated = translatedReleaseCategories, !translated.isEmpty {
            return translated
        }
        return rawReleaseCategories
    }

    public var effectiveReleaseSummary: String? {
        if !showOriginalReleaseNotes,
           LocalizationService.shared.effectiveLanguage != .en,
           let translated = translatedReleaseSummary, !translated.isEmpty {
            return translated
        }
        return rawReleaseSummary
    }

    public func refreshReleaseNotesTranslation() {
        let lang = LocalizationService.shared.effectiveLanguage
        guard lang != .en else {
            DispatchQueue.main.async {
                self.translatedReleaseSummary = nil
                self.translatedReleaseCategories = nil
                self.isTranslatingReleaseNotes = false
            }
            return
        }

        let categories = rawReleaseCategories
        guard !categories.isEmpty else { return }

        let tag = effectiveReleaseTag
        let summary = rawReleaseSummary ?? ""

        if let cached = ReleaseNotesTranslator.shared.cachedTranslation(tag: tag, language: lang) {
            DispatchQueue.main.async {
                self.translatedReleaseSummary = cached.summary
                self.translatedReleaseCategories = cached.categories
                self.isTranslatingReleaseNotes = false
            }
            return
        }

        DispatchQueue.main.async {
            self.isTranslatingReleaseNotes = true
        }

        ReleaseNotesTranslator.shared.translate(tag: tag, summary: summary, categories: categories, to: lang) { [weak self] translated in
            guard let self = self else { return }
            self.isTranslatingReleaseNotes = false
            if let translated = translated {
                self.translatedReleaseSummary = translated.summary
                self.translatedReleaseCategories = translated.categories
            }
        }
    }
}
