import Foundation
import SwiftData

/// 一次动作失败的统一载体。抛给 `ControlHandler` 的分发层，由它翻成 `ControlResponse`。
///
/// `hosts` 用于 `host_ambiguous` —— 把候选主机（带 UUID）一并回给 CLI，
/// 技能文档教模型改用 UUID 重试。
nonisolated struct ControlFailure: Error, Sendable {
    let code: ControlErrorCode
    let message: String
    let hosts: [ControlHostSnapshot]?

    init(code: ControlErrorCode, message: String, hosts: [ControlHostSnapshot]? = nil) {
        self.code = code
        self.message = message
        self.hosts = hosts
    }

    static func notImplemented(_ what: String) -> ControlFailure {
        ControlFailure(code: .not_implemented, message: "\(what) 尚未实现")
    }
}

/// 把一条 IPC 请求翻译成对 uTerm 自己那套原语（`SSHCommandExecutor` / `SFTPProviding` /
/// `ForwardingCoordinator` / `TerminalSessionRegistry`）的调用。
///
/// 三条硬约束：
/// 1. **凭据不出应用**。CLI 只能按名字 / UUID 指一台**已保存**的主机，密码、私钥、口令
///    全程留在钥匙串里。协议里根本没有导出凭据的字段。
/// 2. **门禁三层**。主开关 → 改动开关 → `ServerProfile.sftpOnly` 主机级硬规则，
///    顺序由 `handle(_:)` 统一执行，各组 extension 不重复判、也不许绕。
/// 3. **不碰窗口态**。CLI 用自己的 `ControlConnectionPool` 持有连接：关窗口不影响 CLI，
///    CLI 也不改任何窗口的当前目录 / 标签。
@MainActor
final class ControlHandler {

    /// handler 运行所需的一切。全部由 app 在启动时注入（`uTermApp`），
    /// 这样测试可以塞 mock，`shared` 也不会自己去建第二个 `ModelContainer`。
    struct Dependencies {
        let settings: ControlSettings
        let modelContainer: ModelContainer
        let forwardingCoordinator: ForwardingCoordinator
        let pool: any ControlConnectionPooling
        let registry: TerminalSessionRegistry
        /// 中继配置的落点（远控服务）。测试里可以不给，`relay-*` 动作就回 `app_not_ready`。
        var relay: (any ControlRelayManaging)? = nil
        /// 配对过的 Mac（`macs` / `mac-*`）。测试里可以不给，这组动作就回 `app_not_ready`。
        var macs: (any ControlRemoteMacs)? = nil
    }

    /// `ControlServer` 默认 requestHandler 指向的实例。app 起来后调 `attach(_:)` 注入依赖；
    /// 注入前一律回 `app_not_ready`（不是崩溃）。
    static let shared = ControlHandler()

    private(set) var dependencies: Dependencies?

    /// 未接线的空实例（`shared` 用）。
    init() {}

    /// 全量注入。测试与 app 都走这条。
    init(
        settings: ControlSettings,
        modelContainer: ModelContainer,
        forwardingCoordinator: ForwardingCoordinator,
        pool: any ControlConnectionPooling,
        registry: TerminalSessionRegistry,
        relay: (any ControlRelayManaging)? = nil,
        macs: (any ControlRemoteMacs)? = nil
    ) {
        dependencies = Dependencies(
            settings: settings,
            modelContainer: modelContainer,
            forwardingCoordinator: forwardingCoordinator,
            pool: pool,
            registry: registry,
            relay: relay,
            macs: macs
        )
    }

    func attach(_ dependencies: Dependencies) {
        self.dependencies = dependencies
    }

    // MARK: - 入口（门禁 + 分发）

