import SwiftUI

/// uTerm DesignKit 浮层 —— 抬升的指标卡（设计稿 metrics popover）。
///
/// 纯展示组件：所有数据经普通值输入，不依赖任何 domain model。容器为 `overlayHi`
/// 实体面 + 单层 `border` 细发丝边 + `udShadow(.lg)`（无内高光）。主体含标题行、
/// 摘要、Sparkline 折线，以及可选的每核占用网格；`showsPointer` 时在底-尾挂一个
/// 45° 方块以暗示指向箭头。
///
/// - 所有 `samples` / `cores` 值域 0...100。
/// - 调用方传入**固定**样本数组（视图体内不取 `Date()`/随机），保证可预览、可截图。
struct UDMetricsPopover: View {
    var title: String
    var summary: String
    var color: Color
    /// 折线样本，每项 0...100。
    var samples: [Double]
    /// 可选每核占用（0...100）；为 `nil` 时不显示网格。
    var cores: [Double]? = nil
    /// 是否在底-尾挂指向箭头。
    var showsPointer: Bool = false

    private static let width: CGFloat = 340
    private static let contentWidth: CGFloat = 312
    private static let sparkHeight: CGFloat = 56

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            // 标题行
            HStack(spacing: 8) {
                Circle()
                    .fill(color)
                    .frame(width: 8, height: 8)

                Text(title)
                    .font(UD.font(12.5, weight: .semibold))
                    .foregroundStyle(UD.text)

                Spacer(minLength: 0)

                Text("实时")
                    .font(UD.mono(10.5))
                    .foregroundStyle(UD.text3)
            }
            .padding(.bottom, 8)

            // 摘要
            Text(summary)
                .font(UD.mono(11))
                .foregroundStyle(UD.text2)
                .padding(.bottom, 10)

            // Sparkline
            UDSparkline(samples: samples, color: color)
                .frame(width: Self.contentWidth, height: Self.sparkHeight)

            // 每核网格
            if let cores {
                LazyVGrid(
                    columns: [
                        GridItem(.flexible(), spacing: 18),
                        GridItem(.flexible(), spacing: 18)
                    ],
                    spacing: 6
                ) {
                    ForEach(Array(cores.enumerated()), id: \.offset) { index, value in
                        coreRow(index: index, value: value)
                    }
                }
                .padding(.top, 10)
            }
        }
        .padding(.vertical, 12)
        .padding(.horizontal, 14)
        .frame(width: Self.width)
        .background(
            RoundedRectangle(cornerRadius: UD.Radius.lg)
                .fill(UD.overlayHi)
        )
        .overlay(
            // 浮层细发丝边：单层 UD.border（白 7% / 黑 10%），无内高光。
            RoundedRectangle(cornerRadius: UD.Radius.lg)
                .strokeBorder(UD.border, lineWidth: 1)
        )
        .udShadow(.lg)
        .overlay(alignment: .bottomTrailing) {
            if showsPointer {
                Rectangle()
                    .fill(UD.overlayHi)
                    .overlay(
                        Rectangle()
                            .strokeBorder(UD.border, lineWidth: 1)
                    )
                    .frame(width: 10, height: 10)
                    .rotationEffect(.degrees(45))
                    .offset(x: -16, y: 5)
            }
        }
    }

    @ViewBuilder
    private func coreRow(index: Int, value: Double) -> some View {
        let pct = min(max(value, 0), 100) / 100
        let hot = value > 80

        HStack(spacing: 6) {
            Text("\(index + 1)")
                .font(UD.mono(10.5))
                .foregroundStyle(UD.text3)
                .frame(width: 20, alignment: .leading)

            GeometryReader { geo in
                ZStack(alignment: .leading) {
                    RoundedRectangle(cornerRadius: 4)
                        .fill(UD.dyn(.white(0.08), .black(0.08)))
                        .frame(height: 4)

                    RoundedRectangle(cornerRadius: 4)
                        .fill(hot ? UD.warning : color)
                        .frame(width: geo.size.width * pct, height: 4)
                }
                .frame(maxHeight: .infinity, alignment: .center)
            }
            .frame(height: 4)

            Text("\(Int(value))%")
                .font(UD.mono(10.5))
                .foregroundStyle(hot ? UD.warning : UD.text2)
                .frame(width: 38, alignment: .trailing)
        }
    }
}

