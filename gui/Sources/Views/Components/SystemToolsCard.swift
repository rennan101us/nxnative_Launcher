import SwiftUI

public struct SystemToolsCard: View {
    @ObservedObject public var viewModel: AppViewModel
    
    public init(viewModel: AppViewModel) {
        self.viewModel = viewModel
    }
    
    public var body: some View {
        GlassCard {
            VStack(alignment: .leading, spacing: 14) {
                // Header
                HStack(spacing: 10) {
                    Label(viewModel.tr("system.tools_title"), systemImage: "wrench.and.screwdriver.fill")
                        .symbolRenderingMode(.hierarchical)
                        .font(.system(size: 13, weight: .bold, design: .rounded))
                        .foregroundColor(NXTheme.textPrimary)
                        .help(viewModel.tr("system.tools_help"))
                    
                    Spacer()
                    
                    let isAllReady = viewModel.prerequisites.allSatisfied(for: viewModel.selectedOnboardingPlatforms)
                    let missingCount = viewModel.prerequisites.missingList(for: viewModel.selectedOnboardingPlatforms).count
                    StatusBadge(
                        isPositive: isAllReady,
                        text: isAllReady ? viewModel.tr("system.deps_ready") : viewModel.tr("system.deps_missing_count", missingCount)
                    )
                }
                
                if viewModel.isDeveloperMode {
                    developerModeContent
                } else {
                    simpleModeContent
                }
            }
        }
    }
    
