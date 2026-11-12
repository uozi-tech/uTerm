import Foundation

/// 命令行要用的「配对过的 Mac」：列出来、按名字找到、拿到它的文件通道。
///
/// 抽成协议是为了测试：`ControlMacHandlerTests` 塞一个连着本进程里假服务端的实现，不碰真实的配对记录。
@MainActor
protocol ControlRemoteMacs: AnyObject {
    /// - Parameter session: 发命令的程序所在的终端（没在 uTerm 的终端里就是 nil）。
    func snapshots(session: UUID?) -> [ControlMacSnapshot]
    /// 按名字或设备 UUID 找到一台 Mac（或一台正连着本机的主控设备），确保连上，回它的文件通道。用完必须调 `finished`。
    /// `needle` 为空时按 `session` 取此刻接管着那个终端的设备（规则见 `ControlMacSessions.defaultController`）。
    func provider(for needle: String, session: UUID?) async throws(ControlFailure) -> ControlMacSession
    /// 一次动作做完了（成败都算）。在用的连接不会被空闲回收掉。
    func finished(_ session: ControlMacSession)
    /// 放掉命令行握着的连接。`needle` 为 nil 全放。回放掉了几条。
    func release(_ needle: String?) -> Int
}

nonisolated enum ControlMacRole {
    /// 配对过、由本机控制的 Mac。
    static let host = "host"
    /// 此刻正控制着本机的设备。
    static let controller = "controller"
    /// 主控设备在命令行里的 id 前缀（同一台 Mac 可能既是配对过的 Mac、又正连着本机，两条路要分得开）。
    static let controllerPrefix = "controller:"
    /// `--mac @controller`：此刻接管着发命令那个终端的设备。
    static let currentController = "@controller"
}

