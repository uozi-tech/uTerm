import UDesignKit
import SwiftUI
import SwiftData

/// 一个 SFTP 独立窗口：绑定单台服务器（由 `SFTPWindowID` 指定）。纯文件浏览，
/// 无终端 / 无 Agent。复用 `FileBrowserModel` 作为 SFTP 引擎。
///
/// 视觉：完全对齐设计稿 `pages/sftp.jsx` —— 自绘扁平窗口，外观随主题（`WorkspaceWindowChrome`
/// 透明标题栏 + full-size content + 去玻璃），**不出现任何系统 Liquid Glass**。
/// 标题栏自绘（红绿灯让位 + 居中 SFTP·user@host + 状态胶囊）。
struct SFTPWindowView: View {
    let windowID: SFTPWindowID?

    @Query private var profiles: [ServerProfile]
    @Environment(\.openWindow) private var openWindow
    @Environment(\.dismiss) private var dismiss
    @Environment(\.modelContext) private var modelContext
    /// 该窗口的所有 SFTP 标签 —— 每个标签 = 一个独立 `FileBrowserModel`（独立路径历史 /
    /// 选中 / 排序 / 检视器宽度）。全部挂载、按激活态显隐以保留各自状态（对齐设计稿
    /// `pages/sftp.jsx`）。同一窗口的标签共用一台服务器（由 `SFTPWindowID` 指定）。
    @State private var tabs: [SFTPBrowserTab] = [SFTPBrowserTab()]
    @State private var activeTabID: UUID?

    private var server: ServerProfile? {
        guard let id = windowID?.serverID else { return nil }
        return profiles.first { $0.id == id }
    }

    /// 实际激活标签 id（activeTabID 未显式设过时回退到首个标签）。
    private var effectiveActiveID: UUID? { activeTabID ?? tabs.first?.id }
    /// 激活标签的 model —— 供标题栏状态胶囊读取当前连接状态。
    private var activeModel: FileBrowserModel? { activeTab?.model }
    private var activeTab: SFTPBrowserTab? {
        tabs.first { $0.id == effectiveActiveID } ?? tabs.first
    }

    var body: some View {
        content
            .frame(minWidth: 900, minHeight: 560)
            // 不要开屏自动聚焦路径栏的搜索框：连接中窗口里只有这一个文本框，macOS 会在窗口
            // 成为 key 时把焦点自动交给它（实机反馈「连接中搜索框自动 focus」）。
            .disablesInitialAutoFocus()
            .onDisappear { disposeAll() }
    }

    @ViewBuilder
    private var content: some View {
        if windowID != nil, let server {
            sftpBody(server: server)
        } else {
            placeholder(windowID == nil ? "正在恢复…" : "主机已删除",
                        systemImage: windowID == nil ? "clock" : "server.rack")
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .ignoresSafeArea(.container, edges: .top)
                .background(UD.bg)
                .background(WorkspaceWindowChrome(serverName: "SFTP"))
        }
    }

