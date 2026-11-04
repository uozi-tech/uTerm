import UDesignKit
import Foundation

/// 命令面板条目的种类。决定分组标题、显示顺序、图标。
nonisolated enum CommandPaletteKind: String, CaseIterable {
    case host, command, file, setting

    var label: String {
        switch self {
        case .host:    return "主机"
        case .command: return "命令"
        case .file:    return "文件"
        case .setting: return "设置"
        }
    }

    /// 分组显示顺序（复刻设计稿 groupResults 的 order）。
    var order: Int {
        switch self {
        case .host:    return 0
        case .command: return 1
        case .file:    return 2
        case .setting: return 3
        }
    }

    /// 类型图标（SF Symbol；设计稿自绘 SVG 的近似映射）。
    var symbol: String {
        switch self {
        case .host:    return "server.rack"
        case .command: return "command"
        case .file:    return "doc"
        case .setting: return "gearshape"
        }
    }
}

/// 命令面板的一个条目。`run` 是选中执行的动作（在主线程跑）。
nonisolated struct CommandPaletteItem: Identifiable {
    let id: String
    let kind: CommandPaletteKind
    let title: String
    let detail: String
    let hint: String          // 右侧提示，如「连接」「⌘N」「打开」「↵」
    let group: String?        // 二级分组名（本版本不渲染，预留）
    let run: @MainActor () -> Void

    init(id: String, kind: CommandPaletteKind, title: String, detail: String,
         hint: String, group: String? = nil, run: @escaping @MainActor () -> Void) {
        self.id = id
        self.kind = kind
        self.title = title
        self.detail = detail
        self.hint = hint
        self.group = group
        self.run = run
    }
}

/// 一个分组（kind + 标题 + 该组条目）。
nonisolated struct CommandPaletteSection: Identifiable {
    var id: String { kind.rawValue }
    let kind: CommandPaletteKind
    let label: String
    let items: [CommandPaletteItem]
}

/// 子串过滤：query 为空（或纯空白）→ 不显示建议；否则 title/detail/kind 任一含 query（小写）即保留。
/// 复刻设计稿 filterCommands。
nonisolated func filterCommandPalette(_ items: [CommandPaletteItem],
                                      query: String) -> [CommandPaletteItem] {
    let q = query.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
    guard !q.isEmpty else { return [] }
    // kind.rawValue（英文：host/command/file/setting）也参与匹配：power-user 可直接键入类型名筛选。
    return items.filter {
        $0.title.lowercased().contains(q) ||
        $0.detail.lowercased().contains(q) ||
        $0.kind.rawValue.lowercased().contains(q)
    }
}

/// 按 kind.order 分组：只产出存在的组，组内保持输入顺序。复刻设计稿 groupResults。
nonisolated func groupCommandPalette(_ items: [CommandPaletteItem]) -> [CommandPaletteSection] {
    CommandPaletteKind.allCases
        .sorted { $0.order < $1.order }
        .compactMap { kind in
            let group = items.filter { $0.kind == kind }
            return group.isEmpty ? nil
                : CommandPaletteSection(kind: kind, label: kind.label, items: group)
        }
}

/// 完全匹配优先：title 或 detail 与 query 相等（忽略大小写和首尾空白）。
/// 精确项及其分组都会稳定前移，其余条目仍保持原有分组与输入顺序。
nonisolated func groupCommandPaletteByMatchPriority(
    _ items: [CommandPaletteItem],
    query: String
) -> [CommandPaletteSection] {
    let normalizedQuery = normalizedCommandPaletteText(query)
    guard !normalizedQuery.isEmpty else { return groupCommandPalette(items) }

    var exactItems: [CommandPaletteItem] = []
    var otherItems: [CommandPaletteItem] = []
    var exactKinds = Set<CommandPaletteKind>()
    exactItems.reserveCapacity(items.count)
    otherItems.reserveCapacity(items.count)

    for item in items {
        if isExactCommandPaletteMatch(item, normalizedQuery: normalizedQuery) {
            exactItems.append(item)
            exactKinds.insert(item.kind)
        } else {
            otherItems.append(item)
        }
    }

    guard !exactItems.isEmpty else { return groupCommandPalette(items) }

    let sections = groupCommandPalette(exactItems + otherItems)
    return sections.filter { exactKinds.contains($0.kind) }
        + sections.filter { !exactKinds.contains($0.kind) }
}

nonisolated private func normalizedCommandPaletteText(_ value: String) -> String {
    value.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
}

nonisolated private func isExactCommandPaletteMatch(
    _ item: CommandPaletteItem,
    normalizedQuery: String
) -> Bool {
    normalizedCommandPaletteText(item.title) == normalizedQuery
        || normalizedCommandPaletteText(item.detail) == normalizedQuery
}

/// 按 id 去重，保留首次出现（静态项在前 → 压过同 id 的动态搜索命中）。
nonisolated func dedupeCommandPaletteByID(_ items: [CommandPaletteItem]) -> [CommandPaletteItem] {
    var seen = Set<String>()
    return items.filter { seen.insert($0.id).inserted }
}

/// 共享的「设置」命令项：写 SettingsTabSelection.key 后打开设置窗，深链到对应 tab。
/// `openSettings` 由各窗口注入（`@Environment(\.openSettings)` 包成闭包）。
@MainActor
func commandPaletteSettingsItems(openSettings: @escaping () -> Void) -> [CommandPaletteItem] {
    let tabs: [(SettingsTab, String)] = [
        (.general,   "外观、启动、语言、更新"),
        (.providers, "Anthropic / OpenAI 兼容"),
        (.terminal,  "字体、颜色、行距"),
        (.advanced,  "SSH 超时 / 主机校验 / 日志"),
    ]
    return tabs.map { tab, detail in
        CommandPaletteItem(
            id: "setting.\(tab.rawValue)", kind: .setting,
            title: "设置 · \(tab.label)", detail: detail, hint: "↵", group: nil) {
                UserDefaults.standard.set(tab.rawValue, forKey: SettingsTabSelection.key)
                openSettings()
            }
    }
}

/// uTerm-only command-palette bridge for the shared package's accent state.
@MainActor
func commandPaletteAccentItems(state: AccentState = .shared) -> [CommandPaletteItem] {
    AccentColor.allCases.map { color in
        CommandPaletteItem(
            id: "setting.accent.\(color.rawValue)",
            kind: .setting,
            title: "强调色 · \(color.label)",
            detail: "切换全局界面强调色",
            hint: state.selected == color ? "当前" : "↵",
            group: nil
        ) {
            state.selected = color
        }
    }
}
