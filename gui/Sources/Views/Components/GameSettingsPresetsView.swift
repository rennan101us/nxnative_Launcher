import SwiftUI
import AppKit
import UniformTypeIdentifiers

public struct GameSettingsPresetsView: View {
    @ObservedObject public var viewModel: AppViewModel
    public let game: PortedGame
    public let isOot: Bool

    @State private var showingSaveInline: Bool = false
    @State private var newPresetName: String = ""
    @State private var userPresets: [GamePreset] = []
    @State private var statusFeedback: String? = nil
    @State private var statusIsError: Bool = false

    public init(viewModel: AppViewModel, game: PortedGame, isOot: Bool) {
        self.viewModel = viewModel
        self.game = game
        self.isOot = isOot
    }

    private var builtInPresets: [GamePreset] {
        GamePresetService.shared.builtInPresets(for: game)
    }

    private var activeMatchedPreset: GamePreset? {
        let all = builtInPresets + userPresets
        return all.first { preset in
            viewModel.activeSettingsConfig.matchesPerformanceSettings(of: preset.config, isOot: isOot)
        }
    }

    private var currentPresetDisplayName: String {
        if let matched = activeMatchedPreset {
            return matched.name
        }
        return viewModel.tr("presets.custom_label")
    }

    public var body: some View {
        let isFocused = viewModel.settingsModalFocusIndex == 20
        return VStack(alignment: .leading, spacing: 10) {
            // Header Bar with Icon & Title
            HStack(spacing: 8) {
                Image(systemName: "wand.and.stars")
                    .font(.system(size: 13, weight: .bold))
                    .foregroundColor(NXTheme.isNeonBlack ? .white : Color(red: 0.95, green: 0.65, blue: 0.15))

                Text(viewModel.tr("presets.title"))
                    .font(.system(size: 13, weight: .bold, design: .rounded))
                    .foregroundColor(NXTheme.textPrimary)

                Spacer()

                if let matched = activeMatchedPreset, !matched.isBuiltIn {
                    // Delete Button for Custom Preset
                    Button(action: { deleteCurrentPreset(matched) }) {
                        Image(systemName: "trash")
                            .font(.system(size: 11, weight: .semibold))
                            .foregroundColor(Color.red.opacity(0.85))
                    }
                    .buttonStyle(NXSecondaryButtonStyle())
                    .controlSize(.mini)
                    .help(viewModel.tr("presets.delete_button"))
                }
            }

            // Dropdown Selector & Quick Actions
            HStack(spacing: 8) {
                // Preset Dropdown Menu
                Menu {
                    // Section 1: Recommended Built-in Presets
                    Section(viewModel.tr("presets.recommended_header")) {
                        ForEach(builtInPresets) { preset in
                            Button(action: { applyPreset(preset) }) {
                                HStack {
                                    if activeMatchedPreset?.id == preset.id || activeMatchedPreset?.name == preset.name {
                                        Image(systemName: "checkmark")
                                    }
                                    Text(preset.name)
                                }
                            }
                        }
                    }

                    // Section 2: Custom User Presets
                    if !userPresets.isEmpty {
                        Section(viewModel.tr("presets.user_header")) {
                            ForEach(userPresets) { preset in
                                Button(action: { applyPreset(preset) }) {
                                    HStack {
                                        if activeMatchedPreset?.name == preset.name {
                                            Image(systemName: "checkmark")
                                        }
                                        Text(preset.name)
                                    }
                                }
                            }
                        }
                    }
                } label: {
                    HStack(spacing: 6) {
                        Image(systemName: activeMatchedPreset?.isBuiltIn == true ? "sparkles" : (activeMatchedPreset != nil ? "bookmark.fill" : "slider.horizontal.3"))
                            .font(.system(size: 11, weight: .semibold))
                            .foregroundColor(activeMatchedPreset != nil ? NXTheme.secondary : NXTheme.textSecondary)

                        Text(currentPresetDisplayName)
                            .font(.system(size: 12, weight: .semibold, design: .rounded))
                            .foregroundColor(.white)
                            .lineLimit(1)

                        Spacer()

                        Image(systemName: "chevron.up.chevron.down")
                            .font(.system(size: 10, weight: .bold))
                            .foregroundColor(NXTheme.textSecondary)
                    }
                    .padding(.horizontal, 10)
                    .padding(.vertical, 7)
                    .background(
                        RoundedRectangle(cornerRadius: 9, style: .continuous)
                            .fill(Color.black.opacity(0.35))
                    )
                    .overlay(
                        RoundedRectangle(cornerRadius: 9, style: .continuous)
                            .stroke(NXTheme.specularRim, lineWidth: 1)
                    )
                }
                .menuStyle(.borderlessButton)
                .frame(maxWidth: .infinity)

                // Save Custom Preset Button
                Button(action: {
                    withAnimation(.spring(response: 0.3, dampingFraction: 0.8)) {
                        showingSaveInline.toggle()
                        if showingSaveInline {
                            newPresetName = activeMatchedPreset?.isBuiltIn == false ? (activeMatchedPreset?.name ?? "") : ""
                        }
                    }
                }) {
                    HStack(spacing: 4) {
                        Image(systemName: "plus.circle.fill")
                            .font(.system(size: 10, weight: .bold))
                        Text(viewModel.tr("presets.save_button"))
                            .font(.system(size: 11, weight: .semibold))
                    }
                }
                .buttonStyle(NXSecondaryButtonStyle())
                .controlSize(.small)

                // Import (.nxn) Button
                Button(action: { importPresetFromFile() }) {
                    HStack(spacing: 4) {
                        Image(systemName: "square.and.arrow.down")
                            .font(.system(size: 10, weight: .bold))
                        Text(viewModel.tr("presets.import_button"))
                            .font(.system(size: 11, weight: .semibold))
                    }
                }
                .buttonStyle(NXSecondaryButtonStyle())
                .controlSize(.small)

                // Export (.nxn) Button
                Button(action: { exportPresetToFile() }) {
                    HStack(spacing: 4) {
                        Image(systemName: "square.and.arrow.up")
                            .font(.system(size: 10, weight: .bold))
                        Text(viewModel.tr("presets.export_button"))
                            .font(.system(size: 11, weight: .semibold))
                    }
                }
                .buttonStyle(NXSecondaryButtonStyle())
                .controlSize(.small)
            }

            // Inline Save Dialog
            if showingSaveInline {
                VStack(alignment: .leading, spacing: 8) {
                    Text(viewModel.tr("presets.save_sheet_title"))
                        .font(.system(size: 12, weight: .bold, design: .rounded))
                        .foregroundColor(.white)

                    Text(viewModel.tr("presets.save_sheet_desc"))
                        .font(.system(size: 10, weight: .medium))
                        .foregroundColor(NXTheme.modalDescription)

                    HStack(spacing: 8) {
                        TextField(viewModel.tr("presets.preset_name_placeholder"), text: $newPresetName)
                            .textFieldStyle(.plain)
                            .padding(.horizontal, 10)
                            .padding(.vertical, 6)
                            .background(Color.black.opacity(0.45))
                            .cornerRadius(8)
                            .overlay(
                                RoundedRectangle(cornerRadius: 8, style: .continuous)
                                    .stroke(NXTheme.specularRim, lineWidth: 1)
                            )
                            .foregroundColor(.white)
                            .font(.system(size: 12, weight: .medium))

                        Button(viewModel.tr("presets.save_action")) {
                            saveCustomPreset()
                        }
                        .buttonStyle(NXPrimaryButtonStyle())
                        .controlSize(.small)
                        .disabled(newPresetName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)

                        Button(viewModel.tr("presets.cancel_action")) {
                            withAnimation(.spring(response: 0.3, dampingFraction: 0.8)) {
                                showingSaveInline = false
                                newPresetName = ""
                            }
                        }
                        .buttonStyle(NXSecondaryButtonStyle())
                        .controlSize(.small)
                    }
                }
                .padding(10)
                .background(
                    RoundedRectangle(cornerRadius: 10, style: .continuous)
                        .fill(Color.black.opacity(0.35))
                )
                .overlay(
                    RoundedRectangle(cornerRadius: 10, style: .continuous)
                        .stroke(NXTheme.secondary.opacity(0.4), lineWidth: 1)
                )
                .transition(.opacity.combined(with: .move(edge: .top)))
            }

            // Status Banner Feedback
            if let feedback = statusFeedback {
                HStack(spacing: 6) {
                    Image(systemName: statusIsError ? "exclamationmark.triangle.fill" : "checkmark.circle.fill")
                        .font(.system(size: 10, weight: .bold))
                        .foregroundColor(statusIsError ? Color.orange : Color(red: 0.13, green: 0.77, blue: 0.37))

                    Text(feedback)
                        .font(.system(size: 10, weight: .semibold))
                        .foregroundColor(.white.opacity(0.92))
                        .lineLimit(1)
                }
                .padding(.horizontal, 8)
                .padding(.vertical, 4)
                .background(
                    RoundedRectangle(cornerRadius: 6, style: .continuous)
                        .fill(Color.black.opacity(0.35))
                )
                .transition(.opacity)
            }
        }
        .padding(12)
        .nxGlassCard(cornerRadius: 14, tint: isFocused ? NXTheme.primary.opacity(0.28) : nil)
        .overlay(
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .strokeBorder(isFocused ? AnyShapeStyle(NXTheme.primaryGradient) : AnyShapeStyle(Color.clear), lineWidth: 2.2)
        )
        .shadow(color: isFocused ? NXTheme.primary.opacity(0.4) : Color.clear, radius: 8, x: 0, y: 2)
        .onTapGesture {
            viewModel.settingsModalFocusIndex = 20
        }
        .id("setting_row_20")
        .onAppear {
            refreshUserPresets()
        }
    }

