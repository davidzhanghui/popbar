import Cocoa
import SwiftUI

// 组件库（与 Decklet `ui.rs` 一一对应）。各模块不再自己画按钮和卡片，所有颜色都来自令牌。

// MARK: - 文字

public struct DSEyebrow: View {
    let text: String
    public init(_ text: String) { self.text = text }
    public var body: some View {
        Text(text).font(DS.font(11, .medium)).foregroundStyle(DS.faint)
    }
}

public extension Text {
    func dsHeading() -> some View { font(DS.heading).foregroundStyle(DS.text) }
    func dsBody() -> some View { font(DS.body).foregroundStyle(DS.text2) }
    func dsCaption() -> some View { font(DS.caption).foregroundStyle(DS.muted) }
}

// MARK: - 按钮

public enum DSButtonKind { case primary, secondary, ghost, danger }

public struct DSButton: View {
    let title: String
    let icon: String?
    let kind: DSButtonKind
    let action: () -> Void
    @State private var hovering = false
    @Environment(\.isEnabled) private var enabled

    public init(_ title: String, icon: String? = nil, kind: DSButtonKind = .secondary, action: @escaping () -> Void) {
        self.title = title
        self.icon = icon
        self.kind = kind
        self.action = action
    }

    private var colors: (bg: Color, fg: Color, border: Color, hover: Color) {
        switch kind {
        case .primary: return (DS.accent, DS.onAccent, DS.accent, DS.accent.opacity(0.88))
        case .secondary: return (DS.surface, DS.text, DS.borderStrong, DS.surface2)
        case .ghost: return (.clear, DS.text2, .clear, DS.hover)
        case .danger: return (DS.dangerSoft, DS.danger, .clear, DS.danger.opacity(0.18))
        }
    }

    public var body: some View {
        let c = colors
        Button(action: action) {
            HStack(spacing: 6) {
                if let icon { Icon(icon, size: 14, color: c.fg) }
                Text(title).font(DS.font(12.5, .medium)).lineLimit(1)
            }
            .foregroundStyle(c.fg)
            .padding(.horizontal, 12)
            .frame(height: 30)
            .background(RoundedRectangle(cornerRadius: Theme.Radius.button).fill(hovering && enabled ? c.hover : c.bg))
            .overlay(RoundedRectangle(cornerRadius: Theme.Radius.button).strokeBorder(c.border, lineWidth: 1))
            .contentShape(Rectangle())
            .opacity(enabled ? 1 : 0.45)
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
    }
}

public struct DSIconButton: View {
    let icon: String
    let tint: Color?
    let help: String?
    let size: CGFloat
    let action: () -> Void
    @State private var hovering = false

    public init(_ icon: String, tint: Color? = nil, help: String? = nil, size: CGFloat = 28, action: @escaping () -> Void) {
        self.icon = icon
        self.tint = tint
        self.help = help
        self.size = size
        self.action = action
    }

