import Cocoa
import PopBarCore
import PopBarPlatform
import PopBarDesign

/// 跨模块的入口动作集中在这里：菜单栏、快捷键、浮动条、Deck 都调用同一套函数，
/// 模块之间不直接互相引用。
@MainActor
enum AppRouter {
    static func snap() {
        guard ModuleRegistry.shared.isEnabled("snap") else { return }
        SnapController.shared.start()
    }

    /// 录屏 / 停止录屏：菜单、热键、面板三处共用
    static func recordToggle() {
        if RecordSession.shared.isRecording {
            RecordSession.shared.stop()
        } else if RecordSession.shared.isCountingDown {
            RecordSession.shared.cancelCountdown()
        } else {
            guard ModuleRegistry.shared.isEnabled("record") else { return }
            guard !SnapController.shared.isActive else { return }
            guard ScreenPermission.ensure() else { return }
            SnapController.shared.start(mode: .record)
        }
    }

    /// 打开设置的某一页（翻译服务没配置时浮动条直接跳到这里）
    static func openSettings(_ section: SettingsSection = .general) {
        DeckController.shared.show(page: .settings, settings: section)
    }

    static func openAccessibilitySettings() {
        openPrivacyPane("Privacy_Accessibility")
    }

    static func openPrivacyPane(_ anchor: String) {
        if let u = URL(string: "x-apple.systempreferences:com.apple.preference.security?\(anchor)") {
            NSWorkspace.shared.open(u)
        }
    }

    /// 带快捷键展示的菜单项
    static func menuItem(_ title: String, hotkey: String = "", image: String? = nil,
                         action: @escaping @MainActor () -> Void) -> NSMenuItem {
        let item = NSMenuItem(title: title, action: #selector(MenuClosure.run(_:)), keyEquivalent: "")
        if let eq = HotKeyCenter.menuEquivalent(hotkey) {
            item.keyEquivalent = eq.key
            item.keyEquivalentModifierMask = eq.mask
        }
        if let image { item.image = Lucide.image(image, size: 15) }
        let box = MenuClosure(action)
        item.target = box
        item.representedObject = box   // 菜单项持有闭包，生命周期跟着菜单
        return item
    }
}

/// NSMenuItem 的闭包 target
final class MenuClosure: NSObject {
    private let action: @MainActor () -> Void
    init(_ action: @escaping @MainActor () -> Void) { self.action = action }
    @objc func run(_ sender: Any?) { MainActor.assumeIsolated { action() } }
}
