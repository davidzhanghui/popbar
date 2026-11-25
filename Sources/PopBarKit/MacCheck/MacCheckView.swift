import AppKit
import PopBarCore
import PopBarDesign
import SwiftUI

// MARK: - 状态模型（懒加载 + 两阶段极速扫描 + 完整资源生命周期管控）

@MainActor
final class MacCheckModel: ObservableObject {
    @Published var tab: MCTab = .overview
    @Published var selectedCategory: MCCategory? = nil
    @Published var activeTest: MCInteractiveKind? = nil
    @Published var isScanning = false
    @Published var profile: MCDeviceProfile?
    @Published private(set) var autoItems: [MCCheckItem] = []
    @Published private(set) var testItems: [String: MCCheckItem] = [:]
    @Published var generatedAt = Date()
    @Published private(set) var history: [MCSavedSnapshot] = []
    @Published var toastMessage: String?

    @Published private(set) var currentBatteryCycles: Int?
    @Published private(set) var currentBatteryHealthPct: Int?
    @Published private(set) var currentSSDWearPct: Int?

    private var hasScanned = false
    private var scanTask: Task<Void, Never>?
    private var lastLanguage: String = ConfigStore.shared.config.language
    private var configObserver: NSObjectProtocol?

    private static var appVersion: String {
        (Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String) ?? "dev"
    }

    init() {
        configObserver = NotificationCenter.default.addObserver(
            forName: ConfigStore.didChange, object: nil, queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self else { return }
                let lang = ConfigStore.shared.config.language
                if lang != self.lastLanguage {
                    self.lastLanguage = lang
                    if self.hasScanned { self.rescan() }
                }
            }
        }
    }

    deinit {
        if let configObserver { NotificationCenter.default.removeObserver(configObserver) }
    }

    func pageDidAppear() {
        if history.isEmpty { history = MCHistoryStore.load() }
        if !hasScanned { rescan() }
    }

    func pageDidDisappear() {
        stopActiveWork()
    }

    func stopModule() {
        stopActiveWork()
    }

    private func stopActiveWork() {
        scanTask?.cancel()
        scanTask = nil
        isScanning = false
        activeTest = nil
        MCFullscreenPresenter.dismiss()
    }

    func rescan() {
        scanTask?.cancel()
        isScanning = true
        scanTask = Task { [weak self] in
            guard let self else { return }
            // Phase 1：亚毫秒级原生探测，首屏瞬间出机型/电池/NVMe SMART/Wi-Fi
            let fast = await Task.detached(priority: .userInitiated) {
                MacCheckEngine.runFastProbe()
            }.value
            guard !Task.isCancelled else { return }
            self.profile = fast.profile
            if self.autoItems.isEmpty {
                self.autoItems = fast.items
            }
            self.currentBatteryCycles = fast.batteryCycles
            self.currentBatteryHealthPct = fast.batteryHealthPct
            self.currentSSDWearPct = fast.ssdWearPct

            // Phase 2：复用 Phase 1 原生结果 + 合并单次 system_profiler 与并发 profiles/defaults
            let full = await MacCheckEngine.runFullProbe(reusing: fast)
            guard !Task.isCancelled else { return }
            self.profile = full.profile
            self.autoItems = full.items
            self.currentBatteryCycles = full.batteryCycles
            self.currentBatteryHealthPct = full.batteryHealthPct
            self.currentSSDWearPct = full.ssdWearPct
            self.generatedAt = Date()
            self.isScanning = false
            self.hasScanned = true
        }
    }

    func recordTestResult(_ item: MCCheckItem) {
        testItems[item.id] = item
        generatedAt = Date()
        if activeTest?.resultID == item.id {
            activeTest = nil
        }
        MCFullscreenPresenter.dismiss()
        showToast(L10n.t("已记录「\(item.title)」结果", "Saved result for \(item.title)"))
    }

    func launchTest(_ kind: MCInteractiveKind) {
        if kind.needsFullscreen {
            let screen = NSApp.keyWindow?.screen ?? NSScreen.main
            switch kind {
            case .keyboard:
                MCFullscreenPresenter.present(
                    MCKeyboardTestView(
                        onFinish: { [weak self] item in self?.recordTestResult(item) },
                        onCancel: { MCFullscreenPresenter.dismiss() }
                    ),
                    on: screen
                )
            case .screen:
                MCFullscreenPresenter.present(
                    MCScreenTestView(
                        onFinish: { [weak self] item in self?.recordTestResult(item) },
                        onCancel: { MCFullscreenPresenter.dismiss() }
                    ),
                    on: screen
                )
            default:
                break
            }
        } else {
            tab = .tests
            activeTest = kind
        }
    }

    func status(for category: MCCategory) -> MCStatus? {
        let matched = autoItems.filter { $0.category == category }
        return matched.max(by: { $0.status.severityRank < $1.status.severityRank })?.status
    }

    func items(for category: MCCategory) -> [MCCheckItem] {
        autoItems.filter { $0.category == category }
    }

    func testResult(for kind: MCInteractiveKind) -> MCCheckItem? {
        testItems[kind.resultID]
    }

    var completedTestCount: Int {
        MCInteractiveKind.allCases.filter { testItems[$0.resultID] != nil }.count
    }

    var orderedAllItems: [MCCheckItem] {
        let orderedTests = MCInteractiveKind.allCases.compactMap { testItems[$0.resultID] }
        return autoItems + orderedTests
    }

    var currentReport: MCReport {
        MCReport(
            generatedAt: generatedAt,
            appVersion: Self.appVersion,
            profile: profile,
            items: orderedAllItems
        )
    }

    func saveSnapshot() {
        guard let profile else { return }
        let rep = currentReport
        let snap = MCSavedSnapshot(
            id: UUID(),
            savedAt: Date(),
            deviceName: profile.marketingName,
            serial: profile.serialNumber,
            score: rep.score,
            batteryCycles: currentBatteryCycles,
            batteryHealthPct: currentBatteryHealthPct,
            ssdWearPct: currentSSDWearPct,
            report: rep
        )
        history.insert(snap, at: 0)
        MCHistoryStore.save(history)
        showToast(L10n.t("已保存到历史快照", "Snapshot saved to history"))
    }

    func copySerialNumber() {
        guard let sn = profile?.serialNumber, !sn.isEmpty else { return }
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(sn, forType: .string)
        showToast(L10n.t("已复制序列号", "Serial copied"))
    }

    func openAppleCoverage() {
        if let url = URL(string: "https://checkcoverage.apple.com/") {
            NSWorkspace.shared.open(url)
        }
    }

    func deleteSnapshot(_ id: UUID) {
        history.removeAll { $0.id == id }
        MCHistoryStore.save(history)
    }

    private func showToast(_ msg: String) {
        toastMessage = msg
        Task { @MainActor [weak self] in
            try? await Task.sleep(nanoseconds: 2_200_000_000)
            if self?.toastMessage == msg { self?.toastMessage = nil }
        }
    }
}

