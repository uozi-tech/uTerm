import SwiftData
import SwiftUI

/// 重新打开 App 后要恢复的终端标签。
///
/// 只记直连主机、还没断开的终端标签：主机的 id 加主机上那个会话的 id（远控标签跟着 Mac 走，文件标签重新打开就是了）。
/// Code 标签页本身不记；它里面跑着的直连会话按终端标签页记（排在 Code 标签页的位置上），重新打开后以普通终端标签页接回。
/// App 被系统结束、被用户划掉都不走关标签的流程，主机上的会话还在跑；重新打开时凭这张表把标签开回来，
/// `PersistentSSHConnection` 用原来的会话 id 接回同一个 shell，画面从存在主机上的检查点还原。
/// 关标签会从表里拿掉（主机上的会话也随之结束）。只存在本机，不同步。
nonisolated struct MobileTerminalTabArchive: Codable, Equatable {
    struct Tab: Codable, Equatable {
        var hostID: UUID
        var sessionID: UUID
    }

    var tabs: [Tab] = []
    /// 前台的那个标签在 `tabs` 里的下标。
    var activeIndex: Int?
    /// 当时工作区是展开的（正看着终端）。
    var showsWorkspace = false

    static func load(from defaults: UserDefaults) -> MobileTerminalTabArchive {
        guard let data = defaults.data(forKey: DefaultsKey.mobileRestorableTerminalTabs),
              let archive = try? JSONDecoder().decode(MobileTerminalTabArchive.self, from: data) else {
            return MobileTerminalTabArchive()
        }
        return archive
    }

    func save(to defaults: UserDefaults) {
        guard !tabs.isEmpty, let data = try? JSONEncoder().encode(self) else {
            defaults.removeObject(forKey: DefaultsKey.mobileRestorableTerminalTabs)
            return
        }
        defaults.set(data, forKey: DefaultsKey.mobileRestorableTerminalTabs)
    }
}

extension MobileWorkspace {
    /// 此刻值得恢复的终端标签，按标签条上的先后（第一格在前）。
    func terminalTabArchive(showsWorkspace: Bool) -> MobileTerminalTabArchive {
        var archive = MobileTerminalTabArchive()
        let activeID = activeTab?.id
        for pane in panes {
            for tab in tabs(in: pane) {
                let terms: [TermTab]
                // Code 标签页在前台时，前台算它此刻看着的那个会话（没有就算它的第一个）。
                var front: TermTab?
                switch tab {
                case .terminal(let term):
                    terms = [term]
                    front = term
                case .history(let code):
                    terms = code.runTerminals
                    front = code.runs.focused?.terminal ?? terms.first
                case .files, .preview:
                    continue
                }
                for term in terms where term.remote == nil && term.controller.state != .disconnected
                    && !term.host.isDeleted && term.host.modelContext != nil {
                    if tab.id == activeID, term === front { archive.activeIndex = archive.tabs.count }
                    archive.tabs.append(.init(hostID: term.host.id, sessionID: term.controller.hostSessionID))
                }
            }
        }
        archive.showsWorkspace = showsWorkspace && !archive.tabs.isEmpty
        return archive
    }
}

extension MobileTerminalTabArchive {
    /// 把表里的标签开回工作区，交给 `start` 建连。主机已经不在（被删了、改成仅 SFTP）的跳过。返回开回来的标签。
    @MainActor
    @discardableResult
    func restore(into workspace: MobileWorkspace, hosts: [ServerProfile],
                 transportFactory: MobileTerminalTransportFactory = .live,
                 start: (TermTab) -> Void) -> [TermTab] {
        var opened: [TermTab] = []
        var active: TermTab?
        for (index, entry) in tabs.enumerated() {
            guard let host = hosts.first(where: { $0.id == entry.hostID }), !host.sftpOnly else { continue }
            let term = TermTab(host: host, transportFactory: transportFactory, hostSessionID: entry.sessionID)
            workspace.open(.terminal(term), activate: false)
            start(term)
            opened.append(term)
            if index == activeIndex { active = term }
        }
        if let active { workspace.activate(active.id) }
        return opened
    }
}

/// 挂在根视图里的一个看不见的视图：启动时把上次的终端标签开回来，之后标签有变化就记下来。
struct MobileTerminalTabRestorer: View {
    @Environment(MobileStore.self) private var store
    @Environment(MobileWorkspace.self) private var workspace
    @Environment(HostKeyChallengeRelay.self) private var relay
    @Environment(\.modelContext) private var context
    @Environment(SubscriptionStore.self) private var subscriptions: SubscriptionStore?
    /// 订阅主机表（和 `WorkspaceScreen` 同一种取法）：首次出现时结果已经在了。
    @Query private var hosts: [ServerProfile]
    /// 测试宿主和正式版共用一份偏好：在里面记、恢复标签会把测试开的假标签变成对真实主机的连接，所以不碰。
    var defaults: UserDefaults? = TestHostEnvironment.isActive ? nil : .standard
    @State private var didRestore = false

    var body: some View {
        Color.clear
            .frame(width: 0, height: 0)
            .allowsHitTesting(false)
            .accessibilityHidden(true)
            // 先等订阅状态读出来：没订阅就不把上次的会话连回去（连接也在订阅里）。
            .task {
                await subscriptions?.waitUntilResolved()
                restoreOnce()
            }
            .onChange(of: workspace.terminalTabArchive(showsWorkspace: store.showWorkspace)) { _, archive in
                guard didRestore, let defaults else { return }
                archive.save(to: defaults)
            }
    }

    private func restoreOnce() {
        guard !didRestore, let defaults else { return }
        guard subscriptions?.isEntitled ?? true else { return }
        didRestore = true
        let archive = MobileTerminalTabArchive.load(from: defaults)
        guard !archive.tabs.isEmpty else { return }
        let container = context.container
        let opened = archive.restore(into: workspace, hosts: hosts) { term in
            term.controller.start(profile: term.host, container: container, relay: relay)
        }
        if archive.showsWorkspace, !opened.isEmpty { store.showWorkspace = true }
    }
}