    public var body: some View {
        Button(action: action) {
            Icon(icon, size: 16, color: tint ?? DS.muted)
                .frame(width: size, height: size)
                .background(RoundedRectangle(cornerRadius: Theme.Radius.button).fill(hovering ? DS.hover : .clear))
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
        .help(help ?? "")
    }
}

// MARK: - 开关 / 分段 / 复选框

public struct DSToggle: View {
    @Binding var isOn: Bool
    public init(isOn: Binding<Bool>) { _isOn = isOn }
    public var body: some View {
        Button { withAnimation(.easeOut(duration: 0.12)) { isOn.toggle() } } label: {
            ZStack(alignment: isOn ? .trailing : .leading) {
                Capsule().fill(isOn ? DS.accent : DS.borderStrong)
                Circle().fill(Color.white).frame(width: 14, height: 14).padding(2)
                    .shadow(color: .black.opacity(0.15), radius: 1, y: 0.5)
            }
            .frame(width: 32, height: 18)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }
}

public struct DSSegmented<T: Hashable>: View {
    @Binding var selection: T
    let options: [(T, String)]
    public init(selection: Binding<T>, options: [(T, String)]) {
        _selection = selection
        self.options = options
    }
    public var body: some View {
        HStack(spacing: 2) {
            ForEach(Array(options.enumerated()), id: \.offset) { _, opt in
                let selected = opt.0 == selection
                Button { selection = opt.0 } label: {
                    Text(opt.1)
                        .font(DS.font(12.5, selected ? .medium : .regular))
                        .foregroundStyle(selected ? DS.text : DS.muted)
                        .padding(.horizontal, 10)
                        .frame(height: 24)
                        .background(RoundedRectangle(cornerRadius: 6).fill(selected ? DS.surface : .clear)
                            .shadow(color: selected ? DS.shadow.opacity(0.6) : .clear, radius: 1, y: 0.5))
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
            }
        }
        .padding(2)
        .background(RoundedRectangle(cornerRadius: Theme.Radius.button).fill(DS.surface2))
        .overlay(RoundedRectangle(cornerRadius: Theme.Radius.button).strokeBorder(DS.border, lineWidth: 1))
    }
}

public enum TriState { case on, mixed, off }

public struct DSTriCheckbox: View {
    let state: TriState
    let action: () -> Void
    public init(_ state: TriState, action: @escaping () -> Void) {
        self.state = state
        self.action = action
    }
    public var body: some View {
        Button(action: action) {
            ZStack {
                RoundedRectangle(cornerRadius: Theme.Radius.checkbox)
                    .fill(state == .off ? Color.clear : DS.accent)
                RoundedRectangle(cornerRadius: Theme.Radius.checkbox)
                    .strokeBorder(state == .off ? DS.borderStrong : DS.accent, lineWidth: 1.2)
                switch state {
                case .on: Icon("check", size: 11, color: DS.onAccent)
                case .mixed: Icon("minus", size: 11, color: DS.onAccent)
                case .off: EmptyView()
                }
            }
            .frame(width: 16, height: 16)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }
}

public struct DSCheckbox: View {
    @Binding var isOn: Bool
    public init(isOn: Binding<Bool>) { _isOn = isOn }
    public var body: some View {
        DSTriCheckbox(isOn ? .on : .off) { isOn.toggle() }
    }
}

// MARK: - 卡片 / 设置行

public struct DSCard<Content: View>: View {
    let padding: CGFloat
    let content: Content
    public init(padding: CGFloat = 16, @ViewBuilder content: () -> Content) {
        self.padding = padding
        self.content = content()
    }
    public var body: some View {
        content
            .padding(padding)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(RoundedRectangle(cornerRadius: Theme.Radius.card).fill(DS.surface))
            .overlay(RoundedRectangle(cornerRadius: Theme.Radius.card).strokeBorder(DS.border, lineWidth: 1))
    }
}

/// 设置页分组：卡片里放若干 DSSettingRow，行间用细线分隔（DSDivider）
public struct DSGroup<Content: View>: View {
    let title: String?
    let content: Content
    public init(_ title: String? = nil, @ViewBuilder content: () -> Content) {
        self.title = title
        self.content = content()
    }
    public var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            if let title { DSEyebrow(title).padding(.leading, 2) }
            VStack(spacing: 0) { content }
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(RoundedRectangle(cornerRadius: Theme.Radius.card).fill(DS.surface))
                .overlay(RoundedRectangle(cornerRadius: Theme.Radius.card).strokeBorder(DS.border, lineWidth: 1))
        }
    }
}

public struct DSDivider: View {
    let inset: CGFloat
    public init(inset: CGFloat = 16) { self.inset = inset }
    public var body: some View {
        Rectangle().fill(DS.border).frame(height: 1).padding(.horizontal, inset)
    }
}

/// 「标题 + 说明 + 右侧控件」行
public struct DSSettingRow<Control: View>: View {
    let title: String
    let subtitle: String?
    let subtitleTone: DSTone?
    let control: Control
    public init(_ title: String, subtitle: String? = nil, subtitleTone: DSTone? = nil, @ViewBuilder control: () -> Control) {
        self.title = title
        self.subtitle = subtitle
        self.subtitleTone = subtitleTone
        self.control = control()
    }
    public var body: some View {
        HStack(alignment: .center, spacing: 16) {
            VStack(alignment: .leading, spacing: 3) {
                Text(title).font(DS.font(13, .medium)).foregroundStyle(DS.text)
                if let subtitle, !subtitle.isEmpty {
                    Text(subtitle).font(DS.caption).foregroundStyle(subtitleTone == .danger ? DS.danger : DS.muted)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            Spacer(minLength: 8)
            control
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 12)
        .frame(minHeight: 52)
    }
}

// MARK: - 标签 / 快捷键

public enum DSTone { case neutral, accent, success, danger, warning }

public struct DSChip: View {
    let text: String
    let tone: DSTone
    let icon: String?
    public init(_ text: String, tone: DSTone = .neutral, icon: String? = nil) {
        self.text = text
        self.tone = tone
        self.icon = icon
    }
    private var colors: (Color, Color) {
        switch tone {
        case .neutral: return (DS.surface2, DS.muted)
        case .accent: return (DS.accentSoft, DS.accent)
        case .success: return (DS.successSoft, DS.success)
        case .danger: return (DS.dangerSoft, DS.danger)
        case .warning: return (DS.warningSoft, DS.warning)
        }
    }
    public var body: some View {
        let (bg, fg) = colors
        HStack(spacing: 4) {
            if let icon { Icon(icon, size: 11, color: fg) }
            Text(text).font(DS.font(11, .medium))
        }
        .foregroundStyle(fg)
        .padding(.horizontal, 7)
        .frame(height: 20)
        .background(Capsule().fill(bg))
    }
}

public struct DSKbd: View {
    let text: String
    public init(_ text: String) { self.text = text }
    public var body: some View {
        Text(text)
            .font(.system(size: 11.5, weight: .medium, design: .rounded))
            .foregroundStyle(DS.text2)
            .padding(.horizontal, 6)
            .frame(minWidth: 22, minHeight: 20)
            .background(RoundedRectangle(cornerRadius: 5).fill(DS.surface2))
            .overlay(RoundedRectangle(cornerRadius: 5).strokeBorder(DS.border, lineWidth: 1))
    }
}

// MARK: - 空状态

public struct DSEmptyState: View {
    let icon: String
    let title: String
    let message: String?
    let actionTitle: String?
    let action: (() -> Void)?
    public init(icon: String, title: String, message: String? = nil, actionTitle: String? = nil, action: (() -> Void)? = nil) {
        self.icon = icon
        self.title = title
        self.message = message
        self.actionTitle = actionTitle
        self.action = action
    }
    public var body: some View {
        VStack(spacing: 10) {
            Icon(icon, size: 22, color: DS.muted)
                .frame(width: 44, height: 44)
                .background(Circle().fill(DS.surface2))
            Text(title).font(DS.font(14, .semibold)).foregroundStyle(DS.text)
            if let message {
                Text(message).font(DS.caption).foregroundStyle(DS.muted)
                    .multilineTextAlignment(.center).frame(maxWidth: 320)
            }
            if let actionTitle, let action {
                DSButton(actionTitle, kind: .primary, action: action).padding(.top, 4)
            }
        }
        .padding(28)
        .frame(maxWidth: .infinity)
    }
}

// MARK: - 输入框

public struct DSField: View {
    let placeholder: String
    @Binding var text: String
    let mono: Bool
    public init(_ placeholder: String, text: Binding<String>, mono: Bool = false) {
        self.placeholder = placeholder
        _text = text
        self.mono = mono
    }
    public var body: some View {
        TextField(placeholder, text: $text)
            .textFieldStyle(.plain)
            .font(mono ? DS.mono : DS.body)
            .foregroundStyle(DS.text)
            .padding(.horizontal, 10)
            .frame(height: 30)
            .background(RoundedRectangle(cornerRadius: Theme.Radius.button).fill(DS.surface2))
            .overlay(RoundedRectangle(cornerRadius: Theme.Radius.button).strokeBorder(DS.borderStrong, lineWidth: 1))
    }
}

/// 显示为掩码的输入框（API Key）。只影响显示：存储方式不变，仍明文写进 config.json
public struct DSSecureField: View {
    let placeholder: String
    @Binding var text: String
    @State private var reveal = false
    public init(_ placeholder: String, text: Binding<String>) {
        self.placeholder = placeholder
        _text = text
    }
    public var body: some View {
        HStack(spacing: 4) {
            Group {
                if reveal { TextField(placeholder, text: $text) } else { SecureField(placeholder, text: $text) }
            }
            .textFieldStyle(.plain)
            .font(DS.mono)
            .foregroundStyle(DS.text)
            Button { reveal.toggle() } label: { Icon(reveal ? "eye-off" : "eye", size: 14) }
                .buttonStyle(.plain)
        }
        .padding(.horizontal, 10)
        .frame(height: 30)
        .background(RoundedRectangle(cornerRadius: Theme.Radius.button).fill(DS.surface2))
        .overlay(RoundedRectangle(cornerRadius: Theme.Radius.button).strokeBorder(DS.borderStrong, lineWidth: 1))
    }
}

// MARK: - 进度 / 柱状图 / 数值

public struct DSProgress: View {
    let value: Double
    let tint: Color
    public init(_ value: Double, tint: Color = DS.accent) {
        self.value = value
        self.tint = tint
    }
    public var body: some View {
        GeometryReader { g in
            ZStack(alignment: .leading) {
                Capsule().fill(DS.surface2)
                Capsule().fill(tint).frame(width: max(0, min(1, value)) * g.size.width)
            }
        }
        .frame(height: 5)
    }
}

/// 迷你柱状图（最近 N 次采样）
public struct DSBars: View {
    let values: [Double]
    let maxValue: Double
    let tint: Color
    public init(_ values: [Double], max: Double? = nil, tint: Color = DS.accent) {
        self.values = values
        self.maxValue = max ?? (values.max() ?? 1)
        self.tint = tint
    }
    public var body: some View {
        GeometryReader { g in
            let n = max(values.count, 1)
            let w = g.size.width / CGFloat(n)
            HStack(alignment: .bottom, spacing: 0) {
                ForEach(Array(values.enumerated()), id: \.offset) { _, v in
                    let h = maxValue > 0 ? CGFloat(v / maxValue) * g.size.height : 0
                    Rectangle().fill(tint.opacity(0.85))
                        .frame(width: max(1, w - 1), height: max(1, h))
                        .frame(width: w, alignment: .bottom)
                }
            }
            .frame(maxHeight: .infinity, alignment: .bottom)
        }
    }
}

public struct DSStat: View {
    let label: String
    let value: String
    let detail: String?
    public init(_ label: String, value: String, detail: String? = nil) {
        self.label = label
        self.value = value
        self.detail = detail
    }
    public var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(label).font(DS.caption).foregroundStyle(DS.muted)
            Text(value).font(DS.font(20, .semibold)).foregroundStyle(DS.text).monospacedDigit()
            if let detail { Text(detail).font(DS.caption).foregroundStyle(DS.muted) }
        }
    }
}

// MARK: - 页面外壳

/// Deck 每一页的统一页头：标题 + 副标题 + 右侧操作；内容区可滚动，左右边距 40
public struct DSPageShell<Actions: View, Content: View>: View {
    let title: String
    let subtitle: String?
    let scrolls: Bool
    let actions: Actions
    let content: Content

