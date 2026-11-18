import SwiftUI
import UniformTypeIdentifiers

public struct OnboardingFlowView: View {
    @ObservedObject public var viewModel: AppViewModel
    @ObservedObject private var localization = LocalizationService.shared

    @Namespace private var stepPillNamespace
    @State private var hoveredLanguage: AppLanguage? = nil
    @State private var isKeysDropTargeted: Bool = false
    @State private var isDropZoneHovered: Bool = false
    @State private var shimmerOffset: CGFloat = -0.35

    private let languageColumns: [GridItem] = Array(
        repeating: GridItem(.flexible(), spacing: 12),
        count: 3
    )

    public init(viewModel: AppViewModel) {
        self.viewModel = viewModel
    }

    public var body: some View {
        // Bind to localization changes so Step 1 re-translates every string live.
        let _ = localization.effectiveLanguage
        let _ = viewModel.launcherLanguage

        ScrollView(.vertical, showsIndicators: false) {
            VStack(spacing: 22) {
                Spacer(minLength: 8)

                onboardingHeader
                    .padding(.top, 12)

                NXGlassContainer(spacing: 16) {
                    GlassCard(cornerRadius: 28, padding: 30) {
                        ZStack {
                            switch viewModel.onboardingStep {
                            case .language:
                                languageStepView
                                    .transition(stepTransition)
                            case .targetPlatforms:
                                targetPlatformsStepView
                                    .transition(stepTransition)
                            case .dependenciesOverview:
                                dependenciesOverviewStepView
                                    .transition(stepTransition)
                            case .installingDependencies:
                                installingDependenciesStepView
                                    .transition(stepTransition)
                            case .prodKeys:
                                prodKeysStepView
                                    .transition(stepTransition)
                            }
                        }
                        .id(viewModel.onboardingStep)
                        .animation(.spring(response: 0.42, dampingFraction: 0.86), value: viewModel.onboardingStep)
                    }
                    .frame(maxWidth: (viewModel.onboardingStep == .language || viewModel.onboardingStep == .targetPlatforms) ? 740 : 620)
                }

                Spacer(minLength: 12)
            }
            .padding(.horizontal, 36)
            .padding(.vertical, 20)
            .frame(maxWidth: .infinity, minHeight: 540)
        }
        .onAppear {
            withAnimation(.linear(duration: 1.8).repeatForever(autoreverses: false)) {
                shimmerOffset = 1.35
            }
        }
    }

    private var stepTransition: AnyTransition {
        .asymmetric(
            insertion: .opacity
                .combined(with: .scale(scale: 0.97))
                .combined(with: .offset(y: 12)),
            removal: .opacity
                .combined(with: .scale(scale: 0.98))
                .combined(with: .offset(y: -12))
        )
    }

    // MARK: - Header & Step Progress Indicator

    private var onboardingHeader: some View {
        VStack(spacing: 14) {
            HStack(spacing: 12) {
                appEmblemView

                VStack(alignment: .leading, spacing: 2) {
                    Text("NxNative Launcher")
                        .font(.system(size: 18, weight: .bold, design: .rounded))
                        .foregroundColor(NXTheme.textPrimary)

                    Text(viewModel.tr("onboarding.step_badge", viewModel.onboardingStep.rawValue + 1, OnboardingStep.allCases.count))
                        .font(.system(size: 12, weight: .medium, design: .rounded))
                        .foregroundColor(NXTheme.textMuted)
                }
            }

            HStack(spacing: 8) {
                ForEach(OnboardingStep.allCases, id: \.rawValue) { step in
                    let isActive = step == viewModel.onboardingStep
                    let isDone = step.rawValue < viewModel.onboardingStep.rawValue

                    ZStack {
                        Capsule()
                            .fill(
                                isDone
                                ? NXTheme.primary.opacity(0.45)
                                : Color.white.opacity(0.10)
                            )
                            .frame(width: isActive ? 44 : 20, height: 6)

                        if isActive {
                            Capsule()
                                .fill(NXTheme.primaryGradient)
                                .frame(width: 44, height: 6)
                                .shadow(color: NXTheme.primary.opacity(0.6), radius: 6)
                                .matchedGeometryEffect(id: "onboardingActiveStepPill", in: stepPillNamespace)
                        }
                    }
                    .animation(.spring(response: 0.35, dampingFraction: 0.8), value: viewModel.onboardingStep)
                }
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 8)
            .nxGlassBar(in: Capsule(), tint: NXTheme.primary.opacity(0.18))
        }
    }

