import SwiftUI
import AppKit
import UniformTypeIdentifiers

public struct GameSettingsModsAndSavesView: View {
    public let game: PortedGame
    public var viewModel: AppViewModel? = nil
    public var onOpenBatchModal: (() -> Void)? = nil
    @ObservedObject private var modService = ModManagerService.shared
    @ObservedObject private var deviceService = DeviceDeploymentService.shared
    @State private var modsList: [GameModItem] = []
    @State private var isDropTargeted: Bool = false
    @State private var isInstallingMod: Bool = false
    @State private var installFeedbackMessage: String? = nil

    public init(game: PortedGame, viewModel: AppViewModel? = nil, onOpenBatchModal: (() -> Void)? = nil) {
        self.game = game
        self.viewModel = viewModel
        self.onOpenBatchModal = onOpenBatchModal
    }

    private var titleId: String {
        game.titleId ?? CompatibilityService.shared.findTitleId(forGameTitle: game.name) ?? "UNKNOWN"
    }

    public var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            if game.platform == .ios {
                GameSettingsIosDeploymentView(game: game, viewModel: viewModel)
            } else {
                if game.platform == .macApp {
                    if let vm = viewModel {
                        GameSettingsShaderSectionView(game: game, viewModel: vm)
                    }
                    modsSection
                }
                GameSettingsSavesSectionView(game: game, viewModel: viewModel)
            }
        }
        .onAppear {
            if game.platform != .nonSwitch && game.platform != .ios {
                refreshMods()
            }
            deviceService.refreshDevicesAndTeams()
        }
        .onReceive(modService.$refreshTrigger) { _ in
            refreshMods()
        }
    }

    // MARK: - Mods Management Section
    private var modsSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            modsHeader

            if isInstallingMod {
                installingIndicator
            }

            if let msg = installFeedbackMessage {
                Text(msg)
                    .font(.system(size: 11, weight: .medium))
                    .foregroundColor(NXTheme.textSecondary)
                    .padding(6)
            }

            if modsList.isEmpty {
                modsEmptyView
            } else {
                modsListView
            }
        }
        .padding(14)
        .nxGlassCard(cornerRadius: 14)
        .onDrop(of: [.fileURL], isTargeted: $isDropTargeted) { providers in
            handleDrop(providers)
        }
    }

    private var modsHeader: some View {
        HStack(spacing: 8) {
            Label(L10n.t("settings_modal.mods_title"), systemImage: "puzzlepiece.extension.fill")
                .font(.system(size: 13, weight: .bold, design: .rounded))
                .foregroundColor(NXTheme.textPrimary)

            Spacer()

            Button(action: chooseModToInstall) {
                HStack(spacing: 4) {
                    Image(systemName: "plus.circle.fill")
                    Text(L10n.t("settings_modal.install_mod", default: "Install Mod..."))
                }
            }
            .buttonStyle(NXSecondaryButtonStyle())
            .controlSize(.mini)
            .disabled(isInstallingMod)

            Button(action: {
                SoundEffectService.shared.play(.click)
                modService.openModsFolder(for: titleId)
            }) {
                HStack(spacing: 4) {
                    Image(systemName: "folder.fill")
                    Text(L10n.t("settings_modal.open_mods_folder"))
                }
            }
            .buttonStyle(NXSecondaryButtonStyle())
            .controlSize(.mini)
        }
    }

    private var installingIndicator: some View {
        HStack(spacing: 8) {
            ProgressView()
                .controlSize(.small)
            Text(L10n.t("settings_modal.mod_installing", default: "Installing mod..."))
                .font(.system(size: 11, weight: .medium))
                .foregroundColor(NXTheme.primary)
        }
        .padding(8)
        .frame(maxWidth: .infinity, alignment: .leading)
        .nxGlassCard(cornerRadius: 10, isNested: true)
    }

    private var modsEmptyView: some View {
        VStack(spacing: 8) {
            Image(systemName: "square.and.arrow.down.on.square")
                .font(.system(size: 24))
                .foregroundColor(isDropTargeted ? NXTheme.primary : NXTheme.textMuted)
            Text(L10n.t("settings_modal.no_mods"))
                .font(.system(size: 11))
                .foregroundColor(NXTheme.textSecondary)
            Text(L10n.t("settings_modal.drop_mod_hint", default: "Drag & drop mod (.zip or folder) here to install"))
                .font(.system(size: 10))
                .foregroundColor(NXTheme.textMuted)
        }
        .padding(14)
        .frame(maxWidth: .infinity)
        .nxGlassCard(cornerRadius: 10, isNested: true)
        .overlay(
            RoundedRectangle(cornerRadius: 10)
                .stroke(isDropTargeted ? NXTheme.primary : Color.clear, lineWidth: 1.5)
        )
    }

    private var modsListView: some View {
        VStack(spacing: 6) {
            ForEach(modsList) { mod in
                modRowView(for: mod)
            }
        }
        .overlay(
            RoundedRectangle(cornerRadius: 10)
                .stroke(isDropTargeted ? NXTheme.primary : Color.clear, lineWidth: 1.5)
        )
    }

    private func modRowView(for mod: GameModItem) -> some View {
        HStack(spacing: 8) {
            VStack(alignment: .leading, spacing: 3) {
                Text(mod.name)
                    .font(.system(size: 12, weight: .semibold, design: .rounded))
                    .foregroundColor(NXTheme.textPrimary)

                HStack(spacing: 6) {
                    if mod.hasAssetPatches {
                        HStack(spacing: 3) {
                            Image(systemName: "checkmark.circle.fill")
                                .font(.system(size: 9))
                            Text(L10n.t("settings_modal.mod_badge_romfs", default: "RomFS Asset Layer"))
                                .font(.system(size: 9, weight: .medium))
                        }
                        .foregroundColor(Color.cyan)
                        .padding(.horizontal, 5)
                        .padding(.vertical, 1)
                        .background(Color.cyan.opacity(0.15))
                        .cornerRadius(4)
                    }

                    if mod.hasCodePatches {
                        HStack(spacing: 3) {
                            Image(systemName: "exclamationmark.triangle.fill")
                                .font(.system(size: 9))
                            Text(L10n.t("settings_modal.mod_badge_code_only", default: "Code Patch (exefs)"))
                                .font(.system(size: 9, weight: .medium))
                        }
                        .foregroundColor(Color.orange)
                        .padding(.horizontal, 5)
                        .padding(.vertical, 1)
                        .background(Color.orange.opacity(0.15))
                        .cornerRadius(4)
                    }
                }
            }

            Spacer()

            Button(action: {
                deleteMod(mod)
            }) {
                Image(systemName: "trash")
                    .font(.system(size: 11))
                    .foregroundColor(NXTheme.textMuted)
            }
            .buttonStyle(PlainButtonStyle())
            .help(L10n.t("settings_modal.mod_delete", default: "Delete Mod"))

            Toggle("", isOn: Binding(
                get: { mod.isEnabled },
                set: { _ in
                    toggleMod(mod)
                }
            ))
            .toggleStyle(.switch)
            .labelsHidden()
        }
        .padding(8)
        .nxGlassCard(cornerRadius: 10, isNested: true)
    }

    private func refreshMods() {
        modsList = modService.discoverMods(for: titleId, appURL: game.url)
    }

    private func toggleMod(_ mod: GameModItem) {
        SoundEffectService.shared.play(.click)
        _ = modService.toggleMod(mod, in: titleId)
        GameRuntimeConfig.load(for: game).applyToDisk(for: game)
        refreshMods()
    }

    private func deleteMod(_ mod: GameModItem) {
        SoundEffectService.shared.play(.click)
        _ = modService.deleteMod(mod)
        GameRuntimeConfig.load(for: game).applyToDisk(for: game)
        refreshMods()
    }

    private func chooseModToInstall() {
        SoundEffectService.shared.play(.click)
        let panel = NSOpenPanel()
        panel.title = L10n.t("settings_modal.install_mod", default: "Install Mod")
        panel.prompt = L10n.t("common.choose", default: "Install")
        panel.allowsMultipleSelection = false
        panel.canChooseFiles = true
        panel.canChooseDirectories = true
        panel.allowedContentTypes = [.zip, .folder]
        if panel.runModal() == .OK, let selectedURL = panel.url {
            installModURL(selectedURL)
        }
    }

    private func handleDrop(_ providers: [NSItemProvider]) -> Bool {
        guard let provider = providers.first else { return false }
        _ = provider.loadObject(ofClass: URL.self) { url, _ in
            guard let url = url else { return }
            DispatchQueue.main.async {
                installModURL(url)
            }
        }
        return true
    }

    private func installModURL(_ url: URL) {
        isInstallingMod = true
        installFeedbackMessage = nil
        SoundEffectService.shared.play(.click)
        modService.installMod(from: url, for: titleId) { result in
            isInstallingMod = false
            switch result {
            case .success(let item):
                SoundEffectService.shared.play(.click)
                installFeedbackMessage = "Installed: \(item.name)"
                GameRuntimeConfig.load(for: game).applyToDisk(for: game)
                refreshMods()
            case .failure(let error):
                SoundEffectService.shared.play(.error)
                installFeedbackMessage = "Error: \(error.localizedDescription)"
            }
        }
    }
}
