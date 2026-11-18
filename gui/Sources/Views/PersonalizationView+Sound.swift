import SwiftUI

// MARK: - Sound Effects Settings Extension for PersonalizationView

extension PersonalizationView {
    internal var soundEffectsCard: some View {
        GlassCard(cornerRadius: 16, padding: 18) {
            VStack(alignment: .leading, spacing: 14) {
                HStack {
                    HStack(spacing: 8) {
                        Image(systemName: soundService.isSoundEnabled ? "speaker.wave.2.fill" : "speaker.slash.fill")
                            .font(.system(size: 14, weight: .bold))
                            .foregroundColor(viewModel.highlightTheme.primaryColor)
                        
                        Text(viewModel.tr("personalization.sound_effects"))
                            .font(.system(size: 13, weight: .bold, design: .rounded))
                            .foregroundColor(NXTheme.textPrimary)
                    }
                    
                    Spacer()
                    
                    Toggle("", isOn: $soundService.isSoundEnabled)
                        .toggleStyle(.switch)
                        .labelsHidden()
                        .onChange(of: soundService.isSoundEnabled) { val in
                            if val {
                                SoundEffectService.shared.play(.click)
                            }
                        }
                }
                
                Divider().opacity(0.15)
                
                if soundService.isSoundEnabled {
                    HStack(spacing: 8) {
                        soundPreviewButton(title: "Click", type: .click)
                        soundPreviewButton(title: "Tab", type: .tabSwitch)
                        soundPreviewButton(title: "Launch", type: .launch)
                    }
                }
            }
        }
    }
    
    private func soundPreviewButton(title: String, type: SoundEffectType) -> some View {
        Button(action: {
            SoundEffectService.shared.play(type)
        }) {
            HStack(spacing: 4) {
                Image(systemName: "play.fill")
                    .font(.system(size: 8))
                Text(title)
                    .font(.system(size: 10, weight: .semibold, design: .rounded))
            }
            .padding(.horizontal, 9)
            .padding(.vertical, 5)
            .nxGlassBar(
                in: Capsule(),
                fallbackFill: NXTheme.glassSurfaceElevated.opacity(0.65),
                fallbackStroke: NXTheme.borderSubtle
            )
            .nxGlassInteractive(in: Capsule())
        }
        .buttonStyle(NXPressableButtonStyle())
        .nxNoFocusRing()
    }
}
