import SwiftUI

public struct DependencyRow: View {
    public let item: DependencyStatus
    @ObservedObject public var viewModel: AppViewModel
    
    public init(item: DependencyStatus, viewModel: AppViewModel) {
        self.item = item
        self.viewModel = viewModel
    }
    
    public var body: some View {
        HStack(spacing: 12) {
            Image(systemName: item.isAvailable ? "checkmark.circle.fill" : "xmark.circle.fill")
                .foregroundColor(item.isAvailable ? Color(red: 0.13, green: 0.77, blue: 0.37) : NXTheme.tertiary)
                .font(.system(size: 16))
                .frame(width: 20)
            
            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 6) {
                    Text(item.name)
                        .font(.system(size: 12, weight: .bold, design: .rounded))
                        .foregroundColor(NXTheme.textPrimary)
                    
                    if let download = item.downloadSizeBadge, !download.isEmpty {
                        HStack(spacing: 3) {
                            Image(systemName: "arrow.down.circle")
                                .font(.system(size: 8.5))
                            Text(download)
                                .font(.system(size: 9.5, weight: .semibold, design: .monospaced))
                        }
                        .foregroundColor(NXTheme.secondary)
                        .padding(.horizontal, 6)
                        .padding(.vertical, 1.5)
                        .background(NXTheme.glassSurfaceElevated.opacity(0.85))
                        .clipShape(Capsule())
                        .overlay(
                            Capsule()
                                .strokeBorder(NXTheme.specularRim.opacity(0.4), lineWidth: 0.6)
                        )
                    }

                    if let disk = item.installedSizeBadge, !disk.isEmpty {
                        HStack(spacing: 3) {
                            Image(systemName: "internaldrive")
                                .font(.system(size: 8.5))
                            Text(disk)
                                .font(.system(size: 9.5, weight: .semibold, design: .monospaced))
                        }
                        .foregroundColor(NXTheme.modalDescription)
                        .padding(.horizontal, 6)
                        .padding(.vertical, 1.5)
                        .background(NXTheme.glassSurfaceElevated.opacity(0.5))
                        .clipShape(Capsule())
                    }
                }
                
                Text(item.details)
                    .font(.system(size: 11, design: .monospaced))
                    .foregroundColor(NXTheme.textSecondary)
                
                if let rec = item.recommendation {
                    Text(rec)
                        .font(.system(size: 11))
                        .foregroundColor(Color(red: 1.0, green: 0.65, blue: 0.35))
                }
            }
            
            Spacer()
            
            // Actions: Install / Repair / Uninstall
            NXGlassContainer(spacing: 6) {
                if !item.isAvailable && item.installCommand != nil {
                    Button(action: {
                        viewModel.installDependency(item)
                    }) {
                        HStack(spacing: 4) {
                            Image(systemName: "arrow.down.circle")
                            Text(viewModel.tr("common.install"))
                        }
                        .font(.system(size: 11, weight: .semibold))
                    }
                    .buttonStyle(NXPrimaryButtonStyle())
                    .controlSize(.small)
                } else if item.isAvailable {
                    HStack(spacing: 6) {
                        Button(viewModel.tr("common.repair")) {
                            viewModel.repairDependency(item)
                        }
                        .buttonStyle(NXSecondaryButtonStyle())
                        .controlSize(.small)
                        .help(viewModel.tr("system.repair_help"))
                        
                        if !item.isProtected && item.uninstallCommand != nil {
                            Button(role: .destructive) {
                                viewModel.confirmUninstall(item)
                            } label: {
                                Image(systemName: "trash")
                                    .font(.system(size: 11))
                                    .foregroundColor(NXTheme.tertiary)
                            }
                            .buttonStyle(NXSecondaryButtonStyle())
                            .controlSize(.small)
                            .help(viewModel.tr("system.uninstall_help"))
                        }
                    }
                }
            }
        }
        .padding(10)
        .nxGlassCard(cornerRadius: 10, isNested: true)
    }
}
