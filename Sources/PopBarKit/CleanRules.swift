import Foundation
import PopBarCore
import PopBarPlatform
import PopBarDesign

/// 编译期内置的扫描与安全保护规则（A 档：不含需要 root 的系统数据）
enum CleanRules {

    // MARK: - 绝对保护红线（扫描器与 CleanPathGuard 双重拦截）

    /// 永不进入清理清单且执行期强制拒绝的目录/文件名（精确匹配，大小写敏感与小写兜底均检查）
    static let protectedNames: Set<String> = [
        // 自身与 Safari
        "dev.popbar.app", "PopBar",
        "com.apple.Safari", "com.apple.Safari.SafeBrowsing",
        // Apple 系统高危/TCC 受保护缓存（含非 com.apple.* 命名）
        "CloudKit", "FamilyCircle", "familycircled",
        "GeoServices", "PassKit", "Animoji", "askpermissiond",
        "AudioUnitCache", "Metadata", "VoiceTrigger", "SiriTTS",
        "Trial", "Biome", "Knowledge",
        "com.apple.TCC", "com.apple.HomeKit", "com.apple.homed",
        "com.apple.bird", "com.apple.containermanagerd",
        "com.apple.akd", "com.apple.accountsd",
        "com.apple.AppleMediaServices", "com.apple.Music",
        "com.apple.ProtectedCloudStorage", "com.apple.iCloudHelper",
        "com.apple.cloudd", "com.apple.ap.adprivacyd",
        "com.apple.nsurlsessiond",
        // 凭证/密钥相关
        "docker-secrets-engine", "com.docker.docker",
    ]

    static let protectedNamesLower: Set<String> = Set(protectedNames.map { $0.lowercased() })

    /// 永不清理的名称前缀（覆盖带随机后缀或细分服务的 Apple 系统元数据与 TCC 缓存）
    static let protectedPrefixes: [String] = [
        "AAProfilePicture_",
        "com.apple.Safari.",
        "com.apple.TCC",
        "com.apple.HomeKit",
        "com.apple.findmy.",
        "com.apple.iCloud",
        "com.apple.CloudKit",
        "com.apple.siri.",
        "com.apple.tiswitcher",
        "com.apple.preferencepanes",
        "com.apple.systemsettings",
        "com.apple.nsservicescache",
    ]

    /// 绝对禁止整目录删除的 ~/Library/Application Support 顶层目录名（防止误伤核心用户数据）
    static let protectedAppSupportNames: Set<String> = [
        "Apple", "Google", "Mozilla", "Firefox", "Microsoft", "Microsoft Edge",
        "BraveSoftware", "Arc", "Chromium", "Code", "Cursor", "Antigravity",
        "Claude", "Slack", "discord", "LarkShell", "Notion", "obsidian",
        "MobileSync", "AddressBook", "CallHistoryDB", "CloudDocs", "Dock",
        "FileProvider", "iCloud", "Knowledge", "SyncServices", "1Password",
        "Bitwarden", "Dashlane", "KeePassXC", "Raycast", "Alfred", "PopBar",
    ]

    static func isProtectedName(_ name: String) -> Bool {
        if protectedNames.contains(name) || protectedNamesLower.contains(name.lowercased()) { return true }
        let lower = name.lowercased()
        return protectedPrefixes.contains { lower.hasPrefix($0.lowercased()) }
    }

    // MARK: - AI 工具缓存（~/.cache 与 ~/Library/Caches 共享）

    /// 可安全重建的 AI 工具纯缓存
    static let aiSafeCacheNames: Set<String> = [
        "claude", "claude-code", "claude-cli-nodejs",
        "cursor-agent", "copilot", "devin", "opencode",
        "codex", "chrome-devtools-mcp", "amp", "goose", "aider", "mcp",
        "antigravity", "com.google.antigravity",
        "com.anthropic.claudefordesktop", "com.anthropic.claudefordesktop.ShipIt",
        "ai.opencode.desktop", "ai.opencode.desktop.ShipIt",
        "@opencode-aidesktop-updater", "@deepseek-aidsh-desktop-updater",
    ]

    /// AI 模型权重或重下成本较高的运行时缓存（默认不勾选）
    static let aiReviewCacheNames: Set<String> = [
        "torch", "ollama", "whisper", "comfyui",
        "lm-studio", "lmstudio", "audioseal", "codex-runtimes",
    ]

