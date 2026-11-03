import Foundation

extension MobileTerminalTransportFactory {
    /// 远控：接入 Mac 上的一个终端（经那台 Mac 的远控连接，不直连服务器）。
    static func remote(client: RemoteMacClient, sessionID: UUID) -> MobileTerminalTransportFactory {
        MobileTerminalTransportFactory { _ in RemoteTerminalBackend(client: client, sessionID: sessionID) }
    }
}
