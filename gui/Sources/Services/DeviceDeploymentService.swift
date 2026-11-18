import Foundation
import AppKit

public struct ConnectedAppleDevice: Identifiable, Equatable, Hashable {
    public let id: String
    public let name: String
    public let model: String
    public let osVersion: String
    public let isPaired: Bool
    public let isAvailable: Bool

    public init(id: String, name: String, model: String, osVersion: String, isPaired: Bool, isAvailable: Bool = true) {
        self.id = id
        self.name = name
        self.model = model
        self.osVersion = osVersion
        self.isPaired = isPaired
        self.isAvailable = isAvailable
    }
}

public struct DeveloperSigningTeam: Identifiable, Equatable, Hashable {
    public let id: String
    public let name: String
    public let teamType: String?
    public let isFreeProvisioningTeam: Bool
    public let hasCertificateInKeychain: Bool
    public let signingIdentity: String?

    public init(
        id: String,
        name: String,
        teamType: String? = nil,
        isFreeProvisioningTeam: Bool = false,
        hasCertificateInKeychain: Bool = false,
        signingIdentity: String? = nil
    ) {
        self.id = id
        self.name = name
        self.teamType = teamType
        self.isFreeProvisioningTeam = isFreeProvisioningTeam
        self.hasCertificateInKeychain = hasCertificateInKeychain
        self.signingIdentity = signingIdentity
    }

    public var displayName: String {
        if let type = teamType, !type.isEmpty {
            return "\(name) (\(type)) · \(id)"
        }
        return "\(name) · \(id)"
    }
}

public enum DeploymentErrorCategory: Equatable {
    case signatureVerificationFailed
    case deviceLocked
    case developerModeDisabled
    case insufficientStorage
    case deviceDisconnected
    case invalidIPA
    case generic(String)
}

public struct DeploymentProgressInfo: Equatable {
    public enum Phase: String {
        case idle = "Idle"
        case compiling = "Compiling Game Framework"
        case extracting = "Extracting Package (.ipa)"
        case signing = "Preparing Signature"
        case connecting = "Connecting to Device"
        case transferring = "Transferring to Device"
        case installing = "Installing on iOS"
        case copyingRomFS = "Transferring Game Data (romfs.img)"
        case completed = "Installation Completed"
        case failed = "Installation Failed"
        case cancelled = "Deployment Cancelled"
    }

    public var phase: Phase = .idle
    public var progressFraction: Double = 0.0 // 0.0 ... 1.0
    public var statusMessage: String = ""
    public var detailMessage: String = ""
    public var logLines: [String] = []
    public var isRunning: Bool = false
    public var targetDeviceName: String = ""
    public var elapsedSeconds: Int = 0
    public var errorCategory: DeploymentErrorCategory? = nil
    public var rawError: String? = nil
}

public final class DeviceDeploymentService: ObservableObject {
    public static let shared = DeviceDeploymentService()

    @Published public var connectedDevices: [ConnectedAppleDevice] = []
    @Published public var signingTeams: [DeveloperSigningTeam] = []
    @Published public var selectedDevice: ConnectedAppleDevice? = nil
    @Published public var selectedSigningTeam: DeveloperSigningTeam? = nil
    @Published public var isDetecting: Bool = false
    @Published public var deploymentStatus: String? = nil
    @Published public var activeDeployment: DeploymentProgressInfo = DeploymentProgressInfo()
    @Published public var currentDeployingGame: PortedGame? = nil

    internal var currentRunningProcess: Process? = nil
    internal var currentDeployingAppURL: URL? = nil
    internal var completionCallback: ((Bool, String) -> Void)? = nil
    internal var elapsedTimer: Timer? = nil

    private init() {
        // Do not eagerly run xcrun/security/defaults subprocesses on launch.
        // Discovery is triggered when opening the iOS deployment view or explicit refresh.
    }

    public func refreshDevicesAndTeams() {
        guard !isDetecting else { return }
        isDetecting = true

        discoverConnectedDevicesAsync { _, _ in }
    }

