import SwiftUI

/// Reusable Apple Liquid Glass confirmation and alert overlay replacing native macOS `.confirmationDialog` / `.alert`,
/// providing full Gamepad (D-Pad/A/B) and Keyboard (Arrows/Enter/Esc) navigation.
public struct NXConfirmationOverlayView: View {
    @ObservedObject public var viewModel: AppViewModel

    public init(viewModel: AppViewModel) {
        self.viewModel = viewModel
    }

    private struct DialogSpec {
        let icon: String
        let accent: Color
        let title: String
        let message: String
        let primaryTitle: String
        let isDestructive: Bool
        let isSingleButton: Bool
    }

    private var activeSpec: DialogSpec? {
        if viewModel.showHideConfirm {
            return DialogSpec(
                icon: "eye.slash.fill",
                accent: NXTheme.secondary,
                title: viewModel.tr("library.hide_title", viewModel.gameToHide?.name ?? "Game"),
                message: viewModel.tr("library.hide_message"),
                primaryTitle: viewModel.tr("library.hide_button"),
                isDestructive: false,
                isSingleButton: false
            )
        }
        if viewModel.showRemoveConfirm {
            return DialogSpec(
                icon: "folder.badge.minus",
                accent: Color.orange,
                title: viewModel.tr("library.remove_title", viewModel.gameToRemove?.name ?? "Game"),
                message: viewModel.tr("library.remove_message"),
                primaryTitle: viewModel.tr("library.remove_button"),
                isDestructive: true,
                isSingleButton: false
            )
        }
        if viewModel.showTrashConfirm {
            return DialogSpec(
                icon: "trash.fill",
                accent: Color.red,
                title: viewModel.tr("library.trash_title", viewModel.gameToTrash?.name ?? "Game"),
                message: viewModel.tr("library.trash_message"),
                primaryTitle: viewModel.tr("library.trash_button"),
                isDestructive: true,
                isSingleButton: false
            )
        }
        if viewModel.showDeleteConfirm {
            return DialogSpec(
                icon: "trash.fill",
                accent: Color.red,
                title: viewModel.tr("library.delete_title", viewModel.gameToDelete?.name ?? "Game"),
                message: viewModel.tr("library.trash_message"),
                primaryTitle: viewModel.tr("library.trash_button"),
                isDestructive: true,
                isSingleButton: false
            )
        }
        if viewModel.showUninstallConfirm {
            return DialogSpec(
                icon: "wrench.and.screwdriver.fill",
                accent: Color.red,
                title: viewModel.tr("system.uninstall_title", viewModel.dependencyToUninstall?.name ?? "Tool"),
                message: viewModel.tr("system.uninstall_message"),
                primaryTitle: viewModel.tr("system.uninstall_button"),
                isDestructive: true,
                isSingleButton: false
            )
        }
        if viewModel.showCltInstallAlert {
            return DialogSpec(
                icon: "hammer.fill",
                accent: NXTheme.primary,
                title: "Apple Command Line Tools",
                message: viewModel.tr("build.apple_clt_dialog"),
                primaryTitle: viewModel.tr("common.ok"),
                isDestructive: false,
                isSingleButton: true
            )
        }
        return nil
    }

    public var body: some View {
        if let spec = activeSpec {
            ZStack {
                Color.black.opacity(0.62)
                    .ignoresSafeArea()
                    .onTapGesture {
                        SoundEffectService.shared.play(.click)
                        viewModel.dismissActiveConfirmationDialogs()
                    }

                VStack(alignment: .leading, spacing: 14) {
                    HStack(spacing: 10) {
                        Image(systemName: spec.icon)
                            .font(.system(size: 18, weight: .bold))
                            .foregroundColor(spec.accent)

                        Text(spec.title)
                            .font(.system(size: 15, weight: .bold, design: .rounded))
                            .foregroundColor(.white)
                            .fixedSize(horizontal: false, vertical: true)

                        Spacer()
                    }

                    Text(spec.message)
                        .font(.system(size: 12.5, weight: .medium))
                        .foregroundColor(NXTheme.modalDescription)
                        .fixedSize(horizontal: false, vertical: true)
                        .lineSpacing(2)

                    NXGlassContainer(spacing: 10) {
                        HStack(spacing: 10) {
                            Spacer()

                            if !spec.isSingleButton {
                                Button(action: {
                                    SoundEffectService.shared.play(.click)
                                    viewModel.executeActiveConfirmationAction()
                                }) {
                                    Text(spec.primaryTitle)
                                        .font(.system(size: 12.5, weight: .bold, design: .rounded))
                                        .foregroundColor(.white)
                                        .padding(.horizontal, 16)
                                        .padding(.vertical, 8)
                                        .nxGlassInteractive(
                                            in: Capsule(),
                                            tint: (spec.isDestructive ? Color.red : NXTheme.primary).opacity(viewModel.confirmDialogFocusIndex == 0 ? 0.85 : 0.45),
                                            isSelected: viewModel.confirmDialogFocusIndex == 0,
                                            fallbackFill: (spec.isDestructive ? Color.red : NXTheme.primary).opacity(0.75)
                                        )
                                }
                                .buttonStyle(NXPressableButtonStyle())
                                .nxNoFocusRing()
                                .nxConsoleFocusRing(in: Capsule(), isFocused: viewModel.confirmDialogFocusIndex == 0, accent: spec.isDestructive ? .red : NXTheme.secondary)

                                Button(action: {
                                    SoundEffectService.shared.play(.click)
                                    viewModel.dismissActiveConfirmationDialogs()
                                }) {
                                    Text(viewModel.tr("library.cancel"))
                                        .font(.system(size: 12.5, weight: .semibold, design: .rounded))
                                        .foregroundColor(.white)
                                        .padding(.horizontal, 16)
                                        .padding(.vertical, 8)
                                        .nxGlassInteractive(
                                            in: Capsule(),
                                            tint: viewModel.confirmDialogFocusIndex == 1 ? NXTheme.secondary.opacity(0.45) : nil,
                                            isSelected: viewModel.confirmDialogFocusIndex == 1,
                                            fallbackFill: NXTheme.glassSurfaceElevated.opacity(0.85)
                                        )
                                }
                                .buttonStyle(NXPressableButtonStyle())
                                .nxNoFocusRing()
                                .nxConsoleFocusRing(in: Capsule(), isFocused: viewModel.confirmDialogFocusIndex == 1)
                            } else {
                                Button(action: {
                                    SoundEffectService.shared.play(.click)
                                    viewModel.dismissActiveConfirmationDialogs()
                                }) {
                                    Text(spec.primaryTitle)
                                        .font(.system(size: 12.5, weight: .bold, design: .rounded))
                                        .foregroundColor(.white)
                                        .padding(.horizontal, 18)
                                        .padding(.vertical, 8)
                                        .nxGlassInteractive(
                                            in: Capsule(),
                                            tint: NXTheme.primary.opacity(0.78),
                                            isSelected: true,
                                            fallbackFill: NXTheme.primary
                                        )
                                }
                                .buttonStyle(NXPressableButtonStyle())
                                .nxNoFocusRing()
                                .nxConsoleFocusRing(in: Capsule(), isFocused: true)
                            }
                        }
                    }
                }
                .padding(22)
                .frame(maxWidth: 440)
                .nxGlassBar(in: RoundedRectangle(cornerRadius: 20, style: .continuous), tint: spec.accent.opacity(0.16))
                .shadow(color: Color.black.opacity(0.65), radius: 24, x: 0, y: 12)
            }
            .transition(.opacity.combined(with: .scale(scale: 0.96)))
        }
    }
}
