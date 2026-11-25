import AppKit
import PopBarCore
import PopBarDesign
import SwiftUI

// MARK: - 报告导出文档视图（用于 ImageRenderer 渲染 PNG 长图或矢量 PDF）

struct MCReportDocumentView: View {
    let report: MCReport

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            // 顶部标题与评分
            HStack(alignment: .top) {
                VStack(alignment: .leading, spacing: 5) {
                    Text(L10n.t("PopBar 硬件验机报告", "PopBar Hardware Inspection Report"))
                        .font(.system(size: 22, weight: .bold))
                        .foregroundStyle(Color(nsColor: NSColor(srgbRed: 0.11, green: 0.11, blue: 0.10, alpha: 1)))
                    if let p = report.profile {
                        Text("\(p.marketingName) · \(p.chip) · \(p.memoryDisplay)")
                            .font(.system(size: 13, weight: .medium))
                            .foregroundStyle(.secondary)
                        Text(L10n.t("序列号：\(p.serialNumber.isEmpty ? "未知" : p.serialNumber) · \(p.macOSVersion)",
                                    "Serial: \(p.serialNumber.isEmpty ? "Unknown" : p.serialNumber) · \(p.macOSVersion)"))
                            .font(.system(size: 11.5, design: .monospaced))
                            .foregroundStyle(.secondary)
                    }
                }
                Spacer()
                VStack(alignment: .trailing, spacing: 2) {
                    Text("\(report.score)")
                        .font(.system(size: 36, weight: .heavy, design: .rounded))
                        .foregroundStyle(scoreColor)
                    Text(report.gradeLabel)
                        .font(.system(size: 11.5, weight: .semibold))
                        .foregroundStyle(scoreColor)
                }
            }
            .padding(16)
            .background(RoundedRectangle(cornerRadius: 12).fill(Color(nsColor: NSColor(srgbRed: 0.97, green: 0.96, blue: 0.95, alpha: 1))))

            // 重大风险提醒
            if !report.criticalRisks.isEmpty {
                VStack(alignment: .leading, spacing: 8) {
                    Text(L10n.t("高风险项提示", "Critical Warnings"))
                        .font(.system(size: 13, weight: .bold))
                        .foregroundStyle(Color.red)
                    ForEach(report.criticalRisks) { item in
                        VStack(alignment: .leading, spacing: 3) {
                            Text(item.title).font(.system(size: 12.5, weight: .semibold))
                            Text(item.riskNotice ?? item.summary).font(.system(size: 11.5)).foregroundStyle(.secondary)
                        }
                        .padding(10)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .background(RoundedRectangle(cornerRadius: 8).fill(Color.red.opacity(0.08)))
                    }
                }
            }

            // 全部检测项明细
            VStack(alignment: .leading, spacing: 8) {
                Text(L10n.t("检测明细（共 \(report.items.count) 项）", "Inspection Details (\(report.items.count) items)"))
                    .font(.system(size: 13, weight: .bold))
                VStack(spacing: 0) {
                    ForEach(Array(report.items.enumerated()), id: \.element.id) { idx, item in
                        if idx > 0 {
                            Rectangle().fill(Color.black.opacity(0.08)).frame(height: 1)
                        }
                        HStack(alignment: .top, spacing: 12) {
                            Text(item.title)
                                .font(.system(size: 12, weight: .semibold))
                                .frame(width: 150, alignment: .leading)
                            Text(item.summary)
                                .font(.system(size: 11.5))
                                .foregroundStyle(.secondary)
                                .frame(maxWidth: .infinity, alignment: .leading)
                            Text(item.status.label)
                                .font(.system(size: 11, weight: .semibold))
                                .foregroundStyle(statusColor(item.status))
                                .frame(width: 68, alignment: .trailing)
                        }
                        .padding(.horizontal, 12)
                        .padding(.vertical, 8)
                    }
                }
                .overlay(RoundedRectangle(cornerRadius: 10).strokeBorder(Color.black.opacity(0.1), lineWidth: 1))
            }

            // 页脚
            HStack {
                Text(L10n.t("生成时间：\(report.generatedAt.formatted(date: .abbreviated, time: .shortened))",
                            "Generated: \(report.generatedAt.formatted(date: .abbreviated, time: .shortened))"))
                Spacer()
                Text("PopBar v\(report.appVersion) · " + L10n.t("纯本地离线检测", "Offline Local Inspection"))
            }
            .font(.system(size: 10.5))
            .foregroundStyle(.secondary)
        }
        .padding(28)
        .frame(width: 720)
        .background(Color.white)
        .environment(\.colorScheme, .light)
    }

    private var scoreColor: Color {
        if report.score < 60 { return .red }
        if report.score < 88 { return .orange }
        return Color(red: 0.18, green: 0.62, blue: 0.42)
    }

    private func statusColor(_ s: MCStatus) -> Color {
        switch s {
        case .pass: return Color(red: 0.18, green: 0.62, blue: 0.42)
        case .warning: return .orange
        case .critical: return .red
        case .skipped, .unsupported: return .secondary
        }
    }
}

// MARK: - 导出器

@MainActor
enum MCReportExporter {
    enum Format { case png, pdf }

    static func export(_ report: MCReport, format: Format) {
        let renderer = ImageRenderer(content: MCReportDocumentView(report: report))
        renderer.scale = 2.0

        let fmt = DateFormatter()
        fmt.dateFormat = "yyyyMMdd-HHmm"
        let stamp = fmt.string(from: report.generatedAt)
        let baseName = L10n.t("PopBar-硬件验机报告-\(stamp)", "PopBar-MacCheck-\(stamp)")

        switch format {
        case .png:
            guard let img = renderer.nsImage,
                  let tiff = img.tiffRepresentation,
                  let rep = NSBitmapImageRep(data: tiff),
                  let data = rep.representation(using: .png, properties: [:]) else { return }
            saveData(data, suggestedName: baseName + ".png")
        case .pdf:
            let pdfData = NSMutableData()
            renderer.render { size, draw in
                var box = CGRect(origin: .zero, size: size)
                guard let consumer = CGDataConsumer(data: pdfData),
                      let ctx = CGContext(consumer: consumer, mediaBox: &box, nil) else { return }
                ctx.beginPDFPage(nil)
                draw(ctx)
                ctx.endPDFPage()
                ctx.closePDF()
            }
            saveData(pdfData as Data, suggestedName: baseName + ".pdf")
        }
    }

    private static func saveData(_ data: Data, suggestedName: String) {
        NSApp.activateForUI()
        let panel = NSSavePanel()
        panel.nameFieldStringValue = suggestedName
        panel.canCreateDirectories = true
        panel.begin { resp in
            guard resp == .OK, let url = panel.url else { return }
            try? data.write(to: url, options: .atomic)
        }
    }
}
