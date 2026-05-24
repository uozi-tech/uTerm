import SwiftUI
import SwiftData
import UniformTypeIdentifiers

/// 渲染一个 `PaneModel`：终端窗格按连接状态显示，文件窗格显示文件浏览内容。
struct PaneView: View {
    let pane: PaneModel
    /// 该窗格是否为所在标签的聚焦窗格（用于高亮）。
    let isFocused: Bool
    /// 当前标签的拖拽会话状态（所有窗格共享一份）。
    let dragState: PaneDragState
    /// 点击窗格时通知上层设置聚焦。
    let onFocus: () -> Void
    /// 头部「分屏」按钮；方向由 `PaneView` 按窗格长宽比算出后传出。
    let onSplit: (SplitDirection) -> Void
    /// 拖拽落点：把 `source` 窗格按 `zone` 移到本窗格 / 与本窗格交换。
    let onMoveOrSwap: @MainActor @Sendable (_ source: UUID, _ zone: PaneDropZone) -> Void
    /// 头部「关闭窗格」按钮。
    let onClose: () -> Void
    /// 是否渲染窗格头部（图标 + 服务器名 + 分屏 + 关闭）。
    /// 单窗格 tab 由 titlebar 上的 chip 表达标题，header 多余。
    let showsHeader: Bool

    @Environment(\.modelContext) private var modelContext
    @Query private var profiles: [ServerProfile]

    @State private var paneSize: CGSize = .zero

    private var profile: ServerProfile? {
        profiles.first { $0.id == pane.serverProfileID }
    }

    var body: some View {
        VStack(spacing: 0) {
            if showsHeader { header }
            content
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(
            GeometryReader { geo in
                Color.clear
                    .onAppear { paneSize = geo.size }
                    .onChange(of: geo.size) { _, newSize in paneSize = newSize }
            }
        )
        // 投放区高亮叠在整块窗格上 —— 与 .onDrop 的 bounds、paneSize 量测
        // 同一坐标系（包含头部，当 showsHeader 为 true 时），高亮位置才与
        // paneDropZone 的归类一致。
        .overlay {
            if let zone = dropHighlightZone {
                PaneDropHighlight(zone: zone)
            }
        }
        // 焦点蓝框：只在多窗格 tab（即显示 header 时）出现 —— 单窗格 tab 时
        // 整块区域就是唯一焦点，框纯是视觉噪声。
        .overlay(
            RoundedRectangle(cornerRadius: 4)
                .strokeBorder(
                    (isFocused && showsHeader) ? AppTheme.Palette.accent : Color.clear,
                    lineWidth: 2)
        )
        .contentShape(Rectangle())
        .onTapGesture { onFocus() }
        .onDrop(of: [.utermPaneID], delegate: PaneDropDelegate(
            targetID: pane.id,
            dragState: dragState,
            bounds: CGRect(origin: .zero, size: paneSize),
            onDrop: onMoveOrSwap))
        .task(id: pane.id) { await connect() }
        .hostKeySheet(pane.hostKeyRelay)
    }

    /// 窗格头部条：拖拽手柄（图标 + 服务器名）+ 分屏 / 关闭控制。
    private var header: some View {
        HStack(spacing: 6) {
            // 图标 + 名称区域兼作拖拽手柄；尾部按钮在手柄之外，故按钮的
            // mouseDown 不会进入 .onDrag 的潜在拖拽态，保持可点。
            HStack(spacing: 6) {
                Image(systemName: headerIcon)
                    .font(.caption)
                    .foregroundStyle(AppTheme.Palette.textMuted)
                Text(profile?.name ?? "终端")
                    .font(.caption)
                    .foregroundStyle(AppTheme.Palette.textMuted)
                    .lineLimit(1)
                Spacer(minLength: 0)
            }
            .contentShape(Rectangle())
            .onDrag {
                dragState.begin(paneID: pane.id)
                return PaneDragPayload.itemProvider(paneID: pane.id)
            } preview: {
                dragPreview
            }
            Button(action: { onSplit(autoSplitDirection) }) {
                Image(systemName: "rectangle.split.2x1")
            }
            .help("分屏")
            Button(action: onClose) {
                Image(systemName: "xmark")
            }
            .help("关闭窗格")
        }
        .buttonStyle(.borderless)
        .font(.caption)
        .padding(.horizontal, 8)
        .frame(height: 26)
        .background(AppTheme.Palette.bgPanel)
    }

    /// 拖拽时跟随光标的小卡片。
    private var dragPreview: some View {
        HStack(spacing: 6) {
            Image(systemName: headerIcon)
            Text(profile?.name ?? "终端").lineLimit(1)
        }
        .font(.caption)
        .padding(.horizontal, 10)
        .padding(.vertical, 6)
        .background(RoundedRectangle(cornerRadius: 6).fill(.bar))
    }

    /// 按窗格当前长宽比选分屏方向：偏宽 → 左右分，偏高 → 上下分。
    private var autoSplitDirection: SplitDirection {
        paneSize.width >= paneSize.height ? .horizontal : .vertical
    }

    /// 当前应在本窗格上显示的投放区高亮；非拖拽悬停目标时为 nil。
    private var dropHighlightZone: PaneDropZone? {
        guard let dragging = dragState.draggingPaneID, dragging != pane.id,
              let hover = dragState.hover, hover.paneID == pane.id else { return nil }
        return hover.zone
    }

    private var headerIcon: String { "terminal" }

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
            Image(systemName: systemImage).font(.largeTitle).foregroundStyle(AppTheme.Palette.textMuted)
            Text(title).font(.headline)
            if !detail.isEmpty {
                Text(detail).font(.caption).foregroundStyle(AppTheme.Palette.textMuted)
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

