import Foundation

extension RemoteMacFileProvider {
    /// 本机的文件，经不带沙盒的辅助程序 `uTermShellAgent.xpc` 读（App 在沙盒里，读不到 `~/.claude`）。
    /// 用的是远控文件服务的同一套线格式（`RemoteFileWire`）与同一个 `SFTPProviding` 包装，只是不经网络。
    ///
    /// 历史会话窗口只用它读（列目录、属性、按区间读、解析路径）。
    @MainActor
    static func localShellAgent(client: LocalShellAgentClient = LocalShellService.shared.client) -> RemoteMacFileProvider {
        RemoteMacFileProvider(send: { request, body, _ in
            var request = request
            request.acceptsCompression = false
            let payload = RemoteFileCodec.packRequest(request, body: body, compress: false)
            let raw: Data
            do {
                raw = try await client.fileRequest(payload)
            } catch {
                throw RemoteFileError(.unreachable, error.localizedDescription)
            }
            let (reply, data) = try RemoteFileCodec.unpackReply(raw)
            if let error = reply.error { throw error }
            return (reply, data)
        })
    }
}
