import Foundation

/// 按 workspace 范围持久化最近打开的 SFTP 文件。
nonisolated final class RecentFilesStore {
    static let maxEntries = 20

    let rootDirectory: URL
    let fileName: String

    /// 生产用：用 ApplicationSupport/uTerm 子目录 + workspace-id 命名。
    convenience init(windowID: WorkspaceWindowID) {
        let support = (try? FileManager.default.url(
            for: .applicationSupportDirectory,
            in: .userDomainMask,
            appropriateFor: nil,
            create: true))?
            .appendingPathComponent("uTerm", isDirectory: true)
            ?? URL(fileURLWithPath: NSTemporaryDirectory())
        self.init(rootDirectory: support,
                  fileName: "recents-\(windowID.id.uuidString).json")
    }

    /// 测试构造器 —— 指定根目录便于隔离。
    init(rootDirectory: URL, fileName: String) {
        self.rootDirectory = rootDirectory
        self.fileName = fileName
    }

    private var fileURL: URL { rootDirectory.appendingPathComponent(fileName) }

    func load() -> [RecentFileEntry] {
        guard let data = try? Data(contentsOf: fileURL) else { return [] }
        return (try? JSONDecoder().decode([RecentFileEntry].self, from: data)) ?? []
    }

    func save(_ entries: [RecentFileEntry]) {
        try? FileManager.default.createDirectory(at: rootDirectory, withIntermediateDirectories: true)
        guard let data = try? JSONEncoder().encode(entries) else { return }
        try? data.write(to: fileURL, options: .atomic)
    }

    /// 添加或更新一个条目：去重后加到队头，截断 maxEntries。
    func touch(_ entry: RecentFileEntry) {
        var entries = load().filter { $0.remotePath != entry.remotePath }
        entries.insert(entry, at: 0)
        if entries.count > Self.maxEntries {
            entries.removeLast(entries.count - Self.maxEntries)
        }
        save(entries)
    }
}
