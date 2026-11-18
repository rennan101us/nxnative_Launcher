import SwiftUI
import AppKit

private enum UpdateSheetTab: Hashable {
    case highlights
    case commits
}

public struct LauncherUpdateSheet: View {
    @ObservedObject public var viewModel: AppViewModel
    @ObservedObject private var localizer = LocalizationService.shared
    @Environment(\.dismiss) private var dismiss
    @State private var selectedTab: UpdateSheetTab = .highlights
    
    public init(viewModel: AppViewModel) {
        self.viewModel = viewModel
    }
    
    private var currentVersion: String {
        Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "2.2.4"
    }
    
    private var targetVersion: String {
        let tag = viewModel.effectiveReleaseTag
        if !tag.isEmpty {
            let clean = tag.trimmingCharacters(in: CharacterSet(charactersIn: "vV"))
            if !clean.isEmpty && clean.count < 12 { return clean }
        }
        if let remote = viewModel.updateInfo?.remoteCommit, !remote.isEmpty {
            let clean = remote.trimmingCharacters(in: CharacterSet(charactersIn: "vV"))
            if !clean.isEmpty && clean.count < 10 { return clean }
        }
        return currentVersion
    }

    private func categoryColor(for key: String) -> Color {
        switch key {
        case "green":
            return Color(red: 0.13, green: 0.77, blue: 0.37)
        case "pink":
            return Color(red: 0.95, green: 0.45, blue: 0.75)
        case "yellow":
            return Color.yellow
        case "purple":
            return Color(red: 0.85, green: 0.45, blue: 0.95)
        case "teal":
            return Color(red: 0.30, green: 0.85, blue: 0.75)
        default:
            return Color(red: 0.22, green: 0.65, blue: 0.98)
        }
    }

    private var summarizedCategories: [ReleaseHighlightCategory] {
        let all = viewModel.effectiveReleaseCategories
        if !all.isEmpty {
            let primary = all.filter { $0.isPrimarySection }
            return Array((primary.isEmpty ? all : primary).prefix(4))
        }
        return [
            ReleaseHighlightCategory(
                title: "NxNative Launcher v\(targetVersion)",
                icon: "sparkles",
                colorKey: "blue",
                summaryPoints: [viewModel.tr("update_modal.default_summary")],
                detailedPoints: [viewModel.tr("update_modal.default_summary")],
                isPrimarySection: true
            )
        ]
    }
    
