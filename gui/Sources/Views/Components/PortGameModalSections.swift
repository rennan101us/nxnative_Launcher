import SwiftUI
import AppKit

// MARK: - Android Robot Logo (Vector)
private struct AndroidDomeWithEyesShape: Shape {
    func path(in rect: CGRect) -> Path {
        let s = min(rect.width, rect.height)
        let ox = rect.midX - s / 2
        let oy = rect.midY - s / 2

        var path = Path()
        let cx = ox + s * 0.50
        let baseY = oy + s * 0.80
        let r = s * 0.39

        // Dome semicircle (180° -> 270° -> 360° in y-down SwiftUI coordinates)
        path.addArc(
            center: CGPoint(x: cx, y: baseY),
            radius: r,
            startAngle: .degrees(180),
            endAngle: .degrees(0),
            clockwise: false
        )
        path.closeSubpath()

        // Eye cutouts (used with eoFill: true)
        let eyeR = s * 0.048
        let eyeOffsetX = r * 0.43
        let eyeY = baseY - r * 0.42
        path.addEllipse(in: CGRect(x: cx - eyeOffsetX - eyeR, y: eyeY - eyeR, width: eyeR * 2, height: eyeR * 2))
        path.addEllipse(in: CGRect(x: cx + eyeOffsetX - eyeR, y: eyeY - eyeR, width: eyeR * 2, height: eyeR * 2))

        return path
    }
}

private struct AndroidAntennaeShape: Shape {
    func path(in rect: CGRect) -> Path {
        let s = min(rect.width, rect.height)
        let ox = rect.midX - s / 2
        let oy = rect.midY - s / 2
        let cx = ox + s * 0.50
        let baseY = oy + s * 0.80
        let r = s * 0.39

        var path = Path()
        path.move(to: CGPoint(x: cx - r * 0.46, y: baseY - r * 0.90))
        path.addLine(to: CGPoint(x: cx - r * 0.74, y: baseY - r * 1.34))
        path.move(to: CGPoint(x: cx + r * 0.46, y: baseY - r * 0.90))
        path.addLine(to: CGPoint(x: cx + r * 0.74, y: baseY - r * 1.34))
        return path
    }
}

private struct AndroidLogoIcon: View {
    let color: Color
    var size: CGFloat = 17

    var body: some View {
        ZStack {
            AndroidDomeWithEyesShape()
                .fill(color, style: FillStyle(eoFill: true))
            AndroidAntennaeShape()
                .stroke(color, style: StrokeStyle(lineWidth: max(1.3, size * 0.085), lineCap: .round))
        }
        .frame(width: size, height: size)
    }
}

// MARK: - Platform Selector View
public struct PortPlatformSelectorView: View {
    @ObservedObject public var viewModel: AppViewModel
    
    public init(viewModel: AppViewModel) {
        self.viewModel = viewModel
    }
    
