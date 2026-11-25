import AppKit
import CoreGraphics
import PopBarCore
import PopBarDesign
import SwiftUI

// MARK: - 真·全屏呈现器（覆盖菜单栏与刘海，供键盘与屏幕测试使用）

private final class MCFullscreenWindow: NSWindow {
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { true }
}

@MainActor
enum MCFullscreenPresenter {
    private static var window: NSWindow?

    static var isPresented: Bool { window?.isVisible ?? false }

    static func present<Content: View>(_ content: Content, on screen: NSScreen?) {
        dismiss()
        guard let target = screen ?? NSScreen.main ?? NSScreen.screens.first else { return }
        let w = MCFullscreenWindow(
            contentRect: target.frame,
            styleMask: [.borderless],
            backing: .buffered,
            defer: false
        )
        w.level = .screenSaver
        w.collectionBehavior = [.fullScreenAuxiliary, .ignoresCycle]
        w.isReleasedWhenClosed = false
        w.hidesOnDeactivate = true
        w.backgroundColor = .black
        w.hasShadow = false
        w.contentView = NSHostingView(rootView: content.ignoresSafeArea())
        w.setFrame(target.frame, display: true)
        NSApp.activateForUI()
        w.makeKeyAndOrderFront(nil)
        self.window = w
    }

    static func dismiss() {
        window?.orderOut(nil)
        window = nil
    }
}

// MARK: - 键盘布局与测试引擎

struct MCKeyCap: Identifiable, Hashable {
    let code: UInt16
    let label: String
    let width: CGFloat
    var id: UInt16 { code }

    init(_ code: UInt16, _ label: String, w: CGFloat = 1.0) {
        self.code = code
        self.label = label
        self.width = w
    }
}

enum MCKeyboardLayout {
    /// 媒体键偏移（避免与标准硬件 keyCode 0–127 冲突）
    static let mediaOffset: UInt16 = 0x2000

    static let rows: [[MCKeyCap]] = [
        [
            .init(53, "Esc", w: 1.45), .init(122, "F1"), .init(120, "F2"), .init(99, "F3"),
            .init(118, "F4"), .init(96, "F5"), .init(97, "F6"), .init(98, "F7"),
            .init(100, "F8"), .init(101, "F9"), .init(109, "F10"), .init(103, "F11"), .init(111, "F12"),
        ],
        [
            .init(50, "`"), .init(18, "1"), .init(19, "2"), .init(20, "3"), .init(21, "4"),
            .init(23, "5"), .init(22, "6"), .init(26, "7"), .init(28, "8"), .init(25, "9"),
            .init(29, "0"), .init(27, "-"), .init(24, "="), .init(51, "⌫", w: 1.55),
        ],
        [
            .init(48, "⇥", w: 1.55), .init(12, "Q"), .init(13, "W"), .init(14, "E"), .init(15, "R"),
            .init(17, "T"), .init(16, "Y"), .init(32, "U"), .init(34, "I"), .init(31, "O"),
            .init(35, "P"), .init(33, "["), .init(30, "]"), .init(42, "\\"),
        ],
        [
            .init(57, "⇪", w: 1.8), .init(0, "A"), .init(1, "S"), .init(2, "D"), .init(3, "F"),
            .init(5, "G"), .init(4, "H"), .init(38, "J"), .init(40, "K"), .init(37, "L"),
            .init(41, ";"), .init(39, "'"), .init(36, "↩", w: 1.75),
        ],
        [
            .init(56, "⇧", w: 2.3), .init(6, "Z"), .init(7, "X"), .init(8, "C"), .init(9, "V"),
            .init(11, "B"), .init(45, "N"), .init(46, "M"), .init(43, ","), .init(47, "."),
            .init(44, "/"), .init(60, "⇧", w: 2.3),
        ],
        [
            .init(63, "fn"), .init(59, "⌃"), .init(58, "⌥"), .init(55, "⌘", w: 1.3),
            .init(49, "Space", w: 5.0),
            .init(54, "⌘", w: 1.3), .init(61, "⌥"),
            .init(123, "◀"), .init(126, "▲"), .init(125, "▼"), .init(124, "▶"),
        ],
    ]

    static let allKeys: [MCKeyCap] = rows.flatMap { $0 }
    static let allCodes: Set<UInt16> = Set(allKeys.map(\.code))
    static let totalCount: Int = allKeys.count

