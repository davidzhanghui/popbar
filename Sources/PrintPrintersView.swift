import SwiftUI

/// 打印机页:状态 / 墨量 / 控制 / 别名备注 / 默认 / 能力
struct PrintPrintersView: View {
    @ObservedObject var center: PrintCenter

    var body: some View {
        ScrollView(showsIndicators: false) {
            VStack(spacing: 10) {
                if center.data.visiblePrinters.isEmpty {
                    Text(L10n.t("没有打印机。到「管理」页添加。", "No printers. Add one from the Manage tab."))
                        .font(.system(size: 12)).foregroundStyle(SysTheme.secondary).padding(30)
                }
                ForEach(center.data.visiblePrinters) { PrinterCard(center: center, printer: $0) }
            }
        }
    }
}

private struct PrinterCard: View {
    @ObservedObject var center: PrintCenter
    let printer: PrinterRecord
    @State private var expanded = false
    @State private var alias = ""
    @State private var note = ""
    @State private var confirmRemove = false
    @State private var syncSystem = true

    private var isDefault: Bool {
        center.data.settings.defaultPrinter == printer.name
            || (center.data.settings.defaultPrinter.isEmpty && center.data.defaultPrinter()?.name == printer.name)
    }

    var body: some View {
        let p = printer
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 10) {
                Image(systemName: "printer.fill").font(.system(size: 16)).foregroundStyle(.white)
                    .frame(width: 38, height: 38)
                    .background(RoundedRectangle(cornerRadius: 9, style: .continuous).fill(PanelTheme.brandColor))
                VStack(alignment: .leading, spacing: 2) {
                    HStack(spacing: 6) {
                        Text(p.displayName).font(.system(size: 14, weight: .semibold)).lineLimit(1)
                        if isDefault { PBadge(text: L10n.t("默认", "Default"), color: PanelTheme.brandColor) }
                        if !p.accepting { PBadge(text: L10n.t("停止接收", "Rejecting"), color: .orange) }
                    }
                    Text(p.makeModel.isEmpty ? p.name : p.makeModel).font(.system(size: 11)).foregroundStyle(SysTheme.secondary).lineLimit(1)
                    if !p.location.isEmpty || !p.note.isEmpty {
                        Text([p.location, p.note].filter { !$0.isEmpty }.joined(separator: " · "))
                            .font(.system(size: 10.5)).foregroundStyle(SysTheme.tertiary).lineLimit(1)
                    }
                }
                Spacer()
                PIcon(symbol: p.favorite ? "star.fill" : "star", help: L10n.t("收藏(排在前面)", "Favorite (sort first)"),
                      tint: p.favorite ? .yellow : SysTheme.secondary) {
                    center.updateLocal(p.name, favorite: !p.favorite)
                }
                PBadge(text: PrintStyle.printerStateText(p), color: PrintStyle.printerColor(p), filled: true)
            }

            let msgs = PrintReasons.labels(p.reasons)
            if !msgs.isEmpty || !p.stateMessage.isEmpty {
                HStack(spacing: 4) {
                    Image(systemName: "exclamationmark.circle").font(.system(size: 10.5))
                    Text(msgs.isEmpty ? p.stateMessage : msgs.joined(separator: " · ")).font(.system(size: 11))
                }
                .foregroundStyle(PrintReasons.hasError(p.reasons) ? Color.red : Color.orange)
            }

            PInkBars(markers: p.markers, threshold: center.data.settings.lowInkThreshold)

            HStack(spacing: 6) {
                if p.state == PrinterStateCode.stopped {
                    PBtn(title: L10n.t("恢复打印", "Resume"), symbol: "play.fill", disabled: !center.cupsOK) { Task { await center.resume(p.name) } }
                } else {
                    PBtn(title: L10n.t("暂停", "Pause"), symbol: "pause.fill", disabled: !center.cupsOK) { Task { await center.pause(p.name) } }
                }
                PBtn(title: p.accepting ? L10n.t("停止接收", "Reject jobs") : L10n.t("开始接收", "Accept jobs"),
                     symbol: p.accepting ? "hand.raised" : "tray.and.arrow.down", disabled: !center.cupsOK) {
                    Task { await center.setAccepting(p.name, !p.accepting) }
                }
                PBtn(title: L10n.t("任务 \(center.data.jobs.filter { $0.printer == p.name && $0.isLive }.count)", "Jobs"), symbol: "list.bullet") {
                    center.jobsPrinterFilter = p.name
                    center.tab = .jobs
                }
                Spacer()
                PBtn(title: expanded ? L10n.t("收起", "Less") : L10n.t("更多", "More"), symbol: expanded ? "chevron.up" : "chevron.down") {
                    alias = p.alias; note = p.note
                    withAnimation(.easeInOut(duration: 0.15)) { expanded.toggle() }
                }
            }

