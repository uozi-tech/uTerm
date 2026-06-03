import SwiftUI
import SwiftData

/// 一个 SFTP 独立窗口：绑定单台服务器（由 `SFTPWindowID` 指定）。纯文件浏览，
/// 无终端 / 无 Agent。复用 `FileBrowserModel` 作为 SFTP 引擎。
///
/// 视觉：完全对齐设计稿 `pages/sftp.jsx` —— 自绘扁平深色窗口（`WorkspaceWindowChrome`
/// 透明标题栏 + full-size content + `.darkAqua` + 去玻璃），WS 暗色调色板，**不出现
/// 任何系统 Liquid Glass**。标题栏自绘（红绿灯让位 + 居中 SFTP·user@host + 状态胶囊）。
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
        Group {
            if windowID != nil {
                if let server {
                    VStack(spacing: 0) {
                        SFTPTitleBar(server: server, state: model.state,
                                     onDisconnect: { model.dispose(); dismiss() })
                        SFTPBrowserView(model: model, server: server,
                                        openWorkspace: { openWorkspace(for: server) })
                    }
                    .hostKeySheet(model.hostKeyRelay)
                    .task(id: windowID) {
                        await model.connect(profile: server, modelContainer: modelContext.container)
                    }
                } else {
                    placeholder("服务器已删除", systemImage: "server.rack")
                }
            } else {
                placeholder("正在恢复…", systemImage: "clock")
            }
        }
        // 让内容延伸到标题栏区域之下（配合 WorkspaceWindowChrome 的 fullSizeContentView）。
        .ignoresSafeArea(.container, edges: .top)
        .background(WS.bg)
        // 自绘窗口 chrome：透明标题栏 + full-size content + 不透明 WS 底 + 深色外观。
        // 无系统 toolbar / NavigationSplitView ⇒ 不存在系统玻璃。
        .background(WorkspaceWindowChrome(serverName: server.map { "SFTP — \($0.name)" } ?? "SFTP"))
        .environment(\.colorScheme, .dark)
        .frame(minWidth: 900, minHeight: 560)
        .onDisappear { model.dispose() }
    }

    private func placeholder(_ title: String, systemImage: String) -> some View {
        VStack(spacing: 12) {
            Image(systemName: systemImage)
                .font(.system(size: 30)).foregroundStyle(WS.text3)
            Text(title).font(.system(size: 14)).foregroundStyle(WS.text2)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private func openWorkspace(for server: ServerProfile) {
        openWindow(value: WorkspaceWindowID(id: UUID(), serverID: server.id))
    }
}

// MARK: - 标题栏

/// 自绘 SFTP 标题栏（替代系统 toolbar）——对齐设计稿：左侧让位窗口红绿灯，居中
/// 文件夹图标 + `SFTP` + `user@host`(mono) + 连接状态胶囊，右侧断开按钮。40px 扁平
/// WS.panel 条 + 底部 1px 描边。彻底脱离系统 Liquid Glass。
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
                    .foregroundStyle(WS.accent)
                Text("SFTP")
                    .font(.system(size: 13, weight: .medium))
                    .foregroundStyle(WS.text)
                Text("\(server.username)@\(server.host)")
                    .font(WS.mono(12))
                    .foregroundStyle(WS.text3)
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
        .frame(height: 40)
        .frame(maxWidth: .infinity)
        // WindowDragHandle 既画 WS.panel 实色底，又充当窗口拖动手柄（窗口 chrome 已关
        // isMovableByWindowBackground）。其上的按钮 / 红绿灯更靠前，点击不落到手柄。
        .background(WindowDragHandle())
        .overlay(alignment: .bottom) {
            Rectangle().fill(WS.border).frame(height: 1)
        }
    }
}

/// 标题栏连接状态胶囊：圆点（连接时脉冲）+ 文案，外裹细描边 capsule。映射
/// `FileBrowserModel.State`。
struct SFTPStatusPill: View {
    let state: FileBrowserModel.State
    @State private var pulse = false

    private var info: (text: String, color: Color) {
        switch state {
        case .browsing:          return ("已连接", WS.connected)
        case .connecting, .idle: return ("连接中", WS.connecting)
        case .failed:            return ("连接失败", WS.failed)
        }
    }

    var body: some View {
        let i = info
        return HStack(spacing: 6) {
            ZStack {
                if case .browsing = state {
                    Circle().fill(i.color).frame(width: 9, height: 9)
                        .opacity(pulse ? 0.0 : 0.35)
                        .scaleEffect(pulse ? 1.8 : 1)
                }
                Circle().fill(i.color).frame(width: 7, height: 7)
            }
            Text(i.text)
                .font(.system(size: 11))
                .foregroundStyle(WS.text2)
        }
        .padding(.leading, 7).padding(.trailing, 8).padding(.vertical, 2)
        .background(Capsule().fill(Color.white.opacity(0.04)))
        .overlay(Capsule().strokeBorder(WS.border, lineWidth: 1))
        // 进入 .browsing 才启动脉冲 —— 首帧通常是 .idle/.connecting，故 onAppear 与
        // onChange 都要试一次（否则连上后圆点静止不动）。
        .onAppear { startPulseIfBrowsing() }
        .onChange(of: state) { _, _ in startPulseIfBrowsing() }
    }

    private func startPulseIfBrowsing() {
        guard case .browsing = state, !pulse else { return }
        withAnimation(.easeOut(duration: 1.4).repeatForever(autoreverses: false)) {
            pulse = true
        }
    }
}
