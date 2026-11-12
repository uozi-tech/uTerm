import Foundation

/// 远控进程里的 `RemoteHostSessions`：会话在 App 里，经 XPC 转过来。
///
/// App 不在（更新、崩溃）的那段时间：列表冻结在最后一份、不报「消失」；已接入的终端暂停（没有输出，输入丢弃），
/// App 回来并接回本机终端后，按同一个接入号重新向 App 接入，第一段数据就是一张新快照，期间的输出由 holder 补齐。
@MainActor
final class RemoteForwardedSessions: RemoteHostSessions {
    private(set) var entries: [RemoteHostSessionEntry] = []
    private(set) var terminalEngine: String
    /// App 报了「接回完成」。App 走了就变回 false，直到它回来再报。
    private(set) var isRestored = false
    private var restoreWaiters: [UUID: CheckedContinuation<Void, Never>] = [:]
    private var observer: RemoteHostSessionObserver?
    private var attachments: [String: ForwardedAttachment] = [:]
    private var attachWaiters: [String: CheckedContinuation<String?, Never>] = [:]
    private var requestTimeout: Duration

    /// 此刻连着的 App（nil = App 不在）。
    private(set) var app: (any RemoteHostAppXPC)?

    init(terminalEngine: String = TerminalEngineVersion.current, requestTimeout: Duration = RemoteHostAgent.appRequestWait) {
        self.terminalEngine = terminalEngine
        self.requestTimeout = requestTimeout
    }

    // MARK: - App 来去

    /// App 连上了（或换了一条连接）。会话等它报「接回完成」再用。
    func appConnected(_ app: any RemoteHostAppXPC) {
        self.app = app
    }

    /// App 走了：暂停所有接入，在途的接入请求按失败处理。
    func appDisconnected() {
        app = nil
        isRestored = false
        for attachment in attachments.values { attachment.suspend() }
        for (id, waiter) in attachWaiters {
            attachWaiters.removeValue(forKey: id)
            waiter.resume(returning: RemoteHostAttachError.appUnavailable.message)
        }
    }

    /// 服务停了：等着的都放行（它们随后会发现连接已经关了）。
    func releaseWaiters() {
        for waiter in restoreWaiters.values { waiter.resume() }
        restoreWaiters.removeAll()
    }

    /// App 报来的会话目录。
    func apply(_ update: RemoteHostAgentSessions) {
        terminalEngine = update.terminalEngine
        // App 刚回来、还在接回本机终端：这份列表不全，先用上一份。
        guard update.restored else { return }
        let previous = entries
        entries = update.entries
        let becameRestored = !isRestored
        isRestored = true
        if becameRestored {
            for waiter in restoreWaiters.values { waiter.resume() }
            restoreWaiters.removeAll()
            resumeSuspended()
        }
        notifyChanges(from: previous)
    }

    private func notifyChanges(from previous: [RemoteHostSessionEntry]) {
        guard let observer else { return }
        let oldIDs = previous.map(\.id), newIDs = entries.map(\.id)
        if Set(oldIDs) != Set(newIDs) {
            observer.sessionsChanged(Set(newIDs))
        } else if oldIDs != newIDs {
            observer.orderChanged()
        }
        let oldByID = Dictionary(previous.map { ($0.id, $0) }, uniquingKeysWith: { a, _ in a })
        if entries.contains(where: { oldByID[$0.id]?.tabTitle != $0.tabTitle }) { observer.titlesChanged() }
        if entries.contains(where: { oldByID[$0.id]?.program != $0.program })
            || previous.contains(where: { old in old.program != nil && !newIDs.contains(old.id) }) {
            observer.programStatusChanged()
        }
    }

    // MARK: - RemoteHostSessions

    func orderedSessions() -> [RemoteHostSessionEntry] { entries }

    func observe(_ observer: RemoteHostSessionObserver) { self.observer = observer }

    func stopObserving() { observer = nil }

    func waitUntilRestored() async {
        guard !isRestored else { return }
        let id = UUID()
        let timeout = requestTimeout
        // App 迟迟不回来：到点放行，接入随后以「App 不在」失败，对端可以重试。
        let timer = Task { [weak self] in
            guard (try? await Task.sleep(for: timeout)) != nil else { return }
            self?.restoreWaiters.removeValue(forKey: id)?.resume()
        }
        await withCheckedContinuation { continuation in
            if isRestored { continuation.resume() } else { restoreWaiters[id] = continuation }
        }
        timer.cancel()
    }

    func requestClose(sessionID: UUID) async -> Bool {
        let reply = await request(.closeSession(sessionID))
        return reply?.error == nil && reply != nil
    }

    func attach(_ request: RemoteHostAttachRequest) async -> Result<any RemoteHostTerminalAttachment, RemoteHostAttachError> {
        guard app != nil else { return .failure(.appUnavailable) }
        let attachment = ForwardedAttachment(id: UUID().uuidString, request: request, owner: self)
        attachments[attachment.id] = attachment
        if let error = await sendAttach(attachment) {
            attachments.removeValue(forKey: attachment.id)
            return .failure(error == RemoteHostAttachError.appUnavailable.message ? .appUnavailable : .unavailable)
        }
        return .success(attachment)
    }

