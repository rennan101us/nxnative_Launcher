import Foundation
import SwiftUI
import AppKit

public final class AppViewModel: ObservableObject, BuildRunnerDelegate, InstallerServiceDelegate, UpdateCheckerDelegate {
    public static var shared: AppViewModel? = nil

    // MARK: - Storage Keys for Persistence
    public enum StorageKeys {
        public static let savedGameFolder = "NXNative_SavedGameFolder"
        public static let savedGameFolders = "NXNative_SavedGameFolders"
        public static let savedLibraryFolder = "NXNative_SavedLibraryFolder"
        public static let savedCustomOutputFolder = "NXNative_SavedCustomOutputFolder"
        public static let savedUseCustomOutput = "NXNative_SavedUseCustomOutput"
        public static let savedProdKeysPath = "NXNative_SavedProdKeysPath"
        public static let savedNxnativePath = "NXNative_SavedNxnativePath"
        public static let savedShowFps = "NXNative_SavedShowFps"
        public static let savedKeepExtracted = "NXNative_SavedKeepExtracted"
        public static let savedPlatform = "NXNative_SavedPlatform"
        public static let savedIconAppearanceMode = "NXNative_SavedIconAppearanceMode_v2"
        public static let savedHighlightTheme = "NXNative_SavedHighlightTheme"
        public static let savedLiquidGlassEnabled = "NXNative_SavedLiquidGlassEnabled"
        public static let savedLiquidGlassAppearance = "NXNative_SavedLiquidGlassAppearance"
        public static let savedLiquidGlassIntensity = "NXNative_SavedLiquidGlassIntensity"
        public static let savedCompatibilityDisplayMode = "NXNative_SavedCompatibilityDisplayMode"
        public static let savedLibraryCardSize = "NXNative_SavedLibraryCardSize"
        public static let savedLibraryCardScale = "NXNative_SavedLibraryCardScale"
        public static let savedLauncherLanguage = "NXNative_SavedLauncherLanguage"
        public static let savedHiddenGamePaths = "NXNative_SavedHiddenGamePaths"
        public static let savedRemovedGamePaths = "NXNative_SavedRemovedGamePaths"
        public static let savedRomfsSeparate = "NXNative_SavedRomfsSeparate"
        public static let savedAutoRomfsSplitLimitGB = "NXNative_SavedAutoRomfsSplitLimitGB"
        public static let savedCustomCertP12Path = "NXNative_SavedCustomCertP12Path"
        public static let savedCustomCertPassword = "NXNative_SavedCustomCertPassword"
        public static let savedCustomProvisioningProfilePath = "NXNative_SavedCustomProvisioningProfilePath"
        public static let savedMenuBarIconStyle = "NXNative_SavedMenuBarIconStyle"
        public static let savedAllowOtherMetal = "NXNative_SavedAllowOtherMetal"
        public static let savedDeveloperMode = "NXNative_SavedDeveloperMode"
        public static let savedNonSwitchAppPaths = "NXNative_SavedNonSwitchAppPaths"
        public static let savedNonSwitchGameFolders = "NXNative_SavedNonSwitchGameFolders"
        public static let savedLastPlayedDates = "NXNative_SavedLastPlayedDates"
        public static let savedActiveGroupFilter = "NXNative_SavedActiveGroupFilter"
        public static let savedActiveSortOption = "NXNative_SavedActiveSortOption"
        public static let hasCompletedOnboarding = "NXNative_HasCompletedOnboarding"
        public static let savedTargetPlatforms = "NXNative_SavedTargetPlatforms"
    }
    
    // MARK: - Onboarding (First-Launch Full-Screen Flow)
    @Published public var isShowingOnboarding: Bool = false
    @Published public var onboardingStep: OnboardingStep = .language
    @Published public var selectedOnboardingPlatforms: Set<TargetPlatform> = {
        if let saved = UserDefaults.standard.stringArray(forKey: StorageKeys.savedTargetPlatforms) {
            let plats = saved.compactMap { TargetPlatform(rawValue: $0) }
            if !plats.isEmpty { return Set(plats) }
        }
        return [.macApp]
    }() {
        didSet {
            let raw = selectedOnboardingPlatforms.map(\.rawValue)
            UserDefaults.standard.set(raw, forKey: StorageKeys.savedTargetPlatforms)
        }
    }
    @Published public var onboardingLanguageFocusIndex: Int = 0
    @Published public var onboardingProgress: Double = 0.0
    @Published public var onboardingStatusMessage: String = ""
    @Published public var onboardingSubstatusMessage: String = ""
    @Published public var onboardingIsInstalling: Bool = false
    @Published public var onboardingWaitingForAppleCLT: Bool = false
    @Published public var onboardingInstallError: String? = nil
    @Published public var onboardingEstimatedTotalBytes: Int64 = 0
    @Published public var onboardingComponentCount: Int = 0
    internal var onboardingStepStart: Double = 0.0
    internal var onboardingStepEnd: Double = 0.0
    internal var onboardingPollTimer: DispatchSourceTimer? = nil
    internal var onboardingTrickleTimer: DispatchSourceTimer? = nil
    
    // MARK: - Workspace & Paths
    @Published public var defaultInstallPath: String = ""
    @Published public var nxnativePath: String = ""
    @Published public var isNxnativeValid: Bool = false
    @Published public var isCloningRepository: Bool = false
    @Published public var cloneErrorMessage: String? = nil
    @Published public var enginePatches: [EnginePatchItem] = []
    @Published public var showCltInstallAlert: Bool = false
    
    // MARK: - Auto-Provisioning & Host Compatibility
    @Published public var macSDKVersion: String? = nil
    @Published public var provisioningStatus: String = ""
    @Published public var isProvisioningBusy: Bool = false
    @Published public var coreRepoLastCheck: Date? = nil
    @Published public var buildErrorFocusIndex: Int = 0
    internal var provisioningTimer: Timer? = nil
    internal var nextCloneAttempt: Date = .distantPast
    internal var nextDependencyAttempt: Date = .distantPast
    internal var nextMetalAttempt: Date = .distantPast
    internal var isAutoProvisioningDependencies: Bool = false
    internal var hasCompletedInitialProvisioningPass: Bool = false
    
