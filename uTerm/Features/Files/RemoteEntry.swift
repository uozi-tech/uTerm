import Foundation

/// 一个远程目录项。值类型，便于单测与 SwiftUI 列表。
nonisolated struct RemoteEntry: Equatable, Sendable, Identifiable {
    let name: String
    let isDirectory: Bool
    let size: UInt64?
    let modifiedAt: Date?
    /// 原始 POSIX mode（含文件类型位）。供权限串展示。
    let permissions: UInt32?
    /// 数字 owner（SFTP 协议不返回用户名）。
    let uid: UInt32?
    let gid: UInt32?
    /// 经 SSH exec 额外解析出的用户名 / 组名。解析失败时保持 nil，UI 回退数字 ID。
    let ownerName: String?
    let groupName: String?

    var id: String { name }
    var ownerDisplayText: String {
        "\(Self.ownerLabel(name: ownerName, id: uid)) · \(Self.ownerLabel(name: groupName, id: gid))"
    }

    /// 是否符号链接（S_IFLNK，类型位 0o120000）。注意 symlink 的 `isDirectory`
    /// 恒为 false —— 列目录走 lstat 拿的是链接本身的类型，即便它指向目录；目标
    /// 是目录还是文件留到点击时再解析（见 FileBrowserModel.resolveSymlinkForOpen）。
    var isSymlink: Bool {
        guard let perm = permissions else { return false }
        return (perm & 0o170000) == 0o120000
    }

    /// 由 SFTP 列目录的 POSIX 属性构造。`posixPermissions` 含文件类型位
    /// （`S_IFMT` 掩码 `0o170000`，目录为 `0o040000`）。`uid`/`gid` 默认 nil
    /// 以兼容既有调用方（测试 helper 等）。
    init(name: String, posixPermissions: UInt32?, size: UInt64?, modifiedAt: Date?,
         uid: UInt32? = nil, gid: UInt32? = nil,
         ownerName: String? = nil, groupName: String? = nil) {
        self.name = name
        self.permissions = posixPermissions
        if let perm = posixPermissions {
            self.isDirectory = (perm & 0o170000) == 0o040000
        } else {
            self.isDirectory = false
        }
        self.size = size
        self.modifiedAt = modifiedAt
        self.uid = uid
        self.gid = gid
        self.ownerName = ownerName
        self.groupName = groupName
    }

    func withOwnerInfo(uid: UInt32?, gid: UInt32?,
                       ownerName: String?, groupName: String?) -> RemoteEntry {
        RemoteEntry(
            name: name,
            posixPermissions: permissions,
            size: size,
            modifiedAt: modifiedAt,
            uid: uid ?? self.uid,
            gid: gid ?? self.gid,
            ownerName: ownerName,
            groupName: groupName)
    }

    private static func ownerLabel(name: String?, id: UInt32?) -> String {
        if let name, !name.isEmpty { return name }
        return id.map(String.init) ?? "?"
    }
}
