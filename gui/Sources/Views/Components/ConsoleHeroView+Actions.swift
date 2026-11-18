import SwiftUI
import AppKit

// MARK: - Dedicated Stateful Action Buttons with Hover & Selection Illumination
internal struct HeroPrimaryPlayButton: View {
    let isLaunching: Bool
    let isFocused: Bool
    let action: () -> Void
    @ObservedObject private var i18n = LocalizationService.shared
    @Environment(\.nxLiquidGlass) private var glassEnv
    @State private var isHovered: Bool = false

    private var isActive: Bool { isFocused || isHovered }

    var body: some View {
        Button(action: action) {
            HStack(spacing: 8) {
                if isLaunching {
                    ProgressView()
                        .controlSize(.small)
                    Text(i18n.t("common.launching"))
                        .font(.system(size: 13, weight: .bold, design: .rounded))
                } else {
                    Image(systemName: "play.fill")
                        .font(.system(size: 12))
                    Text(i18n.t("common.play"))
                        .font(.system(size: 14, weight: .bold, design: .rounded))
                }
            }
            .foregroundColor(.white)
            .padding(.horizontal, 22)
            .padding(.vertical, 10)
            .contentShape(Capsule())
            .nxGlassInteractive(
                in: Capsule(),
                tint: isActive ? NXTheme.primary.opacity(glassEnv.appearance == .liquid ? 0.76 : 0.88) : nil,
                isSelected: isActive,
                isInteractive: !isLaunching,
                fallbackFill: isActive ? NXTheme.primary : NXTheme.glassSurfaceElevated.opacity(0.85),
                fallbackSelectedFill: isActive ? NXTheme.primary : NXTheme.glassSurfaceElevated.opacity(0.85)
            )
            .overlay(
                Capsule()
                    .strokeBorder(
                        isActive
                            ? AnyShapeStyle(LinearGradient(colors: [Color.white, NXTheme.primary], startPoint: .topLeading, endPoint: .bottomTrailing))
                            : AnyShapeStyle(Color.white.opacity(0.18)),
                        lineWidth: isActive ? 2.5 : 1.0
                    )
            )
            .animation(.easeInOut(duration: 0.18), value: isActive)
        }
        .buttonStyle(NXPressableButtonStyle())
        .disabled(isLaunching)
        .nxNoFocusRing()
        .nxGlassTransition(.identity)
        .onHover { isHovered = $0 }
    }
}

internal struct HeroIosDeviceButton: View {
    let game: PortedGame
    let isFocused: Bool
    let action: () -> Void
    @ObservedObject private var i18n = LocalizationService.shared
    @ObservedObject private var deviceService = DeviceDeploymentService.shared
    @ObservedObject private var deploymentTracker = IosDeploymentTracker.shared
    @Environment(\.nxLiquidGlass) private var glassEnv
    @State private var isHovered: Bool = false

    private var isActive: Bool { isFocused || isHovered }

    var body: some View {
        let isDeployed = deploymentTracker.isGameDeployed(game)
        let record = deploymentTracker.deploymentRecord(for: game)
        let isExpired = record?.isExpired ?? false
        let activeColor = isExpired ? Color.red : NXTheme.primary

        Button(action: action) {
            HStack(spacing: 8) {
                if deviceService.activeDeployment.isRunning {
                    ProgressView()
                        .controlSize(.small)
                    Text("\(deviceService.activeDeployment.phase.rawValue) (\(Int(deviceService.activeDeployment.progressFraction * 100))%)")
                        .font(.system(size: 13, weight: .bold, design: .rounded))
                } else {
                    Image(systemName: isDeployed ? "arrow.triangle.2.circlepath" : "arrow.up.forward.app")
                        .font(.system(size: 13))
                    Text(
                        isDeployed
                            ? (isExpired ? i18n.t("console.renew_ios_expired") : i18n.t("console.renew_ios"))
                            : i18n.t("console.send_ios")
                    )
                    .font(.system(size: 14, weight: .bold, design: .rounded))
                }
            }
            .foregroundColor(.white)
            .padding(.horizontal, 20)
            .padding(.vertical, 10)
            .contentShape(Capsule())
            .nxGlassInteractive(
                in: Capsule(),
                tint: isActive ? activeColor.opacity(glassEnv.appearance == .liquid ? 0.76 : 0.88) : nil,
                isSelected: isActive,
                fallbackFill: isActive ? activeColor : NXTheme.glassSurfaceElevated.opacity(0.85),
                fallbackSelectedFill: isActive ? activeColor : NXTheme.glassSurfaceElevated.opacity(0.85)
            )
            .overlay(
                Capsule()
                    .strokeBorder(
                        isActive ? Color.white : Color.white.opacity(0.18),
                        lineWidth: isActive ? 2.5 : 1.0
                    )
            )
            .animation(.easeInOut(duration: 0.18), value: isActive)
        }
        .buttonStyle(NXPressableButtonStyle())
        .nxNoFocusRing()
        .nxGlassTransition(.identity)
        .onHover { isHovered = $0 }
    }
}