    public var body: some View {
        VStack(spacing: 8) {
            NXGlassContainer(spacing: 8) {
                HStack(spacing: 8) {
                    platformChoiceButton(
                        platform: .macApp,
                        title: "macOS",
                        index: 0
                    )
                    
                    platformChoiceButton(
                        platform: .ios,
                        title: "iOS/iPadOS",
                        index: 1
                    )

                    platformChoiceButton(
                        platform: .android,
                        title: "Android",
                        index: 2
                    )
                }
            }

            if viewModel.platform == .ios && (viewModel.selectedGame?.isSwitch2 == true || viewModel.selectedGame?.isNup == true) {
                HStack(alignment: .top, spacing: 8) {
                    Image(systemName: "exclamationmark.triangle.fill")
                        .foregroundColor(Color.orange)
                        .font(.system(size: 11, weight: .bold))
                    Text(viewModel.tr("port_modal.switch2_ios_experimental_notice"))
                        .font(.system(size: 10, weight: .medium, design: .rounded))
                        .foregroundColor(NXTheme.textSecondary)
                        .fixedSize(horizontal: false, vertical: true)
                    Spacer(minLength: 0)
                }
                .padding(.horizontal, 10)
                .padding(.vertical, 7)
                .background(
                    RoundedRectangle(cornerRadius: 8, style: .continuous)
                        .fill(Color.orange.opacity(0.10))
                        .overlay(
                            RoundedRectangle(cornerRadius: 8, style: .continuous)
                                .strokeBorder(Color.orange.opacity(0.30), lineWidth: 1)
                        )
                )
                .transition(.opacity)
            } else if viewModel.platform == .android {
                if viewModel.selectedGame?.isSwitch2 == true || viewModel.selectedGame?.isNup == true {
                    HStack(alignment: .top, spacing: 8) {
                        Image(systemName: "exclamationmark.circle.fill")
                            .foregroundColor(Color.red)
                            .font(.system(size: 11, weight: .bold))
                        Text(viewModel.tr("port_modal.switch2_android_unsupported_notice"))
                            .font(.system(size: 10, weight: .medium, design: .rounded))
                            .foregroundColor(NXTheme.textSecondary)
                            .fixedSize(horizontal: false, vertical: true)
                        Spacer(minLength: 0)
                    }
                    .padding(.horizontal, 10)
                    .padding(.vertical, 7)
                    .background(
                        RoundedRectangle(cornerRadius: 8, style: .continuous)
                            .fill(Color.red.opacity(0.10))
                            .overlay(
                                RoundedRectangle(cornerRadius: 8, style: .continuous)
                                    .strokeBorder(Color.red.opacity(0.30), lineWidth: 1)
                            )
                    )
                    .transition(.opacity)
                } else {
                    if !viewModel.prerequisites.androidNdk.isAvailable || !viewModel.prerequisites.androidAdb.isAvailable {
                        HStack(spacing: 8) {
                            Image(systemName: "arrow.down.circle.fill")
                                .foregroundColor(Color.orange)
                                .font(.system(size: 12, weight: .bold))
                            Text(viewModel.tr("port_modal.android_toolchain_missing_notice"))
                                .font(.system(size: 10, weight: .medium, design: .rounded))
                                .foregroundColor(NXTheme.textPrimary)
                                .fixedSize(horizontal: false, vertical: true)
                            Spacer(minLength: 4)
                            Button(action: {
                                SoundEffectService.shared.play(.click)
                                viewModel.installMissingAndroidToolchain()
                            }) {
                                HStack(spacing: 4) {
                                    if viewModel.isInstallingDependency {
                                        ProgressView().controlSize(.mini)
                                    } else {
                                        Image(systemName: "arrow.down.circle")
                                    }
                                    Text(viewModel.tr("common.install"))
                                }
                                .font(.system(size: 10.5, weight: .bold, design: .rounded))
                            }
                            .buttonStyle(NXPrimaryButtonStyle())
                            .controlSize(.small)
                            .disabled(viewModel.isInstallingDependency)
                        }
                        .padding(.horizontal, 10)
                        .padding(.vertical, 7)
                        .background(
                            RoundedRectangle(cornerRadius: 8, style: .continuous)
                                .fill(Color.orange.opacity(0.10))
                                .overlay(
                                    RoundedRectangle(cornerRadius: 8, style: .continuous)
                                        .strokeBorder(Color.orange.opacity(0.32), lineWidth: 1)
                                )
                        )
                        .transition(.opacity)
                    }

                    HStack(alignment: .top, spacing: 8) {
                        Image(systemName: "info.circle.fill")
                            .foregroundColor(NXTheme.primary)
                            .font(.system(size: 11, weight: .bold))
                        Text(viewModel.tr("port_modal.android_gpu_notice"))
                            .font(.system(size: 10, weight: .medium, design: .rounded))
                            .foregroundColor(NXTheme.textSecondary)
                            .fixedSize(horizontal: false, vertical: true)
                        Spacer(minLength: 0)
                    }
                    .padding(.horizontal, 10)
                    .padding(.vertical, 7)
                    .background(
                        RoundedRectangle(cornerRadius: 8, style: .continuous)
                            .fill(NXTheme.primary.opacity(0.08))
                            .overlay(
                                RoundedRectangle(cornerRadius: 8, style: .continuous)
                                    .strokeBorder(NXTheme.primary.opacity(0.25), lineWidth: 1)
                            )
                    )
                    .transition(.opacity)
                }
            }
        }
    }

