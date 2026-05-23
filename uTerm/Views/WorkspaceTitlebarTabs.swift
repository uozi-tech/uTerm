import SwiftUI
import UniformTypeIdentifiers

/// 嵌入到 macOS 系统标题栏的 tab 条（Finder 式）。chip 即标题。
struct WorkspaceTitlebarTabs: View {
    let workspace: WorkspaceModel
    /// 点 chip 末尾 + 菜单选择窗格种类时触发（上层据此新建对应 tab）。
    let onNewTab: (PaneKindTag) -> Void

    var body: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 4) {
                ForEach(workspace.tabs) { tab in
                    TabChip(
                        tab: tab,
                        isActive: workspace.activeTabID == tab.id,
                        onSelect: { workspace.selectTab(tab.id) },
                        onClose: { workspace.closeTab(tab.id) })
                        .draggable(TabDragItem(tabID: tab.id)) {
                            chipLabel(tab).padding(6)
                        }
                        .dropDestination(for: TabDragItem.self) { items, _ in
                            guard let dragged = items.first,
                                  let toIndex = workspace.tabs.firstIndex(where: { $0.id == tab.id })
                            else { return false }
                            workspace.moveTab(fromID: dragged.tabID, toIndex: toIndex)
                            return true
                        }
                }
                NewTabMenu(onNewTab: onNewTab)
            }
            .padding(.horizontal, 6)
            .padding(.vertical, 2)   // 系统 titlebar 高度受限，留 2pt 即可
        }
    }

    /// 拖拽时跟随光标的最小卡片。
    private func chipLabel(_ tab: TabModel) -> some View {
        Text(tab.title).font(.callout).lineLimit(1)
    }
}

/// 单个 tab chip：状态点 + 图标 + 标题 + hover 时显示的 ×。
private struct TabChip: View {
    let tab: TabModel
    let isActive: Bool
    let onSelect: () -> Void
    let onClose: () -> Void

    @State private var isHovered = false

    var body: some View {
        HStack(spacing: 6) {
            if let session = focusedTerminalSession {
                Circle()
                    .fill(ConnectionStatusDisplay(state: session.connectionState).tint.color)
                    .frame(width: 6, height: 6)
            }
            Image(systemName: chipIcon)
                .font(.caption)
                .foregroundStyle(.secondary)
            Text(tab.title)
                .font(.callout)
                .lineLimit(1)
            // X 仅 hover 出现；用 .opacity + .allowsHitTesting 而非分支切换，
            // 避免每次 hover 都重建 Button，宽度也自然占位、不抖动。
            Button(action: onClose) {
                Image(systemName: "xmark").font(.system(size: 9))
            }
            .buttonStyle(.plain)
            .opacity(isHovered ? 1 : 0)
            .allowsHitTesting(isHovered)
        }
        .padding(.horizontal, 10).padding(.vertical, 4)
        .background(isActive ? Color.accentColor.opacity(0.2) : Color.clear)
        .clipShape(RoundedRectangle(cornerRadius: 6))
        .contentShape(Rectangle())
        .onTapGesture(perform: onSelect)
        .onHover { isHovered = $0 }
    }

    private var chipIcon: String {
        switch tab.focusedPane?.kind {
        case .terminal: return "terminal"
        case .files:    return "folder"
        case .none:     return "questionmark.circle"
        }
    }

    private var focusedTerminalSession: TerminalSession? {
        if case .terminal(let session) = tab.focusedPane?.kind { return session }
        return nil
    }
}

/// chip 行末尾的 + 菜单，新建终端 / 文件 tab。
private struct NewTabMenu: View {
    let onNewTab: (PaneKindTag) -> Void

    var body: some View {
        Menu {
            Button("新建终端标签") { onNewTab(.terminal) }
            Button("新建文件标签") { onNewTab(.files) }
        } label: {
            Image(systemName: "plus")
        }
        .menuStyle(.borderlessButton)
        .menuIndicator(.hidden)
        .fixedSize()
        .padding(.horizontal, 6)
        .help("新建标签")
    }
}