    /// 向 App 发接入请求，等它回话。回 nil = 成功，否则是失败原因。
    private func sendAttach(_ attachment: ForwardedAttachment) async -> String? {
        guard let app else { return RemoteHostAttachError.appUnavailable.message }
        let id = attachment.id
        let timeout = requestTimeout
        let timer = Task { [weak self] in
            guard (try? await Task.sleep(for: timeout)) != nil else { return }
            self?.attachWaiters.removeValue(forKey: id)?.resume(returning: RemoteHostAttachError.appUnavailable.message)
        }
        defer { timer.cancel() }
        return await withCheckedContinuation { continuation in
            attachWaiters[id] = continuation
            app.terminalAttach(id, request: RemoteHostAgentJSON.encode(attachment.wire))
        }
    }

    /// App 回来了：把暂停着的接入重新接上。会话没了的交给列表变化去结束（`sessionsChanged`）。
    private func resumeSuspended() {
        for attachment in attachments.values where attachment.isSuspended {
            guard entries.contains(where: { $0.id == attachment.wire.sessionID }) else { continue }
            Task {
                attachment.prepareForResume()
                if let error = await sendAttach(attachment) {
                    AppLogger.info("远控进程：重新接入会话 \(attachment.wire.sessionID.uuidString.prefix(8)) 失败：\(error)",
                                   category: RemoteLog.category)
                    attachment.onRemoteDisconnect?()
                } else {
                    attachment.resumed()
                }
            }
        }
    }

    // MARK: - App 转来的消息

    func attachResult(_ id: String, error: String?) {
        attachWaiters.removeValue(forKey: id)?.resume(returning: error)
    }

    func chunk(_ id: String, kind: Int, data: Data) {
        guard let kind = RemoteHostTerminalChunkKind(rawValue: kind) else { return }
        attachments[id]?.deliver(kind.chunk(data))
    }

    func ended(_ id: String) {
        attachments[id]?.onRemoteDisconnect?()
    }

    fileprivate func remove(_ attachment: ForwardedAttachment) {
        attachments.removeValue(forKey: attachment.id)
        if !attachment.isSuspended { app?.terminalDetach(attachment.id) }
    }

    // MARK: - 要 App 办的事

    /// 发一个请求，等应答。App 不在时最多等 `requestTimeout` 看它回不回来；回不来回 nil。
    func request(_ request: RemoteHostAppRequest) async -> RemoteHostAppReply? {
        if app == nil {
            await waitUntilRestored()
        }
        guard let app else { return nil }
        let payload = RemoteHostAgentJSON.encode(request)
        let timeout = requestTimeout
        return await withCheckedContinuation { continuation in
            let once = RemoteOnce(continuation)
            app.request(payload) { data in once.resume(RemoteHostAgentJSON.decode(RemoteHostAppReply.self, from: data)) }
            // App 在半路走了，XPC 不会回：到点按「回不来」收尾。
            Task {
                try? await Task.sleep(for: timeout * 2)
                once.resume(nil)
            }
        }
    }
}

/// 远控进程里的一个接入：输出从 App 来，经信用窗口流控；输入、尺寸转给 App。
@MainActor
private final class ForwardedAttachment: RemoteHostTerminalAttachment {
    let id: String
    let wire: RemoteHostAgentAttach
    private weak var owner: RemoteForwardedSessions?
    private let buffer: ForwardedFeed
    var onRemoteDisconnect: (@MainActor () -> Void)?
    private(set) var isSuspended = false
    private var isDetached = false

    nonisolated var feed: any RemoteTerminalFeed { buffer }

    init(id: String, request: RemoteHostAttachRequest, owner: RemoteForwardedSessions) {
        self.id = id
        wire = RemoteHostAgentAttach(sessionID: request.sessionID, cols: request.cols, rows: request.rows,
                                     controller: request.controller, settleTimeout: request.settleTimeout)
        self.owner = owner
        buffer = ForwardedFeed(onReadable: request.onReadable)
        buffer.grant = { [weak owner, id] bytes in
            DispatchQueue.main.async { MainActor.assumeIsolated { owner?.app?.terminalCredit(id, bytes: bytes) } }
        }
    }

    func suspend() {
        isSuspended = true
    }

    /// 重新接入前：丢掉手上还没发完的旧数据（新的订阅从一张完整的快照开始）。
    func prepareForResume() {
        buffer.reset()
    }

    func resumed() {
        isSuspended = false
    }

    func deliver(_ chunk: RemoteTerminalChunk) {
        guard !isDetached else { return }
        buffer.append(chunk)
    }

    func write(_ data: Data) {
        // App 不在时丢弃：画面是冻结的，延后送达容易误操作。
        guard !isSuspended, !isDetached else { return }
        owner?.app?.terminalInput(id, data: data)
    }

    func resize(cols: Int, rows: Int, controller: String) {
        guard !isSuspended, !isDetached else { return }
        owner?.app?.terminalResize(id, cols: cols, rows: rows, controller: controller)
    }

