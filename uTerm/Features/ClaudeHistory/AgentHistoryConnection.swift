import Foundation
import Observation
import SwiftData
import Synchronization

/// 历史会话连主机时怎么对待主机密钥：**不弹确认**，只记下「被问过」。
///
/// 能从终端标签打开历史会话，说明终端已经连过这台主机、密钥早已信任，正常不会被问。被问了（密钥没信任过，或者和已信任的
/// 不一致）就连不上，这时提示用户回终端里去信任——底层的报错写的是「用户拒绝了未知主机密钥」，但这里没人问过用户。
nonisolated final class ClaudeHistoryHostKeyGate: Sendable {
    private let challenged = Mutex(false)

    var wasChallenged: Bool { challenged.withLock { $0 } }

    var approver: @Sendable (HostKeyChallenge) async -> Bool {
        { [self] challenge in
            // 连接方式变弱了不是主机密钥的问题：不记，失败时报 `LegacyAlgorithmRefusal.message` 那句。
            if !challenge.isWeakAlgorithms { challenged.withLock { $0 = true } }
            return false
        }
    }

    /// 连不上时给用户看的话。
    func failureMessage(for error: any Error) -> String {
        wasChallenged
            ? String(localized: "这台主机的密钥还没有被信任，或者和已信任的不一致。请先在终端里连接这台主机并信任它的密钥，再回来打开历史会话。")
            : FriendlyError.describe(error)
    }
}

/// 读历史会话的文件通道从哪来：已保存的 SSH 主机走 SFTP，配对过的 Mac 走远控链路，Mac 本机走辅助程序（mac-only，
/// 见 `RemoteMacFileProvider.localShellAgent`）。拿到的通道交给 `AgentHistoryConnection`。
enum AgentHistoryAccess {
    typealias Connect = @MainActor (ClaudeHistoryHostKeyGate) async throws -> any SFTPProviding

    nonisolated struct Failure: LocalizedError {
        let message: String
        var errorDescription: String? { message }
    }

    /// 一台已保存的 SSH 主机。只走 `SFTPSession.make`（共享连接池，和终端共用一条 SSH 连接），主机密钥不弹确认；
    /// 也就不和同时在弹确认的终端合并握手（`approvesInteractively: false`），免得它的「不」替终端答掉。
    static func server(_ profile: ServerProfile, container: ModelContainer) -> Connect {
        { gate in try await SFTPSession.make(profile: profile, container: container, approver: gate.approver,
                                             approvesInteractively: false) }
    }

    /// 按 `ServerProfile.id` 找主机（Mac 的窗口身份里只有 id）。`found` 拿到主机名。
    static func server(id: UUID, container: ModelContainer, found: @escaping @MainActor (ServerProfile) -> Void) -> Connect {
        { gate in
            var descriptor = FetchDescriptor<ServerProfile>(predicate: #Predicate { $0.id == id })
            descriptor.fetchLimit = 1
            guard let profile = try container.mainContext.fetch(descriptor).first else {
                throw Failure(message: String(localized: "找不到这台主机，它可能已被删除。"))
            }
            found(profile)
            return try await SFTPSession.make(profile: profile, container: container, approver: gate.approver,
                                             approvesInteractively: false)
        }
    }

    /// 配对过的 Mac：经远控链路读它的 `~/.claude`（`RemoteMacFileProvider`）。先连上、再看握手能力 `files`——
    /// 老版本的 Mac 收到不认识的消息会断开整条连接，所以没有这项能力一个文件请求也不发。
    static func pairedMac(_ client: RemoteMacClient) -> Connect {
        { _ in
            await client.connect()
            switch client.state {
            case .connected:
                break
            case .failed(let message):
                throw Failure(message: message)
            case .awaitingApproval:
                throw Failure(message: String(localized: "还在等那台 Mac 上确认配对。在 Mac 上点「允许」后重试。"))
            case .idle, .connecting:
                throw Failure(message: String(localized: "连不上这台 Mac"))
            }
            guard client.supportsFiles else { throw Failure(message: unsupportedMacMessage) }
            return RemoteMacFileProvider(client: client)
        }
    }

    /// 那台 Mac 的 uTerm 太旧、不认文件请求（同 `RemoteMacClient` 发文件请求前的拦截）。
    static var unsupportedMacMessage: String {
        String(localized: "这台 Mac 上的 uTerm 版本太旧，不支持远程访问文件。把 Mac 上的 uTerm 更新到最新版后再试")
    }
}

/// 历史会话的连接状态：先建文件通道，建好之后交给共享的 `AgentHistoryModel`。两端共用：Mac 的历史窗口、iOS 的历史标签。
@MainActor
@Observable
final class AgentHistoryConnection {
    enum Phase {
        case connecting
        case failed(String)
        case ready(AgentHistoryModel)
    }

