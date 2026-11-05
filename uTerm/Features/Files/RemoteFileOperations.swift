import Foundation

/// 递归删除的进度快照。值类型，驱动 macOS 侧栏 / SFTP 窗口顶部的删除进度条，
/// 以及 iOS 文件标签的删除提示。
///
/// 两段式：先深度优先枚举整棵子树（总数未知 → 不定态 + 已发现计数），
/// 再逐项删（确定态 done/total）。删一个几千项的目录要几千次网络往返，
/// 没有这条状态用户只能对着不动的列表干等。
nonisolated struct RemoteDeletionProgress: Equatable, Sendable {
    enum Phase: Sendable, Equatable { case counting, deleting }
    /// 被删的顶层项名（展示用）。
    let name: String
    var phase: Phase
    /// counting 阶段 = 已发现条目数；deleting 阶段 = 已删除条目数。
    var count: Int
    /// 待删总条目数（含目录自身）。counting 阶段为 nil。
    var total: Int?
    /// 用户已点取消，正在等当前这次网络往返返回。
    var isCancelling: Bool

    /// 开始删除 `name` 时的初始快照。
    static func starting(_ name: String) -> RemoteDeletionProgress {
        RemoteDeletionProgress(name: name, phase: .counting, count: 0, total: nil, isCancelling: false)
    }

    /// 确定态进度（0...1）。counting 阶段恒 0（视图此时用不定态条）。
    var fraction: Double {
        guard let total, total > 0 else { return 0 }
        return min(1, Double(count) / Double(total))
    }

    /// 把一次删除事件写进快照（保留 `name` / `isCancelling`）。
    mutating func apply(_ event: RemoteFileOperations.DeletionEvent) {
        switch event {
        case .counting(let discovered):
            phase = .counting
            count = discovered
            total = nil
        case .deleting(let done, let total):
            phase = .deleting
            count = done
            self.total = total
        }
    }
}

