import SwiftUI

public enum MousePlatformTab: String, CaseIterable, Identifiable {
    case switch1 = "switch1"
    case switch2 = "switch2"
    public var id: String { rawValue }
}

public struct MouseLookSettingsView: View {
    @Binding public var profile: ControllerProfile
    public var isMasterFocused: Bool = false
    public var isSensitivityFocused: Bool = false
    public var isInvertXFocused: Bool = false
    public var isInvertYFocused: Bool = false
    public var isModeFocused: Bool = false
    
    @State private var selectedTab: MousePlatformTab = .switch1
    
    public init(
        profile: Binding<ControllerProfile>,
        isMasterFocused: Bool = false,
        isSensitivityFocused: Bool = false,
        isInvertXFocused: Bool = false,
        isInvertYFocused: Bool = false,
        isModeFocused: Bool = false
    ) {
        self._profile = profile
        self.isMasterFocused = isMasterFocused
        self.isSensitivityFocused = isSensitivityFocused
        self.isInvertXFocused = isInvertXFocused
        self.isInvertYFocused = isInvertYFocused
        self.isModeFocused = isModeFocused
    }
    
    public var body: some View {
        GlassCard {
            VStack(alignment: .leading, spacing: 14) {
                // Header & Active Tab Indicator Pill
                HStack(alignment: .center) {
                    Label(L10n.t("controls.mouse_input_mode"), systemImage: "cursorarrow.motionlines")
                        .font(.system(size: 13, weight: .bold, design: .rounded))
                        .foregroundColor(NXTheme.textPrimary)
                    
                    Spacer()
                    
                    HStack(spacing: 5) {
                        Image(systemName: selectedTab == .switch2 ? "2.circle.fill" : "1.circle.fill")
                            .font(.system(size: 10, weight: .bold))
                            .foregroundColor(selectedTab == .switch2 ? Color(red: 0.20, green: 0.85, blue: 0.50) : Color(red: 0.20, green: 0.60, blue: 1.00))
                        Text(selectedTab == .switch2 ? "Switch 2 Native" : "Switch 1 R-Stick")
                            .font(.system(size: 10, weight: .bold, design: .rounded))
                            .foregroundColor(.white)
                    }
                    .padding(.horizontal, 8)
                    .padding(.vertical, 3)
                    .background(
                        (selectedTab == .switch2 ? Color(red: 0.20, green: 0.85, blue: 0.50) : Color(red: 0.20, green: 0.60, blue: 1.00)).opacity(0.18)
                    )
                    .cornerRadius(6)
                }

                // 2 Liquid Glass Tabs: Mouse for Switch 1 & Mouse for Switch 2
                NXLiquidSegmentedPicker(
                    selection: $selectedTab,
                    options: [
                        NXSegmentOption(
                            value: .switch1,
                            title: L10n.t("controls.mouse_tab_switch1"),
                            icon: "1.circle.fill"
                        ),
                        NXSegmentOption(
                            value: .switch2,
                            title: L10n.t("controls.mouse_tab_switch2"),
                            icon: "2.circle.fill"
                        )
                    ]
                )
                
                // Active Tab Content
                switch selectedTab {
                case .switch1:
                    switch1TabView
                case .switch2:
                    switch2TabView
                }
            }
        }
    }

    // MARK: - Tab 1: Mouse for Switch 1 (Emulated Right Stick)