    func detach() {
        guard !isDetached else { return }
        isDetached = true
        onRemoteDisconnect = nil
        owner?.remove(self)
    }

    func deliverImage(_ image: TerminalImage) async -> Result<String?, RemoteHostImageError> {
        guard let owner, !isSuspended else {
            return .failure(RemoteHostImageError(message: RemoteHostAttachError.appUnavailable.message))
        }
        guard let reply = await owner.request(.deliverImage(attachment: id, image: image.data, format: image.format.rawValue)) else {
            return .failure(RemoteHostImageError(message: RemoteHostAttachError.appUnavailable.message))
        }
        if let error = reply.error { return .failure(RemoteHostImageError(message: error)) }
        return .success(reply.path)
    }
}

/// App 送来的终端数据，等链路来取。取走多少就还 App 多少信用。
nonisolated final class ForwardedFeed: RemoteTerminalFeed, @unchecked Sendable {
    private let lock = NSLock()
    private var chunks: [RemoteTerminalChunk] = []
    private let onReadable: @Sendable () -> Void
    /// 取走了多少字节（在链路队列上调）。
    var grant: (@Sendable (Int) -> Void)?

    init(onReadable: @escaping @Sendable () -> Void) {
        self.onReadable = onReadable
    }

    func append(_ chunk: RemoteTerminalChunk) {
        lock.withLock { chunks.append(chunk) }
        onReadable()
    }

    func reset() {
        lock.withLock { chunks.removeAll() }
    }

    func take(maxBytes: Int) -> RemoteTerminalChunk? {
        let taken: RemoteTerminalChunk? = lock.withLock {
            guard !chunks.isEmpty else { return nil }
            let head = chunks[0]
            let limit = max(1, maxBytes)
            guard head.byteCount > limit else {
                chunks.removeFirst()
                return head
            }
            // 比链路一次能取的大：切开，快照的首尾标记留在对应的那一片上。
            switch head {
            case .output(let data):
                chunks[0] = .output(Data(data.dropFirst(limit)))
                return .output(Data(data.prefix(limit)))
            case .snapshot(let data, let isFirst, let isLast):
                chunks[0] = .snapshot(Data(data.dropFirst(limit)), isFirst: false, isLast: isLast)
                return .snapshot(Data(data.prefix(limit)), isFirst: isFirst, isLast: false)
            }
        }
        if let taken { grant?(taken.byteCount) }
        return taken
    }
}

/// 接入请求在 XPC 上的样子。
nonisolated struct RemoteHostAgentAttach: Codable, Equatable, Sendable {
    var sessionID: UUID
    var cols: Int
    var rows: Int
    var controller: String
    var settleTimeout: TimeInterval
}

/// 只恢复一次的续体（XPC 的回复与超时谁先到用谁）。
nonisolated final class RemoteOnce<T: Sendable>: @unchecked Sendable {
    private let lock = NSLock()
    private var continuation: CheckedContinuation<T, Never>?

    init(_ continuation: CheckedContinuation<T, Never>) {
        self.continuation = continuation
    }

    func resume(_ value: T) {
        let pending = lock.withLock { () -> CheckedContinuation<T, Never>? in
            defer { continuation = nil }
            return continuation
        }
        pending?.resume(returning: value)
    }
}

/// 远控身份存储的内存镜像：初值是 App 交来的钥匙串内容，写入同时回传 App 落盘（App 不在时排队）。
nonisolated final class RemoteMirroredSecretStorage: RemoteSecretStorage, @unchecked Sendable {
    private let lock = NSLock()
    private var values: [String: Data]
    /// 每次写入调一次（任意线程）。
    var onSave: (@Sendable (String, Data) -> Void)?

    init(values: [String: Data] = [:]) {
        self.values = values
    }

    func load(_ account: String) throws -> Data? {
        lock.withLock { values[account] }
    }

    func save(_ data: Data, account: String) throws {
        lock.withLock { values[account] = data }
        onSave?(account, data)
    }

    /// App（重新）连上时交来的内容。`keeping` 里的条目是 App 不在时本进程写的、App 还没落盘，以本进程为准。
    func replaceAll(_ fresh: [String: Data], keeping pending: Set<String>) {
        lock.withLock {
            var merged = fresh
            for account in pending { merged[account] = values[account] }
            values = merged
        }
    }
}

/// 中继配置存储的内存镜像（同上）。
nonisolated final class RemoteMirroredSyncedStorage: RemoteSyncedStorage, @unchecked Sendable {
    private let lock = NSLock()
    private var value: Data?
    var onChange: (@Sendable (Data?) -> Void)?

    init(value: Data? = nil) {
        self.value = value
    }

    func loadAll() -> [Data] {
        lock.withLock { value.map { [$0] } ?? [] }
    }

    func save(_ data: Data, account: String) throws {
        lock.withLock { value = data }
        onChange?(data)
    }

    func delete(account: String) throws {
        lock.withLock { value = nil }
        onChange?(nil)
    }

    /// 换成 App 那份，不回传。
    func replace(_ data: Data?) {
        lock.withLock { value = data }
    }
}
