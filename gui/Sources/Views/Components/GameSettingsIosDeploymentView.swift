import SwiftUI
import AppKit

public enum IosDeploymentTab: Int, CaseIterable, Identifiable {
    case singleGame = 0
    case multiPort = 1

    public var id: Int { rawValue }
}

public struct GameSettingsIosDeploymentView: View {
    public let game: PortedGame
    public var viewModel: AppViewModel? = nil

    @ObservedObject internal var deviceService = DeviceDeploymentService.shared
    @ObservedObject internal var deploymentTracker = IosDeploymentTracker.shared
    @ObservedObject internal var hubService = NxHubDeploymentService.shared
    @ObservedObject internal var ipaHealth = IpaHealthService.shared
    @ObservedObject internal var repairCoordinator = IpaRepairDeployCoordinator.shared
    @State internal var staleHubGames: [NxHubDeploymentService.StaleHubGameEntry] = []
    @State internal var isUpdatingStaleHub: Bool = false
    @State internal var staleHubStatusMessage: String? = nil

    private var selectedTab: IosDeploymentTab {
        viewModel?.iosDeploymentTab ?? .singleGame
    }

    // MARK: - Single Game State
    @State internal var showDeployLogs: Bool = false
    @State internal var showCustomSigning: Bool = false
    @State internal var p12Path: String = ""
    @State internal var p12Password: String = ""
    @State internal var mobileprovisionPath: String = ""
    @State internal var importMessage: String? = nil
    @State internal var isImportingCert: Bool = false
    @State internal var isSyncingConfig: Bool = false
    @State internal var configSyncFeedback: (isError: Bool, text: String)? = nil

    // MARK: - Multi-Port State
    @State private var selectedMultiPortGameIds: Set<String> = []
    @State private var isMultiPortDeploying: Bool = false
    @State private var multiPortStatus: String = ""
    @State private var multiPortValidationError: String? = nil
    @State private var multiPortSuccessMessage: String? = nil
    @State private var multiPortCurrentGameIndex: Int = 0
    @State private var multiPortTotalGamesCount: Int = 0

    internal var hasExternalRomfs: Bool {
        hubService.hasExternalRomfsAsset(for: game)
    }

    public init(game: PortedGame, viewModel: AppViewModel? = nil) {
        self.game = game
        self.viewModel = viewModel
    }

    internal var availableIpaGames: [PortedGame] {
        let all = viewModel?.libraryGames ?? [game]
        let filtered = all.filter { g in
            g.platform == .ios || g.url.pathExtension.lowercased() == "ipa"
        }
        if filtered.isEmpty, game.platform == .ios {
            return [game]
        }
        return filtered
    }

    internal var selectedMultiPortGames: [PortedGame] {
        return availableIpaGames.filter { selectedMultiPortGameIds.contains($0.stableId) }
    }

    private var totalSelectedSizeFormatted: String {
        let total = selectedMultiPortGames.reduce(Int64(0)) { acc, g in
            acc + hubService.estimatedTransferSizeBytes(for: g)
        }
        return ByteCountFormatter.string(fromByteCount: total, countStyle: .file)
    }

