import AppKit
import ApplicationServices

/// FingerPath：贴着输入法候选条的屏幕键盘。看屏幕，不看手。
@main
@MainActor
struct FingerPathApp {
    static func main() {
        let app = NSApplication.shared
        let delegate = AppDelegate()
        app.setActivationPolicy(.accessory)
        app.delegate = delegate
        app.run()
    }
}

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate, NSMenuDelegate {
    private var statusItem: NSStatusItem?
    private let keyboard = KeyboardOverlayController.shared

    func applicationDidFinishLaunching(_ notification: Notification) {
        // 读取输入框位置、全局监听按键都需要「辅助功能」权限。
        _ = AXIsProcessTrustedWithOptions(["AXTrustedCheckOptionPrompt": true] as CFDictionary)
        let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        item.button?.image = NSImage(systemSymbolName: "keyboard", accessibilityDescription: "FingerPath")
        let menu = NSMenu()
        menu.delegate = self
        item.menu = menu
        statusItem = item
        keyboard.startIfEnabled()
    }

    /// 每次打开菜单时重新生成，勾选状态总是最新的。
    func menuNeedsUpdate(_ menu: NSMenu) {
        menu.removeAllItems()
        add(menu, keyboard.isEnabled ? "隐藏键盘" : "显示键盘", #selector(toggleKeyboard))

        menu.addItem(.separator())
        menu.addItem(header("位置"))
        add(menu, "跟随输入框（紧贴候选条）", #selector(followInput), checked: keyboard.followsInput)
        add(menu, "固定在屏幕顶部", #selector(pinTop), checked: !keyboard.followsInput)

        menu.addItem(.separator())
        menu.addItem(header("提示"))
        for level in KeyboardOverlayController.HintLevel.allCases {
            let item = add(menu, level.title, #selector(setLevel(_:)), checked: keyboard.level == level)
            item.tag = level.rawValue
        }
        add(menu, "显示英文翻译", #selector(toggleTranslation), checked: keyboard.showsTranslation)

        menu.addItem(.separator())
        menu.addItem(header("最容易打错：" + KeyStats.summary()))
        add(menu, "清空统计", #selector(resetStats))

        menu.addItem(.separator())
        if !AXIsProcessTrusted() {
            add(menu, "⚠️ 需要辅助功能权限，点这里打开设置", #selector(openAccessibilitySettings))
        }
        add(menu, "GitHub 主页", #selector(openHomepage))
        add(menu, "退出 FingerPath", #selector(quit), key: "q")
    }

    @discardableResult
    private func add(_ menu: NSMenu, _ title: String, _ action: Selector, checked: Bool = false, key: String = "") -> NSMenuItem {
        let item = NSMenuItem(title: title, action: action, keyEquivalent: key)
        item.target = self
        item.state = checked ? .on : .off
        menu.addItem(item)
        return item
    }

    private func header(_ title: String) -> NSMenuItem {
        let item = NSMenuItem(title: title, action: nil, keyEquivalent: "")
        item.isEnabled = false
        return item
    }

    @objc private func toggleKeyboard() { keyboard.toggle() }
    @objc private func followInput() { keyboard.followsInput = true }
    @objc private func pinTop() { keyboard.followsInput = false }
    @objc private func setLevel(_ sender: NSMenuItem) {
        keyboard.level = KeyboardOverlayController.HintLevel(rawValue: sender.tag) ?? .full
    }
    @objc private func toggleTranslation() { keyboard.showsTranslation.toggle() }
    @objc private func resetStats() { KeyStats.reset() }
    @objc private func openAccessibilitySettings() {
        NSWorkspace.shared.open(URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility")!)
    }
    @objc private func openHomepage() {
        NSWorkspace.shared.open(URL(string: "https://github.com/mulikouc-collab/FingerPath")!)
    }
    @objc private func quit() { NSApp.terminate(nil) }
}
