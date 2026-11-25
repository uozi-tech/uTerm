import CryptoKit
import Foundation

/// 共享连接池里的一条连接需要的能力。生产实现是 `ConnectedClient`；单测注入假的。
nonisolated protocol PooledConnection: Sendable {
    /// 传输是否还活着。已断开的连接不会再借出去。
    var isAlive: Bool { get }
    /// 挂传输断开回调。池子每条连接只挂一次，再自己分发给各租约（归还租约时连同回调一起撤掉）。
    func onTransportClosed(_ handler: @escaping @Sendable () -> Void)
    /// 真正断开底层传输。
    func closeTransport() async
}

/// 一份租约：凭它归还连接、订阅断开。
nonisolated struct PooledLease: Sendable, Hashable {
    let connectionID: UUID
    let leaseID: UUID
}

/// 这次借到的连接是怎么来的（计时日志用）。
nonisolated enum PooledConnectionOrigin: String, Sendable {
    /// 这次新建的。
    case created
    /// 别人正在建，等它建好一起用。
    case joined
    /// 已有的活连接。
    case reused
}

/// 按 key 共享连接、引用计数回收，相当于 OpenSSH 的 ControlMaster。
///
/// 为什么要共享：服务器为每条新连接做的初始化（起 sshd 会话进程、跑 PAM 的 logind / motd）
/// 在小规格实例上要 0.1～3 秒、并发时还会排队；在已有连接上开通道不再触发它，同一台
/// 1 核 1G 的机器上实测 64～160ms。
///
/// 规则：
/// - 同一 key 同时到来的建连只建一次：后来者等同一个 in-flight `Task`。
/// - 每条连接最多 `maxLeasesPerConnection` 份租约，满了另开一条。
/// - 最后一份租约归还时才真正断开。
/// - 传输断开（对端 FIN/RST，或某个使用方判死后 `closeTransport`）→ 先把这条连接摘出
///   表，之后的 `acquire` 会新建；再通知它上面的全部租约。
actor SharedConnectionPool<Key: Hashable & Sendable, Connection: PooledConnection> {
    private struct Entry {
        let key: Key
        let connection: Connection
        var leases: Set<UUID> = []
        var closeHandlers: [UUID: @Sendable () -> Void] = [:]
        let flight: Flight?
    }

    /// 一次建连。等它的人（发起的与后来加入的）都拿着同一个对象：连接**只登记一次**，被摘出表之后谁也不能再把它
    /// 登记回去——摘掉的连接可能正在关（经跳板机时关要等几秒，这期间 `isAlive` 还是真），再借出去就是一条马上断的连接。
    private nonisolated final class Flight: @unchecked Sendable {
        enum State { case connecting, registered, retired }
        let id = UUID()
        let task: Task<Connection, Error>
        var state = State.connecting   // 只在池子的 actor 上读写

        init(task: Task<Connection, Error>) { self.task = task }
    }

    let maxLeasesPerConnection: Int
    private var entries: [UUID: Entry] = [:]
    private var pending: [Key: Flight] = [:]

    init(maxLeasesPerConnection: Int) {
        self.maxLeasesPerConnection = max(1, maxLeasesPerConnection)
    }

    /// 借一条 `key` 对应的连接；没有可用的就用 `connect` 新建。
    ///
    /// 新建失败时，等这次建连的所有调用方都拿到同一个错误。
    func acquire(
        _ key: Key,
        connect: @escaping @Sendable @concurrent () async throws -> Connection
    ) async throws -> (connection: Connection, lease: PooledLease, origin: PooledConnectionOrigin) {
        try await acquire(key, sharesHandshake: true, connect: connect, beforeClaim: nil)
    }

    /// - `sharesHandshake`：false 时不加入、也不让别人加入这一次的握手（已经建好的连接照样复用）。非交互的建连
    ///   （主机密钥一律拒绝，比如后台清理、终端区的预览）用它：否则同时打开的新标签页加入它的握手，主机密钥的问题被
    ///   「一律拒绝」替它答了，用户连确认框都看不到。
    /// - `beforeClaim`：只给测试用，在等到建连结果之后、认领之前插一段（造「别人先借完又还了」的时序）。
    func acquire(
        _ key: Key,
        sharesHandshake: Bool,
        connect: @escaping @Sendable @concurrent () async throws -> Connection,
        beforeClaim: (@Sendable () async -> Void)? = nil
    ) async throws -> (connection: Connection, lease: PooledLease, origin: PooledConnectionOrigin) {
        if let id = reusableConnectionID(for: key) {
            return (entries[id]!.connection, lease(on: id), .reused)
        }

        let origin: PooledConnectionOrigin
        let flight: Flight
        if sharesHandshake, let joined = pending[key] {
            origin = .joined
            flight = joined
        } else {
            origin = .created
            flight = Flight(task: Task { try await connect() })
            if sharesHandshake { pending[key] = flight }
        }

        let connection: Connection
        do {
            connection = try await flight.task.value
        } catch {
            clearPending(key, flight)
            throw error
        }
        clearPending(key, flight)
        if let beforeClaim { await beforeClaim() }

        // 认领：每份租约只从「登记着、活着、还有名额」的那一项发。
        switch flight.state {
        case .connecting:
            guard connection.isAlive else {
                // 还没登记就断了（或本来就是坏的）：谁也别用它。
                flight.state = .retired
                Task { await connection.closeTransport() }
                return try await acquire(key, sharesHandshake: sharesHandshake, connect: connect)
            }
            register(flight, key: key, connection: connection)
        case .registered:
            guard let entry = entries[flight.id], entry.connection.isAlive else {
                handleClosed(flight.id)
                return try await acquire(key, sharesHandshake: sharesHandshake, connect: connect)
            }
            guard entry.leases.count < maxLeasesPerConnection else {
                // 先来的人已经把它借满了：另找 / 另建一条。
                return try await acquire(key, sharesHandshake: sharesHandshake, connect: connect)
            }
        case .retired:
            // 已经被借完还光（正在关）或判死摘掉了：绝不再登记回去。
            return try await acquire(key, sharesHandshake: sharesHandshake, connect: connect)
        }
        return (connection, lease(on: flight.id), origin)
    }

    /// 归还租约。最后一份归还时断开连接。
    func release(_ lease: PooledLease) async {
        guard var entry = entries[lease.connectionID],
              entry.leases.remove(lease.leaseID) != nil else { return }
        entry.closeHandlers[lease.leaseID] = nil
        guard entry.leases.isEmpty else {
            entries[lease.connectionID] = entry
            return
        }
        entries[lease.connectionID] = nil
        entry.flight?.state = .retired
        await entry.connection.closeTransport()
    }

    /// 判死这份租约所在的连接（看门狗 / 探活判定传输已死）：**先**摘出表、通知上面的全部租约，**再**断开传输。
    ///
    /// 顺序要紧：断开不是立刻完成的（经跳板机的内层连接最多等 5 秒），这期间连接的 `isAlive` 仍是真；
    /// 先断后摘的话，这段时间里新开的标签会借到这条正在关的连接，开通道失败报 `.localClose`（不算网络断开，
    /// 不会自动重连），用户看到的是一个错误而不是重连。
    func invalidate(_ lease: PooledLease) async {
        guard let entry = evict(lease.connectionID) else { return }
        await entry.connection.closeTransport()
    }

    /// 订阅这份租约所在连接的断开。连接已经断了就立即回调。
    ///
    /// 不会因为归还而回调：`release` 会先摘掉这份租约的订阅。
    func onClosed(_ lease: PooledLease, _ handler: @escaping @Sendable () -> Void) {
        guard let entry = entries[lease.connectionID],
              entry.leases.contains(lease.leaseID) else {
            handler()
            return
        }
        guard entry.connection.isAlive else {
            handleClosed(lease.connectionID)
            handler()
            return
        }
        entries[lease.connectionID]?.closeHandlers[lease.leaseID] = handler
    }

    /// `key` 下正在建的连接数（0 或 1，单测用）。
    func pendingCount(for key: Key) -> Int {
        pending[key] == nil ? 0 : 1
    }

    /// `key` 下还开着的连接数（单测用）。
    func connectionCount(for key: Key) -> Int {
        entries.values.filter { $0.key == key }.count
    }

    // MARK: - 私有

    private func reusableConnectionID(for key: Key) -> UUID? {
        for (id, entry) in entries where entry.key == key {
            guard entry.connection.isAlive else {
                handleClosed(id)
                continue
            }
            if entry.leases.count < maxLeasesPerConnection {
                return id
            }
        }
        return nil
    }

    private func lease(on id: UUID) -> PooledLease {
        let lease = PooledLease(connectionID: id, leaseID: UUID())
        entries[id]?.leases.insert(lease.leaseID)
        return lease
    }

    private func register(_ flight: Flight, key: Key, connection: Connection) {
        let id = flight.id
        flight.state = .registered
        entries[id] = Entry(key: key, connection: connection, flight: flight)
        connection.onTransportClosed { [weak self] in
            Task { await self?.handleClosed(id) }
        }
    }

    private func clearPending(_ key: Key, _ flight: Flight) {
        if pending[key] === flight {
            pending[key] = nil
        }
    }

    /// 一条连接断了（或被发现已经不活）：摘出表、通知租约，并把它彻底关掉。
    ///
    /// 关掉这一步不能省：经跳板机时断的常常只是目标那一跳，跳板机的 `SSHClient`（socket + 那边的 sshd 会话）
    /// 还连着；表里已经没有它，之后谁也不会再 `release` / `invalidate` 它，不关就挂到 App 退出。`closeTransport`
    /// 是幂等的，已经断了的那一跳关一次没有代价。
    private func handleClosed(_ id: UUID) {
        guard let entry = evict(id) else { return }
        Task { await entry.connection.closeTransport() }
    }

    private func evict(_ id: UUID) -> Entry? {
        guard let entry = entries.removeValue(forKey: id) else { return nil }
        entry.flight?.state = .retired
        for handler in entry.closeHandlers.values {
            handler()
        }
        return entry
    }
}

