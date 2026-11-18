import Foundation
import AppKit

extension AppViewModel {
    static let provisioningVersion = "1.9.9"
    private static let provisioningVersionKey = "NXNative_ProvisioningVersion"

    /// True when no game launch or port is in progress and onboarding has finished, so background work may run.
    private var isSafeForBackgroundProvisioning: Bool {
        !isShowingOnboarding && !isBuilding && launchingGameId == nil
    }

    /// Entry point (called once from init): first-run provisioning, version migrations and the 60 s auto-update loop.
    public func startAutoProvisioning() {
        let saved = UserDefaults.standard.string(forKey: Self.provisioningVersionKey)
        if saved != Self.provisioningVersion {
            logs.append(LogEntry(level: .info, message: "[Provisioning] Setup check on v\(Self.provisioningVersion) (previous: \(saved ?? "none")). Installing any missing dependencies in order…"))
            UserDefaults.standard.set(Self.provisioningVersion, forKey: Self.provisioningVersionKey)
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 2.5) { [weak self] in self?.provisioningTick() }
        let timer = Timer(timeInterval: 60, repeats: true) { [weak self] _ in self?.provisioningTick() }
        RunLoop.main.add(timer, forMode: .common)
        provisioningTimer = timer
    }

    /// Runs on initial launch, transitions between provisioning stages, and every 60 s. Non-blocking.
    public func provisioningTick() {
        guard isSafeForBackgroundProvisioning, !isProvisioningBusy else { return }

        // 1. Core Repository missing → download it first.
        if !isNxnativeValid {
            guard !isCloningRepository, Date() >= nextCloneAttempt else { return }
            nextCloneAttempt = Date().addingTimeInterval(300)
            provisioningStatus = tr("provisioning.cloning_repo")
            cloneNxnativeRepository()
            return
        }

        // Wait until initial prerequisite scan completes before evaluating missing tools (completion hook triggers next tick).
        if isCheckingPrerequisites {
            return
        }

        // 2. Missing tools in strict topological order, scoped ONLY to the user's enabled target platforms.
        // Android (NDK/adb) and iOS (libimobiledevice) are strictly opt-in and never auto-downloaded unless selected.
        let rawMissing = prerequisites.missingList(for: selectedOnboardingPlatforms).filter {
            $0.id != "xcode" && !($0.installCommand ?? "").trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        }
        let missing = SystemPrerequisites.ordered(rawMissing)

        if !missing.isEmpty && !isInstallingDependency {
            let needsAppleCltFirst = !prerequisites.xcode.isAvailable && missing.contains {
                $0.id == "homebrew" || ($0.installCommand ?? "").contains("brew ")
            }
            if needsAppleCltFirst {
                provisioningStatus = tr("provisioning.needs_clt")
                return
            }

            if Date() >= nextDependencyAttempt {
                nextDependencyAttempt = Date().addingTimeInterval(300)
                let queueSummary = missing.map(\.name).joined(separator: " -> ")
                provisioningStatus = tr("provisioning.installing_deps", missing.count)
                isInstallingDependency = true
                isAutoProvisioningDependencies = true
                installerLogs.removeAll()
                installerLogs.append("[Provisioning] Installing \(missing.count) missing dependency(ies) in order: \(queueSummary)")
                logs.append(LogEntry(level: .info, message: "[Provisioning] Installing missing dependencies: \(queueSummary)"))

                installer.installAll(dependencies: missing) { [weak self] ok in
                    guard let self = self else { return }
                    self.isInstallingDependency = false
                    self.isAutoProvisioningDependencies = false
                    self.installerCurrentItem = nil
                    self.provisioningStatus = ""
                    self.nextDependencyAttempt = Date().addingTimeInterval(ok ? 1800 : 300)
                    self.hasCompletedInitialProvisioningPass = true
                    self.logs.append(LogEntry(
                        level: ok ? .success : .warning,
                        message: "[Provisioning] Tool installation \(ok ? "completed" : "had failures; will retry later")."
                    ))
                    self.refreshPrerequisites()
                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.8) { [weak self] in
                        self?.provisioningTick()
                    }
                }
                return
            }
        } else if missing.isEmpty && !isInstallingDependency {
            if !isCloningRepository && !isProvisioningBusy {
                provisioningStatus = ""
            }
            hasCompletedInitialProvisioningPass = true
        }

