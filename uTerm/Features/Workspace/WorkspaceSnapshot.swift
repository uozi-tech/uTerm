import UPaneGroups
import UPaneTree
import Foundation

/// 持久化用的布局树快照。叶子记录 `serverProfileID`。
nonisolated indirect enum NodeSnapshot: Codable, Equatable, Sendable {
    case leaf(serverProfileID: UUID)
    case split(direction: SplitDirection, fraction: Double,
               first: NodeSnapshot, second: NodeSnapshot)
}

// 自定义 Codable —— `leaf` 解码时兼容含 kind 字段的 pane-types 时期旧快照。
// 冲突说明：把 `Codable` 写在主声明（`nonisolated` 类型）上而非扩展上，
// 否则在 main-actor 默认隔离的模块里扩展会让该 conformance 变成 main-actor 隔离。
extension NodeSnapshot {
    private enum CodingKeys: String, CodingKey { case leaf, split }
    private enum LeafKeys: String, CodingKey { case serverProfileID, kind }  // kind 保留键名，仅为兼容旧 JSON
    private enum SplitKeys: String, CodingKey { case direction, fraction, first, second }

    nonisolated init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        if container.contains(.leaf) {
            let leaf = try container.nestedContainer(keyedBy: LeafKeys.self, forKey: .leaf)
            // 老 JSON 可能含 kind 字段（pane-types 时期），统一忽略。
            self = .leaf(serverProfileID: try leaf.decode(UUID.self, forKey: .serverProfileID))
        } else if container.contains(.split) {
            let split = try container.nestedContainer(keyedBy: SplitKeys.self, forKey: .split)
            self = .split(
                direction: try split.decode(SplitDirection.self, forKey: .direction),
                fraction: try split.decode(Double.self, forKey: .fraction),
                first: try split.decode(NodeSnapshot.self, forKey: .first),
                second: try split.decode(NodeSnapshot.self, forKey: .second))
        } else {
            throw DecodingError.dataCorrupted(.init(
                codingPath: decoder.codingPath,
                debugDescription: "NodeSnapshot 既非 leaf 也非 split"))
        }
    }

    nonisolated func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        switch self {
        case .leaf(let serverProfileID):
            var leaf = container.nestedContainer(keyedBy: LeafKeys.self, forKey: .leaf)
            try leaf.encode(serverProfileID, forKey: .serverProfileID)
        case .split(let direction, let fraction, let first, let second):
            var split = container.nestedContainer(keyedBy: SplitKeys.self, forKey: .split)
            try split.encode(direction, forKey: .direction)
            try split.encode(fraction, forKey: .fraction)
            try split.encode(first, forKey: .first)
            try split.encode(second, forKey: .second)
        }
    }
}

extension NodeSnapshot {
    /// 深度优先摊平成 `serverProfileID` 序列（保序）。老快照迁移时，非活动标签的
    /// 每个窗格各降成第一个组里的一个标签，用的就是这个序列。
    nonisolated var leafServerIDs: [UUID] {
        switch self {
        case .leaf(let serverProfileID):
            return [serverProfileID]
        case .split(_, _, let first, let second):
            return first.leafServerIDs + second.leafServerIDs
        }
    }
}

/// 一个标签的快照。
nonisolated struct TabSnapshot: Codable, Equatable, Sendable {
    var title: String
    var layout: NodeSnapshot
}

/// 终端组树里一个标签的快照 —— 组件 `UPaneGroupsSnapshot` 的泛型载荷。
/// 只记「连哪台服务器 + 标题」：会话本身不进盘，恢复后重连。
nonisolated struct TerminalTabSnapshot: Codable, Equatable, Sendable {
    var serverProfileID: UUID
    var title: String
}

/// 终端区的组树快照：一棵组树 + 每组的标签列表 + 每组 `activeIndex` + 活动组。
/// 编解码全部复用组件自带的 `UPaneGroupsModel.snapshot(_:)` / `restore(_:make:)`，
/// 这里只定标签载荷。快照里**不存 UUID** —— 组 id 与分屏节点 id 恢复时重新铸造。
typealias TerminalGroupsSnapshot = UPaneGroupsSnapshot<TerminalTabSnapshot>

/// 预览/编辑区打开文件的轻量快照。只保存远程路径和加载元信息；
/// 重连后内容通过 SFTP 重新读取，不保存编辑器正文或未保存修改。
nonisolated struct OpenFileSnapshot: Codable, Equatable, Sendable {
    var remotePath: String
    /// nil 表示保存快照时远端大小未知。Optional 同时兼容旧快照中的整数值。
    var byteSize: Int64?
    var mtimeWhenLoaded: Date?
}

