import Foundation
import AppKit

// MARK: - NxN Launcher Deployment Service

/// Manages high-speed deployment to the unified NxN Launcher container on iOS/iPadOS.
public final class NxHubDeploymentService: ObservableObject {
    public static let shared = NxHubDeploymentService()

    @Published public var deploymentMode: NxDeploymentTargetMode = .consoleHub
    @Published public var isHotDropping: Bool = false
    @Published public var hotDropProgress: Double = 0.0
    @Published public var currentActionMessage: String = ""
    @Published public var useExternalStorage: Bool = false
    @Published public var detectedHubBundleId: String? = nil

    public static var hubBundleId: String {
        let userName = NSUserName().lowercased().filter { $0.isLetter || $0.isNumber }
        let userPrefix = userName.isEmpty ? "developer" : userName
        return "com.\(userPrefix).nxnative.hub"
    }

    private init() {
        let savedRaw = UserDefaults.standard.string(forKey: "NXNative_SavedDeploymentMode")
        if let raw = savedRaw, let mode = NxDeploymentTargetMode(rawValue: raw) {
            self.deploymentMode = mode
        } else {
            self.deploymentMode = .consoleHub
        }
    }

    public func setDeploymentMode(_ mode: NxDeploymentTargetMode) {
        self.deploymentMode = mode
        UserDefaults.standard.set(mode.rawValue, forKey: "NXNative_SavedDeploymentMode")
    }

    /// Matches the installed NxN Launcher (DmShell) bundle identifier from a `devicectl device info apps` result list.
    internal func matchHubBundleId(in apps: [[String: Any]], configuredId: String? = nil) -> String? {
        let targetConfigId = (configuredId ?? loadShellLibrary().bundleID).trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        for app in apps {
            let bid = ((app["bundleIdentifier"] as? String) ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
            let bidLower = bid.lowercased()
            let appName = ((app["name"] as? String) ?? "").trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
            if (!targetConfigId.isEmpty && bidLower == targetConfigId)
                || bidLower == "org.nxnative.launcher"
                || bidLower.hasSuffix(".org.nxnative.launcher")
                || bidLower.contains("org.nxnative.launcher")
                || bidLower.contains("nxnative.hub")
                || bidLower == "org.nxnative.shell"
                || appName == "nxn launcher" {
                return bid
            }
        }
        return nil
    }

    /// Resolves the concrete bundle identifier deployed on the device for this Hub container.
    public func resolveHubBundleId(for game: PortedGame, on device: ConnectedAppleDevice) -> String {
        if let detected = self.detectedHubBundleId, !detected.isEmpty {
            return detected
        }
        let savedState = loadShellLibrary()
        if !savedState.bundleID.isEmpty {
            return savedState.bundleID
        }
        return "org.nxnative.launcher"
    }

    /// Verifies if NxN Launcher is installed on the target iOS device with bounded timeout.
    public func isHubAppInstalled(on device: ConnectedAppleDevice, completion: @escaping (Bool) -> Void) {
        guard device.isAvailable else {
            DispatchQueue.main.async { completion(false) }
            return
        }

        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            let (res, json) = BoundedProcess.runDevicectlJson(
                ["device", "info", "apps", "--device", device.id],
                timeout: 6.0
            )
            guard res.success,
                  let result = json?["result"] as? [String: Any],
                  let apps = result["apps"] as? [[String: Any]] else {
                DispatchQueue.main.async { completion(false) }
                return
            }

            let configuredId = self?.loadShellLibrary().bundleID.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            let matchedId = self?.matchHubBundleId(in: apps, configuredId: configuredId)

            DispatchQueue.main.async {
                if let found = matchedId {
                    self?.detectedHubBundleId = found
                    completion(true)
                } else {
                    completion(false)
                }
            }
        }
    }

