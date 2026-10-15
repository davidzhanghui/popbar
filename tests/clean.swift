import Cocoa
import CryptoKit

/// 磁盘清理的沙箱测试:全部在临时 home 里造目录,真实走 扫描 → 勾选 → 移入废纸篓 / npm GC,
/// 不碰用户真实目录。进了废纸篓的测试数据在末尾回收。

private func write(_ url: URL, _ bytes: Int = 4096) {
    try? FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
    try? Data(repeating: 0x41, count: bytes).write(to: url)
}

private func integrity(of data: Data) -> (sri: String, rel: String) {
    let digest = Data(SHA512.hash(data: data))
    let hex = digest.map { String(format: "%02x", $0) }.joined()
    return ("sha512-" + digest.base64EncodedString(),
            "sha512/\(hex.prefix(2))/\(hex.dropFirst(2).prefix(2))/\(hex.dropFirst(4))")
}

@MainActor
func runCleanTests() async {
    let fm = FileManager.default
    let home = URL(fileURLWithPath: NSTemporaryDirectory())
        .appendingPathComponent("popbar-clean-\(UUID().uuidString.prefix(8))").resolvingSymlinksInPath()
    let outside = URL(fileURLWithPath: NSTemporaryDirectory())
        .appendingPathComponent("popbar-clean-outside-\(UUID().uuidString.prefix(8))").resolvingSymlinksInPath()
    defer { try? fm.removeItem(at: home); try? fm.removeItem(at: outside) }

    // —— 造沙箱 ——
    write(home.appendingPathComponent("Library/Caches/com.foo.cache/a.bin"))
    write(home.appendingPathComponent("Library/Caches/com.apple.thing/a.bin"))
    write(home.appendingPathComponent("Library/Caches/dev.popbar.app/a.bin"))
    write(home.appendingPathComponent("Library/Caches/com.apple.Safari/a.bin"))
    write(home.appendingPathComponent("Library/Caches/Homebrew/a.bin"))
    write(home.appendingPathComponent("Library/Logs/SomeApp/x.log"))
    write(home.appendingPathComponent("Library/Logs/PopBar/clean.log"))
    write(home.appendingPathComponent(".cache/uv/a.bin"))
    write(home.appendingPathComponent(".cache/torch/a.bin"))
    write(home.appendingPathComponent(".cache/claude/a.bin"))
    write(home.appendingPathComponent(".cache/mystery/a.bin"))
    write(home.appendingPathComponent(".cache/huggingface/a.bin"))
    write(home.appendingPathComponent("Library/Developer/Xcode/DerivedData/a.bin"))
    write(home.appendingPathComponent("Library/Containers/com.ghost.app.x/a.bin"))
    write(home.appendingPathComponent("Library/Containers/com.foo.cache/a.bin"))
    write(home.appendingPathComponent("Library/Containers/com.apple.x/a.bin"))
    write(home.appendingPathComponent("Library/Application Support/Claude/vm_bundles/a.bin"))
    // 已安装 App:com.foo.cache
    let apps = home.appendingPathComponent("Applications")
    let plist = apps.appendingPathComponent("Foo.app/Contents/Info.plist")
    try? fm.createDirectory(at: plist.deletingLastPathComponent(), withIntermediateDirectories: true)
    (["CFBundleIdentifier": "com.foo.cache", "CFBundleName": "Foo"] as NSDictionary).write(to: plist, atomically: true)
    // 指向用户目录之外的符号链接
    write(outside.appendingPathComponent("precious.txt"))
    try? fm.createSymbolicLink(at: home.appendingPathComponent("Library/Caches/linkx"), withDestinationURL: outside)
    // npm cacache:一个被索引引用的 blob + 一个孤儿 blob + tmp 残留
    let npm = home.appendingPathComponent(".npm/_cacache")
    let kept = integrity(of: Data("kept".utf8)), orphan = integrity(of: Data("orphan".utf8))
    write(npm.appendingPathComponent("content-v2/\(kept.rel)"), 2000)
    write(npm.appendingPathComponent("content-v2/\(orphan.rel)"), 3000)
    try? fm.createDirectory(at: npm.appendingPathComponent("index-v5/ab/cd"), withIntermediateDirectories: true)
    try? "deadbeef\t{\"key\":\"k\",\"integrity\":\"\(kept.sri)\",\"time\":1}\n"
        .write(to: npm.appendingPathComponent("index-v5/ab/cd/entry"), atomically: true, encoding: .utf8)
    write(npm.appendingPathComponent("tmp/leftover"), 500)

    // MARK: 扫描分类
    section("CleanScanner.buildTargets")
    let index = CleanScanner.buildAppIndex(home: home, extraRoots: [apps])
    expectEqual(index.appName(forBundleID: "com.foo.cache"), "Foo", "App 索引读到展示名")
    let targets = CleanScanner.buildTargets(home: home, appIndex: index, runningBundleIDs: [])
    func target(_ suffix: String) -> CleanScanner.Target? { targets.first { $0.url.path.hasSuffix(suffix) } }
    expectEqual(target("Library/Caches/com.foo.cache")?.category, .appCache, "App 缓存归 appCache")
    expectEqual(target("Library/Caches/com.foo.cache")?.safety, .safe, "普通 App 缓存为 safe")
    expectEqual(target("Library/Caches/com.apple.thing")?.safety, .review, "com.apple.* 缓存需确认")
    expect(target("Library/Caches/dev.popbar.app") == nil, "PopBar 自己的缓存不进清单")
    expect(target("Library/Caches/com.apple.Safari") == nil, "Safari 不进清单")
    expect(target("Library/Caches/Homebrew")?.category == .developerTools, "Homebrew 归开发工具")
    expect(target("Library/Logs/PopBar") == nil, "PopBar 日志不进清单")
    expectEqual(target("Library/Logs/SomeApp")?.category, .appCache, "旧日志归 appCache")
    expectEqual(target(".cache/uv")?.category, .developerTools, "uv 归开发工具")
    expectEqual(target(".cache/claude")?.category, .aiTools, "claude 缓存归 AI 工具")
    expectEqual(target(".cache/torch")?.safety, .review, "模型缓存需确认")
    expectEqual(target(".cache/mystery")?.safety, .review, "未知 ~/.cache 目录需确认")
    expect(target(".cache/huggingface") == nil, "huggingface 归手动管理,不进清单")
    expectEqual(target("Xcode/DerivedData")?.safety, .safe, "DerivedData 为 safe")
    expectEqual(target(".npm/_cacache")?.kind, .npmCache, "npm 走引用图清理")
    expectEqual(target("com.ghost.app.x")?.category, .remnants, "无宿主 App 的容器 = 卸载残留")
    expect(target("Containers/com.foo.cache") == nil, "已安装 App 的容器不是残留")
    expect(target("Containers/com.apple.x") == nil, "com.apple.* 容器不当残留")
    let manual = CleanScanner.buildManualItems(home: home).map(\.name)
    expect(manual.contains("Hugging Face 模型") && manual.contains("Claude 虚拟机镜像"), "手动管理区列出模型/虚拟机镜像")
    let running = CleanScanner.buildTargets(home: home, appIndex: index, runningBundleIDs: ["com.ghost.app.x"])
    expect(!running.contains { $0.url.lastPathComponent == "com.ghost.app.x" }, "宿主 App 在运行 → 不当残留")

    // MARK: 路径保护
    section("CleanPathGuard")
    func rej(_ p: String) -> String? { CleanPathGuard.rejection(for: URL(fileURLWithPath: p), home: home) }
    expect(rej(home.path + "/Library/Caches/com.foo.cache") == nil, "允许根下的目录通过")
    expect(rej(home.path + "/Library/Caches") != nil, "允许根本身不能删")
    expect(rej(home.path) != nil, "home 本身不能删")
    expect(rej(home.path + "/Documents/x") != nil, "允许范围外拒绝")
    expect(rej(home.path + "/Library/Caches/../Documents") != nil, "含 .. 拒绝")
    expect(rej("/System/Library/Caches/x") != nil, "系统路径拒绝")
    expect(rej("/Library/Caches/x") != nil, "/Library 拒绝")
    expect(rej(home.path + "/Library/Caches/linkx") != nil, "符号链接拒绝")

    // MARK: npm 引用图
    section("CleanNpmGC")
    let ana = await CleanNpmGC.analyze(cacheRoot: npm)
    expectEqual(ana?.orphanCount, 1, "只识别出 1 个孤儿 blob")
    expectEqual(ana?.orphanBytes, 3000, "孤儿大小 3000")
    expectEqual(ana?.keptBytes, 2000, "被引用的 2000 字节保留")
    let gc = await CleanNpmGC.cleanup(cacheRoot: npm)
    expectEqual(gc?.removedBlobs, 1, "清理删除 1 个孤儿")
    expect(!fm.fileExists(atPath: npm.appendingPathComponent("content-v2/\(orphan.rel)").path), "孤儿已删除")
    expect(fm.fileExists(atPath: npm.appendingPathComponent("content-v2/\(kept.rel)").path), "被引用的 blob 保留")
    expect(!fm.fileExists(atPath: npm.appendingPathComponent("tmp/leftover").path), "tmp 残留已清")

    // MARK: 端到端:扫描 → 勾选 → 移入废纸篓
    section("CleanViewModel(沙箱 home 端到端)")
    let vm = CleanViewModel(home: home)
    vm.scan()
    var waited = 0
    while vm.isScanning && waited < 300 { try? await Task.sleep(nanoseconds: 100_000_000); waited += 1 }
    expect(!vm.isScanning && vm.hasScanned, "扫描完成")
    expect(vm.items.allSatisfy { $0.sizeBytes != nil || $0.kind == .npmCache }, "所有条目都测出了大小")
    func item(_ suffix: String) -> CleanItem? { vm.items.first { $0.url.path.hasSuffix(suffix) } }
    expect(item("Library/Caches/com.foo.cache")?.isSelected == true, "safe 默认勾选")
    expect(item("com.ghost.app.x")?.isSelected == false, "残留默认不勾选")
    expect(item(".cache/mystery")?.isSelected == false, "需确认项默认不勾选")
    expectEqual(item("Library/Caches/com.foo.cache")?.ownerAppName, "Foo", "条目解析出所属 App 名")
    let sizes = vm.items.compactMap(\.sizeBytes)
    expect(sizes == sizes.sorted(by: >), "按大小降序")

    vm.selectNone()
    expectEqual(vm.selectedItems.count, 0, "全不选")
    vm.selectRecommended()
    expect(vm.selectedItems.allSatisfy { $0.safety == .safe }, "推荐 = 仅 safe")
    vm.toggleSection(.remnants)
    expect(item("com.ghost.app.x")?.isSelected == true, "分类全选勾上残留")
    vm.toggleSection(.remnants)
    expect(item("com.ghost.app.x")?.isSelected == false, "再点取消")

    // 底栏按当前 tab 的分类统计与操作,其他分类里的勾选不受影响
    vm.selectNone()
    vm.selectAll(in: .aiTools)
    let aiSelectable = vm.items.filter { $0.category == .aiTools && $0.isSelectable }.count
    expect(aiSelectable > 0, "沙箱里有 AI 工具条目")
    expectEqual(vm.selectedItems(in: .aiTools).count, aiSelectable, "分类内全选")
    expectEqual(vm.selectedItems(in: .appCache).count, 0, "其他分类不受影响")
    expectEqual(vm.selectedItems.count, aiSelectable, "全局只有该分类被选中")
    expectEqual(vm.selectedBytes(in: .appCache), 0, "其他分类的已选大小为 0")
    expectEqual(vm.selectedBytes(in: .aiTools), vm.selectedBytes, "分类已选大小 = 全局(此时只选了它)")
    vm.selectRecommended()
    vm.selectNone(in: .appCache)
    expectEqual(vm.selectedItems(in: .appCache).count, 0, "分类内全不选")
    expect(vm.selectedItems(in: .developerTools).count > 0, "全不选一个分类不影响另一个")
    vm.selectRecommended(in: .remnants)
    expectEqual(vm.selectedItems(in: .remnants).count, 0, "残留的推荐 = 不选(都是 review)")
    vm.selectNone()

    // 锁定:所属 App 正在运行的条目不可勾选(Finder 一定在跑)
    if NSWorkspace.shared.runningApplications.contains(where: { $0.bundleIdentifier == "com.apple.finder" }) {
        write(home.appendingPathComponent("Library/Caches/com.apple.finder/a.bin"))
        let vm2 = CleanViewModel(home: home)
        vm2.scan()
        var w2 = 0
        while vm2.isScanning && w2 < 300 { try? await Task.sleep(nanoseconds: 100_000_000); w2 += 1 }
        let fin = vm2.items.first { $0.url.lastPathComponent == "com.apple.finder" }
        expect(fin?.isLocked == true && fin?.isSelectable == false, "运行中的 App 缓存加锁不可选")
        if let fin { vm2.toggle(fin.id) }
        expect(vm2.items.first { $0.url.lastPathComponent == "com.apple.finder" }?.isSelected == false, "锁定项点勾选无效")
        try? fm.removeItem(at: home.appendingPathComponent("Library/Caches/com.apple.finder"))
    }

    // 执行:勾 foo 缓存 + 残留 + 符号链接(应被拒),不勾 npm(避免依赖本机 node 是否在跑)
    vm.selectNone()
    for suffix in ["Library/Caches/com.foo.cache", "com.ghost.app.x", "Library/Caches/linkx"] {
        if let it = item(suffix), let i = vm.items.firstIndex(where: { $0.id == it.id }) { vm.items[i].isSelected = true }
    }
    expectEqual(vm.selectedItems.count, 3, "选中 3 项")
    await vm.execute(vm.selectedItems)
    expect(!fm.fileExists(atPath: home.appendingPathComponent("Library/Caches/com.foo.cache").path), "App 缓存已离开原位")
    expect(!fm.fileExists(atPath: home.appendingPathComponent("Library/Containers/com.ghost.app.x").path), "残留已离开原位")
    expectEqual(vm.trashedURLs.count, 2, "两项进了废纸篓")
    expect(vm.trashedURLs.allSatisfy { fm.fileExists(atPath: $0.path) }, "废纸篓里能找到(可恢复)")
    expect(fm.fileExists(atPath: outside.appendingPathComponent("precious.txt").path), "符号链接指向的外部数据没被动")
    expect(fm.fileExists(atPath: home.appendingPathComponent("Library/Caches/linkx").path), "符号链接本身也没被动")
    expectEqual(vm.summary?.trashedCount, 2, "汇总:2 项进废纸篓")
    expectEqual(vm.summary?.failedCount, 1, "汇总:符号链接被拒算 1 项失败")
    expect(item("Library/Caches/com.foo.cache") == nil, "已处理项从列表移除")
    expect(item(".cache/uv") != nil, "未选中的项保留")
    expect(fm.fileExists(atPath: home.appendingPathComponent(".cache/uv/a.bin").path), "未选中的数据未动")

    // 回收测试数据,别在用户废纸篓里留垃圾
    for u in vm.trashedURLs { try? fm.removeItem(at: u) }
}
