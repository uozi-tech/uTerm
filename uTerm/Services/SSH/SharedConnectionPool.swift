import CryptoKit
import Foundation

/// 共享连接池里的一条连接需要的能力。生产实现是 `ConnectedClient`；单测注入假的。
nonisolated protocol PooledConnection: Sendable {
    /// 传输是否还活着。已断开的连接不会再借出去。
    var isAlive: Bool { get }
    /// 挂传输断开回调。池子每条连接只挂一次，再自己分发给各租约 —— Citadel 的
    /// `onDisconnect` 只存一个回调，后挂的会覆盖先挂的。
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
    }

    let maxLeasesPerConnection: Int
    private var entries: [UUID: Entry] = [:]
    private var pending: [Key: (id: UUID, task: Task<Connection, Error>)] = [:]

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
        if let id = reusableConnectionID(for: key) {
            return (entries[id]!.connection, lease(on: id), .reused)
        }

        let origin: PooledConnectionOrigin
        let inFlight: (id: UUID, task: Task<Connection, Error>)
        if let joined = pending[key] {
            origin = .joined
            inFlight = joined
        } else {
            origin = .created
            inFlight = (UUID(), Task { try await connect() })
            pending[key] = inFlight
        }

        let connection: Connection
        do {
            connection = try await inFlight.task.value
        } catch {
            clearPending(key, id: inFlight.id)
            throw error
        }
        clearPending(key, id: inFlight.id)

        if entries[inFlight.id] == nil {
            // 等的这段时间里，这条连接可能已经被别人借完又还光、断开了。
            guard connection.isAlive else {
                return try await acquire(key, connect: connect)
            }
            register(id: inFlight.id, key: key, connection: connection)
        }
        return (connection, lease(on: inFlight.id), origin)
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

    private func register(id: UUID, key: Key, connection: Connection) {
        entries[id] = Entry(key: key, connection: connection)
        connection.onTransportClosed { [weak self] in
            Task { await self?.handleClosed(id) }
        }
    }

    private func clearPending(_ key: Key, id: UUID) {
        if pending[key]?.id == id {
            pending[key] = nil
        }
    }

    private func handleClosed(_ id: UUID) {
        guard let entry = entries.removeValue(forKey: id) else { return }
        for handler in entry.closeHandlers.values {
            handler()
        }
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
