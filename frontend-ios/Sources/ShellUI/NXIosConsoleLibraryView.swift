import SwiftUI

// MARK: - NxN Launcher iOS Flagship Console Hub View (Apple Liquid Glass)

/// The primary console library interface on iOS/iPadOS featuring the exact "My Games" tab console layout:
/// - Dynamic promotional hero background with atmospheric vignette
/// - Left floating frosted glass navigation rail with console glyphs (My Games, Controllers, Personalize, Settings)
/// - Selected game context deck with metadata badges and player-focused action buttons (Play, Options)
/// - Bottom horizontal game cards carousel with specular border highlights and "Playing" badge
public struct NXIosConsoleLibraryView: View {
    public let games: [GameDetail]
    public let selected: GameDetail
    public let controllersCount: Int
    public let showsHints: Bool
    public var screenInsets: EdgeInsets = EdgeInsets()
    public var windowSize: CGSize? = nil
    public let select: (String) -> Void
    public let primary: (GameDetail) -> Void
    public let openSettings: () -> Void
    public let openControllers: () -> Void
    public let openPersonalization: () -> Void
    public let openShellSettings: () -> Void

    @State private var searchText: String = ""
    @State private var activeNavTab: Int = 0
    @ObservedObject private var themeManager: NXThemeManager = .shared

    public init(
        games: [GameDetail],
        selected: GameDetail,
        controllersCount: Int = 0,
        showsHints: Bool = true,
        screenInsets: EdgeInsets = EdgeInsets(),
        windowSize: CGSize? = nil,
        select: @escaping (String) -> Void,
        primary: @escaping (GameDetail) -> Void,
        openSettings: @escaping () -> Void,
        openControllers: @escaping () -> Void,
        openPersonalization: @escaping () -> Void,
        openShellSettings: @escaping () -> Void
    ) {
        self.games = games
        self.selected = selected
        self.controllersCount = controllersCount
        self.showsHints = showsHints
        self.screenInsets = screenInsets
        self.windowSize = windowSize
        self.select = select
        self.primary = primary
        self.openSettings = openSettings
        self.openControllers = openControllers
        self.openPersonalization = openPersonalization
        self.openShellSettings = openShellSettings
    }

    private var filteredGames: [GameDetail] {
        let query = searchText.trimmingCharacters(in: .whitespacesAndNewlines)
        if query.isEmpty { return games }
        return games.filter {
            $0.game.title.localizedCaseInsensitiveContains(query) ||
            $0.id.localizedCaseInsensitiveContains(query)
        }
    }

