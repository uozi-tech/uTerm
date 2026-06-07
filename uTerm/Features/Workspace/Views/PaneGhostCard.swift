import SwiftUI
import AppKit

/// 拖拽幽灵的"窗口卡片"——纯 SwiftUI 视图，由 `DragGhostWindowBridge` 装入独立
/// `NSPanel` 的 `NSHostingView` 渲染。复刻 `PaneView` 的窗格外观：头部条 + 终端主体
/// 实色底（终端走 Metal 无法纳入快照，故用纯色填充；底色按当前主题深 / 浅解析所选
/// 配色，与终端区一致）。卡片不可交互。
struct PaneGhostCard: View {
    let name: String
    let paneSize: CGSize

    /// 投影向外留白（四边）。`DragGhostWindowBridge` 据此扩展面板，使卡片主体与
    /// 屏幕上的真实窗格 1:1 对齐。
    static let shadowPadding: CGFloat = 24
    private static let cornerRadius: CGFloat = 8

    /// 终端配色在给定外观下的背景色。`dark` 由调用方按 app 外观计算
    /// （视图体读 `NSApp.effectiveAppearance`），抽成纯静态便于单测。
    static func terminalBackgroundColor(dark: Bool) -> NSColor {
        TerminalColorScheme.resolve(dark: dark).backgroundColor
    }

    /// 终端主体底色。独立 `NSPanel` 拿不到 `@Environment(\.colorScheme)`，故按
    /// `NSApp.effectiveAppearance` 现算深 / 浅（其余在层级内的视图用环境值）。
    private var terminalBackground: Color {
        let dark = NSApp.effectiveAppearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua
        return Color(nsColor: Self.terminalBackgroundColor(dark: dark))
    }

    var body: some View {
        VStack(spacing: 0) {
            header
            terminalBackground
        }
        .frame(width: max(paneSize.width, 1), height: max(paneSize.height, 1))
        .clipShape(RoundedRectangle(cornerRadius: Self.cornerRadius))
        .overlay(
            RoundedRectangle(cornerRadius: Self.cornerRadius)
                .strokeBorder(UD.border, lineWidth: 1)
        )
        .opacity(0.9)
        .shadow(color: .black.opacity(0.35), radius: 16, x: 0, y: 6)
        .padding(Self.shadowPadding)
    }

    /// 复刻 `PaneView.header`：终端图标 + 服务器名 + 静态分屏/关闭图标。背景用
    /// `UD.panel`，与真实头部一致。
    private var header: some View {
        HStack(spacing: 6) {
            Image(systemName: "terminal")
                .font(.caption)
                .foregroundStyle(UD.text3)
            Text(name)
                .font(.caption)
                .foregroundStyle(UD.text3)
                .lineLimit(1)
            Spacer(minLength: 0)
            Image(systemName: "rectangle.split.2x1")
                .font(.caption)
                .foregroundStyle(UD.text3)
            Image(systemName: "xmark")
                .font(.caption)
                .foregroundStyle(UD.text3)
        }
        .padding(.horizontal, 8)
        .frame(height: 26)
        .background(UD.panel)
        .overlay(alignment: .bottom) {
            Rectangle().fill(UD.border).frame(height: 1)
        }
    }
}
