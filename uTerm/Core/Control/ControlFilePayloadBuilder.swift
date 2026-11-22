import Foundation
@preconcurrency import Citadel

/// 文件组（`sftp-*`）的纯逻辑：线上形状构造、SFTP 错误归类、权限串解析。
///
/// 全部是 `nonisolated` 静态函数，不碰网络 / SwiftData / MainActor ——
/// `ControlSFTPHandlerTests` 直接对它们断言，handler 只负责取数据与包响应。
nonisolated enum ControlFilePayloadBuilder {

    /// `RemoteEntry` → 线上形状。时间转 ISO8601，权限保留含类型位的原始 mode。
    static func entry(_ remote: RemoteEntry) -> ControlRemoteEntry {
        ControlRemoteEntry(
            name: remote.name,
            isDirectory: remote.isDirectory,
            isSymlink: remote.isSymlink,
            size: remote.size,
            modifiedAt: ControlProtocol.iso8601(remote.modifiedAt),
            permissions: remote.permissions,
            uid: remote.uid,
            gid: remote.gid,
            ownerName: remote.ownerName,
            groupName: remote.groupName
        )
    }

    static func entries(_ remotes: [RemoteEntry]) -> [ControlRemoteEntry] {
        remotes.map(entry)
    }

    /// `RemoteStat` → 线上形状（附解析后的路径）。权限保留含类型位的原始 mode，
    /// 与 `entry(_:)` 一致；`kind` 由类型位推出。
    static func stat(path: String, _ remote: RemoteStat) -> ControlRemoteStat {
        ControlRemoteStat(
            path: path,
            size: remote.size,
            // `modifiedAt` 非可选；`iso8601` 只在 date 为 nil 时回 nil，这里必有值。
            modifiedAt: ControlProtocol.iso8601(remote.mtime) ?? "",
            permissions: remote.permissions.map { Int($0) },
            kind: kind(mode: remote.permissions)
        )
    }

    /// POSIX mode 的类型位 → `file` / `directory` / `symlink`；socket / fifo /
    /// 字符设备之类统一 `other`。mode 为 nil 时 nil（宁可不说，也不谎称是普通文件）。
    static func kind(mode: UInt32?) -> String? {
        guard let mode else { return nil }
        switch mode & UInt32(S_IFMT) {
        case UInt32(S_IFDIR): return "directory"
        case UInt32(S_IFLNK): return "symlink"
        case UInt32(S_IFREG): return "file"
        default: return "other"
        }
    }

    /// 文件载荷。UTF-8 可解码 → `text`，否则 `base64`（二进制原样回给 CLI 落盘）。
    ///
    /// `declaredSize` 是**下载前 stat 量到的大小**：它大于实际拿到的字节数即说明内容被
    /// 削过（`truncated`）。传 nil（拿不到 stat）时一律视为未截断 —— 宁可少报也不谎报。
    static func payload(
        path: String,
        data: Data,
        declaredSize: Int64?
    ) -> ControlFilePayload {
        let text = String(data: data, encoding: .utf8)
        let truncated: Bool = {
            guard let declaredSize else { return false }
            return declaredSize > Int64(data.count)
        }()
        return ControlFilePayload(
            path: path,
            bytes: data.count,
            isUTF8: text != nil,
            text: text,
            base64: text == nil ? data.base64EncodedString() : nil,
            truncated: truncated
        )
    }

    /// `sftp-put` 的响应载荷：只报本次写入的字节数，不回显内容。
    static func written(path: String, bytes: Int) -> ControlFilePayload {
        ControlFilePayload(
            path: path,
            bytes: bytes,
            isUTF8: false,
            text: nil,
            base64: nil,
            truncated: false
        )
    }

    // MARK: - 错误归类

    /// SFTP 操作失败 → 协议错误码。
    ///
    /// 优先按**强类型**判：`SFTPDownloadLimitExceeded`（有界下载超限）→
    /// 服务端状态码（最可靠）→ POSIX errno → 最后才退到大小写无关的文本匹配
    /// （覆盖被包成文本的底层错误）。
    ///
    /// ⚠️ 服务端状态码有**两种**装法，都要认（真机上命中的是第二种）：
    /// - `SFTPError.errorStatus(status)`：Citadel 里只有 `setAttributes` 这一条
    ///   路径显式包过（`SFTPClient.setAttributes`）；
    /// - **裸的 `SFTPMessage.Status`**：`SFTPClientInboundHandler.channelRead` 对
    ///   一切非 `ok`/`eof` 的响应直接 `promise.fail(status)` —— `remove` / `rmdir` /
    ///   `rename` / `mkdir` / `getAttributes` / `open` 全走这条，抛出来的就是
    ///   `SFTPMessage.Status` 本身，`as? SFTPError` 永远匹配不上。
    ///   （`SFTPMessage.Status` 只是 `Error`、不是 `LocalizedError`，所以它的
    ///   `localizedDescription` 经 `any Error` 走的是 NSError 桥接的那句
    ///   「操作未能完成」，文本兜底也匹配不到 —— `sftp rm` 一个不存在的文件
    ///   于是回了 `operation_failed`。）
    ///
    /// 「文件已存在」有专码 `file_exists`（`sftp-put` 的 `create` 默认档要用），
    /// 它有三条来源：内存替身的 `SFTPFileExistsError`、errno `EEXIST`、以及
    /// 服务端文案里的 "file exists" / "already exists"。SFTP v3 撞 EXCL 时只回
    /// `SSH_FX_FAILURE`，文案还依实现而定，所以 handler 在落到 `operation_failed`
    /// 时会再 `stat` 一次兜底（见 `ControlHandler.putErrorCode`）。
    ///
    /// 其余没有专码的失败（目录不为空之类）一律落到 `operation_failed`
    /// —— 它是协议的兜底码，比借用一个语义不符的码诚实。
    static func errorCode(for rawError: Error) -> ControlErrorCode {
        // `writeRange` 给「打开阶段」的失败包了一层阶段标记（见 `SFTPWriteStageError`）；
        // 归类前先剥掉，否则服务端状态码被藏在里面，一切都落到 operation_failed。
        let error = SFTPWriteStageError.unwrap(rawError)
        if error is SFTPDownloadLimitExceeded { return .file_too_large }
        if error is SFTPShortReadError { return .operation_failed }
        if error is SFTPFileExistsError { return .file_exists }

        if let status = sftpStatus(of: error) {
            switch status.errorCode {
            case .noSuchFile: return .file_not_found
            case .permissionDenied: return .permission_denied
            // SSH_FX_FILE_ALREADY_EXISTS（v4+，v3 只会回 failure + 文案）。
            case .unknown(11): return .file_exists
            default:
                // 服务端把 EISDIR 之类塞在 failure 的文本里，再过一遍文本匹配。
                return errorCode(forText: status.message) ?? .operation_failed
            }
        }

        if let errno = FriendlyError.posixErrno(of: error) {
            switch errno {
            case ENOENT: return .file_not_found
            case EACCES, EPERM: return .permission_denied
            case EISDIR: return .is_directory
            case EEXIST: return .file_exists
            default: break
            }
        }

        return errorCode(forText: error.localizedDescription) ?? .operation_failed
    }

    /// 取出 Citadel 的服务端状态（两种装法都认，见 `errorCode(for:)`）。
    static func sftpStatus(of error: Error) -> SFTPMessage.Status? {
        if let status = error as? SFTPMessage.Status { return status }
        if let sftp = error as? SFTPError, case .errorStatus(let status) = sftp { return status }
        return nil
    }

    /// 失败的**原话**，给 CLI 的 `message` 用。
    ///
    /// CLI 面向模型 / 开发者，`FriendlyError.describe` 那句「操作未能完成，请稍后
    /// 重试」对排查毫无价值。服务端状态在的话优先给它自带的文案 + `SSH_FX` 码
    /// （`No such file (SSH_FX 2)`），否则退到 `String(describing:)`。
    static func errorDetail(for rawError: Error) -> String {
        let error = SFTPWriteStageError.unwrap(rawError)
        if let status = sftpStatus(of: error) {
            let text = status.message.trimmingCharacters(in: .whitespacesAndNewlines)
            let code = "SSH_FX \(status.errorCode.rawValue)"
            return text.isEmpty ? code : "\(text)（\(code)）"
        }
        if let limit = error as? SFTPDownloadLimitExceeded {
            return String(localized: "内容超过本次上限（\(String(limit.observedBytes)) > \(String(limit.maximumBytes)) 字节）")
        }
        if let short = error as? SFTPShortReadError {
            return short.localizedDescription
        }
        return String(describing: error)
    }

    /// 文本兜底匹配。返回 nil = 没有可靠结论（调用方落 `operation_failed`）。
    static func errorCode(forText raw: String) -> ControlErrorCode? {
        let text = raw.lowercased()
        if text.contains("is a directory") || text.contains("eisdir") {
            return .is_directory
        }
        if text.contains("no such file") || text.contains("not found")
            || text.contains("does not exist") || text.contains("enoent") {
            return .file_not_found
        }
        if text.contains("permission denied") || text.contains("access denied")
            || text.contains("eacces") || text.contains("eperm") {
            return .permission_denied
        }
        if text.contains("too large") || text.contains("efbig") {
            return .file_too_large
        }
        if text.contains("file exists") || text.contains("already exists")
            || text.contains("eexist") {
            return .file_exists
        }
        return nil
    }
}

/// `sftp-chmod` 的 `mode` 解析。
///
/// 请求字段是字符串（JSON 里的数字解不进 `String?`），所以两种写法都要认：
/// - **八进制**（chmod 的日常写法）：`"644"` / `"0644"` / `"0o644"` / `"755"`；
/// - **十进制**：数位里出现 8 或 9 时不可能是八进制，按十进制读（如 `"420"` 会被当
///   八进制 `0o420`，这是 chmod 语义下唯一合理的默认，文档要写明）。
///
/// 超过 `0o7777`（含 setuid / setgid / sticky）视为非法。
nonisolated enum ControlFileMode {

    static func parse(_ raw: String?) -> UInt32? {
        guard let raw else { return nil }
        var text = raw.trimmingCharacters(in: .whitespaces)
        guard !text.isEmpty else { return nil }

        var radix = 8
        if text.hasPrefix("0o") || text.hasPrefix("0O") {
            text = String(text.dropFirst(2))
        } else if text.contains("8") || text.contains("9") {
            radix = 10
        }
        guard !text.isEmpty, text.allSatisfy(\.isNumber) else { return nil }
        guard let value = UInt32(text, radix: radix) else { return nil }
        guard value <= 0o7777 else { return nil }
        return value
    }
}