    public var body: some View {
        GeometryReader { geometry in
            let size = windowSize ?? geometry.size
            let availableWidth = max(1, size.width)
            let availableHeight = max(1, size.height)
            let isLandscape = availableWidth > availableHeight
            let isCompact = isLandscape && (availableHeight + screenInsets.top + screenInsets.bottom) < 560
            let isCompactPortrait = !isLandscape && availableWidth < 600

            // Left Navigation Rail metrics (inside safe area bounds)
            let railWidth: CGFloat = isCompact ? 60 : 70
            let railLeadingPadding: CGFloat = isCompact ? 10 : 20
            let railTrailingPadding: CGFloat = isCompact ? 12 : 16
            let railTotalLeadingSpace = !isCompactPortrait
                ? (railLeadingPadding + railWidth + railTrailingPadding)
                : 12

            // Safe-area relative insets
            let bottomPadding: CGFloat = isCompact ? 6 : 12
            let trailingPadding: CGFloat = (isCompact || isCompactPortrait) ? 12 : 24
            let shelfAvailableWidth = max(200, availableWidth - railTotalLeadingSpace - trailingPadding)
            let compactDeck = isCompact || isCompactPortrait

            // Dynamic Card Sizing: scales proportionally to available height
            let baseCardHeight: CGFloat = compactDeck ? 106 : 144
            let cardSize: CGFloat = min(baseCardHeight, max(92, availableHeight * (compactDeck ? 0.27 : 0.24)))
            let shelfHeight: CGFloat = cardSize + (compactDeck ? 8 : 12)

            ZStack(alignment: .topLeading) {
                // MARK: - Layer 1: Floating Navigation Rail (Vertical Left, or Horizontal Top Strip on Compact Portrait)
                if !isCompactPortrait {
                    VStack {
                        Spacer(minLength: 0)
                        NXIosConsoleNavRail(
                            activeTab: activeNavTab,
                            compact: isCompact,
                            onSelectTab: { tab in
                                activeNavTab = tab
                            },
                            openControllers: {
                                activeNavTab = 1
                                openControllers()
                            },
                            openPersonalization: {
                                activeNavTab = 2
                                openPersonalization()
                            },
                            openShellSettings: {
                                activeNavTab = 3
                                openShellSettings()
                            }
                        )
                        Spacer(minLength: 0)
                    }
                    .frame(width: railWidth)
                    .padding(.leading, railLeadingPadding)
                    .frame(maxHeight: availableHeight, alignment: .leading)
                }

                // MARK: - Layer 2: Top Status, Search Bar, and Compact Portrait Nav Strip
                if !isCompact {
                    VStack(alignment: .leading, spacing: 8) {
                        NXIosConsoleTopBar(
                            searchText: $searchText,
                            compact: isCompactPortrait,
                            onSearchChange: { _ in }
                        )

                        if isCompactPortrait {
                            NXIosConsoleNavRail(
                                activeTab: activeNavTab,
                                compact: true,
                                axis: .horizontal,
                                onSelectTab: { tab in
                                    activeNavTab = tab
                                },
                                openControllers: {
                                    activeNavTab = 1
                                    openControllers()
                                },
                                openPersonalization: {
                                    activeNavTab = 2
                                    openPersonalization()
                                },
                                openShellSettings: {
                                    activeNavTab = 3
                                    openShellSettings()
                                }
                            )
                        }
                    }
                    .padding(.top, 10)
                    .padding(.trailing, trailingPadding)
                    .padding(.leading, railTotalLeadingSpace)
                    .frame(width: availableWidth, alignment: .topLeading)
                }

                // MARK: - Layer 3: Fixed Bottom Console Dock (GUARANTEED BOTTOM ANCHORING)
                // Pinned directly to .bottomLeading of the safe-area viewport so it CAN NEVER appear at the top.
                VStack(alignment: .leading, spacing: compactDeck ? 6 : 10) {
                    // Selected Game Context Deck (Title, Badges, Action Buttons)
                    NXIosConsoleGameDeck(
                        game: selected,
                        compact: compactDeck,
                        onPlay: { primary(selected) },
                        onOpenSettings: openSettings
                    )

                    // Horizontal Game Cards Carousel Shelf
                    shelfView(compact: compactDeck, cardSize: cardSize, availableWidth: shelfAvailableWidth)
                        .frame(height: shelfHeight)
                }
                .padding(.leading, railTotalLeadingSpace)
                .padding(.trailing, trailingPadding)
                .padding(.bottom, bottomPadding)
                .frame(width: availableWidth, height: availableHeight, alignment: .bottomLeading)
            }
            .frame(width: availableWidth, height: availableHeight)
            .clipped()
        }
    }

    @ViewBuilder
    private func shelfView(compact: Bool, cardSize: CGFloat, availableWidth: CGFloat) -> some View {
        ScrollViewReader { shelfProxy in
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: compact ? 12 : 16) {
                    ForEach(filteredGames) { item in
                        let isCurrent = item.id == selected.id
                        NXIosConsoleShelfCard(
                            game: item,
                            isSelected: isCurrent,
                            compact: compact,
                            cardSize: cardSize,
                            onSelect: {
                                select(item.id)
                            }
                        )
                        .id("shelf.\(item.id)")
                    }
                }
                .padding(.horizontal, 4)
                .padding(.vertical, compact ? 2 : 4)
            }
            .frame(width: availableWidth, alignment: .leading)
            .clipped()
            .onChange(of: selected.id) { _, newId in
                if filteredGames.count > 3 {
                    withAnimation(.spring(response: 0.35, dampingFraction: 0.8)) {
                        shelfProxy.scrollTo("shelf.\(newId)", anchor: .center)
                    }
                }
            }
        }
    }
}
