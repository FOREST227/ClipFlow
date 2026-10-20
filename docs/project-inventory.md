# 项目清单（v0.0.5）

| 路径 | 职责 |
| --- | --- |
| Package.swift | SwiftPM 可执行程序、测试目标和 macOS 12 部署要求 |
| Sources/ClipFlowApp/ClipFlowApp.swift | AppKit 生命周期、菜单、启动路由 |
| Sources/ClipFlowApp/MainWindow.swift | 合并主窗口、页面导航、设置草稿 |
| Sources/ClipFlowApp/ContentView.swift | 历史库、菜单栏内容、详情和共享视觉组件 |
| Sources/ClipFlowApp/SettingsView.swift | 通用、隐私、同步设置 |
| Sources/ClipFlowApp/Models.swift | 历史模型、分类、持久化、偏好、同步状态 |
| Sources/ClipFlowApp/CloudSync.swift | 文稿目录合并及后台文件同步 |
| Sources/ClipFlowApp/Services.swift | 剪贴板监听、自动粘贴、快速面板 |
| Sources/ClipFlowApp/StatusBarController.swift | 菜单栏图标、弹窗定位与导航入口 |
| Sources/ClipFlowApp/Shortcut.swift、HotKeyController.swift、ShortcutRecorder.swift | 快捷键配置、注册与录入 |
| Sources/ClipFlowApp/Appearance.swift、AppearanceTransition.swift | 外观选择与过渡 |
| Sources/ClipFlowApp/LayoutComponents.swift、TabBar.swift、ClipFlowMotion.swift | 共享排版、分页、动效参数 |
| Sources/ClipFlowApp/Compatibility.swift、ViewState.swift | 系统及 SDK 兼容 |
| Tests/ClipFlowAppTests | 分类、持久化、隐私、同步、快捷键、窗口和偏好的回归测试 |
| scripts/setup_signing.sh、sign_app.sh | 本机固定签名身份设置与验证 |
| scripts/build_app.sh、build_release_dmg.sh | 构建应用及多架构 DMG |
| .github/workflows/release.yml | 标签触发的测试、打包和 GitHub Release 发布 |
| docs/releases | 版本说明 |

构建产物位于被 Git 忽略的 `.build/` 和 `dist/`。签名私钥、证书身份配置及用户剪贴历史均不进入仓库。
