import SwiftUI
import AppKit

// MARK: - Multi-Game Batch Deployment Modal for NxN Launcher (Apple Liquid Glass)
public struct NxDeploymentBatchModalView: View {
    @ObservedObject public var viewModel: AppViewModel
    @ObservedObject private var hubService = NxHubDeploymentService.shared
    @ObservedObject private var deviceService = DeviceDeploymentService.shared
    @ObservedObject private var ipaHealth = IpaHealthService.shared
    @ObservedObject private var repairCoordinator = IpaRepairDeployCoordinator.shared
    @Environment(\.dismiss) private var dismiss
    @State private var initiatedBatchOrRepair: Bool = false

    @State private var isDeploying: Bool = false
    @State private var currentBatchStatus: String = ""
    @State private var validationError: String? = nil

    public init(viewModel: AppViewModel) {
        self.viewModel = viewModel
    }

    private var availableGames: [PortedGame] {
        return viewModel.libraryGames.filter { game in
            game.platform == .ios || game.url.pathExtension.lowercased() == "ipa"
        }
    }

    private var selectedGamesList: [PortedGame] {
        return availableGames.filter { viewModel.batchSelectedGameIds.contains($0.stableId) }
    }

    private var totalSelectedSizeFormatted: String {
        let total = selectedGamesList.reduce(Int64(0)) { acc, g in
            acc + hubService.estimatedTransferSizeBytes(for: g)
        }
        return ByteCountFormatter.string(fromByteCount: total, countStyle: .file)
    }

    public var body: some View {
        VStack(spacing: 0) {
            headerBar

            if let err = validationError {
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
                .padding(.horizontal, 18)
                .padding(.top, 8)
            }

            ScrollViewReader { scrollProxy in
                ScrollView(.vertical, showsIndicators: true) {
                    VStack(spacing: 8) {
                        ForEach(Array(availableGames.enumerated()), id: \.element.id) { index, game in
                            gameRow(game: game, index: index)
                                .id("batch_row_\(index)")
                        }
                    }
                    .padding(18)
                }
                .onChange(of: viewModel.batchModalFocusIndex) { newIdx in
                    if newIdx < availableGames.count {
                        withAnimation(.spring(response: 0.3, dampingFraction: 0.8)) {
                            scrollProxy.scrollTo("batch_row_\(newIdx)", anchor: .center)
                        }
                    }
                }
            }
            .frame(maxHeight: 380)

            footerBar
        }
        .frame(width: 560)
        .background(NXTheme.canvasObsidian)
        .cornerRadius(18)
        .overlay(
            RoundedRectangle(cornerRadius: 18)
                .strokeBorder(NXTheme.borderSubtle, lineWidth: 1)
        )
        .onAppear {
            viewModel.batchModalFocusIndex = 0
            // Select all games by default for convenience
            let allIds = Set(availableGames.map { $0.stableId })
            if viewModel.batchSelectedGameIds.isEmpty {
                viewModel.batchSelectedGameIds = allIds
            } else {
                viewModel.batchSelectedGameIds = viewModel.batchSelectedGameIds.intersection(allIds)
                if viewModel.batchSelectedGameIds.isEmpty {
                    viewModel.batchSelectedGameIds = allIds
                }
            }
            deviceService.refreshDevicesAndTeams()
            ipaHealth.inspectBatchAsync(games: availableGames)
        }
        .onChange(of: availableGames.map { $0.stableId }) { newIds in
            let validSet = Set(newIds)
            viewModel.batchSelectedGameIds = viewModel.batchSelectedGameIds.intersection(validSet)
            if viewModel.batchSelectedGameIds.isEmpty && !validSet.isEmpty {
                viewModel.batchSelectedGameIds = validSet
            }
            ipaHealth.inspectBatchAsync(games: availableGames)
        }
        .onReceive(NotificationCenter.default.publisher(for: .nxBatchModalExecute)) { note in
            guard let btn = note.object as? Int else { return }
            guard !selectedGamesList.isEmpty, !isDeploying, !repairCoordinator.isRepairing else { return }
            switch btn {
            case 1:
                startExportGameData()
            case 2:
                startExportIPA()
            case 3:
                startMultiPortDeployment()
            default:
                break
            }
        }
        .onChange(of: deviceService.activeDeployment.isRunning) { isRunning in
            if isRunning && initiatedBatchOrRepair {
                dismiss()
            }
        }
    }

    private var failingSelectedGames: [PortedGame] {
        selectedGamesList.filter { ipaHealth.cachedReport(for: $0)?.hasIpaDefect == true }
    }

