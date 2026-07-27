import Foundation

/// 工作区快照的本地 JSON 持久化。
/// 按服务器分文件：`workspace-<serverID>.json`，存于
/// `~/Library/Application Support/uTerm/`。不走 iCloud。同一服务器重连会命中
/// 同一份快照。
nonisolated struct WorkspaceStore: Sendable {
    private let fileURL: URL
    private let directory: URL

    /// 按服务器持久化。`directory` 为 nil 时用默认应用支持目录。
    nonisolated init(windowID: WorkspaceWindowID, directory: URL? = nil) {
        let dir = directory ?? Self.defaultDirectory
        self.directory = dir
        self.fileURL = dir.appendingPathComponent("workspace-\(windowID.serverID.uuidString).json")
    }

    private nonisolated static var defaultDirectory: URL {
        FileManager.default
            .urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("uTerm", isDirectory: true)
    }

    /// 读取快照；文件缺失或损坏返回 nil（调用方据此以空工作区启动）。
    nonisolated func load() -> WorkspaceSnapshot? {
        if let data = try? Data(contentsOf: fileURL),
           let snapshot = try? JSONDecoder().decode(WorkspaceSnapshot.self, from: data) {
            return snapshot
        }
        return loadLegacyRandomWindowSnapshot()
    }

    /// 写入快照（原子写）。
    nonisolated func save(_ snapshot: WorkspaceSnapshot) throws {
        try FileManager.default.createDirectory(
            at: directory, withIntermediateDirectories: true)
        let data = try JSONEncoder().encode(snapshot)
        try data.write(to: fileURL, options: .atomic)
    }

    /// 删除 Spec 1 之前的单份 `workspace.json` —— 旧文件已无用。
    nonisolated static func purgeLegacyWorkspaceFile(directory: URL? = nil) {
        let dir = directory ?? defaultDirectory
        try? FileManager.default.removeItem(at: dir.appendingPathComponent("workspace.json"))
    }

    /// 兼容旧版本按随机 windowID 命名的 `workspace-<uuid>.json`。新文件名用
    /// serverID，若新文件缺失，则扫描旧文件，挑一份包含该 serverID 的最近快照。
    private nonisolated func loadLegacyRandomWindowSnapshot() -> WorkspaceSnapshot? {
        guard let serverID = Self.serverID(from: fileURL),
              let urls = try? FileManager.default.contentsOfDirectory(
                at: directory,
                includingPropertiesForKeys: [.contentModificationDateKey],
                options: [.skipsHiddenFiles])
        else {
            return nil
        }
        let candidates = urls
            .filter { $0.lastPathComponent.hasPrefix("workspace-") && $0.pathExtension == "json" }
            .compactMap { url -> (URL, WorkspaceSnapshot, Date)? in
                guard url != fileURL,
                      let data = try? Data(contentsOf: url),
                      let snapshot = try? JSONDecoder().decode(WorkspaceSnapshot.self, from: data),
                      snapshot.containsServer(serverID)
                else {
                    return nil
                }
                let values = try? url.resourceValues(forKeys: [.contentModificationDateKey])
                return (url, snapshot, values?.contentModificationDate ?? .distantPast)
            }
            .sorted { $0.2 > $1.2 }
        return candidates.first?.1
    }

    private nonisolated static func serverID(from url: URL) -> UUID? {
        let name = url.deletingPathExtension().lastPathComponent
        guard name.hasPrefix("workspace-") else { return nil }
        return UUID(uuidString: String(name.dropFirst("workspace-".count)))
    }
}

private extension WorkspaceSnapshot {
    nonisolated func containsServer(_ serverID: UUID) -> Bool {
        tabs.contains { $0.layout.containsServer(serverID) }
    }
}

private extension NodeSnapshot {
    nonisolated func containsServer(_ serverID: UUID) -> Bool {
        switch self {
        case .leaf(let id):
            return id == serverID
        case .split(_, _, let first, let second):
            return first.containsServer(serverID) || second.containsServer(serverID)
        }
    }
}
