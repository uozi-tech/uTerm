import Foundation
import Observation

/// 本机 shell 的入口：到辅助程序的 XPC 客户端，以及设置页用的健康检查。
///
/// 主程序是沙盒 app，shell 由不带沙盒的内嵌 XPC 服务 `uTermShellAgent.xpc` 起（见 `LocalShellAgent`）。
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

/// 一个 shell：伪终端主端（主程序直接读写）与进程号（调尺寸、结束时交给辅助进程）。
nonisolated struct LocalShellHandle: @unchecked Sendable {
    let master: FileHandle
    let pid: Int32
}

nonisolated enum LocalShellError: LocalizedError {
    case agentUnavailable(String)
    case openFailed(String)

    var errorDescription: String? {
        switch self {
        case .agentUnavailable(let reason): return "连不上本机终端的辅助程序：\(reason)"
        case .openFailed(let reason): return "本机终端没能启动：\(reason)"
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

    func openShell(columns: Int, rows: Int) async throws -> LocalShellHandle {
        try await withCheckedThrowingContinuation { continuation in
            let once = LocalShellOnce(continuation)
            guard let agent = proxy(onError: { once.resume(throwing: LocalShellError.agentUnavailable($0.localizedDescription)) }) else {
                once.resume(throwing: LocalShellError.agentUnavailable("无法建立连接"))
                return
            }
            agent.openShell(columns: columns, rows: rows) { handle, pid, error in
                if let handle, pid > 0 {
                    once.resume(returning: LocalShellHandle(master: handle, pid: pid))
                } else {
                    once.resume(throwing: LocalShellError.openFailed(error ?? "未知原因"))
                }
            }
        }
    }

    func resize(pid: Int32, columns: Int, rows: Int) {
        proxy(onError: { _ in })?.resize(pid: pid, columns: columns, rows: rows)
    }

    func terminate(pid: Int32) {
        proxy(onError: { _ in })?.terminate(pid: pid)
    }
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
