import SwiftUI

enum ClipFlowPermissionStatus {
    case granted
    case needsAttention
    case notRequired

    var label: String {
        switch self {
        case .granted:
            return "正常"
        case .needsAttention:
            return "需要处理"
        case .notRequired:
            return "当前无需"
        }
    }

    var tint: Color {
        switch self {
        case .granted:
            return Color(red: 0.34, green: 0.67, blue: 0.53)
        case .needsAttention:
            return ClipCategory.protected.tint
        case .notRequired:
            return ClipCategory.all.tint
        }
    }
}

struct ClipFlowPermissionItem: Identifiable {
    let id = UUID()
    let title: String
    let detail: String
    let icon: String
    let status: ClipFlowPermissionStatus
}

struct ClipFlowPermissionReport: Identifiable {
    let id = UUID()
    let title: String
    let message: String
    let items: [ClipFlowPermissionItem]

    var needsAttention: Bool {
        items.contains { $0.status == .needsAttention }
    }
}
