import Foundation

/// 配置的唯一来源:启动时加载,监听 config.json 变化自动重载,变更后广播通知。
/// 外部编辑器保存(原地写或原子替换)、设置窗口保存都会触发刷新。
final class ConfigStore {
    static let shared = ConfigStore()
    static let didChange = Notification.Name("PopBarConfigDidChange")

    /// 测试代码可直接注入配置;生产路径经 save()/reload() 更新
    var config = PopBarConfig()
    /// 最近一次读取失败的原因(JSON 写坏了等);nil 表示正常
    private(set) var loadError: String?

    private var dirSource: DispatchSourceFileSystemObject?
    private var fileSource: DispatchSourceFileSystemObject?
    private var pendingReload: DispatchWorkItem?

    func start() {
        PopBarConfig.ensureExists()
        reload()
        watchDirectory()
        watchFile()
    }

    /// 重新读盘;内容没变时不广播。JSON 损坏时保留上一次的有效配置
    func reload() {
        let old = config
        let oldError = loadError
        if FileManager.default.fileExists(atPath: PopBarConfig.fileURL.path) {
            if let fresh = PopBarConfig.readFromDisk() {
                config = fresh
                loadError = nil
            } else {
                loadError = L10n.t("config.json 格式错误,已沿用上一次的有效配置",
                                   "config.json is malformed; kept the last valid config")
            }
        } else {
            config = PopBarConfig()
            loadError = nil
        }
        if config != old || loadError != oldError {
            NotificationCenter.default.post(name: ConfigStore.didChange, object: self)
        }
    }

    func save(_ newConfig: PopBarConfig) throws {
        try PopBarConfig.write(newConfig)
        let changed = newConfig != config || loadError != nil
        config = newConfig
        loadError = nil
        watchFile()     // 原子写入换了 inode,重新挂监听
        if changed {
            NotificationCenter.default.post(name: ConfigStore.didChange, object: self)
        }
    }

    // MARK: - 文件监听

    /// 目录级:捕获原子替换(先写临时文件再 rename)与文件新建/删除
    private func watchDirectory() {
        dirSource?.cancel()
        let dir = PopBarConfig.directoryURL
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let fd = open(dir.path, O_EVTONLY)
        guard fd >= 0 else { return }
        let source = DispatchSource.makeFileSystemObjectSource(
            fileDescriptor: fd, eventMask: [.write, .rename, .delete], queue: .main)
        source.setEventHandler { [weak self] in self?.scheduleReload() }
        source.setCancelHandler { close(fd) }
        source.resume()
        dirSource = source
    }

    /// 文件级:捕获原地写入(echo >>、部分编辑器)
    private func watchFile() {
        fileSource?.cancel()
        fileSource = nil
        let fd = open(PopBarConfig.fileURL.path, O_EVTONLY)
        guard fd >= 0 else { return }
        let source = DispatchSource.makeFileSystemObjectSource(
            fileDescriptor: fd, eventMask: [.write, .extend, .rename, .delete], queue: .main)
        source.setEventHandler { [weak self] in self?.scheduleReload() }
        source.setCancelHandler { close(fd) }
        source.resume()
        fileSource = source
    }

    /// 编辑器保存常是多次事件连发,合并成一次重载
    private func scheduleReload() {
        pendingReload?.cancel()
        let work = DispatchWorkItem { [weak self] in
            self?.reload()
            self?.watchFile()
        }
        pendingReload = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.25, execute: work)
    }
}