    // MARK: - Keys
    @Published public var prodKeysPath: String = "" {
        didSet {
            if !prodKeysPath.isEmpty {
                UserDefaults.standard.set(prodKeysPath, forKey: StorageKeys.savedProdKeysPath)
            }
        }
    }
    @Published public var prodKeysSource: String = ""
    @Published public var isProdKeysValid: Bool = false
    
    // MARK: - Game Selection
    internal var isUpdatingSelectedGameFolderFromAdd: Bool = false
    @Published public var selectedGameFolder: URL? {
        didSet {
            if let folder = selectedGameFolder {
                UserDefaults.standard.set(folder.path, forKey: StorageKeys.savedGameFolder)
                if !isUpdatingSelectedGameFolderFromAdd {
                    addGameFolder(folder)
                }
            } else {
                UserDefaults.standard.removeObject(forKey: StorageKeys.savedGameFolder)
            }
        }
    }
    @Published public var gameFolders: [URL] = [] {
        didSet {
            let paths = gameFolders.map { $0.path }
            UserDefaults.standard.set(paths, forKey: StorageKeys.savedGameFolders)
        }
    }
    @Published public var detectedFiles: [GameFileItem] = []
    @Published public var detectedGames: [SelectableGame] = []
    @Published public var selectedGame: SelectableGame? = nil {
        didSet {
            if let game = selectedGame {
                self.appName = game.name
                self.userDidManuallyOverrideRomfsSeparate = false
                self.evaluateAutoRomfsSplit()
            }
        }
    }
    
    // MARK: - Port Modal & Auto Deployment
    @Published public var gameForPortModal: SelectableGame? = nil
    @Published public var autoDeployToDeviceOnFinish: Bool = false
    @Published public var buildingGameId: String? = nil

    // MARK: - Repair & Re-Port Queue Overrides (Transient per-build, never persisted)
    internal var repairOverrideOutputFolder: URL? = nil
    internal var repairOverrideAppName: String? = nil
    internal var repairOverrideRomfsSeparate: Bool? = nil
    internal var repairOverrideAllowOtherMetal: Bool? = nil
    
    public func isGameAlreadyPorted(_ selectable: SelectableGame) -> Bool {
        let cleanSelectable = GameScanner.shared.cleanGameTitle(selectable.name).lowercased()
        return libraryGames.contains { ported in
            if let selTid = selectable.titleId, !selTid.isEmpty,
               let portTid = ported.titleId, !portTid.isEmpty,
               selTid.caseInsensitiveCompare(portTid) == .orderedSame {
                return true
            }
            let cleanPorted = GameScanner.shared.cleanGameTitle(ported.name).lowercased()
            return cleanSelectable == cleanPorted
        }
    }
    
    public var unportedGames: [SelectableGame] {
        detectedGames
    }
    
    // MARK: - Drag & Drop & ZIP
    @Published public var isExtractingZip: Bool = false
    @Published public var zipExtractionMessage: String = ""
    @Published public var dropErrorMessage: String? = nil
    
    // MARK: - Target & Output
    @Published public var platform: TargetPlatform = .macApp {
        didSet {
            UserDefaults.standard.set(platform.rawValue, forKey: StorageKeys.savedPlatform)
            evaluateAutoRomfsSplit()
            if isKeepExtractedLocked {
                keepExtracted = true
            }
        }
    }
    @Published public var useCustomOutputFolder: Bool = false {
        didSet {
            UserDefaults.standard.set(useCustomOutputFolder, forKey: StorageKeys.savedUseCustomOutput)
        }
    }
    @Published public var customOutputFolder: URL? {
        didSet {
            if let folder = customOutputFolder {
                UserDefaults.standard.set(folder.path, forKey: StorageKeys.savedCustomOutputFolder)
            } else {
                UserDefaults.standard.removeObject(forKey: StorageKeys.savedCustomOutputFolder)
            }
        }
    }
    
    // MARK: - Library State & Card Scale Slider
    @Published public var libraryGames: [PortedGame] = []
    @Published public var libraryFolder: URL? {
        didSet {
            if let folder = libraryFolder {
                UserDefaults.standard.set(folder.path, forKey: StorageKeys.savedLibraryFolder)
            }
        }
    }
    @Published public var librarySearchText: String = ""
    @Published public var isScanningLibrary: Bool = false
    @Published public var libraryCardSize: LibraryCardSize = .regular {
        didSet {
            UserDefaults.standard.set(libraryCardSize.rawValue, forKey: StorageKeys.savedLibraryCardSize)
        }
    }
    @Published public var libraryCardScale: Double = 1.0 {
        didSet {
            UserDefaults.standard.set(libraryCardScale, forKey: StorageKeys.savedLibraryCardScale)
        }
    }
    @Published public var draggedGame: PortedGame? = nil
    @Published public var draggedItemPath: String? = nil
    @Published public var isTextInputActive: Bool = false
    @Published public var gameForSettingsSheet: PortedGame? = nil {
        didSet {
            if let game = gameForSettingsSheet {
                activeSettingsConfig = GameRuntimeConfig.load(for: game)
                settingsModalFocusIndex = 0
                settingsModalSubFocusIndex = 0
                iosDeploymentTab = .multiPort
            }
        }
    }
    @Published public var iosDeploymentTab: IosDeploymentTab = .multiPort
    @Published public var activeSettingsConfig: GameRuntimeConfig = GameRuntimeConfig()
    internal var runtimeConfigCache: [String: GameRuntimeConfig] = [:]
    @Published public var settingsModalFocusIndex: Int = 0
    @Published public var controlsFocusIndex: Int = 0
    @Published public var settingsFocusIndex: Int = 0
    @Published public var activeSettingsCategory: SettingsCategory = .general
    @Published public var settingsItemFocusIndex: Int = 0
    