        // 3. Metal Toolchain (Xcode 26+ ships it as a separate download).
        if let metal = metalToolchainInfo, !metal.isAvailable, Date() >= nextMetalAttempt,
           FileManager.default.fileExists(atPath: "/usr/bin/xcodebuild") {
            nextMetalAttempt = Date().addingTimeInterval(6 * 3600)
            provisioningStatus = tr("provisioning.downloading_metal")
            isProvisioningBusy = true
            DispatchQueue.global(qos: .utility).async { [weak self] in
                let res = BoundedProcess.run("/usr/bin/xcodebuild", ["-downloadComponent", "MetalToolchain"], timeout: 3600)
                DispatchQueue.main.async {
                    guard let self = self else { return }
                    self.isProvisioningBusy = false
                    self.provisioningStatus = ""
                    self.logs.append(LogEntry(level: res.success ? .success : .warning,
                        message: "[Provisioning] Metal Toolchain \(res.success ? "installed" : "download failed/skipped")."))
                    self.detectMetalToolchain()
                }
            }
            return
        }

        // 4. Core Repository auto-update (fetch + fast-forward) + optional nx2android auto-update when Android support is installed.
        let repo = nxnativePath
        let shouldUpdateNx2Android =
            (prerequisites.androidNdk.isAvailable || prerequisites.androidAdb.isAvailable) &&
            (prerequisites.androidNdk.isAvailable ||
             selectedOnboardingPlatforms.contains(.android) ||
             Nx2AndroidAutoUpdater.hasLocalInstall(nxnativePath: repo))

        isProvisioningBusy = true
        DispatchQueue.global(qos: .utility).async { [weak self] in
            let result = CoreRepoAutoUpdater.shared.updateIfNeeded(repoPath: repo)
            let nx2aResult: CoreRepoUpdateResult? = shouldUpdateNx2Android
                ? Nx2AndroidAutoUpdater.shared.updateIfNeeded(nxnativePath: repo)
                : nil

            DispatchQueue.main.async {
                guard let self = self else { return }
                self.isProvisioningBusy = false
                self.coreRepoLastCheck = Date()
                switch result {
                case .updated(let head):
                    // Never touch the tree under a running build/launch: re-check before patching.
                    PatchService.shared.applyPatchesIfNeeded(nxnativePath: repo)
                    self.refreshEnginePatches()
                    self.checkForUpdates()
                    self.logs.append(LogEntry(level: .success, message: "[Core Repo] Auto-updated to \(head)."))
                case .failed(let msg):
                    self.logs.append(LogEntry(level: .warning, message: "[Core Repo] Auto-update failed (will retry with backoff): \(msg.prefix(160))"))
                case .skipped(let reason) where reason != "backoff":
                    self.logs.append(LogEntry(level: .info, message: "[Core Repo] Auto-update skipped: \(reason)"))
                default:
                    break
                }

                if let nx2aResult = nx2aResult {
                    switch nx2aResult {
                    case .updated(let head):
                        self.logs.append(LogEntry(level: .success, message: "[nx2android] Auto-updated Android backend to \(head)."))
                        if !self.isLoadingCompatibility {
                            self.loadCompatibleGames(forceRefresh: true)
                        }
                    case .failed(let msg):
                        self.logs.append(LogEntry(level: .warning, message: "[nx2android] Auto-update failed (will retry with backoff): \(msg.prefix(160))"))
                    case .skipped(let reason) where reason != "cooldown" && reason != "backoff":
                        self.logs.append(LogEntry(level: .info, message: "[nx2android] Auto-update skipped: \(reason)"))
                    default:
                        break
                    }
                }
            }
        }
    }
}
