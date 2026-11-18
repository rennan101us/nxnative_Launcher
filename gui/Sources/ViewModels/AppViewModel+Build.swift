import Foundation
import AppKit
import UniformTypeIdentifiers

extension AppViewModel {
    // MARK: - Build Actions
    public var effectiveGameFolder: URL? {
        if let folder = selectedGameFolder { return folder }
        if let fileURL = selectedGame?.files.first?.url { return fileURL.deletingLastPathComponent() }
        return gameFolders.first
    }
    
    public var canStartBuild: Bool {
        !isBuilding &&
        effectiveGameFolder != nil &&
        selectedGame != nil &&
        (isProdKeysValid || selectedGame?.isSwitch2 == true || selectedGame?.isNup == true || selectedGame?.isDumpFolder == true) &&
        isNxnativeValid &&
        !isDiskSpaceLow
    }
    
    public func goToWizardStep(_ step: Int) {
        guard step >= 1 && step <= 3 else { return }
        if step == 2 && selectedGame == nil { return }
        buildWizardStep = step
    }
    
    public func resetWizard() {
        buildWizardStep = 1
        buildError = nil
        buildSuccessPath = nil
    }
    
    /// Prepares a dedicated workspace inside the configured Staging directory with symlinks to the game's files
    /// (and returns the explicit `--work-dir` path so intermediate `<TitleID>_build` files stay out of the original ROM folder).
    public static func prepareStagingWorkspace(
        for sel: SelectableGame,
        stagingBaseDirectory: URL = SystemDetector.shared.stagingDirectory
    ) throws -> (gameDirectory: URL, workDirectory: URL?) {
        let stagingDir = stagingBaseDirectory.appendingPathComponent(sel.sanitizedStagingFolderName, isDirectory: true)

        let fm = FileManager.default
        if !fm.fileExists(atPath: stagingDir.path) {
            try fm.createDirectory(at: stagingDir, withIntermediateDirectories: true)
        } else {
            // Clean up stale top-level symlinks only; preserve intermediate *_build, *_survey, and .tmp caches.
            if let existingItems = try? fm.contentsOfDirectory(at: stagingDir, includingPropertiesForKeys: nil) {
                for itemURL in existingItems {
                    let name = itemURL.lastPathComponent
                    if name == ".tmp" || name.hasSuffix("_build") || name.hasSuffix("_survey") {
                        continue
                    }
                    try? fm.removeItem(at: itemURL)
                }
            }
        }

        var populatedEntries = 0
        if sel.files.count == 1, let onlyURL = sel.files.first?.url {
            var isDir: ObjCBool = false
            if fm.fileExists(atPath: onlyURL.path, isDirectory: &isDir), isDir.boolValue {
                let children = try fm.contentsOfDirectory(at: onlyURL, includingPropertiesForKeys: nil)
                for child in children {
                    let name = child.lastPathComponent
                    let ext = child.pathExtension.lowercased()
                    if name.hasPrefix(".") || name.hasSuffix("_build") || name.hasSuffix("_survey") || ext == "app" || ext == "ipa" {
                        continue
                    }
                    let linkURL = stagingDir.appendingPathComponent(name)
                    try? fm.removeItem(at: linkURL)
                    try fm.createSymbolicLink(at: linkURL, withDestinationURL: child)
                    populatedEntries += 1
                }
            }
        }

        if populatedEntries == 0 {
            for item in sel.files {
                let linkURL = stagingDir.appendingPathComponent(item.url.lastPathComponent)
                try? fm.removeItem(at: linkURL)
                try fm.createSymbolicLink(at: linkURL, withDestinationURL: item.url)
                populatedEntries += 1
            }
        }

        let normalizedTid = sel.titleId?.trimmingCharacters(in: .whitespacesAndNewlines).uppercased()
        let workDir = (normalizedTid?.isEmpty == false)
            ? stagingDir.appendingPathComponent("\(normalizedTid!)_build", isDirectory: true)
            : nil
        return (stagingDir, workDir)
    }