    // Controls Tab Navigation (2-Level Card Architecture)
    @Published public var controlsCardIndex: Int = 0 // 0: Header, 1: Mapping, 2: Deadzone, 3: Rumble
    @Published public var isInsideControlsCard: Bool = false
    @Published public var controlsHeaderFocus: Int = 0 // 0: Player, 1: Profile, 2: Duplicate, 3: Reset
    @Published public var controlsMappingFocus: Int = 0 // 0..18 (Buttons + Swap AB/XY)
    @Published public var controlsHapticsFocus: Int = 0 // 0: Master, 1: Strength, 2: Floor Boost, 3: Test
    @Published public var controlsMouseTab: Int = 0 // 0: Switch 1, 1: Switch 2
    @Published public var controlsMouseFocus: Int = 0 // 0: Tab Selector, 1..N: Sub-settings
    @Published public var showControlsPlayerModal: Bool = false
    @Published public var showControlsProfileModal: Bool = false
    @Published public var controlsPlayerModalFocus: Int = 0
    @Published public var controlsProfileModalFocus: Int = 0
    @Published public var controlsListeningButton: SwitchButton? = nil

    // Personalize Tab Navigation (2-Level Card Architecture)
    @Published public var personalizeCardIndex: Int = 1 // 0: Reset, 1: Language, 2: Colors/Glass, 3: Icons, 4: Sound
    @Published public var isInsidePersonalizeCard: Bool = false
    @Published public var personalizeLangFocus: Int = 0
    @Published public var personalizeColorFocus: Int = 0 // 0..7: Swatches, 8: Glass Slider, 9: Glass Toggle
    @Published public var personalizeIconFocus: Int = 0 // AppIconAppearanceMode index
    @Published public var personalizeMenuBarFocus: Int = 0 // MenuBarIconStyle index
    @Published public var gameToDelete: PortedGame? = nil
    @Published public var showDeleteConfirm: Bool = false
    @Published public var hiddenGamePaths: Set<String> = [] {
        didSet {
            UserDefaults.standard.set(Array(hiddenGamePaths), forKey: StorageKeys.savedHiddenGamePaths)
        }
    }
    @Published public var removedGamePaths: Set<String> = [] {
        didSet {
            UserDefaults.standard.set(Array(removedGamePaths), forKey: StorageKeys.savedRemovedGamePaths)
        }
    }
    @Published public var gameToHide: PortedGame? = nil
    @Published public var showHideConfirm: Bool = false
    @Published public var gameToRemove: PortedGame? = nil
    @Published public var showRemoveConfirm: Bool = false
    @Published public var gameToTrash: PortedGame? = nil
    @Published public var showTrashConfirm: Bool = false
    
    // MARK: - Non-Switch Games & Filtering & Sorting
    internal var isInitializing: Bool = true
    @Published public var savedNonSwitchAppPaths: [String] = [] {
        didSet {
            UserDefaults.standard.set(savedNonSwitchAppPaths, forKey: StorageKeys.savedNonSwitchAppPaths)
            if !isInitializing {
                refreshLibrary()
            }
        }
    }
    @Published public var nonSwitchGameFolders: [URL] = [] {
        didSet {
            let paths = nonSwitchGameFolders.map { $0.path }
            UserDefaults.standard.set(paths, forKey: StorageKeys.savedNonSwitchGameFolders)
            if !isInitializing {
                refreshLibrary()
            }
        }
    }
    @Published public var lastPlayedTimestamps: [String: Double] = [:] {
        didSet {
            UserDefaults.standard.set(lastPlayedTimestamps, forKey: StorageKeys.savedLastPlayedDates)
        }
    }
    @Published public var activeGroupFilter: LibraryGroupFilter = .categories {
        didSet {
            UserDefaults.standard.set(activeGroupFilter.rawValue, forKey: StorageKeys.savedActiveGroupFilter)
        }
    }
    @Published public var activeLibraryTab: LibrarySubTab = .switch1And2 {
        didSet {
            UserDefaults.standard.set(activeLibraryTab.rawValue, forKey: "NXNative_SavedLibrarySubTab")
            reconcileLibraryFocusState()
        }
    }
    @Published public var activeSortOption: LibrarySortOption = .lastPlayed {
        didSet {
            UserDefaults.standard.set(activeSortOption.rawValue, forKey: StorageKeys.savedActiveSortOption)
            applyActiveSorting()
        }
    }
    
    public func recordLastPlayed(for game: PortedGame) {
        let key = game.uniqueKey
        let now = Date().timeIntervalSince1970
        var dict = lastPlayedTimestamps
        dict[key] = now
        lastPlayedTimestamps = dict
    }
    
    public func lastPlayedDate(for game: PortedGame) -> Date? {
        if let ts = lastPlayedTimestamps[game.uniqueKey] {
            return Date(timeIntervalSince1970: ts)
        }
        return nil
    }
    
    public func formattedPlayTime(for game: PortedGame) -> String {
        PlayTimeService.shared.formattedPlayTime(for: game)
    }
    
    public func addNonSwitchGame(url: URL, autoRefresh: Bool = true) {
        let clean = url.standardizedFileURL
        let path = clean.path
        guard FileManager.default.fileExists(atPath: path), clean.pathExtension.lowercased() == "app" else { return }
        hiddenGamePaths.remove(path)
        hiddenGamePaths.remove(url.path)
        hiddenGamePaths.remove(clean.standardized.path)
        removedGamePaths.remove(path)
        removedGamePaths.remove(url.path)
        removedGamePaths.remove(clean.standardized.path)
        if !savedNonSwitchAppPaths.contains(path) {
            var paths = savedNonSwitchAppPaths
            paths.append(path)
            savedNonSwitchAppPaths = paths
        }
        let parent = clean.deletingLastPathComponent().standardizedFileURL
        if !nonSwitchGameFolders.contains(where: { $0.standardizedFileURL.path == parent.path }) {
            nonSwitchGameFolders.append(parent)
        }
        if !gameFolders.contains(where: { $0.standardizedFileURL.path == parent.path }) {
            gameFolders.append(parent)
        }
        if autoRefresh {
            DispatchQueue.main.async {
                self.selectedTab = 0
                self.refreshLibrary(focusOnOutputURL: clean)
                SoundEffectService.shared.play(.click)
                let name = clean.deletingPathExtension().lastPathComponent
                self.logs.append(LogEntry(level: .success, message: "Added \(name) to Library."))
            }
        }
    }
    
