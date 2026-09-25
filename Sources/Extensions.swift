import Cocoa
import Foundation

/// #6 扩展系统:url 模板 / shell 脚本 / 快捷指令三类动作。
/// 配置见 ExtensionConfig;文本只通过 URL 参数或 stdin 传递,绝不拼进 shell 命令串。
enum Extensions {

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
                symbol: ext.symbol, color: .systemPurple) { c in
                    run(ext, ctx: c)
                }
        }
    }

    static func run(_ ext: ExtensionConfig, ctx: SourceContext) {
        let bar = FloatingBarController.shared
        switch ext.type {
        case "url":
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
        case "shell":
            bar.hide()
            runShell(ext, ctx: ctx)
        case "shortcut":
            bar.hide()
            runShortcut(ext, ctx: ctx)
        default:
            bar.showInfo(L10n.t("未知扩展类型 \(ext.type)", "Unknown extension type"))
        }
    }

    // MARK: - shell

    /// shell:command 经 /bin/sh -c 执行,文本走 stdin + 环境变量;超时 SIGKILL
    private static func runShell(_ ext: ExtensionConfig, ctx: SourceContext) {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/sh")
        process.arguments = ["-c", ext.command]
        var env = ProcessInfo.processInfo.environment
        env["POPBAR_TEXT"] = ctx.text
        env["POPBAR_APP"] = ctx.appName ?? ""
        env["POPBAR_BUNDLE_ID"] = ctx.bundleID ?? ""
        process.environment = env

        let stdin = Pipe()
        let stdout = Pipe()
        let stderr = Pipe()
        process.standardInput = stdin
        process.standardOutput = stdout
        process.standardError = stderr

        do {
            try process.run()
        } catch {
            FloatingBarController.shared.showInfo(
                L10n.t("扩展启动失败:\(error.localizedDescription)", "Extension failed to start"))
            return
        }

        // stdin 写和进程等待都放后台,避免卡住主线程/工具条
        DispatchQueue.global(qos: .userInitiated).async {
            stdin.fileHandleForWriting.write(ctx.text.data(using: .utf8) ?? Data())
            try? stdin.fileHandleForWriting.close()

            let outHandle = stdout.fileHandleForReading
            let deadline = Date().addingTimeInterval(ext.timeout)
            var timedOut = false
            while process.isRunning {
                if Date() > deadline {
                    timedOut = true
                    kill(process.processIdentifier, SIGKILL)
                    break
                }
                Thread.sleep(forTimeInterval: 0.05)
            }
            let data = outHandle.readDataToEndOfFile()
            let output = String(data: data, encoding: .utf8)?
                .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""

            DispatchQueue.main.async {
                if timedOut {
                    FloatingBarController.shared.showInfo(
                        L10n.t("扩展超时已终止(\(Int(ext.timeout))s)", "Extension timed out"))
                    return
                }
                deliver(output, mode: ext.output, ctx: ctx)
            }
        }
    }

    // MARK: - shortcut

    /// shortcut:`shortcuts run "名称" -i -`(stdin 传文本)
    private static func runShortcut(_ ext: ExtensionConfig, ctx: SourceContext) {
        var e = ext
        e.command = "/usr/bin/shortcuts run \(shellQuote(ext.shortcut)) -i -"
        e.output = ext.output == "none" ? "none" : ext.output
        runShell(e, ctx: ctx)
    }

    private static func shellQuote(_ s: String) -> String {
        "'" + s.replacingOccurrences(of: "'", with: "'\\''") + "'"
    }

    // MARK: - 结果分发

    private static func deliver(_ output: String, mode: String, ctx: SourceContext) {
        switch mode {
        case "copy":
            PasteboardGuard.write(output)
            FloatingBarController.shared.showInfo(
                L10n.t("已复制扩展结果", "Extension result copied"))
        case "replace":
            TextReplacer.replaceInline(output)
        case "show", "panel":
            OutputPanel.show(text: output, title: L10n.t("扩展结果", "Extension result"))
        default:
            if !output.isEmpty {
                FloatingBarController.shared.showInfo(output)
            }
        }
    }
}

/// shell/shortcut 结果的轻量展示窗口
enum OutputPanel {
    private static var window: NSWindow?

    static func show(text: String, title: String) {
        if window == nil {
            let w = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 420, height: 240),
                             styleMask: [.titled, .closable, .resizable],
                             backing: .buffered, defer: false)
            w.isReleasedWhenClosed = false
            let scroll = NSScrollView(frame: w.contentView!.bounds)
            scroll.autoresizingMask = [.width, .height]
            let tv = NSTextView(frame: scroll.bounds)
            tv.isEditable = false
            tv.font = .systemFont(ofSize: 12)
            tv.textContainerInset = NSSize(width: 8, height: 8)
            tv.autoresizingMask = [.width]
            scroll.documentView = tv
            scroll.hasVerticalScroller = true
            w.contentView = scroll
            window = w
        }
        window?.title = title
        (window?.contentView as? NSScrollView)?.documentView
            .flatMap { $0 as? NSTextView }?.string = text
        window?.center()
        NSApp.activateForUI()          // accessory 应用不激活就看不到窗口
        window?.orderFrontRegardless() // 兜底:即使激活被系统忽略也排到最前
        window?.makeKeyAndOrderFront(nil)
    }
}
