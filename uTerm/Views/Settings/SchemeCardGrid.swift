import SwiftUI
import SwiftTerm

/// 5-列网格的配色选择器。每个 SchemeCard 显示 5 色 chip + 一行 prompt
/// 示例 + 名字 + 选中态描边/勾。点击切换 @Binding。
struct SchemeCardGrid: View {
    @Binding var selection: TerminalColorSchemeID
    @Environment(\.colorScheme) private var scheme

    var body: some View {
        LazyVGrid(
            columns: [GridItem(.adaptive(minimum: 160), spacing: 10)],
            spacing: 10
        ) {
            ForEach(TerminalColorSchemeID.allCases) { id in
                SchemeCard(scheme: TerminalColorScheme.resolve(id, dark: scheme == .dark),
                           isSelected: selection == id)
                    .contentShape(Rectangle())
                    .onTapGesture { selection = id }
            }
        }
    }
}

struct SchemeCard: View {
    let scheme: TerminalColorScheme
    let isSelected: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            // chips + 一行 prompt 示例
            VStack(alignment: .leading, spacing: 6) {
                HStack(spacing: 4) {
                    ForEach(0..<previewChips.count, id: \.self) { i in
                        Circle()
                            .fill(Color(nsColor: previewChips[i]))
                            .frame(width: 10, height: 10)
                    }
                }
                HStack(spacing: 0) {
                    Text("$ ")
                        .foregroundStyle(Color(nsColor: scheme.foregroundColor).opacity(0.6))
                    Text("echo ")
                        .foregroundStyle(ansiColor(2))  // green
                    Text("\"hi\"")
                        .foregroundStyle(ansiColor(3))  // yellow
                }
                .font(.system(size: 10.5, design: .monospaced))
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 10)
            .frame(height: 60)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(Color(nsColor: scheme.backgroundColor))

            // bottom label
            HStack {
                Text(scheme.displayName)
                    .font(.system(size: 11.5))
                    .foregroundStyle(isSelected ? UD.text : UD.text2)
                Spacer()
                if isSelected {
                    Image(systemName: "checkmark")
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundStyle(Color(nsColor: scheme.accentColor))
                }
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 7)
        }
        .background(.regularMaterial)
        .overlay(
            RoundedRectangle(cornerRadius: 8)
                .stroke(isSelected ? Color(nsColor: scheme.accentColor) : UD.border, lineWidth: 1)
        )
        .clipShape(RoundedRectangle(cornerRadius: 8))
        .shadow(color: isSelected ? Color(nsColor: scheme.accentColor).opacity(0.2) : .clear, radius: 4)
    }

    /// 5 色 chip：红 / 黄 / 绿 / 蓝 / 品（设计稿 6 色但太挤；先 5 色）。
    private var previewChips: [NSColor] {
        // ansiColors 顺序：[black, red, green, yellow, blue, magenta, cyan, white, …bright]
        let ansi = scheme.ansiColors
        let pick: [Int] = [1, 3, 2, 4, 5]  // red, yellow, green, blue, magenta
        return pick.map { idx -> NSColor in
            let c = ansi[idx]
            return NSColor(
                srgbRed: CGFloat(c.red) / 65535,
                green: CGFloat(c.green) / 65535,
                blue: CGFloat(c.blue) / 65535,
                alpha: 1
            )
        }
    }

    // SwiftTerm 也定义 Color 类型 —— 全限定 SwiftUI.Color 消歧
    private func ansiColor(_ idx: Int) -> SwiftUI.Color {
        let c = scheme.ansiColors[idx]
        return SwiftUI.Color(
            red: Double(c.red) / 65535,
            green: Double(c.green) / 65535,
            blue: Double(c.blue) / 65535
        )
    }
}
