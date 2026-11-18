import SwiftUI

// MARK: - NxN Launcher iOS Console Subcomponents (Apple Liquid Glass)

/// Ambient dynamic hero background rendering full-bleed promotional artwork with cinematic dark gradients.
public struct NXIosConsoleHeroBackground: View {
    private static let heroBlurRadius: CGFloat = 6

    public let game: GameTile
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    public init(game: GameTile) {
        self.game = game
    }

    public var body: some View {
        ZStack {
            // Base obsidian canvas
            ShellPalette.canvasObsidian.ignoresSafeArea(.all)

            // Key art / banner image
            if let artwork = game.banner ?? game.icon {
                ArtworkImage(artwork, contentMode: .fill)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .clipped()
                    .blur(radius: Self.heroBlurRadius, opaque: true)
                    .clipped()
                    .ignoresSafeArea(.all)
                    .id(game.id)
                    .transition(.opacity)
            } else {
                // Procedural ambient chromatic glow when no banner is available
                RadialGradient(
                    colors: [ShellPalette.primary.opacity(0.16), Color.clear],
                    center: .top,
                    startRadius: 60,
                    endRadius: 650
                )
                .ignoresSafeArea(.all)
            }

            // Top gradient overlay for status bar and header legibility
            LinearGradient(
                colors: [
                    Color.black.opacity(0.85),
                    Color.black.opacity(0.40),
                    Color.clear
                ],
                startPoint: .top,
                endPoint: .bottom
            )
            .frame(height: 120)
            .frame(maxHeight: .infinity, alignment: .top)
            .ignoresSafeArea(.all)

            // Bottom deep obsidian vignette for the game deck and carousel
            LinearGradient(
                colors: [
                    Color.clear,
                    Color.black.opacity(0.30),
                    Color.black.opacity(0.68),
                    Color.black.opacity(0.92)
                ],
                startPoint: .top,
                endPoint: .bottom
            )
            .frame(height: 260)
            .frame(maxHeight: .infinity, alignment: .bottom)
            .ignoresSafeArea(.all)
        }
        .ignoresSafeArea(.all)
        .animation(.easeInOut(duration: 0.35), value: game.id)
    }
}

/// Floating frosted glass navigation rail (vertical on landscape/iPad, compact horizontal bar on portrait phone).
public struct NXIosConsoleNavRail: View {
    public let activeTab: Int
    public let compact: Bool
    public let axis: Axis
    public let onSelectTab: (Int) -> Void
    public let openControllers: () -> Void
    public let openPersonalization: () -> Void
    public let openShellSettings: () -> Void
    @ObservedObject private var themeManager: NXThemeManager = .shared

    public init(
        activeTab: Int = 0,
        compact: Bool = false,
        axis: Axis = .vertical,
        onSelectTab: @escaping (Int) -> Void = { _ in },
        openControllers: @escaping () -> Void,
        openPersonalization: @escaping () -> Void,
        openShellSettings: @escaping () -> Void
    ) {
        self.activeTab = activeTab
        self.compact = compact
        self.axis = axis
        self.onSelectTab = onSelectTab
        self.openControllers = openControllers
        self.openPersonalization = openPersonalization
        self.openShellSettings = openShellSettings
    }

    public var body: some View {
        let isHorizontal = axis == .horizontal
        let corner: CGFloat = isHorizontal ? 18 : (compact ? 20 : 24)
        Group {
            if isHorizontal {
                HStack(spacing: 8) {
                    navButtons
                }
                .padding(.vertical, 6)
                .padding(.horizontal, 10)
            } else {
                VStack(spacing: compact ? 8 : 12) {
                    navButtons
                }
                .padding(.vertical, compact ? 10 : 12)
                .padding(.horizontal, compact ? 8 : 10)
            }
        }
        .background(
            RoundedRectangle(cornerRadius: corner)
                .fill(ShellPalette.glassSurfaceElevated.opacity(0.72))
                .background(RoundedRectangle(cornerRadius: corner).fill(.ultraThinMaterial))
        )
        .overlay(
            RoundedRectangle(cornerRadius: corner)
                .strokeBorder(ShellPalette.specularRim, lineWidth: 1)
        )
        .shadow(color: Color.black.opacity(0.45), radius: compact ? 10 : 16, x: 0, y: compact ? 3 : 6)
    }

