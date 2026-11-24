import Foundation

/// 最近打开文件的轻量条目。`id` 即 `remotePath` —— 同路径覆盖。
nonisolated struct RecentFileEntry: Codable, Equatable, Sendable, Identifiable {
    /// 逐字节（见 `RemoteNameKey`）：NFC / NFD 写法的同名文件是两条。
    var id: RemoteNameKey { remotePath.remoteKey }
    let remotePath: String
    /// 持久化 kind 用字符串而非 enum，避免与 FileKind enum 在 swift 版本间漂移导致解码失败。
    /// 格式："code:<grammar>" / "markdown" / "image" / "text"。
    let kindTag: String
    var lastOpenedAt: Date
}
