import UDesignKit
import SwiftUI

/// 远程条目的展示文案。macOS 文件表 / 检视器 / 朗读值与 iOS 文件行 / 操作单 / 简介共用，
/// 保证两端同一个条目说同一句话。
extension RemoteEntry {
    /// 列表分类（文件夹 / 符号链接 / 按扩展名的文件类型），带中文类型名与角标。
    var kind: BrowserFileKind {
        BrowserFileKind.from(name: name, isDirectory: isDirectory, isSymlink: isSymlink)
    }

    /// 大小：`12.3 KB`；目录或服务端没给大小时为占位 `UFormat.placeholder`。
    var sizeText: String {
        guard !isDirectory, let size else { return UFormat.placeholder }
        return UFormat.bytes(Int64(clamping: size))
    }

    /// 一句话概况的头半句：目录给类型名（「文件夹」），其余给 `sizeText`。
    /// 检视器名字下那行、iOS 文件行副标题与操作单副标题都用它。
    var sizeOrKindText: String { isDirectory ? kind.label : sizeText }

    /// 八进制权限（`755`；带特殊位时 `4755`）；缺权限位为 `—`。
    var octalText: String { posixOctalString(permissions) }

    /// 符号权限（`drwxr-xr-x`）；缺权限位为 `----------`。
    var symbolicText: String { posixPermissionString(permissions) }

    /// 条目在 `directory` 下的完整远程路径。
    func fullPath(in directory: String) -> String { RemotePath.join(directory, name) }
}