    /// 兼容旧访问名（全部已知 AI 缓存目录名，大小写不敏感查表请走辅助方法）
    static let aiCacheNames: Set<String> = aiSafeCacheNames.union(aiReviewCacheNames)

    private static let aiSafeLower: Set<String> = Set(aiSafeCacheNames.map { $0.lowercased() })
    private static let aiReviewLower: Set<String> = Set(aiReviewCacheNames.map { $0.lowercased() })

    // MARK: - 开发工具缓存（~/.cache 与 ~/Library/Caches 共享）

    /// 可快速重建的构建与下载缓存（默认勾选）
    static let devSafeCacheNames: Set<String> = [
        "nix", "pnpm", "yarn", "go-build", "uv", "pip",
        "node-gyp", "node", "fontconfig", "pre-commit",
        "poetry", "pypoetry", "mypy", "black", "ruff", "swc", "turbo",
        "parcel-bundler", "vite", "webpack", "gradle", "cocoapods",
        "swiftpm", "org.swift.swiftpm", "terraform", "deno", "bun",
        "composer", "gem", "ruby", "gh", "prisma", "prisma-python",
        "typescript", "puccinialin", "homebrew", "com.apple.dt.xcode",
    ]

    /// 浏览器二进制、IDE 全量索引或大依赖仓库（默认不勾选）
    static let devReviewCacheNames: Set<String> = [
        "ms-playwright", "playwright", "puppeteer", "cypress",
        "electron", "electron-builder", "pnpm-store", "jetbrains",
    ]

    static let devCacheNames: Set<String> = devSafeCacheNames.union(devReviewCacheNames)

    private static let devSafeLower: Set<String> = Set(devSafeCacheNames.map { $0.lowercased() })
    private static let devReviewLower: Set<String> = Set(devReviewCacheNames.map { $0.lowercased() })

    /// 根据目录名分类（同时服务 ~/.cache 和 ~/Library/Caches）
    static func classifyKnownToolCache(_ name: String) -> (category: CleanCategory, safety: CleanSafety, hint: String?)? {
        let lower = name.lowercased()
        if aiReviewLower.contains(lower) {
            let hint = lower == "codex-runtimes"
                ? L10n.t("AI 运行时缓存，删除后需重新下载", "AI runtime cache, re-downloaded after removal")
                : L10n.t("模型缓存，删除后需重新下载", "Model cache, re-downloaded after removal")
            return (.aiTools, .review, hint)
        }
        if aiSafeLower.contains(lower) {
            return (.aiTools, .safe, nil)
        }
        if devReviewLower.contains(lower) {
            let hint: String
            if lower == "jetbrains" {
                hint = L10n.t("IDE 索引缓存，删除后打开项目需重新建立索引", "IDE index cache; projects will re-index on next launch")
            } else if ["ms-playwright", "playwright", "puppeteer", "cypress"].contains(lower) {
                hint = L10n.t("自动化浏览器二进制，删除后需重新下载", "Browser binaries for automation; re-downloaded after removal")
            } else {
                hint = L10n.t("依赖或运行时缓存，删除后需重新下载", "Dependency or runtime cache; re-downloaded after removal")
            }
            return (.developerTools, .review, hint)
        }
        if devSafeLower.contains(lower) {
            return (.developerTools, .safe, nil)
        }
        return nil
    }

    // MARK: - 开发工具固定路径（相对 home）

    struct DevPathRule: Sendable {
        let path: String
        let safety: CleanSafety
        let name: String?
        let hint: String?
        let lockBundles: [String]
        let lockProcesses: [String]

        init(_ path: String, safety: CleanSafety, name: String? = nil, hint: String? = nil,
             lockBundles: [String] = [], lockProcesses: [String] = []) {
            self.path = path
            self.safety = safety
            self.name = name
            self.hint = hint
            self.lockBundles = lockBundles
            self.lockProcesses = lockProcesses
        }
    }

