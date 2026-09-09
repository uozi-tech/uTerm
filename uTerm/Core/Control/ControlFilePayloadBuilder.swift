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

    /// `RemoteStat` → 线上形状（附解析后的路径）。
    static func stat(path: String, _ remote: RemoteStat) -> ControlRemoteStat {
        ControlRemoteStat(
            path: path,
            size: remote.size,
            modifiedAt: ISO8601DateFormatter().string(from: remote.mtime)
        )
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

    // MARK: - 错误归类

    /// SFTP 操作失败 → 协议错误码。
    ///
    /// 优先按**强类型**判：`SFTPDownloadLimitExceeded`（有界下载超限）→
    /// Citadel `SFTPError.errorStatus`（服务端状态码，最可靠）→ POSIX errno →
    /// 最后才退到大小写无关的文本匹配（覆盖被包成文本的底层错误）。
    ///
    /// 契约里没有「目录不为空 / 文件已存在」这类码，一律落到 `operation_failed`
    /// —— 它是协议的兜底码，比借用一个语义不符的码诚实。
    static func errorCode(for error: Error) -> ControlErrorCode {
        if error is SFTPDownloadLimitExceeded { return .file_too_large }

        if let sftp = error as? SFTPError, case .errorStatus(let status) = sftp {
            switch status.errorCode {
            case .noSuchFile: return .file_not_found
            case .permissionDenied: return .permission_denied
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
            default: break
            }
        }

        return errorCode(forText: error.localizedDescription) ?? .operation_failed
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
