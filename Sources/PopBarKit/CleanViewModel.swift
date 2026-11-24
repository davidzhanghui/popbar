import AppKit
import Combine
import PopBarCore
import PopBarPlatform
import PopBarDesign

/// 磁盘清理编排：扫描 -> 归属/占用解析 -> 并发测量 -> 勾选 -> 执行（进废纸篓 / npm GC）-> 记账
/// 与监控面板一样只在面板可见时工作；home 与应用索引根可注入，测试里指向沙箱目录。
@MainActor
final class CleanViewModel: ObservableObject {

    struct CategoryGroup: Identifiable {
        let category: CleanCategory
        let items: [CleanItem]
        var id: CleanCategory { category }
    }

    @Published var items: [CleanItem] = []
    @Published var manualItems: [CleanManualItem] = []
    @Published var isScanning = false
    @Published var isWorking = false
    @Published var hasScanned = false
    @Published var measuredCount = 0
    @Published var summary: CleanSummary?

    let home: URL
    /// 可选覆盖应用索引根目录（供沙箱测试隔离宿主机已装应用）
    let appIndexRoots: [URL]?
    /// 本次会话里进了废纸篓的位置（测试据此回收，界面不使用）
    private(set) var trashedURLs: [URL] = []
    private var scanTask: Task<Void, Never>?
    private var scanGeneration = 0

    init(home: URL = FileManager.default.homeDirectoryForCurrentUser, appIndexRoots: [URL]? = nil) {
        self.home = home
        self.appIndexRoots = appIndexRoots
    }

    // MARK: - 派生数据

    /// 可清理项（不含已锁定或受保护项）的总字节数
    var totalBytes: Int64 { items.filter(\.isSelectable).compactMap(\.sizeBytes).reduce(0, +) }
    var lockedCount: Int { items.filter(\.isLocked).count }
    var selectedItems: [CleanItem] { selectedItems(in: nil) }
    var selectedBytes: Int64 { selectedBytes(in: nil) }

    /// category 为 nil 表示全部分类；界面的底栏只作用于当前 tab 的分类
    func selectedItems(in category: CleanCategory?) -> [CleanItem] {
        items.filter { $0.isSelected && $0.isSelectable && (category == nil || $0.category == category) }
    }
    func selectedBytes(in category: CleanCategory?) -> Int64 {
        selectedItems(in: category).compactMap(\.sizeBytes).reduce(0, +)
    }
    var hasUnmeasured: Bool { !isScanning && items.contains { $0.sizeBytes == nil } }

    var groupedItems: [CategoryGroup] {
        CleanCategory.allCases.compactMap { c in
            let list = items.filter { $0.category == c }
            return list.isEmpty ? nil : CategoryGroup(category: c, items: list)
        }
    }

    // MARK: - 扫描