    @ViewBuilder
    private var appEmblemView: some View {
        let iconImage = AppIconCache.image(named: viewModel.iconAppearanceMode.resourceName)
        ZStack {
            RoundedRectangle(cornerRadius: 13, style: .continuous)
                .fill(Color.white.opacity(0.08))
                .frame(width: 46, height: 46)
                .overlay(
                    RoundedRectangle(cornerRadius: 13, style: .continuous)
                        .strokeBorder(NXTheme.specularRim, lineWidth: 1)
                )

            if let nsImage = iconImage {
                Image(nsImage: nsImage)
                    .resizable()
                    .interpolation(.high)
                    .antialiased(true)
                    .aspectRatio(contentMode: .fit)
                    .frame(width: 34, height: 34)
                    .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
            } else {
                Image(systemName: "gamecontroller.fill")
                    .font(.system(size: 20, weight: .semibold))
                    .foregroundStyle(NXTheme.primaryGradient)
            }
        }
        .shadow(color: NXTheme.primary.opacity(0.28), radius: 10, y: 3)
    }

    // MARK: - Step 1: Language Selection

    private var languageStepView: some View {
        VStack(spacing: 22) {
            VStack(spacing: 8) {
                Image(systemName: "globe")
                    .font(.system(size: 28, weight: .semibold))
                    .foregroundStyle(NXTheme.primaryGradient)
                    .padding(12)
                    .nxGlassCard(cornerRadius: 18, tint: NXTheme.primary, isNested: true)

                Text(viewModel.tr("onboarding.language_title"))
                    .font(.system(size: 26, weight: .bold, design: .rounded))
                    .foregroundColor(NXTheme.textPrimary)
                    .multilineTextAlignment(.center)

                Text(viewModel.tr("onboarding.language_subtitle"))
                    .font(.system(size: 14, weight: .regular))
                    .foregroundColor(NXTheme.textSecondary)
                    .multilineTextAlignment(.center)
            }

            LazyVGrid(columns: languageColumns, spacing: 10) {
                ForEach(Array(AppViewModel.onboardingLanguages.enumerated()), id: \.element.id) { index, language in
                    let isSelected = viewModel.activeOnboardingLanguage == language
                    let isFocused = viewModel.onboardingLanguageFocusIndex == index
                    let isHovered = hoveredLanguage == language

                    Button(action: {
                        viewModel.selectOnboardingLanguage(language)
                    }) {
                        HStack(spacing: 10) {
                            Text(language.flag)
                                .font(.system(size: 18))

                            Text(language.nativeName)
                                .font(.system(size: 13.5, weight: isSelected ? .bold : .medium, design: .rounded))
                                .foregroundColor(NXTheme.textPrimary)
                                .lineLimit(1)
                                .minimumScaleFactor(0.85)

                            Spacer(minLength: 4)

                            if isSelected {
                                Image(systemName: "checkmark.circle.fill")
                                    .font(.system(size: 14, weight: .semibold))
                                    .foregroundColor(NXTheme.primary)
                            }
                        }
                        .padding(.horizontal, 13)
                        .padding(.vertical, 11)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .contentShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
                    }
                    .buttonStyle(NXPressableButtonStyle())
                    .nxGlassInteractive(
                        in: RoundedRectangle(cornerRadius: 14, style: .continuous),
                        tint: NXTheme.primary,
                        isSelected: isSelected,
                        isFocused: isFocused,
                        isHovered: isHovered
                    )
                    .overlay(
                        RoundedRectangle(cornerRadius: 14, style: .continuous)
                            .strokeBorder(
                                isFocused && !isSelected
                                ? NXTheme.primary.opacity(0.65)
                                : Color.clear,
                                lineWidth: 1.4
                            )
                    )
                    .nxNoFocusRing()
                    .onHover { hovering in
                        hoveredLanguage = hovering ? language : (hoveredLanguage == language ? nil : hoveredLanguage)
                    }
                }
            }

            HStack {
                Spacer()
                Button(action: {
                    viewModel.advanceOnboardingStep()
                }) {
                    HStack(spacing: 8) {
                        Text(viewModel.tr("onboarding.continue"))
                        Image(systemName: "arrow.right")
                            .font(.system(size: 13, weight: .bold))
                    }
                    .frame(minWidth: 150)
                }
                .buttonStyle(NXPrimaryButtonStyle())
                .nxNoFocusRing()
                Spacer()
            }
            .padding(.top, 4)
        }
    }

