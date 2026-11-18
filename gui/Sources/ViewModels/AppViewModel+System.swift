import Foundation
import AppKit

extension AppViewModel {
    private static var lastAppliedIconMode: AppIconAppearanceMode?

    // MARK: - Dynamic Dock & Minimized Taskbar Icon
    public func updateDockIcon(userInitiated: Bool = false) {
        DispatchQueue.main.async { [weak self] in
            guard let self = self else { return }
            if !MenuBarManager.shared.isMinimizedToMenuBar {
                NSApplication.shared.setActivationPolicy(.regular)
            }
            
            let resName = self.iconAppearanceMode.resourceName
            let mode = self.iconAppearanceMode

            if !userInitiated,
               Self.lastAppliedIconMode == mode,
               let existingImg = NSApplication.shared.applicationIconImage {
                for window in NSApplication.shared.windows where window.miniwindowImage !== existingImg {
                    window.miniwindowImage = existingImg
                    window.miniwindowTitle = "NxNative Launcher"
                }
                return
            }
            
            let image = AppIconCache.image(named: resName)
            
            if let img = image {
                Self.lastAppliedIconMode = mode
                NSApplication.shared.applicationIconImage = img
                NSApplication.shared.dockTile.display()
                
                for window in NSApplication.shared.windows {
                    window.miniwindowImage = img
                    window.miniwindowTitle = "NxNative Launcher"
                }

                // Persist custom icon permanently on disk ONLY when explicitly initiated by the user
                if userInitiated {
                    let bundleURL = Bundle.main.bundleURL
                    let appBundlePath: String? = {
                        if bundleURL.pathExtension == "app" {
                            return bundleURL.path
                        }
                        let candidates = [
                            "/Volumes/SSD FN501 PRO/Emulations/NativePort/NxNative_Launcher.app",
                            "/Applications/NxNative_Launcher.app"
                        ]
                        return candidates.first { FileManager.default.fileExists(atPath: $0) }
                    }()

                    if let targetPath = appBundlePath {
                        let targetResName = resName
                        let isDefault = (mode == .default)
                        DispatchQueue.global(qos: .utility).async {
                            Self.persistAppIconToDisk(
                                appBundlePath: targetPath,
                                resourceName: targetResName,
                                iconImage: isDefault ? nil : img,
                                restartDock: true
                            )
                        }
                    }
                }
            }
        }
    }
    
    // MARK: - Permanent App Icon Persistence on macOS
    private static func persistAppIconToDisk(
        appBundlePath: String,
        resourceName: String,
        iconImage: NSImage?,
        restartDock: Bool
    ) {
        let fm = FileManager.default
        let bundleURL = URL(fileURLWithPath: appBundlePath)
        let resourcesURL = bundleURL.appendingPathComponent("Contents/Resources")
        guard fm.fileExists(atPath: resourcesURL.path) else { return }

        let targetIcnsURL = resourcesURL.appendingPathComponent("AppIcon.icns")
        let sourceIcnsURL = resourcesURL.appendingPathComponent("\(resourceName).icns")

        // 1. Set the Finder custom icon via Apple's official API
        DispatchQueue.main.async {
            NSWorkspace.shared.setIcon(iconImage, forFile: appBundlePath, options: [])
        }

        // 2. Atomically update AppIcon.icns inside Contents/Resources
        if fm.fileExists(atPath: sourceIcnsURL.path) {
            do {
                if fm.fileExists(atPath: targetIcnsURL.path) {
                    try fm.removeItem(at: targetIcnsURL)
                }
                try fm.copyItem(at: sourceIcnsURL, to: targetIcnsURL)
            } catch {}
        }

        // 3. Update timestamps on Info.plist and app bundle
        let infoPlist = bundleURL.appendingPathComponent("Contents/Info.plist").path
        runProcessWithTimeout(executable: "/usr/bin/touch", arguments: [infoPlist, appBundlePath], timeoutSeconds: 1.0)

        // 4. Force LaunchServices to refresh registration for this bundle
        let lsregisterPath = "/System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister"
        if fm.fileExists(atPath: lsregisterPath) {
            runProcessWithTimeout(executable: lsregisterPath, arguments: ["-f", appBundlePath], timeoutSeconds: 2.0)
        }

        // 5. Invalidate Finder file system cache
        DispatchQueue.main.async {
            NSWorkspace.shared.noteFileSystemChanged(appBundlePath)
        }

        // 6. Refresh macOS Dock icon cache if user actively changed the icon
        if restartDock {
            runProcessWithTimeout(executable: "/usr/bin/killall", arguments: ["Dock"], timeoutSeconds: 2.0)
        }
    }

