import Cocoa
import Vision

/// 菜单栏入口:截图翻译 / 输入翻译 / 剪贴板翻译
enum TranslateTriggers {

    /// 截图翻译:系统 screencapture 选区截图 → Vision OCR → 翻译面板
    /// 需要「屏幕录制」权限;SCScreenshotManager 没有交互选区 API,统一走 screencapture -i
    static func screenshot() {
        if !CGPreflightScreenCaptureAccess() {
            CGRequestScreenCaptureAccess()   // 触发系统授权弹窗
            let a = NSAlert()
            a.messageText = L10n.t("需要「屏幕录制」权限", "Screen Recording Permission Required")
            a.informativeText = L10n.t(
                "截图翻译需要读取屏幕上的文字。\n请在 系统设置 → 隐私与安全性 → 屏幕录制 中允许 PopBar,然后重新使用本功能。",
                "Screenshot translation needs to read text on screen.\nPlease allow PopBar in System Settings → Privacy & Security → Screen Recording, then try again.")
            a.addButton(withTitle: L10n.t("打开设置", "Open Settings"))
            a.addButton(withTitle: L10n.t("取消", "Cancel"))
            NSApp.activate(ignoringOtherApps: true)
            if a.runModal() == .alertFirstButtonReturn {
                if let u = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_ScreenCapture") {
                    NSWorkspace.shared.open(u)
                }
            }
            return
        }
        captureInteractively()
    }

    /// 输入翻译:弹出翻译面板,原文区可编辑
    static func input() {
        TranslationPanelController.shared.showInput()
    }

    /// 剪贴板翻译:文本直接翻,图片先 OCR 再翻
    static func clipboard() {
        let pb = NSPasteboard.general
        if let text = pb.string(forType: .string),
           !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            TranslationPanelController.shared.show(text: text)
            return
        }
        for type in [NSPasteboard.PasteboardType.png, .tiff] {
            if let data = pb.data(forType: type),
               let cg = NSImage(data: data)?.cgImage(forProposedRect: nil, context: nil, hints: nil) {
                ocrAndShow(cg)
                return
            }
        }
        NSSound.beep()
    }

    // MARK: - 私有

    private static func ocrAndShow(_ image: CGImage) {
        TextOCR.recognize(image) { text in
            guard let text,
                  !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
                NSSound.beep()   // 没识别到文字
                return
            }
            TranslationPanelController.shared.show(text: text)
        }
    }

    /// 调系统自带的交互选区截图(十字光标,Esc 取消),写到临时文件再读回
    private static func captureInteractively() {
        let path = NSTemporaryDirectory() + "popbar-shot-\(UUID().uuidString).png"
        let proc = Process()
        proc.executableURL = URL(fileURLWithPath: "/usr/sbin/screencapture")
        proc.arguments = ["-x", "-i", path]   // 静音 + 交互选区
        proc.terminationHandler = { p in
            DispatchQueue.main.async {
                defer { try? FileManager.default.removeItem(atPath: path) }
                guard p.terminationStatus == 0,
                      let cg = NSImage(contentsOfFile: path)?
                        .cgImage(forProposedRect: nil, context: nil, hints: nil) else {
                    return   // 用户取消
                }
                ocrAndShow(cg)
            }
        }
        try? proc.run()
    }
}

/// Vision 离线 OCR,中英双语,不需要任何权限和网络
enum TextOCR {
    static func recognize(_ image: CGImage, completion: @escaping (String?) -> Void) {
        DispatchQueue.global(qos: .userInitiated).async {
            let request = VNRecognizeTextRequest { req, _ in
                let lines = (req.results as? [VNRecognizedTextObservation])?
                    .compactMap { $0.topCandidates(1).first?.string } ?? []
                DispatchQueue.main.async {
                    completion(lines.isEmpty ? nil : lines.joined(separator: "\n"))
                }
            }
            request.recognitionLevel = .accurate
            request.recognitionLanguages = ["zh-Hans", "en-US"]
            request.usesLanguageCorrection = true
            try? VNImageRequestHandler(cgImage: image, options: [:]).perform([request])
        }
    }
}
