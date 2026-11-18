import Foundation
import AppKit

// MARK: - Multi-Game Batch Deployment & Storage Validation for NxN Launcher
extension NxHubDeploymentService {

    /// Validates device storage before deploying a batch of games.
    public func validateDeviceStorage(
        for games: [PortedGame],
        on device: ConnectedAppleDevice,
        completion: @escaping (Bool, String) -> Void
    ) {
        var totalBytes: Int64 = 0

        for game in games {
            totalBytes += estimatedTransferSizeBytes(for: game)
        }

        let formattedTotal = ByteCountFormatter.string(fromByteCount: totalBytes, countStyle: .file)

        // Query available device storage via USB AFC / ideviceinfo
        DispatchQueue.global(qos: .userInitiated).async {
            if let freeBytes = AppleAfcTransferService.queryFreeStorageBytes(for: device) {
                let formattedFree = ByteCountFormatter.string(fromByteCount: freeBytes, countStyle: .file)
                let safetyMargin: Int64 = 1024 * 1024 * 1024 // 1 GB safety buffer
                if freeBytes < (totalBytes + safetyMargin) {
                    DispatchQueue.main.async {
                        completion(false, "Espaço insuficiente em \(device.name). Necessário: \(formattedTotal), Livre: \(formattedFree).")
                    }
                    return
                }
            }

            DispatchQueue.main.async {
                completion(true, "Armazenamento verificado: \(formattedTotal) para \(games.count) jogo(s).")
            }
        }
    }

