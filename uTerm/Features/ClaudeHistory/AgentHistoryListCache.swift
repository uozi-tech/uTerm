import Foundation

/// 历史会话列表的进程内缓存：同一台主机、同一组工具的列表再开一次（新开一个 Code 标签页、关了又开、开独立的历史窗口）
/// 时，先把上一次列到的显示出来（`AgentHistoryModel.start`），后台再重列。
///
/// 只在内存里，App 退出就没了：不落盘、不进 iCloud。存的是列目录的结果和每份记录的列表信息（标题、来源、目录、分支），
/// 不存对话内容。每条信息都带着读它时那份文件的（路径、大小、修改时间），文件变了会重读，不会一直显示旧的。
@MainActor
final class AgentHistoryListCache {
    static let shared = AgentHistoryListCache()

    struct Entry {
        var projects: [AgentHistoryProject]
        var availableTools: [AgentHistoryTool]
        var listedFiles: [AgentHistorySessionFile]
        var metadata: [String: AgentHistorySessionMetadata]
        var metadataKeys: [String: AgentHistorySessionFile.CacheKey]
        /// 当时列表显示到了几行（再开时至少读到这么多行，滚动位置附近的不至于先空着）。
        var shownRows: Int
    }

    /// 最多记几份（几台主机）。超了丢最久没用的。
    nonisolated static let capacity = 8

    private var entries: [String: Entry] = [:]
    private var order: [String] = []

    func entry(_ key: String) -> Entry? {
        guard let entry = entries[key] else { return nil }
        touch(key)
        return entry
    }

    func store(_ key: String, _ entry: Entry) {
        entries[key] = entry
        touch(key)
        while order.count > Self.capacity { entries[order.removeFirst()] = nil }
    }

    func removeAll() {
        entries = [:]
        order = []
    }

    private func touch(_ key: String) {
        order.removeAll { $0 == key }
        order.append(key)
    }
}
