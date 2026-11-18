import Foundation
import SwiftUI
import AppKit

public enum OnboardingStep: Int, CaseIterable, Sendable {
    case language = 0
    case targetPlatforms = 1
    case dependenciesOverview = 2
    case installingDependencies = 3
    case prodKeys = 4
}

private struct OnboardingInstallSlice {
    let id: String
    let label: String
    let weight: Double
    let start: Double
    let end: Double
}

extension AppViewModel {
    /// Languages shown in the Step 1 selector, putting the macOS-resolved language first.
    public static let onboardingLanguages: [AppLanguage] = {
        let resolved = AppLanguage.resolve()
        let concrete = AppLanguage.allCases
            .filter { $0 != .system }
            .sorted { $0.nativeName.localizedStandardCompare($1.nativeName) == .orderedAscending }
        guard let idx = concrete.firstIndex(of: resolved) else { return concrete }
        var reordered = concrete
        let preferred = reordered.remove(at: idx)
        return [preferred] + reordered
    }()

    public static var isOnboardingForcedByArgument: Bool {
        ProcessInfo.processInfo.arguments.contains("--onboarding")
    }

    public var activeOnboardingLanguage: AppLanguage {
        launcherLanguage == .system ? AppLanguage.resolve() : launcherLanguage
    }

    public var onboardingPercentDone: Int {
        min(100, max(0, Int((onboardingProgress * 100.0).rounded())))
    }

    public var onboardingPercentRemaining: Int {
        max(0, 100 - onboardingPercentDone)
    }

    public var onboardingFormattedTotalSize: String {
        guard onboardingEstimatedTotalBytes > 0 else {
            return tr("onboarding.deps_all_ready_size")
        }
        let formatted = ByteCountFormatter.string(fromByteCount: onboardingEstimatedTotalBytes, countStyle: .file)
        return "~\(formatted)"
    }

    // MARK: - Initial Gate Evaluation

    internal func evaluateInitialOnboardingState() {
        if Self.isOnboardingForcedByArgument {
            beginOnboardingAtStep(.language)
            return
        }

        if let completed = UserDefaults.standard.object(forKey: StorageKeys.hasCompletedOnboarding) as? Bool {
            if completed {
                isShowingOnboarding = false
            } else {
                beginOnboardingAtStep(.language)
            }
            return
        }

        // Migrate existing users silently when legacy provisioning & core repo already exist.
        let legacyProvisioned = UserDefaults.standard.string(forKey: "NXNative_ProvisioningVersion") != nil
        if legacyProvisioned && isNxnativeValid {
            UserDefaults.standard.set(true, forKey: StorageKeys.hasCompletedOnboarding)
            isShowingOnboarding = false
        } else {
            beginOnboardingAtStep(.language)
        }
    }

    internal func evaluateLegacyOnboardingCompletionIfNeeded() {
        guard isShowingOnboarding, !Self.isOnboardingForcedByArgument else { return }
        guard onboardingStep == .language, !onboardingIsInstalling else { return }
        guard UserDefaults.standard.object(forKey: StorageKeys.hasCompletedOnboarding) == nil else { return }

        let legacyProvisioned = UserDefaults.standard.string(forKey: "NXNative_ProvisioningVersion") != nil
        if legacyProvisioned && isNxnativeValid && prerequisites.allSatisfied {
            completeOnboarding()
        }
    }

    private func beginOnboardingAtStep(_ step: OnboardingStep) {
        onboardingStep = step
        onboardingProgress = 0.0
        onboardingInstallError = nil
        onboardingWaitingForAppleCLT = false
        onboardingIsInstalling = false
        if let idx = Self.onboardingLanguages.firstIndex(of: activeOnboardingLanguage) {
            onboardingLanguageFocusIndex = idx
        } else {
            onboardingLanguageFocusIndex = 0
        }
        isShowingOnboarding = true
    }

    // MARK: - Dynamic Weight & Step Inventory

    private struct OnboardingPendingTask {
        let id: String
        let label: String
        let estimatedBytes: Int64
        let dependency: DependencyStatus?
    }

