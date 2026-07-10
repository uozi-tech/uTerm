import SwiftUI

/// uTerm DesignKit 搜索框 —— 带前导放大镜与尾部 `⌘K` 提示芯片的输入框。
///
/// 纯展示组件：仅持有外部传入的文本 `Binding`，不依赖任何 domain model。
/// 高 32，内边距水平 12，圆角 `UD.Radius.md`，子元素间距 8。聚焦态（`@FocusState`）
/// 切换背景 / 描边 / 图标色，并叠一圈 3px `accent` 焦点环。`width` 给定则定宽，
/// 否则横向撑满。
struct UDSearchField: View {
    @Binding var text: String
    var width: CGFloat? = nil
    var autoFocus: Bool = false
    var showsHotkeyChip: Bool = true

    init(text: Binding<String>, width: CGFloat? = nil, autoFocus: Bool = false, showsHotkeyChip: Bool = true) {
        self._text = text
        self.width = width
        self.autoFocus = autoFocus
        self.showsHotkeyChip = showsHotkeyChip
    }

    @FocusState private var focused: Bool

    var body: some View {
        HStack(spacing: UD.Space.sm) { // 8
            Image(systemName: "magnifyingglass")
                .font(.system(size: 13))
                .foregroundStyle(focused ? UD.text2 : UD.text3)

            TextField("搜索", text: $text)
                .font(UD.body)
                .foregroundStyle(UD.text)
                .textFieldStyle(.plain)
                .focused($focused)

            if showsHotkeyChip {
                Text("⌘ K")
                    .font(UD.monoKbd)
                    .foregroundStyle(UD.text4)
                    .padding(.vertical, 2)
                    .padding(.horizontal, 6)
                    .background(
                        RoundedRectangle(cornerRadius: UD.Radius.xs) // 4
                            .fill(UD.dyn(.white(0.055), .black(0.065)))   // 键帽淡灰底，无描边
                    )
            }
        }
        .padding(.horizontal, UD.Space.lg) // 12
        .frame(height: 32)
        .frame(width: width)
        .frame(maxWidth: width == nil ? .infinity : nil)
        .background(
            RoundedRectangle(cornerRadius: UD.Radius.md) // 8
                .fill(UD.inputBg)   // 淡灰底、无描边；聚焦靠 accent 描边 + 焦点环
        )
        .overlay(
            RoundedRectangle(cornerRadius: UD.Radius.md)
                .strokeBorder(focused ? UD.accent.opacity(0.53) : .clear, lineWidth: 1)
        )
        .overlay(
            // 聚焦焦点环：2px 细环（强调色 ~13%），不用粗发光。
            RoundedRectangle(cornerRadius: UD.Radius.md)
                .stroke(UD.accent.opacity(focused ? 0.13 : 0), lineWidth: 2)
        )
        .overlay(
            UDInputFocusDismissMonitor(isFocused: $focused)
        )
        .onAppear { focused = autoFocus }
        .onChange(of: autoFocus) { _, newValue in
            focused = newValue
        }
    }

}

#Preview("UDSearchField") {
    struct PreviewWrapper: View {
        @State private var empty = ""
        @State private var focusedLook = ""
        @State private var filled = "nginx"

        var body: some View {
            VStack(alignment: .leading, spacing: UD.Space.xxl) {
                UDSearchField(text: $empty)
                UDSearchField(text: $focusedLook, width: 320)
                UDSearchField(text: $filled, width: 320)
            }
            .padding(UD.Space.xxxl)
            .background(UD.bg)
        }
    }
    return PreviewWrapper()
}