    private var headerBar: some View {
        HStack(spacing: 12) {
            Image(systemName: "square.stack.3d.up.fill")
                .font(.system(size: 16))
                .foregroundColor(NXTheme.modalIconColor)

            VStack(alignment: .leading, spacing: 2) {
                Text(L10n.t("nxn_launcher.batch_modal_title"))
                    .font(.system(size: 14, weight: .bold))
                    .foregroundColor(NXTheme.textPrimary)
                Text(L10n.t("nxn_launcher.batch_modal_subtitle"))
                    .font(.system(size: 11))
                    .foregroundColor(NXTheme.modalDescription)
            }

            Spacer()

            Button(action: {
                if selectedGamesList.count == availableGames.count {
                    viewModel.batchSelectedGameIds.removeAll()
                } else {
                    viewModel.batchSelectedGameIds = Set(availableGames.map { $0.stableId })
                }
            }) {
                Text(selectedGamesList.count == availableGames.count ? L10n.t("nxn_launcher.deselect_all") : L10n.t("nxn_launcher.select_all"))
                    .font(.system(size: 11, weight: .medium))
                    .foregroundColor(NXTheme.modalIconColor)
            }
            .buttonStyle(.plain)

            NXModalCloseButton(size: 28) {
                viewModel.showNxDeploymentBatchModal = false
                dismiss()
            }
        }
        .padding(.horizontal, 18)
        .padding(.vertical, 14)
        .background(NXTheme.glassSurfaceElevated.opacity(0.85))
    }

