import Foundation

/// 编译期内置的扫描规则(A 档:不含需要 root 的系统数据)
enum CleanRules {

    /// ~/.cache 下属于 AI 工具/模型运行时的目录(huggingface 归「手动管理」)
    static let aiCacheNames: Set<String> = [
        "claude", "claude-code", "cursor-agent", "copilot", "devin", "opencode",
        "codex", "chrome-devtools-mcp", "lm-studio", "lmstudio",
        "torch", "whisper", "ollama", "amp", "goose", "aider", "comfyui", "mcp",
    ]

    /// ~/.cache 下属于开发工具的目录
    static let devCacheNames: Set<String> = [
        "nix", "pnpm", "yarn", "go-build", "uv", "pip", "puppeteer",
        "ms-playwright", "playwright", "electron", "electron-builder",
        "node-gyp", "node", "pnpm-store", "fontconfig", "cypress", "pre-commit",
        "poetry", "mypy", "black", "ruff", "swc", "turbo", "parcel-bundler",
        "vite", "webpack", "gradle", "cocoapods", "swiftpm", "terraform",
        "deno", "bun", "composer", "gem", "ruby", "gh", "prisma",
    ]

    /// 开发工具固定缓存路径(相对 home)。.npm/_cacache 不在这里,走引用图清理
    static let developerPaths: [(path: String, safety: CleanSafety, hint: String?)] = [
        ("Library/Developer/Xcode/DerivedData", .safe, L10n.t("Xcode 构建产物,可自动重建", "Xcode build products, rebuilt automatically")),
        ("Library/Developer/Xcode/iOS DeviceSupport", .safe, L10n.t("真机符号缓存,连接设备后重新生成", "Device symbols, regenerated when a device connects")),
        ("Library/Developer/Xcode/SourcePackages", .review, L10n.t("Swift 包缓存,重新构建时需重新解析", "Swift package cache, re-resolved on next build")),
        ("Library/Developer/XCTestDevices", .safe, nil),
        ("Library/Developer/CoreSimulator/Caches", .safe, nil),
        (".cargo/registry", .safe, nil),
        (".cargo/git", .safe, nil),
        (".gradle/caches", .safe, nil),
        (".m2/repository", .safe, nil),
        (".pub-cache", .safe, nil),
        ("go/pkg/mod", .review, L10n.t("Go 模块缓存,首次构建需重新下载", "Go module cache, re-downloaded on first build")),
        ("Library/Caches/Homebrew", .safe, nil),
    ]

    static let npmCachePath = ".npm/_cacache"

    /// 手动管理(只展示占用):重新生成成本高,交给用户在对应工具里处置
    static let manualTargets: [(name: String, path: String, hint: String)] = [
        ("Claude 虚拟机镜像", "Library/Application Support/Claude/vm_bundles",
         L10n.t("在 Claude App 里删除不用的虚拟机镜像", "Delete unused VM images inside the Claude app")),
        ("Ollama 模型", ".ollama/models",
         L10n.t("在对应工具里删除不用的模型", "Delete unused models in the tool itself")),
        ("Hugging Face 模型", ".cache/huggingface",
         L10n.t("在所用工具里删除不用的模型", "Delete unused models in the tool you use")),
    ]

    static let manualCacheExcludes: Set<String> = ["huggingface"]

    /// 永不进入清单:Safari 数据,以及 PopBar 自己的缓存
    static let protectedNames: Set<String> = [
        "com.apple.Safari", "dev.popbar.app", "PopBar",
    ]
}