/// 远程文件操作：只依赖 `SFTPProviding`，不持任何 UI 状态。
///
/// macOS `FileBrowserModel` 与 iOS `MobileSFTPController` 共用这一份；两端各自管
/// 自己的状态（当前目录、错误提示、进度条），这里只做「发哪些请求、按什么顺序、
/// 怎么解析结果」。所有操作都显式接收所在目录（`in directory:`），不读任何「当前目录」——
/// 调用方传操作发起那一刻的目录，用户中途切走也不会改到别的目录。
nonisolated enum RemoteFileOperations {

    // MARK: - 删除

    /// 递归删除进度事件。
    enum DeletionEvent: Equatable, Sendable {
        /// 枚举阶段：已发现 `discovered` 项（含根目录自身）。
        case counting(discovered: Int)
        /// 删除阶段：已删 `done` / 共 `total` 项。
        case deleting(done: Int, total: Int)
    }

    /// 用户取消了删除。不是错误，调用方不应上报给用户。
    struct DeletionCancelled: Error {}

    /// 进度事件的最小间隔：每删一项都上报会让 SwiftUI 在大目录上每秒重渲染上千次。
    static let deletionProgressInterval: TimeInterval = 0.10

    /// 删除 `directory` 下的 `entry`：文件 / 符号链接一次 `removeFile`，
    /// 目录走 `removeTree`（进度与取消见那里）。
    ///
    /// 符号链接的 `isDirectory` 恒为 false（列目录走 lstat）→ 只删链接本身，
    /// 绝不跟随进目标目录。
    static func delete(
        _ entry: RemoteEntry,
        in directory: String,
        provider: any SFTPProviding,
        isolation: isolated (any Actor)? = #isolation,
        isCancelled: () -> Bool = { false },
        onProgress: (DeletionEvent) -> Void = { _ in }
    ) async throws {
        let path = RemotePath.join(directory, entry.name)
        if entry.isDirectory {
            try await removeTree(at: path, provider: provider,
                                 isCancelled: isCancelled, onProgress: onProgress)
        } else {
            try await provider.removeFile(path)
        }
    }

    /// 递归删目录：先一趟广度优先枚举拿到全部待删项（顺带得到总数 → 进度条能给
    /// 确定态），再先删文件、后按发现顺序**倒序**删目录。
    ///
    /// 倒序即可保证 rmdir 时目录一定已空：枚举是前序的（父一定先于子入列），
    /// 倒过来自然子先于父。整棵树只需一次 list 遍历，不必边删边重列。
    ///
    /// `isCancelled` 在每次往返前检查，返回 true 即抛 `DeletionCancelled`
    /// （已经删掉的部分不回滚——SFTP 没有事务）。`onProgress` 按
    /// `deletionProgressInterval` 节流，阶段切换与收尾那一帧必发。两个闭包都在
    /// 调用方的 actor 上同步执行（`isolation` 参数），可以直接读写调用方状态。
    static func removeTree(
        at root: String,
        provider: any SFTPProviding,
        isolation: isolated (any Actor)? = #isolation,
        isCancelled: () -> Bool = { false },
        onProgress: (DeletionEvent) -> Void = { _ in }
    ) async throws {
        var lastPublish: Date?
        func publish(_ event: DeletionEvent, force: Bool) {
            let now = Date()
            if !force, let lastPublish,
               now.timeIntervalSince(lastPublish) < deletionProgressInterval { return }
            lastPublish = now
            onProgress(event)
        }
        func checkCancelled() throws {
            if isCancelled() { throw DeletionCancelled() }
        }

        // 前序：`directories[0]` 是 root，父恒排在子之前。
        var directories: [String] = [root]
        var files: [String] = []
        var cursor = 0
        while cursor < directories.count {
            try checkCancelled()
            let dir = directories[cursor]
            cursor += 1
            for child in try await provider.list(path: dir) {
                let childPath = RemotePath.join(dir, child.name)
                if child.isDirectory {
                    directories.append(childPath)
                } else {
                    files.append(childPath)
                }
            }
            publish(.counting(discovered: files.count + directories.count), force: false)
        }

        try checkCancelled()
        let total = files.count + directories.count
        publish(.deleting(done: 0, total: total), force: true)

        var done = 0
        for file in files {
            try checkCancelled()
            try await provider.removeFile(file)
            done += 1
            publish(.deleting(done: done, total: total), force: false)
        }
        for directory in directories.reversed() {
            try checkCancelled()
            try await provider.removeDirectory(directory)
            done += 1
            publish(.deleting(done: done, total: total), force: false)
        }
        publish(.deleting(done: done, total: total), force: true)
    }

    // MARK: - 权限

    /// chmod。`mode` 取低 9 位（`& 0o777`）。
    /// - 非递归（或文件）：走 SFTP `setstat`（`provider.setPermissions`）。
    /// - 递归（目录 + `recursive`）：开 exec channel 跑 `chmod -R <oct> <path>`，
    ///   一次性把整棵子树改掉（比逐项 setstat 可靠且快）。
    static func setPermissions(
        _ entry: RemoteEntry,
        in directory: String,
        mode: UInt32,
        recursive: Bool = false,
        provider: any SFTPProviding
    ) async throws {
        let path = RemotePath.join(directory, entry.name)
        let perm = mode & 0o777
        if recursive && entry.isDirectory {
            _ = try await provider.exec(chmodRecursiveCommand(path: path, mode: perm))
        } else {
            try await provider.setPermissions(path: path, mode: perm)
        }
    }

    /// `chmod -R <八进制> '<path>'`。
    static func chmodRecursiveCommand(path: String, mode: UInt32) -> String {
        "chmod -R \(String(mode & 0o777, radix: 8)) \(RemotePath.shellQuote(path))"
    }

    // MARK: - 重命名

    /// 校验并规范新名字：去首尾空白；空名或与原名相同返回 nil（调用方不发请求）。
    static func validatedNewName(_ newName: String, for entry: RemoteEntry) -> String? {
        let trimmed = newName.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, trimmed != entry.name else { return nil }
        return trimmed
    }

    /// 同目录内改名。名字无效 / 没变时不发请求，返回 false；改成功返回 true。
    @discardableResult
    static func rename(
        _ entry: RemoteEntry,
        to newName: String,
        in directory: String,
        provider: any SFTPProviding
    ) async throws -> Bool {
        guard let name = validatedNewName(newName, for: entry) else { return false }
        try await provider.rename(RemotePath.join(directory, entry.name),
                                  to: RemotePath.join(directory, name))
        return true
    }

    // MARK: - 符号链接

    /// 符号链接指向的东西。
    enum SymlinkTarget: Sendable {
        /// 指向目录：`entries` 是已经列出来的目标目录内容（省一次往返）。
        case directory(path: String, entries: [RemoteEntry])
        /// 指向文件（或目标不存在 / 列不出）：`size` / `mtime` 取自跟随链接的 `stat`，
        /// 取不到为 nil。
        case file(path: String, size: Int64?, mtime: Date?)
    }

    /// 沿链接路径探测：`opendir` 跟随符号链接，能列出即目标是目录；否则按文件处理，
    /// `stat` 跟随链接取目标的 size / mtime。
    static func resolveSymlink(
        _ entry: RemoteEntry,
        in directory: String,
        provider: any SFTPProviding
    ) async -> SymlinkTarget {
        let linkPath = RemotePath.join(directory, entry.name)
        if let targetEntries = try? await provider.list(path: linkPath) {
            return .directory(path: linkPath, entries: targetEntries)
        }
        let stat = try? await provider.stat(linkPath)
        return .file(path: linkPath, size: stat?.size, mtime: stat?.mtime)
    }

    // MARK: - 上传查重名

    /// 上传前的覆盖检查：列一次 `directory`，返回 `names` 中远端已存在的那些
    /// （即会被覆盖 / 截断的文件）。空数组 = 没有冲突。
    ///
    /// 列目录失败时返回空——宁可照常上传（带原有错误处理），也不因列目录失败误报覆盖。
    static func existingNames(
        _ names: [String],
        in directory: String,
        provider: any SFTPProviding
    ) async -> [String] {
        guard !names.isEmpty,
              let listed = try? await provider.list(path: directory) else { return [] }
        let existing = Set(listed.map(\.name))
        return names.filter { existing.contains($0) }
    }

    // MARK: - 属主名补全

    /// 一次 exec 补多少条的属主名（命令行长度与单次往返的折中）。
    static let ownerStatChunkSize = 80

    /// SFTP 只给数字 uid / gid；经 exec 跑 `stat` 把用户名 / 组名补上。
    /// 某一批 exec 失败或输出行数对不上时那一批保持原样（UI 回退数字 ID）。
    static func resolveOwnerNames(
        for entries: [RemoteEntry],
        in directory: String,
        provider: any SFTPProviding
    ) async -> [RemoteEntry] {
        guard !entries.isEmpty else { return entries }
        var resolved = entries
        let indexedEntries = entries.enumerated()
            .filter { $0.element.uid != nil || $0.element.gid != nil }
            .map { (index: $0.offset, entry: $0.element) }
        guard !indexedEntries.isEmpty else { return entries }

        for start in stride(from: 0, to: indexedEntries.count, by: ownerStatChunkSize) {
            let end = min(start + ownerStatChunkSize, indexedEntries.count)
            let chunk = Array(indexedEntries[start..<end])
            let paths = chunk.map { RemotePath.join(directory, $0.entry.name) }
            guard let output = try? await provider.exec(ownerStatCommand(paths: paths)) else { continue }
            let rows = parseOwnerStatOutput(output)
            guard rows.count == chunk.count else { continue }
            for (indexed, row) in zip(chunk, rows) {
                resolved[indexed.index] = applying(row, to: indexed.entry)
            }
        }
        return resolved
    }

    /// `stat` 一行的解析结果。
    struct OwnerStatRow: Equatable, Sendable {
        let uid: UInt32?
        let gid: UInt32?
        let ownerName: String?
        let groupName: String?
    }

    /// GNU `stat -c` 优先，失败回退 BSD `stat -f`；输出每行 `uid\tgid\tuser\tgroup`。
    static func ownerStatCommand(paths: [String]) -> String {
        let quotedPaths = paths.map(RemotePath.shellQuote).joined(separator: " ")
        let gnuFormat = RemotePath.shellQuote("%u\t%g\t%U\t%G")
        let bsdFormat = RemotePath.shellQuote("%u\t%g\t%Su\t%Sg")
        return "(stat -c \(gnuFormat) -- \(quotedPaths) 2>/dev/null) || " +
            "stat -f \(bsdFormat) \(quotedPaths) 2>/dev/null"
    }

    static func parseOwnerStatOutput(_ output: String) -> [OwnerStatRow] {
        output.split(whereSeparator: \.isNewline).compactMap { line in
            let fields = line.split(separator: "\t", omittingEmptySubsequences: false)
            guard fields.count >= 4 else { return nil }
            let uid = UInt32(fields[0])
            let gid = UInt32(fields[1])
            return OwnerStatRow(
                uid: uid,
                gid: gid,
                ownerName: normalizedOwnerName(fields[2], numericID: uid),
                groupName: normalizedOwnerName(fields[3], numericID: gid))
        }
    }

    /// 只在 `stat` 报的 uid / gid 与列表一致时才采用名字（文件在两次往返之间被 chown 过就不认）。
    static func applying(_ row: OwnerStatRow, to entry: RemoteEntry) -> RemoteEntry {
        let uid = row.uid ?? entry.uid
        let gid = row.gid ?? entry.gid
        let ownerName = row.uid == entry.uid || entry.uid == nil ? row.ownerName : nil
        let groupName = row.gid == entry.gid || entry.gid == nil ? row.groupName : nil
        return entry.withOwnerInfo(uid: uid, gid: gid, ownerName: ownerName, groupName: groupName)
    }

    private static func normalizedOwnerName(_ raw: Substring, numericID: UInt32?) -> String? {
        let value = String(raw).trimmingCharacters(in: .whitespacesAndNewlines)
        guard !value.isEmpty, value != "UNKNOWN", value != "?" else { return nil }
        if let numericID, value == String(numericID) { return nil }
        return value
    }
}
