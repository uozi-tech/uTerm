import Foundation

/// App 启动时清点上次留下的 SSH 会话，把它们交回原来的窗口。
///
/// 真值在 holder 那边（socket 目录 + 存在里面的归属），窗格 id 就是会话 id。工作区窗口自己的快照里也记着会话 id，
/// 恢复时直接接回；这里兜底快照没来得及存的、以及系统没有恢复的窗口。
@MainActor
final class SSHSessionRestorer {
    static let shared = SSHSessionRestorer()

    struct Session: Equatable, Sendable {
        let id: UUID
        let serverID: UUID
        let title: String
        let order: Double
    }

    private struct PendingWindow {
        let kind: String
        var sessions: [Session]
    }

    private let client: LocalShellAgentClient
    private let namespace: String
    private let gateTimeout: Duration
    private let reopenDelay: Duration
    private var openWindow: (@MainActor (_ kind: String, _ windowID: UUID, _ serverID: UUID) -> Void)?
    private var knownServerIDs: (@MainActor () -> Set<UUID>)?
    private var inventory: Task<Void, Never>?
    private var pending: [UUID: PendingWindow] = [:]
    /// 已清点、还没走完接回的会话。手机接入前等它们。
    private var unsettled: Set<UUID> = []
    private var didOpenWindows = false

    init(client: LocalShellAgentClient = LocalShellService.shared.client, namespace: String = SSHSessionNamespace.current,
         gateTimeout: Duration = .seconds(15), reopenDelay: Duration = .milliseconds(500)) {
        self.client = client
        self.namespace = namespace
        self.gateTimeout = gateTimeout
        self.reopenDelay = reopenDelay
    }

    func install(knownServerIDs: @escaping @MainActor () -> Set<UUID>,
                 openWindow: @escaping @MainActor (_ kind: String, _ windowID: UUID, _ serverID: UUID) -> Void) {
        self.knownServerIDs = knownServerIDs
        self.openWindow = openWindow
    }

    /// 幂等。`install` 之前不开窗口，装好之后再调一次。
    func restoreIfNeeded() {
        guard !BackgroundLaunchMode.isRunningInTestHost, openWindow != nil, !didOpenWindows else { return }
        didOpenWindows = true
        Task {
            await takeInventory()
            await openUnclaimedWindows()
        }
    }

    /// 窗口出现时领走属于自己的会话，先于「没有标签就开一个」。可能赶在 `install` 之前，所以自己也会触发清点。
    func claim(windowID: UUID) async -> [Session] {
        guard !BackgroundLaunchMode.isRunningInTestHost else { return [] }
        await takeInventory()
        return takePending(windowID: windowID)
    }

    /// 只清点一次；同时到来的调用等同一次结果。
    func takeInventory() async {
        if inventory == nil {
            inventory = Task { await runInventory() }
        }
        await inventory?.value
    }

    func takePending(windowID: UUID) -> [Session] {
        pending.removeValue(forKey: windowID)?.sessions.sorted { $0.order < $1.order } ?? []
    }

    /// 窗格的连接走完了（接回、失败都算）。
    func settled(_ id: UUID) {
        unsettled.remove(id)
    }

    /// 接回完成后返回。手机接入前等它，否则会看到一份缺了终端的列表。
    func finished() async {
        guard !BackgroundLaunchMode.isRunningInTestHost, openWindow != nil else { return }
        restoreIfNeeded()
        await takeInventory()
        let deadline = ContinuousClock.now + gateTimeout
        while !(unsettled.isEmpty && pending.isEmpty), ContinuousClock.now < deadline {
            try? await Task.sleep(for: .milliseconds(50))
        }
    }

