import Foundation
import AppKit

/// Deployment target to execute automatically after defective `.ipa` files have been removed and re-ported.
public enum RepairDeployTarget {
    case individual(game: PortedGame, mode: NxDeploymentTargetMode)
    case multiPort(selectedGames: [PortedGame], failingGames: [PortedGame])

    public var isMultiPort: Bool {
        if case .multiPort = self { return true }
        return false
    }
}

/// Orchestrates moving failing/obsolete `.ipa` files to Trash (preserving `_build` shader caches),
/// sequentially re-porting clean `.ipa` packages into their original folders, and deploying
/// with the user's chosen strategy (Individual: NxN Launcher/Standalone, or Multi-Port batch).
public final class IpaRepairDeployCoordinator: ObservableObject {
    public static let shared = IpaRepairDeployCoordinator()

    @Published public var isRepairing: Bool = false
    @Published public var currentQueueIndex: Int = 0
    @Published public var totalQueueCount: Int = 0
    @Published public var currentGameName: String = ""
    @Published public var currentStageLabel: String = ""
    @Published public var currentStepLabel: String = ""
    @Published public var currentGameProgress: Double = 0.0
    @Published public var targetModeDescription: String = ""
    @Published public var lastErrorMessage: String? = nil
    @Published public var lastInfoMessage: String? = nil

    private struct RepairJob {
        let failedGame: PortedGame
        let sourceGame: SelectableGame
        let outputFolder: URL
        let preservedAppName: String
        let separateRomfs: Bool
    }

    private var jobs: [RepairJob] = []
    private var rebuiltGamesByOriginalPath: [String: PortedGame] = [:]
    private var activeTarget: RepairDeployTarget? = nil
    private weak var activeViewModel: AppViewModel? = nil
    private var activeDevice: ConnectedAppleDevice? = nil
    private var activeTeam: DeveloperSigningTeam? = nil
    private var onBatchCompleted: ((_ success: Bool, _ message: String) -> Void)? = nil

    private init() {}

    public var overallProgress: Double {
        guard totalQueueCount > 0 else { return 0.0 }
        let completedFraction = Double(max(0, currentQueueIndex - 1)) / Double(totalQueueCount)
        let activeFraction = min(1.0, max(0.0, currentGameProgress)) / Double(totalQueueCount)
        return min(1.0, completedFraction + activeFraction)
    }

