import SwiftUI
import SwiftData
import UniformTypeIdentifiers

/// 渲染一个 `PaneModel`：按其 `TerminalSession.connectionState` 显示
/// 连接中 / 失败重试 / 终端 / 断开重连；host-key 挑战弹 sheet。
struct PaneView: View {
    let pane: PaneModel
    /// 该窗格是否为所在标签的聚焦窗格（用于高亮）。
    let isFocused: Bool
    /// 点击窗格时通知上层设置聚焦。
    let onFocus: () -> Void
    /// 拖入边缘区落下：按方向分屏，新窗格连给定服务器。
    let onSplit: @MainActor @Sendable (SplitDirection, UUID) -> Void
    /// 拖入中心区落下：在新标签打开给定服务器。
    let onOpenInNewTab: @MainActor @Sendable (UUID) -> Void
    /// 头部「水平分屏」按钮。
    let onSplitHorizontal: () -> Void
    /// 头部「垂直分屏」按钮。
    let onSplitVertical: () -> Void
    /// 头部「关闭窗格」按钮。
    let onClose: () -> Void

    @Environment(\.modelContext) private var modelContext
    @Query private var profiles: [ServerProfile]
    @State private var dropZone: PaneDropZone?

    private var profile: ServerProfile? {
        profiles.first { $0.id == pane.serverProfileID }
    }

    private var challengeBinding: Binding<HostKeyChallenge?> {
        Binding(
            get: { pane.pendingChallenge },
            set: { if $0 == nil { pane.resolveChallenge(false) } }
        )
    }

    var body: some View {
        GeometryReader { geo in
            VStack(spacing: 0) {
                header
                content
            }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .overlay(
                    RoundedRectangle(cornerRadius: 4)
                        .strokeBorder(isFocused ? Color.accentColor : Color.clear, lineWidth: 2)
                )
                .overlay {
                    if let dropZone {
                        PaneDropHighlight(zone: dropZone)
                    }
                }
                .contentShape(Rectangle())
                .onTapGesture { onFocus() }
                .onDrop(of: [.plainText], delegate: PaneDropDelegate(
                    bounds: CGRect(origin: .zero, size: geo.size),
                    hoverZone: $dropZone,
                    onSplit: onSplit,
                    onOpenInNewTab: onOpenInNewTab))
        }
        .task(id: pane.id) { await connect() }
        .sheet(item: challengeBinding) { challenge in
            HostKeyPromptView(challenge: challenge) { pane.resolveChallenge($0) }
        }
    }

    /// 窗格头部条：服务器名 + 分屏/关闭控制。
    private var header: some View {
        HStack(spacing: 6) {
            Image(systemName: "terminal")
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

    @ViewBuilder
    private var content: some View {
        switch pane.session.connectionState {
        case .idle, .connecting:
            ProgressView("正在连接…")
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        case .connected:
            TerminalHostView(terminalView: pane.session.terminalView)
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
