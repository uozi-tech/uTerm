import CryptoKit
import Foundation
@preconcurrency import Network
import Observation
import UIKit

/// 「我的 Mac」：配对过的 Mac，以及每台 Mac 的远控客户端。
///
/// 列表只来自配对关系，不来自局域网：同一 Apple ID 名册里的 Mac（`RemoteCloudRoster`，自动配对）加上本机信任过的
/// Mac（扫码配对的、或老版本审批配上的）。Bonjour（`_uterm-remote._tcp`）只用来回答「这几台里哪台此刻在线、
/// 地址是什么」：按 TXT 记录里的设备 ID 对号，对不上的 Mac 不显示、也不连。设备 ID 与公钥在握手里再核对一遍
///（`RemoteMacClient.expectedPeer`）。
///
/// 浏览要「本地网络」授权，所以和局域网同步一样推迟：用户第一次点「连接我的 Mac」才开始
/// （之后每次进主机页自动开始），不会一启动就弹系统授权框。
@MainActor
@Observable
final class RemoteMacDirectory {
    nonisolated struct Mac: Identifiable, Hashable {
        enum Source: Hashable {
            /// 同一 Apple ID 的名册。
            case iCloud
            /// 本机信任过（扫码或老版本审批）。
            case paired
            /// 调试直连（`-RemoteDebugEndpoint`），事先不知道身份。
            case debug
        }

        /// 设备 ID 的字符串；调试直连是 `debug:<地址>`。
        let id: String
        let deviceID: UUID?
        var name: String
        var publicKey: Data?
        var source: Source
        /// 在线时的服务端点；nil = 此刻在局域网里找不到它。
        var endpoint: NWEndpoint?

        var isOnline: Bool { endpoint != nil }

        var expectedPeer: RemotePeer? {
            guard let deviceID, let publicKey else { return nil }
            return RemotePeer(id: deviceID, name: name, publicKey: publicKey, pairedAt: .distantPast)
        }
    }

    private static let activatedKey = DefaultsKey.remoteBrowseActivated

    /// 配对过的 Mac（在线的在前）。
    private(set) var macs: [Mac] = []
    private(set) var isBrowsing = false
    /// 存储属性而不是现读 UserDefaults：视图要能观察到它从 false 变成 true。
    private(set) var isActivated: Bool

    @ObservationIgnored let identity: RemoteIdentityStore
    /// 同一 Apple ID 的名册。测试里为 nil：不读写真实的 iCloud 钥匙串。
    @ObservationIgnored let roster: RemoteCloudRoster?
    @ObservationIgnored private let defaults: UserDefaults
    @ObservationIgnored private var browser: NWBrowser?
    /// Bonjour 此刻看到的、带设备 ID 的 Mac：设备 ID → (电脑名, 端点)。
    @ObservationIgnored private var online: [UUID: (name: String, endpoint: NWEndpoint)] = [:]
    @ObservationIgnored private var clients: [String: RemoteMacClient] = [:]
    /// 扫码拿到、还没用掉的令牌：设备 ID → 令牌。
    @ObservationIgnored private var pendingTokens: [UUID: Data] = [:]
    @ObservationIgnored private var networkWatcher: RemoteNetworkWatcher?
    @ObservationIgnored private var lifecycleObservers: [NSObjectProtocol] = []
    @ObservationIgnored private var backgroundTask = UIBackgroundTaskIdentifier.invalid

    init(identity: RemoteIdentityStore = RemoteIdentityStore(), roster: RemoteCloudRoster? = nil,
         defaults: UserDefaults = .standard) {
        self.identity = identity
        self.roster = roster
        self.defaults = defaults
        self.isActivated = defaults.bool(forKey: Self.activatedKey)
        if isActivated { publishSelf() }
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
        // 名册可能在后台经 iCloud 同步来了新的 Mac。
        refreshPaired()
        for client in clients.values { client.returnedToForeground() }
    }

    private func endBackgroundTask() {
        guard backgroundTask != .invalid else { return }
        UIApplication.shared.endBackgroundTask(backgroundTask)
        backgroundTask = .invalid
    }

    /// 用户主动点了「连接我的 Mac」：记住，之后自动浏览；同时把本机登进名册，同一 Apple ID 的 Mac 认得出这台手机。
    func activate() {
        defaults.set(true, forKey: Self.activatedKey)
        isActivated = true
        publishSelf()
        startBrowsing()
    }

    private func publishSelf() {
        guard let roster, let key = try? identity.localIdentity().publicKey.rawRepresentation else { return }
        roster.publish(RemoteRosterEntry(id: RemoteLocalDevice.id(),
                                         name: LANSyncCoordinator.localDeviceName(), publicKey: key,
                                         platform: .mobile, updatedAt: Date()))
    }

    func startBrowsing() {
        refreshPaired()
        guard browser == nil else { return }
        let browser = NWBrowser(for: .bonjourWithTXTRecord(type: RemoteConstants.serviceType, domain: nil), using: .tcp)
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
    }

