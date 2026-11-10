import Cocoa
@preconcurrency import AVFoundation
import ImageIO
import UniformTypeIdentifiers
import PopBarCore
import PopBarPlatform
import PopBarDesign

enum GIFError: LocalizedError {
    case noVideo
    case cancelled
    case writeFailed

    var errorDescription: String? {
        switch self {
        case .noVideo: return L10n.t("文件里没有可导出的视频轨", "No video track to export")
        case .cancelled: return L10n.t("已取消", "Cancelled")
        case .writeFailed: return L10n.t("GIF 写入失败", "Failed to write GIF")
        }
    }
}

struct GIFParams {
    /// 5 | 10 | 15
    var fps: Int = 10
    /// 0 = 原始宽度
    var width: Int = 800
    var start: Double = 0
    /// nil = 到结尾
    var end: Double? = nil
    var loop: Bool = true

    /// 「直接录 GIF」:≤800 宽、10fps、整段
    static var auto: GIFParams {
        let cfg = ConfigStore.shared.config.snap.record.gif
        return GIFParams(fps: min(max(cfg.fps, 5), 15),
                         width: cfg.width > 0 ? min(cfg.width, 800) : 800,
                         start: 0, end: nil, loop: true)
    }

    static var defaults: GIFParams {
        let cfg = ConfigStore.shared.config.snap.record.gif
        return GIFParams(fps: min(max(cfg.fps, 1), 30), width: cfg.width, start: 0, end: nil, loop: true)
    }
}

enum RecordGIF {
    /// 帧数与输出尺寸(纯逻辑,便于测试):width ≤ 0 表示原始宽度
    static func plan(duration: Double, size: CGSize, fps: Int, width: Int) -> (frames: Int, size: CGSize) {
        let count = max(Int((max(duration, 0) * Double(max(fps, 1))).rounded()), 1)
        let naturalW = max(Int(size.width.rounded()), 1)
        let w = width > 0 ? max(min(width, naturalW), 1) : naturalW
        let h = max(Int((size.height * CGFloat(w) / max(size.width, 1)).rounded()), 1)
        return (count, CGSize(width: w, height: h))
    }

    /// 起止钳位(纯逻辑,便于测试):span 为有效视频时长
    static func clampRange(span: Double, start: Double, end: Double?) -> (Double, Double) {
        let s = min(max(start, 0), max(span - 0.01, 0))
        let e = min(max(end ?? span, s + 0.01), span)
        return (s, e)
    }

    /// dest 为 nil 时写到源文件旁边、同名 .gif
    static func export(url: URL, params: GIFParams, to destURL: URL? = nil,
                       progress: @escaping @Sendable (Double) -> Void = { _ in },
                       isCancelled: @escaping @Sendable () -> Bool = { false }) async throws -> URL {
        let asset = AVURLAsset(url: url)
        guard let track = try? await asset.loadTracks(withMediaType: .video).first else { throw GIFError.noVideo }
        let seconds = ((try? await asset.load(.duration)) ?? .zero).seconds
        let natural = (try? await track.load(.naturalSize)) ?? .zero
        let transform = (try? await track.load(.preferredTransform)) ?? .identity
        let raw = natural.applying(transform)
        let size = CGSize(width: abs(raw.width), height: abs(raw.height))
        guard seconds > 0.01, size.width >= 1, size.height >= 1 else { throw GIFError.noVideo }

        // 录制中掉帧时视频轨可能比音频/容器短,取帧范围以视频轨实际时长为准,
        // 否则超出末尾的请求点会报 Cannot Open
        let videoDur = ((try? await track.load(.timeRange))?.duration.seconds ?? 0)
        let span = videoDur > 0.01 ? min(seconds, videoDur) : seconds
        let (start, end) = clampRange(span: span, start: params.start, end: params.end)
        let (frames, outSize) = plan(duration: end - start, size: size, fps: params.fps, width: params.width)
        let times = (0..<frames).map { i in
            CMTime(seconds: start + (end - start) * (Double(i) / Double(frames)), preferredTimescale: 600)
        }

        let generator = AVAssetImageGenerator(asset: asset)
        generator.appliesPreferredTrackTransform = true
        generator.requestedTimeToleranceBefore = .zero
        generator.requestedTimeToleranceAfter = .zero
        generator.maximumSize = outSize       // 解码时就缩到目标尺寸,避免整段 1080p 常驻内存

        let dest = destURL ?? RecordUtil.uniqueURL(in: url.deletingLastPathComponent(),
                                                   stem: url.deletingPathExtension().lastPathComponent, ext: "gif")
        do {
            try await write(generator: generator, times: times, to: dest,
                            fps: params.fps, loop: params.loop, progress: progress, isCancelled: isCancelled)
        } catch {
            try? FileManager.default.removeItem(at: dest)   // 中途失败/取消不留半成品
            throw error
        }
        progress(1)
        return dest
    }

    /// 逐帧解码并边写边丢:generateCGImagesAsynchronously 一次性并发全部请求会让硬件解码器
    /// 过载,中段帧批量报 Cannot Decode(-11821);串行 copyCGImage 实测全部成功且 99 帧 ≈1s。
    /// 边解边写同时把内存峰值从整段帧降到单帧。
    private static func write(generator: AVAssetImageGenerator, times: [CMTime], to url: URL,
                              fps: Int, loop: Bool,
                              progress: @escaping @Sendable (Double) -> Void,
                              isCancelled: @escaping @Sendable () -> Bool) async throws {
        try await Task.detached(priority: .userInitiated) {
            guard let dest = CGImageDestinationCreateWithURL(url as CFURL, UTType.gif.identifier as CFString,
                                                             times.count, nil) else { throw GIFError.writeFailed }
            CGImageDestinationSetProperties(dest, [
                kCGImagePropertyGIFDictionary: [kCGImagePropertyGIFLoopCount: loop ? 0 : 1],
            ] as CFDictionary)
            let delay = 1.0 / Double(max(fps, 1))
            let props = [
                kCGImagePropertyGIFDictionary: [kCGImagePropertyGIFDelayTime: delay],
            ] as CFDictionary
            for (i, t) in times.enumerated() {
                if isCancelled() { throw GIFError.cancelled }
                let img: CGImage = try await withCheckedThrowingContinuation { (c: CheckedContinuation<CGImage, Error>) in
                    generator.generateCGImageAsynchronously(for: t) { image, _, error in
                        if let image { c.resume(returning: image) }
                        else { c.resume(throwing: error ?? GIFError.noVideo) }
                    }
                }
                CGImageDestinationAddImage(dest, img, props)
                if (i + 1) % 5 == 0 || i + 1 == times.count {
                    progress(Double(i + 1) / Double(times.count) * 0.95)
                }
            }
            guard CGImageDestinationFinalize(dest) else { throw GIFError.writeFailed }
        }.value
    }
}
