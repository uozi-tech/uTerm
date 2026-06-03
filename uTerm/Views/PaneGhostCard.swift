import SwiftUI

/// 拖拽幽灵的"窗口卡片"——纯 SwiftUI 视图，由 `DragGhostWindowBridge` 装入独立
/// `NSPanel` 的 `NSHostingView` 渲染。复刻 `PaneView` 的窗格外观：头部条 + 深色
/// 终端主体（终端走 Metal，拖拽时本就呈深色，无需也无法纳入快照）。卡片不可交互。
struct PaneGhostCard: View {
    let name: String
    let paneSize: CGSize

    /// 投影向外留白（四边）。`DragGhostWindowBridge` 据此扩展面板，使卡片主体与
    /// 屏幕上的真实窗格 1:1 对齐。
    static let shadowPadding: CGFloat = 24
    private static let cornerRadius: CGFloat = 8

    var body: some View {
        VStack(spacing: 0) {
            header
            Color(nsColor: TerminalTheme.backgroundColor)
        }
        .frame(width: max(paneSize.width, 1), height: max(paneSize.height, 1))
        .clipShape(RoundedRectangle(cornerRadius: Self.cornerRadius))
        .overlay(
            RoundedRectangle(cornerRadius: Self.cornerRadius)
                .strokeBorder(WS.border, lineWidth: 1)
        )
        .opacity(0.9)
        .shadow(color: .black.opacity(0.35), radius: 16, x: 0, y: 6)
        .padding(Self.shadowPadding)
    }

    /// 复刻 `PaneView.header`：终端图标 + 服务器名 + 静态分屏/关闭图标。背景用
    /// `WS.panel`，与真实头部一致。
    private var header: some View {
        HStack(spacing: 6) {
            Image(systemName: "terminal")
                .font(.caption)
                .foregroundStyle(WS.text3)
            Text(name)
                .font(.caption)
                .foregroundStyle(WS.text3)
                .lineLimit(1)
            Spacer(minLength: 0)
            Image(systemName: "rectangle.split.2x1")
                .font(.caption)
                .foregroundStyle(WS.text3)
            Image(systemName: "xmark")
                .font(.caption)
                .foregroundStyle(WS.text3)
        }
        .padding(.horizontal, 8)
        .frame(height: 26)
        .background(WS.panel)
        .overlay(alignment: .bottom) {
            Rectangle().fill(WS.border).frame(height: 1)
        }
    }
}
