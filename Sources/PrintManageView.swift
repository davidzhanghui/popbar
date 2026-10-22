import SwiftUI
import UniformTypeIdentifiers

/// 管理页:添加 / 发现 / 恢复打印机 · 预设 · 偏好 · 数据维护(清理、备份、恢复)
struct PrintManageView: View {
    @ObservedObject var center: PrintCenter
    @State private var discovered: [PrintCUPS.Discovered]?
    @State private var discovering = false
    @State private var newName = ""
    @State private var newURI = ""
    @State private var newLocation = ""
    @State private var adding = false
    @State private var cleanupPreview: PrintData.CleanupResult?
    @State private var confirmRestore: URL?

    var body: some View {
        let d = center.data
        ScrollView(showsIndicators: false) {
            VStack(spacing: 10) {
                addSection
                let removed = d.printers.filter(\.hidden)
                if !removed.isEmpty {
                    PSection(title: L10n.t("已删除的打印机", "Removed printers")) {
                        ForEach(removed) { p in
                            HStack {
                                Text(p.displayName).font(.system(size: 12))
                                Text(p.name).font(.system(size: 10)).foregroundStyle(SysTheme.tertiary)
                                Spacer()
                                PBtn(title: L10n.t("恢复显示", "Restore"), symbol: "arrow.uturn.backward") { center.restorePrinter(p.name) }
                            }
                        }
                        Text(L10n.t("软删除:历史任务与统计保留。若 CUPS 里已没有这台机器,恢复后会显示「CUPS 中已不存在」,重新添加即可。",
                                    "Soft-deleted: history and stats are kept. If CUPS no longer has the queue, add it again."))
                            .font(.system(size: 10.5)).foregroundStyle(SysTheme.tertiary)
                    }
                }
                presetsSection
                prefsSection
                dataSection
            }
        }
        .confirmationDialog(L10n.t("恢复备份?", "Restore backup?"),
                            isPresented: Binding(get: { confirmRestore != nil }, set: { if !$0 { confirmRestore = nil } }),
                            titleVisibility: .visible, presenting: confirmRestore) { url in
            Button(L10n.t("恢复", "Restore"), role: .destructive) {
                Task { center.say((await center.restore(from: url))?.text ?? L10n.t("已恢复(旧数据已改名保留为 Print.bak-…)", "Restored (old data kept as Print.bak-…)")) }
            }
        } message: { _ in
            Text(L10n.t("当前的打印数据会被改名保留为 Print.bak-<时间>,然后用备份内容替换。", "Current print data is renamed to Print.bak-<time>, then replaced by the backup."))
        }
    }

    // MARK: 添加

    private var addSection: some View {
        PSection(title: L10n.t("添加打印机", "Add a printer"),
                 trailing: AnyView(PBtn(title: discovering ? L10n.t("搜索中…", "Searching…") : L10n.t("搜索局域网打印机", "Find on network"),
                                        symbol: "dot.radiowaves.left.and.right", disabled: discovering || !center.cupsOK) { discover() })) {
            if let list = discovered {
                if list.isEmpty {
                    Text(L10n.t("没有发现打印机。确认它与这台 Mac 在同一网络,或在下面手动输入地址。", "None found. Check that it is on the same network, or enter an address below."))
                        .font(.system(size: 11)).foregroundStyle(SysTheme.secondary)
                }
                ForEach(list, id: \.uri) { r in
                    HStack(spacing: 8) {
                        Image(systemName: "printer").foregroundStyle(SysTheme.secondary)
                        VStack(alignment: .leading, spacing: 1) {
                            Text(r.host).font(.system(size: 12)).lineLimit(1)
                            Text(r.uri).font(.system(size: 10)).foregroundStyle(SysTheme.tertiary).lineLimit(1).truncationMode(.middle)
                        }
                        Spacer()
                        if r.configured { PBadge(text: L10n.t("已添加", "Added"), color: .green) }
                        else {
                            PBtn(title: L10n.t("添加", "Add"), symbol: "plus", disabled: adding) {
                                newURI = r.uri
                                newName = suggestName(r.host)
                                add()
                            }
                        }
                    }
                }
            }
            Text(L10n.t("手动添加(IPP Everywhere 免驱)", "Manual (driverless IPP Everywhere)")).font(.system(size: 11, weight: .semibold))
            PTable {
                PRow(title: L10n.t("名称", "Name"), hint: L10n.t("字母 数字 _ . -", "letters digits _ . -")) {
                    PField(placeholder: "Office_Printer", text: $newName, width: 300)
                }
                PRow(title: L10n.t("地址", "URI")) {
                    PField(placeholder: "ipp://192.168.1.20/ipp/print", text: $newURI, width: 300)
                }
                PRow(title: L10n.t("位置", "Location")) {
                    PField(placeholder: L10n.t("可选", "Optional"), text: $newLocation, width: 300)
                }
            }
            HStack {
                Spacer()
                PBtn(title: adding ? L10n.t("添加中…", "Adding…") : L10n.t("添加", "Add"), symbol: "plus", prominent: true,
                     disabled: adding || newName.isEmpty || newURI.isEmpty || !center.cupsOK) { add() }
            }
        }
    }

