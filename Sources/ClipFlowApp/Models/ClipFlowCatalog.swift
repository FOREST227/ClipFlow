import SwiftUI

struct FlowMetric: Identifiable {
    let id = UUID()
    let value: String
    let title: String
    let detail: String
    let icon: String
    let tint: Color
}

struct IntegrationPill: Identifiable {
    let id = UUID()
    let title: String
    let icon: String
    let detail: String
    let tint: Color
}

enum ClipFlowCatalog {
    static let integrations: [IntegrationPill] = [
        IntegrationPill(
            title: "菜单栏入口",
            icon: "menubar.rectangle",
            detail: "从菜单栏暂停监听、查看最近内容，或重新打开主窗口。",
            tint: ClipCategory.all.tint
        ),
        IntegrationPill(
            title: "全局呼出",
            icon: "command.circle",
            detail: "用全局快捷键在指针附近呼出快速粘贴面板，可在设置中自定义组合。",
            tint: ClipCategory.pinned.tint
        ),
        IntegrationPill(
            title: "隐私优先",
            icon: "lock.rectangle.stack",
            detail: "敏感内容默认遮罩显示，仅本地保存，并可自动过期。",
            tint: ClipCategory.protected.tint
        ),
        IntegrationPill(
            title: "原生粘贴",
            icon: "arrow.up.doc",
            detail: "选中条目后会重新写入剪贴板，并向目标应用发送粘贴操作。",
            tint: ClipCategory.links.tint
        )
    ]
}