// `AgentSnapshot` 已抽到共享文件 `Features/Agent/AgentSnapshot.swift`
// （随 `AssistantModel` 一并进入移动端 target）。

/// 整个工作区的快照。
nonisolated struct WorkspaceSnapshot: Codable, Equatable, Sendable {
    /// **旧格式**：一个窗口级标签一棵窗格树。新模型（全窗口一棵组树）表达不了它。
    ///
    /// 读：只在 `terminalGroups` 缺失时用作迁移输入（`migratingLegacyTabs`）。
    /// 写：**仍然写**，作为降级回滚通道 —— 用户装回旧版本时不至于开出一个空窗口。
    /// 降维方式是「一个标签一条 `TabSnapshot`，layout 恒为单叶」而不是设计文档
    /// §4.2 建议的「一个组一条」：前者会话一条不丢（旧版本把它们摊成一排窗口级
    /// 标签），后者会把每个组的后台标签整条丢掉。
    var tabs: [TabSnapshot]
    var activeTabIndex: Int?
    /// **新格式**：终端区的组树，分屏形状 / fraction / 每组标签顺序 / 每组前台标签 /
    /// 活动组全在里面。nil = 老快照，按 `migratingLegacyTabs` 迁移。
    var terminalGroups: TerminalGroupsSnapshot?
    /// 窗口的 UI 状态（sidebar / inspector / 预览-终端比例）。
    /// 老的 workspace-<id>.json 没有这个字段，解码后为 nil，由 `WorkspaceModel`
    /// 用默认 `WorkspaceUIState()` 接住。
    var uiState: WorkspaceUIState?
    /// 左侧 SFTP 当前目录。nil 表示让连接逻辑使用远端 home。
    var fileBrowserPath: String?
    /// 预览/编辑区已打开的远程文件 tab。
    var openFiles: [OpenFileSnapshot]?
    var activeFileIndex: Int?
    /// 右侧 Agent 对话框状态。nil 表示旧快照或没有可恢复状态。
    var agentState: AgentSnapshot?

    init(tabs: [TabSnapshot],
         activeTabIndex: Int?,
         terminalGroups: TerminalGroupsSnapshot? = nil,
         uiState: WorkspaceUIState? = nil,
         fileBrowserPath: String? = nil,
         openFiles: [OpenFileSnapshot]? = nil,
         activeFileIndex: Int? = nil,
         agentState: AgentSnapshot? = nil) {
        self.tabs = tabs
        self.activeTabIndex = activeTabIndex
        self.terminalGroups = terminalGroups
        self.uiState = uiState
        self.fileBrowserPath = fileBrowserPath
        self.openFiles = openFiles
        self.activeFileIndex = activeFileIndex
        self.agentState = agentState
    }
}

// MARK: - 终端区：新格式优先，老格式迁移

extension WorkspaceSnapshot {
    /// 终端区该恢复成什么样的组树。
    ///
    /// 新快照直接取 `terminalGroups`；老快照（该键为 nil）走 `migratingLegacyTabs`。
    /// 白名单剪枝**不在这里做** —— 它在 `UPaneGroupsModel.restore` 的 `make` 闭包里，
    /// 对新老两种格式一视同仁。
    nonisolated var terminalGroupsForRestore: TerminalGroupsSnapshot {
        terminalGroups ?? Self.migratingLegacyTabs(tabs, activeTabIndex: activeTabIndex)
    }

