import AppKit

enum ClipFlowAppearance: String, CaseIterable, Identifiable, ClipFlowTab {
    case system
    case light
    case dark

    var id: Self { self }

    static func load(from defaults: UserDefaults) -> Self {
        if let rawValue = defaults.string(forKey: "appearanceMode"),
           let mode = Self(rawValue: rawValue) {
            return mode
        }
        // v0.0.4 stored the appearance as an integer instead of a string.
        if let legacy = defaults.object(forKey: "appearanceMode") as? NSNumber {
            switch legacy.intValue {
            case 1: return .light
            case 2: return .dark
            default: return .system
            }
        }
        return .system
    }
    var title: String {
        switch self {
        case .system: "跟随系统"
        case .light: "浅色"
        case .dark: "深色"
        }
    }
    var icon: String {
        switch self {
        case .system: "circle.lefthalf.filled"
        case .light: "sun.max.fill"
        case .dark: "moon.fill"
        }
    }

    @MainActor
    var appKitAppearance: NSAppearance? {
        switch self {
        case .system: nil
        case .light: NSAppearance(named: .aqua)
        case .dark: NSAppearance(named: .darkAqua)
        }
    }
}
