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
    @State private var model = FileBrowserModel()

    private var server: ServerProfile? {
        guard let id = windowID?.serverID else { return nil }
        return profiles.first { $0.id == id }
    }

    var body: some View {
        content
            .frame(minWidth: 900, minHeight: 560)
            .onDisappear { model.dispose() }
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
        VStack(spacing: 0) {
            SFTPTitleBar(server: server, state: model.state,
                         onDisconnect: { model.dispose(); dismiss() })
            SFTPBrowserView(model: model, server: server,
                            openWorkspace: { openWorkspace(for: server) })
        }
        .ignoresSafeArea(.container, edges: .top)
        .background(UD.bg)
        .background(WorkspaceWindowChrome(serverName: "SFTP — \(server.name)"))
        .hostKeySheet(model.hostKeyRelay)
        .task(id: windowID) {
            await model.connect(profile: server, modelContainer: modelContext.container)
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

    private func openWorkspace(for server: ServerProfile) {
        openWindow(value: WorkspaceWindowID(serverID: server.id))
    }
}

// MARK: - 标题栏

/// 自绘 SFTP 标题栏（替代系统 toolbar）——对齐设计稿：左侧让位窗口红绿灯，居中
/// 文件夹图标 + `SFTP` + `user@host`(mono) + 连接状态胶囊，右侧断开按钮。40px 扁平
/// UD.panel 条 + 底部 1px 描边。彻底脱离系统 Liquid Glass。
struct SFTPTitleBar: View {
    let server: ServerProfile
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
        .overlay(Capsule().strokeBorder(UD.border, lineWidth: 1))
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
