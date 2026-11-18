import SwiftUI
import AppKit

/// Floating Apple Liquid Glass banner and modal alert for shader prebuilding status and recovery.
public struct ShaderPrebuildHUDView: View {
    @ObservedObject var service = ShaderPrebuildService.shared
    @ObservedObject var viewModel: AppViewModel
    
    public init(viewModel: AppViewModel) {
        self.viewModel = viewModel
    }
    
    public var body: some View {
        ZStack {
            // 1. Active Launch Monitoring Banner (Floating Pill at top of screen)
            if service.isPrebuilding {
                VStack {
                    activePrebuildBanner
                        .padding(.top, 14)
                        .transition(.move(edge: .top).combined(with: .opacity))
                    Spacer()
                }
                .zIndex(200)
            }
            
            // 2. Interrupted Shader Prebuild Recovery Modal
            if service.showInterruptedAlert, let game = service.interruptedGame {
                interruptedRecoveryModal(for: game)
                    .zIndex(210)
                    .transition(.opacity.combined(with: .scale(scale: 0.95)))
            }
            
            // 3. Headless Background Prebuild Progress HUD (if launched from alert or settings)
            if service.isRunningHeadlessPrebuild {
                VStack {
                    headlessPrebuildHUD
                        .padding(.top, 14)
                        .transition(.move(edge: .top).combined(with: .opacity))
                    Spacer()
                }
                .zIndex(205)
            }
        }
        .animation(.spring(response: 0.35, dampingFraction: 0.82), value: service.isPrebuilding)
        .animation(.spring(response: 0.35, dampingFraction: 0.82), value: service.showInterruptedAlert)
        .animation(.spring(response: 0.35, dampingFraction: 0.82), value: service.isRunningHeadlessPrebuild)
    }
    
    // MARK: - Active Prebuild Floating Banner
    private var activePrebuildBanner: some View {
        HStack(spacing: 14) {
            ZStack {
                Circle()
                    .fill(NXTheme.primary.opacity(0.20))
                    .frame(width: 38, height: 38)
                Image(systemName: "gearshape.arrow.triangle.2.circlepath")
                    .font(.system(size: 18, weight: .bold))
                    .foregroundColor(NXTheme.primary)
            }
            
            VStack(alignment: .leading, spacing: 4) {
                HStack(spacing: 8) {
                    Text(L10n.t("shader.prebuild_active_title"))
                        .font(.system(size: 13, weight: .bold, design: .rounded))
                        .foregroundColor(NXTheme.textPrimary)
                    
                    if service.totalPairs > 0 {
                        Text("\(service.currentPairs) / \(service.totalPairs) (\(Int(service.progress * 100))%)")
                            .font(.system(size: 11, weight: .bold, design: .monospaced))
                            .foregroundColor(NXTheme.secondary)
                    }
                }
                
                // Progress Bar
                GeometryReader { barGeo in
                    ZStack(alignment: .leading) {
                        Capsule()
                            .fill(Color.white.opacity(0.12))
                            .frame(height: 6)
                        
                        Capsule()
                            .fill(
                                LinearGradient(
                                    colors: [NXTheme.primary, NXTheme.secondary],
                                    startPoint: .leading,
                                    endPoint: .trailing
                                )
                            )
                            .frame(width: max(6, barGeo.size.width * CGFloat(service.progress)), height: 6)
                    }
                }
                .frame(height: 6)
                
                Text(L10n.t("shader.prebuild_active_desc", service.activeGameName))
                    .font(.system(size: 10.5, weight: .medium))
                    .foregroundColor(NXTheme.textSecondary)
                    .lineLimit(1)
            }
            .frame(width: 380)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 12)
        .nxGlassCard(cornerRadius: 18)
        .shadow(color: Color.black.opacity(0.40), radius: 16, x: 0, y: 8)
    }
    
