import Combine
import Foundation
import PopBarCore

/// VPS 列表完全由 ~/.ssh/config 派生；这里只持久化停用状态。
/// 仅支持手动刷新：进入页面时只加载主机列表，不自动发起 SSH 检查；链接测试全部按需触发。
@MainActor
final class VPSMonitorModel: ObservableObject {
    @Published private(set) var hosts: [VPSHost] = []
    @Published private(set) var results: [String: VPSHostResult] = [:]
    @Published private(set) var refreshing = false
    @Published private(set) var refreshingHostIDs: Set<String> = []
    @Published private(set) var testingConnectivity: Set<String> = []
    @Published private(set) var testingSpeed: Set<String> = []
    @Published private(set) var lastRefresh: Date?

    private var observer: NSObjectProtocol?
    private var generation = 0
    private var started = false

    init() {
        observer = NotificationCenter.default.addObserver(forName: ConfigStore.didChange, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.reloadHostsFromSSHConfig() }
        }
        reloadHostsFromSSHConfig()
        restorePersistedSnapshots()
    }

    deinit {
        if let observer { NotificationCenter.default.removeObserver(observer) }
    }

    var enabledHosts: [VPSHost] { hosts.filter(\.enabled) }
    var disabledHosts: [VPSHost] { hosts.filter { !$0.enabled } }
    private var enabledResults: [VPSHostResult] {
        let ids = Set(enabledHosts.map(\.id))
        return results.values.filter { ids.contains($0.id) }
    }
    var hasAnyResult: Bool { !enabledResults.isEmpty }
    var onlineCount: Int { enabledResults.filter(\.online).count }
    var offlineCount: Int { enabledResults.filter { !$0.online }.count }
    var securityWarningCount: Int {
        enabledResults.reduce(0) { $0 + ($1.remote?.securityWarnings.count ?? 0) }
    }
    var vlessTestedCount: Int {
        enabledResults.reduce(0) { total, result in
            total + result.vlessChecks.filter { $0.check.state != .skipped || $0.speed != nil }.count
        }
    }
    var vlessOKCount: Int {
        enabledResults.reduce(0) { total, result in
            total + result.vlessChecks.filter { $0.check.state == .ok }.count
        }
    }
    var attentionCount: Int { enabledResults.filter(\.attention).count }
    var vlessLinkCount: Int {
        enabledResults.reduce(0) { $0 + $1.vlessChecks.count }
    }
    var isBusy: Bool {
        refreshing || !refreshingHostIDs.isEmpty || !testingConnectivity.isEmpty || !testingSpeed.isEmpty
    }

    func isRefreshing(_ host: VPSHost) -> Bool { refreshing || refreshingHostIDs.contains(host.id) }
    func result(for host: VPSHost) -> VPSHostResult? { results[host.id] }
    func isTestingConnectivity(host: VPSHost, link: VPSLinkCheck) -> Bool {
        testingConnectivity.contains(linkKey(host, link))
    }
    func isTestingSpeed(host: VPSHost, link: VPSLinkCheck) -> Bool {
        testingSpeed.contains(linkKey(host, link))
    }
    func isTestingAnyLink(for host: VPSHost) -> Bool {
        let prefix = "\(host.id)|"
        return testingConnectivity.contains { $0.hasPrefix(prefix) }
            || testingSpeed.contains { $0.hasPrefix(prefix) }
    }

    /// 进入页面调用：仅重新读取 ~/.ssh/config 中的主机列表，不自动发起 SSH 刷新。
    func start() {
        guard !started else { return }
        started = true
        reloadHostsFromSSHConfig()
    }

    func stop() {
        started = false
        generation &+= 1
        refreshing = false
        refreshingHostIDs.removeAll()
        testingConnectivity.removeAll()
        testingSpeed.removeAll()
    }

    /// 手动刷新全部启用的主机；同时重新读取 ~/.ssh/config。
    func refresh() {
        guard started, !isBusy else { return }
        reloadHostsFromSSHConfig()
        guard !enabledHosts.isEmpty else { return }
        let gen = generation
        Task { @MainActor [weak self] in
            await self?.refreshAllNow(gen: gen)
        }
    }

    /// 手动刷新单台主机（不阻塞其它主机独立刷新或测速）。
    func refresh(_ host: VPSHost) {
        guard started, !refreshing, !refreshingHostIDs.contains(host.id), !isTestingAnyLink(for: host), host.enabled else { return }
        refreshingHostIDs.insert(host.id)
        let gen = generation
        Task { @MainActor [weak self] in
            guard let self, self.started, gen == self.generation else { return }
            let result = await VPSProbe.probe(host)
            guard gen == self.generation else { return }
            self.results[host.id] = result
            self.lastRefresh = Date()
            self.refreshingHostIDs.remove(host.id)
            self.persistSnapshots()
        }
    }

    /// 监控卡片上的开关：只持久化停用别名，不改 SSH 配置（重新启用后保持未检查状态，待手动刷新）。
    func setEnabled(_ host: VPSHost, _ on: Bool) {
        guard host.enabled != on else { return }
        var c = ConfigStore.shared.config
        var disabled = Set(c.vps.disabledAliases.map { $0.lowercased() })
        if on {
            disabled.remove(host.alias.lowercased())
        } else {
            disabled.insert(host.alias.lowercased())
        }
        c.vps.disabledAliases = disabled.sorted()
        try? ConfigStore.shared.save(c)
        if let index = hosts.firstIndex(where: { $0.id == host.id }) {
            hosts[index].enabled = on
        }
    }

    func testConnectivity(host: VPSHost, link: VPSLinkCheck) {
        guard started, !refreshing, !refreshingHostIDs.contains(host.id) else { return }
        let key = linkKey(host, link)
        guard !testingConnectivity.contains(key), !testingSpeed.contains(key) else { return }
        guard let endpoint = VLESSEndpoint.parse(link.url) else {
            updateLink(hostID: host.id, linkID: link.id) {
                $0.check = VLESSCheck(state: .failed, latencyMs: nil,
                                      message: L10n.t("VLESS 链接格式不支持", "Unsupported VLESS link"),
                                      endpoint: $0.endpoint)
            }
            return
        }
        testingConnectivity.insert(key)
        Task { @MainActor [weak self] in
            guard let self else { return }
            let check = await VPSXrayTester.run(endpoint)
            self.testingConnectivity.remove(key)
            guard self.started else { return }
            self.updateLink(hostID: host.id, linkID: link.id) { $0.check = check }
        }
    }

    func testSpeed(host: VPSHost, link: VPSLinkCheck) {
        guard started, !refreshing, !refreshingHostIDs.contains(host.id) else { return }
        let key = linkKey(host, link)
        guard !testingConnectivity.contains(key), !testingSpeed.contains(key) else { return }
        guard let endpoint = VLESSEndpoint.parse(link.url) else {
            updateLink(hostID: host.id, linkID: link.id) {
                $0.speed = VLESpeedCheck(state: .failed, megabytesPerSecond: nil, latencyMs: nil,
                                         message: L10n.t("VLESS 链接格式不支持", "Unsupported VLESS link"))
            }
            return
        }
        testingSpeed.insert(key)
        Task { @MainActor [weak self] in
            guard let self else { return }
            let speed = await VPSXrayTester.speedTest(endpoint)
            self.testingSpeed.remove(key)
            guard self.started else { return }
            self.updateLink(hostID: host.id, linkID: link.id) { link in
                link.speed = speed
                if speed.state == .ok, link.check.state == .skipped {
                    link.check = VLESSCheck(state: .ok, latencyMs: speed.latencyMs,
                                            message: "", endpoint: link.endpoint)
                }
            }
        }
    }

    private func reloadHostsFromSSHConfig() {
        let disabled = Set(ConfigStore.shared.config.vps.disabledAliases.map { $0.lowercased() })
        hosts = VPSHostDiscovery.fromSSHConfig().map { host in
            var copy = host
            copy.enabled = !disabled.contains(host.alias.lowercased())
            return copy
        }
        let ids = Set(hosts.map(\.id))
        if results.keys.contains(where: { !ids.contains($0) }) {
            results = results.filter { ids.contains($0.key) }
            persistSnapshots()
        }
    }

    private func restorePersistedSnapshots() {
        guard let cache = VPSSnapshotStore.load() else { return }
        let ids = Set(hosts.map(\.id))
        let valid = cache.results.filter { ids.contains($0.key) }
        guard !valid.isEmpty else { return }
        results = valid
        lastRefresh = cache.lastRefresh ?? valid.values.map(\.checkedAt).max()
    }

    private func persistSnapshots() {
        VPSSnapshotStore.save(VPSSnapshotCache(lastRefresh: lastRefresh, results: results))
    }

    private func refreshAllNow(gen: Int) async {
        guard started, gen == generation, !refreshing, refreshingHostIDs.isEmpty else { return }
        refreshing = true
        let snapshot = enabledHosts
        let collected = await withTaskGroup(of: VPSHostResult.self, returning: [VPSHostResult].self) { group in
            for host in snapshot {
                group.addTask { await VPSProbe.probe(host) }
            }
            var out: [VPSHostResult] = []
            for await result in group { out.append(result) }
            return out
        }
        guard gen == generation else { return }
        var merged = results
        for result in collected { merged[result.id] = result }
        results = merged
        let now = Date()
        lastRefresh = now
        persistLastRefresh(now)
        persistSnapshots()
        refreshing = false
    }

    private func persistLastRefresh(_ date: Date) {
        var c = ConfigStore.shared.config
        c.vps.lastRefreshAt = date.timeIntervalSince1970
        try? ConfigStore.shared.save(c)
    }

    private func linkKey(_ host: VPSHost, _ link: VPSLinkCheck) -> String {
        "\(host.id)|\(link.id)"
    }

    private func updateLink(hostID: String, linkID: String, _ body: (inout VPSLinkCheck) -> Void) {
        guard var result = results[hostID],
              let index = result.vlessChecks.firstIndex(where: { $0.id == linkID }) else { return }
        body(&result.vlessChecks[index])
        results[hostID] = result
        persistSnapshots()
    }
}
