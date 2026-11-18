import SwiftUI
import GameController

public struct AnalogDeadzoneTestView: View {
    @Binding public var deadzone: Double
    public var isFocused: Bool = false
    @State private var leftX: Float = 0
    @State private var leftY: Float = 0
    @State private var rightX: Float = 0
    @State private var rightY: Float = 0
    @State private var timer: Timer? = nil

    public init(deadzone: Binding<Double>, isFocused: Bool = false) {
        self._deadzone = deadzone
        self.isFocused = isFocused
    }

    public var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Label(L10n.t("controls.deadzone_title"), systemImage: "scope")
                    .font(.system(size: 13, weight: .bold, design: .rounded))
                    .foregroundColor(NXTheme.textPrimary)
                    .lineLimit(1)
                    .minimumScaleFactor(0.85)

                Spacer()
            }

            Divider().opacity(0.15)

            HStack(alignment: .top, spacing: 16) {
                // Left Stick Target
                stickRadarView(label: "Left Stick (LS)", x: leftX, y: leftY)

                // Right Stick Target
                stickRadarView(label: "Right Stick (RS)", x: rightX, y: rightY)

                // Column: Deadzone Slider ON TOP of Live Drift Monitor
                VStack(alignment: .leading, spacing: 10) {
                    // Deadzone Slider (on top of live drift monitor)
                    VStack(alignment: .leading, spacing: 4) {
                        HStack {
                            Text(L10n.t("controls.deadzone_label", Int(round(deadzone * 100))))
                                .font(.system(size: 11, weight: .bold, design: .monospaced))
                                .foregroundColor(.white)
                                .lineLimit(1)
                                .minimumScaleFactor(0.85)
                            Spacer()
                        }

                        NXLiquidGlassSlider(
                            value: $deadzone,
                            in: 0.05...0.30,
                            step: 0.01,
                            accentColor: isFocused ? NXTheme.secondary : NXTheme.primary
                        )
                        .frame(maxWidth: .infinity)
                        .padding(2)
                        .background(isFocused ? NXTheme.primary.opacity(0.12) : Color.clear)
                        .cornerRadius(8)
                        .overlay(
                            RoundedRectangle(cornerRadius: 8)
                                .stroke(isFocused ? NXTheme.secondary : Color.clear, lineWidth: 1.5)
                        )
                    }

                    // Live Drift Monitor (bellow slider)
                    VStack(alignment: .leading, spacing: 3) {
                        Text(L10n.t("controls.live_drift_monitor"))
                            .font(.system(size: 11, weight: .bold, design: .rounded))
                            .foregroundColor(NXTheme.textSecondary)
                            .lineLimit(1)
                            .minimumScaleFactor(0.85)

                        let isDrifting = isStickDrifting(x: leftX, y: leftY) || isStickDrifting(x: rightX, y: rightY)
                        Text(isDrifting ? "Drift Detected outside Deadzone" : "Centered & Stable (Within Deadzone)")
                            .font(.system(size: 10.5, weight: .semibold))
                            .foregroundColor(isDrifting ? Color(red: 0.91, green: 0.07, blue: 0.14) : Color(red: 0.13, green: 0.77, blue: 0.37))
                            .lineLimit(1)
                            .minimumScaleFactor(0.80)

                        Text(L10n.t("controls.deadzone_hint"))
                            .font(.system(size: 9.5))
                            .foregroundColor(NXTheme.textMuted)
                            .lineLimit(2)
                            .minimumScaleFactor(0.80)
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
        .padding(14)
        .nxGlassCard(cornerRadius: 18)
        .onAppear {
            startPolling()
        }
        .onDisappear {
            timer?.invalidate()
            timer = nil
        }
    }

    private func stickRadarView(label: String, x: Float, y: Float) -> some View {
        VStack(spacing: 6) {
            ZStack {
                // Outer circle
                Circle()
                    .fill(Color(white: 0.09))
                    .frame(width: 72, height: 72)
                    .overlay(Circle().stroke(Color.white.opacity(0.15), lineWidth: 1))

                // Deadzone safe zone
                Circle()
                    .stroke(Color.yellow.opacity(0.4), style: StrokeStyle(lineWidth: 1, dash: [2, 2]))
                    .frame(width: CGFloat(deadzone) * 72, height: CGFloat(deadzone) * 72)

                // Axes lines
                Rectangle()
                    .fill(Color.white.opacity(0.12))
                    .frame(width: 72, height: 1)

                Rectangle()
                    .fill(Color.white.opacity(0.12))
                    .frame(width: 1, height: 72)

                // Current stick position dot
                let posX = CGFloat(x) * 36
                let posY = CGFloat(-y) * 36

                Circle()
                    .fill(isStickDrifting(x: x, y: y) ? Color.red : Color.cyan)
                    .frame(width: 8, height: 8)
                    .offset(x: posX, y: posY)
                    .shadow(color: (isStickDrifting(x: x, y: y) ? Color.red : Color.cyan).opacity(0.8), radius: 4)
            }
            .frame(width: 72, height: 72)

            Text(label)
                .font(.system(size: 9.5, weight: .bold, design: .rounded))
                .foregroundColor(NXTheme.textSecondary)

            Text(String(format: "X: %+.2f Y: %+.2f", x, y))
                .font(.system(size: 9, weight: .semibold, design: .monospaced))
                .foregroundColor(isStickDrifting(x: x, y: y) ? Color(red: 0.91, green: 0.07, blue: 0.14) : NXTheme.textMuted)
        }
    }

    private func isStickDrifting(x: Float, y: Float) -> Bool {
        let magnitude = sqrt(Double(x * x + y * y))
        return magnitude > deadzone
    }

    private func startPolling() {
        timer?.invalidate()
        timer = Timer.scheduledTimer(withTimeInterval: 0.033, repeats: true) { _ in
            guard NSApplication.shared.isActive && !MenuBarManager.isMinimized else { return }
            if let pad = GCController.controllers().first?.extendedGamepad {
                self.leftX = pad.leftThumbstick.xAxis.value
                self.leftY = pad.leftThumbstick.yAxis.value
                self.rightX = pad.rightThumbstick.xAxis.value
                self.rightY = pad.rightThumbstick.yAxis.value
            }
        }
    }
}
