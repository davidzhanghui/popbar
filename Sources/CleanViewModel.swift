import AppKit
import Combine

/// 磁盘清理编排:扫描 -> 归属/占用解析 -> 并发测量 -> 勾选 -> 执行(进废纸篓)-> 记账
/// 与监控面板一样只在面板可见时工作;home 可注入,测试里指向沙箱目录。
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
    @Published var confirmClean = false

    let home: URL
    /// 本次会话里进了废纸篓的位置(测试据此回收,界面不使用)
    private(set) var trashedURLs: [URL] = []
    private var scanTask: Task<Void, Never>?

    init(home: URL = FileManager.default.homeDirectoryForCurrentUser) {
        self.home = home
    }

    // MARK: - 派生数据

    var totalBytes: Int64 { items.compactMap(\.sizeBytes).reduce(0, +) }
    var selectedItems: [CleanItem] { selectedItems(in: nil) }
    var selectedBytes: Int64 { selectedBytes(in: nil) }

    /// category 为 nil 表示全部分类;界面的底栏只作用于当前 tab 的分类
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
        guard !isScanning else { return }
        isScanning = true
        items = []
        manualItems = []
        measuredCount = 0
        summary = nil
        let home = self.home

        scanTask = Task { [weak self] in
            guard let self else { return }
            let running = Set(NSWorkspace.shared.runningApplications.compactMap(\.bundleIdentifier))
            let (targets, manual, index) = await Task.detached(priority: .userInitiated) {
                () -> ([CleanScanner.Target], [CleanManualItem], CleanAppIndex) in
                let index = CleanScanner.buildAppIndex(home: home)
                return (CleanScanner.buildTargets(home: home, appIndex: index, runningBundleIDs: running),
                        CleanScanner.buildManualItems(home: home), index)
            }.value

            self.items = targets.map { t in
                var item = CleanItem(id: UUID(), url: t.url, name: t.name ?? t.url.lastPathComponent,
                                     displayPath: CleanDisplayPath.shorten(t.url, home: home),
                                     category: t.category, kind: t.kind, safety: t.safety, hint: t.hint,
                                     ownerBundleID: nil, ownerAppName: nil, sizeBytes: nil,
                                     isSelected: t.safety == .safe, isLocked: false, statusNote: nil)
                let key = t.url.lastPathComponent
                if let app = index.appName(forBundleID: key) {
                    item.ownerAppName = app
                    item.ownerBundleID = key
                } else if CleanScanner.isBundleIDLike(key) {
                    item.ownerBundleID = key
                }
                // 所属 App 正在运行 -> 加锁、不可勾选
                if let id = item.ownerBundleID, running.contains(id) {
                    item.isLocked = true
                    item.isSelected = false
                    item.statusNote = L10n.t("使用中", "In use")
                }
                return item
            }
            self.manualItems = manual

            await self.measureSizes()
            await self.measureManualItems()
            self.items.sort { ($0.sizeBytes ?? -1) > ($1.sizeBytes ?? -1) }
            self.isScanning = false
            self.hasScanned = true
        }
    }

    func cancel() {
        scanTask?.cancel()
        scanTask = nil
        isScanning = false
    }

    private enum Measure: Sendable {
        case size(Int64?)
        case npm(CleanNpmGC.Analysis?)
    }

    private func measureSizes() async {
        let snapshot = items
        guard !snapshot.isEmpty else { return }
        await withTaskGroup(of: (UUID, Measure).self) { group in
            var next = 0
            func addNext() {
                guard next < snapshot.count else { return }
                let item = snapshot[next]
                next += 1
                group.addTask {
                    switch item.kind {
                    case .npmCache: return (item.id, .npm(await CleanNpmGC.analyze(cacheRoot: item.url)))
                    case .path: return (item.id, .size(await CleanSizeProbe.size(of: item.url)))
                    }
                }
            }
            for _ in 0..<6 { addNext() }
            while let (id, outcome) = await group.next() {
                if let idx = items.firstIndex(where: { $0.id == id }) {
                    switch outcome {
                    case .size(let b): items[idx].sizeBytes = b
                    case .npm(let a):
                        if let a {
                            items[idx].sizeBytes = a.orphanBytes
                            items[idx].statusNote = L10n.t(
                                "孤儿 \(ByteFormat.string(a.orphanBytes)) · 保留 \(ByteFormat.string(a.keptBytes)) · 直接删除",
                                "Orphan \(ByteFormat.string(a.orphanBytes)) · kept \(ByteFormat.string(a.keptBytes)) · deleted directly")
                        } else if items[idx].statusNote == nil {
                            items[idx].statusNote = L10n.t("无法读取缓存目录", "Can’t read the cache directory")
                        }
                    }
                }
                measuredCount += 1
                addNext()
            }
        }
    }

    private func measureManualItems() async {
        let snapshot = manualItems
        guard !snapshot.isEmpty else { return }
        await withTaskGroup(of: (UUID, Int64?).self) { group in
            for item in snapshot { group.addTask { (item.id, await CleanSizeProbe.size(of: item.url)) } }
            while let (id, size) = await group.next() {
                if let idx = manualItems.firstIndex(where: { $0.id == id }) { manualItems[idx].sizeBytes = size }
            }
        }
    }

    // MARK: - 选择

    func toggle(_ id: UUID) {
        guard let i = items.firstIndex(where: { $0.id == id }), items[i].isSelectable else { return }
        items[i].isSelected.toggle()
    }

    func toggleSection(_ c: CleanCategory) {
        let idx = items.indices.filter { items[$0].category == c && items[$0].isSelectable }
        guard !idx.isEmpty else { return }
        let all = idx.allSatisfy { items[$0].isSelected }
        for i in idx { items[i].isSelected = !all }
    }

    func selectAll(in category: CleanCategory? = nil) {
        for i in items.indices where items[i].isSelectable && (category == nil || items[i].category == category) {
            items[i].isSelected = true
        }
    }
    func selectNone(in category: CleanCategory? = nil) {
        for i in items.indices where category == nil || items[i].category == category { items[i].isSelected = false }
    }
    func selectRecommended(in category: CleanCategory? = nil) {
        for i in items.indices where category == nil || items[i].category == category {
            items[i].isSelected = items[i].isSelectable && items[i].safety == .safe
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

    /// 单行垃圾桶按钮:只处理这一项
    func trashItem(_ id: UUID) {
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

        for item in targets {
            switch item.kind {
            case .path:
                // 删除前二次复核,不信任评审阶段的状态
                if let reason = CleanPathGuard.rejection(for: item.url, home: home) {
                    failed += 1
                    CleanLog.append(action: "trash", status: "SKIPPED", count: 1, detail: "\(item.displayPath) (\(reason))")
                    continue
                }
                // 占用复核:执行时所属 App 可能刚被打开
                if let id = item.ownerBundleID,
                   NSWorkspace.shared.runningApplications.contains(where: { $0.bundleIdentifier == id }) {
                    failed += 1
                    CleanLog.append(action: "trash", status: "SKIPPED", count: 1, detail: "\(item.displayPath) (in use)")
                    continue
                }
                let result = await Task.detached { CleanTrash.trash(item.url) }.value
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
                    failures.append("· \(item.name):\(CleanTrash.reason(for: e))")
                }

            case .npmCache:
                if let reason = CleanPathGuard.rejection(for: item.url, home: home) {
                    failed += 1
                    CleanLog.append(action: "clean-npm", status: "SKIPPED", count: 1, detail: "\(item.displayPath) (\(reason))")
                    continue
                }
                if await CleanProcessCheck.isNpmActive() {
                    failed += 1
                    CleanLog.append(action: "clean-npm", status: "SKIPPED", count: 1, detail: "npm/node running")
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
                    CleanLog.append(action: "clean-npm", status: "SKIPPED", count: 1, detail: "cache dir unreadable")
                }
            }
        }

        items.removeAll { done.contains($0.id) }
        summary = CleanSummary(trashedCount: trashed, npmCount: npm, failedCount: failed, failures: failures,
                               freedBytes: freed, trashedBytes: trashedBytes)
    }

    func reveal(_ url: URL) { NSWorkspace.shared.activateFileViewerSelecting([url]) }
}