    /// 调试：启动参数 `-RemoteDebugEndpoint 127.0.0.1:端口` 把一个地址当作 Mac 列出来，不走 Bonjour。
    /// 模拟器与 Mac 共用网络栈，回环地址又不受「本地网络」权限管，联调时用它直连 Mac 上的测试服务。
    private var debugMacs: [Mac] {
        #if DEBUG
        guard let raw = defaults.string(forKey: DefaultsKey.remoteDebugEndpoint), let colon = raw.lastIndex(of: ":"),
              let port = NWEndpoint.Port(String(raw[raw.index(after: colon)...])) else { return [] }
        let host = NWEndpoint.Host(String(raw[..<colon]))
        return [Mac(id: "debug:\(raw)", deviceID: nil, name: "调试 Mac（\(raw)）", publicKey: nil, source: .debug,
                    endpoint: .hostPort(host: host, port: port))]
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

    /// 只认 TXT 里带设备 ID 的结果；电脑名只拿来显示。没有设备 ID 的（老版本 Mac）不认。
    private func update(_ results: Set<NWBrowser.Result>) {
        online = Self.onlineMacs(results.compactMap { result in
            guard case .service(let name, _, _, _) = result.endpoint,
                  case .bonjour(let txt) = result.metadata else { return nil }
            return (name, txt[RemoteConstants.deviceIDKey], result.endpoint)
        })
        rebuild()
    }

    nonisolated static func onlineMacs(_ results: [(name: String, deviceID: String?, endpoint: NWEndpoint)])
        -> [UUID: (name: String, endpoint: NWEndpoint)] {
        var online: [UUID: (name: String, endpoint: NWEndpoint)] = [:]
        for result in results {
            guard let id = result.deviceID.flatMap(UUID.init(uuidString:)) else { continue }
            online[id] = (result.name, result.endpoint)
        }
        return online
    }

    /// 某台 Mac 的远控客户端（同一台 Mac 复用同一个，标签之间共用一条连接）。只对在线的 Mac 调。
    func client(for mac: Mac) -> RemoteMacClient {
        let endpoint = mac.endpoint ?? .hostPort(host: "0.0.0.0", port: 1)
        let client: RemoteMacClient
        if let existing = clients[mac.id] {
            existing.updateEndpoint(endpoint)
            client = existing
        } else {
            client = RemoteMacClient(macName: mac.name, endpoint: endpoint, identity: identity,
                                     expectedPeer: mac.expectedPeer)
            clients[mac.id] = client
        }
        if let deviceID = mac.deviceID, let token = pendingTokens.removeValue(forKey: deviceID) {
            client.pairingToken = token
        }
        if networkWatcher == nil {
            networkWatcher = RemoteNetworkWatcher { [weak self] isSatisfied in
                for client in self?.clients.values ?? [:].values { client.networkChanged(isSatisfied: isSatisfied) }
            }
        }
        return client
    }

    /// 扫到 Mac 出示的配对码：信任这台 Mac（解除之前的拉黑），下次连它时带上凭据，Mac 那边就直接认这台手机。
    /// 返回这台 Mac（可能此刻不在线）。
    @discardableResult
    func pair(with invitation: RemotePairingInvitation) throws -> Mac? {
        try identity.trust(RemotePeer(id: invitation.macID, name: invitation.macName, publicKey: invitation.macKey,
                                      pairedAt: Date()))
        pendingTokens[invitation.macID] = invitation.token
        // 之前按旧身份建过的客户端作废：要按扫到的公钥核对。
        clients[invitation.macID.uuidString] = nil
        if !isActivated { activate() }
        refreshPaired()
        return macs.first { $0.deviceID == invitation.macID }
    }

    /// 配对过、此刻在局域网里能找到的 Mac。新建终端抽屉只列它们。
    var pairedMacs: [Mac] { macs.filter(\.isOnline) }

    /// 重新读本机信任与名册（配对 / 忘记之后、回到前台时）。
    func refreshPaired() {
        rebuild()
    }

    private func rebuild() {
        macs = debugMacs + Self.knownMacs(trusted: identity.trustedPeers(), roster: roster?.entries() ?? [],
                                         blocked: identity.isBlocked, online: online)
    }

    /// 配对过的 Mac：本机信任的 ∪ 名册里的 Mac（本机拉黑的除外）。同一设备 ID 只算一台；名册里有它时公钥以名册
    /// 为准（Mac 重装后换了密钥，名册经同一 Apple ID 同步的是新的，本机记的旧公钥会把它永远挡在外面）。
    /// 名字在线时取 Bonjour 的电脑名（改过名也跟得上），否则取记下的。
    nonisolated static func knownMacs(trusted: [RemotePeer], roster: [RemoteRosterEntry], blocked: (UUID) -> Bool,
                                      online: [UUID: (name: String, endpoint: NWEndpoint)]) -> [Mac] {
        var byID: [UUID: Mac] = [:]
        for entry in roster where entry.platform == .mac && !blocked(entry.id) {
            byID[entry.id] = Mac(id: entry.id.uuidString, deviceID: entry.id, name: entry.name,
                                 publicKey: entry.publicKey, source: .iCloud)
        }
        for peer in trusted where byID[peer.id] == nil {
            byID[peer.id] = Mac(id: peer.id.uuidString, deviceID: peer.id, name: peer.name, publicKey: peer.publicKey,
                                source: .paired)
        }
        for (id, seen) in online where byID[id] != nil {
            byID[id]?.endpoint = seen.endpoint
            byID[id]?.name = seen.name
        }
        return byID.values.sorted {
            if $0.isOnline != $1.isOnline { return $0.isOnline }
            return $0.name.localizedStandardCompare($1.name) == .orderedAscending
        }
    }

    /// 忘记一台 Mac：本机不再信任并拉黑（名册里还有它也不再自动出现），直到重新扫码。
    func forget(_ mac: Mac) {
        if let deviceID = mac.deviceID { try? identity.revoke(id: deviceID) }
        clients.removeValue(forKey: mac.id)?.disconnect()
        refreshPaired()
    }
}
