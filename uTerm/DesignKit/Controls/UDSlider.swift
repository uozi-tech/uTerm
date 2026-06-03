import SwiftUI

/// uTerm DesignKit 滑块原语 —— 可拖拽取值的水平滑块。
///
/// 纯展示组件：值统一为 `Double`，绑定外部 state，不依赖任何 domain model。
/// 颜色 / 度量均取自 UD token；填充带柔光，旋钮为白色圆 + 投影 + `UD.border` 描边环。
/// 通过 `@Environment(\.isEnabled)` 响应 `.disabled()`：降透明度并禁用手势。
struct UDSlider: View {
    @Binding var value: Double
    var range: ClosedRange<Double> = 0...1
    var step: Double? = nil
    var ticks: Int = 0
    var color: Color = UD.accent
    var valueLabel: ((Double) -> String)? = nil

    @Environment(\.isEnabled) private var isEnabled

    private let knobSize: CGFloat = 20
    private let trackHeight: CGFloat = 4

    init(
        value: Binding<Double>,
        in range: ClosedRange<Double> = 0...1,
        step: Double? = nil,
        ticks: Int = 0,
        color: Color = UD.accent,
        valueLabel: ((Double) -> String)? = nil
    ) {
        self._value = value
        self.range = range
        self.step = step
        self.ticks = ticks
        self.color = color
        self.valueLabel = valueLabel
    }

    // 当前值映射到 0...1 比例
    private var fraction: Double {
        let span = range.upperBound - range.lowerBound
        guard span > 0 else { return 0 }
        return min(max((value - range.lowerBound) / span, 0), 1)
    }

    var body: some View {
        HStack(spacing: 12) {
            sliderArea
                .frame(maxWidth: .infinity)
                .frame(height: knobSize)

            if let valueLabel {
                Text(valueLabel(value))
                    .font(UD.mono(12))
                    .foregroundStyle(UD.text2)
                    .frame(width: 52, alignment: .trailing)
            }
        }
        .opacity(isEnabled ? 1 : 0.45)
    }

    private var sliderArea: some View {
        GeometryReader { geo in
            let width = geo.size.width
            let travel = max(width - knobSize, 0)
            let knobX = travel * fraction
            // 填充延伸到旋钮中心
            let fillWidth = knobX + knobSize / 2

            ZStack(alignment: .leading) {
                // 轨道
                Capsule()
                    .fill(UD.dyn(.white(0.07), .black(0.08)))
                    .frame(width: width, height: trackHeight)

                // 填充（0% 时不渲染）
                if fraction > 0 {
                    Capsule()
                        .fill(color)
                        .frame(width: fillWidth, height: trackHeight)
                        .shadow(color: color.opacity(0.4), radius: 4)
                }

                // 刻度点（轨道下方 6pt）
                if ticks > 0 {
                    tickRow(width: width)
                        .offset(y: trackHeight / 2 + 6)
                }

                // 旋钮
                Circle()
                    .fill(Color.white)
                    .frame(width: knobSize, height: knobSize)
                    .overlay(Circle().strokeBorder(UD.border, lineWidth: 1))
                    .shadow(color: .black.opacity(0.3), radius: 2, y: 1)
                    .offset(x: knobX)
            }
            .frame(width: width, height: knobSize)
            .contentShape(Rectangle())
            .gesture(isEnabled ? dragGesture(width: width) : nil)
        }
    }

    private func tickRow(width: CGFloat) -> some View {
        let count = max(ticks, 1)
        let inset = knobSize / 2
        let usable = max(width - knobSize, 0)
        return ZStack(alignment: .leading) {
            ForEach(0..<count, id: \.self) { i in
                let t = count > 1 ? Double(i) / Double(count - 1) : 0
                Circle()
                    .fill(UD.text4)
                    .frame(width: 2, height: 2)
                    .offset(x: inset + usable * t - 1)
            }
        }
        .frame(width: width, alignment: .leading)
    }

    private func dragGesture(width: CGFloat) -> some Gesture {
        DragGesture(minimumDistance: 0)
            .onChanged { g in
                let travel = max(width - knobSize, 0)
                guard travel > 0 else { return }
                // 以旋钮中心对齐光标
                let frac = min(max((g.location.x - knobSize / 2) / travel, 0), 1)
                let span = range.upperBound - range.lowerBound
                var newValue = range.lowerBound + frac * span

                if let step, step > 0 {
                    let steps = (newValue - range.lowerBound) / step
                    newValue = range.lowerBound + steps.rounded() * step
                }

                value = min(max(newValue, range.lowerBound), range.upperBound)
            }
    }
}

// MARK: - Preview

#Preview("UDSlider") {
    struct Demo: View {
        @State private var fontSize: Double = 11
        @State private var lineHeight: Double = 1.0
        @State private var green: Double = 24
        @State private var disabled: Double = 0.5

        var body: some View {
            VStack(alignment: .leading, spacing: UD.Space.xxl) {
                UDSlider(
                    value: $fontSize,
                    in: 8...24,
                    step: 1,
                    ticks: 7,
                    valueLabel: { "\(Int($0)) pt" }
                )

                UDSlider(
                    value: $lineHeight,
                    in: 1.0...2.0,
                    valueLabel: { String(format: "%.2f", $0) }
                )

                UDSlider(
                    value: $green,
                    in: 8...48,
                    step: 1,
                    color: UD.success,
                    valueLabel: { "\(Int($0)) pt" }
                )

                UDSlider(
                    value: $disabled,
                    valueLabel: { String(format: "%.2f", $0) }
                )
                .disabled(true)
            }
            .frame(width: 320)
            .padding(UD.Space.xxxl)
            .background(UD.bg)
        }
    }
    return Demo()
}
