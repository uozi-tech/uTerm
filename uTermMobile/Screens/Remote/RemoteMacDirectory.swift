import Foundation
@preconcurrency import Network
import Observation
import UIKit

/// 局域网里开着远控的 Mac（Bonjour `_uterm-remote._tcp`），以及每台 Mac 的远控客户端。
///
/// 浏览要「本地网络」授权，所以和局域网同步一样推迟：用户第一次点「连接我的 Mac」才开始
/// （之后每次进主机页自动开始），不会一启动就弹系统授权框。
@MainActor
@Observable
final class RemoteMacDirectory {
    struct Mac: Identifiable, Hashable {
        /// Bonjour 服务名（= Mac 的电脑名）。同一网络里唯一。
        let id: String
        let endpoint: NWEndpoint
        var name: String { id }
    }

    private static let activatedKey = "remote.browseActivated"

    private(set) var macs: [Mac] = []
    private(set) var isBrowsing = false
    /// 存储属性而不是现读 UserDefaults：视图要能观察到它从 false 变成 true。
    private(set) var isActivated: Bool

    @ObservationIgnored let identity: RemoteIdentityStore
    @ObservationIgnored private let defaults: UserDefaults
    @ObservationIgnored private var browser: NWBrowser?
    @ObservationIgnored private var clients: [String: RemoteMacClient] = [:]
    @ObservationIgnored private var networkWatcher: RemoteNetworkWatcher?
    @ObservationIgnored private var lifecycleObservers: [NSObjectProtocol] = []
    @ObservationIgnored private var backgroundTask = UIBackgroundTaskIdentifier.invalid

    init(identity: RemoteIdentityStore = RemoteIdentityStore(), defaults: UserDefaults = .standard) {
        self.identity = identity
        self.defaults = defaults
        self.isActivated = defaults.bool(forKey: Self.activatedKey)
        refreshPaired()
        observeLifecycle()
    }

    /// 切到别的 App 回个消息：申请一段后台时间，短暂离开连接不断，回来也不用重发快照。
    /// 到期后 iOS 挂起 App，连接随之断开，回前台再重连。
    private func observeLifecycle() {
        let center = NotificationCenter.default
        lifecycleObservers = [
            center.addObserver(forName: UIApplication.didEnterBackgroundNotification, object: nil, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated { self?.didEnterBackground() }
            },
            center.addObserver(forName: UIApplication.willEnterForegroundNotification, object: nil, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated { self?.willEnterForeground() }
            },
        ]
    }

    private func didEnterBackground() {
        guard backgroundTask == .invalid, clients.values.contains(where: { $0.state == .connected }) else { return }
        backgroundTask = UIApplication.shared.beginBackgroundTask(withName: "Remote terminals") { [weak self] in
            MainActor.assumeIsolated { self?.endBackgroundTask() }
        }
    }

    private func willEnterForeground() {
        endBackgroundTask()
        for client in clients.values { client.returnedToForeground() }
    }

    private func endBackgroundTask() {
        guard backgroundTask != .invalid else { return }
        UIApplication.shared.endBackgroundTask(backgroundTask)
        backgroundTask = .invalid
    }

    /// 用户主动点了「连接我的 Mac」：记住，之后自动浏览。
    func activate() {
        defaults.set(true, forKey: Self.activatedKey)
        isActivated = true
        startBrowsing()
    }

    func startBrowsing() {
        guard browser == nil else { return }
        let browser = NWBrowser(for: .bonjour(type: RemoteConstants.serviceType, domain: nil), using: .tcp)
        browser.browseResultsChangedHandler = { [weak self] results, _ in
            DispatchQueue.main.async { MainActor.assumeIsolated { self?.update(results) } }
        }
        browser.stateUpdateHandler = { [weak self] state in
            DispatchQueue.main.async {
                MainActor.assumeIsolated {
                    if case .failed = state { self?.restartBrowsing() }
                }
            }
        }
        browser.start(queue: DispatchQueue(label: "com.uozi.uTerm.remote.browser"))
        self.browser = browser
        isBrowsing = true
        macs = debugMacs
    }

    /// 调试：启动参数 `-RemoteDebugEndpoint 127.0.0.1:端口` 把一个地址当作 Mac 列出来，不走 Bonjour。
    /// 模拟器与 Mac 共用网络栈，回环地址又不受「本地网络」权限管，联调时用它直连 Mac 上的测试服务。
    private var debugMacs: [Mac] {
        #if DEBUG
        guard let raw = defaults.string(forKey: "RemoteDebugEndpoint"), let colon = raw.lastIndex(of: ":"),
              let port = NWEndpoint.Port(String(raw[raw.index(after: colon)...])) else { return [] }
        let host = NWEndpoint.Host(String(raw[..<colon]))
        return [Mac(id: "调试 Mac（\(raw)）", endpoint: .hostPort(host: host, port: port))]
        #else
        return []
        #endif
    }

    private func restartBrowsing() {
        browser?.cancel()
        browser = nil
        isBrowsing = false
        startBrowsing()
    }

    private func update(_ results: Set<NWBrowser.Result>) {
        macs = debugMacs + results.compactMap { result -> Mac? in
            guard case .service(let name, _, _, _) = result.endpoint else { return nil }
            return Mac(id: name, endpoint: result.endpoint)
        }
        .sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
    }

    /// 某台 Mac 的远控客户端（同一台 Mac 复用同一个，标签之间共用一条连接）。
    func client(for mac: Mac) -> RemoteMacClient {
        if let existing = clients[mac.id] {
            existing.updateEndpoint(mac.endpoint)
            return existing
        }
        let client = RemoteMacClient(macName: mac.name, endpoint: mac.endpoint, identity: identity)
        clients[mac.id] = client
        if networkWatcher == nil {
            networkWatcher = RemoteNetworkWatcher { [weak self] isSatisfied in
                for client in self?.clients.values ?? [:].values { client.networkChanged(isSatisfied: isSatisfied) }
            }
        }
        return client
    }

    /// 配对过的 Mac 的名字。只用于列表上的「已配对」标记（按名字粗判）；真正的身份校验在握手里
    /// 按 Mac 的设备 ID 与长期公钥做。存成属性是为了让列表能观察到配对前后的变化。
    private(set) var pairedNames: Set<String> = []

    func isPaired(_ mac: Mac) -> Bool {
        pairedNames.contains(mac.name)
    }

    /// 配对过、此刻在局域网里能找到的 Mac。新建终端抽屉只列它们：没配对的要先走配对流程（主机页「我的 Mac」）。
    var pairedMacs: [Mac] { macs.filter(isPaired) }

    /// 配对 / 忘记之后刷新列表上的标记（Mac 面板关闭时调用）。
    func refreshPaired() {
        pairedNames = Set(identity.trustedPeers().map(\.name))
    }
}