    public func removeNonSwitchGame(path: String) {
        savedNonSwitchAppPaths.removeAll { $0 == path }
    }
    
    // MARK: - Compatibility Database
    @Published public var compatibleGames: [CompatibleGameItem] = []
    @Published public var isLoadingCompatibility: Bool = false
    @Published public var compatibilityFilter: String = "All"
    @Published public var compatibilityRamFilter: Int? = nil
    @Published public var compatibilityChipFilter: IphoneChipTier? = nil
    @Published public var compatibilityAndroidGpuFilter: AndroidGpuTier? = nil
    @Published public var compatibilityGenerationFilter: SwitchGenerationFilter = .all
    @Published public var compatibilityPlatformFilter: CompatibilityPlatformFilter = .all
    @Published public var compatibilityOnlyMyDevice: Bool = false
    @Published public var compatibilityNameFilter: String = "All"
    @Published public var compatibilitySearchText: String = ""
    @Published public var compatibilityLastUpdated: Date? = nil
    @Published public var isCompatibilityFromOnline: Bool = false
    
    // MARK: - Cloud Sources & Compatibility Downloads
    @Published public var cloudSources: [CloudGameSource] = []
    @Published public var cloudAvailableGames: [String: CloudAvailableGame] = [:] // [titleId: CloudAvailableGame]
    @Published public var cloudStreamsByTitleId: [String: [CloudAvailableGame]] = [:] // [titleId: [CloudAvailableGame]]
    @Published public var selectedGameForStreams: CompatibleGameItem? = nil
    @Published public var activeCloudDownloads: [String: DownloadTaskItem] = [:]   // [titleId: DownloadTaskItem]
    @Published public var filterOnlyAvailableInCloud: Bool = false
    @Published public var showCloudSourcesSheet: Bool = false
    @Published public var isSyncingCloudSources: Bool = false

    public var macPhysicalMemoryGB: Int {
        Int(ProcessInfo.processInfo.physicalMemory / (1024 * 1024 * 1024))
    }
    @Published public var compatibilityDisplayMode: CompatibilityDisplayMode = .list {
        didSet {
            UserDefaults.standard.set(compatibilityDisplayMode.rawValue, forKey: StorageKeys.savedCompatibilityDisplayMode)
        }
    }
    @Published public var compatibilityFocusArea: CompatibilityFocusArea = .filters
    @Published public var focusedCompatibilityIndex: Int = 0
    @Published public var focusedCompatibilityButtonIndex: CompatibilityButtonFocus = .notes
    @Published public var compatibilityGridColumnCount: Int = 6
    
    // MARK: - System Prerequisites & Installer
    @Published public var prerequisites: SystemPrerequisites = SystemPrerequisites()
    @Published public var isCheckingPrerequisites: Bool = false
    @Published public var isInstallingDependency: Bool = false
    @Published public var installerCurrentItem: String? = nil
    @Published public var installerLogs: [String] = []
    @Published public var showInstallerSheet: Bool = false
    @Published public var dependencyToUninstall: DependencyStatus? = nil
    @Published public var showUninstallConfirm: Bool = false
    
    // MARK: - Update Checker & About Sheet
    @Published public var showAboutSheet: Bool = false
    @Published public var showUpdateSheet: Bool = false
    @Published public var showControlsGuideSheet: Bool = false
    @Published public var showNxDeploymentBatchModal: Bool = false
    
    public func openNxDeploymentBatchModal() {
        SoundEffectService.shared.play(.click)
        showNxDeploymentBatchModal = true
    }
    @Published public var isCheckingUpdate: Bool = false
    @Published public var updateInfo: UpdateInfo? = nil
    @Published public var isApplyingUpdate: Bool = false
    @Published public var updateProgressFraction: Double = 0.0
    @Published public var updateStatusText: String = ""
    @Published public var updateInstallLogs: [String] = []
    @Published public var updateCompletedReadyToRelaunch: Bool = false
    @Published public var isSyncingUpstream: Bool = false
    @Published public var updateSuccessBanner: String? = nil
    @Published public var updateErrorBanner: String? = nil
    @Published public var translatedReleaseSummary: String? = nil
    @Published public var translatedReleaseCategories: [ReleaseHighlightCategory]? = nil
    @Published public var isTranslatingReleaseNotes: Bool = false
    @Published public var showOriginalReleaseNotes: Bool = false
    
