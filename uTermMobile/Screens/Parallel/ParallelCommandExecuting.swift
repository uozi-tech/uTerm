import Foundation
import SwiftData

/// 并行执行的执行器缝：**按主机起一条会话、按节拍回吐输出行、可取消、可失败**。
///
/// 为什么要这条缝：`ParallelRunController` 原本在 `makeExecTarget` 里直接调
/// `WorkspaceCommandExecutorFactory.make(server:container:…)` 现造真连接，于是
/// 整屏（`ParallelRunView`）在测试里只能连真机器才跑得起来 —— 探针挂不上，
/// 「24 台一起吐输出时主线程还剩多少」这类账根本量不到。
///
/// 生产实现是 `SSHParallelExecutor`（原样包住那个工厂），探针注入
/// `MobileFakeParallelRun`。**协议之外的生产路径逐行未改**：真实会话不使用
/// `onLines`（SSH exec 只有命令跑完才拿得到完整输出），控制器照旧从返回的
/// `CommandResult` 切行追加。
@MainActor
protocol ParallelCommandExecuting {
    /// 为一台主机开一条执行会话。真实实现在这里解析认证材料、准备复用连接；
    /// 解析失败不抛错，而是把错误文本放进会话的 `setupErrorText`（与抽协议前
    /// `ExecTarget.setupErrorText` 的语义一致）。
    func makeSession(for profile: ServerProfile, trustNewKeys: Bool) -> ParallelExecutionSession
}

/// 一台主机上的一次执行会话（同台内多条命令串行复用同一条连接）。
///
/// - **可失败**：`run` 抛错 = 执行 / 连接失败，错误文本进 `ExecOutcome.errorText`；
///   建会话就失败的（认证材料解析不出来）走 `setupErrorText`。
/// - **可超时**：真实会话在 `SupervisedExec` 看门狗下跑，连续太久没输出 / 超总时长就终止
///   远端进程组并抛 `ParallelExecutionStalled`，控制器按「执行超时」收尾（不是连不上）。
/// - **可取消**：`run` 应当尊重 `Task.isCancelled`（真实实现靠 NIO 的取消传播，
///   假实现靠 `Task.sleep` 抛 `CancellationError`）。
/// - **按节拍回吐行**：`onLines` 在命令**仍在执行**时把已产出的行回吐给调用方。
nonisolated protocol ParallelExecutionSession: Sendable {
    /// 建会话阶段就失败的原因（认证材料解析不出来等）。非 nil 时控制器不会真的执行，
    /// 直接按「无法连接」收尾 —— 与抽协议前 `executor == nil` 的那条分支等价。
    var setupErrorText: String? { get }

    /// 跑一条命令。
    ///
    /// - Parameter onLines: 按节拍回吐输出行。**真实 SSH 从不调用它**（`exec` 只有
    ///   命令结束才拿得到完整输出），控制器于是照旧从返回的 `CommandResult` 切行；
    ///   假实现按节拍逐批吐，控制器据「这次 run 吐过行没有」决定不要再切一次，
    ///   避免同一批输出被追加两遍。
    /// - Returns: 完整输出与退出码（供退出码判定与 AI 提示词使用）。
    func run(_ command: String,
             onLines: @escaping @Sendable ([PLine]) -> Void) async throws -> CommandResult

    /// 读取并清空本次建连记录下的 host-key 质询（有则 UI 摆指纹 +「信任并重试」）。
    func takeHostKeyChallenge() -> HostKeyChallenge?

    /// 该台跑完后释放连接。
    func close() async
}

// MARK: - 生产实现

/// 真实执行器：`WorkspaceCommandExecutorFactory` + 复用连接 + host-key sink。
struct SSHParallelExecutor: ParallelCommandExecuting {
    let container: ModelContainer

    func makeSession(for profile: ServerProfile, trustNewKeys: Bool) -> ParallelExecutionSession {
        do {
            let made = try WorkspaceCommandExecutorFactory.make(
                server: profile, container: container,
                trustNewKeys: trustNewKeys, reuseConnection: true)
            return SSHParallelSession(executor: made.executor,
                                      hostKeyChallenges: made.hostKeyChallenges,
                                      connection: made.connection,
                                      setupErrorText: nil)
        } catch {
            return SSHParallelSession(executor: nil, hostKeyChallenges: nil,
                                      connection: nil,
                                      setupErrorText: error.localizedDescription)
        }
    }
}

/// 一台主机的真实会话。字段与抽协议前的 `ExecTarget` 逐个对应。
nonisolated struct SSHParallelSession: ParallelExecutionSession {
    let executor: SSHCommandExecutor?
    let hostKeyChallenges: HostKeyChallengeSink?
    let connection: ReusableSSHConnection?
    let setupErrorText: String?

    /// 真实 SSH 在看门狗下跑、结束时一次交付，所以**不吐中间行**，`onLines` 原样忽略。
    func run(_ command: String,
             onLines: @escaping @Sendable ([PLine]) -> Void) async throws -> CommandResult {
        guard let executor else { throw ParallelExecutionUnavailable() }
        return try await executor.runSupervised(command)
    }

    func takeHostKeyChallenge() -> HostKeyChallenge? { hostKeyChallenges?.take() }

    func close() async { await connection?.close() }
}

/// 会话不可用（`setupErrorText != nil` 时控制器不会走到 `run`，此错误只作兜底）。
struct ParallelExecutionUnavailable: Error {}

/// 看门狗判定超时（静默太久 / 超总时长 / 被取消）。带着判定前的输出与一句话原因。
nonisolated struct ParallelExecutionStalled: Error, Sendable {
    let stalled: SupervisedExec.Stalled
    let message: String
}

extension SSHCommandExecutor {
    /// 在 `SupervisedExec` 看门狗下跑：正常结束返回结果；执行失败抛原错误（控制器取
    /// `localizedDescription` 当原因）；超时抛 `ParallelExecutionStalled`。
    nonisolated func runSupervised(_ command: String) async throws -> CommandResult {
        switch await SupervisedExec.runInteractive(command, on: self) {
        case .completed(let result):
            return result
        case .failed(let failure):
            throw failure.underlying
        case .stalled(let stalled):
            throw ParallelExecutionStalled(
                stalled: stalled,
                message: stalled.message(limits: SupervisedExec.interactiveLimits(for: self)))
        }
    }
}

/// 裸执行器也能当会话使：无 host-key sink、无复用连接。
/// 让「真实 `SSHCommandExecutor` 遵循本协议」这件事成立，测试与将来的一次性连接路径可直接用。
extension SSHCommandExecutor: ParallelExecutionSession {
    var setupErrorText: String? { nil }

    func run(_ command: String,
             onLines: @escaping @Sendable ([PLine]) -> Void) async throws -> CommandResult {
        try await runSupervised(command)
    }

    func takeHostKeyChallenge() -> HostKeyChallenge? { nil }

    func close() async {}
}

/// 本次 `run` 通过 `onLines` 吐了几行 —— 控制器据此决定还要不要从 `CommandResult`
/// 切行追加。回调在任意线程调用（真实实现在 NIO 线程、假实现在自己的 Task 上），
/// 所以计数用锁而不是 actor：调用方需要在 `run` 返回的那一刻**同步**读到准确值。
nonisolated final class ParallelStreamedLineCount: @unchecked Sendable {
    private let lock = NSLock()
    private var value = 0

    func add(_ n: Int) {
        lock.lock(); defer { lock.unlock() }
        value += n
    }

    var count: Int {
        lock.lock(); defer { lock.unlock() }
        return value
    }
}
