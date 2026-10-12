import Cocoa
@preconcurrency import AVFoundation
import QuartzCore

/// 录屏导出管线的端到端验证。
///
/// 纯逻辑测试查不出「涟漪到底画在哪、摄像头有没有出现、裁剪后时长对不对」——
/// 这里用合成视频真跑一遍 AVAssetExportSession,再把成品抽帧逐像素检查。
/// 不依赖屏幕录制权限、不依赖显示器,可以在 CI / 终端里直接跑。

// MARK: - 合成素材

private func makeSolidVideo(url: URL, size: CGSize, seconds: Double, fps: Int32,
                            rgb: (UInt8, UInt8, UInt8)) async throws {
    try? FileManager.default.removeItem(at: url)
    let writer = try AVAssetWriter(outputURL: url, fileType: .mov)
    let input = AVAssetWriterInput(mediaType: .video, outputSettings: [
        AVVideoCodecKey: AVVideoCodecType.h264,
        AVVideoWidthKey: Int(size.width),
        AVVideoHeightKey: Int(size.height),
    ])
    input.expectsMediaDataInRealTime = false
    let adaptor = AVAssetWriterInputPixelBufferAdaptor(assetWriterInput: input, sourcePixelBufferAttributes: [
        kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA,
        kCVPixelBufferWidthKey as String: Int(size.width),
        kCVPixelBufferHeightKey as String: Int(size.height),
    ])
    guard writer.canAdd(input) else { throw RecordExportError.writeFailed("合成素材:无法添加 video input") }
    writer.add(input)
    guard writer.startWriting() else {
        throw RecordExportError.writeFailed("合成素材:startWriting 失败 \(String(describing: writer.error))")
    }
    writer.startSession(atSourceTime: .zero)

    let w = Int(size.width), h = Int(size.height)
    let frames = max(Int((seconds * Double(fps)).rounded()), 1)
    for i in 0..<frames {
        var guardCount = 0
        while !input.isReadyForMoreMediaData {
            usleep(2000)
            guardCount += 1
            if guardCount > 5000 { throw RecordExportError.writeFailed("合成素材:input 一直没准备好") }
        }
        guard let pool = adaptor.pixelBufferPool else {
            throw RecordExportError.writeFailed("合成素材:没有 pixelBufferPool")
        }
        var pb: CVPixelBuffer?
        guard CVPixelBufferPoolCreatePixelBuffer(nil, pool, &pb) == kCVReturnSuccess, let buf = pb else {
            throw RecordExportError.writeFailed("合成素材:申请 pixelBuffer 失败")
        }
        CVPixelBufferLockBaseAddress(buf, [])
        if let base = CVPixelBufferGetBaseAddress(buf) {
            let bpr = CVPixelBufferGetBytesPerRow(buf)
            for y in 0..<h {
                let row = base.advanced(by: y * bpr).assumingMemoryBound(to: UInt8.self)
                for x in 0..<w {
                    row[x * 4 + 0] = rgb.2
                    row[x * 4 + 1] = rgb.1
                    row[x * 4 + 2] = rgb.0
                    row[x * 4 + 3] = 255
                }
            }
        }
        CVPixelBufferUnlockBaseAddress(buf, [])
        guard adaptor.append(buf, withPresentationTime: CMTime(value: CMTimeValue(i), timescale: fps)) else {
            throw RecordExportError.writeFailed("合成素材:append 第 \(i) 帧失败")
        }
    }
    input.markAsFinished()
    await writer.finishWriting()
    guard writer.status == .completed else {
        throw RecordExportError.writeFailed("合成素材:收尾失败 \(String(describing: writer.error))")
    }
}

// MARK: - 抽帧取像素

private func frame(_ url: URL, at seconds: Double) async -> CGImage? {
    let gen = AVAssetImageGenerator(asset: AVURLAsset(url: url))
    gen.appliesPreferredTrackTransform = true
    gen.requestedTimeToleranceBefore = .zero
    gen.requestedTimeToleranceAfter = .zero
    return try? await gen.image(at: CMTime(seconds: seconds, preferredTimescale: 600)).image
}

