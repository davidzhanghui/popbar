import Cocoa
import ScreenCaptureKit
import PopBarCore
import PopBarPlatform
import PopBarDesign

/// 长截图拼接:逐帧找出滚动偏移,只追加新出现的行(纯逻辑,不依赖 AppKit 窗口/SCK)
///
/// 匹配用「容差行特征」而不是逐字节哈希,原因:
/// - 滚动时 macOS 叠加滚动条会在右边缘淡入/移动,逐字节哈希会让几乎每一行都对不上 → 用 ignoreRight 排除右侧条带
/// - 吸顶栏滚动后出现阴影、光标闪烁、GIF/视频小区域变化、亚像素抗锯齿差异 → 行特征带容差 + 只按比例统计失配
/// - 大片空白(两段之间的空行)对任何偏移都"匹配" → 只用有边缘的"信息行"打分
struct SnapStitcher {
    enum AddResult: Equatable { case appended(Int), unchanged, tooFast, ambiguous, upward, limitReached }

    /// 每行切成 bands 条竖带,每条记 (平均亮度, 平均水平梯度),共 vals 个特征值,单位为亮度×4(0…1020)
    static let bands = 16
    static let vals = bands * 2
    /// 单个特征值允许的平均偏差(亮度×4 单位,≈3 级灰度)
    static let tolPerVal: Int32 = 12
    /// 一个偏移被接受时,信息行最多允许的失配比例
    static let maxMissRatio = 0.12

    private let w: Int
    private let h: Int
    private let maxHeight: Int
    private let ignoreRight: Int
    private let rowTol: Int32
    private var lastBytes: [UInt8]
    private var lastFeat: [Int32]
    private var result: [UInt8]
    private var resultRows: Int
    private var footer: [UInt8] = []
    private var footerRows = 0
    private var limited = false

    /// ignoreRight:右侧这么多像素列不参与匹配(叠加滚动条区域),仍然会被拼进结果
    init?(first: CGImage, maxHeight: Int = 20000, ignoreRight: Int = 0) {
        let ir = first.width - ignoreRight >= 32 ? max(ignoreRight, 0) : 0
        guard let (bytes, feat) = Self.decode(first, ignoreRight: ir) else { return nil }
        w = first.width
        h = first.height
        self.maxHeight = maxHeight
        self.ignoreRight = ir
        rowTol = Self.tolPerVal * Int32(Self.vals)
        lastBytes = bytes
        lastFeat = feat
        result = bytes
        resultRows = first.height
    }

    var height: Int { resultRows + footerRows }

