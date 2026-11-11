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

/// 按下时轻微缩小 + 变暗，松开回弹；所有自绘按钮共用，保证「点下去有反应」
public struct DSPressStyle: ButtonStyle {
    let scale: CGFloat
    public init(scale: CGFloat = 0.97) { self.scale = scale }
    public func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .scaleEffect(configuration.isPressed ? scale : 1)
            .opacity(configuration.isPressed ? 0.82 : 1)
            .animation(.easeOut(duration: 0.1), value: configuration.isPressed)
    }
}

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

    private var shadowColor: Color {
        switch kind {
        case .primary: return DS.accent.opacity(enabled ? 0.28 : 0)
        case .secondary: return DS.shadow.opacity(0.35)
        default: return .clear
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
            .background(
                RoundedRectangle(cornerRadius: Theme.Radius.button, style: .continuous)
                    .fill(hovering && enabled ? c.hover : c.bg)
                    .shadow(color: shadowColor, radius: kind == .primary ? 3 : 1, y: 1))
            // 主按钮顶部一道高光，立体一点
            .overlay(RoundedRectangle(cornerRadius: Theme.Radius.button, style: .continuous)
                .fill(LinearGradient(colors: [.white.opacity(kind == .primary ? 0.16 : 0), .clear],
                                     startPoint: .top, endPoint: .bottom))
                .allowsHitTesting(false))
            .overlay(RoundedRectangle(cornerRadius: Theme.Radius.button, style: .continuous).strokeBorder(c.border, lineWidth: 1))
            .contentShape(Rectangle())
            .opacity(enabled ? 1 : 0.45)
            .animation(.easeOut(duration: 0.12), value: hovering)
        }
        .buttonStyle(DSPressStyle())
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
                .background(RoundedRectangle(cornerRadius: Theme.Radius.button, style: .continuous).fill(hovering ? DS.hover : .clear))
                .contentShape(Rectangle())
                .animation(.easeOut(duration: 0.1), value: hovering)
        }
        .buttonStyle(DSPressStyle(scale: 0.92))
        .onHover { hovering = $0 }
        .help(help ?? "")
    }
}

// MARK: - 开关 / 分段 / 复选框

public struct DSToggle: View {
    @Binding var isOn: Bool
    @Environment(\.isEnabled) private var enabled
    public init(isOn: Binding<Bool>) { _isOn = isOn }
    public var body: some View {
        Button { isOn.toggle() } label: {
            ZStack(alignment: isOn ? .trailing : .leading) {
                Capsule().fill(isOn ? DS.accent : DS.borderStrong)
                Capsule().strokeBorder(Color.black.opacity(0.06), lineWidth: 0.5)
                Circle().fill(Color.white).frame(width: 16, height: 16).padding(2)
                    .shadow(color: .black.opacity(0.22), radius: 1.5, y: 0.5)
            }
            .frame(width: 36, height: 20)
            .contentShape(Rectangle())
            .opacity(enabled ? 1 : 0.5)
            .animation(.spring(response: 0.26, dampingFraction: 0.78), value: isOn)
        }
        .buttonStyle(.plain)
    }
}

