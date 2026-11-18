import SwiftUI
import AppKit

public struct LibraryFilterSortBarView: View {
    @ObservedObject public var viewModel: AppViewModel
    
    public init(viewModel: AppViewModel) {
        self.viewModel = viewModel
    }
    
    public var body: some View {
        HStack(spacing: 12) {
            // Left: Unified Games Count Badge
            let totalGames = viewModel.unifiedItems(for: viewModel.libraryGames).count
            HStack(spacing: 6) {
                Image(systemName: "gamecontroller.fill")
                    .font(.system(size: 11, weight: .bold))
                    .foregroundColor(NXTheme.primary)
                Text("\(totalGames) \(totalGames == 1 ? viewModel.tr("common.game") : viewModel.tr("common.games"))")
                    .font(.system(size: 12, weight: .bold, design: .rounded))
                    .foregroundColor(NXTheme.textPrimary)
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 5)
            .nxGlassBar(
                in: Capsule(),
                fallbackFill: NXTheme.glassSurfaceElevated.opacity(0.70),
                fallbackStroke: NXTheme.borderSubtle
            )
            .fixedSize()
            
            Spacer(minLength: 12)
            
            // Search Field Capsule (positioned on the right next to filters)
            NXLiquidGlassSearchField(
                viewModel.tr("library.search_placeholder"),
                text: $viewModel.librarySearchText
            )
            .padding(.horizontal, 10)
            .padding(.vertical, 4)
            .frame(maxWidth: 220)
            .nxGlassBar(
                in: Capsule(),
                fallbackFill: NXTheme.glassSurfaceElevated.opacity(0.85),
                fallbackStroke: NXTheme.borderSubtle
            )
            
            // View Mode Toggle (Shelves vs Grid)
            Button {
                SoundEffectService.shared.play(.click)
                withAnimation(.spring(response: 0.28, dampingFraction: 0.8)) {
                    if viewModel.activeGroupFilter == .all {
                        viewModel.activeGroupFilter = .categories
                    } else {
                        viewModel.activeGroupFilter = .all
                    }
                    viewModel.reconcileLibraryFocusState()
                }
            } label: {
                HStack(spacing: 4) {
                    Image(systemName: viewModel.activeGroupFilter == .all ? "rectangle.stack.fill" : "square.grid.2x2.fill")
                        .font(.system(size: 11, weight: .bold))
                        .foregroundColor(NXTheme.primary)
                }
                .padding(.horizontal, 7)
                .frame(height: 26)
                .nxGlassBar(
                    in: RoundedRectangle(cornerRadius: 7, style: .continuous),
                    fallbackFill: NXTheme.glassSurfaceElevated.opacity(0.70),
                    fallbackStroke: NXTheme.borderSubtle
                )
            }
            .buttonStyle(PlainButtonStyle())
            .fixedSize()
            .nxNoFocusRing()
            .help(viewModel.tr(viewModel.activeGroupFilter == .all ? "library.view_shelves" : "library.view_grid"))
            
            // Sort Option Menu
            Menu {
                ForEach(LibrarySortOption.allCases) { option in
                    Button {
                        SoundEffectService.shared.play(.click)
                        viewModel.activeSortOption = option
                        viewModel.reconcileLibraryFocusState()
                    } label: {
                        HStack {
                            Image(systemName: option.iconName)
                            Text(viewModel.tr(option.translationKey))
                            if viewModel.activeSortOption == option {
                                Image(systemName: "checkmark")
                            }
                        }
                    }
                }
            } label: {
                HStack(spacing: 4) {
                    Image(systemName: viewModel.activeSortOption.iconName)
                        .font(.system(size: 11, weight: .bold))
                        .foregroundColor(NXTheme.secondary)
                    
                    Image(systemName: "chevron.down")
                        .font(.system(size: 7, weight: .bold))
                        .foregroundColor(NXTheme.textSecondary.opacity(0.85))
                }
                .padding(.horizontal, 7)
                .frame(height: 26)
                .nxGlassBar(
                    in: RoundedRectangle(cornerRadius: 7, style: .continuous),
                    fallbackFill: NXTheme.glassSurfaceElevated.opacity(0.70),
                    fallbackStroke: NXTheme.borderSubtle
                )
            }
            .menuStyle(.borderlessButton)
            .menuIndicator(.hidden)
            .fixedSize()
            .nxNoFocusRing()
            .help(viewModel.tr("library.tooltip_sort", viewModel.tr(viewModel.activeSortOption.translationKey)))
            
            // Rescan / Refresh Library Button
            Button {
                SoundEffectService.shared.play(.click)
                viewModel.scanAllGameFolders()
                viewModel.refreshLibrary()
            } label: {
                HStack(spacing: 4) {
                    Image(systemName: "arrow.clockwise")
                        .font(.system(size: 11, weight: .bold))
                        .foregroundColor(NXTheme.textPrimary)
                }
                .padding(.horizontal, 7)
                .frame(height: 26)
                .nxGlassBar(
                    in: RoundedRectangle(cornerRadius: 7, style: .continuous),
                    fallbackFill: NXTheme.glassSurfaceElevated.opacity(0.70),
                    fallbackStroke: NXTheme.borderSubtle
                )
            }
            .buttonStyle(PlainButtonStyle())
            .fixedSize()
            .nxNoFocusRing()
            .help(viewModel.tr("library.rescan_tooltip"))
        }
        .padding(.horizontal, 34)
        .padding(.top, 2)
        .padding(.bottom, 2)
    }
}
