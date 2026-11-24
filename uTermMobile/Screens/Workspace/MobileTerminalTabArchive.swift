import SwiftData
import SwiftUI

/// 重新打开 App 后要恢复的终端标签。
///
/// 只记直连主机、还没断开的终端标签：主机的 id 加主机上那个会话的 id（远控标签跟着 Mac 走，文件标签重新打开就是了）。
/// App 被系统结束、被用户划掉都不走关标签的流程，主机上的会话还在跑；重新打开时凭这张表把标签开回来，
/// `PersistentSSHConnection` 用原来的会话 id 接回同一个 shell，画面从存在主机上的检查点还原。
/// 关标签会从表里拿掉（主机上的会话也随之结束）。只存在本机，不同步。偏好键的值永远不改。
///
/// 直连主机的 Code 标签页也记（`codeTabs`）：重新打开后照原样开回来，里面跑着的会话接回它里面。格式只加不改，
/// 为了旧版读到新表时不丢会话，Code 标签页里的会话仍旧按终端标签页记在 `tabs` 里（排在 Code 标签页的位置上），
/// 只是多一个 `codeTab` 标明它属于哪个 Code 标签页：旧版不认这两个键，照旧把它们开成普通终端标签页；新版按 `codeTabs`
/// 把它们放回 Code 标签页。里面没有会话在跑的 Code 标签页旧版读不到（它本来也不恢复）。
nonisolated struct MobileTerminalTabArchive: Codable, Equatable {
    struct Tab: Codable, Equatable {
        var hostID: UUID
        var sessionID: UUID
        /// 这个会话跑在哪个 Code 标签页里（`CodeTab.record.id`）；普通终端标签页为 nil。
        var codeTab: UUID? = nil
    }

    /// 一个 Code 标签页：排在哪、记下来的样子（哪台主机、里面的会话、看着哪一个）。
    struct CodeTab: Codable, Equatable {
        /// 排在 `tabs` 的第几个之前（它里面的会话紧跟着记在那里）。
        var position: Int
        var record: CodeTabRecord
    }

    var tabs: [Tab] = []
    /// 前台的那个标签在 `tabs` 里的下标。前台是 Code 标签页时指向它此刻看着的那个会话（没有就是它的第一个），
    /// 旧版读到也有个着落；新版看 `activeCodeTab`。
    var activeIndex: Int?
    /// 当时工作区是展开的（正看着终端）。
    var showsWorkspace = false
    /// 直连主机的 Code 标签页。旧版写的没有。
    var codeTabs: [CodeTab]? = nil
    /// 前台是哪个 Code 标签页（`CodeTab.record.id`）。
    var activeCodeTab: UUID? = nil

    /// 有没有要恢复的东西。
    var isEmpty: Bool { tabs.isEmpty && (codeTabs ?? []).isEmpty }

    init() {}

    /// Code 标签页那一段是别的版本写的、解不开时当没有：终端标签照样开回来（那些会话退回普通终端标签页）。
    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        tabs = try container.decode([Tab].self, forKey: .tabs)
        activeIndex = try container.decodeIfPresent(Int.self, forKey: .activeIndex)
        showsWorkspace = try container.decode(Bool.self, forKey: .showsWorkspace)
        codeTabs = try? container.decodeIfPresent([CodeTab].self, forKey: .codeTabs)
        activeCodeTab = try? container.decodeIfPresent(UUID.self, forKey: .activeCodeTab)
    }

    static func load(from defaults: UserDefaults) -> MobileTerminalTabArchive {
        guard let data = defaults.data(forKey: DefaultsKey.mobileRestorableTerminalTabs),
              let archive = try? JSONDecoder().decode(MobileTerminalTabArchive.self, from: data) else {
            return MobileTerminalTabArchive()
        }
        return archive
    }

    func save(to defaults: UserDefaults) {
        guard !isEmpty, let data = try? JSONEncoder().encode(self) else {
            defaults.removeObject(forKey: DefaultsKey.mobileRestorableTerminalTabs)
            return
        }
        defaults.set(data, forKey: DefaultsKey.mobileRestorableTerminalTabs)
    }
}

extension MobileWorkspace {
    /// 此刻值得恢复的终端标签与 Code 标签页，按标签条上的先后（第一格在前）。
    func terminalTabArchive(showsWorkspace: Bool) -> MobileTerminalTabArchive {
        var archive = MobileTerminalTabArchive()
        var codeTabs: [MobileTerminalTabArchive.CodeTab] = []
        let activeID = activeTab?.id
        func restorable(_ term: TermTab) -> Bool {
            term.remote == nil && term.controller.state != .disconnected && !term.host.isDeleted
                && term.host.modelContext != nil
        }
        for pane in panes {
            for tab in tabs(in: pane) {
                switch tab {
                case .terminal(let term):
                    guard restorable(term) else { continue }
                    if tab.id == activeID { archive.activeIndex = archive.tabs.count }
                    archive.tabs.append(.init(hostID: term.host.id, sessionID: term.controller.hostSessionID))
                case .history(let code):
                    let included = code.runs.runs.filter { restorable($0.terminal) }
                    let record = code.archiveRecord(including: included)
                    if let record {
                        codeTabs.append(.init(position: archive.tabs.count, record: record))
                        if tab.id == activeID { archive.activeCodeTab = code.id }
                    }
                    // 前台算它此刻看着的那个会话（没有就算它的第一个）：旧版据此把前台落在它的会话上。
                    let front = included.first { $0.id == code.runs.focusedID } ?? included.first
                    for run in included {
                        if tab.id == activeID, run.id == front?.id { archive.activeIndex = archive.tabs.count }
                        archive.tabs.append(.init(hostID: run.terminal.host.id,
                                                  sessionID: run.terminal.controller.hostSessionID,
                                                  codeTab: record?.id))
                    }
                case .files, .preview:
                    continue
                }
            }
        }
        archive.codeTabs = codeTabs.isEmpty ? nil : codeTabs
        archive.showsWorkspace = showsWorkspace && !archive.isEmpty
        return archive
    }
}

