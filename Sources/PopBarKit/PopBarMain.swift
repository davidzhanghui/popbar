import Cocoa
import PopBarCore
import PopBarPlatform
import PopBarDesign

/// App 入口（main.swift 只调这一行）
public enum PopBarMain {
    public static func run() {
        // 写往已关闭管道时返回 EPIPE，而不是让整个 App 被 SIGPIPE 杀掉（扩展脚本不读 stdin 就退出的场景）
        Shell.ignoreSIGPIPE()
        let app = NSApplication.shared
        app.setActivationPolicy(.accessory)
        let delegate = AppDelegate()
        app.delegate = delegate
        withExtendedLifetime(delegate) { app.run() }
    }
}
