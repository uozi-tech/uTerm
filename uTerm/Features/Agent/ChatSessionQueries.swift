import AgentKit
import Foundation
import SwiftData

/// 会话历史下拉共用的取数描述符。
///
/// 两处下拉（`AssistantView` 的浮层、`TerminalAgentView` 上下文条里的 `Menu`）原来都用
/// `@Query(sort: \ChatSession.updatedAt, order: .reverse)` —— **不带 `fetchLimit`**，
/// 一开窗就把库里所有会话取出来并物化成模型对象。重度用户的库里上千条会话，
/// 而下拉本身只有 280pt 高（约 6 行可见）。
///
/// 这里钉上 `fetchLimit`：下拉是「最近用过的对话」的快速切换器，不是历史归档浏览器。
/// 排序仍是 `updatedAt` 倒序，所以取到的就是最近的那批。
nonisolated enum ChatSessionQueries {
    /// 下拉里最多列多少条。280pt 的浮层一次看得见约 6 行，50 条够翻好几屏。
    static let recentLimit = 50

    static let recent: FetchDescriptor<ChatSession> = {
        var d = FetchDescriptor<ChatSession>(
            sortBy: [SortDescriptor(\.updatedAt, order: .reverse)])
        d.fetchLimit = recentLimit
        return d
    }()
}
