import SwiftUI
import SwiftData

/// 工作区中央下半部：终端区。
/// 顶部 TerminalTabBar + 当前活动 tab 的 TabContentView。无活动 tab 时
/// 渲染「新建终端标签」入口。
struct TerminalArea: View {
    let workspace: WorkspaceModel
    let server: ServerProfile

    @Environment(\.colorScheme) private var appColorScheme

    private var terminalAreaBG: Color {
        Color(nsColor: TerminalColorScheme.resolve(dark: appColorScheme == .dark).backgroundColor)
    }

    var body: some View {
        VStack(spacing: 0) {
            TerminalTabBar(workspace: workspace) {
                workspace.openServer(profileID: server.id, title: server.name)
            }
            if let activeTab = workspace.activeTab {
                TabContentView(tab: activeTab, onCloseTab: {
                    workspace.closeTab(activeTab.id)
                }, onDropTab: { sourceTab, targetPane, zone in
                    workspace.dropTab(sourceTab, onto: targetPane, zone: zone)
                }, onDropFile: { sourceBuffer, targetPane, zone in
                    workspace.dropFileBuffer(sourceBuffer, onto: targetPane, zone: zone)
                }, onDownloadFile: { buffer in
                    try await workspace.filePreviewModel.download(buffer)
                }, onLoadMarkdownImage: { source, buffer in
                    try await workspace.filePreviewModel.loadMarkdownImage(
                        source: source,
                        referencedBy: buffer)
                }, workspaceDragSource: workspace.dragSource, onBeginPaneDrag: { sourcePane in
                    workspace.beginDrag(.pane(sourcePane))
                }, onDropDragSource: { targetPane, zone in
                    workspace.dropDragSource(onto: targetPane, zone: zone)
                })
                    .background(terminalAreaBG)
            } else {
                emptyState
            }
        }
    }

    private var emptyState: some View {
        VStack(spacing: 8) {
            Image(systemName: "terminal")
                .font(.system(size: 28, weight: .light))
                .foregroundStyle(UD.text3)
            Text("没有打开的终端标签")
                .font(.callout)
                .foregroundStyle(UD.text2)
            UDButton(title: "新建终端标签", systemImage: "plus") {
                workspace.openServer(profileID: server.id, title: server.name)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(terminalAreaBG)
    }
}