    // MARK: - Step 2: Target Platforms Selection

    private var targetPlatformsStepView: some View {
        VStack(spacing: 22) {
            VStack(spacing: 10) {
                Image(systemName: "square.grid.3x3.topleft.filled")
                    .font(.system(size: 30, weight: .semibold))
                    .foregroundStyle(NXTheme.primaryGradient)
                    .padding(14)
                    .nxGlassCard(cornerRadius: 20, tint: NXTheme.primary, isNested: true)

                Text(viewModel.tr("onboarding.platforms_title"))
                    .font(.system(size: 26, weight: .bold, design: .rounded))
                    .foregroundColor(NXTheme.textPrimary)
                    .multilineTextAlignment(.center)

                Text(viewModel.tr("onboarding.platforms_desc"))
                    .font(.system(size: 14, weight: .regular))
                    .foregroundColor(NXTheme.textSecondary)
                    .multilineTextAlignment(.center)
                    .lineSpacing(3)
                    .frame(maxWidth: 520)
            }

            VStack(spacing: 12) {
                platformCheckboxRow(
                    platform: .macApp,
                    icon: "macbook.and.display",
                    title: viewModel.tr("port_modal.platform_mac_title"),
                    desc: viewModel.tr("onboarding.platform_mac_desc"),
                    footprint: "~1.9 GB download"
                )

                platformCheckboxRow(
                    platform: .ios,
                    icon: "iphone.and.arrow.forward",
                    title: viewModel.tr("port_modal.platform_ios_title"),
                    desc: viewModel.tr("onboarding.platform_ios_desc"),
                    footprint: "+20 MB (libimobiledevice)"
                )

                platformCheckboxRow(
                    platform: .android,
                    icon: "candybarphone",
                    title: viewModel.tr("port_modal.platform_android_title"),
                    desc: viewModel.tr("onboarding.platform_android_desc"),
                    footprint: "+1.12 GB (Android NDK & adb)"
                )
            }
            .frame(maxWidth: 520)

            HStack(spacing: 14) {
                Button(action: {
                    viewModel.goBackOnboardingStep()
                }) {
                    HStack(spacing: 6) {
                        Image(systemName: "chevron.left")
                            .font(.system(size: 12, weight: .semibold))
                        Text(viewModel.tr("onboarding.back"))
                    }
                    .frame(minWidth: 110)
                }
                .buttonStyle(NXSecondaryButtonStyle())
                .nxNoFocusRing()

                Button(action: {
                    viewModel.advanceOnboardingStep()
                }) {
                    HStack(spacing: 8) {
                        Text(viewModel.tr("onboarding.continue"))
                        Image(systemName: "arrow.right")
                            .font(.system(size: 13, weight: .bold))
                    }
                    .frame(minWidth: 160)
                }
                .buttonStyle(NXPrimaryButtonStyle())
                .nxNoFocusRing()
            }
            .padding(.top, 4)
        }
    }