    // MARK: - Advanced Options
    @Published public var appName: String = ""
    @Published public var bundleId: String = ""
    @Published public var selectedLanguage: String = "auto"
    @Published public var showFps: Bool = true {
        didSet {
            UserDefaults.standard.set(showFps, forKey: StorageKeys.savedShowFps)
        }
    }
    @Published public var keepExtracted: Bool = true {
        didSet {
            UserDefaults.standard.set(keepExtracted, forKey: StorageKeys.savedKeepExtracted)
        }
    }
    @Published public var surveyOnly: Bool = false
    @Published public var allowOtherMetal: Bool = true {
        didSet {
            UserDefaults.standard.set(allowOtherMetal, forKey: StorageKeys.savedAllowOtherMetal)
        }
    }
    @Published public var metalToolchainInfo: MetalToolchainInfo? = nil
    @Published public var userDidManuallyOverrideRomfsSeparate: Bool = false
    @Published public var romfsSeparate: Bool = false {
        didSet {
            UserDefaults.standard.set(romfsSeparate, forKey: StorageKeys.savedRomfsSeparate)
            if romfsSeparate {
                keepExtracted = true
            }
        }
    }
    @Published public var autoRomfsSplitLimitGB: Double = 8.0 {
        didSet {
            UserDefaults.standard.set(autoRomfsSplitLimitGB, forKey: StorageKeys.savedAutoRomfsSplitLimitGB)
            evaluateAutoRomfsSplit()
        }
    }
    @Published public var customCertP12Path: String = "" {
        didSet {
            UserDefaults.standard.set(customCertP12Path, forKey: StorageKeys.savedCustomCertP12Path)
        }
    }
    @Published public var customCertPassword: String = "" {
        didSet {
            UserDefaults.standard.set(customCertPassword, forKey: StorageKeys.savedCustomCertPassword)
        }
    }
    @Published public var customProvisioningProfilePath: String = "" {
        didSet {
            UserDefaults.standard.set(customProvisioningProfilePath, forKey: StorageKeys.savedCustomProvisioningProfilePath)
        }
    }
    
    public var shouldSuggestRomfsSplit: Bool {
        guard platform == .ios else { return false }
        let totalBytes = selectedGame?.totalSizeBytes ?? detectedFiles.reduce(0) { $0 + $1.sizeBytes }
        let limitBytes = Int64(autoRomfsSplitLimitGB * 1_073_741_824)
        return totalBytes >= limitBytes
    }
    
    public func evaluateAutoRomfsSplit() {
        guard platform == .ios else { return }
        if shouldSuggestRomfsSplit {
            if !userDidManuallyOverrideRomfsSeparate {
                romfsSeparate = true
            }
        } else {
            if !userDidManuallyOverrideRomfsSeparate {
                romfsSeparate = false
            }
        }
        if isKeepExtractedLocked {
            keepExtracted = true
        }
    }
    
    public var isRomfsSeparateAutoActive: Bool {
        platform == .ios && romfsSeparate && shouldSuggestRomfsSplit && !userDidManuallyOverrideRomfsSeparate
    }
    
    public var isKeepExtractedLocked: Bool {
        if platform == .macApp { return true }
        if platform == .ios && romfsSeparate { return true }
        return false
    }
    
    public var keepExtractedLockReason: String? {
        if platform == .macApp {
            return tr("build.opt_keep_extracted_locked_mac")
        }
        if platform == .ios && romfsSeparate {
            return tr("build.opt_keep_extracted_locked_romfs")
        }
        return nil
    }
    
    public var selectedGameSizeString: String {
        let totalBytes = selectedGame?.totalSizeBytes ?? detectedFiles.reduce(0) { $0 + $1.sizeBytes }
        return ByteCountFormatter.string(fromByteCount: totalBytes, countStyle: .file)
    }
    
    // MARK: - Build State
    @Published public var isBuilding: Bool = false
    @Published public var currentStageName: String = ""
    @Published public var currentStepName: String = ""
    @Published public var stageIndex: Int = 0
    @Published public var totalStages: Int = 0
    @Published public var progressFraction: Double = 0.0
    @Published public var etaSeconds: Double? = nil
    @Published public var buildStages: [BuildStageItem] = []
    @Published public var showLiveLogsInBuild: Bool = true
    @Published public var logs: [LogEntry] = []
    @Published public var buildError: String? = nil
    @Published public var buildSuccessPath: String? = nil
    @Published public var buildWizardStep: Int = 1
    @Published public var isDeveloperMode: Bool = false {
        didSet {
            UserDefaults.standard.set(isDeveloperMode, forKey: StorageKeys.savedDeveloperMode)
            if !isDeveloperMode && selectedTab == 5 {
                selectedTab = 0
            }
        }
    }
    @Published public var iconAppearanceMode: AppIconAppearanceMode = .default {
        didSet {
            UserDefaults.standard.set(iconAppearanceMode.rawValue, forKey: StorageKeys.savedIconAppearanceMode)
            UserDefaults.standard.synchronize()
            updateDockIcon(userInitiated: true)
            DispatchQueue.main.async {
                MenuBarManager.shared.updateMenuBarIcon()
            }
        }
    }
    @Published public var menuBarIconStyle: MenuBarIconStyle = .matchAppIcon {
        didSet {
            UserDefaults.standard.set(menuBarIconStyle.rawValue, forKey: StorageKeys.savedMenuBarIconStyle)
            let style = menuBarIconStyle
            DispatchQueue.main.async {
                MenuBarManager.shared.updateMenuBarIcon(style: style)
            }
        }
    }
    @Published public var highlightTheme: LauncherHighlightTheme = NXTheme.activeHighlightTheme {
        didSet {
            NXTheme.activeHighlightTheme = highlightTheme
            UserDefaults.standard.set(highlightTheme.rawValue, forKey: StorageKeys.savedHighlightTheme)
        }
    }
    @Published public var isLiquidGlassEnabled: Bool = NXTheme.isLiquidGlassEnabled {
        didSet {
            NXTheme.isLiquidGlassEnabled = isLiquidGlassEnabled
            UserDefaults.standard.set(isLiquidGlassEnabled, forKey: StorageKeys.savedLiquidGlassEnabled)
        }
    }
    @Published public var liquidGlassAppearance: LiquidGlassAppearance = NXTheme.liquidGlassAppearance {
        didSet {
            NXTheme.liquidGlassAppearance = liquidGlassAppearance
            UserDefaults.standard.set(liquidGlassAppearance.rawValue, forKey: StorageKeys.savedLiquidGlassAppearance)
        }
    }
    @Published public var liquidGlassIntensity: Double = NXTheme.liquidGlassIntensity {
        didSet {
            let clamped = min(max(liquidGlassIntensity, 0.0), 1.0)
            NXTheme.liquidGlassIntensity = clamped
            UserDefaults.standard.set(clamped, forKey: StorageKeys.savedLiquidGlassIntensity)
            let derivedMode: LiquidGlassAppearance = clamped >= 0.5 ? .liquid : .frosted
            if liquidGlassAppearance != derivedMode {
                liquidGlassAppearance = derivedMode
            }
        }
    }
    public var liquidGlassEnvironment: NXLiquidGlassEnvironment {
        NXLiquidGlassEnvironment(
            isEnabled: isLiquidGlassEnabled,
            appearance: liquidGlassAppearance,
            intensity: liquidGlassIntensity,
            highlightTheme: highlightTheme
        )
    }
    @Published public var launcherLanguage: AppLanguage = .system {
        didSet {
            UserDefaults.standard.set(launcherLanguage.rawValue, forKey: StorageKeys.savedLauncherLanguage)
            LocalizationService.shared.currentLanguage = launcherLanguage
            DispatchQueue.main.async {
                MenuBarManager.shared.refreshLocalizedUI()
            }
        }
    }
    
