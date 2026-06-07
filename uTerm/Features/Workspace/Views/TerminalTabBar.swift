import SwiftUI
import UniformTypeIdentifiers

/// 工作区中央下半部（终端区）上沿的 tab 条。
/// chip 用 DesignKit `UDTermTab`：连接状态点传连接色、激活底色传终端正文色以无缝衔接；
/// 拖拽重排 / 新建按钮仍在本条内（UD 件不含这些 domain 行为）。
struct TerminalTabBar: View {
    let workspace: WorkspaceModel
    let onNewTab: () -> Void

    @Environment(\.colorScheme) private var appColorScheme

    private var terminalAreaBG: Color {
        Color(nsColor: TerminalColorScheme.resolve(dark: appColorScheme == .dark).backgroundColor)
    }

    var body: some View {
        HStack(spacing: 0) {
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 0) {
                    ForEach(Array(workspace.tabs.enumerated()), id: \.element.id) { index, tab in
                        UDTermTab(
                            name: tab.title,
                            active: workspace.activeTabID == tab.id,
                            first: index == 0,
                            dotColor: Self.dotColor(for: tab),
                            activeBackground: terminalAreaBG,
                            onSelect: { workspace.selectTab(tab.id) },
                            onClose:  { workspace.closeTab(tab.id) })
                            .frame(maxHeight: .infinity)
                            // 选中态供 VoiceOver 念读；整条 tab 区 .contain 聚合为一组。
                            .accessibilityElement(children: .combine)
                            .accessibilityLabel(Text(tab.title))
                            .accessibilityAddTraits(
                                workspace.activeTabID == tab.id ? [.isButton, .isSelected] : .isButton)
                            .onDrag {
                                workspace.beginDrag(.tab(tab.id))
                                return TabDragPayload.itemProvider(tabID: tab.id)
                            } preview: {
                                Text(tab.title).font(.callout)
                                    .padding(6)
                                    .foregroundStyle(UD.text2)
                            }
                            .onDrop(of: [.utermTabID], delegate: TabReorderDropDelegate(
                                workspace: workspace,
                                targetTabID: tab.id))
                    }
                    Button(action: onNewTab) {
                        // 图标色不在这里设——交给 iconButtonHover 随 hover 切换。
                        Image(systemName: "plus")
                            .frame(width: 24, height: 24)
                    }
                    .buttonStyle(.plain)
                    .iconButtonHover()
                    .help("新建终端标签（⌘T）")
                    .accessibilityLabel(Text("新建终端标签"))
                    .padding(.leading, 4)
                    // ⌘T 走 uTermApp 的 CommandGroup 单独注册 —— 按在终端焦点
                    // 区时也能正确触发（Fix #10）；这里只是 UI 按钮入口。
                }
                .frame(maxHeight: .infinity)
                .accessibilityElement(children: .contain)
            }
            .frame(maxHeight: .infinity)
        }
        .frame(height: 36)
        // 与上方预览区/状态条统一为 UD.bg —— 避免在分隔条两侧出现深浅不一的色块。
        .background(UD.bg)
        .overlay(alignment: .bottom) {
            Rectangle().fill(UD.border).frame(height: 1)
        }
    }

    /// 聚焦窗格会话的连接状态色；无会话时 nil（UDTermTab 回退到激活/非激活默认点色）。
    private static func dotColor(for tab: TabModel) -> Color? {
        guard let session = tab.focusedPane?.session else { return nil }
        return ConnectionStatusDisplay(state: session.connectionState).tint.color
    }
}

private struct TabReorderDropDelegate: DropDelegate {
    let workspace: WorkspaceModel
    let targetTabID: UUID

    func validateDrop(info: DropInfo) -> Bool {
        info.hasItemsConforming(to: [.utermTabID])
    }

    func dropUpdated(info: DropInfo) -> DropProposal? {
        DropProposal(operation: .move)
    }

    func performDrop(info: DropInfo) -> Bool {
        guard let provider = info.itemProviders(for: [.utermTabID]).first,
              let toIndex = workspace.tabs.firstIndex(where: { $0.id == targetTabID })
        else {
            return false
        }

        TabDragPayload.load(from: provider) { draggedTabID in
            guard let draggedTabID else { return }
            Task { @MainActor in
                workspace.moveTab(fromID: draggedTabID, toIndex: toIndex)
            }
        }
        return true
    }
}