    private func gameRow(game: PortedGame, index: Int) -> some View {
        let isSelected = viewModel.batchSelectedGameIds.contains(game.stableId)
        let isRowFocused = viewModel.batchModalFocusIndex == index
        return HStack(spacing: 12) {
            Button(action: {
                viewModel.batchModalFocusIndex = index
                if isSelected {
                    viewModel.batchSelectedGameIds.remove(game.stableId)
                } else {
                    viewModel.batchSelectedGameIds.insert(game.stableId)
                }
            }) {
                Image(systemName: isSelected ? "checkmark.circle.fill" : "circle")
                    .font(.system(size: 18))
                    .foregroundColor(isSelected ? NXTheme.primary : NXTheme.textSecondary)
            }
            .buttonStyle(.plain)

            VStack(alignment: .leading, spacing: 2) {
                Text(game.name)
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundColor(NXTheme.textPrimary)
                Text("ID: \(game.titleId ?? "N/A")  ·  \(L10n.t("about.version")): \(game.versionString ?? "1.0.0")")
                    .font(.system(size: 10, design: .monospaced))
                    .foregroundColor(NXTheme.modalDescription)
            }

            Spacer()

            IpaHealthBadgeView(report: ipaHealth.cachedReport(for: game))

            if SaveSyncService.shared.locateExistingSave(titleId: game.titleId ?? "", gameName: game.name) != nil {
                HStack(spacing: 4) {
                    Image(systemName: "icloud.fill")
                        .font(.system(size: 10))
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
        .padding(10)
        .background(isSelected ? NXTheme.primary.opacity(0.08) : NXTheme.glassSurfaceElevated.opacity(0.4))
        .cornerRadius(10)
        .overlay(
            RoundedRectangle(cornerRadius: 10)
                .strokeBorder(isSelected ? NXTheme.primary.opacity(0.3) : Color.clear, lineWidth: 1)
        )
        .nxConsoleFocusRing(in: RoundedRectangle(cornerRadius: 10, style: .continuous), isFocused: isRowFocused)
        .onTapGesture {
            viewModel.batchModalFocusIndex = index
        }
    }

    private var footerBar: some View {
        VStack(spacing: 10) {
            if repairCoordinator.isRepairing {
                IpaRepairProgressCard()
            } else if !failingSelectedGames.isEmpty && !isDeploying {
                let detailLines = failingSelectedGames.compactMap { g -> String? in
                    guard let report = ipaHealth.cachedReport(for: g),
                          let issue = report.issues.first(where: { $0.requiresIpaRebuild }) else { return nil }
                    return "• \(g.name): \(issue.localizedSummary)"
                }
                IpaRepairWarningBanner(
                    title: L10n.t("ipa_health.warn_title_multi", failingSelectedGames.count),
                    subtitle: L10n.t("ipa_health.warn_subtitle_multi"),
                    detailLines: detailLines,
                    actionTitle: L10n.t("ipa_health.action_repair_deploy_multi", failingSelectedGames.count),
                    errorMessage: repairCoordinator.lastErrorMessage,
                    isCritical: failingSelectedGames.contains { ipaHealth.cachedReport(for: $0)?.isUnusableArchive == true },
                    isActionDisabled: repairCoordinator.isRepairing || viewModel.isBuilding
                ) {
                    initiatedBatchOrRepair = true
                    validationError = nil
                    repairCoordinator.startRepairAndDeploy(
                        target: .multiPort(selectedGames: selectedGamesList, failingGames: failingSelectedGames),
                        viewModel: viewModel,
                        device: deviceService.selectedDevice,
                        team: deviceService.selectedSigningTeam
                    ) { ok, msg in
                        DispatchQueue.main.async {
                            if !ok && !msg.isEmpty {
                                self.validationError = msg
                            } else if ok && self.deviceService.selectedDevice == nil && !msg.isEmpty {
                                self.currentBatchStatus = msg
                            }
                            self.ipaHealth.inspectBatchAsync(games: self.availableGames)
                        }
                    }
                }
            }

            if !currentBatchStatus.isEmpty {
                HStack(spacing: 8) {
                    ProgressView().scaleEffect(0.6).frame(width: 14, height: 14)
                    Text(currentBatchStatus)
                        .font(.system(size: 11, weight: .medium))
                        .foregroundColor(NXTheme.secondary)
                    Spacer()
                }
                .padding(.horizontal, 4)
            }

            if let infoMsg = repairCoordinator.lastInfoMessage, !infoMsg.isEmpty, failingSelectedGames.isEmpty {
                IpaInfoStatusBanner(message: infoMsg) {
                    repairCoordinator.lastInfoMessage = nil
                }
            }

            HStack(spacing: 10) {
                VStack(alignment: .leading, spacing: 2) {
                    Text(L10n.t("nxn_launcher.selected_count_format", selectedGamesList.count, availableGames.count))
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundColor(NXTheme.textPrimary)
                    Text(L10n.t("nxn_launcher.total_size_format", totalSelectedSizeFormatted))
                        .font(.system(size: 10))
                        .foregroundColor(NXTheme.modalDescription)
                }

                Spacer()

                let footerStart = availableGames.count

                Button(L10n.t("common.cancel")) {
                    viewModel.showNxDeploymentBatchModal = false
                    dismiss()
                }
                .buttonStyle(.plain)
                .foregroundColor(NXTheme.textSecondary)
                .padding(.horizontal, 10)
                .padding(.vertical, 6)
                .nxConsoleFocusRing(in: RoundedRectangle(cornerRadius: 8, style: .continuous), isFocused: viewModel.batchModalFocusIndex == footerStart)

                // Export RomFS & Data button
                Button(action: startExportGameData) {
                    HStack(spacing: 5) {
                        Image(systemName: "folder.badge.gearshape")
                            .font(.system(size: 11))
                        Text(L10n.t("nxn_launcher.export_data_btn"))
                            .font(.system(size: 11, weight: .semibold))
                    }
                    .foregroundColor(NXTheme.textPrimary)
                    .padding(.horizontal, 10)
                    .padding(.vertical, 7)
                    .background(NXTheme.glassSurfaceElevated)
                    .cornerRadius(8)
                    .overlay(RoundedRectangle(cornerRadius: 8).strokeBorder(NXTheme.borderSubtle, lineWidth: 1))
                }
                .buttonStyle(.plain)
                .disabled(selectedGamesList.isEmpty || isDeploying || repairCoordinator.isRepairing)
                .nxConsoleFocusRing(in: RoundedRectangle(cornerRadius: 8, style: .continuous), isFocused: viewModel.batchModalFocusIndex == footerStart + 1)

                // Export .ipa Multi-Game button
                Button(action: startExportIPA) {
                    HStack(spacing: 5) {
                        Image(systemName: "arrow.down.doc.fill")
                            .font(.system(size: 11))
                        Text(L10n.t("nxn_launcher.export_ipa_btn"))
                            .font(.system(size: 11, weight: .semibold))
                    }
                    .foregroundColor(NXTheme.textPrimary)
                    .padding(.horizontal, 10)
                    .padding(.vertical, 7)
                    .background(NXTheme.glassSurfaceElevated)
                    .cornerRadius(8)
                    .overlay(RoundedRectangle(cornerRadius: 8).strokeBorder(NXTheme.secondary, lineWidth: 1))
                }
                .buttonStyle(.plain)
                .disabled(selectedGamesList.isEmpty || isDeploying || repairCoordinator.isRepairing)
                .nxConsoleFocusRing(in: RoundedRectangle(cornerRadius: 8, style: .continuous), isFocused: viewModel.batchModalFocusIndex == footerStart + 2)

                // Send to Connected Device
                Button(action: startMultiPortDeployment) {
                    HStack(spacing: 6) {
                        if isDeploying {
                            ProgressView()
                                .scaleEffect(0.6)
                                .frame(width: 14, height: 14)
                        } else {
                            Image(systemName: "arrow.up.forward.app.fill")
                                .font(.system(size: 12))
                        }
                        Text(isDeploying ? L10n.t("nxn_launcher.sending_progress_format", 1, max(1, selectedGamesList.count)) : L10n.t("nxn_launcher.install_on_device_btn"))
                            .font(.system(size: 11, weight: .bold))
                    }
                    .foregroundColor(.white)
                    .padding(.horizontal, 12)
                    .padding(.vertical, 7)
                    .background(selectedGamesList.isEmpty ? Color.gray.opacity(0.4) : NXTheme.primary)
                    .cornerRadius(8)
                }
                .buttonStyle(.plain)
                .disabled(selectedGamesList.isEmpty || isDeploying || repairCoordinator.isRepairing)
                .nxConsoleFocusRing(in: RoundedRectangle(cornerRadius: 8, style: .continuous), isFocused: viewModel.batchModalFocusIndex == footerStart + 3)
            }
        }
        .padding(.horizontal, 18)
        .padding(.vertical, 12)
        .background(NXTheme.glassSurfaceElevated.opacity(0.85))
    }

    private func startExportIPA() {
        guard !selectedGamesList.isEmpty else { return }
        let panel = NSSavePanel()
        panel.title = "Salvar Pacote IPA do NxN Launcher (Multi-Port)"
        panel.nameFieldStringValue = "NxN_Launcher.ipa"
        panel.allowedContentTypes = [.init(filenameExtension: "ipa")!]
        panel.canCreateDirectories = true

        if panel.runModal() == .OK, let url = panel.url {
            isDeploying = true
            currentBatchStatus = "Preparando exportação do IPA Multi-Port..."
            let teamId = deviceService.selectedSigningTeam?.id ?? ""

            hubService.exportBatchIPA(
                games: selectedGamesList,
                outputIPAURL: url,
                teamId: teamId,
                onProgress: { status, fraction in
                    DispatchQueue.main.async {
                        self.currentBatchStatus = status
                    }
                },
                completion: { success, msg in
                    DispatchQueue.main.async {
                        self.isDeploying = false
                        if success {
                            SoundEffectService.shared.play(.click)
                            self.validationError = nil
                            self.dismiss()
                            NSWorkspace.shared.activateFileViewerSelecting([url])
                        } else {
                            SoundEffectService.shared.play(.error)
                            self.validationError = msg
                        }
                    }
                }
            )
        }
    }

    private func startExportGameData() {
        guard !selectedGamesList.isEmpty else { return }
        let panel = NSOpenPanel()
        panel.title = "Selecionar Pasta de Destino ou Unidade USB-C Externa"
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.canCreateDirectories = true
        panel.prompt = "Exportar Dados para iOS"

        if panel.runModal() == .OK, let url = panel.url {
            isDeploying = true
            currentBatchStatus = "Exportando arquivos de jogos..."

            hubService.exportBatchGameData(
                games: selectedGamesList,
                destinationFolderURL: url,
                onProgress: { status, fraction in
                    DispatchQueue.main.async {
                        self.currentBatchStatus = status
                    }
                },
                completion: { success, msg in
                    DispatchQueue.main.async {
                        self.isDeploying = false
                        if success {
                            SoundEffectService.shared.play(.click)
                            self.validationError = nil
                            self.dismiss()
                            NSWorkspace.shared.activateFileViewerSelecting([url.appendingPathComponent("games")])
                        } else {
                            SoundEffectService.shared.play(.error)
                            self.validationError = msg
                        }
                    }
                }
            )
        }
    }

    private func startMultiPortDeployment() {
        guard let device = deviceService.selectedDevice else {
            validationError = "Nenhum dispositivo iOS conectado selecionado."
            return
        }
        guard !selectedGamesList.isEmpty else { return }

        isDeploying = true
        validationError = nil

        hubService.validateDeviceStorage(for: selectedGamesList, on: device) { ok, msg in
            if !ok {
                self.isDeploying = false
                self.validationError = msg
                return
            }

            self.dismiss()
            // Dispatch batch deployment through DeviceDeploymentService active sheet
            self.hubService.deployBatchToHub(
                games: self.selectedGamesList,
                device: device,
                team: self.deviceService.selectedSigningTeam,
                onProgress: { current, total, status in
                    DispatchQueue.main.async {
                        DeviceDeploymentService.shared.activeDeployment.statusMessage = status
                        DeviceDeploymentService.shared.activeDeployment.progressFraction = Double(current) / Double(total)
                    }
                },
                completion: { success, finalMsg in
                    DispatchQueue.main.async {
                        if success {
                            SoundEffectService.shared.play(.click)
                        } else {
                            SoundEffectService.shared.play(.error)
                        }
                    }
                }
            )
        }
    }
}
