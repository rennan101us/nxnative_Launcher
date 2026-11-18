import SwiftUI
import AppKit

public struct SwitchConsoleLibraryView: View {
    @ObservedObject public var viewModel: AppViewModel
    public let games: [PortedGame]
    public let containerHeight: CGFloat
    @State internal var scrollWheelMonitor: Any? = nil
    @State private var hoveredTargetGamePath: String? = nil

    public init(viewModel: AppViewModel, games: [PortedGame], containerHeight: CGFloat = 720) {
        self.viewModel = viewModel
        self.games = games
        self.containerHeight = containerHeight
    }

    private var macGames: [PortedGame] {
        games.filter { $0.platform == .macApp && !$0.isSwitch2 }
    }

    private var switch2Games: [PortedGame] {
        games.filter { $0.isSwitch2 }
    }

    private var switch1And2Games: [PortedGame] {
        games.filter { $0.platform == .macApp || $0.platform == .nonSwitch }
    }

    private var iosGames: [PortedGame] {
        games.filter { $0.platform == .ios }
    }

    private var nonSwitchGames: [PortedGame] {
        games.filter { $0.platform == .nonSwitch }
    }

    internal var sortedUnportedGames: [SelectableGame] {
        var list = viewModel.unportedGames
        if viewModel.activeGroupFilter == .switch2 {
            list = list.filter { $0.isSwitch2 || $0.isNup }
        }
        let query = viewModel.librarySearchText.trimmingCharacters(in: .whitespacesAndNewlines)
        if !query.isEmpty {
            list = list.filter {
                $0.name.localizedCaseInsensitiveContains(query) ||
                ($0.titleId?.localizedCaseInsensitiveContains(query) == true)
            }
        }
        return list
    }

    private var currentTargetGameItem: (PortedGame?, SelectableGame?) {
        let items = viewModel.unifiedItems(for: games)
        if items.indices.contains(viewModel.focusedUnifiedIndex) {
            switch items[viewModel.focusedUnifiedIndex] {
            case .ported(let g): return (g, nil)
            case .unported(let u): return (nil, u)
            }
        } else if let first = items.first {
            switch first {
            case .ported(let g): return (g, nil)
            case .unported(let u): return (nil, u)
            }
        }
        if let g = viewModel.currentFocusedGame { return (g, nil) }
        if let u = viewModel.focusedUnportedGame ?? sortedUnportedGames.first { return (nil, u) }
        return (nil, nil)
    }

    public var body: some View {
        let (targetGame, targetUnported) = currentTargetGameItem

        VStack(alignment: .leading, spacing: 14) {
            Spacer(minLength: 0)

            // MARK: - Game Info Deck (Title, Hour, Storage, Platform, Performance, Play, Port, Settings)
            if targetGame != nil || targetUnported != nil {
                ConsoleGameDetailView(
                    game: targetGame,
                    unportedGame: targetUnported,
                    viewModel: viewModel
                )
                .padding(.horizontal, 36)
                .transition(.opacity)
                .id(targetGame?.stableId ?? targetUnported?.id ?? "hero_empty")
            }

            // MARK: - Games Gallery Carousel (Directly below the Info Deck, on top of bottom bar)
            UnifiedConsoleGridView(viewModel: viewModel, games: games)
                .padding(.bottom, 6)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottomLeading)
        .onAppear {
            installScrollWheelForwarder()
        }
        .onDisappear {
            removeScrollWheelForwarder()
        }
    }
}
