import Foundation
import AppKit

extension AppViewModel {
    // MARK: - BuildRunner Delegates
    public func buildRunner(_ runner: BuildRunner, didProduceLog entry: LogEntry) {
        logs.append(entry)
        if logs.count > 1200 {
            logs.removeFirst(200)
        }
    }
    
    public func buildRunner(_ runner: BuildRunner, didUpdateStage stage: String, index: Int, total: Int) {
        self.currentStageName = stage
        self.stageIndex = index
        self.totalStages = total
        
        for i in 0..<buildStages.count {
            if buildStages[i].id < index && buildStages[i].isRunning {
                buildStages[i].isRunning = false
                buildStages[i].isCompleted = true
            }
        }
        
        if let existingIdx = buildStages.firstIndex(where: { $0.id == index }) {
            buildStages[existingIdx].isRunning = true
            buildStages[existingIdx].step = ""
        } else {
            buildStages.append(BuildStageItem(id: index, name: stage, isRunning: true))
        }
        IpaRepairDeployCoordinator.shared.handleBuildStage(stage, index: index, total: total)
    }
    
    public func buildRunner(_ runner: BuildRunner, didUpdateStep step: String) {
        self.currentStepName = step
        if let idx = buildStages.firstIndex(where: { $0.id == stageIndex }) {
            buildStages[idx].step = step
        }
        IpaRepairDeployCoordinator.shared.handleBuildStep(step)
    }
    
    public func buildRunner(_ runner: BuildRunner, didUpdateProgress fraction: Double, doneBytes: Double?, totalBytes: Double?, etaSeconds: Double?) {
        self.progressFraction = fraction
        self.etaSeconds = etaSeconds
        IpaRepairDeployCoordinator.shared.handleBuildProgress(fraction, totalStages: totalStages, stageIndex: stageIndex)
    }
    
    public func buildRunner(_ runner: BuildRunner, didEndStage stage: String, index: Int, ok: Bool, elapsed: Double?, summary: String?) {
        if let idx = buildStages.firstIndex(where: { $0.id == index }) {
            buildStages[idx].isRunning = false
            buildStages[idx].isCompleted = ok
            buildStages[idx].isFailed = !ok
            buildStages[idx].elapsedSeconds = elapsed
            buildStages[idx].summary = summary
        }
    }
    
