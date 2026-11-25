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
/// - **exec 的冷启动只建一次**：建连期间以 `Task` 占位，同时到来的第二个请求
///   `await` 同一个 Task。没有这层占位时，两条并发的 `run` 会各建一条连接，
///   后者覆盖前者入表，前者永远关不掉 —— fd 泄漏，而且远端多一条看不见的 SSH 会话。
/// - **SFTP 是每主机最多 `maxSFTPChannelsPerHost`（8）条的小池子**，借还制
///   （`borrowSFTP` / `returnSFTP`，或协议扩展里的 `withSFTP(for:_:)`）。
///   分片并行传输要的就是多条通道各跑各的；到上限的借用者排队等归还。
///   与 exec 不同，SFTP **不**共享冷启动 —— 那会把并行退化回单通道。
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

    /// 每台主机最多几条并行的 SFTP 会话（各自一条独立的 SSH 连接）。
    ///
    /// 上限卡的是 sshd 的 `MaxStartups`（默认 `10:30:100`）：同一时刻**还没认证完**的
    /// 连接超过 10 条，sshd 就开始随机丢新连接。8 条 SFTP + 1 条 exec 一起冷启动也不到 10。
    /// 每条会话是单独一条 SSH 连接，所以 `MaxSessions`（单连接内的通道数）管不到这里。
    /// 一次传输默认 8 路（`ControlProtocol.defaultTransferChannels`），16 条让同一台主机
    /// 能同时跑两个满速传输；再多就是 8 路以上的实测负收益区。建连由
    /// `maxConcurrentHandshakes` 分批，不会一口气撞 `MaxStartups`。
    /// 超过上限的借用请求排队等归还。
    static let maxSFTPChannelsPerHost = 16

    /// 一台主机的 SFTP 小池子。会话本身是 actor（引用类型），用 `ObjectIdentifier` 认人。
    private nonisolated struct SFTPChannels: Sendable {
        var idle: [any SFTPProviding] = []
        var busy: [ObjectIdentifier: any SFTPProviding] = [:]
        /// 正在建的条数（还没进 idle / busy），一并计入上限，免得并发借用超建。
        var pending = 0

        var total: Int { idle.count + busy.count + pending }
        var isEmpty: Bool { total == 0 }
        var all: [any SFTPProviding] { idle + Array(busy.values) }
    }

    private nonisolated struct Entry: Sendable {
        var exec: (any ControlExecChannel)?
        var sftp = SFTPChannels()
        var lastUsedAt: Date
        /// 正在流式跑的命令数。`run` 能跑到 `--max-duration`（默认 1 小时），远超
        /// 10 分钟的空闲回收 —— 不数着的话清扫会把连接从正在跑的命令底下关掉。
        var execInFlight = 0

        var isEmpty: Bool { exec == nil && sftp.isEmpty }
    }

    /// 一个在等 SFTP 名额的借用者。
    ///
    /// `continuation` 的 `Bool`：true = 有名额了（或被取消，交给借用者自己的
    /// `checkCancellation` 收场），false = 等到超时。
    private struct SFTPWaiter {
        let ticket: UUID
        let flag: SFTPWaitFlag
        let continuation: CheckedContinuation<Bool, Never>
    }

    /// 等待者「已被取消」的标记。
    ///
    /// `withTaskCancellationHandler` 的 `onCancel` 在**取消方**的线程上同步跑，进不了
    /// 本 actor，所以只能用一个带锁的小盒子把状态立刻记下来 —— 唤醒方据此跳过已取消的
    /// 等待者，把名额传给下一个。少了这一层，唤醒一个已取消的等待者就等于把名额丢掉：
    /// 它醒来只会抛 `CancellationError`，而后面还排着的人永远等不到下一次归还。
    private final class SFTPWaitFlag: @unchecked Sendable {
        private let lock = NSLock()
        private var cancelled = false

        func markCancelled() {
            lock.lock(); defer { lock.unlock() }
            cancelled = true
        }

        var isCancelled: Bool {
            lock.lock(); defer { lock.unlock() }
            return cancelled
        }
    }

    /// 借一条 SFTP 会话最多等多久。
    ///
    /// 必须**短于** `ControlServer` 的静默预算（120 s；排队期间没有进展可报），否则等待方
    /// 永远等不到自己的答案：请求先被服务端按 `handler_timeout` 掐掉，客户端只看到一个
    /// 不说明原因的超时，而排队者还占着一个传输槽位。
    static let sftpWaitTimeout: Duration = .seconds(90)

    private let connector: Connector
    private let idleInterval: Duration
    private let maxSFTPChannels: Int
    private let sftpWaitTimeout: Duration
    private let now: @Sendable () -> Date

    private var entries: [UUID: Entry] = [:]
    /// 按主机排队的借用者。名额一腾出来（归还 / 建连失败 / 全量释放）就唤醒一个。
    private var sftpWaiters: [UUID: [SFTPWaiter]] = [:]
    /// exec 建连中的占位。后到的请求 `await` 同一个 Task，因此一台主机同一时刻
    /// 只会有一次 exec 冷启动。（SFTP 不共享冷启动 —— 那正是多通道要的并行，
    /// 上限由 `SFTPChannels.pending` 计数守住。）
    private var pendingExec: [UUID: Task<any ControlExecChannel, any Error>] = [:]
    /// 最近一次建连被拒的主机密钥质询，按 hostID。`trust` 只认这里的指纹。
    private var challenges: [UUID: HostKeyChallenge] = [:]
    private var sweeper: Task<Void, Never>?
    /// 每主机正在握手的 SFTP 连接数，与排队等握手名额的借用者。
    private var handshaking: [UUID: Int] = [:]
    private var handshakeWaiters: [UUID: [CheckedContinuation<Void, Never>]] = [:]

    /// 同一主机同时握手的 SFTP 连接上限。sshd 的 `MaxStartups`（默认 `10:30:100`）数的是
    /// **还没认证完**的连接：一次性并发建十几条，超过 10 条的会被随机丢掉（实测 32 通道
    /// 并发冷启动时吞吐反而掉一半，就是一部分工作者没建起连接）。握手排队、认证完的连接
    /// 不再计入，所以限制握手并发而不是连接总数。
    static let maxConcurrentHandshakes = 4

    init(
        connector: Connector = .live,
        idleInterval: Duration = ControlConnectionPool.idleTimeout,
        maxSFTPChannels: Int = ControlConnectionPool.maxSFTPChannelsPerHost,
        sftpWaitTimeout: Duration = ControlConnectionPool.sftpWaitTimeout,
        now: @escaping @Sendable () -> Date = { Date() }
    ) {
        self.connector = connector
        self.idleInterval = idleInterval
        self.maxSFTPChannels = max(1, maxSFTPChannels)
        self.sftpWaitTimeout = sftpWaitTimeout
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
        return SSHCommandExecutor(
            maxLines: maxLines,
            maxBytes: maxBytes,
            exec: { [weak self] command in
                // 跑命令期间**不**占着本 actor：touch 立刻返回，exec 在通道自己的隔离域里跑。
                await self?.touch(hostID)
                return try await channel.exec(command)
            },
            execStream: { [weak self] command, onOutput in
                await self?.beginExec(hostID)
                do {
                    try await channel.execStreaming(command, onOutput: onOutput)
                    await self?.endExec(hostID)
                } catch {
                    await self?.endExec(hostID)
                    throw error
                }
            }
        )
    }

    /// 借一条这台主机的 SFTP 会话：
    /// 有空闲 → 直接拿；没空闲且没到 `maxSFTPChannels` → 新建一条；到上限 → 排队等归还
    /// （最多 `sftpWaitTimeout`，等不到抛 `SFTPChannelsBusyError`）。
    ///
    /// 必须与 `returnSFTP(_:for:)` 配对，最省事的写法是协议扩展里的
    /// `withSFTP(for:_:)`。不归还的话这条会话永远算「在用」，既不会被复用也不会被
    /// 空闲回收，等于把这台主机的一个名额烧掉。
    func borrowSFTP(for host: HostConnectionSpec) async throws -> any SFTPProviding {
        sweepIdle()
        while true {
            try Task.checkCancellation()
            var entry = entries[host.id] ?? Entry(lastUsedAt: now())
            if !entry.sftp.idle.isEmpty {
                let session = entry.sftp.idle.removeLast()
                entry.sftp.busy[ObjectIdentifier(session)] = session
                entry.lastUsedAt = now()
                entries[host.id] = entry
                return session
            }
            if entry.sftp.total < maxSFTPChannels {
                entry.sftp.pending += 1
                entry.lastUsedAt = now()
                entries[host.id] = entry
                return try await makeSFTPChannel(for: host)
            }
            // 到上限：让出名额给已在跑的传输，等一次归还再重来。
            let granted = await waitForSFTPSlot(host.id)
            guard granted else {
                throw SFTPChannelsBusyError(
                    limit: maxSFTPChannels,
                    waitedSeconds: sftpWaitTimeout.seconds
                )
            }
            if Task.isCancelled {
                // 被唤醒但自己已经取消：名额传给下一个等待者，别让它烂在这里。
                resumeOneSFTPWaiter(host.id)
                try Task.checkCancellation()
            }
        }
    }

    /// 归还借出的会话。会话回到空闲队列并唤醒一个等待者；
    /// 期间若这台主机被 `disconnect` / `disconnectAll` 清过，就直接关掉它。
    ///
    /// **重复归还是 no-op**（协议明说安全）。判据必须是「它是不是已经在 idle 里」，
    /// 而不是「它在不在 busy 里」—— 只看 busy 的话，第二次归还会走进「池里没这条记录」
    /// 的分支，把一条**刚被别人借走、正在传输**的活会话关掉。
    func returnSFTP(_ session: any SFTPProviding, for hostID: UUID) async {
        let key = ObjectIdentifier(session)
        guard var entry = entries[hostID] else {
            // 池里已经没这台主机（被显式释放过）→ 关掉，别泄漏。
            closeDetached(sftp: session)
            resumeOneSFTPWaiter(hostID)
            return
        }
        if entry.sftp.busy[key] != nil {
            entry.sftp.busy[key] = nil
            entry.sftp.idle.append(session)
            entry.lastUsedAt = now()
            entries[hostID] = entry
            resumeOneSFTPWaiter(hostID)
            return
        }
        if entry.sftp.idle.contains(where: { ObjectIdentifier($0) == key }) {
            return   // 重复归还：已经在空闲队列里了，不关也不重复唤醒。
        }
        // 既不在 busy 也不在 idle：这条会话不属于当前的这台主机记录（释放后重建过）。
        closeDetached(sftp: session)
        resumeOneSFTPWaiter(hostID)
    }

    private func acquireHandshake(_ hostID: UUID) async {
        if handshaking[hostID, default: 0] < Self.maxConcurrentHandshakes {
            handshaking[hostID, default: 0] += 1
            return
        }
        // 名额由 `releaseHandshake` 直接转交给排队者，计数不变。
        await withCheckedContinuation { handshakeWaiters[hostID, default: []].append($0) }
    }

    private func releaseHandshake(_ hostID: UUID) {
        if var queue = handshakeWaiters[hostID], !queue.isEmpty {
            let next = queue.removeFirst()
            handshakeWaiters[hostID] = queue.isEmpty ? nil : queue
            next.resume()
            return
        }
        let count = handshaking[hostID, default: 1] - 1
        handshaking[hostID] = count > 0 ? count : nil
    }

    func discardSFTP(_ session: any SFTPProviding, for hostID: UUID) async {
        let key = ObjectIdentifier(session)
        if var entry = entries[hostID] {
            entry.sftp.busy[key] = nil
            entry.sftp.idle.removeAll { ObjectIdentifier($0) == key }
            entries[hostID] = entry.isEmpty ? nil : entry
        }
        closeDetached(sftp: session)
        // 名额空出来了：等着的借用者会新建一条，而不是拿到这条死会话。
        resumeOneSFTPWaiter(hostID)
    }

    /// 真正建一条新的 SFTP 会话。调用前已经把 `pending` 加过 1（占住名额）。
    private func makeSFTPChannel(for host: HostConnectionSpec) async throws -> any SFTPProviding {
        let make = connector.makeSFTP
        await acquireHandshake(host.id)
        let task = Task.detached { try await make(host) }
        let session: any SFTPProviding
        do {
            session = try await task.value
            releaseHandshake(host.id)
        } catch {
            releaseHandshake(host.id)
            releaseSFTPPending(host.id)
            throw record(error, for: host)
        }
        guard var entry = entries[host.id], entry.sftp.pending > 0 else {
            // 建连期间这台主机被释放了 —— 新会话没人认领，关掉。
            closeDetached(sftp: session)
            resumeOneSFTPWaiter(host.id)
            // 不是 `connectFailed`：握手、认证、主机密钥全过了，纯粹是建连期间
            // 这台主机被 disconnect 掉。报成「连接失败」会把人引去查不存在的网络故障。
            throw ControlConnectError.released(String(localized: "建立期间该主机被断开"))
        }
        entry.sftp.pending -= 1
        entry.sftp.busy[ObjectIdentifier(session)] = session
        entry.lastUsedAt = now()
        entries[host.id] = entry
        scheduleSweep()
        return session
    }

    /// 建连失败 / 中途作废：把占住的名额还回去并唤醒一个等待者。
    private func releaseSFTPPending(_ hostID: UUID) {
        if var entry = entries[hostID], entry.sftp.pending > 0 {
            entry.sftp.pending -= 1
            if entry.isEmpty {
                entries[hostID] = nil
            } else {
                entries[hostID] = entry
            }
        }
        resumeOneSFTPWaiter(hostID)
    }

    /// 等一个 SFTP 名额，最多等 `sftpWaitTimeout`。返回 true = 有名额了（或本任务被
    /// 取消，由 `borrowSFTP` 的 `checkCancellation` 收场），false = 超时。
    ///
    /// 三条出路都必须恢复 continuation，否则借用者永久挂死：
    /// - 有人归还 / 主机被释放 → `resumeOneSFTPWaiter` / `resumeAllSFTPWaiters`；
    /// - 本任务被取消 → `onCancel` 先立刻打标记（唤醒方据此跳过它），再把自己从队列摘掉；
    /// - 等够 `sftpWaitTimeout` → 计时器把自己从队列摘掉并回 false。
    private func waitForSFTPSlot(_ hostID: UUID) async -> Bool {
        let ticket = UUID()
        let flag = SFTPWaitFlag()
        let timeout = sftpWaitTimeout
        let timer = Task { [weak self] in
            do {
                try await Task.sleep(for: timeout)
            } catch {
                return   // 名额到手 / 被取消 → 计时器作废
            }
            await self?.expireSFTPWait(hostID, ticket)
        }
        defer { timer.cancel() }
        return await withTaskCancellationHandler {
            await withCheckedContinuation { (continuation: CheckedContinuation<Bool, Never>) in
                // 已经取消就别进队列了：`onCancel` 可能已经跑过，没人再来叫醒我们。
                guard !Task.isCancelled, !flag.isCancelled else {
                    continuation.resume(returning: true)
                    return
                }
                sftpWaiters[hostID, default: []].append(
                    SFTPWaiter(ticket: ticket, flag: flag, continuation: continuation))
            }
        } onCancel: {
            flag.markCancelled()
            Task { await self.cancelSFTPWait(hostID, ticket) }
        }
    }

    private func cancelSFTPWait(_ hostID: UUID, _ ticket: UUID) {
        guard let waiter = removeSFTPWaiter(hostID, ticket) else { return }
        // true：让 `borrowSFTP` 回到循环顶端，由它的 `checkCancellation` 抛出去。
        waiter.continuation.resume(returning: true)
    }

    /// 等超时：摘掉自己并回 false，`borrowSFTP` 据此抛 `SFTPChannelsBusyError`。
    private func expireSFTPWait(_ hostID: UUID, _ ticket: UUID) {
        guard let waiter = removeSFTPWaiter(hostID, ticket) else { return }
        waiter.continuation.resume(returning: false)
    }

    private func removeSFTPWaiter(_ hostID: UUID, _ ticket: UUID) -> SFTPWaiter? {
        guard var queue = sftpWaiters[hostID],
              let index = queue.firstIndex(where: { $0.ticket == ticket }) else { return nil }
        let waiter = queue.remove(at: index)
        sftpWaiters[hostID] = queue.isEmpty ? nil : queue
        return waiter
    }

    /// 把一个名额交给队首。队首若已经取消，就叫醒它让它自行收场，**继续往下传**，
    /// 直到有人真的接手或队列空 —— 否则一次归还的名额会随着一个已取消的等待者一起丢掉，
    /// 后面还排着的人只能等下一次归还（最坏情况：再也没有下一次）。
    private func resumeOneSFTPWaiter(_ hostID: UUID) {
        while var queue = sftpWaiters[hostID], !queue.isEmpty {
            let waiter = queue.removeFirst()
            sftpWaiters[hostID] = queue.isEmpty ? nil : queue
            waiter.continuation.resume(returning: true)
            if !waiter.flag.isCancelled { return }
        }
    }

    private func resumeAllSFTPWaiters(_ hostID: UUID) {
        guard let queue = sftpWaiters.removeValue(forKey: hostID) else { return }
        for waiter in queue { waiter.continuation.resume(returning: true) }
    }

    private func resumeAllSFTPWaiters() {
        let all = sftpWaiters
        sftpWaiters.removeAll()
        for queue in all.values {
            for waiter in queue { waiter.continuation.resume(returning: true) }
        }
    }

    private func execChannel(for host: HostConnectionSpec) async throws -> any ControlExecChannel {
        sweepIdle()
        if let existing = entries[host.id]?.exec {
            touch(host.id)
            return existing
        }
        let task: Task<any ControlExecChannel, any Error>
        if let pending = pendingExec[host.id] {
            task = pending
        } else {
            let make = connector.makeExec
            task = Task.detached { try await make(host) }
            pendingExec[host.id] = task
        }
        let channel: any ControlExecChannel
        do {
            channel = try await task.value
        } catch {
            clearPendingExec(host.id, task)
            throw record(error, for: host)
        }
        clearPendingExec(host.id, task)
        if let existing = entries[host.id]?.exec {
            closeDetached(exec: channel)
            touch(host.id)
            return existing
        }
        var entry = entries[host.id] ?? Entry(lastUsedAt: now())
        entry.exec = channel
        entry.lastUsedAt = now()
        entries[host.id] = entry
        scheduleSweep()
        return channel
    }

    /// 只清掉**自己那次**的占位：搭车者恢复得晚，此时占位可能已经属于新一轮建连了。
    private func clearPendingExec(_ hostID: UUID, _ task: Task<any ControlExecChannel, any Error>) {
        if pendingExec[hostID] == task { pendingExec[hostID] = nil }
    }

    /// 关掉一条多余的连接。派到独立 Task，免得在建连路径里引入 await 重入。
    private func closeDetached(exec channel: any ControlExecChannel) {
        Task.detached { await channel.close() }
    }

    private func closeDetached(sftp session: any SFTPProviding) {
        Task.detached { await session.close() }
    }

    /// 建连失败的收口：主机密钥两态落进 `challenges`（`trust` 从这里取指纹核对），
    /// 错误原样上抛。
    private func record(_ error: any Error, for host: HostConnectionSpec) -> any Error {
        if let connectError = error as? ControlConnectError {
            recordChallenge(connectError, for: host)
        }
        return error
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

    /// 关掉这台主机的 exec 与**全部** SFTP 会话（空闲的和正在借出的都关）。
    /// 借出中的会话归还时会发现自己已经不在表里，随即被关掉。
    func disconnect(hostID: UUID) async {
        let entry = entries.removeValue(forKey: hostID)
        resumeAllSFTPWaiters(hostID)
        guard let entry else { return }
        await close(entry)
    }

    func disconnectAll() async {
        let all = entries
        entries.removeAll()
        challenges.removeAll()
        resumeAllSFTPWaiters()
        sweeper?.cancel()
        sweeper = nil
        for entry in all.values {
            await close(entry)
        }
    }

    func heldHostIDs() async -> [UUID] {
        Array(entries.keys)
    }

    // MARK: - 空闲回收

    /// 清掉空闲超过 `idleInterval` 的持有，返回剩下几台。**同步**执行关闭
    /// （`close()` 派到独立 Task），这样它可以被建连路径顺手调用而不引入 await 重入。
    @discardableResult
    func sweepIdle() -> Int {
        let deadline = now().addingTimeInterval(-idleInterval.seconds)
        var expired: [Entry] = []
        for (id, entry) in entries where entry.lastUsedAt <= deadline {
            // 有会话正借在外面（长传输）或正在建、或有命令正在跑 → 这台主机还在用，别回收。
            guard entry.sftp.busy.isEmpty, entry.sftp.pending == 0, entry.execInFlight == 0
            else { continue }
            expired.append(entry)
            entries.removeValue(forKey: id)
        }
        guard !expired.isEmpty else { return entries.count }
        let closing = expired
        Task.detached {
            for entry in closing {
                await entry.exec?.close()
                for session in entry.sftp.all { await session.close() }
            }
        }
        return entries.count
    }

    private func touch(_ hostID: UUID) {
        entries[hostID]?.lastUsedAt = now()
    }

    private func beginExec(_ hostID: UUID) {
        entries[hostID]?.execInFlight += 1
        touch(hostID)
    }

    /// 结束时也 touch：空闲从命令**跑完**算起，而不是从它开始算。
    private func endExec(_ hostID: UUID) {
        if let count = entries[hostID]?.execInFlight, count > 0 {
            entries[hostID]?.execInFlight = count - 1
        }
        touch(hostID)
    }

    private func close(_ entry: Entry) async {
        await entry.exec?.close()
        for session in entry.sftp.all { await session.close() }
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
    nonisolated static let live = live(transferWindowBytes: ParallelTransfer.Tuning.standard.windowBytes)

    /// 生产建连。SFTP 会话只给大文件传输用，窗口单独设（`transferWindowBytes`）；exec 与
    /// 信任握手沿用终端那套 1 MiB。
    nonisolated static func live(transferWindowBytes: Int) -> ControlConnectionPool.Connector {
        ControlConnectionPool.Connector(
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
                } catch is CancellationError {
                    await reusable.close()
                    throw CancellationError()
                } catch {
                    await reusable.close()
                    throw ControlConnectionPool.mapConnectError(error, sink: sink)
                }
                return reusable
            },
            makeSFTP: { spec in
                let sink = HostKeyChallengeSink()
                do {
                    let connected = try await ControlConnectionPool.liveConnect(
                        spec, sink: sink, windowBytes: transferWindowBytes)()
                    // 命令行自己的连接，上面没有终端：上传不按节奏，跑满速。
                    return try await SFTPSession(connected: connected, pacesUploads: false)
                } catch is CancellationError {
                    throw CancellationError()   // 命令行断开了：不是连接失败
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
                } catch is CancellationError {
                    throw CancellationError()   // 命令行断开了：不是连接失败
                } catch {
                    throw ControlConnectionPool.mapConnectError(error, sink: sink)
                }
            }
        )
    }
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
        pinnedFingerprint: String? = nil,
        windowBytes: Int = 1 << 20
    ) -> @Sendable () async throws -> ConnectedClient {
        let maximumPacketSize = SSHClientFactory.maximumPacketSize(forWindowBytes: windowBytes)
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
                    // 加密方式变弱了（`.weakAlgorithms`）也走这里：记下、拒绝，`mapConnectError` 归成 `weak_algorithms`。
                    // `trust` 路径也不放行它——钉住的是主机密钥，不是加密方式。
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
                },
                approvesInteractively: false,
                maximumPacketSize: maximumPacketSize
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
            case .weakAlgorithms:
                return .weakAlgorithms(LegacyAlgorithmRefusal(host: challenge.host, port: challenge.port,
                                                              isJumpHost: challenge.isJumpHost))
            }
        }
        if let already = error as? ControlConnectError { return already }
        let text = FriendlyError.describe(error)
        if let error = error as? SSHConnection.SSHConnectionError {
            switch error {
            case .weakAlgorithmsDeclined(let refusal):
                return .weakAlgorithms(refusal)
            case .authenticationFailed, .jumpHostFailed(_, .authentication):
                return .authFailed(text)
            // 握手 / 主机密钥：目标那一跳或跳板机那一跳都一样，重试不会好。
            case .handshakeFailed, .hostKeyRejected, .jumpHostFailed(_, .hostKey), .jumpHostFailed(_, .handshake),
                 .jumpHostFailed(_, .weakAlgorithms):
                return .connectRejected(text)
            case .notConnected, .alreadyClosed, .connectFailed, .jumpHostFailed(_, .unreachable):
                break
            }
        }
        if text.contains("认证失败") || text.localizedCaseInsensitiveContains("authentication") {
            return .authFailed(text)
        }
        return .connectFailed(text)
    }
}

private extension Duration {
    /// 秒（含小数部分），用来和 `Date` 比。
    nonisolated var seconds: TimeInterval {
        let parts = components
        return TimeInterval(parts.seconds) + TimeInterval(parts.attoseconds) / 1e18
    }
}
