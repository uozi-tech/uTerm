import SwiftUI

/// 工作区窗口的 UI 状态：sidebar 折叠 / inspector 显隐 / 预览-终端比例。
/// 进入 `WorkspaceSnapshot` 持久化。`NavigationSplitViewVisibility` 不直接 Codable，
/// 通过 String 表示编解码；未知字符串落回 `.all`，保持向前兼容。
nonisolated struct WorkspaceUIState: Codable, Equatable, Sendable {
    var leftSidebarVisibility: NavigationSplitViewVisibility = .all
    var rightInspectorPresented: Bool = true
    /// 预览区在中央 VSplit 中所占比例 (0.1...0.9)；setter clamp。
    private var _previewTerminalRatio: Double = 0.667
    var previewTerminalRatio: Double {
        get { _previewTerminalRatio }
        set { _previewTerminalRatio = min(0.9, max(0.1, newValue)) }
    }

    /// 自绘三栏的列宽（pt），持久化。clamp 在拖拽处（ColumnResizer）做。
    var sidebarWidth: Double = 300
    var inspectorWidth: Double = 300

    /// 左 sidebar 是否可见（自绘布局用）。沿用 `leftSidebarVisibility` 字段存储以
    /// 保持快照向后兼容：`.detailOnly` = 隐藏，其余 = 显示。
    var leftSidebarVisible: Bool { leftSidebarVisibility != .detailOnly }

    init() {}

    init(leftSidebarVisibility: NavigationSplitViewVisibility = .all,
         rightInspectorPresented: Bool = true,
         previewTerminalRatio: Double = 0.667) {
        self.leftSidebarVisibility = leftSidebarVisibility
        self.rightInspectorPresented = rightInspectorPresented
        self.previewTerminalRatio = previewTerminalRatio
    }

    // MARK: Codable

    private enum CodingKeys: String, CodingKey {
        case leftSidebarVisibility, rightInspectorPresented, previewTerminalRatio
        case sidebarWidth, inspectorWidth
    }

    private static func visibility(from raw: String) -> NavigationSplitViewVisibility {
        switch raw {
        case "all":          return .all
        case "detailOnly":   return .detailOnly
        case "doubleColumn": return .doubleColumn
        case "automatic":    return .automatic
        default:             return .all
        }
    }

    private static func raw(_ v: NavigationSplitViewVisibility) -> String {
        // NavigationSplitViewVisibility 在不同 SDK 版本下可能新增 case；
        // 用 == 而非 switch 来避免 'switch must be exhaustive' 编译错误。
        if v == .all          { return "all" }
        if v == .detailOnly   { return "detailOnly" }
        if v == .doubleColumn { return "doubleColumn" }
        if v == .automatic    { return "automatic" }
        return "all"
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let visRaw = try c.decodeIfPresent(String.self, forKey: .leftSidebarVisibility) ?? "all"
        self.leftSidebarVisibility = Self.visibility(from: visRaw)
        self.rightInspectorPresented = try c.decodeIfPresent(Bool.self, forKey: .rightInspectorPresented) ?? true
        let ratio = try c.decodeIfPresent(Double.self, forKey: .previewTerminalRatio) ?? 0.667
        self.previewTerminalRatio = ratio   // 经 setter clamp
        self.sidebarWidth = try c.decodeIfPresent(Double.self, forKey: .sidebarWidth) ?? 300
        self.inspectorWidth = try c.decodeIfPresent(Double.self, forKey: .inspectorWidth) ?? 300
    }

    func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(Self.raw(leftSidebarVisibility), forKey: .leftSidebarVisibility)
        try c.encode(rightInspectorPresented, forKey: .rightInspectorPresented)
        try c.encode(_previewTerminalRatio, forKey: .previewTerminalRatio)
        try c.encode(sidebarWidth, forKey: .sidebarWidth)
        try c.encode(inspectorWidth, forKey: .inspectorWidth)
    }

    static func == (lhs: WorkspaceUIState, rhs: WorkspaceUIState) -> Bool {
        lhs.leftSidebarVisibility == rhs.leftSidebarVisibility
            && lhs.rightInspectorPresented == rhs.rightInspectorPresented
            && abs(lhs._previewTerminalRatio - rhs._previewTerminalRatio) < 0.0001
            && abs(lhs.sidebarWidth - rhs.sidebarWidth) < 0.5
            && abs(lhs.inspectorWidth - rhs.inspectorWidth) < 0.5
    }
}
