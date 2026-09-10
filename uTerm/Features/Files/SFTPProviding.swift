import Foundation

// MARK: - RemoteStat

/// 远程文件的轻量元信息快照（size + mtime + 权限）。
nonisolated struct RemoteStat: Sendable, Equatable {
    let size: Int64
    let mtime: Date
    /// 原始 POSIX mode（**含类型位**，与 `RemoteEntry.permissions` 同义）。
    /// 服务端没给 `SSH_FILEXFER_ATTR_PERMISSIONS` 时为 nil。
    let permissions: UInt32?

    init(size: Int64, mtime: Date, permissions: UInt32? = nil) {
        self.size = size
        self.mtime = mtime
        self.permissions = permissions
    }
}

// MARK: - TransferProgress

/// 单次传输的进度快照。`bytesTotal == 0` 视为未知总量。
nonisolated struct TransferProgress: Sendable, Equatable {
    let bytesDone: Int64
    let bytesTotal: Int64
}

/// 有界下载超过调用方上限。`observedBytes` 来自下载前 stat，或流式读取时实际
/// 看到的字节数；两条路径都让调用方能在分配无界内存前终止。
nonisolated struct SFTPDownloadLimitExceeded: Error, Sendable, Equatable {
    let observedBytes: Int64
    let maximumBytes: Int
}

/// `create` 模式撞上已存在的文件。
///
/// 真实的 `SFTPSession` 走 SSH_FXF_EXCL，服务端回的是 `SSH_FX_FAILURE`（v3 没有
/// 「已存在」这个码）；内存替身抛这个强类型错误。两条路径最后都被
/// `ControlFilePayloadBuilder.errorCode(for:)` 归到 `file_exists`。
nonisolated struct SFTPFileExistsError: Error, Sendable, Equatable {
    let path: String

    init(path: String) { self.path = path }
}

/// `writeRange` 的打开语义。
nonisolated enum SFTPWriteMode: String, Sendable, CaseIterable {
    /// 已存在 → 失败（SSH_FXF_CREAT | SSH_FXF_EXCL）。默认档，防止误覆盖。
    case create
    /// 截断后写（SSH_FXF_CREAT | SSH_FXF_TRUNC）。
    case overwrite
    /// 不截断、写到给定 offset，不存在则创建（SSH_FXF_CREAT）。多分片并行写同一文件用这档。
    case write
}

/// 控制真实传输进度回调频率：首个数据块立即上报，后续按时间节流，完成必达。
nonisolated struct TransferProgressEmitter: Sendable {
    private let totalBytes: Int64
    private let minimumInterval: TimeInterval
    private var lastEmittedBytes: Int64?
    private var lastEmittedAt: Date?
    private var emittedNonZero = false

    init(totalBytes: Int64, minimumInterval: TimeInterval = 0.25) {
        self.totalBytes = max(0, totalBytes)
        self.minimumInterval = max(0, minimumInterval)
    }

    mutating func shouldEmit(bytesDone: Int64, at now: Date = Date()) -> Bool {
        let upperBound = totalBytes > 0 ? totalBytes : Int64.max
        let clampedBytes = min(max(0, bytesDone), upperBound)
        guard let lastEmittedBytes else {
            record(bytesDone: clampedBytes, at: now)
            return true
        }
        guard clampedBytes > lastEmittedBytes else { return false }
        if clampedBytes > 0, !emittedNonZero {
            record(bytesDone: clampedBytes, at: now)
            return true
        }
        if totalBytes > 0, clampedBytes >= totalBytes {
            record(bytesDone: clampedBytes, at: now)
            return true
        }
        if let lastEmittedAt, now.timeIntervalSince(lastEmittedAt) >= minimumInterval {
            record(bytesDone: clampedBytes, at: now)
            return true
        }
        return false
    }

    private mutating func record(bytesDone: Int64, at date: Date) {
        lastEmittedBytes = bytesDone
        lastEmittedAt = date
        if bytesDone > 0 { emittedNonZero = true }
    }
}

// MARK: - SFTPProviding

/// `FileBrowserModel` 和文件预览层依赖的 SFTP 抽象 —— 便于用 `MockSFTP` 单测。
protocol SFTPProviding: Actor {
    func list(path: String) async throws -> [RemoteEntry]
    func realPath(_ path: String) async throws -> String

    /// 下载远程文件，返回完整内容。
    func download(remotePath: String) async throws -> Data

    /// 有界下载。预览不可信远程资源时必须走此入口，不能先完整读入再检查大小。
    func download(remotePath: String, maximumBytes: Int) async throws -> Data

    /// 上传数据到远程路径。
    func upload(data: Data, toRemotePath: String) async throws

    /// 把 `data` 完整写到 `path`（覆盖）。
    func write(_ path: String, data: Data) async throws

    /// 把 `data` 写到 `path` 的 `[offset, offset + data.count)`，按 `mode` 决定打开语义。
    /// 分片 / 断点续传的基础原语：多个 `.write` 调用可以并行落在同一文件的不同区间。
    func writeRange(_ path: String, offset: UInt64, data: Data, mode: SFTPWriteMode) async throws

    /// 读 `path` 的 `[offset, offset + length)`。到 EOF 会短（返回的字节数少于 `length`），
    /// 不是错误。
    func readRange(_ path: String, offset: UInt64, length: Int) async throws -> Data

