import SwiftUI

/// uTerm DesignKit 开关 —— 设计稿 `Components.html` 开关组件。
///
/// `UDToggle` 是 `Button(.plain)` 包装的 on/off 拨动开关：40×24 Capsule 轨道，
/// Ø20 白色圆形 knob 在 2px 内边距里左 / 右滑动（`.easeOut(0.2)`）。
/// ON 时轨道填 `UD.accent`、knob 居右；OFF 时填 `UD.dyn(.white(0.10), .black(0.10))`
/// 并叠一层顶部内阴影近似，knob 居左。
///
/// 通过 `@Environment(\.isEnabled)` 响应 `.disabled()`：整体降透明 ~0.45 且不响应点击。
/// 纯展示组件，只读 `UD` token + `Bool` 绑定，不依赖任何 domain model。
struct UDToggle: View {
    @Binding var isOn: Bool

    init(_ isOn: Binding<Bool>) {
        self._isOn = isOn
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
        Capsule()
            .fill(isOn ? UD.accent : UD.panelHover)
            .overlay(
                // OFF 态：顶部细描边 + 轻模糊，近似内嵌阴影
                Capsule()
                    .stroke(.black.opacity(0.12), lineWidth: 1)
                    .blur(radius: 1)
                    .opacity(isOn ? 0 : 1)
            )
            .clipShape(Capsule())
    }

    // MARK: - knob

    private var knob: some View {
        Circle()
            .fill(.white)
            .frame(width: 20, height: 20)
            .shadow(color: .black.opacity(0.3), radius: 1.5, y: 1)
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
