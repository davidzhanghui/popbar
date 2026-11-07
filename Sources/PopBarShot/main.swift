import Cocoa
import PopBarKit

// 文档截图工具：离屏渲染 PopBar 各界面，写到 docs/screenshots/<模块>-<状态>[-dark].png。
// 用法：swift run PopBarShot [输出目录] [只截某个前缀，如 bar]
// 配置读写指向临时目录，不影响本机正在用的 PopBar。
let tmp = NSTemporaryDirectory() + "popbar-shot-\(ProcessInfo.processInfo.processIdentifier)"
try? FileManager.default.createDirectory(atPath: tmp, withIntermediateDirectories: true)
setenv("POPBAR_CONFIG_DIR", tmp, 1)
setenv("POPBAR_LANG", "zh", 1)

let args = CommandLine.arguments
let outDir = args.count > 1 ? args[1] : "docs/screenshots"
let only = args.count > 2 ? args[2] : nil

let app = NSApplication.shared
app.setActivationPolicy(.accessory)
// 直接运行的可执行文件没有 bundle 图标，Deck 侧栏会显示成文件夹；用仓库里的 AppIcon
if let icon = NSImage(contentsOfFile: "Resources/AppIcon.icns") { app.applicationIconImage = icon }
Task { @MainActor in
    await PopBarShots.run(outDir: outDir, only: only)
    try? FileManager.default.removeItem(atPath: tmp)
    exit(0)
}
app.run()