    func scan() {
        guard !isScanning, !isWorking else { return }
        scanTask?.cancel()
        scanGeneration += 1
        let gen = scanGeneration

        isScanning = true
        items = []
        manualItems = []
        measuredCount = 0
        summary = nil
        let home = self.home
        let roots = self.appIndexRoots

        scanTask = Task { [weak self] in
            guard let self else { return }
            let procs = await CleanProcessCheck.runningProcessNames()
            guard !Task.isCancelled, self.scanGeneration == gen else { return }

            let activity = CleanLockResolver.ActivitySnapshot.captureFromWorkspace(processNames: procs)
            let running = Set(NSWorkspace.shared.runningApplications.compactMap(\.bundleIdentifier))

            let (targets, manual, index) = await Task.detached(priority: .userInitiated) {
                () -> ([CleanScanner.Target], [CleanManualItem], CleanAppIndex) in
                let index = CleanScanner.buildAppIndex(home: home, extraRoots: roots)
                return (CleanScanner.buildTargets(home: home, appIndex: index, runningBundleIDs: running),
                        CleanScanner.buildManualItems(home: home), index)
            }.value
            guard !Task.isCancelled, self.scanGeneration == gen else { return }

            var built: [CleanItem] = targets.map { t in
                let key = t.url.lastPathComponent
                var ownerID = t.ownerBundleID
                var ownerName = t.ownerAppName

                if ownerID == nil {
                    let stripped = CleanScanner.stripTeamIDPrefix(key)
                    if let app = index.appName(forBundleID: key) {
                        ownerName = ownerName ?? app
                        ownerID = stripped
                    } else if CleanScanner.isBundleIDLike(key) {
                        ownerID = stripped
                    }
                } else if ownerName == nil, let id = ownerID {
                    ownerName = index.appName(forBundleID: id)
                }

                let locked = CleanLockResolver.isLocked(
                    ownerBundleID: ownerID,
                    ownerAppName: ownerName,
                    lockBundlePrefixes: t.lockBundlePrefixes,
                    lockProcessNames: t.lockProcessNames,
                    snapshot: activity
                )

                return CleanItem(
                    id: UUID(),
                    url: t.url,
                    name: t.name ?? key,
                    displayPath: CleanDisplayPath.shorten(t.url, home: home),
                    category: t.category,
                    kind: t.kind,
                    safety: t.safety,
                    hint: t.hint,
                    ownerBundleID: ownerID,
                    ownerAppName: ownerName,
                    lockBundlePrefixes: t.lockBundlePrefixes,
                    lockProcessNames: t.lockProcessNames,
                    allowFinderFallback: t.allowFinderFallback,
                    sizeBytes: nil,
                    isSelected: !locked && t.safety == .safe,
                    isLocked: locked,
                    statusNote: locked ? L10n.t("使用中", "In use") : nil
                )
            }

            self.items = built
            self.manualItems = manual

            built = await self.measureSizes(built, generation: gen)
            guard !Task.isCancelled, self.scanGeneration == gen else { return }

            // 过滤 0 字节空壳目录（保留卸载残留、npm 缓存和无法测量的项以保持透明性）
            built.removeAll { item in
                item.category != .remnants && item.kind == .path && item.sizeBytes == 0
            }
            built.sort { ($0.sizeBytes ?? -1) > ($1.sizeBytes ?? -1) }
            self.items = built

            await self.measureManualItems(generation: gen)
            guard !Task.isCancelled, self.scanGeneration == gen else { return }

            self.isScanning = false
            self.hasScanned = true
        }
    }

    func cancel() {
        scanGeneration += 1
        scanTask?.cancel()
        scanTask = nil
        isScanning = false
    }

    private enum Measure: Sendable {
        case size(Int64?)
        case npm(CleanNpmGC.Analysis?)
    }

    private func measureSizes(_ initial: [CleanItem], generation gen: Int) async -> [CleanItem] {
        guard !initial.isEmpty else { return initial }
        var working = initial
        var indexByID: [UUID: Int] = [:]
        for (i, it) in working.enumerated() { indexByID[it.id] = i }

        var completed = 0
        var lastPublish = Date.distantPast

        await withTaskGroup(of: (UUID, Measure).self) { group in
            var next = 0
            func addNext() {
                guard !Task.isCancelled, next < working.count else { return }
                let item = working[next]
                next += 1
                group.addTask {
                    if Task.isCancelled { return (item.id, .size(nil)) }
                    switch item.kind {
                    case .npmCache: return (item.id, .npm(await CleanNpmGC.analyze(cacheRoot: item.url)))
                    case .path: return (item.id, .size(await CleanSizeProbe.size(of: item.url)))
                    }
                }
            }
            for _ in 0..<6 { addNext() }

            while let (id, outcome) = await group.next() {
                if Task.isCancelled || self.scanGeneration != gen {
                    group.cancelAll()
                    break
                }
                if let idx = indexByID[id] {
                    switch outcome {
                    case .size(let b):
                        working[idx].sizeBytes = b
                        // 无法测量（通常是受保护/权限不足目录）禁止保持默认勾选
                        if b == nil {
                            working[idx].isSelected = false
                            if working[idx].statusNote == nil {
                                working[idx].statusNote = L10n.t("无法测量（可能受系统保护）", "Cannot measure (may be protected)")
                            }
                        }
                    case .npm(let a):
                        if let a {
                            working[idx].sizeBytes = a.reclaimableBytes
                            if a.reclaimableBytes == 0 {
                                working[idx].isSelected = false
                                if !working[idx].isLocked {
                                    working[idx].statusNote = L10n.t(
                                        "无孤儿缓存 · 保留 \(ByteFormat.string(a.keptBytes))",
                                        "No orphan blobs · kept \(ByteFormat.string(a.keptBytes))")
                                }
                            } else if !working[idx].isLocked {
                                working[idx].statusNote = L10n.t(
                                    "可清 \(ByteFormat.string(a.reclaimableBytes)) · 保留 \(ByteFormat.string(a.keptBytes)) · 直接删除",
                                    "Cleanable \(ByteFormat.string(a.reclaimableBytes)) · kept \(ByteFormat.string(a.keptBytes)) · deleted directly")
                            }
                        } else {
                            working[idx].isSelected = false
                            if working[idx].statusNote == nil {
                                working[idx].statusNote = L10n.t("索引不可读，已跳过", "Index unreadable; skipped")
                            }
                        }
                    }
                }
                completed += 1
                let now = Date()
                if now.timeIntervalSince(lastPublish) >= 0.12 || completed == working.count {
                    lastPublish = now
                    self.measuredCount = completed
                    self.items = working
                }
                addNext()
            }
        }
        return working
    }