    // MARK: - Navigation & Gamepad State
    @Published public var selectedTab: Int = 0 {
        didSet {
            if railFocusIndex != selectedTab {
                railFocusIndex = selectedTab
            }
        }
    }
    @Published public var focusZone: LauncherFocusZone = .content
    @Published public var railFocusIndex: Int = 0
    @Published public var headerFocusItem: HeaderFocusItem = .search
    @Published public var isSearchFieldProgrammaticallyFocused: Bool = false

    // Tab-specific toolbar & sub-item focus indices
    @Published public var compatibilityToolbarFocusIndex: Int = 0 // 0: New, 1: Generation, 2: RAM, 3: List/Grid, 4: Refresh
    @Published public var controlsSelectedDeviceIndex: Int = GameControllerService.shared.isGamepadConnected ? 0 : 1
    @Published public var logsFocusIndex: Int = 0 // 0: Auto-scroll, 1: Copy, 2: Clear
    @Published public var logsAutoScroll: Bool = true
    @Published public var logsScrollTrigger: Int = 0 // negative = page up, positive = page down

    // System Tab (Tab 4) 2-level navigation
    @Published public var systemHeaderFocusIndex: Int = 0 // -1: inside category/cards, 0: DevMode, 1: Install/Repair All
    @Published public var isInsideSystemCard: Bool = false
    @Published public var systemSubItemFocusIndex: Int = 0

    // Modal focus indices & sheet states
    @Published public var showNewControllerProfileModal: Bool = false
    @Published public var newProfileNameInput: String = ""
    @Published public var isNewProfileTextFocused: Bool = false
    @Published public var newProfileModalFocusIndex: Int = 0 // 0: TextField, 1: Cancel, 2: Create
    @Published public var aboutModalFocusIndex: Int = 2 // 0: GitLab, 1: Check Updates, 2: Close
    @Published public var updateModalTabIndex: Int = 0 // 0: Highlights, 1: Commits
    @Published public var updateModalFocusIndex: Int = 0 // Footer/actions index
    @Published public var updateModalScrollTrigger: Int = 0
    @Published public var batchModalFocusIndex: Int = 0 // Game rows + header/footer buttons
    @Published public var batchSelectedGameIds: Set<String> = []
    @Published public var ryujinxSheetFocusIndex: Int = 2 // 0: Cancel, 1: Select Folder, 2: Select prod.keys
    @Published public var controlsGuideFocusIndex: Int = 1 // 0: Customize Keybindings, 1: Done
    @Published public var installerSheetFocusIndex: Int = 0 // 0: Close
    @Published public var confirmDialogFocusIndex: Int = 1 // 0: Confirm, 1: Cancel
    @Published public var settingsModalSubFocusIndex: Int = 0

    @Published public var focusedGameIndex: Int = 0
    @Published public var focusedMacIndex: Int = 0
    @Published public var focusedSwitch2Index: Int = 0
    @Published public var focusedIosIndex: Int = 0
    @Published public var focusedNonSwitchIndex: Int = 0
    @Published public var focusedUnifiedIndex: Int = 0
    @Published public var unifiedGridColumnsCount: Int = 4
    @Published public var activeLibraryShelf: LibraryShelfFocus = .mac
    @Published public var focusedUnportedGameIndex: Int = 0
    @Published public var isFocusOnHeroBar: Bool = false
    @Published public var isViewingGameDetail: Bool = false
    @Published public var heroActionFocusIndex: Int = 0
    @Published public var portModalFocusIndex: Int = 0
    @Published public var isPortAdvancedExpanded: Bool = false
    @Published public var showRyujinxNotFoundSheet: Bool = false
    @Published public var isFocusOnDeck: Bool = false
    @Published public var isGameActionMenuPresented: Bool = false
    @Published public var gameActionFocusedIndex: Int = 0
    @Published public var launchingGameId: UUID? = nil
    @Published public var runningGameTitle: String? = nil

    public func trimHistoricalLogs(keepCount: Int = 200) {
        if logs.count > keepCount {
            logs = Array(logs.suffix(keepCount))
        }
        if installerLogs.count > keepCount {
            installerLogs = Array(installerLogs.suffix(keepCount))
        }
        if updateInstallLogs.count > keepCount {
            updateInstallLogs = Array(updateInstallLogs.suffix(keepCount))
        }
    }
    
    public var availableLanguages: [(code: String, label: String)] {
        Self.availableLanguages
    }
    
    public func tr(_ key: String, _ args: CVarArg...) -> String {
        LocalizationService.shared.format(key: key, arguments: args)
    }
    
    let runner = BuildRunner()
    let installer = InstallerService.shared
    let updateChecker = UpdateCheckerService.shared
    