nonisolated struct ControlMacSession: Sendable {
    let id: String
    let name: String
    var role = ControlMacRole.host
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

    /// 本机的远控服务端：此刻连着本机的主控设备从这里问。nil = 不提供反方向（测试里不需要时）。
    private weak var host: RemoteHostServer?

    init(directory: RemoteMacDirectory, host: RemoteHostServer? = nil) {
        self.directory = directory
        self.host = host
    }

    func snapshots(session: UUID?) -> [ControlMacSnapshot] {
        prepare()
        let hosts = directory.macs.map { mac in
            let client = held[mac.id]?.client ?? directory.existingClient(macID: mac.id)
            let connected = client?.state == .connected
            return ControlMacSnapshot(id: mac.id, name: mac.name, role: ControlMacRole.host,
                                      onLocalNetwork: mac.endpoint != nil,
                                      onRelay: mac.isOnRelay ? true : nil, connected: connected,
                                      path: connected ? client?.path?.label : nil,
                                      supportsFiles: connected ? client?.supportsFiles : nil)
        }
        let current = session.flatMap { host?.controller(ofSession: $0)?.deviceID }
        let controllers = (host?.connectedControllers() ?? []).map { controller in
            ControlMacSnapshot(id: ControlMacRole.controllerPrefix + controller.deviceID.uuidString, name: controller.name,
                               role: ControlMacRole.controller, current: controller.deviceID == current,
                               platform: controller.platform, onLocalNetwork: false, onRelay: nil, connected: true,
                               path: nil, supportsFiles: controller.sharesFiles)
        }
        return hosts + controllers
    }

    /// 用户打开过「我的 Mac」就在局域网里找（不会再弹授权）；没打开过就不找，免得命令行触发「本地网络」授权框，
    /// 这时只走中继。
    private func prepare() {
        if directory.isActivated, !directory.isBrowsing { directory.startBrowsing() }
    }

    func provider(for needle: String, session: UUID?) async throws(ControlFailure) -> ControlMacSession {
        prepare()
        var mac: RemoteMacDirectory.Mac
        switch try resolve(needle, session: session) {
        case .controller(let controller):
            return try controllerSession(controller)
        case .host(let found):
            mac = found
        }
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

    private enum Target {
        case host(RemoteMacDirectory.Mac)
        case controller(RemoteHostServer.Controller)
    }

    /// 一台正连着本机的主控设备的文件通道。连接是它建的、归它管，这里不握着；每条请求现找它此刻的连接，
    /// 它断了重连之后接着能用。
    private func controllerSession(_ controller: RemoteHostServer.Controller) throws(ControlFailure) -> ControlMacSession {
        guard controller.sharesFiles else {
            throw ControlFailure(code: .operation_failed, message: Self.noFiles(controller))
        }
        let deviceID = controller.deviceID
        let name = controller.name
        let provider = RemoteMacFileProvider(send: { [weak host] request, body, timeout in
            let connection = await MainActor.run { host?.fileConnection(toDevice: deviceID) }
            guard let connection else {
                throw RemoteFileError(.unreachable, "「\(name)」已经不连着这台 Mac 了")
            }
            return try await connection.performFile(request, body: body, timeout: timeout)
        })
        return ControlMacSession(id: ControlMacRole.controllerPrefix + deviceID.uuidString, name: name,
                                 role: ControlMacRole.controller, provider: provider)
    }

    private static func noFiles(_ controller: RemoteHostServer.Controller) -> String {
        controller.platform == RemoteDevicePlatform.mac.rawValue
            ? "「\(controller.name)」上的 uTerm 版本太旧，不能共享文件夹。把那台 Mac 上的 uTerm 更新到最新版"
            : "「\(controller.name)」不是 Mac，没有文件可以共享"
    }

    private static func label(_ controller: RemoteHostServer.Controller) -> String {
        "\(controller.name)（\(ControlMacRole.controllerPrefix)\(controller.deviceID.uuidString)）"
    }

    /// 没写 `--mac`（或写的是 `@controller`）时用哪台设备。几台设备同时连着本机时绝不猜：
    /// 1. 发命令的终端此刻被谁接管，就是谁（同一时刻一个终端只归一台设备）；它不提供文件就直说，不换别的设备顶上。
    /// 2. 认不出终端、或终端此刻没人接管：只有一台肯提供文件的设备连着就用它。
    /// 3. 否则报错，把候选列出来。
    private func defaultController(session: UUID?) throws(ControlFailure) -> RemoteHostServer.Controller {
        let connected = host?.connectedControllers() ?? []
        if let session, let current = host?.controller(ofSession: session) {
            guard current.sharesFiles else {
                let others = connected.filter { $0.sharesFiles }
                throw ControlFailure(code: .operation_failed,
                                     message: "此刻接管这个终端的是" + Self.noFiles(current)
                                         + (others.isEmpty ? "" : "。还连着的有：" + others.map(Self.label).joined(separator: "、")
                                            + "，要用它们请用 --mac 指定"))
            }
            return current
        }
        let sharing = connected.filter { $0.sharesFiles }
        switch sharing.count {
        case 1:
            return sharing[0]
        case 0:
            let hint = connected.isEmpty
                ? "此刻没有设备连着这台 Mac"
                : "此刻连着这台 Mac 的设备（" + connected.map(\.name).joined(separator: "、") + "）都不提供文件"
            throw ControlFailure(code: .invalid_request,
                                 message: "缺少 --mac：\(hint)。先跑 `utermctl macs` 看有哪些 Mac 可用")
        default:
            throw ControlFailure(code: .host_ambiguous,
                                 message: "此刻有 \(sharing.count) 台设备连着这台 Mac："
                                     + sharing.map(Self.label).joined(separator: "、")
                                     + (session == nil ? "。这条命令不是在 uTerm 的终端里发的，" : "。这个终端此刻没有被哪台设备接管，")
                                     + "分不出该用哪台，用 --mac 加括号里的 id 指定")
        }
    }

    private func resolve(_ needle: String, session: UUID? = nil) throws(ControlFailure) -> Target {
        let trimmed = needle.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.isEmpty || trimmed == ControlMacRole.currentController {
            return .controller(try defaultController(session: session))
        }
        let controllers = host?.connectedControllers() ?? []
        // `controller:<设备 UUID>`：点名走「正连着本机的主控设备」这条路。
        if trimmed.hasPrefix(ControlMacRole.controllerPrefix) {
            let raw = String(trimmed.dropFirst(ControlMacRole.controllerPrefix.count))
            guard let id = UUID(uuidString: raw), let found = controllers.first(where: { $0.deviceID == id }) else {
                throw ControlFailure(code: .host_not_found, message: "设备 \(raw) 此刻没有连着这台 Mac（跑 `utermctl macs` 看有哪些）")
            }
            return .controller(found)
        }
        let macs = directory.macs
        // 两边放在一起解析，名字的精确 / 前缀匹配才不会各算各的。调试直连的 Mac 没有设备 ID、主控设备要和
        // 同一台 Mac 的「配对过」那条路分开，所以都用只在这次解析里有效的编号。
        var targets: [UUID: Target] = [:]
        var candidates: [HostResolver.Candidate] = []
        for mac in macs {
            let id = mac.deviceID ?? UUID()
            targets[id] = .host(mac)
            candidates.append(HostResolver.Candidate(id: id, name: mac.name))
        }
        var controllerKeys: [UUID: RemoteHostServer.Controller] = [:]
        for controller in controllers {
            let id = UUID()
            targets[id] = .controller(controller)
            controllerKeys[id] = controller
            candidates.append(HostResolver.Candidate(id: id, name: controller.name))
        }
        switch HostResolver.resolve(trimmed, in: candidates) {
        case .matched(let id):
            guard let target = targets[id] else {
                throw ControlFailure(code: .host_not_found, message: "没有名为「\(trimmed)」的 Mac")
            }
            return target
        case .ambiguous(let matches):
            let labels = matches.map { match in
                controllerKeys[match.id].map { Self.label($0) + "，正连着这台 Mac" } ?? "\(match.name)（\(match.id.uuidString)），配对过的 Mac"
            }
            throw ControlFailure(code: .host_ambiguous,
                                 message: "「\(trimmed)」匹配到 \(matches.count) 个：" + labels.joined(separator: "；")
                                     + "。改用括号里的 id 重试。")
        case .notFound:
            // 只给了设备 UUID、它又只是正连着本机的主控设备（没有反过来配对过）。
            if let id = UUID(uuidString: trimmed), let found = controllers.first(where: { $0.deviceID == id }) {
                return .controller(found)
            }
            throw ControlFailure(code: .host_not_found,
                                 message: macs.isEmpty && controllers.isEmpty
                                     ? "这台 Mac 还没有配对过别的 Mac，此刻也没有设备连着它。在 uTerm「动作 › 我的 Mac」里配对"
                                     : "没有名为「\(trimmed)」的 Mac（跑 `utermctl macs` 看有哪些）")
        }
    }

    func release(_ needle: String?) -> Int {
        let ids: [String]
        if let needle {
            guard case .host(let mac)? = try? resolve(needle), held[mac.id] != nil else { return 0 }
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