    /// 开发工具固定缓存路径（相对 home）。.npm/_cacache 不在这里，走引用图清理。
    /// 统一约定：纯构建产物/临时下载为 .safe；大型依赖仓库与归档包为 .review（默认不勾选）。
    static let developerPaths: [DevPathRule] = [
        // Xcode & 模拟器（Xcode 或 xcodebuild 运行时锁定）
        DevPathRule("Library/Developer/Xcode/DerivedData", safety: .safe,
                    hint: L10n.t("Xcode 构建产物，可自动重建", "Xcode build products, rebuilt automatically"),
                    lockBundles: ["com.apple.dt.Xcode"], lockProcesses: ["xcodebuild", "swift-frontend"]),
        DevPathRule("Library/Developer/Xcode/iOS DeviceSupport", safety: .safe,
                    hint: L10n.t("iOS 真机符号缓存，连接设备后重新生成", "iOS device symbols, regenerated when a device connects"),
                    lockBundles: ["com.apple.dt.Xcode"]),
        DevPathRule("Library/Developer/Xcode/watchOS DeviceSupport", safety: .safe,
                    hint: L10n.t("watchOS 真机符号缓存，连接设备后重新生成", "watchOS device symbols, regenerated when a device connects"),
                    lockBundles: ["com.apple.dt.Xcode"]),
        DevPathRule("Library/Developer/Xcode/tvOS DeviceSupport", safety: .safe,
                    hint: L10n.t("tvOS 真机符号缓存，连接设备后重新生成", "tvOS device symbols, regenerated when a device connects"),
                    lockBundles: ["com.apple.dt.Xcode"]),
        DevPathRule("Library/Developer/Xcode/visionOS DeviceSupport", safety: .safe,
                    hint: L10n.t("visionOS 真机符号缓存，连接设备后重新生成", "visionOS device symbols, regenerated when a device connects"),
                    lockBundles: ["com.apple.dt.Xcode"]),
        DevPathRule("Library/Developer/Xcode/Products", safety: .safe,
                    hint: L10n.t("Xcode 中间构建产物，可自动重建", "Xcode intermediate build products, rebuilt automatically"),
                    lockBundles: ["com.apple.dt.Xcode"], lockProcesses: ["xcodebuild"]),
        DevPathRule("Library/Developer/Xcode/UserData/Previews", safety: .safe,
                    hint: L10n.t("SwiftUI 预览缓存，打开预览时重新生成", "SwiftUI Preview caches, regenerated on use"),
                    lockBundles: ["com.apple.dt.Xcode"]),
        DevPathRule("Library/Developer/Xcode/DocumentationCache", safety: .safe,
                    lockBundles: ["com.apple.dt.Xcode"]),
        DevPathRule("Library/Developer/Xcode/SourcePackages", safety: .review,
                    hint: L10n.t("Swift 包缓存，重新构建时需重新解析下载", "Swift package cache, re-resolved on next build"),
                    lockBundles: ["com.apple.dt.Xcode"], lockProcesses: ["xcodebuild", "swift-package"]),
        DevPathRule("Library/Developer/Xcode/Archives", safety: .review,
                    hint: L10n.t("应用归档包，含历史发布版本与 dSYM，请确认后再删", "App archives with release builds and dSYMs; review before removing"),
                    lockBundles: ["com.apple.dt.Xcode"]),
        DevPathRule("Library/Developer/DVTDownloads", safety: .safe,
                    lockBundles: ["com.apple.dt.Xcode"]),
        DevPathRule("Library/Developer/XCTestDevices", safety: .safe,
                    lockBundles: ["com.apple.dt.Xcode", "com.apple.iphonesimulator"]),
        DevPathRule("Library/Developer/XCPGDevices", safety: .safe,
                    lockBundles: ["com.apple.dt.Xcode"]),
        DevPathRule("Library/Developer/CoreSimulator/Caches", safety: .safe,
                    lockBundles: ["com.apple.dt.Xcode", "com.apple.iphonesimulator"]),

        // 可快速重建的包下载/临时执行缓存（.safe）
        DevPathRule("Library/Caches/Homebrew", safety: .safe,
                    hint: L10n.t("Homebrew 下载安装包缓存，不影响已安装软件", "Homebrew download cache; installed formulae are kept"),
                    lockProcesses: ["brew"]),
        DevPathRule(".bun/install/cache", safety: .safe,
                    name: L10n.t("Bun 安装缓存", "Bun Install Cache"),
                    lockProcesses: ["bun"]),
        DevPathRule(".yarn/cache", safety: .safe,
                    name: L10n.t("Yarn 缓存", "Yarn Cache"),
                    lockProcesses: ["yarn"]),
        DevPathRule(".yarn/berry/cache", safety: .safe,
                    name: L10n.t("Yarn Berry 缓存", "Yarn Berry Cache"),
                    lockProcesses: ["yarn"]),
        DevPathRule(".npm/_npx", safety: .safe,
                    name: L10n.t("npx 临时缓存", "npx Temporary Cache"),
                    hint: L10n.t("npx 临时下载的 CLI 包缓存，可按需重新拉取", "Temporary CLI packages downloaded by npx"),
                    lockProcesses: ["npm", "npx", "node"]),
        DevPathRule(".gradle/daemon", safety: .safe,
                    name: L10n.t("Gradle 守护进程日志", "Gradle Daemon Logs"),
                    lockProcesses: ["gradle", "GradleDaemon"]),
        DevPathRule(".android/cache", safety: .safe,
                    name: L10n.t("Android 工具缓存", "Android Tool Cache")),
        DevPathRule(".android/build-cache", safety: .safe,
                    name: L10n.t("Android 构建缓存", "Android Build Cache")),
        DevPathRule(".composer/cache", safety: .safe,
                    name: L10n.t("Composer 缓存", "Composer Cache"),
                    lockProcesses: ["composer"]),

        // 大型依赖仓库（统一 .review：重下成本高，默认不勾选）
        DevPathRule(".cargo/registry", safety: .review,
                    name: L10n.t("Cargo 依赖仓库", "Cargo Registry"),
                    hint: L10n.t("Rust 依赖缓存，重新构建时需重新下载", "Rust crate cache, re-downloaded on next build"),
                    lockProcesses: ["cargo", "rustc"]),
        DevPathRule(".cargo/git", safety: .review,
                    name: L10n.t("Cargo Git 依赖", "Cargo Git Cache"),
                    hint: L10n.t("Rust Git 依赖缓存，重新构建时需重新拉取", "Rust Git dependencies, re-fetched on next build"),
                    lockProcesses: ["cargo", "rustc"]),
        DevPathRule(".gradle/caches", safety: .review,
                    name: L10n.t("Gradle 依赖缓存", "Gradle Caches"),
                    hint: L10n.t("Gradle 构建与依赖缓存，首次构建需重新下载", "Gradle dependency cache, re-downloaded on first build"),
                    lockProcesses: ["gradle", "GradleDaemon"]),
        DevPathRule(".gradle/wrapper/dists", safety: .review,
                    name: L10n.t("Gradle Wrapper 分发包", "Gradle Wrapper Dists"),
                    hint: L10n.t("Gradle 运行时压缩包，首次构建需重新下载", "Gradle runtime distributions, re-downloaded on first build"),
                    lockProcesses: ["gradle", "GradleDaemon"]),
        DevPathRule(".m2/repository", safety: .review,
                    name: L10n.t("Maven 本地仓库", "Maven Repository"),
                    hint: L10n.t("Maven 依赖缓存，首次构建需重新下载", "Maven dependency cache, re-downloaded on first build"),
                    lockProcesses: ["mvn"]),
        DevPathRule(".ivy2/cache", safety: .review,
                    name: L10n.t("Ivy 依赖缓存", "Ivy Cache"),
                    hint: L10n.t("Ivy/SBT 依赖缓存，重新构建时需重新下载", "Ivy/SBT dependency cache, re-downloaded on next build")),
        DevPathRule(".pub-cache", safety: .review,
                    name: L10n.t("Pub 依赖缓存", "Pub Cache"),
                    hint: L10n.t("Dart/Flutter 包缓存，首次构建需重新下载", "Dart/Flutter package cache, re-downloaded on first build"),
                    lockProcesses: ["dart", "flutter"]),
        DevPathRule("go/pkg/mod", safety: .review,
                    name: L10n.t("Go 模块缓存", "Go Module Cache"),
                    hint: L10n.t("Go 模块缓存，首次构建需重新下载", "Go module cache, re-downloaded on first build"),
                    lockProcesses: ["go"]),
        DevPathRule("Library/pnpm/store", safety: .review,
                    name: L10n.t("pnpm 全局存储", "pnpm Global Store"),
                    hint: L10n.t("pnpm 依赖内容仓库，删除后安装依赖需重新下载", "pnpm content-addressable store, re-downloaded on install"),
                    lockProcesses: ["pnpm"]),
        DevPathRule(".pnpm-store", safety: .review,
                    name: L10n.t("pnpm 全局存储", "pnpm Store"),
                    hint: L10n.t("pnpm 依赖内容仓库，删除后安装依赖需重新下载", "pnpm content-addressable store, re-downloaded on install"),
                    lockProcesses: ["pnpm"]),
        DevPathRule(".conda/pkgs", safety: .review,
                    name: L10n.t("Conda 包缓存", "Conda Package Cache"),
                    hint: L10n.t("Conda 压缩包缓存，重建环境时需重新下载", "Conda package cache, re-downloaded when creating envs"),
                    lockProcesses: ["conda", "mamba"]),
    ]

