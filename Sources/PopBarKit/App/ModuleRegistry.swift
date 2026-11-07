import Cocoa
import SwiftUI
import PopBarCore
import PopBarPlatform
import PopBarDesign

/// Deck 侧栏分组
enum DeckGroup: Int, CaseIterable {
    case work, media, system, devices

    var title: String {
        switch self {
        case .work: return L10n.t("工作", "Work")
        case .media: return L10n.t("媒体", "Media")
        case .system: return L10n.t("系统", "System")
        case .devices: return L10n.t("设备", "Devices")
        }
    }
}

/// 模块需要的系统权限（欢迎页只列出当前已开启模块真正需要的）
enum PermissionKind: String, CaseIterable, Identifiable {
    case accessibility, inputMonitoring, screenRecording, reminders, calendar, localNetwork, microphone, camera
    var id: String { rawValue }
}

/// 一个模块注册的快捷键
struct ModuleHotkey {
    let id: String
    let title: String
    let keyPath: WritableKeyPath<HotkeysConfig, String>
    let action: @MainActor () -> Void
}

/// 功能模块协议（docs 3.9）：模块只能通过 ModuleRegistry 向 App 注册侧栏页、浮动条动作、快捷键、菜单项。
/// 模块关闭后：不出现在侧栏、浮动条和菜单里；快捷键不注册；不跑任何定时器或线程；欢迎页不再要它需要的权限。
@MainActor
protocol PopBarModule: AnyObject {
    var id: String { get }
    var title: String { get }
    /// 一句话说明（设置 › 模块）
    var summary: String { get }
    /// Lucide 图标名
    var icon: String { get }
    var group: DeckGroup { get }
    /// 侧栏角标（待办数、剪贴板条数）
    var badge: Int? { get }
    /// Deck 页面
    func page() -> AnyView
    /// 浮动条动作（模块关闭时不出现）
    func barActions(for ctx: SourceContext) -> [BarAction]
    var hotkeys: [ModuleHotkey] { get }
    /// 菜单栏菜单里的项（精简后只有截屏 / 录屏有）
    func menuItems() -> [NSMenuItem]
    var permissions: [PermissionKind] { get }
    /// 模块开启：启动需要常驻的定时器 / 监听
    func start()
    /// 模块关闭：停掉一切后台工作
    func stop()
    /// Deck 切到 / 离开这一页（页面生命周期：离开监控页停采样、离开打印页停刷新）
    func pageDidAppear()
    func pageDidDisappear()
}

extension PopBarModule {
    var badge: Int? { nil }
    var summary: String { "" }
    func barActions(for ctx: SourceContext) -> [BarAction] { [] }
    var hotkeys: [ModuleHotkey] { [] }
    func menuItems() -> [NSMenuItem] { [] }
    var permissions: [PermissionKind] { [] }
    func start() {}
    func stop() {}
    func pageDidAppear() {}
    func pageDidDisappear() {}
}

/// 根据配置启动或停止模块
@MainActor
final class ModuleRegistry: ObservableObject {
    static let shared = ModuleRegistry()

    /// 侧栏顺序即此顺序
    let all: [PopBarModule] = [
        TodayModule(), ClipboardModule(),
        SnapModule(), RecordModule(),
        MonitorModule(), CleanModule(), StartupModule(), MaintenanceModule(),
        PrintModule(), TVModule(),
    ]

    @Published private(set) var enabledIDs: Set<String> = []
    private var started: Set<String> = []

    func module(_ id: String) -> PopBarModule? { all.first { $0.id == id } }

    /// 以配置为准（启动顺序无关；enabledIDs 只用来驱动界面刷新）
    func isEnabled(_ id: String) -> Bool { ConfigStore.shared.config.isModuleEnabled(id) }

    var enabled: [PopBarModule] { all.filter { isEnabled($0.id) } }

    /// 配置变化时调用：开启的启动、关闭的停止
    func apply(_ config: PopBarConfig = ConfigStore.shared.config) {
        let want = Set(all.map(\.id).filter { config.isModuleEnabled($0) })
        if want != enabledIDs { enabledIDs = want }
        for m in all {
            if want.contains(m.id), !started.contains(m.id) {
                started.insert(m.id)
                m.start()
            } else if !want.contains(m.id), started.contains(m.id) {
                started.remove(m.id)
                m.stop()
            }
        }
    }

    func stopAll() {
        for m in all where started.contains(m.id) { m.stop() }
        started.removeAll()
    }

    /// 开启模块的浮动条动作
    func barActions(for ctx: SourceContext) -> [BarAction] {
        enabled.flatMap { $0.barActions(for: ctx) }
    }

    /// 已开启模块需要的权限（辅助功能 + 输入监控永远需要：前者取词，后者听鼠标划词）
    var requiredPermissions: [PermissionKind] {
        var out: [PermissionKind] = [.accessibility, .inputMonitoring]
        for m in enabled {
            for p in m.permissions where !out.contains(p) { out.append(p) }
        }
        return PermissionKind.allCases.filter { out.contains($0) }
    }

    static func setEnabled(_ id: String, _ on: Bool) {
        var c = ConfigStore.shared.config
        c.modules[id] = on
        try? ConfigStore.shared.save(c)
    }
}