    mutating func add(_ frame: CGImage) -> AddResult {
        if limited { return .limitReached }
        guard frame.width == w, frame.height == h,
              let (bytes, feat) = Self.decode(frame, ignoreRight: ignoreRight) else { return .ambiguous }
        let n = Self.vals
        let tol = rowTol
        let last = lastFeat
        @inline(__always) func dist(_ a: [Int32], _ ya: Int, _ b: [Int32], _ yb: Int) -> Int32 {
            var s: Int32 = 0
            let ia = ya * n, ib = yb * n
            for k in 0..<n { s &+= abs(a[ia + k] &- b[ib + k]) }
            return s
        }

        var changed = false
        for y in 0..<h where dist(feat, y, last, y) > tol { changed = true; break }
        if !changed { return .unchanged }

        // 固定的顶栏/底栏:与上一帧同位置不变的行
        let cap = h / 3
        var header = 0
        while header < cap, dist(feat, header, last, header) <= tol { header += 1 }
        var f = 0
        while f < cap, dist(feat, h - 1 - f, last, h - 1 - f) <= tol { f += 1 }
        let content = h - header - f
        let minOverlap = max(12, content / 6)
        let maxD = content - minOverlap
        guard maxD >= 1 else { return .ambiguous }

        // 信息行:与上下相邻行明显不同(文字/边框的边缘),空白行不参与打分
        let lo = header, hi = header + content
        var info: [Int] = []
        info.reserveCapacity(content)
        for y in lo..<hi {
            let up = y > lo && dist(feat, y, feat, y - 1) > tol
            let dn = y < hi - 1 && dist(feat, y, feat, y + 1) > tol
            if up || dn { info.append(y) }
        }
        guard info.count >= 8 else { return .ambiguous }
        let minRows = max(6, min(24, info.count / 4))

        /// 返回失配比例最低的偏移;down=true 表示内容向上走(用户向下滚)
        func search(down: Bool) -> (d: Int, miss: Int, rows: Int)? {
            var best: (d: Int, miss: Int, rows: Int)?
            for d in 1...maxD {
                // down:新帧 y ↔ 旧帧 y+d,要求 y+d < hi;up:新帧 y ↔ 旧帧 y-d,要求 y-d >= lo
                var rows = 0
                if down { for y in info { if y + d < hi { rows += 1 } else { break } } }
                else { for y in info.reversed() { if y - d >= lo { rows += 1 } else { break } } }
                guard rows >= minRows else { continue }
                // 允许的最大失配数:不比当前最优更差(比例意义下)
                let budget: Int = best.map { b in (b.miss * rows) / max(b.rows, 1) } ?? Int(Double(rows) * Self.maxMissRatio)
                var miss = 0
                var i = down ? 0 : info.count - rows
                let end = i + rows
                while i < end {
                    let y = info[i]
                    if dist(feat, y, last, down ? y + d : y - d) > tol {
                        miss += 1
                        if miss > budget { break }
                    }
                    i += 1
                }
                guard miss <= budget else { continue }
                if let b = best, miss * b.rows >= b.miss * rows { continue }
                best = (d, miss, rows)
                if miss == 0 && rows >= minRows * 2 { break }   // 完全吻合且样本足够,不必再找
            }
            guard let b = best, Double(b.miss) <= Double(b.rows) * Self.maxMissRatio else { return nil }
            return b
        }

        guard let match = search(down: true) else { return search(down: false) != nil ? .upward : .tooFast }
        let d = match.d

        let rb = w * 4
        if f > footerRows {
            let drop = f - footerRows
            result.removeLast(drop * rb)
            resultRows -= drop
        } else if f < footerRows {
            result.append(contentsOf: lastBytes[((h - footerRows) * rb)..<((h - f) * rb)])
            resultRows += footerRows - f
        }
        let room = max(maxHeight - resultRows - f, 0)
        let take = min(d, room)
        let start = h - f - d
        result.append(contentsOf: bytes[(start * rb)..<((start + take) * rb)])
        resultRows += take
        footer = Array(bytes[((h - f) * rb)..<(h * rb)])
        footerRows = f
        lastBytes = bytes
        lastFeat = feat
        if take < d {
            limited = true
            return .limitReached
        }
        return .appended(d)
    }

