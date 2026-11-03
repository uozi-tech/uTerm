import Foundation
import Observation
import ServiceManagement

/// 本机 shell 的入口：注册辅助进程（`SMAppService.agent`）、看它的状态，以及经 XPC 起 / 调 / 结束 shell。
///
/// 主程序是沙盒 app，shell 由不带沙盒的 `uTermShellAgent` 起（见 `LocalShellAgent`）。辅助进程第一次注册时
/// 系统会发「已添加后台项目」通知；有的系统设置下要用户在 系统设置 › 通用 › 登录项与扩展 里打开它才能运行
///（状态 `.requiresApproval`）。
@MainActor
@Observable
final class LocalShellService {
    enum Status: Equatable {
        case notRegistered
        case enabled
        case requiresApproval
        /// 包里找不到 launchd 配置（构建漏嵌，或从不完整的包里跑）。
        case notFound
    }

    static let shared = LocalShellService()

    private(set) var status: Status = .notRegistered
    var lastError: String?

    @ObservationIgnored private let service = SMAppService.agent(plistName: LocalShellAgent.plistName)
    @ObservationIgnored let client = LocalShellAgentClient()

    private init() {
        refresh()
    }

    func refresh() {
        status = switch service.status {
        case .enabled: .enabled
        case .requiresApproval: .requiresApproval
        case .notFound: .notFound
        case .notRegistered: .notRegistered
        @unknown default: .notFound
        }
    }

    /// 注册（幂等）。已注册时什么也不做。
    func register() {
        lastError = nil
        refresh()
        guard status == .notRegistered || status == .notFound else { return }
        do {
            try service.register()
        } catch {
            lastError = "无法注册本机终端的后台项目：\(error.localizedDescription)"
        }
        refresh()
    }

    func unregister() {
        lastError = nil
        client.invalidate()
        guard status != .notRegistered else { return }
        do {
            try service.unregister()
        } catch {
            lastError = "无法移除本机终端的后台项目：\(error.localizedDescription)"
        }
        refresh()
    }

    func openLoginItemsSettings() {
        SMAppService.openSystemSettingsLoginItems()
    }

    /// 开 shell 之前的检查：没注册就注册；仍不可用时给出用户能照着做的说明。
    func readinessProblem() -> String? {
        register()
        switch status {
        case .enabled: return nil
        case .requiresApproval:
            return "需要在 Mac 的 系统设置 › 通用 › 登录项与扩展 里打开 uTerm 的后台项目，本机终端才能启动"
        case .notFound:
            return "这份 uTerm 里缺少本机终端的辅助程序，请重新安装 uTerm"
        case .notRegistered:
            return lastError ?? "本机终端的后台项目没能注册"
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

/// 到辅助进程的 XPC 连接。任意线程可调；连接断了下次调用时重建（launchd 会按需把辅助进程拉起来）。
nonisolated final class LocalShellAgentClient: @unchecked Sendable {
    private let lock = NSLock()
    private var connection: NSXPCConnection?

    private func proxy(onError: @escaping @Sendable (Error) -> Void) -> LocalShellAgentProtocol? {
        lock.lock()
        defer { lock.unlock() }
        if connection == nil {
            let made = NSXPCConnection(machServiceName: LocalShellAgent.machServiceName, options: [])
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
