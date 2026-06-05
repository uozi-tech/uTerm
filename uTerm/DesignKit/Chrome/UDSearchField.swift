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

    init(text: Binding<String>, width: CGFloat? = nil, autoFocus: Bool = false) {
        self._text = text
        self.width = width
        self.autoFocus = autoFocus
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

            Text("⌘ K")
                .font(UD.monoKbd)
                .foregroundStyle(UD.text4)
                .padding(.vertical, 2)
                .padding(.horizontal, 6)
                .overlay(
                    RoundedRectangle(cornerRadius: UD.Radius.xs) // 4
                        .strokeBorder(UD.border, lineWidth: 1)
                )
        }
        .padding(.horizontal, UD.Space.lg) // 12
        .frame(height: 32)
        .frame(width: width)
        .frame(maxWidth: width == nil ? .infinity : nil)
        .background(
            RoundedRectangle(cornerRadius: UD.Radius.md) // 8
                .fill(focused ? UD.dyn(.white(0.05), .black(0.05))
                              : UD.dyn(.white(0.035), .black(0.035)))
        )
        .overlay(
            RoundedRectangle(cornerRadius: UD.Radius.md)
                .strokeBorder(focused ? UD.accent.opacity(0.53) : UD.border, lineWidth: 1)
        )
        .overlay(
            RoundedRectangle(cornerRadius: UD.Radius.md)
                .stroke(UD.accent.opacity(focused ? 0.13 : 0), lineWidth: 3)
        )
        // ⌘K 聚焦搜索框（对应尾部提示芯片）。隐藏的零尺寸按钮承载快捷键，
        // 在所在窗口为 key 时生效，焦点在别处也能触发。
        .background(hotkey)
        .onAppear { focused = autoFocus }
        .onChange(of: autoFocus) { _, newValue in
            focused = newValue
        }
    }

    /// 承载 ⌘K 快捷键的隐藏按钮：把键盘焦点交给搜索输入框。
    private var hotkey: some View {
        Button("") { focused = true }
            .keyboardShortcut("k", modifiers: .command)
            .opacity(0)
            .frame(width: 0, height: 0)
            .accessibilityHidden(true)
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
