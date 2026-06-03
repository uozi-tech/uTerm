import SwiftUI

/// uTerm DesignKit 分段控制 —— 设计稿 `Components.html` 分段控制组。
///
/// `DarkSegmented` 的 drop-in 替代：泛型选项（`Value: Hashable`），等宽分段，
/// 选中段填 `UD.accent` + 白字 + 顶部高光；未选段悬停浅底；相邻**均未选**的
/// 两段之间显示 1px 竖分隔。纯展示组件，只读 `UD` token + 普通值输入，不依赖
/// 任何 domain model。
struct UDSegmented<Value: Hashable>: View {
    @Binding var selection: Value
    let options: [(value: Value, label: String)]

    init(selection: Binding<Value>, options: [(value: Value, label: String)]) {
        self._selection = selection
        self.options = options
    }

    var body: some View {
        HStack(spacing: 0) {
            ForEach(Array(options.enumerated()), id: \.offset) { index, option in
                segment(option.value, option.label)
                    .overlay(alignment: .trailing) {
                        if showsDivider(after: index) {
                            Rectangle()
                                .fill(UD.border)
                                .frame(width: 1)
                                .padding(.vertical, 6)
                        }
                    }
            }
        }
        .padding(3)
        .frame(height: 30)
        .background(
            RoundedRectangle(cornerRadius: 9, style: .continuous)
                .fill(UD.dyn(.white(0.05), .black(0.04)))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 9, style: .continuous)
                .strokeBorder(UD.border, lineWidth: 1)
        )
        .fixedSize(horizontal: true, vertical: false)
    }

    // MARK: - 单段

    private func segment(_ value: Value, _ label: String) -> some View {
        let selected = value == selection
        return Button {
            withAnimation(.easeOut(duration: 0.16)) {
                selection = value
            }
        } label: {
            SegmentLabel(label: label, selected: selected)
        }
        .buttonStyle(.plain)
    }

    /// 仅当第 `index` 段与其右邻段**都未选中**时，显示二者间的竖分隔。
    private func showsDivider(after index: Int) -> Bool {
        guard index + 1 < options.count else { return false }
        let left = options[index].value
        let right = options[index + 1].value
        return left != selection && right != selection
    }
}

// MARK: - 段标签（承载 hover 态）

private struct SegmentLabel: View {
    let label: String
    let selected: Bool
    @State private var hovering = false

    var body: some View {
        Text(label)
            .font(UD.font(12, weight: .medium))
            .foregroundStyle(selected ? Color.white : UD.text2)
            .padding(.horizontal, 16)
            .frame(minWidth: 56)
            .frame(maxWidth: .infinity)
            .frame(maxHeight: .infinity)
            .background {
                if selected {
                    RoundedRectangle(cornerRadius: 6, style: .continuous)
                        .fill(UD.accent)
                        .overlay(
                            RoundedRectangle(cornerRadius: 6, style: .continuous)
                                .strokeBorder(Color.white.opacity(0.15), lineWidth: 1)
                                .mask(
                                    LinearGradient(colors: [.white, .clear],
                                                   startPoint: .top, endPoint: .bottom)
                                )
                        )
                } else if hovering {
                    RoundedRectangle(cornerRadius: 6, style: .continuous)
                        .fill(UD.dyn(.white(0.05), .black(0.05)))
                }
            }
            .contentShape(Rectangle())
            .onHover { hovering = $0 }
    }
}

// MARK: - Preview

#Preview {
    struct Demo: View {
        let scheme: ColorScheme
        @State private var fontChoice = "Monaco"
        @State private var appearance = "深色"
        @State private var viewMode = "分屏"

        var body: some View {
            VStack(alignment: .leading, spacing: 20) {
                UDSegmented(selection: $fontChoice, options: [
                    (value: "Menlo", label: "Menlo"),
                    (value: "SF Mono", label: "SF Mono"),
                    (value: "Monaco", label: "Monaco"),
                ])
                UDSegmented(selection: $appearance, options: [
                    (value: "浅色", label: "浅色"),
                    (value: "深色", label: "深色"),
                ])
                UDSegmented(selection: $viewMode, options: [
                    (value: "编辑", label: "编辑"),
                    (value: "分屏", label: "分屏"),
                    (value: "预览", label: "预览"),
                ])
            }
            .padding(24)
            .frame(width: 320, alignment: .leading)
            .background(UD.bg)
            .environment(\.colorScheme, scheme)
        }
    }

    return HStack(spacing: 0) {
        Demo(scheme: .dark)
        Demo(scheme: .light)
    }
}