    // MARK: - Actions

    private func refreshUserPresets() {
        userPresets = GamePresetService.shared.userPresets(for: game)
    }

    private func applyPreset(_ preset: GamePreset) {
        SoundEffectService.shared.play(.click)
        withAnimation(.spring(response: 0.35, dampingFraction: 0.8)) {
            viewModel.activeSettingsConfig.applyPerformanceSettings(from: preset.config, isOot: isOot)
            statusIsError = false
            statusFeedback = String(format: viewModel.tr("presets.imported_success"), preset.name)
        }
        clearFeedbackAfterDelay()
    }

    private func saveCustomPreset() {
        let trimmed = newPresetName.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }

        do {
            let saved = try GamePresetService.shared.saveCustomPreset(
                name: trimmed,
                config: viewModel.activeSettingsConfig,
                for: game
            )
            refreshUserPresets()
            SoundEffectService.shared.play(.click)
            withAnimation(.spring(response: 0.3, dampingFraction: 0.8)) {
                showingSaveInline = false
                newPresetName = ""
                statusIsError = false
                statusFeedback = String(format: viewModel.tr("presets.saved_success"), saved.name)
            }
        } catch {
            SoundEffectService.shared.play(.error)
            statusIsError = true
            statusFeedback = error.localizedDescription
        }
        clearFeedbackAfterDelay()
    }

    private func deleteCurrentPreset(_ preset: GamePreset) {
        SoundEffectService.shared.play(.click)
        GamePresetService.shared.deleteUserPreset(preset, for: game)
        refreshUserPresets()
        withAnimation(.spring(response: 0.3, dampingFraction: 0.8)) {
            statusIsError = false
            statusFeedback = String(format: viewModel.tr("presets.deleted_success"), preset.name)
        }
        clearFeedbackAfterDelay()
    }

    private func exportPresetToFile() {
        let presetToExport: GamePreset = {
            if let matched = activeMatchedPreset {
                return matched
            }
            return GamePreset(
                name: "\(game.name) Preset",
                titleId: game.titleId,
                isBuiltIn: false,
                config: viewModel.activeSettingsConfig,
                createdAt: Date()
            )
        }()

        var safeName = presetToExport.name.replacingOccurrences(of: "/", with: "_")
        while safeName.lowercased().hasSuffix(".nxn") {
            safeName = String(safeName.dropLast(4)).trimmingCharacters(in: .whitespacesAndNewlines)
        }

        let panel = NSSavePanel()
        panel.title = viewModel.tr("presets.export_button")
        panel.nameFieldStringValue = "\(game.name) - \(safeName)"
        panel.allowedContentTypes = [UTType(filenameExtension: "nxn") ?? .data]
        panel.canCreateDirectories = true

        if panel.runModal() == .OK, var dest = panel.url {
            var path = dest.path
            while path.lowercased().hasSuffix(".nxn.nxn") {
                path = String(path.dropLast(4))
            }
            if !path.lowercased().hasSuffix(".nxn") {
                path += ".nxn"
            }
            dest = URL(fileURLWithPath: path)

            do {
                try GamePresetService.shared.exportPreset(presetToExport, for: game, to: dest)
                SoundEffectService.shared.play(.click)
                withAnimation {
                    statusIsError = false
                    statusFeedback = String(format: viewModel.tr("presets.saved_success"), presetToExport.name)
                }
            } catch {
                SoundEffectService.shared.play(.error)
                statusIsError = true
                statusFeedback = error.localizedDescription
            }
            clearFeedbackAfterDelay()
        }
    }

    private func importPresetFromFile() {
        let panel = NSOpenPanel()
        panel.title = viewModel.tr("presets.import_button")
        panel.allowedContentTypes = [UTType(filenameExtension: "nxn") ?? .data]
        panel.allowsMultipleSelection = false
        panel.canChooseFiles = true
        panel.canChooseDirectories = false

        if panel.runModal() == .OK, let source = panel.url {
            do {
                let imported = try GamePresetService.shared.importPreset(from: source, for: game)
                refreshUserPresets()
                applyPreset(imported)
                SoundEffectService.shared.play(.click)
            } catch {
                SoundEffectService.shared.play(.error)
                withAnimation {
                    statusIsError = true
                    statusFeedback = viewModel.tr("presets.invalid_file")
                }
                clearFeedbackAfterDelay()
            }
        }
    }

    private func clearFeedbackAfterDelay() {
        DispatchQueue.main.asyncAfter(deadline: .now() + 4.0) {
            withAnimation(.easeOut(duration: 0.3)) {
                self.statusFeedback = nil
            }
        }
    }
}