    static let npmCachePath = ".npm/_cacache"

    // MARK: - Chromium / Electron 定点安全子缓存（位于 Application Support 内，默认 .review 不勾选）

    struct AppSubCacheRule: Sendable {
        let appName: String
        /// 相对 ~/Library/Application Support 的路径
        let baseRelPath: String
        /// 是否按 Chromium 多 Profile（Default / Profile *）展开
        let hasProfiles: Bool
        let subDirs: [String]
        let lockBundles: [String]
        let lockProcesses: [String]
    }

    static let chromiumSubDirs = [
        "Service Worker/CacheStorage",
        "Cache",
        "Code Cache",
        "GPUCache",
        "DawnGraphiteCache",
        "DawnWebGPUCache",
    ]

    static let electronSubDirs = [
        "Cache",
        "CachedData",
        "Code Cache",
        "GPUCache",
        "DawnGraphiteCache",
        "DawnWebGPUCache",
        "Service Worker/CacheStorage",
    ]

    static let appSupportSubCacheRules: [AppSubCacheRule] = [
        AppSubCacheRule(appName: "Google Chrome", baseRelPath: "Google/Chrome", hasProfiles: true,
                        subDirs: chromiumSubDirs, lockBundles: ["com.google.Chrome"], lockProcesses: ["Google Chrome"]),
        AppSubCacheRule(appName: "Chrome Canary", baseRelPath: "Google/Chrome Canary", hasProfiles: true,
                        subDirs: chromiumSubDirs, lockBundles: ["com.google.Chrome.canary"], lockProcesses: ["Google Chrome Canary"]),
        AppSubCacheRule(appName: "Microsoft Edge", baseRelPath: "Microsoft Edge", hasProfiles: true,
                        subDirs: chromiumSubDirs, lockBundles: ["com.microsoft.edgemac"], lockProcesses: ["Microsoft Edge"]),
        AppSubCacheRule(appName: "Brave", baseRelPath: "BraveSoftware/Brave-Browser", hasProfiles: true,
                        subDirs: chromiumSubDirs, lockBundles: ["com.brave.Browser"], lockProcesses: ["Brave Browser"]),
        AppSubCacheRule(appName: "Arc", baseRelPath: "Arc/User Data", hasProfiles: true,
                        subDirs: chromiumSubDirs, lockBundles: ["company.thebrowser.Browser"], lockProcesses: ["Arc"]),
        AppSubCacheRule(appName: "VS Code", baseRelPath: "Code", hasProfiles: false,
                        subDirs: electronSubDirs, lockBundles: ["com.microsoft.VSCode"], lockProcesses: ["Electron", "Code"]),
        AppSubCacheRule(appName: "Cursor", baseRelPath: "Cursor", hasProfiles: false,
                        subDirs: electronSubDirs, lockBundles: ["com.todesktop.230313mzl4w4u92"], lockProcesses: ["Cursor"]),
        AppSubCacheRule(appName: "Antigravity", baseRelPath: "Antigravity", hasProfiles: false,
                        subDirs: electronSubDirs, lockBundles: ["com.google.antigravity"], lockProcesses: ["Antigravity"]),
        AppSubCacheRule(appName: "Slack", baseRelPath: "Slack", hasProfiles: false,
                        subDirs: electronSubDirs, lockBundles: ["com.tinyspeck.slackmacgap"], lockProcesses: ["Slack"]),
        AppSubCacheRule(appName: "Discord", baseRelPath: "discord", hasProfiles: false,
                        subDirs: electronSubDirs, lockBundles: ["com.hnc.Discord"], lockProcesses: ["Discord"]),
        AppSubCacheRule(appName: "Lark / 飞书", baseRelPath: "LarkShell", hasProfiles: false,
                        subDirs: electronSubDirs, lockBundles: ["com.electron.lark", "com.bytedance.lark", "com.larksuite"],
                        lockProcesses: ["Lark", "Feishu"]),
        AppSubCacheRule(appName: "Notion", baseRelPath: "Notion", hasProfiles: false,
                        subDirs: electronSubDirs, lockBundles: ["notion.id"], lockProcesses: ["Notion"]),
        AppSubCacheRule(appName: "Obsidian", baseRelPath: "obsidian", hasProfiles: false,
                        subDirs: electronSubDirs, lockBundles: ["md.obsidian"], lockProcesses: ["Obsidian"]),
        AppSubCacheRule(appName: "Claude", baseRelPath: "Claude", hasProfiles: false,
                        subDirs: electronSubDirs, lockBundles: ["com.anthropic.claudefordesktop"], lockProcesses: ["Claude"]),
    ]

