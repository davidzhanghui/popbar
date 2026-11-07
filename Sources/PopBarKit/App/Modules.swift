import Cocoa
import SwiftUI
import PopBarCore
import PopBarPlatform
import PopBarDesign

// 十个功能模块。每个模块只通过 PopBarModule 协议向 App 暴露页面、浮动条动作、快捷键、菜单项，
// 模块之间互不引用。默认开启：今日、剪贴板、截屏、录屏、监控、清理；默认关闭：启动项、维护、打印、电视。

// MARK: - 工作

@MainActor
final class TodayModule: PopBarModule {
    let id = "today"
    var title: String { L10n.t("今日", "Today") }
    var summary: String { L10n.t("今日待办与番茄钟，可钉在桌面；可与提醒事项、日历同步", "To-dos and Pomodoro; pin to desktop; syncs with Reminders and Calendar") }
    let icon = "list-checks"
    let group = DeckGroup.work
    var badge: Int? { let n = TodoStore.shared.undoneCount; return n > 0 ? n : nil }

    func page() -> AnyView { AnyView(TodayPage()) }

    var hotkeys: [ModuleHotkey] {
        [ModuleHotkey(id: "todo", title: L10n.t("今日待办", "Today"), keyPath: \.todo) { TodayPinWindow.shared.toggle() }]
    }

    var permissions: [PermissionKind] {
        let c = ConfigStore.shared.config.todo
        return (c.syncReminders ? [.reminders] : []) + (c.syncCalendar ? [.calendar] : [])
    }

    func barActions(for ctx: SourceContext) -> [BarAction] {
        [BarAction(id: "builtin.todo", title: L10n.t("加入待办", "Add to To-Do"), icon: "list-plus") { ctx in
            let text = ctx.text.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !text.isEmpty else { return }
            let source = ctx.origin == .selection ? ctx.appName : nil
            Task { @MainActor in
                TodoStore.shared.add(text, source: source)
                FloatingBarController.shared.showInfo(L10n.t("已加入今日待办（\(TodoStore.shared.undoneCount) 项）",
                                                             "Added to To-Do (\(TodoStore.shared.undoneCount) open)"))
            }
        }]
    }

    func start() {
        TodoStore.shared.reload()
        Pomodoro.shared.applyConfig()
        RemindersSync.shared.start()
        TodayPinWindow.shared.restorePinned()
    }

    func stop() {
        Pomodoro.shared.reset()
        RemindersSync.shared.stop()
        TodayPinWindow.shared.close()
    }

    func pageDidAppear() {
        TodoStore.shared.reload()
        RemindersSync.shared.syncSoon()
    }
}

@MainActor
final class ClipboardModule: PopBarModule {
    let id = "clipboard"
    var title: String { L10n.t("剪贴板", "Clipboard") }
    var summary: String { L10n.t("剪贴板历史与速选面板（⌥⌘V），跳过密码类内容", "Clipboard history and quick picker (⌥⌘V); skips passwords") }
    let icon = "clipboard"
    let group = DeckGroup.work
    var badge: Int? {
        guard ConfigStore.shared.config.clipboardHistory.enabled else { return nil }
        let n = ClipboardHistory.shared.items.count
        return n > 0 ? n : nil
    }

    func page() -> AnyView { AnyView(ClipboardPage()) }

    var hotkeys: [ModuleHotkey] {
        [ModuleHotkey(id: "history", title: L10n.t("剪贴板速选", "Clipboard Picker"), keyPath: \.history) {
            ClipboardPicker.shared.toggle()
        }]
    }

    func start() { ClipboardHistory.shared.applyConfig() }
    func stop() { ClipboardHistory.shared.suspend() }
}

// MARK: - 媒体

@MainActor
final class SnapModule: PopBarModule {
    let id = "snap"
    var title: String { L10n.t("截屏", "Screenshot") }
    var summary: String { L10n.t("区域截屏、标注、贴图、长截屏与截图 OCR", "Region capture, annotate, pin, scrolling capture and OCR") }
    let icon = "scan"
    let group = DeckGroup.media

    func page() -> AnyView { AnyView(SnapPage()) }

    var hotkeys: [ModuleHotkey] {
        [
            ModuleHotkey(id: "snap", title: L10n.t("截屏", "Screenshot"), keyPath: \.snap) { AppRouter.snap() },
            ModuleHotkey(id: "ocr", title: L10n.t("截图 OCR", "Screenshot OCR"), keyPath: \.ocr) { TranslateTriggers.screenshot() },
        ]
    }

    var permissions: [PermissionKind] { [.screenRecording] }

    func menuItems() -> [NSMenuItem] {
        [AppRouter.menuItem(L10n.t("截屏", "Screenshot"), hotkey: ConfigStore.shared.config.hotkeys.snap) { AppRouter.snap() }]
    }
}

@MainActor
final class RecordModule: PopBarModule {
    let id = "record"
    var title: String { L10n.t("录屏", "Recording") }
    var summary: String { L10n.t("区域录屏、点击涟漪、摄像头画中画、导出 GIF / MP4", "Region recording, click ripples, camera overlay, GIF / MP4 export") }
    let icon = "circle-dot"
    let group = DeckGroup.media

    func page() -> AnyView { AnyView(RecordPage()) }

