import SwiftUI
import AppKit

public struct UnifiedConsoleGridView: View {
    @ObservedObject public var viewModel: AppViewModel
    public let games: [PortedGame]
    @State private var hoveredTargetPath: String? = nil

    public init(viewModel: AppViewModel, games: [PortedGame]) {
        self.viewModel = viewModel
        self.games = games
    }

    private var items: [UnifiedLibraryItem] {
        viewModel.unifiedItems(for: games)
    }

    public var body: some View {
        let baseCardSize: CGFloat = 144 * CGFloat(viewModel.libraryCardScale)
        let cardSpacing: CGFloat = max(20, baseCardSize * 0.13)
        let verticalPadding: CGFloat = max(18, baseCardSize * 0.12)
        let carouselHeight: CGFloat = (baseCardSize * 1.16) + (verticalPadding * 2) + 16

        ScrollViewReader { horizontalProxy in
            ScrollView(.horizontal, showsIndicators: false) {
                LazyHStack(alignment: .center, spacing: cardSpacing) {
                    ForEach(Array(items.enumerated()), id: \.element.stableId) { idx, item in
                        let isFocused = viewModel.focusedUnifiedIndex == idx

                        switch item {
                        case .ported(let game):
                            let isDropTarget = hoveredTargetPath == game.url.standardized.path &&
                                               viewModel.draggedGame != nil &&
                                               viewModel.draggedGame?.url.standardized.path != game.url.standardized.path

                            SquareGameCardView(
                                game: game,
                                viewModel: viewModel,
                                isFocused: isFocused,
                                isDropTarget: isDropTarget,
                                baseSize: baseCardSize,
                                onSelect: {
                                    guard !viewModel.isAnyModalPresented else { return }
                                    viewModel.draggedGame = nil
                                    hoveredTargetPath = nil
                                    let targetPath = game.url.standardizedFileURL.path
                                    let wasAlreadySelectedAndSynced =
                                        isFocused &&
                                        viewModel.activeLibraryShelf != .unportedSwitch &&
                                        viewModel.currentFocusedGame?.url.standardizedFileURL.path == targetPath
                                    viewModel.selectUnifiedItem(at: idx, items: items, playSound: !wasAlreadySelectedAndSynced)
                                    if wasAlreadySelectedAndSynced {
                                        if game.isPlayableLocally {
                                            viewModel.launchGame(game)
                                        } else {
                                            SoundEffectService.shared.play(.click)
                                            viewModel.gameForSettingsSheet = game
                                        }
                                    }
                                }
                            )
                            .zIndex(isFocused ? 10 : (isDropTarget ? 8 : 1))
                            .id(item.stableId)
                            .onDrag {
                                viewModel.draggedGame = game
                                return NSItemProvider(object: game.url.standardized.path as NSString)
                            }
                            .onDrop(of: [.text, .plainText], delegate: GameReorderDropDelegate(
                                target: game,
                                viewModel: viewModel,
                                hoveredTargetGamePath: $hoveredTargetPath,
                                move: { dragged, target in
                                    viewModel.moveUnifiedItem(
                                        fromPath: dragged.url.standardized.path,
                                        onto: target.url.standardized.path,
                                        items: items
                                    )
                                }
                            ))

                        case .unported(let unported):
                            UnportedGameCardView(
                                game: unported,
                                viewModel: viewModel,
                                isFocused: isFocused,
                                baseSize: baseCardSize,
                                onSelect: {
                                    guard !viewModel.isAnyModalPresented else { return }
                                    viewModel.draggedGame = nil
                                    hoveredTargetPath = nil
                                    let wasAlreadySelectedAndSynced =
                                        isFocused &&
                                        viewModel.activeLibraryShelf == .unportedSwitch &&
                                        viewModel.focusedUnportedGame?.id == unported.id
                                    viewModel.selectUnifiedItem(at: idx, items: items, playSound: !wasAlreadySelectedAndSynced)
                                    if wasAlreadySelectedAndSynced {
                                        SoundEffectService.shared.play(.click)
                                        viewModel.selectedGame = unported
                                        viewModel.gameForPortModal = unported
                                    }
                                }
                            )
                            .zIndex(isFocused ? 10 : 1)
                            .id(item.stableId)
                        }
                    }

                    AddGameCardView(
                        viewModel: viewModel,
                        baseSize: baseCardSize,
                        isFocused: viewModel.focusZone == .content && !viewModel.isFocusOnHeroBar && viewModel.focusedUnifiedIndex == items.count
                    )
                        .id("unified_card_add")
                        .zIndex(viewModel.focusedUnifiedIndex == items.count ? 10 : 1)
                }
                .padding(.horizontal, 36)
                .padding(.vertical, verticalPadding)
            }
            .frame(height: carouselHeight)
            .onChange(of: viewModel.focusedUnifiedIndex) { newIdx in
                let targetId: String? = items.indices.contains(newIdx)
                    ? items[newIdx].stableId
                    : (newIdx == items.count ? "unified_card_add" : nil)
                guard let scrollId = targetId else { return }
                withAnimation(.easeOut(duration: 0.18)) {
                    let anchor: UnitPoint = newIdx == 0 ? .leading : (newIdx >= items.count - 1 ? .trailing : .center)
                    horizontalProxy.scrollTo(scrollId, anchor: anchor)
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}
