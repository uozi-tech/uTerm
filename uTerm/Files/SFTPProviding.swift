import Foundation

// MARK: - RemoteStat

/// 远程文件的轻量元信息快照（size + mtime）。
nonisolated struct RemoteStat: Sendable, Equatable {
    let size: Int64
    let mtime: Date
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

    func close() async
}