    private func measureManualItems(generation gen: Int) async {
        let snapshot = manualItems
        guard !snapshot.isEmpty else { return }
        await withTaskGroup(of: (UUID, Int64?).self) { group in
            for item in snapshot {
                group.addTask {
                    if Task.isCancelled { return (item.id, nil) }
                    return (item.id, await CleanSizeProbe.size(of: item.url))
                }
            }
            var updated = manualItems
            while let (id, size) = await group.next() {
                if Task.isCancelled || self.scanGeneration != gen {
                    group.cancelAll()
                    return
                }
                if let idx = updated.firstIndex(where: { $0.id == id }) {
                    updated[idx].sizeBytes = size
                }
            }
            if !Task.isCancelled && self.scanGeneration == gen {
                updated.sort { ($0.sizeBytes ?? -1) > ($1.sizeBytes ?? -1) }
                self.manualItems = updated
            }
        }
    }

    // MARK: - 选择

    func toggle(_ id: UUID) {
        guard !isWorking, !isScanning else { return }
        guard let i = items.firstIndex(where: { $0.id == id }), items[i].isSelectable else { return }
        items[i].isSelected.toggle()
    }

    func toggleSection(_ c: CleanCategory) {
        guard !isWorking, !isScanning else { return }
        let idx = items.indices.filter { items[$0].category == c && items[$0].isSelectable }
        guard !idx.isEmpty else { return }
        let all = idx.allSatisfy { items[$0].isSelected }
        for i in idx { items[i].isSelected = !all }
    }

    func selectAll(in category: CleanCategory? = nil) {
        guard !isWorking, !isScanning else { return }
        for i in items.indices where items[i].isSelectable && (category == nil || items[i].category == category) {
            items[i].isSelected = true
        }
    }

    func selectNone(in category: CleanCategory? = nil) {
        guard !isWorking, !isScanning else { return }
        for i in items.indices where category == nil || items[i].category == category {
            items[i].isSelected = false
        }
    }

    func selectRecommended(in category: CleanCategory? = nil) {
        guard !isWorking, !isScanning else { return }
        for i in items.indices where category == nil || items[i].category == category {
            let item = items[i]
            let eligibleSize = item.sizeBytes != nil && (item.kind != .npmCache || (item.sizeBytes ?? 0) > 0)
            items[i].isSelected = item.isSelectable && item.safety == .safe && eligibleSize
        }
    }

    func selectionState(_ c: CleanCategory) -> CleanSelState {
        let list = items.filter { $0.category == c && $0.isSelectable }
        return .from(selected: list.filter(\.isSelected).count, total: list.count)
    }

    // MARK: - 执行

    func cleanSelected(in category: CleanCategory? = nil) {
        let targets = selectedItems(in: category)
        guard !targets.isEmpty else { return }
        Task { await execute(targets) }
    }

    /// 单行垃圾桶按钮：只处理这一项（调用方需先通过 CleanConfirm 确认）
    func trashItem(_ id: UUID) {
        guard !isWorking, !isScanning else { return }
        guard let item = items.first(where: { $0.id == id }), item.isSelectable, item.kind == .path else { return }
        Task { await execute([item]) }
    }

