import Foundation

/// 命令行要用的「配对过的 Mac」：列出来、按名字找到、拿到它的文件通道。
///
/// 抽成协议是为了测试：`ControlMacHandlerTests` 塞一个连着本进程里假服务端的实现，不碰真实的配对记录。
@MainActor
protocol ControlRemoteMacs: AnyObject {
    func snapshots() -> [ControlMacSnapshot]
    /// 按名字或设备 UUID 找到一台 Mac，确保连上，回它的文件通道。用完必须调 `finished`。
    func provider(for needle: String) async throws(ControlFailure) -> ControlMacSession
    /// 一次动作做完了（成败都算）。在用的连接不会被空闲回收掉。
    func finished(_ session: ControlMacSession)
    /// 放掉命令行握着的连接。`needle` 为 nil 全放。回放掉了几条。
    func release(_ needle: String?) -> Int
}

nonisolated struct ControlMacSession: Sendable {
    let id: String
    let name: String
    let provider: RemoteMacFileProvider
}

/// 真实实现：连接归 `RemoteMacDirectory` 管（和「我的 Mac」窗口共用同一条），命令行只是又一个使用者。
///
/// 命令行握着的连接空闲 10 分钟后放掉（同 SSH 的连接池）；这时如果有窗口还在用这台 Mac，连接不会真的断开。
@MainActor
final class ControlMacSessions: ControlRemoteMacs {
    static let idleLifetime: TimeInterval = 600

    private let directory: RemoteMacDirectory
    private var held: [String: Held] = [:]

    private struct Held {
        let session: ControlMacSession
        var client: RemoteMacClient
        var lastUsed = Date()
        /// 正在这条连接上做的动作数。大文件传输一做十几分钟，中途不能被当成空闲放掉。
        var busy = 0
    }

    private var reaper: Task<Void, Never>?

    init(directory: RemoteMacDirectory) {
        self.directory = directory
    }

    func snapshots() -> [ControlMacSnapshot] {
        prepare()
        return directory.macs.map { mac in
            let client = held[mac.id]?.client ?? directory.existingClient(macID: mac.id)
            let connected = client?.state == .connected
            return ControlMacSnapshot(id: mac.id, name: mac.name, onLocalNetwork: mac.endpoint != nil,
                                      onRelay: mac.isOnRelay ? true : nil, connected: connected,
                                      path: connected ? client?.path?.label : nil,
                                      supportsFiles: connected ? client?.supportsFiles : nil)
        }
    }

    /// 用户打开过「我的 Mac」就在局域网里找（不会再弹授权）；没打开过就不找，免得命令行触发「本地网络」授权框，
    /// 这时只走中继。
    private func prepare() {
        if directory.isActivated, !directory.isBrowsing { directory.startBrowsing() }
    }

    func provider(for needle: String) async throws(ControlFailure) -> ControlMacSession {
        prepare()
        var mac = try resolve(needle)
        // 刚开始浏览时局域网的结果还没回来：这台 Mac 又没有中继可走，就等一小会儿。
        if mac.endpoint == nil, mac.relay == nil, !mac.isOnRelay, directory.isBrowsing {
            for _ in 0..<15 {
                try? await Task.sleep(for: .milliseconds(200))
                guard let fresh = directory.macs.first(where: { $0.id == mac.id }) else { break }
                mac = fresh
                if mac.endpoint != nil { break }
            }
        }
        let client: RemoteMacClient
        if held[mac.id] != nil {
            // 顺手按最新的在线情况更新它能走的路。
            client = directory.client(for: mac)
            held[mac.id]?.client = client
        } else {
            client = directory.acquireClient(for: mac)
            let session = ControlMacSession(id: mac.id, name: mac.name, provider: RemoteMacFileProvider(client: client))
            held[mac.id] = Held(session: session, client: client)
            startReaper()
        }
        held[mac.id]?.lastUsed = Date()
        held[mac.id]?.busy += 1
        do {
            return try await connected(client, mac: mac)
        } catch {
            held[mac.id]?.busy -= 1
            throw error
        }
    }

