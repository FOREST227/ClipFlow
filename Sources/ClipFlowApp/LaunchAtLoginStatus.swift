import Foundation
import ServiceManagement

/// What the Settings switch should show for the system login item.
enum LaunchAtLoginStatus: Equatable {
    case unsupported
    case disabled
    case enabled
    case needsApproval

    var isOn: Bool { self == .enabled || self == .needsApproval }

    static let standardDetail = "登录 macOS 后自动运行剪流"
    static let approvalDetail = "已加入登录项，请在“系统设置 → 通用 → 登录项与扩展”中允许剪流。"
    static let unsupportedDetail = "macOS 12 请在系统偏好设置的用户与群组中添加登录项"
    static let registrationFailed = "开机自动启动设置失败，请将 ClipFlow 放在应用程序目录后再试"

    var detail: String {
        switch self {
        case .unsupported: Self.unsupportedDetail
        case .needsApproval: Self.approvalDetail
        case .disabled, .enabled: Self.standardDetail
        }
    }

    @available(macOS 13, *)
    static func resolve(_ status: SMAppService.Status) -> LaunchAtLoginStatus {
        switch status {
        case .enabled: .enabled
        case .requiresApproval: .needsApproval
        case .notRegistered, .notFound: .disabled
        @unknown default: .disabled
        }
    }
}