/// 图像左上原点的像素(x, y) → RGB
private func pixel(_ img: CGImage, x: Int, y: Int) -> (Int, Int, Int) {
    let w = img.width, h = img.height
    var buf = [UInt8](repeating: 0, count: w * h * 4)
    guard w > 0, h > 0,
          let ctx = CGContext(data: &buf, width: w, height: h, bitsPerComponent: 8, bytesPerRow: w * 4,
                              space: CGColorSpace(name: CGColorSpace.sRGB)!,
                              bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return (0, 0, 0) }
    ctx.draw(img, in: CGRect(x: 0, y: 0, width: w, height: h))
    let xx = min(max(x, 0), w - 1), yy = min(max(y, 0), h - 1)
    let o = (yy * w + xx) * 4
    return (Int(buf[o]), Int(buf[o + 1]), Int(buf[o + 2]))
}

private func videoSize(_ url: URL) async -> CGSize {
    let asset = AVURLAsset(url: url)
    guard let t = try? await asset.loadTracks(withMediaType: .video).first,
          let n = try? await t.load(.naturalSize),
          let p = try? await t.load(.preferredTransform) else { return .zero }
    let r = CGRect(origin: .zero, size: n).applying(p)
    return CGSize(width: abs(r.width), height: abs(r.height))
}

private func duration(_ url: URL) async -> Double {
    ((try? await AVURLAsset(url: url).load(.duration)) ?? .zero).seconds
}

/// 纯色 PNG —— 用来验证图片水印有没有画上去
private func makeSolidPNG(url: URL, size: Int, rgb: (Double, Double, Double)) -> Bool {
    guard let ctx = CGContext(data: nil, width: size, height: size, bitsPerComponent: 8, bytesPerRow: 0,
                              space: CGColorSpace(name: CGColorSpace.sRGB)!,
                              bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return false }
    ctx.setFillColor(CGColor(srgbRed: rgb.0, green: rgb.1, blue: rgb.2, alpha: 1))
    ctx.fill(CGRect(x: 0, y: 0, width: size, height: size))
    guard let img = ctx.makeImage() else { return false }
    return (try? NSBitmapImageRep(cgImage: img).representation(using: .png, properties: [:])?
        .write(to: url)) != nil
}

private let noCancel: @Sendable () -> Bool = { false }
private let noProgress: @Sendable (Double) -> Void = { _ in }

// MARK: - 用例