    private static func estimatedWeightBytes(for componentId: String) -> Int64 {
        switch componentId {
        case "xcode": return 1_900_000_000
        case "core_repo": return 1_700_000_000
        case "homebrew": return 360_000_000
        case "git": return 95_000_000
        case "python": return 120_000_000
        case "python_packages": return 45_000_000
        case "libimobiledevice": return 35_000_000
        case "android_ndk": return 1_180_000_000
        case "android_adb": return 18_000_000
        case "dotnet": return 1_200_000_000
        case "xcodegen": return 20_000_000
        case "zstd": return 10_000_000
        case "spirv_cross": return 15_000_000
        case "glslang": return 20_000_000
        case "metal_toolchain": return 866_000_000
        default: return 30_000_000
        }
    }

    private func computePendingOnboardingTasks() -> [OnboardingPendingTask] {
        var tasks: [OnboardingPendingTask] = []

        let orderedMissing = SystemPrerequisites.ordered(
            prerequisites.missingList(for: selectedOnboardingPlatforms).filter {
                $0.id != "xcode" && !($0.installCommand ?? "").trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            }
        )

        let needsCltForCoreOrBrew = !prerequisites.xcode.isAvailable && (
            !isNxnativeValid ||
            orderedMissing.contains { $0.id == "homebrew" || ($0.installCommand ?? "").contains("brew ") }
        )

        if needsCltForCoreOrBrew {
            tasks.append(OnboardingPendingTask(
                id: "xcode",
                label: prerequisites.xcode.name,
                estimatedBytes: Self.estimatedWeightBytes(for: "xcode"),
                dependency: prerequisites.xcode
            ))
        }

        if !isNxnativeValid {
            tasks.append(OnboardingPendingTask(
                id: "core_repo",
                label: "NxNative Core Engine",
                estimatedBytes: Self.estimatedWeightBytes(for: "core_repo"),
                dependency: nil
            ))
        }

        for dep in orderedMissing {
            tasks.append(OnboardingPendingTask(
                id: dep.id,
                label: dep.name,
                estimatedBytes: Self.estimatedWeightBytes(for: dep.id),
                dependency: dep
            ))
        }

        let hasFullXcode = FileManager.default.fileExists(atPath: "/Applications/Xcode.app")
            || prerequisites.xcode.details.hasPrefix("Xcode ")
        if hasFullXcode && (metalToolchainInfo?.isAvailable == false) {
            tasks.append(OnboardingPendingTask(
                id: "metal_toolchain",
                label: "Apple Metal Toolchain",
                estimatedBytes: Self.estimatedWeightBytes(for: "metal_toolchain"),
                dependency: nil
            ))
        }

        return tasks
    }

    public func recalculateOnboardingEstimate() {
        let tasks = computePendingOnboardingTasks()
        onboardingEstimatedTotalBytes = tasks.reduce(0) { $0 + $1.estimatedBytes }
        onboardingComponentCount = tasks.count
    }

    // MARK: - Step Navigation

    public func selectOnboardingLanguage(_ language: AppLanguage) {
        SoundEffectService.shared.play(.click)
        if let idx = Self.onboardingLanguages.firstIndex(of: language) {
            onboardingLanguageFocusIndex = idx
        }
        launcherLanguage = language
    }

    public func toggleOnboardingPlatform(_ platform: TargetPlatform) {
        SoundEffectService.shared.play(.click)
        if selectedOnboardingPlatforms.contains(platform) {
            if selectedOnboardingPlatforms.count > 1 {
                selectedOnboardingPlatforms.remove(platform)
            }
        } else {
            selectedOnboardingPlatforms.insert(platform)
        }
        recalculateOnboardingEstimate()
    }

    public func advanceOnboardingStep() {
        SoundEffectService.shared.play(.click)
        switch onboardingStep {
        case .language:
            withAnimation(.spring(response: 0.40, dampingFraction: 0.84)) {
                onboardingStep = .targetPlatforms
            }
        case .targetPlatforms:
            recalculateOnboardingEstimate()
            withAnimation(.spring(response: 0.40, dampingFraction: 0.84)) {
                onboardingStep = .dependenciesOverview
            }
        case .dependenciesOverview:
            startOnboardingInstallation()
        case .installingDependencies:
            break
        case .prodKeys:
            completeOnboarding()
        }
    }

