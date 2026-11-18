import Foundation
import AppKit

// MARK: - Asynchronous devicectl Execution with Real-Time Pipe Streaming
extension DeviceDeploymentService {
    internal func executeDeviceCtlInstall(
        targetAppURL: URL,
        device: ConnectedAppleDevice,
        stagedRomfsURL: URL?
    ) {
        let process = Process()
        let pipeOut = Pipe()
        let pipeErr = Pipe()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/xcrun")
        process.arguments = ["devicectl", "device", "install", "app", "--device", device.id, targetAppURL.path, "--verbose"]
        process.standardOutput = pipeOut
        process.standardError = pipeErr

        self.currentRunningProcess = process

        var fullOutput = ""
        let lock = NSLock()

        let handleOutputData: (Data) -> Void = { [weak self] data in
            guard let self = self, !data.isEmpty, let text = String(data: data, encoding: .utf8) else { return }
            lock.lock()
            fullOutput += text
            lock.unlock()

            let lines = text.components(separatedBy: .newlines)
            for line in lines {
                let trimmed = line.trimmingCharacters(in: .whitespacesAndNewlines)
                guard !trimmed.isEmpty else { continue }

                DispatchQueue.main.async {
                    self.activeDeployment.logLines.append(trimmed)
                    if self.activeDeployment.logLines.count > 60 {
                        self.activeDeployment.logLines.removeFirst()
                    }
                    self.parseDeviceCtlLine(trimmed)
                }
            }
        }

        pipeOut.fileHandleForReading.readabilityHandler = { handle in
            handleOutputData(handle.availableData)
        }
        pipeErr.fileHandleForReading.readabilityHandler = { handle in
            handleOutputData(handle.availableData)
        }

        let appSize = fileSize(of: targetAppURL)
        let timeoutSeconds = max(180.0, (Double(appSize) / (15.0 * 1024.0 * 1024.0)) + 120.0)

        let watchdog = DispatchSource.makeTimerSource(queue: DispatchQueue.global())
        watchdog.schedule(deadline: .now() + timeoutSeconds)
        watchdog.setEventHandler { [weak process, weak self] in
            guard let proc = process, proc.isRunning else { return }
            proc.terminate()
            DispatchQueue.main.async {
                self?.failDeployment(
                    category: .deviceDisconnected,
                    title: "Tempo Limite Excedido (Watchdog)",
                    detail: "A instalação do app excedeu o tempo limite (\(Int(timeoutSeconds))s).\n1. Desbloqueie o iPhone com o código de acesso.\n2. Se solicitado, toque em 'Confiar neste Computador'.\n3. Verifique o cabo USB e tente novamente."
                )
            }
        }
        watchdog.resume()

        process.terminationHandler = { [weak self] proc in
            watchdog.cancel()
            pipeOut.fileHandleForReading.readabilityHandler = nil
            pipeErr.fileHandleForReading.readabilityHandler = nil

            let remOut = pipeOut.fileHandleForReading.readDataToEndOfFile()
            let remErr = pipeErr.fileHandleForReading.readDataToEndOfFile()
            handleOutputData(remOut)
            handleOutputData(remErr)

            lock.lock()
            let output = fullOutput
            lock.unlock()

            DispatchQueue.main.async {
                self?.handleDeviceCtlTermination(
                    status: proc.terminationStatus,
                    output: output,
                    device: device,
                    targetAppURL: targetAppURL,
                    stagedRomfsURL: stagedRomfsURL
                )
            }
        }

        do {
            try process.run()
        } catch {
            pipeOut.fileHandleForReading.readabilityHandler = nil
            pipeErr.fileHandleForReading.readabilityHandler = nil
            DispatchQueue.main.async {
                self.failDeployment(
                    category: .generic(error.localizedDescription),
                    title: "Failed to Launch devicectl",
                    detail: error.localizedDescription
                )
            }
        }
    }