// MARK: - 主页面（DSPageShell + 顶部 Segmented 切换，零双侧栏）

struct MacCheckPage: View {
    @ObservedObject var model: MacCheckModel

    var body: some View {
        DSPageShell(
            L10n.t("硬件验机", "Mac Check"),
            subtitle: L10n.t("纯本地离线硬件体检、NVMe 寿命、MDM 风险排查与交互测试",
                             "Offline hardware inspection, NVMe SMART wear, MDM checks and interactive tests")
        ) {
            if let toast = model.toastMessage {
                DSChip(toast, tone: .success, icon: "check")
            }
            DSButton(model.isScanning ? L10n.t("检测中…", "Scanning…") : L10n.t("重新检测", "Rescan"),
                     icon: "refresh-cw", kind: .ghost) {
                model.rescan()
            }
            .disabled(model.isScanning)

            DSButton(L10n.t("保存快照", "Save Snapshot"), icon: "save", kind: .secondary) {
                model.saveSnapshot()
            }
            .disabled(model.isScanning || model.profile == nil)

            MCExportMenuButton(disabled: model.profile == nil) { format in
                MCReportExporter.export(model.currentReport, format: format)
            }
        } pinned: {
            HStack(spacing: 12) {
                DSSegmented(selection: $model.tab, options: MCTab.allCases.map { ($0, $0.title) })
                Spacer()
                if let p = model.profile {
                    Text(L10n.t("探测耗时 \(p.scanElapsedMs) ms", "Scanned in \(p.scanElapsedMs) ms"))
                        .font(DS.small).monospacedDigit().foregroundStyle(DS.faint)
                }
            }
        } content: {
            switch model.tab {
            case .overview:
                overviewContent
            case .system:
                systemContent
            case .tests:
                testsContent
            case .ai:
                aiContent
            case .history:
                historyContent
            }
        }
    }