    public func buildRunner(_ runner: BuildRunner, didFinishSuccess outputPath: String?) {
        self.isBuilding = false
        self.buildingGameId = nil
        self.progressFraction = 1.0
        self.currentStageName = "Build Completed!"
        for i in 0..<buildStages.count {
            buildStages[i].isRunning = false
            buildStages[i].isCompleted = true
        }
        self.buildSuccessPath = outputPath
        self.logs.append(LogEntry(level: .success, message: "Build succeeded! Output: \(outputPath ?? "Unknown")"))
        
        if let out = outputPath {
            let targetURL = URL(fileURLWithPath: out)
            let gName = appName.isEmpty ? (selectedGame?.name ?? "Game") : appName
            let tId = selectedGame?.titleId
            GameCoverService.shared.injectCoverIntoBundle(
                at: targetURL,
                gameName: gName,
                titleId: tId
            )
            
            // If ported game is Zelda Ocarina of Time Remake, initialize with 2.0.1 default configuration
            let isOot = (tId?.uppercased() == "0400486024DEC000") ||
                        gName.localizedCaseInsensitiveContains("Ocarina") ||
                        LibraryScanner.shared.isOcarinaOfTime(at: targetURL)
            if isOot {
                let actualSize: Int64 = {
                    if self.platform == .ios {
                        return Int64((try? targetURL.resourceValues(forKeys: [.fileSizeKey]))?.fileSize ?? 0)
                    } else {
                        return LibraryScanner.shared.calculateDirectorySize(url: targetURL)
                    }
                }()
                let dummyOot = PortedGame(
                    name: gName,
                    url: targetURL,
                    platform: self.platform,
                    sizeBytes: actualSize,
                    modificationDate: Date(),
                    bundleId: "org.nxnative.0400486024dec000",
                    titleId: "0400486024DEC000",
                    versionString: "1.0.0"
                )
                let ootConfig = GameRuntimeConfig.defaultOotConfig()
                ootConfig.save(for: dummyOot)
            }
        }
        
        self.clearRepairOverrides()

        let outURL = outputPath.map { URL(fileURLWithPath: $0) }
        if let builtURL = outURL {
            IpaHealthService.shared.invalidateCache(for: builtURL)
        }
        refreshLibrary(focusOnOutputURL: outURL)
        
        SoundEffectService.shared.play(.launch)
        NotificationService.shared.sendPortSuccessNotification(
            gameName: appName.isEmpty ? "Ported Game" : appName,
            outputPath: outputPath
        )

        if IpaRepairDeployCoordinator.shared.isRepairing {
            IpaRepairDeployCoordinator.shared.handleBuildFinished(success: true, outputPath: outputPath, error: nil)
            return
        }
        
        // Auto-deploy to iOS device if requested by user in Port modal
        if self.autoDeployToDeviceOnFinish && self.platform == .ios, let out = outputPath {
            let ipaURL = URL(fileURLWithPath: out)
            DispatchQueue.main.asyncAfter(deadline: .now() + 1.0) { [weak self] in
                DeviceDeploymentService.shared.refreshDevicesAndTeams()
                if let dev = DeviceDeploymentService.shared.selectedDevice ?? DeviceDeploymentService.shared.connectedDevices.first {
                    let team = DeviceDeploymentService.shared.selectedSigningTeam ?? DeviceDeploymentService.shared.signingTeams.first
                    if NxHubDeploymentService.shared.deploymentMode == .consoleHub {
                        let portedGame = LibraryScanner.shared.scan(directories: [], extraAppURLs: [ipaURL]).first
                            ?? PortedGame(
                                name: self?.appName.isEmpty == false ? self!.appName : (self?.selectedGame?.name ?? ipaURL.deletingPathExtension().lastPathComponent),
                                url: ipaURL,
                                platform: .ios,
                                sizeBytes: Int64((try? ipaURL.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0),
                                modificationDate: Date(),
                                bundleId: nil,
                                titleId: self?.selectedGame?.titleId,
                                versionString: "1.0.0"
                            )
                        NxHubDeploymentService.shared.deployToHub(game: portedGame, device: dev, team: team) { [weak self] ok, msg in
                            if ok {
                                IosDeploymentTracker.shared.recordDeployment(forGameUrl: ipaURL, deviceName: dev.name, deviceId: dev.id)
                            }
                            self?.logs.append(LogEntry(level: ok ? .success : .error, message: "[Auto-Deploy] \(msg)"))
                        }
                    } else {
                        DeviceDeploymentService.shared.installApp(appBundleURL: ipaURL, on: dev, team: team) { [weak self] ok, msg in
                            if ok {
                                IosDeploymentTracker.shared.recordDeployment(forGameUrl: ipaURL, deviceName: dev.name, deviceId: dev.id)
                            }
                            self?.logs.append(LogEntry(level: ok ? .success : .error, message: "[Auto-Deploy] \(msg)"))
                        }
                    }
                }
            }
        }
    }
    
    public func buildRunner(_ runner: BuildRunner, didFinishWithError error: String) {
        self.isBuilding = false
        self.buildingGameId = nil
        self.clearRepairOverrides()
        if let idx = buildStages.firstIndex(where: { $0.isRunning }) {
            buildStages[idx].isRunning = false
            buildStages[idx].isFailed = true
        }
        self.buildError = error
        self.logs.append(LogEntry(level: .error, message: error))
        
        SoundEffectService.shared.play(.error)
        NotificationService.shared.sendPortErrorNotification(
            gameName: appName.isEmpty ? "Game" : appName,
            error: error
        )

        if IpaRepairDeployCoordinator.shared.isRepairing {
            IpaRepairDeployCoordinator.shared.handleBuildFinished(success: false, outputPath: nil, error: error)
        }
    }
}