    @ViewBuilder
    private var switch1TabView: some View {
        VStack(alignment: .leading, spacing: 12) {
            // Switch 1 Banner
            HStack(spacing: 8) {
                Image(systemName: "1.circle.fill")
                    .font(.system(size: 14, weight: .bold))
                    .foregroundColor(Color(red: 0.20, green: 0.60, blue: 1.00))
                Text(L10n.t("controls.mouse_switch1_banner"))
                    .font(.system(size: 11, weight: .medium))
                    .foregroundColor(NXTheme.textSecondary)
                Spacer()
            }
            .padding(9)
            .background(Color(red: 0.20, green: 0.60, blue: 1.00).opacity(0.08))
            .cornerRadius(9)
            .overlay(
                RoundedRectangle(cornerRadius: 9)
                    .stroke(Color(red: 0.20, green: 0.60, blue: 1.00).opacity(0.18), lineWidth: 1)
            )

            // Master Toggle: Enable Mouse as Right Stick
            Toggle(isOn: $profile.mouseAsRightStick) {
                VStack(alignment: .leading, spacing: 2) {
                    Text(L10n.t("controls.mouse_right_stick_title"))
                        .font(.system(size: 12, weight: .semibold, design: .rounded))
                        .foregroundColor(NXTheme.textPrimary)
                    Text(L10n.t("controls.mouse_right_stick_desc"))
                        .font(.system(size: 10))
                        .foregroundColor(NXTheme.textSecondary)
                }
            }
            .toggleStyle(SwitchToggleStyle(tint: Color(red: 0.20, green: 0.60, blue: 1.00)))
            .padding(6)

            if profile.mouseAsRightStick {
                Divider().opacity(0.15)
                
                // Sensitivity Slider (Liquid Glass)
                HStack {
                    Text(L10n.t("controls.mouse_sensitivity"))
                        .font(.system(size: 11, weight: .medium))
                        .foregroundColor(isSensitivityFocused ? NXTheme.primary : NXTheme.textPrimary)
                    
                    Spacer()
                    
                    Text(String(format: "%.1fx", profile.mouseSensitivity))
                        .font(.system(size: 11, weight: .bold, design: .monospaced))
                        .foregroundColor(isSensitivityFocused ? .white : NXTheme.secondary)
                }
                
                NXLiquidGlassSlider(
                    value: $profile.mouseSensitivity,
                    in: 0.5...100.0,
                    step: 0.5,
                    accentColor: Color(red: 0.20, green: 0.60, blue: 1.00)
                )
                .frame(height: 24)
                .padding(6)
                .background(isSensitivityFocused ? NXTheme.primary.opacity(0.12) : Color.clear)
                .cornerRadius(8)
                .overlay(
                    RoundedRectangle(cornerRadius: 8)
                        .stroke(isSensitivityFocused ? NXTheme.secondary : Color.clear, lineWidth: 1.5)
                )
                
                // Invert X Axis
                Toggle(isOn: $profile.mouseInvertX) {
                    Text(L10n.t("controls.mouse_invert_x"))
                        .font(.system(size: 11, weight: .medium))
                        .foregroundColor(isInvertXFocused ? NXTheme.primary : NXTheme.textPrimary)
                }
                .toggleStyle(SwitchToggleStyle(tint: Color(red: 0.20, green: 0.60, blue: 1.00)))
                .padding(6)
                .background(isInvertXFocused ? NXTheme.primary.opacity(0.12) : Color.clear)
                .cornerRadius(8)
                .overlay(
                    RoundedRectangle(cornerRadius: 8)
                        .stroke(isInvertXFocused ? NXTheme.secondary : Color.clear, lineWidth: 1.5)
                )
                
                // Invert Y Axis
                Toggle(isOn: $profile.mouseInvertY) {
                    Text(L10n.t("controls.mouse_invert_y"))
                        .font(.system(size: 11, weight: .medium))
                        .foregroundColor(isInvertYFocused ? NXTheme.primary : NXTheme.textPrimary)
                }
                .toggleStyle(SwitchToggleStyle(tint: Color(red: 0.20, green: 0.60, blue: 1.00)))
                .padding(6)
                .background(isInvertYFocused ? NXTheme.primary.opacity(0.12) : Color.clear)
                .cornerRadius(8)
                .overlay(
                    RoundedRectangle(cornerRadius: 8)
                        .stroke(isInvertYFocused ? NXTheme.secondary : Color.clear, lineWidth: 1.5)
                )
                
                // Activation Mode (Cursor Lock vs Right Drag)
                VStack(alignment: .leading, spacing: 6) {
                    Text(L10n.t("controls.mouse_mode_title"))
                        .font(.system(size: 11, weight: .medium))
                        .foregroundColor(isModeFocused ? NXTheme.primary : NXTheme.textPrimary)
                    
                    NXLiquidSegmentedPicker(
                        selection: $profile.mouseRightStickMode,
                        options: [
                            NXSegmentOption(value: "cursorLock", title: L10n.t("controls.mouse_mode_lock"), icon: "lock.fill"),
                            NXSegmentOption(value: "rightDrag", title: L10n.t("controls.mouse_mode_drag"), icon: "hand.draw.fill")
                        ]
                    )
                }
                .padding(6)
                .background(isModeFocused ? NXTheme.primary.opacity(0.12) : Color.clear)
                .cornerRadius(8)
                .overlay(
                    RoundedRectangle(cornerRadius: 8)
                        .stroke(isModeFocused ? NXTheme.secondary : Color.clear, lineWidth: 1.5)
                )
            }
        }
        .transition(.opacity.combined(with: .move(edge: .leading)))
    }

    // MARK: - Tab 2: Mouse for Switch 2 (Native Pointer / JCMS)

