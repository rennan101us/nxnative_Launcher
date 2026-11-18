import Foundation

public enum LibrarySubTab: String, CaseIterable, Identifiable {
    case switch1And2 = "switch1And2"
    case iosAndIpados = "iosAndIpados"
    case nonPorted = "nonPorted"

    public var id: String { rawValue }

    public var iconName: String {
        switch self {
        case .switch1And2: return "gamecontroller.fill"
        case .iosAndIpados: return "iphone.gen3"
        case .nonPorted: return "shippingbox.fill"
        }
    }

    public var translationKey: String {
        switch self {
        case .switch1And2: return "library.tab_switch1_and_2"
        case .iosAndIpados: return "library.tab_ios_and_ipados"
        case .nonPorted: return "library.tab_non_ported"
        }
    }
}