    @ViewBuilder
    private func platformLogo(for platform: TargetPlatform, isSelected: Bool) -> some View {
        let androidGreen = Color(red: 0.24, green: 0.86, blue: 0.52)
        let appleColor: Color = isSelected ? (NXTheme.isNeonBlack ? .white : NXTheme.primary) : NXTheme.textSecondary
        switch platform {
        case .macApp, .nonSwitch:
            Image(systemName: "apple.logo")
                .font(.system(size: 16, weight: .semibold))
                .foregroundColor(appleColor)
        case .ios:
            Image(systemName: "ipad.and.iphone")
                .font(.system(size: 15, weight: .semibold))
                .foregroundColor(appleColor)
        case .android:
            AndroidLogoIcon(color: isSelected ? androidGreen : NXTheme.textSecondary, size: 17)
        }
    }
    
    private func platformChoiceButton(platform: TargetPlatform, title: String, index: Int) -> some View {
        let isSelected = viewModel.platform == platform
        let isFocused = viewModel.portModalFocusIndex == index
        let isSwitch2 = viewModel.selectedGame?.isSwitch2 == true
        let isNup = viewModel.selectedGame?.isNup == true
        let isSwitch2OrNup = isSwitch2 || isNup
        let isIosExperimental = (platform == .ios && isSwitch2OrNup)
        let androidGreen = Color(red: 0.24, green: 0.86, blue: 0.52)
        let activeTint: Color = (platform == .android) ? androidGreen : NXTheme.primary

        return Button(action: {
            SoundEffectService.shared.play(.click)
            viewModel.platform = platform
            viewModel.portModalFocusIndex = index
        }) {
            HStack(spacing: 7) {
                platformLogo(for: platform, isSelected: isSelected)

                Text(title)
                    .font(.system(size: 12.5, weight: .bold, design: .rounded))
                    .foregroundColor(NXTheme.textPrimary)
                    .lineLimit(1)
                    .minimumScaleFactor(0.82)

                if isIosExperimental {
                    Text(viewModel.tr("port_modal.experimental"))
                        .font(.system(size: 8, weight: .heavy, design: .rounded))
                        .foregroundColor(.white)
                        .padding(.horizontal, 5)
                        .padding(.vertical, 2)
                        .background(Color.orange.opacity(0.85))
                        .clipShape(Capsule())
                }

                Spacer(minLength: 0)

                if isSelected {
                    Image(systemName: "checkmark.circle.fill")
                        .foregroundColor(platform == .android ? androidGreen : Color.green)
                        .font(.system(size: 13))
                }
            }
            .padding(.horizontal, 11)
            .padding(.vertical, 11)
            .frame(maxWidth: .infinity)
            .contentShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
        }
        .buttonStyle(NXPressableButtonStyle())
        .nxGlassInteractive(
            in: RoundedRectangle(cornerRadius: 12, style: .continuous),
            tint: isSelected ? activeTint.opacity(0.45) : nil,
            isSelected: isSelected,
            isFocused: isFocused
        )
        .overlay(
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .strokeBorder(
                    isFocused ? AnyShapeStyle(NXTheme.secondary) : (isSelected ? AnyShapeStyle(activeTint.opacity(0.75)) : AnyShapeStyle(Color.clear)),
                    lineWidth: isFocused ? 2 : 1
                )
        )
        .shadow(color: isFocused ? NXTheme.secondary.opacity(0.55) : Color.clear, radius: 6)
        .nxNoFocusRing()
    }
}

// MARK: - iOS Immediate Auto-Deploy vs Later Choice View
public struct PortIosDeployChoiceView: View {
    @ObservedObject public var viewModel: AppViewModel
    @ObservedObject private var deviceService = DeviceDeploymentService.shared
    
    public init(viewModel: AppViewModel) {
        self.viewModel = viewModel
    }
    
