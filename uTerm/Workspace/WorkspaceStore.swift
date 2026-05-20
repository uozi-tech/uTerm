import Foundation

/// 工作区快照的本地 JSON 持久化。
/// Spec 1 起按窗口分文件：`workspace-<windowID>.json`，存于
/// `~/Library/Application Support/uTerm/`。不走 iCloud。
nonisolated struct WorkspaceStore {
    private let fileURL: URL
    private let directory: URL

    /// 按窗口持久化。`directory` 为 nil 时用默认应用支持目录。
    nonisolated init(windowID: WorkspaceWindowID, directory: URL? = nil) {
        let dir = directory ?? Self.defaultDirectory
        self.directory = dir
        self.fileURL = dir.appendingPathComponent("workspace-\(windowID.id.uuidString).json")
    }

    private nonisolated static var defaultDirectory: URL {
        FileManager.default
            .urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("uTerm", isDirectory: true)
    }

    /// 读取快照；文件缺失或损坏返回 nil（调用方据此以空工作区启动）。
    nonisolated func load() -> WorkspaceSnapshot? {
        guard let data = try? Data(contentsOf: fileURL) else { return nil }
        return try? JSONDecoder().decode(WorkspaceSnapshot.self, from: data)
    }

    /// 写入快照（原子写）。
    nonisolated func save(_ snapshot: WorkspaceSnapshot) throws {
        try FileManager.default.createDirectory(
            at: directory, withIntermediateDirectories: true)
        let data = try JSONEncoder().encode(snapshot)
        try data.write(to: fileURL, options: .atomic)
    }

    /// 删除 Spec 1 之前的单份 `workspace.json` —— 新模型按窗口分文件，旧文件已无用。
    nonisolated static func purgeLegacyWorkspaceFile(directory: URL? = nil) {
        let dir = directory ?? defaultDirectory
        try? FileManager.default.removeItem(at: dir.appendingPathComponent("workspace.json"))
    }
}