/// 终端与 SFTP 侧栏共用连接的分组键：目标、跳板机与两跳的认证材料都相同才共用。
///
/// 认证材料只存 SHA-256 摘要：改了密码 / 换了私钥就是另一组，不会借到用旧凭据登录的连接。
nonisolated struct SharedSSHKey: Hashable, Sendable {
    let host: String
    let port: Int
    let jumpHost: String?
    let credential: String
    let jumpCredential: String?

    init(profile: SSHConnection.ProfileSnapshot, auth: ResolvedAuth, jumpHostAuth: ResolvedAuth?) {
        host = profile.host
        port = profile.port
        jumpHost = profile.jumpHost.map { "\($0.host):\($0.port)" }
        credential = Self.digest(auth)
        jumpCredential = jumpHostAuth.map(Self.digest)
    }

    static func digest(_ auth: ResolvedAuth) -> String {
        let fields: [String]
        switch auth {
        case .password(let username, let password):
            fields = ["password", username, password]
        case .privateKey(let username, let pem, let passphrase):
            fields = ["privateKey", username, pem, passphrase ?? ""]
        }
        let input = Data(fields.joined(separator: "\u{0}").utf8)
        return SHA256.hash(data: input).map { String(format: "%02x", $0) }.joined()
    }
}

/// app 级的共享 SSH 连接池（终端与 SFTP 侧栏用，见 `SSHClientFactory.connectShared`）。
///
/// 每条连接最多 6 份租约：sshd 默认 `MaxSessions` 10，每份租约常驻一条通道，余下的留给
/// 看门狗探测、遥测、属主名查询这些临时 exec 通道。
nonisolated enum SharedSSHConnections {
    static let pool = SharedConnectionPool<SharedSSHKey, ConnectedClient>(maxLeasesPerConnection: 6)
}
