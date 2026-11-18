import SwiftUI
import AppKit

public struct CloudSourcesSimpleSheet: View {
    @ObservedObject public var viewModel: AppViewModel
    @Environment(\.dismiss) private var dismiss
    
    @State private var inputURL: String = ""
    @State private var inputName: String = ""
    
    public init(viewModel: AppViewModel) {
        self.viewModel = viewModel
    }
    
    public var body: some View {
        VStack(spacing: 16) {
            // MARK: - Header
            HStack(spacing: 12) {
                ZStack {
                    Circle()
                        .fill(NXTheme.primary.opacity(0.20))
                        .frame(width: 42, height: 42)
                    Image(systemName: "icloud.and.arrow.down.fill")
                        .font(.system(size: 20, weight: .bold))
                        .foregroundColor(NXTheme.primary)
                }
                
                VStack(alignment: .leading, spacing: 3) {
                    Text("Links dos seus jogos na Nuvem")
                        .font(.system(size: 16, weight: .bold, design: .rounded))
                        .foregroundColor(.white)
                    Text("Adicione URLs de sites, diretórios ou repositórios onde seus backups estão armazenados.")
                        .font(.system(size: 11, design: .rounded))
                        .foregroundColor(NXTheme.textSecondary)
                }
                
                Spacer()
                
                Button(action: {
                    SoundEffectService.shared.play(.click)
                    dismiss()
                }) {
                    Image(systemName: "xmark.circle.fill")
                        .font(.system(size: 20))
                        .foregroundColor(NXTheme.textSecondary)
                }
                .buttonStyle(PlainButtonStyle())
            }
            .padding(.horizontal, 2)
            
            // MARK: - Add Source Box
            VStack(spacing: 10) {
                HStack(spacing: 10) {
                    TextField("Nome (ex: Backup Pessoal, Nuvem)", text: $inputName)
                        .textFieldStyle(PlainTextFieldStyle())
                        .font(.system(size: 12, design: .rounded))
                        .padding(.horizontal, 12)
                        .padding(.vertical, 8)
                        .background(NXTheme.glassSurfaceElevated.opacity(0.50))
                        .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
                        .overlay(
                            RoundedRectangle(cornerRadius: 10, style: .continuous)
                                .strokeBorder(NXTheme.borderSubtle, lineWidth: 1)
                        )
                        .frame(maxWidth: 180)
                    
                    TextField("https://seusite.com/roms ou magnet:...", text: $inputURL)
                        .textFieldStyle(PlainTextFieldStyle())
                        .font(.system(size: 12, design: .rounded))
                        .padding(.horizontal, 12)
                        .padding(.vertical, 8)
                        .background(NXTheme.glassSurfaceElevated.opacity(0.50))
                        .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
                        .overlay(
                            RoundedRectangle(cornerRadius: 10, style: .continuous)
                                .strokeBorder(NXTheme.borderSubtle, lineWidth: 1)
                        )
                    
                    Button(action: {
                        let url = inputURL.trimmingCharacters(in: .whitespacesAndNewlines)
                        guard !url.isEmpty else { return }
                        viewModel.addCloudSource(name: inputName, urlString: url)
                        inputURL = ""
                        inputName = ""
                    }) {
                        HStack(spacing: 5) {
                            Image(systemName: "plus.circle.fill")
                            Text("Adicionar")
                        }
                        .font(.system(size: 11, weight: .bold))
                    }
                    .buttonStyle(NXAccentButtonStyle())
                    .disabled(inputURL.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                }
            }
            .padding(14)
            .nxGlassCard(cornerRadius: 14)
            
            // MARK: - Sources List
            VStack(alignment: .leading, spacing: 8) {
                HStack {
                    Text("Fontes Cadastradas (\(viewModel.cloudSources.count))")
                        .font(.system(size: 12, weight: .bold, design: .rounded))
                        .foregroundColor(NXTheme.textPrimary)
                    
                    Spacer()
                    
                    if viewModel.isSyncingCloudSources {
                        HStack(spacing: 5) {
                            ProgressView()
                                .controlSize(.small)
                            Text("Buscando jogos compatíveis...")
                                .font(.system(size: 10, weight: .medium))
                                .foregroundColor(NXTheme.textSecondary)
                        }
                    } else {
                        Button(action: {
                            SoundEffectService.shared.play(.click)
                            viewModel.syncCloudSources()
                        }) {
                            HStack(spacing: 4) {
                                Image(systemName: "arrow.clockwise")
                                Text("Sincronizar")
                            }
                            .font(.system(size: 10.5, weight: .semibold))
                        }
                        .buttonStyle(NXSecondaryButtonStyle())
                        .controlSize(.mini)
                    }
                }
                
                if viewModel.cloudSources.isEmpty {
                    VStack(spacing: 8) {
                        Image(systemName: "link.badge.plus")
                            .font(.system(size: 28))
                            .foregroundColor(NXTheme.textMuted)
                        Text("Nenhuma fonte adicionada ainda.")
                            .font(.system(size: 12, weight: .medium))
                            .foregroundColor(NXTheme.textSecondary)
                        Text("Cole a URL de um site ou diretório acima para que o launcher encontre os jogos compatíveis automaticamente.")
                            .font(.system(size: 10.5))
                            .foregroundColor(NXTheme.textMuted)
                            .multilineTextAlignment(.center)
                    }
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 24)
                    .nxGlassCard(cornerRadius: 12)
                } else {
                    ScrollView {
                        VStack(spacing: 8) {
                            ForEach(viewModel.cloudSources) { source in
                                HStack(spacing: 12) {
                                    VStack(alignment: .leading, spacing: 3) {
                                        HStack(spacing: 6) {
                                            Text(source.name)
                                                .font(.system(size: 12, weight: .bold, design: .rounded))
                                                .foregroundColor(.white)
                                            
                                            if let err = source.lastErrorMessage {
                                                Text(err)
                                                    .font(.system(size: 9, weight: .semibold))
                                                    .foregroundColor(.red)
                                                    .padding(.horizontal, 5)
                                                    .padding(.vertical, 1)
                                                    .background(Color.red.opacity(0.20))
                                                    .clipShape(Capsule())
                                            } else if source.lastItemCount > 0 {
                                                Text("\(source.lastItemCount) compatíveis")
                                                    .font(.system(size: 9, weight: .bold))
                                                    .foregroundColor(NXTheme.primary)
                                                    .padding(.horizontal, 5)
                                                    .padding(.vertical, 1)
                                                    .background(NXTheme.primary.opacity(0.20))
                                                    .clipShape(Capsule())
                                            }
                                        }
                                        
                                        Text(source.urlString)
                                            .font(.system(size: 10, design: .monospaced))
                                            .foregroundColor(NXTheme.textSecondary)
                                            .lineLimit(1)
                                            .truncationMode(.middle)
                                    }
                                    
                                    Spacer()
                                    
                                    Toggle("", isOn: Binding(
                                        get: { source.isEnabled },
                                        set: { viewModel.toggleCloudSource(id: source.id, isEnabled: $0) }
                                    ))
                                    .labelsHidden()
                                    .toggleStyle(.switch)
                                    .controlSize(.mini)
                                    
                                    Button(action: {
                                        viewModel.removeCloudSource(id: source.id)
                                    }) {
                                        Image(systemName: "trash.fill")
                                            .font(.system(size: 12))
                                            .foregroundColor(.red.opacity(0.85))
                                    }
                                    .buttonStyle(PlainButtonStyle())
                                    .padding(.leading, 4)
                                }
                                .padding(.horizontal, 12)
                                .padding(.vertical, 8)
                                .nxGlassCard(cornerRadius: 10)
                            }
                        }
                    }
                    .frame(maxHeight: 180)
                }
            }
            
            // MARK: - Legal Disclaimer Banner
            HStack(spacing: 8) {
                Image(systemName: "shield.lefthalf.filled")
                    .font(.system(size: 12))
                    .foregroundColor(NXTheme.secondary)
                Text("Isenção de Responsabilidade: O NxNative Launcher é um emulador/portador neutro de código aberto. Não fornecemos, não hospedamos e não distribuímos arquivos de jogos. Todos os links inseridos são de responsabilidade do próprio usuário.")
                    .font(.system(size: 9.5))
                    .foregroundColor(NXTheme.textMuted)
                    .lineLimit(2)
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 6)
            .background(Color.black.opacity(0.25))
            .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
        }
        .padding(20)
        .frame(minWidth: 580, idealWidth: 640, minHeight: 400, maxHeight: 460)
        .background(NXWindowGlassBackground(viewModel: viewModel))
    }
}