    /// Re-polls CoreDevice briefly to recover from transient USB reconnects or lock-screen wakeups.
    internal func resolveAvailableDevice(_ device: ConnectedAppleDevice, waitSeconds: Double = 3.0) -> ConnectedAppleDevice? {
        if device.isAvailable { return device }
        let deadline = Date().addingTimeInterval(waitSeconds)
        while Date() < deadline {
            let devices = DeviceDeploymentService.shared.fetchConnectedDevices()
            if let match = devices.first(where: { $0.id == device.id && $0.isAvailable }) {
                return match
            }
            usleep(400_000)
        }
        return nil
    }

    /// Injects Hub metadata and dark icon when needed.
    public func injectHubMetadataAndDarkIcon(targetAppURL: URL) {
        let infoPlistURL = targetAppURL.appendingPathComponent("Info.plist")
        if var infoDict = try? PropertyListSerialization.propertyList(from: Data(contentsOf: infoPlistURL), options: .mutableContainers, format: nil) as? [String: Any] {
            infoDict["CFBundleDisplayName"] = "NxN Launcher"
            infoDict["CFBundleName"] = "NxN Launcher"
            if let updatedData = try? PropertyListSerialization.data(fromPropertyList: infoDict, format: .xml, options: 0) {
                try? updatedData.write(to: infoPlistURL)
            }
        }
    }

