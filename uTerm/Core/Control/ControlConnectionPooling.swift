import Foundation
import SwiftData

/// CLI 建连所需的一切，**已解析成 `Sendable` 值**。
///
/// 这是 MainActor 与连接池 actor 之间的唯一桥：认证材料在 MainActor 上从
/// `ServerProfile` + 钥匙串解析出来（`SSHAuthResolver.resolveForConnect`），之后连接闭包只捕获
/// 这些值，不捕获任何 MainActor 隔离状态 —— 与 `WorkspaceCommandExecutorFactory.make`
/// 的做法一致。
nonisolated struct HostConnectionSpec: Sendable {
    /// `ServerProfile.id`。连接池按它做键。
    let id: UUID
    /// 主机档案名（日志 / `ping.openHosts` 用）。
    let name: String
    /// host / port / 跳板机端点。
    let profile: SSHConnection.ProfileSnapshot
    let auth: ResolvedAuth
    /// 跳板机的认证材料；无跳板机为 nil。
    let jumpAuth: ResolvedAuth?
    /// 建连闭包在池 actor 里构造 `HostKeyVerifier(modelContainer:)` 要用它。
    /// `ModelContainer` 是 `Sendable`，可以跨隔离域带；`ModelContext` 不是，绝不能带。
    let container: ModelContainer

    init(
        id: UUID,
        name: String,
        profile: SSHConnection.ProfileSnapshot,
        auth: ResolvedAuth,
        jumpAuth: ResolvedAuth?,
        container: ModelContainer
    ) {
        self.id = id
        self.name = name
        self.profile = profile
        self.auth = auth
        self.jumpAuth = jumpAuth
        self.container = container
    }

    /// **仅测试**用的钥匙串注入点：非 nil 时替代真实的 `KeychainStore`。
    /// 生产路径永远是 nil —— 没有它，`ControlHandlerTests` 里的 `run` 根本走不到连接池
    /// （测试宿主的钥匙串里当然没有任何主机的密码）。放在 MainActor 上（`resolve` 本来
    /// 就是 MainActor 方法），不需要 `nonisolated(unsafe)` 全局。
    @MainActor static var keychainOverride: (any KeychainReading)?

    /// 在 MainActor 上把一台主机解析成可跨隔离域传递的建连输入。
    ///
    /// `KeychainStore()` → `SSHConnection.ProfileSnapshot(profile)` →
    /// `SSHAuthResolver.resolveForConnect(profile:keychain:)`（目标 + 跳板机，跳板机缺凭据报错；
    /// 与终端 / 端口转发 / Agent 同一条规则）。
    /// 解析失败（钥匙串里没有密码 / 私钥，或钥匙串本身读不了）抛
    /// `ControlConnectError.authFailed` —— handler 把它翻成 `auth_failed`。
    @MainActor
    static func resolve(
        profile: ServerProfile,
        container: ModelContainer
    ) throws -> HostConnectionSpec {
        let keychain: any KeychainReading = keychainOverride ?? KeychainStore()
        let snapshot = SSHConnection.ProfileSnapshot(profile)
        let resolved: (auth: ResolvedAuth, jump: ResolvedAuth?)
        do {
            resolved = try SSHAuthResolver.resolveForConnect(profile: profile, keychain: keychain)
        } catch {
            throw ControlConnectError.authFailed(FriendlyError.describe(error))
        }
        let displayName = profile.name.isEmpty ? profile.host : profile.name
        return HostConnectionSpec(
            id: profile.id,
            name: displayName,
            profile: snapshot,
            auth: resolved.auth,
            jumpAuth: resolved.jump,
            container: container
        )
    }
}

/// 连接池建连失败的分类。三种主机密钥状态各自带指纹，供 handler 翻成
/// `host_key_unknown` / `host_key_changed` 并把指纹回给 CLI。
nonisolated enum ControlConnectError: Error, Sendable {
    /// 首连、信任库里没有这台主机的密钥。**绝不自动 TOFU** —— 拒绝并回指纹，
    /// 用户显式 `trust --fingerprint <值>` 才写 `KnownHost`。
    case hostKeyUnknown(fingerprint: String, algorithm: String)
    /// 信任库里有记录但对不上。即便 mutation 开着也不给 CLI 覆盖，必须回界面处理
    /// —— 这是中间人风险的最后一道闸。
    case hostKeyChanged(fingerprint: String, algorithm: String)
    case connectFailed(String)
    case authFailed(String)
    /// 建连**成功了**，但这条连接刚建好就没人认领 —— 建连期间该主机被
    /// `disconnect` / `disconnectAll` 释放（用户关了主开关、或显式断开）。
    ///
    /// 单独一个 case 而不是塞进 `connectFailed`：网络、认证、主机密钥全都没问题，
    /// 报成「连接失败」会让人 / 模型去查根本不存在的网络故障。重试一次就好。
    case released(String)
}

