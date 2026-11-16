import SwiftUI

/// Switch titles shared by the menu bar and Settings.
/// A switch that is on means the feature is active.
enum SharedSettingsCopy {
    static let recordClipboard = "记录剪贴板"
    static let recordClipboardDetail = "关闭后暂停记录新内容，已有历史仍可使用"

    static let protectSecrets = "自动保护疑似敏感内容"
    static let protectSecretsDetail = "识别验证码、令牌等内容并应用隐私策略"

    static let expireSecrets = "5 分钟后删除敏感内容"
    static let expireSecretsDetail = "按复制时间计算，置顶也会过期"
    static let expireSecretsHelp = "按复制时间计算，置顶也会过期；重新开启将清理已超时的敏感记录"

    static let syncPlainHistory = "同步普通历史"

    /// Menu and Settings both show recording as the on state.
    static func recording(isPaused: Binding<Bool>) -> Binding<Bool> {
        Binding(get: { !isPaused.wrappedValue }, set: { isPaused.wrappedValue = !$0 })
    }
}