extension MobileTerminalTabArchive {
    /// 把表里的标签开回工作区，交给 `start` 建连。主机已经不在（被删了、改成仅 SFTP）的跳过。返回开回来的终端
    ///（含 Code 标签页里接回的）。
    ///
    /// `makeCodeTab` 给出一台主机的 Code 标签页（开在记下来的目录）；给了就按 `codeTabs` 把 Code 标签页开回原位，
    /// 记在它名下的会话接回它里面（`ClaudeHistoryTab.restoreRuns`）。没给（或那个 Code 标签页开不出来：主机没了、
    /// 这台主机已经有一个了）时那些会话照普通终端标签页开，同旧版。
    @MainActor
    @discardableResult
    func restore(into workspace: MobileWorkspace, hosts: [ServerProfile],
                 transportFactory: MobileTerminalTransportFactory = .live,
                 makeCodeTab: ((ServerProfile, CodeTabRecord) -> ClaudeHistoryTab)? = nil,
                 start: (TermTab) -> Void) -> [TermTab] {
        func host(_ id: UUID?) -> ServerProfile? {
            id.flatMap { id in hosts.first { $0.id == id && !$0.sftpOnly } }
        }
        var opened: [TermTab] = []
        var activeTabID: UUID?
        // 开出来的 Code 标签页，键是 `CodeTabRecord.id`。
        var codeTabsOpened: [UUID: ClaudeHistoryTab] = [:]
        var sessionsInCodeTabs: Set<UUID> = []
        let pendingCodeTabs = (makeCodeTab == nil ? [] : codeTabs ?? []).sorted { $0.position < $1.position }
        var nextCodeTab = pendingCodeTabs.startIndex

        func openCodeTabs(before position: Int) {
            while nextCodeTab < pendingCodeTabs.endIndex, pendingCodeTabs[nextCodeTab].position <= position {
                let entry = pendingCodeTabs[nextCodeTab]
                nextCodeTab += 1
                guard let makeCodeTab, codeTabsOpened[entry.record.id] == nil, let server = host(entry.record.host),
                      workspace.existingHistory(host: server.persistentModelID) == nil else { continue }
                let code = makeCodeTab(server, entry.record)
                workspace.open(.history(code), activate: false)
                code.start()
                var terminals: [UUID: TermTab] = [:]
                for run in entry.record.runs where tabs.contains(where: {
                    $0.sessionID == run.session && $0.codeTab == entry.record.id
                }) {
                    terminals[run.session] = TermTab(host: server, transportFactory: transportFactory,
                                                     hostSessionID: run.session)
                }
                let adopted = code.restoreRuns(entry.record, terminals: terminals, start: start)
                sessionsInCodeTabs.formUnion(adopted)
                opened += adopted.compactMap { terminals[$0] }
                codeTabsOpened[entry.record.id] = code
                if entry.record.id == activeCodeTab { activeTabID = code.id }
            }
        }

        for (index, entry) in tabs.enumerated() {
            openCodeTabs(before: index)
            if entry.codeTab != nil, sessionsInCodeTabs.contains(entry.sessionID) {
                // 前台是 Code 标签页（旧字段指着它的会话）：Code 标签页到前台，看哪个由它自己还原。
                if index == activeIndex, activeTabID == nil,
                   let code = codeTabsOpened.values.first(where: { $0.runs.runs.contains {
                       $0.terminal.controller.hostSessionID == entry.sessionID } }) {
                    activeTabID = code.id
                }
                continue
            }
            guard let host = host(entry.hostID) else { continue }
            let term = TermTab(host: host, transportFactory: transportFactory, hostSessionID: entry.sessionID)
            workspace.open(.terminal(term), activate: false)
            start(term)
            opened.append(term)
            if index == activeIndex, activeTabID == nil { activeTabID = term.id }
        }
        openCodeTabs(before: .max)
        if let activeTabID { workspace.activate(activeTabID) }
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
        guard !archive.isEmpty else { return }
        let container = context.container
        archive.restore(into: workspace, hosts: hosts, makeCodeTab: { host, record in
            ClaudeHistoryTab(server: host, directory: record.directory, container: container)
        }) { term in
            term.controller.start(profile: term.host, container: container, relay: relay)
        }
        if archive.showsWorkspace, !workspace.tabs.isEmpty { store.showWorkspace = true }
    }
}
