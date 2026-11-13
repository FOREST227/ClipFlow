import Foundation

extension ClipFlowStore {
    func runStartupPermissionCheck() {
        // Launch only reads trust. The system prompt waits until the first auto-paste.
        refreshPermissionReport(showEvenIfHealthy: false)
    }

    func refreshPermissionReport(showEvenIfHealthy: Bool) {
        let report = buildPermissionReport()

        if report.needsAttention || showEvenIfHealthy {
            startupPermissionReport = report
        } else {
            startupPermissionReport = nil
            lastCaptureStatus = "启动权限检查完成"
        }
    }

    private func buildPermissionReport() -> ClipFlowPermissionReport {
        let accessibilityGranted = checkAccessibilityPermission()
        let accessibilityItem = ClipFlowPermissionItem(
            title: "辅助功能",
            detail: accessibilityGranted
                ? "已授权。ClipFlow 可以在回填剪贴板后自动触发粘贴。"
                : "未授权。请打开“系统设置 → 隐私与安全性 → 辅助功能”并允许 ClipFlow。没有这项权限时，自动粘贴会改为把内容复制回剪贴板。",
            icon: "figure.wave.circle",
            status: accessibilityGranted ? .granted : .needsAttention
        )

        let documentsAccessGranted = checkDocumentsFolderAccessIfNeeded()
        let documentsItem = ClipFlowPermissionItem(
            title: "文稿目录",
            detail: iCloudSyncEnabled
                ? (documentsAccessGranted
                    ? "已可读写“文稿/ClipFlow”，普通历史内容会镜像到这个文件夹。"
                    : "文稿目录同步已开启，但当前还不能稳定读写“文稿/ClipFlow”。如系统弹出权限提示，请选择允许。")
                : "当前未开启文稿目录同步，因此不需要检查这个权限。",
            icon: "folder.badge.gearshape",
            status: iCloudSyncEnabled ? (documentsAccessGranted ? .granted : .needsAttention) : .notRequired
        )

        let items = [accessibilityItem, documentsItem]
        let hasIssue = items.contains { $0.status == .needsAttention }

        return ClipFlowPermissionReport(
            title: hasIssue ? "启动时发现权限未完整" : "权限检查完成",
            message: hasIssue
                ? "启动时只做了静默检查，没有弹出系统授权窗口。自动粘贴会在第一次使用时再请求辅助功能；未授权则改为复制到剪贴板。"
                : "ClipFlow 已完成本次启动权限检测，当前核心权限状态正常。",
            items: items
        )
    }

    private func checkAccessibilityPermission() -> Bool {
        isAccessibilityTrusted(prompt: false)
    }

    private func checkDocumentsFolderAccessIfNeeded() -> Bool {
        guard iCloudSyncEnabled else { return true }
        guard let documentsURL = fileManager.urls(for: .documentDirectory, in: .userDomainMask).first else {
            return false
        }

        let clipFlowDirectory = documentsURL.appendingPathComponent("ClipFlow", isDirectory: true)
        let probeURL = clipFlowDirectory.appendingPathComponent(".permission-probe")

        do {
            try fileManager.createDirectory(at: clipFlowDirectory, withIntermediateDirectories: true)
            let probeData = Data("clipflow".utf8)
            try probeData.write(to: probeURL, options: [.atomic])
            try? fileManager.removeItem(at: probeURL)
            return true
        } catch {
            return false
        }
    }
}