    /// 打开时终端所在的目录；拿不到为 nil（列全部项目）。
    let preferredDirectory: String?
    private(set) var phase: Phase = .connecting
    @ObservationIgnored private let connect: AgentHistoryAccess.Connect?
    @ObservationIgnored private let home: String?
    @ObservationIgnored private var provider: (any SFTPProviding)?
    @ObservationIgnored private var isOpening = false
    @ObservationIgnored private var isClosed = false

    /// 这台主机能不能跑命令（搜索要用）：连上之后问一次。标成只许 SFTP 的主机不能。
    @ObservationIgnored private let allowsCommands: @MainActor () -> Bool
    /// 读哪几种工具的记录。两端的界面都给 `AgentHistoryTool.allCases`；默认只读 Claude Code（老的调用点与测试）。
    let tools: [AgentHistoryTool]
    /// 见 `AgentHistoryModel.followsCurrentProject`。
    @ObservationIgnored private let followsCurrentProject: Bool
    /// 文件通道建好之后怎么建数据源（测试换成假的）。
    @ObservationIgnored private let makeSource: (any SFTPProviding, String?) -> any AgentHistorySource
    /// 置顶按哪台主机记：连上之后才问（配对的 Mac 握手后才知道设备 ID）。nil = 这个列表不能置顶。
    @ObservationIgnored private let pinHost: @MainActor () -> AgentHistoryPinHost?
    /// 置顶存在哪（测试换成一次性的）。
    @ObservationIgnored private let pinDefaults: UserDefaults

    /// `home`：主目录，不给就问那台主机（见 `ClaudeHistorySource.init`）。
    init(preferredDirectory: String?, home: String? = nil, allowsCommands: @escaping @MainActor () -> Bool = { true },
         tools: [AgentHistoryTool] = [.claude], followsCurrentProject: Bool = true,
         makeSource: ((any SFTPProviding, String?) -> any AgentHistorySource)? = nil,
         pinHost: @escaping @MainActor () -> AgentHistoryPinHost? = { nil }, pinDefaults: UserDefaults = .standard,
         connect: @escaping AgentHistoryAccess.Connect) {
        self.preferredDirectory = preferredDirectory
        self.pinHost = pinHost
        self.pinDefaults = pinDefaults
        self.home = home
        self.allowsCommands = allowsCommands
        self.tools = tools
        self.followsCurrentProject = followsCurrentProject
        self.makeSource = makeSource ?? { provider, home in AgentHistorySources.make(tools: tools, provider: provider, home: home) }
        self.connect = connect
    }

    /// 界面画廊、测试用：直接给一个已经接好假数据的模型。
    init(history: AgentHistoryModel) {
        preferredDirectory = history.preferredDirectory
        home = nil
        allowsCommands = { true }
        tools = history.configuredTools
        followsCurrentProject = history.followsCurrentProject
        makeSource = { _, _ in history.source }
        pinHost = { nil }
        pinDefaults = .standard
        connect = nil
        phase = .ready(history)
    }

    var history: AgentHistoryModel? {
        if case .ready(let model) = phase { return model }
        return nil
    }

    var failureMessage: String? {
        if case .failed(let message) = phase { return message }
        return nil
    }

    /// 建文件通道、列项目。已经开着或正在开时不再开；失败后再调就是重试。
    func open() async {
        guard let connect, !isOpening, !isClosed, history == nil else { return }
        isOpening = true
        defer { isOpening = false }
        phase = .connecting
        let hostKeys = ClaudeHistoryHostKeyGate()
        do {
            let provider = try await connect(hostKeys)
            guard !isClosed else {
                await provider.close()
                return
            }
            self.provider = provider
            let history = AgentHistoryModel(source: makeSource(provider, home), preferredDirectory: preferredDirectory,
                                            allowsSearch: allowsCommands(), followsCurrentProject: followsCurrentProject)
            history.pins = pinHost().map { AgentHistoryPins(host: $0, defaults: pinDefaults) }
            phase = .ready(history)
            await history.start()
        } catch {
            guard !isClosed else { return }
            phase = .failed(hostKeys.failureMessage(for: error))
        }
    }

    /// 关窗口 / 关标签：放掉文件通道（SFTP 会话还给连接池，远控的通道本来就和终端共用）。
    func close() {
        isClosed = true
        // 在途的搜索不再往主机上发命令。
        history?.stopSearch()
        let provider = self.provider
        self.provider = nil
        if let provider { Task { await provider.close() } }
    }
}
