import Foundation
import AppKit

// MARK: - Route C Shell Compilation and Device Installation

extension NxHubDeploymentService {
    /// Compiles DmShell with the user's signing identity and installs it onto the target device.
    public func compileAndInstallShell(
        device: ConnectedAppleDevice,
        team: DeveloperSigningTeam?,
        completion: @escaping (Bool, String) -> Void
    ) {
        let teamId = team?.id ?? "0000000000"
        let projectPath = hubProjectURL.appendingPathComponent("DmShell.xcodeproj").path

        guard FileManager.default.fileExists(atPath: projectPath) else {
            completion(false, "Shell project does not exist at \(projectPath)")
            return
        }

        DispatchQueue.main.async {
            DeviceDeploymentService.shared.activeDeployment.phase = .signing
            DeviceDeploymentService.shared.activeDeployment.statusMessage = "Compiling NxN Launcher..."
            DeviceDeploymentService.shared.activeDeployment.detailMessage = "Building DmShell for \(device.name)..."
            DeviceDeploymentService.shared.activeDeployment.logLines.append("==> Building DmShell.app with Xcode for NxN Launcher...")
        }

        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            guard let self = self else { return }

            let logURL = self.hubDerivedDataURL.appendingPathComponent("xcodebuild_shell.log")
            var buildEnv = ProcessInfo.processInfo.environment
            let path = buildEnv["PATH"] ?? "/usr/bin:/bin:/usr/sbin:/sbin"
            buildEnv["PATH"] = "/opt/homebrew/bin:/usr/local/bin:" + path

            var (buildOk, buildOut, buildStatus) = self.runShellXcodeBuild(
                projectPath: projectPath,
                device: device,
                teamId: teamId,
                logURL: logURL,
                environment: buildEnv
            )

            // Self-heal once on transient/stale DerivedData build errors (unless explicitly missing signing team/account).
            if !buildOk && !self.isNonRecoverableSigningError(buildOut) {
                DispatchQueue.main.async {
                    DeviceDeploymentService.shared.activeDeployment.detailMessage = "Limpeza automática de cache Xcode e nova tentativa..."
                    DeviceDeploymentService.shared.activeDeployment.logLines.append("[WARN] xcodebuild falhou (\(buildStatus)); limpando caches em MobileHub/dd/Build e regerando projeto...")
                }
                self.resetShellBuildCaches(library: self.loadShellLibrary(), teamId: teamId)
                (buildOk, buildOut, buildStatus) = self.runShellXcodeBuild(
                    projectPath: projectPath,
                    device: device,
                    teamId: teamId,
                    logURL: logURL,
                    environment: buildEnv
                )
            }

            guard buildOk else {
                let errLine = buildOut.split(separator: "\n").filter { $0.contains("error:") }.last ?? "Compilation failed"
                DispatchQueue.main.async {
                    completion(false, "xcodebuild failed (\(buildStatus)): \(errLine)")
                }
                return
            }

            // Verify built .app
            let builtApp = self.hubDerivedDataURL
                .appendingPathComponent("Build/Products/Release-iphoneos/DmShell.app")
            guard FileManager.default.fileExists(atPath: builtApp.path) else {
                DispatchQueue.main.async {
                    completion(false, "Built app not found at \(builtApp.path)")
                }
                return
            }

            DispatchQueue.main.async {
                DeviceDeploymentService.shared.activeDeployment.phase = .installing
                DeviceDeploymentService.shared.activeDeployment.statusMessage = "Installing Hub onto \(device.name)..."
                DeviceDeploymentService.shared.activeDeployment.detailMessage = "Installing DmShell via devicectl..."
                DeviceDeploymentService.shared.activeDeployment.logLines.append("==> Installing DmShell.app via devicectl...")
            }

            let installLogURL = self.hubDerivedDataURL.appendingPathComponent("install_shell.log")
            var (instOk, installOut) = self.runShellDevicectlInstall(
                builtApp: builtApp,
                device: device,
                logURL: installLogURL,
                environment: buildEnv
            )

            // Self-heal: handle entitlement/team mismatch by uninstalling conflicting Hub app & reinstalling cleanly,
            // or retry once after brief tunnel/device stabilization.
            if !instOk {
                let libState = self.loadShellLibrary()
                if self.isEntitlementOrUpgradeMismatch(installOut) {
                    DispatchQueue.main.async {
                        DeviceDeploymentService.shared.activeDeployment.detailMessage = "Corrigindo conflito de assinatura no iPhone e reinstalando Hub..."
                        DeviceDeploymentService.shared.activeDeployment.logLines.append("[WARN] Conflito de assinatura/certificado detectado; removendo Hub conflitante para reinstalação limpa...")
                    }
                    self.uninstallConflictingHubApps(library: libState, on: device, teamId: teamId)
                    (instOk, installOut) = self.runShellDevicectlInstall(
                        builtApp: builtApp,
                        device: device,
                        logURL: installLogURL,
                        environment: buildEnv
                    )
                } else {
                    DispatchQueue.main.async {
                        DeviceDeploymentService.shared.activeDeployment.detailMessage = "Reconectando a \(device.name) e retentando instalação..."
                        DeviceDeploymentService.shared.activeDeployment.logLines.append("[WARN] Instalação inicial do Hub falhou; aguardando estabilização e retentando...")
                    }
                    usleep(1_800_000)
                    _ = self.resolveAvailableDevice(device, waitSeconds: 4.0)
                    (instOk, installOut) = self.runShellDevicectlInstall(
                        builtApp: builtApp,
                        device: device,
                        logURL: installLogURL,
                        environment: buildEnv
                    )
                }
            }

            if instOk {
                let libState = self.loadShellLibrary()
                self.recordHubDeployedOnDevice(device: device, library: libState, teamId: teamId)
                AppleAfcTransferService.invalidateUDIDCache(for: device.id)

                DispatchQueue.main.async {
                    self.detectedHubBundleId = libState.bundleID
                    DeviceDeploymentService.shared.activeDeployment.detailMessage = "NxN Launcher instalado; validando container de dados..."
                    DeviceDeploymentService.shared.activeDeployment.logLines.append("==> Verificando container do NxN Launcher (\(libState.bundleID))...")
                }

                _ = AppleAfcTransferService.waitForContainerReady(
                    bundleId: libState.bundleID,
                    device: device,
                    timeoutSeconds: 6.0
                )

                DispatchQueue.main.async {
                    DeviceDeploymentService.shared.activeDeployment.detailMessage = "NxN Launcher pronto para receber jogos."
                    completion(true, L10n.t("nxn_launcher.status_ready"))
                }
            } else {
                DispatchQueue.main.async {
                    DeviceDeploymentService.shared.activeDeployment.detailMessage = "Falha na instalação do NxN Launcher."
                    completion(false, "Installation failed: \(installOut)")
                }
            }
        }
    }

    private func runShellXcodeBuild(
        projectPath: String,
        device: ConnectedAppleDevice,
        teamId: String,
        logURL: URL,
        environment: [String: String]
    ) -> (success: Bool, output: String, exitCode: Int32) {
        try? FileManager.default.removeItem(at: logURL)
        FileManager.default.createFile(atPath: logURL.path, contents: nil)
        guard let logHandle = try? FileHandle(forWritingTo: logURL) else {
            return (false, "Cannot open log file for xcodebuild", -1)
        }

        let buildProc = Process()
        buildProc.executableURL = URL(fileURLWithPath: "/usr/bin/xcrun")
        buildProc.arguments = [
            "xcodebuild",
            "-project", projectPath,
            "-scheme", "DmShell",
            "-configuration", "Release",
            "-destination", "id=\(device.id)",
            "-derivedDataPath", self.hubDerivedDataURL.path,
            "-allowProvisioningUpdates",
            "DEVELOPMENT_TEAM=\(teamId)",
            "build"
        ]
        buildProc.environment = environment
        buildProc.standardOutput = logHandle
        buildProc.standardError = logHandle

        let buildWatchdog = DispatchSource.makeTimerSource(queue: DispatchQueue.global())
        buildWatchdog.schedule(deadline: .now() + 300.0)
        buildWatchdog.setEventHandler { [weak buildProc] in
            if let p = buildProc, p.isRunning { p.terminate() }
        }
        buildWatchdog.resume()

        do {
            try buildProc.run()
            buildProc.waitUntilExit()
            buildWatchdog.cancel()
            try? logHandle.close()
            let buildOut = (try? String(contentsOf: logURL, encoding: .utf8)) ?? ""
            return (buildProc.terminationStatus == 0, buildOut, buildProc.terminationStatus)
        } catch {
            buildWatchdog.cancel()
            try? logHandle.close()
            return (false, error.localizedDescription, -1)
        }
    }

    private func runShellDevicectlInstall(
        builtApp: URL,
        device: ConnectedAppleDevice,
        logURL: URL,
        environment: [String: String]
    ) -> (success: Bool, output: String) {
        try? FileManager.default.removeItem(at: logURL)
        FileManager.default.createFile(atPath: logURL.path, contents: nil)
        guard let installLogHandle = try? FileHandle(forWritingTo: logURL) else {
            return (false, "Cannot open log file for devicectl")
        }

        let installProc = Process()
        installProc.executableURL = URL(fileURLWithPath: "/usr/bin/xcrun")
        installProc.arguments = [
            "devicectl", "device", "install", "app",
            "--device", device.id,
            builtApp.path
        ]
        installProc.environment = environment
        installProc.standardOutput = installLogHandle
        installProc.standardError = installLogHandle

        let installWatchdog = DispatchSource.makeTimerSource(queue: DispatchQueue.global())
        installWatchdog.schedule(deadline: .now() + 240.0)
        installWatchdog.setEventHandler { [weak installProc] in
            if let p = installProc, p.isRunning { p.terminate() }
        }
        installWatchdog.resume()

        do {
            try installProc.run()
            installProc.waitUntilExit()
            installWatchdog.cancel()
            try? installLogHandle.close()
            let installOut = (try? String(contentsOf: logURL, encoding: .utf8)) ?? ""
            return (installProc.terminationStatus == 0, installOut)
        } catch {
            installWatchdog.cancel()
            try? installLogHandle.close()
            return (false, error.localizedDescription)
        }
    }

    private func isNonRecoverableSigningError(_ output: String) -> Bool {
        let lower = output.lowercased()
        return lower.contains("maximum number of registered")
            || lower.contains("signing for \"dmshell\" requires a development team")
            || lower.contains("no accounts with app store connect access")
            || lower.contains("authentication")
    }

    private func isEntitlementOrUpgradeMismatch(_ output: String) -> Bool {
        let lower = output.lowercased()
        return lower.contains("mismatchedapplicationidentifierentitlement")
            || lower.contains("application-identifier")
            || lower.contains("upgrade")
            || lower.contains("previous installation")
            || lower.contains("codesigning")
            || lower.contains("entitlement")
    }

    private func uninstallConflictingHubApps(
        library: ShellLibraryState,
        on device: ConnectedAppleDevice,
        teamId: String
    ) {
        var bundleIds = Set<String>([library.bundleID, Self.hubBundleId, "org.nxnative.launcher"])
        if let detected = self.detectedHubBundleId, !detected.isEmpty {
            bundleIds.insert(detected)
        }
        for bid in bundleIds where !bid.isEmpty {
            _ = BoundedProcess.run(
                "/usr/bin/xcrun",
                ["devicectl", "device", "uninstall", "app", "--device", device.id, "--bundle-identifier", bid],
                timeout: 20.0
            )
            UserDefaults.standard.removeObject(forKey: self.hubSignatureDefaultsKey(deviceId: device.id, bundleId: bid))
        }
        DispatchQueue.main.async {
            self.detectedHubBundleId = nil
        }
        usleep(500_000)
    }

    internal func resetShellBuildCaches(library: ShellLibraryState, teamId: String) {
        let fm = FileManager.default
        try? fm.removeItem(at: hubDerivedDataURL.appendingPathComponent("Build"))
        try? fm.removeItem(at: hubProjectURL.appendingPathComponent("DmShell.xcodeproj"))

        let sema = DispatchSemaphore(value: 0)
        prepareShellProject(library: library, teamId: teamId) { _, _ in
            sema.signal()
        }
        _ = sema.wait(timeout: .now() + 35.0)
    }
}