    func finalImage() -> CGImage? {
        var data = Data(capacity: (result.count + footer.count))
        data.append(contentsOf: result)
        data.append(contentsOf: footer)
        guard let provider = CGDataProvider(data: data as CFData) else { return nil }
        return CGImage(width: w, height: height, bitsPerComponent: 8, bitsPerPixel: 32, bytesPerRow: w * 4,
                       space: CGColorSpace(name: CGColorSpace.sRGB)!,
                       bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.premultipliedLast.rawValue),
                       provider: provider, decode: nil, shouldInterpolate: false, intent: .defaultIntent)
    }

    /// 缩略预览:直接从内部缓冲画到小画布,不复制整张长图
    func preview(maxWidth: Int, maxHeight maxH: Int) -> CGImage? {
        let total = height
        let s = min(Double(maxWidth) / Double(w), Double(maxH) / Double(total), 1)
        let tw = max(Int(Double(w) * s), 1), th = max(Int(Double(total) * s), 1)
        let space = CGColorSpace(name: CGColorSpace.sRGB)!
        guard let ctx = CGContext(data: nil, width: tw, height: th, bitsPerComponent: 8, bytesPerRow: 0, space: space,
                                  bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return nil }
        ctx.interpolationQuality = .medium
        func draw(_ buf: [UInt8], rows: Int, top: Int) {
            guard rows > 0 else { return }
            buf.withUnsafeBytes { raw in
                guard let base = raw.baseAddress,
                      let provider = CGDataProvider(dataInfo: nil, data: base, size: rows * w * 4, releaseData: { _, _, _ in }),
                      let img = CGImage(width: w, height: rows, bitsPerComponent: 8, bitsPerPixel: 32, bytesPerRow: w * 4,
                                        space: space, bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.premultipliedLast.rawValue),
                                        provider: provider, decode: nil, shouldInterpolate: true, intent: .defaultIntent)
                else { return }
                // CG 坐标原点在左下:top 是从图顶部数的行
                let y = Double(total - top - rows) * s
                ctx.draw(img, in: CGRect(x: 0, y: y, width: Double(tw), height: Double(rows) * s))
            }
        }
        draw(result, rows: resultRows, top: 0)
        draw(footer, rows: footerRows, top: resultRows)
        return ctx.makeImage()
    }

    /// 解码成 RGBA 字节 + 每行特征(h × vals)
    private static func decode(_ img: CGImage, ignoreRight: Int) -> ([UInt8], [Int32])? {
        let w = img.width, h = img.height
        guard w > 0, h > 0,
              let ctx = CGContext(data: nil, width: w, height: h, bitsPerComponent: 8, bytesPerRow: w * 4,
                                  space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                  bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue),
              let base = ctx.data?.assumingMemoryBound(to: UInt8.self) else { return nil }
        ctx.draw(img, in: CGRect(x: 0, y: 0, width: w, height: h))
        let bytes = Array(UnsafeBufferPointer(start: base, count: w * h * 4))
        let usable = max(w - ignoreRight, 1)
        let nb = bands
        var feat = [Int32](repeating: 0, count: h * vals)
        // 竖带边界;窄图时部分竖带为空,特征保持 0
        let edges = (0...nb).map { $0 * usable / nb }
        feat.withUnsafeMutableBufferPointer { fp in
            for y in 0..<h {
                let row = base + y * w * 4
                for b in 0..<nb {
                    let x0 = edges[b], x1 = edges[b + 1]
                    guard x1 > x0 else { continue }
                    var sum = 0, grad = 0
                    var prev = -1
                    for x in x0..<x1 {
                        let p = row + x * 4
                        let l = Int(p[0]) + 2 * Int(p[1]) + Int(p[2])
                        sum += l
                        if prev >= 0 { grad += abs(l - prev) }
                        prev = l
                    }
                    let cnt = x1 - x0
                    fp[y * vals + b * 2] = Int32(sum / cnt)
                    fp[y * vals + b * 2 + 1] = Int32(grad / cnt)
                }
            }
        }
        return (bytes, feat)
    }
}

/// 长截图抓取循环:固定区域反复截图,交给拼接器;支持手动滚动和自动滚动
/// 状态字段只在主线程读写;拼接器只在 work 队列上读写。unchecked Sendable 仅为消除严格并发警告
final class SnapScrollSession: @unchecked Sendable {
    let scale: CGFloat
    var onUpdate: ((_ preview: CGImage?, _ status: String) -> Void)?
    var onAutoChange: ((Bool) -> Void)?
    private(set) var autoScrolling = false

    private let screen: NSScreen
    private let rect: CGRect
    private let work = DispatchQueue(label: "popbar.snap.stitch", qos: .userInitiated)
    private var filter: SCContentFilter?
    private var config: SCStreamConfiguration?
    private var stitcher: SnapStitcher?          // 仅 work 队列
    private var lastPreview = Date.distantPast   // 仅 work 队列
    private var timer: Timer?
    private var autoTask: Task<Void, Never>?
    private var inFlight = false
    private var stopped = false
    private var status = ""