    // MARK: - 1. 概览页

    @ViewBuilder
    private var overviewContent: some View {
        deviceHeroCard

        let risks = model.currentReport.criticalRisks
        if !risks.isEmpty {
            VStack(alignment: .leading, spacing: 8) {
                DSSectionHeader(L10n.t("高风险项 · 请优先核查", "Critical Warnings · Read First"))
                VStack(spacing: 8) {
                    ForEach(risks) { item in
                        HStack(alignment: .top, spacing: 10) {
                            Icon("shield-alert", size: 16, color: DS.danger).padding(.top, 2)
                            VStack(alignment: .leading, spacing: 4) {
                                Text(item.title).font(DS.font(13, .semibold)).foregroundStyle(DS.danger)
                                Text(item.riskNotice ?? item.summary)
                                    .font(DS.caption).foregroundStyle(DS.text2)
                                    .fixedSize(horizontal: false, vertical: true)
                            }
                            Spacer()
                        }
                        .padding(14)
                        .background(RoundedRectangle(cornerRadius: Theme.Radius.card, style: .continuous).fill(DS.dangerSoft))
                        .overlay(RoundedRectangle(cornerRadius: Theme.Radius.card, style: .continuous).strokeBorder(DS.danger.opacity(0.35), lineWidth: 1))
                    }
                }
            }
        }

        // 系统自动检测总览
        VStack(alignment: .leading, spacing: 8) {
            DSSectionHeader(L10n.t("系统自动检测", "Automated System Checks")) {
                DSButton(L10n.t("查看全部明细", "All Details"), kind: .ghost) {
                    model.selectedCategory = nil
                    model.tab = .system
                }
            }
            VStack(spacing: 0) {
                ForEach(Array(MCCategory.autoCategories.enumerated()), id: \.element.id) { idx, cat in
                    if idx > 0 { DSDivider(inset: 16) }
                    let st = model.status(for: cat)
                    let summary = model.items(for: cat).first?.summary ?? (model.isScanning ? L10n.t("探测中…", "Probing…") : "—")
                    Button {
                        model.selectedCategory = cat
                        model.tab = .system
                    } label: {
                        HStack(spacing: 12) {
                            DSIconTile(cat.icon, color: statusTint(st), size: 30)
                            VStack(alignment: .leading, spacing: 2) {
                                Text(cat.title).font(DS.font(13, .medium)).foregroundStyle(DS.text)
                                Text(summary).font(DS.caption).foregroundStyle(DS.muted).lineLimit(1)
                            }
                            Spacer(minLength: 10)
                            if let st {
                                DSChip(st.label, tone: statusTone(st), icon: st.icon)
                            } else {
                                ProgressView().controlSize(.mini)
                            }
                            Icon("chevron-right", size: 14, color: DS.faint)
                        }
                        .padding(.horizontal, 14).padding(.vertical, 10)
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .dsHoverRow()
                }
            }
            .clipShape(RoundedRectangle(cornerRadius: Theme.Radius.card, style: .continuous))
            .dsCardBackground()
        }

        // 交互测试速览
        VStack(alignment: .leading, spacing: 8) {
            DSSectionHeader(L10n.t("硬件交互测试", "Interactive Hardware Tests")) {
                Text(L10n.t("已完成 \(model.completedTestCount) / \(MCInteractiveKind.allCases.count)",
                            "\(model.completedTestCount) / \(MCInteractiveKind.allCases.count) completed"))
                    .font(DS.small).foregroundStyle(DS.muted)
            }
            let cols = [GridItem(.flexible(), spacing: 10), GridItem(.flexible(), spacing: 10)]
            LazyVGrid(columns: cols, spacing: 10) {
                ForEach(MCInteractiveKind.allCases) { kind in
                    let res = model.testResult(for: kind)
                    Button { model.launchTest(kind) } label: {
                        HStack(spacing: 10) {
                            DSIconTile(kind.icon, color: res.map { statusTint($0.status) } ?? DS.muted, size: 28)
                            VStack(alignment: .leading, spacing: 2) {
                                Text(kind.title).font(DS.font(12.5, .medium)).foregroundStyle(DS.text).lineLimit(1)
                                Text(res?.summary ?? kind.subtitle).font(DS.small).foregroundStyle(DS.muted).lineLimit(1)
                            }
                            Spacer(minLength: 4)
                            if let res {
                                DSChip(res.status.label, tone: statusTone(res.status))
                            } else {
                                Icon("chevron-right", size: 13, color: DS.faint)
                            }
                        }
                        .padding(10)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .dsCardBackground()
                    }
                    .buttonStyle(DSPressStyle(scale: 0.99))
                }
            }
        }
    }

    private var deviceHeroCard: some View {
        let rep = model.currentReport
        return DSCard {
            VStack(alignment: .leading, spacing: 12) {
                HStack(alignment: .center, spacing: 16) {
                    DSIconTile("cpu", color: DS.accent, size: 48, filled: true)
                    VStack(alignment: .leading, spacing: 6) {
                        Text(model.profile?.marketingName ?? L10n.t("正在读取硬件信息…", "Probing hardware…"))
                            .font(DS.font(18, .bold)).foregroundStyle(DS.text)
                        if let p = model.profile {
                            Text("\(p.chip) · \(p.memoryDisplay) · \(p.macOSVersion)")
                                .font(DS.body).foregroundStyle(DS.text2)
                            HStack(spacing: 8) {
                                if !p.serialNumber.isEmpty {
                                    DSChip(p.serialNumber, tone: .neutral, icon: "hash")
                                }
                                DSChip(p.architecture, tone: .neutral, icon: "cpu")
                                if !p.modelYear.isEmpty {
                                    let ageSuffix = MCSerialDecoder.estimatedAgeText(modelYear: p.modelYear).map { " · \($0)" } ?? ""
                                    DSChip(L10n.t("\(p.modelYear) 年款\(ageSuffix)", "\(p.modelYear)\(ageSuffix)"), tone: .neutral, icon: "calendar")
                                }
                            }
                        }
                    }
                    Spacer(minLength: 12)
                    VStack(alignment: .trailing, spacing: 2) {
                        Text("\(rep.score)")
                            .font(.system(size: 34, weight: .heavy, design: .rounded))
                            .monospacedDigit()
                            .foregroundStyle(scoreColor(rep.score))
                        DSChip(rep.gradeLabel, tone: scoreTone(rep.score))
                    }
                }
                if let p = model.profile, !p.serialNumber.isEmpty {
                    DSDivider(inset: 0)
                    HStack(spacing: 8) {
                        DSButton(L10n.t("复制序列号", "Copy Serial"), icon: "copy", kind: .ghost) {
                            model.copySerialNumber()
                        }
                        DSButton(L10n.t("Apple 官网查保修", "Check Apple Warranty"), icon: "external-link", kind: .ghost) {
                            model.openAppleCoverage()
                        }
                        Spacer()
                        Text(L10n.t("保修与激活日期需在官网凭序列号核对，本模块全程离线不联网",
                                    "Warranty lives on Apple's site; this check stays 100% offline"))
                            .font(DS.small).foregroundStyle(DS.faint)
                    }
                }
            }
        }
    }

    // MARK: - 2. 系统检测明细页

    @ViewBuilder
    private var systemContent: some View {
        // 顶部分类筛选条
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 6) {
                filterPill(nil, title: L10n.t("全部", "All"))
                ForEach(MCCategory.autoCategories) { cat in
                    filterPill(cat, title: cat.title)
                }
            }
        }

