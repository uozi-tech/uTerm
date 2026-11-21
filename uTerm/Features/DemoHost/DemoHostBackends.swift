import Foundation

/// 体验主机：一台不联网、不受订阅限制的演示主机（审核员和没有服务器的新用户都能直接用）。
/// 文件系统每个进程一份，终端标签与文件标签共用，所以两边看到的是同一批文件。
nonisolated enum DemoHost {
    static let fileSystem = DemoFileSystem()
    /// 上传到体验主机的单个文件上限：文件都在内存里，别让一个大文件把 App 撑爆。
    static let maxFileBytes = 20 * 1024 * 1024
}

/// 体验主机的终端后端：键盘字节交给 `DemoShell`，它的回显与输出原样进输出泵。
actor DemoTerminalBackend: TerminalBackend {
    nonisolated let outputItems: AsyncStream<TerminalOutputItem>
    nonisolated let exitStream: AsyncStream<Void>
    private let output: TerminalByteOutput
    private let exitContinuation: AsyncStream<Void>.Continuation
    private let shell: DemoShell
    /// 一个 UTF-8 字符可能被拆在两次写入里（粘贴长文本时），凑齐了再交给 shell。
    private var pendingBytes = Data()
    private var finished = false

    init(fileSystem: DemoFileSystem = DemoHost.fileSystem) {
        let output = TerminalByteOutput()
        self.output = output
        outputItems = output.items
        (exitStream, exitContinuation) = AsyncStream.makeStream(of: Void.self)
        shell = DemoShell(fs: fileSystem)
    }

    func connect() async throws {
        guard !finished else { return }
        output.send(Data(shell.start().utf8))
    }

    func write(_ data: Data) async {
        guard !finished else { return }
        pendingBytes.append(data)
        guard let text = String(data: pendingBytes, encoding: .utf8) ?? (pendingBytes.count > 8
            ? String(decoding: pendingBytes, as: UTF8.self) : nil) else { return }
        pendingBytes.removeAll()
        let (echo, exited) = shell.receive(text)
        if !echo.isEmpty { output.send(Data(echo.utf8)) }
        if exited {
            exitContinuation.yield()
            finish()
        }
    }

    func resize(cols: UInt16, rows: UInt16) async {}

    func close() async { finish() }

    /// 模拟 shell 没有前台程序：关标签不用二次确认。
    func foregroundActivity() async -> TerminalActivity { .idle }

    private func finish() {
        guard !finished else { return }
        finished = true
        output.finish()
        exitContinuation.finish()
    }
}

/// 体验主机的文件通道：`SFTPProviding` 落在同一份 `DemoFileSystem` 上；`exec`（文件页的搜索、递归改权限）
/// 交给一个非交互的 `DemoShell`。
actor DemoSFTPProvider: SFTPProviding {
    private let fs: DemoFileSystem
    private let shell: DemoShell

    init(fileSystem: DemoFileSystem = DemoHost.fileSystem) {
        fs = fileSystem
        shell = DemoShell(fs: fileSystem)
    }

    private func absolute(_ path: String) -> String {
        DemoFileSystem.normalize(path.isEmpty ? "." : path, cwd: DemoFileSystem.home)
    }

    private static func entry(name: String, node: DemoFileSystem.Node) -> RemoteEntry {
        RemoteEntry(name: name, posixPermissions: (node.isDirectory ? 0o040000 : 0o100000) | node.mode,
                    size: UInt64(node.size), modifiedAt: node.mtime,
                    uid: DemoFileSystem.uid, gid: DemoFileSystem.uid,
                    ownerName: DemoFileSystem.user, groupName: DemoFileSystem.user)
    }

    func list(path: String) async throws -> [RemoteEntry] {
        try fs.children(of: absolute(path)).map { Self.entry(name: $0.name, node: $0.node) }
    }

    func realPath(_ path: String) async throws -> String {
        let resolved = absolute(path)
        guard fs.node(at: resolved) != nil else { throw DemoFSError.noSuchFile(path) }
        return resolved
    }

    func download(remotePath: String) async throws -> Data {
        try fs.read(absolute(remotePath))
    }

    func upload(data: Data, toRemotePath: String) async throws {
        try store(toRemotePath, data: data)
    }

    func write(_ path: String, data: Data) async throws {
        try store(path, data: data)
    }

    private func store(_ path: String, data: Data) throws {
        guard data.count <= DemoHost.maxFileBytes else { throw DemoUploadTooLarge() }
        try fs.write(absolute(path), data: data)
    }

    func stat(_ path: String) async throws -> RemoteStat {
        guard let node = fs.node(at: absolute(path)) else { throw DemoFSError.noSuchFile(path) }
        return RemoteStat(size: Int64(node.size), mtime: node.mtime,
                          permissions: (node.isDirectory ? 0o040000 : 0o100000) | node.mode)
    }

    func exec(_ command: String) async throws -> String {
        shell.run(command)
    }

    func rename(_ path: String, to newPath: String) async throws {
        let dest = absolute(newPath)
        guard fs.node(at: dest) == nil else { throw DemoFSError.exists(newPath) }
        try fs.move(absolute(path), to: dest)
    }

    func removeFile(_ path: String) async throws {
        try fs.remove(absolute(path))
    }

    func removeDirectory(_ path: String) async throws {
        let target = absolute(path)
        guard fs.isDirectory(target) else { throw DemoFSError.notDirectory(path) }
        try fs.remove(target, allowEmptyDirectory: true)
    }

    func createDirectory(_ path: String) async throws {
        try fs.mkdir(absolute(path))
    }

    func createFile(_ path: String) async throws {
        let target = absolute(path)
        if fs.node(at: target) != nil { throw SFTPFileExistsError(path: path) }
        try fs.touch(target, exclusive: true)
    }

    func setPermissions(path: String, mode: UInt32) async throws {
        try fs.chmod(absolute(path), mode: mode)
    }

    func upload(data: Data, toRemotePath: String,
                onProgress: (@Sendable (TransferProgress) -> Void)?) async throws {
        try store(toRemotePath, data: data)
        onProgress?(TransferProgress(bytesDone: Int64(data.count), bytesTotal: Int64(data.count)))
    }

    func download(remotePath: String,
                  onProgress: (@Sendable (TransferProgress) -> Void)?) async throws -> Data {
        let data = try fs.read(absolute(remotePath))
        onProgress?(TransferProgress(bytesDone: Int64(data.count), bytesTotal: Int64(data.count)))
        return data
    }

    func download(remotePath: String, toLocalURL localURL: URL,
                  onProgress: (@Sendable (TransferProgress) -> Void)?) async throws {
        let data = try fs.read(absolute(remotePath))
        try data.write(to: localURL, options: .atomic)
        onProgress?(TransferProgress(bytesDone: Int64(data.count), bytesTotal: Int64(data.count)))
    }

    func upload(localURL: URL, toRemotePath: String,
                onProgress: (@Sendable (TransferProgress) -> Void)?) async throws {
        let size = (try? localURL.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0
        guard size <= DemoHost.maxFileBytes else { throw DemoUploadTooLarge() }
        let data = try Data(contentsOf: localURL)
        try store(toRemotePath, data: data)
        onProgress?(TransferProgress(bytesDone: Int64(data.count), bytesTotal: Int64(data.count)))
    }

    func close() async {}
}

nonisolated struct DemoUploadTooLarge: LocalizedError {
    var errorDescription: String? { String(localized: "体验主机的文件都放在内存里，单个文件不能超过 20 MB。") }
}