    public var body: some View {
        GlassCard(padding: 12) {
            VStack(alignment: .leading, spacing: 10) {
                Label(viewModel.tr("port_modal.ios_deploy_prompt"), systemImage: "iphone.badge.play")
                    .font(.system(size: 12, weight: .bold, design: .rounded))
                    .foregroundColor(NXTheme.textPrimary)
                
                VStack(spacing: 6) {
                    deployChoiceRow(
                        title: viewModel.tr("port_modal.ios_deploy_now"),
                        subtitle: deviceService.selectedDevice != nil ? "\(deviceService.selectedDevice!.name) (\(deviceService.selectedDevice!.model))" : viewModel.tr("port_modal.ios_deploy_now_desc"),
                        icon: "bolt.fill",
                        isSelected: viewModel.autoDeployToDeviceOnFinish,
                        index: 3
                    ) {
                        viewModel.autoDeployToDeviceOnFinish = true
                        viewModel.portModalFocusIndex = 3
                    }
                    
                    deployChoiceRow(
                        title: viewModel.tr("port_modal.ios_deploy_later"),
                        subtitle: viewModel.tr("port_modal.ios_deploy_later_desc"),
                        icon: "clock.arrow.circlepath",
                        isSelected: !viewModel.autoDeployToDeviceOnFinish,
                        index: 4
                    ) {
                        viewModel.autoDeployToDeviceOnFinish = false
                        viewModel.portModalFocusIndex = 4
                    }
                }
                
                if viewModel.autoDeployToDeviceOnFinish {
                    Divider().opacity(0.15)
                    
                    VStack(alignment: .leading, spacing: 8) {
                        // Device Selection Row
                        let isDeviceRowFocused = viewModel.portModalFocusIndex == 13
                        HStack(spacing: 8) {
                            HStack(spacing: 6) {
                                Image(systemName: "iphone.gen3")
                                    .foregroundColor(NXTheme.modalIconColor)
                                    .font(.system(size: 12))
                                Text(L10n.t("settings_modal.install_on_label"))
                                    .font(.system(size: 11, weight: .semibold))
                                    .foregroundColor(NXTheme.textPrimary)
                            }
                            
                            Spacer()
                            
                            Button(action: {
                                SoundEffectService.shared.play(.click)
                                deviceService.refreshDevicesAndTeams()
                            }) {
                                HStack(spacing: 3) {
                                    if deviceService.isDetecting {
                                        ProgressView().controlSize(.mini)
                                    } else {
                                        Image(systemName: "arrow.clockwise")
                                    }
                                    Text(L10n.t("settings_modal.refresh_label"))
                                }
                            }
                            .buttonStyle(NXSecondaryButtonStyle())
                            .controlSize(.mini)
                            .disabled(deviceService.isDetecting)
                            
                            if deviceService.connectedDevices.isEmpty {
                                Text(L10n.t("settings_modal.no_devices"))
                                    .font(.system(size: 10))
                                    .foregroundColor(NXTheme.modalDescription)
                            } else {
                                Picker("", selection: $deviceService.selectedDevice) {
                                    ForEach(deviceService.connectedDevices) { dev in
                                        Text("\(dev.name) (\(dev.model) • iOS \(dev.osVersion))")
                                            .tag(Optional(dev))
                                    }
                                }
                                .pickerStyle(MenuPickerStyle())
                                .frame(maxWidth: 220)
                                
                                Circle()
                                    .fill(Color(red: 0.13, green: 0.77, blue: 0.37))
                                    .frame(width: 6, height: 6)
                            }
                        }
                        .padding(4)
                        .background(isDeviceRowFocused ? NXTheme.secondary.opacity(0.14) : Color.clear)
                        .cornerRadius(6)
                        .overlay(
                            RoundedRectangle(cornerRadius: 6, style: .continuous)
                                .strokeBorder(isDeviceRowFocused ? NXTheme.secondary : Color.clear, lineWidth: 1.5)
                        )
                        .onTapGesture {
                            viewModel.portModalFocusIndex = 13
                        }
                        .id("port_row_13")
                        
                        // Signing Team Row
                        let isTeamRowFocused = viewModel.portModalFocusIndex == 14
                        HStack(spacing: 8) {
                            HStack(spacing: 6) {
                                Image(systemName: "person.badge.shield.checkmark")
                                    .foregroundColor(NXTheme.modalIconColor)
                                    .font(.system(size: 12))
                                Text(L10n.t("settings_modal.signing_team_label"))
                                    .font(.system(size: 11, weight: .semibold))
                                    .foregroundColor(NXTheme.textPrimary)
                            }
                            
                            Spacer()
                            
                            if deviceService.signingTeams.isEmpty {
                                Text(L10n.t("settings_modal.no_teams_found"))
                                    .font(.system(size: 10))
                                    .foregroundColor(NXTheme.modalDescription)
                            } else {
                                Picker("", selection: $deviceService.selectedSigningTeam) {
                                    Text(L10n.t("settings.ios_unsigned_sideloading")).tag(Optional<DeveloperSigningTeam>.none)
                                    ForEach(deviceService.signingTeams) { team in
                                        Text(team.displayName)
                                            .tag(Optional(team))
                                    }
                                }
                                .pickerStyle(MenuPickerStyle())
                                .frame(maxWidth: 240)
                            }
                        }
                        .padding(4)
                        .background(isTeamRowFocused ? NXTheme.secondary.opacity(0.14) : Color.clear)
                        .cornerRadius(6)
                        .overlay(
                            RoundedRectangle(cornerRadius: 6, style: .continuous)
                                .strokeBorder(isTeamRowFocused ? NXTheme.secondary : Color.clear, lineWidth: 1.5)
                        )
                        .onTapGesture {
                            viewModel.portModalFocusIndex = 14
                        }
                        .id("port_row_14")
                    }
                    .padding(8)
                    .background(NXTheme.glassSurfaceElevated.opacity(0.35))
                    .cornerRadius(8)
                }

                Divider().opacity(0.15)

                NxDeploymentModeSection(
                    isStorageToggleFocused: viewModel.portModalFocusIndex == 15,
                    onOpenBatchModal: {
                        viewModel.gameForPortModal = nil
                        viewModel.openNxDeploymentBatchModal()
                    }
                )
            }
        }
        .onAppear {
            if deviceService.connectedDevices.isEmpty || deviceService.signingTeams.isEmpty {
                deviceService.refreshDevicesAndTeams()
            }
        }
    }
    
