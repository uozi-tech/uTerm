import SwiftUI
import SwiftData
import Observation

/// 文件浏览会话标签：一台主机 + 独立 `MobileSFTPController`（独立 SFTP 会话，各自记当前目录）。
/// 引用类型，与 `TermTab` 一样放进工作区里跨标签切换 / 分屏移动保活。
@MainActor
@Observable
final class FileTab: Identifiable {
    let id = UUID()
    let host: ServerProfile
    let controller: MobileSFTPController

    /// `controller` 默认新建（未建连）；测试注入已经「连上并列好目录」的假会话控制器。
    init(host: ServerProfile, controller: MobileSFTPController = MobileSFTPController()) {
        self.host = host
        self.controller = controller
    }
}

/// 工作区里的一个标签：终端会话或文件浏览（多态，对齐 macOS 工作区里终端 / 文件同条标签）。
enum MWorkTab: Identifiable {
    case terminal(TermTab)
    case files(FileTab)

    var id: UUID {
        switch self {
        case .terminal(let t): return t.id
        case .files(let f): return f.id
        }
    }

    var host: ServerProfile {
        switch self {
        case .terminal(let t): return t.host
        case .files(let f): return f.host
        }
    }

    var kind: MConnectKind {
        switch self {
        case .terminal: return .terminal
        case .files: return .sftp
        }
    }

    var terminal: TermTab? {
        if case .terminal(let t) = self { return t }
        return nil
    }

    /// 标签标题：终端优先用 shell 设置的标题（OSC 0/2），文件浏览用主机名。
    var title: String {
        switch self {
        case .terminal(let t): return t.controller.title.isEmpty ? t.host.name : t.controller.title
        case .files(let f): return f.host.name
        }
    }
}

/// 一个分屏格：自己的一条标签条 + 一个前台标签（对齐 macOS `UPaneGroups` 的「组」）。
struct MPane: Identifiable, Equatable {
    let id: UUID
    var tabIDs: [UUID] = []
    var activeID: UUID?

    init(id: UUID = UUID()) { self.id = id }
}

/// 移动端工作区：全部会话标签（终端 / 文件）+ 至多两个分屏格 + 聚焦格。
///
/// 由根视图 `MobileRootView` 持有并注入（高于标签栏 ⇄ 侧栏外壳），size class 翻转、
/// 外壳重建时会话与 SSH 连接都不丢。这里只管「哪个标签在哪一格、谁在前台」，
/// 不碰连接生命周期——建连 / 关闭由 `WorkspaceScreen` 做，`close` 把移除的标签交回去清理。
@MainActor
@Observable
final class MobileWorkspace {
    /// 分屏格数上限。手机与 iPad 上两格已够「终端 + 文件」并排，再多每格都太窄。
    static let maxPanes = 2

    private(set) var tabs: [MWorkTab] = []
    private(set) var panes: [MPane]
    private(set) var focusedPaneID: UUID
    /// 第一格占分屏方向的比例（拖动分隔条改它）。
    var splitFraction: CGFloat = 0.5

    init() {
        let pane = MPane()
        panes = [pane]
        focusedPaneID = pane.id
    }

    var isEmpty: Bool { tabs.isEmpty }
    var isSplit: Bool { panes.count > 1 }
    var terminalTabs: [TermTab] { tabs.compactMap(\.terminal) }

    var focusedPane: MPane { panes.first { $0.id == focusedPaneID } ?? panes[0] }
    /// 当前活动标签 = 聚焦格的前台标签（键盘、Agent 自动执行都只认它）。
    var activeTab: MWorkTab? { tab(focusedPane.activeID) }

    func tab(_ id: UUID?) -> MWorkTab? {
        guard let id else { return nil }
        return tabs.first { $0.id == id }
    }

    func tabs(in pane: MPane) -> [MWorkTab] { pane.tabIDs.compactMap { tab($0) } }

    func paneIndex(containing tabID: UUID) -> Int? {
        panes.firstIndex { $0.tabIDs.contains(tabID) }
    }

    /// 是否为所在格的前台标签（分屏时两格的前台标签都在屏上）。
    func isFront(_ tabID: UUID) -> Bool {
        guard let i = paneIndex(containing: tabID) else { return false }
        return panes[i].activeID == tabID
    }

    /// 是否为活动标签（聚焦格的前台）。
    func isActive(_ tabID: UUID) -> Bool { focusedPane.activeID == tabID }

