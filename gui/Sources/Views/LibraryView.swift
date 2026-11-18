import SwiftUI
import AppKit

public struct LibraryView: View {
    @ObservedObject public var viewModel: AppViewModel
    @ObservedObject private var controllerService = GameControllerService.shared
    public var containerHeight: CGFloat
    @State private var isLibraryDropTargeted: Bool = false

    public init(viewModel: AppViewModel, containerHeight: CGFloat = 720) {
        self.viewModel = viewModel
        self.containerHeight = containerHeight
    }
    
    private var filteredGames: [PortedGame] {
        if viewModel.librarySearchText.trimmingCharacters(in: .whitespaces).isEmpty {
            return viewModel.libraryGames
        }
        return viewModel.libraryGames.filter {
            $0.name.localizedCaseInsensitiveContains(viewModel.librarySearchText)
        }
    }
    
    private var currentSelectedGame: PortedGame? {
        viewModel.currentFocusedGame
    }
    
    public var body: some View {
        let isLibraryEmptyAfterScan = !viewModel.isScanningLibrary && viewModel.libraryGames.isEmpty && viewModel.unportedGames.isEmpty

        ZStack {
            SwitchConsoleLibraryView(
                viewModel: viewModel,
                games: filteredGames,
                containerHeight: containerHeight
            )
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .opacity(isLibraryEmptyAfterScan ? 0 : 1)
            .allowsHitTesting(!isLibraryEmptyAfterScan)

            if isLibraryEmptyAfterScan {
                LibraryEmptyDropView(viewModel: viewModel)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
            
            // Compact Console Action Sheet (Overlay when Game Selected)
            if viewModel.isGameActionMenuPresented, let selected = currentSelectedGame {
                CompactConsoleActionSheetView(
                    game: selected,
                    viewModel: viewModel,
                    onHideFromLibrary: { target in
                        viewModel.confirmDialogFocusIndex = 1
                        viewModel.gameToHide = target
                        viewModel.showHideConfirm = true
                    },
                    onRemoveFromLibrary: { target in
                        viewModel.confirmDialogFocusIndex = 1
                        viewModel.gameToRemove = target
                        viewModel.showRemoveConfirm = true
                    },
                    onDeleteToTrash: { target in
                        viewModel.confirmDialogFocusIndex = 1
                        viewModel.gameToTrash = target
                        viewModel.showTrashConfirm = true
                    },
                    onDelete: { target in
                        viewModel.confirmDialogFocusIndex = 1
                        viewModel.gameToTrash = target
                        viewModel.showTrashConfirm = true
                    },
                    onDismiss: {
                        withAnimation(.easeInOut(duration: 0.18)) {
                            viewModel.isGameActionMenuPresented = false
                        }
                    }
                )
                .transition(.opacity.combined(with: .scale(scale: 0.96)))
                .zIndex(100)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .onDrop(of: AppViewModel.acceptedDropTypes, isTargeted: $isLibraryDropTargeted) { providers in
            AppViewModel.extractURLs(from: providers) { urls in
                if !urls.isEmpty {
                    SoundEffectService.shared.play(.click)
                    viewModel.handleDroppedURLs(urls, openPortModalForSingleGame: false)
                }
            }
            return true
        }
        .onAppear {
            if !viewModel.gameFolders.isEmpty && !viewModel.isBuilding {
                viewModel.scanAllGameFolders()
            }
            viewModel.reconcileLibraryFocusState()
        }
        .animation(.easeInOut(duration: 0.2), value: viewModel.isGameActionMenuPresented)
        .sheet(item: $viewModel.gameForSettingsSheet) { game in
            GameSettingsSheetView(viewModel: viewModel, game: game)
                .environment(\.nxLiquidGlass, viewModel.liquidGlassEnvironment)
        }
        .sheet(item: $viewModel.gameForPortModal) { game in
            PortGameModalView(game: game, viewModel: viewModel)
                .environment(\.nxLiquidGlass, viewModel.liquidGlassEnvironment)
        }
    }
}
