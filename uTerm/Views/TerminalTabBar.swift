import SwiftUI
import UniformTypeIdentifiers

/// 工作区中央下半部（终端区）上沿的 tab 条。
/// 替代 `WorkspaceTitlebarTabs`：信息密度近似，样式适配嵌入区域。
struct TerminalTabBar: View {
    let workspace: WorkspaceModel
    let onNewTab: () -> Void

    var body: some View {
        HStack(spacing: 0) {
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 4) {
                    ForEach(workspace.tabs) { tab in
                        TerminalTabChip(
                            tab: tab,
                            isActive: workspace.activeTabID == tab.id,
                            onSelect: { workspace.selectTab(tab.id) },
                            onClose:  { workspace.closeTab(tab.id) })
                            .draggable(TabDragItem(tabID: tab.id)) {
                                Text(tab.title).font(.callout)
                                    .padding(6)
                                    .foregroundStyle(AppTheme.Palette.textSecondary)
                            }
                            .dropDestination(for: TabDragItem.self) { items, _ in
                                guard let dragged = items.first,
                                      let toIndex = workspace.tabs.firstIndex(where: { $0.id == tab.id })
                                else { return false }
                                workspace.moveTab(fromID: dragged.tabID, toIndex: toIndex)
                                return true
                            }
                    }
                    Button(action: onNewTab) {
                        Image(systemName: "plus")
                            .foregroundStyle(AppTheme.Palette.textSecondary)
                            .frame(width: 24, height: 24)
                    }
                    .buttonStyle(.plain)
                    .help("新建终端标签（⌘T）")
                    // ⌘T 走 uTermApp 的 CommandGroup 单独注册 —— 按在终端焦点
                    // 区时也能正确触发（Fix #10）；这里只是 UI 按钮入口。
                }
                .padding(.horizontal, 8)
                .padding(.vertical, 4)
            }
        }
        .frame(height: 32)
        .background(AppTheme.Palette.bgPanel)
        .overlay(alignment: .bottom) {
            Rectangle().fill(AppTheme.Palette.border).frame(height: 1)
        }
    }
}

private struct TerminalTabChip: View {
    let tab: TabModel
    let isActive: Bool
    let onSelect: () -> Void
    let onClose: () -> Void

    @State private var isHovered = false

    var body: some View {
        HStack(spacing: 6) {
            if let session = tab.focusedPane?.session {
                Circle()
                    .fill(ConnectionStatusDisplay(state: session.connectionState).tint.color)
                    .frame(width: 6, height: 6)
            }
            Image(systemName: "terminal")
                .font(.caption)
                .foregroundStyle(AppTheme.Palette.textMuted)
            Text(tab.title)
                .font(.callout)
                .lineLimit(1)
                .foregroundStyle(isActive ? AppTheme.Palette.textPrimary
                                          : AppTheme.Palette.textSecondary)
            Button(action: onClose) {
                Image(systemName: "xmark").font(.system(size: 9))
            }
            .buttonStyle(.plain)
            .foregroundStyle(AppTheme.Palette.textMuted)
            .opacity(isHovered ? 1 : 0)
            .allowsHitTesting(isHovered)
        }
        .padding(.horizontal, 10).padding(.vertical, 4)
        .background(
            ZStack {
                if isActive {
                    RoundedRectangle(cornerRadius: 5)
                        .fill(AppTheme.Palette.bgSelected)
                }
            }
        )
        .overlay(alignment: .leading) {
            if isActive {
                Rectangle().fill(AppTheme.Palette.accent).frame(width: 2)
                    .padding(.vertical, 3)
            }
        }
        .contentShape(Rectangle())
        .onTapGesture(perform: onSelect)
        .onHover { isHovered = $0 }
    }
}
