import Foundation
import PopBarCore

/// 提权执行的结构化结果：区分成功、用户取消授权与真正失败。
enum AdminRunResult: Equatable {
    case success(output: String)
    case cancelled
    case failure(String)
}

/// 兼容层：保留老的 (status, out, err) 元组接口，内部全部走 PopBarCore.Shell（唯一的子进程封装）。
/// 超时：-2；启动失败：-1。只在后台线程调用。
enum ShellRun {
    typealias Result = (status: Int32, out: String, err: String)

    static func run(_ path: String, _ args: [String], timeout: TimeInterval = 60) -> Result {
        let o = Shell.run(path, args, timeout: timeout)
        return (o.code, o.text, o.ok ? o.stderr : (o.stderr.isEmpty ? o.error : o.stderr))
    }

    /// 同 run，但 stdout 保持原始字节（截图等二进制输出）
    static func runData(_ path: String, _ args: [String], timeout: TimeInterval = 60) -> (status: Int32, out: Data, err: String) {
        let o = Shell.run(path, args, timeout: timeout, maxOutput: 64 << 20)
        return (o.code, o.stdout, o.ok ? o.stderr : (o.stderr.isEmpty ? o.error : o.stderr))
    }

    /// AppleScript 取消授权的标准结尾错误码为 `(-128)`，避免任意位置出现 `-128` 误判。
    static func isAdminCancelled(_ stderr: String) -> Bool {
        stderr.trimmingCharacters(in: .whitespacesAndNewlines).hasSuffix("(-128)")
    }

    /// 清洗 AppleScript `execution error:` 定位前缀与末尾退出码噪点，保留核心可读错误。
    static func cleanAdminError(_ stderr: String) -> String {
        var s = stderr.trimmingCharacters(in: .whitespacesAndNewlines)
        if let r = s.range(of: #"^\d+:\d+:\s*execution error:\s*"#, options: .regularExpression) {
            s.removeSubrange(r)
        } else if let r = s.range(of: #"^execution error:\s*"#, options: .regularExpression) {
            s.removeSubrange(r)
        }
        if let r = s.range(of: #"\s*\(-?\d+\)\s*$"#, options: .regularExpression) {
            s.removeSubrange(r)
        }
        return s.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    static func escapeAppleScriptString(_ s: String) -> String {
        s.replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "\"", with: "\\\"")
    }

    /// 构造带管理员权限提示的 AppleScript；拒绝包含换行符的多行命令输入。
    /// 附带 `without altering line endings` 防止 AppleScript 默认把 stdout 中的 `\n` 转成 `\r`。
    static func buildAdminScript(shell: String, prompt: String?) -> String? {
        guard !shell.contains("\n"), !shell.contains("\r") else { return nil }
        let escapedShell = escapeAppleScriptString(shell)
        if let prompt, !prompt.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            let cleanPrompt = prompt.replacingOccurrences(of: "\n", with: " ").replacingOccurrences(of: "\r", with: " ")
            return "do shell script \"\(escapedShell)\" with prompt \"\(escapeAppleScriptString(cleanPrompt))\" with administrator privileges without altering line endings"
        }
        return "do shell script \"\(escapedShell)\" with administrator privileges without altering line endings"
    }

    /// 以管理员权限运行固定的 shell 命令（系统弹出密码框），返回结构化结果。
    /// 只允许传入代码内的常量命令，不要拼接任何外部输入。
    /// 注意：超时仅能终止 `osascript` 客户端进程，已由系统授权启动的 root 子进程不受普通用户信号控制。
    static func runAsAdminResult(_ shell: String, prompt: String? = nil, timeout: TimeInterval = 900) -> AdminRunResult {
        guard let script = buildAdminScript(shell: shell, prompt: prompt) else {
            return .failure(L10n.t("无效的管理员命令", "Invalid administrator command"))
        }
        let r = run("/usr/bin/osascript", ["-e", script], timeout: timeout)
        if r.status == 0 { return .success(output: r.out) }
        if isAdminCancelled(r.err) { return .cancelled }
        let cleaned = cleanAdminError(r.err)
        return .failure(cleaned.isEmpty ? L10n.t("执行失败", "Failed") : cleaned)
    }

    /// 兼容旧接口：nil 表示成功，否则为错误或取消描述。
    static func runAsAdmin(_ shell: String, prompt: String? = nil, timeout: TimeInterval = 900) -> String? {
        switch runAsAdminResult(shell, prompt: prompt, timeout: timeout) {
        case .success:
            return nil
        case .cancelled:
            return L10n.t("已取消授权", "Authorization cancelled")
        case .failure(let msg):
            return msg
        }
    }
}
