import AppKit
import SwiftUI
import Combine

@main
struct ClipFlowApp {
    @MainActor
    static func main() {
        let application = NSApplication.shared
        let delegate = ClipFlowAppDelegate()
        application.setActivationPolicy(.regular)
        application.delegate = delegate
        withExtendedLifetime(delegate) {
            application.run()
        }
    }
}

@MainActor
final class ClipFlowAppDelegate: NSObject, NSApplicationDelegate {
    private var statusBarController: StatusBarController?
    private var appearanceSubscription: AnyCancellable?
    private let appearanceTransition = AppearanceTransition()
    private lazy var mainWindowController = MainWindowController(
        store: ClipFlowStore.shared,
        locale: Locale(identifier: "zh-Hans")
    )
    func applicationDidFinishLaunching(_ notification: Notification) {
        // Native windows, popovers and every NSHostingView inherit this override.
        // nil removes it so future macOS appearance changes propagate normally.
        appearanceSubscription = ClipFlowStore.shared.$appearanceMode.sink { [weak self] mode in
            self?.appearanceTransition.apply(mode)
        }
        configureMainMenu()
        ClipFlowRuntime.shared.start()
        statusBarController = StatusBarController(store: ClipFlowStore.shared)
        AppNavigationCenter.shared.openLibraryWindow = { [weak self] in
            self?.showLibraryWindow()
        }
        AppNavigationCenter.shared.openSettingsWindow = { [weak self] in
            self?.showSettingsWindow()
        }

        // Wait until the status item has been attached to the menu bar.
        DispatchQueue.main.async { [weak self] in
            self?.showStartupInterface()
        }
    }

    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        showStartupInterface()
        return false
    }

    func applicationShouldSaveApplicationState(_ app: NSApplication, coder: NSCoder) -> Bool { false }
    func applicationShouldRestoreApplicationState(_ app: NSApplication, coder: NSCoder) -> Bool { false }

    private func showStartupInterface() {
        if ClipFlowStore.shared.launchToStatusBar {
            statusBarController?.showPopover(waitForMenuBarLayout: true)
        } else {
            showLibraryWindow()
        }
    }

    @objc private func openLibraryFromMenu(_ sender: Any?) {
        AppNavigationCenter.shared.openLibrary()
    }

    @objc private func openSettingsFromMenu(_ sender: Any?) {
        AppNavigationCenter.shared.openSettings()
    }

    private func configureMainMenu() {
        let menuBar = NSMenu()
        func addMenu(_ title: String) -> NSMenu {
            let item = NSMenuItem(title: title, action: nil, keyEquivalent: "")
            let menu = NSMenu(title: title)
            item.submenu = menu
            menuBar.addItem(item)
            return menu
        }
        let applicationMenu = addMenu("ClipFlow")
        applicationMenu.addItem(withTitle: "关于 ClipFlow 剪流", action: #selector(NSApplication.orderFrontStandardAboutPanel(_:)), keyEquivalent: "")
        applicationMenu.addItem(.separator())
        let settingsItem = applicationMenu.addItem(withTitle: "设置…", action: #selector(openSettingsFromMenu(_:)), keyEquivalent: ",")
        settingsItem.target = self
        let historyItem = applicationMenu.addItem(withTitle: "打开剪贴历史", action: #selector(openLibraryFromMenu(_:)), keyEquivalent: "")
        historyItem.target = self
        applicationMenu.addItem(.separator())
        let servicesItem = NSMenuItem(title: "服务", action: nil, keyEquivalent: "")
        let servicesMenu = NSMenu(title: "服务")
        servicesItem.submenu = servicesMenu
        applicationMenu.addItem(servicesItem)
        NSApp.servicesMenu = servicesMenu
        applicationMenu.addItem(.separator())
        applicationMenu.addItem(withTitle: "隐藏 ClipFlow", action: #selector(NSApplication.hide(_:)), keyEquivalent: "h")
        let hideOthers = applicationMenu.addItem(withTitle: "隐藏其他", action: #selector(NSApplication.hideOtherApplications(_:)), keyEquivalent: "h")
        hideOthers.keyEquivalentModifierMask = [.command, .option]
        applicationMenu.addItem(withTitle: "显示全部", action: #selector(NSApplication.unhideAllApplications(_:)), keyEquivalent: "")
        applicationMenu.addItem(.separator())
        applicationMenu.addItem(withTitle: "退出 ClipFlow", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")

        let editMenu = addMenu("编辑")
        editMenu.addItem(withTitle: "撤销", action: Selector(("undo:")), keyEquivalent: "z")
        let redo = editMenu.addItem(withTitle: "重做", action: Selector(("redo:")), keyEquivalent: "z")
        redo.keyEquivalentModifierMask = [.command, .shift]
        editMenu.addItem(.separator())
        for (title, action, key) in [("剪切", "cut:", "x"), ("复制", "copy:", "c"), ("粘贴", "paste:", "v"), ("全选", "selectAll:", "a")] {
            editMenu.addItem(withTitle: title, action: Selector(action), keyEquivalent: key)
        }

        let windowMenu = addMenu("窗口")
        let libraryItem = windowMenu.addItem(withTitle: "打开剪贴历史", action: #selector(openLibraryFromMenu(_:)), keyEquivalent: "")
        libraryItem.target = self
        windowMenu.addItem(.separator())
        windowMenu.addItem(withTitle: "关闭窗口", action: #selector(NSWindow.performClose(_:)), keyEquivalent: "w")
        windowMenu.addItem(withTitle: "最小化", action: #selector(NSWindow.performMiniaturize(_:)), keyEquivalent: "m")
        windowMenu.addItem(withTitle: "缩放", action: #selector(NSWindow.performZoom(_:)), keyEquivalent: "")
        windowMenu.addItem(withTitle: "全部前置", action: #selector(NSApplication.arrangeInFront(_:)), keyEquivalent: "")
        NSApp.windowsMenu = windowMenu
        NSApp.mainMenu = menuBar
    }

    @MainActor
    private func showLibraryWindow() {
        mainWindowController.show(page: .history)
    }

    @MainActor
    private func showSettingsWindow() {
        mainWindowController.show(page: .settings)
    }
}
