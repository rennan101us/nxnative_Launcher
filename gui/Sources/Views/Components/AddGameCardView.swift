import SwiftUI
import UniformTypeIdentifiers
import AppKit

public struct AddGameCardView: View {
    @ObservedObject public var viewModel: AppViewModel
    public let baseSize: CGFloat
    public let isFocused: Bool
    @State private var isTargeted: Bool = false
    @State private var isHovered: Bool = false

    public init(viewModel: AppViewModel, baseSize: CGFloat = 170, isFocused: Bool = false) {
        self.viewModel = viewModel
        self.baseSize = baseSize
        self.isFocused = isFocused
    }

    private var borderStrokeStyle: AnyShapeStyle {
        if isTargeted {
            return AnyShapeStyle(NXTheme.secondary)
        } else if isFocused || isHovered {
            return AnyShapeStyle(NXTheme.primary.opacity(0.92))
        } else {
            return AnyShapeStyle(NXTheme.specularRim)
        }
    }
    
    public var body: some View {
        Button(action: {
            SoundEffectService.shared.play(.click)
            openFileOrFolderPicker()
        }) {
            ZStack {
                RoundedRectangle(cornerRadius: 14, style: .continuous)
                    .fill(isTargeted ? NXTheme.primary.opacity(0.16) : (isHovered ? Color.white.opacity(0.05) : Color.white.opacity(0.02)))
                
                VStack(spacing: 8) {
                    ZStack {
                        Circle()
                            .fill(NXTheme.primary.opacity(isTargeted || isHovered ? 0.25 : 0.12))
                            .frame(width: 44, height: 44)
                        
                        Image(systemName: isTargeted ? "arrow.down.doc.fill" : "plus")
                            .font(.system(size: 20, weight: .bold))
                            .foregroundColor(isTargeted ? NXTheme.secondary : (isHovered ? NXTheme.primary : NXTheme.textSecondary))
                    }
                    
                    Text(viewModel.tr("library.add_game_card"))
                        .font(.system(size: 11, weight: .semibold, design: .rounded))
                        .foregroundColor(isHovered ? NXTheme.textPrimary : NXTheme.textSecondary)
                        .multilineTextAlignment(.center)
                        .lineLimit(2)
                        .padding(.horizontal, 8)
                    
                    Text("NSP, NSZ, NZS, XCI, XCZ, NUP, APP")
                        .font(.system(size: 8.5, weight: .bold, design: .monospaced))
                        .foregroundColor(isHovered ? NXTheme.textSecondary : NXTheme.textMuted.opacity(0.80))
                        .lineLimit(1)
                        .minimumScaleFactor(0.8)
                        .padding(.horizontal, 6)
                }
            }
            .frame(width: baseSize, height: baseSize)
            .overlay(
                RoundedRectangle(cornerRadius: 14, style: .continuous)
                    .strokeBorder(
                        borderStrokeStyle,
                        style: StrokeStyle(lineWidth: (isTargeted || isFocused) ? 2.2 : 1.4, dash: isFocused ? [] : [6])
                    )
            )
            .nxConsoleFocusRing(in: RoundedRectangle(cornerRadius: 14, style: .continuous), isFocused: isFocused)
            .scaleEffect(isFocused ? 1.05 : 1.0)
            .opacity(isFocused ? 1.0 : 0.90)
            .animation(.spring(response: 0.28, dampingFraction: 0.78), value: isHovered)
            .animation(.spring(response: 0.24, dampingFraction: 0.80), value: isTargeted)
            .animation(.spring(response: 0.24, dampingFraction: 0.80), value: isFocused)
        }
        .buttonStyle(PlainButtonStyle())
        .nxNoFocusRing()
        .onHover { hovering in
            self.isHovered = hovering
        }
        .onDrop(of: AppViewModel.acceptedDropTypes, isTargeted: $isTargeted) { providers in
            AppViewModel.extractURLs(from: providers) { urls in
                if !urls.isEmpty {
                    SoundEffectService.shared.play(.click)
                    viewModel.handleDroppedURLs(urls, openPortModalForSingleGame: true)
                }
            }
            return true
        }
    }
    
    private func openFileOrFolderPicker() {
        viewModel.openUnifiedGamePicker()
    }
}