    // MARK: - 目录名 -> 运行中锁定映射（解决非 Bundle ID 命名的缓存无法加锁的问题）

    struct LockRule: Sendable {
        let bundlePrefixes: [String]
        let processNames: [String]
    }

    static let directoryLockRules: [String: LockRule] = [
        "google": LockRule(bundlePrefixes: ["com.google.chrome", "com.google.googledrive"], processNames: ["google chrome"]),
        "chromium": LockRule(bundlePrefixes: ["org.chromium.chromium"], processNames: ["chromium"]),
        "larkshell": LockRule(bundlePrefixes: ["com.electron.lark", "com.bytedance.lark", "com.larksuite"], processNames: ["lark", "feishu"]),
        "jetbrains": LockRule(bundlePrefixes: ["com.jetbrains."],
                              processNames: ["idea", "pycharm", "webstorm", "goland", "clion", "rider", "datagrip", "phpstorm", "rubymine", "studio"]),
        "doubao": LockRule(bundlePrefixes: ["com.bytedance.doubao", "com.volcengine.doubao"], processNames: ["doubao", "豆包"]),
        "docker desktop": LockRule(bundlePrefixes: ["com.docker.docker"], processNames: ["docker", "com.docker.backend"]),
        "quarkclouddrive": LockRule(bundlePrefixes: ["com.quark.clouddrive"], processNames: ["quarkclouddrive"]),
        "quarkclouddriveinstaller": LockRule(bundlePrefixes: ["com.quark.clouddrive"], processNames: ["quarkclouddrive"]),
        "富途牛牛": LockRule(bundlePrefixes: ["cn.futu.niuniu"], processNames: ["futuniuniu", "富途牛牛"]),
        "blender": LockRule(bundlePrefixes: ["org.blenderfoundation.blender"], processNames: ["blender"]),
        "antigravity": LockRule(bundlePrefixes: ["com.google.antigravity"], processNames: ["antigravity"]),
        "codex": LockRule(bundlePrefixes: ["com.openai.codex"], processNames: ["codex"]),
        "codex-runtimes": LockRule(bundlePrefixes: ["com.openai.codex"], processNames: ["codex"]),
        "claude": LockRule(bundlePrefixes: ["com.anthropic.claudefordesktop"], processNames: ["claude"]),
        "claude-code": LockRule(bundlePrefixes: [], processNames: ["claude"]),
        "claude-cli-nodejs": LockRule(bundlePrefixes: [], processNames: ["claude"]),
        "opencode": LockRule(bundlePrefixes: ["ai.opencode.desktop"], processNames: ["opencode"]),
        "@opencode-aidesktop-updater": LockRule(bundlePrefixes: ["ai.opencode.desktop"], processNames: ["opencode"]),
        "@deepseek-aidsh-desktop-updater": LockRule(bundlePrefixes: ["com.deepseek.", "ai.deepseek."], processNames: ["deepseek"]),
        "ollama": LockRule(bundlePrefixes: ["com.electron.ollama"], processNames: ["ollama"]),
        "lm-studio": LockRule(bundlePrefixes: ["ai.elementlabs.lmstudio"], processNames: ["lm studio"]),
        "lmstudio": LockRule(bundlePrefixes: ["ai.elementlabs.lmstudio"], processNames: ["lm studio"]),
        "go-build": LockRule(bundlePrefixes: [], processNames: ["go"]),
        "pip": LockRule(bundlePrefixes: [], processNames: ["pip", "pip3"]),
        "uv": LockRule(bundlePrefixes: [], processNames: ["uv"]),
        "poetry": LockRule(bundlePrefixes: [], processNames: ["poetry"]),
        "pypoetry": LockRule(bundlePrefixes: [], processNames: ["poetry"]),
        "pnpm": LockRule(bundlePrefixes: [], processNames: ["pnpm"]),
        "pnpm-store": LockRule(bundlePrefixes: [], processNames: ["pnpm"]),
        "yarn": LockRule(bundlePrefixes: [], processNames: ["yarn"]),
        "bun": LockRule(bundlePrefixes: [], processNames: ["bun"]),
        "gradle": LockRule(bundlePrefixes: [], processNames: ["gradle", "gradledaemon"]),
        "homebrew": LockRule(bundlePrefixes: [], processNames: ["brew"]),
        "com.apple.dt.xcode": LockRule(bundlePrefixes: ["com.apple.dt.xcode"], processNames: ["xcode", "xcodebuild"]),
        "cursor-agent": LockRule(bundlePrefixes: ["com.todesktop.230313mzl4w4u92"], processNames: ["cursor"]),
    ]