    public var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            if selectedTab == .singleGame {
                singleGameContent
            } else {
                multiPortContent
            }
        }
        .padding(14)
        .nxGlassCard(cornerRadius: 14)
        .onAppear {
            if deviceService.connectedDevices.isEmpty || deviceService.signingTeams.isEmpty {
                deviceService.refreshDevicesAndTeams()
            }
            deviceService.syncInstalledApps(with: [game])
            if mobileprovisionPath.isEmpty, let saved = UserDefaults.standard.string(forKey: "NXNative_SavedCustomProvisioningProfilePath") {
                mobileprovisionPath = saved
            }
            let allIds = Set(availableIpaGames.map { $0.stableId })
            if selectedMultiPortGameIds.isEmpty {
                selectedMultiPortGameIds = allIds
            } else {
                selectedMultiPortGameIds = selectedMultiPortGameIds.intersection(allIds)
                if selectedMultiPortGameIds.isEmpty {
                    selectedMultiPortGameIds = allIds
                }
            }
            refreshIpaHealthAndHubState()
        }
        .onChange(of: hubService.deploymentMode) { _ in
            refreshStaleHubList()
        }
        .onChange(of: game.stableId) { _ in
            refreshIpaHealthAndHubState()
        }
        .onChange(of: availableIpaGames.map { $0.stableId }) { newIds in
            let validSet = Set(newIds)
            selectedMultiPortGameIds = selectedMultiPortGameIds.intersection(validSet)
            if selectedMultiPortGameIds.isEmpty && !validSet.isEmpty {
                selectedMultiPortGameIds = validSet
            }
            refreshIpaHealthAndHubState()
        }
        .onChange(of: deviceService.connectedDevices.count) { count in
            if count > 0 {
                repairCoordinator.lastInfoMessage = nil
            }
        }
        .onChange(of: repairCoordinator.isRepairing) { repairing in
            if !repairing {
                refreshIpaHealthAndHubState()
            }
        }
    }

    // MARK: - Tab 1: Single Game Content
    @ViewBuilder
    private var singleGameContent: some View {
        VStack(alignment: .leading, spacing: 14) {
            headerBar

            // Deployment Target Mode Picker (NxN Launcher vs Standalone)
            HStack(spacing: 10) {
                Label(L10n.t("nxn_launcher.target_label"), systemImage: "target")
                    .font(.system(size: 11, weight: .bold))
                    .foregroundColor(NXTheme.textSecondary)

                NXLiquidSegmentedPicker(
                    selection: $hubService.deploymentMode,
                    options: [
                        NXSegmentOption(
                            value: NxDeploymentTargetMode.consoleHub,
                            title: L10n.t("nxn_launcher.mode_hub_title"),
                            icon: "square.stack.3d.up.fill"
                        ),
                        NXSegmentOption(
                            value: NxDeploymentTargetMode.standalone,
                            title: L10n.t("nxn_launcher.mode_standalone_title"),
                            icon: "iphone.gen3"
                        )
                    ]
                )
            }
            .padding(.horizontal, 4)

            if repairCoordinator.isRepairing {
                IpaRepairProgressCard()
            }

            let deployment = deviceService.activeDeployment
            if deployment.isRunning {
                activeDeploymentCard(deployment: deployment)
            } else if deployment.phase == .completed {
                completedCard(deployment: deployment)
            } else if deployment.phase == .failed {
                failedCard(deployment: deployment)
            }

            if !deployment.isRunning && !repairCoordinator.isRepairing {
                if let report = singleGameIpaReport, report.hasIpaDefect, deployment.phase != .failed {
                    IpaRepairWarningBanner(
                        title: L10n.t("ipa_health.warn_title_single"),
                        subtitle: L10n.t("ipa_health.warn_subtitle_single"),
                        detailLines: report.issues.filter { $0.requiresIpaRebuild }.map { "• \($0.localizedSummary)" },
                        actionTitle: L10n.t("ipa_health.action_repair_deploy_single", currentSingleModeTitle),
                        errorMessage: repairCoordinator.lastErrorMessage,
                        isCritical: report.isUnusableArchive,
                        isActionDisabled: repairCoordinator.isRepairing || (viewModel ?? AppViewModel.shared)?.isBuilding == true,
                        onRepairAndDeploy: { triggerSingleRepairAndDeploy() }
                    )
                }

                if let infoMsg = repairCoordinator.lastInfoMessage, !infoMsg.isEmpty, deployment.phase != .completed {
                    IpaInfoStatusBanner(message: infoMsg) {
                        repairCoordinator.lastInfoMessage = nil
                    }
                }

                if let record = deploymentTracker.deploymentRecord(for: game) {
                    renewalStatusCard(record: record)
                } else {
                    untrackedSideloadCard
                }
                deviceAndSigningSection
                actionSection

                if let syncMsg = configSyncFeedback {
                    HStack(spacing: 8) {
                        Image(systemName: syncMsg.isError ? "exclamationmark.triangle.fill" : "checkmark.circle.fill")
                            .font(.system(size: 12, weight: .bold))
                            .foregroundColor(syncMsg.isError ? .orange : Color(red: 0.13, green: 0.77, blue: 0.37))
                        Text(syncMsg.text)
                            .font(.system(size: 11, weight: .medium))
                            .foregroundColor(NXTheme.textPrimary)
                        Spacer()
                        Button {
                            configSyncFeedback = nil
                        } label: {
                            Image(systemName: "xmark")
                                .font(.system(size: 10, weight: .bold))
                                .foregroundColor(NXTheme.textMuted)
                        }
                        .buttonStyle(.plain)
                    }
                    .padding(9)
                    .background((syncMsg.isError ? Color.orange : Color.green).opacity(0.12))
                    .overlay(
                        RoundedRectangle(cornerRadius: 8)
                            .strokeBorder((syncMsg.isError ? Color.orange : Color.green).opacity(0.35), lineWidth: 1)
                    )
                    .cornerRadius(8)
                }
            }
        }
    }

    // MARK: - Tab 2: Multi-Port Content (NxN Launcher)
    @ViewBuilder
    private var multiPortContent: some View {
        VStack(alignment: .leading, spacing: 12) {
            if repairCoordinator.isRepairing {
                IpaRepairProgressCard()
            }

            let deployment = deviceService.activeDeployment
            if deployment.isRunning {
                activeDeploymentCard(deployment: deployment)
            } else if deployment.phase == .completed {
                completedCard(deployment: deployment)
            } else if deployment.phase == .failed {
                failedCard(deployment: deployment)
            }

            if !deployment.isRunning && !repairCoordinator.isRepairing {
                deviceAndSigningSection

                if let infoMsg = repairCoordinator.lastInfoMessage, !infoMsg.isEmpty, multiPortFailingSelectedGames.isEmpty, deployment.phase != .completed {
                    IpaInfoStatusBanner(message: infoMsg) {
                        repairCoordinator.lastInfoMessage = nil
                    }
                }
            }

            NxDeploymentModeSection()

            if let okMsg = multiPortSuccessMessage {
                HStack(spacing: 8) {
                    Image(systemName: "checkmark.seal.fill")
                        .foregroundColor(Color.green)
                    Text(okMsg)
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundColor(NXTheme.textPrimary)
                    Spacer()
                }
                .padding(10)
                .background(Color.green.opacity(0.14))
                .cornerRadius(8)
                .overlay(RoundedRectangle(cornerRadius: 8).strokeBorder(Color.green.opacity(0.35), lineWidth: 1))
            }

            if let err = multiPortValidationError {
                HStack(spacing: 8) {
                    Image(systemName: "exclamationmark.triangle.fill")
                        .foregroundColor(Color.orange)
                    Text(err)
                        .font(.system(size: 11, weight: .medium))
                        .foregroundColor(NXTheme.textPrimary)
                    Spacer()
                }
                .padding(10)
                .background(Color.orange.opacity(0.12))
                .cornerRadius(8)
            }

            // IPA Games List Header
            HStack {
                Label(L10n.t("nxn_launcher.detected_ipa_games", availableIpaGames.count), systemImage: "arrow.down.app")
                    .font(.system(size: 12, weight: .bold, design: .rounded))
                    .foregroundColor(NXTheme.textPrimary)

                Spacer()

                Button(action: {
                    if selectedMultiPortGames.count == availableIpaGames.count {
                        selectedMultiPortGameIds.removeAll()
                    } else {
                        selectedMultiPortGameIds = Set(availableIpaGames.map { $0.stableId })
                    }
                }) {
                    Text(selectedMultiPortGames.count == availableIpaGames.count ? L10n.t("nxn_launcher.deselect_all") : L10n.t("nxn_launcher.select_all"))
                        .font(.system(size: 11, weight: .medium))
                        .foregroundColor(NXTheme.modalIconColor)
                }
                .buttonStyle(.plain)
            }
            .padding(.top, 4)

            // IPA Games List (Exclusively IPAs, NO Mac ports)
            if availableIpaGames.isEmpty {
                HStack {
                    Spacer()
                    Text(L10n.t("nxn_launcher.no_ipa_games_found"))
                        .font(.system(size: 11))
                        .foregroundColor(NXTheme.modalDescription)
                    Spacer()
                }
                .padding(.vertical, 16)
            } else {
                VStack(spacing: 6) {
                    ForEach(availableIpaGames) { ipaGame in
                        multiPortGameRow(game: ipaGame)
                    }
                }
            }

            if !multiPortFailingSelectedGames.isEmpty && !isMultiPortDeploying && !deployment.isRunning && !repairCoordinator.isRepairing {
                let failing = multiPortFailingSelectedGames
                let detailLines = failing.compactMap { g -> String? in
                    guard let report = ipaHealth.cachedReport(for: g),
                          let issue = report.issues.first(where: { $0.requiresIpaRebuild }) else { return nil }
                    return "• \(g.name): \(issue.localizedSummary)"
                }
                IpaRepairWarningBanner(
                    title: L10n.t("ipa_health.warn_title_multi", failing.count),
                    subtitle: L10n.t("ipa_health.warn_subtitle_multi"),
                    detailLines: detailLines,
                    actionTitle: L10n.t("ipa_health.action_repair_deploy_multi", failing.count),
                    errorMessage: repairCoordinator.lastErrorMessage,
                    isCritical: failing.contains { ipaHealth.cachedReport(for: $0)?.isUnusableArchive == true },
                    isActionDisabled: repairCoordinator.isRepairing || (viewModel ?? AppViewModel.shared)?.isBuilding == true,
                    onRepairAndDeploy: { triggerMultiPortRepairAndDeploy() }
                )
            }

            // Multi-Port Actions Footer
            multiPortFooter
        }
    }

    private func multiPortGameRow(game: PortedGame) -> some View {
        let isSelected = selectedMultiPortGameIds.contains(game.stableId)
        return HStack(spacing: 10) {
            Button(action: {
                if isSelected {
                    selectedMultiPortGameIds.remove(game.stableId)
                } else {
                    selectedMultiPortGameIds.insert(game.stableId)
                }
            }) {
                Image(systemName: isSelected ? "checkmark.circle.fill" : "circle")
                    .font(.system(size: 16))
                    .foregroundColor(isSelected ? NXTheme.primary : NXTheme.textSecondary)
            }
            .buttonStyle(.plain)

            VStack(alignment: .leading, spacing: 2) {
                Text(game.name)
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundColor(NXTheme.textPrimary)
                Text("ID: \(game.titleId ?? "N/A")  ·  \(L10n.t("about.version")): \(game.versionString ?? "1.0.0")  ·  IPA")
                    .font(.system(size: 10, design: .monospaced))
                    .foregroundColor(NXTheme.modalDescription)
            }

            Spacer()

            IpaHealthBadgeView(report: ipaHealth.cachedReport(for: game))

            if SaveSyncService.shared.locateExistingSave(titleId: game.titleId ?? "", gameName: game.name) != nil {
                HStack(spacing: 4) {
                    Image(systemName: "icloud.fill")
                        .font(.system(size: 9))
                        .foregroundColor(NXTheme.secondary)
                    Text(L10n.t("nxn_launcher.save_icloud_badge"))
                        .font(.system(size: 9, weight: .medium))
                        .foregroundColor(NXTheme.secondary)
                }
                .padding(.horizontal, 6)
                .padding(.vertical, 2)
                .background(NXTheme.secondary.opacity(0.12))
                .cornerRadius(4)
            }
        }
        .padding(8)
        .background(isSelected ? NXTheme.primary.opacity(0.08) : NXTheme.glassSurfaceElevated.opacity(0.35))
        .cornerRadius(8)
        .overlay(
            RoundedRectangle(cornerRadius: 8)
                .strokeBorder(isSelected ? NXTheme.primary.opacity(0.3) : Color.clear, lineWidth: 1)
        )
    }

    private var multiPortFooter: some View {
        VStack(spacing: 10) {
            HStack(spacing: 8) {
                VStack(alignment: .leading, spacing: 2) {
                    Text(L10n.t("nxn_launcher.selected_count_format", selectedMultiPortGames.count, availableIpaGames.count))
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundColor(NXTheme.textPrimary)
                    Text(L10n.t("nxn_launcher.total_size_format", totalSelectedSizeFormatted))
                        .font(.system(size: 10))
                        .foregroundColor(NXTheme.modalDescription)
                }

                Spacer()

                // Export RomFS & Data button
                Button(action: startExportGameData) {
                    HStack(spacing: 4) {
                        Image(systemName: "folder.badge.gearshape")
                            .font(.system(size: 11))
                        Text(L10n.t("nxn_launcher.export_data_btn"))
                            .font(.system(size: 11, weight: .semibold))
                    }
                    .foregroundColor(NXTheme.textPrimary)
                    .padding(.horizontal, 10)
                    .padding(.vertical, 6)
                    .background(NXTheme.glassSurfaceElevated)
                    .cornerRadius(8)
                    .overlay(RoundedRectangle(cornerRadius: 8).strokeBorder(NXTheme.borderSubtle, lineWidth: 1))
                }
                .buttonStyle(.plain)
                .disabled(selectedMultiPortGames.isEmpty || isMultiPortDeploying || repairCoordinator.isRepairing)
                .help(L10n.t("nxn_launcher.export_data_help"))

                // Export .ipa Multi-Port button
                Button(action: startExportIPA) {
                    HStack(spacing: 4) {
                        Image(systemName: "arrow.down.doc.fill")
                            .font(.system(size: 11))
                        Text(L10n.t("nxn_launcher.export_ipa_btn"))
                            .font(.system(size: 11, weight: .semibold))
                    }
                    .foregroundColor(NXTheme.textPrimary)
                    .padding(.horizontal, 10)
                    .padding(.vertical, 6)
                    .background(NXTheme.glassSurfaceElevated)
                    .cornerRadius(8)
                    .overlay(RoundedRectangle(cornerRadius: 8).strokeBorder(NXTheme.secondary, lineWidth: 1))
                }
                .buttonStyle(.plain)
                .disabled(selectedMultiPortGames.isEmpty || isMultiPortDeploying || repairCoordinator.isRepairing)
                .help(L10n.t("nxn_launcher.export_ipa_help"))

                // Send to Connected Device
                Button(action: startMultiPortDeployment) {
                    HStack(spacing: 5) {
                        if isMultiPortDeploying {
                            ProgressView()
                                .scaleEffect(0.6)
                                .frame(width: 14, height: 14)
                            Text(L10n.t("nxn_launcher.sending_progress_format", multiPortCurrentGameIndex, multiPortTotalGamesCount))
                                .font(.system(size: 11, weight: .bold))
                        } else if multiPortSuccessMessage != nil {
                            Image(systemName: "checkmark")
                                .font(.system(size: 11, weight: .bold))
                            Text(L10n.t("nxn_launcher.reinstall_btn"))
                                .font(.system(size: 11, weight: .bold))
                        } else if multiPortValidationError != nil {
                            Image(systemName: "arrow.clockwise")
                                .font(.system(size: 11, weight: .bold))
                            Text(L10n.t("build.try_again"))
                                .font(.system(size: 11, weight: .bold))
                        } else {
                            Image(systemName: "arrow.up.forward.app.fill")
                                .font(.system(size: 11))
                            Text(L10n.t("nxn_launcher.install_on_device_btn"))
                                .font(.system(size: 11, weight: .bold))
                        }
                    }
                    .foregroundColor(.white)
                    .padding(.horizontal, 12)
                    .padding(.vertical, 6)
                    .background(
                        selectedMultiPortGames.isEmpty
                            ? Color.gray.opacity(0.4)
                            : (multiPortSuccessMessage != nil
                                ? Color.green.opacity(0.85)
                                : (multiPortValidationError != nil ? Color.orange.opacity(0.9) : NXTheme.primary))
                    )
                    .cornerRadius(8)
                }
                .buttonStyle(.plain)
                .disabled(selectedMultiPortGames.isEmpty || isMultiPortDeploying || repairCoordinator.isRepairing)
                .help(L10n.t("nxn_launcher.install_on_device_help"))
            }
        }
        .padding(10)
        .background(NXTheme.glassSurfaceElevated.opacity(0.6))
        .cornerRadius(10)
    }

    private func startExportIPA() {
        guard !selectedMultiPortGames.isEmpty else { return }
        let panel = NSSavePanel()
        panel.title = "Salvar Pacote IPA do NxN Launcher (Multi-Port)"
        panel.nameFieldStringValue = "NxN_Launcher.ipa"
        panel.allowedContentTypes = [.init(filenameExtension: "ipa")!]
        panel.canCreateDirectories = true

        if panel.runModal() == .OK, let url = panel.url {
            isMultiPortDeploying = true
            multiPortValidationError = nil
            multiPortSuccessMessage = nil
            multiPortStatus = "Preparando exportação do IPA Multi-Port..."
            DeviceDeploymentService.shared.activeDeployment = DeploymentProgressInfo(
                phase: .compiling,
                progressFraction: 0.05,
                statusMessage: multiPortStatus,
                detailMessage: url.lastPathComponent,
                logLines: ["==> \(multiPortStatus)"],
                isRunning: true
            )
            DeviceDeploymentService.shared.startElapsedTimer()
            let teamId = deviceService.selectedSigningTeam?.id ?? ""

            hubService.exportBatchIPA(
                games: selectedMultiPortGames,
                outputIPAURL: url,
                teamId: teamId,
                onProgress: { status, fraction in
                    DispatchQueue.main.async {
                        self.multiPortStatus = status
                        DeviceDeploymentService.shared.activeDeployment.statusMessage = status
                        DeviceDeploymentService.shared.activeDeployment.progressFraction = max(0.05, min(0.99, fraction))
                        DeviceDeploymentService.shared.activeDeployment.logLines.append(status)
                    }
                },
                completion: { success, msg in
                    DispatchQueue.main.async {
                        self.isMultiPortDeploying = false
                        DeviceDeploymentService.shared.activeDeployment.isRunning = false
                        DeviceDeploymentService.shared.stopElapsedTimer()
                        if success {
                            SoundEffectService.shared.play(.click)
                            self.multiPortValidationError = nil
                            self.multiPortSuccessMessage = msg
                            DeviceDeploymentService.shared.activeDeployment.phase = .completed
                            DeviceDeploymentService.shared.activeDeployment.progressFraction = 1.0
                            DeviceDeploymentService.shared.activeDeployment.statusMessage = msg
                            DeviceDeploymentService.shared.activeDeployment.logLines.append("[SUCCESS] \(msg)")
                            NSWorkspace.shared.activateFileViewerSelecting([url])
                        } else {
                            SoundEffectService.shared.play(.error)
                            self.multiPortValidationError = msg
                            DeviceDeploymentService.shared.activeDeployment.phase = .failed
                            DeviceDeploymentService.shared.activeDeployment.statusMessage = msg
                            DeviceDeploymentService.shared.activeDeployment.logLines.append("[ERROR] \(msg)")
                        }
                    }
                }
            )
        }
    }

    private func startExportGameData() {
        guard !selectedMultiPortGames.isEmpty else { return }
        let panel = NSOpenPanel()
        panel.title = "Selecionar Pasta de Destino ou Unidade USB-C Externa"
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.canCreateDirectories = true
        panel.prompt = "Exportar Dados para iOS"

        if panel.runModal() == .OK, let url = panel.url {
            isMultiPortDeploying = true
            multiPortValidationError = nil
            multiPortSuccessMessage = nil
            multiPortStatus = "Exportando arquivos de jogos Multi-Port..."
            DeviceDeploymentService.shared.activeDeployment = DeploymentProgressInfo(
                phase: .copyingRomFS,
                progressFraction: 0.05,
                statusMessage: multiPortStatus,
                detailMessage: url.path,
                logLines: ["==> \(multiPortStatus)"],
                isRunning: true
            )
            DeviceDeploymentService.shared.startElapsedTimer()

            hubService.exportBatchGameData(
                games: selectedMultiPortGames,
                destinationFolderURL: url,
                onProgress: { status, fraction in
                    DispatchQueue.main.async {
                        self.multiPortStatus = status
                        DeviceDeploymentService.shared.activeDeployment.statusMessage = status
                        DeviceDeploymentService.shared.activeDeployment.progressFraction = max(0.05, min(0.99, fraction))
                        DeviceDeploymentService.shared.activeDeployment.logLines.append(status)
                    }
                },
                completion: { success, msg in
                    DispatchQueue.main.async {
                        self.isMultiPortDeploying = false
                        DeviceDeploymentService.shared.activeDeployment.isRunning = false
                        DeviceDeploymentService.shared.stopElapsedTimer()
                        if success {
                            SoundEffectService.shared.play(.click)
                            self.multiPortValidationError = nil
                            self.multiPortSuccessMessage = msg
                            DeviceDeploymentService.shared.activeDeployment.phase = .completed
                            DeviceDeploymentService.shared.activeDeployment.progressFraction = 1.0
                            DeviceDeploymentService.shared.activeDeployment.statusMessage = msg
                            DeviceDeploymentService.shared.activeDeployment.logLines.append("[SUCCESS] \(msg)")
                            NSWorkspace.shared.activateFileViewerSelecting([url.appendingPathComponent("games")])
                        } else {
                            SoundEffectService.shared.play(.error)
                            self.multiPortValidationError = msg
                            DeviceDeploymentService.shared.activeDeployment.phase = .failed
                            DeviceDeploymentService.shared.activeDeployment.statusMessage = msg
                            DeviceDeploymentService.shared.activeDeployment.logLines.append("[ERROR] \(msg)")
                        }
                    }
                }
            )
        }
    }

    private func startMultiPortDeployment() {
        guard let device = deviceService.selectedDevice else {
            multiPortValidationError = "Nenhum dispositivo iOS conectado selecionado."
            return
        }
        guard !selectedMultiPortGames.isEmpty else { return }

        isMultiPortDeploying = true
        multiPortValidationError = nil
        multiPortSuccessMessage = nil
        multiPortCurrentGameIndex = 1
        multiPortTotalGamesCount = selectedMultiPortGames.count
        multiPortStatus = "Preparando NxN Launcher..."
        DeviceDeploymentService.shared.activeDeployment = DeploymentProgressInfo(
            phase: .transferring,
            progressFraction: 0.05,
            statusMessage: "Preparando NxN Launcher...",
            detailMessage: device.name,
            logLines: ["==> Preparando envio Multi-Port para \(device.name)..."],
            isRunning: true
        )
        DeviceDeploymentService.shared.startElapsedTimer()

        hubService.validateDeviceStorage(for: selectedMultiPortGames, on: device) { ok, msg in
            if !ok {
                DispatchQueue.main.async {
                    self.isMultiPortDeploying = false
                    self.multiPortValidationError = msg
                    DeviceDeploymentService.shared.activeDeployment.isRunning = false
                    DeviceDeploymentService.shared.activeDeployment.phase = .failed
                    DeviceDeploymentService.shared.activeDeployment.statusMessage = msg
                    DeviceDeploymentService.shared.activeDeployment.logLines.append("[ERROR] \(msg)")
                    DeviceDeploymentService.shared.stopElapsedTimer()
                }
                return
            }

            self.hubService.deployBatchToHub(
                games: self.selectedMultiPortGames,
                device: device,
                team: self.deviceService.selectedSigningTeam,
                onProgress: { current, total, status in
                    DispatchQueue.main.async {
                        self.multiPortCurrentGameIndex = current
                        self.multiPortTotalGamesCount = total
                        self.multiPortStatus = "[\(current)/\(total)] \(status)"
                        DeviceDeploymentService.shared.activeDeployment.statusMessage = "[\(current)/\(total)] \(status)"
                        let baseline = 0.05 + 0.30 * (Double(current - 1) / Double(max(1, total)))
                        if DeviceDeploymentService.shared.activeDeployment.progressFraction < baseline {
                            DeviceDeploymentService.shared.activeDeployment.progressFraction = baseline
                        }
                    }
                },
                completion: { success, finalMsg in
                    DispatchQueue.main.async {
                        self.isMultiPortDeploying = false
                        DeviceDeploymentService.shared.activeDeployment.isRunning = false
                        DeviceDeploymentService.shared.stopElapsedTimer()
                        if success {
                            SoundEffectService.shared.play(.click)
                            self.multiPortSuccessMessage = finalMsg
                            self.multiPortValidationError = nil
                            self.multiPortStatus = ""
                            DeviceDeploymentService.shared.activeDeployment.phase = .completed
                            DeviceDeploymentService.shared.activeDeployment.progressFraction = 1.0
                            DeviceDeploymentService.shared.activeDeployment.statusMessage = finalMsg
                        } else {
                            SoundEffectService.shared.play(.error)
                            self.multiPortValidationError = finalMsg
                            self.multiPortSuccessMessage = nil
                            self.multiPortStatus = ""
                            DeviceDeploymentService.shared.activeDeployment.phase = .failed
                            DeviceDeploymentService.shared.activeDeployment.statusMessage = finalMsg
                        }
                    }
                }
            )
        }
    }

    // MARK: - Header
    private var headerBar: some View {
        HStack(spacing: 8) {
            Label(L10n.t("settings_modal.ios_deploy_title"), systemImage: "iphone.badge.play")
                .font(.system(size: 13, weight: .bold, design: .rounded))
                .foregroundColor(NXTheme.textPrimary)

            Spacer()

            HStack(spacing: 8) {
                IpaHealthBadgeView(report: singleGameIpaReport)

                Button(action: {
                    SoundEffectService.shared.play(.click)
                    let deployURL = deviceService.resolveDeployableURL(for: game)
                    deviceService.revealInFinder(fileURL: deployURL)
                }) {
                    HStack(spacing: 4) {
                        Image(systemName: "folder")
                        Text(L10n.t("settings_modal.show_ipa"))
                            .font(.system(size: 10.5, weight: .semibold))
                    }
                }
                .buttonStyle(NXSecondaryButtonStyle())
                .controlSize(.mini)
                .help(L10n.t("settings_modal.open_ipa_folder_help"))
            }
        }
    }

    // MARK: - Device & Signing Section
    private var deviceAndSigningSection: some View {
        VStack(spacing: 8) {
            HStack(spacing: 8) {
                Image(systemName: "iphone.gen3")
                    .foregroundColor(NXTheme.primary)
                    .font(.system(size: 13))
                Text(L10n.t("settings_modal.install_on_label"))
                    .font(.system(size: 11.5, weight: .semibold))
                    .foregroundColor(NXTheme.textPrimary)

                Spacer()

                if deviceService.connectedDevices.isEmpty {
                    Text(L10n.t("settings_modal.no_devices"))
                        .font(.system(size: 11))
                        .foregroundColor(NXTheme.textSecondary)
                } else {
                    Picker("", selection: $deviceService.selectedDevice) {
                        ForEach(deviceService.connectedDevices) { dev in
                            Text("\(dev.name) (\(dev.model))").tag(Optional(dev))
                        }
                    }
                    .pickerStyle(MenuPickerStyle())
                    .frame(maxWidth: 240)

                    Circle()
                        .fill(deviceService.selectedDevice?.isAvailable == true ? Color.green : Color.orange)
                        .frame(width: 7, height: 7)
                }

                Button(action: {
                    SoundEffectService.shared.play(.click)
                    deviceService.refreshDevicesAndTeams()
                }) {
                    Image(systemName: deviceService.isDetecting ? "arrow.triangle.2.circlepath" : "arrow.clockwise")
                        .font(.system(size: 11))
                }
                .buttonStyle(NXSecondaryButtonStyle())
                .controlSize(.mini)
                .disabled(deviceService.isDetecting)
            }

            HStack(spacing: 8) {
                Image(systemName: "person.badge.shield.checkmark")
                    .foregroundColor(NXTheme.primary)
                    .font(.system(size: 13))
                Text(L10n.t("settings_modal.signing_team_label"))
                    .font(.system(size: 11.5, weight: .semibold))
                    .foregroundColor(NXTheme.textPrimary)

                Spacer()

                if deviceService.signingTeams.isEmpty {
                    Text(L10n.t("settings_modal.no_teams_found"))
                        .font(.system(size: 11))
                        .foregroundColor(NXTheme.textSecondary)
                } else {
                    Picker("", selection: $deviceService.selectedSigningTeam) {
                        Text(L10n.t("settings.ios_unsigned_sideloading")).tag(Optional<DeveloperSigningTeam>.none)
                        ForEach(deviceService.signingTeams) { team in
                            Text(team.displayName).tag(Optional(team))
                        }
                    }
                    .pickerStyle(MenuPickerStyle())
                    .frame(maxWidth: 240)
                }
            }

            // Custom Signing Identity Disclosure
            DisclosureGroup(isExpanded: $showCustomSigning) {
                VStack(alignment: .leading, spacing: 8) {
                    Text(L10n.t("settings.ios_custom_cert_desc"))
                        .font(.system(size: 10.5))
                        .foregroundColor(NXTheme.textSecondary)

                    HStack(spacing: 8) {
                        Button(L10n.t("settings.ios_select_p12")) {
                            let panel = NSOpenPanel()
                            panel.canChooseFiles = true
                            panel.canChooseDirectories = false
                            panel.prompt = "Choose .p12"
                            if panel.runModal() == .OK, let url = panel.url {
                                p12Path = url.path
                            }
                        }
                        .buttonStyle(NXSecondaryButtonStyle())
                        .controlSize(.mini)

                        if !p12Path.isEmpty {
                            HStack(spacing: 4) {
                                Text(URL(fileURLWithPath: p12Path).lastPathComponent)
                                    .font(.system(size: 10.5, design: .monospaced))
                                    .foregroundColor(NXTheme.textPrimary)
                                    .lineLimit(1)

                                Button(action: {
                                    p12Path = ""
                                    p12Password = ""
                                    importMessage = nil
                                }) {
                                    Image(systemName: "xmark.circle.fill")
                                        .foregroundColor(NXTheme.textSecondary)
                                        .font(.system(size: 11))
                                        .padding(4)
                                        .contentShape(Rectangle())
                                }
                                .buttonStyle(NXPressableButtonStyle())
                            }
                        }
                    }

                    if !p12Path.isEmpty {
                        HStack(spacing: 8) {
                            SecureField(L10n.t("settings.ios_p12_password_placeholder"), text: $p12Password)
                                .textFieldStyle(RoundedBorderTextFieldStyle())
                                .font(.system(size: 11))
                                .frame(maxWidth: 180)

                            Button(isImportingCert ? L10n.t("settings.ios_importing") : L10n.t("settings.ios_import_keychain")) {
                                isImportingCert = true
                                deviceService.importP12Certificate(fileURL: URL(fileURLWithPath: p12Path), password: p12Password) { success, msg in
                                    isImportingCert = false
                                    importMessage = msg
                                }
                            }
                            .buttonStyle(NXSecondaryButtonStyle())
                            .controlSize(.mini)
                            .disabled(isImportingCert)
                        }
                    }

                    HStack(spacing: 8) {
                        Button(L10n.t("settings.ios_select_profile")) {
                            let panel = NSOpenPanel()
                            panel.canChooseFiles = true
                            panel.canChooseDirectories = false
                            panel.prompt = "Choose Profile"
                            if panel.runModal() == .OK, let url = panel.url {
                                mobileprovisionPath = url.path
                                UserDefaults.standard.set(url.path, forKey: "NXNative_SavedCustomProvisioningProfilePath")
                            }
                        }
                        .buttonStyle(NXSecondaryButtonStyle())
                        .controlSize(.mini)

                        if !mobileprovisionPath.isEmpty {
                            HStack(spacing: 4) {
                                Text(URL(fileURLWithPath: mobileprovisionPath).lastPathComponent)
                                    .font(.system(size: 10.5, design: .monospaced))
                                    .foregroundColor(NXTheme.textPrimary)
                                    .lineLimit(1)

                                Button(action: {
                                    mobileprovisionPath = ""
                                    UserDefaults.standard.removeObject(forKey: "NXNative_SavedCustomProvisioningProfilePath")
                                }) {
                                    Image(systemName: "xmark.circle.fill")
                                        .foregroundColor(NXTheme.textSecondary)
                                        .font(.system(size: 11))
                                        .padding(4)
                                        .contentShape(Rectangle())
                                }
                                .buttonStyle(NXPressableButtonStyle())
                            }
                        }
                    }

                    if let msg = importMessage {
                        Text(msg)
                            .font(.system(size: 10))
                            .foregroundColor(msg.contains("successfully") ? Color.green : Color.orange)
                    }
                }
                .padding(.top, 4)
            } label: {
                Label(L10n.t("settings.ios_custom_cert_title"), systemImage: "signature")
                    .font(.system(size: 11, weight: .medium))
                    .foregroundColor(NXTheme.textSecondary)
            }

            HStack(spacing: 6) {
                if let team = deviceService.selectedSigningTeam {
                    if team.hasCertificateInKeychain {
                        Image(systemName: "checkmark.shield.fill")
                            .foregroundColor(Color.green)
                            .font(.system(size: 11))
                        Text(L10n.t("settings_modal.team_has_cert_notice"))
                            .font(.system(size: 10.5))
                            .foregroundColor(NXTheme.textSecondary)
                    } else {
                        Image(systemName: "info.circle.fill")
                            .foregroundColor(.orange)
                            .font(.system(size: 11))
                        Text(L10n.t("settings_modal.team_no_cert_notice"))
                            .font(.system(size: 10.5))
                            .foregroundColor(NXTheme.textSecondary)
                        Spacer()
                        Button("Xcode") {
                            deviceService.openXcodeAccounts()
                        }
                        .buttonStyle(NXSecondaryButtonStyle())
                        .controlSize(.mini)
                    }
                } else {
                    Image(systemName: "lock.open.fill")
                        .foregroundColor(NXTheme.secondary)
                        .font(.system(size: 11))
                    Text(L10n.t("settings.ios_unsigned_sideloading"))
                        .font(.system(size: 10.5))
                        .foregroundColor(NXTheme.textSecondary)
                }
                Spacer()
            }
            .padding(.horizontal, 4)
        }
        .padding(10)
        .nxGlassCard(cornerRadius: 10, isNested: true)
    }
}
