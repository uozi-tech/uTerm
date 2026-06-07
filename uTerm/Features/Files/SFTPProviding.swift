import Foundation

// MARK: - RemoteStat

/// 远程文件的轻量元信息快照（size + mtime）。
nonisolated struct RemoteStat: Sendable, Equatable {
    let size: Int64
    let mtime: Date
}

// MARK: - TransferProgress

/// 单次传输的进度快照。`bytesTotal == 0` 视为未知总量。
nonisolated struct TransferProgress: Sendable, Equatable {
    let bytesDone: Int64
    let bytesTotal: Int64
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

    /// 上传数据到远程路径。
    func upload(data: Data, toRemotePath: String) async throws

    /// 把 `data` 完整写到 `path`（覆盖）。
    func write(_ path: String, data: Data) async throws

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

    /// 设置文件权限（chmod，单个路径，非递归）。`mode` 取低 9 位（`& 0o777`），
    /// 只改权限位、保留文件类型位。递归由上层走 exec `chmod -R`（见 FileBrowserModel）。
    func setPermissions(path: String, mode: UInt32) async throws

    // MARK: 带进度的传输（既有无进度重载保留不动）
    func upload(data: Data, toRemotePath: String,
                onProgress: (@Sendable (TransferProgress) -> Void)?) async throws
    func download(remotePath: String,
                  onProgress: (@Sendable (TransferProgress) -> Void)?) async throws -> Data

    func close() async
}