    public func goBackOnboardingStep() {
        guard !onboardingIsInstalling else { return }
        switch onboardingStep {
        case .targetPlatforms:
            SoundEffectService.shared.play(.click)
            withAnimation(.spring(response: 0.36, dampingFraction: 0.84)) {
                onboardingStep = .language
            }
        case .dependenciesOverview:
            SoundEffectService.shared.play(.click)
            withAnimation(.spring(response: 0.36, dampingFraction: 0.84)) {
                onboardingStep = .targetPlatforms
            }
        default:
            break
        }
    }

    public func completeOnboarding() {
        stopOnboardingTimers()
        onboardingIsInstalling = false
        onboardingWaitingForAppleCLT = false
        isAutoProvisioningDependencies = false
        isInstallingDependency = false
        installerCurrentItem = nil
        provisioningStatus = ""
        UserDefaults.standard.set(true, forKey: StorageKeys.hasCompletedOnboarding)
        SoundEffectService.shared.play(.launch)

        withAnimation(.spring(response: 0.42, dampingFraction: 0.86)) {
            isShowingOnboarding = false
        }

        DispatchQueue.main.asyncAfter(deadline: .now() + 0.35) { [weak self] in
            guard let self = self else { return }
            self.detectEnvironment()
            self.checkForUpdates(showModalIfAvailable: true)
            NotificationService.shared.requestAuthorization()
            self.startAutoProvisioning()
        }
    }

    // MARK: - Step 3: Weighted 0% -> 100% Installation Pipeline

    public func startOnboardingInstallation() {
        guard !onboardingIsInstalling else { return }
        stopOnboardingTimers()

        onboardingInstallError = nil
        onboardingWaitingForAppleCLT = false
        onboardingIsInstalling = true
        onboardingProgress = 0.0
        onboardingStatusMessage = tr("onboarding.status_preparing")
        onboardingSubstatusMessage = ""

        withAnimation(.spring(response: 0.38, dampingFraction: 0.84)) {
            onboardingStep = .installingDependencies
        }

        let tasks = computePendingOnboardingTasks()
        guard !tasks.isEmpty else {
            runFastVerificationSweep()
            return
        }

        let slices = buildSlices(from: tasks)
        executeSliceQueue(slices, index: 0)
    }

    public func reopenAppleCltInstaller() {
        SoundEffectService.shared.play(.click)
        DispatchQueue.global(qos: .userInitiated).async {
            _ = BoundedProcess.run("/usr/bin/xcode-select", ["--install"], timeout: 10.0)
        }
    }

    public func skipFailedOnboardingInstallToKeys() {
        stopOnboardingTimers()
        onboardingIsInstalling = false
        onboardingWaitingForAppleCLT = false
        onboardingInstallError = nil
        SoundEffectService.shared.play(.click)
        withAnimation(.spring(response: 0.38, dampingFraction: 0.84)) {
            onboardingStep = .prodKeys
        }
    }

    private func buildSlices(from tasks: [OnboardingPendingTask]) -> [OnboardingInstallSlice] {
        // Guarantee tiny packages still produce visible forward progress.
        let floorBytes: Double = 60_000_000
        let weights = tasks.map { max(Double($0.estimatedBytes), floorBytes) }
        let sum = max(weights.reduce(0, +), 1.0)

        var cursor = 0.0
        var result: [OnboardingInstallSlice] = []
        for (idx, task) in tasks.enumerated() {
            let span = weights[idx] / sum
            let end = idx == tasks.count - 1 ? 1.0 : min(1.0, cursor + span)
            result.append(OnboardingInstallSlice(
                id: task.id,
                label: task.label,
                weight: weights[idx],
                start: cursor,
                end: end
            ))
            cursor = end
        }
        return result
    }