            if expanded { more }
        }
        .padding(12)
        .background(CardBackground())
        .confirmationDialog(L10n.t("删除打印机「\(p.displayName)」?", "Remove printer “\(p.displayName)”?"),
                            isPresented: $confirmRemove, titleVisibility: .visible) {
            Button(L10n.t("删除", "Remove"), role: .destructive) { Task { await center.removePrinter(p.name) } }
        } message: {
            Text(L10n.t("会从 CUPS 里删除这台打印机的队列。历史任务与统计保留,可在「管理」页恢复显示;重新添加后即可继续使用。",
                        "Removes the printer's queue from CUPS. Job history and stats are kept and the printer can be restored from Manage."))
        }
    }

    private var more: some View {
        let p = printer
        return VStack(alignment: .leading, spacing: 8) {
            Divider().opacity(0.5)
            PTable {
                PRow(title: L10n.t("别名", "Alias")) {
                    PField(placeholder: p.info, text: $alias, width: 320, onSubmit: { center.updateLocal(p.name, alias: alias) })
                }
                PRow(title: L10n.t("备注", "Note")) {
                    PField(placeholder: L10n.t("例如:书房 / 公司 3 楼", "e.g. study / 3rd floor"), text: $note, width: 320,
                           onSubmit: { center.updateLocal(p.name, note: note) })
                }
            }
            HStack(spacing: 6) {
                PBtn(title: L10n.t("保存名称与备注", "Save alias & note"), symbol: "checkmark") {
                    center.updateLocal(p.name, alias: alias, note: note)
                    center.say(L10n.t("已保存", "Saved"))
                }
                Spacer()
            }
            HStack(spacing: 8) {
                PBtn(title: L10n.t("设为默认打印机", "Set as default"), symbol: "star", disabled: isDefault) {
                    Task { await center.setDefault(p.name, syncSystem: syncSystem) }
                }
                Toggle(L10n.t("同时写入系统默认", "Also set the system default"), isOn: $syncSystem)
                    .toggleStyle(.checkbox).font(.system(size: 11)).foregroundStyle(SysTheme.secondary)
            }
            capsBlock(p.caps)
            HStack(spacing: 6) {
                PBtn(title: L10n.t("取消全部任务", "Cancel all jobs"), symbol: "xmark.circle", destructive: true,
                     disabled: !center.cupsOK || center.data.liveJobs.filter { $0.printer == p.name }.isEmpty) {
                    Task { await center.cancelAll(printer: p.name) }
                }
                PBtn(title: L10n.t("删除打印机…", "Remove printer…"), symbol: "trash", destructive: true,
                     disabled: !center.cupsOK) { confirmRemove = true }
                Spacer()
                Text(p.name).font(.system(size: 10)).foregroundStyle(SysTheme.tertiary).textSelection(.enabled)
            }
        }
    }

    private func capsBlock(_ c: PrintCaps) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(L10n.t("能力", "Capabilities")).font(.system(size: 11, weight: .semibold))
            capLine(L10n.t("纸张", "Paper"), c.media.filter { !$0.contains("fullbleed") && !$0.hasPrefix("custom_") }
                .prefix(12).map(PrintLabels.media).joined(separator: " · "))
            capLine(L10n.t("纸质", "Paper type"), c.mediaTypes.map(PrintLabels.mediaType).joined(separator: " · "))
            capLine(L10n.t("色彩", "Color"), c.colorModes.map(PrintLabels.color).joined(separator: " · "))
            capLine(L10n.t("质量", "Quality"), c.qualities.map(PrintLabels.quality).joined(separator: " · "))
            capLine(L10n.t("双面", "Duplex"), c.sides.contains { $0 != "one-sided" } ? L10n.t("支持", "Supported") : L10n.t("仅单面", "One-sided only"))
            capLine(L10n.t("选页", "Page ranges"), c.pageRanges ? L10n.t("支持", "Supported") : L10n.t("不支持", "No"))
        }
    }

    @ViewBuilder private func capLine(_ t: String, _ v: String) -> some View {
        if !v.isEmpty {
            HStack(alignment: .top, spacing: 6) {
                Text(t).font(.system(size: 10.5)).foregroundStyle(SysTheme.tertiary).frame(width: 52, alignment: .leading)
                Text(v).font(.system(size: 10.5)).foregroundStyle(SysTheme.secondary).fixedSize(horizontal: false, vertical: true)
            }
        }
    }
}