    @ViewBuilder
    private var navButtons: some View {
        // 🎮 My Games / Library (Tab 0)
        railButton(id: "rail.tab.0", icon: "gamecontroller.fill", label: ShellStrings.text("My Games"), isSelected: activeTab == 0) {
            onSelectTab(0)
        }

        // 🎛️ Controllers (Tab 1)
        railButton(id: "rail.tab.1", icon: "arcade.stick.console.fill", label: ShellStrings.text("Controllers"), isSelected: activeTab == 1) {
            onSelectTab(1)
            openControllers()
        }

        // 🎨 Personalize / Themes & Language (Tab 2)
        railButton(id: "rail.tab.2", icon: "paintpalette.fill", label: ShellStrings.text("Personalize"), isSelected: activeTab == 2) {
            onSelectTab(2)
            openPersonalization()
        }

        // ⚙️ Settings (Tab 3)
        railButton(id: "rail.tab.3", icon: "gearshape.fill", label: ShellStrings.text("Settings"), isSelected: activeTab == 3) {
            onSelectTab(3)
            openShellSettings()
        }
    }

    private func railButton(id: String, icon: String, label: String, isSelected: Bool, action: @escaping () -> Void) -> some View {
        let isHorizontal = axis == .horizontal
        let btnCornerRadius: CGFloat = compact ? 12 : 14
        let size: CGFloat = isHorizontal ? 38 : (compact ? 44 : 50)
        return Button(action: action) {
            ZStack {
                RoundedRectangle(cornerRadius: btnCornerRadius)
                    .fill(Color.white.opacity(0.002))

                if isSelected {
                    RoundedRectangle(cornerRadius: btnCornerRadius)
                        .fill(ShellPalette.primaryGradient)
                        .shadow(color: ShellPalette.primary.opacity(0.55), radius: compact ? 6 : 8, x: 0, y: 2)
                }

                Image(systemName: icon)
                    .font(.system(size: isHorizontal ? 17 : (compact ? 19 : 21), weight: isSelected ? .bold : .medium))
                    .foregroundColor(isSelected ? .white : ShellPalette.textSecondary)
            }
            .frame(maxWidth: isHorizontal ? .infinity : size, minHeight: size, maxHeight: size)
            .contentShape(RoundedRectangle(cornerRadius: btnCornerRadius))
        }
        .buttonStyle(.plain)
        .accessibilityLabel(label)
        .shellTarget(id, radius: btnCornerRadius, action: action)
    }
}

/// Top status and live search header bar.
public struct NXIosConsoleTopBar: View {
    @Binding public var searchText: String
    public var compact: Bool = false
    public let onSearchChange: (String) -> Void
    @ObservedObject private var themeManager: NXThemeManager = .shared

    public init(searchText: Binding<String>, gameCount: Int = 0, compact: Bool = false, onSearchChange: @escaping (String) -> Void = { _ in }) {
        self._searchText = searchText
        self.compact = compact
        self.onSearchChange = onSearchChange
    }

    public var body: some View {
        HStack(spacing: compact ? 10 : 14) {
            // App Branding Badge (Official Dark NxN Launcher Icon)
            HStack(spacing: compact ? 6 : 8) {
                #if canImport(UIKit)
                if let icon = ShellArtworkLoader.loadAppIcon() {
                    Image(uiImage: icon)
                        .resizable()
                        .aspectRatio(contentMode: .fit)
                        .frame(width: compact ? 22 : 26, height: compact ? 22 : 26)
                        .clipShape(RoundedRectangle(cornerRadius: 6, style: .continuous))
                        .overlay(RoundedRectangle(cornerRadius: 6, style: .continuous).stroke(ShellPalette.specularRim, lineWidth: 1))
                        .shadow(color: ShellPalette.neonCyan.opacity(0.35), radius: 5)
                } else {
                    brandingFallback
                }
                #else
                brandingFallback
                #endif

                Text("NxN Launcher")
                    .font(.system(size: compact ? 14 : 16, weight: .bold, design: .rounded))
                    .foregroundColor(.white)
            }

            Spacer()

            // Search Input Pill
            HStack(spacing: 8) {
                Image(systemName: "magnifyingglass")
                    .font(.system(size: compact ? 11 : 12, weight: .semibold))
                    .foregroundColor(ShellPalette.textTertiary)

                TextField(ShellStrings.text("Search ported games..."), text: $searchText)
                    .font(.system(size: compact ? 11 : 12, weight: .medium, design: .rounded))
                    .foregroundColor(.white)
                    .frame(width: compact ? 140 : 170)
                    .onChange(of: searchText) { _, newValue in
                        onSearchChange(newValue)
                    }

                if !searchText.isEmpty {
                    Button(action: { searchText = "" }) {
                        Image(systemName: "xmark.circle.fill")
                            .font(.system(size: 11))
                            .foregroundColor(ShellPalette.textSecondary)
                    }
                    .buttonStyle(.plain)
                }
            }
            .padding(.horizontal, compact ? 10 : 12)
            .padding(.vertical, compact ? 4 : 6)
            .nxLiquidGlassPill()
        }
    }

