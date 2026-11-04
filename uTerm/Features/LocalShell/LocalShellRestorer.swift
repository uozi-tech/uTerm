import Foundation
import UPaneGroups

/// App 启动时把上次留下的本机终端接回来：向 XPC 服务要会话列表，读每个 holder 里存的归属，放回原来的窗口。
///
/// 会话的真值在 holder 那边（socket 目录），不依赖容器里的文件。窗格 id 就是会话 id，所以接回后手机还能接到同一个会话。
@MainActor
final class LocalShellRestorer {
    static let shared = LocalShellRestorer()

    private struct PendingPane {
        let id: UUID
        let ordinal: Int
    }

    private let client: LocalShellAgentClient
    private let namespace: String
    /// 手机等接回完成的上限。超过之后按现状回答，比一直不回好。
    private let gateTimeout: Duration
    private let reopenDelay: Duration
    private var openWindow: (@MainActor (UUID, UUID) -> Void)?
    private var didStart = false
    private var isDone = false
    private var pending: [UUID: [PendingPane]] = [:]
    private var waiters: [CheckedContinuation<Void, Never>] = []

    init(client: LocalShellAgentClient = LocalShellService.shared.client, namespace: String = LocalShellNamespace.current,
         gateTimeout: Duration = .seconds(15), reopenDelay: Duration = .milliseconds(500)) {
        self.reopenDelay = reopenDelay
        self.client = client
        self.namespace = namespace
        self.gateTimeout = gateTimeout
    }

    func install(openWindow: @escaping @MainActor (_ windowID: UUID, _ firstPaneID: UUID) -> Void) {
        self.openWindow = openWindow
    }

    /// 幂等。在 Scene 环境还没好（`install` 之前）时不开始，装好之后会再调一次。
    func restoreIfNeeded() {
        guard !didStart, openWindow != nil, !BackgroundLaunchMode.isRunningInTestHost else { return }
        didStart = true
        Task { await restore() }
    }

    /// 窗口出现时领走属于自己的标签。这一步放在窗口的 `.task` 里，SwiftUI 自己恢复的窗口也走这条路。
    func adoptPending(windowID: UUID, into model: LocalShellWindowModel) {
        guard let panes = pending.removeValue(forKey: windowID) else { return }
        for pane in panes where model.groups.tab(pane.id) == nil {
            model.addTab(id: pane.id, ordinal: pane.ordinal)
        }
    }

    /// 接回完成（或确定没有要接回的）后返回。手机接入前等它，否则会看到一份缺了本机终端的列表。
    func finished() async {
        guard !isDone else { return }
        if isRunningWithoutRestoration { return }
        restoreIfNeeded()
        await withCheckedContinuation { waiters.append($0) }
    }

    private var isRunningWithoutRestoration: Bool {
        BackgroundLaunchMode.isRunningInTestHost || openWindow == nil
    }

    func restore() async {
        var byWindow: [UUID: [PendingPane]] = [:]
        if let ids = try? await client.listSessions(namespace: namespace) {
            for id in ids {
                switch await Self.inspect(id, client: client, namespace: namespace) {
                case .live(let attributes):
                    // 没有归属的会话（没来得及写归属就崩了）单独开一个窗口，不丢。
                    let window = attributes?.windowID ?? UUID()
                    byWindow[window, default: []].append(PendingPane(id: id, ordinal: attributes?.ordinal ?? 1))
                case .gone:
                    break
                }
            }
        }
        for (windowID, panes) in byWindow {
            let sorted = panes.sorted { $0.ordinal < $1.ordinal }
            pending[windowID] = sorted
            if let model = LocalShellWindowRouter.shared.model(forWindow: windowID) {
                adoptPending(windowID: windowID, into: model)
            } else if let first = sorted.first {
                openWindow?(windowID, first.id)
            }
        }
        await reopenUnclaimedWindows()
        await waitForPanes(byWindow.values.flatMap { $0 }.map(\.id))
        isDone = true
        for waiter in waiters { waiter.resume() }
        waiters = []
    }

    /// `open(value:)` 遇到同值的窗口只是带到前台。系统恢复的旧窗口正在关闭时会抢走这次打开，标签就没人领了，
    /// 等它关完再开一次。
    private func reopenUnclaimedWindows() async {
        for _ in 0..<3 where !pending.isEmpty {
            try? await Task.sleep(for: reopenDelay)
            for (windowID, panes) in pending {
                if let first = panes.first { openWindow?(windowID, first.id) }
            }
        }
    }

    /// 等接回的会话都走完回放。之后它们才进注册表，手机才看得到。
    private func waitForPanes(_ ids: [UUID]) async {
        let deadline = ContinuousClock.now + gateTimeout
        while ContinuousClock.now < deadline {
            let panes = LocalShellWindowRouter.shared.allPanes
            let settled = ids.allSatisfy { id in
                guard let pane = panes.first(where: { $0.id == id }) else { return false }
                return pane.session.connectionState != .connecting && pane.session.connectionState != .idle
            }
            if settled { return }
            try? await Task.sleep(for: .milliseconds(50))
        }
    }

    private enum Inspection: Sendable {
        case live(LocalShellSessionAttributes?)
        case gone
    }

    /// 只问 hello，不接入。shell 已经退出的（App 不在时用户的命令结束了）顺手结束掉，不开窗口：
    /// 恢复出一个只写着「已退出」的标签没有用。
    private nonisolated static func inspect(_ id: UUID, client: LocalShellAgentClient, namespace: String) async -> Inspection {
        guard let reply = await HolderProbe.hello(id, client: client, namespace: namespace) else { return .gone }
        if reply.exitStatus != nil {
            await HolderProbe.terminate(id, client: client, namespace: namespace)
            return .gone
        }
        return .live(try? JSONDecoder().decode(LocalShellSessionAttributes.self, from: Data(reply.attributes)))
    }
}
