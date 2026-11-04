import CryptoKit
import Foundation
import Observation

/// 本机 shell 的入口：到辅助程序的 XPC 客户端，以及设置页用的健康检查。
///
/// 主程序是沙盒 app，shell 由不带沙盒的内嵌 XPC 服务 `uTermShellAgent.xpc` 拉起（见 `LocalShellAgent`）。
/// 内嵌 XPC 服务由系统在第一次连接时拉起，不需要注册后台项目，也不需要用户授权。
@MainActor
@Observable
final class LocalShellService {
    enum HelperState: Equatable {
        case unknown
        case checking
        /// 能连上，带辅助程序版本号。
        case ok(String)
        case failed(String)
    }

    static let shared = LocalShellService()

    private(set) var helperState: HelperState = .unknown
    @ObservationIgnored let client = LocalShellAgentClient()

    private init() {}

    /// 连一下辅助程序（会把它拉起来），设置页据此显示「正常」或失败原因。
    func checkHelper() async {
        helperState = .checking
        do {
            helperState = .ok(try await client.ping())
        } catch {
            helperState = .failed(error.localizedDescription)
        }
    }
}

nonisolated enum LocalShellError: LocalizedError {
    case agentUnavailable(String)
    case openFailed(String)

    var errorDescription: String? {
        switch self {
        case .agentUnavailable(let reason): return "连不上终端的辅助程序：\(reason)"
        case .openFailed(let reason): return "终端没能启动：\(reason)"
        }
    }
}

/// 到辅助程序的 XPC 连接。任意线程可调；连接断了下次调用时重建（系统会按需把辅助程序拉起来）。
nonisolated final class LocalShellAgentClient: @unchecked Sendable {
    private let lock = NSLock()
    private var connection: NSXPCConnection?

    private func proxy(onError: @escaping @Sendable (Error) -> Void) -> LocalShellAgentProtocol? {
        lock.lock()
        defer { lock.unlock() }
        if connection == nil {
            let made = NSXPCConnection(serviceName: LocalShellAgent.serviceName)
            made.remoteObjectInterface = NSXPCInterface(with: LocalShellAgentProtocol.self)
            let madeID = ObjectIdentifier(made)
            let dropped: @Sendable () -> Void = { [weak self] in self?.dropConnection(madeID) }
            made.invalidationHandler = dropped
            made.interruptionHandler = dropped
            made.resume()
            connection = made
        }
        return connection?.remoteObjectProxyWithErrorHandler(onError) as? LocalShellAgentProtocol
    }

    private func dropConnection(_ dead: ObjectIdentifier) {
        lock.lock()
        if let connection, ObjectIdentifier(connection) == dead { self.connection = nil }
        lock.unlock()
    }

    func invalidate() {
        lock.lock()
        let old = connection
        connection = nil
        lock.unlock()
        old?.invalidate()
    }

    /// 探活，回辅助进程版本号。
    func ping() async throws -> String {
        try await withCheckedThrowingContinuation { continuation in
            let once = LocalShellOnce(continuation)
            guard let agent = proxy(onError: { once.resume(throwing: LocalShellError.agentUnavailable($0.localizedDescription)) }) else {
                once.resume(throwing: LocalShellError.agentUnavailable("无法建立连接"))
                return
            }
            agent.ping { once.resume(returning: $0) }
        }
    }

    /// 连上会话 `id`；还没有就新起一个 shell。
    func openSession(namespace: String, id: UUID, columns: Int, rows: Int,
                     ownsResponsibility: Bool = false) async throws -> FileHandle {
        try await withCheckedThrowingContinuation { continuation in
            let once = LocalShellOnce(continuation)
            guard let agent = proxy(onError: { once.resume(throwing: LocalShellError.agentUnavailable($0.localizedDescription)) }) else {
                once.resume(throwing: LocalShellError.agentUnavailable("无法建立连接"))
                return
            }
            agent.openSession(namespace: namespace, id: id.uuidString, columns: columns, rows: rows,
                              ownsResponsibility: ownsResponsibility) { handle, error in
                once.finish(handle, error: error)
            }
        }
    }

    /// 连上 SSH 会话 `id`；还没有就新起一个 `uterm-ssh`，这时 `control` 非 nil，连接参数要从它交过去。
    func openSSHSession(namespace: String, id: UUID, columns: Int, rows: Int) async throws -> (holder: FileHandle, control: FileHandle?) {
        let box: LocalShellHandlePair = try await withCheckedThrowingContinuation { continuation in
            let once = LocalShellOnce(continuation)
            guard let agent = proxy(onError: { once.resume(throwing: LocalShellError.agentUnavailable($0.localizedDescription)) }) else {
                once.resume(throwing: LocalShellError.agentUnavailable("无法建立连接"))
                return
            }
            agent.openSSHSession(namespace: namespace, id: id.uuidString, columns: columns, rows: rows) { holder, control, error in
                if let holder {
                    once.resume(returning: LocalShellHandlePair(holder: holder, control: control))
                } else {
                    once.resume(throwing: LocalShellError.openFailed(error ?? "未知原因"))
                }
            }
        }
        return (box.holder, box.control)
    }

    /// 只连已有的会话。
    func connectSession(namespace: String, id: UUID) async throws -> FileHandle {
        try await withCheckedThrowingContinuation { continuation in
            let once = LocalShellOnce(continuation)
            guard let agent = proxy(onError: { once.resume(throwing: LocalShellError.agentUnavailable($0.localizedDescription)) }) else {
                once.resume(throwing: LocalShellError.agentUnavailable("无法建立连接"))
                return
            }
            agent.connectSession(namespace: namespace, id: id.uuidString) { handle, error in
                once.finish(handle, error: error)
            }
        }
    }

    func listSessions(namespace: String) async throws -> [UUID] {
        try await withCheckedThrowingContinuation { continuation in
            let once = LocalShellOnce(continuation)
            guard let agent = proxy(onError: { once.resume(throwing: LocalShellError.agentUnavailable($0.localizedDescription)) }) else {
                once.resume(throwing: LocalShellError.agentUnavailable("无法建立连接"))
                return
            }
            agent.listSessions(namespace: namespace) { ids in
                once.resume(returning: ids.compactMap(UUID.init(uuidString:)))
            }
        }
    }
}

