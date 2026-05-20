import SwiftUI
import SwiftData

/// 渲染一个 `PaneModel`：终端窗格按连接状态显示，文件窗格显示文件浏览内容。
struct PaneView: View {
    let pane: PaneModel
    /// 该窗格是否为所在标签的聚焦窗格（用于高亮）。
    let isFocused: Bool
    /// 点击窗格时通知上层设置聚焦。
    let onFocus: () -> Void
    /// 头部「水平分屏」按钮。
    let onSplitHorizontal: () -> Void
    /// 头部「垂直分屏」按钮。
    let onSplitVertical: () -> Void
    /// 头部「关闭窗格」按钮。
    let onClose: () -> Void

    @Environment(\.modelContext) private var modelContext
    @Query private var profiles: [ServerProfile]

    private var profile: ServerProfile? {
        profiles.first { $0.id == pane.serverProfileID }
    }

    var body: some View {
        VStack(spacing: 0) {
            header
            content
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .overlay(
            RoundedRectangle(cornerRadius: 4)
                .strokeBorder(isFocused ? Color.accentColor : Color.clear, lineWidth: 2)
        )
        .contentShape(Rectangle())
        .onTapGesture { onFocus() }
        .task(id: pane.id) { await connect() }
        .modifier(HostKeySheetModifier(pane: pane))
    }

    /// 窗格头部条：图标 + 服务器名 + 分屏/关闭控制。
    private var header: some View {
        HStack(spacing: 6) {
            Image(systemName: headerIcon)
                .font(.caption)
                .foregroundStyle(.secondary)
            Text(profile?.name ?? "终端")
                .font(.caption)
                .foregroundStyle(.secondary)
                .lineLimit(1)
            Spacer(minLength: 0)
            Button(action: onSplitHorizontal) {
                Image(systemName: "rectangle.split.2x1")
            }
            .help("水平分屏")
            Button(action: onSplitVertical) {
                Image(systemName: "rectangle.split.1x2")
            }
            .help("垂直分屏")
            Button(action: onClose) {
                Image(systemName: "xmark")
            }
            .help("关闭窗格")
        }
        .buttonStyle(.borderless)
        .font(.caption)
        .padding(.horizontal, 8)
        .frame(height: 26)
        .background(.bar)
    }

    private var headerIcon: String {
        switch pane.kind {
        case .terminal: "terminal"
        case .files: "folder"
        }
    }

    @ViewBuilder
    private var content: some View {
        switch pane.kind {
        case .terminal(let session):
            terminalContent(session: session)
        case .files(let model):
            FileBrowserContent(model: model)
        }
    }

    @ViewBuilder
    private func terminalContent(session: TerminalSession) -> some View {
        switch session.connectionState {
        case .idle, .connecting:
            ProgressView("正在连接…")
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        case .connected:
            TerminalHostView(terminalView: session.terminalView)
        case .failed(let message):
            stateView(systemImage: "exclamationmark.triangle",
                      title: "连接失败", detail: message, action: "重试")
        case .disconnected:
            stateView(systemImage: "bolt.horizontal.circle",
                      title: "连接已断开", detail: "", action: "重新连接")
        }
    }

    private func connect() async {
        if let profile {
            await pane.connect(profile: profile, modelContainer: modelContext.container)
        } else {
            pane.markServerMissing()
        }
    }

    @ViewBuilder
    private func stateView(systemImage: String, title: String,
                           detail: String, action: String) -> some View {
        VStack(spacing: 12) {
            Image(systemName: systemImage).font(.largeTitle).foregroundStyle(.secondary)
            Text(title).font(.headline)
            if !detail.isEmpty {
                Text(detail).font(.caption).foregroundStyle(.secondary)
                    .multilineTextAlignment(.center).textSelection(.enabled)
            }
            if profile != nil {
                Button(action) { Task { await connect() } }
                    .buttonStyle(.borderedProminent)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .padding()
    }
}

/// 按 kind 给窗格挂对应的 host-key 审批 sheet。
private struct HostKeySheetModifier: ViewModifier {
    let pane: PaneModel

    func body(content: Content) -> some View {
        switch pane.kind {
        case .terminal:
            content.hostKeySheet(pane.hostKeyRelay)
        case .files(let model):
            content.hostKeySheet(model.hostKeyRelay)
        }
    }
}
