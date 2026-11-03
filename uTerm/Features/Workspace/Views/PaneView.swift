import UDesignKit
import SwiftUI
import SwiftData

/// 面板头部小图标按钮的命中区尺寸。终端区的窗格头已随本次改造删除，但预览区
/// （`PreviewArea`）还在用同一套尺寸，故留在这里。
enum PaneHeaderButtonLayout {
    nonisolated static let hitWidth: CGFloat = 28
    nonisolated static let hitHeight: CGFloat = 22
    nonisolated static let iconSize: CGFloat = 11
    nonisolated static let cornerRadius: CGFloat = 5
}

/// 一个终端标签的面板内容：终端窗格按连接状态显示，文件窗格显示文件预览。
///
/// **只剩内容。** 标题 / 关闭 / 分屏 / 拖拽手柄都搬到了组件的标签条上，旧的 22px
/// 窗格头整条消失（设计文档 §4.4(g)）；焦点框、五区落点、按下即激活的 NSEvent
/// 探针也都由 `UPaneGroupArea` 提供 —— 那个探针不能退回 SwiftUI 手势：终端内容是
/// SwiftTerm 的 NSView，自己吃掉 `mouseDown`，而 SwiftUI 在 macOS 上不装
/// `NSGestureRecognizer`，祖先的 `.onTapGesture` 永不触发。
struct PaneView: View {
    let pane: PaneModel
    /// 由 `TerminalArea` 在区域层解析后传下来 —— 面板不自己扫 `@Query` 数组。
    let profile: ServerProfile?
    /// 已载入的 `ServerProfile` 数量。为 0 时不判「配置已删除」（那是终态，
    /// 在 store 打开 / CloudKit 同步的瞬态里判就是假阳性）。
    let profileCount: Int
    /// 终端配色方案的背景色，由区域层算好传下来。
    let background: Color
    /// 文件窗格里的 Markdown 图片加载入口。来源于 Workspace 共享的 FilePreviewModel。
    let onLoadMarkdownImage: MarkdownBufferImageLoader

    @Environment(\.modelContext) private var modelContext

    var body: some View {
        content
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .background(background)
            .task(id: pane.id) { await connect() }
            // `.task(id:)` 只在窗格 id 变化时重跑，服务器列表迟到不会让它重来一遍。
            // 列表到齐后补连一次，避免窗格永远停在「未连接」。
            .onChange(of: profileCount) { _, _ in
                guard pane.fileBuffer == nil,
                      pane.session.connectionState == .idle else { return }
                Task { await connect() }
            }
            .hostKeySheet(pane.hostKeyRelay)
    }

    @ViewBuilder
    private var content: some View {
        if let buffer = pane.fileBuffer {
            PreviewBufferBody(buffer: buffer,
                              onLoadMarkdownImage: onLoadMarkdownImage)
        } else {
            switch pane.session.connectionState {
            case .idle, .connecting:
                VStack(spacing: 10) {
                    UDIndeterminateBar()
                        .frame(width: 140)
                    Text("正在连接…")
                        .font(UD.caption)
                        .foregroundStyle(UD.text3)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            case .connected:
                RemoteControlledTerminal(session: pane.session)
            case .failed(let message):
                stateView(systemImage: "exclamationmark.triangle",
                          title: "连接失败", detail: message, action: "重试")
            case .disconnected:
                stateView(systemImage: "bolt.horizontal.circle",
                          title: "连接已断开", detail: "", action: "重新连接")
            }
        }
    }

    private func connect() async {
        if let profile {
            await pane.connect(profile: profile, modelContainer: modelContext.container)
        } else if profileCount == 0 {
            // ServerProfile 还没被 @Query 载入（store 打开 / CloudKit 同步的瞬态）。
            // 此时判「配置已删除」是假阳性，而且那是个终态：窗格会挂着
            // 「连接失败 / 服务器配置已被删除」再也不重试。留在 .idle，
            // 等上面的 onChange(profileCount) 拿到真数据再决定。
            return
        } else {
            pane.markServerMissing()
        }
    }

    @ViewBuilder
    private func stateView(systemImage: String, title: String,
                           detail: String, action: String) -> some View {
        VStack(spacing: 12) {
            Image(systemName: systemImage).font(.largeTitle).foregroundStyle(UD.text3)
            Text(title).font(.headline).foregroundStyle(UD.text)
            if !detail.isEmpty {
                Text(detail).font(.caption).foregroundStyle(UD.text3)
                    .multilineTextAlignment(.center).textSelection(.enabled)
            }
            if profile != nil {
                UDButton(title: action) { Task { await connect() } }
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .padding()
    }
}
