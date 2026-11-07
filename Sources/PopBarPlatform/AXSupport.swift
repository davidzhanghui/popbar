import ApplicationServices
import Cocoa

/// AX 取词的公共设置。
///
/// 以前每次划词都对前台 App 设置 `AXEnhancedUserInterface` 且从不关闭——它会让
/// Rectangle 这类窗口管理器的动画失效、App 变慢。现在改为每个进程只设一次
/// `AXManualAccessibility`（Electron 官方支持的开关），已设过的 pid 记下来不再重复。
/// 所有 AX 调用都带 0.25 秒消息超时，前台 App 卡死时不会把主线程一起卡住。
///
/// 参考：Decklet `decklet-sys/src/ax.rs` 的 `enable_manual_accessibility`。
public enum AXSupport {
    public static let messagingTimeout: Float = 0.25
    nonisolated(unsafe) private static var enabledPIDs = Set<pid_t>()

    /// 对该进程只设一次 AXManualAccessibility；返回本次是否新设置
    @discardableResult
    public static func enableManualAccessibility(pid: pid_t) -> Bool {
        guard pid > 0, pid != getpid(), !enabledPIDs.contains(pid) else { return false }
        enabledPIDs.insert(pid)
        let app = AXUIElementCreateApplication(pid)
        AXUIElementSetMessagingTimeout(app, messagingTimeout)
        AXUIElementSetAttributeValue(app, "AXManualAccessibility" as CFString, kCFBooleanTrue)
        return true
    }

    /// 测试用：是否已经对该 pid 设置过
    public static func hasEnabled(pid: pid_t) -> Bool { enabledPIDs.contains(pid) }

    /// 进程退出后清理记录（pid 会被复用）
    public static func forget(pid: pid_t) { enabledPIDs.remove(pid) }

    /// 系统级元素（已设超时）
    public static func systemWide() -> AXUIElement {
        let el = AXUIElementCreateSystemWide()
        AXUIElementSetMessagingTimeout(el, messagingTimeout)
        return el
    }

    /// 给元素设消息超时
    public static func applyTimeout(_ el: AXUIElement) {
        AXUIElementSetMessagingTimeout(el, messagingTimeout)
    }

    public static var isTrusted: Bool { AXIsProcessTrusted() }

    @discardableResult
    public static func promptIfNeeded() -> Bool {
        let key = kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String
        return AXIsProcessTrustedWithOptions([key: true] as CFDictionary)
    }
}
