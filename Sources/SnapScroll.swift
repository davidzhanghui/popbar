import Cocoa
import ScreenCaptureKit

/// 长截图拼接:逐帧找出滚动偏移,只追加新出现的行(纯逻辑,不依赖 AppKit 窗口/SCK)
struct SnapStitcher {
    enum AddResult: Equatable { case appended(Int), unchanged, tooFast, ambiguous, upward, limitReached }

    private let w: Int
    private let h: Int
    private let maxHeight: Int
    private var lastBytes: [UInt8]
    private var lastHashes: [UInt64]
    private var result: [UInt8]
    private var resultRows: Int
    private var footer: [UInt8] = []
    private var footerRows = 0
    private var limited = false

    init?(first: CGImage, maxHeight: Int = 20000) {
        guard let (bytes, hashes) = Self.decode(first) else { return nil }
        w = first.width
        h = first.height
        self.maxHeight = maxHeight
        lastBytes = bytes
        lastHashes = hashes
        result = bytes
        resultRows = first.height
    }

    var height: Int { resultRows + footerRows }

    mutating func add(_ frame: CGImage) -> AddResult {
        if limited { return .limitReached }
        guard frame.width == w, frame.height == h, let (bytes, hashes) = Self.decode(frame) else { return .ambiguous }
        if hashes == lastHashes { return .unchanged }
        let cap = h / 3
        var header = 0
        while header < cap, hashes[header] == lastHashes[header] { header += 1 }
        var f = 0
        while f < cap, hashes[h - 1 - f] == lastHashes[h - 1 - f] { f += 1 }
        let content = h - header - f
        let maxD = content - max(16, content / 5)
        guard maxD >= 1 else { return .ambiguous }

        func search(down: Bool) -> Int? {
            for d in 1...maxD {
                let overlap = content - d
                let allowed = Int(Double(overlap) * 0.02)
                var miss = 0
                var i = header
                while i < header + overlap {
                    let same = down ? hashes[i] == lastHashes[i + d] : hashes[i + d] == lastHashes[i]
                    if !same { miss += 1; if miss > allowed { break } }
                    i += 1
                }
                if miss <= allowed { return d }
            }
            return nil
        }

        guard let d = search(down: true) else { return search(down: false) != nil ? .upward : .tooFast }
        guard Set(hashes[header..<(header + content - d)]).count >= 8 else { return .ambiguous }

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
        lastHashes = hashes
        if take < d {
            limited = true
            return .limitReached
        }
        return .appended(d)
    }

    func finalImage() -> CGImage? {
        let data = Data(result + footer)
        guard let provider = CGDataProvider(data: data as CFData) else { return nil }
        return CGImage(width: w, height: height, bitsPerComponent: 8, bitsPerPixel: 32, bytesPerRow: w * 4,
                       space: CGColorSpace(name: CGColorSpace.sRGB)!,
                       bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.premultipliedLast.rawValue),
                       provider: provider, decode: nil, shouldInterpolate: false, intent: .defaultIntent)
    }

    private static func decode(_ img: CGImage) -> ([UInt8], [UInt64])? {
        let w = img.width, h = img.height
        guard w > 0, h > 0,
              let ctx = CGContext(data: nil, width: w, height: h, bitsPerComponent: 8, bytesPerRow: w * 4,
                                  space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                  bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue),
              let base = ctx.data?.assumingMemoryBound(to: UInt8.self) else { return nil }
        ctx.draw(img, in: CGRect(x: 0, y: 0, width: w, height: h))
        let bytes = Array(UnsafeBufferPointer(start: base, count: w * h * 4))
        var hashes = [UInt64](repeating: 0, count: h)
        for y in 0..<h {
            var hash: UInt64 = 0xcbf29ce484222325
            for i in (y * w * 4)..<((y + 1) * w * 4) {
                hash = (hash ^ UInt64(bytes[i])) &* 0x100000001b3
            }
            hashes[y] = hash
        }
        return (bytes, hashes)
    }
}

/// 长截图抓取循环:固定区域反复截图,交给拼接器
final class SnapScrollSession {
    let scale: CGFloat
    var onUpdate: ((_ preview: CGImage?, _ status: String) -> Void)?

    private let screen: NSScreen
    private let rect: CGRect
    private var filter: SCContentFilter?
    private var config: SCStreamConfiguration?
    private var stitcher: SnapStitcher?
    private var timer: Timer?
    private var inFlight = false
    private var stopped = false
    private var lastPreview = Date.distantPast
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
        let own = content.applications.filter { $0.processID == getpid() }
        filter = SCContentFilter(display: display, excludingApplications: own, exceptingWindows: [])
        let cfg = SCStreamConfiguration()
        let f = screen.frame
        cfg.sourceRect = CGRect(x: rect.minX - f.minX, y: f.maxY - rect.maxY, width: rect.width, height: rect.height)
        cfg.width = Int((rect.width * scale).rounded())
        cfg.height = Int((rect.height * scale).rounded())
        cfg.showsCursor = false
        cfg.captureResolution = .best
        config = cfg
        let first = try await capture()
        guard let s = SnapStitcher(first: first) else { throw CocoaError(.fileReadCorruptFile) }
        await MainActor.run {
            guard !stopped else { return }
            stitcher = s
            status = L10n.t("向下滚动以拼接", "Scroll down to stitch") + " · \(s.height) px"
            onUpdate?(first, status)
            timer = Timer.scheduledTimer(withTimeInterval: 0.15, repeats: true) { [weak self] _ in self?.tick() }
        }
    }

    func stop() {
        stopped = true
        timer?.invalidate()
        timer = nil
    }

    func finalImage() -> CGImage? { stitcher?.finalImage() }

    private func capture() async throws -> CGImage {
        guard let filter, let config else { throw CocoaError(.fileNoSuchFile) }
        return try await SCScreenshotManager.captureImage(contentFilter: filter, configuration: config)
    }

    private func tick() {
        guard !inFlight, !stopped else { return }
        inFlight = true
        Task { @MainActor in
            defer { inFlight = false }
            guard !stopped, let frame = try? await capture(), !stopped, var s = stitcher else { return }
            let r = s.add(frame)
            stitcher = s
            switch r {
            case .appended:
                status = L10n.t("向下滚动以拼接", "Scroll down to stitch") + " · \(s.height) px"
            case .unchanged:
                return
            case .tooFast, .ambiguous:
                status = L10n.t("请慢一点滚动", "Scroll slower")
            case .upward:
                status = L10n.t("请向下滚动", "Scroll down")
            case .limitReached:
                status = L10n.t("已达上限 20000 px", "Limit reached: 20000 px")
            }
            var preview: CGImage?
            if case .appended = r, Date().timeIntervalSince(lastPreview) > 0.3 { preview = s.finalImage() }
            if case .limitReached = r { preview = s.finalImage() }
            if preview != nil { lastPreview = Date() }
            onUpdate?(preview, status)
        }
    }
}
