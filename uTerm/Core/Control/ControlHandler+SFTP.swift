import Foundation

/// 文件组：`sftp-ls` / `sftp-stat` / `sftp-cat` / `sftp-get` /
/// `sftp-put` / `sftp-mkdir` / `sftp-rm` / `sftp-rmdir` / `sftp-mv` / `sftp-chmod`。
///
/// 硬约束：
/// - **本地文件 I/O 由 CLI 做**。uTerm 是沙盒 app，写不了任意本地路径；socket 上
///   只传 base64（`sftp-put`）或文本 / base64（`sftp-cat` / `sftp-get`）。
/// - 上限：`cat` 1 MiB（`maxCatBytes`），`get` / `put` 8 MiB（`maxFileBytes`），
///   超限一律 `file_too_large`，不要先整个读进内存再判 —— 用
///   `SFTPProviding.download(remotePath:maximumBytes:)` 的有界入口。
/// - 删除类动作在技能文档层面要求先问用户。
///
/// Wave 2 待填：十个动作的实现。
extension ControlHandler {

    func handleSFTP(
        _ request: ControlRequest,
        _ deps: Dependencies
    ) async throws -> ControlResponse {
        switch request.action {
        case .sftpLs, .sftpStat, .sftpCat, .sftpGet,
             .sftpPut, .sftpMkdir, .sftpRm, .sftpRmdir, .sftpMv, .sftpChmod:
            // Wave 2：resolveHost → pool.sftp(for:) → 对应 SFTPProviding 调用 →
            // ControlRemoteEntry / ControlRemoteStat / ControlFilePayload。
            throw ControlFailure.notImplemented(request.action.rawValue)
        default:
            throw ControlFailure(
                code: .invalid_request,
                message: "动作 \(request.action.rawValue) 不属于文件组"
            )
        }
    }
}