    /// 特殊虚拟键码归一化（如 Apple 顶排 F3-F6 不按 Fn 时发出的调度中心/启动台/聚焦/听写/勿扰键码）
    static let altVirtualKeyMap: [UInt16: UInt16] = [
        160: 99,   // Mission Control -> F3
        131: 118,  // Launchpad       -> F4
        177: 118,  // Spotlight       -> F4
        176: 96,   // Dictation       -> F5
        178: 97,   // Do Not Disturb  -> F6
    ]

    /// 将媒体键 NX_KEYTYPE 映射到对应的顶排功能键，保证媒体键和 Fn+F1..F12 点亮同一位置
    static let mediaToFunctionKey: [UInt16: UInt16] = [
        3: 122,   // Brightness Down -> F1
        2: 120,   // Brightness Up   -> F2
        22: 96,   // Keyboard Backlight Down -> F5
        21: 97,   // Keyboard Backlight Up   -> F6
        20: 98,   // Rewind          -> F7
        18: 98,   // Previous Track  -> F7
        16: 100,  // Play/Pause      -> F8
        19: 101,  // Fast Forward    -> F9
        17: 101,  // Next Track      -> F9
        7: 109,   // Mute            -> F10
        1: 103,   // Volume Down     -> F11
        0: 111,   // Volume Up       -> F12
    ]
}

@MainActor
final class MCKeyboardEngine: ObservableObject {
    @Published private(set) var tested: Set<UInt16> = []
    @Published private(set) var pressed: Set<UInt16> = []
    @Published private(set) var stuck: Set<UInt16> = []
    @Published private(set) var manualConfirmed: Set<UInt16> = []

    var onExitRequested: (() -> Void)?

    private var pressTimestamps: [UInt16: Date] = [:]
    private var localMonitor: Any?
    private var stuckTimer: Timer?
    private var resignObserver: NSObjectProtocol?

    private static let modifierDeviceMasks: [UInt16: UInt] = [
        56: 0x0000_0002, 60: 0x0000_0004,
        59: 0x0000_0001, 62: 0x0000_2000,
        58: 0x0000_0020, 61: 0x0000_0040,
        55: 0x0000_0008, 54: 0x0000_0010,
        63: NSEvent.ModifierFlags.function.rawValue,
    ]

    var progress: Double {
        Double(tested.count) / Double(max(1, MCKeyboardLayout.totalCount))
    }