    public init() {
        Self.shared = self
        runner.delegate = self
        installer.delegate = self
        updateChecker.delegate = self
        
        SystemDetector.shared.ensureStorageDirectoriesAndSymlinks()
        let root = SystemDetector.shared.resolveRootDirectory()
        self.defaultInstallPath = root.path
        
        if let savedLib = SystemDetector.shared.resolveDirectoryIfAvailable(atPath: UserDefaults.standard.string(forKey: StorageKeys.savedLibraryFolder)) {
            self.libraryFolder = savedLib
        } else {
            self.libraryFolder = root.appendingPathComponent("Games")
        }
        
        if UserDefaults.standard.object(forKey: StorageKeys.savedUseCustomOutput) != nil {
            self.useCustomOutputFolder = UserDefaults.standard.bool(forKey: StorageKeys.savedUseCustomOutput)
        }
        if let savedOut = SystemDetector.shared.resolveDirectoryIfAvailable(atPath: UserDefaults.standard.string(forKey: StorageKeys.savedCustomOutputFolder)) {
            self.customOutputFolder = savedOut
        }
        if self.useCustomOutputFolder && self.customOutputFolder == nil {
            self.useCustomOutputFolder = false
        }
        
        if let savedFps = UserDefaults.standard.object(forKey: StorageKeys.savedShowFps) as? Bool {
            self.showFps = savedFps
        }
        if let savedKeep = UserDefaults.standard.object(forKey: StorageKeys.savedKeepExtracted) as? Bool {
            self.keepExtracted = savedKeep
        }
        if let savedPlat = UserDefaults.standard.string(forKey: StorageKeys.savedPlatform),
           let p = TargetPlatform(rawValue: savedPlat) {
            self.platform = p
        }
        if let savedRomfs = UserDefaults.standard.object(forKey: StorageKeys.savedRomfsSeparate) as? Bool {
            self.romfsSeparate = savedRomfs
        }
        if let savedAllowMetal = UserDefaults.standard.object(forKey: StorageKeys.savedAllowOtherMetal) as? Bool {
            self.allowOtherMetal = savedAllowMetal
        }
        if let savedSplitLimit = UserDefaults.standard.object(forKey: StorageKeys.savedAutoRomfsSplitLimitGB) as? Double {
            self.autoRomfsSplitLimitGB = savedSplitLimit
        }
        if let savedP12 = UserDefaults.standard.string(forKey: StorageKeys.savedCustomCertP12Path) {
            self.customCertP12Path = savedP12
        }
        if let savedPass = UserDefaults.standard.string(forKey: StorageKeys.savedCustomCertPassword) {
            self.customCertPassword = savedPass
        }
        if let savedProfile = UserDefaults.standard.string(forKey: StorageKeys.savedCustomProvisioningProfilePath) {
            self.customProvisioningProfilePath = savedProfile
        }
        if let savedMode = UserDefaults.standard.string(forKey: StorageKeys.savedIconAppearanceMode) {
            self.iconAppearanceMode = AppIconAppearanceMode.from(saved: savedMode)
        }
        if let savedMenuStyle = UserDefaults.standard.string(forKey: StorageKeys.savedMenuBarIconStyle),
           let menuStyle = MenuBarIconStyle(rawValue: savedMenuStyle) {
            self.menuBarIconStyle = menuStyle
        }
        if let savedTheme = UserDefaults.standard.string(forKey: StorageKeys.savedHighlightTheme),
           let theme = LauncherHighlightTheme(rawValue: savedTheme) {
            NXTheme.activeHighlightTheme = theme
            self.highlightTheme = theme
        }
        if let savedGlassEnabled = UserDefaults.standard.object(forKey: StorageKeys.savedLiquidGlassEnabled) as? Bool {
            NXTheme.isLiquidGlassEnabled = savedGlassEnabled
            self.isLiquidGlassEnabled = savedGlassEnabled
        }
        if let savedGlassMode = UserDefaults.standard.string(forKey: StorageKeys.savedLiquidGlassAppearance),
           let glassMode = LiquidGlassAppearance(rawValue: savedGlassMode) {
            NXTheme.liquidGlassAppearance = glassMode
            self.liquidGlassAppearance = glassMode
        }
        if let savedIntensity = UserDefaults.standard.object(forKey: StorageKeys.savedLiquidGlassIntensity) as? Double {
            let clamped = min(max(savedIntensity, 0.0), 1.0)
            NXTheme.liquidGlassIntensity = clamped
            self.liquidGlassIntensity = clamped
        } else {
            let fallback = self.liquidGlassAppearance == .liquid ? 1.0 : 0.0
            NXTheme.liquidGlassIntensity = fallback
            self.liquidGlassIntensity = fallback
        }
        if let savedDisplay = UserDefaults.standard.string(forKey: StorageKeys.savedCompatibilityDisplayMode),
           let dispMode = CompatibilityDisplayMode(rawValue: savedDisplay) {
            self.compatibilityDisplayMode = dispMode
        }
        if let savedCardSize = UserDefaults.standard.string(forKey: StorageKeys.savedLibraryCardSize),
           let size = LibraryCardSize(rawValue: savedCardSize) {
            self.libraryCardSize = size
        }
        if let savedScale = UserDefaults.standard.object(forKey: StorageKeys.savedLibraryCardScale) as? Double {
            self.libraryCardScale = max(0.70, min(1.50, savedScale))
        }
        if let savedDev = UserDefaults.standard.object(forKey: StorageKeys.savedDeveloperMode) as? Bool {
            self.isDeveloperMode = savedDev
        }
        if let savedLang = UserDefaults.standard.string(forKey: StorageKeys.savedLauncherLanguage),
           let lang = AppLanguage(rawValue: savedLang) {
            self.launcherLanguage = lang
            LocalizationService.shared.currentLanguage = lang
        } else {
            self.launcherLanguage = .system
            LocalizationService.shared.currentLanguage = .system
        }
        
        detectEnvironment()
        
        // Load Game Folders
        self.isUpdatingSelectedGameFolderFromAdd = true
        if let savedFolders = UserDefaults.standard.stringArray(forKey: StorageKeys.savedGameFolders) {
            let urls = savedFolders.compactMap { path -> URL? in
                var isDir: ObjCBool = false
                if FileManager.default.fileExists(atPath: path, isDirectory: &isDir), isDir.boolValue {
                    return URL(fileURLWithPath: path)
                }
                return nil
            }
            self.gameFolders = urls
            self.selectedGameFolder = urls.first
        } else if let savedGamePath = UserDefaults.standard.string(forKey: StorageKeys.savedGameFolder) {
            var isDir: ObjCBool = false
            if FileManager.default.fileExists(atPath: savedGamePath, isDirectory: &isDir), isDir.boolValue {
                let singleURL = URL(fileURLWithPath: savedGamePath)
                self.selectedGameFolder = singleURL
                self.gameFolders = [singleURL]
            }
        }
        self.isUpdatingSelectedGameFolderFromAdd = false
        
        // Load Non-Switch Games
        if let savedNonSwitch = UserDefaults.standard.stringArray(forKey: StorageKeys.savedNonSwitchAppPaths) {
            self.savedNonSwitchAppPaths = savedNonSwitch
        }
        
        // Load Non-Switch Game Folders
        if let savedNonSwitchFolders = UserDefaults.standard.stringArray(forKey: StorageKeys.savedNonSwitchGameFolders) {
            let urls = savedNonSwitchFolders.compactMap { path -> URL? in
                let url = URL(fileURLWithPath: path)
                return FileManager.default.fileExists(atPath: path) ? url : nil
            }
            self.nonSwitchGameFolders = urls
        }
        
        // Load Last Played Dates
        if let savedDates = UserDefaults.standard.dictionary(forKey: StorageKeys.savedLastPlayedDates) as? [String: Double] {
            self.lastPlayedTimestamps = savedDates
        }
        
        // Load Filters & Sorting
        if let savedFilter = UserDefaults.standard.string(forKey: StorageKeys.savedActiveGroupFilter),
           let filter = LibraryGroupFilter(rawValue: savedFilter) {
            self.activeGroupFilter = filter
        }
        if let savedSort = UserDefaults.standard.string(forKey: StorageKeys.savedActiveSortOption),
           let sort = LibrarySortOption(rawValue: savedSort) {
            self.activeSortOption = sort
        }
        if let savedTab = UserDefaults.standard.string(forKey: "NXNative_SavedLibrarySubTab"),
           let tab = LibrarySubTab(rawValue: savedTab) {
            self.activeLibraryTab = tab
        }
        
        if let savedHidden = UserDefaults.standard.stringArray(forKey: StorageKeys.savedHiddenGamePaths) {
            self.hiddenGamePaths = Set(savedHidden)
        }
        if let savedRemoved = UserDefaults.standard.stringArray(forKey: StorageKeys.savedRemovedGamePaths) {
            self.removedGamePaths = Set(savedRemoved)
        }
        
        // Force one-time cleanup of legacy image cache containing old eShop icons / uncropped console headers
        let legacyCacheCleanKey = "nxnative_cleaned_legacy_image_cache_v2_2_0"
        if !UserDefaults.standard.bool(forKey: legacyCacheCleanKey) {
            _ = BuildCleanupService.shared.cleanImageCache()
            UserDefaults.standard.set(true, forKey: legacyCacheCleanKey)
        }
        
        self.isInitializing = false
        evaluateInitialOnboardingState()
        InputProfileManager.shared.exportActiveMappingToDisk(libraryFolder: self.libraryFolder)
        loadLibraryCache()
        scanAllGameFolders()
        refreshLibrary()
        loadCompatibleGames()
        loadCloudSources()
        updateDockIcon()
        setupWindowMinimizeIconObserver()
        
        NotificationCenter.default.addObserver(
            forName: NSApplication.didBecomeActiveNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            guard let self = self, !self.isBuilding, !self.gameFolders.isEmpty else { return }
            self.scanAllGameFolders()
        }
        
        setupControllerNavigation()
        detectSDKVersion()
        if !isShowingOnboarding {
            checkForUpdates(showModalIfAvailable: true)
            NotificationService.shared.requestAuthorization()
            startAutoProvisioning()
        } else {
            recalculateOnboardingEstimate()
        }
        
        DispatchQueue.main.async { [weak self] in
            guard let self = self else { return }
            MenuBarManager.shared.configure(with: self)
        }
    }
    
