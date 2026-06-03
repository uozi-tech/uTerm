// uTerm/Views/EmptyServersState.swift
import SwiftUI
import Combine

/// 还没有任何服务器时的空态（设计稿 Variant A · EmptyA）。
///
/// 居中构图：朦胧径向点阵 + 品牌微光打底 → ULogo（84）→「uTerm」字标（细体，
/// 「Term」用品牌蓝）→ 等宽提示 `~ ssh user@host` + 闪烁光标 → 品牌蓝「新建主机」
/// 主按钮（⌘N 提示）→ 拖拽导入软提示。
struct EmptyServersState: View {
    let onNewServer: () -> Void

    @State private var caretOn = true
    @State private var ctaHover = false

    /// 光标闪烁节拍（设计稿 u-blink ≈ 1.1s steps，硬切而非渐变）。
    private let blink = Timer.publish(every: 0.6, on: .main, in: .common).autoconnect()

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

                Button(action: onNewServer) { ctaLabel }
                    .buttonStyle(.plain)
                    .onHover { ctaHover = $0 }
                    .padding(.top, 36)

                importHint.padding(.top, 18)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(UD.panel)
        .onReceive(blink) { _ in caretOn.toggle() }
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
                .opacity(caretOn ? 1 : 0)
        }
    }

    private var ctaLabel: some View {
        HStack(spacing: 8) {
            Image(systemName: "plus")
                .font(.system(size: 11, weight: .semibold))
            Text("新建主机")
                .font(.system(size: 12.5, weight: .medium))
            KbdChip(text: "⌘N")
        }
        .foregroundColor(UD.text)
        .padding(.horizontal, 16)
        .frame(height: 34)
        .background(
            RoundedRectangle(cornerRadius: 8)
                .fill(UD.accent.opacity(ctaHover ? 0.20 : 0.12)))
        .overlay(
            RoundedRectangle(cornerRadius: 8)
                .stroke(UD.accent.opacity(ctaHover ? 0.55 : 0.35), lineWidth: 1))
        .animation(.easeOut(duration: 0.15), value: ctaHover)
    }

    private var importHint: some View {
        Text("或拖拽 \(Text("~/.ssh/config").font(.system(size: 11.5, design: .monospaced)).foregroundColor(UD.text3)) 到此处导入")
            .font(.system(size: 11.5))
            .foregroundColor(UD.text3.opacity(0.8))
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
