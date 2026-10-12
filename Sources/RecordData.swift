import Cocoa

// MARK: - 旁挂数据

/// 一次点击:t 为「已录制时长」(不含暂停),x/y 为录制区内的归一化坐标(左上原点)
struct ClickMark: Codable, Equatable {
    var t: Double
    var x: Double
    var y: Double
    /// 0 左键 / 1 右键 / 2 中键
    var button: Int = 0
}

/// 录制中打的标记点,导出时用来快速定位
struct RecordMarker: Codable, Equatable {
    var t: Double
}

/// 摄像头旁挂视频的在成品上的位置(归一化,左上原点)
struct CameraSidecar: Codable, Equatable {
    var file: String
    var x: Double
    var y: Double
    var width: Double
    var height: Double
    var mirror: Bool
}

/// 一段录制附带的全部元数据,存到 RecordData/<key>/sidecar.json
struct RecordSidecar: Codable, Equatable {
    var version: Int = 1
    /// 记下它属于哪个视频:清理孤儿目录时要用
    var videoPath: String = ""
    var duration: Double = 0
    var videoWidth: Int = 0
    var videoHeight: Int = 0
    /// 自由选区时的录制区(Cocoa 全局坐标);跟随窗口时为空
    var areaRect: [Double]?
    var windowID: UInt32?
    /// 录制时是否开了麦克风 —— 导出时用来判断第二条音轨是不是麦克风
    var micEnabled: Bool = false
    var clicks: [ClickMark] = []
    var markers: [RecordMarker] = []
    var camera: CameraSidecar?

    init() {}

    var area: CGRect? {
        guard let a = areaRect, a.count == 4 else { return nil }
        return CGRect(x: a[0], y: a[1], width: a[2], height: a[3])
    }
}

/// 旁挂数据的落盘位置。目录名用稳定哈希 —— String.hashValue 每次启动都不同,不能做目录名。
enum RecordDataStore {
    static var root: URL { PopBarConfig.directoryURL.appendingPathComponent("RecordData", isDirectory: true) }

    /// FNV-1a 64 位:同一路径永远得到同一个 key
    static func stableKey(_ path: String) -> String {
        var hash: UInt64 = 0xcbf2_9ce4_8422_2325
        for b in path.utf8 {
            hash ^= UInt64(b)
            hash = hash &* 0x0000_0100_0000_01b3
        }
        return String(hash, radix: 16)
    }

    static func directory(for video: URL) -> URL {
        root.appendingPathComponent(stableKey(video.standardizedFileURL.path), isDirectory: true)
    }

    static func sidecarURL(for video: URL) -> URL {
        directory(for: video).appendingPathComponent("sidecar.json")
    }

    /// 摄像头旁挂视频的落盘位置(写入前需确保父目录存在)
    static func cameraURL(for video: URL) -> URL {
        directory(for: video).appendingPathComponent("camera.mov")
    }

    static func save(_ sidecar: RecordSidecar, for video: URL) {
        guard let data = try? JSONEncoder().encode(sidecar) else { return }
        let dir = directory(for: video)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        try? data.write(to: sidecarURL(for: video), options: .atomic)
    }

    static func load(for video: URL) -> RecordSidecar? {
        guard let data = try? Data(contentsOf: sidecarURL(for: video)),
              let s = try? JSONDecoder().decode(RecordSidecar.self, from: data) else { return nil }
        return s
    }

    static func remove(for video: URL) {
        try? FileManager.default.removeItem(at: directory(for: video))
    }

    /// 清掉视频已经不在了的旁挂目录(用户直接删视频、或历史条目过期时)
    static func pruneOrphans() {
        let fm = FileManager.default
        for dir in (try? fm.contentsOfDirectory(at: root, includingPropertiesForKeys: nil)) ?? [] {
            let file = dir.appendingPathComponent("sidecar.json")
            guard let data = try? Data(contentsOf: file),
                  let s = try? JSONDecoder().decode(RecordSidecar.self, from: data),
                  !s.videoPath.isEmpty,
                  fm.fileExists(atPath: s.videoPath) else {
                // sidecar 读不出来或对应视频已消失:整个目录一起清掉
                try? fm.removeItem(at: dir)
                continue
            }
        }
    }
}

// MARK: - 窗口几何

/// 读某个窗口当前的 Cocoa 全局 frame。
/// 跟随窗口录制时用它在「点击发生的那一刻」取准窗口位置,而不是等下一次轮询。
enum CGWindowGeometry {
    static func cocoaFrame(of windowID: CGWindowID) -> CGRect? {
        guard let list = CGWindowListCopyWindowInfo([.optionIncludingWindow], windowID) as? [[String: Any]],
              let w = list.first,
              let bounds = w[kCGWindowBounds as String] as? [String: CGFloat],
              let r = CGRect(dictionaryRepresentation: bounds as CFDictionary),
              r.width >= 1, r.height >= 1 else { return nil }
        return Screen.cocoaRect(from: r)
    }
}

// MARK: - 点击采集

/// 录制期间的鼠标点击采集。
/// 用 NSEvent 全局监听而不是 CGEvent tap:鼠标事件的全局监听不需要「辅助功能」权限
/// (只有键盘事件才需要),少一个新 TCC 授权。
@MainActor
final class ClickRecorder {
    /// 已录制时长(不含暂停);暂停时返回负值表示「不要记录」
    var durationProvider: () -> TimeInterval = { -1 }
    /// 当前录制区(Cocoa 全局坐标);窗口跟随时每次点击实时取窗口 frame
    var areaProvider: () -> CGRect? = { nil }
    /// PopBar 自己的面板 / 红框:落在这些矩形里的点击不算画面内的点击
    var ownRectsProvider: () -> [CGRect] = { [] }

    private(set) var clicks: [ClickMark] = []
    private var monitor: Any?

    static let mask: NSEvent.EventTypeMask = [.leftMouseDown, .rightMouseDown, .otherMouseDown]

    var isRunning: Bool { monitor != nil }

    func start() {
        stop()
        clicks = []
        // 全局监听器回调在主线程投递,assumeIsolated 是安全的
        monitor = NSEvent.addGlobalMonitorForEvents(matching: Self.mask) { [weak self] event in
            MainActor.assumeIsolated { self?.record(event) }
        }
    }

    func stop() {
        if let monitor { NSEvent.removeMonitor(monitor) }
        monitor = nil
    }

    private func record(_ event: NSEvent) {
        let t = durationProvider()
        guard t >= 0 else { return }        // 暂停中 / 还没开录
        let p = NSEvent.mouseLocation
        guard let area = areaProvider() else { return }
        if ownRectsProvider().contains(where: { $0.contains(p) }) { return }
        guard let (x, y) = Self.normalize(p, in: area) else { return }
        let index: Int
        switch event.type {
        case .rightMouseDown: index = 1
        case .otherMouseDown: index = 2
        default: index = 0
        }
        clicks.append(ClickMark(t: t, x: x, y: y, button: index))
    }

    /// 全局点 → 录制区内归一化坐标(左上原点);落在区域外返回 nil
    static func normalize(_ p: CGPoint, in area: CGRect) -> (Double, Double)? {
        guard area.width > 0, area.height > 0 else { return nil }
        let x = (p.x - area.minX) / area.width
        let y = 1 - (p.y - area.minY) / area.height
        guard x >= 0, x <= 1, y >= 0, y <= 1 else { return nil }
        return (Double(x), Double(y))
    }
}