    // MARK: - Simple Mode (Normal Users: 1 Button to Install All + Compact Log/Progress)
    @ViewBuilder
    private var simpleModeContent: some View {
        VStack(spacing: 12) {
            if !viewModel.prerequisites.allSatisfied(for: viewModel.selectedOnboardingPlatforms) {
                // Single button to install all
                Button(action: {
                    SoundEffectService.shared.play(.click)
                    viewModel.installAllMissingDependencies(openSheet: false)
                }) {
                    HStack(spacing: 8) {
                        if viewModel.isInstallingDependency {
                            ProgressView()
                                .controlSize(.small)
                            Text(viewModel.tr("common.installing"))
                        } else {
                            Image(systemName: "arrow.down.circle.fill")
                            Text(viewModel.tr("system.install_all"))
                        }
                    }
                    .font(.system(size: 13, weight: .bold, design: .rounded))
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 10)
                }
                .buttonStyle(NXAccentButtonStyle())
                .disabled(viewModel.isInstallingDependency)
            } else {
                // Everything is ready
                HStack(spacing: 12) {
                    Image(systemName: "checkmark.seal.fill")
                        .font(.system(size: 20))
                        .foregroundColor(Color(red: 0.13, green: 0.77, blue: 0.37))
                    
                    VStack(alignment: .leading, spacing: 2) {
                        Text(viewModel.tr("system.all_tools_ready"))
                            .font(.system(size: 13, weight: .bold, design: .rounded))
                            .foregroundColor(NXTheme.textPrimary)
                        Text(viewModel.tr("system.tools_help"))
                            .font(.system(size: 11))
                            .foregroundColor(NXTheme.textSecondary)
                    }
                    
                    Spacer()
                    
                    Button(action: {
                        SoundEffectService.shared.play(.click)
                        viewModel.refreshPrerequisites()
                    }) {
                        HStack(spacing: 4) {
                            Image(systemName: "arrow.triangle.2.circlepath")
                            Text(viewModel.tr("system.repair_recheck"))
                        }
                        .font(.system(size: 11, weight: .semibold, design: .rounded))
                    }
                    .buttonStyle(NXSecondaryButtonStyle())
                    .controlSize(.small)
                }
                .padding(12)
                .nxGlassCard(cornerRadius: 10, isNested: true)
            }
            
            // Inline compact log & progress
            if viewModel.isInstallingDependency || !viewModel.installerLogs.isEmpty {
                VStack(alignment: .leading, spacing: 6) {
                    HStack {
                        Text(viewModel.isInstallingDependency ? viewModel.tr("common.installing") : "Log de Instalação")
                            .font(.system(size: 11, weight: .semibold, design: .rounded))
                            .foregroundColor(NXTheme.textSecondary)
                        Spacer()
                        if viewModel.isInstallingDependency {
                            ProgressView().controlSize(.mini)
                        }
                    }
                    
                    ScrollViewReader { proxy in
                        ScrollView {
                            LazyVStack(alignment: .leading, spacing: 3) {
                                ForEach(Array(viewModel.installerLogs.enumerated()), id: \.offset) { idx, line in
                                    let isError = line.lowercased().contains("error") || line.lowercased().contains("failed")
                                    Text(line)
                                        .font(.system(size: 10, design: .monospaced))
                                        .foregroundColor(isError ? Color.red : NXTheme.textPrimary)
                                        .id(idx)
                                }
                            }
                            .padding(8)
                        }
                        .frame(height: 100)
                        .nxGlassCard(cornerRadius: 8, isNested: true)
                        .onChange(of: viewModel.installerLogs.count) { _ in
                            if let last = viewModel.installerLogs.indices.last {
                                proxy.scrollTo(last, anchor: .bottom)
                            }
                        }
                    }
                }
            }
        }
    }
    
    // MARK: - Developer Mode Content (Granular Dependency Control)
    @ViewBuilder
    private var developerModeContent: some View {
        VStack(spacing: 12) {
            // Missing Dependencies Action Callout
            let scopedMissing = viewModel.prerequisites.missingList(for: viewModel.selectedOnboardingPlatforms)
            if !scopedMissing.isEmpty {
                HStack(spacing: 12) {
                    Image(systemName: "arrow.down.circle.fill")
                        .font(.system(size: 22))
                        .foregroundColor(NXTheme.tertiary)
                    
                    VStack(alignment: .leading, spacing: 2) {
                        Text(viewModel.tr("system.missing_deps_title", scopedMissing.count))
                            .font(.system(size: 13, weight: .bold, design: .rounded))
                            .foregroundColor(NXTheme.textPrimary)
                        Text(viewModel.tr("system.missing_deps_desc"))
                            .font(.system(size: 11))
                            .foregroundColor(NXTheme.textSecondary)
                    }
                    
                    Spacer()
                    
                    Button(action: {
                        SoundEffectService.shared.play(.click)
                        viewModel.installAllMissingDependencies()
                    }) {
                        HStack(spacing: 6) {
                            if viewModel.isInstallingDependency {
                                ProgressView().controlSize(.small)
                                Text(viewModel.tr("common.installing"))
                            } else {
                                Image(systemName: "play.fill")
                                Text(viewModel.tr("build.install_all_seq"))
                            }
                        }
                        .font(.system(size: 12, weight: .bold, design: .rounded))
                    }
                    .buttonStyle(NXAccentButtonStyle())
                    .disabled(viewModel.isInstallingDependency)
                }
                .padding(12)
                .nxGlassCard(cornerRadius: 10, isNested: true)
                .overlay(
                    RoundedRectangle(cornerRadius: 10, style: .continuous)
                        .strokeBorder(NXTheme.tertiary.opacity(0.35), lineWidth: 1)
                )
            }
            
            // Detailed Dependency rows list (Grouped by Platform)
            VStack(alignment: .leading, spacing: 10) {
                // Core & Apple Dependencies
                VStack(alignment: .leading, spacing: 8) {
                    Text(viewModel.tr("system.core_apple_tools_title"))
                        .font(.system(size: 11, weight: .bold, design: .rounded))
                        .foregroundColor(NXTheme.textSecondary)
                    
                    ForEach(viewModel.prerequisites.list.filter { $0.category != .android }) { item in
                        DependencyRow(item: item, viewModel: viewModel)
                    }
                }

                // Android Porting Toolchain
                VStack(alignment: .leading, spacing: 8) {
                    HStack(spacing: 8) {
                        Image(systemName: "candybarphone")
                            .font(.system(size: 12, weight: .bold))
                            .foregroundColor(NXTheme.primary)
                        Text(viewModel.tr("system.android_toolchain_title"))
                            .font(.system(size: 11, weight: .bold, design: .rounded))
                            .foregroundColor(NXTheme.textPrimary)
                        Spacer()
                        Text("~1.12 GB download")
                            .font(.system(size: 9.5, weight: .semibold, design: .monospaced))
                            .foregroundColor(NXTheme.secondary)
                            .padding(.horizontal, 6)
                            .padding(.vertical, 2)
                            .background(NXTheme.glassSurfaceElevated.opacity(0.85))
                            .clipShape(Capsule())
                    }

                    ForEach(viewModel.prerequisites.list.filter { $0.category == .android }) { item in
                        DependencyRow(item: item, viewModel: viewModel)
                    }
                }
                .padding(10)
                .nxGlassCard(cornerRadius: 12, isNested: true)
            }
            
            // Bottom Action Bar
            HStack {
                Button(action: {
                    SoundEffectService.shared.play(.click)
                    viewModel.refreshPrerequisites()
                }) {
                    HStack(spacing: 4) {
                        Image(systemName: "arrow.triangle.2.circlepath")
                        Text(viewModel.tr("system.repair_recheck"))
                    }
                }
                .buttonStyle(NXSecondaryButtonStyle())
                .controlSize(.small)
                
                Spacer()
                
                Button(viewModel.tr("system.repair_all")) {
                    SoundEffectService.shared.play(.click)
                    viewModel.repairAllDependencies()
                }
                .buttonStyle(NXSecondaryButtonStyle())
                .controlSize(.small)
                .help(viewModel.tr("system.repair_all_help"))
            }
            .padding(.top, 4)
        }
    }
}