    public init(_ title: String, subtitle: String? = nil, scrolls: Bool = true,
                @ViewBuilder actions: () -> Actions, @ViewBuilder content: () -> Content) {
        self.title = title
        self.subtitle = subtitle
        self.scrolls = scrolls
        self.actions = actions()
        self.content = content()
    }

    public var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(alignment: .top) {
                VStack(alignment: .leading, spacing: 6) {
                    Text(title).font(DS.font(Theme.FontSize.title + 2, .semibold)).foregroundStyle(DS.text)
                    if let subtitle { Text(subtitle).font(DS.caption).foregroundStyle(DS.muted) }
                }
                Spacer()
                HStack(spacing: 8) { actions }
            }
            .padding(.horizontal, 36)
            .padding(.top, 28)
            .padding(.bottom, 18)
            if scrolls {
                ScrollView {
                    VStack(alignment: .leading, spacing: 16) { content }
                        .padding(.horizontal, 36)
                        .padding(.bottom, 28)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
            } else {
                VStack(alignment: .leading, spacing: 16) { content }
                    .padding(.horizontal, 36)
                    .padding(.bottom, 24)
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .background(DS.bg)
    }
}

public extension DSPageShell where Actions == EmptyView {
    init(_ title: String, subtitle: String? = nil, scrolls: Bool = true, @ViewBuilder content: () -> Content) {
        self.init(title, subtitle: subtitle, scrolls: scrolls, actions: { EmptyView() }, content: content)
    }
}

/// 竖向分隔条：拖拽调整左侧栏宽度（命中区约 7pt，视觉线 1pt）
public struct DSColumnResize: View {
    @Binding private var width: CGFloat
    private let range: ClosedRange<CGFloat>
    @State private var hovering = false
    @State private var dragOrigin: CGFloat?

