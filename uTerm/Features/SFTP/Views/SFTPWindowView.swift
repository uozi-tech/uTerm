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
    private var activeModel: FileBrowserModel? {
        (tabs.first { $0.id == effectiveActiveID } ?? tabs.first)?.model
    }

    var body: some View {
        content
            .frame(minWidth: 900, minHeight: 560)
            .onDisappear { disposeAll() }
    }

    @ViewBuilder
    private var content: some View {
        if windowID != nil, let server {
            sftpBody(server: server)
        } else {
            placeholder(windowID == nil ? "正在恢复…" : "服务器已删除",
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
                         state: activeModel?.state ?? .idle,
                         onDisconnect: { disposeAll(); dismiss() })
            SFTPTabBar(
                tabs: tabs, activeID: effectiveActiveID, serverHost: server.host,
                onSelect: { activeTabID = $0 },
                onClose: { closeTab($0) },
                onNew: newTab)
            // 全部标签同时挂载、按激活态显隐 —— 各浏览器保留自己的导航 / 选中 / 检视器宽度
            // @State；切换标签不重建 model（对齐设计稿「全部挂载 + 显隐」实现）。
            ZStack {
                ForEach(tabs) { tab in
                    SFTPBrowserContainer(
                        tab: tab, server: server,
                        openWorkspace: { openWorkspace(for: server) })
                        .opacity(tab.id == effectiveActiveID ? 1 : 0)
                        .allowsHitTesting(tab.id == effectiveActiveID)
                        .zIndex(tab.id == effectiveActiveID ? 1 : 0)
                }
            }
        }
        .ignoresSafeArea(.container, edges: .top)
        .background(UD.bg)
        .background(WorkspaceWindowChrome(serverName: ServerChromeTitle.sftpWindowTitle(
            serverName: server.name,
            groupName: server.group)))
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
        if tabs.count <= 1 { disposeAll(); dismiss(); return }
        let wasActive = (effectiveActiveID == id)
        tabs[idx].model.dispose()
        tabs.remove(at: idx)
        if wasActive {
            activeTabID = (tabs.indices.contains(idx) ? tabs[idx] : tabs[tabs.count - 1]).id
        }
    }

    private func disposeAll() {
        for tab in tabs { tab.model.dispose() }
    }
}

// MARK: - 标签数据 / 容器

/// 一个 SFTP 标签：持有该标签独立的 `FileBrowserModel`（引用类型，跨重渲染存活）。
struct SFTPBrowserTab: Identifiable {
    let id = UUID()
    let model = FileBrowserModel()
}

/// 单个标签的浏览器容器：挂 host-key sheet + 按 tab.id 自启连接。所有标签同时挂载，
/// 各标签的连接随其创建建立、随窗口关闭统一释放。
private struct SFTPBrowserContainer: View {
    let tab: SFTPBrowserTab
    let server: ServerProfile
    let openWorkspace: () -> Void
    @Environment(\.modelContext) private var modelContext

    var body: some View {
        SFTPBrowserView(model: tab.model, server: server, openWorkspace: openWorkspace)
            .hostKeySheet(tab.model.hostKeyRelay)
            .task(id: tab.id) {
                await tab.model.connect(profile: server, modelContainer: modelContext.container)
            }
    }
}

// MARK: - 标签栏

/// SFTP 多标签栏（高 36，与终端窗口同款 DesignKit tab）：文件夹图标 + 当前目录名 +
/// 关闭按钮 + 末尾「+」。激活标签底色 = 浏览器正文 `UD.bg`，与下方内容无缝相连；
/// **无左 padding**（首个激活标签贴窗口左缘，避免 L 形缺口 —— 原型踩过的坑）。
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
                HStack(spacing: 0) {
                    ForEach(Array(tabs.enumerated()), id: \.element.id) { index, tab in
                        UDPreviewTab(
                            name: title(for: tab),
                            active: tab.id == activeID,
                            first: index == 0,
                            systemImage: "folder",
                            activeBackground: UD.bg,
                            onSelect: { onSelect(tab.id) },
                            onClose: { onClose(tab.id) })
                            .frame(maxHeight: .infinity)
                            .accessibilityElement(children: .combine)
                            .accessibilityLabel(Text(title(for: tab)))
                            .accessibilityAddTraits(
                                tab.id == activeID ? [.isButton, .isSelected] : .isButton)
                    }
                    Button(action: onNew) {
                        Image(systemName: "plus")
                            .frame(width: 24, height: 24)
                    }
                    .buttonStyle(.plain)
                    .iconButtonHover()
                    .help("新建 SFTP 标签")
                    .accessibilityLabel(Text("新建 SFTP 标签"))
                    .padding(.leading, 4)
                }
                .frame(maxHeight: .infinity)
                .accessibilityElement(children: .contain)
            }
            .frame(maxHeight: .infinity)
        }
        .frame(height: 36)
        .background(UD.panel)
        .overlay(alignment: .bottom) {
            Rectangle().fill(UD.border).frame(height: 1)
        }
    }

    /// 标签名 = 当前目录 basename；根目录 "/" 回退主机名以便区分各标签。
    private func title(for tab: SFTPBrowserTab) -> String {
        let last = tab.model.currentPath.split(separator: "/").last
        return last.map(String.init) ?? serverHost
    }
}