    /// 主体：自绘标题栏 + 浏览器。窗口 chrome / 去顶部安全区 / 深色 / 连接钩子都挂在
    /// 这个**稳定的 VStack** 上（而非外层 Group）—— 否则 `.ignoresSafeArea(.top)` 不能
    /// 把自绘标题栏顶进系统标题栏区，macOS 会继续在上面画自带（Liquid Glass）标题栏，
    /// 把自绘 header 整条盖住（即之前「header 被遮挡」的根因）。与 WorkspaceWindowView
    /// 的结构保持一致。
    @ViewBuilder
    private func sftpBody(server: ServerProfile) -> some View {
        let chromeTitle = ServerChromeTitle.serverTitle(serverName: server.name, groupName: server.group)
        VStack(spacing: 0) {
            SFTPTitleBar(server: server, serverTitle: chromeTitle,
                         state: activeModel?.state ?? .idle)
            SFTPTabBar(
                tabs: tabs, activeID: effectiveActiveID, serverHost: server.host,
                onSelect: { activeTabID = $0 },
                onClose: { closeTab($0) },
                onNew: newTab)
            // 全部标签同时挂载、按激活态显隐 —— 各浏览器保留自己的导航 / 选中 / 检视器宽度
            // @State；切换标签不重建 model（对齐设计稿「全部挂载 + 显隐」实现）。
            // 分区方案 v3：浏览器整体是一张内容卡（距窗口左右 / 下 8pt），标签条在画布上。
            // 同一时刻只露一个标签，卡外框套在 ZStack 上一份即可。
            ZStack {
                ForEach(tabs) { tab in
                    SFTPBrowserContainer(
                        tab: tab, server: server,
                        openWorkspace: { openWorkspace(for: server) },
                        openTerminal: { openTerminal(for: server) })
                        .opacity(tab.id == effectiveActiveID ? 1 : 0)
                        .allowsHitTesting(tab.id == effectiveActiveID)
                        .zIndex(tab.id == effectiveActiveID ? 1 : 0)
                }
            }
            .udCard()
            .padding(.horizontal, UD.Layout.cardInset)
            .padding(.bottom, UD.Layout.cardInset)
        }
        .ignoresSafeArea(.container, edges: .top)
        .background(UD.pageBg)
        // 「打开」的 toast / 同步芯片跟着活动标签；关窗时检查所有标签没上传的改动。
        .modifier(OptionalExternalOpenBinding(tab: activeTab, allTabs: tabs))
        .background(WorkspaceWindowChrome(
            serverName: ServerChromeTitle.sftpWindowTitle(serverName: server.name,
                                                         groupName: server.group),
            background: WS.canvasNSColor))
    }

