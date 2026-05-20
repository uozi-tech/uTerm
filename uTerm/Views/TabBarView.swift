import SwiftUI
import UniformTypeIdentifiers

/// 顶部标签条：显示所有标签、可选中/关闭、可拖拽重排，末尾 ＋ 新建。
struct TabBarView: View {
    let workspace: WorkspaceModel
    /// 点 ＋ 选择窗格种类时触发（上层据此新建对应标签）。
    let onNewTab: (PaneKindTag) -> Void

    var body: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 4) {
                ForEach(workspace.tabs) { tab in
                    tabChip(tab)
                        .draggable(TabDragItem(tabID: tab.id)) {
                            tabLabel(tab).padding(6)
                        }
                        .dropDestination(for: TabDragItem.self) { items, _ in
                            guard let dragged = items.first,
                                  let toIndex = workspace.tabs.firstIndex(where: { $0.id == tab.id })
                            else { return false }
                            workspace.moveTab(fromID: dragged.tabID, toIndex: toIndex)
                            return true
                        }
                }
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
            .padding(.horizontal, 6)
            .padding(.vertical, 4)
        }
        .frame(height: 32)
        .background(.bar)
    }

    @ViewBuilder
    private func tabChip(_ tab: TabModel) -> some View {
        let isActive = workspace.activeTabID == tab.id
        HStack(spacing: 6) {
            tabLabel(tab)
            Button {
                workspace.closeTab(tab.id)
            } label: {
                Image(systemName: "xmark").font(.system(size: 9))
            }
            .buttonStyle(.plain)
        }
        .padding(.horizontal, 10).padding(.vertical, 4)
        .background(isActive ? Color.accentColor.opacity(0.2) : Color.clear)
        .clipShape(RoundedRectangle(cornerRadius: 6))
        .contentShape(Rectangle())
        .onTapGesture { workspace.selectTab(tab.id) }
    }

    private func tabLabel(_ tab: TabModel) -> some View {
        Text(tab.title).font(.callout).lineLimit(1)
    }
}

/// 标签拖拽的传输载荷。
struct TabDragItem: Codable, Transferable, Sendable {
    let tabID: UUID
    static var transferRepresentation: some TransferRepresentation {
        CodableRepresentation(contentType: .data)
    }
}
