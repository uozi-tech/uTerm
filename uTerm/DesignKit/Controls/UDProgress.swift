import SwiftUI

/// uTerm DesignKit 进度原语 —— 线性条 / 不定态条 / 环形 / 传输行，集中于此一文件。
///
/// 全部为纯展示组件：进度值统一为 `Double`（0...1），不依赖任何 domain model。
/// 颜色 / 度量均取自 UD token；深色态线性条带柔光，浅色态传输卡片带 `udShadow(.sm)`。

// MARK: - 线性进度条

/// 确定态线性进度条。轨道为半透明 Capsule，填充为 `color` 上色的 Capsule，
/// 宽度按 `progress` 比例，深色态带柔光。
struct UDLinearBar: View {
    var progress: Double
    var color: Color = UD.accent
    var height: CGFloat = 6

    private var clamped: Double { min(max(progress, 0), 1) }

    var body: some View {
        GeometryReader { geo in
            ZStack(alignment: .leading) {
                Capsule()
                    .fill(UD.dyn(.white(0.07), .black(0.08)))
                    .frame(width: geo.size.width, height: height)

                Capsule()
                    .fill(color)
                    .frame(width: geo.size.width * clamped, height: height)
                    .shadow(color: color.opacity(0.4), radius: 4)
            }
            .frame(height: height)
        }
        .frame(height: height)
    }
}

// MARK: - 不定态进度条

/// 不定态线性进度条。一根占 40% 宽的 Capsule 在轨道内由 -40% 滑至 100%，
/// 1.4s easeInOut 无限往复。
struct UDIndeterminateBar: View {
    var height: CGFloat = 4

    @State private var animating = false

    var body: some View {
        GeometryReader { geo in
            let width = geo.size.width
            let sliderWidth = width * 0.4

            ZStack(alignment: .leading) {
                Capsule()
                    .fill(UD.dyn(.white(0.07), .black(0.08)))
                    .frame(width: width, height: height)

                Capsule()
                    .fill(UD.accent)
                    .frame(width: sliderWidth, height: height)
                    .offset(x: animating ? width : -sliderWidth)
            }
            .frame(width: width, height: height)
            .clipShape(Capsule())
            .onAppear {
                withAnimation(.easeInOut(duration: 1.4).repeatForever(autoreverses: false)) {
                    animating = true
                }
            }
        }
        .frame(height: height)
    }
}

// MARK: - 环形进度

/// 确定态环形进度。底环半透明，进度环 `color` 上色、圆头、自顶部顺时针，
/// 圆心显示整数百分比。
struct UDRing: View {
    var progress: Double
    var size: CGFloat = 44
    var color: Color = UD.accent

    private var clamped: Double { min(max(progress, 0), 1) }

    var body: some View {
        ZStack {
            Circle()
                .stroke(UD.dyn(.white(0.08), .black(0.10)), lineWidth: 3.5)

            Circle()
                .trim(from: 0, to: clamped)
                .stroke(color, style: StrokeStyle(lineWidth: 3.5, lineCap: .round))
                .rotationEffect(.degrees(-90))

            Text("\(Int(clamped * 100))")
                .font(UD.mono(10))
                .foregroundStyle(UD.text2)
        }
        .frame(width: size, height: size)
    }
}

// MARK: - 传输行

/// 文件传输卡片：标题（方向箭头 + 文件名 + 百分比）、线性进度条、底部速率 / 大小。
struct UDTransferRow: View {
    enum Direction { case up, down }

    var name: String
    var progress: Double
    var direction: Direction

    private var clamped: Double { min(max(progress, 0), 1) }

    var body: some View {
        VStack(spacing: 7) {
            HStack(spacing: 6) {
                Image(systemName: direction == .up ? "arrow.up" : "arrow.down")
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(UD.accent)

                Text(name)
                    .font(UD.mono(11.5))
                    .foregroundStyle(UD.text2)
                    .lineLimit(1)
                    .truncationMode(.middle)
                    .frame(maxWidth: .infinity, alignment: .leading)

                Text("\(Int(clamped * 100))%")
                    .font(UD.mono(10.5))
                    .foregroundStyle(UD.text3)
            }

            UDLinearBar(progress: clamped, height: 4)

            HStack {
                Text("\(direction == .up ? "上传" : "下载") · 2.4 MB/s")
                Spacer()
                Text(String(format: "%.1f / 12.8 MB", clamped * 12.8))
            }
            .font(UD.mono(9.5))
            .foregroundStyle(UD.text4)
        }
        .padding(.vertical, 10)
        .padding(.horizontal, 12)
        .frame(width: 320)
        .background(
            RoundedRectangle(cornerRadius: UD.Radius.lg)
                .fill(UD.dyn(.white(0.025), .hex(0xFFFFFF)))
        )
        .overlay(
            RoundedRectangle(cornerRadius: UD.Radius.lg)
                .strokeBorder(UD.border, lineWidth: 1)
        )
        .udShadow(.sm)
    }
}

// MARK: - Preview

#Preview("UDProgress") {
    VStack(alignment: .leading, spacing: UD.Space.xxl) {
        VStack(alignment: .leading, spacing: UD.Space.lg) {
            UDLinearBar(progress: 0.24)
            UDLinearBar(progress: 0.62)
            UDLinearBar(progress: 1.0, color: UD.success)
        }
        .frame(width: 320)

        HStack(spacing: UD.Space.xl) {
            UDRing(progress: 0.30, color: UD.success)
            UDRing(progress: 0.68, color: UD.success)
            UDRing(progress: 0.92, color: UD.success)
        }

        UDIndeterminateBar()
            .frame(width: 320)

        UDTransferRow(name: "banner.png", progress: 0.72, direction: .up)
        UDTransferRow(name: "backup-2026.tar.gz", progress: 0.38, direction: .down)
    }
    .padding(UD.Space.xxxl)
    .background(UD.bg)
}