    private func deployChoiceRow(title: String, subtitle: String? = nil, icon: String, isSelected: Bool, index: Int, action: @escaping () -> Void) -> some View {
        let isFocused = viewModel.portModalFocusIndex == index
        return Button(action: {
            SoundEffectService.shared.play(.click)
            action()
        }) {
            HStack(spacing: 8) {
                Image(systemName: isSelected ? "largecircle.fill.circle" : "circle")
                    .foregroundColor(isSelected ? NXTheme.primary : NXTheme.textSecondary)
                    .font(.system(size: 12))
                Image(systemName: icon)
                    .font(.system(size: 11))
                    .foregroundColor(isSelected ? NXTheme.primary : NXTheme.textSecondary)
                VStack(alignment: .leading, spacing: 2) {
                    Text(title)
                        .font(.system(size: 11, weight: isSelected ? .semibold : .regular))
                        .foregroundColor(NXTheme.textPrimary)
                    if let sub = subtitle, !sub.isEmpty {
                        Text(sub)
                            .font(.system(size: 9.5))
                            .foregroundColor(NXTheme.modalDescription)
                    }
                }
                Spacer()
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 6)
            .background(isSelected ? NXTheme.primary.opacity(0.12) : Color.clear)
            .cornerRadius(6)
            .overlay(
                RoundedRectangle(cornerRadius: 6, style: .continuous)
                    .strokeBorder(isFocused ? NXTheme.secondary : Color.clear, lineWidth: 1.5)
            )
        }
        .buttonStyle(PlainButtonStyle())
        .nxNoFocusRing()
    }
}

// MARK: - Advanced Settings Collapsible View
public struct PortAdvancedSettingsView: View {
    @ObservedObject public var viewModel: AppViewModel
    
    public init(viewModel: AppViewModel) {
        self.viewModel = viewModel
    }
    