// MARK: - 标题栏

/// 自绘 SFTP 标题栏（替代系统 toolbar）——对齐设计稿：左侧让位窗口红绿灯，居中
/// 文件夹图标 + `SFTP` + `user@host`(mono) + 连接状态胶囊，右侧断开按钮。40px 扁平
/// UD.panel 条 + 底部 1px 描边。彻底脱离系统 Liquid Glass。
struct SFTPTitleBar: View {
    let server: ServerProfile
    let serverTitle: String
    let state: FileBrowserModel.State
    let onDisconnect: () -> Void

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
                    .help(serverTitle)
                Text("\(server.username)@\(server.host)")
                    .font(UD.mono(12))
                    .foregroundStyle(UD.text3)
                SFTPStatusPill(state: state)
            }

            // 两侧：左让位红绿灯（~68px），右断开按钮。
            HStack(spacing: 2) {
                Color.clear.frame(width: 68)
                Spacer()
                WSIconButton(systemName: "power", help: "断开并关闭窗口",
                             action: onDisconnect)
            }
            .padding(.horizontal, 8)
        }
        .frame(height: 38)
        .frame(maxWidth: .infinity)
        // WindowDragHandle 既画 UD.panel 实色底，又充当窗口拖动手柄（窗口 chrome 已关
        // isMovableByWindowBackground）。其上的按钮 / 红绿灯更靠前，点击不落到手柄。
        .background(WindowDragHandle())
        .overlay(alignment: .bottom) {
            Rectangle().fill(UD.border).frame(height: 1)
        }
    }
}

/// 标题栏连接状态胶囊：圆点（连接时脉冲）+ 文案，外裹细描边 capsule。映射
/// `FileBrowserModel.State`。
struct SFTPStatusPill: View {
    let state: FileBrowserModel.State
    @State private var pulse = false
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    private var info: (text: String, color: Color) {
        switch state {
        case .browsing:          return ("已连接", UD.success)
        case .connecting, .idle: return ("连接中", UD.warning)
        case .failed:            return ("连接失败", UD.danger)
        }
    }

    var body: some View {
        let i = info
        return HStack(spacing: 6) {
            ZStack {
                if case .browsing = state, !reduceMotion {
                    Circle().fill(i.color).frame(width: 9, height: 9)
                        .opacity(pulse ? 0.0 : 0.35)
                        .scaleEffect(pulse ? 1.8 : 1)
                }
                Circle().fill(i.color).frame(width: 7, height: 7)
            }
            Text(i.text)
                .font(.system(size: 11))
                .foregroundStyle(UD.text2)
        }
        .padding(.leading, 7).padding(.trailing, 8).padding(.vertical, 2)
        .background(Capsule().fill(UD.fillFaint))
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("连接状态")
        .accessibilityValue(i.text)
        // 进入 .browsing 才启动脉冲 —— 首帧通常是 .idle/.connecting，故 onAppear 与
        // onChange 都要试一次（否则连上后圆点静止不动）。
        .onAppear { startPulseIfBrowsing() }
        .onChange(of: state) { _, _ in startPulseIfBrowsing() }
    }

    private func startPulseIfBrowsing() {
        guard case .browsing = state, !pulse, !reduceMotion else { return }
        withAnimation(.easeOut(duration: 1.4).repeatForever(autoreverses: false)) {
            pulse = true
        }
    }
}
