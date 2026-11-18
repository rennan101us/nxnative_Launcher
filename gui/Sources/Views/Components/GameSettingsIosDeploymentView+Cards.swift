import SwiftUI
import AppKit

// MARK: - Status Cards and Helpers for GameSettingsIosDeploymentView
extension GameSettingsIosDeploymentView {
    internal func formatSeconds(_ seconds: Int) -> String {
        let m = seconds / 60
        let s = seconds % 60
        return String(format: "%02d:%02d", m, s)
    }

    @ViewBuilder
    internal func activeDeploymentCard(deployment: DeploymentProgressInfo) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                ProgressView().controlSize(.small)
                Text(deployment.phase.rawValue)
                    .font(.system(size: 12, weight: .bold, design: .rounded))
                    .foregroundColor(NXTheme.textPrimary)

                Spacer()

                HStack(spacing: 4) {
                    Image(systemName: "stopwatch")
                    Text(formatSeconds(deployment.elapsedSeconds))
                }
                .font(.system(size: 11, weight: .semibold, design: .monospaced))
                .foregroundColor(NXTheme.textSecondary)
                .padding(.horizontal, 8)
                .padding(.vertical, 3)
                .background(NXTheme.glassSurface.opacity(0.8))
                .cornerRadius(6)
            }

            VStack(alignment: .leading, spacing: 4) {
                ProgressView(value: deployment.progressFraction, total: 1.0)
                    .accentColor(NXTheme.primary)

                HStack {
                    Text(deployment.statusMessage)
                        .font(.system(size: 11, weight: .medium))
                        .foregroundColor(NXTheme.textPrimary)
                    Spacer()
                    Text("\(Int(deployment.progressFraction * 100))%")
                        .font(.system(size: 11, weight: .bold, design: .rounded))
                        .foregroundColor(NXTheme.primary)
                }
            }

            if !deployment.detailMessage.isEmpty {
                Text(deployment.detailMessage)
                    .font(.system(size: 10))
                    .foregroundColor(NXTheme.textSecondary)
            }

            HStack {
                Button(L10n.t("settings_modal.cancel_deployment")) {
                    SoundEffectService.shared.play(.click)
                    deviceService.cancelDeployment()
                }
                .buttonStyle(NXSecondaryButtonStyle())
                .controlSize(.mini)

                Spacer()

                Button(showDeployLogs ? "Hide Logs" : "View Live Logs") {
                    withAnimation(.easeInOut(duration: 0.2)) { showDeployLogs.toggle() }
                }
                .buttonStyle(NXPressableButtonStyle())
                .font(.system(size: 10))
                .foregroundColor(NXTheme.textSecondary)
            }

            if showDeployLogs && !deployment.logLines.isEmpty {
                ScrollView {
                    VStack(alignment: .leading, spacing: 2) {
                        ForEach(Array(deployment.logLines.suffix(10).enumerated()), id: \.offset) { _, log in
                            Text(log)
                                .font(.system(size: 9, design: .monospaced))
                                .foregroundColor(Color.green.opacity(0.85))
                                .frame(maxWidth: .infinity, alignment: .leading)
                        }
                    }
                    .padding(8)
                }
                .frame(height: 80)
                .background(Color.black.opacity(0.45))
                .cornerRadius(6)
            }
        }
        .padding(12)
        .background(NXTheme.glassSurfaceElevated.opacity(0.8))
        .overlay(
            RoundedRectangle(cornerRadius: 10)
                .strokeBorder(NXTheme.primary.opacity(0.35), lineWidth: 1)
        )
        .cornerRadius(10)
    }

    @ViewBuilder
    internal func completedCard(deployment: DeploymentProgressInfo) -> some View {
        HStack(spacing: 10) {
            Image(systemName: "checkmark.circle.fill")
                .font(.system(size: 22))
                .foregroundColor(Color(red: 0.13, green: 0.77, blue: 0.37))

            VStack(alignment: .leading, spacing: 2) {
                Text(deployment.statusMessage)
                    .font(.system(size: 12, weight: .bold))
                    .foregroundColor(Color(red: 0.13, green: 0.77, blue: 0.37))
                Text(deployment.detailMessage)
                    .font(.system(size: 10))
                    .foregroundColor(NXTheme.textSecondary)
            }

            Spacer()

            Button(L10n.t("common.ok")) {
                SoundEffectService.shared.play(.click)
                deviceService.dismissDeploymentStatus()
            }
            .buttonStyle(NXSecondaryButtonStyle())
            .controlSize(.mini)
        }
        .padding(10)
        .background(Color(red: 0.13, green: 0.77, blue: 0.37).opacity(0.12))
        .cornerRadius(8)
    }

    @ViewBuilder
    internal func failedCard(deployment: DeploymentProgressInfo) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 8) {
                Image(systemName: "exclamationmark.triangle.fill")
                    .foregroundColor(.orange)
                    .font(.system(size: 16))

                Text(deployment.statusMessage)
                    .font(.system(size: 12, weight: .bold))
                    .foregroundColor(NXTheme.textPrimary)

                Spacer()

                Button(L10n.t("common.close")) {
                    SoundEffectService.shared.play(.click)
                    deviceService.dismissDeploymentStatus()
                }
                .buttonStyle(NXSecondaryButtonStyle())
                .controlSize(.mini)
            }

            Text(deployment.detailMessage)
                .font(.system(size: 11))
                .foregroundColor(NXTheme.textSecondary)
                .fixedSize(horizontal: false, vertical: true)

            let detailLower = deployment.detailMessage.lowercased()
            let hasIpaFailureReason = deployment.errorCategory == .invalidIPA
                || singleGameIpaReport?.hasIpaDefect == true
                || detailLower.contains(".ipa")
                || detailLower.contains("descompactar")
                || detailLower.contains("corromp")
                || detailLower.contains("unzip")

            if hasIpaFailureReason || deployment.errorCategory == .signatureVerificationFailed {
                VStack(alignment: .leading, spacing: 8) {
                    if hasIpaFailureReason {
                        if let err = repairCoordinator.lastErrorMessage, !err.isEmpty {
                            Text(err)
                                .font(.system(size: 11, weight: .medium))
                                .foregroundColor(.orange)
                                .fixedSize(horizontal: false, vertical: true)
                        }

                        Button(action: {
                            SoundEffectService.shared.play(.click)
                            triggerSingleRepairAndDeploy()
                        }) {
                            HStack(spacing: 6) {
                                Image(systemName: "wrench.and.screwdriver.fill")
                                Text(L10n.t("ipa_health.action_repair_deploy_single", currentSingleModeTitle))
                            }
                        }
                        .buttonStyle(NXPrimaryButtonStyle())
                        .disabled(repairCoordinator.isRepairing || (viewModel ?? AppViewModel.shared)?.isBuilding == true)
                    }

                    if deployment.errorCategory == .signatureVerificationFailed {
                        Button(action: {
                            SoundEffectService.shared.play(.click)
                            let deployURL = deviceService.resolveDeployableURL(for: game)
                            deviceService.revealInFinder(fileURL: deployURL)
                        }) {
                            HStack(spacing: 4) {
                                Image(systemName: "folder")
                                Text(L10n.t("settings_modal.open_ipa_folder"))
                            }
                        }
                        .buttonStyle(NXSecondaryButtonStyle())
                        .controlSize(.small)
                    }
                }
                .padding(.top, 4)
            }
        }
        .padding(12)
        .background(Color.orange.opacity(0.12))
        .overlay(
            RoundedRectangle(cornerRadius: 8)
                .strokeBorder(Color.orange.opacity(0.3), lineWidth: 1)
        )
        .cornerRadius(8)
    }

    // MARK: - Sideload Renewal Status Cards
    internal func renewalStatusCard(record: IosDeploymentRecord) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .center) {
                HStack(spacing: 6) {
                    Image(systemName: record.isExpired ? "exclamationmark.triangle.fill" : "clock.arrow.circlepath")
                        .foregroundColor(record.tier.tintColor)
                        .font(.system(size: 13, weight: .bold))

                    Text(L10n.t("settings.ios_sideload_status"))
                        .font(.system(size: 12, weight: .bold, design: .rounded))
                        .foregroundColor(NXTheme.textPrimary)
                }

                Spacer()

                HStack(spacing: 8) {
                    IosRenewalBadgeView(record: record)

                    Button(action: {
                        SoundEffectService.shared.play(.click)
                        deploymentTracker.clearDeployment(for: game)
                    }) {
                        Image(systemName: "trash")
                            .font(.system(size: 10.5))
                            .foregroundColor(NXTheme.textSecondary)
                            .frame(width: 16, height: 16)
                    }
                    .buttonStyle(NXSecondaryButtonStyle())
                    .controlSize(.mini)
                    .help(L10n.t("settings.ios_clear_deployment"))
                }
            }

            HStack(alignment: .center, spacing: 24) {
                VStack(alignment: .leading, spacing: 2) {
                    Text(L10n.t("settings.ios_first_deployed"))
                        .font(.system(size: 10))
                        .foregroundColor(NXTheme.textSecondary)
                    Text(record.formattedFirstDeployed)
                        .font(.system(size: 11, weight: .medium, design: .rounded))
                        .foregroundColor(NXTheme.textPrimary)
                }

                VStack(alignment: .leading, spacing: 2) {
                    Text(L10n.t("settings.ios_last_renewed"))
                        .font(.system(size: 10))
                        .foregroundColor(NXTheme.textSecondary)
                    Text(record.formattedLastDeployed)
                        .font(.system(size: 11, weight: .medium, design: .rounded))
                        .foregroundColor(NXTheme.textPrimary)
                }

                if let dev = record.targetDeviceName {
                    VStack(alignment: .leading, spacing: 2) {
                        Text(L10n.t("settings.ios_target_device"))
                            .font(.system(size: 10))
                            .foregroundColor(NXTheme.textSecondary)
                        Text(dev)
                            .font(.system(size: 11, weight: .medium, design: .rounded))
                            .foregroundColor(NXTheme.textPrimary)
                    }
                }

                Spacer()
            }
        }
        .padding(12)
        .background(record.tier.tintColor.opacity(0.08))
        .overlay(
            RoundedRectangle(cornerRadius: 10)
                .strokeBorder(record.tier.tintColor.opacity(0.3), lineWidth: 1)
        )
        .cornerRadius(10)
    }

    internal var untrackedSideloadCard: some View {
        HStack(spacing: 8) {
            Image(systemName: "iphone.badge.play")
                .foregroundColor(NXTheme.secondary)
                .font(.system(size: 13))

            Text(L10n.t("settings.ios_already_installed_prompt"))
                .font(.system(size: 11))
                .foregroundColor(NXTheme.textSecondary)

            Spacer()

            Button(action: {
                SoundEffectService.shared.play(.click)
                deploymentTracker.markAsDeployedToday(for: game, deviceName: deviceService.selectedDevice?.name)
            }) {
                HStack(spacing: 4) {
                    Image(systemName: "checkmark.circle.fill")
                    Text(L10n.t("settings.ios_mark_deployed_today"))
                        .font(.system(size: 10.5, weight: .semibold))
                }
            }
            .buttonStyle(NXSecondaryButtonStyle())
            .controlSize(.mini)
        }
        .padding(10)
        .background(NXTheme.glassSurfaceElevated.opacity(0.6))
        .cornerRadius(8)
    }

    // MARK: - Action Section
    internal var actionSection: some View {
        HStack(spacing: 12) {
            if let record = deploymentTracker.deploymentRecord(for: game) {
                IosRenewalBadgeView(record: record)
            }

            Spacer()

            Button(action: {
                guard let dev = deviceService.selectedDevice else { return }
                SoundEffectService.shared.play(.click)
                isSyncingConfig = true
                configSyncFeedback = nil
                let vm = viewModel ?? AppViewModel.shared
                let cfg = vm?.activeSettingsConfig ?? GameRuntimeConfig.load(for: game)
                cfg.save(for: game)
                vm?.runtimeConfigCache[game.uniqueKey] = cfg
                deviceService.syncConfigToIosDevice(game: game, config: cfg, device: dev) { success, msg in
                    isSyncingConfig = false
                    SoundEffectService.shared.play(success ? .click : .error)
                    if success {
                        configSyncFeedback = (false, L10n.t("settings.ios_sync_config_ok", dev.name))
                        vm?.logs.append(LogEntry(level: .success, message: msg))
                    } else {
                        configSyncFeedback = (true, L10n.t("settings.ios_sync_config_fail", msg))
                        vm?.logs.append(LogEntry(level: .warning, message: msg))
                    }
                }
            }) {
                HStack(spacing: 5) {
                    if isSyncingConfig {
                        ProgressView()
                            .scaleEffect(0.55)
                            .frame(width: 12, height: 12)
                    } else {
                        Image(systemName: "slider.horizontal.2.gobackward")
                            .font(.system(size: 11))
                    }
                    Text(L10n.t(isSyncingConfig ? "settings.ios_sync_config_syncing" : "settings.ios_sync_config_btn"))
                }
            }
            .buttonStyle(NXSecondaryButtonStyle())
            .controlSize(.small)
            .disabled(deviceService.selectedDevice == nil || deviceService.isDetecting || isSyncingConfig)
            .help(L10n.t("settings.ios_sync_config_help"))

            if hasExternalRomfs {
                Button(action: {
                    guard let dev = deviceService.selectedDevice else { return }
                    SoundEffectService.shared.play(.click)
                    let deployURL = deviceService.resolveDeployableURL(for: game)
                    deviceService.pushRomfsDirectly(gameURL: deployURL, device: dev) { _, _ in }
                }) {
                    HStack(spacing: 5) {
                        Image(systemName: "arrow.up.doc.fill")
                        Text(L10n.t("settings.ios_push_romfs_only"))
                    }
                }
                .buttonStyle(NXSecondaryButtonStyle())
                .controlSize(.small)
                .disabled(deviceService.selectedDevice == nil || deviceService.isDetecting)
            }

            if SaveSyncService.shared.locateExistingSave(titleId: game.titleId ?? "", gameName: game.name) != nil {
                Button(action: {
                    guard let dev = deviceService.selectedDevice else { return }
                    SoundEffectService.shared.play(.click)
                    let bundleId = deviceService.findBundleId(for: game.titleId ?? "", gameName: game.name, on: dev)
                        ?? game.bundleId
                        ?? "org.nxnative.\((game.titleId ?? "0100000000000000").lowercased())"
                    SaveSyncService.shared.restoreICloudSaveToDevice(
                        titleId: game.titleId ?? "",
                        gameName: game.name,
                        bundleId: bundleId,
                        device: dev
                    ) { success, _ in
                        SoundEffectService.shared.play(success ? .click : .error)
                    }
                }) {
                    HStack(spacing: 4) {
                        Image(systemName: "arrow.counterclockwise.icloud.fill")
                            .font(.system(size: 11))
                        Text(L10n.t("nxn_launcher.restore_save_btn"))
                            .font(.system(size: 11, weight: .medium))
                    }
                }
                .buttonStyle(NXSecondaryButtonStyle())
                .controlSize(.small)
                .disabled(deviceService.selectedDevice == nil || deviceService.isDetecting)
            }

            let isDeployed = deploymentTracker.isGameDeployed(game)
            let deviceTargetName = (deviceService.selectedDevice?.model.contains("iPad") == true) ? "iPad" : "iPhone"
            let buttonTitle: String = isDeployed
                ? L10n.t("settings_modal.renew_button", deviceTargetName)
                : L10n.t("settings_modal.install_button", deviceTargetName)

            if hubService.deploymentMode == .consoleHub {
                Button(action: {
                    guard let dev = deviceService.selectedDevice else { return }
                    SoundEffectService.shared.play(.click)
                    hubService.deployToHub(
                        game: game,
                        device: dev,
                        team: deviceService.selectedSigningTeam
                    ) { success, msg in
                        DispatchQueue.main.async {
                            SoundEffectService.shared.play(success ? .click : .error)
                        }
                    }
                }) {
                    HStack(spacing: 6) {
                        Image(systemName: "square.stack.3d.up.fill")
                            .font(.system(size: 12, weight: .bold))
                        Text(L10n.t("nxn_launcher.send_to_hub_btn"))
                            .font(.system(size: 12, weight: .bold, design: .rounded))
                    }
                    .padding(.horizontal, 16)
                    .padding(.vertical, 7)
                }
                .buttonStyle(NXPrimaryButtonStyle())
                .disabled(deviceService.selectedDevice == nil || deviceService.isDetecting || deviceService.activeDeployment.isRunning)
            } else {
                Button(action: {
                    guard let dev = deviceService.selectedDevice else { return }
                    SoundEffectService.shared.play(.click)
                    let deployURL = deviceService.resolveDeployableURL(for: game)

                    // Validate that we have an iOS deployable package (.ipa or iOS .app)
                    if deployURL.pathExtension.lowercased() != "ipa" && !deviceService.isIosAppBundle(deployURL) {
                        deviceService.failDeployment(
                            category: .invalidIPA,
                            title: "Pacote iOS (.ipa) Não Encontrado",
                            detail: "O jogo '\(game.name)' foi portado apenas para macOS (.app).\n\nPara instalar ou renovar no iPhone ou iPad, realize o porte selecionando a plataforma 'iOS' para gerar o arquivo .ipa."
                        )
                        SoundEffectService.shared.play(.error)
                        return
                    }

                    deviceService.installApp(
                        appBundleURL: deployURL,
                        on: dev,
                        team: deviceService.selectedSigningTeam,
                        game: game
                    ) { success, _ in
                        SoundEffectService.shared.play(success ? .click : .error)
                    }
                }) {
                    HStack(spacing: 6) {
                        Image(systemName: isDeployed ? "arrow.triangle.2.circlepath" : "arrow.down.to.line.circle.fill")
                            .font(.system(size: 12, weight: .bold))
                        Text(buttonTitle)
                            .font(.system(size: 12, weight: .bold, design: .rounded))
                    }
                    .padding(.horizontal, 16)
                    .padding(.vertical, 7)
                }
                .buttonStyle(NXPrimaryButtonStyle())
                .disabled(deviceService.selectedDevice == nil || deviceService.isDetecting || deviceService.activeDeployment.isRunning)
            }
        }
    }

    // MARK: - IPA Health Inspection & Auto Repair Helpers

    internal var currentSingleModeTitle: String {
        hubService.deploymentMode == .consoleHub
            ? L10n.t("nxn_launcher.mode_hub_title")
            : L10n.t("nxn_launcher.mode_standalone_title")
    }

    internal var singleGameIpaReport: IpaHealthReport? {
        ipaHealth.cachedReport(for: game)
    }

    internal var multiPortFailingSelectedGames: [PortedGame] {
        selectedMultiPortGames.filter { ipaHealth.cachedReport(for: $0)?.hasIpaDefect == true }
    }

    internal var multiPortStaleHubGames: [NxHubDeploymentService.StaleHubGameEntry] {
        guard hubService.deploymentMode == .consoleHub else { return [] }
        let excluded = Set(selectedMultiPortGames.compactMap { $0.titleId?.uppercased() })
        let allKnown = viewModel?.libraryGames ?? AppViewModel.shared?.libraryGames ?? availableIpaGames
        return hubService.staleOtherHubGames(excludingTitleIds: excluded, knownPortedGames: allKnown)
    }

    internal func refreshIpaHealthAndHubState() {
        var targets: [PortedGame] = [game]
        for g in availableIpaGames where g.stableId != game.stableId {
            targets.append(g)
        }
        ipaHealth.inspectBatchAsync(games: targets) { _ in
            self.refreshStaleHubList()
            if self.singleGameIpaReport?.hasIpaDefect != true && self.multiPortFailingSelectedGames.isEmpty {
                // Do not keep a stale repair failure banner if inspected packages are now healthy
                self.repairCoordinator.lastErrorMessage = nil
            }
        }
        refreshStaleHubList()
    }

    internal func refreshStaleHubList() {
        guard hubService.deploymentMode == .consoleHub else {
            staleHubGames = []
            return
        }
        let excluded: Set<String> = game.titleId.map { [$0.uppercased()] } ?? []
        let allKnown = viewModel?.libraryGames ?? AppViewModel.shared?.libraryGames ?? availableIpaGames
        staleHubGames = hubService.staleOtherHubGames(
            excludingTitleIds: excluded,
            knownPortedGames: allKnown
        )
    }

    internal func pruneOldHubEntries(_ entries: [NxHubDeploymentService.StaleHubGameEntry]? = nil) {
        let targets = entries ?? staleHubGames
        guard !targets.isEmpty else { return }
        let tids = Set(targets.map { $0.titleID })
        _ = hubService.pruneGamesFromHub(titleIds: tids)
        refreshStaleHubList()
    }

    internal func updateStaleHubEntries(excluding customExcluded: Set<String>? = nil) {
        let targets = customExcluded != nil ? multiPortStaleHubGames : staleHubGames
        guard !targets.isEmpty, !isUpdatingStaleHub else { return }
        isUpdatingStaleHub = true
        let library = hubService.loadShellLibrary()
        let currentExcluded: Set<String> = customExcluded ?? (game.titleId.map { [$0.uppercased()] } ?? [])
        let allKnown = viewModel?.libraryGames ?? AppViewModel.shared?.libraryGames ?? availableIpaGames
        let dev = deviceService.selectedDevice ?? ConnectedAppleDevice(
            id: "hub-refresh",
            name: "NxN Launcher",
            model: "iPhone",
            osVersion: "iOS",
            isPaired: true,
            isAvailable: false
        )

        DeviceDeploymentService.shared.activeDeployment = DeploymentProgressInfo()
        DeviceDeploymentService.shared.activeDeployment.isRunning = true
        DeviceDeploymentService.shared.activeDeployment.phase = .compiling
        DeviceDeploymentService.shared.activeDeployment.progressFraction = 0.08
        DeviceDeploymentService.shared.activeDeployment.statusMessage = L10n.t("ipa_health.hub_stale_update_btn")

        hubService.refreshFrameworksForHub(
            games: library.games,
            device: dev,
            team: deviceService.selectedSigningTeam,
            excludingTitleIds: currentExcluded,
            knownPortedGames: allKnown
        ) { ok, err in
            DispatchQueue.main.async {
                self.isUpdatingStaleHub = false
                if ok {
                    DeviceDeploymentService.shared.activeDeployment.isRunning = false
                    DeviceDeploymentService.shared.activeDeployment.phase = .idle
                    DeviceDeploymentService.shared.activeDeployment.progressFraction = 0.0
                    DeviceDeploymentService.shared.activeDeployment.statusMessage = ""
                    DeviceDeploymentService.shared.activeDeployment.detailMessage = ""
                    SoundEffectService.shared.play(.click)
                } else {
                    DeviceDeploymentService.shared.activeDeployment.isRunning = false
                    DeviceDeploymentService.shared.activeDeployment.phase = .failed
                    DeviceDeploymentService.shared.activeDeployment.statusMessage = L10n.t("ipa_health.hub_stale_update_btn")
                    DeviceDeploymentService.shared.activeDeployment.detailMessage = err ?? ""
                    SoundEffectService.shared.play(.error)
                }
                self.refreshStaleHubList()
            }
        }
    }

    internal func triggerSingleRepairAndDeploy() {
        guard let vm = viewModel ?? AppViewModel.shared else { return }
        repairCoordinator.startRepairAndDeploy(
            target: .individual(game: game, mode: hubService.deploymentMode),
            viewModel: vm,
            device: deviceService.selectedDevice,
            team: deviceService.selectedSigningTeam
        ) { _, _ in
            DispatchQueue.main.async {
                self.refreshIpaHealthAndHubState()
            }
        }
    }

    internal func triggerMultiPortRepairAndDeploy() {
        guard let vm = viewModel ?? AppViewModel.shared else { return }
        let selected = selectedMultiPortGames
        let failing = multiPortFailingSelectedGames
        guard !failing.isEmpty else { return }
        repairCoordinator.startRepairAndDeploy(
            target: .multiPort(selectedGames: selected, failingGames: failing),
            viewModel: vm,
            device: deviceService.selectedDevice,
            team: deviceService.selectedSigningTeam
        ) { _, _ in
            DispatchQueue.main.async {
                self.refreshIpaHealthAndHubState()
            }
        }
    }
}
