import SwiftUI

extension ControllerPromptBar {
    private var onboardingConfirmGlyph: String {
        controllerService.activeBrand == .playstation ? "✕" : "A"
    }

    private var onboardingCancelGlyph: String {
        controllerService.activeBrand == .playstation ? "○" : "B"
    }

    @ViewBuilder
    var onboardingControllerPrompts: some View {
        switch viewModel.onboardingStep {
        case .language:
            dpadPill(glyph: "D-Pad", action: viewModel.tr("onboarding.prompt_choose_lang"))
            controllerPill(glyph: onboardingConfirmGlyph, action: viewModel.tr("onboarding.continue"), color: brandAColor)
        case .targetPlatforms:
            controllerPill(glyph: onboardingConfirmGlyph, action: viewModel.tr("onboarding.continue"), color: brandAColor)
            controllerPill(glyph: onboardingCancelGlyph, action: viewModel.tr("onboarding.back"), color: brandBColor)
        case .dependenciesOverview:
            controllerPill(glyph: onboardingConfirmGlyph, action: viewModel.tr("onboarding.install_button"), color: brandAColor)
            controllerPill(glyph: onboardingCancelGlyph, action: viewModel.tr("onboarding.back"), color: brandBColor)
        case .installingDependencies:
            if viewModel.onboardingInstallError != nil {
                controllerPill(glyph: onboardingConfirmGlyph, action: viewModel.tr("onboarding.retry_button"), color: brandAColor)
                controllerPill(glyph: onboardingCancelGlyph, action: viewModel.tr("onboarding.continue_anyway"), color: brandBColor)
            }
        case .prodKeys:
            if viewModel.isProdKeysValid {
                controllerPill(glyph: onboardingConfirmGlyph, action: viewModel.tr("onboarding.keys_finish_button"), color: brandAColor)
            } else {
                controllerPill(glyph: onboardingConfirmGlyph, action: viewModel.tr("onboarding.keys_choose_button"), color: brandAColor)
                controllerPill(glyph: onboardingCancelGlyph, action: viewModel.tr("onboarding.prompt_skip_later"), color: brandBColor)
            }
        }
    }

    @ViewBuilder
    var onboardingKeyboardPrompts: some View {
        switch viewModel.onboardingStep {
        case .language:
            keyboardKeyBadge(glyph: "←/→/↑/↓", action: viewModel.tr("onboarding.prompt_choose_lang"))
            keyboardKeyBadge(glyph: "⏎", action: viewModel.tr("onboarding.continue"))
        case .targetPlatforms:
            keyboardKeyBadge(glyph: "⏎", action: viewModel.tr("onboarding.continue"))
            keyboardKeyBadge(glyph: "Esc", action: viewModel.tr("onboarding.back"))
        case .dependenciesOverview:
            keyboardKeyBadge(glyph: "⏎", action: viewModel.tr("onboarding.install_button"))
            keyboardKeyBadge(glyph: "Esc", action: viewModel.tr("onboarding.back"))
        case .installingDependencies:
            if viewModel.onboardingInstallError != nil {
                keyboardKeyBadge(glyph: "⏎", action: viewModel.tr("onboarding.retry_button"))
                keyboardKeyBadge(glyph: "Esc", action: viewModel.tr("onboarding.continue_anyway"))
            }
        case .prodKeys:
            if viewModel.isProdKeysValid {
                keyboardKeyBadge(glyph: "⏎", action: viewModel.tr("onboarding.keys_finish_button"))
            } else {
                keyboardKeyBadge(glyph: "⏎", action: viewModel.tr("onboarding.keys_choose_button"))
                keyboardKeyBadge(glyph: "Esc", action: viewModel.tr("onboarding.prompt_skip_later"))
            }
        }
    }
}