    private func runFastVerificationSweep() {
        onboardingStatusMessage = tr("onboarding.status_verifying")
        let steps: [(Double, Double)] = [(0.15, 0.35), (0.45, 0.75), (0.80, 1.0)]
        for (delay, target) in steps {
            DispatchQueue.main.asyncAfter(deadline: .now() + delay) { [weak self] in
                guard let self = self, self.onboardingIsInstalling else { return }
                self.advanceOnboardingProgressMonotonic(to: target)
                if target >= 1.0 {
                    self.finishOnboardingInstallationSuccess()
                }
            }
        }
    }

    private func executeSliceQueue(_ slices: [OnboardingInstallSlice], index: Int) {
        guard onboardingIsInstalling else { return }
        guard index < slices.count else {
            finishOnboardingInstallationSuccess()
            return
        }

        let slice = slices[index]
        onboardingStepStart = max(onboardingProgress, slice.start)
        onboardingStepEnd = slice.end
        advanceOnboardingProgressMonotonic(to: onboardingStepStart)

        switch slice.id {
        case "xcode":
            runCltInstallSlice(slice) { [weak self] ok, err in
                self?.handleSliceResult(ok: ok, errorDetail: err, slice: slice, slices: slices, nextIndex: index + 1)
            }
        case "core_repo":
            runCoreRepoSlice(slice) { [weak self] ok, err in
                self?.handleSliceResult(ok: ok, errorDetail: err, slice: slice, slices: slices, nextIndex: index + 1)
            }
        case "metal_toolchain":
            runMetalToolchainSlice(slice) { [weak self] _, _ in
                // MetalToolchain is optional/skipped automatically on CLT-only Macs.
                self?.handleSliceResult(ok: true, errorDetail: nil, slice: slice, slices: slices, nextIndex: index + 1)
            }
        default:
            runDependencySlice(slice) { [weak self] ok, err in
                self?.handleSliceResult(ok: ok, errorDetail: err, slice: slice, slices: slices, nextIndex: index + 1)
            }
        }
    }

    private func handleSliceResult(
        ok: Bool,
        errorDetail: String?,
        slice: OnboardingInstallSlice,
        slices: [OnboardingInstallSlice],
        nextIndex: Int
    ) {
        stopTrickleTimer()
        guard onboardingIsInstalling else { return }

        if ok {
            advanceOnboardingProgressMonotonic(to: slice.end)
            executeSliceQueue(slices, index: nextIndex)
        } else {
            onboardingIsInstalling = false
            onboardingWaitingForAppleCLT = false
            onboardingInstallError = errorDetail ?? "\(tr("onboarding.error_title")) (\(slice.label))"
            SoundEffectService.shared.play(.error)
            refreshPrerequisites()
        }
    }

    private func runCltInstallSlice(_ slice: OnboardingInstallSlice, completion: @escaping (Bool, String?) -> Void) {
        onboardingStatusMessage = tr("onboarding.status_xcode_clt")
        onboardingSubstatusMessage = ""
        onboardingWaitingForAppleCLT = true
        startTrickleTimer(within: slice, capRatio: 0.85, rate: 0.015)

        DispatchQueue.global(qos: .userInitiated).async {
            _ = BoundedProcess.run("/usr/bin/xcode-select", ["--install"], timeout: 10.0)
        }

        let deadline = Date().addingTimeInterval(1500)
        let timer = DispatchSource.makeTimerSource(queue: DispatchQueue.global(qos: .utility))
        timer.schedule(deadline: .now() + 2.0, repeating: 2.5)
        timer.setEventHandler { [weak self, weak timer] in
            let check = BoundedProcess.run("/usr/bin/xcode-select", ["-p"], timeout: 2.0)
            let path = check.output.trimmingCharacters(in: .whitespacesAndNewlines)
            if check.success && !path.isEmpty {
                timer?.cancel()
                let freshPrereqs = SystemDetector.shared.checkPrerequisites()
                DispatchQueue.main.async {
                    guard let self = self else { return }
                    self.onboardingPollTimer = nil
                    self.onboardingWaitingForAppleCLT = false
                    self.prerequisites = freshPrereqs
                    completion(true, nil)
                }
            } else if Date() >= deadline {
                timer?.cancel()
                DispatchQueue.main.async {
                    self?.onboardingPollTimer = nil
                    self?.onboardingWaitingForAppleCLT = false
                    completion(false, "Xcode Command Line Tools installation timed out.")
                }
            }
        }
        onboardingPollTimer = timer
        timer.resume()
    }