    private var brandingFallback: some View {
        ZStack {
            RoundedRectangle(cornerRadius: 6)
                .fill(ShellPalette.logoGradient)
                .frame(width: compact ? 22 : 26, height: compact ? 22 : 26)
                .shadow(color: ShellPalette.neonCyan.opacity(0.4), radius: 5)

            Text("N")
                .font(.system(size: compact ? 13 : 15, weight: .black, design: .rounded))
                .foregroundColor(.black)
        }
    }
}

/// Metadata badge component with icon, label, and dynamic value.
public struct NXMetadataBadge: View {
    public let icon: String
    public let label: String
    public let value: String

    public init(icon: String, label: String, value: String) {
        self.icon = icon
        self.label = label
        self.value = value
    }

    public var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            HStack(spacing: 4) {
                Image(systemName: icon)
                    .font(.system(size: 9, weight: .bold))
                    .foregroundColor(ShellPalette.neonCyan)
                Text(label)
                    .font(.system(size: 9, weight: .bold, design: .rounded))
                    .foregroundColor(ShellPalette.textTertiary)
            }

            Text(value)
                .font(.system(size: 11, weight: .bold, design: .rounded))
                .foregroundColor(.white)
                .lineLimit(1)
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 6)
        .background(
            RoundedRectangle(cornerRadius: 10)
                .fill(ShellPalette.glassSurfaceElevated.opacity(0.60))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 10)
                .strokeBorder(Color.white.opacity(0.08), lineWidth: 1)
        )
    }
}

/// Selected game info deck: title, metadata badges, and player action buttons.
public struct NXIosConsoleGameDeck: View {
    public let game: GameDetail
    public let compact: Bool
    public let onPlay: () -> Void
    public let onOpenSettings: () -> Void
    @ObservedObject private var themeManager: NXThemeManager = .shared

    public init(
        game: GameDetail,
        compact: Bool = false,
        onPlay: @escaping () -> Void,
        onOpenSettings: @escaping () -> Void
    ) {
        self.game = game
        self.compact = compact
        self.onPlay = onPlay
        self.onOpenSettings = onOpenSettings
    }