    func start() {
        guard localMonitor == nil else { return }
        localMonitor = NSEvent.addLocalMonitorForEvents(matching: [.keyDown, .keyUp, .flagsChanged, .systemDefined]) { [weak self] event in
            guard let self else { return event }
            if event.type == .systemDefined {
                self.handleMedia(event)
                return event
            }
            let allowSystemShortcut = event.modifierFlags.contains(.command)
            self.handleKeyEvent(event, isShortcut: allowSystemShortcut)
            return allowSystemShortcut ? event : nil
        }
        stuckTimer = Timer.scheduledTimer(withTimeInterval: 1.0, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.inspectStuckKeys() }
        }
        resignObserver = NotificationCenter.default.addObserver(
            forName: NSApplication.didResignActiveNotification, object: nil, queue: .main
        ) { [weak self] _ in
            Task { @MainActor in self?.clearPressed() }
        }
    }

    func stop() {
        if let localMonitor { NSEvent.removeMonitor(localMonitor) }
        localMonitor = nil
        stuckTimer?.invalidate()
        stuckTimer = nil
        if let resignObserver { NotificationCenter.default.removeObserver(resignObserver) }
        resignObserver = nil
    }

    func toggleManual(_ code: UInt16) {
        if manualConfirmed.contains(code) {
            manualConfirmed.remove(code)
            tested.remove(code)
        } else if !tested.contains(code) {
            manualConfirmed.insert(code)
            tested.insert(code)
        }
    }

    func reset() {
        tested.removeAll()
        manualConfirmed.removeAll()
        clearPressed()
    }

    private func clearPressed() {
        pressed.removeAll()
        pressTimestamps.removeAll()
        stuck.removeAll()
    }

    private func flash(_ code: UInt16) {
        pressed.insert(code)
        Task { @MainActor [weak self] in
            try? await Task.sleep(nanoseconds: 220_000_000)
            if self?.pressTimestamps[code] == nil {
                self?.pressed.remove(code)
            }
        }
    }

    private func handleKeyEvent(_ event: NSEvent, isShortcut: Bool) {
        let code = MCKeyboardLayout.altVirtualKeyMap[event.keyCode] ?? event.keyCode
        guard MCKeyboardLayout.allCodes.contains(code) else { return }
        switch event.type {
        case .keyDown:
            tested.insert(code)
            manualConfirmed.remove(code)
            if isShortcut {
                flash(code)
            } else {
                pressed.insert(code)
                if pressTimestamps[code] == nil { pressTimestamps[code] = Date() }
                stuck.remove(code)
            }
        case .keyUp:
            if code == 53, let start = pressTimestamps[code], Date().timeIntervalSince(start) >= 1.1 {
                onExitRequested?()
            }
            pressed.remove(code)
            pressTimestamps[code] = nil
            stuck.remove(code)
        case .flagsChanged:
            tested.insert(code)
            manualConfirmed.remove(code)
            if code == 57 {
                flash(code)
            } else if let mask = Self.modifierDeviceMasks[code] {
                if event.modifierFlags.rawValue & mask != 0 {
                    pressed.insert(code)
                    if pressTimestamps[code] == nil { pressTimestamps[code] = Date() }
                } else {
                    pressed.remove(code)
                    pressTimestamps[code] = nil
                    stuck.remove(code)
                }
            } else {
                flash(code)
            }
        default:
            break
        }
    }

    private func handleMedia(_ event: NSEvent) {
        guard event.subtype.rawValue == 8 else { return }
        let keyType = UInt16((event.data1 & 0xFFFF_0000) >> 16)
        let isDown = ((event.data1 & 0xFF00) >> 8) == 0x0A
        guard isDown, let mapped = MCKeyboardLayout.mediaToFunctionKey[keyType] else { return }
        tested.insert(mapped)
        manualConfirmed.remove(mapped)
        flash(mapped)
    }

    private func inspectStuckKeys() {
        let now = Date()
        for (code, started) in pressTimestamps {
            if !CGEventSource.keyState(.hidSystemState, key: CGKeyCode(code)) {
                pressed.remove(code)
                pressTimestamps[code] = nil
                stuck.remove(code)
                continue
            }
            if now.timeIntervalSince(started) > 5.0 {
                stuck.insert(code)
            }
        }
    }

    func buildResult() -> MCCheckItem {
        let total = MCKeyboardLayout.totalCount
        var details: [MCDetailPair] = [
            .init(L10n.t("已测按键", "Keys Tested"), "\(tested.count) / \(total)"),
        ]
        if !manualConfirmed.isEmpty {
            let names = MCKeyboardLayout.allKeys.filter { manualConfirmed.contains($0.code) }.map(\.label).joined(separator: "、")
            details.append(.init(L10n.t("手动确认", "Manual Confirm"), names))
        }
        if !stuck.isEmpty {
            let names = MCKeyboardLayout.allKeys.filter { stuck.contains($0.code) }.map(\.label).joined(separator: "、")
            details.append(.init(L10n.t("疑似卡键", "Suspected Stuck Keys"), names))
            return MCCheckItem(
                id: MCInteractiveKind.keyboard.resultID,
                category: .interactive,
                title: MCInteractiveKind.keyboard.title,
                status: .warning,
                summary: L10n.t("检测到疑似卡键：\(names)", "Suspected stuck keys: \(names)"),
                details: details
            )
        }
        if tested.count >= total {
            return MCCheckItem(
                id: MCInteractiveKind.keyboard.resultID,
                category: .interactive,
                title: MCInteractiveKind.keyboard.title,
                status: .pass,
                summary: L10n.t("全部 \(total) 个按键响应正常，无卡键", "All \(total) keys responded normally"),
                details: details
            )
        }
        return MCCheckItem(
            id: MCInteractiveKind.keyboard.resultID,
            category: .interactive,
            title: MCInteractiveKind.keyboard.title,
            status: .warning,
            summary: L10n.t("已完成 \(tested.count) / \(total) 个按键测试", "Tested \(tested.count) / \(total) keys"),
            details: details
        )
    }
}

