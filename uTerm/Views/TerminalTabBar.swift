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
                                    .foregroundStyle(WS.text2)
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
        .frame(height: 36)
        .background(WS.panel)
        .overlay(alignment: .bottom) {
            Rectangle().fill(WS.border).frame(height: 1)
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
                    .fill(WS.color(for: ConnectionStatusDisplay(state: session.connectionState).tint))
                    .frame(width: 6, height: 6)
            }
            Text(tab.title)
                .font(WS.mono(12))
                .lineLimit(1)
                .foregroundStyle(isActive ? WS.text : WS.text3)
            Button(action: onClose) {
                Image(systemName: "xmark").font(.system(size: 9))
            }
            .buttonStyle(.plain)
            .foregroundStyle(WS.text3)
            .opacity(isHovered ? 1 : 0)
            .allowsHitTesting(isHovered)
        }
        .padding(.horizontal, 10)
        .frame(maxHeight: .infinity)
        .background(
            // 活动 tab 用终端正文同色（TerminalTheme.backgroundColor），与下方终端区
            // 无缝衔接；非活动 tab 透明，露出 WS.panel 的 tab 条底。不用圆角。
            isActive ? Color(nsColor: TerminalTheme.backgroundColor) : Color.clear
        )
        .overlay(alignment: .top) {
            // 顶部 2px accent 横线（设计稿活动 tab 标示）。
            if isActive {
                Rectangle().fill(WS.accent).frame(height: 2)
            }
        }
        .hoverBackground(WS.rowHover, cornerRadius: 0, isActive: isActive)
        .contentShape(Rectangle())
        .onTapGesture(perform: onSelect)
        .onHover { isHovered = $0 }
    }
}
