import Foundation

/// `ControlConnectionPooling` 的生产实现：按 hostID 持有 `ReusableSSHConnection`（exec）
/// 与 `SFTPSession`（文件），懒建、空闲 10 分钟自动关、`disconnect` 显式释放。
///
/// 要点：
/// - 建连闭包用 `HostConnectionSpec` 里已解析好的 Sendable 值 + `SSHClientFactory.connect`，
///   `hostKeyVerifier` 由捕获的 `ModelContainer` 在闭包内构造（`HostKeyVerifier` 是 actor）。
/// - `hostKeyApprover` 走**非交互**路径：记录质询到 `HostKeyChallengeSink` 后**拒绝**，
///   再由本 actor 翻成 `ControlConnectError.hostKeyUnknown` / `.hostKeyChanged` 上抛，
///   并把质询缓存起来供 `trust` 核对。绝不自动 TOFU。
/// - 建连是**急切**的：`makeExec` 拿到复用连接后先跑一条 `:`（shell no-op）把握手做掉，
///   这样「主机密钥未信任 / 认证失败」在 `executor(for:)` 就暴露，而不是等到用户的命令
///   跑到一半才从 `BoundedExec` 里冒出来（那里拿不到质询，也没法把指纹回给 CLI）。
/// - 空闲回收靠 `lastUsedAt` + 一个按需起停的清扫任务，不常驻 Timer；`now` 与间隔都
///   可注入，测试里能把 10 分钟压成一瞬。
actor ControlConnectionPool: ControlConnectionPooling {

    /// 建连的三条外部依赖。生产用 `.live`，测试注入假的（池本身不认识 SSH）。
    nonisolated struct Connector: Sendable {
        /// 建一条**已经握过手**的 exec 通道；失败抛 `ControlConnectError`。
        var makeExec: @Sendable (HostConnectionSpec) async throws -> any ControlExecChannel
        /// 建一个 SFTP 会话；失败抛 `ControlConnectError`。
        var makeSFTP: @Sendable (HostConnectionSpec) async throws -> any SFTPProviding
        /// 按钉住的指纹重新握手并写信任库；指纹不符抛 `ControlConnectError.hostKeyChanged`。
        var trustHostKey: @Sendable (HostConnectionSpec, String) async throws -> Void

        init(
            makeExec: @escaping @Sendable (HostConnectionSpec) async throws -> any ControlExecChannel,
            makeSFTP: @escaping @Sendable (HostConnectionSpec) async throws -> any SFTPProviding,
            trustHostKey: @escaping @Sendable (HostConnectionSpec, String) async throws -> Void
        ) {
            self.makeExec = makeExec
            self.makeSFTP = makeSFTP
            self.trustHostKey = trustHostKey
        }
    }

    /// app 级单例。`uTermApp` 注入给 `ControlHandler`。
    static let shared = ControlConnectionPool()

    /// 空闲多久后自动关闭一台主机的持有。
    static let idleTimeout: Duration = .seconds(600)

    private nonisolated struct Entry: Sendable {
        var exec: (any ControlExecChannel)?
        var sftp: (any SFTPProviding)?
        var lastUsedAt: Date

        var isEmpty: Bool { exec == nil && sftp == nil }
    }

    private let connector: Connector
    private let idleInterval: Duration
    private let now: @Sendable () -> Date
    /// 供 `heldHostIDsNow()` 读的同步镜像（`resolveHost` 那条路径不能 await）。
    private nonisolated let mirror = HeldHostIDsMirror()

    private var entries: [UUID: Entry] = [:]
    /// 最近一次建连被拒的主机密钥质询，按 hostID。`trust` 只认这里的指纹。
    private var challenges: [UUID: HostKeyChallenge] = [:]
    private var sweeper: Task<Void, Never>?

    init(
        connector: Connector = .live,
        idleInterval: Duration = ControlConnectionPool.idleTimeout,
        now: @escaping @Sendable () -> Date = { Date() }
    ) {
        self.connector = connector
        self.idleInterval = idleInterval
        self.now = now
    }

    // MARK: - 取用

    func executor(
        for host: HostConnectionSpec,
        maxLines: Int,
        maxBytes: Int
    ) async throws -> SSHCommandExecutor {
        let channel = try await execChannel(for: host)
        let hostID = host.id
        return SSHCommandExecutor(maxLines: maxLines, maxBytes: maxBytes) { [weak self] command in
            // 跑命令期间**不**占着本 actor：touch 立刻返回，exec 在通道自己的隔离域里跑。
            await self?.touch(hostID)
            return try await channel.exec(command)
        }
    }

    func sftp(for host: HostConnectionSpec) async throws -> any SFTPProviding {
        sweepIdle()
        if let existing = entries[host.id]?.sftp {
            touch(host.id)
            return existing
        }
        let session = try await connect(for: host) { try await self.connector.makeSFTP(host) }
        var entry = entries[host.id] ?? Entry(exec: nil, sftp: nil, lastUsedAt: now())
        entry.sftp = session
        entry.lastUsedAt = now()
        entries[host.id] = entry
        syncMirror()
        scheduleSweep()
        return session
    }

    private func execChannel(for host: HostConnectionSpec) async throws -> any ControlExecChannel {
        sweepIdle()
        if let existing = entries[host.id]?.exec {
            touch(host.id)
            return existing
        }
        let channel = try await connect(for: host) { try await self.connector.makeExec(host) }
        var entry = entries[host.id] ?? Entry(exec: nil, sftp: nil, lastUsedAt: now())
        entry.exec = channel
        entry.lastUsedAt = now()
        entries[host.id] = entry
        syncMirror()
        scheduleSweep()
        return channel
    }

    /// 建连 + 质询缓存。任何 `ControlConnectError` 的主机密钥两态都会在这里落进
    /// `challenges`，`trust` 再从这里取出来核对指纹。
    private func connect<T>(
        for host: HostConnectionSpec,
        _ body: () async throws -> T
    ) async throws -> T {
        do {
            return try await body()
        } catch let error as ControlConnectError {
            recordChallenge(error, for: host)
            throw error
        }
    }

    private func recordChallenge(_ error: ControlConnectError, for host: HostConnectionSpec) {
        let kind: HostKeyChallenge.Kind
        switch error {
        case .hostKeyUnknown: kind = .unknown
        case .hostKeyChanged: kind = .mismatch
        default: return
        }
        challenges[host.id] = HostKeyChallenge(
            host: host.profile.host,
            port: host.profile.port,
            kind: kind,
            newFingerprint: error.fingerprint ?? "",
            oldFingerprint: nil
        )
    }

    // MARK: - 主机密钥

    func lastHostKeyChallenge(hostID: UUID) async -> HostKeyChallenge? {
        challenges[hostID]
    }

    /// 池外路径（`forward-start` 的专用转发连接）拿到的挑战也记进同一张表，
    /// 好让 `trust --fingerprint` 配得上对。与池内 `recordChallenge(_:for:)` 同一份存储。
    func recordChallenge(hostID: UUID, _ challenge: HostKeyChallenge) async {
        challenges[hostID] = challenge
    }

    func trustHostKey(host: HostConnectionSpec, fingerprint: String) async throws {
        try await connector.trustHostKey(host, fingerprint)
        // 信任成功：质询作废，否则下一次 `trust` 会拿着陈旧指纹重复批准。
        challenges[host.id] = nil
    }

    // MARK: - 释放

    func disconnect(hostID: UUID) async {
        guard let entry = entries.removeValue(forKey: hostID) else { return }
        syncMirror()
        await close(entry)
    }

    func disconnectAll() async {
        let all = entries
        entries.removeAll()
        challenges.removeAll()
        syncMirror()
        sweeper?.cancel()
        sweeper = nil
        for entry in all.values {
            await close(entry)
        }
    }

    func heldHostIDs() async -> [UUID] {
        Array(entries.keys)
    }

    nonisolated func heldHostIDsNow() -> [UUID] {
        mirror.value
    }

    // MARK: - 空闲回收

    /// 清掉空闲超过 `idleInterval` 的持有，返回剩下几台。**同步**执行关闭
    /// （`close()` 派到独立 Task），这样它可以被建连路径顺手调用而不引入 await 重入。
    @discardableResult
    func sweepIdle() -> Int {
        let deadline = now().addingTimeInterval(-idleInterval.seconds)
        var expired: [Entry] = []
        for (id, entry) in entries where entry.lastUsedAt <= deadline {
            expired.append(entry)
            entries.removeValue(forKey: id)
        }
        guard !expired.isEmpty else { return entries.count }
        syncMirror()
        let closing = expired
        Task.detached {
            for entry in closing {
                await entry.exec?.close()
                await entry.sftp?.close()
            }
        }
        return entries.count
    }

    private func touch(_ hostID: UUID) {
        entries[hostID]?.lastUsedAt = now()
    }

    private func close(_ entry: Entry) async {
        await entry.exec?.close()
        await entry.sftp?.close()
    }

    private func syncMirror() {
        mirror.value = Array(entries.keys)
    }

    /// 起一个按需的清扫任务（不常驻）：每隔 `idleInterval` 扫一次，池空了就自己收摊。
    private func scheduleSweep() {
        guard sweeper == nil else { return }
        let interval = idleInterval
        sweeper = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: interval)
                if Task.isCancelled { return }
                guard let self else { return }
                let remaining = await self.sweepIdle()
                if remaining == 0 {
                    await self.clearSweeper()
                    return
                }
            }
        }
    }

    private func clearSweeper() {
        sweeper = nil
    }
}

