import UDesignKit
// uTerm/Views/EmptyServersState.swift
import SwiftUI

/// 还没有任何服务器时的空态（设计稿 Variant A · EmptyA）。
///
/// 居中构图：朦胧径向点阵 + 品牌微光打底 → ULogo（84）→「uTerm」字标（细体，
/// 「Term」用品牌蓝）→ 等宽提示 `~ ssh user@host` + 静态光标 → 品牌蓝「新建主机」
/// 主按钮（⌘N 提示）→ 拖拽导入软提示。
struct EmptyServersState: View {
    let onNewServer: () -> Void
    @Environment(\.openWindow) private var openWindow

    var body: some View {
        ZStack {
            WelcomeDotGrid()
            Circle()
                .fill(RadialGradient(
                    colors: [UD.accent.opacity(0.10), .clear],
                    center: .center, startRadius: 0, endRadius: 230))
                .frame(width: 460, height: 460)
                .blur(radius: 20)
                .allowsHitTesting(false)

            VStack(spacing: 0) {
                ULogo(size: 84)

                wordmark.padding(.top, 18)
                tagline.padding(.top, 10)

                UDButton(title: "新建主机", systemImage: "plus", action: onNewServer)
                    .padding(.top, 36)

                importHint.padding(.top, 18)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(UD.panel)
    }

    // MARK: pieces

    private var wordmark: some View {
        Text("u\(Text("Term").foregroundColor(UD.accent))")
            .font(.system(size: 36, weight: .thin))
            .foregroundColor(UD.text)
            .tracking(-1.2)
    }

    private var tagline: some View {
        HStack(spacing: 4) {
            Text("~ \(Text("ssh").foregroundColor(UD.text2)) user@host")
                .font(.system(size: 13, design: .monospaced))
                .foregroundColor(UD.text3)
            Rectangle()
                .fill(UD.accent)
                .frame(width: 6, height: 13)
        }
    }

    private var importHint: some View {
        Button {
            openWindow(id: "import")
        } label: {
            Text("或拖拽 \(Text("~/.ssh/config").font(.system(size: 11.5, design: .monospaced)).foregroundColor(UD.text3)) 到此处导入")
                .font(.system(size: 11.5))
                .foregroundColor(UD.text3.opacity(0.8))
        }
        .buttonStyle(.plain)
    }
}

/// 朦胧径向点阵背景：1.5pt 圆点按 22pt 网格平铺，向边缘径向淡出。
/// 用 `Color.primary` 透明叠加，浅深自适应（深色下白点、浅色下黑点）。
private struct WelcomeDotGrid: View {
    var body: some View {
        Canvas { context, size in
            let spacing: CGFloat = 22
            let diameter: CGFloat = 1.5
            var y: CGFloat = spacing / 2
            while y < size.height {
                var x: CGFloat = spacing / 2
                while x < size.width {
                    let rect = CGRect(x: x, y: y, width: diameter, height: diameter)
                    context.fill(Path(ellipseIn: rect), with: .color(Color.primary.opacity(0.045)))
                    x += spacing
                }
                y += spacing
            }
        }
        .mask(
            RadialGradient(
                colors: [.black, .black.opacity(0.85), .clear],
                center: .center, startRadius: 20, endRadius: 320)
        )
        .allowsHitTesting(false)
    }
}
