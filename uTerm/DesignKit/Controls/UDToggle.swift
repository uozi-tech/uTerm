import SwiftUI

/// uTerm DesignKit 开关 —— 设计稿 `Components.html` 开关组件。
///
/// `UDToggle` 是 `Button(.plain)` 包装的 on/off 拨动开关：40×24 Capsule 轨道，
/// Ø20 白色圆形 knob 在 2px 内边距里左 / 右滑动（`.easeOut(0.2)`）。
/// ON 时轨道填纯 `UD.accent`、无描边、knob 居右；OFF 时填中性 `UD.panelHover` +
/// 1px `UD.border` 细描边（无内阴影），knob 居左。knob 自带投影。
///
/// 通过 `@Environment(\.isEnabled)` 响应 `.disabled()`：整体降透明 ~0.45 且不响应点击。
/// 纯展示组件，只读 `UD` token + `Bool` 绑定，不依赖任何 domain model。
struct UDToggle: View {
    @Binding var isOn: Bool
    /// ON 态轨道填充色（默认 `UD.accent`）。AI 介入开关传 `UD.aiAccent` 显紫。
    var tint: Color

    init(_ isOn: Binding<Bool>, tint: Color = UD.accent) {
        self._isOn = isOn
        self.tint = tint
    }

    @Environment(\.isEnabled) private var isEnabled

    var body: some View {
        Button {
            isOn.toggle()
        } label: {
            ZStack(alignment: isOn ? .trailing : .leading) {
                track
                knob
                    .padding(2)   // knob 在 2px 内边距里滑动（含上下，故 20+2+2=24 撑满轨道高）
            }
            .frame(width: 40, height: 24)
            .animation(.easeOut(duration: 0.2), value: isOn)
        }
        .buttonStyle(.plain)
        .opacity(isEnabled ? 1 : 0.45)
        .allowsHitTesting(isEnabled)
    }

    // MARK: - 轨道

    private var track: some View {
        // OFF 态中性灰填充 / ON 态纯强调色填充；均无描边、无内阴影（v2 拍平）。
        Capsule()
            .fill(isOn ? tint : UD.panelHover)
    }

    // MARK: - knob

    private var knob: some View {
        Circle()
            .fill(.white)
            .frame(width: 20, height: 20)
            .shadow(color: .black.opacity(0.18), radius: 1, y: 1)   // 设计稿 0 1 2 /.18
    }
}

// MARK: - Preview

#Preview {
    struct Demo: View {
        @State private var off = false
        @State private var on = true
        @State private var disOff = false
        @State private var disOn = true
        @State private var hotReload = true

        var body: some View {
            VStack(alignment: .leading, spacing: 18) {
                row("off", $off)
                row("on", $on)
                row("disabled-off", $disOff, disabled: true)
                row("disabled-on", $disOn, disabled: true)

                Divider().overlay(UD.border)

                // 设置行示例
                HStack {
                    Text("热加载")
                        .font(UD.font(13))
                        .foregroundStyle(UD.text)
                    Spacer()
                    UDToggle($hotReload)
                }
            }
            .padding(24)
            .frame(width: 300, alignment: .leading)
            .background(UD.bg)
        }

        private func row(_ label: String, _ binding: Binding<Bool>, disabled: Bool = false) -> some View {
            HStack(spacing: 12) {
                Text(label)
                    .font(UD.caption)
                    .foregroundStyle(UD.text3)
                    .frame(width: 110, alignment: .leading)
                UDToggle(binding)
                    .disabled(disabled)
            }
        }
    }

    return Demo()
}
