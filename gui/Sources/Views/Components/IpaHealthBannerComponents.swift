import SwiftUI

/// Compact Apple Liquid Glass pill indicating `.ipa` package health (corrupted, obsolete shaders, bloated RomFS, Hub stale, or ready).
public struct IpaHealthBadgeView: View {
    public let report: IpaHealthReport?
    public let isInspecting: Bool

    public init(report: IpaHealthReport?, isInspecting: Bool = false) {
        self.report = report
        self.isInspecting = isInspecting
    }

    public var body: some View {
        if let report = report {
            HStack(spacing: 4) {
                Image(systemName: iconName(for: report))
                    .font(.system(size: 9.5, weight: .bold))
                    .foregroundColor(report.badgeColor)
                Text(report.shortBadgeText)
                    .font(.system(size: 9.5, weight: .bold))
                    .foregroundColor(.white)
                    .lineLimit(1)
            }
            .padding(.horizontal, 7)
            .padding(.vertical, 3)
            .nxGlassInteractive(
                in: Capsule(),
                tint: report.badgeColor.opacity(report.isHealthy ? 0.16 : 0.30),
                isInteractive: false,
                fallbackFill: report.badgeColor.opacity(report.isHealthy ? 0.16 : 0.28)
            )
            .help(report.detailedExplanation.isEmpty ? report.shortBadgeText : report.detailedExplanation)
        } else if isInspecting {
            HStack(spacing: 4) {
                ProgressView()
                    .scaleEffect(0.5)
                    .frame(width: 10, height: 10)
            }
            .padding(.horizontal, 7)
            .padding(.vertical, 3)
            .nxGlassInteractive(
                in: Capsule(),
                tint: NXTheme.glassSurfaceElevated.opacity(0.4),
                isInteractive: false,
                fallbackFill: NXTheme.glassSurfaceElevated.opacity(0.6)
            )
        }
    }

    private func iconName(for report: IpaHealthReport) -> String {
        if report.isUnusableArchive {
            return "exclamationmark.octagon.fill"
        }
        if report.hasIpaDefect {
            return "exclamationmark.triangle.fill"
        }
        if !report.issues.isEmpty {
            return "arrow.triangle.2.circlepath"
        }
        return "checkmark.seal.fill"
    }
}

/// Apple Liquid Glass warning banner surfacing `.ipa` defects and offering one-click Trash + Re-Port + Deploy automation.
public struct IpaRepairWarningBanner: View {
    public let title: String
    public let subtitle: String
    public let detailLines: [String]
    public let actionTitle: String
    public let errorMessage: String?
    public let isCritical: Bool
    public let isActionDisabled: Bool
    public let onRepairAndDeploy: () -> Void

    public init(
        title: String,
        subtitle: String,
        detailLines: [String],
        actionTitle: String,
        errorMessage: String? = nil,
        isCritical: Bool = false,
        isActionDisabled: Bool = false,
        onRepairAndDeploy: @escaping () -> Void
    ) {
        self.title = title
        self.subtitle = subtitle
        self.detailLines = detailLines
        self.actionTitle = actionTitle
        self.errorMessage = errorMessage
        self.isCritical = isCritical
        self.isActionDisabled = isActionDisabled
        self.onRepairAndDeploy = onRepairAndDeploy
    }

