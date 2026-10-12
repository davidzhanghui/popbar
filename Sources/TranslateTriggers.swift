import Cocoa
import Vision

/// 菜单栏入口:截图翻译 / 输入翻译 / 剪贴板翻译
enum TranslateTriggers {

    /// 截图翻译:系统 screencapture 选区截图 → Vision OCR → 翻译面板
    /// 需要「屏幕录制」权限;SCScreenshotManager 没有交互选区 API,统一走 screencapture -i
    static func screenshot() {
        guard ScreenPermission.ensure() else { return }
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
                handleOCRImage(cg)
                return
            }
        }
        NSSound.beep()
    }

    /// OCR 结果统一路由(截图翻译、截屏 OCR 共用)
    static func handleOCRImage(_ image: CGImage) {
        TextOCR.recognize(image) { text in
            guard let text,
                  !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
                // #19 没文字时仍可能是二维码
                detectBarcode(image)
                return
            }
            switch ConfigStore.shared.config.ocr.after {
            case "bar":
                // #19 OCR 结果直接弹完整工具条
                var ctx = SourceContext(text: text, origin: .ocr)
                ctx.bounds = nil
                FloatingBarController.shared.show(ctx: ctx)
                detectBarcode(image)
            default:
                TranslationPanelController.shared.show(text: text)
                detectBarcode(image)
            }
        }
    }

    // MARK: - 私有

    /// #19 识别截图里的二维码:命中则弹出可点击的结果条
    private static func detectBarcode(_ image: CGImage) {
        TextOCR.detectBarcode(image) { payloads in
            guard let first = payloads.first else { return }
            FloatingBarController.shared.showResult(
                L10n.t("二维码:", "QR: ") + first,
                buttons: [
                    (L10n.t("复制", "Copy"), { PasteboardGuard.write(first) }),
                    (L10n.t("打开", "Open"), {
                        var s = first
                        if !s.contains("://") { s = "https://" + s }
                        if let u = URL(string: s) { NSWorkspace.shared.open(u) }
                    }),
                ])
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
                handleOCRImage(cg)
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

    /// #19 二维码识别;返回全部 payload(空数组 = 无)
    static func detectBarcode(_ image: CGImage, completion: @escaping ([String]) -> Void) {
        DispatchQueue.global(qos: .userInitiated).async {
            let request = VNDetectBarcodesRequest { req, _ in
                let payloads = (req.results as? [VNBarcodeObservation])?
                    .compactMap { $0.payloadStringValue } ?? []
                DispatchQueue.main.async { completion(payloads) }
            }
            try? VNImageRequestHandler(cgImage: image, options: [:]).perform([request])
        }
    }
}