    private func runCoreRepoSlice(_ slice: OnboardingInstallSlice, completion: @escaping (Bool, String?) -> Void) {
        onboardingStatusMessage = tr("onboarding.status_core_repo")
        onboardingSubstatusMessage = ""
        let dest = URL(fileURLWithPath: defaultInstallPath).appendingPathComponent("nxnative")
        isCloningRepository = true

        SystemDetector.shared.cloneNxnativeRepositoryWithProgress(to: dest, onProgress: { [weak self] fraction, line in
            guard let self = self, self.onboardingIsInstalling else { return }
            if fraction >= 0 {
                let target = slice.start + (slice.end - slice.start) * fraction
                self.advanceOnboardingProgressMonotonic(to: target)
            }
            let trimmed = line.trimmingCharacters(in: .whitespacesAndNewlines)
            if !trimmed.isEmpty {
                self.onboardingSubstatusMessage = trimmed
            }
        }) { [weak self] success, output in
            guard let self = self else { return }
            self.isCloningRepository = false
            if success {
                if !SystemDetector.isValidNxnativeDirectory(SystemDetector.shared.savedCustomNxnativeDirectory ?? "") {
                    SystemDetector.shared.saveCustomNxnativeDirectory(nil)
                }
                PatchService.shared.applyPatchesIfNeeded(nxnativePath: dest.path)
                self.detectEnvironment()
                completion(true, nil)
            } else {
                let msg = output.components(separatedBy: .newlines).last { !$0.trimmingCharacters(in: .whitespaces).isEmpty }
                completion(false, msg ?? "Core repository download failed.")
            }
        }
    }

    private func runDependencySlice(_ slice: OnboardingInstallSlice, completion: @escaping (Bool, String?) -> Void) {
        let freshPrereqs = SystemDetector.shared.checkPrerequisites()
        self.prerequisites = freshPrereqs

        guard let dep = freshPrereqs.list.first(where: { $0.id == slice.id }), !dep.isAvailable else {
            completion(true, nil)
            return
        }

        onboardingStatusMessage = tr("provisioning.installing_item", dep.name)
        onboardingSubstatusMessage = ""
        isInstallingDependency = true
        isAutoProvisioningDependencies = false
        installerLogs.append("[Onboarding] Installing \(dep.name)...")
        startTrickleTimer(within: slice, capRatio: 0.90, rate: 0.03)

        installer.install(dependency: dep) { [weak self] success in
            guard let self = self else { return }
            self.isInstallingDependency = false
            self.isAutoProvisioningDependencies = false
            self.installerCurrentItem = nil
            self.provisioningStatus = ""
            if success {
                self.refreshPrerequisites()
                completion(true, nil)
            } else {
                completion(false, "\(dep.name)")
            }
        }
    }

    private func runMetalToolchainSlice(_ slice: OnboardingInstallSlice, completion: @escaping (Bool, String?) -> Void) {
        onboardingStatusMessage = tr("onboarding.status_metal_toolchain")
        onboardingSubstatusMessage = ""
        startTrickleTimer(within: slice, capRatio: 0.92, rate: 0.02)

        DispatchQueue.global(qos: .utility).async { [weak self] in
            guard let self = self else { return }
            let metal = SystemDetector.shared.detectMetalToolchain(nxnativePath: self.nxnativePath)
            guard !metal.isAvailable, FileManager.default.fileExists(atPath: "/usr/bin/xcodebuild") else {
                DispatchQueue.main.async {
                    self.metalToolchainInfo = metal
                    completion(true, nil)
                }
                return
            }

            let res = BoundedProcess.runStreaming(
                "/usr/bin/xcodebuild",
                ["-downloadComponent", "MetalToolchain"],
                timeout: 1800
            ) { line in
                DispatchQueue.main.async {
                    guard self.onboardingIsInstalling else { return }
                    self.onboardingSubstatusMessage = line
                    if let pctIdx = line.firstIndex(of: "%") {
                        let prefix = line[..<pctIdx]
                        let digits = prefix.reversed().prefix(while: { $0.isNumber }).reversed()
                        if let pct = Int(String(digits)) {
                            let norm = Double(min(max(pct, 0), 100)) / 100.0
                            let target = slice.start + (slice.end - slice.start) * norm
                            self.advanceOnboardingProgressMonotonic(to: target)
                        }
                    }
                }
            }

            let updatedMetal = SystemDetector.shared.detectMetalToolchain(nxnativePath: self.nxnativePath)
            DispatchQueue.main.async {
                self.metalToolchainInfo = updatedMetal
                completion(res.success, res.success ? nil : res.output)
            }
        }
    }