    /// rect 为 Cocoa 全局坐标
    init(screen: NSScreen, rect: CGRect) {
        self.screen = screen
        self.rect = rect
        scale = screen.backingScaleFactor
    }

    func start() async throws {
        let content = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: true)
        let id = (screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber)?.uint32Value
        guard let display = content.displays.first(where: { $0.displayID == id }) else { throw CocoaError(.fileNoSuchFile) }
        // 滚动框/控制条在 start 之前已创建并标记,这里排除它们;其余 PopBar 窗口照常进画面
        filter = SCContentFilter(display: display, excludingWindows: await CaptureChrome.excludedWindows())
        let cfg = SCStreamConfiguration()
        let f = screen.frame
        cfg.sourceRect = CGRect(x: rect.minX - f.minX, y: f.maxY - rect.maxY, width: rect.width, height: rect.height)
        cfg.width = Int((rect.width * scale).rounded())
        cfg.height = Int((rect.height * scale).rounded())
        cfg.showsCursor = false
        cfg.captureResolution = .best
        config = cfg
        let first = try await capture()
        // 叠加滚动条最宽约 16pt,留点余量
        guard let s = SnapStitcher(first: first, ignoreRight: Int((18 * scale).rounded())) else {
            throw CocoaError(.fileReadCorruptFile)
        }
        let px = s.height
        work.sync { stitcher = s }
        await MainActor.run {
            guard !stopped else { return }
            status = Self.progress(px)
            onUpdate?(first, status)
            timer = Timer.scheduledTimer(withTimeInterval: 0.08, repeats: true) { [weak self] _ in self?.tick() }
        }
    }

    func stop() {
        stopped = true
        timer?.invalidate()
        timer = nil
        autoScrolling = false
        autoTask?.cancel()
        autoTask = nil
    }

    func finalImage() -> CGImage? { work.sync { stitcher?.finalImage() } }

    // MARK: - 抓帧 + 拼接

    private static func progress(_ px: Int) -> String {
        L10n.t("向下滚动以拼接", "Scroll down to stitch") + " · \(px) px"
    }

    private func capture() async throws -> CGImage {
        guard let filter, let config else { throw CocoaError(.fileNoSuchFile) }
        return try await SCScreenshotManager.captureImage(contentFilter: filter, configuration: config)
    }

    /// 截一帧并拼接;拼接在后台队列做,不卡主线程
    @MainActor
    private func processFrame() async -> SnapStitcher.AddResult? {
        guard !stopped, let frame = try? await capture(), !stopped else { return nil }
        let (r, px, preview): (SnapStitcher.AddResult?, Int, CGImage?) = await withCheckedContinuation { cont in
            work.async { [self] in
                guard stitcher != nil else { return cont.resume(returning: (nil, 0, nil)) }
                let r = stitcher!.add(frame)   // 原地修改,避免整张长图写时复制
                let px = stitcher!.height
                var preview: CGImage?
                let interval = 0.25 + Double(px) / 40000
                let due = Date().timeIntervalSince(lastPreview) > interval
                if (r == .limitReached) || (due && { if case .appended = r { return true }; return false }()) {
                    preview = stitcher!.preview(maxWidth: 360, maxHeight: 2400)
                    lastPreview = Date()
                }
                cont.resume(returning: (r, px, preview))
            }
        }
        guard let r, !stopped else { return nil }
        switch r {
        case .appended:
            status = Self.progress(px)
        case .unchanged:
            if preview == nil { return r }
        case .tooFast:
            status = L10n.t("滚动太快，请往回滚一点", "Too fast, scroll back up a little")
        case .ambiguous:
            status = L10n.t("内容太少无法对齐，继续滚动", "Not enough detail, keep scrolling")
        case .upward:
            status = L10n.t("请向下滚动", "Scroll down")
        case .limitReached:
            status = L10n.t("已达上限 20000 px", "Limit reached: 20000 px")
        }
        onUpdate?(preview, status)
        return r
    }

    private func tick() {
        guard !inFlight, !stopped, !autoScrolling else { return }
        inFlight = true
        Task { @MainActor in
            _ = await processFrame()
            inFlight = false
        }
    }

    // MARK: - 自动滚动

    func toggleAuto() {
        autoScrolling ? stopAuto(nil) : startAuto()
    }

    private func startAuto() {
        guard !stopped else { return }
        guard AXSupport.isTrusted else {
            AXSupport.promptIfNeeded()
            status = L10n.t("自动滚动需要辅助功能权限", "Auto-scroll needs Accessibility permission")
            onUpdate?(nil, status)
            return
        }
        autoScrolling = true
        onAutoChange?(true)
        // 滚轮事件发给鼠标下的窗口:把指针移到选区中心(截图不含指针)
        CGWarpMouseCursorPosition(cgCenter)
        CGAssociateMouseAndMouseCursorPosition(1)
        autoTask = Task { @MainActor [weak self] in await self?.autoLoop() }
    }

    private func stopAuto(_ message: String?) {
        guard autoScrolling else { return }
        autoScrolling = false
        autoTask?.cancel()
        autoTask = nil
        onAutoChange?(false)
        if let message {
            status = message
            onUpdate?(nil, status)
        }
    }

    /// Cocoa 全局坐标 → CG 全局坐标(原点在主屏左上)
    private var cgCenter: CGPoint {
        let primaryH = NSScreen.screens.first?.frame.height ?? screen.frame.height
        return CGPoint(x: rect.midX, y: primaryH - rect.midY)
    }

    @MainActor
    private func autoLoop() async {
        // 每步滚 ~45% 选区高度,保证与上一帧有足够重叠;被吸顶栏占掉的部分也留了余量
        var step = max(rect.height * 0.45, 40)
        var still = 0
        while inFlight { try? await Task.sleep(nanoseconds: 20_000_000) }
        while autoScrolling, !stopped, !Task.isCancelled {
            await postScroll(points: step)
            try? await Task.sleep(nanoseconds: 180_000_000)   // 等目标应用重绘
            guard autoScrolling, !stopped, !Task.isCancelled else { break }
            inFlight = true
            let r = await processFrame()
            inFlight = false
            switch r {
            case .appended:
                still = 0
            case .unchanged:
                still += 1
                if still >= 3 { return stopAuto(L10n.t("已到底部", "Reached the bottom")) }
            case .tooFast:
                // 应用把滚动量放大了:退回一半并减小步长
                await postScroll(points: -step / 2)
                step = max(step / 2, 20)
                try? await Task.sleep(nanoseconds: 150_000_000)
            case .limitReached:
                return stopAuto(nil)
            default:
                break
            }
        }
    }

    /// 发送像素级(触控板式)滚轮事件;points>0 向下滚。拆成小段,更接近真实触控板,兼容对单次大增量做限制的应用
    @MainActor
    private func postScroll(points: CGFloat) async {
        let src = CGEventSource(stateID: .hidSystemState)
        var left = Int(points.rounded())
        let sign = left >= 0 ? -1 : 1   // 负值 = 内容向上走(向下滚)
        left = abs(left)
        let loc = cgCenter
        while left > 0, !stopped {
            let chunk = min(left, 40)
            left -= chunk
            guard let e = CGEvent(scrollWheelEvent2Source: src, units: .pixel, wheelCount: 1,
                                  wheel1: Int32(sign * chunk), wheel2: 0, wheel3: 0) else { return }
            e.setIntegerValueField(.scrollWheelEventIsContinuous, value: 1)
            e.location = loc
            e.post(tap: .cghidEventTap)
            try? await Task.sleep(nanoseconds: 8_000_000)
        }
    }
}