struct MCKeyboardTestView: View {
    @StateObject private var engine = MCKeyboardEngine()
    let onFinish: (MCCheckItem) -> Void
    let onCancel: () -> Void

    var body: some View {
        ZStack {
            Color(nsColor: NSColor(srgbRed: 0.09, green: 0.09, blue: 0.09, alpha: 1))
                .ignoresSafeArea()
            VStack(spacing: 24) {
                HStack(alignment: .center) {
                    VStack(alignment: .leading, spacing: 6) {
                        Text(L10n.t("全屏键盘逐键测试", "Fullscreen Keyboard Test"))
                            .font(.system(size: 22, weight: .bold))
                            .foregroundStyle(.white)
                        Text(L10n.t("依次按下每个按键进行点亮；若系统快捷键占用了某键，可直接鼠标点击该键位手动确认；长按 Esc 1 秒以上可快速结束",
                                    "Press every key to light it up. Click any key captured by a system shortcut to confirm manually, or hold Esc for 1s to finish."))
                            .font(.system(size: 13))
                            .foregroundStyle(.white.opacity(0.68))
                    }
                    Spacer()
                    HStack(spacing: 10) {
                        Text("\(engine.tested.count) / \(MCKeyboardLayout.totalCount)")
                            .font(.system(size: 16, weight: .semibold, design: .monospaced))
                            .foregroundStyle(engine.tested.count >= MCKeyboardLayout.totalCount ? DS.success : .white)
                        DSButton(L10n.t("重置", "Reset"), kind: .secondary) { engine.reset() }
                        DSButton(L10n.t("取消", "Cancel"), kind: .ghost) {
                            engine.stop()
                            onCancel()
                        }
                        DSButton(L10n.t("完成并保存", "Save Result"), icon: "check", kind: .primary) {
                            let res = engine.buildResult()
                            engine.stop()
                            onFinish(res)
                        }
                    }
                }
                .frame(maxWidth: 960)

                DSProgress(engine.progress, tint: DS.accent)
                    .frame(maxWidth: 960)

                VStack(spacing: 8) {
                    ForEach(Array(MCKeyboardLayout.rows.enumerated()), id: \.offset) { _, row in
                        HStack(spacing: 6) {
                            ForEach(row) { cap in
                                keyTile(cap)
                            }
                        }
                    }
                }
                .padding(20)
                .background(RoundedRectangle(cornerRadius: 16, style: .continuous).fill(Color.white.opacity(0.05)))
                .overlay(RoundedRectangle(cornerRadius: 16, style: .continuous).strokeBorder(Color.white.opacity(0.12), lineWidth: 1))
                .frame(maxWidth: 960)

                HStack(spacing: 20) {
                    legendDot(color: Color.white.opacity(0.14), text: L10n.t("未测试", "Untested"))
                    legendDot(color: DS.accent, text: L10n.t("正在按下", "Pressed"))
                    legendDot(color: DS.success, text: L10n.t("已通过", "Tested"))
                    legendDot(color: DS.danger, text: L10n.t("疑似卡键", "Stuck"))
                }
            }
            .padding(36)
        }
        .onAppear {
            engine.onExitRequested = {
                let res = engine.buildResult()
                engine.stop()
                onFinish(res)
            }
            engine.start()
        }
        .onDisappear { engine.stop() }
    }

    private func keyTile(_ cap: MCKeyCap) -> some View {
        let isStuck = engine.stuck.contains(cap.code)
        let isPressed = engine.pressed.contains(cap.code)
        let isTested = engine.tested.contains(cap.code)
        let bg: Color = isStuck ? DS.danger : (isPressed ? DS.accent : (isTested ? DS.success.opacity(0.85) : Color.white.opacity(0.11)))
        return Button { engine.toggleManual(cap.code) } label: {
            Text(cap.label)
                .font(.system(size: 12.5, weight: .semibold, design: .rounded))
                .foregroundStyle(.white)
                .frame(width: cap.width * 56, height: 50)
                .background(RoundedRectangle(cornerRadius: 8, style: .continuous).fill(bg))
                .overlay(RoundedRectangle(cornerRadius: 8, style: .continuous).strokeBorder(Color.white.opacity(isPressed ? 0.8 : 0.16), lineWidth: 1))
        }
        .buttonStyle(.plain)
    }