    internal func handleOnboardingInstallerOutput(_ line: String) {
        let trimmed = line.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        onboardingSubstatusMessage = trimmed

        let lower = trimmed.lowercased()
        let span = max(0.0, onboardingStepEnd - onboardingStepStart)
        guard span > 0 else { return }

        if lower.contains("downloading") {
            advanceOnboardingProgressMonotonic(to: onboardingStepStart + span * 0.25)
        } else if lower.contains("pouring") || lower.contains("verifying") {
            advanceOnboardingProgressMonotonic(to: onboardingStepStart + span * 0.65)
        } else if lower.contains("installing") || lower.contains("summary") {
            advanceOnboardingProgressMonotonic(to: onboardingStepStart + span * 0.85)
        }
    }

    private func startTrickleTimer(within slice: OnboardingInstallSlice, capRatio: Double, rate: Double) {
        stopTrickleTimer()
        let cap = slice.start + (slice.end - slice.start) * capRatio
        let timer = DispatchSource.makeTimerSource(queue: DispatchQueue.main)
        timer.schedule(deadline: .now() + 0.35, repeating: 0.35)
        timer.setEventHandler { [weak self] in
            guard let self = self, self.onboardingIsInstalling else { return }
            if self.onboardingProgress < cap {
                let remaining = cap - self.onboardingProgress
                self.advanceOnboardingProgressMonotonic(to: self.onboardingProgress + remaining * rate)
            }
        }
        onboardingTrickleTimer = timer
        timer.resume()
    }

    private func stopTrickleTimer() {
        onboardingTrickleTimer?.cancel()
        onboardingTrickleTimer = nil
    }

    private func stopOnboardingTimers() {
        stopTrickleTimer()
        onboardingPollTimer?.cancel()
        onboardingPollTimer = nil
    }

    private func advanceOnboardingProgressMonotonic(to target: Double) {
        let clamped = min(1.0, max(onboardingProgress, target))
        guard clamped > onboardingProgress else { return }
        withAnimation(.easeOut(duration: 0.22)) {
            onboardingProgress = clamped
        }
    }

    private func finishOnboardingInstallationSuccess() {
        stopOnboardingTimers()
        onboardingProgress = 1.0
        onboardingStatusMessage = tr("onboarding.progress_done_label")
        onboardingSubstatusMessage = ""
        onboardingWaitingForAppleCLT = false
        detectEnvironment()
        SoundEffectService.shared.play(.launch)

        DispatchQueue.main.asyncAfter(deadline: .now() + 0.65) { [weak self] in
            guard let self = self else { return }
            self.onboardingIsInstalling = false
            withAnimation(.spring(response: 0.42, dampingFraction: 0.84)) {
                self.onboardingStep = .prodKeys
            }
        }
    }

    // MARK: - Step 4: prod.keys Drop Handler

    public func handleOnboardingDroppedKeys(providers: [NSItemProvider]) -> Bool {
        var droppedURLs: [URL] = []
        let group = DispatchGroup()

        for provider in providers {
            group.enter()
            _ = provider.loadObject(ofClass: URL.self) { url, _ in
                defer { group.leave() }
                if let url = url { droppedURLs.append(url) }
            }
        }

        group.notify(queue: .main) { [weak self] in
            guard let self = self, let first = droppedURLs.first else { return }
            var isDir: ObjCBool = false
            let fm = FileManager.default
            if fm.fileExists(atPath: first.path, isDirectory: &isDir) {
                if isDir.boolValue {
                    self.detectEnvironment(customRyujinxDir: first.path)
                    if self.isProdKeysValid {
                        SoundEffectService.shared.play(.launch)
                    } else {
                        SoundEffectService.shared.play(.error)
                    }
                } else if first.lastPathComponent.lowercased().contains("keys") {
                    self.prodKeysPath = first.path
                    self.prodKeysSource = "Dropped prod.keys"
                    self.isProdKeysValid = true
                    SoundEffectService.shared.play(.launch)
                }
            }
        }
        return true
    }