    public var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            if viewModel.isApplyingUpdate || viewModel.isSyncingUpstream {
                // MARK: - Collapsed Progress View (% & Liquid Glass Bar)
                collapsedProgressView
            } else if viewModel.updateCompletedReadyToRelaunch {
                // MARK: - Completion View
                completedView
            } else {
                // MARK: - Standard Header
                headerView
                
                Divider().opacity(0.2)
                
                // MARK: - Main Content: Fixes and New Functionalities
                mainContent
                
                if viewModel.isBuilding {
                    buildingWarningBanner
                }
                
                Divider().opacity(0.2)
                
                // MARK: - Footer Buttons
                footerButtons
            }
        }
        .padding(22)
        .nxSheetSurface()
        .frame(width: 580)
        .fixedSize(horizontal: false, vertical: true)
        .animation(.easeInOut(duration: 0.30), value: viewModel.isApplyingUpdate)
        .animation(.easeInOut(duration: 0.30), value: viewModel.updateCompletedReadyToRelaunch)
        .onAppear {
            viewModel.refreshReleaseNotesTranslation()
            viewModel.updateModalTabIndex = (selectedTab == .highlights) ? 0 : 1
            let hasAction = (viewModel.updateInfo?.hasUpdate == true) || ((viewModel.updateInfo?.upstreamBehindCount ?? 0) > 0)
            let closeIdx = viewModel.isCheckingUpdate ? 0 : 1
            viewModel.updateModalFocusIndex = hasAction ? (closeIdx + 1) : closeIdx
        }
        .onChange(of: localizer.currentLanguage) { _ in
            viewModel.refreshReleaseNotesTranslation()
        }
        .onChange(of: viewModel.updateModalTabIndex) { newIndex in
            selectedTab = (newIndex == 0) ? .highlights : .commits
        }
        .onChange(of: selectedTab) { newTab in
            viewModel.updateModalTabIndex = (newTab == .highlights) ? 0 : 1
        }
    }
    
    // MARK: - Header View
    private var headerView: some View {
        HStack(spacing: 12) {
            ZStack {
                Circle()
                    .fill(NXTheme.primaryGradient)
                    .frame(width: 40, height: 40)
                Image(systemName: "sparkles")
                    .font(.system(size: 17, weight: .bold))
                    .foregroundColor(.white)
            }
            
            VStack(alignment: .leading, spacing: 2) {
                Text(viewModel.tr("update_modal.title"))
                    .font(.system(size: 16, weight: .bold, design: .rounded))
                    .foregroundColor(.white)
                Text(viewModel.updateInfo?.hasUpdate == true
                     ? viewModel.tr("update_modal.upgrade_available", currentVersion, targetVersion)
                     : viewModel.tr("update_modal.latest_release_label", currentVersion))
                    .font(.system(size: 12))
                    .foregroundColor(NXTheme.modalDescription)
            }
            
            Spacer()

            NXModalCloseButton(size: 28) {
                viewModel.showUpdateSheet = false
                dismiss()
            }
        }
    }
    
    // MARK: - Main Content (Fixes & New Functionalities)
    @ViewBuilder
    private var mainContent: some View {
        if viewModel.isCheckingUpdate {
            HStack(spacing: 12) {
                ProgressView()
                    .controlSize(.regular)
                VStack(alignment: .leading, spacing: 3) {
                    Text(viewModel.tr("update_modal.checking"))
                        .font(.system(size: 13, weight: .semibold))
                        .foregroundColor(.white)
                    Text(viewModel.tr("update_modal.comparing"))
                        .font(.system(size: 11))
                        .foregroundColor(NXTheme.modalDescription)
                }
                Spacer()
            }
            .padding(16)
            .nxGlassCard(cornerRadius: 12)
        } else if let err = viewModel.updateErrorBanner {
            VStack(alignment: .leading, spacing: 10) {
                HStack(spacing: 10) {
                    Image(systemName: "exclamationmark.triangle.fill")
                        .font(.system(size: 20))
                        .foregroundColor(.orange)
                    VStack(alignment: .leading, spacing: 2) {
                        Text(viewModel.tr("update_modal.issue"))
                            .font(.system(size: 13, weight: .bold))
                            .foregroundColor(.white)
                        Text(err)
                            .font(.system(size: 11))
                            .foregroundColor(NXTheme.modalDescription)
                    }
                    Spacer()
                }
                .padding(12)
                .nxGlassCard(cornerRadius: 12, tint: Color.orange.opacity(0.28))
                
                // Still show highlights even on network check warning
                highlightsScrollView
            }
        } else {
            VStack(alignment: .leading, spacing: 12) {
                let installPlan = LauncherSelfUpdater.shared.resolveInstallPlan(nxnativePath: viewModel.nxnativePath)
                HStack(spacing: 8) {
                    Image(systemName: installPlan.totalCleanupCount > 0 || installPlan.isTranslocated ? "checkmark.shield.fill" : "folder.fill")
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundColor(installPlan.totalCleanupCount > 0 ? Color.orange : NXTheme.secondary)
                    Text("Target: \(installPlan.canonicalTarget)")
                        .font(.system(size: 10.5, design: .monospaced))
                        .foregroundColor(NXTheme.modalDescription)
                        .lineLimit(1)
                        .truncationMode(.middle)
                    if installPlan.totalCleanupCount > 0 {
                        Spacer()
                        Text("\(installPlan.totalCleanupCount) old duplicate(s) will be cleaned")
                            .font(.system(size: 10, weight: .semibold))
                            .foregroundColor(.orange)
                    }
                }
                .padding(.horizontal, 10)
                .padding(.vertical, 6)
                .nxGlassCard(cornerRadius: 8)

                if let okMsg = viewModel.updateSuccessBanner, !viewModel.updateCompletedReadyToRelaunch {
                    HStack(spacing: 10) {
                        Image(systemName: "checkmark.circle.fill")
                            .font(.system(size: 18))
                            .foregroundColor(.green)
                        Text(okMsg)
                            .font(.system(size: 11.5, weight: .semibold))
                            .foregroundColor(.white)
                        Spacer()
                    }
                    .padding(10)
                    .nxGlassCard(cornerRadius: 10, tint: Color.green.opacity(0.22))
                }
                
                // Hero Version Banner
                versionBannerView
                
                // Liquid Glass Segmented Mode Picker
                NXLiquidSegmentedPicker(
                    selection: $selectedTab,
                    options: [
                        NXSegmentOption(id: .highlights, title: viewModel.tr("update_modal.highlights_tab", targetVersion), icon: "sparkles"),
                        NXSegmentOption(id: .commits, title: viewModel.tr("update_modal.commits_tab", viewModel.updateInfo?.commitMessages.count ?? 0), icon: "list.bullet")
                    ]
                )
                
                if selectedTab == .highlights {
                    highlightsScrollView
                } else {
                    commitsScrollView
                }
            }
        }
    }
    
    // MARK: - Version Banner View
    private var versionBannerView: some View {
        HStack(spacing: 12) {
            ZStack {
                RoundedRectangle(cornerRadius: 10)
                    .fill(NXTheme.primaryGradient.opacity(0.25))
                    .frame(width: 44, height: 44)
                    .overlay(
                        RoundedRectangle(cornerRadius: 10)
                            .stroke(NXTheme.primary.opacity(0.4), lineWidth: 1)
                    )
                Image(systemName: "arrow.up.circle.fill")
                    .font(.system(size: 22, weight: .bold))
                    .foregroundColor(NXTheme.primary)
            }
            
            VStack(alignment: .leading, spacing: 4) {
                HStack(spacing: 6) {
                    Text(viewModel.updateInfo?.releaseName ?? "NxNative Launcher v\(targetVersion)")
                        .font(.system(size: 14, weight: .bold, design: .rounded))
                        .foregroundColor(.white)
                    
                    Text(viewModel.updateInfo?.hasUpdate == true ? "v\(currentVersion) → v\(targetVersion)" : "v\(targetVersion)")
                        .font(.system(size: 11, weight: .heavy, design: .monospaced))
                        .foregroundColor(NXTheme.primary)
                        .padding(.horizontal, 6)
                        .padding(.vertical, 2)
                        .background(NXTheme.primary.opacity(0.18))
                        .cornerRadius(4)

                    Spacer(minLength: 4)

                    if viewModel.isTranslatingReleaseNotes {
                        HStack(spacing: 4) {
                            ProgressView().controlSize(.mini)
                            Text(viewModel.tr("update_modal.translating_notes"))
                                .font(.system(size: 10, weight: .medium))
                                .foregroundColor(NXTheme.modalDescription)
                        }
                    } else if viewModel.canToggleReleaseTranslation {
                        Button(action: {
                            viewModel.showOriginalReleaseNotes.toggle()
                        }) {
                            HStack(spacing: 4) {
                                Image(systemName: "globe")
                                    .font(.system(size: 9.5, weight: .semibold))
                                Text(viewModel.showOriginalReleaseNotes
                                     ? viewModel.tr("update_modal.show_translated")
                                     : viewModel.tr("update_modal.show_original"))
                                    .font(.system(size: 10, weight: .semibold, design: .rounded))
                            }
                            .foregroundColor(.white.opacity(0.92))
                            .padding(.horizontal, 8)
                            .padding(.vertical, 3)
                        }
                        .buttonStyle(.plain)
                        .nxGlassInteractive(in: Capsule())
                    }
                }
                
                Text(viewModel.effectiveReleaseSummary ?? viewModel.tr("update_modal.default_summary"))
                    .font(.system(size: 11))
                    .foregroundColor(NXTheme.modalDescription)
                    .lineLimit(2)
            }
        }
        .padding(12)
        .nxGlassCard(cornerRadius: 12, tint: NXTheme.primary.opacity(0.15))
    }
    
    // MARK: - Highlights Scroll View (Summarized)
    private var highlightsScrollView: some View {
        ScrollView(.vertical, showsIndicators: true) {
            VStack(alignment: .leading, spacing: 10) {
                ForEach(summarizedCategories) { cat in
                    let catColor = categoryColor(for: cat.colorKey)
                    let points = cat.summaryPoints.isEmpty ? Array(cat.detailedPoints.prefix(3)) : cat.summaryPoints
                    VStack(alignment: .leading, spacing: 6) {
                        HStack(spacing: 6) {
                            Image(systemName: cat.icon)
                                .font(.system(size: 12, weight: .bold))
                                .foregroundColor(catColor)
                            Text(cat.title)
                                .font(.system(size: 12, weight: .bold, design: .rounded))
                                .foregroundColor(.white)
                            Spacer()
                        }
                        
                        VStack(alignment: .leading, spacing: 4) {
                            ForEach(points, id: \.self) { pt in
                                HStack(alignment: .top, spacing: 6) {
                                    Text("•")
                                        .font(.system(size: 11, weight: .bold))
                                        .foregroundColor(catColor.opacity(0.85))
                                    Text(pt)
                                        .font(.system(size: 11, design: .rounded))
                                        .foregroundColor(Color.white.opacity(0.90))
                                        .fixedSize(horizontal: false, vertical: true)
                                }
                            }
                        }
                        .padding(.leading, 4)
                    }
                    .padding(10)
                    .nxGlassCard(cornerRadius: 10, tint: catColor.opacity(0.08))
                }

                HStack(spacing: 6) {
                    Image(systemName: "info.circle")
                        .font(.system(size: 10.5))
                        .foregroundColor(NXTheme.modalDescription)
                    Text(viewModel.tr("update_modal.full_notes_hint"))
                        .font(.system(size: 10.5, design: .rounded))
                        .foregroundColor(NXTheme.modalDescription)
                }
                .padding(.top, 2)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.trailing, 2)
        }
        .frame(maxHeight: 250)
    }
    
    // MARK: - Commits Scroll View
    private var commitsScrollView: some View {
        VStack(alignment: .leading, spacing: 8) {
            if let info = viewModel.updateInfo, !info.commitMessages.isEmpty {
                ScrollView(.vertical, showsIndicators: true) {
                    VStack(alignment: .leading, spacing: 6) {
                        ForEach(info.commitMessages, id: \.self) { msg in
                            HStack(alignment: .top, spacing: 6) {
                                Text("•")
                                    .font(.system(size: 11, weight: .bold))
                                    .foregroundColor(NXTheme.secondary)
                                Text(msg)
                                    .font(.system(size: 11, design: .rounded))
                                    .foregroundColor(.white.opacity(0.92))
                                    .fixedSize(horizontal: false, vertical: true)
                            }
                        }
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.trailing, 2)
                }
                .frame(maxHeight: 250)
                .padding(10)
                .nxGlassCard(cornerRadius: 10)
            } else {
                HStack(spacing: 8) {
                    Image(systemName: "checkmark.circle.fill")
                        .foregroundColor(Color(red: 0.13, green: 0.77, blue: 0.37))
                    Text(viewModel.tr("update_modal.up_to_date_desc"))
                        .font(.system(size: 11.5))
                        .foregroundColor(NXTheme.modalDescription)
                    Spacer()
                }
                .padding(14)
                .nxGlassCard(cornerRadius: 10)
                .frame(maxHeight: 250)
            }
            
            // Upstream updates (if any)
            if let info = viewModel.updateInfo, info.upstreamBehindCount > 0 {
                VStack(alignment: .leading, spacing: 6) {
                    HStack {
                        Label(viewModel.tr("update_modal.upstream_section"), systemImage: "arrow.triangle.merge")
                            .font(.system(size: 11.5, weight: .bold, design: .rounded))
                            .foregroundColor(.orange)
                        Spacer()
                        Text(viewModel.tr("system.upstream_commits_available", info.upstreamBehindCount))
                            .font(.system(size: 10, weight: .semibold, design: .monospaced))
                            .foregroundColor(.white)
                            .padding(.horizontal, 6)
                            .padding(.vertical, 2)
                            .background(Color.orange.opacity(0.35))
                            .cornerRadius(4)
                        Button(action: {
                            SoundEffectService.shared.play(.click)
                            viewModel.syncUpstreamEngine()
                        }) {
                            HStack(spacing: 5) {
                                Image(systemName: "arrow.triangle.2.circlepath")
                                Text(viewModel.tr("updates.sync_upstream"))
                            }
                        }
                        .buttonStyle(NXSecondaryButtonStyle())
                        .disabled(viewModel.isBuilding || viewModel.isApplyingUpdate || viewModel.isSyncingUpstream)
                    }
                    
                    ScrollView {
                        VStack(alignment: .leading, spacing: 3) {
                            ForEach(info.upstreamCommitMessages, id: \.self) { msg in
                                Text("• \(msg)")
                                    .font(.system(size: 10.5, design: .monospaced))
                                    .foregroundColor(NXTheme.modalDescription)
                            }
                        }
                        .frame(maxWidth: .infinity, alignment: .leading)
                    }
                    .frame(maxHeight: 60)
                    .padding(8)
                    .nxGlassCard(cornerRadius: 8)
                }
                .padding(10)
                .nxGlassCard(cornerRadius: 10, tint: Color.orange.opacity(0.12))
            }
        }
    }
    
    // MARK: - Collapsed Progress View (When Update Button is Pressed)
    private var collapsedProgressView: some View {
        VStack(spacing: 18) {
            ZStack {
                Circle()
                    .fill(NXTheme.primary.opacity(0.18))
                    .frame(width: 58, height: 58)
                Image(systemName: "arrow.triangle.2.circlepath")
                    .font(.system(size: 24, weight: .bold))
                    .foregroundColor(NXTheme.primary)
            }
            .padding(.top, 6)
            
            VStack(spacing: 4) {
                Text(viewModel.updateStatusText.isEmpty ? (viewModel.isSyncingUpstream ? "Syncing Upstream Engine..." : "Updating NxNative Launcher...") : viewModel.updateStatusText)
                    .font(.system(size: 14, weight: .bold, design: .rounded))
                    .foregroundColor(.white)
                
                Text("\(Int(viewModel.updateProgressFraction * 100))%")
                    .font(.system(size: 32, weight: .heavy, design: .rounded))
                    .foregroundColor(NXTheme.primary)
            }
            
            // Liquid Glass Progress Bar
            GeometryReader { geo in
                ZStack(alignment: .leading) {
                    Capsule()
                        .fill(Color.white.opacity(0.12))
                        .frame(height: 10)
                    
                    Capsule()
                        .fill(NXTheme.primaryGradient)
                        .frame(width: max(10, geo.size.width * CGFloat(min(1.0, max(0.05, viewModel.updateProgressFraction)))), height: 10)
                        .shadow(color: NXTheme.primary.opacity(0.55), radius: 6, x: 0, y: 1)
                        .animation(.easeInOut(duration: 0.25), value: viewModel.updateProgressFraction)
                }
            }
            .frame(height: 10)
            .padding(.horizontal, 16)
            
            Text(viewModel.tr("update_modal.do_not_close"))
                .font(.system(size: 10.5))
                .foregroundColor(NXTheme.textMuted)
                .padding(.bottom, 6)
        }
        .frame(maxWidth: .infinity)
        .padding(18)
        .nxGlassCard(cornerRadius: 16)
    }
    
    // MARK: - Completed View
    private var completedView: some View {
        VStack(spacing: 16) {
            Image(systemName: "checkmark.seal.fill")
                .font(.system(size: 36))
                .foregroundColor(Color(red: 0.13, green: 0.77, blue: 0.37))
            
            VStack(spacing: 4) {
                Text(viewModel.tr("update_modal.success"))
                    .font(.system(size: 16, weight: .bold, design: .rounded))
                    .foregroundColor(.white)
                Text(viewModel.updateSuccessBanner ?? "The new NxNative_Launcher.app bundle has been compiled and installed.")
                    .font(.system(size: 12))
                    .foregroundColor(NXTheme.modalDescription)
                    .multilineTextAlignment(.center)
            }
            
            Button(action: {
                SoundEffectService.shared.play(.click)
                viewModel.relaunchUpdatedLauncher()
            }) {
                HStack(spacing: 6) {
                    Image(systemName: "bolt.fill")
                    Text(viewModel.tr("update_modal.relaunch_now"))
                }
                .font(.system(size: 13, weight: .bold))
            }
            .buttonStyle(NXPrimaryButtonStyle())
            .controlSize(.large)
            .nxConsoleFocusRing(in: Capsule(), isFocused: viewModel.updateCompletedReadyToRelaunch)
        }
        .frame(maxWidth: .infinity)
        .padding(20)
        .nxGlassCard(cornerRadius: 16, tint: Color(red: 0.13, green: 0.77, blue: 0.37).opacity(0.22))
    }
    
    // MARK: - Building Warning Banner
    private var buildingWarningBanner: some View {
        HStack(spacing: 8) {
            Image(systemName: "lock.shield.fill")
                .font(.system(size: 13))
                .foregroundColor(.yellow)
            Text(viewModel.tr("build.update_locked_during_build"))
                .font(.system(size: 11.5, weight: .medium))
                .foregroundColor(NXTheme.textPrimary)
        }
        .padding(10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color.yellow.opacity(0.12))
        .cornerRadius(8)
    }
    
    // MARK: - Footer Buttons
    private var footerButtons: some View {
        let hasRecheck = !viewModel.isCheckingUpdate
        let closeIdx = hasRecheck ? 1 : 0
        let actionIdx = closeIdx + 1
        return NXGlassContainer(spacing: 10) {
            HStack(spacing: 10) {
                if hasRecheck {
                    Button(action: {
                        SoundEffectService.shared.play(.click)
                        viewModel.openUpdateCheckerAndAutoInstall()
                    }) {
                        HStack(spacing: 5) {
                            Image(systemName: "arrow.clockwise")
                            Text(viewModel.tr("update_modal.recheck"))
                        }
                    }
                    .buttonStyle(NXSecondaryButtonStyle())
                    .nxConsoleFocusRing(in: Capsule(), isFocused: viewModel.updateModalFocusIndex == 0)
                }
                
                Spacer()
                
                Button(action: {
                    SoundEffectService.shared.play(.click)
                    viewModel.showUpdateSheet = false
                    dismiss()
                }) {
                    Text(viewModel.tr("common.close"))
                }
                .buttonStyle(NXSecondaryButtonStyle())
                .nxConsoleFocusRing(in: Capsule(), isFocused: viewModel.updateModalFocusIndex == closeIdx)
                
                if let info = viewModel.updateInfo, info.hasUpdate {
                    Button(action: {
                        SoundEffectService.shared.play(.click)
                        viewModel.applyUpdate(autoRelaunch: true)
                    }) {
                        HStack(spacing: 6) {
                            Image(systemName: viewModel.isBuilding ? "lock.fill" : "arrow.down.circle.fill")
                            Text(viewModel.isBuilding ? viewModel.tr("build.update_locked_badge") : viewModel.tr("update_modal.install_relaunch"))
                        }
                    }
                    .buttonStyle(NXPrimaryButtonStyle())
                    .disabled(viewModel.isBuilding)
                    .nxConsoleFocusRing(in: Capsule(), isFocused: viewModel.updateModalFocusIndex == actionIdx)
                } else if let info = viewModel.updateInfo, info.upstreamBehindCount > 0 {
                    Button(action: {
                        SoundEffectService.shared.play(.click)
                        viewModel.syncUpstreamEngine()
                    }) {
                        HStack(spacing: 6) {
                            Image(systemName: viewModel.isBuilding ? "lock.fill" : "arrow.triangle.merge")
                            Text(viewModel.isBuilding ? viewModel.tr("build.update_locked_badge") : viewModel.tr("updates.sync_upstream"))
                        }
                    }
                    .buttonStyle(NXPrimaryButtonStyle())
                    .disabled(viewModel.isBuilding || viewModel.isApplyingUpdate || viewModel.isSyncingUpstream)
                    .nxConsoleFocusRing(in: Capsule(), isFocused: viewModel.updateModalFocusIndex == actionIdx)
                }
            }
        }
    }
}
