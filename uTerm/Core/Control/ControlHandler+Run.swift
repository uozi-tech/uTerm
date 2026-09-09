import Foundation
import SwiftData

/// 执行组：`run` / `run-many` / `quick-commands` / `quick-run`。
///
/// 全组共同的硬约束：
/// - `run*` 与 `quick-run` 是 mutation（shell 无法可靠分类读写），门禁已在
///   `ControlHandler.handle` 统一判过，这里只判主机级 `sftpOnly`。
/// - Citadel 的 exec **不可取消**：超时必须走 `BoundedExec` 的「非结构化 Task +
///   一次性闸门」放手模式，否则 `tail -f` 会挂死整个任务组。超时返回后**命令可能
///   还在远端跑**，文案与技能文档都要写明。
/// - 未知 / 变更的主机密钥一律拒绝并回 fingerprint，绝不自动 TOFU。
///
/// Wave 1 待填：`runResponse` / `runManyResponse` / `quickCommandsResponse` / `quickRunResponse`。
extension ControlHandler {

    func handleRun(
        _ request: ControlRequest,
        _ deps: Dependencies
    ) async throws -> ControlResponse {
        switch request.action {
        case .run:
            // Wave 1：resolveHost → requireExecCapable → pool.executor(for:) →
            // BoundedExec（timeoutSeconds 封顶 maxRunTimeoutSeconds）→ ControlRunResult。
            throw ControlFailure.notImplemented("run")
        case .runMany:
            // Wave 1：逐主机解析 → 有界并发 maxParallelHosts → [ControlRunResult]；
            // 单台失败只写该条的 errorCode，不让整批失败。
            throw ControlFailure.notImplemented("run-many")
        case .quickCommands:
            // Wave 2：fetch QuickCommand → ControlQuickCommandSnapshot（serverIDs 翻成 serverNames）。
            throw ControlFailure.notImplemented("quick-commands")
        case .quickRun:
            // Wave 2：按 name/id 找 QuickCommand（可 --host 覆盖目标）→ 复用 run-many 路径 →
            // QuickCommandStore.recordRun 写 30 天日志（与界面里跑的记录同表）。
            throw ControlFailure.notImplemented("quick-run")
        default:
            throw ControlFailure(
                code: .invalid_request,
                message: "动作 \(request.action.rawValue) 不属于执行组"
            )
        }
    }
}