    public var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            let isAdvFocused = viewModel.portModalFocusIndex == 5
            Button(action: {
                SoundEffectService.shared.play(.click)
                withAnimation(.spring(response: 0.30, dampingFraction: 0.78)) {
                    viewModel.isPortAdvancedExpanded.toggle()
                    viewModel.portModalFocusIndex = 5
                }
            }) {
                HStack(spacing: 6) {
                    Image(systemName: viewModel.isPortAdvancedExpanded ? "chevron.down" : "chevron.right")
                        .font(.system(size: 10, weight: .bold))
                        .foregroundColor(NXTheme.secondary)
                    Text(viewModel.tr("port_modal.advanced_settings"))
                        .font(.system(size: 11, weight: .semibold, design: .rounded))
                        .foregroundColor(NXTheme.modalDescription)
                    Spacer()
                }
                .padding(6)
                .background(isAdvFocused ? NXTheme.secondary.opacity(0.15) : Color.clear)
                .cornerRadius(6)
                .overlay(
                    RoundedRectangle(cornerRadius: 6, style: .continuous)
                        .strokeBorder(isAdvFocused ? NXTheme.secondary : Color.clear, lineWidth: 1.5)
                )
                .contentShape(Rectangle())
            }
            .buttonStyle(PlainButtonStyle())
            .nxNoFocusRing()
            .id("port_row_5")
            