    // MARK: - Interrupted Prebuild Recovery Modal
    private func interruptedRecoveryModal(for game: PortedGame) -> some View {
        ZStack {
            Color.black.opacity(0.60)
                .ignoresSafeArea()
                .onTapGesture {
                    service.showInterruptedAlert = false
                }
            
            VStack(alignment: .leading, spacing: 14) {
                HStack(spacing: 12) {
                    Image(systemName: "exclamationmark.triangle.fill")
                        .font(.system(size: 22, weight: .bold))
                        .foregroundColor(.orange)
                    
                    VStack(alignment: .leading, spacing: 2) {
                        Text(L10n.t("shader.interrupted_title"))
                            .font(.system(size: 15, weight: .bold, design: .rounded))
                            .foregroundColor(NXTheme.textPrimary)
                        Text(game.name)
                            .font(.system(size: 12, weight: .semibold))
                            .foregroundColor(NXTheme.secondary)
                    }
                    
                    Spacer()
                    
                    NXModalCloseButton(size: 28) {
                        service.showInterruptedAlert = false
                    }
                }
                
                Text(L10n.t("shader.interrupted_desc", service.interruptedCurrentPairs, service.interruptedTotalPairs))
                    .font(.system(size: 12))
                    .foregroundColor(NXTheme.textPrimary.opacity(0.90))
                    .lineSpacing(3)
                
                Divider().opacity(0.20)
                
                HStack(spacing: 10) {
                    Spacer()
                    
                    Button(L10n.t("shader.dismiss_btn")) {
                        SoundEffectService.shared.play(.click)
                        service.showInterruptedAlert = false
                    }
                    .buttonStyle(NXSecondaryButtonStyle())
                    
                    Button(L10n.t("shader.resume_btn")) {
                        SoundEffectService.shared.play(.click)
                        service.showInterruptedAlert = false
                        service.prebuildShadersHeadless(for: game) { success, _ in
                            if success {
                                viewModel.logs.append(LogEntry(level: .success, message: "Shader optimization complete for \(game.name)."))
                            }
                        }
                    }
                    .buttonStyle(NXPrimaryButtonStyle())
                }
            }
            .padding(22)
            .frame(maxWidth: 480)
            .nxGlassCard(cornerRadius: 20)
            .shadow(color: Color.black.opacity(0.50), radius: 24, x: 0, y: 12)
        }
    }
    
    // MARK: - Headless Prebuild Progress HUD
    private var headlessPrebuildHUD: some View {
        HStack(spacing: 14) {
            ProgressView()
                .controlSize(.small)
            
            VStack(alignment: .leading, spacing: 4) {
                HStack(spacing: 8) {
                    Text(L10n.t("shader.prebuild_active_title"))
                        .font(.system(size: 13, weight: .bold, design: .rounded))
                        .foregroundColor(NXTheme.textPrimary)
                    
                    if service.headlessTotalPairs > 0 {
                        Text("\(service.headlessCurrentPairs) / \(service.headlessTotalPairs) (\(Int(service.headlessPrebuildProgress * 100))%)")
                            .font(.system(size: 11, weight: .bold, design: .monospaced))
                            .foregroundColor(NXTheme.secondary)
                    }
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
                            .frame(width: max(6, barGeo.size.width * CGFloat(service.headlessPrebuildProgress)), height: 6)
                    }
                }
                .frame(height: 6)
                
                Text(service.headlessStatusMessage)
                    .font(.system(size: 10.5, weight: .medium))
                    .foregroundColor(NXTheme.textSecondary)
                    .lineLimit(1)
            }
            .frame(width: 380)
            
            Button {
                service.cancelHeadlessPrebuild()
            } label: {
                Image(systemName: "xmark.circle.fill")
                    .foregroundColor(NXTheme.textSecondary)
                    .font(.system(size: 16))
            }
            .buttonStyle(.plain)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 12)
        .nxGlassCard(cornerRadius: 18)
        .shadow(color: Color.black.opacity(0.40), radius: 16, x: 0, y: 8)
    }
}
