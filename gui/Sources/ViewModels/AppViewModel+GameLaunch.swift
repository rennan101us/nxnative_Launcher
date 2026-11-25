import Foundation
import AppKit

extension AppViewModel {
    public func launchGame(_ game: PortedGame) {
        guard game.isPlayableLocally else {
            logs.append(LogEntry(level: .warning, message: "Cannot launch iOS IPA locally on Mac. Please deploy to an iPhone or iPad."))
            return
        }
        guard launchingGameId == nil else { return }
        launchingGameId = game.id
        SoundEffectService.shared.play(.launch)
        
        let targetGameId = game.id
        // Fail-safe Watchdog: guarantees launchingGameId is reset if launch stalls
        DispatchQueue.main.asyncAfter(deadline: .now() + 6.0) { [weak self] in
            if self?.launchingGameId == targetGameId {
                self?.launchingGameId = nil
                SoundEffectService.shared.play(.error)
                self?.logs.append(LogEntry(level: .warning, message: "Launch watchdog cleared stuck launching state for \(game.name)."))
            }
        }
        
        recordLastPlayed(for: game)
        
        if game.platform == .nonSwitch {
            let openConfig = NSWorkspace.OpenConfiguration()
            openConfig.environment = ProcessInfo.processInfo.environment
            NSWorkspace.shared.openApplication(at: game.url, configuration: openConfig) { [weak self] runningApp, error in
                DispatchQueue.main.async {
                    self?.launchingGameId = nil
                    if let error = error {
                        SoundEffectService.shared.play(.error)
                        self?.logs.append(LogEntry(level: .error, message: "Failed to launch \(game.name): \(error.localizedDescription)"))
                    } else {
                        self?.runningGameTitle = game.name
                        self?.logs.append(LogEntry(level: .success, message: "Launched Mac native game: \(game.name)"))
                        if let app = runningApp {
                            let targetPid = app.processIdentifier
                            PlayTimeService.shared.startSession(for: game, pid: targetPid)
                            var observer: NSObjectProtocol?
                            observer = NSWorkspace.shared.notificationCenter.addObserver(
                                forName: NSWorkspace.didTerminateApplicationNotification,
                                object: nil,
                                queue: .main
                            ) { [weak self] notif in
                                if let termApp = notif.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication,
                                   termApp.processIdentifier == targetPid {
                                    if let obs = observer {
                                        NSWorkspace.shared.notificationCenter.removeObserver(obs)
                                        observer = nil
                                    }
                                    self?.runningGameTitle = nil
                                    PlayTimeService.shared.endSession(forPid: targetPid)
                                }
                            }
                        }
                    }
                }
            }
            return
        }
        
        let config = GameRuntimeConfig.load(for: game)
        config.applyToDisk(for: game)
        InputProfileManager.shared.exportMapping(for: game, config: config)
        
        // Ensure iCloud Cross-Save is configured with cover art if iCloud Sync is enabled by user
        var savePath: String? = nil
        var cloudSyncPath: String? = nil
        if SaveSyncService.shared.isICloudSyncEnabled(for: game) && SaveSyncService.shared.isICloudDriveAvailable {
            let cover = GameCoverService.shared.coverImage(for: game)
            SaveSyncService.shared.syncWithCloudDMSyncIfNeeded(for: game)
            switch SaveSyncService.shared.ensureCloudSaveConfigured(for: game, cover: cover) {
            case .success(let cloudSaveDir):
                savePath = cloudSaveDir.path
                cloudSyncPath = SaveSyncService.shared.iCloudRootURL.path
            case .failure(let error):
                logs.append(LogEntry(level: .warning, message: "[iCloud] \(error.localizedDescription)"))
            }
        }
        
        // Auto-sync saves with connected device before launch if available
        SaveSyncService.shared.autoSyncOnLaunch(for: game) { [weak self] status, msg in
            if let status = status, status != .noSaves && status != .alreadyInSync {
                self?.logs.append(LogEntry(level: .info, message: "Auto-sync on launch: \(msg)"))
            }
            var env = config.toEnvironmentDict(for: game, savePath: savePath)
            env["NXNATIVE_DATA_DIR"] = SystemDetector.shared.appSupportDirectory.path
            env["NXNATIVE_LOGS_DIR"] = SystemDetector.shared.logsDirectory.path
            env["TMPDIR"] = SystemDetector.shared.tempDirectory.path

            // Ensure RomFS Mod Overlay is set and logged
            if let tid = game.titleId ?? CompatibilityService.shared.findTitleId(forGameTitle: game.name), !tid.isEmpty {
                if env["DM_ROMFS_OVERLAY"] == nil,
                   let overlay = ModManagerService.shared.buildRomfsOverlayString(for: tid, appURL: game.url) {
                    env["DM_ROMFS_OVERLAY"] = overlay
                }
            }
            if let overlay = env["DM_ROMFS_OVERLAY"], !overlay.isEmpty {
                let layers = overlay.components(separatedBy: ":")
                self?.logs.append(LogEntry(level: .info, message: "Applied RomFS Mod Overlay (\(layers.count) active layer\(layers.count > 1 ? "s" : ""))."))
            }
            if GameRuntimeConfig.isOotGame(game) {
                let ramModeLabel = config.oot16GBRamMode ? "16GB Mode" : "Standard RAM"
                let fgLabel = config.ootExperimentalFrameGen ? ", Frame Blend 60/120Hz (maxK=\(config.ootFrameGenMaxK))" : ""
                let presetLabel = (config.ootResolutionPreset == "potato") ? ", Preset=Potato" : ""
                self?.logs.append(LogEntry(level: .info, message: "Zelda OoT Mode: Ultra Boost, RT=0, Lossy RT, Pool Skip, \(ramModeLabel)\(presetLabel)\(fgLabel)."))
            }
            if let csp = cloudSyncPath {
                env["DM_SAVE_SYNC"] = csp
            }
            let prof = InputProfileManager.shared.resolveProfile(for: game, config: config)
            let bundleMapping = game.url.appendingPathComponent("Contents/Resources/dm/input_mapping.json")
            if FileManager.default.fileExists(atPath: bundleMapping.path) {
                env["DM_INPUT_MAPPING"] = bundleMapping.path
            }
            if !config.enableGamepadProfile {
                env["DM_DISABLE_GAMEPAD_REMAP"] = "1"
            }
            if let leftBtn = prof.keyboardBindings[MouseKeyCode.left] {
                env["DM_MOUSE_BTN_LEFT"] = leftBtn.rawValue
            }
            if let rightBtn = prof.keyboardBindings[MouseKeyCode.right] {
                env["DM_MOUSE_BTN_RIGHT"] = rightBtn.rawValue
            }
            if let midBtn = prof.keyboardBindings[MouseKeyCode.middle] {
                env["DM_MOUSE_BTN_MIDDLE"] = midBtn.rawValue
            }
            if game.isSwitch2 {
                env["DM_SWITCH2_MOUSE"] = prof.mouseSwitch2Enabled ? "1" : "0"
                env["DM_SWITCH2_MOUSE_SPEED"] = String(format: "%.2f", locale: Locale(identifier: "en_US_POSIX"), prof.mouseSwitch2PointerSpeed)
                env["DM_SWITCH2_LOCK_CURSOR"] = prof.mouseSwitch2LockCursor ? "1" : "0"
                env["DM_SWITCH2_SWAP_BTNS"] = (prof.mouseSwitch2PrimaryButton == "right") ? "1" : "0"
                env["DM_SWITCH2_SIDE"] = prof.mouseSwitch2Side
                env["DM_SWITCH2_INVERT_Y"] = prof.mouseSwitch2InvertY ? "1" : "0"
                env["DM_MOUSE_RIGHT_STICK"] = (!prof.mouseSwitch2Enabled && prof.mouseAsRightStick) ? "1" : "0"
                env["DM_MOUSE_SENSITIVITY"] = String(format: "%.2f", locale: Locale(identifier: "en_US_POSIX"), prof.mouseSensitivity)
                env["DM_MOUSE_INVERT_X"] = prof.mouseInvertX ? "1" : "0"
                env["DM_MOUSE_INVERT_Y"] = prof.mouseInvertY ? "1" : "0"
                env["DM_MOUSE_MODE"] = prof.mouseRightStickMode
            } else {
                env["DM_SWITCH2_MOUSE"] = "0"
                env["DM_MOUSE_RIGHT_STICK"] = prof.mouseAsRightStick ? "1" : "0"
                env["DM_MOUSE_SENSITIVITY"] = String(format: "%.2f", locale: Locale(identifier: "en_US_POSIX"), prof.mouseSensitivity)
                env["DM_MOUSE_INVERT_X"] = prof.mouseInvertX ? "1" : "0"
                env["DM_MOUSE_INVERT_Y"] = prof.mouseInvertY ? "1" : "0"
                env["DM_MOUSE_MODE"] = prof.mouseRightStickMode
            }
            env["DM_RUMBLE"] = prof.enableRumble ? "1" : "0"
            env["DM_RUMBLE_GAIN"] = String(format: "%.2f", locale: Locale(identifier: "en_US_POSIX"), prof.rumbleStrength)
            env["DM_RUMBLE_FLOOR"] = prof.rumbleFloorBoost ? "0.22" : "0.0"
            LibraryScanner.shared.launchGame(at: game.url, env: env) { [weak self] success, error in
                DispatchQueue.main.async {
                    if success {
                        DispatchQueue.main.asyncAfter(deadline: .now() + 1.2) {
                            if self?.launchingGameId == targetGameId {
                                self?.launchingGameId = nil
                            }
                        }
                        self?.runningGameTitle = game.name
                        self?.logs.append(LogEntry(level: .success, message: "Launched game: \(game.name)"))
                        ShaderPrebuildService.shared.startMonitoringLaunch(game: game)
                        MemoryOptimizer.shared.optimizeForBackground(viewModel: self)
                        
                        // Observe game termination via NSWorkspace.shared.notificationCenter + live heartbeat checkpointing
                        let resolvedRunningApp = GameControllerService.shared.activeRunningGameApp ??
                            (game.bundleId.flatMap { NSRunningApplication.runningApplications(withBundleIdentifier: $0).first })
                        if let runningApp = resolvedRunningApp {
                            let targetPid = runningApp.processIdentifier
                            PlayTimeService.shared.startSession(for: game, pid: targetPid)
                            var observer: NSObjectProtocol?
                            observer = NSWorkspace.shared.notificationCenter.addObserver(
                                forName: NSWorkspace.didTerminateApplicationNotification,
                                object: nil,
                                queue: .main
                            ) { [weak self] notif in
                                if let termApp = notif.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication,
                                   termApp.processIdentifier == targetPid {
                                    if let obs = observer {
                                        NSWorkspace.shared.notificationCenter.removeObserver(obs)
                                        observer = nil
                                    }
                                    ShaderPrebuildService.shared.onGameTerminated(game: game)
                                    self?.runningGameTitle = nil
                                    PlayTimeService.shared.endSession(forPid: targetPid)
                                    if SaveSyncService.shared.isICloudSyncEnabled(for: game) {
                                        DispatchQueue.global(qos: .utility).async {
                                            _ = SaveSyncService.shared.writeDMSync(for: game)
                                        }
                                    }
                                }
                            }
                        }
                    } else {
                        // Immediately clear launching state on error so user is never locked out
                        if self?.launchingGameId == targetGameId {
                            self?.launchingGameId = nil
                        }
                        self?.runningGameTitle = nil
                        SoundEffectService.shared.play(.error)
                        let errMsg = error ?? "Unknown error"
                        self?.logs.append(LogEntry(level: .error, message: "Failed to launch game: \(errMsg)"))
                    }
                }
            }
        }
    }
    
    public func loadRuntimeConfig(for game: PortedGame) -> GameRuntimeConfig {
        let key = game.uniqueKey
        if let cached = runtimeConfigCache[key] {
            return cached
        }
        let loaded = GameRuntimeConfig.load(for: game)
        runtimeConfigCache[key] = loaded
        return loaded
    }
    
    public func saveRuntimeConfig(_ config: GameRuntimeConfig, for game: PortedGame) {
        runtimeConfigCache[game.uniqueKey] = config
        config.save(for: game)
        if GameRuntimeConfig.isOotGame(game) && game.platform != .ios {
            DispatchQueue.global(qos: .userInitiated).async {
                LibraryScanner.shared.sanitizeOoTEnvIfNeeded(at: game.url)
            }
        } else if game.platform == .ios,
                  let dev = DeviceDeploymentService.shared.selectedDevice,
                  dev.isAvailable {
            DeviceDeploymentService.shared.syncConfigToIosDevice(game: game, config: config, device: dev) { [weak self] ok, msg in
                if ok {
                    self?.logs.append(LogEntry(level: .success, message: "iOS Sync: \(msg)"))
                }
            }
        }
        logs.append(LogEntry(level: .success, message: "Saved settings for \(game.name)"))
    }
}