    private func placeholder(_ title: String, systemImage: String) -> some View {
        VStack(spacing: 12) {
            Image(systemName: systemImage)
                .font(.system(size: 30)).foregroundStyle(UD.text3)
            Text(title).font(.system(size: 14)).foregroundStyle(UD.text2)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private func openWorkspace(for server: ServerProfile) {
        openWindow(value: WorkspaceWindowID(serverID: server.id))
    }

    /// 终端窗口（只有终端 ⇄ Agent，无 SFTP 侧栏 / 预览）：有终端窗口就作为新标签送进去，
    /// 没有才新开一个。
    private func openTerminal(for server: ServerProfile) {
        if TerminalWindowRouter.shared.openInExistingWindow(serverID: server.id) { return }
        openWindow(value: TerminalWindowID(id: UUID(), serverID: server.id))
    }

    // MARK: - 标签管理

    /// 新建标签 —— 追加一个独立 `FileBrowserModel` 并激活。连接 / host-key sheet 由
    /// `SFTPBrowserContainer` 挂载时按 tab.id 自启。
    private func newTab() {
        let tab = SFTPBrowserTab()
        tabs.append(tab)
        activeTabID = tab.id
    }

    /// 关闭标签：释放其 model，激活相邻标签。关闭最后一个标签 = 关窗（不留空窗口）。
    private func closeTab(_ id: UUID) {
        guard let idx = tabs.firstIndex(where: { $0.id == id }) else { return }
        if tabs.count <= 1 { closeWindow(); return }
        ExternalEditCloseGuard.confirmThenClose([tabs[idx].externalOpen]) {
            removeTab(id)
        }
    }

    private func removeTab(_ id: UUID) {
        guard let idx = tabs.firstIndex(where: { $0.id == id }) else { return }
        let wasActive = (effectiveActiveID == id)
        tabs[idx].externalOpen.dispose()
        tabs[idx].model.dispose()
        tabs.remove(at: idx)
        if wasActive {
            activeTabID = (tabs.indices.contains(idx) ? tabs[idx] : tabs[tabs.count - 1]).id
        }
    }

    /// 关最后一个标签：不走 `windowShouldClose`，自己先问一遍
    /// 没上传的外部编辑改动。
    private func closeWindow() {
        ExternalEditCloseGuard.confirmThenClose(tabs.map(\.externalOpen)) {
            disposeAll()
            dismiss()
        }
    }

    private func disposeAll() {
        for tab in tabs {
            tab.externalOpen.dispose()
            tab.model.dispose()
        }
    }
}

// MARK: - 标签数据 / 容器

/// 一个 SFTP 标签：持有该标签独立的 `FileBrowserModel`（引用类型，跨重渲染存活）。
struct SFTPBrowserTab: Identifiable {
    let id = UUID()
    let model: FileBrowserModel
    /// 本标签的「打开」（下载到本地交外部应用、保存自动回传；数据库交 uTable）。
    let externalOpen: ExternalOpenCoordinator

    init() {
        let model = FileBrowserModel()
        self.model = model
        self.externalOpen = ExternalOpenCoordinator(
            provider: { [weak model] in model?.sftpProvider },
            host: { [weak model] in model?.connectedHost })
    }
}

/// 活动标签还没定下来（理论上不会，标签至少一个）时不挂。
private struct OptionalExternalOpenBinding: ViewModifier {
    let tab: SFTPBrowserTab?
    let allTabs: [SFTPBrowserTab]

    func body(content: Content) -> some View {
        if let tab {
            content.modifier(ExternalOpenWindowBinding(
                coordinator: tab.externalOpen,
                fileBrowserModel: tab.model,
                allCoordinators: { allTabs.map(\.externalOpen) }))
        } else {
            content
        }
    }
}

/// 单个标签的浏览器容器：挂 host-key sheet + 按 tab.id 自启连接。所有标签同时挂载，
/// 各标签的连接随其创建建立、随窗口关闭统一释放。
private struct SFTPBrowserContainer: View {
    let tab: SFTPBrowserTab
    let server: ServerProfile
    let openWorkspace: () -> Void
    let openTerminal: () -> Void
    @Environment(\.modelContext) private var modelContext

    var body: some View {
        SFTPBrowserView(model: tab.model, externalOpen: tab.externalOpen,
                        server: server, openWorkspace: openWorkspace,
                        openTerminal: openTerminal)
            .hostKeySheet(tab.model.hostKeyRelay)
            .task(id: tab.id) {
                await tab.model.connect(profile: server, modelContainer: modelContext.container)
            }
    }
}

// MARK: - 标签栏

/// SFTP 多标签栏（高 36）：文件夹图标 + 当前目录名 + 关闭按钮 + 末尾「+」。
/// 分区方案 v3：标签条坐在窗口画布上（与标题栏同层），激活标签是**浮起的卡色胶囊**
/// （`UD.panel` + 卡片细轮廓，28 高、圆角 7），与下方的浏览器内容卡同色；未激活 text3，
/// 悬停 `panelHover`。去掉底线与 accent 顶条。
/// 标签名取该 model 当前目录 basename（根目录回退主机名），随导航实时更新。
struct SFTPTabBar: View {
    let tabs: [SFTPBrowserTab]
    let activeID: UUID?
    let serverHost: String
    let onSelect: (UUID) -> Void
    let onClose: (UUID) -> Void
    let onNew: () -> Void

    var body: some View {
        HStack(spacing: 0) {
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 2) {
                    ForEach(tabs) { tab in
                        WSCanvasTab(
                            name: title(for: tab),
                            active: tab.id == activeID,
                            onSelect: { onSelect(tab.id) },
                            onClose: { onClose(tab.id) }
                        ) { active in
                            Image(systemName: "folder")
                                .font(.system(size: 11))
                                .foregroundStyle(active ? UD.accent : UD.text4)
                        }
                    }
                    Button(action: onNew) {
                        Image(systemName: "plus")
                            .frame(width: 26, height: 26)
                    }
                    .buttonStyle(.udPlain)
                    .iconButtonHover(cornerRadius: 6)
                    .help("新建 SFTP 标签页")
                    .accessibilityLabel(Text("新建 SFTP 标签页"))
                    .padding(.leading, 4)
                }
                // 胶囊比卡片轮廓 / 投影多出 1–2pt，留出来别被 ScrollView 裁掉。
                .padding(.vertical, 2)
                .padding(.horizontal, 8)
                .accessibilityElement(children: .contain)
            }
        }
        // 36 高、底部多留 4pt（设计稿 padding 0 8 4）：胶囊与下方内容卡之间有呼吸。
        .padding(.bottom, 4)
        .frame(height: 36)
    }