// MARK: - Sparkline

/// 折线图：从 `samples`（每项 0...100）绘一条填充面（向底闭合，渐变上浓下透）
/// 加一条折线描边（圆角接头）。
private struct UDSparkline: View {
    var samples: [Double]
    var color: Color

    var body: some View {
        GeometryReader { geo in
            let w = geo.size.width
            let h = geo.size.height
            let n = samples.count

            ZStack {
                // 填充面
                areaPath(w: w, h: h, n: n)
                    .fill(
                        LinearGradient(
                            colors: [color.opacity(0.28), .clear],
                            startPoint: .top,
                            endPoint: .bottom
                        )
                    )

                // 折线
                linePath(w: w, h: h, n: n)
                    .stroke(
                        color,
                        style: StrokeStyle(lineWidth: 1.5, lineCap: .round, lineJoin: .round)
                    )
            }
        }
    }

    private func point(_ i: Int, w: CGFloat, h: CGFloat, n: Int) -> CGPoint {
        let x = n > 1 ? CGFloat(i) / CGFloat(n - 1) * w : 0
        let v = min(max(samples[i], 0), 100)
        let y = h - CGFloat(v) / 100 * h
        return CGPoint(x: x, y: y)
    }

    private func linePath(w: CGFloat, h: CGFloat, n: Int) -> Path {
        var path = Path()
        guard n > 0 else { return path }
        for i in 0..<n {
            let p = point(i, w: w, h: h, n: n)
            if i == 0 { path.move(to: p) } else { path.addLine(to: p) }
        }
        return path
    }

    private func areaPath(w: CGFloat, h: CGFloat, n: Int) -> Path {
        var path = Path()
        guard n > 0 else { return path }
        path.move(to: CGPoint(x: 0, y: h))
        for i in 0..<n {
            path.addLine(to: point(i, w: w, h: h, n: n))
        }
        path.addLine(to: CGPoint(x: w, y: h))
        path.closeSubpath()
        return path
    }
}

// MARK: - Preview

#Preview("UDMetricsPopover") {
    // 固定确定性样本（~40 值），视图体内不取 Date()/随机。
    let cpuSamples: [Double] = [
        42, 48, 45, 52, 60, 58, 64, 70, 66, 72,
        68, 74, 80, 76, 82, 78, 71, 66, 60, 64,
        58, 62, 68, 73, 77, 70, 64, 58, 54, 60,
        66, 72, 78, 74, 68, 62, 56, 60, 64, 62
    ]
    let memSamples: [Double] = [
        28, 30, 29, 31, 33, 32, 30, 28, 27, 29,
        31, 34, 36, 33, 30, 28, 26, 29, 31, 30,
        32, 35, 33, 31, 29, 27, 30, 33, 36, 34,
        31, 28, 30, 32, 31, 29, 30, 32, 31, 30
    ]

    return HStack(alignment: .top, spacing: UD.Space.xxxl) {
        UDMetricsPopover(
            title: "CPU 与负载",
            summary: "CPU 64.0% · 负载 0.42 / 0.51 / 0.48",
            color: UD.mCPU,
            samples: cpuSamples,
            cores: [64, 42, 88, 12],
            showsPointer: true
        )

        UDMetricsPopover(
            title: "内存负载",
            summary: "1.2 GB / 4.0 GB · 30.0%",
            color: UD.mMem,
            samples: memSamples
        )
    }
    .padding(UD.Space.xxxl)
    .background(UD.bg)
}
