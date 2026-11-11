import Cocoa
import SwiftUI
import AVFoundation
import PopBarCore
import PopBarPlatform
import PopBarDesign

// MARK: - 截屏与录屏

struct MediaSettings: View {
    @EnvironmentObject var e: ConfigEditor
    @State private var micLevel: Float = 0
    @State private var micTesting = false
    @State private var mic = MicLevelMonitor()

    @State private var mics: [(String, String)] = []
    @State private var cameras: [(String, String)] = []

    /// 重新枚举麦克风 / 摄像头（插拔设备后列表才会更新）
    private func refreshDevices() {
        let def = ("", L10n.t("系统默认", "System default"))
        mics = [def] + MicPermission.devices().map { ($0.id, $0.name) }
        cameras = [def] + CameraPermission.devices().map { ($0.id, $0.name) }
    }

    private var refreshButton: some View {
        DSIconButton("refresh-cw", help: L10n.t("刷新设备列表", "Refresh devices")) { refreshDevices() }
    }

    var body: some View {
        DSGroup(L10n.t("截屏", "Screenshot")) {
            DSSettingRow(L10n.t("保存目录", "Save Folder"), subtitle: e.c.snap.saveDir) {
                DSButton(L10n.t("选择…", "Choose…")) {
                    if let p = FilePick.directory(start: e.c.snap.saveDir) {
                        e.update { $0.snap.saveDir = p.replacingOccurrences(of: NSHomeDirectory(), with: "~") }
                    }
                }
            }
            DSDivider()
            DSSettingRow(L10n.t("格式", "Format")) {
                DSSegmented(selection: e.bind(\.snap.format), options: [(.png, "PNG"), (.jpg, "JPG")])
            }
            DSDivider()
            DSSettingRow(L10n.t("放大镜", "Magnifier"), subtitle: L10n.t("框选时显示像素放大镜和取色", "Pixel loupe and color picker while selecting")) {
                DSToggle(isOn: e.bind(\.snap.showMagnifier))
            }
            DSDivider()
            DSSettingRow(L10n.t("截图历史", "History"), subtitle: L10n.t("保存在本机 Application Support/PopBar/Snaps", "Kept in Application Support/PopBar/Snaps")) {
                HStack(spacing: 8) {
                    if e.c.snap.history.enabled { DSNumberField(value: e.bind(\.snap.history.limit), range: 1...200, suffix: L10n.t("张", "")) }
                    DSToggle(isOn: e.bind(\.snap.history.enabled))
                }
            }
        }

        DSGroup(L10n.t("录屏画面", "Recording Video")) {
            DSSettingRow(L10n.t("帧率", "Frame Rate")) {
                DSSegmented(selection: e.bind(\.snap.record.fps), options: [(30, "30"), (60, "60")])
            }
            DSDivider()
            DSSettingRow(L10n.t("清晰度", "Scale"), subtitle: L10n.t("2x 为 Retina 原生像素", "2x keeps Retina pixels")) {
                DSSegmented(selection: e.bind(\.snap.record.scale), options: [(1, "1x"), (2, "2x")])
            }
            DSDivider()
            DSSettingRow(L10n.t("编码", "Codec")) {
                DSSegmented(selection: e.bind(\.snap.record.codec), options: [("h264", "H.264"), ("hevc", "HEVC")])
            }
            DSDivider()
            DSSettingRow(L10n.t("容器", "Container")) {
                DSSegmented(selection: e.bind(\.snap.record.container), options: [("mov", "MOV"), ("mp4", "MP4")])
            }
            DSDivider()
            DSSettingRow(L10n.t("录制鼠标指针", "Show Cursor")) { DSToggle(isOn: e.bind(\.snap.record.showsCursor)) }
        }

        DSGroup(L10n.t("录屏声音", "Recording Audio")) {
            DSSettingRow(L10n.t("系统声音", "System Audio"), subtitle: L10n.t("PopBar 自己的声音始终排除", "PopBar's own sounds are always excluded")) {
                DSToggle(isOn: e.bind(\.snap.record.systemAudio))
            }
            DSDivider()
            DSSettingRow(L10n.t("麦克风", "Microphone")) {
                HStack(spacing: 8) {
                    if e.c.snap.record.microphone {
                        DSMenuPicker(selection: e.bind(\.snap.record.microphoneDevice), options: mics, width: 170)
                        refreshButton
                        DSButton(micTesting ? L10n.t("停止", "Stop") : L10n.t("测试", "Test"), kind: .ghost) { toggleMic() }
                        if micTesting { DSProgress(Double(micLevel)).frame(width: 60) }
                    }
                    DSToggle(isOn: Binding(get: { e.c.snap.record.microphone }, set: { v in
                        Task { @MainActor in
                            if v, !(await MicPermission.ensure()) { return }
                            e.update { $0.snap.record.microphone = v }
                        }
                    }))
                }
            }
        }

        DSGroup(L10n.t("录制流程", "Recording Flow")) {
            DSSettingRow(L10n.t("最长时长", "Max Duration"), subtitle: L10n.t("0 表示不限", "0 means unlimited")) {
                DSNumberField(value: e.bind(\.snap.record.maxDuration), range: 0...7200, suffix: L10n.t("秒", "s"))
            }
            DSDivider()
            DSSettingRow(L10n.t("倒计时", "Countdown"), subtitle: L10n.t("确认选区后先倒数，留出切换窗口的时间", "Time to switch windows before recording")) {
                DSSegmented(selection: e.bind(\.snap.record.countdown), options: [(0, "0"), (3, "3"), (5, "5"), (10, "10")])
            }
            DSDivider()
            DSSettingRow(L10n.t("窗口跟随", "Follow Window"), subtitle: L10n.t("录制窗口时，窗口移动后选区跟着走", "Region follows the window when it moves")) {
                DSToggle(isOn: e.bind(\.snap.record.windowFollow))
            }
            DSDivider()
            DSSettingRow(L10n.t("录完复制到剪贴板", "Copy on Finish")) { DSToggle(isOn: e.bind(\.snap.record.copyToClipboard)) }
            DSDivider()
            HStack {
                Spacer()
                DSButton(L10n.t("套用产品演示参数", "Apply Demo Preset"), kind: .ghost) {
                    e.update { c in
                        c.snap.record.scale = 1
                        c.snap.record.container = "mp4"
                        c.snap.record.codec = "h264"
                        c.snap.record.fps = 30
                        c.snap.record.countdown = 3
                        c.snap.record.showsCursor = true
                        c.snap.record.export.width = 1920
                        c.snap.record.export.quality = "medium"
                        c.snap.record.export.container = "mp4"
                    }
                }
            }
            .padding(10)
        }

        DSGroup(L10n.t("点击涟漪与摄像头", "Clicks & Camera")) {
            DSSettingRow(L10n.t("点击涟漪", "Click Ripple"), subtitle: L10n.t("导出时在每次点击处画扩散圆环", "Draw a ring at each click on export")) {
                DSToggle(isOn: e.bind(\.snap.record.click.enabled))
            }
            if e.c.snap.record.click.enabled {
                DSDivider()
                DSSettingRow(L10n.t("涟漪时长", "Duration")) {
                    DSSegmented(selection: e.bind(\.snap.record.click.duration),
                                options: [(0.3, L10n.t("短", "Short")), (0.6, L10n.t("标准", "Normal")), (1.0, L10n.t("长", "Long"))])
                }
                DSDivider()
                DSSettingRow(L10n.t("涟漪颜色", "Color")) {
                    DSSegmented(selection: e.bind(\.snap.record.click.color),
                                options: [("#FF3B30", L10n.t("红", "Red")), ("#0A84FF", L10n.t("蓝", "Blue")), ("#FFD60A", L10n.t("黄", "Yellow"))])
                }
            }
            DSDivider()
            DSSettingRow(L10n.t("摄像头画中画", "Camera PiP"), subtitle: L10n.t("录制时显示预览窗，导出时叠加到成品上", "Preview while recording; composited on export")) {
                DSToggle(isOn: Binding(get: { e.c.snap.record.camera.enabled }, set: { v in
                    Task { @MainActor in
                        if v, !(await CameraPermission.ensure()) { return }
                        e.update { $0.snap.record.camera.enabled = v }
                    }
                }))
            }
            if e.c.snap.record.camera.enabled {
                DSDivider()
                DSSettingRow(L10n.t("设备", "Device")) {
                    HStack(spacing: 8) {
                        DSMenuPicker(selection: e.bind(\.snap.record.camera.device), options: cameras, width: 200)
                        refreshButton
                    }
                }
                DSDivider()
                DSSettingRow(L10n.t("位置", "Position")) {
                    DSSegmented(selection: e.bind(\.snap.record.camera.position), options: corners)
                }
                DSDivider()
                DSSettingRow(L10n.t("大小", "Size")) {
                    DSSegmented(selection: e.bind(\.snap.record.camera.size), options: [(120, "120"), (160, "160"), (220, "220")])
                }
                DSDivider()
                DSSettingRow(L10n.t("镜像", "Mirror")) { DSToggle(isOn: e.bind(\.snap.record.camera.mirror)) }
            }
        }

        DSGroup(L10n.t("水印", "Watermark")) {
            DSSettingRow(L10n.t("导出时加水印", "Watermark on Export")) { DSToggle(isOn: e.bind(\.snap.record.watermark.enabled)) }
            if e.c.snap.record.watermark.enabled {
                DSDivider()
                DSSettingRow(L10n.t("文字", "Text")) { DSField("PopBar", text: e.bind(\.snap.record.watermark.text)).frame(width: 200) }
                DSDivider()
                DSSettingRow(L10n.t("图片", "Image"), subtitle: e.c.snap.record.watermark.imagePath.isEmpty ? L10n.t("可选；设置后优先用图片", "Optional; used instead of text") : e.c.snap.record.watermark.imagePath) {
                    HStack(spacing: 8) {
                        if !e.c.snap.record.watermark.imagePath.isEmpty {
                            DSButton(L10n.t("移除", "Remove"), kind: .ghost) { e.update { $0.snap.record.watermark.imagePath = "" } }
                        }
                        DSButton(L10n.t("选择…", "Choose…")) { if let p = FilePick.image() { e.update { $0.snap.record.watermark.imagePath = p } } }
                    }
                }
                DSDivider()
                DSSettingRow(L10n.t("位置", "Position")) {
                    DSSegmented(selection: e.bind(\.snap.record.watermark.position), options: corners)
                }
                DSDivider()
                DSSettingRow(L10n.t("不透明度", "Opacity")) {
                    DSSlider(value: e.bind(\.snap.record.watermark.opacity), range: 0.1...1) { "\(Int(($0 * 100).rounded()))%" }
                }
            }
        }

        DSGroup(L10n.t("视频导出", "Video Export")) {
            DSSettingRow(L10n.t("录完自动导出", "Auto Export"), subtitle: L10n.t("录制结束直接按下面的参数出成品", "Export with these settings right after recording")) {
                DSToggle(isOn: e.bind(\.snap.record.export.autoExport))
            }
            DSDivider()
            DSSettingRow(L10n.t("宽度", "Width")) {
                DSSegmented(selection: e.bind(\.snap.record.export.width),
                            options: [(0, L10n.t("原始", "Original")), (1920, "1920"), (1280, "1280"), (854, "854")])
            }
            DSDivider()
            DSSettingRow(L10n.t("画质", "Quality")) {
                DSSegmented(selection: e.bind(\.snap.record.export.quality),
                            options: [("high", L10n.t("高", "High")), ("medium", L10n.t("中", "Medium")), ("low", L10n.t("低", "Low"))])
            }
            DSDivider()
            DSSettingRow(L10n.t("格式", "Format")) {
                DSSegmented(selection: e.bind(\.snap.record.export.container), options: [("mp4", "MP4"), ("mov", "MOV")])
            }
            DSDivider()
            DSSettingRow(L10n.t("导出后复制到剪贴板", "Copy After Export")) { DSToggle(isOn: e.bind(\.snap.record.export.copyToClipboard)) }
        }

        DSGroup("GIF") {
            DSSettingRow(L10n.t("帧率", "Frame Rate")) {
                DSSegmented(selection: e.bind(\.snap.record.gif.fps), options: [(5, "5"), (10, "10"), (15, "15")])
            }
            DSDivider()
            DSSettingRow(L10n.t("宽度", "Width")) {
                DSSegmented(selection: e.bind(\.snap.record.gif.width), options: [(0, L10n.t("原始", "Original")), (800, "800"), (480, "480")])
            }
            DSDivider()
            DSSettingRow(L10n.t("导出后复制到剪贴板", "Copy After Export")) { DSToggle(isOn: e.bind(\.snap.record.gif.copyToClipboard)) }
        }
        .onAppear { refreshDevices() }
        .onReceive(NotificationCenter.default.publisher(for: AVCaptureDevice.wasConnectedNotification)) { _ in refreshDevices() }
        .onReceive(NotificationCenter.default.publisher(for: AVCaptureDevice.wasDisconnectedNotification)) { _ in refreshDevices() }
        .onDisappear { mic.stop(); micTesting = false }
    }

    private var corners: [(String, String)] {
        [("bottomRight", L10n.t("右下", "BR")), ("bottomLeft", L10n.t("左下", "BL")),
         ("topRight", L10n.t("右上", "TR")), ("topLeft", L10n.t("左上", "TL"))]
    }

    private func toggleMic() {
        if micTesting {
            mic.stop(); mic.onLevel = nil; micTesting = false; micLevel = 0
            return
        }
        Task { @MainActor in
            guard await MicPermission.ensure() else { return }
            mic.onLevel = { v in micLevel = v }
            mic.start(deviceUID: e.c.snap.record.microphoneDevice)
            micTesting = true
        }
    }
}