    // MARK: - Onboarding Keyboard & Gamepad Navigation

    public func handleOnboardingGamepadAction(_ action: GamepadAction) {
        switch onboardingStep {
        case .language:
            let count = Self.onboardingLanguages.count
            guard count > 0 else { return }
            switch action {
            case .navigateRight:
                onboardingLanguageFocusIndex = (onboardingLanguageFocusIndex + 1) % count
                SoundEffectService.shared.play(.focus)
            case .navigateLeft:
                onboardingLanguageFocusIndex = (onboardingLanguageFocusIndex - 1 + count) % count
                SoundEffectService.shared.play(.focus)
            case .navigateDown:
                onboardingLanguageFocusIndex = min(count - 1, onboardingLanguageFocusIndex + 3)
                SoundEffectService.shared.play(.focus)
            case .navigateUp:
                onboardingLanguageFocusIndex = max(0, onboardingLanguageFocusIndex - 3)
                SoundEffectService.shared.play(.focus)
            case .confirm:
                let focusedLang = Self.onboardingLanguages[onboardingLanguageFocusIndex]
                if launcherLanguage != focusedLang {
                    selectOnboardingLanguage(focusedLang)
                } else {
                    advanceOnboardingStep()
                }
            case .options, .menu:
                let focusedLang = Self.onboardingLanguages[onboardingLanguageFocusIndex]
                if launcherLanguage != focusedLang {
                    selectOnboardingLanguage(focusedLang)
                }
                advanceOnboardingStep()
            default:
                break
            }
        case .targetPlatforms:
            switch action {
            case .confirm:
                advanceOnboardingStep()
            case .cancel:
                goBackOnboardingStep()
            default:
                break
            }
        case .dependenciesOverview:
            switch action {
            case .confirm:
                advanceOnboardingStep()
            case .cancel:
                goBackOnboardingStep()
            default:
                break
            }
        case .installingDependencies:
            if onboardingInstallError != nil {
                switch action {
                case .confirm:
                    startOnboardingInstallation()
                case .cancel:
                    skipFailedOnboardingInstallToKeys()
                default:
                    break
                }
            }
        case .prodKeys:
            switch action {
            case .confirm:
                if isProdKeysValid {
                    completeOnboarding()
                } else {
                    SoundEffectService.shared.play(.click)
                    selectProdKeysFile()
                }
            case .cancel, .secondaryAction:
                completeOnboarding()
            default:
                break
            }
        }
    }

    public func handleOnboardingKeyboardKey(_ key: String) {
        switch key {
        case "left": handleOnboardingGamepadAction(.navigateLeft)
        case "right": handleOnboardingGamepadAction(.navigateRight)
        case "up": handleOnboardingGamepadAction(.navigateUp)
        case "down": handleOnboardingGamepadAction(.navigateDown)
        case "return":
            if onboardingStep == .language {
                let focusedLang = Self.onboardingLanguages[min(max(0, onboardingLanguageFocusIndex), Self.onboardingLanguages.count - 1)]
                selectOnboardingLanguage(focusedLang)
                advanceOnboardingStep()
            } else {
                handleOnboardingGamepadAction(.confirm)
            }
        case "space":
            if onboardingStep == .language {
                let focusedLang = Self.onboardingLanguages[min(max(0, onboardingLanguageFocusIndex), Self.onboardingLanguages.count - 1)]
                selectOnboardingLanguage(focusedLang)
            } else {
                handleOnboardingGamepadAction(.confirm)
            }
        case "escape":
            handleOnboardingGamepadAction(.cancel)
        default:
            break
        }
    }
}