public struct DSSegmented<T: Hashable>: View {
    @Binding var selection: T
    let options: [(T, String)]
    @Namespace private var ns
    @State private var hovered: Int?
    public init(selection: Binding<T>, options: [(T, String)]) {
        _selection = selection
        self.options = options
    }
    public var body: some View {
        HStack(spacing: 2) {
            ForEach(Array(options.enumerated()), id: \.offset) { i, opt in
                let selected = opt.0 == selection
                Button { selection = opt.0 } label: {
                    Text(opt.1)
                        .font(DS.font(12.5, .medium))
                        .foregroundStyle(selected ? DS.text : (hovered == i ? DS.text2 : DS.muted))
                        .padding(.horizontal, 11)
                        .frame(height: 24)
                        .background {
                            // 选中块在选项之间滑动，而不是瞬移
                            if selected {
                                RoundedRectangle(cornerRadius: 6, style: .continuous).fill(DS.surface)
                                    .shadow(color: DS.shadow.opacity(0.7), radius: 1.5, y: 0.5)
                                    .matchedGeometryEffect(id: "thumb", in: ns)
                            }
                        }
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .onHover { hovered = $0 ? i : (hovered == i ? nil : hovered) }
            }
        }
        .animation(.spring(response: 0.28, dampingFraction: 0.82), value: selection)
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
            .dsCardBackground()
    }
}

/// 设置页分组的小标题，右侧可放操作（如「添加服务」）
public struct DSSectionHeader<Trailing: View>: View {
    let title: String
    let trailing: Trailing
    public init(_ title: String, @ViewBuilder trailing: () -> Trailing) {
        self.title = title
        self.trailing = trailing()
    }
    public var body: some View {
        HStack(alignment: .lastTextBaseline) {
            Text(title).font(DS.font(12, .semibold)).foregroundStyle(DS.muted).kerning(0.2)
            Spacer(minLength: 8)
            trailing
        }
        .padding(.horizontal, 4)
    }
}

public extension DSSectionHeader where Trailing == EmptyView {
    init(_ title: String) { self.init(title, trailing: { EmptyView() }) }
}

/// 设置页分组：卡片里放若干 DSSettingRow，行间用细线分隔（DSDivider）
public struct DSGroup<Content: View>: View {
    let title: String?
    let footer: String?
    let content: Content
    public init(_ title: String? = nil, footer: String? = nil, @ViewBuilder content: () -> Content) {
        self.title = title
        self.footer = footer
        self.content = content()
    }
    public var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            if let title { DSSectionHeader(title) }
            VStack(spacing: 0) { content }
                .frame(maxWidth: .infinity, alignment: .leading)
                .dsCardBackground()
            if let footer {
                Text(footer).font(DS.font(11.5)).foregroundStyle(DS.faint)
                    .lineSpacing(2)
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(.horizontal, 4)
            }
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
        HStack(alignment: .center, spacing: 20) {
            VStack(alignment: .leading, spacing: 4) {
                Text(title).font(DS.font(13, .medium)).foregroundStyle(DS.text)
                if let subtitle, !subtitle.isEmpty {
                    Text(subtitle).font(DS.font(11.5)).foregroundStyle(subtitleTone == .danger ? DS.danger : DS.muted)
                        .lineSpacing(2)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            // 控件保持自身尺寸，说明文字在剩余宽度里换行，不把按钮挤变形
            control.fixedSize()
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 11)
        .frame(minHeight: 50)
    }
}

// MARK: - 图标块

/// 圆角方块图标：`filled` 是实色渐变底 + 白色图标（侧栏导航），否则是同色浅底 + 彩色图标（列表行）
public struct DSIconTile: View {
    let icon: String
    let color: Color
    let size: CGFloat
    let filled: Bool
    public init(_ icon: String, color: Color, size: CGFloat = 28, filled: Bool = false) {
        self.icon = icon
        self.color = color
        self.size = size
        self.filled = filled
    }
    public var body: some View {
        let shape = RoundedRectangle(cornerRadius: size * 0.29, style: .continuous)
        Icon(icon, size: (size * 0.56).rounded(), color: filled ? .white : color)
            .frame(width: size, height: size)
            .background(shape.fill(filled ? AnyShapeStyle(color.gradient) : AnyShapeStyle(color.opacity(0.13))))
            .overlay(shape.strokeBorder(Color.black.opacity(filled ? 0.08 : 0), lineWidth: 0.5))
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
            Icon(icon, size: 24, color: DS.muted)
                .frame(width: 56, height: 56)
                .background(RoundedRectangle(cornerRadius: 16, style: .continuous).fill(DS.surface2))
                .overlay(RoundedRectangle(cornerRadius: 16, style: .continuous).strokeBorder(DS.border, lineWidth: 1))
                .padding(.bottom, 4)
            Text(title).font(DS.font(14, .semibold)).foregroundStyle(DS.text)
            if let message {
                Text(message).font(DS.caption).foregroundStyle(DS.muted)
                    .multilineTextAlignment(.center).frame(maxWidth: 320)
            }
            if let actionTitle, let action {
                DSButton(actionTitle, kind: .primary, action: action).padding(.top, 4)
            }
        }
        .padding(.horizontal, 28).padding(.vertical, 40)
        .frame(maxWidth: .infinity)
    }
}

// MARK: - 输入框

public struct DSField: View {
    let placeholder: String
    @Binding var text: String
    let mono: Bool
    @FocusState private var focused: Bool
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
            .focused($focused)
            .padding(.horizontal, 10)
            .frame(height: 30)
            .dsFieldChrome(focused: focused)
    }
}

/// 搜索框：放大镜 + 输入 + 一键清空；聚焦时描边变强调色
public struct DSSearchField: View {
    let placeholder: String
    @Binding var text: String
    @FocusState private var focused: Bool
    public init(_ placeholder: String, text: Binding<String>) {
        self.placeholder = placeholder
        _text = text
    }
    public var body: some View {
        HStack(spacing: 7) {
            Icon("search", size: 14, color: focused ? DS.accent : DS.faint)
            TextField(placeholder, text: $text)
                .textFieldStyle(.plain)
                .font(DS.body)
                .foregroundStyle(DS.text)
                .focused($focused)
                .onExitCommand { if text.isEmpty { focused = false } else { text = "" } }
            if !text.isEmpty {
                Button { text = "" } label: {
                    Icon("x", size: 10, color: DS.surface)
                        .frame(width: 15, height: 15)
                        .background(Circle().fill(DS.faint))
                }
                .buttonStyle(DSPressStyle(scale: 0.88))
                .transition(.opacity.combined(with: .scale(scale: 0.7)))
            }
        }
        .padding(.horizontal, 10)
        .frame(height: 32)
        .dsFieldChrome(focused: focused)
        .animation(.easeOut(duration: 0.12), value: text.isEmpty)
    }
}

