import Cocoa

/// 录屏导出类面板(视频 / GIF)共用的控件:渐变底、分组卡片、左标题右控件的行,
/// 视觉与「设置」窗口一致。
@MainActor
enum RecordPanelKit {
    static func label(_ s: String, size: CGFloat = 13, secondary: Bool = false) -> NSTextField {
        let t = NSTextField(labelWithString: s)
        t.font = .systemFont(ofSize: size)
        if secondary { t.textColor = .secondaryLabelColor }
        return t
    }

    // 与「设置」窗口同一套视觉:渐变底 + 圆角卡片 + 左标题副标题/右控件的行
    static let lightTheme = PanelTheme(dark: false)
    static let darkTheme = PanelTheme(dark: true)
    static func dyn(_ l: NSColor, _ d: NSColor) -> NSColor {
        NSColor(name: nil) { $0.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua ? d : l }
    }

    static func sectionHeader(_ text: String) -> NSView {
        let l = NSTextField(labelWithString: text)
        l.font = .systemFont(ofSize: 11, weight: .medium)
        l.textColor = .secondaryLabelColor
        let wrap = NSView()
        wrap.addSubview(l)
        l.translatesAutoresizingMaskIntoConstraints = false
        l.leadingAnchor.constraint(equalTo: wrap.leadingAnchor, constant: 14).isActive = true
        l.topAnchor.constraint(equalTo: wrap.topAnchor).isActive = true
        l.bottomAnchor.constraint(equalTo: wrap.bottomAnchor).isActive = true
        return wrap
    }

    static func row(_ title: String, _ subtitle: String = "", _ control: NSView) -> NSView {
        let t = Self.label(title)
        var views: [NSView] = [t]
        if !subtitle.isEmpty {
            let s = Self.label(subtitle, size: 11, secondary: true)
            views.append(s)
        }
        let labels = NSStackView(views: views)
        labels.orientation = .vertical
        labels.alignment = .leading
        labels.spacing = 2
        labels.setContentCompressionResistancePriority(.init(900), for: .horizontal)
        let spring = NSView()
        spring.setContentHuggingPriority(.init(1), for: .horizontal)
        spring.setContentCompressionResistancePriority(.init(1), for: .horizontal)
        control.setContentHuggingPriority(.required, for: .horizontal)
        control.setContentCompressionResistancePriority(.required, for: .horizontal)
        let r = NSStackView(views: [labels, spring, control])
        r.orientation = .horizontal
        r.alignment = .centerY
        r.spacing = 12
        r.edgeInsets = NSEdgeInsets(top: 10, left: 14, bottom: 10, right: 14)
        let natural = max(labels.fittingSize.height, control.fittingSize.height) + 20
        r.heightAnchor.constraint(equalToConstant: natural).isActive = true
        return r
    }

    /// 整行放一个自适应内容(标记点按钮)
    static func plainRow(_ content: NSView) -> NSView {
        let r = NSStackView(views: [content])
        r.orientation = .horizontal
        r.alignment = .centerY
        r.edgeInsets = NSEdgeInsets(top: 10, left: 14, bottom: 10, right: 14)
        return r
    }

    static func card(_ rows: [NSView]) -> NSView {
        let col = NSStackView()
        col.orientation = .vertical
        col.alignment = .leading
        col.spacing = 0
        for (i, r) in rows.enumerated() {
            col.addArrangedSubview(r)
            r.leadingAnchor.constraint(equalTo: col.leadingAnchor).isActive = true
            r.trailingAnchor.constraint(equalTo: col.trailingAnchor).isActive = true
            if i < rows.count - 1 {
                let sep = NSBox()
                sep.boxType = .separator
                col.addArrangedSubview(sep)
                sep.leadingAnchor.constraint(equalTo: col.leadingAnchor, constant: 14).isActive = true
                sep.trailingAnchor.constraint(equalTo: col.trailingAnchor).isActive = true
            }
        }
        let box = NSBox()
        box.boxType = .custom
        box.cornerRadius = 10
        box.borderWidth = 1
        box.borderColor = Self.dyn(Self.lightTheme.surfaceBorder, Self.darkTheme.surfaceBorder)
        box.fillColor = Self.dyn(Self.lightTheme.surface, Self.darkTheme.surface)
        box.contentViewMargins = .zero
        col.translatesAutoresizingMaskIntoConstraints = false
        box.contentView?.addSubview(col)
        if let host = box.contentView {
            NSLayoutConstraint.activate([
                col.leadingAnchor.constraint(equalTo: host.leadingAnchor),
                col.trailingAnchor.constraint(equalTo: host.trailingAnchor),
                col.topAnchor.constraint(equalTo: host.topAnchor),
                col.bottomAnchor.constraint(equalTo: host.bottomAnchor),
            ])
        }
        return box
    }
}
