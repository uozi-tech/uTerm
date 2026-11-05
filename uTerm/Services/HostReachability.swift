import Foundation
import Observation

/// 主机列表头像角标用的「服务器在线吗」：对 `host:port` 做一次裸 TCP 握手，握上即在线。
///
/// 两端（macOS 欢迎页列表 / iOS 主机页）共用。设计约束：
///
/// - **只探可见行**：行用 `.task { await monitor.watch(key) }` 登记，滚出屏幕 task 被取消即注销。
///   排队中的探测出队时若已没人看，直接跳过 —— 2000 台的列表快速滚过去不会排出 2000 次握手。
/// - **频率很低**：可见期间每 `refreshInterval`（5 分钟）重探一次；重新出现时结果比
///   `staleAfter`（2 分钟）旧才补探。sshd 会把「握手后立刻断开」记成一条 preauth 日志，
///   fail2ban 的 aggressive / ddos 模式会数这类日志（默认 10 分钟内 5 次封 IP）。
///   别把间隔调到分钟级以下。
/// - **不登录、不发 SSH 标识**：只证明端口开着，不碰认证，也就不会累计认证失败。
/// - **按端点去重**：多个主机指向同一 `host:port` 共用一个结果、一次探测。
/// - **走跳板机的主机不探**：内网地址从本机直连没有意义，角标保持「未知」。
/// - **每行只观察自己的那一格**：状态挂在每个端点自己的 `@Observable` 对象上，
///   一台主机状态变了只让那一行重求 body，不会让整屏可见行一起失效。
@MainActor
@Observable
final class HostReachabilityEntry {
    enum Status: Equatable, Sendable {
        /// 还没探过 / 走跳板机 / 探测被关闭。
        case unknown
        case online
        case offline
    }

    fileprivate(set) var status: Status = .unknown
    @ObservationIgnored fileprivate var lastProbe: Date?
    @ObservationIgnored fileprivate var watchers = 0
    @ObservationIgnored fileprivate var queued = false
}

nonisolated struct HostEndpointKey: Hashable, Sendable {
    let host: String
    let port: Int

    /// 走跳板机、或地址为空 → nil（不探）。
    @MainActor
    init?(_ profile: ServerProfile) {
        let host = profile.host.trimmingCharacters(in: .whitespacesAndNewlines)
        guard profile.jumpHost == nil, !host.isEmpty, (1...65535).contains(profile.port) else { return nil }
        self.host = host.lowercased()
        self.port = profile.port
    }

    init(host: String, port: Int) {
        self.host = host
        self.port = port
    }
}

@MainActor
final class HostReachabilityMonitor {
    typealias Probe = @Sendable (HostEndpointKey) async -> Bool

    /// 正式进程用的实例。XCTest 宿主里不发真实握手（列表探针 / 快照用例会挂几十上百行假主机）。
    static let shared = HostReachabilityMonitor(probe: TestHostEnvironment.isActive ? nil : tcpProbe)

    /// 裸 TCP 握手，4 秒内握上即在线。不发 SSH 标识、不登录。
    nonisolated static func tcpProbe(_ key: HostEndpointKey) async -> Bool {
        await ConnectProbe.tcpConnect(host: key.host, port: key.port, timeout: .seconds(4)) != nil
    }

    let refreshInterval: Duration
    let staleAfter: TimeInterval
    let maxConcurrent: Int

    private let probe: Probe?
    private let now: () -> Date
    private var entries: [HostEndpointKey: HostReachabilityEntry] = [:]
    private var pending: [HostEndpointKey] = []
    private var running = 0

    init(probe: Probe?,
         refreshInterval: Duration = .seconds(300),
         staleAfter: TimeInterval = 120,
         maxConcurrent: Int = 6,
         now: @escaping () -> Date = Date.init) {
        self.probe = probe
        self.refreshInterval = refreshInterval
        self.staleAfter = staleAfter
        self.maxConcurrent = maxConcurrent
        self.now = now
    }

    /// 取（必要时建）某端点的状态格。只读、不触发探测，可以在 body 里调。
    func entry(for key: HostEndpointKey) -> HostReachabilityEntry {
        if let entry = entries[key] { return entry }
        let entry = HostReachabilityEntry()
        entries[key] = entry
        return entry
    }

    /// 某主机当前的在线状态格；跳板机主机 / 空地址返回 nil。
    func entry(for profile: ServerProfile) -> HostReachabilityEntry? {
        HostEndpointKey(profile).map(entry(for:))
    }

    /// 行可见期间挂着：登记观察者、按需探测、每 `refreshInterval` 重探；task 取消即注销。
    func watch(_ key: HostEndpointKey) async {
        let entry = entry(for: key)
        entry.watchers += 1
        defer { entry.watchers -= 1 }
        enqueueIfStale(key, entry: entry, maxAge: staleAfter)
        while !Task.isCancelled {
            try? await Task.sleep(for: refreshInterval)
            if Task.isCancelled { break }
            // 周期重探：只要上一次不是刚刚（别的行同端点刚探过）就再探。
            enqueueIfStale(key, entry: entry, maxAge: refreshInterval / .seconds(1) * 0.5)
        }
    }

    private func enqueueIfStale(_ key: HostEndpointKey, entry: HostReachabilityEntry, maxAge: TimeInterval) {
        guard probe != nil, !entry.queued else { return }
        if let last = entry.lastProbe, now().timeIntervalSince(last) < maxAge { return }
        entry.queued = true
        pending.append(key)
        drain()
    }

    private func drain() {
        guard let probe else { return }
        while running < maxConcurrent, !pending.isEmpty {
            let key = pending.removeFirst()
            guard let entry = entries[key] else { continue }
            // 排队期间滚出屏幕了：不探，下次出现时按陈旧度重新入队。
            guard entry.watchers > 0 else {
                entry.queued = false
                continue
            }
            running += 1
            Task {
                let reachable = await probe(key)
                entry.status = reachable ? .online : .offline
                entry.lastProbe = now()
                entry.queued = false
                running -= 1
                drain()
            }
        }
    }
}
