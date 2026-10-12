import Foundation
import SwiftData
import SwiftUI

/// Agent「运行命令」工具的**执行契约**（注入口）。
///
/// 之前这条路上只有一个具体类型：`MobileAgentChat.configureModel()` 直接调
/// `WorkspaceCommandExecutorFactory.make(server:container:)` 现造一个真的 SSH 执行器。
/// 于是「批准 → 执行 → 输出回填卡片 → 完成态」这条链在测试里根本走不通 ——
/// 假 Agent 流只能覆盖到「卡片渲染出来」为止（见 `uTermMobileTests/README.md`
/// 「数据注入口不存在的屏幕」表）。
///
/// 契约（实现方须满足，`MobileFakeCommandExecutor` 是按这几条写的）：
///
/// - **执行命令**：`run(_:)` 收一条已经被 `SSHCommandExecutor` 包过的 shell 文本。
/// - **按节拍回吐输出**：实现可以边跑边攒输出（真实现是 SSH exec 的流），
///   `run` 返回时给出**合并后的**输出。中途进度由实现自己暴露（假实现给
///   `emittedLines`），`AssistantModel` 只认最终结果 —— 这是有意为之：
///   接一条中途回吐的通道会改变生产行为，本轮不做。
/// - **返回退出码**：`CommandResult.exitCode`，非零不算抛错。
/// - **可取消**：`run` 在 `Task` 被取消时须尽快返回或抛 `CancellationError`。
///   注意 `AssistantModel.approveAndRun` 把 `exec.run` 放进一个**不随驱动任务取消**
///   的 `Task` 里（已经发出去的命令不等于远端进程停了），所以取消语义由实现兜底。
/// - **可失败 / 超时**：抛任意 `Error`；`AssistantModel` 会把它折成
///   `[命令执行失败：…]` 折回卡片并把该调用标 `.failed`。
///
/// 之所以是 `CommandExecutor` 的**精化**而不是另起一套：`AssistantModel.executor`
/// 的类型是 `CommandExecutor?`，精化之后假实现可以直接赋进去，生产类型
/// `SSHCommandExecutor` 也零改动地满足（见文件末尾的 conformance）。
nonisolated protocol AgentCommandExecuting: CommandExecutor {
    /// 取消在途命令。默认空实现 —— 真实现每条命令一条一次性 exec 连接，
    /// 取消由 `Task` 传播；假实现用它来做「执行到一半被打断」那一档。
    func cancelInFlight() async
}

extension AgentCommandExecuting {
    func cancelInFlight() async {}
}

/// 生产实现：`SSHCommandExecutor` 本来就满足全部契约（wrapped 命令永远 exit 0 +
/// 哨兵解析出真实退出码；`exec` 闭包沿 `Task` 取消传播；建连 / 传输失败直接抛）。
extension SSHCommandExecutor: AgentCommandExecuting {}

