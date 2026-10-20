# ClipFlow 技术设计（v0.0.5）

## 应用与界面

应用由 AppKit 的 `NSApplication` 和 `ClipFlowAppDelegate` 启动，SwiftUI 用于具体页面。只有一个 `MainWindowController` 管理历史与设置窗口；`MainWindowNavigation` 切换页面，`SettingsDraft` 保留尚未保存的排除规则及设置分组选择。

`StatusBarController` 管理菜单栏图标与弹窗。启动和重新打开应用共用启动选项：开启时等待图标定位后展开弹窗，关闭时显示历史。`QuickPastePanelController` 保留鼠标附近呼出的独立非激活面板。

## 数据与持久化

`ClipFlowStore` 在主 actor 上管理历史、筛选、偏好和状态。历史保存在 Application Support/ClipFlow/history.json，图片保存在同目录的 images 文件夹。写入使用原子替换和串行队列；读入失败时禁止覆盖原历史和清理图片，等待恢复。

`ClipboardItem` 中的 `capturedAt` 将敏感内容的过期时间与排序使用的 `createdAt` 分离。旧记录缺少该字段时回退到 createdAt。敏感记录按用户开关应用五分钟过期策略，置顶不会延长有效期。普通文本原样保留。

## 同步

文稿目录同步合并普通历史和删除标记；系统开启 iCloud Drive 文稿同步后，文件随系统同步。文件读写和图片拷贝通过 `ClipFlowCloudSyncWorker` 串行在后台执行，结果应用前检查本地修订号和同步代次，避免覆盖期间发生的复制或删除。

远端未引用图片不自动清理，因为图片可能早于引用它的历史到达。本地图片按当前记录集合清理。

## 系统输入与外观

`ClipboardMonitor` 轮询剪贴板版本，并在空闲时清理过期记录。回填后忽略自身写入的具体版本，避免吞掉下一次外部复制。

`HotKeyController` 使用 Carbon 注册快捷键，替换注册成功后才释放旧快捷键。录入控件保留 AppKit 的键盘事件处理，SwiftUI 负责展示；取消、失焦或离开设置会恢复原绑定。

外观偏好由 `ClipFlowAppearance` 表示，应用级 NSAppearance 覆盖驱动所有页面。菜单栏弹窗显式跟踪应用有效外观。`AppearanceTransition` 使用短暂的内存快照淡出平滑手动颜色切换；实际颜色相同或减少动态效果开启时不播放动画。

## 兼容与构建

最低部署目标为 macOS 12。`Compatibility.swift` 为新 SwiftUI API 提供回退；macOS 12 无 SMAppService 注册能力时提示手动添加系统登录项。开发需要 Swift 6 及完整 Xcode。

`scripts/build_app.sh` 支持 host、arm64、x86_64，并使用固定签名助手。`build_release_dmg.sh` 合并两种架构为 universal，重新签名后输出三个 DMG。CI 运行测试并显式使用 ad-hoc 签名，开发者私钥只保存在本机钥匙串。