    public var body: some View {
        VStack(alignment: .leading, spacing: compact ? 4 : 10) {
            // Game Title
            Text(game.game.title)
                .font(.system(size: compact ? 20 : 28, weight: .black, design: .rounded))
                .foregroundColor(.white)
                .lineLimit(1)
                .shadow(color: Color.black.opacity(0.6), radius: 6, x: 0, y: 2)

            // Metadata Badges Row
            if !compact {
                HStack(spacing: 10) {
                    NXMetadataBadge(
                        icon: "clock.fill",
                        label: ShellStrings.text("PLAYED FOR"),
                        value: game.game.recentlyPlayed ?? "0 min"
                    )

                    NXMetadataBadge(
                        icon: "internaldrive.fill",
                        label: ShellStrings.text("STORAGE"),
                        value: game.dataSource.isEmpty ? "Documents" : game.dataSource
                    )

                    NXMetadataBadge(
                        icon: "gamecontroller.fill",
                        label: ShellStrings.text("PLATFORM"),
                        value: "Nintendo Switch"
                    )

                    NXMetadataBadge(
                        icon: "bolt.fill",
                        label: ShellStrings.text("PERFORMANCE"),
                        value: ShellStrings.text("60 FPS • Handheld")
                    )
                }
            } else {
                HStack(spacing: 6) {
                    compactBadge(icon: "bolt.fill", text: "60 FPS")
                    compactBadge(icon: "internaldrive.fill", text: game.dataSource.isEmpty ? "Documents" : game.dataSource)
                    if let played = game.game.recentlyPlayed {
                        compactBadge(icon: "clock.fill", text: played)
                    }
                }
            }

            // Action Buttons Bar (Player-Focused: Play + Single Options Button)
            HStack(spacing: compact ? 8 : 12) {
                // Primary Play Button
                Button(action: onPlay) {
                    HStack(spacing: compact ? 6 : 8) {
                        Image(systemName: "play.fill")
                            .font(.system(size: compact ? 12 : 14, weight: .bold))
                        Text(ShellStrings.text("Play"))
                            .font(.system(size: compact ? 13 : 15, weight: .bold, design: .rounded))
                    }
                    .foregroundColor(.white)
                    .padding(.horizontal, compact ? 16 : 24)
                    .padding(.vertical, compact ? 6 : 10)
                    .background(
                        Capsule()
                            .fill(ShellPalette.primaryGradient)
                            .shadow(color: ShellPalette.primary.opacity(0.55), radius: compact ? 5 : 10, x: 0, y: compact ? 2 : 4)
                    )
                    .overlay(
                        Capsule()
                            .strokeBorder(Color.white.opacity(0.35), lineWidth: 1)
                    )
                }
                .buttonStyle(.plain)
                .shellTarget("deck.play", radius: 25, action: onPlay)

                // Settings / Options Glass Button (Single Unified Settings Button)
                Button(action: onOpenSettings) {
                    HStack(spacing: 5) {
                        Image(systemName: "gearshape.fill")
                            .font(.system(size: compact ? 11 : 13, weight: .bold))
                        Text(ShellStrings.text("Options"))
                            .font(.system(size: compact ? 12 : 14, weight: .semibold, design: .rounded))
                    }
                    .foregroundColor(.white)
                    .padding(.horizontal, compact ? 12 : 18)
                    .padding(.vertical, compact ? 6 : 10)
                    .background(
                        Capsule()
                            .fill(ShellPalette.glassSurfaceElevated.opacity(0.70))
                            .background(Capsule().fill(.ultraThinMaterial))
                    )
                    .overlay(
                        Capsule()
                            .strokeBorder(ShellPalette.specularRim, lineWidth: 1)
                    )
                }
                .buttonStyle(.plain)
                .shellTarget("deck.options", radius: 25, action: onOpenSettings)
            }
            .padding(.top, compact ? 1 : 2)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func compactBadge(icon: String, text: String) -> some View {
        HStack(spacing: 3.5) {
            Image(systemName: icon)
                .font(.system(size: 8, weight: .bold))
                .foregroundColor(ShellPalette.neonCyan)
            Text(text)
                .font(.system(size: 9, weight: .semibold, design: .rounded))
                .foregroundColor(.white.opacity(0.92))
                .lineLimit(1)
        }
        .padding(.horizontal, 6)
        .padding(.vertical, 3)
        .background(Capsule().fill(Color.black.opacity(0.50)))
        .overlay(Capsule().strokeBorder(ShellPalette.specularRim, lineWidth: 0.5))
    }
}

/// Horizontal game card rendered inside the shelf carousel.
public struct NXIosConsoleShelfCard: View {
    public let game: GameDetail
    public let isSelected: Bool
    public let compact: Bool
    public let customCardSize: CGFloat?
    public let onSelect: () -> Void
    @ObservedObject private var themeManager: NXThemeManager = .shared

    public init(
        game: GameDetail,
        isSelected: Bool,
        compact: Bool = false,
        cardSize: CGFloat? = nil,
        onSelect: @escaping () -> Void
    ) {
        self.game = game
        self.isSelected = isSelected
        self.compact = compact
        self.customCardSize = cardSize
        self.onSelect = onSelect
    }

    private var cardSize: CGFloat {
        if let custom = customCardSize { return custom }
        return compact ? 102 : 142
    }

    public var body: some View {
        Button(action: onSelect) {
            ZStack(alignment: .bottomLeading) {
                // Card Artwork Background
                if let artwork = game.game.icon ?? game.game.banner {
                    ArtworkImage(artwork, contentMode: .fill)
                        .frame(width: cardSize, height: cardSize)
                        .clipped()
                } else {
                    Rectangle()
                        .fill(ShellPalette.glassSurfaceElevated)
                        .overlay(
                            Text(game.game.title)
                                .font(.system(size: compact ? 11 : 13, weight: .bold, design: .rounded))
                                .foregroundColor(.white)
                                .padding(compact ? 6 : 8)
                        )
                }

                // Dark vignette over card bottom
                LinearGradient(
                    colors: [Color.clear, Color.black.opacity(0.78)],
                    startPoint: .center,
                    endPoint: .bottom
                )

                // Top Badge (e.g. "Playing" or time badge)
                if isSelected {
                    VStack {
                        HStack {
                            Spacer()
                            Text(ShellStrings.text("Playing"))
                                .font(.system(size: compact ? 8.5 : 9.5, weight: .bold, design: .rounded))
                                .foregroundColor(.white)
                                .padding(.horizontal, compact ? 7 : 9)
                                .padding(.vertical, compact ? 2.5 : 3.5)
                                .background(
                                    Capsule()
                                        .fill(Color.black.opacity(0.80))
                                        .overlay(Capsule().strokeBorder(ShellPalette.neonCyan, lineWidth: 1.2))
                                )
                                .padding(compact ? 5 : 8)
                        }
                        Spacer()
                    }
                }

                // Bottom platform badges
                HStack(spacing: compact ? 4 : 6) {
                    Image(systemName: "applelogo")
                        .font(.system(size: compact ? 8 : 10, weight: .bold))
                        .foregroundColor(.white.opacity(0.90))

                    Image(systemName: "iphone")
                        .font(.system(size: compact ? 8 : 10, weight: .bold))
                        .foregroundColor(.white.opacity(0.90))

                    if game.cloudSaves != nil {
                        Image(systemName: "icloud.fill")
                            .font(.system(size: compact ? 8 : 10, weight: .bold))
                            .foregroundColor(ShellPalette.neonCyan)
                    }

                    Spacer()
                }
                .padding(compact ? 5 : 8)
            }
            .frame(width: cardSize, height: cardSize)
            .cornerRadius(compact ? 14 : 20)
            .overlay(
                RoundedRectangle(cornerRadius: compact ? 14 : 20)
                    .strokeBorder(
                        isSelected ? Color.white.opacity(0.95) : ShellPalette.borderSubtle,
                        lineWidth: isSelected ? (compact ? 2.5 : 3.0) : 1
                    )
            )
            .shadow(
                color: isSelected ? ShellPalette.primary.opacity(0.65) : Color.black.opacity(0.40),
                radius: isSelected ? (compact ? 10 : 16) : (compact ? 4 : 8),
                x: 0,
                y: isSelected ? (compact ? 3 : 5) : 2
            )
            .animation(.spring(response: 0.32, dampingFraction: 0.75), value: isSelected)
        }
        .buttonStyle(.plain)
        .shellTarget("lib.tile.\(game.id)", radius: compact ? 14 : 20, action: onSelect)
    }
}

/// Bottom footer control rail showing controller badges and navigation hints.
public struct NXIosConsoleFooterRail: View {
    public let controllersCount: Int
    public let compact: Bool
    @ObservedObject private var themeManager: NXThemeManager = .shared

    public init(controllersCount: Int = 0, compact: Bool = false) {
        self.controllersCount = controllersCount
        self.compact = compact
    }

    public var body: some View {
        HStack {
            // Left Controller Pill
            HStack(spacing: compact ? 3 : 6) {
                Image(systemName: controllersCount > 0 ? "gamecontroller.fill" : "keyboard")
                    .font(.system(size: compact ? 8 : 11, weight: .bold))
                Text(ShellStrings.text(controllersCount > 0 ? "Gamepad" : "Touch / Keyboard"))
                    .font(.system(size: compact ? 8 : 11, weight: .medium, design: .rounded))
            }
            .foregroundColor(ShellPalette.textSecondary)
            .padding(.horizontal, compact ? 6 : 10)
            .padding(.vertical, compact ? 2 : 5)
            .nxLiquidGlassPill()

            Spacer()

            // Right Gamepad & Keyboard Hints
            HStack(spacing: compact ? 6 : 12) {
                hintBadge(key: "← / →", label: ShellStrings.text("Browse"))
                hintBadge(key: "↵ / Ⓐ", label: ShellStrings.text("Play"))
                hintBadge(key: "Ⓞ / Ⓧ", label: ShellStrings.text("Options"))
                if !compact {
                    hintBadge(key: "⚙", label: ShellStrings.text("Settings"))
                }
            }
        }
    }

    private func hintBadge(key: String, label: String) -> some View {
        HStack(spacing: compact ? 2 : 4) {
            Text(key)
                .font(.system(size: compact ? 7.5 : 10, weight: .bold, design: .monospaced))
                .foregroundColor(ShellPalette.neonCyan)
                .padding(.horizontal, compact ? 3 : 5)
                .padding(.vertical, compact ? 1 : 2)
                .background(Color.white.opacity(0.12))
                .cornerRadius(3)

            Text(label)
                .font(.system(size: compact ? 7.5 : 10, weight: .medium, design: .rounded))
                .foregroundColor(ShellPalette.textSecondary)
        }
    }
}