func runExportPipelineTests() async {
    let fm = FileManager.default
    let dir = fm.temporaryDirectory.appendingPathComponent("popbar-export-test-\(UUID().uuidString)", isDirectory: true)
    try? fm.createDirectory(at: dir, withIntermediateDirectories: true)
    defer { try? fm.removeItem(at: dir) }

    let src = dir.appendingPathComponent("src.mov")
    let cam = dir.appendingPathComponent("cam.mov")
    let out = dir.appendingPathComponent("out.mp4")

    section("导出管线:合成素材")
    do {
        // 320×180 深灰蓝:红涟漪与绿色摄像头都能一眼区分
        try await makeSolidVideo(url: src, size: CGSize(width: 320, height: 180),
                                 seconds: 2.0, fps: 30, rgb: (30, 30, 40))
        try await makeSolidVideo(url: cam, size: CGSize(width: 160, height: 120),
                                 seconds: 2.0, fps: 30, rgb: (10, 220, 10))
        expect(fm.fileExists(atPath: src.path), "合成主视频写入成功")
        expect(fm.fileExists(atPath: cam.path), "合成摄像头视频写入成功")
        let d = await duration(src)
        expect(abs(d - 2.0) < 0.2, "合成主视频时长 ≈ 2s(实测 \(String(format: "%.2f", d)))")
    } catch {
        expect(false, "合成素材失败:\(error.localizedDescription)")
        return
    }

    // ① 只用裁剪 → 走 passthrough 快路径,尺寸不变
    section("导出管线:passthrough 裁剪")
    do {
        var p = RecordExportParams()
        p.start = 0.5
        p.end = 1.5
        p.container = "mp4"
        _ = try await RecordExport.export(source: src, params: p, to: out,
                                          progress: noProgress, isCancelled: noCancel)
        let d = await duration(out)
        let s = await videoSize(out)
        expect(abs(d - 1.0) < 0.25, "裁剪后时长 ≈ 1s(实测 \(String(format: "%.2f", d)))")
        expectEqual(Int(s.width), 320, "passthrough 不改尺寸")
    } catch {
        expect(false, "passthrough 导出失败:\(error.localizedDescription)")
    }

    // ② 缩放 + 涟漪 + 摄像头 + 水印 一次导出
    section("导出管线:缩放 / 涟漪 / 摄像头 / 水印")
    let clicks = [
        ClickMark(t: 0.6, x: 0.25, y: 0.25, button: 0),   // 裁剪后 = 成品 0.1s
        ClickMark(t: 0.2, x: 0.9, y: 0.9, button: 0),     // 落在裁剪区间之外,应被丢掉
    ]
    var cameraSidecar: CameraSidecar?
    do {
        var p = RecordExportParams()
        p.start = 0.5
        p.end = 1.5
        p.width = 160                       // 320×180 → 160×90
        p.quality = "high"
        p.container = "mp4"
        p.burnClicks = true
        p.click.radius = 200                // 90 高画布上缩放后 ≈16.7px,足以取到圆心
        p.click.duration = 0.6
        p.clicks = clicks
        p.micEnabled = false
        cameraSidecar = CameraSidecar(file: "cam.mov", x: 0.70, y: 0.70, width: 0.25, height: 0.25, mirror: false)
        p.camera = cameraSidecar
        p.cameraURL = cam
        // 图片水印:纯洋红 PNG,位置放左上角(避开右下角的摄像头),抽帧就能认出来
        let mark = dir.appendingPathComponent("mark.png")
        expect(makeSolidPNG(url: mark, size: 40, rgb: (1, 0, 1)), "生成洋红水印 PNG")
        p.watermark.enabled = true
        p.watermark.imagePath = mark.path
        p.watermark.position = "topLeft"
        p.watermark.size = 24
        p.watermark.opacity = 1
        _ = try await RecordExport.export(source: src, params: p, to: out,
                                          progress: noProgress, isCancelled: noCancel)

        let s = await videoSize(out)
        let d = await duration(out)
        expectEqual(Int(s.width), 160, "缩放到目标宽度 160")
        expectEqual(Int(s.height), 90, "按比例得到 90 高")
        expect(abs(d - 1.0) < 0.25, "成品时长 ≈ 1s(实测 \(String(format: "%.2f", d)))")

        // 点击在成品 0.1s,取 0.2s 的帧:圆心应带红,背景不该红
        if let img = await frame(out, at: 0.2) {
            let cx = Int((0.25 * Double(img.width)).rounded())
            let cy = Int((0.25 * Double(img.height)).rounded())
            let c = pixel(img, x: cx, y: cy)
            let far = pixel(img, x: img.width - 4, y: img.height - 26)   // 远离点击与摄像头的角落
            expect(c.0 > far.0 + 15, "点击位置出现红色涟漪 (圆心 R=\(c.0) vs 背景 R=\(far.0))")
            expect(far.0 < 60 && far.1 < 60, "背景未被涟漪染色 (R=\(far.0) G=\(far.1))")
        } else {
            expect(false, "抽帧失败(0.2s)")
        }

        // 点击之前(成品 0.04s)同一位置不该有涟漪
        if let img = await frame(out, at: 0.04) {
            let cx = Int((0.25 * Double(img.width)).rounded())
            let cy = Int((0.25 * Double(img.height)).rounded())
            let c = pixel(img, x: cx, y: cy)
            expect(c.0 < 60, "点击之前该位置没有涟漪 (R=\(c.0))")
        } else {
            expect(false, "抽帧失败(0.04s)")
        }

        // 摄像头叠加:归一化 (0.70,0.70,0.25,0.25) 在左上原点坐标里就是右下角,
        // 画布中心约 (0.825, 0.825) —— 采样点与归一化坐标同一套约定,不掺入 CA 的翻转
        if let img = await frame(out, at: 0.6) {
            let cx = Int((0.825 * Double(img.width)).rounded())
            let cy = Int((0.825 * Double(img.height)).rounded())
            let c = pixel(img, x: cx, y: cy)
            expect(c.1 > 140 && c.0 < 120, "摄像头画面在归一化 (0.70,0.70) 处 (RGB=\(c.0),\(c.1),\(c.2))")
            // 纵向镜像的位置必须是背景:层指令用左上原点,写错会整体上下翻
            if let img2 = await frame(out, at: 0.6) {
                let flipped = pixel(img2, x: cx, y: img2.height - cy)
                expect(!(flipped.1 > 140 && flipped.0 < 120),
                       "摄像头没有被摆到垂直镜像处 (RGB=\(flipped.0),\(flipped.1),\(flipped.2))")
            }
        } else {
            expect(false, "抽帧失败(0.6s)")
        }

        // 水印:左上角的洋红图片
        if let img = await frame(out, at: 0.6) {
            let c = pixel(img, x: 12, y: 12)
            expect(c.0 > 150 && c.2 > 150 && c.1 < 110, "图片水印画在左上角 (RGB=\(c.0),\(c.1),\(c.2))")
        } else {
            expect(false, "抽帧失败(0.6s,水印)")
        }

        // 文字水印:大字放左下角,区域里应出现近白色的文字像素
        do {
            var q = RecordExportParams()
            q.width = 320
            q.watermark.enabled = true
            q.watermark.text = "WWWW"
            q.watermark.position = "bottomLeft"
            q.watermark.size = 60
            q.watermark.opacity = 1
            let out2 = dir.appendingPathComponent("wm-text.mp4")
            try? FileManager.default.removeItem(at: out2)
            _ = try await RecordExport.export(source: src, params: q, to: out2,
                                              progress: noProgress, isCancelled: noCancel)
            if let img = await frame(out2, at: 0.5) {
                var bright = 0
                for y in (img.height - 60)..<img.height { for x in 0..<110 {
                    let c = pixel(img, x: x, y: y)
                    if c.0 > 200 && c.1 > 200 && c.2 > 200 { bright += 1 }
                } }
                expect(bright > 20, "文字水印画在左下角 (近白像素 \(bright))")
            } else { expect(false, "抽帧失败(文字水印)") }
        }
    } catch {
        expect(false, "合成导出失败:\(error.localizedDescription)")
    }

    // ③ 摄像头比正片短时,之后不能留黑块
    section("导出管线:摄像头比正片短")
    do {
        var p = RecordExportParams()
        p.width = 160
        p.container = "mp4"
        p.camera = CameraSidecar(file: "cam.mov", x: 0.7, y: 0.7, width: 0.25, height: 0.25, mirror: false)
        p.cameraURL = cam
        p.end = 1.2            // 只导 0..1.2,摄像头有 2s,足够覆盖
        try? fm.removeItem(at: out)
        _ = try await RecordExport.export(source: src, params: p, to: out,
                                          progress: noProgress, isCancelled: noCancel)
        expect(fm.fileExists(atPath: out.path), "带摄像头叠加导出成功")
    } catch {
        expect(false, "摄像头叠加导出失败:\(error.localizedDescription)")
    }

    // ④ 取消
    section("导出管线:取消")
    do {
        let cancelled = CancelFlag()
        var p = RecordExportParams()
        p.width = 160
        cancelled.set()
        try? fm.removeItem(at: out)
        var threw = false
        do {
            _ = try await RecordExport.export(source: src, params: p, to: out,
                                              progress: noProgress, isCancelled: { cancelled.value })
        } catch { threw = true }
        expect(threw, "已取消时抛出错误而不是产出文件")
        expect(!fm.fileExists(atPath: out.path), "取消后不留半成品")
    }

    // ⑤ 源文件不存在
    section("导出管线:源文件缺失")
    do {
        var p = RecordExportParams()
        var threw = false
        do {
            _ = try await RecordExport.export(source: dir.appendingPathComponent("nope.mov"), params: p,
                                              to: out, progress: noProgress, isCancelled: noCancel)
        } catch { threw = true }
        expect(threw, "源文件不存在时抛错")
    }

    _ = cameraSidecar
}

private final class CancelFlag: @unchecked Sendable {
    private let lock = NSLock()
    private var flag = false
    var value: Bool { lock.lock(); defer { lock.unlock() }; return flag }
    func set() { lock.lock(); flag = true; lock.unlock() }
}