    private func platformCheckboxRow(
        platform: TargetPlatform,
        icon: String,
        title: String,
        desc: String,
        footprint: String
    ) -> some View {
        let isSelected = viewModel.selectedOnboardingPlatforms.contains(platform)

        return Button(action: {
            viewModel.toggleOnboardingPlatform(platform)
        }) {
            HStack(spacing: 14) {
                ZStack {
                    RoundedRectangle(cornerRadius: 8, style: .continuous)
                        .fill(isSelected ? NXTheme.primary : NXTheme.glassSurfaceElevated.opacity(0.8))
                        .frame(width: 24, height: 24)
                        .overlay(
                            RoundedRectangle(cornerRadius: 8, style: .continuous)
                                .strokeBorder(isSelected ? Color.white.opacity(0.3) : NXTheme.borderSubtle, lineWidth: 1)
                        )

                    if isSelected {
                        Image(systemName: "checkmark")
                            .font(.system(size: 12, weight: .bold))
                            .foregroundColor(.white)
                    }
                }

                Image(systemName: icon)
                    .font(.system(size: 20, weight: .semibold))
                    .foregroundColor(isSelected ? (NXTheme.isNeonBlack ? .white : NXTheme.primary) : NXTheme.textSecondary)
                    .frame(width: 28)

                VStack(alignment: .leading, spacing: 2) {
                    HStack(spacing: 8) {
                        Text(title)
                            .font(.system(size: 14, weight: .bold, design: .rounded))
                            .foregroundColor(NXTheme.textPrimary)

                        Text(footprint)
                            .font(.system(size: 10, weight: .semibold, design: .monospaced))
                            .foregroundColor(NXTheme.secondary)
                            .padding(.horizontal, 6)
                            .padding(.vertical, 2)
                            .background(NXTheme.glassSurfaceElevated.opacity(0.85))
                            .clipShape(Capsule())
                    }

                    Text(desc)
                        .font(.system(size: 11.5))
                        .foregroundColor(NXTheme.textSecondary)
                        .lineLimit(2)
                }

                Spacer(minLength: 4)
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 12)
            .frame(maxWidth: .infinity, alignment: .leading)
            .contentShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
        }
        .buttonStyle(NXPressableButtonStyle())
        .nxGlassInteractive(
            in: RoundedRectangle(cornerRadius: 14, style: .continuous),
            tint: NXTheme.primary,
            isSelected: isSelected
        )
        .nxNoFocusRing()
    }

    // MARK: - Step 3: Dependencies Overview & Total Weight