    internal func parseDeviceCtlLine(_ line: String) {
        let lower = line.lowercased()

        if lower.contains("tunnel connection") {
            activeDeployment.progressFraction = max(activeDeployment.progressFraction, 0.52)
            activeDeployment.detailMessage = "USB / Network tunnel established with device..."
        } else if lower.contains("developer disk image") {
            activeDeployment.progressFraction = max(activeDeployment.progressFraction, 0.62)
            activeDeployment.detailMessage = "Developer services active on iOS..."
        } else if lower.contains("usage assertion") {
            activeDeployment.progressFraction = max(activeDeployment.progressFraction, 0.72)
            activeDeployment.detailMessage = "Transferring game package to device..."
        } else if lower.contains("staging") || lower.contains("uploading") {
            activeDeployment.progressFraction = max(activeDeployment.progressFraction, 0.80)
            activeDeployment.detailMessage = "Transferring files to device storage..."
        } else if lower.contains("install") || lower.contains("extracting") {
            activeDeployment.phase = .installing
            activeDeployment.progressFraction = max(activeDeployment.progressFraction, 0.88)
            activeDeployment.statusMessage = "Finalizing installation on iOS..."
            activeDeployment.detailMessage = "iOS is registering the app in the system..."
        }
    }

    internal func completeDeploymentSuccess(device: ConnectedAppleDevice, targetAppURL: URL) {
        stopElapsedTimer()
        currentRunningProcess = nil
        activeDeployment.isRunning = false
        activeDeployment.phase = .completed
        activeDeployment.progressFraction = 1.0
        activeDeployment.statusMessage = "Port installed successfully on \(device.name)!"
        activeDeployment.detailMessage = L10n.t("settings_modal.developer_mode_tip")
        activeDeployment.logLines.append("[SUCCESS] Installation completed successfully!")

        if let g = self.currentDeployingGame {
            IosDeploymentTracker.shared.recordDeployment(for: g, deviceName: device.name, deviceId: device.id)
        } else if let appURL = self.currentDeployingAppURL ?? Optional(targetAppURL) {
            IosDeploymentTracker.shared.recordDeployment(forGameUrl: appURL, deviceName: device.name, deviceId: device.id)
        }
        self.currentDeployingGame = nil

        let cb = completionCallback
        completionCallback = nil
        cb?(true, activeDeployment.statusMessage)
    }