    /// 同主机、同类型的已有标签（外部「连接」请求默认复用它而不是再开一个）。
    func existing(host: PersistentIdentifier, kind: MConnectKind) -> MWorkTab? {
        tabs.first { $0.kind == kind && $0.host.persistentModelID == host }
    }

    // MARK: - 操作

    /// 把新标签放进 `paneID`（缺省聚焦格）末尾，设为前台并聚焦该格。
    func open(_ tab: MWorkTab, in paneID: UUID? = nil) {
        tabs.append(tab)
        let i = panes.firstIndex { $0.id == (paneID ?? focusedPaneID) } ?? 0
        panes[i].tabIDs.append(tab.id)
        panes[i].activeID = tab.id
        focusedPaneID = panes[i].id
    }

    /// 切到某个标签：设为所在格的前台，并聚焦该格。
    func activate(_ tabID: UUID) {
        guard let i = paneIndex(containing: tabID) else { return }
        panes[i].activeID = tabID
        focusedPaneID = panes[i].id
    }

    func focus(pane id: UUID) {
        guard panes.contains(where: { $0.id == id }) else { return }
        focusedPaneID = id
    }

    /// 移除一个标签，返回它供调用方关连接 / 收键盘。前台标签被关时前台落到右邻（没有就左邻），
    /// 对齐 macOS 标签条；分屏时某格关空了就收起那一格。
    @discardableResult
    func close(_ tabID: UUID) -> MWorkTab? {
        guard let i = paneIndex(containing: tabID),
              let removed = tab(tabID) else { return nil }
        tabs.removeAll { $0.id == tabID }
        let pos = panes[i].tabIDs.firstIndex(of: tabID) ?? 0
        panes[i].tabIDs.remove(at: pos)
        if panes[i].activeID == tabID {
            let ids = panes[i].tabIDs
            panes[i].activeID = ids.isEmpty ? nil : ids[min(pos, ids.count - 1)]
        }
        if panes[i].tabIDs.isEmpty && isSplit { removePane(at: i) }
        return removed
    }

    /// 拆出第二格并聚焦它。当前格有两个以上标签时把前台标签移过去（常见的「拖到右边」）；
    /// 只有一个标签时新格留空，由调用方给它开新标签。已分屏时什么也不做。
    func split() {
        guard panes.count < Self.maxPanes else { return }
        let source = panes.firstIndex { $0.id == focusedPaneID } ?? 0
        panes.append(MPane())
        let target = panes.count - 1
        if panes[source].tabIDs.count > 1, let moving = panes[source].activeID {
            move(moving, from: source, to: target)
        }
        focusedPaneID = panes[target].id
    }

    /// 取消分屏：所有标签并回第一格，聚焦格的前台标签仍在前台。
    func unsplit() {
        guard isSplit else { return }
        let keepActive = focusedPane.activeID ?? panes[0].activeID
        var merged = panes[0]
        for pane in panes.dropFirst() { merged.tabIDs.append(contentsOf: pane.tabIDs) }
        merged.activeID = keepActive
        panes = [merged]
        focusedPaneID = merged.id
    }

    /// 把标签挪到另一格（没分屏就先拆出一格）。挪走后原格空了会收起，等同取消分屏。
    func moveToOtherPane(_ tabID: UUID) {
        guard let source = paneIndex(containing: tabID) else { return }
        if !isSplit { panes.append(MPane()) }
        let target = source == 0 ? 1 : 0
        move(tabID, from: source, to: target)
        focusedPaneID = panes[target].id
        if panes[source].tabIDs.isEmpty { removePane(at: source) }
    }

    private func move(_ tabID: UUID, from source: Int, to target: Int) {
        guard let pos = panes[source].tabIDs.firstIndex(of: tabID) else { return }
        panes[source].tabIDs.remove(at: pos)
        if panes[source].activeID == tabID {
            let ids = panes[source].tabIDs
            panes[source].activeID = ids.isEmpty ? nil : ids[min(pos, ids.count - 1)]
        }
        panes[target].tabIDs.append(tabID)
        panes[target].activeID = tabID
    }

    private func removePane(at index: Int) {
        let removedID = panes[index].id
        panes.remove(at: index)
        if focusedPaneID == removedID { focusedPaneID = panes[0].id }
    }
}
