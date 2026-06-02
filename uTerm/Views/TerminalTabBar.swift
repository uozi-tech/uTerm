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
                HStack(spacing: 0) {
                    ForEach(workspace.tabs) { tab in
                        TerminalTabChip(
                            tab: tab,
                            isActive: workspace.activeTabID == tab.id,
                            onSelect: { workspace.selectTab(tab.id) },
                            onClose:  { workspace.closeTab(tab.id) })
                            .frame(maxHeight: .infinity)
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
                        // 图标色不在这里设——交给 iconButtonHover 随 hover 切换。
                        Image(systemName: "plus")
                            .frame(width: 24, height: 24)
                    }
                    .buttonStyle(.plain)
                    .iconButtonHover()
                    .help("新建终端标签（⌘T）")
                    .padding(.leading, 4)
                    // ⌘T 走 uTermApp 的 CommandGroup 单独注册 —— 按在终端焦点
                    // 区时也能正确触发（Fix #10）；这里只是 UI 按钮入口。
                }
                .frame(maxHeight: .infinity)
            }
            .frame(maxHeight: .infinity)
        }
        .frame(height: 32)
        .background(.regularMaterial)
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
        .padding(.horizontal, 10)
        .frame(maxHeight: .infinity)
        .background(
            // 活动 tab 用 controlBackgroundColor（=Editor / 终端区同色），视觉上跟下方主区无缝
            // 衔接；非活动 tab 留空，继承 TabBar 的 .regularMaterial。不用圆角，
            // 否则跟"无缝"目标矛盾。
            isActive ? Color(nsColor: .controlBackgroundColor) : Color.clear
        )
        .overlay(alignment: .top) {
            // 顶部 1px accent 横线，VS Code Dark Modern 标示活动 tab 的方式
            if isActive {
                Rectangle().fill(AppTheme.Palette.accent).frame(height: 1)
            }
        }
        .hoverBackground(cornerRadius: 0, isActive: isActive)
        .contentShape(Rectangle())
        .onTapGesture(perform: onSelect)
        .onHover { isHovered = $0 }
    }
}