    private func legendDot(color: Color, text: String) -> some View {
        HStack(spacing: 6) {
            Circle().fill(color).frame(width: 10, height: 10)
            Text(text).font(.system(size: 12)).foregroundStyle(.white.opacity(0.75))
        }
    }
}

// MARK: - 屏幕坏点 / 灰阶 / 棋盘格测试

enum MCScreenPattern: Int, CaseIterable, Identifiable {
    case black, white, red, green, blue, gray50, grayscaleRamp, checkerboard, sharpness

    var id: Int { rawValue }

    var title: String {
        switch self {
        case .black: return L10n.t("纯黑（检漏光与亮点）", "Pure Black (Backlight & Bright Pixels)")
        case .white: return L10n.t("纯白（检暗点、偏色与阴阳屏）", "Pure White (Dead Pixels & Tint)")
        case .red: return L10n.t("纯红（检红子像素）", "Pure Red")
        case .green: return L10n.t("纯绿（检绿子像素）", "Pure Green")
        case .blue: return L10n.t("纯蓝（检蓝子像素）", "Pure Blue")
        case .gray50: return L10n.t("50% 灰（检均匀度与残影）", "50% Gray (Uniformity & Burn-in)")
        case .grayscaleRamp: return L10n.t("16 级灰阶（检色带断层）", "16-Step Grayscale")
        case .checkerboard: return L10n.t("高对比棋盘格（检像素串扰）", "High-Contrast Checkerboard")
        case .sharpness: return L10n.t("文本锐度（检字体边缘彩边）", "Text Sharpness")
        }
    }
}

struct MCScreenTestView: View {
    @State private var index = 0
    @State private var visited: Set<Int> = [0]
    @State private var flagged: Set<Int> = []
    @State private var showHUD = true
    @State private var keyMonitor: Any?

    let onFinish: (MCCheckItem) -> Void
    let onCancel: () -> Void

    private var pattern: MCScreenPattern {
        MCScreenPattern.allCases[index % MCScreenPattern.allCases.count]
    }

    private var isFlagged: Bool { flagged.contains(index) }

    var body: some View {
        ZStack {
            patternCanvas(pattern)
                .ignoresSafeArea()
                .contentShape(Rectangle())
                .onTapGesture { nextPattern() }

            if showHUD {
                VStack {
                    Spacer()
                    HStack(spacing: 12) {
                        HStack(spacing: 6) {
                            Text("\(index + 1)/\(MCScreenPattern.allCases.count) · \(pattern.title)")
                                .font(.system(size: 13, weight: .semibold))
                                .foregroundStyle(.white)
                            if isFlagged {
                                DSChip(L10n.t("已标异常", "Flagged"), tone: .danger, icon: "triangle-alert")
                            }
                        }
                        Spacer()
                        Text(L10n.t("空格切换 · F 标异常 · H 隐提示 · Esc 退出", "Space: Next · F: Flag · H: HUD · Esc: Exit"))
                            .font(.system(size: 11.5))
                            .foregroundStyle(.white.opacity(0.75))
                        DSButton(isFlagged ? L10n.t("取消异常标记", "Unflag") : L10n.t("标记此画面异常", "Flag Screen"),
                                 kind: isFlagged ? .secondary : .danger) {
                            toggleFlagCurrent()
                        }
                        DSButton(L10n.t("完成保存", "Finish"), icon: "check", kind: .primary) {
                            finish()
                        }
                    }
                    .padding(.horizontal, 18)
                    .padding(.vertical, 12)
                    .background(RoundedRectangle(cornerRadius: 12, style: .continuous).fill(Color.black.opacity(0.78)))
                    .overlay(RoundedRectangle(cornerRadius: 12, style: .continuous).strokeBorder(Color.white.opacity(0.18), lineWidth: 1))
                    .frame(maxWidth: 920)
                    .padding(.bottom, 28)
                }
            }
        }
        .onAppear {
            NSCursor.setHiddenUntilMouseMoves(true)
            keyMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { event in
                switch event.keyCode {
                case 53: // Esc
                    stopMonitor()
                    onCancel()
                    return nil
                case 49, 124: // Space, Right
                    nextPattern()
                    return nil
                case 123: // Left
                    let prev = (index - 1 + MCScreenPattern.allCases.count) % MCScreenPattern.allCases.count
                    index = prev
                    visited.insert(prev)
                    NSCursor.setHiddenUntilMouseMoves(true)
                    return nil
                case 3: // F
                    toggleFlagCurrent()
                    return nil
                case 4: // H
                    showHUD.toggle()
                    return nil
                default:
                    return event
                }
            }
        }
        .onDisappear { stopMonitor() }
    }