    private func suggestName(_ host: String) -> String {
        let base = host.replacingOccurrences(of: ".local", with: "")
        return String(base.map { $0.isLetter || $0.isNumber || "_.-".contains($0) ? $0 : "_" }.prefix(64))
    }

    private func discover() {
        discovering = true
        Task {
            discovered = await center.discover()
            discovering = false
        }
    }

    private func add() {
        adding = true
        let n = newName, u = newURI, l = newLocation
        Task {
            if await center.addPrinter(name: n, uri: u, location: l) { newName = ""; newURI = ""; newLocation = ""; discover() }
            adding = false
        }
    }

    // MARK: 预设

    private var presetsSection: some View {
        PSection(title: L10n.t("打印预设", "Presets")) {
            if center.data.presets.isEmpty {
                Text(L10n.t("在「打印」页调好参数后点「存为预设」。预设只保存色彩、质量、纸张、双面、方向等,不含份数与页码范围。",
                            "Set options on the Print tab, then “Save preset”. Copies and page ranges are not stored."))
                    .font(.system(size: 11)).foregroundStyle(SysTheme.secondary)
            }
            ForEach(center.data.presets) { p in PresetRow(center: center, preset: p) }
        }
    }

    // MARK: 偏好

    private var prefsSection: some View {
        let s = center.data.settings
        return PSection(title: L10n.t("偏好", "Preferences")) {
            PTable {
                PRow(title: L10n.t("完成通知", "Notify")) {
                    Toggle("", isOn: Binding(get: { s.notify }, set: { v in center.updateSettings { $0.notify = v } }))
                        .toggleStyle(.switch).controlSize(.small).labelsHidden()
                    Text(L10n.t("作业完成 / 失败时发系统通知", "When a job finishes or fails")).font(.system(size: 11.5)).foregroundStyle(SysTheme.secondary)
                }
                PRow(title: L10n.t("打印确认", "Confirm")) {
                    Toggle("", isOn: Binding(get: { s.confirmBeforePrint }, set: { v in center.updateSettings { $0.confirmBeforePrint = v } }))
                        .toggleStyle(.switch).controlSize(.small).labelsHidden()
                    Text(L10n.t("打印前弹出确认", "Ask before printing")).font(.system(size: 11.5)).foregroundStyle(SysTheme.secondary)
                }
                PRow(title: L10n.t("墨量预警", "Low ink")) {
                    PStepper(value: Binding(get: { s.lowInkThreshold }, set: { v in center.updateSettings { $0.lowInkThreshold = v } }),
                             range: 1...90, step: 5, prefix: "< ", suffix: "%", width: 130)
                }
                PRow(title: L10n.t("默认打印机", "Default")) {
                    PMenu(label: "", selection: Binding(get: { s.defaultPrinter }, set: { v in center.updateSettings { $0.defaultPrinter = v } }),
                          options: [("", L10n.t("自动(第一台)", "Automatic"))] + center.data.visiblePrinters.map { ($0.name, $0.displayName) }, width: 260)
                }
            }
        }
    }

    // MARK: 数据维护

