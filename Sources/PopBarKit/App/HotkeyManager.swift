import Cocoa
import PopBarCore
import PopBarPlatform

/// 全局快捷键的唯一入口：配置变化时解析一次（不再每次按键都把七八个字符串重新解析），
/// 用 Carbon RegisterEventHotKey 注册——系统吞掉按键，不漏给前台 App，也不需要辅助功能权限。
/// 只注册「核心 + 已开启模块」的快捷键；注册失败的组合记下来，设置页当场标红。
@MainActor
final class HotkeyManager: ObservableObject {
    static let shared = HotkeyManager()

    struct Binding {
        let id: String
        let title: String
        let keyPath: WritableKeyPath<HotkeysConfig, String>
        let action: @MainActor () -> Void
    }

    /// 最近一次注册后的问题：重复、系统占用、注册失败
    @Published private(set) var issues: [String: HotkeyIssue] = [:]
    private var lastSignature = ""

    /// 核心快捷键（不属于任何模块）
    private var coreBindings: [Binding] {
        [
            Binding(id: "showBar", title: L10n.t("唤起浮动条", "Show Bar"), keyPath: \.showBar) {
                SelectionMonitor.shared.fetchSelectionAndShow(keyboard: true)
            },
            Binding(id: "deck", title: L10n.t("打开 / 关闭 Deck", "Toggle Deck"), keyPath: \.deck) {
                DeckController.shared.toggle()
            },
            Binding(id: "inputTranslate", title: L10n.t("输入翻译", "Type to Translate"), keyPath: \.inputTranslate) {
                TranslateTriggers.input()
            },
        ]
    }

    /// 当前应注册的全部绑定（核心 + 开启的模块）
    var bindings: [Binding] {
        coreBindings + ModuleRegistry.shared.enabled.flatMap { m in
            m.hotkeys.map { Binding(id: $0.id, title: $0.title, keyPath: $0.keyPath, action: $0.action) }
        }
    }

    /// 设置页展示用：所有快捷键（含关闭模块的，标记为未启用）
    var allBindings: [(binding: Binding, moduleEnabled: Bool)] {
        coreBindings.map { ($0, true) } + ModuleRegistry.shared.all.flatMap { m in
            m.hotkeys.map { (Binding(id: $0.id, title: $0.title, keyPath: $0.keyPath, action: $0.action),
                             ModuleRegistry.shared.isEnabled(m.id)) }
        }
    }

    /// 配置或模块开关变化时调用；内容没变就不重复注册
    func apply(force: Bool = false) {
        let hk = ConfigStore.shared.config.hotkeys
        let list = bindings
        let signature = list.map { "\($0.id)=\(hk[keyPath: $0.keyPath])" }.joined(separator: ";")
        guard force || signature != lastSignature else { return }
        lastSignature = signature

        let center = HotKeyCenter.shared
        center.unregisterAll()
        var found = HotkeyAnalysis.issues(list.map { (id: $0.id, spec: hk[keyPath: $0.keyPath]) })
        var taken = Set<KeyCombo>()
        for b in list {
            let spec = hk[keyPath: b.keyPath]
            guard let combo = KeyCombo(spec), !combo.modifiers.isEmpty, !taken.contains(combo) else { continue }
            if case .invalid = found[b.id] { continue }
            taken.insert(combo)
            let action = b.action
            if !center.register(id: b.id, combo: combo, handler: { MainActor.assumeIsolated { action() } }) {
                found[b.id] = .registrationFailed
            }
        }
        issues = found
    }

    /// 录制器开始 / 结束录制：暂停全局热键，避免录制时触发动作
    func suspend() { HotKeyCenter.shared.suspend() }
    func resume() { HotKeyCenter.shared.resume() }

    /// 给人看的问题描述
    static func describe(_ issue: HotkeyIssue, titles: [String: String]) -> String {
        switch issue {
        case .invalid: return L10n.t("无法识别，需要至少一个修饰键", "Invalid; needs at least one modifier")
        case .duplicate(let other): return L10n.t("与「\(titles[other] ?? other)」冲突", "Conflicts with \(titles[other] ?? other)")
        case .systemReserved(let who): return L10n.t("系统已占用（\(who)）", "Reserved by macOS (\(who))")
        case .registrationFailed: return L10n.t("注册失败，可能被其他 App 占用", "Registration failed; another app may own it")
        }
    }
}