    @discardableResult
    private static func runProcessWithTimeout(executable: String, arguments: [String], timeoutSeconds: Double = 2.0) -> Bool {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: executable)
        process.arguments = arguments
        process.standardOutput = Pipe()
        process.standardError = Pipe()

        do {
            try process.run()
            let deadline = DispatchTime.now() + timeoutSeconds
            while process.isRunning && DispatchTime.now() < deadline {
                usleep(25_000) // 25ms polling
            }
            if process.isRunning {
                process.terminate()
                return false
            }
            return process.terminationStatus == 0
        } catch {
            return false
        }
    }
    
    public func setupWindowMinimizeIconObserver() {
        NotificationCenter.default.addObserver(
            forName: NSWindow.didBecomeKeyNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            guard let self = self, !MenuBarManager.isMinimized else { return }
            self.updateDockIcon()
        }
    }
    
    // MARK: - Compatibility
    public func loadCompatibleGames(forceRefresh: Bool = false) {
        isLoadingCompatibility = true
        CompatibilityService.shared.fetchCompatibleGames(localNxnativePath: nxnativePath) { [weak self] games, isOnline in
            guard let self = self else { return }
            self.compatibleGames = games
            self.isCompatibilityFromOnline = isOnline
            self.compatibilityLastUpdated = Date()
            self.isLoadingCompatibility = false
            GameCoverService.shared.ensureCoversForCompatibleGames(games, forceRetryFailed: forceRefresh)
            if !self.cloudSources.isEmpty {
                self.syncCloudSources()
            }
        }
    }
    
    public func cycleCompatibilityFilter(forward: Bool) {
        let ramFilters: [Int?] = [nil, 4, 6, 8, 16]
        SoundEffectService.shared.play(.focus)
        
        let currentIdx = ramFilters.firstIndex(where: { $0 == compatibilityRamFilter }) ?? 0
        if forward {
            let nextIdx = (currentIdx + 1) % ramFilters.count
            compatibilityRamFilter = ramFilters[nextIdx]
        } else {
            let prevIdx = (currentIdx - 1 + ramFilters.count) % ramFilters.count
            compatibilityRamFilter = ramFilters[prevIdx]
        }
    }
    
    // MARK: - Environment Detection
    public func detectEnvironment(customRyujinxDir: String? = nil) {
        if let savedKeys = UserDefaults.standard.string(forKey: StorageKeys.savedProdKeysPath),
           FileManager.default.fileExists(atPath: savedKeys),
           savedKeys.hasSuffix("prod.keys") {
            self.prodKeysPath = savedKeys
            self.prodKeysSource = "Saved Preference"
            self.isProdKeysValid = true
        } else if let keysResult = SystemDetector.shared.detectProdKeys(additionalSearchDir: customRyujinxDir) {
            self.prodKeysPath = keysResult.path
            self.prodKeysSource = keysResult.sourceName
            self.isProdKeysValid = keysResult.isValid
        } else {
            self.isProdKeysValid = false
            self.prodKeysSource = "Not Found"
        }
        
        let nxResult = SystemDetector.shared.detectNxnativeDirectory()
        self.nxnativePath = nxResult.path
        self.isNxnativeValid = nxResult.isValid
        
        refreshEnginePatches()
        refreshPrerequisites()
        detectMetalToolchain()
    }
    
    public func detectMetalToolchain() {
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            guard let self = self else { return }
            let info = SystemDetector.shared.detectMetalToolchain(nxnativePath: self.nxnativePath)
            DispatchQueue.main.async {
                self.metalToolchainInfo = info
                if self.isShowingOnboarding {
                    self.recalculateOnboardingEstimate()
                }
            }
        }
    }
    
    public func refreshEnginePatches() {
        guard !nxnativePath.isEmpty else { return }
        self.enginePatches = PatchService.shared.checkPatchStatuses(nxnativePath: nxnativePath)
    }
    
    public func applyEnginePatches() {
        guard !nxnativePath.isEmpty else { return }
        let (applied, skipped, errors) = PatchService.shared.applyPatchesIfNeeded(nxnativePath: nxnativePath) { [weak self] msg, ok in
            self?.logs.append(LogEntry(level: ok ? .success : .info, message: msg))
        }
        refreshEnginePatches()
        if !errors.isEmpty {
            self.logs.append(LogEntry(level: .warning, message: "Engine patches completed with notices: \(errors.joined(separator: ", "))"))
        } else {
            self.logs.append(LogEntry(level: .success, message: "Engine patches verified: \(applied) applied, \(skipped) already present."))
        }
    }
    
    public func installAppleCommandLineTools() {
        showCltInstallAlert = true
        installer.install(dependency: prerequisites.xcode) { [weak self] _ in
            self?.refreshPrerequisites()
        }
    }
    
    public func refreshPrerequisites() {
        isCheckingPrerequisites = true
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            let res = SystemDetector.shared.checkPrerequisites()
            DispatchQueue.main.async {
                guard let self = self else { return }
                self.prerequisites = res
                self.isCheckingPrerequisites = false
                if !self.isInstallingDependency && !self.isCloningRepository && !self.isProvisioningBusy && res.missingList(for: self.selectedOnboardingPlatforms).isEmpty && self.isNxnativeValid {
                    self.provisioningStatus = ""
                }
                if self.isShowingOnboarding {
                    self.evaluateLegacyOnboardingCompletionIfNeeded()
                    self.recalculateOnboardingEstimate()
                }
                if !self.isShowingOnboarding, !self.hasCompletedInitialProvisioningPass, !self.isProvisioningBusy, !self.isInstallingDependency {
                    self.provisioningTick()
                }
            }
        }
    }
    
    public func cloneNxnativeRepository() {
        let dest = URL(fileURLWithPath: defaultInstallPath).appendingPathComponent("nxnative")
        isCloningRepository = true
        cloneErrorMessage = nil
        
        SystemDetector.shared.cloneNxnativeRepository(to: dest) { [weak self] success, output in
            guard let self = self else { return }
            self.isCloningRepository = false
            self.provisioningStatus = ""
            if success {
                if !SystemDetector.isValidNxnativeDirectory(SystemDetector.shared.savedCustomNxnativeDirectory ?? "") {
                    SystemDetector.shared.saveCustomNxnativeDirectory(nil)
                }
                PatchService.shared.applyPatchesIfNeeded(nxnativePath: dest.path)
                self.detectEnvironment()
                self.logs.append(LogEntry(level: .success, message: "nxnative repository cloned and compatibility patches applied."))
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { [weak self] in
                    self?.provisioningTick()
                }
            } else {
                self.cloneErrorMessage = output
                self.logs.append(LogEntry(level: .error, message: "Failed to clone repository: \(output)"))
            }
        }
    }
    
    // MARK: - Tool Installer / Repair / Uninstall
    public func installAllMissingDependencies(openSheet: Bool? = nil) {
        let missing = prerequisites.missingList(for: selectedOnboardingPlatforms)
        guard !missing.isEmpty else { return }
        let shouldOpenSheet = openSheet ?? (selectedTab != 4)
        if shouldOpenSheet {
            showInstallerSheet = true
        }
        isInstallingDependency = true
        installerLogs.removeAll()
        installerLogs.append("Installing \(missing.count) missing dependencies...")
        
        installer.installAll(dependencies: missing) { [weak self] success in
            self?.isInstallingDependency = false
            self?.refreshPrerequisites()
            if success {
                self?.logs.append(LogEntry(level: .success, message: "All missing dependencies installed successfully."))
            } else {
                self?.logs.append(LogEntry(level: .warning, message: "Some dependencies could not be installed."))
            }
        }
    }

    /// Explicitly opts into Android porting and installs only missing Android toolchain packages on demand.
    public func installMissingAndroidToolchain() {
        selectedOnboardingPlatforms.insert(.android)
        let missingAndroid = prerequisites.missingList(for: [.android]).filter { $0.category == .android }
        guard !missingAndroid.isEmpty else {
            refreshPrerequisites()
            return
        }
        showInstallerSheet = true
        isInstallingDependency = true
        installerLogs.removeAll()
        installerLogs.append("Installing Android Toolchain (\(missingAndroid.map(\.name).joined(separator: ", ")))...")

        installer.installAll(dependencies: missingAndroid) { [weak self] success in
            self?.isInstallingDependency = false
            self?.refreshPrerequisites()
            if success {
                self?.logs.append(LogEntry(level: .success, message: "Android toolchain installed successfully."))
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.8) { [weak self] in
                    self?.provisioningTick()
                }
            } else {
                self?.logs.append(LogEntry(level: .warning, message: "Some Android toolchain packages could not be installed."))
            }
        }
    }
    
    public func installDependency(_ dep: DependencyStatus) {
        showInstallerSheet = true
        isInstallingDependency = true
        installerLogs.removeAll()
        installerLogs.append("Installing \(dep.name)...")
        
        installer.install(dependency: dep) { [weak self] success in
            self?.isInstallingDependency = false
            self?.refreshPrerequisites()
            if success {
                self?.logs.append(LogEntry(level: .success, message: "\(dep.name) installed successfully."))
            } else {
                self?.logs.append(LogEntry(level: .error, message: "Failed to install \(dep.name)."))
            }
        }
    }
    
    public func repairDependency(_ dep: DependencyStatus) {
        showInstallerSheet = true
        isInstallingDependency = true
        installerLogs.removeAll()
        installerLogs.append("Repairing \(dep.name)...")
        
        installer.repair(dependency: dep) { [weak self] success in
            self?.isInstallingDependency = false
            self?.refreshPrerequisites()
            if success {
                self?.logs.append(LogEntry(level: .success, message: "\(dep.name) repaired successfully."))
            } else {
                self?.logs.append(LogEntry(level: .error, message: "Failed to repair \(dep.name)."))
            }
        }
    }
    
    public func confirmUninstall(_ dep: DependencyStatus) {
        self.confirmDialogFocusIndex = 1
        self.dependencyToUninstall = dep
        self.showUninstallConfirm = true
    }
    
    public func executeUninstall() {
        guard let dep = dependencyToUninstall else { return }
        showUninstallConfirm = false
        showInstallerSheet = true
        isInstallingDependency = true
        installerLogs.removeAll()
        installerLogs.append("Uninstalling \(dep.name)...")
        
        installer.uninstall(dependency: dep) { [weak self] success in
            guard let self = self else { return }
            self.isInstallingDependency = false
            if success {
                if dep.category == .android, self.selectedOnboardingPlatforms.contains(.android) {
                    self.selectedOnboardingPlatforms.remove(.android)
                    if self.selectedOnboardingPlatforms.isEmpty {
                        self.selectedOnboardingPlatforms.insert(.macApp)
                    }
                } else if dep.category == .ios, self.selectedOnboardingPlatforms.contains(.ios) {
                    self.selectedOnboardingPlatforms.remove(.ios)
                    if self.selectedOnboardingPlatforms.isEmpty {
                        self.selectedOnboardingPlatforms.insert(.macApp)
                    }
                }
                self.logs.append(LogEntry(level: .warning, message: "\(dep.name) was uninstalled."))
            } else {
                self.logs.append(LogEntry(level: .error, message: "Failed to uninstall \(dep.name)."))
            }
            self.refreshPrerequisites()
        }
    }
    
    public func repairAllDependencies() {
        showInstallerSheet = true
        isInstallingDependency = true
        installerLogs.removeAll()
        installerLogs.append("Repairing all environment tools...")
        
        installer.repairAll(dependencies: prerequisites.list(for: selectedOnboardingPlatforms)) { [weak self] success in
            self?.isInstallingDependency = false
            self?.refreshPrerequisites()
            if success {
                self?.logs.append(LogEntry(level: .success, message: "All environment tools repaired."))
            }
        }
    }
    
    // MARK: - Customizable Application Support and Staging Folders
    public var appSupportFolder: URL {
        SystemDetector.shared.appSupportDirectory
    }
    
    public var isUsingDefaultAppSupportFolder: Bool {
        SystemDetector.shared.getCustomAppSupportDirectory() == nil
    }
    
    public func selectAppSupportFolder() {
        let panel = NSOpenPanel()
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.allowsMultipleSelection = false
        panel.prompt = tr("common.choose")
        panel.message = tr("system.select_app_support_folder_message")
        
        if panel.runModal() == .OK, let url = panel.url {
            let currentConfigured = SystemDetector.shared.getCustomAppSupportDirectory() ?? SystemDetector.shared.defaultAppSupportDirectory
            guard currentConfigured.standardizedFileURL.path != url.standardizedFileURL.path else { return }
            
            logs.append(LogEntry(level: .info, message: "Migrating game saves & application support to: \(url.path)..."))
            SystemDetector.shared.migrateAppSupportDirectoryContents(from: currentConfigured, to: url) { [weak self] success, error in
                guard let self = self else { return }
                if success {
                    SystemDetector.shared.saveCustomAppSupportDirectory(url)
                    self.logs.append(LogEntry(level: .success, message: "Game saves successfully migrated to: \(url.path)"))
                    SaveSyncService.shared.refreshAllFolderIcons(games: self.libraryGames)
                    self.objectWillChange.send()
                } else {
                    self.logs.append(LogEntry(level: .error, message: "Failed to migrate game saves: \(error ?? "Unknown error")"))
                    SoundEffectService.shared.play(.error)
                }
            }
        }
    }
    
    public func resetAppSupportFolderToDefault() {
        let oldFolder = SystemDetector.shared.appSupportDirectory
        let defaultFolder = SystemDetector.shared.defaultAppSupportDirectory
        guard oldFolder.standardizedFileURL.path != defaultFolder.standardizedFileURL.path else { return }
        
        logs.append(LogEntry(level: .info, message: "Restoring game saves to default location: \(defaultFolder.path)..."))
        SystemDetector.shared.migrateAppSupportDirectoryContents(from: oldFolder, to: defaultFolder) { [weak self] success, error in
            guard let self = self else { return }
            if success {
                SystemDetector.shared.saveCustomAppSupportDirectory(nil)
                SystemDetector.shared.ensureStorageDirectoriesAndSymlinks()
                self.logs.append(LogEntry(level: .success, message: "Game saves restored to standard macOS folder: \(defaultFolder.path)"))
                SaveSyncService.shared.refreshAllFolderIcons(games: self.libraryGames)
                self.objectWillChange.send()
            } else {
                self.logs.append(LogEntry(level: .error, message: "Failed to restore game saves: \(error ?? "Unknown error")"))
                SoundEffectService.shared.play(.error)
            }
        }
    }
    
    public var stagingFolder: URL {
        SystemDetector.shared.stagingDirectory
    }
    
    public var isUsingDefaultStagingFolder: Bool {
        SystemDetector.shared.getCustomStagingDirectory() == nil
    }
    
    public func selectStagingFolder() {
        let panel = NSOpenPanel()
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.allowsMultipleSelection = false
        panel.prompt = tr("common.choose")
        panel.message = tr("system.select_staging_folder_message")
        
        if panel.runModal() == .OK, let url = panel.url {
            SystemDetector.shared.saveCustomStagingDirectory(url)
            self.defaultInstallPath = SystemDetector.shared.resolveRootDirectory().path
            objectWillChange.send()
        }
    }
    
    public func resetStagingFolderToDefault() {
        SystemDetector.shared.saveCustomStagingDirectory(nil)
        self.defaultInstallPath = SystemDetector.shared.resolveRootDirectory().path
        objectWillChange.send()
    }
}