    /// Starts the automated flow: locates source ROMs/NSPs for defective `.ipa`(s), moves defective `.ipa` artifacts to Trash
    /// while preserving `_build` shader caches, re-ports sequentially, and auto-deploys via Individual or Multi-Port.
    public func startRepairAndDeploy(
        target: RepairDeployTarget,
        viewModel: AppViewModel,
        device: ConnectedAppleDevice?,
        team: DeveloperSigningTeam?,
        onDeploymentFinished: ((_ success: Bool, _ message: String) -> Void)? = nil
    ) {
        guard !isRepairing, !viewModel.isBuilding else { return }

        let gamesToRebuild: [PortedGame]
        let modeText: String
        switch target {
        case .individual(let game, let mode):
            gamesToRebuild = [game]
            modeText = mode == .consoleHub
                ? L10n.t("nxn_launcher.mode_hub_title")
                : L10n.t("nxn_launcher.mode_standalone_title")
        case .multiPort(_, let failingGames):
            gamesToRebuild = failingGames
            modeText = L10n.t("nxn_launcher.tab_multi")
        }

        guard !gamesToRebuild.isEmpty else { return }

        // Pre-flight check: engine repository and disk space before trashing anything
        guard viewModel.isNxnativeValid else {
            lastErrorMessage = L10n.t("ipa_health.err_nxnative_invalid")
            SoundEffectService.shared.play(.error)
            return
        }
        guard !viewModel.isDiskSpaceLow else {
            lastErrorMessage = L10n.t("ipa_health.err_disk_low")
            SoundEffectService.shared.play(.error)
            return
        }

        lastErrorMessage = nil
        lastInfoMessage = nil
        currentStageLabel = L10n.t("ipa_health.locating_sources")

        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            guard let self = self else { return }
            let extraScanned = self.scanFallbackSourceGames(viewModel: viewModel)

            DispatchQueue.main.async {
                var preparedJobs: [RepairJob] = []
                let allCandidates = self.mergedSelectableGames(primary: viewModel.detectedGames, fallback: extraScanned)

                for ported in gamesToRebuild {
                    let source = self.matchSelectableGame(for: ported, candidates: allCandidates, viewModel: viewModel)
                        ?? self.promptUserForSourcePackage(for: ported, viewModel: viewModel)

                    guard let matchedSource = source else {
                        let msg = L10n.t("ipa_health.err_source_not_found", ported.name)
                        self.isRepairing = false
                        self.currentStageLabel = ""
                        self.lastErrorMessage = msg
                        SoundEffectService.shared.play(.error)
                        onDeploymentFinished?(false, msg)
                        return
                    }

                    if !viewModel.isProdKeysValid && !matchedSource.isSwitch2 && !matchedSource.isNup && !matchedSource.isDumpFolder {
                        let msg = L10n.t("ipa_health.err_prodkeys_invalid")
                        self.isRepairing = false
                        self.currentStageLabel = ""
                        self.lastErrorMessage = msg
                        SoundEffectService.shared.play(.error)
                        onDeploymentFinished?(false, msg)
                        return
                    }

                    let ipaURL = self.resolvedIpaURL(for: ported, viewModel: viewModel)
                    let outFolder = ipaURL.deletingLastPathComponent()
                    let stemName = ipaURL.pathExtension.lowercased() == "ipa"
                        ? ipaURL.deletingPathExtension().lastPathComponent
                        : ported.name

                    let report = IpaHealthService.shared.cachedReport(for: ported)
                        ?? (ipaURL.pathExtension.lowercased() == "ipa"
                            ? IpaHealthService.shared.inspectSync(ipaURL: ipaURL, titleIdHint: ported.titleId, romfsThresholdGB: viewModel.autoRomfsSplitLimitGB)
                            : nil)
                    let hasOversizedRomfs = report?.issues.contains(where: {
                        if case .oversizedEmbeddedRomfs = $0 { return true }
                        return false
                    }) ?? false
                    let exceedsLimit = Double(matchedSource.totalSizeBytes) >= viewModel.autoRomfsSplitLimitGB * 1_073_741_824.0
                    let separateRomfs = hasOversizedRomfs || exceedsLimit || viewModel.romfsSeparate

                    preparedJobs.append(RepairJob(
                        failedGame: ported,
                        sourceGame: matchedSource,
                        outputFolder: outFolder,
                        preservedAppName: stemName,
                        separateRomfs: separateRomfs
                    ))
                }

                guard !preparedJobs.isEmpty else { return }

                self.jobs = preparedJobs
                self.rebuiltGamesByOriginalPath.removeAll()
                self.activeTarget = target
                self.activeViewModel = viewModel
                self.activeDevice = device
                self.activeTeam = team
                self.onBatchCompleted = onDeploymentFinished

                self.isRepairing = true
                self.totalQueueCount = preparedJobs.count
                self.currentQueueIndex = 0
                self.targetModeDescription = modeText
                self.lastErrorMessage = nil

                DeviceDeploymentService.shared.dismissDeploymentStatus()
                self.runJob(at: 0)
            }
        }
    }

    public func cancelRepair() {
        guard isRepairing else { return }
        let vm = activeViewModel
        resetState()
        vm?.cancelBuild()
    }

    // MARK: - BuildRunner Event Forwarding from AppViewModel+BuildRunner
    public func handleBuildStage(_ name: String, index: Int, total: Int) {
        guard isRepairing else { return }
        currentStageLabel = "[\(index)/\(max(1, total))] \(name)"
        currentStepLabel = ""
        currentGameProgress = max(currentGameProgress, Double(max(0, index - 1)) / Double(max(1, total)))
    }

    public func handleBuildStep(_ step: String) {
        guard isRepairing else { return }
        currentStepLabel = step
    }

    public func handleBuildProgress(_ fraction: Double, totalStages: Int, stageIndex: Int) {
        guard isRepairing else { return }
        let n = Double(max(1, totalStages))
        let k = Double(max(1, stageIndex))
        let combined = ((k - 1.0) + min(1.0, max(0.0, fraction))) / n
        currentGameProgress = max(currentGameProgress, min(0.99, combined))
    }

    public func handleBuildFinished(success: Bool, outputPath: String?, error: String?) {
        guard isRepairing else { return }

        guard success, let outPath = outputPath else {
            let failedName = currentGameName.isEmpty ? "Game" : currentGameName
            let msg = error ?? L10n.t("ipa_health.err_rebuild_failed", failedName)
            let cb = onBatchCompleted
            resetState()
            lastErrorMessage = msg
            SoundEffectService.shared.play(.error)
            cb?(false, msg)
            return
        }

        let jobIdx = currentQueueIndex - 1
        if jobIdx >= 0 && jobIdx < jobs.count {
            let job = jobs[jobIdx]
            let rebuiltURL = URL(fileURLWithPath: outPath)
            IpaHealthService.shared.invalidateCache(for: rebuiltURL)

            let scanned = LibraryScanner.shared.scan(directories: [], extraAppURLs: [rebuiltURL]).first
            let resolvedGame = scanned ?? PortedGame(
                name: job.preservedAppName,
                url: rebuiltURL,
                platform: .ios,
                sizeBytes: Int64((try? rebuiltURL.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0),
                modificationDate: Date(),
                bundleId: job.failedGame.bundleId,
                titleId: job.sourceGame.titleId ?? job.failedGame.titleId,
                versionString: job.failedGame.versionString
            )
            rebuiltGamesByOriginalPath[job.failedGame.stableId] = resolvedGame
            IpaHealthService.shared.inspectAsync(game: resolvedGame, forceRefresh: true)
        }

        let nextIdx = currentQueueIndex
        if nextIdx < jobs.count {
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.35) { [weak self] in
                self?.runJob(at: nextIdx)
            }
        } else {
            finalizeAndDeploy()
        }
    }

    // MARK: - Private Pipeline
    private func runJob(at index: Int) {
        guard isRepairing, index < jobs.count, let vm = activeViewModel else {
            resetState()
            return
        }

        let job = jobs[index]
        currentQueueIndex = index + 1
        currentGameName = job.failedGame.name
        currentStageLabel = L10n.t("ipa_health.removing_failed_ipa")
        currentStepLabel = job.failedGame.url.lastPathComponent
        currentGameProgress = 0.03

        // 1. Move failed .ipa artifacts to Trash (keeping _build shaders & external .romfs.img intact)
        let trashResult = IpaHealthService.shared.trashFailedIpaArtifacts(for: job.failedGame, purgeStaleFramework: true)
        for p in trashResult.trashedPaths {
            vm.logs.append(LogEntry(level: .warning, message: "[Repair] Moved defective artifact to Trash: \(URL(fileURLWithPath: p).lastPathComponent)"))
        }
        for e in trashResult.errors {
            vm.logs.append(LogEntry(level: .warning, message: "[Repair] \(e)"))
        }

        let stdOldPath = job.failedGame.url.standardizedFileURL.path
        vm.hiddenGamePaths.remove(stdOldPath)
        vm.removedGamePaths.remove(stdOldPath)

        // 2. Configure overrides on AppViewModel without mutating persisted Build tab user settings
        if let firstFileDir = job.sourceGame.files.first?.url.deletingLastPathComponent() {
            vm.isUpdatingSelectedGameFolderFromAdd = true
            vm.selectedGameFolder = firstFileDir
            vm.isUpdatingSelectedGameFolderFromAdd = false
        }
        vm.platform = .ios
        vm.selectedGame = job.sourceGame
        vm.appName = job.preservedAppName
        vm.autoDeployToDeviceOnFinish = false

        vm.repairOverrideOutputFolder = job.outputFolder
        vm.repairOverrideAppName = job.preservedAppName
        vm.repairOverrideRomfsSeparate = job.separateRomfs
        vm.repairOverrideAllowOtherMetal = true

        currentStageLabel = L10n.t("ipa_health.rebuilding_ipa_stage")
        currentStepLabel = "\(job.preservedAppName).ipa"

        vm.startBuild()

        if !vm.isBuilding {
            let msg = L10n.t("ipa_health.err_could_not_start_build", job.failedGame.name)
            let cb = onBatchCompleted
            resetState()
            lastErrorMessage = msg
            SoundEffectService.shared.play(.error)
            cb?(false, msg)
        }
    }

    public func clearMessages() {
        lastErrorMessage = nil
        lastInfoMessage = nil
    }

    private func finalizeAndDeploy() {
        let target = activeTarget
        let rebuiltMap = rebuiltGamesByOriginalPath
        let initialDevice = activeDevice ?? DeviceDeploymentService.shared.selectedDevice ?? DeviceDeploymentService.shared.connectedDevices.first
        let initialTeam = activeTeam ?? DeviceDeploymentService.shared.selectedSigningTeam ?? DeviceDeploymentService.shared.signingTeams.first
        let cb = onBatchCompleted

        guard let target = target else {
            resetState()
            return
        }

        if let dev = initialDevice, initialTeam != nil {
            resetState()
            dispatchDeployment(target: target, rebuiltMap: rebuiltMap, device: dev, team: initialTeam, completion: cb)
            return
        }

        // Always perform a fresh bounded devicectl + team scan before concluding no iOS device is connected.
        // Covers Multi-Port clicks before initial detection finished, or devices plugged/unlocked during re-porting.
        currentStageLabel = L10n.t("nxn_launcher.status_checking")
        currentStepLabel = ""
        currentGameProgress = 0.99

        DeviceDeploymentService.shared.discoverConnectedDevicesAsync { [weak self] devices, teams in
            guard let self = self else { return }
            self.resetState()

            let resolvedDevice = initialDevice
                ?? DeviceDeploymentService.shared.selectedDevice
                ?? devices.first(where: { $0.isAvailable })
                ?? devices.first
            let resolvedTeam = initialTeam
                ?? DeviceDeploymentService.shared.selectedSigningTeam
                ?? teams.first

            guard let dev = resolvedDevice else {
                let msg = L10n.t("ipa_health.rebuilt_no_device_ready")
                self.lastErrorMessage = nil
                self.lastInfoMessage = msg
                SoundEffectService.shared.play(.launch)
                cb?(false, msg)
                return
            }

            self.dispatchDeployment(target: target, rebuiltMap: rebuiltMap, device: dev, team: resolvedTeam, completion: cb)
        }
    }

    private func dispatchDeployment(
        target: RepairDeployTarget,
        rebuiltMap: [String: PortedGame],
        device dev: ConnectedAppleDevice,
        team: DeveloperSigningTeam?,
        completion cb: ((_ success: Bool, _ message: String) -> Void)?
    ) {
        lastErrorMessage = nil
        lastInfoMessage = nil

        switch target {
        case .individual(let originalGame, let mode):
            let finalGame = rebuiltMap[originalGame.stableId] ?? originalGame
            if mode == .consoleHub {
                NxHubDeploymentService.shared.deployToHub(
                    game: finalGame,
                    device: dev,
                    team: team
                ) { ok, msg in
                    DispatchQueue.main.async {
                        SoundEffectService.shared.play(ok ? .click : .error)
                        if !ok { self.lastErrorMessage = msg }
                        cb?(ok, msg)
                    }
                }
            } else {
                let deployURL = DeviceDeploymentService.shared.resolveDeployableURL(for: finalGame)
                DeviceDeploymentService.shared.installApp(
                    appBundleURL: deployURL,
                    on: dev,
                    team: team,
                    game: finalGame
                ) { ok, msg in
                    DispatchQueue.main.async {
                        SoundEffectService.shared.play(ok ? .click : .error)
                        if !ok { self.lastErrorMessage = msg }
                        cb?(ok, msg)
                    }
                }
            }

        case .multiPort(let selectedGames, _):
            let mergedGames: [PortedGame] = selectedGames.map { g in
                rebuiltMap[g.stableId] ?? g
            }
            guard !mergedGames.isEmpty else { return }

            DeviceDeploymentService.shared.activeDeployment = DeploymentProgressInfo(
                phase: .transferring,
                progressFraction: 0.05,
                statusMessage: "Preparando NxN Launcher...",
                detailMessage: dev.name,
                logLines: ["==> Todos os .ipa falhos foram re-portados. Iniciando envio Multi-Port para \(dev.name)..."],
                isRunning: true,
                targetDeviceName: dev.name,
                elapsedSeconds: 0
            )
            DeviceDeploymentService.shared.startElapsedTimer()

            NxHubDeploymentService.shared.validateDeviceStorage(for: mergedGames, on: dev) { ok, storageMsg in
                if !ok {
                    DispatchQueue.main.async {
                        DeviceDeploymentService.shared.activeDeployment.isRunning = false
                        DeviceDeploymentService.shared.activeDeployment.phase = .failed
                        DeviceDeploymentService.shared.activeDeployment.statusMessage = storageMsg
                        DeviceDeploymentService.shared.stopElapsedTimer()
                        SoundEffectService.shared.play(.error)
                        self.lastErrorMessage = storageMsg
                        cb?(false, storageMsg)
                    }
                    return
                }

                NxHubDeploymentService.shared.deployBatchToHub(
                    games: mergedGames,
                    device: dev,
                    team: team,
                    onProgress: { current, total, status in
                        DispatchQueue.main.async {
                            DeviceDeploymentService.shared.activeDeployment.statusMessage = "[\(current)/\(total)] \(status)"
                            let baseline = 0.05 + 0.25 * (Double(max(0, current - 1)) / Double(max(1, total)))
                            if DeviceDeploymentService.shared.activeDeployment.progressFraction < baseline {
                                DeviceDeploymentService.shared.activeDeployment.progressFraction = baseline
                            }
                        }
                    },
                    completion: { success, finalMsg in
                        DispatchQueue.main.async {
                            DeviceDeploymentService.shared.activeDeployment.isRunning = false
                            DeviceDeploymentService.shared.stopElapsedTimer()
                            if success {
                                SoundEffectService.shared.play(.click)
                                DeviceDeploymentService.shared.activeDeployment.phase = .completed
                                DeviceDeploymentService.shared.activeDeployment.progressFraction = 1.0
                                DeviceDeploymentService.shared.activeDeployment.statusMessage = finalMsg
                                self.lastErrorMessage = nil
                            } else {
                                SoundEffectService.shared.play(.error)
                                DeviceDeploymentService.shared.activeDeployment.phase = .failed
                                DeviceDeploymentService.shared.activeDeployment.statusMessage = finalMsg
                                self.lastErrorMessage = finalMsg
                            }
                            cb?(success, finalMsg)
                        }
                    }
                )
            }
        }
    }

    private func resetState() {
        isRepairing = false
        currentQueueIndex = 0
        totalQueueCount = 0
        currentGameName = ""
        currentStageLabel = ""
        currentStepLabel = ""
        currentGameProgress = 0.0
        targetModeDescription = ""
        jobs.removeAll()
        rebuiltGamesByOriginalPath.removeAll()
        activeTarget = nil
        activeViewModel = nil
        activeDevice = nil
        activeTeam = nil
        onBatchCompleted = nil
    }

    // MARK: - Source NSP/Folder Resolution
    private func resolvedIpaURL(for ported: PortedGame, viewModel: AppViewModel) -> URL {
        if ported.url.pathExtension.lowercased() == "ipa" {
            return ported.url
        }
        return viewModel.iosPort(for: ported)?.url ?? ported.url
    }

    private func scanFallbackSourceGames(viewModel: AppViewModel) -> [SelectableGame] {
        var dirs = viewModel.gameFolders + viewModel.nonSwitchGameFolders
        let nintendoRoot = URL(fileURLWithPath: "/Volumes/Nintendo/Games")
        if FileManager.default.fileExists(atPath: nintendoRoot.path) &&
           !dirs.contains(where: { $0.standardizedFileURL.path == nintendoRoot.standardizedFileURL.path }) {
            dirs.append(nintendoRoot)
        }
        guard !dirs.isEmpty else { return [] }
        let files = GameScanner.shared.scan(directories: dirs)
        return GameScanner.shared.groupFilesIntoGames(files: files)
    }

    private func mergedSelectableGames(primary: [SelectableGame], fallback: [SelectableGame]) -> [SelectableGame] {
        var seen = Set<String>()
        var merged: [SelectableGame] = []
        for g in primary + fallback {
            let key = (g.titleId?.uppercased() ?? "") + "::" + g.id
            if !seen.contains(key) {
                seen.insert(key)
                merged.append(g)
            }
        }
        return merged
    }

    private func matchSelectableGame(
        for ported: PortedGame,
        candidates: [SelectableGame],
        viewModel: AppViewModel
    ) -> SelectableGame? {
        if let tid = ported.titleId, !tid.isEmpty {
            if let byTid = candidates.first(where: { $0.titleId?.caseInsensitiveCompare(tid) == .orderedSame }) {
                return byTid
            }
        }
        let portedKey = viewModel.deduplicationKey(for: ported)
        if !portedKey.isEmpty,
           let byKey = candidates.first(where: { viewModel.deduplicationKey(for: $0) == portedKey }) {
            return byKey
        }
        let normPorted = GameScanner.shared.cleanGameTitle(ported.name).lowercased()
        return candidates.first {
            let normCand = GameScanner.shared.cleanGameTitle($0.name).lowercased()
            return normCand == normPorted || normCand.contains(normPorted) || normPorted.contains(normCand)
        }
    }

    private func promptUserForSourcePackage(for ported: PortedGame, viewModel: AppViewModel) -> SelectableGame? {
        let panel = NSOpenPanel()
        panel.title = L10n.t("ipa_health.select_source_title", ported.name)
        panel.message = L10n.t("ipa_health.select_source_message", ported.name)
        panel.canChooseFiles = true
        panel.canChooseDirectories = true
        panel.allowsMultipleSelection = false
        panel.prompt = L10n.t("common.choose")

        guard panel.runModal() == .OK, let url = panel.url else {
            return nil
        }

        let files = GameScanner.shared.scan(directory: url)
        let grouped = GameScanner.shared.groupFilesIntoGames(files: files)
        let folder = url.hasDirectoryPath ? url : url.deletingLastPathComponent()
        viewModel.addGameFolder(folder, openPortModalIfFound: false)

        return matchSelectableGame(for: ported, candidates: grouped, viewModel: viewModel) ?? grouped.first
    }
}
