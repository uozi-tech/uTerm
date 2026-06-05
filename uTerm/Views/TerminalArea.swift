import SwiftUI
import SwiftData

/// 工作区中央下半部：终端区。
/// 顶部 TerminalTabBar + 当前活动 tab 的 TabContentView。无活动 tab 时
/// 渲染「新建终端标签」入口。
struct TerminalArea: View {
    let workspace: WorkspaceModel
    let server: ServerProfile

    @AppStorage("terminalColorScheme") private var terminalSchemeRaw: String = TerminalColorSchemeID.vscodeDark.rawValue
    @Environment(\.colorScheme) private var appColorScheme

    private var terminalAreaBG: Color {
        let id = TerminalColorSchemeID(rawValue: terminalSchemeRaw) ?? .vscodeDark
        return Color(nsColor: TerminalColorScheme.resolve(id, dark: appColorScheme == .dark).backgroundColor)
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
            Button("新建终端标签") {
                workspace.openServer(profileID: server.id, title: server.name)
            }
            .buttonStyle(.borderedProminent)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(terminalAreaBG)
    }
}