    private var dependenciesOverviewStepView: some View {
        VStack(spacing: 24) {
            VStack(spacing: 10) {
                Image(systemName: "shippingbox.and.arrow.backward.fill")
                    .font(.system(size: 30, weight: .semibold))
                    .foregroundStyle(NXTheme.primaryGradient)
                    .padding(14)
                    .nxGlassCard(cornerRadius: 20, tint: NXTheme.primary, isNested: true)

                Text(viewModel.tr("onboarding.deps_title"))
                    .font(.system(size: 26, weight: .bold, design: .rounded))
                    .foregroundColor(NXTheme.textPrimary)
                    .multilineTextAlignment(.center)

                Text(viewModel.tr("onboarding.deps_message"))
                    .font(.system(size: 14.5, weight: .regular))
                    .foregroundColor(NXTheme.textSecondary)
                    .multilineTextAlignment(.center)
                    .lineSpacing(3)
                    .frame(maxWidth: 500)
            }

            VStack(spacing: 6) {
                Text(viewModel.tr("onboarding.deps_total_size_label"))
                    .font(.system(size: 11.5, weight: .semibold, design: .rounded))
                    .textCase(.uppercase)
                    .tracking(0.8)
                    .foregroundColor(NXTheme.textMuted)

                Text(viewModel.onboardingFormattedTotalSize)
                    .font(.system(size: 32, weight: .heavy, design: .rounded))
                    .foregroundStyle(NXTheme.primaryGradient)
                    .monospacedDigit()

                Text(
                    viewModel.onboardingComponentCount > 0
                    ? viewModel.tr("onboarding.deps_summary_count", viewModel.onboardingComponentCount)
                    : viewModel.tr("onboarding.deps_none_missing")
                )
                .font(.system(size: 12.5, weight: .medium, design: .rounded))
                .foregroundColor(NXTheme.textSecondary)
            }
            .padding(.horizontal, 26)
            .padding(.vertical, 18)
            .frame(maxWidth: 440)
            .nxGlassCard(cornerRadius: 20, tint: NXTheme.primary, isNested: true)

            HStack(spacing: 14) {
                Button(action: {
                    viewModel.goBackOnboardingStep()
                }) {
                    HStack(spacing: 6) {
                        Image(systemName: "chevron.left")
                            .font(.system(size: 12, weight: .semibold))
                        Text(viewModel.tr("onboarding.back"))
                    }
                    .frame(minWidth: 110)
                }
                .buttonStyle(NXSecondaryButtonStyle())
                .nxNoFocusRing()

                Button(action: {
                    viewModel.advanceOnboardingStep()
                }) {
                    HStack(spacing: 8) {
                        Image(systemName: "arrow.down.circle.fill")
                            .font(.system(size: 14, weight: .semibold))
                        Text(viewModel.tr("onboarding.install_button"))
                    }
                    .frame(minWidth: 170)
                }
                .buttonStyle(NXPrimaryButtonStyle())
                .nxNoFocusRing()
            }
        }
    }

    // MARK: - Step 3: 0% -> 100% Liquid Glass Progress Bar

    private let coralAccent = Color(red: 1.0, green: 0.38, blue: 0.40)
    private let amberAccent = Color(red: 1.0, green: 0.74, blue: 0.26)
    private let emeraldAccent = Color(red: 0.20, green: 0.85, blue: 0.56)

