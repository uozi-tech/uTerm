import Foundation
import SwiftData

/// 主机组：`hosts` / `host-key` / `trust`。
///
/// 这个文件同时是**主机解析的唯一入口**：所有其它组要拿 `ServerProfile` 都得走
/// `resolveHost(_:)`，从而共享同一套三级匹配与歧义规则，也共享 `sftpOnly` 硬规则。
///
/// Wave 1 待填：`hostSnapshots` / `hostKeyResponse` / `trustResponse` / `resolveHost`。
extension ControlHandler {

    func handleHosts(
        _ request: ControlRequest,
        _ deps: Dependencies
    ) async throws -> ControlResponse {
        switch request.action {
        case .hosts:
            // Wave 1：fetch ServerProfile（按 isPinned / sortOrder / name 排序）→ hostSnapshots。
            throw ControlFailure.notImplemented("hosts")
        case .hostKey:
            // Wave 1：resolveHost → 查 KnownHost（host+port）→ ControlHostKeyInfo（known/unknown/changed）。
            throw ControlFailure.notImplemented("host-key")
        case .trust:
            // Wave 1：只接受与**当前挑战**一致的 fingerprint 才写 KnownHost；
            // host_key_changed 即便 mutation 开着也不给 CLI 覆盖，必须回界面处理。
            throw ControlFailure.notImplemented("trust")
        default:
            throw ControlFailure(
                code: .invalid_request,
                message: "动作 \(request.action.rawValue) 不属于主机组"
            )
        }
    }

    /// 名字 / UUID → `ServerProfile` 的三级解析：精确 → 忽略大小写 → 唯一前缀。
    ///
    /// 多条命中抛 `host_ambiguous`，并把候选（带 UUID）放进 `ControlFailure.hosts` ——
    /// CloudKit 同步下同名主机是常态，技能文档要教模型改用 UUID 重试。
    /// 纯匹配逻辑将抽进 `HostResolver` 以便单测，本方法只负责取数据 + 包错。
    ///
    /// - Important: 所有需要主机的动作都必须经此入口，不要各自 fetch。
    func resolveHost(_ needle: String) throws(ControlFailure) -> ServerProfile {
        // ⚠️ 临时实现（Wave 1D 为了让 `terminal-open` 可用 / 可测而先填的最小版本）：
        // 只做「UUID 直达 → 名字精确」两级，**没有**忽略大小写与唯一前缀，
        // 歧义时也没有把候选放进 `ControlFailure.hosts`。合并时以核心分支
        //（`HostResolver` + 完整三级解析）为准，直接覆盖本方法。
        let trimmed = needle.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            throw ControlFailure(code: .invalid_request, message: "缺少 --host")
        }
        guard let deps = dependencies else {
            throw ControlFailure(code: .app_not_ready, message: "uTerm 尚未完成启动")
        }
        let profiles = (try? deps.modelContainer.mainContext
            .fetch(FetchDescriptor<ServerProfile>())) ?? []
        if let uuid = UUID(uuidString: trimmed),
           let hit = profiles.first(where: { $0.id == uuid }) {
            return hit
        }
        let exact = profiles.filter { $0.name == trimmed }
        if exact.count == 1 { return exact[0] }
        if exact.count > 1 {
            throw ControlFailure(
                code: .host_ambiguous,
                message: "「\(trimmed)」匹配到 \(exact.count) 台主机，请改用 UUID"
            )
        }
        throw ControlFailure(code: .host_not_found, message: "没有名为「\(trimmed)」的主机")
    }

    /// 主机级硬规则：`sftpOnly` 的主机拒绝执行命令与终端操作。
    ///
    /// 这是用户在主机档案上做的定性，CLI 不绕 —— 各组在 `resolveHost` 之后**立刻**调用。
    func requireExecCapable(
        _ profile: ServerProfile,
        action: ControlAction
    ) throws(ControlFailure) {
        guard action.requiresExecCapableHost, profile.sftpOnly else { return }
        throw ControlFailure(
            code: .host_sftp_only,
            message: "主机「\(profile.name)」被标记为仅 SFTP，不允许执行命令或操作终端"
        )
    }
}