    public func startBuild() {
        guard canStartBuild, let sel = selectedGame, let gameDir = effectiveGameFolder else { return }
        if selectedGameFolder == nil {
            selectedGameFolder = gameDir
        }
        
        buildWizardStep = 3
        isBuilding = true
        buildingGameId = sel.id
        buildError = nil
        buildSuccessPath = nil
        progressFraction = 0.0
        currentStageName = "Preparing Build..."
        currentStepName = ""
        stageIndex = 0
        totalStages = 0
        etaSeconds = nil
        buildStages.removeAll()
        logs.removeAll()
        
        if sel.updateCount > 0 || sel.dlcCount > 0 {
            logs.append(LogEntry(
                level: .info,
                message: "Auto-Bundling: Base Game + \(sel.updateCount) Update(s) + \(sel.dlcCount) DLC(s) detected in folder and queued for automatic installation."
            ))
        }
        
        if (sel.isSwitch2 || sel.isNup), let firstFile = (sel.baseFile?.url ?? sel.files.first?.url) {
            let label = sel.isNup ? "NUP container" : "Nintendo Switch 2 package"
            logs.append(LogEntry(level: .info, message: "\(label) identified: '\(firstFile.path)'."))
        }

        var targetGameDirectory = gameDir
        var stagingWorkDir: URL? = nil
        do {
            let staged = try Self.prepareStagingWorkspace(for: sel)
            targetGameDirectory = staged.gameDirectory
            stagingWorkDir = staged.workDirectory
            logs.append(LogEntry(level: .info, message: "Prepared staging build workspace for '\(sel.name)' at '\(targetGameDirectory.path)' (\(sel.files.count) source item(s))."))
        } catch {
            logs.append(LogEntry(level: .warning, message: "Could not prepare staging workspace (\(error.localizedDescription)). Using original directory."))
        }
        
        let targetOutDir = repairOverrideOutputFolder ?? appOutputDirectory
        try? FileManager.default.createDirectory(at: targetOutDir, withIntermediateDirectories: true)
        
        let isAboveThreshold = (platform == .ios && shouldSuggestRomfsSplit)
        let effectiveRomfsSeparate: Bool
        if let forcedRomfsSeparate = repairOverrideRomfsSeparate {
            effectiveRomfsSeparate = forcedRomfsSeparate
        } else if platform == .ios {
            if userDidManuallyOverrideRomfsSeparate {
                effectiveRomfsSeparate = romfsSeparate
            } else {
                effectiveRomfsSeparate = romfsSeparate || isAboveThreshold
            }
        } else {
            effectiveRomfsSeparate = false
        }
        
        if platform == .ios && isAboveThreshold && !romfsSeparate && !userDidManuallyOverrideRomfsSeparate {
            logs.append(LogEntry(
                level: .info,
                message: "[Auto-Split] Game size (\(selectedGameSizeString)) exceeds configured threshold (\(Int(autoRomfsSplitLimitGB)) GB). Automatically applying --romfs separate."
            ))
        }
        
        let resolvedAppName = (repairOverrideAppName?.isEmpty == false) ? repairOverrideAppName! : (appName.isEmpty ? sel.name : appName)
        let effectiveAllowOtherMetal = repairOverrideAllowOtherMetal ?? allowOtherMetal
        let normalizedTitleId = sel.titleId?.trimmingCharacters(in: .whitespacesAndNewlines).uppercased()
        let isOcarinaOfTime = (normalizedTitleId == "0400486024DEC000") ||
            (normalizedTitleId == nil && sel.name.localizedCaseInsensitiveContains("Ocarina of Time"))

        runner.startBuild(
            nxnativePath: nxnativePath,
            gameDirectory: targetGameDirectory,
            prodKeysPath: prodKeysPath,
            platform: platform,
            customOutputFolder: targetOutDir,
            stagingWorkDirectory: stagingWorkDir,
            appName: resolvedAppName,
            bundleId: bundleId.isEmpty ? nil : bundleId,
            language: selectedLanguage,
            showFps: showFps,
            keepExtracted: keepExtracted,
            surveyOnly: surveyOnly,
            romfsSeparate: effectiveRomfsSeparate,
            allowOtherMetal: effectiveAllowOtherMetal,
            isOcarinaOfTime: isOcarinaOfTime
        )
    }
    
    public var isMetalCompilerMismatchError: Bool {
        if let err = buildError,
           (err.contains("allow-other-metal") || err.contains("ALLOW_OTHER_METAL") || err.contains("Metal compiler is not the one")) {
            return true
        }
        return logs.suffix(25).contains { entry in
            entry.message.contains("allow-other-metal") ||
            entry.message.contains("ALLOW_OTHER_METAL") ||
            entry.message.contains("Metal compiler is not the one")
        }
    }
    
    public func enableAllowOtherMetalAndRetry() {
        allowOtherMetal = true
        startBuild()
    }
    
    public func cancelBuild() {
        clearRepairOverrides()
        runner.cancel()
    }

    internal func clearRepairOverrides() {
        repairOverrideOutputFolder = nil
        repairOverrideAppName = nil
        repairOverrideRomfsSeparate = nil
        repairOverrideAllowOtherMetal = nil
    }
    
