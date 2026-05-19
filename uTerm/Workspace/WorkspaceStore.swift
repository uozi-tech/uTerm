import Foundation

/// 工作区快照的本地 JSON 持久化。默认存到
/// `~/Library/Application Support/uTerm/workspace.json`。不走 iCloud。
nonisolated struct WorkspaceStore {
    private let fileURL: URL

    nonisolated init(directory: URL? = nil) {
        let dir = directory ?? FileManager.default
            .urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("uTerm", isDirectory: true)
        self.fileURL = dir.appendingPathComponent("workspace.json")
    }

    /// 读取快照；文件缺失或损坏返回 nil（调用方据此以空工作区启动）。
    nonisolated func load() -> WorkspaceSnapshot? {
        guard let data = try? Data(contentsOf: fileURL) else { return nil }
        return try? JSONDecoder().decode(WorkspaceSnapshot.self, from: data)
    }

    /// 写入快照（原子写）。
    nonisolated func save(_ snapshot: WorkspaceSnapshot) throws {
        try FileManager.default.createDirectory(
            at: fileURL.deletingLastPathComponent(),
            withIntermediateDirectories: true)
        let data = try JSONEncoder().encode(snapshot)
        try data.write(to: fileURL, options: .atomic)
    }
}