    /// Best-effort bounded config sync (`Documents/env.txt`) after standalone `.ipa` installation.
    /// Runs on a background queue and never fails deployment if the device container cannot be updated.
    internal func finalizeDeploymentWithConfigSync(
        device: ConnectedAppleDevice,
        targetAppURL: URL,
        bundleId: String? = nil
    ) {
        let gameSnapshot = self.currentDeployingGame
        let deployURL = self.currentDeployingAppURL ?? targetAppURL
        let resolvedBid = bundleId
            ?? extractBundleIdentifier(from: targetAppURL)
            ?? extractBundleIdentifier(from: deployURL)
            ?? gameSnapshot?.bundleId

        guard let gameSnapshot, let resolvedBid, !resolvedBid.isEmpty else {
            DispatchQueue.main.async {
                self.completeDeploymentSuccess(device: device, targetAppURL: targetAppURL)
            }
            return
        }

        let cfg = GameRuntimeConfig.load(for: gameSnapshot)
        let syncToken = String(Int64(Date().timeIntervalSince1970 * 1000))
        let envText = cfg.iosEnvFileContent(for: gameSnapshot, syncToken: syncToken)

        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            guard let self = self else {
                DispatchQueue.main.async {
                    DeviceDeploymentService.shared.completeDeploymentSuccess(device: device, targetAppURL: targetAppURL)
                }
                return
            }
            let tempEnv = FileManager.default.temporaryDirectory
                .appendingPathComponent("nxnative_install_env_\(UUID().uuidString).txt")
            var didPush = false
            if (try? envText.write(to: tempEnv, atomically: true, encoding: .utf8)) != nil {
                defer { try? FileManager.default.removeItem(at: tempEnv) }
                didPush = self.pushSingleFileToIosContainer(
                    localURL: tempEnv,
                    bundleId: resolvedBid,
                    destinationSubpath: "Documents/env.txt",
                    device: device
                )
            }
            DispatchQueue.main.async {
                if didPush {
                    self.activeDeployment.logLines.append("[OK] Synced game configuration (Documents/env.txt) to \(device.name).")
                }
                self.completeDeploymentSuccess(device: device, targetAppURL: targetAppURL)
            }
        }
    }

    /// Checks whether romfs.img is already present in the target app's Documents folder on the device.
    /// Runs with bounded timeout (max 3.5s) to guarantee zero UI hang.
    internal func checkDeviceRomfsSize(bundleId: String, device: ConnectedAppleDevice) -> Int64? {
        AppleAfcTransferService.checkContainerFileSize(
            bundleId: bundleId,
            subdirectory: "Documents",
            searchName: "romfs.img",
            device: device
        )
    }

    internal func handleDeviceCtlTermination(
        status: Int32,
        output: String,
        device: ConnectedAppleDevice,
        targetAppURL: URL,
        stagedRomfsURL: URL?
    ) {
        stopElapsedTimer()
        currentRunningProcess = nil

        if status == 0 {
            activeDeployment.logLines.append("[SUCCESS] App bundle installed on \(device.name).")

            // Stage 2: Sideload romfs.img into app's Documents directory if present
            if let romfsURL = stagedRomfsURL, FileManager.default.fileExists(atPath: romfsURL.path) {
                let bundleId = extractBundleIdentifier(from: targetAppURL)
                    ?? findBundleId(for: currentDeployingGame?.titleId ?? "", gameName: currentDeployingGame?.name, on: device)
                    ?? findBundleId(for: targetAppURL.deletingPathExtension().lastPathComponent, on: device)
                    ?? "org.nxnative"

                activeDeployment.statusMessage = "Verifying game data (romfs.img)..."
                activeDeployment.detailMessage = "Checking if RomFS is already present on \(device.name)..."

                let expectedRomfsBytes = self.fileSize(of: romfsURL)
                DispatchQueue.global(qos: .userInitiated).async { [weak self] in
                    guard let self = self else { return }
                    if let devRomfsSize = self.checkDeviceRomfsSize(bundleId: bundleId, device: device),
                       (expectedRomfsBytes > 0 ? devRomfsSize == expectedRomfsBytes : devRomfsSize > 0) {
                        DispatchQueue.main.async {
                            self.activeDeployment.logLines.append("[OK] Game data (romfs.img) already verified on \(device.name) (\(self.formatByteSize(devRomfsSize))). Skipping re-transfer.")
                            self.finalizeDeploymentWithConfigSync(device: device, targetAppURL: targetAppURL, bundleId: bundleId)
                        }
                        return
                    }

                    DispatchQueue.main.async {
                        self.executeRomfsCopy(romfsURL: romfsURL, bundleId: bundleId, device: device)
                    }
                }
                return
            }

            finalizeDeploymentWithConfigSync(device: device, targetAppURL: targetAppURL)
            return
        }

        activeDeployment.isRunning = false

        // Parse Failure Category
        if output.contains("0xe8008014") || output.contains("0xe8008015") || output.contains("ApplicationVerificationFailed") || output.contains("invalid signature") || output.contains("integridade não pôde ser verificada") {
            failDeployment(
                category: .signatureVerificationFailed,
                title: "iOS Signature Verification Failed",
                detail: "iOS rejected the app because it requires a valid Apple Developer certificate or must be sideloaded via AltStore, SideStore, Sideloadly, or TrollStore. On stock iOS, ensure your Apple ID is logged into Xcode.",
                raw: output
            )
        } else if output.contains("passcodeRequired") || output.contains("locked") {
            failDeployment(
                category: .deviceLocked,
                title: "Device is Locked",
                detail: "Unlock your \(device.name) with your passcode and try again.",
                raw: output
            )
        } else if output.contains("Developer Mode") || output.contains("developerModeStatus") {
            failDeployment(
                category: .developerModeDisabled,
                title: "Developer Mode Required",
                detail: "Enable Developer Mode in Settings > Privacy & Security > Developer Mode on your device, then restart.",
                raw: output
            )
        } else if output.contains("no space") || output.contains("storage") || output.contains("disc full") {
            failDeployment(
                category: .insufficientStorage,
                title: "Insufficient Storage",
                detail: "Not enough free storage space on \(device.name) to install this game.",
                raw: output
            )
        } else if output.contains("tunnel") || output.contains("disconnected") || output.contains("offline") || output.contains("connection issue") || output.contains("not available") || output.contains("paired with another") {
            failDeployment(
                category: .deviceDisconnected,
                title: "Device Connection Issue",
                detail: "1. Unlock \(device.name) and tap 'Trust This Computer'.\n2. Verify Developer Mode is ON in Settings > Privacy & Security > Developer Mode.\n3. Reconnect the USB cable or open Xcode > Window > Devices & Simulators to renew pairing.",
                raw: output
            )
        } else {
            let summary = output.trimmingCharacters(in: .whitespacesAndNewlines)
            failDeployment(
                category: .generic(summary),
                title: "Installation Failed on \(device.name)",
                detail: summary.isEmpty ? "Unknown devicectl error." : summary,
                raw: output
            )
        }
    }

    internal func executeRomfsCopy(romfsURL: URL, bundleId: String, device: ConnectedAppleDevice) {
        let resolvedRomfsURL = romfsURL.resolvingSymlinksInPath()
        let expectedBytes = fileSize(of: resolvedRomfsURL)

        startElapsedTimer()
        activeDeployment.isRunning = true
        activeDeployment.phase = .copyingRomFS
        activeDeployment.progressFraction = 0.90
        activeDeployment.statusMessage = L10n.t("settings_modal.copying_romfs_status")
        activeDeployment.detailMessage = L10n.t("settings_modal.copying_romfs_detail")
        activeDeployment.logLines.append("==> Transferring romfs.img (\(formatByteSize(expectedBytes))) to Documents on \(device.name) for \(bundleId)...")

        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            guard let self = self else { return }
            if expectedBytes > 0,
               let afcPath = AppleAfcTransferService.resolveAfcClientTool(),
               let udid = AppleAfcTransferService.resolveHardwareUDID(for: device) {
                let afcOK = AppleAfcTransferService.transferFileViaAfcClient(
                    afcPath: afcPath,
                    udid: udid,
                    domainId: bundleId,
                    resolvedSourceURL: resolvedRomfsURL,
                    destinationSubpath: "Documents/romfs.img",
                    expectedSize: expectedBytes,
                    device: device,
                    onProcessChanged: { proc in
                        DispatchQueue.main.async {
                            self.currentRunningProcess = proc
                        }
                    },
                    onProgress: { pct, speed in
                        DispatchQueue.main.async {
                            let baseProgress = 0.85
                            self.activeDeployment.progressFraction = min(0.99, baseProgress + (0.14 * pct))
                            if !speed.isEmpty {
                                self.activeDeployment.detailMessage = "USB streaming: \(Int(pct * 100))% (\(speed))"
                            } else {
                                self.activeDeployment.detailMessage = "USB streaming: \(Int(pct * 100))%"
                            }
                        }
                    },
                    onLog: { line in
                        DispatchQueue.main.async {
                            self.activeDeployment.logLines.append(line)
                        }
                    }
                )

                var wasCancelled = false
                DispatchQueue.main.sync {
                    wasCancelled = (self.activeDeployment.phase == .cancelled)
                }
                if wasCancelled {
                    DispatchQueue.main.async {
                        self.stopElapsedTimer()
                        self.activeDeployment.isRunning = false
                    }
                    return
                }

                if afcOK {
                    DispatchQueue.main.async {
                        self.stopElapsedTimer()
                        self.currentRunningProcess = nil
                        self.activeDeployment.isRunning = false
                        self.activeDeployment.logLines.append("[SUCCESS] Game data (romfs.img) streamed via USB (afcclient) and verified on \(device.name) (\(self.formatByteSize(expectedBytes))).")
                        self.finalizeDeploymentWithConfigSync(device: device, targetAppURL: self.currentDeployingAppURL ?? resolvedRomfsURL, bundleId: bundleId)
                    }
                    return
                }

                DispatchQueue.main.async {
                    self.activeDeployment.logLines.append("[WARN] afcclient streaming failed or device is on Wi-Fi; falling back to devicectl...")
                }
            }

            DispatchQueue.main.async {
                guard self.activeDeployment.phase != .cancelled else { return }
                self.executeDevicectlRomfsCopy(romfsURL: resolvedRomfsURL, expectedBytes: expectedBytes, bundleId: bundleId, device: device)
            }
        }
    }

    private func executeDevicectlRomfsCopy(
        romfsURL: URL,
        expectedBytes: Int64,
        bundleId: String,
        device: ConnectedAppleDevice
    ) {
        let process = Process()
        let pipeOut = Pipe()
        let pipeErr = Pipe()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/xcrun")
        process.arguments = [
            "devicectl", "device", "copy", "to",
            "--device", device.id,
            "--domain-type", "appDataContainer",
            "--domain-identifier", bundleId,
            "--source", romfsURL.path,
            "--destination", "Documents/romfs.img",
            "--verbose"
        ]
        process.standardOutput = pipeOut
        process.standardError = pipeErr
        self.currentRunningProcess = process

        var fullOutput = ""
        let lock = NSLock()

        let handleOutputData: (Data) -> Void = { [weak self] data in
            guard let self = self, !data.isEmpty, let text = String(data: data, encoding: .utf8) else { return }
            lock.lock()
            fullOutput += text
            lock.unlock()

            let lines = text.components(separatedBy: .newlines)
            for line in lines {
                let trimmed = line.trimmingCharacters(in: .whitespacesAndNewlines)
                guard !trimmed.isEmpty else { continue }
                DispatchQueue.main.async {
                    self.activeDeployment.logLines.append(trimmed)
                    if self.activeDeployment.logLines.count > 60 {
                        self.activeDeployment.logLines.removeFirst()
                    }
                }
            }
        }

        pipeOut.fileHandleForReading.readabilityHandler = { handle in handleOutputData(handle.availableData) }
        pipeErr.fileHandleForReading.readabilityHandler = { handle in handleOutputData(handle.availableData) }

        let romfsTimeoutSeconds = max(180.0, (Double(expectedBytes) / (15.0 * 1024.0 * 1024.0)) + 120.0)

        let watchdog = DispatchSource.makeTimerSource(queue: DispatchQueue.global())
        watchdog.schedule(deadline: .now() + romfsTimeoutSeconds)
        watchdog.setEventHandler { [weak process, weak self] in
            guard let proc = process, proc.isRunning else { return }
            proc.terminate()
            DispatchQueue.main.async {
                self?.failDeployment(
                    category: .deviceDisconnected,
                    title: "Tempo Limite Excedido (Watchdog)",
                    detail: "A transferência do RomFS excedeu o tempo limite (\(Int(romfsTimeoutSeconds))s).\n1. Desbloqueie o iPhone com o código de acesso.\n2. Verifique o cabo USB e a conexão com o dispositivo."
                )
            }
        }
        watchdog.resume()

        process.terminationHandler = { [weak self] proc in
            watchdog.cancel()
            pipeOut.fileHandleForReading.readabilityHandler = nil
            pipeErr.fileHandleForReading.readabilityHandler = nil
            let remOut = pipeOut.fileHandleForReading.readDataToEndOfFile()
            let remErr = pipeErr.fileHandleForReading.readDataToEndOfFile()
            handleOutputData(remOut)
            handleOutputData(remErr)

            lock.lock()
            let output = fullOutput
            lock.unlock()

            DispatchQueue.main.async {
                guard let self = self else { return }
                self.stopElapsedTimer()
                self.currentRunningProcess = nil
                guard self.activeDeployment.phase != .cancelled else { return }

                DispatchQueue.global(qos: .userInitiated).async { [weak self] in
                    guard let self = self else { return }
                    let devRomfsSize = self.checkDeviceRomfsSize(bundleId: bundleId, device: device)
                    let verifiedMatch = expectedBytes > 0
                        ? (devRomfsSize == expectedBytes)
                        : ((devRomfsSize ?? 0) > 0)

                    DispatchQueue.main.async {
                        self.activeDeployment.isRunning = false
                        if verifiedMatch {
                            let labelSize = devRomfsSize ?? expectedBytes
                            self.activeDeployment.logLines.append("[SUCCESS] Game data (romfs.img) verified on \(device.name) (\(self.formatByteSize(labelSize))).")
                            self.finalizeDeploymentWithConfigSync(device: device, targetAppURL: self.currentDeployingAppURL ?? romfsURL, bundleId: bundleId)
                        } else {
                            var detailMsg = "Could not verify romfs.img on \(device.name) (device size: \(devRomfsSize.map { self.formatByteSize($0) } ?? "missing"), expected: \(self.formatByteSize(expectedBytes)))."
                            if !output.isEmpty {
                                detailMsg += " Output: \(output)"
                            }
                            if expectedBytes >= 3_500_000_000 {
                                detailMsg += " Tip: devicectl can leave 0-byte multi-GB files on 16 GB Macs; install libimobiledevice (afcclient) in Settings > Toolchain."
                            }
                            self.failDeployment(
                                category: .generic(output.isEmpty ? detailMsg : output),
                                title: "Failed to Verify Game Data (romfs.img)",
                                detail: detailMsg,
                                raw: output
                            )
                        }
                    }
                }
            }
        }

        do {
            try process.run()
        } catch {
            watchdog.cancel()
            pipeOut.fileHandleForReading.readabilityHandler = nil
            pipeErr.fileHandleForReading.readabilityHandler = nil
            DispatchQueue.main.async {
                self.failDeployment(
                    category: .generic(error.localizedDescription),
                    title: "Failed to Launch devicectl copy",
                    detail: error.localizedDescription
                )
            }
        }
    }

    internal func extractBundleIdentifier(from appURL: URL) -> String? {
        let plistURL = appURL.appendingPathComponent("Info.plist")
        guard let data = try? Data(contentsOf: plistURL),
              let plist = try? PropertyListSerialization.propertyList(from: data, options: [], format: nil) as? [String: Any],
              let bid = plist["CFBundleIdentifier"] as? String else {
            return nil
        }
        return bid
    }

    internal func fileSize(of url: URL) -> Int64 {
        let resolved = url.resolvingSymlinksInPath()
        let values = try? resolved.resourceValues(forKeys: [.fileSizeKey])
        return Int64(values?.fileSize ?? 0)
    }

    internal func failDeployment(category: DeploymentErrorCategory, title: String, detail: String, raw: String? = nil) {
        stopElapsedTimer()
        currentRunningProcess = nil
        activeDeployment.isRunning = false
        activeDeployment.phase = .failed
        activeDeployment.errorCategory = category
        activeDeployment.statusMessage = title
        activeDeployment.detailMessage = detail
        activeDeployment.rawError = raw
        activeDeployment.logLines.append("[ERROR] \(title): \(detail)")

        let cb = completionCallback
        completionCallback = nil
        cb?(false, title)
    }

    // MARK: - Timer Management
    internal func startElapsedTimer() {
        stopElapsedTimer()
        elapsedTimer = Timer.scheduledTimer(withTimeInterval: 1.0, repeats: true) { [weak self] _ in
            DispatchQueue.main.async {
                guard let self = self, self.activeDeployment.isRunning else { return }
                self.activeDeployment.elapsedSeconds += 1
            }
        }
    }

    internal func stopElapsedTimer() {
        elapsedTimer?.invalidate()
        elapsedTimer = nil
    }

    // MARK: - Utilities
    internal func formatByteSize(_ bytes: Int64) -> String {
        let formatter = ByteCountFormatter()
        formatter.allowedUnits = [.useGB, .useMB]
        formatter.countStyle = .file
        return formatter.string(fromByteCount: bytes)
    }
}
