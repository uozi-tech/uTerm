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

/// 一个标签的快照。
nonisolated struct TabSnapshot: Codable, Equatable, Sendable {
    var title: String
    var layout: NodeSnapshot
}

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
    var tabs: [TabSnapshot]
    var activeTabIndex: Int?
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
         uiState: WorkspaceUIState? = nil,
         fileBrowserPath: String? = nil,
         openFiles: [OpenFileSnapshot]? = nil,
         activeFileIndex: Int? = nil,
         agentState: AgentSnapshot? = nil) {
        self.tabs = tabs
        self.activeTabIndex = activeTabIndex
        self.uiState = uiState
        self.fileBrowserPath = fileBrowserPath
        self.openFiles = openFiles
        self.activeFileIndex = activeFileIndex
        self.agentState = agentState
    }
}
