import Foundation
import USSHKit

/// 记录目录「不存在」只认明确的说法：数据源据此判断这台主机上没用过某种工具（列表里就没有它的会话）。
///
/// 别的失败（辅助程序一时连不上、断线、超时、没权限）一律不算：当成「没用过」的话，后台重列会把整个侧栏清空
/// （2026-11-25 实测：Code 标签页里起 / 结束一个会话之后，侧栏只剩顶上跑着的那几行）。说不清的照常报错，
/// 列表留着上一次列到的，下次重列再试。
nonisolated enum AgentHistoryMissingPath {
    /// 这个错误明确说路径不在（或者路径上有一段不是目录）。
    static func isNotFound(_ error: any Error) -> Bool {
        if let remote = error as? RemoteFileError { return remote.code == .notFound || remote.code == .notDirectory }
        if let sftp = error as? SFTPError { return sftp.statusCode == .noSuchFile || sftp.statusCode == .noSuchPath }
        if let code = FriendlyError.posixErrno(of: error) { return code == ENOENT || code == ENOTDIR }
        let nsError = error as NSError
        if nsError.domain == NSCocoaErrorDomain {
            return nsError.code == NSFileNoSuchFileError || nsError.code == NSFileReadNoSuchFileError
        }
        return false
    }

    /// 这个错误明确说没权限：不会自己好起来，跳过那一处不算「少列了」。
    static func isPermissionDenied(_ error: any Error) -> Bool {
        if let remote = error as? RemoteFileError { return remote.code == .permissionDenied }
        if let sftp = error as? SFTPError { return sftp.statusCode == .permissionDenied }
        if let code = FriendlyError.posixErrno(of: error) { return code == EACCES || code == EPERM }
        return false
    }

    /// 列 `path` 失败之后，它是不是确实不存在：列的错误本身说不存在，或者再 `stat` 一次说不存在（有的 SFTP 服务端
    /// 列不存在的目录只回一个笼统的失败）。`stat` 成功、或者也说不清的，为 false。
    static func confirmsAbsent(_ path: String, after listError: any Error, provider: any SFTPProviding) async -> Bool {
        if isNotFound(listError) { return true }
        do {
            _ = try await provider.stat(path)
            return false
        } catch {
            return isNotFound(error)
        }
    }
}

/// 历史会话的日志：只记事情的种类，不记路径、标题、对话（错误的说明里常带着路径）。
nonisolated enum AgentHistoryLog {
    static let category = "agent-history"

    /// 错误是哪一类：远控 / 辅助程序的文件服务报的码，SFTP 的状态码，或者错误的类型与 `NSError` 的域和码。
    static func kind(of error: any Error) -> String {
        if let remote = error as? RemoteFileError { return "file-service:\(remote.code.rawValue)" }
        if let sftp = error as? SFTPError, let code = sftp.statusCode { return "sftp:\(code)" }
        let nsError = error as NSError
        return "\(String(reflecting: type(of: error))) \(nsError.domain)#\(nsError.code)"
    }
}