        let filtered = model.autoItems.filter { model.selectedCategory == nil || $0.category == model.selectedCategory }
        if filtered.isEmpty {
            DSEmptyState(icon: "cpu", title: L10n.t("正在扫描硬件…", "Scanning hardware…"))
                .dsCardBackground()
        } else {
            VStack(spacing: 12) {
                ForEach(filtered) { item in
                    DSCard {
                        VStack(alignment: .leading, spacing: 10) {
                            HStack(spacing: 10) {
                                DSIconTile(item.category.icon, color: statusTint(item.status), size: 28)
                                VStack(alignment: .leading, spacing: 2) {
                                    Text(item.title).font(DS.font(13.5, .semibold)).foregroundStyle(DS.text)
                                    Text(item.summary).font(DS.caption).foregroundStyle(DS.muted)
                                        .fixedSize(horizontal: false, vertical: true)
                                }
                                Spacer()
                                DSChip(item.status.label, tone: statusTone(item.status), icon: item.status.icon)
                            }
                            if let risk = item.riskNotice {
                                Text(risk)
                                    .font(DS.caption).foregroundStyle(DS.danger)
                                    .padding(10)
                                    .frame(maxWidth: .infinity, alignment: .leading)
                                    .background(RoundedRectangle(cornerRadius: Theme.Radius.button).fill(DS.dangerSoft))
                            }
                            if !item.details.isEmpty {
                                DSDivider(inset: 0)
                                VStack(spacing: 6) {
                                    ForEach(item.details) { pair in
                                        HStack(alignment: .top, spacing: 12) {
                                            Text(pair.key).font(DS.caption).foregroundStyle(DS.muted)
                                            Spacer(minLength: 16)
                                            Text(pair.value)
                                                .font(pair.mono ? DS.mono : DS.caption)
                                                .foregroundStyle(DS.text)
                                                .multilineTextAlignment(.trailing)
                                                .textSelection(.enabled)
                                        }
                                    }
                                }
                            }
                        }
                    }
                }
            }
        }
    }

    private func filterPill(_ cat: MCCategory?, title: String) -> some View {
        let active = model.selectedCategory == cat
        return Button {
            model.selectedCategory = cat
        } label: {
            Text(title)
                .font(DS.font(12, active ? .semibold : .regular))
                .foregroundStyle(active ? DS.onAccent : DS.text2)
                .padding(.horizontal, 12).frame(height: 26)
                .background(Capsule().fill(active ? DS.accent : DS.surface))
                .overlay(Capsule().strokeBorder(active ? DS.accent : DS.border, lineWidth: 1))
        }
        .buttonStyle(DSPressStyle())
    }

    // MARK: - 3. 硬件交互测试页

    @ViewBuilder
    private var testsContent: some View {
        if let active = model.activeTest {
            DSCard {
                VStack(alignment: .leading, spacing: 14) {
                    HStack(spacing: 10) {
                        DSButton(L10n.t("返回测试列表", "Back to Tests"), icon: "chevron-left", kind: .ghost) {
                            model.activeTest = nil
                        }
                        Spacer()
                        if let existing = model.testResult(for: active) {
                            DSChip(existing.status.label, tone: statusTone(existing.status), icon: existing.status.icon)
                        }
                    }
                    HStack(spacing: 10) {
                        DSIconTile(active.icon, color: DS.accent, size: 32, filled: true)
                        VStack(alignment: .leading, spacing: 2) {
                            Text(active.title).font(DS.font(15, .semibold)).foregroundStyle(DS.text)
                            Text(active.subtitle).font(DS.caption).foregroundStyle(DS.muted)
                        }
                    }
                    DSDivider(inset: 0)
                    interactivePane(for: active)
                }
            }
        } else {
            let cols = [GridItem(.flexible(), spacing: 12), GridItem(.flexible(), spacing: 12)]
            LazyVGrid(columns: cols, spacing: 12) {
                ForEach(MCInteractiveKind.allCases) { kind in
                    let res = model.testResult(for: kind)
                    Button { model.launchTest(kind) } label: {
                        VStack(alignment: .leading, spacing: 10) {
                            HStack(spacing: 10) {
                                DSIconTile(kind.icon, color: res.map { statusTint($0.status) } ?? DS.accent, size: 32)
                                VStack(alignment: .leading, spacing: 2) {
                                    Text(kind.title).font(DS.font(13.5, .semibold)).foregroundStyle(DS.text)
                                    Text(kind.needsFullscreen ? L10n.t("全屏接管测试", "Fullscreen test") : L10n.t("面板内测试", "Inline test"))
                                        .font(DS.small).foregroundStyle(DS.faint)
                                }
                                Spacer()
                                if let res {
                                    DSChip(res.status.label, tone: statusTone(res.status), icon: res.status.icon)
                                }
                            }
                            Text(res?.summary ?? kind.subtitle)
                                .font(DS.caption).foregroundStyle(DS.muted)
                                .lineLimit(2)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                        .padding(14)
                        .frame(maxWidth: .infinity, minHeight: 96, alignment: .topLeading)
                        .dsCardBackground()
                    }
                    .buttonStyle(DSPressStyle(scale: 0.985))
                }
            }
        }
    }

    @ViewBuilder
    private func interactivePane(for kind: MCInteractiveKind) -> some View {
        switch kind {
        case .audio:
            MCAudioTestView { model.recordTestResult($0) }
        case .microphone:
            MCMicTestView { model.recordTestResult($0) }
        case .camera:
            MCCameraTestView { model.recordTestResult($0) }
        case .touchID:
            MCTouchIDTestView { model.recordTestResult($0) }
        case .trackpad:
            MCTrackpadTestView { model.recordTestResult($0) }
        case .stress:
            MCStressTestView { model.recordTestResult($0) }
        case .diskSpeed:
            MCDiskSpeedTestView { model.recordTestResult($0) }
        case .portsLive:
            MCPortsLiveTestView { model.recordTestResult($0) }
        case .keyboard, .screen:
            EmptyView()
        }
    }

    // MARK: - 4. AI 大模型本地可跑性页

    @ViewBuilder
    private var aiContent: some View {
        let memGB = model.profile?.memoryGB ?? Int((Double(ProcessInfo.processInfo.physicalMemory) / 1_073_741_824.0).rounded())
        let isArm = model.profile?.architecture.contains("Apple Silicon") ?? true
        let budget = MCAIAdvisor.usableBudgetGB(totalMemoryGB: memGB, isAppleSilicon: isArm)
        let tiers = MCAIAdvisor.evaluate(totalMemoryGB: memGB, isAppleSilicon: isArm)
        let sweet = MCAIAdvisor.sweetSpot(totalMemoryGB: memGB, isAppleSilicon: isArm)

        DSCard {
            VStack(alignment: .leading, spacing: 12) {
                HStack(spacing: 14) {
                    DSIconTile("sparkles", color: DS.accent, size: 38, filled: true)
                    VStack(alignment: .leading, spacing: 4) {
                        Text(L10n.t("本地大模型算力评估（\(memGB) GB 内存）", "Local LLM Fit (\(memGB) GB RAM)"))
                            .font(DS.font(15, .semibold)).foregroundStyle(DS.text)
                        Text(L10n.t("按 Q4_K_M 量化与典型上下文余量估算，本机安全可用模型内存约 \(budget) GB。",
                                    "Estimated safe model memory budget is ~\(budget) GB at Q4_K_M quantization."))
                            .font(DS.caption).foregroundStyle(DS.muted)
                    }
                    Spacer()
                }
                if let sweet {
                    DSDivider(inset: 0)
                    HStack(spacing: 8) {
                        DSChip(L10n.t("推荐甜点档", "Sweet Spot"), tone: .accent, icon: "star")
                        Text("\(sweet.name)（\(sweet.params) · \(sweet.examples)）")
                            .font(DS.caption).foregroundStyle(DS.text)
                            .lineLimit(1)
                    }
                }
                if !isArm {
                    DSChip(L10n.t("当前为 Intel 架构，缺少统一内存与 Apple GPU 加速，本地推理速度会明显偏慢，建议优先尝试 8B 以内小模型",
                                  "Intel Mac lacks unified memory and Apple GPU acceleration; stick to models under 8B"),
                           tone: .warning, icon: "triangle-alert")
                }
            }
        }

        VStack(spacing: 0) {
            ForEach(Array(tiers.enumerated()), id: \.element.id) { idx, tier in
                if idx > 0 { DSDivider(inset: 16) }
                HStack(alignment: .top, spacing: 14) {
                    VStack(alignment: .leading, spacing: 4) {
                        HStack(spacing: 8) {
                            Text(tier.name).font(DS.font(13.5, .semibold)).foregroundStyle(DS.text)
                            DSChip(tier.params, tone: .neutral)
                            DSChip(tier.quantization, tone: .neutral)
                            if sweet?.id == tier.id {
                                DSChip(L10n.t("甜点", "Sweet Spot"), tone: .accent, icon: "star")
                            }
                        }
                        Text(tier.examples).font(DS.mono).foregroundStyle(DS.text2)
                        Text(tier.note).font(DS.caption).foregroundStyle(DS.muted)
                    }
                    Spacer(minLength: 10)
                    DSChip(tier.fit.label, tone: aiTone(tier.fit))
                }
                .padding(14)
            }
        }
        .clipShape(RoundedRectangle(cornerRadius: Theme.Radius.card, style: .continuous))
        .dsCardBackground()

        // 常用本地运行工具与模型库入口
        VStack(alignment: .leading, spacing: 8) {
            DSSectionHeader(L10n.t("本地运行工具与模型库", "Local Runtimes & Model Hubs"))
            let cols = [GridItem(.flexible(), spacing: 10), GridItem(.flexible(), spacing: 10)]
            LazyVGrid(columns: cols, spacing: 10) {
                ForEach(MCAIAdvisor.resourceLinks) { link in
                    Button {
                        if let u = URL(string: link.url) { NSWorkspace.shared.open(u) }
                    } label: {
                        HStack(spacing: 10) {
                            DSIconTile("external-link", color: DS.accent, size: 28)
                            VStack(alignment: .leading, spacing: 2) {
                                Text(link.title).font(DS.font(12.5, .semibold)).foregroundStyle(DS.text)
                                Text(link.subtitle).font(DS.small).foregroundStyle(DS.muted).lineLimit(1)
                            }
                            Spacer(minLength: 4)
                            Icon("chevron-right", size: 13, color: DS.faint)
                        }
                        .padding(10)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .dsCardBackground()
                    }
                    .buttonStyle(DSPressStyle(scale: 0.99))
                }
            }
        }
    }

    // MARK: - 5. 历史快照页（含同机 Diff 对比）

    @ViewBuilder
    private var historyContent: some View {
        if model.history.isEmpty {
            DSEmptyState(
                icon: "history",
                title: L10n.t("暂无历史快照", "No Saved Snapshots"),
                message: L10n.t("点击右上角「保存快照」留存本次验机数据，便于日后追踪电池衰减或 SSD 写入量变化。",
                                "Click Save Snapshot above to keep records for tracking battery wear and SSD TBW over time."),
                actionTitle: L10n.t("立即保存当前快照", "Save Current Snapshot")
            ) {
                model.saveSnapshot()
            }
            .dsCardBackground()
        } else {
            VStack(spacing: 10) {
                ForEach(model.history) { snap in
                    let diffs = snapshotDiffs(snap)
                    DSCard(padding: 14) {
                        VStack(alignment: .leading, spacing: 10) {
                            HStack(spacing: 12) {
                                Text("\(snap.score)")
                                    .font(.system(size: 20, weight: .bold, design: .rounded))
                                    .monospacedDigit()
                                    .foregroundStyle(scoreColor(snap.score))
                                    .frame(width: 42)
                                VStack(alignment: .leading, spacing: 3) {
                                    HStack(spacing: 8) {
                                        Text(snap.deviceName).font(DS.font(13.5, .semibold)).foregroundStyle(DS.text)
                                        if !snap.serial.isEmpty {
                                            Text(snap.serial).font(DS.mono).foregroundStyle(DS.faint)
                                        }
                                    }
                                    HStack(spacing: 10) {
                                        Text(snap.savedAt.formatted(date: .abbreviated, time: .shortened))
                                            .font(DS.small).foregroundStyle(DS.muted)
                                        if let c = snap.batteryCycles {
                                            Text(L10n.t("电池循环 \(c) 次", "\(c) cycles")).font(DS.small).foregroundStyle(DS.muted)
                                        }
                                        if let h = snap.batteryHealthPct {
                                            Text(L10n.t("健康 \(h)%", "Health \(h)%")).font(DS.small).foregroundStyle(DS.muted)
                                        }
                                        if let w = snap.ssdWearPct {
                                            Text(L10n.t("SSD 损耗 \(w)%", "SSD \(w)% wear")).font(DS.small).foregroundStyle(DS.muted)
                                        }
                                    }
                                }
                                Spacer()
                                DSButton("PNG", icon: "image", kind: .ghost) {
                                    MCReportExporter.export(snap.report, format: .png)
                                }
                                DSButton("PDF", icon: "file-text", kind: .ghost) {
                                    MCReportExporter.export(snap.report, format: .pdf)
                                }
                                DSIconButton("trash-2", tint: DS.danger, help: L10n.t("删除快照", "Delete")) {
                                    model.deleteSnapshot(snap.id)
                                }
                            }

                            if !diffs.isEmpty {
                                DSDivider(inset: 0)
                                HStack(spacing: 8) {
                                    Text(L10n.t("与当前对比", "vs. Now"))
                                        .font(DS.font(11, .semibold)).foregroundStyle(DS.faint)
                                    ForEach(diffs, id: \.label) { d in
                                        DSChip("\(d.label) \(d.text)", tone: d.tone)
                                    }
                                    Spacer()
                                }
                            }
                        }
                    }
                }
            }
        }
    }

    private struct SnapshotDiff {
        let label: String
        let text: String
        let tone: DSTone
    }

    private func snapshotDiffs(_ snap: MCSavedSnapshot) -> [SnapshotDiff] {
        guard let curSerial = model.profile?.serialNumber, !curSerial.isEmpty, curSerial == snap.serial else {
            return []
        }
        var out: [SnapshotDiff] = []
        let ds = model.currentReport.score - snap.score
        out.append(SnapshotDiff(
            label: L10n.t("评分", "Score"),
            text: ds == 0 ? L10n.t("无变化", "Same") : (ds > 0 ? "+\(ds)" : "\(ds)"),
            tone: ds == 0 ? .neutral : (ds > 0 ? .success : .warning)
        ))
        if let thenC = snap.batteryCycles, let nowC = model.currentBatteryCycles {
            let dc = nowC - thenC
            out.append(SnapshotDiff(
                label: L10n.t("循环", "Cycles"),
                text: dc == 0 ? L10n.t("无变化", "0") : (dc > 0 ? "+\(dc)" : "\(dc)"),
                tone: dc > 0 ? .warning : .neutral
            ))
        }
        if let thenH = snap.batteryHealthPct, let nowH = model.currentBatteryHealthPct {
            let dh = nowH - thenH
            out.append(SnapshotDiff(
                label: L10n.t("健康", "Health"),
                text: dh == 0 ? L10n.t("无变化", "0%") : (dh > 0 ? "+\(dh)%" : "\(dh)%"),
                tone: dh < 0 ? .warning : (dh > 0 ? .success : .neutral)
            ))
        }
        if let thenW = snap.ssdWearPct, let nowW = model.currentSSDWearPct {
            let dw = nowW - thenW
            out.append(SnapshotDiff(
                label: L10n.t("SSD 损耗", "SSD Wear"),
                text: dw == 0 ? L10n.t("无变化", "0%") : (dw > 0 ? "+\(dw)%" : "\(dw)%"),
                tone: dw > 0 ? .warning : .neutral
            ))
        }
        return out
    }

    // MARK: - 颜色语义辅助

    private func statusTone(_ s: MCStatus?) -> DSTone {
        switch s {
        case .pass: return .success
        case .warning: return .warning
        case .critical: return .danger
        case .skipped, .unsupported, .none: return .neutral
        }
    }

    private func statusTint(_ s: MCStatus?) -> Color {
        switch s {
        case .pass: return DS.success
        case .warning: return DS.warning
        case .critical: return DS.danger
        case .skipped, .unsupported, .none: return DS.muted
        }
    }

    private func scoreColor(_ score: Int) -> Color {
        if score < 60 { return DS.danger }
        if score < 88 { return DS.warning }
        return DS.success
    }

    private func scoreTone(_ score: Int) -> DSTone {
        if score < 60 { return .danger }
        if score < 88 { return .warning }
        return .success
    }

    private func aiTone(_ fit: MCAIFitLevel) -> DSTone {
        switch fit {
        case .smooth: return .success
        case .tight: return .warning
        case .insufficient: return .neutral
        }
    }
}