    /// Deploys a game to NxN Launcher. If NxN Launcher is not installed, installs it automatically first.
    public func deployToHub(
        game: PortedGame,
        device: ConnectedAppleDevice,
        team: DeveloperSigningTeam?,
        completion: @escaping (Bool, String) -> Void
    ) {
        guard !isHotDropping else {
            completion(false, "A deployment is already running.")
            return
        }

        self.isHotDropping = true
        self.hotDropProgress = 0.08
        self.currentActionMessage = "Verifying NxN Launcher on \(device.name)..."

        DispatchQueue.main.async {
            DeviceDeploymentService.shared.currentDeployingGame = game
            DeviceDeploymentService.shared.currentDeployingAppURL = game.url
            DeviceDeploymentService.shared.activeDeployment = DeploymentProgressInfo(
                phase: .connecting,
                progressFraction: 0.10,
                statusMessage: "Checking NxN Launcher on \(device.name)...",
                detailMessage: "Verifying container app installation...",
                logLines: [
                    "==> Connecting to \(device.name)...",
                    "==> Checking for NxN Launcher container..."
                ],
                isRunning: true,
                targetDeviceName: device.name,
                elapsedSeconds: 0
            )
            DeviceDeploymentService.shared.startElapsedTimer()
        }

        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            guard let self = self else { return }
            let resolvedDevice = self.resolveAvailableDevice(device, waitSeconds: 3.0)
            guard let activeDevice = resolvedDevice, activeDevice.isAvailable else {
                DispatchQueue.main.async {
                    self.isHotDropping = false
                    DeviceDeploymentService.shared.stopElapsedTimer()
                    DeviceDeploymentService.shared.activeDeployment.isRunning = false
                    DeviceDeploymentService.shared.failDeployment(
                        category: .deviceLocked,
                        title: "\(device.name) está Indisponível ou Bloqueado",
                        detail: "O iPhone precisa estar com a tela acesa e desbloqueada.\n1. Digite a senha na tela do iPhone.\n2. Se solicitado, confirme 'Confiar neste Computador'.\n3. Verifique o cabo USB e tente novamente."
                    )
                    SoundEffectService.shared.play(.error)
                    completion(false, "Device is locked or unavailable.")
                }
                return
            }

            AppleAfcTransferService.invalidateUDIDCache(for: activeDevice.id)
            self.isHubAppInstalled(on: activeDevice) { [weak self] installed in
                guard let self = self else { return }

                let titleId = game.titleId?.uppercased() ?? "0100000000000000"

                func runHotDropWithRecovery(allowRetry: Bool) {
                    self.executeHotDropTransfer(
                        game: game,
                        device: activeDevice,
                        suppressFailureUI: allowRetry
                    ) { ok, msg in
                        if ok {
                            completion(true, msg)
                            return
                        }
                        if allowRetry {
                            DispatchQueue.main.async {
                                DeviceDeploymentService.shared.activeDeployment.detailMessage = "Recuperando conexão USB e retentando \(game.name)..."
                                DeviceDeploymentService.shared.activeDeployment.logLines.append(
                                    "[WARN] Envio falhou (\(msg)); validando container e retentando..."
                                )
                            }
                            DispatchQueue.global(qos: .userInitiated).async {
                                AppleAfcTransferService.invalidateUDIDCache(for: activeDevice.id)
                                let hubBid = self.resolveHubBundleId(for: game, on: activeDevice)
                                usleep(1_500_000)
                                _ = AppleAfcTransferService.waitForContainerReady(bundleId: hubBid, device: activeDevice, timeoutSeconds: 5.0)
                                DispatchQueue.main.async {
                                    runHotDropWithRecovery(allowRetry: false)
                                }
                            }
                            return
                        }
                        completion(false, msg)
                    }
                }

                func ensureGameFrameworkWithRetry(allowRetry: Bool) {
                    self.ensureFramework(for: game, device: activeDevice, team: team, progressRange: 0.10...0.26) { [weak self] fwOk, fwURL, fwErr in
                        guard let self = self else { return }
                        guard fwOk, let fw = fwURL else {
                            if allowRetry {
                                DispatchQueue.main.async {
                                    DeviceDeploymentService.shared.activeDeployment.detailMessage = "Auto-corrigindo framework de \(game.name)..."
                                    DeviceDeploymentService.shared.activeDeployment.logLines.append("[WARN] Falha ao preparar framework (\(fwErr ?? "erro")); limpando cache e retentando...")
                                }
                                self.sanitizeFrameworkArtifacts(at: self.hubFrameworksURL.appendingPathComponent("DmGame\(titleId).framework"))
                                DispatchQueue.main.asyncAfter(deadline: .now() + 0.4) {
                                    ensureGameFrameworkWithRetry(allowRetry: false)
                                }
                                return
                            }
                            self.isHotDropping = false
                            DispatchQueue.main.async {
                                DeviceDeploymentService.shared.stopElapsedTimer()
                                DeviceDeploymentService.shared.activeDeployment.isRunning = false
                                DeviceDeploymentService.shared.failDeployment(
                                    category: .generic(fwErr ?? "Missing Framework"),
                                    title: "Framework do Jogo Não Encontrado",
                                    detail: fwErr ?? "Não foi possível gerar DmGame\(titleId).framework para o NxN Launcher."
                                )
                            }
                            completion(false, fwErr ?? "Framework not found")
                            return
                        }

                        do {
                            try self.registerGameInHub(titleId: titleId, name: game.name, frameworkPath: fw.path)
                        } catch {
                            self.isHotDropping = false
                            DispatchQueue.main.async {
                                DeviceDeploymentService.shared.stopElapsedTimer()
                                DeviceDeploymentService.shared.activeDeployment.isRunning = false
                            }
                            completion(false, "Failed to register game in shell.json: \(error.localizedDescription)")
                            return
                        }

                        let state = self.loadShellLibrary()
                        let knownGames = AppViewModel.shared?.libraryGames ?? []

                        DispatchQueue.main.async {
                            DeviceDeploymentService.shared.activeDeployment.phase = installed ? .signing : .installing
                            DeviceDeploymentService.shared.activeDeployment.progressFraction = max(
                                DeviceDeploymentService.shared.activeDeployment.progressFraction,
                                installed ? 0.28 : 0.24
                            )
                            DeviceDeploymentService.shared.activeDeployment.statusMessage = installed
                                ? "Updating NxN Launcher on \(activeDevice.name)..."
                                : "Installing NxN Launcher on \(activeDevice.name)..."
                            DeviceDeploymentService.shared.activeDeployment.detailMessage = installed
                                ? "Embedding \(game.name) into NxN Launcher..."
                                : "First-time setup: Building & deploying NxN Launcher with official icon..."
                            DeviceDeploymentService.shared.activeDeployment.logLines.append(
                                installed
                                    ? "==> Embedding new game framework into NxN Launcher..."
                                    : "==> NxN Launcher not detected. Preparing & installing container app..."
                            )
                        }

                        self.refreshFrameworksForHub(
                            games: state.games,
                            device: activeDevice,
                            team: team,
                            excludingTitleIds: [titleId],
                            knownPortedGames: knownGames
                        ) { [weak self] refreshOk, refreshErr in
                            guard let self = self else { return }
                            guard refreshOk else {
                                self.isHotDropping = false
                                let errMsg = refreshErr ?? "Failed to update cached frameworks for NxN Launcher."
                                DispatchQueue.main.async {
                                    DeviceDeploymentService.shared.stopElapsedTimer()
                                    DeviceDeploymentService.shared.activeDeployment.isRunning = false
                                    DeviceDeploymentService.shared.failDeployment(
                                        category: .generic(errMsg),
                                        title: "Framework Desatualizado no Launcher",
                                        detail: errMsg
                                    )
                                }
                                completion(false, errMsg)
                                return
                            }

                            let refreshedState = self.loadShellLibrary()
                            let resolvedTeamId = team?.id ?? "0000000000"
                            if installed, self.isHubUpToDateOnDevice(device: activeDevice, library: refreshedState, teamId: resolvedTeamId) {
                                DispatchQueue.main.async {
                                    DeviceDeploymentService.shared.activeDeployment.logLines.append(
                                        "[OK] NxN Launcher on \(activeDevice.name) already embeds unchanged frameworks; skipping Xcode rebuild & reinstall."
                                    )
                                }
                                runHotDropWithRecovery(allowRetry: true)
                                return
                            }

                            func prepareAndInstall(allowProjectRetry: Bool) {
                                self.prepareShellProject(library: refreshedState, teamId: resolvedTeamId) { [weak self] prepOk, prepMsg in
                                    guard let self = self else { return }
                                    guard prepOk else {
                                        if allowProjectRetry {
                                            try? FileManager.default.removeItem(at: self.hubProjectURL.appendingPathComponent("DmShell.xcodeproj"))
                                            prepareAndInstall(allowProjectRetry: false)
                                            return
                                        }
                                        self.isHotDropping = false
                                        DispatchQueue.main.async {
                                            DeviceDeploymentService.shared.stopElapsedTimer()
                                            DeviceDeploymentService.shared.activeDeployment.isRunning = false
                                            DeviceDeploymentService.shared.failDeployment(category: .generic(prepMsg), title: "Project Preparation Failed", detail: prepMsg)
                                        }
                                        completion(false, prepMsg)
                                        return
                                    }

                                    self.compileAndInstallShell(device: activeDevice, team: team) { [weak self] instOk, instMsg in
                                        guard let self = self else { return }
                                        if instOk {
                                            DispatchQueue.main.async {
                                                DeviceDeploymentService.shared.activeDeployment.logLines.append(
                                                    installed
                                                        ? "[OK] NxN Launcher updated! Sending RomFS..."
                                                        : "[OK] NxN Launcher installed successfully! Sending game data..."
                                                )
                                            }
                                            runHotDropWithRecovery(allowRetry: true)
                                        } else {
                                            self.isHotDropping = false
                                            DispatchQueue.main.async {
                                                DeviceDeploymentService.shared.stopElapsedTimer()
                                                DeviceDeploymentService.shared.activeDeployment.isRunning = false
                                                DeviceDeploymentService.shared.failDeployment(
                                                    category: .generic(instMsg),
                                                    title: installed ? "NxN Launcher Update Failed" : "NxN Launcher Installation Failed",
                                                    detail: instMsg
                                                )
                                            }
                                            completion(false, instMsg)
                                        }
                                    }
                                }
                            }

                            prepareAndInstall(allowProjectRetry: true)
                        }
                    }
                }

                ensureGameFrameworkWithRetry(allowRetry: true)
            }
        }
    }
}