    /// 门禁顺序：`requiresEnabled` → `control_disabled`；`requiresMutation` →
    /// `mutations_disabled`；然后按 `action.group` 分发。
    /// 主机级 `sftpOnly` 硬规则（`requiresExecCapableHost`）在主机解析之后才能判，
    /// 由各组 extension 在 `resolveHost` 之后立刻执行。
    func handle(_ request: ControlRequest) async -> ControlResponse {
        guard let deps = dependencies else {
            return .failure(
                id: request.id,
                code: .app_not_ready,
                message: "uTerm 尚未完成启动"
            )
        }

        // ping 永远可用 —— 否则客户端连「开关关着」都问不出来。
        if request.action == .ping {
            return .success(
                id: request.id,
                message: "uTerm 正在运行",
                app: await appInfo(deps)
            )
        }

        guard !request.action.requiresEnabled || deps.settings.isEnabled else {
            return .failure(
                id: request.id,
                code: .control_disabled,
                message: "命令行接口未启用：在 uTerm「设置 › 命令行与技能」里打开「启用命令行接口」",
                app: await appInfo(deps)
            )
        }

        guard !request.action.requiresMutation || deps.settings.allowMutations else {
            return .failure(
                id: request.id,
                code: .mutations_disabled,
                message: "写入未启用：在 uTerm「设置 › 命令行与技能」里打开「允许执行命令与写入」",
                app: await appInfo(deps)
            )
        }

        do {
            switch request.action.group {
            case .hosts:
                return try await handleHosts(request, deps)
            case .exec:
                return try await handleRun(request, deps)
            case .sftp:
                return try await handleSFTP(request, deps)
            case .forward:
                return try await handleForward(request, deps)
            case .terminal:
                return try await handleTerminal(request, deps)
            case .relay:
                return try await handleRelay(request, deps)
            case .mac:
                return try await handleMac(request, deps)
            case .misc:
                return try await handleMisc(request, deps)
            }
        } catch let failure as ControlFailure {
            return .failure(
                id: request.id,
                code: failure.code,
                message: failure.message,
                hosts: await decorated(failure.hosts, deps)
            )
        } catch {
            return .failure(
                id: request.id,
                code: .operation_failed,
                message: error.localizedDescription
            )
        }
    }

    /// 给失败响应里的候选主机补 `cliConnected`。
    ///
    /// `resolveHost` 是同步的（`throws(ControlFailure)`，各组都在它之后才 await），
    /// 问不到连接池；而这里是 async 收口，一次 `await` 就能给所有组把这一列填对。
    private func decorated(
        _ hosts: [ControlHostSnapshot]?,
        _ deps: Dependencies
    ) async -> [ControlHostSnapshot]? {
        guard let hosts, !hosts.isEmpty else { return hosts }
        let held = Set(await deps.pool.heldHostIDs())
        return hosts.map { snapshot in
            var updated = snapshot
            updated.cliConnected = UUID(uuidString: snapshot.id).map(held.contains) ?? false
            return updated
        }
    }

    // MARK: - misc 组（ping 在上面已短路，这里只剩 disconnect）

    private func handleMisc(
        _ request: ControlRequest,
        _ deps: Dependencies
    ) async throws -> ControlResponse {
        switch request.action {
        case .ping:
            return .success(id: request.id, message: "uTerm 正在运行", app: await appInfo(deps))
        case .disconnect:
            // 解析主机 → `deps.pool.disconnect(hostID:)`；无 `--host` 时全部释放。
            // 实现在 `ControlHandler+Hosts.swift`（它按主机走，与主机组共用解析入口）。
            return try await handleDisconnect(request, deps)
        default:
            throw ControlFailure(
                code: .invalid_request,
                message: "动作 \(request.action.rawValue) 不属于 misc 组"
            )
        }
    }

    // MARK: - ping 载荷

    func appInfo(_ deps: Dependencies) async -> ControlAppInfo {
        let info = Bundle.main.infoDictionary
        let heldIDs = await deps.pool.heldHostIDs()
        let names = hostNames(for: heldIDs, deps)
        return ControlAppInfo(
            name: "uTerm",
            version: info?["CFBundleShortVersionString"] as? String ?? "",
            build: info?["CFBundleVersion"] as? String ?? "",
            socket: ControlProtocol.socketURL.path,
            controlEnabled: deps.settings.isEnabled,
            mutationsEnabled: deps.settings.allowMutations,
            openHosts: names
        )
    }

    /// 把连接池持有的 hostID 翻成主机名。取不到（档案已删）就退回 UUID 串。
    private func hostNames(for ids: [UUID], _ deps: Dependencies) -> [String] {
        guard !ids.isEmpty else { return [] }
        let wanted = Set(ids)
        let profiles = (try? deps.modelContainer.mainContext
            .fetch(FetchDescriptor<ServerProfile>())) ?? []
        var byID: [UUID: String] = [:]
        for profile in profiles where wanted.contains(profile.id) {
            byID[profile.id] = profile.name
        }
        return ids.map { byID[$0] ?? $0.uuidString }.sorted()
    }
}