internal struct HeroPortNowButton: View {
    let isBuilding: Bool
    let progressFraction: Double
    let isFocused: Bool
    let action: () -> Void
    @ObservedObject private var i18n = LocalizationService.shared
    @Environment(\.nxLiquidGlass) private var glassEnv
    @State private var isHovered: Bool = false

    private var isActive: Bool { isFocused || isHovered }

    var body: some View {
        Button(action: action) {
            HStack(spacing: 8) {
                if isBuilding {
                    ProgressView()
                        .controlSize(.small)
                    Text("Building (\(Int(progressFraction * 100))%)")
                        .font(.system(size: 13, weight: .bold, design: .rounded))
                } else {
                    Image(systemName: "play.circle.fill")
                        .font(.system(size: 13))
                    Text(i18n.t("library.port_now"))
                        .font(.system(size: 14, weight: .bold, design: .rounded))
                }
            }
            .foregroundColor(.white)
            .padding(.horizontal, 22)
            .padding(.vertical, 10)
            .contentShape(Capsule())
            .nxGlassInteractive(
                in: Capsule(),
                tint: isActive ? NXTheme.primary.opacity(0.88) : nil,
                isSelected: isActive,
                isInteractive: !isBuilding,
                fallbackFill: isActive ? NXTheme.primary : NXTheme.glassSurfaceElevated.opacity(0.85),
                fallbackSelectedFill: isActive ? NXTheme.primary : NXTheme.glassSurfaceElevated.opacity(0.85)
            )
            .overlay(
                Capsule()
                    .strokeBorder(
                        isActive ? Color.white : Color.white.opacity(0.18),
                        lineWidth: isActive ? 2.5 : 1.0
                    )
            )
            .animation(.easeInOut(duration: 0.18), value: isActive)
        }
        .buttonStyle(NXPressableButtonStyle())
        .disabled(isBuilding)
        .nxNoFocusRing()
        .nxGlassTransition(.identity)
        .onHover { isHovered = $0 }
    }
}

internal struct HeroHoverSecondaryButton: View {
    let icon: String
    let title: String
    let isFocused: Bool
    let action: () -> Void
    @State private var isHovered: Bool = false

    private var isActive: Bool { isFocused || isHovered }

    var body: some View {
        Button(action: action) {
            HStack(spacing: 6) {
                Image(systemName: icon)
                Text(title)
                    .font(.system(size: 12, weight: .semibold, design: .rounded))
            }
            .foregroundColor(isActive ? .white : NXTheme.textPrimary)
            .padding(.horizontal, 14)
            .padding(.vertical, 10)
            .contentShape(Capsule())
            .nxGlassInteractive(
                in: Capsule(),
                tint: isActive ? NXTheme.primary.opacity(0.76) : nil,
                isSelected: isActive,
                fallbackFill: isActive ? NXTheme.primary.opacity(0.85) : NXTheme.glassSurfaceElevated.opacity(0.85)
            )
            .overlay(
                Capsule()
                    .strokeBorder(
                        isActive ? Color.white : Color.white.opacity(0.18),
                        lineWidth: isActive ? 2 : 1
                    )
            )
            .animation(.easeInOut(duration: 0.18), value: isActive)
        }
        .buttonStyle(NXPressableButtonStyle())
        .nxNoFocusRing()
        .nxGlassTransition(.identity)
        .onHover { isHovered = $0 }
    }
}

internal struct HeroHoverIconButton: View {
    let icon: String
    let isFocused: Bool
    let helpText: String
    let action: () -> Void
    @State private var isHovered: Bool = false

    private var isActive: Bool { isFocused || isHovered }

    var body: some View {
        Button(action: action) {
            Image(systemName: icon)
                .font(.system(size: 13, weight: .bold))
                .foregroundColor(isActive ? .white : NXTheme.textPrimary)
                .frame(width: 36, height: 36)
                .contentShape(Circle())
                .nxGlassInteractive(
                    in: Circle(),
                    tint: isActive ? NXTheme.primary.opacity(0.76) : nil,
                    isSelected: isActive,
                    fallbackFill: isActive ? NXTheme.primary.opacity(0.85) : NXTheme.glassSurfaceElevated.opacity(0.85)
                )
                .overlay(
                    Circle()
                        .strokeBorder(
                            isActive ? Color.white : Color.white.opacity(0.18),
                            lineWidth: 2
                        )
                )
                .animation(.easeInOut(duration: 0.18), value: isActive)
        }
        .buttonStyle(NXPressableButtonStyle())
        .help(helpText)
        .nxNoFocusRing()
        .nxGlassTransition(.identity)
        .onHover { isHovered = $0 }
    }
}