    @ViewBuilder
    private var switch2TabView: some View {
        VStack(alignment: .leading, spacing: 12) {
            // Switch 2 Banner
            HStack(spacing: 8) {
                Image(systemName: "2.circle.fill")
                    .font(.system(size: 14, weight: .bold))
                    .foregroundColor(Color(red: 0.20, green: 0.85, blue: 0.50))
                Text(L10n.t("controls.mouse_switch2_banner"))
                    .font(.system(size: 11, weight: .medium))
                    .foregroundColor(NXTheme.textSecondary)
                Spacer()
            }
            .padding(9)
            .background(Color(red: 0.20, green: 0.85, blue: 0.50).opacity(0.08))
            .cornerRadius(9)
            .overlay(
                RoundedRectangle(cornerRadius: 9)
                    .stroke(Color(red: 0.20, green: 0.85, blue: 0.50).opacity(0.18), lineWidth: 1)
            )

            // Master Toggle: Enable Switch 2 Native Mouse
            Toggle(isOn: $profile.mouseSwitch2Enabled) {
                VStack(alignment: .leading, spacing: 2) {
                    Text(L10n.t("controls.mouse_switch2_enable"))
                        .font(.system(size: 12, weight: .semibold, design: .rounded))
                        .foregroundColor(NXTheme.textPrimary)
                    Text(L10n.t("controls.mouse_switch2_enable_desc"))
                        .font(.system(size: 10))
                        .foregroundColor(NXTheme.textSecondary)
                }
            }
            .toggleStyle(SwitchToggleStyle(tint: Color(red: 0.20, green: 0.85, blue: 0.50)))
            .padding(6)

            if profile.mouseSwitch2Enabled {
                Divider().opacity(0.15)
                
                // Pointer Speed Slider (Liquid Glass)
                HStack {
                    Text(L10n.t("controls.mouse_switch2_speed"))
                        .font(.system(size: 11, weight: .medium))
                        .foregroundColor(NXTheme.textPrimary)
                    
                    Spacer()
                    
                    Text(String(format: "%.1fx", profile.mouseSwitch2PointerSpeed))
                        .font(.system(size: 11, weight: .bold, design: .monospaced))
                        .foregroundColor(Color(red: 0.20, green: 0.85, blue: 0.50))
                }
                
                NXLiquidGlassSlider(
                    value: $profile.mouseSwitch2PointerSpeed,
                    in: 0.2...5.0,
                    step: 0.1,
                    accentColor: Color(red: 0.20, green: 0.85, blue: 0.50)
                )
                .frame(height: 24)
                .padding(6)

                // Lock Cursor in Game Window Toggle
                Toggle(isOn: $profile.mouseSwitch2LockCursor) {
                    VStack(alignment: .leading, spacing: 2) {
                        Text(L10n.t("controls.mouse_switch2_lock_cursor"))
                            .font(.system(size: 11, weight: .medium))
                            .foregroundColor(NXTheme.textPrimary)
                        Text(L10n.t("controls.mouse_switch2_lock_cursor_desc"))
                            .font(.system(size: 10))
                            .foregroundColor(NXTheme.textSecondary)
                    }
                }
                .toggleStyle(SwitchToggleStyle(tint: Color(red: 0.20, green: 0.85, blue: 0.50)))
                .padding(6)

                // Primary Button Selection (Standard: Left Click R, Right Click ZR vs. Swapped)
                VStack(alignment: .leading, spacing: 6) {
                    Text(L10n.t("controls.mouse_switch2_primary_btn"))
                        .font(.system(size: 11, weight: .medium))
                        .foregroundColor(NXTheme.textPrimary)
                    
                    NXLiquidSegmentedPicker(
                        selection: $profile.mouseSwitch2PrimaryButton,
                        options: [
                            NXSegmentOption(value: "left", title: L10n.t("controls.mouse_switch2_btn_left"), icon: "cursorarrow.click.2"),
                            NXSegmentOption(value: "right", title: L10n.t("controls.mouse_switch2_btn_right"), icon: "arrow.triangle.swap")
                        ]
                    )
                }
                .padding(6)

                // Joy-Con Side Selection (Right Joy-Con standard vs Left Joy-Con)
                VStack(alignment: .leading, spacing: 6) {
                    Text(L10n.t("controls.mouse_switch2_side"))
                        .font(.system(size: 11, weight: .medium))
                        .foregroundColor(NXTheme.textPrimary)
                    
                    NXLiquidSegmentedPicker(
                        selection: $profile.mouseSwitch2Side,
                        options: [
                            NXSegmentOption(value: "right", title: L10n.t("controls.mouse_switch2_side_right"), icon: "gamecontroller.fill"),
                            NXSegmentOption(value: "left", title: L10n.t("controls.mouse_switch2_side_left"), icon: "gamecontroller")
                        ]
                    )
                }
                .padding(6)

                // Invert Pointer Y-Axis
                Toggle(isOn: $profile.mouseSwitch2InvertY) {
                    Text(L10n.t("controls.mouse_switch2_invert_y"))
                        .font(.system(size: 11, weight: .medium))
                        .foregroundColor(NXTheme.textPrimary)
                }
                .toggleStyle(SwitchToggleStyle(tint: Color(red: 0.20, green: 0.85, blue: 0.50)))
                .padding(6)
            }
        }
        .transition(.opacity.combined(with: .move(edge: .trailing)))
    }
}