/// 导出报告主按钮：使用原生 DSButton(kind: .primary) 外观，点击后在按钮下方弹出 NSMenu，
/// 彻底规避 macOS SwiftUI Menu(.borderlessButton) 丢背景与误染图标颜色的问题。
private struct MCExportMenuButton: View {
    let disabled: Bool
    let onSelect: (MCReportExporter.Format) -> Void
    @State private var anchorView: NSView?

    var body: some View {
        DSButton(L10n.t("导出报告", "Export"), icon: "download", kind: .primary) {
            showMenu()
        }
        .disabled(disabled)
        .background(AnchorCapture(view: $anchorView))
    }

    private func showMenu() {
        let menu = ContextMenu.build([
            ContextMenu.Item(L10n.t("导出 PNG 长图", "Export Long Image (PNG)"), "image") {
                onSelect(.png)
            },
            ContextMenu.Item(L10n.t("导出矢量 PDF", "Export Vector PDF"), "file-text") {
                onSelect(.pdf)
            },
        ])
        if let anchorView {
            // 非 flipped NSView 原点在左下角，y = -4 在按钮正下方 4pt 展开
            menu.popUp(positioning: nil, at: NSPoint(x: 0, y: -4), in: anchorView)
        } else {
            menu.popUp(positioning: nil, at: NSEvent.mouseLocation, in: nil)
        }
        ContextMenu.drain()
    }

    private struct AnchorCapture: NSViewRepresentable {
        @Binding var view: NSView?

        func makeNSView(context: Context) -> NSView {
            let v = NSView()
            DispatchQueue.main.async { view = v }
            return v
        }

        func updateNSView(_ nsView: NSView, context: Context) {
            if view !== nsView {
                DispatchQueue.main.async { view = nsView }
            }
        }
    }
}
