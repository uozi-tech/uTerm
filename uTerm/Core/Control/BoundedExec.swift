import Foundation

/// 「不可取消的远端调用 + 超时」的通用外壳。
///
/// 存在的理由：Citadel 的 exec **不可取消**。任何 `withTaskGroup { await exec() }` 的
/// 写法都会被 `tail -f` 这类命令挂死整个任务组 —— 结构化并发在这里帮不上忙。
/// 唯一可行的形态是「非结构化 Task + 一次性闸门」：超时先返回、把还在跑的 Task 放手，
/// 结果晚到时由闸门丢弃。**超时返回后命令可能还在远端跑**，调用方与技能文档都要写明。
///
/// Wave 1 待填：把 `QuickCommandRunner.runBounded` 与 `ParallelRunModel.execBounded`
/// 的实现抽到这里（行为不变），三处共用，顺手消掉重复。
nonisolated enum BoundedExec {
}
