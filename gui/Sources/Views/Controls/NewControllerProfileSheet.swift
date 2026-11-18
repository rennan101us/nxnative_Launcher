import SwiftUI
import GameController

struct NewControllerProfileSheet: View {
    @ObservedObject var viewModel: AppViewModel
    @ObservedObject var profileManager = InputProfileManager.shared
    @Binding var isPresented: Bool
    @Binding var activeProfile: ControllerProfile
    @FocusState private var textFieldFocused: Bool
    private var i18n = LocalizationService.shared

    var body: some View {
        let trimmed = viewModel.newProfileNameInput.trimmingCharacters(in: .whitespaces)
        return VStack(spacing: 16) {
            Text(i18n.t("controls.new_profile"))
                .font(.system(size: 14, weight: .bold, design: .rounded))
                .foregroundColor(NXTheme.textPrimary)

            NXLiquidGlassTextField("Profile Name (e.g. Zelda Pro Controls)", text: $viewModel.newProfileNameInput)
                .focused($textFieldFocused)
                .frame(width: 290)
                .nxConsoleFocusRing(in: RoundedRectangle(cornerRadius: 9, style: .continuous), isFocused: viewModel.newProfileModalFocusIndex == 0)
                .onChange(of: viewModel.isNewProfileTextFocused) { wanted in
                    if textFieldFocused != wanted { textFieldFocused = wanted }
                }
                .onChange(of: textFieldFocused) { active in
                    if viewModel.isNewProfileTextFocused != active { viewModel.isNewProfileTextFocused = active }
                }

            NXGlassContainer(spacing: 12) {
                HStack(spacing: 12) {
                    Button(i18n.t("common.cancel")) {
                        SoundEffectService.shared.play(.click)
                        isPresented = false
                    }
                    .buttonStyle(NXSecondaryButtonStyle())
                    .nxConsoleFocusRing(in: RoundedRectangle(cornerRadius: 10, style: .continuous), isFocused: viewModel.newProfileModalFocusIndex == 1)

                    Button(i18n.t("controls.create")) {
                        guard !trimmed.isEmpty else { return }
                        SoundEffectService.shared.play(.click)
                        let created = profileManager.createProfile(name: trimmed, basedOn: activeProfile)
                        profileManager.setProfile(created, forPlayer: profileManager.activePlayerIndex)
                        activeProfile = created
                        isPresented = false
                    }
                    .buttonStyle(NXPrimaryButtonStyle())
                    .disabled(trimmed.isEmpty)
                    .nxConsoleFocusRing(in: RoundedRectangle(cornerRadius: 10, style: .continuous), isFocused: viewModel.newProfileModalFocusIndex == 2)
                }
            }
        }
        .padding(24)
        .frame(width: 340, height: 168)
        .nxSheetSurface()
        .onAppear {
            viewModel.newProfileModalFocusIndex = 0
            viewModel.isNewProfileTextFocused = true
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.08) {
                textFieldFocused = true
            }
        }
    }
}
