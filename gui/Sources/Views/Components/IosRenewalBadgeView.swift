import SwiftUI

public struct IosRenewalBadgeView: View {
    public let record: IosDeploymentRecord
    public let scale: CGFloat
    
    public init(record: IosDeploymentRecord, scale: CGFloat = 1.0) {
        self.record = record
        self.scale = scale
    }
    
    private var tooltipText: String {
        if record.isExpired {
            return L10n.t("settings.ios_expired_tooltip")
        } else if record.daysRemaining == 1 {
            return L10n.t("settings.ios_critical_tooltip")
        } else if record.daysRemaining <= 3 {
            return L10n.t("settings.ios_warning_tooltip", record.daysRemaining)
        } else {
            return L10n.t("settings.ios_safe_tooltip", record.daysRemaining)
        }
    }
    
    public var body: some View {
        HStack(spacing: max(2.0, 3.0 * scale)) {
            Image(systemName: record.isExpired ? "exclamationmark.triangle.fill" : "clock.arrow.circlepath")
                .font(.system(size: max(6.0, 8.0 * scale), weight: .bold))
                .foregroundColor(record.tier.tintColor)
            
            Text(record.badgeText)
                .font(.system(size: max(6.5, 9.0 * scale), weight: .black, design: .rounded))
                .foregroundColor(.white)
        }
        .padding(.horizontal, max(3.5, 6.0 * scale))
        .padding(.vertical, max(1.5, 3.0 * scale))
        .background(
            Capsule()
                .fill(Color.black.opacity(0.65))
                .overlay(
                    Capsule()
                        .strokeBorder(record.tier.tintColor.opacity(0.85), lineWidth: max(0.8, 1.2 * scale))
                )
                .shadow(color: record.tier.accentGlow, radius: max(2.0, 4.0 * scale), x: 0, y: 1)
        )
        .help(tooltipText)
    }
}