/// 输入框的统一外观：未聚焦是浅灰底细边，聚焦后底色提亮、边变强调色并带一圈柔光
struct DSFieldChrome: ViewModifier {
    let focused: Bool
    func body(content: Content) -> some View {
        let shape = RoundedRectangle(cornerRadius: Theme.Radius.button, style: .continuous)
        content
            .background(shape.fill(focused ? DS.surface : DS.surface2))
            .overlay(shape.strokeBorder(focused ? DS.accent : DS.borderStrong, lineWidth: 1))
            .background(RoundedRectangle(cornerRadius: Theme.Radius.button + 3, style: .continuous)
                .fill(DS.accentSoft).padding(-3).opacity(focused ? 1 : 0))
            .animation(.easeOut(duration: 0.14), value: focused)
    }
}

public extension View {
    func dsFieldChrome(focused: Bool) -> some View { modifier(DSFieldChrome(focused: focused)) }
}

/// 显示为掩码的输入框（API Key）。只影响显示：存储方式不变，仍明文写进 config.json
public struct DSSecureField: View {
    let placeholder: String
    @Binding var text: String
    @State private var reveal = false
    @FocusState private var focused: Bool
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
            .focused($focused)
            Button { reveal.toggle() } label: { Icon(reveal ? "eye-off" : "eye", size: 14) }
                .buttonStyle(DSPressStyle(scale: 0.9))
        }
        .padding(.horizontal, 10)
        .frame(height: 30)
        .dsFieldChrome(focused: focused)
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

    @State private var scrolled = false

    public var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(alignment: .center, spacing: 16) {
                VStack(alignment: .leading, spacing: 5) {
                    Text(title).font(DS.font(Theme.FontSize.title + 2, .bold)).foregroundStyle(DS.text).kerning(-0.2)
                    if let subtitle {
                        Text(subtitle).font(DS.caption).foregroundStyle(DS.muted)
                            .lineLimit(2).fixedSize(horizontal: false, vertical: true)
                    }
                }
                Spacer(minLength: 8)
                HStack(spacing: 8) { actions }.fixedSize()
            }
            .padding(.horizontal, 36)
            .padding(.top, 30)
            .padding(.bottom, 16)
            if scrolls {
                // 内容滚到页头下面时，页头底部浮出一条发丝线，交代层次
                Rectangle().fill(DS.border).frame(height: 1)
                    .opacity(scrolled ? 1 : 0)
                    .animation(.easeOut(duration: 0.15), value: scrolled)
                ScrollView {
                    VStack(alignment: .leading, spacing: 16) { content }
                        .padding(.horizontal, 36)
                        .padding(.top, 4)
                        .padding(.bottom, 28)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
                .onScrollGeometryChange(for: Bool.self) { $0.contentOffset.y + $0.contentInsets.top > 2 } action: { _, v in
                    scrolled = v
                }
            } else {
                VStack(alignment: .leading, spacing: 16) { content }
                    .padding(.horizontal, 36)
                    .padding(.top, 5)
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
    private let defaultWidth: CGFloat?
    @State private var hovering = false
    @State private var dragOrigin: CGFloat?

    /// defaultWidth：双击分隔条恢复到这个宽度
    public init(width: Binding<CGFloat>, range: ClosedRange<CGFloat>, defaultWidth: CGFloat? = nil) {
        self._width = width
        self.range = range
        self.defaultWidth = defaultWidth
    }

    public var body: some View {
        ZStack {
            Rectangle().fill(hovering || dragOrigin != nil ? DS.accent.opacity(0.55) : DS.border)
                .frame(width: hovering || dragOrigin != nil ? 2 : 1)
                .animation(.easeOut(duration: 0.12), value: hovering)
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
        .simultaneousGesture(TapGesture(count: 2).onEnded {
            if let defaultWidth { withAnimation(.easeOut(duration: 0.18)) { width = defaultWidth } }
        })
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
            .animation(.easeOut(duration: 0.1), value: hovering)
            .onHover { hovering = $0 }
    }
}

public extension View {
    func dsHoverRow(selected: Bool = false) -> some View { modifier(DSHoverRow(selected: selected)) }

    /// 卡片样式（surface + 1pt border + 圆角 10），用于不方便包 DSCard 的地方
    func dsCardBackground(radius: CGFloat = Theme.Radius.card) -> some View {
        background(RoundedRectangle(cornerRadius: radius, style: .continuous).fill(DS.surface)
            .shadow(color: DS.shadow.opacity(0.22), radius: 5, y: 2)
            .shadow(color: DS.shadow.opacity(0.3), radius: 0.5, y: 0.5))
            .overlay(RoundedRectangle(cornerRadius: radius, style: .continuous).strokeBorder(DS.border, lineWidth: 1))
    }
}