    // MARK: - Custom Signing Pickers
    public func selectCustomCertP12() {
        let panel = NSOpenPanel()
        panel.canChooseFiles = true
        panel.canChooseDirectories = false
        panel.allowsMultipleSelection = false
        panel.prompt = "Select .p12 Certificate"
        panel.message = "Choose your custom Apple Developer Certificate (.p12)."
        if panel.runModal() == .OK, let url = panel.url {
            self.customCertP12Path = url.path
        }
    }

    public func selectCustomProvisioningProfile() {
        let panel = NSOpenPanel()
        panel.canChooseFiles = true
        panel.canChooseDirectories = false
        panel.allowsMultipleSelection = false
        panel.prompt = "Select .mobileprovision"
        panel.message = "Choose your custom Provisioning Profile (.mobileprovision)."
        if panel.runModal() == .OK, let url = panel.url {
            self.customProvisioningProfilePath = url.path
        }
    }

    // MARK: - Library Sub-Tab Cycling
    public func nextLibrarySubTab() {
        let all = LibrarySubTab.allCases
        guard let idx = all.firstIndex(of: activeLibraryTab) else { return }
        let nextIdx = (idx + 1) % all.count
        SoundEffectService.shared.play(.tabSwitch)
        activeLibraryTab = all[nextIdx]
    }

    public func previousLibrarySubTab() {
        let all = LibrarySubTab.allCases
        guard let idx = all.firstIndex(of: activeLibraryTab) else { return }
        let prevIdx = (idx - 1 + all.count) % all.count
        SoundEffectService.shared.play(.tabSwitch)
        activeLibraryTab = all[prevIdx]
    }
}
