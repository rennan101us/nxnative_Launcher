import SwiftUI
import AppKit

/// Apple Liquid Glass settings card for inspecting and one-click prebuilding Metal 4 shader pipelines.
public struct GameSettingsShaderSectionView: View {
    public let game: PortedGame
    @ObservedObject public var viewModel: AppViewModel
    @ObservedObject private var shaderService = ShaderPrebuildService.shared
    @State private var shaderStatus: ShaderCacheStatus = .notApplicable
    
    public init(game: PortedGame, viewModel: AppViewModel) {
        self.game = game
        self.viewModel = viewModel
    }
    
    private var isThisGameHeadless: Bool {
        shaderService.isRunningHeadlessPrebuild
    }
    
    public var body: some View {
        if shaderStatus != .notApplicable {
            VStack(alignment: .leading, spacing: 12) {
                // Header
                HStack(alignment: .center, spacing: 10) {
                    Image(systemName: "cpu.fill")
                        .font(.system(size: 15, weight: .bold))
                        .foregroundColor(NXTheme.primary)
                    
                    VStack(alignment: .leading, spacing: 2) {
                        Text(viewModel.tr("shader.section_title"))
                            .font(.system(size: 13, weight: .bold, design: .rounded))
                            .foregroundColor(NXTheme.textPrimary)
                        
                        Text(viewModel.tr("shader.section_desc"))
                            .font(.system(size: 10.5, weight: .medium))
                            .foregroundColor(NXTheme.textSecondary)
                    }
                    
                    Spacer()
                    
                    statusBadge
                }
                
                Divider().opacity(0.15)
                
                // Action / Progress Row
                if isThisGameHeadless {
                    headlessProgressRow
                } else if case .needsPrebuild(let total) = shaderStatus {
                    HStack {
                        Text(L10n.t("shader.status_pending", total))
                            .font(.system(size: 11, weight: .medium))
                            .foregroundColor(.orange)
                        
                        Spacer()
                        
                        Button {
                            SoundEffectService.shared.play(.click)
                            shaderService.prebuildShadersHeadless(for: game) { success, _ in
                                refreshStatus()
                            }
                        } label: {
                            HStack(spacing: 6) {
                                Image(systemName: "bolt.fill")
                                Text(viewModel.tr("shader.prebuild_btn"))
                            }
                        }
                        .buttonStyle(NXPrimaryButtonStyle())
                        .controlSize(.small)
                    }
                } else if case .alreadyOptimized = shaderStatus {
                    HStack(spacing: 6) {
                        Image(systemName: "checkmark.circle.fill")
                            .foregroundColor(.green)
                            .font(.system(size: 12))
                        Text(viewModel.tr("shader.prebuild_success"))
                            .font(.system(size: 11, weight: .medium))
                            .foregroundColor(NXTheme.textSecondary)
                        Spacer()
                    }
                }
            }
            .padding(14)
            .nxGlassCard(cornerRadius: 14)
            .onAppear {
                refreshStatus()
            }
        }
    }
    
    // MARK: - Status Badge
    @ViewBuilder
    private var statusBadge: some View {
        switch shaderStatus {
        case .alreadyOptimized:
            HStack(spacing: 4) {
                Circle().fill(Color.green).frame(width: 6, height: 6)
                Text(viewModel.tr("shader.status_optimized"))
                    .font(.system(size: 10.5, weight: .bold, design: .rounded))
                    .foregroundColor(.green)
            }
            .padding(.horizontal, 8)
            .padding(.vertical, 4)
            .background(Color.green.opacity(0.12))
            .cornerRadius(8)
            
        case .needsPrebuild:
            HStack(spacing: 4) {
                Circle().fill(Color.orange).frame(width: 6, height: 6)
                Text(viewModel.tr("shader.prebuild_required"))
                    .font(.system(size: 10.5, weight: .bold, design: .rounded))
                    .foregroundColor(.orange)
            }
            .padding(.horizontal, 8)
            .padding(.vertical, 4)
            .background(Color.orange.opacity(0.12))
            .cornerRadius(8)
            
        case .notApplicable:
            EmptyView()
        }
    }
    
    // MARK: - Headless Progress Row
    private var headlessProgressRow: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Text(L10n.t("shader.prebuilding_progress", shaderService.headlessCurrentPairs, shaderService.headlessTotalPairs, shaderService.headlessPrebuildProgress * 100))
                    .font(.system(size: 11.5, weight: .bold, design: .monospaced))
                    .foregroundColor(NXTheme.secondary)
                Spacer()
                ProgressView()
                    .controlSize(.mini)
            }
            
            GeometryReader { barGeo in
                ZStack(alignment: .leading) {
                    Capsule()
                        .fill(Color.white.opacity(0.12))
                        .frame(height: 6)
                    
                    Capsule()
                        .fill(
                            LinearGradient(
                                colors: [Color.green, NXTheme.primary],
                                startPoint: .leading,
                                endPoint: .trailing
                            )
                        )
                        .frame(width: max(6, barGeo.size.width * CGFloat(shaderService.headlessPrebuildProgress)), height: 6)
                }
            }
            .frame(height: 6)
        }
        .padding(8)
        .nxGlassCard(cornerRadius: 10, isNested: true)
    }
    
    private func refreshStatus() {
        shaderStatus = shaderService.checkShaderStatus(for: game)
    }
}