extension ControlConnectError {
    /// 翻成协议错误码。
    var code: ControlErrorCode {
        switch self {
        case .hostKeyUnknown: return .host_key_unknown
        case .hostKeyChanged: return .host_key_changed
        case .connectFailed: return .connect_failed
        case .authFailed: return .auth_failed
        // 「稍后重试」语义，回 `server_busy` —— 客户端对这个码有退避重试。
        case .released: return .server_busy
        }
    }

    /// 面向模型 / 用户的文案。主机密钥两态把指纹摆出来，并写清下一步该干什么。
    func message(host: String) -> String {
        switch self {
        case .hostKeyUnknown(let fingerprint, _):
            return String(localized: "主机「\(host)」的密钥尚未信任（\(fingerprint)）。请让用户核对指纹，确认无误后跑 `utermctl trust -H \(host) --fingerprint \(fingerprint)`。")
        case .hostKeyChanged(let fingerprint, _):
            return String(localized: "主机「\(host)」的密钥与信任库里的记录不一致（当前 \(fingerprint)）。这可能是中间人攻击。CLI 不允许覆盖，请到 uTerm 界面里连接一次并由用户处理。")
        case .connectFailed(let reason):
            return String(localized: "连接「\(host)」失败：\(reason)")
        case .authFailed(let reason):
            return String(localized: "「\(host)」认证失败：\(reason)")
        case .released(let reason):
            return String(localized: "「\(host)」的连接在建立过程中被释放（\(reason)），请重试。")
        }
    }

    /// 换一条连接再试可能就好了（网络抖动、sshd 忙、建连期间被释放）。认证失败、主机密钥问题不在此列。
    var isRetryableBorrowFailure: Bool {
        switch self {
        case .connectFailed, .released: return true
        case .authFailed, .hostKeyUnknown, .hostKeyChanged: return false
        }
    }

    /// 主机密钥两态里的指纹（其余为 nil）。
    var fingerprint: String? {
        switch self {
        case .hostKeyUnknown(let fingerprint, _), .hostKeyChanged(let fingerprint, _):
            return fingerprint
        default:
            return nil
        }
    }

    /// 主机密钥两态里的算法（拿不到时是空串 → 快照里填 nil）。
    var algorithm: String? {
        switch self {
        case .hostKeyUnknown(_, let algorithm), .hostKeyChanged(_, let algorithm):
            return algorithm.isEmpty ? nil : algorithm
        default:
            return nil
        }
    }
}

/// 一台主机的 SFTP 通道全忙，排队等到超时。
///
/// 借不到通道**不是**建连失败：链路好好的，只是这台主机的名额都被别的传输占着。
/// 有上限地等（默认 90 s，短于 `ControlServer` 的 120 s 静默预算）而不是无限等 ——
/// 无限等的后果是请求挂到服务端超时，客户端拿到 `handler_timeout`，既看不出原因也
/// 一直占着一个传输槽位。
///
/// TODO（协议侧 `server_busy` 落地后）：handler 把它映射成 `ControlErrorCode.server_busy`；
/// 现在先落 `operation_failed` + 明确 message。
nonisolated struct SFTPChannelsBusyError: Error, Sendable, Equatable {
    /// 每主机的通道上限（`ControlConnectionPool.maxSFTPChannelsPerHost`）。
    let limit: Int
    /// 等了多少秒才放弃。
    let waitedSeconds: Double

    func message(host: String) -> String {
        String(localized: "主机「\(host)」的 SFTP 通道已满（\(limit) 条全在传输中），等待 \(Int(waitedSeconds.rounded())) 秒仍未排到，请稍后重试。")
    }
}

/// 池内一台主机的 exec 通道。生产实现是 `ReusableSSHConnection`（断线自动重连），
/// 测试注入假的 —— 池本身不认识 SSH，只管持有 / 复用 / 到点关闭。
nonisolated protocol ControlExecChannel: Sendable {
    func exec(_ command: String) async throws -> String
    /// 流式 exec：每到一块输出回调一次，命令结束才返回（`run` 的静默看门狗靠它）。
    func execStreaming(_ command: String, onOutput: @escaping @Sendable (Data) -> Void) async throws
    func close() async
}

extension ControlExecChannel {
    /// 只会整段返回的通道（测试替身）：跑完一次性交付。
    func execStreaming(_ command: String, onOutput: @escaping @Sendable (Data) -> Void) async throws {
        onOutput(Data(try await exec(command).utf8))
    }
}

extension ReusableSSHConnection: ControlExecChannel {}

