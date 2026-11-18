import SwiftUI

/// The Personalization drawer allowing users to customize their highlight accent color theme and application language.
public struct PersonalizationSheetView: View {
    @ObservedObject var themeManager: NXThemeManager = .shared
    public var onClose: () -> Void

    public init(onClose: @escaping () -> Void) {
        self.onClose = onClose
    }

    public var body: some View {
        GeometryReader { geometry in
            ScrollViewReader { proxy in
                ScrollView {
                    VStack(alignment: .leading, spacing: 20) {
                        // Header Bar with Close Button
                        HStack(alignment: .center) {
                            Button(action: onClose) {
                                Label(ShellStrings.text("Library"), systemImage: "chevron.left")
                            }
                            .buttonStyle(ChipButtonStyle())
                            .accessibilityLabel(ShellStrings.text("Library"))
                            .accessibilityIdentifier("personalization.back")

                            Spacer(minLength: 8)

                            Button(action: onClose) {
                                ZStack {
                                    Circle()
                                        .fill(ShellPalette.surfaceElevated.opacity(0.85))
                                        .background(Circle().fill(.ultraThinMaterial))
                                    Circle()
                                        .strokeBorder(ShellPalette.specularRim, lineWidth: 1)
                                    Image(systemName: "xmark")
                                        .font(.system(size: 13, weight: .bold))
                                        .foregroundColor(.white)
                                }
                                .frame(width: 32, height: 32)
                            }
                            .buttonStyle(.plain)
                            .accessibilityLabel(ShellStrings.text("Close"))
                            .accessibilityIdentifier("personalization.close")
                        }
                        .id("personalization.top")

                        // Title
                        Text(ShellStrings.text("Personalization"))
                            .font(.system(size: 24, weight: .black, design: .rounded))
                            .foregroundColor(.white)
                            .padding(.top, 4)

                        // MARK: - Section 1: Highlight Accent Theme
                        VStack(alignment: .leading, spacing: 14) {
                            HStack(spacing: 8) {
                                Image(systemName: "paintpalette.fill")
                                    .font(.system(size: 14, weight: .bold))
                                    .foregroundColor(themeManager.currentTheme.primaryColor)

                                Text(ShellStrings.text("Accent Theme"))
                                    .font(.system(size: 14, weight: .bold, design: .rounded))
                                    .foregroundColor(.white)

                                Spacer()

                                Text(themeManager.currentTheme.rawValue)
                                    .font(.system(size: 12, weight: .semibold, design: .rounded))
                                    .foregroundColor(themeManager.currentTheme.primaryColor)
                            }

                            // 9 Color Swatch Dots
                            let columns = [
                                GridItem(.adaptive(minimum: 40, maximum: 48), spacing: 12)
                            ]

                            LazyVGrid(columns: columns, spacing: 12) {
                                ForEach(LauncherHighlightTheme.allCases) { theme in
                                    let isSelected = themeManager.currentTheme == theme
                                    Button(action: {
                                        withAnimation(.spring(response: 0.32, dampingFraction: 0.78)) {
                                            themeManager.currentTheme = theme
                                        }
                                    }) {
                                        ZStack {
                                            // Glowing outer ring for selected dot
                                            if isSelected {
                                                Circle()
                                                    .strokeBorder(theme.primaryColor, lineWidth: 2.5)
                                                    .frame(width: 44, height: 44)
                                                    .shadow(color: theme.primaryColor.opacity(0.8), radius: 6)
                                            }

                                            // Color Dot
                                            Circle()
                                                .fill(
                                                    LinearGradient(
                                                        colors: [theme.primaryColor, theme.secondaryColor],
                                                        startPoint: .topLeading,
                                                        endPoint: .bottomTrailing
                                                    )
                                                )
                                                .frame(width: 34, height: 34)
                                                .overlay(
                                                    Circle()
                                                        .strokeBorder(Color.white.opacity(0.35), lineWidth: 1)
                                                )
                                                .shadow(color: theme.primaryColor.opacity(0.4), radius: 4, x: 0, y: 2)

                                            // White checkmark/dot inside when selected
                                            if isSelected {
                                                Image(systemName: "checkmark")
                                                    .font(.system(size: 12, weight: .heavy))
                                                    .foregroundColor(.white)
                                                    .shadow(color: .black.opacity(0.5), radius: 2)
                                            }
                                        }
                                        .frame(width: 44, height: 44)
                                    }
                                    .buttonStyle(.plain)
                                    .accessibilityLabel(theme.rawValue)
                                }
                            }
                            .padding(14)
                            .background(
                                RoundedRectangle(cornerRadius: 16)
                                    .fill(ShellPalette.surfaceElevated.opacity(0.60))
                                    .overlay(
                                        RoundedRectangle(cornerRadius: 16)
                                            .strokeBorder(ShellPalette.borderSubtle, lineWidth: 1)
                                    )
                            )
                        }
                        .padding(16)
                        .background(
                            RoundedRectangle(cornerRadius: 20)
                                .fill(ShellPalette.glassSurfaceElevated.opacity(0.70))
                                .background(RoundedRectangle(cornerRadius: 20).fill(.ultraThinMaterial))
                                .overlay(
                                    RoundedRectangle(cornerRadius: 20)
                                        .strokeBorder(ShellPalette.specularRim, lineWidth: 1)
                                )
                        )

                        // MARK: - Section 2: App Language Selection
                        VStack(alignment: .leading, spacing: 14) {
                            HStack(spacing: 8) {
                                Image(systemName: "globe")
                                    .font(.system(size: 14, weight: .bold))
                                    .foregroundColor(themeManager.currentTheme.primaryColor)

                                Text(ShellStrings.text("Language"))
                                    .font(.system(size: 14, weight: .bold, design: .rounded))
                                    .foregroundColor(.white)

                                Spacer()

                                Text(themeManager.currentLanguage.flag + " " + themeManager.currentLanguage.displayName)
                                    .font(.system(size: 12, weight: .semibold, design: .rounded))
                                    .foregroundColor(ShellPalette.textSecondary)
                            }

                            // Language items list
                            VStack(spacing: 4) {
                                ForEach(AppLanguage.sortedForDisplay) { lang in
                                    let isSelected = themeManager.currentLanguage == lang
                                    Button(action: {
                                        withAnimation(.spring(response: 0.32, dampingFraction: 0.78)) {
                                            themeManager.currentLanguage = lang
                                        }
                                    }) {
                                        HStack(spacing: 12) {
                                            Text(lang.flag)
                                                .font(.system(size: 18))

                                            VStack(alignment: .leading, spacing: 2) {
                                                Text(lang.nativeName)
                                                    .font(.system(size: 14, weight: isSelected ? .bold : .medium, design: .rounded))
                                                    .foregroundColor(isSelected ? .white : ShellPalette.textPrimary)

                                                if lang != .system && lang.displayName != lang.nativeName {
                                                    Text(lang.displayName)
                                                        .font(.system(size: 11, weight: .regular, design: .rounded))
                                                        .foregroundColor(ShellPalette.textTertiary)
                                                }
                                            }

                                            Spacer()

                                            if isSelected {
                                                Image(systemName: "checkmark.circle.fill")
                                                    .font(.system(size: 16, weight: .bold))
                                                    .foregroundColor(themeManager.currentTheme.primaryColor)
                                            }
                                        }
                                        .padding(.horizontal, 12)
                                        .padding(.vertical, 8)
                                        .background(
                                            RoundedRectangle(cornerRadius: 10)
                                                .fill(isSelected ? themeManager.currentTheme.primaryColor.opacity(0.18) : Color.clear)
                                        )
                                        .contentShape(Rectangle())
                                    }
                                    .buttonStyle(.plain)
                                }
                            }
                            .padding(8)
                            .background(
                                RoundedRectangle(cornerRadius: 16)
                                    .fill(ShellPalette.surfaceElevated.opacity(0.60))
                                    .overlay(
                                        RoundedRectangle(cornerRadius: 16)
                                            .strokeBorder(ShellPalette.borderSubtle, lineWidth: 1)
                                    )
                            )
                        }
                        .padding(16)
                        .background(
                            RoundedRectangle(cornerRadius: 20)
                                .fill(ShellPalette.glassSurfaceElevated.opacity(0.70))
                                .background(RoundedRectangle(cornerRadius: 20).fill(.ultraThinMaterial))
                                .overlay(
                                    RoundedRectangle(cornerRadius: 20)
                                        .strokeBorder(ShellPalette.specularRim, lineWidth: 1)
                                )
                        )
                    }
                    .padding(.horizontal, 20)
                    .padding(.top, 16)
                    .padding(.bottom, 40)
                }
                .scrollIndicators(.hidden)
            }
        }
    }
}