// MARK: - 生产建连

extension ControlConnectionPool.Connector {

    /// 真实 SSH：`SSHClientFactory.connect` + 非交互的 host-key 审批。
    nonisolated static let live = ControlConnectionPool.Connector(
        makeExec: { spec in
            let sink = HostKeyChallengeSink()
            let reusable = ReusableSSHConnection(
                connect: ControlConnectionPool.liveConnect(spec, sink: sink),
                hostKeyChallenges: sink
            )
            do {
                // 急切握手：`:` 是 shell 的 no-op，只为把建连（含主机密钥审批）做掉，
                // 好让失败在这里就带着指纹上抛。连接随后被复用，不会白建。
                _ = try await reusable.exec(":")
            } catch {
                await reusable.close()
                throw ControlConnectionPool.mapConnectError(error, sink: sink)
            }
            return reusable
        },
        makeSFTP: { spec in
            let sink = HostKeyChallengeSink()
            do {
                let connected = try await ControlConnectionPool.liveConnect(spec, sink: sink)()
                return try await SFTPSession(connected: connected)
            } catch {
                throw ControlConnectionPool.mapConnectError(error, sink: sink)
            }
        },
        trustHostKey: { spec, fingerprint in
            let sink = HostKeyChallengeSink()
            do {
                let connected = try await ControlConnectionPool.liveConnect(
                    spec,
                    sink: sink,
                    pinnedFingerprint: fingerprint
                )()
                // 握手成功即说明服务器出示的指纹与钉住的一致，`HostKeyVerifier` 已经
                // 沿 TOFU 路径写好 `KnownHost`。这条连接只为信任而建，随手关掉。
                await connected.close()
            } catch {
                throw ControlConnectionPool.mapConnectError(error, sink: sink)
            }
        }
    )
}

