import Foundation

/// 设备上镜像 Mac 的 Code 标签页时，里面的会话怎么跟着 Mac 走（纯逻辑，两端共用；iOS 的 `ClaudeHistoryTab` 落到
/// 自己的 `CodeRunBoard` 上）：
///
/// - Mac 的 Code 标签页里有、设备上还没有的会话：加进来（只加 Mac 的会话列表里已经列着的——还没列出来的接不上，
///   等列表到了再加）。
/// - 设备上镜像着、Mac 的 Code 标签页里没了的（跑完收回记录、Mac 上「移到新标签页」、Mac 上关掉）：拿掉，只断开镜像。
/// - 两边都有的：对上的记录（路径、会话 ID）、标题、结束时刻照 Mac 的改。路径、会话 ID 只往有了改：Mac 刚重启、
///   列表还没读出来时报的是 nil，设备上已经知道的不丢。
///
/// 认不出工具的会话（以后才有的工具）不镜像，它们照旧开成终端标签页（`RemoteMacClient.codeRunSessionIDs` 同一条规则）。
nonisolated enum RemoteCodeRunMirror {
    /// 设备上已经镜像着的一个会话此刻的样子。
    struct Mirrored: Equatable, Sendable {
        var session: UUID
        var path: String?
        var sessionID: String?
        var title: String?
        var endedAt: Date?
    }

    struct Plan: Equatable, Sendable {
        /// 要加的，按 Mac 上的先后。
        var added: [RemoteCodeTabInfo.Run] = []
        /// 要拿掉的会话 id。
        var removed: [UUID] = []
        /// 要照 Mac 改的（已经合好：路径、会话 ID 为 nil 时保留设备上已知的）。
        var updated: [RemoteCodeTabInfo.Run] = []

        var isEmpty: Bool { added.isEmpty && removed.isEmpty && updated.isEmpty }
    }

    /// `info` 为 nil = Mac 上没有要镜像的 Code 标签页了：设备上镜像着的全部拿掉。`listed`：Mac 此刻的会话列表。
    static func plan(mirrored: [Mirrored], info: RemoteCodeTabInfo?, listed: Set<UUID>) -> Plan {
        var seen: Set<UUID> = []
        let wanted = (info?.runs ?? []).filter { run in
            AgentHistoryTool(rawValue: run.tool) != nil && seen.insert(run.session).inserted
        }
        let wantedIDs = Set(wanted.map(\.session))
        let current = Dictionary(mirrored.map { ($0.session, $0) }, uniquingKeysWith: { first, _ in first })
        var plan = Plan()
        plan.removed = mirrored.map(\.session).filter { !wantedIDs.contains($0) }
        for run in wanted {
            guard let existing = current[run.session] else {
                if listed.contains(run.session) { plan.added.append(run) }
                continue
            }
            var merged = run
            merged.path = run.path ?? existing.path
            merged.sessionID = run.sessionID ?? existing.sessionID
            let now = Mirrored(session: run.session, path: merged.path, sessionID: merged.sessionID, title: merged.title,
                               endedAt: merged.endedAt)
            if now != existing { plan.updated.append(merged) }
        }
        return plan
    }
}