    public func openOutputInFinder() {
        guard let path = buildSuccessPath else { return }
        let url = URL(fileURLWithPath: path)
        NSWorkspace.shared.activateFileViewerSelecting([url])
    }
    
    // MARK: - File Pickers
    public func selectNxnativeFolder() {
        let panel = NSOpenPanel()
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.allowsMultipleSelection = false
        panel.prompt = "Select nxnative Folder"
        panel.message = "Choose the directory containing the nxnative scripts and tools."
        
        if panel.runModal() == .OK, let url = panel.url {
            let res = SystemDetector.shared.detectNxnativeDirectory(customDir: url.path)
            if res.isValid {
                SystemDetector.shared.saveCustomNxnativeDirectory(res.path)
                self.nxnativePath = res.path
                self.isNxnativeValid = true
                self.defaultInstallPath = SystemDetector.shared.resolveRootDirectory().path
                self.logs.append(LogEntry(level: .success, message: "Core repository path saved: \(res.path)"))
                refreshEnginePatches()
                detectMetalToolchain()
                refreshPrerequisites()
                checkForUpdates(force: true)
            } else {
                SoundEffectService.shared.play(.error)
                self.logs.append(LogEntry(level: .error, message: "Selected folder is not a valid nxnative repository (missing scripts/build_ipa_from_nsp.py or dm/): \(url.path)"))
            }
        }
    }

    public func resetNxnativeFolderToDefault() {
        SystemDetector.shared.saveCustomNxnativeDirectory(nil)
        self.defaultInstallPath = SystemDetector.shared.resolveRootDirectory().path
        detectEnvironment()
        checkForUpdates(force: true)
    }
    
    public func selectGameFolder() {
        let panel = NSOpenPanel()
        panel.canChooseFiles = true
        panel.canChooseDirectories = true
        panel.allowsMultipleSelection = false
        panel.treatsFilePackagesAsDirectories = false
        panel.delegate = GameFilePickerDelegate.sharedWithApps
        
        var allowedTypes: [UTType] = [.application, .package, .folder, .zip]
        for ext in ["nsp", "nsz", "nzs", "xci", "xcz", "nup", "nca", "ipa"] {
            if let t = UTType(filenameExtension: ext) {
                allowedTypes.append(t)
            }
        }
        panel.allowedContentTypes = allowedTypes
        
        panel.prompt = tr("common.choose")
        panel.message = "Select a game file (.nsp, .nsz, .nzs, .xci, .xcz, .nup, .nca, .app) or a folder holding your games."
        
        if panel.runModal() == .OK, let url = panel.url {
            handleDroppedURLs([url], openPortModalForSingleGame: true)
        }
    }
    
    public func selectOutputFolder() {
        let panel = NSOpenPanel()
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.allowsMultipleSelection = false
        panel.prompt = tr("common.choose")
        panel.message = tr("build.choose_output_folder_prompt")
        
        if panel.runModal() == .OK, let url = panel.url {
            self.customOutputFolder = url
            self.useCustomOutputFolder = true
            if self.libraryFolder == nil {
                self.libraryFolder = url
            }
            self.defaultInstallPath = SystemDetector.shared.resolveRootDirectory().path
        }
    }
    
    public func selectProdKeysFile() {
        let panel = NSOpenPanel()
        panel.canChooseFiles = true
        panel.canChooseDirectories = false
        panel.allowsMultipleSelection = false
        panel.prompt = tr("common.choose")
        panel.message = tr("system.keys_missing_desc")
        
        if panel.runModal() == .OK, let url = panel.url {
            self.prodKeysPath = url.path
            self.prodKeysSource = "User Selected"
            self.isProdKeysValid = true
        }
    }
    
    public func selectRyujinxFolder() {
        let panel = NSOpenPanel()
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.allowsMultipleSelection = false
        panel.prompt = tr("common.choose")
        panel.message = tr("settings.ryujinx_folder_prompt")
        
        if panel.runModal() == .OK, let url = panel.url {
            detectEnvironment(customRyujinxDir: url.path)
        }
    }

    public func findInRyujinx() {
        if let detected = SystemDetector.shared.detectProdKeys() {
            self.prodKeysPath = detected.path
            self.prodKeysSource = detected.sourceName
            self.isProdKeysValid = true
            SoundEffectService.shared.play(.click)
        } else {
            SoundEffectService.shared.play(.error)
            self.showRyujinxNotFoundSheet = true
        }
    }
}