    /// 标签名 = 当前目录 basename；根目录 "/" 回退主机名以便区分各标签。
    private func title(for tab: SFTPBrowserTab) -> String {
        let last = tab.model.currentPath.split(separator: "/").last
        return last.map(String.init) ?? serverHost
    }
}

// MARK: - 标题栏

/// 自绘 SFTP 标题栏（替代系统 toolbar）——对齐设计稿：左侧让位窗口红绿灯，居中
/// 文件夹图标 + `SFTP` + `user@host`(mono) + 连接状态胶囊。38px，
/// 分区方案 v3：画在窗口画布上，无底色、无分隔线。彻底脱离系统 Liquid Glass。
struct SFTPTitleBar: View {
    let server: ServerProfile
    let serverTitle: String
    let state: FileBrowserModel.State

    var body: some View {
        ZStack {
            // 居中簇：folder · SFTP · user@host · 状态胶囊
            HStack(spacing: 9) {
                Image(systemName: "folder.fill")
                    .font(.system(size: 12))
                    .foregroundStyle(UD.accent)
                Text("SFTP")
                    .font(.system(size: 13, weight: .medium))
                    .foregroundStyle(UD.text)
                Text(serverTitle)
                    .font(.system(size: 13, weight: .medium))
                    .foregroundStyle(UD.text)
                    .lineLimit(1)
                    .truncationMode(.tail)
                Text("\(server.username)@\(server.host)")
                    .font(UD.mono(12))
                    .foregroundStyle(UD.text3)
                SFTPStatusPill(state: state)
            }
            // 纯展示，不参与命中测试：否则会截走标题栏空白处的双击（缩放）/ 拖动（见 WindowDragHandle）。
            .allowsHitTesting(false)
        }
        .frame(height: 38)
        .frame(maxWidth: .infinity)
        // WindowDragHandle 既画画布色实底，又充当窗口拖动手柄（窗口 chrome 已关
        // isMovableByWindowBackground）。其上的按钮 / 红绿灯更靠前，点击不落到手柄。
        .background(WindowDragHandle(fill: WS.canvasNSColor))
    }
}

/// 标题栏连接状态胶囊：圆点（连接时脉冲）+ 文案，外裹细描边 capsule。映射
/// `FileBrowserModel.State`。
///
/// 脉冲走 CA 驱动的 `PulseDot`，不再用 SwiftUI `.repeatForever` —— 后者会把整个窗口
/// 钉在每帧重绘上（详见 `PulseDot` 的注释）。同时省掉了原来的 `@State pulse` +
/// `onAppear` / `onChange` 启动仪式：`pulse:` 直接由 `state` 推导，连上就动、断开就停。
struct SFTPStatusPill: View {
    let state: FileBrowserModel.State

    private var info: (text: String, color: Color) {
        switch state {
        case .browsing:          return ("已连接", UD.success)
        case .connecting, .idle: return ("连接中", UD.warning)
        case .failed:            return ("连接失败", UD.danger)
        }
    }

    private var isBrowsing: Bool {
        if case .browsing = state { return true }
        return false
    }

    var body: some View {
        let i = info
        return HStack(spacing: 6) {
            PulseDot(
                color: i.color,
                coreSize: 7,
                haloSize: 9,
                // 雷达式：单向扩散到 1.8× 后瞬回，不往复（与原实现一致）。
                scale: 1...1.8,
                peakOpacity: 0.35,
                duration: 1.4,
                autoreverses: false,
                pulse: isBrowsing
            )
            Text(i.text)
                .font(.system(size: 11))
                .foregroundStyle(UD.text2)
        }
        .padding(.leading, 7).padding(.trailing, 8).padding(.vertical, 2)
        .background(Capsule().fill(UD.fillFaint))
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("连接状态")
        .accessibilityValue(i.text)
    }
}