    public var body: some View {
        let accentColor: Color = isCritical ? .red : .orange

        VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .top, spacing: 10) {
                Image(systemName: isCritical ? "xmark.octagon.fill" : "exclamationmark.triangle.fill")
                    .font(.system(size: 16, weight: .bold))
                    .foregroundColor(accentColor)
                    .padding(7)
                    .nxGlassInteractive(
                        in: Circle(),
                        tint: accentColor.opacity(0.28),
                        isInteractive: false,
                        fallbackFill: accentColor.opacity(0.22)
                    )

                VStack(alignment: .leading, spacing: 3) {
                    Text(title)
                        .font(.system(size: 12.5, weight: .bold))
                        .foregroundColor(.white)
                    Text(subtitle)
                        .font(.system(size: 11))
                        .foregroundColor(NXTheme.textSecondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }

            if !detailLines.isEmpty {
                VStack(alignment: .leading, spacing: 3) {
                    ForEach(Array(detailLines.prefix(5).enumerated()), id: \.offset) { _, line in
                        Text(line)
                            .font(.system(size: 10.5))
                            .foregroundColor(.white.opacity(0.90))
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    if detailLines.count > 5 {
                        Text("• +\(detailLines.count - 5)...")
                            .font(.system(size: 10.5, weight: .semibold))
                            .foregroundColor(NXTheme.textMuted)
                    }
                }
                .padding(.leading, 4)
            }

            if let errorMessage = errorMessage, !errorMessage.isEmpty {
                HStack(spacing: 6) {
                    Image(systemName: "exclamationmark.circle.fill")
                        .font(.system(size: 11))
                        .foregroundColor(.red)
                    Text(errorMessage)
                        .font(.system(size: 11, weight: .medium))
                        .foregroundColor(.white)
                        .fixedSize(horizontal: false, vertical: true)
                }
                .padding(.horizontal, 10)
                .padding(.vertical, 6)
                .nxGlassCard(cornerRadius: 8, tint: Color.red.opacity(0.24), isNested: true)
            }

            Button(action: {
                SoundEffectService.shared.play(.click)
                onRepairAndDeploy()
            }) {
                HStack(spacing: 7) {
                    Image(systemName: "wrench.and.screwdriver.fill")
                    Text(actionTitle)
                        .lineLimit(1)
                }
                .frame(maxWidth: .infinity)
            }
            .buttonStyle(NXPrimaryButtonStyle())
            .disabled(isActionDisabled)
        }
        .padding(14)
        .nxGlassCard(cornerRadius: 12, tint: accentColor.opacity(0.22))
    }
}

/// Apple Liquid Glass warning banner alerting when other games already registered in `MobileHub/shell.json` are outdated.
public struct IpaHubStaleBanner: View {
    public let staleEntries: [NxHubDeploymentService.StaleHubGameEntry]
    public let isBusy: Bool
    public let onPruneOld: () -> Void
    public let onUpdateHubGames: () -> Void

    public init(
        staleEntries: [NxHubDeploymentService.StaleHubGameEntry],
        isBusy: Bool,
        onPruneOld: @escaping () -> Void,
        onUpdateHubGames: @escaping () -> Void
    ) {
        self.staleEntries = staleEntries
        self.isBusy = isBusy
        self.onPruneOld = onPruneOld
        self.onUpdateHubGames = onUpdateHubGames
    }