/// Agent 对话里 `run_command` 实际走的执行器：把 `SSHCommandExecutor` 放到
/// `SupervisedExec` 看门狗底下跑。**不由各入口注入** —— `AssistantModel` 在发命令的那
/// 一刻自己套（`AssistantModel.supervised`），工作区 / 终端窗口 / iOS 三处入口照旧只给
/// 裸的 `SSHCommandExecutor`，哪一处都漏不掉。
///
/// 裸的 `SSHCommandExecutor.run` 没有任何超时 —— Citadel 的 exec 等不到 EOF 就永远不
/// 返回。远端磁盘 I/O 卡死时一条 `ps aux` 就能把工具卡片永久钉在「执行中」，而
/// `AssistantModel` 的状态由卡片推出来：停止对话之后仍是 `.running`，这个会话里之后发的
/// 每条消息都只会进待发队列。CLI / 快捷命令 / 并行窗口早就走看门狗了，对话这条路是漏的。
///
/// 超时折成**抛错**而不是带说明的成功结果：卡片要落在 `.failed`（红），而
/// `AssistantModel.completeCommand` 把 `localizedDescription` 原样写进卡片输出、回喂模型。
nonisolated struct SupervisedAgentCommandExecutor: AgentCommandExecuting {
    private let base: SSHCommandExecutor
    private let limits: SupervisedExec.Limits
    /// 看门狗的检查间隔；nil 用 `SupervisedExec` 的缺省。测试调小。
    private let tick: Duration?

    init(_ base: SSHCommandExecutor,
         idle: Duration = SupervisedExec.agentIdle,
         maxDuration: Duration = SupervisedExec.interactiveMaxDuration,
         tick: Duration? = nil) {
        self.base = base
        self.limits = SupervisedExec.Limits(idle: idle, maxDuration: maxDuration,
                                            maxLines: base.maxLines, maxBytes: base.maxBytes)
        self.tick = tick
    }

    func run(_ command: String) async throws -> CommandResult {
        switch await SupervisedExec.run(command, on: base, limits: limits, tick: tick) {
        case .completed(let result):
            return result
        case .failed(let failure):
            // 建连 / 传输失败：原样上抛，卡片文案与接看门狗之前一致。
            throw failure.underlying
        case .stalled(let stalled):
            throw AgentCommandStalled(partialOutput: stalled.partial.output,
                                      reason: stalled.message(limits: limits))
        }
    }
}

/// 看门狗判定卡住（或跑满总时长）并终止了命令。文案 = 判定前已收到的输出 + 一行原因：
/// 卡在哪一步通常就在最后几行，模型要看得到。
nonisolated struct AgentCommandStalled: LocalizedError, Equatable {
    let partialOutput: String
    let reason: String

    var errorDescription: String? {
        let note = "[执行超时：\(reason)]"
        return partialOutput.isEmpty ? note : partialOutput + "\n" + note
    }
}

/// 造 Agent 工具执行器的**工厂注入口**。
///
/// 生产走 `.live`，逐字等价于改前 `MobileAgentChat` 里那两行
/// （`try?` 包住 → 失败则不注入执行器，Agent 自然不暴露工具）。
/// 测试用 `.stub(_:)` 换成假执行器；**默认值就是 `.live`，视图不传即生产路径**。
nonisolated struct AgentCommandExecutorFactory: Sendable {
    /// `(主机, 容器) -> 执行器?`。返回 nil 表示认证材料解析失败 —— 与改前
    /// `try?` 吞掉错误的行为一致。
    let make: @MainActor @Sendable (ServerProfile, ModelContainer) -> (any AgentCommandExecuting)?

    init(make: @escaping @MainActor @Sendable (ServerProfile, ModelContainer) -> (any AgentCommandExecuting)?) {
        self.make = make
    }

    /// 真实现：每条命令独立开一条一次性 SSH exec 连接（`WorkspaceCommandExecutorFactory`）。
    static let live = AgentCommandExecutorFactory { server, container in
        (try? WorkspaceCommandExecutorFactory.make(server: server, container: container))?.executor
    }

    /// 固定返回同一个执行器（测试 / 探针用）。
    static func stub(_ executor: any AgentCommandExecuting) -> AgentCommandExecutorFactory {
        AgentCommandExecutorFactory { _, _ in executor }
    }

    /// 永远不给执行器 —— Agent 退化为纯文本对话（等价于认证材料解析失败那条路）。
    static let none = AgentCommandExecutorFactory { _, _ in nil }
}

private struct AgentCommandExecutorFactoryKey: EnvironmentKey {
    static let defaultValue = AgentCommandExecutorFactory.live
}

extension EnvironmentValues {
    /// Agent 工具执行器的工厂。默认 `.live`（生产路径不变）；
    /// 探针用 `.environment(\.agentCommandExecutorFactory, .stub(fake))` 换掉。
    var agentCommandExecutorFactory: AgentCommandExecutorFactory {
        get { self[AgentCommandExecutorFactoryKey.self] }
        set { self[AgentCommandExecutorFactoryKey.self] = newValue }
    }
}