    private var installingDependenciesStepView: some View {
        VStack(spacing: 22) {
            VStack(spacing: 10) {
                Image(systemName: viewModel.onboardingInstallError == nil ? "arrow.triangle.2.circlepath.circle.fill" : "exclamationmark.triangle.fill")
                    .font(.system(size: 30, weight: .semibold))
                    .foregroundStyle(
                        viewModel.onboardingInstallError == nil
                        ? AnyShapeStyle(NXTheme.primaryGradient)
                        : AnyShapeStyle(coralAccent)
                    )
                    .padding(14)
                    .nxGlassCard(
                        cornerRadius: 20,
                        tint: viewModel.onboardingInstallError == nil ? NXTheme.primary : coralAccent,
                        isNested: true
                    )

                Text(viewModel.tr("onboarding.installing_title"))
                    .font(.system(size: 25, weight: .bold, design: .rounded))
                    .foregroundColor(NXTheme.textPrimary)
                    .multilineTextAlignment(.center)
            }

            VStack(spacing: 12) {
                HStack(alignment: .firstTextBaseline) {
                    Text("\(viewModel.onboardingPercentDone)%")
                        .font(.system(size: 30, weight: .heavy, design: .rounded))
                        .foregroundColor(NXTheme.textPrimary)
                        .monospacedDigit()

                    Spacer()

                    Text(
                        viewModel.onboardingPercentDone >= 100
                        ? viewModel.tr("onboarding.progress_done_label")
                        : viewModel.tr("onboarding.progress_remaining", viewModel.onboardingPercentRemaining)
                    )
                    .font(.system(size: 13, weight: .semibold, design: .rounded))
                    .foregroundColor(NXTheme.textSecondary)
                    .monospacedDigit()
                }

                liquidGlassProgressBar(progress: viewModel.onboardingProgress)

                VStack(spacing: 4) {
                    Text(
                        viewModel.onboardingStatusMessage.isEmpty
                        ? viewModel.tr("onboarding.status_preparing")
                        : viewModel.onboardingStatusMessage
                    )
                    .font(.system(size: 13.5, weight: .medium, design: .rounded))
                    .foregroundColor(NXTheme.textPrimary)
                    .lineLimit(1)
                    .truncationMode(.middle)

                    if !viewModel.onboardingSubstatusMessage.isEmpty {
                        Text(viewModel.onboardingSubstatusMessage)
                            .font(.system(size: 11.5, weight: .regular, design: .monospaced))
                            .foregroundColor(NXTheme.textMuted)
                            .lineLimit(1)
                            .truncationMode(.middle)
                    }
                }
                .padding(.top, 2)
            }
            .padding(.horizontal, 22)
            .padding(.vertical, 20)
            .nxGlassCard(cornerRadius: 20, tint: NXTheme.primary, isNested: true)

            if viewModel.onboardingWaitingForAppleCLT {
                VStack(spacing: 10) {
                    HStack(spacing: 8) {
                        Image(systemName: "macwindow.badge.plus")
                            .foregroundColor(amberAccent)
                        Text(viewModel.tr("onboarding.clt_prompt_title"))
                            .font(.system(size: 14, weight: .bold, design: .rounded))
                            .foregroundColor(NXTheme.textPrimary)
                    }

                    Text(viewModel.tr("onboarding.clt_prompt_desc"))
                        .font(.system(size: 12.5))
                        .foregroundColor(NXTheme.textSecondary)
                        .multilineTextAlignment(.center)

                    Button(action: {
                        viewModel.reopenAppleCltInstaller()
                    }) {
                        Text(viewModel.tr("onboarding.clt_reopen_button"))
                    }
                    .buttonStyle(NXSecondaryButtonStyle())
                    .nxNoFocusRing()
                }
                .padding(16)
                .frame(maxWidth: .infinity)
                .nxGlassCard(cornerRadius: 16, tint: amberAccent, isNested: true)
            }

            if let errorMessage = viewModel.onboardingInstallError {
                VStack(spacing: 12) {
                    Text(viewModel.tr("onboarding.error_title"))
                        .font(.system(size: 14, weight: .bold, design: .rounded))
                        .foregroundColor(coralAccent)

                    Text(errorMessage)
                        .font(.system(size: 12))
                        .foregroundColor(NXTheme.textSecondary)
                        .multilineTextAlignment(.center)
                        .lineLimit(3)

                    HStack(spacing: 12) {
                        Button(action: {
                            viewModel.skipFailedOnboardingInstallToKeys()
                        }) {
                            Text(viewModel.tr("onboarding.continue_anyway"))
                        }
                        .buttonStyle(NXSecondaryButtonStyle())
                        .nxNoFocusRing()

                        Button(action: {
                            viewModel.startOnboardingInstallation()
                        }) {
                            Text(viewModel.tr("onboarding.retry_button"))
                        }
                        .buttonStyle(NXPrimaryButtonStyle())
                        .nxNoFocusRing()
                    }
                }
                .padding(16)
                .frame(maxWidth: .infinity)
                .nxGlassCard(cornerRadius: 16, tint: coralAccent, isNested: true)
            }
        }
    }

