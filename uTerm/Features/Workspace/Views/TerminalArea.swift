import UDesignKit
import UPaneGroups
import UPaneTree
import SwiftUI
import SwiftData
import UniformTypeIdentifiers

/// 工作区中央下半部：终端区 = 共享组件 `UPaneGroupArea` 的 uTerm 装配层。
///
/// **模型是「分屏里装标签」（VSCode 编辑组）**：全窗口一棵分屏树，叶子是组，
/// 每个组一条标签条 + 一个前台终端。旧的「标签里装分屏」（`TerminalTabBar` +
/// `TabContentView` + `PaneView` 的 22px 窗格头）整套删除。
///
/// 分屏树摊平定位、按 `tab.id` 定身份的面板保活、按下即激活的 NSEvent 探针、
/// 五区拖放与投放高亮、活动态三档、活动组焦点框，全部在组件里（uAppKit
/// `UPaneGroups`）。
struct TerminalArea: View {
    let workspace: WorkspaceModel
    let server: ServerProfile

    @Environment(\.colorScheme) private var appColorScheme
    @Query private var profiles: [ServerProfile]

    private var terminalAreaBG: Color {
        Color(nsColor: TerminalColorScheme.resolve(dark: appColorScheme == .dark).backgroundColor)
    }

    var body: some View {
        // **服务器配置在区域这一层解析一次、捕获进闭包。** 让每个面板自己在 body 里
        // 扫 `@Query` 数组，就等于把所有面板挂到那个数组上——开 / 关任意一个标签都
        // 要付全体重算（设计文档 §3.1）。
        let profilesByID = Dictionary(profiles.map { ($0.id, $0) },
                                      uniquingKeysWith: { first, _ in first })
        let profileCount = profiles.count
        let background = terminalAreaBG
        UPaneGroupArea(
            model: workspace.terminalGroups,
            // 拖拽类型必须由 app 传：`UTType(exportedAs:)` 要在自家 Info.plist 的
            // `UTExportedTypeDeclarations` 里登记，包替 app 声明不了。
            dragType: .utermTabID,
            // 36pt：与旧终端标签条、上方预览区状态条对齐。
            stripHeight: 36,
            showsSplitButton: true,
            // 不画活动组焦点框：焦点已经由标签条表达 —— 全工作区只有一条 accent 顶条，
            // 就在当前标签上。再套一圈蓝框是同一件事说两遍，而且框住整格比一条顶条抢眼
            // 得多。uTable 一直是这样，两边就此一致。
            showsActiveGroupRing: false,
            // 旧 pane header 的分屏按钮按窗格长宽比自动选方向（`autoSplitDirection`）。
            splitButtonDirection: .automatic,
            splitButtonIcon: .system("rectangle.split.2x1"),
            descriptor: { tab in Self.descriptor(for: tab, profiles: profilesByID) },
            content: { tab, _ in
                PaneView(pane: tab.payload,
                         profile: profilesByID[tab.payload.serverProfileID],
                         profileCount: profileCount,
                         background: background,
                         onDownloadFile: { buffer, localURL in
                             try await workspace.filePreviewModel.download(buffer, to: localURL)
                         },
                         onLoadMarkdownImage: { source, buffer in
                             try await workspace.filePreviewModel.loadMarkdownImage(
                                 source: source, referencedBy: buffer)
                         })
            },
            emptyGroup: { _ in emptyState },
            onRequestClose: { tab in
                // 组件只发「请求关闭」，真关由 app 做。终端标签没有脏文件确认这类
                // 前置流程，定位到就直接关；会话的释放走模型的 `onTabRemoved`。
                guard let at = workspace.terminalGroups.locateTab(tab.id) else { return }
                workspace.terminalGroups.closeTab(groupID: at.groupID, index: at.index)
            },
            stripAccessory: { groupID in newTabButton(groupID) },
            // 预览标签拖进终端组 —— 组件不认识的载荷转给 app。
            foreignDropTypes: [.utermFileBufferID],
            onForeignDrop: { providers, groupID, zone in
                workspace.dropForeignPayload(providers, ontoGroup: groupID, zone: zone)
            })
        .background(background)
        // 区域空掉 / 分屏按钮开在空组上时，新会话连本窗口绑定的这台服务器。
        .task(id: server.id) { workspace.bindDefaultServer(id: server.id, title: server.name) }
    }

    /// 一枚 chip 怎么画。**在每个 chip 自己的 body 里求值**（组件保证），所以
    /// `session.connectionState` 这个 `@Observable` 属性只让它自己那一枚 chip 失效，
    /// 不牵动整条标签条。
    ///
    /// 连接状态点的语义比旧版更准：旧 `TerminalTabBar` 取的是
    /// `tab.focusedPane?.session`，一个标签里四个窗格连四台机器时点只反映聚焦那个；
    /// 现在每枚 chip 用**它自己**那条会话。
    private static func descriptor(for tab: TerminalTab,
                                   profiles: [UUID: ServerProfile]) -> UPaneTabDescriptor {
        let pane = tab.payload
        if let buffer = pane.fileBuffer {
            return UPaneTabDescriptor(title: buffer.displayName,
                                      icon: .system("doc.text"),
                                      isDirty: buffer.isDirty)
        }
        let name = profiles[pane.serverProfileID]?.name ?? "终端"
        let display = ConnectionStatusDisplay(state: pane.session.connectionState)
        return UPaneTabDescriptor(title: name,
                                  icon: .system("terminal"),
                                  leadingDot: display.tint.color,
                                  help: "\(name) · \(display.label)")
    }

    /// 标签条右侧的「＋新建终端」。⌘T 走 `uTermApp` 的 CommandGroup 单独注册
    /// （按在终端焦点区时也能触发），这里只是 UI 入口。
    private func newTabButton(_ groupID: UUID) -> some View {
        Button {
            workspace.openServer(profileID: server.id, title: server.name, in: groupID)
        } label: {
            // 图标色不在这里设——交给 iconButtonHover 随 hover 切换。
            Image(systemName: "plus")
                .frame(width: 28, height: 36)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .iconButtonHover()
        .help("新建终端标签（⌘T）")
        .accessibilityLabel(Text("新建终端标签"))
    }

    /// 空组占位。整棵树只剩一个组且它空掉时，这就是终端区的空态。
    ///
    /// 空间不够时逐级退化（图标 → 文案），按钮留到最后；`minHeight: 0` 让它肯被压扁，
    /// 否则组外壳装不下会整体居中溢出、把标签条顶出终端区上沿（同 `EmptyBody`）。
    private var emptyState: some View {
        ViewThatFits(in: .vertical) {
            emptyStateStack(showsIcon: true, showsText: true)
            emptyStateStack(showsIcon: false, showsText: true)
            emptyStateStack(showsIcon: false, showsText: false)
            Color.clear.frame(height: 0)
        }
        .frame(maxWidth: .infinity, minHeight: 0, maxHeight: .infinity)
        .clipped()
        .background(terminalAreaBG)
    }

    private func emptyStateStack(showsIcon: Bool, showsText: Bool) -> some View {
        VStack(spacing: 8) {
            if showsIcon {
                Image(systemName: "terminal")
                    .font(.system(size: 28, weight: .light))
                    .foregroundStyle(UD.text3)
            }
            if showsText {
                Text("没有打开的终端标签")
                    .font(.callout)
                    .foregroundStyle(UD.text2)
            }
            UDButton(title: "新建终端标签", systemImage: "plus") {
                workspace.openServer(profileID: server.id, title: server.name)
            }
        }
    }
}