    /// 老格式（每个窗口级标签一棵窗格树）→ 新格式（全窗口一棵组树）。
    /// 设计文档 §4.2 的 M2 规则，逐条：
    ///
    /// 1. **活动标签保形**：`activeTabIndex` 那棵窗格树整棵迁过来，每个叶子变成一个
    ///    组、组里放一个标签。分屏方向与 `fraction` 全部保留。
    /// 2. 其余每个标签按深度优先把它树里的每个叶子各变成一个标签，**追加到第一个组
    ///    的标签列表末尾**（保留原标签顺序）。
    /// 3. 活动组 = 第一个组（旧的 `focusedPaneID` 本来就不持久化）；第一个组的前台
    ///    标签是它自己那条，即索引 0。
    ///
    /// **代价：非活动标签的分屏形状丢掉。** 会话一条不丢（都会重连），丢的只是
    /// 「标签 B 曾经是 2×2 四宫格」这条布局信息 —— 新模型全窗口只有一棵组树，
    /// 表达不了「每个标签一套分屏」（设计文档 §4.4(b)，用户已知悉并接受）。
    ///
    /// `activeTabIndex` 为 nil / 越界时取第 0 个标签；`tabs` 为空时给一个空组。
    nonisolated static func migratingLegacyTabs(
        _ tabs: [TabSnapshot], activeTabIndex: Int?) -> TerminalGroupsSnapshot {
        guard !tabs.isEmpty else { return .empty }
        let activeIndex = tabs.indices.contains(activeTabIndex ?? -1) ? activeTabIndex! : 0

        var groups: [TerminalGroupsSnapshot.Group] = []
        // 步骤 1：活动标签保形。DFS 顺序铸组，所以第一个叶子必然是 groups[0]。
        func convert(_ node: NodeSnapshot, title: String) -> TerminalGroupsSnapshot.Node {
            switch node {
            case .leaf(let serverProfileID):
                groups.append(TerminalGroupsSnapshot.Group(
                    tabs: [TerminalTabSnapshot(serverProfileID: serverProfileID, title: title)],
                    activeIndex: 0))
                return .leaf(groupIndex: groups.count - 1)
            case .split(let direction, let fraction, let first, let second):
                // 先左后右，保证 groupIndex 与 DFS 叶子序一致。
                let lhs = convert(first, title: title)
                let rhs = convert(second, title: title)
                return .split(direction: direction, fraction: fraction, first: lhs, second: rhs)
            }
        }
        let root = convert(tabs[activeIndex].layout, title: tabs[activeIndex].title)

        // 步骤 2：其余标签的每个窗格 → 第一个组的一个标签。
        for (index, tab) in tabs.enumerated() where index != activeIndex {
            for serverProfileID in tab.layout.leafServerIDs {
                groups[0].tabs.append(
                    TerminalTabSnapshot(serverProfileID: serverProfileID, title: tab.title))
            }
        }
        // 步骤 3：活动组 = 第一个组；它的前台标签是活动标签自己那条（索引 0）。
        return TerminalGroupsSnapshot(root: root, groups: groups, activeGroupIndex: 0)
    }
}

// MARK: - Equatable

extension WorkspaceSnapshot {
    /// 手写 `==`：`UPaneGroupsSnapshot` 不带 `Equatable`（组件缺口），合成不出来。
    ///
    /// **新增字段必须同步加进来。** `WorkspaceSnapshotAutosave` 是
    /// `.onChange(of: workspace.autosaveStructureSnapshot())`，漏一项就等于那一类
    /// 变化不再触发自动保存 —— 比如只拖分隔条改 `fraction`，除了组树没有别的字段会动。
    nonisolated static func == (lhs: WorkspaceSnapshot, rhs: WorkspaceSnapshot) -> Bool {
        lhs.tabs == rhs.tabs
            && lhs.activeTabIndex == rhs.activeTabIndex
            && lhs.uiState == rhs.uiState
            && lhs.fileBrowserPath == rhs.fileBrowserPath
            && lhs.openFiles == rhs.openFiles
            && lhs.activeFileIndex == rhs.activeFileIndex
            && lhs.agentState == rhs.agentState
            && Self.groupsEqual(lhs.terminalGroups, rhs.terminalGroups)
    }

    nonisolated static func groupsEqual(_ lhs: TerminalGroupsSnapshot?,
                                        _ rhs: TerminalGroupsSnapshot?) -> Bool {
        switch (lhs, rhs) {
        case (nil, nil):
            return true
        case (let lhs?, let rhs?):
            guard lhs.activeGroupIndex == rhs.activeGroupIndex,
                  lhs.groups.count == rhs.groups.count else { return false }
            let sameGroups = zip(lhs.groups, rhs.groups).allSatisfy {
                $0.activeIndex == $1.activeIndex && $0.tabs == $1.tabs
            }
            return sameGroups && nodesEqual(lhs.root, rhs.root)
        default:
            return false
        }
    }

    private nonisolated static func nodesEqual(_ lhs: TerminalGroupsSnapshot.Node,
                                               _ rhs: TerminalGroupsSnapshot.Node) -> Bool {
        switch (lhs, rhs) {
        case (.leaf(let a), .leaf(let b)):
            return a == b
        case (.split(let d1, let f1, let x1, let y1), .split(let d2, let f2, let x2, let y2)):
            return d1 == d2 && f1 == f2 && nodesEqual(x1, x2) && nodesEqual(y1, y2)
        default:
            return false
        }
    }
}