    private func liquidGlassProgressBar(progress: Double) -> some View {
        let clamped = max(0.0, min(1.0, progress))
        return GeometryReader { geo in
            let trackWidth = max(1, geo.size.width)
            let fillWidth = clamped <= 0.001 ? 0 : max(24, trackWidth * clamped)

            ZStack(alignment: .leading) {
                Capsule()
                    .fill(Color.white.opacity(0.08))
                    .overlay(
                        Capsule()
                            .strokeBorder(
                                LinearGradient(
                                    colors: [Color.white.opacity(0.28), Color.white.opacity(0.08)],
                                    startPoint: .top,
                                    endPoint: .bottom
                                ),
                                lineWidth: 1
                            )
                    )

                if fillWidth > 0 {
                    Capsule()
                        .fill(NXTheme.primaryGradient)
                        .frame(width: min(trackWidth, fillWidth))
                        .overlay(
                            Capsule()
                                .fill(
                                    LinearGradient(
                                        colors: [Color.white.opacity(0.42), Color.clear],
                                        startPoint: .top,
                                        endPoint: .bottom
                                    )
                                )
                                .padding(.vertical, 2)
                                .padding(.horizontal, 4)
                        )
                        .overlay(
                            GeometryReader { fillGeo in
                                if viewModel.onboardingIsInstalling && clamped < 1.0 {
                                    LinearGradient(
                                        colors: [.clear, Color.white.opacity(0.35), .clear],
                                        startPoint: .leading,
                                        endPoint: .trailing
                                    )
                                    .frame(width: max(48, fillGeo.size.width * 0.35))
                                    .offset(x: shimmerOffset * fillGeo.size.width)
                                }
                            }
                            .clipShape(Capsule())
                        )
                        .overlay(
                            Capsule()
                                .strokeBorder(Color.white.opacity(0.35), lineWidth: 0.8)
                        )
                        .shadow(color: NXTheme.primary.opacity(0.55), radius: 10)
                        .animation(.spring(response: 0.35, dampingFraction: 0.86), value: clamped)
                }
            }
        }
        .frame(height: 22)
    }

    // MARK: - Step 4: prod.keys Insertion + Discreet Switch 1 / Settings Notice