extension ControlConnectionPool {

    /// 建连闭包：只捕获 `Sendable` 值（`ProfileSnapshot` / `ResolvedAuth` /
    /// `ModelContainer` / sink），`HostKeyVerifier` 在闭包内由 container 构造。
    ///
    /// `pinnedFingerprint == nil`（默认）是**非交互**路径：记录质询并拒绝。
    /// 非 nil 是 `trust` 路径：只批准与钉住指纹逐字相同的**未知**密钥；密钥**变更**
    /// 一律拒绝，CLI 永远不能覆盖已信任的主机密钥。
    nonisolated static func liveConnect(
        _ spec: HostConnectionSpec,
        sink: HostKeyChallengeSink,
        pinnedFingerprint: String? = nil
    ) -> @Sendable () async throws -> ConnectedClient {
        let snapshot = spec.profile
        let auth = spec.auth
        let jumpAuth = spec.jumpAuth
        let container = spec.container
        return {
            try await SSHClientFactory.connect(
                profile: snapshot,
                auth: auth,
                jumpHostAuth: jumpAuth,
                hostKeyVerifier: HostKeyVerifier(modelContainer: container),
                hostKeyApprover: { challenge in
                    // `HostKeyChallenge.Kind` 的 Equatable 合规是 MainActor 隔离的
                    //（模块默认隔离），这里在 NIO 线程上，只能用模式匹配比。
                    guard let pinnedFingerprint else {
                        sink.record(challenge)
                        return false
                    }
                    guard case .unknown = challenge.kind,
                          challenge.newFingerprint == pinnedFingerprint
                    else {
                        sink.record(challenge)
                        return false
                    }
                    return true
                }
            )
        }
    }

    /// 把建连抛出的错误归类。质询在 sink 里就以主机密钥两态为准，否则按文案分
    /// 认证失败 / 连接失败。
    nonisolated static func mapConnectError(
        _ error: any Error,
        sink: HostKeyChallengeSink
    ) -> ControlConnectError {
        if let challenge = sink.take() {
            switch challenge.kind {
            case .unknown:
                return .hostKeyUnknown(fingerprint: challenge.newFingerprint, algorithm: "")
            case .mismatch:
                return .hostKeyChanged(fingerprint: challenge.newFingerprint, algorithm: "")
            }
        }
        if let already = error as? ControlConnectError { return already }
        let text = FriendlyError.describe(error)
        if text.contains("认证失败") || text.localizedCaseInsensitiveContains("authentication") {
            return .authFailed(text)
        }
        return .connectFailed(text)
    }
}

/// `heldHostIDsNow()` 的同步镜像。actor 外只读、actor 内每次增删同步一次。
private nonisolated final class HeldHostIDsMirror: @unchecked Sendable {
    private let lock = NSLock()
    private var stored: [UUID] = []

    var value: [UUID] {
        get {
            lock.lock(); defer { lock.unlock() }
            return stored
        }
        set {
            lock.lock(); defer { lock.unlock() }
            stored = newValue
        }
    }
}

private extension Duration {
    /// 秒（含小数部分），用来和 `Date` 比。
    nonisolated var seconds: TimeInterval {
        let parts = components
        return TimeInterval(parts.seconds) + TimeInterval(parts.attoseconds) / 1e18
    }
}