    /// Deploys a collection of games sequentially to the NxN Launcher container.
    public func deployBatchToHub(
        games: [PortedGame],
        device: ConnectedAppleDevice,
        team: DeveloperSigningTeam?,
        onProgress: @escaping (_ currentIndex: Int, _ totalCount: Int, _ status: String) -> Void,
        completion: @escaping (Bool, String) -> Void
    ) {
        guard !games.isEmpty else {
            completion(false, "Nenhum jogo selecionado para envio.")
            return
        }

        // Self-healing preflight: re-poll momentarily unavailable USB devices up to 3s before failing.
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            guard let self = self else { return }
            let resolvedDevice = self.resolveAvailableDevice(device, waitSeconds: 3.0)
            guard let activeDevice = resolvedDevice, activeDevice.isAvailable else {
                DispatchQueue.main.async {
                    completion(false, "\(device.name) indisponível ou com tela bloqueada. Desbloqueie o iPhone/iPad e tente novamente.")
                }
                return
            }

            AppleAfcTransferService.invalidateUDIDCache(for: activeDevice.id)
            var libraryState = self.loadShellLibrary()
            var verifiedGames: [PortedGame] = []
            var failedFrameworkEntries: [(name: String, reason: String)] = []

            // Phase 1: Ensure frameworks for all selected games and register in shell.json
            func prepareFrameworks(index: Int, didRetryCurrent: Bool = false) {
                guard index < games.count else {
                    guard failedFrameworkEntries.isEmpty else {
                        let summary = failedFrameworkEntries.map { "\($0.name) (\($0.reason))" }.joined(separator: ", ")
                        DispatchQueue.main.async {
                            DeviceDeploymentService.shared.activeDeployment.detailMessage = summary
                            completion(false, "Falha ao preparar frameworks para: \(summary)")
                        }
                        return
                    }
                    guard !verifiedGames.isEmpty else {
                        DispatchQueue.main.async {
                            completion(false, "Nenhum framework válido foi preparado.")
                        }
                        return
                    }

                    let verifiedTIDs = Set(verifiedGames.compactMap { $0.titleId?.uppercased() })
                    self.refreshFrameworksForHub(
                        games: libraryState.games,
                        device: activeDevice,
                        team: team,
                        excludingTitleIds: verifiedTIDs,
                        knownPortedGames: (AppViewModel.shared?.libraryGames ?? []) + games
                    ) { [weak self] refreshOk, refreshErr in
                        guard let self = self else { return }
                        guard refreshOk else {
                            let err = refreshErr ?? "Falha ao atualizar frameworks registrados no NxN Launcher."
                            DispatchQueue.main.async {
                                DeviceDeploymentService.shared.activeDeployment.detailMessage = err
                                completion(false, err)
                            }
                            return
                        }
                        let refreshedState = self.loadShellLibrary()
                        // Phase 2: Check device installation and install/update shell app ONCE
                        self.installOrUpdateHubApp(
                            games: verifiedGames,
                            libraryState: refreshedState,
                            device: activeDevice,
                            team: team,
                            onProgress: onProgress,
                            completion: completion
                        )
                    }
                    return
                }

                let game = games[index]
                let total = Double(max(1, games.count))
                let rangeStart = 0.05 + 0.25 * (Double(index) / total)
                let rangeEnd = 0.05 + 0.25 * (Double(index + 1) / total)
                onProgress(index + 1, games.count, "Preparando framework: \(game.name)...")
                DispatchQueue.main.async {
                    DeviceDeploymentService.shared.activeDeployment.detailMessage = didRetryCurrent
                        ? "Auto-corrigindo framework de \(game.name)..."
                        : "Validando framework de \(game.name)..."
                }

                self.ensureFramework(for: game, device: activeDevice, team: team, progressRange: rangeStart...rangeEnd) { [weak self] ok, fwURL, errorMsg in
                    guard let self = self else { return }
                    if ok, let fw = fwURL {
                        verifiedGames.append(game)
                        let titleId = game.titleId?.uppercased() ?? "0100000000000000"
                        if let registered = try? self.registerGameInHub(titleId: titleId, name: game.name, frameworkPath: fw.path) {
                            libraryState = registered
                        }
                        DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) {
                            prepareFrameworks(index: index + 1, didRetryCurrent: false)
                        }
                        return
                    }

                    if !didRetryCurrent {
                        DispatchQueue.main.async {
                            DeviceDeploymentService.shared.activeDeployment.logLines.append(
                                "[WARN] Falha ao preparar \(game.name) (\(errorMsg ?? "erro")); limpando cache do framework e tentando novamente..."
                            )
                        }
                        let tid = game.titleId?.uppercased() ?? "0100000000000000"
                        self.sanitizeFrameworkArtifacts(at: self.hubFrameworksURL.appendingPathComponent("DmGame\(tid).framework"))
                        DispatchQueue.main.asyncAfter(deadline: .now() + 0.4) {
                            prepareFrameworks(index: index, didRetryCurrent: true)
                        }
                        return
                    }

                    failedFrameworkEntries.append((name: game.name, reason: errorMsg ?? "erro desconhecido"))
                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) {
                        prepareFrameworks(index: index + 1, didRetryCurrent: false)
                    }
                }
            }

            prepareFrameworks(index: 0)
        }
    }

    private func installOrUpdateHubApp(
        games: [PortedGame],
        libraryState: ShellLibraryState,
        device: ConnectedAppleDevice,
        team: DeveloperSigningTeam?,
        onProgress: @escaping (_ currentIndex: Int, _ totalCount: Int, _ status: String) -> Void,
        completion: @escaping (Bool, String) -> Void
    ) {
        onProgress(1, games.count, "Verificando NxN Launcher no dispositivo...")

        isHubAppInstalled(on: device) { [weak self] isInstalled in
            guard let self = self else { return }

            let resolvedTeamId = team?.id ?? "0000000000"
            if isInstalled, self.isHubUpToDateOnDevice(device: device, library: libraryState, teamId: resolvedTeamId) {
                onProgress(1, games.count, "NxN Launcher atualizado! Enviando dados dos jogos...")
                DispatchQueue.main.async {
                    DeviceDeploymentService.shared.activeDeployment.detailMessage = "NxN Launcher pronto; iniciando envio dos jogos..."
                    DeviceDeploymentService.shared.activeDeployment.logLines.append(
                        "[OK] NxN Launcher on \(device.name) already embeds selected frameworks; skipping Xcode rebuild & reinstall."
                    )
                }
                self.transferBatchGameData(
                    games: games,
                    device: device,
                    onProgress: onProgress,
                    completion: completion
                )
                return
            }

            // If not installed, or to ensure all selected frameworks are embedded, prepare & compile shell ONCE
            onProgress(1, games.count, isInstalled ? "Atualizando NxN Launcher com os jogos..." : "Instalando NxN Launcher...")

            func runPrepareAndInstall(allowProjectResetRetry: Bool) {
                self.prepareShellProject(library: libraryState, teamId: resolvedTeamId) { [weak self] prepOk, prepMsg in
                    guard let self = self else { return }
                    guard prepOk else {
                        if allowProjectResetRetry {
                            DispatchQueue.main.async {
                                DeviceDeploymentService.shared.activeDeployment.detailMessage = "Regerando projeto Xcode do NxN Launcher..."
                                DeviceDeploymentService.shared.activeDeployment.logLines.append(
                                    "[WARN] prepareShellProject falhou; limpando DmShell.xcodeproj e retentando..."
                                )
                            }
                            try? FileManager.default.removeItem(at: self.hubProjectURL.appendingPathComponent("DmShell.xcodeproj"))
                            runPrepareAndInstall(allowProjectResetRetry: false)
                            return
                        }
                        DispatchQueue.main.async {
                            DeviceDeploymentService.shared.activeDeployment.detailMessage = prepMsg
                        }
                        completion(false, "Falha na preparação do NxN Launcher: \(prepMsg)")
                        return
                    }

                    self.compileAndInstallShell(device: device, team: team) { [weak self] instOk, instMsg in
                        guard let self = self else { return }
                        guard instOk else {
                            DispatchQueue.main.async {
                                DeviceDeploymentService.shared.activeDeployment.detailMessage = instMsg
                            }
                            completion(false, "Falha na instalação do NxN Launcher: \(instMsg)")
                            return
                        }

                        // Phase 3: Hot-drop (ROMFS) sequentially for each verified game
                        self.transferBatchGameData(
                            games: games,
                            device: device,
                            onProgress: onProgress,
                            completion: completion
                        )
                    }
                }
            }

            runPrepareAndInstall(allowProjectResetRetry: true)
        }
    }

    private final class BatchTransferAccumulator: @unchecked Sendable {
        let lock = NSLock()
        var completedCount = 0
        var failedEntries: [(name: String, reason: String)] = []
    }

    private func transferBatchGameData(
        games: [PortedGame],
        device: ConnectedAppleDevice,
        onProgress: @escaping (_ currentIndex: Int, _ totalCount: Int, _ status: String) -> Void,
        completion: @escaping (Bool, String) -> Void
    ) {
        let tracker = BatchTransferAccumulator()

        func transferNext(index: Int, didRetryCurrent: Bool = false) {
            guard index < games.count else {
                tracker.lock.lock()
                let completedCount = tracker.completedCount
                let failedEntries = tracker.failedEntries
                tracker.lock.unlock()

                let failedNames = failedEntries.map(\.name)
                let msg = failedEntries.isEmpty
                    ? "Todos os \(completedCount) jogos foram enviados com sucesso para o NxN Launcher!"
                    : "\(completedCount) jogos enviados. Falhas: \(failedNames.joined(separator: ", "))"
                DispatchQueue.main.async {
                    DeviceDeploymentService.shared.activeDeployment.isRunning = false
                    DeviceDeploymentService.shared.stopElapsedTimer()
                    if failedEntries.isEmpty {
                        DeviceDeploymentService.shared.activeDeployment.phase = .completed
                        DeviceDeploymentService.shared.activeDeployment.progressFraction = 1.0
                        DeviceDeploymentService.shared.activeDeployment.statusMessage = msg
                        DeviceDeploymentService.shared.activeDeployment.detailMessage = "Todos os \(completedCount) jogo(s) verificados em \(device.name)."
                    } else {
                        DeviceDeploymentService.shared.activeDeployment.phase = .failed
                        DeviceDeploymentService.shared.activeDeployment.statusMessage = msg
                        DeviceDeploymentService.shared.activeDeployment.detailMessage = "\(failedEntries[0].name): \(failedEntries[0].reason)"
                    }
                    completion(failedEntries.isEmpty, msg)
                }
                return
            }

            let game = games[index]
            let total = Double(max(1, games.count))
            let rangeStart = 0.35 + (0.65 * Double(index) / total)
            let rangeEnd = 0.35 + (0.65 * Double(index + 1) / total)
            onProgress(index + 1, games.count, "\(L10n.t("nxn_launcher.sending_progress_format", index + 1, games.count)) — \(game.name)")
            DispatchQueue.main.async {
                DeviceDeploymentService.shared.activeDeployment.detailMessage = didRetryCurrent
                    ? "Retentando envio de \(game.name)..."
                    : "Preparando \(game.name) no NxN Launcher..."
            }

            self.executeHotDropTransfer(
                game: game,
                device: device,
                isBatchMode: true,
                batchProgressRange: rangeStart...rangeEnd
            ) { [weak self] success, msg in
                guard let self = self else { return }
                if success {
                    tracker.lock.lock()
                    tracker.completedCount += 1
                    tracker.lock.unlock()
                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) {
                        transferNext(index: index + 1, didRetryCurrent: false)
                    }
                    return
                }

                // Self-healing auto-retry once per game on transient USB/container/tunnel glitches
                if !didRetryCurrent {
                    DispatchQueue.main.async {
                        DeviceDeploymentService.shared.activeDeployment.detailMessage = "Recuperando conexão USB e retentando \(game.name)..."
                        DeviceDeploymentService.shared.activeDeployment.logLines.append(
                            "[WARN] Envio de \(game.name) falhou (\(msg)); aguardando container e tentando novamente..."
                        )
                    }
                    DispatchQueue.global(qos: .userInitiated).async {
                        AppleAfcTransferService.invalidateUDIDCache(for: device.id)
                        let hubBid = self.resolveHubBundleId(for: game, on: device)
                        if let tid = game.titleId?.uppercased(), !tid.isEmpty {
                            AppleAfcTransferService.removeContainerFileIfPresent(
                                bundleId: hubBid,
                                subpath: "Documents/games/\(tid)/romfs.img.part",
                                device: device
                            )
                        }
                        usleep(1_500_000)
                        _ = AppleAfcTransferService.waitForContainerReady(bundleId: hubBid, device: device, timeoutSeconds: 5.0)
                        DispatchQueue.main.async {
                            transferNext(index: index, didRetryCurrent: true)
                        }
                    }
                    return
                }

                tracker.lock.lock()
                tracker.failedEntries.append((name: game.name, reason: msg))
                tracker.lock.unlock()
                DispatchQueue.main.async {
                    DeviceDeploymentService.shared.activeDeployment.logLines.append("[ERROR] \(game.name): \(msg)")
                }
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) {
                    transferNext(index: index + 1, didRetryCurrent: false)
                }
            }
        }

        transferNext(index: 0)
    }

    /// Prepares frameworks for all selected games, registers them, and builds the aggregate .ipa file.
    public func exportBatchIPA(
        games: [PortedGame],
        outputIPAURL: URL,
        teamId: String,
        onProgress: @escaping (_ status: String, _ progress: Double) -> Void,
        completion: @escaping (Bool, String) -> Void
    ) {
        guard !games.isEmpty else {
            completion(false, "Nenhum jogo selecionado para exportação.")
            return
        }

        var libraryState = loadShellLibrary()
        let total = Double(games.count)

        func processGame(index: Int) {
            if index >= games.count {
                let selectedTIDs = Set(games.compactMap { $0.titleId?.uppercased() })
                let dummyDevice = ConnectedAppleDevice(id: "dummy", name: "Build Host", model: "Host", osVersion: "1.0", isPaired: true, isAvailable: true)
                onProgress("Validando outros frameworks registrados no NxN Launcher...", 0.87)
                self.refreshFrameworksForHub(
                    games: libraryState.games,
                    device: dummyDevice,
                    team: nil,
                    excludingTitleIds: selectedTIDs,
                    knownPortedGames: (AppViewModel.shared?.libraryGames ?? []) + games
                ) { refreshOk, refreshErr in
                    guard refreshOk else {
                        completion(false, refreshErr ?? "Falha ao atualizar frameworks registrados no NxN Launcher.")
                        return
                    }
                    let refreshedState = self.loadShellLibrary()
                    onProgress("Empacotando NxN Launcher IPA agregador...", 0.90)
                    self.buildShellIPA(
                        library: refreshedState,
                        outputIPAURL: outputIPAURL,
                        teamId: teamId,
                        progressHandler: { status in
                            onProgress(status, 0.95)
                        },
                        completion: { success, msg in
                            completion(success, msg)
                        }
                    )
                }
                return
            }

            let game = games[index]
            let progressFraction = Double(index) / total * 0.85
            onProgress("Preparando framework: \(game.name) (\(index + 1)/\(games.count))...", progressFraction)

            let dummyDevice = ConnectedAppleDevice(id: "dummy", name: "Build Host", model: "Host", osVersion: "1.0", isPaired: true, isAvailable: true)
            self.ensureFramework(for: game, device: dummyDevice, team: nil) { ok, fwURL, errorMsg in
                guard ok, let fw = fwURL else {
                    completion(false, "Falha ao preparar framework para \(game.name): \(errorMsg ?? "Erro desconhecido")")
                    return
                }

                let titleId = game.titleId?.uppercased() ?? "0100000000000000"
                if let registered = try? self.registerGameInHub(titleId: titleId, name: game.name, frameworkPath: fw.path) {
                    libraryState = registered
                }

                DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) {
                    processGame(index: index + 1)
                }
            }
        }

        processGame(index: 0)
    }

    /// Exports romfs.img, manifest, and save folders for all selected games into a target directory (e.g. USB-C SSD or local folder).
    public func exportBatchGameData(
        games: [PortedGame],
        destinationFolderURL: URL,
        onProgress: @escaping (_ status: String, _ progress: Double) -> Void,
        completion: @escaping (Bool, String) -> Void
    ) {
        guard !games.isEmpty else {
            completion(false, "Nenhum jogo selecionado para exportação de dados.")
            return
        }

        let fm = FileManager.default
        let gamesFolder = destinationFolderURL.appendingPathComponent("games", isDirectory: true)

        DispatchQueue.global(qos: .userInitiated).async {
            do {
                try fm.createDirectory(at: gamesFolder, withIntermediateDirectories: true)
            } catch {
                DispatchQueue.main.async { completion(false, "Não foi possível criar a pasta games: \(error.localizedDescription)") }
                return
            }

            let total = Double(games.count)
            for (idx, game) in games.enumerated() {
                let titleId = game.titleId?.uppercased() ?? "0100000000000000"
                let targetGameFolder = gamesFolder.appendingPathComponent(titleId, isDirectory: true)
                try? fm.createDirectory(at: targetGameFolder, withIntermediateDirectories: true)

                let progressFraction = Double(idx) / total
                DispatchQueue.main.async {
                    onProgress("Exportando dados de \(game.name) (\(idx + 1)/\(games.count))...", progressFraction)
                }

                // Locate resolved non-empty romfs.img via shared Hub lookup
                let romfsURL = self.locateRomfsImage(for: game)
                let resolvedRomfsSize: Int64 = romfsURL.flatMap {
                    (try? fm.attributesOfItem(atPath: $0.path)[.size] as? Int64)
                } ?? 0

                let destRomfs = targetGameFolder.appendingPathComponent("romfs.img")
                if let romfs = romfsURL, resolvedRomfsSize > 0 {
                    let existingDestSize = (try? fm.attributesOfItem(atPath: destRomfs.path)[.size] as? Int64) ?? 0
                    if existingDestSize != resolvedRomfsSize {
                        if fm.fileExists(atPath: destRomfs.path) {
                            try? fm.removeItem(at: destRomfs)
                        }
                        try? fm.copyItem(at: romfs, to: destRomfs)
                    }
                }

                // Manifest
                let manifest = NxHubGameItem(
                    titleId: titleId,
                    name: game.name,
                    displayVersion: game.versionString ?? "1.0.0",
                    romfsSize: resolvedRomfsSize,
                    hasPatch: false,
                    hasDLC: false,
                    isSwitch2: game.name.contains("Switch 2") || game.name.contains("NUP"),
                    storageLocation: .internalContainer,
                    launchSettings: NxHubGameSettings(),
                    hasSave: false
                )
                if let data = try? JSONEncoder().encode(manifest) {
                    try? data.write(to: targetGameFolder.appendingPathComponent("manifest.json"))
                }

                // Locate and copy existing save if available (resolving .dmsync archives cleanly)
                if let saveSource = SaveSyncService.shared.locateExistingSave(titleId: titleId, gameName: game.name) {
                    let destSave = targetGameFolder.appendingPathComponent("save", isDirectory: true)
                    var saveIsDir: ObjCBool = false
                    if fm.fileExists(atPath: saveSource.path, isDirectory: &saveIsDir), saveIsDir.boolValue {
                        if !fm.fileExists(atPath: destSave.path) {
                            try? fm.copyItem(at: saveSource, to: destSave)
                        }
                    } else if saveSource.lastPathComponent.hasSuffix(".dmsync") {
                        SaveSyncService.shared.unpackDMSync(at: saveSource, into: destSave)
                        let destArchive = targetGameFolder.appendingPathComponent("save.dmsync")
                        if fm.fileExists(atPath: destArchive.path) {
                            try? fm.removeItem(at: destArchive)
                        }
                        try? fm.copyItem(at: saveSource, to: destArchive)
                    }
                }
            }

            // Write setup instructions
            let instructions = """
            ================================================================================
            Instruções de Configuração de Jogos para NxN Launcher no iOS / iPadOS
            ================================================================================

            O NxN Launcher utiliza armazenamento desacoplado para seus jogos, permitindo
            adicionar DLCs, atualizações e novos jogos sem nunca precisar re-assinar o app!

            COMO UTILIZAR OS ARQUIVOS:

            OPÇÃO A - Armazenamento Interno do iPhone / iPad (via App Arquivos):
            1. Abra o app "Arquivos" no seu iPhone ou iPad.
            2. Toque em "No Meu iPhone" (ou "No Meu iPad").
            3. Localize a pasta do aplicativo "NxN Launcher".
            4. Copie a pasta "games" inteira gerada aqui para dentro da pasta "NxN Launcher".
            5. Pronto! Ao abrir o NxN Launcher, todos os seus jogos estarão prontos para jogar!

            OPÇÃO B - Jogar Direto de um Pendrive / SSD USB-C Externo (iPad ou iPhone 15+ Pro):
            1. Conecte este pendrive ou SSD USB-C diretamente no seu iPhone ou iPad.
            2. Abra o NxN Launcher.
            3. No menu lateral, acesse Arquivos / Storage e selecione esta unidade externa.
            4. Seus jogos carregarão diretamente da unidade externa, sem ocupar espaço interno!
            ================================================================================
            """
            let instructionsURL = destinationFolderURL.appendingPathComponent("README_NXN_LAUNCHER_IOS.txt")
            try? instructions.write(to: instructionsURL, atomically: true, encoding: .utf8)

            DispatchQueue.main.async {
                completion(true, "Dados de \(games.count) jogo(s) exportados com sucesso para \(destinationFolderURL.lastPathComponent)!")
            }
        }
    }
}
