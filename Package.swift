// swift-tools-version:5.9
// PopBar 的 SwiftPM 包。分层（与 docs/refactor 2.1 一致）：
//
//   PopBarApp（可执行，main.swift）
//     └─ PopBarKit：浮动条 / Deck / 各功能模块（Features/*，通过 ModuleRegistry 注册）
//          ├─ PopBarDesign：设计令牌、组件库、Lucide 图标（只依赖 AppKit/SwiftUI）
//          ├─ PopBarPlatform：Carbon 热键、AX、剪贴板快照、屏幕定位（依赖 Core）
//          ├─ PopBarCore：不 import AppKit 的纯逻辑（Shell、快捷键解析、配置枚举与迁移、上下文识别）
//          └─ CMetrics：系统监控的 C 采集层
//
// .app 仍由 build.sh 组装；逻辑测试用 `swift test`，静态检查在 tests/run.sh。
import PackageDescription

let package = Package(
    name: "PopBar",
    platforms: [.macOS("15.0")],
    products: [
        .executable(name: "PopBar", targets: ["PopBarApp"]),
    ],
    targets: [
        .target(name: "CMetrics",
                linkerSettings: [.linkedFramework("IOKit")]),
        .target(name: "PopBarCore"),
        .target(name: "PopBarPlatform",
                dependencies: ["PopBarCore"],
                linkerSettings: [.linkedFramework("Carbon")]),
        .target(name: "PopBarDesign"),
        .target(name: "PopBarKit",
                dependencies: ["PopBarCore", "PopBarPlatform", "PopBarDesign", "CMetrics"],
                linkerSettings: [.linkedLibrary("cups"), .linkedFramework("IOKit")]),
        .executableTarget(name: "PopBarApp", dependencies: ["PopBarKit", "PopBarCore"]),
        // 截图工具：渲染真实界面生成 docs/screenshots（只在 debug 下构建）
        .executableTarget(name: "PopBarShot", dependencies: ["PopBarKit", "PopBarCore", "PopBarDesign"]),
        .testTarget(name: "PopBarCoreTests", dependencies: ["PopBarCore"], path: "tests/PopBarCoreTests"),
        .testTarget(name: "PopBarPlatformTests", dependencies: ["PopBarPlatform"], path: "tests/PopBarPlatformTests"),
        .testTarget(name: "PopBarKitTests", dependencies: ["PopBarKit", "PopBarCore", "PopBarPlatform"], path: "tests/PopBarKitTests"),
    ]
)
