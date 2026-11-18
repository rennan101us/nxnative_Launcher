import SwiftUI

struct GameSettingsControllerSection: View {
    @ObservedObject var viewModel: AppViewModel
    @ObservedObject var profileManager = InputProfileManager.shared
    public var game: PortedGame? = nil
    let rowIndex: Int

    private var configuredSlots: [Int] {
        var slots = Set<Int>([0])
        if let map = viewModel.activeSettingsConfig.playerProfileIds {
            for key in map.keys {
                if let idx = Int(key), idx >= 0, idx < 8 {
                    slots.insert(idx)
                }
            }
        }
        return slots.sorted()
    }

    private func playerColor(for index: Int) -> Color {
        switch index {
        case 0: return Color(red: 0.20, green: 0.60, blue: 1.00) // Blue (P1)
        case 1: return Color(red: 1.00, green: 0.35, blue: 0.35) // Red (P2)
        case 2: return Color(red: 0.20, green: 0.85, blue: 0.50) // Green (P3)
        case 3: return Color(red: 1.00, green: 0.80, blue: 0.20) // Yellow (P4)
        case 4: return Color(red: 0.70, green: 0.40, blue: 0.95) // Purple (P5)
        case 5: return Color(red: 0.20, green: 0.85, blue: 0.90) // Cyan (P6)
        case 6: return Color(red: 1.00, green: 0.55, blue: 0.20) // Orange (P7)
        default: return Color(red: 0.95, green: 0.45, blue: 0.70) // Pink (P8)
        }
    }

    private func addNextControllerSlot() {
        let current = Set(configuredSlots)
        guard let next = (0..<8).first(where: { !current.contains($0) }) else { return }
        var map = viewModel.activeSettingsConfig.playerProfileIds ?? [:]
        let defaultProf = profileManager.profile(forPlayer: next)
        map[String(next)] = defaultProf.id.uuidString
        viewModel.activeSettingsConfig.playerProfileIds = map
    }

    private func removeControllerSlot(_ pIdx: Int) {
        SoundEffectService.shared.play(.click)
        var map = viewModel.activeSettingsConfig.playerProfileIds ?? [:]
        map.removeValue(forKey: String(pIdx))
        viewModel.activeSettingsConfig.playerProfileIds = map.isEmpty ? nil : map
        if pIdx == 0 {
            viewModel.activeSettingsConfig.controllerProfileId = nil
        }
    }