/// CLI 自己的连接持有面。
///
/// uTerm 没有全局连接池（exec 走 `WorkspaceCommandExecutorFactory.make` 每窗一份），
/// 所以 CLI 需要一份**与窗口无关**的：关窗口不影响 CLI 持有，CLI 也不动任何窗口的状态。
///
/// 约定：
/// - 懒建 —— 第一次 `run` 才建 exec 连接，第一次 `sftp-*` 才建 SFTP 会话，两者独立
///   （`SFTPProviding.exec` 拿不到退出码，不能拿来跑 `run`）。
/// - 空闲 10 分钟自动 `close()`；`disconnect(hostID:)` 显式释放；主开关关闭时
///   `disconnectAll()` 全部释放。
protocol ControlConnectionPooling: Actor {
    /// 取（必要时建）该主机的命令执行器，输出裁剪用协议默认值。
    func executor(for host: HostConnectionSpec) async throws -> SSHCommandExecutor
    /// 取（必要时建）该主机的命令执行器，输出裁剪按本次请求给定。
    /// 连接是复用的，裁剪参数只影响返回的这个执行器。
    func executor(
        for host: HostConnectionSpec,
        maxLines: Int,
        maxBytes: Int
    ) async throws -> SSHCommandExecutor
    /// **借**一条该主机的 SFTP 会话（必要时新建；到每主机上限则**有上限地**等待归还，
    /// 等不到抛 `SFTPChannelsBusyError`）。
    /// 必须与 `returnSFTP(_:for:)` 配对 —— 直接用 `withSFTP(for:_:)` 最不容易漏还。
    func borrowSFTP(for host: HostConnectionSpec) async throws -> any SFTPProviding
    /// 归还一条借出的 SFTP 会话。重复归还、或归还一条已被释放的会话都是安全的。
    func returnSFTP(_ session: any SFTPProviding, for hostID: UUID) async
    /// 借出的会话用坏了（传输中途出错）：关掉并让出名额，**不**放回空闲队列 —— 放回去
    /// 下一个借用者拿到的还是一条死会话。
    func discardSFTP(_ session: any SFTPProviding, for hostID: UUID) async
    /// 松开对某主机的 exec / SFTP 持有。
    func disconnect(hostID: UUID) async
    /// 释放全部持有（主开关关闭 / app 退出）。
    func disconnectAll() async
    /// 当前持有的主机 id（喂 `ping.openHosts` 与 `hosts.cliConnected`）。
    func heldHostIDs() async -> [UUID]

    /// 最近一次该主机建连时被拒的主机密钥挑战（`trust` 据此核对指纹）。
    /// 没有挑战说明还没跑过会触发建连的动作，`trust` 此时应回 `invalid_request`。
    func lastHostKeyChallenge(hostID: UUID) async -> HostKeyChallenge?

    /// 登记一次**不走连接池**的建连拿到的主机密钥挑战。
    ///
    /// `forward-start` 用的是 `ForwardingCoordinator` 自己的专用连接（不经池），
    /// 挑战落在它临时造的 `HostKeyChallengeRelay` 上。不补这一笔的话，后续
    /// `trust --fingerprint <值>` 在池里找不到可核对的挑战，只能回 `invalid_request`
    /// —— 技能文档教模型走的「拿指纹 → trust → 重试」在转发这条路上就断了。
    func recordChallenge(hostID: UUID, _ challenge: HostKeyChallenge) async

    /// 按**钉住的指纹**信任一台主机的密钥：重新握手，只有服务器出示的指纹与
    /// `fingerprint` 逐字相同才批准并写 `KnownHost`（走 `HostKeyVerifier` 的 TOFU 路径）。
    /// 指纹不符抛 `ControlConnectError.hostKeyChanged` —— 绝不盲信。
    func trustHostKey(host: HostConnectionSpec, fingerprint: String) async throws
}

extension ControlConnectionPooling {

    /// 借 → 用 → 还，一条路上无论抛不抛错都归还。
    ///
    /// `nonisolated` 是刻意的：借还两步各自 hop 进池 actor，`body` 留在**调用方**的
    /// 隔离域里跑（模块开了 `SWIFT_APPROACHABLE_CONCURRENCY`，nonisolated async
    /// 函数继承调用方 actor）。否则一整趟传输会把池 actor 占死，其他主机的借还全被堵住。
    nonisolated func withSFTP<T>(
        for host: HostConnectionSpec,
        _ body: (any SFTPProviding) async throws -> T
    ) async throws -> T {
        let session = try await borrowSFTP(for: host)
        do {
            let value = try await body(session)
            await returnSFTP(session, for: host.id)
            return value
        } catch {
            await returnSFTP(session, for: host.id)
            throw error
        }
    }

    /// 缺省（测试替身）：当成普通归还。
    func discardSFTP(_ session: any SFTPProviding, for hostID: UUID) async {
        await returnSFTP(session, for: hostID)
    }

    func executor(for host: HostConnectionSpec) async throws -> SSHCommandExecutor {
        try await executor(
            for: host,
            maxLines: ControlProtocol.defaultMaxLines,
            maxBytes: ControlProtocol.defaultMaxBytes
        )
    }
}