    func finished(_ session: ControlMacSession) {
        guard var entry = held[session.id] else { return }
        entry.busy = max(0, entry.busy - 1)
        entry.lastUsed = Date()
        held[session.id] = entry
    }

    private func connected(_ client: RemoteMacClient, mac: RemoteMacDirectory.Mac) async throws(ControlFailure) -> ControlMacSession {
        await client.connect()
        switch client.state {
        case .connected:
            break
        case .awaitingApproval:
            throw ControlFailure(code: .connect_failed, message: "「\(mac.name)」还在等那台 Mac 上的人确认配对")
        case .failed(let reason):
            throw ControlFailure(code: .connect_failed, message: "连不上「\(mac.name)」：\(reason)")
        case .idle, .connecting:
            throw ControlFailure(code: .connect_failed, message: "连不上「\(mac.name)」")
        }
        guard client.supportsFiles else {
            throw ControlFailure(code: .operation_failed,
                                 message: "「\(mac.name)」上的 uTerm 版本太旧，不支持远程访问文件。把那台 Mac 上的 uTerm 更新到最新版")
        }
        guard let session = held[mac.id]?.session else {
            throw ControlFailure(code: .connect_failed, message: "到「\(mac.name)」的连接刚被放掉，再试一次")
        }
        return session
    }

    private func resolve(_ needle: String) throws(ControlFailure) -> RemoteMacDirectory.Mac {
        let trimmed = needle.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            throw ControlFailure(code: .invalid_request, message: "缺少 --mac（先跑 `utermctl macs` 看有哪些配对过的 Mac）")
        }
        let macs = directory.macs
        // 调试直连的 Mac 没有设备 ID，给它一个只在这次解析里用的。
        let keyed = macs.map { (HostResolver.Candidate(id: $0.deviceID ?? UUID(), name: $0.name), $0) }
        switch HostResolver.resolve(trimmed, in: keyed.map(\.0)) {
        case .matched(let id):
            guard let match = keyed.first(where: { $0.0.id == id }) else {
                throw ControlFailure(code: .host_not_found, message: "没有名为「\(trimmed)」的已配对 Mac")
            }
            return match.1
        case .ambiguous(let matches):
            throw ControlFailure(code: .host_ambiguous,
                                 message: "「\(trimmed)」匹配到 \(matches.count) 台 Mac："
                                     + matches.map { "\($0.name)（\($0.id.uuidString)）" }.joined(separator: "、")
                                     + "。改用括号里的 UUID 重试。")
        case .notFound:
            throw ControlFailure(code: .host_not_found,
                                 message: macs.isEmpty
                                     ? "这台 Mac 还没有配对过别的 Mac。在 uTerm「动作 › 我的 Mac」里配对"
                                     : "没有名为「\(trimmed)」的已配对 Mac（跑 `utermctl macs` 看有哪些）")
        }
    }

    func release(_ needle: String?) -> Int {
        let ids: [String]
        if let needle {
            guard let mac = try? resolve(needle), held[mac.id] != nil else { return 0 }
            ids = [mac.id]
        } else {
            ids = Array(held.keys)
        }
        for id in ids {
            held[id] = nil
            directory.releaseClient(macID: id)
        }
        return ids.count
    }

    private func startReaper() {
        guard reaper == nil else { return }
        reaper = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(60))
                guard let self else { return }
                let cutoff = Date().addingTimeInterval(-Self.idleLifetime)
                for (id, entry) in self.held where entry.busy == 0 && entry.lastUsed < cutoff {
                    self.held[id] = nil
                    self.directory.releaseClient(macID: id)
                }
                if self.held.isEmpty {
                    self.reaper = nil
                    return
                }
            }
        }
    }
}