    public var body: some View {
        let previewNames = staleEntries.prefix(3).map { $0.name }.joined(separator: ", ")
        let namesSummary = staleEntries.count > 3 ? "\(previewNames) +\(staleEntries.count - 3)" : previewNames

        VStack(alignment: .leading, spacing: 9) {
            HStack(alignment: .top, spacing: 9) {
                Image(systemName: "tray.2.fill")
                    .font(.system(size: 14, weight: .bold))
                    .foregroundColor(.yellow)
                    .padding(6)
                    .nxGlassInteractive(
                        in: Circle(),
                        tint: Color.yellow.opacity(0.26),
                        isInteractive: false,
                        fallbackFill: Color.yellow.opacity(0.20)
                    )

                VStack(alignment: .leading, spacing: 3) {
                    Text(L10n.t("ipa_health.hub_stale_banner_title", staleEntries.count))
                        .font(.system(size: 12, weight: .bold))
                        .foregroundColor(.white)
                    Text(L10n.t("ipa_health.hub_stale_banner_desc", namesSummary))
                        .font(.system(size: 11))
                        .foregroundColor(NXTheme.textSecondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }

            VStack(alignment: .leading, spacing: 2) {
                ForEach(staleEntries.prefix(3)) { entry in
                    Text("• \(entry.name): \(entry.reason)")
                        .font(.system(size: 10.5))
                        .foregroundColor(.white.opacity(0.88))
                        .lineLimit(2)
                }
            }
            .padding(.leading, 2)

            HStack(spacing: 8) {
                Button(action: {
                    SoundEffectService.shared.play(.click)
                    onPruneOld()
                }) {
                    HStack(spacing: 5) {
                        Image(systemName: "trash")
                        Text(L10n.t("ipa_health.hub_stale_prune_btn"))
                    }
                }
                .buttonStyle(NXSecondaryButtonStyle())
                .disabled(isBusy)

                Button(action: {
                    SoundEffectService.shared.play(.click)
                    onUpdateHubGames()
                }) {
                    HStack(spacing: 5) {
                        Image(systemName: "arrow.triangle.2.circlepath")
                        Text(L10n.t("ipa_health.hub_stale_update_btn"))
                    }
                }
                .buttonStyle(NXSecondaryButtonStyle())
                .disabled(isBusy)
            }
        }
        .padding(12)
        .nxGlassCard(cornerRadius: 12, tint: Color.yellow.opacity(0.18))
    }
}

/// Live Apple Liquid Glass progress card shown while `IpaRepairDeployCoordinator` trashes, re-ports, and prepares deployment.
public struct IpaRepairProgressCard: View {
    @ObservedObject private var coordinator = IpaRepairDeployCoordinator.shared

    public init() {}

    public var body: some View {
        let idx = max(1, coordinator.currentQueueIndex)
        let total = max(1, coordinator.totalQueueCount)
        let pct = Int((coordinator.overallProgress * 100.0).rounded())

        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 10) {
                Image(systemName: "wrench.and.screwdriver.fill")
                    .font(.system(size: 14, weight: .bold))
                    .foregroundColor(NXTheme.primary)
                    .padding(7)
                    .nxGlassInteractive(
                        in: Circle(),
                        tint: NXTheme.primary.opacity(0.28),
                        isInteractive: false,
                        fallbackFill: NXTheme.primary.opacity(0.20)
                    )

                VStack(alignment: .leading, spacing: 2) {
                    Text(L10n.t("ipa_health.repairing_card_title", idx, total, coordinator.currentGameName))
                        .font(.system(size: 12.5, weight: .bold))
                        .foregroundColor(.white)
                        .lineLimit(1)

                    Text(L10n.t("ipa_health.repairing_progress_format", pct, coordinator.targetModeDescription))
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundColor(NXTheme.primary)
                }

                Spacer()

                Button(action: {
                    SoundEffectService.shared.play(.click)
                    coordinator.cancelRepair()
                }) {
                    Image(systemName: "xmark")
                        .font(.system(size: 11, weight: .bold))
                }
                .buttonStyle(NXSecondaryButtonStyle())
                .controlSize(.small)
            }

            GeometryReader { geo in
                ZStack(alignment: .leading) {
                    Capsule()
                        .fill(Color.white.opacity(0.12))
                        .frame(height: 6)

                    Capsule()
                        .fill(NXTheme.primaryGradient)
                        .frame(width: max(8, geo.size.width * CGFloat(min(1.0, max(0.0, coordinator.overallProgress)))), height: 6)
                        .animation(.easeInOut(duration: 0.25), value: coordinator.overallProgress)
                }
            }
            .frame(height: 6)

            if !coordinator.currentStageLabel.isEmpty || !coordinator.currentStepLabel.isEmpty {
                VStack(alignment: .leading, spacing: 2) {
                    if !coordinator.currentStageLabel.isEmpty {
                        Text(coordinator.currentStageLabel)
                            .font(.system(size: 11, weight: .medium))
                            .foregroundColor(.white.opacity(0.92))
                            .lineLimit(1)
                    }
                    if !coordinator.currentStepLabel.isEmpty {
                        Text(coordinator.currentStepLabel)
                            .font(.system(size: 10.5))
                            .foregroundColor(NXTheme.textMuted)
                            .lineLimit(2)
                    }
                }
            }
        }
        .padding(14)
        .nxGlassCard(cornerRadius: 12, tint: NXTheme.primary.opacity(0.20))
    }
}

/// Informational Apple Liquid Glass status card shown when re-ports succeeded cleanly and wait only for an iPhone/iPad connection.
public struct IpaInfoStatusBanner: View {
    public let message: String
    public let onDismiss: (() -> Void)?

    public init(message: String, onDismiss: (() -> Void)? = nil) {
        self.message = message
        self.onDismiss = onDismiss
    }

    public var body: some View {
        HStack(spacing: 10) {
            Image(systemName: "checkmark.circle.fill")
                .font(.system(size: 14, weight: .bold))
                .foregroundColor(Color.green)
                .padding(6)
                .nxGlassInteractive(
                    in: Circle(),
                    tint: Color.green.opacity(0.24),
                    isInteractive: false,
                    fallbackFill: Color.green.opacity(0.18)
                )

            Text(message)
                .font(.system(size: 11.5, weight: .medium))
                .foregroundColor(.white)
                .fixedSize(horizontal: false, vertical: true)

            Spacer()

            if let onDismiss = onDismiss {
                Button(action: {
                    SoundEffectService.shared.play(.click)
                    onDismiss()
                }) {
                    Image(systemName: "xmark")
                        .font(.system(size: 10, weight: .bold))
                        .foregroundColor(.white.opacity(0.75))
                }
                .buttonStyle(.plain)
            }
        }
        .padding(12)
        .nxGlassCard(cornerRadius: 12, tint: Color.blue.opacity(0.18))
    }
}
