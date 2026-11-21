import SwiftUI

/// 体验主机在 iOS 上的「主机」：一个固定 id、**永不插入数据库**的 `ServerProfile`（不进 CloudKit、不进主机列表的
/// `@Query`）。同一个实例贯穿进程，工作区按它的 `persistentModelID` 找已有标签。先例见远控的临时主机
/// （`RemoteMacClient.tabHost(for:)`）。
@MainActor
enum DemoHostProfile {
    nonisolated static let id = UUID(uuidString: "D3A0D3A0-0000-4000-8000-00000000DE70")!

    static let shared: ServerProfile = {
        let profile = ServerProfile()
        profile.id = id
        profile.name = String(localized: "体验主机")
        profile.host = DemoFileSystem.hostname
        profile.username = DemoFileSystem.user
        return profile
    }()

    static func isDemo(_ profile: ServerProfile) -> Bool { profile.id == id }
}

extension MobileTerminalTransportFactory {
    /// 体验主机：终端是本机的模拟 shell，不联网。
    static let demo = MobileTerminalTransportFactory { _ in DemoTerminalBackend() }
}

/// 「打开体验主机」的请求，等工作区消费（不走连接中页：没有要等的连接）。
struct MDemoRequest: Equatable {
    let kind: MConnectKind
    let token = UUID()
}