    private var dataSection: some View {
        let s = center.data.settings
        return PSection(title: L10n.t("数据与维护", "Data & maintenance")) {
            Text(L10n.t("清理有两条不同的保留期:外部应用的作业超期后连记录一起删;PopBar 提交的作业记录永远保留(历史和统计要用),只删超期的原文件,之后「重新打印」不可用。排队 / 打印中的任务无论多老都不碰。",
                        "Two retention rules: jobs from other apps are deleted entirely after the limit; PopBar jobs keep their record forever (history & stats) and only lose the original file. Active jobs are never touched."))
                .font(.system(size: 10.5)).foregroundStyle(SysTheme.secondary).fixedSize(horizontal: false, vertical: true)
            PTable {
                PRow(title: L10n.t("外部作业", "External")) {
                    PStepper(value: Binding(get: { s.externalJobKeepDays }, set: { v in center.updateSettings { $0.externalJobKeepDays = v } }),
                             range: 1...365, suffix: L10n.t(" 天", " days"), width: 130)
                    Text(L10n.t("超期连记录一起删", "deleted entirely after this")).font(.system(size: 11)).foregroundStyle(SysTheme.tertiary)
                }
                PRow(title: L10n.t("原文件", "Files")) {
                    PStepper(value: Binding(get: { s.jobFileRetentionDays }, set: { v in center.updateSettings { $0.jobFileRetentionDays = v } }),
                             range: 1...3650, suffix: L10n.t(" 天", " days"), width: 130)
                    Text(L10n.t("超期只删文件,记录保留", "only the file goes; the record stays")).font(.system(size: 11)).foregroundStyle(SysTheme.tertiary)
                }
                PRow(title: L10n.t("自动清理", "Auto clean")) {
                    PStepper(value: Binding(get: { s.maintenanceIntervalHours }, set: { v in center.updateSettings { $0.maintenanceIntervalHours = v } }),
                             range: 1...168, prefix: L10n.t("每 ", "every "), suffix: L10n.t(" 小时", " h"), width: 130)
                    Text(L10n.t("重启后生效", "applies after restart")).font(.system(size: 11)).foregroundStyle(SysTheme.tertiary)
                }
            }
            HStack(spacing: 6) {
                PBtn(title: L10n.t("预演(只统计)", "Dry run"), symbol: "eye") { cleanupPreview = center.runCleanup(dryRun: true) }
                PBtn(title: L10n.t("立即清理", "Clean now"), symbol: "trash") {
                    let r = center.runCleanup()
                    cleanupPreview = nil
                    center.say(L10n.t("已清理 \(r.rowsDeleted) 条记录、\(r.filesDeleted) 份原文件", "Removed \(r.rowsDeleted) records, \(r.filesDeleted) files"))
                }
                Spacer()
            }
            if let r = cleanupPreview {
                Text(L10n.t("预演:会删除 \(r.rowsDeleted) 条记录、\(r.filesDeleted) 份原文件(未实际删除)", "Dry run: would remove \(r.rowsDeleted) records and \(r.filesDeleted) files (nothing deleted)"))
                    .font(.system(size: 11)).foregroundStyle(SysTheme.brand)
            }
            if !center.lastCleanup.isEmpty {
                Text(L10n.t("上次清理:", "Last cleanup: ") + center.lastCleanup).font(.system(size: 10.5)).foregroundStyle(SysTheme.tertiary)
            }
            Divider().opacity(0.4)
            HStack(spacing: 6) {
                PBtn(title: L10n.t("备份…", "Back up…"), symbol: "square.and.arrow.down") { backup() }
                PBtn(title: L10n.t("从备份恢复…", "Restore…"), symbol: "square.and.arrow.up") { chooseRestore() }
                PBtn(title: L10n.t("在访达中显示数据目录", "Reveal data folder"), symbol: "folder") {
                    NSWorkspace.shared.activateFileViewerSelecting([PrintStorage.directory])
                }
                Spacer()
            }
            Text(L10n.t("备份包含作业历史、预设、设置与原文件副本,可用于换机迁移。", "Backups include history, presets, settings and file copies — handy for moving to a new Mac."))
                .font(.system(size: 10.5)).foregroundStyle(SysTheme.tertiary)
        }
    }

    private func backup() {
        let p = NSSavePanel()
        p.nameFieldStringValue = "PopBar-Print-\(Date().formatted(.iso8601.year().month().day())).tar.gz"
        p.allowedContentTypes = [UTType(filenameExtension: "gz") ?? .data]
        NSApp.activateForUI()
        guard p.runModal() == .OK, let url = p.url else { return }
        Task { center.say((await center.backup(to: url))?.text ?? L10n.t("备份完成", "Backup complete")) }
    }

    private func chooseRestore() {
        let p = NSOpenPanel()
        p.allowsMultipleSelection = false
        p.canChooseDirectories = false
        NSApp.activateForUI()
        if p.runModal() == .OK, let u = p.url { confirmRestore = u }
    }
}

private struct PresetRow: View {
    @ObservedObject var center: PrintCenter
    let preset: PrintPreset
    @State private var name = ""
    @State private var editing = false

    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: "slider.horizontal.3").font(.system(size: 11)).foregroundStyle(SysTheme.secondary)
            if editing {
                PField(text: $name, width: nil, onSubmit: { commit() })
                PBtn(title: L10n.t("保存", "Save"), prominent: true) { commit() }
            } else {
                VStack(alignment: .leading, spacing: 1) {
                    Text(preset.name).font(.system(size: 12.5))
                    Text(summary).font(.system(size: 10.5)).foregroundStyle(SysTheme.secondary).lineLimit(1)
                }
                Spacer()
                PIcon(symbol: "pencil", help: L10n.t("重命名", "Rename")) { name = preset.name; editing = true }
                PIcon(symbol: "trash", help: L10n.t("删除", "Delete"), tint: .red) { center.deletePreset(preset.id) }
            }
        }
    }

    private func commit() {
        if let e = center.renamePreset(preset.id, name: name) { center.say(e) } else { editing = false }
    }

    private var summary: String {
        let o = preset.options
        var p: [String] = []
        let printer = preset.printer.flatMap { center.data.printer($0)?.displayName } ?? L10n.t("所有打印机", "All printers")
        p.append(printer)
        if !o.color.isEmpty { p.append(PrintLabels.color(o.color)) }
        if !o.quality.isEmpty { p.append(PrintLabels.quality(o.quality)) }
        if !o.media.isEmpty { p.append(PrintLabels.media(o.media)) }
        if !o.sides.isEmpty { p.append(PrintLabels.sides(o.sides)) }
        if o.numberUp > 1 { p.append(L10n.t("每张 \(o.numberUp) 页", "\(o.numberUp)-up")) }
        return p.joined(separator: " · ")
    }
}