            if viewModel.isPortAdvancedExpanded {
                VStack(alignment: .leading, spacing: 10) {
                    // RomFS Split Slider
                    let isSliderFocused = viewModel.portModalFocusIndex == 6
                    VStack(alignment: .leading, spacing: 6) {
                        HStack {
                            Text(String(format: viewModel.tr("port_modal.romfs_split_title"), Int(viewModel.autoRomfsSplitLimitGB)))
                                .font(.system(size: 11, weight: .medium))
                                .foregroundColor(NXTheme.textPrimary)
                            Spacer()
                            Text("\(Int(viewModel.autoRomfsSplitLimitGB)) GB")
                                .font(.system(size: 11, weight: .bold, design: .monospaced))
                                .foregroundColor(NXTheme.secondary)
                        }
                        Text(viewModel.tr("port_modal.romfs_split_desc"))
                            .font(.system(size: 10))
                            .foregroundColor(NXTheme.modalDescription)
                        
                        NXLiquidGlassSlider(
                            value: $viewModel.autoRomfsSplitLimitGB,
                            in: 2.0...16.0,
                            step: 1.0,
                            accentColor: NXTheme.primary
                        )
                        .padding(4)
                        .background(isSliderFocused ? NXTheme.secondary.opacity(0.12) : Color.clear)
                        .cornerRadius(8)
                        .overlay(
                            RoundedRectangle(cornerRadius: 8, style: .continuous)
                                .strokeBorder(isSliderFocused ? NXTheme.secondary : Color.clear, lineWidth: 1.5)
                        )
                        .id("port_row_6")
                    }
                    
                    Divider().opacity(0.15)
                    
                    // Technical Toggles
                    VStack(alignment: .leading, spacing: 6) {
                        portToggleRow(title: viewModel.tr("build.opt_fps"), isOn: $viewModel.showFps, index: 7)
                        portToggleRow(title: viewModel.tr("build.opt_keep_extracted"), isOn: $viewModel.keepExtracted, index: 8)
                        
                        VStack(alignment: .leading, spacing: 3) {
                            portToggleRow(title: viewModel.tr("build.opt_allow_other_metal"), isOn: $viewModel.allowOtherMetal, index: 9)
                            
                            if let metal = viewModel.metalToolchainInfo {
                                HStack(spacing: 5) {
                                    Circle()
                                        .fill(metalStatusColor(metal: metal))
                                        .frame(width: 5, height: 5)
                                    
                                    Text(metal.shortVersion)
                                        .font(.system(size: 9.5, weight: .semibold, design: .monospaced))
                                        .foregroundColor(NXTheme.textPrimary)
                                    
                                    Text("·")
                                        .foregroundColor(NXTheme.textMuted.opacity(0.6))
                                        .font(.system(size: 9.5))
                                    
                                    Text(metalStatusLabel(metal: metal))
                                        .font(.system(size: 9.5))
                                        .foregroundColor(metal.isVerified ? NXTheme.textSecondary : (viewModel.allowOtherMetal ? NXTheme.secondary : Color.orange))
                                }
                                .padding(.horizontal, 7)
                                .padding(.vertical, 2.5)
                                .background(NXTheme.glassSurfaceElevated.opacity(0.50))
                                .clipShape(Capsule())
                                .overlay(
                                    Capsule().stroke(Color.white.opacity(0.12), lineWidth: 0.5)
                                )
                                .padding(.leading, 18)
                            }
                        }
                        
                        portToggleRow(title: viewModel.tr("build.opt_survey_only"), isOn: $viewModel.surveyOnly, index: 10)
                    }
                    
                    Divider().opacity(0.15)
                    
                    // Output Destination Folder
                    let isFolderFocused = viewModel.portModalFocusIndex == 16
                    VStack(alignment: .leading, spacing: 4) {
                        HStack {
                            VStack(alignment: .leading, spacing: 2) {
                                Text(viewModel.tr("port_modal.output_folder_title"))
                                    .font(.system(size: 11, weight: .medium))
                                    .foregroundColor(NXTheme.textPrimary)
                                Text(viewModel.appOutputDirectory.path)
                                    .font(.system(size: 10, design: .monospaced))
                                    .foregroundColor(NXTheme.modalDescription)
                                    .lineLimit(1)
                                    .truncationMode(.middle)
                            }
                            Spacer()
                            Button(action: {
                                SoundEffectService.shared.play(.click)
                                viewModel.selectOutputFolder()
                            }) {
                                Text(viewModel.tr("common.change"))
                                    .font(.system(size: 10, weight: .bold))
                            }
                            .buttonStyle(NXSecondaryButtonStyle())
                            .controlSize(.small)
                        }
                    }
                    .padding(.horizontal, 6)
                    .padding(.vertical, 4)
                    .background(isFolderFocused ? NXTheme.secondary.opacity(0.15) : Color.clear)
                    .cornerRadius(6)
                    .overlay(
                        RoundedRectangle(cornerRadius: 6, style: .continuous)
                            .strokeBorder(isFolderFocused ? NXTheme.secondary : Color.clear, lineWidth: 1.5)
                    )
                    .onTapGesture {
                        viewModel.portModalFocusIndex = 16
                    }
                    .id("port_row_16")
                }
                .padding(10)
                .background(NXTheme.glassSurfaceElevated.opacity(0.40))
                .cornerRadius(10)
            }
        }
    }

    private func portToggleRow(title: String, isOn: Binding<Bool>, index: Int) -> some View {
        let isFocused = viewModel.portModalFocusIndex == index
        return Toggle(title, isOn: isOn)
            .font(.system(size: 11))
            .padding(.horizontal, 6)
            .padding(.vertical, 3)
            .background(isFocused ? NXTheme.secondary.opacity(0.15) : Color.clear)
            .cornerRadius(6)
            .overlay(
                RoundedRectangle(cornerRadius: 6, style: .continuous)
                    .strokeBorder(isFocused ? NXTheme.secondary : Color.clear, lineWidth: 1.5)
            )
            .onTapGesture {
                viewModel.portModalFocusIndex = index
            }
            .id("port_row_\(index)")
    }

    private func metalStatusColor(metal: MetalToolchainInfo) -> Color {
        guard metal.isAvailable else { return Color.red }
        if metal.isVerified { return Color.green }
        return viewModel.allowOtherMetal ? NXTheme.secondary : Color.orange
    }

    private func metalStatusLabel(metal: MetalToolchainInfo) -> String {
        guard metal.isAvailable else { return viewModel.tr("build.metal_status_not_found") }
        if metal.isVerified { return viewModel.tr("build.metal_status_verified") }
        return viewModel.allowOtherMetal
            ? viewModel.tr("build.metal_status_allowed")
            : viewModel.tr("build.metal_status_untested")
    }
}