    /// 获取远程文件元信息（size + mtime）。文件不存在时抛错。
    func stat(_ path: String) async throws -> RemoteStat

    /// 在连接上跑一条一次性命令（非交互 exec channel），返回合并后的输出。
    /// 供遥测复用 SFTP 的 SSH 连接，不碰交互 PTY。compound 命令（`;` / 管道 /
    /// 重定向）由 sshd 交给登录 shell 执行，故可直接传整串。
    func exec(_ command: String) async throws -> String

    // MARK: 目录 / 改名 / 删除
    func rename(_ path: String, to newPath: String) async throws
    func removeFile(_ path: String) async throws
    func removeDirectory(_ path: String) async throws
    func createDirectory(_ path: String) async throws

    /// 新建一个空文件（fail-if-exists：路径已存在则抛错，绝不覆盖既有文件）。
    func createFile(_ path: String) async throws

    /// 设置文件权限（chmod，单个路径，非递归）。`mode` 取低 9 位（`& 0o777`），
    /// 只改权限位、保留文件类型位。递归由上层走 exec `chmod -R`（见 FileBrowserModel）。
    func setPermissions(path: String, mode: UInt32) async throws

    // MARK: 带进度的传输（既有无进度重载保留不动）
    func upload(data: Data, toRemotePath: String,
                onProgress: (@Sendable (TransferProgress) -> Void)?) async throws
    func download(remotePath: String,
                  onProgress: (@Sendable (TransferProgress) -> Void)?) async throws -> Data

    /// 把远端文件流式写到本地 URL。实现必须使用固定大小缓冲，并在成功前通过同目录
    /// 临时文件保护既有目标；失败或取消不能留下半截目标文件。
    func download(remotePath: String, toLocalURL localURL: URL,
                  onProgress: (@Sendable (TransferProgress) -> Void)?) async throws

    /// 从本地文件 URL 流式上传；不能先构造文件大小级的 `Data`。
    func upload(localURL: URL, toRemotePath: String,
                onProgress: (@Sendable (TransferProgress) -> Void)?) async throws

    /// 主动探测底层连接是否仍然存活（系统唤醒 / 网络恢复后由看门狗触发）。
    /// 判死的实现应自行强制关闭底层连接，让后续操作快速失败（而非挂死），
    /// 由调用方的刷新/重连路径接管。
    func verifyConnectionAlive() async -> Bool

    func close() async
}

extension SFTPProviding {
    /// 通用实现先 stat 拦截已知超限文件，再对返回值复核。真实 `SFTPSession`
    /// 另有流式实现，可覆盖 stat 竞态/未知大小；测试 mock 复用这里即可。
    func download(remotePath: String, maximumBytes: Int) async throws -> Data {
        let limit = max(0, maximumBytes)
        let metadata = try await stat(remotePath)
        if metadata.size > Int64(limit) {
            throw SFTPDownloadLimitExceeded(observedBytes: metadata.size,
                                            maximumBytes: limit)
        }
        let data = try await download(remotePath: remotePath)
        guard data.count <= limit else {
            throw SFTPDownloadLimitExceeded(observedBytes: Int64(data.count),
                                            maximumBytes: limit)
        }
        return data
    }

    /// 默认恒真 —— 非网络实现（测试 mock）没有「静默断死」的概念。
    func verifyConnectionAlive() async -> Bool { true }

    /// 通用回退：读回整文件 → 按 offset 打补丁 → 整文件写回。
    ///
    /// 只对**内存替身**成立（测试夹具全部靠它，不必各自重写一遍语义）。真实的
    /// `SFTPSession` 覆盖成真正的随机写：不读回、不整写，多个分片可以并行落盘。
    func writeRange(_ path: String, offset: UInt64, data: Data,
                    mode: SFTPWriteMode) async throws {
        let exists = (try? await stat(path)) != nil
        var base: Data
        switch mode {
        case .create:
            if exists { throw SFTPFileExistsError(path: path) }
            base = Data()
        case .overwrite:
            base = Data()
        case .write:
            // `Data(...)` 归一化 startIndex —— 下面用的是从 0 起的相对下标。
            base = exists ? Data((try? await download(remotePath: path)) ?? Data()) : Data()
        }
        let start = Int(clamping: offset)
        // 越过末尾的写在 POSIX 下留空洞（读回来是 0），内存实现照做。
        if base.count < start { base.append(Data(count: start - base.count)) }
        let end = start + data.count
        if base.count < end { base.append(Data(count: end - base.count)) }
        if !data.isEmpty { base.replaceSubrange(start..<end, with: data) }
        try await write(path, data: base)
    }

    /// 通用回退：整文件读回后切片。真实实现覆盖成单次区间读。
    func readRange(_ path: String, offset: UInt64, length: Int) async throws -> Data {
        guard length > 0 else { return Data() }
        // 重新装一次：`download` 的返回值理论上可能是个带非零 startIndex 的切片，
        // 而下面用的是从 0 起的相对下标。
        let all = Data(try await download(remotePath: path))
        let start = min(Int(clamping: offset), all.count)
        let end = min(start + length, all.count)
        guard start < end else { return Data() }
        return all.subdata(in: start..<end)
    }
}
