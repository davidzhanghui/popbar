import Cocoa

/// 截屏输出:合成(裁剪 + 后续标注渲染)→ 复制 / 保存 / OCR
enum SnapOutput {
    /// selection 为视图坐标(左下原点,点);标注坐标与选区同一空间
    static func compose(image: CGImage, scale: CGFloat, selection: CGRect, viewHeight: CGFloat,
                        annotations: [SnapAnnotation] = [], mosaicImage: CGImage? = nil) -> CGImage {
        let px = SnapGeometry.pixelRect(selection, viewHeight: viewHeight, scale: scale)
        let cropped = image.cropping(to: px) ?? image
        guard !annotations.isEmpty else { return cropped }
        return render(cropped, scale: scale, selection: selection, viewHeight: viewHeight,
                      imageBounds: CGRect(x: 0, y: 0, width: CGFloat(image.width) / scale, height: viewHeight),
                      annotations: annotations, mosaicImage: mosaicImage)
    }

    private static func render(_ base: CGImage, scale: CGFloat, selection: CGRect, viewHeight: CGFloat,
                               imageBounds: CGRect, annotations: [SnapAnnotation], mosaicImage: CGImage?) -> CGImage {
        let info = CGImageAlphaInfo.premultipliedLast.rawValue
        let sRGB = CGColorSpace(name: CGColorSpace.sRGB)!
        let ctx = base.colorSpace.flatMap {
            CGContext(data: nil, width: base.width, height: base.height, bitsPerComponent: 8,
                      bytesPerRow: 0, space: $0, bitmapInfo: info)
        } ?? CGContext(data: nil, width: base.width, height: base.height, bitsPerComponent: 8,
                       bytesPerRow: 0, space: sRGB, bitmapInfo: info)
        guard let ctx else { return base }
        ctx.draw(base, in: CGRect(x: 0, y: 0, width: base.width, height: base.height))
        ctx.scaleBy(x: scale, y: scale)
        ctx.translateBy(x: -selection.minX, y: -selection.minY)
        for a in annotations { a.draw(in: ctx, mosaicImage: mosaicImage, imageBounds: imageBounds) }
        return ctx.makeImage() ?? base
    }

    static func copy(_ img: CGImage, scale: CGFloat) {
        let rep = NSBitmapImageRep(cgImage: img)
        let nsImage = NSImage(cgImage: img, size: NSSize(width: CGFloat(img.width) / scale,
                                                         height: CGFloat(img.height) / scale))
        let item = NSPasteboardItem()
        if let png = rep.representation(using: .png, properties: [:]) { item.setData(png, forType: .png) }
        if let tiff = nsImage.tiffRepresentation { item.setData(tiff, forType: .tiff) }
        PasteboardGuard.write(items: [item])
    }

    static func save(_ img: CGImage) {
        let cfg = ConfigStore.shared.config.snap
        let isJPG = cfg.format == "jpg"
        let dir = URL(fileURLWithPath: (cfg.saveDir as NSString).expandingTildeInPath, isDirectory: true)
        let fmt = DateFormatter()
        fmt.dateFormat = "yyyy-MM-dd 'at' HH.mm.ss"
        let url = dir.appendingPathComponent("PopBar \(fmt.string(from: Date())).\(isJPG ? "jpg" : "png")")
        let rep = NSBitmapImageRep(cgImage: img)
        let data = isJPG ? rep.representation(using: .jpeg, properties: [.compressionFactor: 0.9])
                         : rep.representation(using: .png, properties: [:])
        do {
            try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
            guard let data else { throw CocoaError(.fileWriteUnknown) }
            try data.write(to: url)
        } catch {
            NSSound.beep()
            return
        }
        FloatingBarController.shared.showResult(
            L10n.t("已保存:", "Saved: ") + url.lastPathComponent,
            buttons: [(L10n.t("在 Finder 中显示", "Show in Finder"), {
                NSWorkspace.shared.activateFileViewerSelecting([url])
            })])
    }

    static func ocr(_ img: CGImage) {
        TranslateTriggers.handleOCRImage(img)
    }
}