    /// Runs bounded device + signing team discovery on a background queue, updating published device state immediately
    /// when `devicectl` finishes and invoking `completion` on `DispatchQueue.main`.
    public func discoverConnectedDevicesAsync(
        completion: @escaping ([ConnectedAppleDevice], [DeveloperSigningTeam]) -> Void
    ) {
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            guard let self = self else {
                DispatchQueue.main.async { completion([], []) }
                return
            }

            let devices = self.fetchConnectedDevices()
            DispatchQueue.main.async {
                self.connectedDevices = devices
                if self.selectedDevice == nil || !devices.contains(where: { $0.id == self.selectedDevice?.id }) {
                    self.selectedDevice = devices.first
                }
            }

            let teams = self.fetchSigningIdentities()
            DispatchQueue.main.async {
                self.signingTeams = teams
                if self.selectedSigningTeam == nil || !teams.contains(where: { $0.id == self.selectedSigningTeam?.id }) {
                    self.selectedSigningTeam = teams.first
                }
                self.isDetecting = false
                completion(devices, teams)
            }
        }
    }

    public func openXcodeAccounts() {
        let script = "tell application \"Xcode\" to activate"
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/usr/bin/osascript")
        p.arguments = ["-e", script]
        try? p.run()
    }

    public func dismissDeploymentStatus() {
        if !activeDeployment.isRunning {
            activeDeployment = DeploymentProgressInfo()
        }
    }

    public func cancelDeployment() {
        guard activeDeployment.isRunning else { return }
        stopElapsedTimer()
        currentRunningProcess?.terminate()
        currentRunningProcess = nil
        currentDeployingGame = nil

        activeDeployment.isRunning = false
        activeDeployment.phase = .cancelled
        activeDeployment.statusMessage = "Deployment cancelled by user."
        activeDeployment.detailMessage = "The installation process was safely terminated."

        let cb = completionCallback
        completionCallback = nil
        cb?(false, "Cancelled by user.")
    }

    public func installApp(
        appBundleURL: URL,
        on device: ConnectedAppleDevice,
        team: DeveloperSigningTeam? = nil,
        game: PortedGame? = nil,
        isHubBootstrap: Bool = false,
        completion: @escaping (Bool, String) -> Void
    ) {
        // Prevent concurrent deployments unless this is an internal bootstrap step of the Hub
        if activeDeployment.isRunning && !isHubBootstrap {
            completion(false, "Another deployment is already in progress.")
            return
        }

        // Fast pre-flight check: ensure device is not locked or unavailable
        if !device.isAvailable {
            failDeployment(
                category: .deviceLocked,
                title: "\(device.name) está Indisponível ou Bloqueado",
                detail: "O dispositivo está bloqueado ou a sessão USB precisa ser renovada.\n1. Desbloqueie o iPhone com seu código de acesso.\n2. Se solicitado, toque em 'Confiar neste Computador'.\n3. Verifique se o Modo de Desenvolvedor está ativo em Ajustes > Privacidade e Segurança."
            )
            completion(false, "Device is locked or unavailable.")
            return
        }

        self.completionCallback = completion
        self.currentDeployingAppURL = appBundleURL
        self.currentDeployingGame = game

        if !isHubBootstrap {
            // Initialize active deployment state
            activeDeployment = DeploymentProgressInfo(
                phase: .extracting,
                progressFraction: 0.05,
                statusMessage: "Starting installation on \(device.name)...",
                detailMessage: "Preparing game package for transfer...",
                logLines: ["==> Starting deployment of \(appBundleURL.lastPathComponent) on \(device.name)..."],
                isRunning: true,
                targetDeviceName: device.name,
                elapsedSeconds: 0,
                errorCategory: nil,
                rawError: nil
            )

            startElapsedTimer()
        } else {
            activeDeployment.logLines.append("==> Bootstrapping base container from \(appBundleURL.lastPathComponent)...")
        }

        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            guard let self = self else { return }
            var targetAppURL = appBundleURL
            var stagedRomfsURL: URL? = nil

            // 1. If given an .ipa archive, validate integrity and extract Payload/*.app with cache support
            if appBundleURL.pathExtension.lowercased() == "ipa" {
                if !isHubBootstrap {
                    let health = IpaHealthService.shared.inspectSync(ipaURL: appBundleURL, titleIdHint: game?.titleId)
                    if health.isUnusableArchive {
                        DispatchQueue.main.async {
                            self.failDeployment(
                                category: .invalidIPA,
                                title: "Pacote .ipa Corrompido ou Incompleto",
                                detail: health.detailedExplanation
                            )
                        }
                        return
                    }
                    if health.hasIpaDefect {
                        DispatchQueue.main.async {
                            self.activeDeployment.logLines.append("[WARN] Aviso no .ipa: \(health.detailedExplanation.replacingOccurrences(of: "\n", with: " "))")
                        }
                    }
                }

                let (appURL, romfsURL, extractError) = self.prepareExtractedApp(from: appBundleURL)
                guard let extractedURL = appURL else {
                    DispatchQueue.main.async {
                        self.failDeployment(
                            category: .invalidIPA,
                            title: "Invalid .ipa Archive",
                            detail: extractError ?? "Could not extract Payload/*.app from .ipa file."
                        )
                    }
                    return
                }
                targetAppURL = extractedURL
                stagedRomfsURL = romfsURL
            }

            // Also check if RomFS was built separately next to the IPA or game bundle (game-specific stem/TitleID first!)
            if stagedRomfsURL == nil,
               let match = self.resolveExternalRomfsCandidate(near: appBundleURL, appBundle: targetAppURL) {
                stagedRomfsURL = match
                DispatchQueue.main.async {
                    self.activeDeployment.logLines.append("[OK] Detected external RomFS image: \(match.lastPathComponent)")
                }
            }

            guard self.activeDeployment.isRunning else { return }

            // 2. Prepare code signature & automated provisioning
            if isHubBootstrap && NxHubDeploymentService.shared.deploymentMode == .consoleHub {
                NxHubDeploymentService.shared.injectHubMetadataAndDarkIcon(targetAppURL: targetAppURL)
            }

            DispatchQueue.main.async {
                self.activeDeployment.phase = .signing
                self.activeDeployment.progressFraction = 0.35
                self.activeDeployment.statusMessage = "Verifying app signature & provisioning..."
                self.activeDeployment.detailMessage = "Ensuring bundle integrity and Apple Developer profile..."
            }

            let (signOK, signError) = self.applyCodeSignatureAndProvisioning(targetAppURL: targetAppURL, device: device, team: team)
            guard signOK else {
                DispatchQueue.main.async {
                    self.failDeployment(
                        category: .signatureVerificationFailed,
                        title: "iOS Code Signing Failed",
                        detail: signError ?? "Could not obtain a valid provisioning profile or signing identity."
                    )
                }
                return
            }

            guard self.activeDeployment.isRunning else { return }

            // 3. Execute xcrun devicectl device install app asynchronously with live line streaming
            DispatchQueue.main.async {
                self.activeDeployment.phase = .transferring
                self.activeDeployment.progressFraction = 0.45
                self.activeDeployment.statusMessage = "Transferring to \(device.name)..."
                self.activeDeployment.detailMessage = "Connecting to device and transferring game files..."
            }

            self.executeDeviceCtlInstall(targetAppURL: targetAppURL, device: device, stagedRomfsURL: stagedRomfsURL)
        }
    }

    private func resolveExternalRomfsCandidate(near sourceURL: URL, appBundle: URL? = nil) -> URL? {
        let fm = FileManager.default
        let parentDir = sourceURL.deletingLastPathComponent()
        let stem = sourceURL.deletingPathExtension().lastPathComponent

        let expectedIdentity: RomfsExpectedIdentity? = {
            if let bundle = appBundle, let id = RomfsIdentityVerifier.readIdentity(fromAppBundle: bundle) {
                return id
            }
            if sourceURL.pathExtension.lowercased() == "ipa",
               let id = RomfsIdentityVerifier.readIdentity(fromIpa: sourceURL) {
                return id
            }
            return nil
        }()

        var candidates: [URL] = []
        for s in RomfsIdentityVerifier.filenameVariants(of: stem) {
            candidates.append(parentDir.appendingPathComponent("\(s).romfs.img"))
            candidates.append(parentDir.appendingPathComponent("\(s).RomFS.img"))
        }

        var titleId: String? = expectedIdentity?.titleId
        if titleId == nil,
           let bundle = appBundle,
           let bid = extractBundleIdentifier(from: bundle),
           let range = bid.range(of: "(?:0100|0400)[0-9A-Fa-f]{12}", options: .regularExpression) {
            titleId = String(bid[range]).uppercased()
        }
        if let tid = titleId {
            candidates.append(parentDir.appendingPathComponent("\(tid).romfs.img"))
            candidates.append(parentDir.appendingPathComponent("\(tid.lowercased()).romfs.img"))
            candidates.append(parentDir.appendingPathComponent("\(tid).RomFS.img"))
        }

        candidates.append(parentDir.appendingPathComponent("RomFS.img"))
        candidates.append(parentDir.appendingPathComponent("romfs.img"))

        for c in candidates {
            guard fm.fileExists(atPath: c.path) else { continue }
            let resolved = c.resolvingSymlinksInPath()
            if RomfsIdentityVerifier.verifyLocalImage(at: resolved, expected: expectedIdentity).valid {
                return resolved
            }
        }

        if let game = currentDeployingGame ?? AppViewModel.shared?.libraryGames.first(where: { $0.url.standardizedFileURL == sourceURL.standardizedFileURL }),
           let hubMatched = NxHubDeploymentService.shared.locateRomfsImage(for: game, expectedIdentity: expectedIdentity) {
            return hubMatched
        }
        return nil
    }

    // MARK: - App Extraction with Fast Cache
    private func prepareExtractedApp(from ipaURL: URL) -> (URL?, URL?, String?) {
        let fm = FileManager.default
        let values = try? ipaURL.resourceValues(forKeys: [.fileSizeKey, .contentModificationDateKey])
        let size = values?.fileSize ?? 0
        let mtime = Int(values?.contentModificationDate?.timeIntervalSince1970 ?? 0)

        let rawStem = ipaURL.deletingPathExtension().lastPathComponent
        let safeName = rawStem.replacingOccurrences(of: " ", with: "_")
        let deployCacheRoot = SystemDetector.shared.cachesDirectory.appendingPathComponent("deploy_cache")
        let currentFolderName = "\(safeName)_\(size)_\(mtime)"
        let cacheDir = deployCacheRoot.appendingPathComponent(currentFolderName)

        // Prune older deploy_cache folders for the same game stem so stale v1.0.0 romfs.img images never shadow updates.
        if let existingCaches = try? fm.contentsOfDirectory(at: deployCacheRoot, includingPropertiesForKeys: nil) {
            let stalePrefixes = RomfsIdentityVerifier.filenameVariants(of: rawStem)
                .map { $0.replacingOccurrences(of: " ", with: "_") + "_" }
            for entry in existingCaches where entry.lastPathComponent != currentFolderName {
                let entryName = entry.lastPathComponent
                let entryForms = [entryName, entryName.precomposedStringWithCanonicalMapping, entryName.decomposedStringWithCanonicalMapping]
                if stalePrefixes.contains(where: { pref in entryForms.contains(where: { $0.hasPrefix(pref) }) }) {
                    try? fm.removeItem(at: entry)
                }
            }
        }

        let payloadDir = cacheDir.appendingPathComponent("Payload")
        let stagedRomfs = cacheDir.appendingPathComponent("romfs.img")

        let stageEmbeddedRomfs: (URL) -> URL? = { appURL in
            let expectedId = RomfsIdentityVerifier.readIdentity(fromAppBundle: appURL)
            let embedded = appURL.appendingPathComponent("romfs.img")
            if fm.fileExists(atPath: embedded.path) {
                if !fm.fileExists(atPath: stagedRomfs.path) {
                    try? fm.moveItem(at: embedded, to: stagedRomfs)
                } else {
                    try? fm.removeItem(at: embedded)
                }
            }
            if fm.fileExists(atPath: stagedRomfs.path) {
                if RomfsIdentityVerifier.verifyLocalImage(at: stagedRomfs, expected: expectedId).valid {
                    return stagedRomfs
                }
                // Stale or mismatched cached image — discard it and search canonical sources instead.
                try? fm.removeItem(at: stagedRomfs)
            }
            return self.resolveExternalRomfsCandidate(near: ipaURL, appBundle: appURL)
        }

        // Check if cache already contains a valid extracted .app
        if fm.fileExists(atPath: payloadDir.path),
           let items = try? fm.contentsOfDirectory(atPath: payloadDir.path),
           let existingApp = items.first(where: { $0.hasSuffix(".app") }) {
            let appURL = payloadDir.appendingPathComponent(existingApp)
            let plistURL = appURL.appendingPathComponent("Info.plist")
            if fm.fileExists(atPath: plistURL.path) {
                let romfsURL = stageEmbeddedRomfs(appURL)
                DispatchQueue.main.async {
                    self.activeDeployment.logLines.append("[OK] Extracted app bundle found in local cache.")
                    self.activeDeployment.progressFraction = 0.30
                }
                return (appURL, romfsURL, nil)
            }
        }

        // Needs extraction
        try? fm.createDirectory(at: cacheDir, withIntermediateDirectories: true)

        DispatchQueue.main.async {
            self.activeDeployment.logLines.append("==> Extracting \(ipaURL.lastPathComponent) (\(self.formatByteSize(Int64(size))))...")
            self.activeDeployment.statusMessage = "Extracting .ipa package (\(self.formatByteSize(Int64(size))))..."
            self.activeDeployment.detailMessage = "Please wait while game assets are unpacked..."
            self.activeDeployment.progressFraction = 0.15
        }

        let extractTimeout = max(60.0, (Double(size) / (25.0 * 1024.0 * 1024.0)) + 30.0)
        let expectedBytes = max(Int64(1), Int64(size))

        func directoryAllocatedSize(_ url: URL) -> Int64 {
            guard let enumerator = fm.enumerator(
                at: url,
                includingPropertiesForKeys: [.fileSizeKey, .isRegularFileKey],
                options: [.skipsHiddenFiles]
            ) else { return 0 }
            var total: Int64 = 0
            for case let fileURL as URL in enumerator {
                let vals = try? fileURL.resourceValues(forKeys: [.fileSizeKey, .isRegularFileKey])
                if vals?.isRegularFile == true {
                    total += Int64(vals?.fileSize ?? 0)
                }
            }
            return total
        }

        @discardableResult
        func runBoundedExtract(executable: String, arguments: [String]) -> Int32 {
            let proc = Process()
            proc.executableURL = URL(fileURLWithPath: executable)
            proc.arguments = arguments
            proc.standardOutput = Pipe()
            proc.standardError = Pipe()

            let startTime = Date()
            let progressTimer = DispatchSource.makeTimerSource(queue: DispatchQueue.global(qos: .utility))
            progressTimer.schedule(deadline: .now() + 0.4, repeating: 0.4)
            progressTimer.setEventHandler { [weak self, weak proc] in
                guard let proc = proc, proc.isRunning else { return }
                let elapsed = Date().timeIntervalSince(startTime)
                if elapsed >= extractTimeout {
                    proc.terminate()
                    return
                }
                if let s = self {
                    if !s.activeDeployment.isRunning {
                        proc.terminate()
                        return
                    }
                    let extracted = directoryAllocatedSize(cacheDir)
                    let ratio = min(0.96, max(0.05, Double(extracted) / Double(expectedBytes)))
                    let mapped = 0.15 + ratio * 0.13
                    DispatchQueue.main.async {
                        if s.activeDeployment.isRunning {
                            s.activeDeployment.progressFraction = max(s.activeDeployment.progressFraction, mapped)
                            s.activeDeployment.detailMessage = "Unpacked \(s.formatByteSize(extracted)) of \(s.formatByteSize(expectedBytes))..."
                        }
                    }
                }
            }

            do {
                try proc.run()
                progressTimer.resume()
                proc.waitUntilExit()
                progressTimer.cancel()
                return proc.terminationStatus
            } catch {
                progressTimer.cancel()
                return -1
            }
        }

        var status = runBoundedExtract(executable: "/usr/bin/ditto", arguments: ["-x", "-k", ipaURL.path, cacheDir.path])
        if status != 0 && self.activeDeployment.isRunning {
            try? fm.removeItem(at: cacheDir)
            try? fm.createDirectory(at: cacheDir, withIntermediateDirectories: true)
            status = runBoundedExtract(executable: "/usr/bin/unzip", arguments: ["-q", "-o", ipaURL.path, "-d", cacheDir.path])
        }

        guard status == 0,
              let items = try? fm.contentsOfDirectory(atPath: payloadDir.path),
              let appFolder = items.first(where: { $0.hasSuffix(".app") }) else {
            try? fm.removeItem(at: cacheDir)
            return (nil, nil, "The .ipa archive could not be extracted or does not contain a valid Payload/*.app directory.")
        }

        let appURL = payloadDir.appendingPathComponent(appFolder)
        let romfsURL = stageEmbeddedRomfs(appURL)

        DispatchQueue.main.async {
            self.activeDeployment.logLines.append("[OK] Package extracted successfully: \(appFolder)")
            if romfsURL != nil {
                self.activeDeployment.logLines.append("[OK] Game data (romfs.img) staged for direct Documents transfer.")
            }
            self.activeDeployment.progressFraction = 0.30
        }
        return (appURL, romfsURL, nil)
    }

    // MARK: - Code Signing Backward-Compatibility Forwarder
    private func applyCodeSignatureIfNeeded(targetAppURL: URL, team: DeveloperSigningTeam?) {
        if let firstDevice = connectedDevices.first {
            applyCodeSignatureAndProvisioning(targetAppURL: targetAppURL, device: firstDevice, team: team)
        } else {
            let fallbackDev = ConnectedAppleDevice(id: "generic", name: "iOS Device", model: "iPhone", osVersion: "iOS", isPaired: true)
            applyCodeSignatureAndProvisioning(targetAppURL: targetAppURL, device: fallbackDev, team: team)
        }
    }
    
    // MARK: - Custom Certificate & Profile Import
    public func importP12Certificate(fileURL: URL, password: String, completion: @escaping (Bool, String) -> Void) {
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            let proc = Process()
            let pipe = Pipe()
            proc.executableURL = URL(fileURLWithPath: "/usr/bin/security")
            let home = FileManager.default.homeDirectoryForCurrentUser.path
            let keychainPath = "\(home)/Library/Keychains/login.keychain-db"
            proc.arguments = ["import", fileURL.path, "-k", keychainPath, "-P", password, "-T", "/usr/bin/codesign"]
            proc.standardOutput = pipe
            proc.standardError = pipe
            
            do {
                try proc.run()
                proc.waitUntilExit()
                let data = pipe.fileHandleForReading.readDataToEndOfFile()
                let output = String(decoding: data, as: UTF8.self)
                
                if proc.terminationStatus == 0 {
                    DispatchQueue.main.async {
                        self?.refreshDevicesAndTeams()
                        completion(true, "Certificate imported successfully into macOS Keychain.")
                    }
                } else {
                    DispatchQueue.main.async {
                        completion(false, output.isEmpty ? "Failed to import .p12 certificate (check password)." : output)
                    }
                }
            } catch {
                DispatchQueue.main.async {
                    completion(false, error.localizedDescription)
                }
            }
        }
    }
    
    // MARK: - Direct iOS Config Sync (Documents/env.txt & NxN Launcher)

    internal func pushSingleFileToIosContainer(
        localURL: URL,
        bundleId: String,
        destinationSubpath: String,
        device: ConnectedAppleDevice
    ) -> Bool {
        let fm = FileManager.default
        let resolvedSource = localURL.resolvingSymlinksInPath()
        guard fm.fileExists(atPath: resolvedSource.path) else { return false }
        let expectedSize = (try? fm.attributesOfItem(atPath: resolvedSource.path)[.size] as? Int64) ?? 0
        guard expectedSize > 0 else { return false }

        if let afc = AppleAfcTransferService.resolveAfcClientTool(),
           let udid = AppleAfcTransferService.resolveHardwareUDID(for: device) {
            if AppleAfcTransferService.transferFileViaAfcClient(
                afcPath: afc,
                udid: udid,
                domainId: bundleId,
                resolvedSourceURL: resolvedSource,
                destinationSubpath: destinationSubpath,
                expectedSize: expectedSize,
                device: device
            ) {
                return true
            }
        }

        let res = BoundedProcess.run(
            "/usr/bin/xcrun",
            [
                "devicectl", "device", "copy", "to",
                "--device", device.id,
                "--domain-type", "appDataContainer",
                "--domain-identifier", bundleId,
                "--source", resolvedSource.path,
                "--destination", destinationSubpath
            ],
            timeout: 8.0
        )
        return res.success
    }

    /// Pushes per-game runtime configuration (`env.txt`, presets, OoT FPS/FrameGen/MetalFX, language)
    /// directly to an installed iOS game container (Standalone `.ipa` and/or `NxN Launcher`) without re-porting.
    public func syncConfigToIosDevice(
        game: PortedGame,
        config: GameRuntimeConfig,
        device: ConnectedAppleDevice,
        completion: @escaping (Bool, String) -> Void
    ) {
        guard device.isAvailable else {
            DispatchQueue.main.async {
                completion(false, "Selected iOS device is not currently available.")
            }
            return
        }

        let syncToken = String(Int64(Date().timeIntervalSince1970 * 1000))
        let envText = config.iosEnvFileContent(for: game, syncToken: syncToken)
        let titleId = (game.titleId ?? CompatibilityService.shared.findTitleId(forGameTitle: game.name) ?? "").uppercased()
        let deployableURL = resolveDeployableURL(for: game)
        let extractedBid = extractBundleIdentifier(from: deployableURL)

        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            guard let self = self else {
                DispatchQueue.main.async {
                    completion(false, "Deployment service unavailable.")
                }
                return
            }

            let tempEnvURL = FileManager.default.temporaryDirectory
                .appendingPathComponent("nxnative_env_\(UUID().uuidString).txt")
            do {
                try envText.write(to: tempEnvURL, atomically: true, encoding: .utf8)
            } catch {
                DispatchQueue.main.async {
                    completion(false, "Could not stage temporary env.txt: \(error.localizedDescription)")
                }
                return
            }
            defer { try? FileManager.default.removeItem(at: tempEnvURL) }

            let apps = self.fetchInstalledAppsList(on: device)
            let hubService = NxHubDeploymentService.shared
            var targets: [(bundleId: String, dest: String, label: String)] = []

            if !titleId.isEmpty {
                if let installedHubId = hubService.matchHubBundleId(in: apps) {
                    DispatchQueue.main.async { hubService.detectedHubBundleId = installedHubId }
                    targets.append((installedHubId, "Documents/games/\(titleId)/env.txt", "NxN Launcher"))
                } else if apps.isEmpty && hubService.deploymentMode == .consoleHub {
                    let fallbackHub = hubService.resolveHubBundleId(for: game, on: device)
                    targets.append((fallbackHub, "Documents/games/\(titleId)/env.txt", "NxN Launcher"))
                }
            }

            let tidLower = titleId.lowercased()
            let normGame = String(game.name.lowercased().unicodeScalars.filter { CharacterSet.alphanumerics.contains($0) })
            let matchedHubBids = Set(targets.map { $0.bundleId.lowercased() })
            var standaloneBid: String? = nil

            for app in apps {
                guard let bid = app["bundleIdentifier"] as? String else { continue }
                let bidLower = bid.lowercased()
                if matchedHubBids.contains(bidLower) { continue }
                if let ex = extractedBid, bidLower == ex.lowercased() {
                    standaloneBid = bid
                    break
                }
                if !tidLower.isEmpty && bidLower.contains(tidLower) {
                    standaloneBid = bid
                    break
                }
                if let name = app["name"] as? String {
                    let normApp = String(name.lowercased().unicodeScalars.filter { CharacterSet.alphanumerics.contains($0) })
                    if !normGame.isEmpty && !normApp.isEmpty && (normApp == normGame || normApp.contains(normGame) || normGame.contains(normApp)) {
                        standaloneBid = bid
                        break
                    }
                }
            }
            if standaloneBid == nil && (apps.isEmpty || hubService.deploymentMode == .standalone) {
                if let ex = extractedBid, !matchedHubBids.contains(ex.lowercased()) {
                    standaloneBid = ex
                }
            }

            if let sBid = standaloneBid, !sBid.isEmpty {
                targets.append((sBid, "Documents/env.txt", "Standalone App"))
            }

            guard !targets.isEmpty else {
                DispatchQueue.main.async {
                    completion(false, "Game or NxN Launcher app not found installed on \(device.name).")
                }
                return
            }

            var syncedLabels: [String] = []
            for t in targets {
                if self.pushSingleFileToIosContainer(
                    localURL: tempEnvURL,
                    bundleId: t.bundleId,
                    destinationSubpath: t.dest,
                    device: device
                ) {
                    syncedLabels.append(t.label)
                }
            }

            DispatchQueue.main.async {
                if syncedLabels.isEmpty {
                    completion(false, "Failed to transfer env.txt to \(device.name). Unlock device and retry.")
                } else {
                    completion(true, "Synced config to \(device.name) (\(syncedLabels.joined(separator: " + "))).")
                }
            }
        }
    }

    // MARK: - Direct RomFS Push (without full app reinstall)
    public func pushRomfsDirectly(
        gameURL: URL,
        device: ConnectedAppleDevice,
        completion: @escaping (Bool, String) -> Void
    ) {
        let fm = FileManager.default
        let parentDir = gameURL.deletingLastPathComponent()
        var romfsURL: URL? = nil
        let candidates = [
            parentDir.appendingPathComponent("RomFS.img"),
            parentDir.appendingPathComponent("romfs.img"),
            gameURL.appendingPathComponent("romfs.img"),
            gameURL.appendingPathComponent("RomFS.img")
        ]
        for c in candidates where fm.fileExists(atPath: c.path) {
            romfsURL = c
            break
        }
        
        guard let targetRomfs = romfsURL else {
            completion(false, "RomFS.img not found next to the game files.")
            return
        }
        
        let bundleId = extractBundleIdentifier(from: gameURL) ?? "org.nxnative"
        executeRomfsCopy(romfsURL: targetRomfs, bundleId: bundleId, device: device)
        completion(true, "RomFS transfer initiated.")
    }

    // MARK: - iOS App Verification & URL Resolution

    /// Determines whether a URL is a valid iOS application package (.ipa or .app with iPhoneOS support).
    public func isIosAppBundle(_ url: URL) -> Bool {
        if url.pathExtension.lowercased() == "ipa" { return true }
        if url.pathExtension.lowercased() != "app" { return false }
        let rootPlist = url.appendingPathComponent("Info.plist")
        let contentsPlist = url.appendingPathComponent("Contents/Info.plist")
        let plistToRead = FileManager.default.fileExists(atPath: rootPlist.path) ? rootPlist : contentsPlist

        guard let data = try? Data(contentsOf: plistToRead),
              let dict = try? PropertyListSerialization.propertyList(from: data, options: [], format: nil) as? [String: Any] else {
            return false
        }
        if let platforms = dict["CFBundleSupportedPlatforms"] as? [String], platforms.contains("iPhoneOS") {
            return true
        }
        if let platformName = dict["DTPlatformName"] as? String, platformName.lowercased().contains("iphone") {
            return true
        }
        return false
    }

    /// Resolves the concrete deployable iOS package (.ipa or iOS .app) for a given PortedGame.
    public func resolveDeployableURL(for game: PortedGame) -> URL {
        if game.url.pathExtension.lowercased() == "ipa" || isIosAppBundle(game.url) {
            return game.url
        }

        let parentDir = game.url.deletingLastPathComponent()

        // 1. Same base name with .ipa
        let baseName = game.url.deletingPathExtension().lastPathComponent
        let sameNameIpa = parentDir.appendingPathComponent("\(baseName).ipa")
        if FileManager.default.fileExists(atPath: sameNameIpa.path) {
            return sameNameIpa
        }

        // 2. Game display name with .ipa
        let displayNameIpa = parentDir.appendingPathComponent("\(game.name).ipa")
        if FileManager.default.fileExists(atPath: displayNameIpa.path) {
            return displayNameIpa
        }

        // 3. Scan directory for any .ipa containing Title ID
        if let tid = game.titleId?.uppercased(), !tid.isEmpty {
            if let items = try? FileManager.default.contentsOfDirectory(at: parentDir, includingPropertiesForKeys: nil) {
                for item in items where item.pathExtension.lowercased() == "ipa" {
                    if item.lastPathComponent.uppercased().contains(tid) {
                        return item
                    }
                }
            }

            // 4. Match in AppViewModel libraryGames
            if let match = AppViewModel.shared?.libraryGames.first(where: {
                $0.url.pathExtension.lowercased() == "ipa" && $0.titleId?.uppercased() == tid
            }) {
                return match.url
            }
        }

        return game.url
    }
}