    var hotkeys: [ModuleHotkey] {
        [
            ModuleHotkey(id: "record", title: L10n.t("录屏 / 停止", "Record / Stop"), keyPath: \.record) { AppRouter.recordToggle() },
            ModuleHotkey(id: "recordPause", title: L10n.t("暂停 / 继续录制", "Pause / Resume"), keyPath: \.recordPause) {
                if RecordSession.shared.isRecording { RecordSession.shared.togglePause() }
            },
            ModuleHotkey(id: "recordMarker", title: L10n.t("录制中打标记", "Add Marker"), keyPath: \.recordMarker) {
                RecordSession.shared.addMarker()
            },
        ]
    }

    var permissions: [PermissionKind] {
        let r = ConfigStore.shared.config.snap.record
        return [.screenRecording] + (r.microphone ? [.microphone] : []) + (r.camera.enabled ? [.camera] : [])
    }

    func menuItems() -> [NSMenuItem] {
        let title: String
        if RecordSession.shared.isRecording {
            title = L10n.t("停止录制", "Stop Recording")
        } else if RecordSession.shared.isCountingDown {
            title = L10n.t("取消录屏倒计时", "Cancel Countdown")
        } else {
            title = L10n.t("录屏", "Record Screen")
        }
        return [AppRouter.menuItem(title, hotkey: ConfigStore.shared.config.hotkeys.record) { AppRouter.recordToggle() }]
    }

    func start() { RecordNotify.prepare() }
}

// MARK: - 系统

@MainActor
final class MonitorModule: PopBarModule {
    let id = "monitor"
    var title: String { L10n.t("监控", "Monitor") }
    var summary: String { L10n.t("CPU、内存、GPU、电池、网络与进程；只在打开页面时采样", "CPU, memory, GPU, battery, network and processes; samples only while open") }
    let icon = "activity"
    let group = DeckGroup.system
    let model = SystemMonitorModel()

    func page() -> AnyView { AnyView(MonitorPage(model: model)) }
    func pageDidAppear() { model.start() }
    func pageDidDisappear() { model.closeDetail(); model.stop() }
    func stop() { model.stop() }
}

@MainActor
final class CleanModule: PopBarModule {
    let id = "clean"
    var title: String { L10n.t("清理", "Cleanup") }
    var summary: String { L10n.t("扫描缓存、日志、构建产物与卸载残留，勾选后移入废纸篓", "Scan caches, logs, build output and leftovers; move to Trash") }
    let icon = "sparkles"
    let group = DeckGroup.system
    var model = CleanViewModel()

    func page() -> AnyView { AnyView(CleanPage(module: self)) }
    func pageDidAppear() { if !model.hasScanned && !model.isScanning { model.scan() } }
    func pageDidDisappear() { if model.isScanning { model.cancel() } }
    func stop() { model.cancel() }
}

@MainActor
final class StartupModule: PopBarModule {
    let id = "startup"
    var title: String { L10n.t("启动项", "Startup") }
    var summary: String { L10n.t("登录项与后台服务：查看来源、停用或恢复", "Login items and background services: inspect, disable or restore") }
    let icon = "power"
    let group = DeckGroup.system
    let model = StartupViewModel()

    func page() -> AnyView { AnyView(StartupPage(model: model)) }
    func pageDidAppear() { model.load() }
}

@MainActor
final class MaintenanceModule: PopBarModule {
    let id = "maintenance"
    var title: String { L10n.t("维护", "Maintenance") }
    var summary: String { L10n.t("刷新 DNS、清理本地快照、重建索引等系统维护", "Flush DNS, thin snapshots, rebuild indexes and more") }
    let icon = "wrench"
    let group = DeckGroup.system
    let model = MaintenanceViewModel()

    func page() -> AnyView { AnyView(MaintenancePage(model: model)) }
    func pageDidAppear() { model.load() }
}

// MARK: - 设备

@MainActor
final class PrintModule: PopBarModule {
    let id = "print"
    var title: String { L10n.t("打印", "Print") }
    var summary: String { L10n.t("CUPS 打印机与作业、批量打印、预设与统计", "CUPS printers and jobs, batch printing, presets and stats") }
    let icon = "printer"
    let group = DeckGroup.devices

    func page() -> AnyView { AnyView(PrintPage()) }

    var hotkeys: [ModuleHotkey] {
        [ModuleHotkey(id: "printPanel", title: L10n.t("打印", "Print"), keyPath: \.printPanel) {
            DeckController.shared.toggle(page: .module("print"))
        }]
    }

    func barActions(for ctx: SourceContext) -> [BarAction] {
        [PrintAction.barAction()].compactMap { $0 }
    }

    func start() { PrintCenter.shared.startMaintenance() }
    func stop() { PrintCenter.shared.stopMaintenance() }
    func pageDidAppear() { PrintCenter.shared.panelOpened() }
}

@MainActor
final class TVModule: PopBarModule {
    let id = "tv"
    var title: String { L10n.t("电视", "TV") }
    var summary: String { L10n.t("通过 ADB 遥控局域网里的安卓电视，支持投送链接", "Remote-control Android TVs on the LAN over ADB; send links") }
    let icon = "tv"
    let group = DeckGroup.devices

    func page() -> AnyView { AnyView(TVPage()) }

    var hotkeys: [ModuleHotkey] {
        [ModuleHotkey(id: "tv", title: L10n.t("电视遥控", "TV Remote"), keyPath: \.tv) {
            DeckController.shared.toggle(page: .module("tv"))
        }]
    }

    var permissions: [PermissionKind] { [.localNetwork] }

    func barActions(for ctx: SourceContext) -> [BarAction] {
        [TVCast.barAction(for: ctx)].compactMap { $0 }
    }

    func pageDidAppear() { TVModel.shared.panelOpened() }
}