    private var prodKeysStepView: some View {
        VStack(spacing: 22) {
            VStack(spacing: 10) {
                Image(systemName: viewModel.isProdKeysValid ? "checkmark.seal.fill" : "key.fill")
                    .font(.system(size: 30, weight: .semibold))
                    .foregroundStyle(
                        viewModel.isProdKeysValid
                        ? AnyShapeStyle(emeraldAccent)
                        : AnyShapeStyle(NXTheme.primaryGradient)
                    )
                    .padding(14)
                    .nxGlassCard(
                        cornerRadius: 20,
                        tint: viewModel.isProdKeysValid ? emeraldAccent : NXTheme.primary,
                        isNested: true
                    )

                Text(viewModel.tr("onboarding.keys_title"))
                    .font(.system(size: 25, weight: .bold, design: .rounded))
                    .foregroundColor(NXTheme.textPrimary)
                    .multilineTextAlignment(.center)

                Text(viewModel.tr("onboarding.keys_subtitle"))
                    .font(.system(size: 14))
                    .foregroundColor(NXTheme.textSecondary)
                    .multilineTextAlignment(.center)
                    .frame(maxWidth: 480)
            }

            if viewModel.isProdKeysValid {
                VStack(spacing: 6) {
                    Text(viewModel.tr("onboarding.keys_detected_title"))
                        .font(.system(size: 16, weight: .bold, design: .rounded))
                        .foregroundColor(emeraldAccent)

                    if !viewModel.prodKeysSource.isEmpty {
                        Text(viewModel.tr("onboarding.keys_detected_source", viewModel.prodKeysSource))
                            .font(.system(size: 12.5, weight: .medium, design: .rounded))
                            .foregroundColor(NXTheme.textSecondary)
                    }
                }
                .padding(.vertical, 20)
                .padding(.horizontal, 24)
                .frame(maxWidth: .infinity)
                .nxGlassCard(cornerRadius: 20, tint: emeraldAccent, isNested: true)
            } else {
                Button(action: {
                    SoundEffectService.shared.play(.click)
                    viewModel.selectProdKeysFile()
                }) {
                    VStack(spacing: 10) {
                        Image(systemName: isKeysDropTargeted ? "arrow.down.doc.fill" : "doc.badge.plus")
                            .font(.system(size: 28, weight: .medium))
                            .foregroundColor(isKeysDropTargeted ? NXTheme.primary : NXTheme.textPrimary)

                        Text(viewModel.tr("onboarding.keys_drop_title"))
                            .font(.system(size: 15, weight: .semibold, design: .rounded))
                            .foregroundColor(NXTheme.textPrimary)

                        Text(viewModel.tr("onboarding.keys_drop_subtitle"))
                            .font(.system(size: 12.5))
                            .foregroundColor(NXTheme.textMuted)
                    }
                    .padding(.vertical, 26)
                    .padding(.horizontal, 24)
                    .frame(maxWidth: .infinity)
                    .contentShape(RoundedRectangle(cornerRadius: 20, style: .continuous))
                }
                .buttonStyle(NXPressableButtonStyle())
                .nxGlassInteractive(
                    in: RoundedRectangle(cornerRadius: 20, style: .continuous),
                    tint: NXTheme.primary,
                    isSelected: isKeysDropTargeted,
                    isFocused: false,
                    isHovered: isDropZoneHovered || isKeysDropTargeted
                )
                .overlay(
                    RoundedRectangle(cornerRadius: 20, style: .continuous)
                        .strokeBorder(
                            isKeysDropTargeted ? NXTheme.primary : Color.white.opacity(0.24),
                            style: StrokeStyle(lineWidth: 1.5, dash: [7, 6])
                        )
                )
                .nxNoFocusRing()
                .onHover { isDropZoneHovered = $0 }
                .onDrop(of: [.fileURL], isTargeted: $isKeysDropTargeted) { providers in
                    viewModel.handleOnboardingDroppedKeys(providers: providers)
                }
            }

            HStack(spacing: 14) {
                if viewModel.isProdKeysValid {
                    Button(action: {
                        SoundEffectService.shared.play(.click)
                        viewModel.selectProdKeysFile()
                    }) {
                        Text(viewModel.tr("onboarding.keys_choose_button"))
                    }
                    .buttonStyle(NXSecondaryButtonStyle())
                    .nxNoFocusRing()

                    Button(action: {
                        viewModel.completeOnboarding()
                    }) {
                        HStack(spacing: 8) {
                            Text(viewModel.tr("onboarding.keys_finish_button"))
                            Image(systemName: "arrow.right")
                                .font(.system(size: 13, weight: .bold))
                        }
                        .frame(minWidth: 170)
                    }
                    .buttonStyle(NXPrimaryButtonStyle())
                    .nxNoFocusRing()
                } else {
                    Button(action: {
                        viewModel.completeOnboarding()
                    }) {
                        Text(viewModel.tr("onboarding.keys_skip_button"))
                            .frame(minWidth: 130)
                    }
                    .buttonStyle(NXSecondaryButtonStyle())
                    .nxNoFocusRing()

                    Button(action: {
                        SoundEffectService.shared.play(.click)
                        viewModel.selectProdKeysFile()
                    }) {
                        HStack(spacing: 8) {
                            Image(systemName: "folder.badge.plus")
                                .font(.system(size: 13, weight: .semibold))
                            Text(viewModel.tr("onboarding.keys_choose_button"))
                        }
                        .frame(minWidth: 170)
                    }
                    .buttonStyle(NXPrimaryButtonStyle())
                    .nxNoFocusRing()
                }
            }

            HStack(spacing: 6) {
                Image(systemName: "info.circle")
                    .font(.system(size: 11.5))
                Text(viewModel.tr("onboarding.keys_discreet_notice"))
                    .font(.system(size: 11.5, weight: .medium, design: .rounded))
                    .multilineTextAlignment(.center)
            }
            .foregroundColor(NXTheme.textMuted.opacity(0.88))
            .padding(.top, 2)
        }
    }
}
