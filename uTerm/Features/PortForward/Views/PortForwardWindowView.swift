import SwiftUI
import SwiftData

/// 一个端口转发独立窗口：绑定单台服务器（由 `PortForwardWindowID` 指定）。
///
/// 视觉对齐设计稿 `pages/port-forwarding.jsx`：自绘扁平窗口，外观随主题
/// （`WorkspaceWindowChrome` 透明标题栏 + full-size content + 去玻璃），不出现
/// 任何系统 Liquid Glass。标题栏自绘（红绿灯让位 + 居中「端口转发 · <主机名>」）。
///
/// 结构镜像 `SFTPWindowView`：`@Query` 取本主机的转发规则、解析 `ServerProfile`，
/// 缺失时显占位；窗口 chrome / 去顶部安全区 / 主题底 / 连接钩子都挂在稳定的
/// `VStack` 上（而非外层 Group）—— 否则 `.ignoresSafeArea(.top)` 无法把自绘标题栏
/// 顶进系统标题栏区，macOS 会继续画系统标题栏盖住自绘 header。
struct PortForwardWindowView: View {
    let windowID: PortForwardWindowID?

    @Query private var profiles: [ServerProfile]
    @Query private var rules: [ForwardingRule]
    @Environment(\.modelContext) private var modelContext
    @Environment(ForwardingCoordinator.self) private var coordinator

    @State private var hostKeyRelay = HostKeyChallengeRelay()

    init(windowID: PortForwardWindowID?) {
        self.windowID = windowID
        // 仅取本主机的规则，按 sortOrder 升序（serverID 外键过滤）。sid 为 nil 时退到
        // 全零哨兵 UUID（不会命中任何真实规则），让 @Query 返回空。`??`/`UUID()` 不能
        // 进 #Predicate 宏（会被当成全局函数），故在宏外先解析成非可选 `sid`。
        let sid = windowID?.serverID ?? UUID(uuid: (0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0))
        _rules = Query(
            filter: #Predicate<ForwardingRule> { rule in
                rule.serverID == sid
            },
            sort: \ForwardingRule.sortOrder,
            order: .forward)
    }

    private var server: ServerProfile? {
        guard let id = windowID?.serverID else { return nil }
        return profiles.first { $0.id == id }
    }

    var body: some View {
        content
            .frame(minWidth: 640, minHeight: 520)
    }

    @ViewBuilder
    private var content: some View {
        if windowID != nil, let server {
            pfBody(server: server)
        } else {
            placeholder(windowID == nil ? "正在恢复…" : "服务器已删除",
                        systemImage: windowID == nil ? "clock" : "server.rack")
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .ignoresSafeArea(.container, edges: .top)
                .background(UD.bg)
                .background(WorkspaceWindowChrome(serverName: "端口转发"))
        }
    }

    @ViewBuilder
    private func pfBody(server: ServerProfile) -> some View {
        VStack(spacing: 0) {
            PortForwardTitleBar(hostName: server.name.isEmpty ? server.host : server.name)
            PortForwardListView(server: server, rules: rules, hostKeyRelay: hostKeyRelay)
        }
        .ignoresSafeArea(.container, edges: .top)
        .background(UD.bg)
        .background(WorkspaceWindowChrome(
            serverName: "端口转发 — \(server.name.isEmpty ? server.host : server.name)"))
        .hostKeySheet(hostKeyRelay)
        .task(id: windowID) {
            // v1 autostart 触发点（spec §6）：打开窗口即建立专用连接并拉起所有
            // autostart==true 的规则。不挂终端连接事件（解耦）。
            coordinator.ensureSession(
                for: server,
                autostart: rules.filter { $0.autostart }.map { $0.snapshot },
                relay: hostKeyRelay,
                modelContainer: modelContext.container)
        }
    }

    private func placeholder(_ title: String, systemImage: String) -> some View {
        VStack(spacing: 12) {
            Image(systemName: systemImage)
                .font(.system(size: 30)).foregroundStyle(UD.text3)
            Text(title).font(.system(size: 14)).foregroundStyle(UD.text2)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

// MARK: - 标题栏

/// 自绘端口转发标题栏（替代系统 toolbar）——对齐设计稿 `pages/port-forwarding.jsx`
/// 标题条：左侧让位窗口红绿灯（~68pt），居中「端口转发」+ `· <主机名>`(mono)。
/// 38pt 扁平 `WindowDragHandle` 实色底 + 底部 1px 描边，彻底脱离系统 Liquid Glass。
struct PortForwardTitleBar: View {
    let hostName: String

    var body: some View {
        ZStack {
            // 居中簇：端口转发 · <主机名>（对齐设计稿 fontSize13/500 + mono12/text3）。
            HStack(spacing: 8) {
                Text("端口转发")
                    .font(.system(size: 13, weight: .medium))
                    .foregroundStyle(UD.text)
                Text("· \(hostName)")
                    .font(UD.mono(12))
                    .foregroundStyle(UD.text3)
            }

            // 左让位窗口红绿灯（标准位 ~x13–68）。
            HStack(spacing: 0) {
                Color.clear.frame(width: 68)
                Spacer()
            }
        }
        .frame(height: 38)
        .frame(maxWidth: .infinity)
        // WindowDragHandle 既画 UD.panel 实色底，又充当窗口拖动手柄。
        .background(WindowDragHandle())
        .overlay(alignment: .bottom) {
            Rectangle().fill(UD.border).frame(height: 1)
        }
    }
}