    private func runInventory() async {
        let client = client
        let namespace = namespace
        guard let ids = try? await client.listSessions(namespace: namespace), !ids.isEmpty else { return }
        let found = await withTaskGroup(of: (UUID, HolderHelloReply?).self) { group in
            for id in ids {
                group.addTask { (id, await HolderProbe.hello(id, client: client, namespace: namespace)) }
            }
            var results: [(UUID, HolderHelloReply?)] = []
            for await result in group { results.append(result) }
            return results
        }
        // 数据库还没载入（空集合）时不判「服务器已删除」：那样会把活着的会话杀掉。
        let known = knownServerIDs?() ?? []
        for (id, hello) in found {
            guard let hello else { continue }
            let attributes: SSHSessionAttributes
            if hello.attributes.isEmpty {
                // 归属没来得及写：没有地方放它。
                await HolderProbe.terminate(id, client: client, namespace: namespace)
                continue
            } else if let decoded = try? JSONDecoder().decode(SSHSessionAttributes.self, from: Data(hello.attributes)) {
                attributes = decoded
            } else {
                // 写了但解不开（别的版本的格式）：不替用户杀掉远端会话，留给写它的那个版本。
                AppLogger.error("SSH 会话 \(id) 的归属解不开，跳过恢复", category: "ssh")
                continue
            }
            guard known.isEmpty || known.contains(attributes.serverID) else {
                // 服务器已经删了：没有地方放它。
                await HolderProbe.terminate(id, client: client, namespace: namespace)
                continue
            }
            let session = Session(id: id, serverID: attributes.serverID, title: attributes.title, order: attributes.order)
            pending[attributes.windowID, default: PendingWindow(kind: attributes.windowKind, sessions: [])].sessions.append(session)
            unsettled.insert(id)
        }
    }

    /// `open(value:)` 遇到同值的窗口只是带到前台。系统恢复的旧窗口正在关闭时会抢走这次打开，会话就没人领了，
    /// 等它关完再开一次。
    private func openUnclaimedWindows() async {
        for attempt in 0..<4 where !pending.isEmpty {
            if attempt > 0 { try? await Task.sleep(for: reopenDelay) }
            for (windowID, window) in pending {
                if let first = window.sessions.min(by: { $0.order < $1.order }) {
                    openWindow?(window.kind, windowID, first.serverID)
                }
            }
        }
    }
}

/// 只问 hello，不接入：接入会把 holder 的「当前客户端」换掉。
nonisolated enum HolderProbe {
    static func hello(_ id: UUID, client: LocalShellAgentClient, namespace: String) async -> HolderHelloReply? {
        guard let handle = try? await client.connectSession(namespace: namespace, id: id) else { return nil }
        let connection = HolderConnection(handle)
        defer { connection.close() }
        return await exchangeHello(connection)
    }

    /// 等到 hello 回复才发结束请求。holder 校验对端身份要连接还在：发完就关的话，它还没 accept 就会拒掉连接，请求跟着丢了。
    static func terminate(_ id: UUID, client: LocalShellAgentClient, namespace: String) async {
        guard let handle = try? await client.connectSession(namespace: namespace, id: id) else { return }
        let connection = HolderConnection(handle)
        _ = await exchangeHello(connection)
        connection.send(HolderFrame(.terminate))
        connection.close()
    }

    private static func exchangeHello(_ connection: HolderConnection) async -> HolderHelloReply? {
        await withCheckedContinuation { continuation in
            let once = HolderHelloOnce(continuation)
            connection.onFrame = { frame in
                if frame.kind == .helloReply { once.finish(HolderHelloReply(decoding: frame.payload)) }
            }
            connection.onClosed = { once.finish(nil) }
            connection.start()
            connection.send(HolderFrame(.hello))
            DispatchQueue.global().asyncAfter(deadline: .now() + 3) { once.finish(nil) }
        }
    }
}

nonisolated private final class HolderHelloOnce: @unchecked Sendable {
    private let lock = NSLock()
    private var continuation: CheckedContinuation<HolderHelloReply?, Never>?

    init(_ continuation: CheckedContinuation<HolderHelloReply?, Never>) {
        self.continuation = continuation
    }

    func finish(_ reply: HolderHelloReply?) {
        lock.lock()
        let taken = continuation
        continuation = nil
        lock.unlock()
        taken?.resume(returning: reply)
    }
}
