import Foundation

/// 一个远程目录项。值类型，便于单测与 SwiftUI 列表。
nonisolated struct RemoteEntry: Equatable, Sendable, Identifiable {
    let name: String
    let isDirectory: Bool
    let size: UInt64?
    let modifiedAt: Date?

    var id: String { name }

    /// 由 SFTP 列目录的 POSIX 属性构造。`posixPermissions` 含文件类型位
    /// （`S_IFMT` 掩码 `0o170000`，目录为 `0o040000`）。
    init(name: String, posixPermissions: UInt32?, size: UInt64?, modifiedAt: Date?) {
        self.name = name
        if let perm = posixPermissions {
            self.isDirectory = (perm & 0o170000) == 0o040000
        } else {
            self.isDirectory = false
        }
        self.size = size
        self.modifiedAt = modifiedAt
    }
}