    var body: some View {
        let isRowFocused = viewModel.settingsModalFocusIndex == rowIndex
        let isEnabled = viewModel.activeSettingsConfig.enableGamepadProfile

        VStack(alignment: .leading, spacing: 12) {
            // Master Toggle: Enable / Disable Gamepad Profiles
            let isToggleFocused = viewModel.settingsModalFocusIndex == rowIndex
            HStack(alignment: .center, spacing: 12) {
                VStack(alignment: .leading, spacing: 3) {
                    Text(isEnabled ? viewModel.tr("settings_modal.gamepad_profile_enabled") : viewModel.tr("settings_modal.gamepad_profile_disabled"))
                        .font(.system(size: 13, weight: .semibold, design: .rounded))
                        .foregroundColor(.white)
                    Text(isEnabled ? viewModel.tr("settings_modal.gamepad_profile_desc_on") : viewModel.tr("settings_modal.gamepad_profile_desc_off"))
                        .font(.system(size: 11, weight: .medium))
                        .foregroundColor(isRowFocused ? .white : NXTheme.modalDescription)
                }
                Spacer(minLength: 12)
                Toggle("", isOn: $viewModel.activeSettingsConfig.enableGamepadProfile)
                    .labelsHidden()
                    .toggleStyle(.switch)
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 8)
            .background(
                RoundedRectangle(cornerRadius: 10, style: .continuous)
                    .fill(isToggleFocused ? NXTheme.secondary.opacity(0.16) : Color.clear)
            )
            .overlay(
                RoundedRectangle(cornerRadius: 10, style: .continuous)
                    .strokeBorder(isToggleFocused ? NXTheme.secondary : Color.clear, lineWidth: 1.6)
            )
            .contentShape(Rectangle())
            .onTapGesture {
                viewModel.settingsModalFocusIndex = rowIndex
            }
            .id("setting_row_\(rowIndex)")

            if isEnabled {
                Divider().background(Color.white.opacity(0.12))

                if let g = game {
                    HStack(spacing: 6) {
                        Image(systemName: g.isSwitch2 ? "cursorarrow.rays" : "gamecontroller.fill")
                            .font(.system(size: 11, weight: .bold))
                            .foregroundColor(g.isSwitch2 ? Color(red: 0.20, green: 0.85, blue: 0.50) : NXTheme.secondary)
                        Text(g.isSwitch2 ? viewModel.tr("settings_modal.mouse_switch2_badge") : viewModel.tr("settings_modal.mouse_switch1_badge"))
                            .font(.system(size: 10, weight: .bold, design: .rounded))
                            .foregroundColor(.white)
                        Spacer()
                    }
                    .padding(.horizontal, 9)
                    .padding(.vertical, 5)
                    .background(Color.white.opacity(0.06))
                    .cornerRadius(7)
                }

                // Header: Configured Controllers Counter + Add Button (+)
                HStack(alignment: .center) {
                    VStack(alignment: .leading, spacing: 2) {
                        HStack(spacing: 6) {
                            Text(String(format: viewModel.tr("settings_modal.controller_configured_count"), configuredSlots.count))
                                .font(.system(size: 12, weight: .bold, design: .rounded))
                                .foregroundColor(.white)

                            Text("Max 8")
                                .font(.system(size: 9, weight: .bold, design: .monospaced))
                                .padding(.horizontal, 5)
                                .padding(.vertical, 1)
                                .background(NXTheme.primary.opacity(0.20))
                                .foregroundColor(NXTheme.primary)
                                .clipShape(Capsule())
                        }
                        Text(viewModel.tr("settings_modal.controller_profile_desc"))
                            .font(.system(size: 11, weight: .medium))
                            .foregroundColor(isRowFocused ? .white : NXTheme.modalDescription)
                    }

                    Spacer(minLength: 8)

                    if configuredSlots.count < 8 {
                        Button(action: {
                            SoundEffectService.shared.play(.click)
                            addNextControllerSlot()
                        }) {
                            HStack(spacing: 5) {
                                Image(systemName: "plus.circle.fill")
                                    .font(.system(size: 12, weight: .bold))
                                Text(viewModel.tr("settings_modal.controller_add_btn"))
                                    .font(.system(size: 11, weight: .bold, design: .rounded))
                            }
                            .padding(.horizontal, 10)
                            .padding(.vertical, 5)
                            .foregroundColor(NXTheme.primary)
                            .contentShape(Capsule())
                            .nxGlassInteractive(in: Capsule(), fallbackFill: NXTheme.glassSurfaceElevated)
                        }
                        .buttonStyle(NXPressableButtonStyle())
                        .nxNoFocusRing()
                    } else {
                        Text(viewModel.tr("settings_modal.controller_max_reached"))
                            .font(.system(size: 10, weight: .semibold, design: .rounded))
                            .foregroundColor(NXTheme.secondary)
                            .padding(.horizontal, 8)
                            .padding(.vertical, 4)
                            .background(NXTheme.secondary.opacity(0.18))
                            .clipShape(Capsule())
                    }
                }

                // Configured Controller Slots (1 up to 8)
                VStack(spacing: 8) {
                    ForEach(configuredSlots, id: \.self) { pIdx in
                        let pKey = String(pIdx)
                        let playerProfileId = viewModel.activeSettingsConfig.playerProfileIds?[pKey] ?? (pIdx == 0 ? viewModel.activeSettingsConfig.controllerProfileId : nil)
                        let selectedProfile = playerProfileId.flatMap { idStr in
                            UUID(uuidString: idStr).flatMap { uuid in
                                profileManager.profiles.first(where: { $0.id == uuid })
                            }
                        }
                        let globalLabel = String(format: viewModel.tr("settings_modal.controller_profile_global"), profileManager.profile(forPlayer: pIdx).name)
                        let currentLabel = selectedProfile?.name ?? globalLabel

                        HStack(spacing: 10) {
                            // Player Badge (LED color + icon + text)
                            HStack(spacing: 6) {
                                Circle()
                                    .fill(playerColor(for: pIdx))
                                    .frame(width: 8, height: 8)
                                    .shadow(color: playerColor(for: pIdx).opacity(0.6), radius: 3)

                                Image(systemName: "gamecontroller.fill")
                                    .font(.system(size: 11, weight: .bold))
                                    .foregroundColor(playerColor(for: pIdx))

                                Text("P\(pIdx + 1)")
                                    .font(.system(size: 12, weight: .bold, design: .rounded))
                                    .foregroundColor(.white)
                            }
                            .padding(.horizontal, 8)
                            .padding(.vertical, 4)
                            .background(playerColor(for: pIdx).opacity(0.15))
                            .clipShape(Capsule())
                            .overlay(
                                Capsule()
                                    .stroke(playerColor(for: pIdx).opacity(0.35), lineWidth: 1)
                            )

                            Text(String(format: viewModel.tr("settings_modal.controller_player_label"), pIdx + 1, pIdx + 1))
                                .font(.system(size: 11, weight: .semibold, design: .rounded))
                                .foregroundColor(.white.opacity(0.9))
                                .lineLimit(1)

                            Spacer(minLength: 6)

                            // Profile Selector Menu
                            Menu {
                                Button(action: {
                                    SoundEffectService.shared.play(.click)
                                    var map = viewModel.activeSettingsConfig.playerProfileIds ?? [:]
                                    map.removeValue(forKey: pKey)
                                    viewModel.activeSettingsConfig.playerProfileIds = map.isEmpty ? nil : map
                                    if pIdx == 0 {
                                        viewModel.activeSettingsConfig.controllerProfileId = nil
                                    }
                                }) {
                                    if selectedProfile == nil {
                                        Label(globalLabel, systemImage: "checkmark")
                                    } else {
                                        Text(globalLabel)
                                    }
                                }
                                Divider()
                                ForEach(profileManager.profiles) { prof in
                                    Button(action: {
                                        SoundEffectService.shared.play(.click)
                                        var map = viewModel.activeSettingsConfig.playerProfileIds ?? [:]
                                        map[pKey] = prof.id.uuidString
                                        viewModel.activeSettingsConfig.playerProfileIds = map
                                        if pIdx == 0 {
                                            viewModel.activeSettingsConfig.controllerProfileId = prof.id.uuidString
                                        }
                                    }) {
                                        if selectedProfile?.id == prof.id {
                                            Label(prof.name, systemImage: "checkmark")
                                        } else {
                                            Text(prof.name)
                                        }
                                    }
                                }
                            } label: {
                                HStack(spacing: 6) {
                                    Image(systemName: "slider.horizontal.3")
                                        .font(.system(size: 10, weight: .semibold))
                                        .foregroundColor(.white.opacity(0.8))
                                    Text(currentLabel)
                                        .font(.system(size: 11, weight: .bold, design: .rounded))
                                        .foregroundColor(.white)
                                        .lineLimit(1)
                                    Image(systemName: "chevron.up.chevron.down")
                                        .font(.system(size: 8, weight: .bold))
                                        .foregroundColor(.white.opacity(0.7))
                                }
                                .padding(.horizontal, 9)
                                .padding(.vertical, 5)
                                .contentShape(Capsule())
                                .nxGlassInteractive(in: Capsule(), fallbackFill: NXTheme.glassSurfaceElevated)
                            }
                            .menuStyle(.button)
                            .buttonStyle(NXPressableButtonStyle())
                            .menuIndicator(.hidden)
                            .fixedSize()
                            .nxNoFocusRing()

                            // Remove controller button (for slots > 0)
                            if pIdx > 0 {
                                Button(action: {
                                    removeControllerSlot(pIdx)
                                }) {
                                    Image(systemName: "minus.circle.fill")
                                        .font(.system(size: 14, weight: .semibold))
                                        .foregroundColor(Color(red: 1.0, green: 0.35, blue: 0.35))
                                }
                                .buttonStyle(.plain)
                                .help(viewModel.tr("settings_modal.controller_remove_btn"))
                            }
                        }
                        .padding(.horizontal, 10)
                        .padding(.vertical, 6)
                        .nxGlassBar(in: RoundedRectangle(cornerRadius: 10, style: .continuous))
                        .overlay(
                            RoundedRectangle(cornerRadius: 10, style: .continuous)
                                .strokeBorder(
                                    (pIdx == 0 && viewModel.settingsModalFocusIndex == 28) ? NXTheme.secondary : Color.clear,
                                    lineWidth: 1.6
                                )
                        )
                        .onTapGesture {
                            if pIdx == 0 {
                                viewModel.settingsModalFocusIndex = 28
                            }
                        }
                        .id(pIdx == 0 ? "setting_row_28" : "controller_slot_\(pIdx)")
                    }
                }
            } else {
                HStack(spacing: 8) {
                    Image(systemName: "checkmark.circle.fill")
                        .font(.system(size: 12, weight: .bold))
                        .foregroundColor(Color(red: 0.13, green: 0.77, blue: 0.37))
                    Text(viewModel.tr("settings_modal.gamepad_profile_native_notice"))
                        .font(.system(size: 11, weight: .medium))
                        .foregroundColor(.white.opacity(0.92))
                }
                .padding(.horizontal, 10)
                .padding(.vertical, 7)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(
                    RoundedRectangle(cornerRadius: 8, style: .continuous)
                        .fill(Color.black.opacity(0.28))
                )
            }
        }
        .animation(.easeInOut(duration: 0.25), value: isEnabled)
    }
}
