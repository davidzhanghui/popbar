import Cocoa
import Foundation
import PopBarCore
import PopBarPlatform
import PopBarDesign

/// 把 @MainActor 的回调包成普通闭包:AppKit 控件(@objc action / Timer)都在主线程但类型上未隔离
func mainClosure(_ body: @escaping @MainActor () -> Void) -> () -> Void {
    { Task { @MainActor in body() } }
}

/// #6 扩展系统:url 模板 / shell 脚本 / 快捷指令三类动作。
/// 配置见 ExtensionConfig;文本只通过 URL 参数或 stdin 传递,绝不拼进 shell 命令串。
enum Extensions {

    /// 扩展图标：配置里存 Lucide 名；v2 配置里的 SF Symbols 名在这里映射，未知的落到拼图
    static func lucideIcon(_ name: String) -> String {
        if Lucide.has(name) { return name }
        let map: [String: String] = [
            "puzzlepiece.extension": "puzzle", "magnifyingglass": "search", "globe": "globe", "terminal": "terminal",
            "doc.on.doc": "copy", "link": "link", "book": "book-open", "cat": "git-branch", "star": "star",
            "bolt": "zap", "text.bubble": "message-square", "character.book.closed": "book-open", "wand.and.stars": "wand-sparkles",
        ]
        return map[name] ?? "puzzle"
    }

    /// 设置页可选的扩展图标
    static let iconChoices = ["puzzle", "search", "globe", "terminal", "code", "link", "book-open", "git-branch",
                              "star", "zap", "message-square", "wand-sparkles", "file-text", "send", "bot", "hammer"]

    /// 生成当前上下文可用的扩展动作(match 正则、apps 白名单过滤)
    static func barActions(for ctx: SourceContext? = nil) -> [BarAction] {
        let config = ConfigStore.shared.config
        return config.extensions.filter { $0.enabled }.compactMap { ext in
            // apps 白名单:非空且当前应用不在列表 → 不出现
            if let ctx, !ext.apps.isEmpty,
               let bid = ctx.bundleID, !ext.apps.contains(bid) { return nil }
            if let ctx, !ext.match.isEmpty,
               ctx.text.range(of: ext.match, options: .regularExpression) == nil { return nil }
            return BarAction(
                id: "ext.\(ext.id)", title: ext.name,
                icon: Extensions.lucideIcon(ext.symbol)) { c in
                    run(ext, ctx: c)
                }
        }
    }

    static func run(_ ext: ExtensionConfig, ctx: SourceContext) {
        let bar = FloatingBarController.shared
        switch ext.type {
        case .url:
            let enc = ctx.text.addingPercentEncoding(
                withAllowedCharacters: .urlQueryAllowed) ?? ""
            let url = ext.template
                .replacingOccurrences(of: "{text}", with: enc)
                .replacingOccurrences(of: "{rawtext}", with: ctx.text)
            if url.hasPrefix("popbar://") {
                // 内置协议:popbar://search 等(留作扩展)
                return
            }
            if let u = URL(string: url) {
                bar.hide()
                NSWorkspace.shared.open(u)
            }
        case .shell:
            bar.hide()
            runShell(ext, ctx: ctx)
        case .shortcut:
            bar.hide()
            runShortcut(ext, ctx: ctx)
        }
    }

    // MARK: - shell

    /// shell:command 经 /bin/sh -c 执行,文本走 stdin + 环境变量。
    /// 走统一的 Shell：stdout/stderr 并发读完（大输出不再卡死后误报超时），
    /// 超时杀整个进程组，脚本不读 stdin 就退出也不会因 SIGPIPE 带崩 App。
    static func runShell(_ ext: ExtensionConfig, ctx: SourceContext) {
        let env = ["POPBAR_TEXT": ctx.text, "POPBAR_APP": ctx.appName ?? "", "POPBAR_BUNDLE_ID": ctx.bundleID ?? ""]
        let input = Data(ctx.text.utf8)
        DispatchQueue.global(qos: .userInitiated).async {
            let o = Shell.sh(ext.command, stdin: input, environment: env, timeout: ext.timeout)
            let output = o.text.trimmingCharacters(in: .whitespacesAndNewlines)
            DispatchQueue.main.async {
                switch o.status {
                case .timedOut:
                    FloatingBarController.shared.showInfo(
                        L10n.t("扩展超时已终止（\(Int(ext.timeout)) 秒）", "Extension timed out (\(Int(ext.timeout))s)"))
                case .spawnFailed:
                    FloatingBarController.shared.showInfo(L10n.t("扩展启动失败：", "Extension failed to start: ") + o.error)
                default:
                    deliver(output, mode: ext.output, ctx: ctx)
                }
            }
        }
    }

    // MARK: - shortcut

    /// shortcut:`shortcuts run "名称" -i -`(stdin 传文本)
    private static func runShortcut(_ ext: ExtensionConfig, ctx: SourceContext) {
        var e = ext
        e.command = "/usr/bin/shortcuts run \(Shell.quote(ext.shortcut)) -i -"
        runShell(e, ctx: ctx)
    }

    // MARK: - 结果分发

    private static func deliver(_ output: String, mode: ExtensionOutput, ctx: SourceContext) {
        switch mode {
        case .copy:
            PasteboardGuard.write(output)
            FloatingBarController.shared.showInfo(
                L10n.t("已复制扩展结果", "Extension result copied"))
        case .replace:
            TextReplacer.replaceInline(output)
        case .show, .panel:
            MainActor.assumeIsolated {
                ResultCard.shared.show(title: L10n.t("扩展结果", "Extension Result"), text: output, anchor: ctx.bounds)
            }
        case .none:
            if !output.isEmpty {
                FloatingBarController.shared.showInfo(output)
            }
        }
    }
}