    private func nextPattern() {
        index = (index + 1) % MCScreenPattern.allCases.count
        visited.insert(index)
        NSCursor.setHiddenUntilMouseMoves(true)
    }

    private func toggleFlagCurrent() {
        if flagged.contains(index) { flagged.remove(index) } else { flagged.insert(index) }
    }

    private func stopMonitor() {
        if let keyMonitor { NSEvent.removeMonitor(keyMonitor) }
        keyMonitor = nil
    }

    private func finish() {
        stopMonitor()
        let total = MCScreenPattern.allCases.count
        let flaggedTitles = flagged.sorted().map { MCScreenPattern.allCases[$0].title }
        var details: [MCDetailPair] = [
            .init(L10n.t("已浏览测试画面", "Patterns Viewed"), "\(visited.count) / \(total)"),
        ]
        if !flaggedTitles.isEmpty {
            details.append(.init(L10n.t("标记异常画面", "Flagged Patterns"), flaggedTitles.joined(separator: "；")))
            onFinish(MCCheckItem(
                id: MCInteractiveKind.screen.resultID,
                category: .interactive,
                title: MCInteractiveKind.screen.title,
                status: .warning,
                summary: L10n.t("以下画面标记存在异常：\(flaggedTitles.joined(separator: "、"))",
                                "Issues flagged on: \(flaggedTitles.joined(separator: ", "))"),
                details: details
            ))
            return
        }
        let incomplete = visited.count < total
        onFinish(MCCheckItem(
            id: MCInteractiveKind.screen.resultID,
            category: .interactive,
            title: MCInteractiveKind.screen.title,
            status: incomplete ? .warning : .pass,
            summary: incomplete
                ? L10n.t("仅浏览了 \(visited.count) / \(total) 个画面，建议完整轮播确认无坏点",
                         "Viewed \(visited.count) of \(total) patterns; review all screens for a complete check")
                : L10n.t("完整检查全部 \(total) 种纯色、灰阶与锐度画面，未发现坏点或偏色",
                         "All \(total) color, grayscale and sharpness screens verified clean"),
            details: details
        ))
    }

    @ViewBuilder
    private func patternCanvas(_ p: MCScreenPattern) -> some View {
        switch p {
        case .black: Color.black
        case .white: Color.white
        case .red: Color(red: 1, green: 0, blue: 0)
        case .green: Color(red: 0, green: 1, blue: 0)
        case .blue: Color(red: 0, green: 0, blue: 1)
        case .gray50: Color(white: 0.5)
        case .grayscaleRamp:
            HStack(spacing: 0) {
                ForEach(0..<16, id: \.self) { step in
                    Color(white: Double(step) / 15.0)
                }
            }
        case .checkerboard:
            Canvas { ctx, size in
                let cell: CGFloat = 32
                let cols = Int(ceil(size.width / cell))
                let rows = Int(ceil(size.height / cell))
                ctx.fill(Path(CGRect(origin: .zero, size: size)), with: .color(.white))
                var darkPath = Path()
                for r in 0..<rows {
                    for c in 0..<cols where (r + c).isMultiple(of: 2) {
                        darkPath.addRect(CGRect(x: CGFloat(c) * cell, y: CGFloat(r) * cell, width: cell, height: cell))
                    }
                }
                ctx.fill(darkPath, with: .color(.black))
            }
        case .sharpness:
            ZStack {
                Color.white
                VStack(alignment: .leading, spacing: 14) {
                    ForEach([9, 11, 13, 16, 22, 32], id: \.self) { sz in
                        Text("[\(sz)pt] 屏幕清晰度测试 · The quick brown fox jumps over the lazy dog 0123456789")
                            .font(.system(size: CGFloat(sz)))
                            .foregroundStyle(.black)
                    }
                }
                .padding(48)
            }
        }
    }
}
