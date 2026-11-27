import CryptoKit
import Foundation

/// 历史会话列表的缓存：同一台主机、同一组工具的列表再开一次（新开一个 Code 标签页、关了又开、开独立的历史窗口、
/// App 重开之后第一次打开）时，先把上一次列到的显示出来（`AgentHistoryModel.start`），后台再重列。
///
/// 内存里一份；另存一份在本机的缓存目录（`Caches/AgentHistoryList/`，不进 iCloud、不进备份，系统空间紧时可以删）：
/// 原来只在内存里，App 重开后第一次打开侧栏要等整趟重列（iOS 上经 SSH / 远控 Mac 列，几种工具先后列完，行一批批进来、
/// 顺序跳几下，实机反馈）。存的是列目录的结果和每份记录的列表信息（标题、来源、目录、分支、额度），不存对话内容。
/// 每条信息都带着读它时那份文件的（路径、大小、修改时间），文件变了会重读，不会一直显示旧的。测试宿主里不读不写盘
/// （它和正式版共用一个沙盒容器）。
@MainActor
final class AgentHistoryListCache {
    static let shared = AgentHistoryListCache(
        directory: TestHostEnvironment.isActive ? nil : AgentHistoryListCache.defaultDirectory)

    nonisolated struct Entry: Codable {
        var projects: [AgentHistoryProject]
        var availableTools: [AgentHistoryTool]
        var listedFiles: [AgentHistorySessionFile]
        var metadata: [String: AgentHistorySessionMetadata]
        var metadataKeys: [String: AgentHistorySessionFile.CacheKey]
        /// 当时列表显示到了几行（再开时至少读到这么多行，滚动位置附近的不至于先空着）。
        var shownRows: Int
    }

    /// 最多记几份（几台主机）。超了丢最久没用的（盘上的也是）。
    nonisolated static let capacity = 8
    /// 盘上格式的版本：改了 `Entry` 里任何类型的字段就加一，旧文件读不出来时当没有。
    nonisolated static let formatVersion = 1
    /// 写盘前等多久（列完、列表多出行时会连着存好几次，合成一次写）。
    nonisolated static let writeDelay: Duration = .seconds(1)

    nonisolated static var defaultDirectory: URL? {
        FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask).first?
            .appendingPathComponent("AgentHistoryList", isDirectory: true)
    }

    /// nil = 只在内存里。
    nonisolated let directory: URL?
    private var entries: [String: Entry] = [:]
    private var order: [String] = []
    private var pendingWrites: [String: Entry] = [:]
    private var writeTask: Task<Void, Never>?

    init(directory: URL?) {
        self.directory = directory
    }

    func entry(_ key: String) -> Entry? {
        guard let entry = entries[key] else { return nil }
        touch(key)
        return entry
    }

    /// 内存里没有时读盘上那份（在后台线程解码），读到了放进内存。没有、读不出来为 nil。
    func persistedEntry(_ key: String) async -> Entry? {
        if let entry = entry(key) { return entry }
        guard let url = fileURL(key) else { return nil }
        let decoded = await Task.detached(priority: .userInitiated) { Self.decode(at: url, key: key) }.value
        // 解码的时候内存里可能已经有了更新的（这一趟重列列完了）：以内存的为准。
        if let current = entries[key] { return current }
        guard let decoded else { return nil }
        remember(key, decoded)
        return decoded
    }

    func store(_ key: String, _ entry: Entry) {
        remember(key, entry)
        guard directory != nil else { return }
        pendingWrites[key] = entry
        guard writeTask == nil else { return }
        writeTask = Task { [weak self] in
            try? await Task.sleep(for: Self.writeDelay)
            await self?.flush()
        }
    }

    /// 把攒着的写下去（测试也直接调）。
    func flush() async {
        writeTask = nil
        let writes = pendingWrites
        pendingWrites = [:]
        guard let directory, !writes.isEmpty else { return }
        let urls = writes.keys.reduce(into: [String: URL]()) { $0[$1] = fileURL($1) }
        let keep = Set(order.compactMap(fileURL).map(\.lastPathComponent))
        await Task.detached(priority: .utility) {
            Self.write(writes, to: urls, directory: directory, keeping: keep)
        }.value
    }

    func removeAll() {
        entries = [:]
        order = []
        pendingWrites = [:]
        if let directory { try? FileManager.default.removeItem(at: directory) }
    }

    private func remember(_ key: String, _ entry: Entry) {
        entries[key] = entry
        touch(key)
        while order.count > Self.capacity { entries[order.removeFirst()] = nil }
    }

    private func touch(_ key: String) {
        order.removeAll { $0 == key }
        order.append(key)
    }

    /// 文件名不带主机名、路径：键（主机 | 工具 | 主目录）的 SHA-256。
    private func fileURL(_ key: String) -> URL? {
        guard let directory else { return nil }
        let digest = SHA256.hash(data: Data(key.utf8)).map { String(format: "%02x", $0) }.joined()
        return directory.appendingPathComponent(digest + ".json")
    }

    nonisolated private struct Stored: Codable {
        var version: Int
        var key: String
        var entry: Entry
    }

    nonisolated private static func decode(at url: URL, key: String) -> Entry? {
        guard let data = try? Data(contentsOf: url),
              let stored = try? JSONDecoder().decode(Stored.self, from: data),
              stored.version == formatVersion, stored.key == key else { return nil }
        return stored.entry
    }

    nonisolated private static func write(_ writes: [String: Entry], to urls: [String: URL], directory: URL,
                                          keeping keep: Set<String>) {
        let manager = FileManager.default
        try? manager.createDirectory(at: directory, withIntermediateDirectories: true)
        for (key, entry) in writes {
            guard let url = urls[key],
                  let data = try? JSONEncoder().encode(Stored(version: formatVersion, key: key, entry: entry)) else { continue }
            try? data.write(to: url, options: [.atomic, .completeFileProtectionUntilFirstUserAuthentication])
        }
        // 盘上只留内存里那几份（最近用过的 `capacity` 台主机）。
        let files = (try? manager.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil)) ?? []
        for file in files where file.pathExtension == "json" && !keep.contains(file.lastPathComponent) {
            try? manager.removeItem(at: file)
        }
    }
}