    func execute(_ targets: [CleanItem]) async {
        guard !isWorking else { return }
        isWorking = true
        defer { isWorking = false }

        var trashed = 0, npm = 0, failed = 0
        var freed: Int64 = 0, trashedBytes: Int64 = 0
        var done = Set<UUID>()
        var failures: [String] = []
        let home = self.home

        // 执行前实时抓取最新的活跃应用与进程快照
        let procs = await CleanProcessCheck.runningProcessNames()
        let liveActivity = CleanLockResolver.ActivitySnapshot.captureFromWorkspace(processNames: procs)

        for item in targets {
            let label = item.ownerAppName ?? item.name
            switch item.kind {
            case .path:
                // 删除前二次复核，不信任评审阶段的旧状态
                if let reason = CleanPathGuard.rejection(for: item.url, home: home) {
                    failed += 1
                    CleanLog.append(action: "trash", status: "SKIPPED", count: 1, detail: "\(item.displayPath) (\(reason))")
                    failures.append("· \(label)：\(reason)")
                    continue
                }
                // 占用复核：执行时所属 App 或构建工具可能刚被打开
                if CleanLockResolver.isLocked(
                    ownerBundleID: item.ownerBundleID,
                    ownerAppName: item.ownerAppName,
                    lockBundlePrefixes: item.lockBundlePrefixes,
                    lockProcessNames: item.lockProcessNames,
                    snapshot: liveActivity
                ) {
                    failed += 1
                    let msg = L10n.t("应用或工具正在运行，已跳过", "App or tool is currently running; skipped")
                    CleanLog.append(action: "trash", status: "SKIPPED", count: 1, detail: "\(item.displayPath) (in use)")
                    failures.append("· \(label)：\(msg)")
                    continue
                }
                let allowFinder = item.allowFinderFallback
                let url = item.url
                let result = await Task.detached { CleanTrash.trash(url, allowFinderFallback: allowFinder) }.value
                switch result {
                case .success(let dest):
                    if let dest { trashedURLs.append(dest) }
                    trashed += 1
                    freed += item.sizeBytes ?? 0
                    trashedBytes += item.sizeBytes ?? 0
                    done.insert(item.id)
                    CleanLog.append(action: "trash", status: "RAN", count: 1, detail: item.displayPath)
                case .failure(let e):
                    failed += 1
                    CleanLog.append(action: "trash", status: "SKIPPED", count: 1,
                                    detail: "\(item.displayPath) (\(e.localizedDescription))")
                    failures.append("· \(label)：\(CleanTrash.reason(for: e))")
                }

            case .npmCache:
                if let reason = CleanPathGuard.rejection(for: item.url, home: home) {
                    failed += 1
                    CleanLog.append(action: "clean-npm", status: "SKIPPED", count: 1, detail: "\(item.displayPath) (\(reason))")
                    failures.append("· \(label)：\(reason)")
                    continue
                }
                let npmTools: Set<String> = ["node", "npm", "npx", "corepack", "yarn", "pnpm"]
                if !liveActivity.runningProcessNamesLower.isDisjoint(with: npmTools) {
                    failed += 1
                    let msg = L10n.t("检测到 Node 或 npm 进程正在运行，已跳过", "Node/npm process is running; skipped")
                    CleanLog.append(action: "clean-npm", status: "SKIPPED", count: 1, detail: "npm/node running")
                    failures.append("· \(label)：\(msg)")
                    continue
                }
                if let r = await CleanNpmGC.cleanup(cacheRoot: item.url) {
                    npm += 1
                    freed += r.freedBytes
                    done.insert(item.id)
                    CleanLog.append(action: "clean-npm", status: "RAN", count: r.removedBlobs,
                                    detail: "orphan blobs \(r.removedBlobs) / tmp \(r.removedTmp) / failed \(r.failedBlobs)")
                } else {
                    failed += 1
                    let msg = L10n.t("缓存索引不可读或校验未通过，为安全已中止清理", "Cache index unreadable or invalid; aborted for safety")
                    CleanLog.append(action: "clean-npm", status: "SKIPPED", count: 1, detail: "cache index unreadable")
                    failures.append("· \(label)：\(msg)")
                }
            }
        }

        items.removeAll { done.contains($0.id) }
        summary = CleanSummary(trashedCount: trashed, npmCount: npm, failedCount: failed, failures: failures,
                               freedBytes: freed, trashedBytes: trashedBytes)
    }

    func dismissSummary() { summary = nil }

    func openLog() {
        let url = CleanLog.fileURL
        if FileManager.default.fileExists(atPath: url.path) {
            NSWorkspace.shared.activateFileViewerSelecting([url])
        } else {
            NSWorkspace.shared.open(url.deletingLastPathComponent())
        }
    }

    func reveal(_ url: URL) { NSWorkspace.shared.activateFileViewerSelecting([url]) }
}