    // MARK: - 手动管理（只展示占用，不参与自动清理）

    static let manualTargets: [(name: String, path: String, hint: String)] = [
        ("Xcode 模拟器设备", "Library/Developer/CoreSimulator/Devices",
         L10n.t("在 Xcode → Devices 或终端运行 xcrun simctl delete unavailable 清理",
                "Manage in Xcode → Devices or run xcrun simctl delete unavailable")),
        ("Docker 磁盘镜像", "Library/Containers/com.docker.docker/Data/vms/0/data/Docker.raw",
         L10n.t("在 Docker Desktop 里清理不用的镜像与卷", "Prune unused images and volumes inside Docker Desktop")),
        ("OrbStack 数据", "Library/Group Containers/HUAQ24HBR6.dev.orbstack",
         L10n.t("在 OrbStack 里管理容器与虚拟机磁盘", "Manage containers and VM disks inside OrbStack")),
        ("Android 模拟器", ".android/avd",
         L10n.t("在 Android Studio Device Manager 中删除不用的模拟器", "Delete unused emulators in Android Studio Device Manager")),
        ("Claude 虚拟机镜像", "Library/Application Support/Claude/vm_bundles",
         L10n.t("在 Claude App 里删除不用的虚拟机镜像", "Delete unused VM images inside the Claude app")),
        ("Ollama 模型", ".ollama/models",
         L10n.t("用 ollama rm 删除不用的本地模型", "Delete unused local models with ollama rm")),
        ("Hugging Face 模型", ".cache/huggingface",
         L10n.t("在所用工具或访达里删除不用的模型", "Delete unused models in your tool or Finder")),
        ("ModelScope 模型", ".cache/modelscope",
         L10n.t("在所用工具或访达里删除不用的魔搭模型", "Delete unused ModelScope models in your tool or Finder")),
        ("LM Studio 模型", ".lmstudio/models",
         L10n.t("在 LM Studio 中删除不用的模型文件", "Delete unused models inside LM Studio")),
        ("iOS 设备备份", "Library/Application Support/MobileSync/Backup",
         L10n.t("在访达或系统设置 → 通用 → 储存空间里管理备份", "Manage backups in Finder or System Settings → Storage")),
        ("废纸篓", ".Trash",
         L10n.t("清倒废纸篓后才会真正释放磁盘空间", "Empty the Trash to actually reclaim disk space")),
    ]

    static let manualCacheExcludes: Set<String> = ["huggingface", "modelscope"]
}