nonisolated private struct LocalShellHandlePair: @unchecked Sendable {
    let holder: FileHandle
    let control: FileHandle?
}

/// XPC 的回复与错误回调可能都来（连接断在回复途中），continuation 只能 resume 一次。
nonisolated private final class LocalShellOnce<T: Sendable>: @unchecked Sendable {
    private let lock = NSLock()
    private var continuation: CheckedContinuation<T, Error>?

    init(_ continuation: CheckedContinuation<T, Error>) {
        self.continuation = continuation
    }

    func resume(returning value: T) {
        take()?.resume(returning: value)
    }

    func resume(throwing error: Error) {
        take()?.resume(throwing: error)
    }

    private func take() -> CheckedContinuation<T, Error>? {
        lock.lock()
        defer { lock.unlock() }
        let taken = continuation
        continuation = nil
        return taken
    }
}

nonisolated private extension LocalShellOnce where T == FileHandle {
    func finish(_ handle: FileHandle?, error: String?) {
        if let handle {
            resume(returning: handle)
        } else {
            resume(throwing: LocalShellError.openFailed(error ?? "未知原因"))
        }
    }
}

/// 一组会话的 socket 目录名。正式版一份；Debug 构建按 App 路径各一份：重编同一个工作树能接回，
/// 不同 worktree、调试版和日常用的正式版都互不相通。
nonisolated enum LocalShellNamespace {
    static var current: String {
        #if DEBUG
        let digest = SHA256.hash(data: Data(Bundle.main.bundlePath.utf8))
        return "debug-" + digest.prefix(6).map { String(format: "%02x", $0) }.joined()
        #else
        return "release"
        #endif
    }
}
