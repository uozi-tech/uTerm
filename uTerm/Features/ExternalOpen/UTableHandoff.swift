import AppKit
import Foundation

/// 把远端 SQLite 文件交给 uTable 打开：`utable://open-sqlite?host=<主机 id>&path=<远端路径>`。
///
/// uTable 收到后按 id 实时读本机 uTerm 的主机配置与钥匙串，以「远程 SQLite」模式直连
/// ——文件下载成本地镜像、每次写入去抖后经 SFTP 传回远端，自动保存与冲突检测都在
/// uTable 那一侧（`RemoteSQLiteMirror`），uTerm 不需要监听、也不需要回传。
///
/// URL 里**没有任何凭据**。格式的另一半在 uTable 的 `UTermSQLiteOpenRequest`，改一边
/// 要同步改另一边。
nonisolated enum UTableHandoff {
    static let bundleIdentifier = "com.uozi.uTable"
    static let scheme = "utable"
    static let action = "open-sqlite"

    static func url(hostID: UUID, remotePath: String) -> URL {
        var components = URLComponents()
        components.scheme = scheme
        components.host = action
        components.queryItems = [
            URLQueryItem(name: "host", value: hostID.uuidString),
            URLQueryItem(name: "path", value: remotePath),
        ]
        return components.url!
    }

    /// 本机装的 uTable 认不认这个交接 URL。只看「装没装」不够：旧版 uTable 没注册
    /// `utable://`，交过去什么都不会发生。
    @MainActor
    static var isAvailable: Bool {
        guard let probe = URL(string: "\(scheme)://\(action)") else { return false }
        return NSWorkspace.shared.urlForApplication(toOpen: probe) != nil
    }

    /// 交给 uTable。返回 false 表示 LaunchServices 没能把 URL 送出去。
    @MainActor
    static func open(hostID: UUID, remotePath: String) async -> Bool {
        let configuration = NSWorkspace.OpenConfiguration()
        configuration.activates = true
        do {
            _ = try await NSWorkspace.shared.open(
                url(hostID: hostID, remotePath: remotePath), configuration: configuration)
            return true
        } catch {
            return false
        }
    }
}