    public init(width: Binding<CGFloat>, range: ClosedRange<CGFloat>) {
        self._width = width
        self.range = range
    }

    public var body: some View {
        ZStack {
            Rectangle().fill(hovering ? DS.borderStrong : DS.border).frame(width: 1)
        }
        .frame(width: 7)
        .frame(maxHeight: .infinity)
        .contentShape(Rectangle())
        .onHover { h in
            hovering = h
            if h { NSCursor.resizeLeftRight.set() } else { NSCursor.arrow.set() }
        }
        .gesture(
            DragGesture(minimumDistance: 0, coordinateSpace: .global)
                .onChanged { value in
                    if dragOrigin == nil { dragOrigin = width }
                    guard let origin = dragOrigin else { return }
                    width = min(max(origin + value.translation.width, range.lowerBound), range.upperBound)
                }
                .onEnded { _ in dragOrigin = nil }
        )
    }
}

/// 列表行的悬停底色
public struct DSHoverRow: ViewModifier {
    @State private var hovering = false
    let selected: Bool
    public init(selected: Bool = false) { self.selected = selected }
    public func body(content: Content) -> some View {
        content
            .background(RoundedRectangle(cornerRadius: Theme.Radius.button)
                .fill(selected ? DS.accentSoft : (hovering ? DS.hover : .clear)))
            .onHover { hovering = $0 }
    }
}

public extension View {
    func dsHoverRow(selected: Bool = false) -> some View { modifier(DSHoverRow(selected: selected)) }

    /// 卡片样式（surface + 1pt border + 圆角 10），用于不方便包 DSCard 的地方
    func dsCardBackground(radius: CGFloat = Theme.Radius.card) -> some View {
        background(RoundedRectangle(cornerRadius: radius).fill(DS.surface))
            .overlay(RoundedRectangle(cornerRadius: radius).strokeBorder(DS.border, lineWidth: 1))
    }
}
