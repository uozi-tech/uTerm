import Foundation

/// 读 Antigravity 数据目录里的 `conversation_summaries.db`，拿每个会话的工作区、标题、最后修改时间、由谁派出。
/// 有了它列表才能按工作区分组（`brain/` 下的记录里没有工作区）。
///
/// 经 `SQLiteRemoteReader`：整份读进内存再打开，不往主机上写、本机不落盘。没有这个库（命令行版不一定有）、
/// 表结构变了、正在被写读不稳，都会抛错，数据源当作没有这份信息。
nonisolated struct AntigravitySummaryIndex: AntigravityConversationIndex {
    static let fileName = "conversation_summaries.db"

    func conversations(root: String, provider: any SFTPProviding) async throws -> [String: AntigravityConversationInfo] {
        let reader = SQLiteRemoteReader(provider: provider, path: root + "/" + Self.fileName)
        let read = try await reader.read { database in
            var found: [String: AntigravityConversationInfo] = [:]
            try database.query("""
                SELECT conversation_id, title, workspace_uris, last_modified_time, parent_conversation_id
                FROM conversation_summaries
                """) { row in
                guard let id = row.text(0), !id.isEmpty else { return }
                func nonEmpty(_ column: Int) -> String? {
                    guard let text = row.text(column), !text.isEmpty else { return nil }
                    return text
                }
                found[id] = AntigravityConversationInfo(
                    title: nonEmpty(1),
                    workspace: nonEmpty(2).flatMap(AntigravityConversationInfo.workspace(fromURIsJSON:)),
                    lastModified: nonEmpty(3).flatMap(AntigravityConversationInfo.date(fromSQLiteText:)),
                    parentID: nonEmpty(4))
            }
            return found
        }
        return read?.value ?? [:]
    }
}
