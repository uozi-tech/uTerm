import SwiftData
import SwiftUI

/// 重新打开 App 后要恢复的终端标签。
///
/// 只记直连主机、还没断开的终端标签：主机的 id 加主机上那个会话的 id（远控标签跟着 Mac 走，文件标签重新打开就是了）。
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
                guard case .terminal(let term) = tab, term.remote == nil,
                      term.controller.state != .disconnected,
                      !term.host.isDeleted, term.host.modelContext != nil else { continue }
                if tab.id == activeID { archive.activeIndex = archive.tabs.count }
                archive.tabs.append(.init(hostID: term.host.id, sessionID: term.controller.hostSessionID))
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
    /// 测试宿主和正式版共用一份偏好：在里面记、恢复标签会把测试开的假标签变成对真实主机的连接，所以不碰。
    var defaults: UserDefaults? = TestHostEnvironment.isActive ? nil : .standard
    @State private var didRestore = false

    var body: some View {
        Color.clear
            .frame(width: 0, height: 0)
            .allowsHitTesting(false)
            .accessibilityHidden(true)
            .onAppear(perform: restoreOnce)
            .onChange(of: workspace.terminalTabArchive(showsWorkspace: store.showWorkspace)) { _, archive in
                guard didRestore, let defaults else { return }
                archive.save(to: defaults)
            }
    }

    private func restoreOnce() {
        guard !didRestore, let defaults else { return }
        didRestore = true
        let archive = MobileTerminalTabArchive.load(from: defaults)
        guard !archive.tabs.isEmpty,
              let hosts = try? context.fetch(FetchDescriptor<ServerProfile>()) else { return }
        let container = context.container
        let opened = archive.restore(into: workspace, hosts: hosts) { term in
            term.controller.start(profile: term.host, container: container, relay: relay)
        }
        if archive.showsWorkspace, !opened.isEmpty { store.showWorkspace = true }
    }
}
