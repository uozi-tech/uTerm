import SwiftUI

/// 列表一行前面的工具标记：小圆角方块里一个字母（或一个系统图标），每种工具一种颜色。
/// 自己画，不用各家的商标图。两端共用这张表，各自画。
nonisolated struct AgentHistoryToolMark: Equatable, Sendable {
    nonisolated enum Glyph: Equatable, Sendable {
        case letter(String)
        case symbol(String)
    }

    let glyph: Glyph
    /// 方块的底色（sRGB）。字是白的：几种颜色都挑得够深，浅色、深色外观下白字都看得清。
    let red: Double
    let green: Double
    let blue: Double

    var color: Color { Color(.sRGB, red: red, green: green, blue: blue) }

    static func of(_ tool: AgentHistoryTool) -> AgentHistoryToolMark {
        switch tool {
        case .claude: return AgentHistoryToolMark(glyph: .letter("C"), red: 0.80, green: 0.42, blue: 0.29)
        case .codex: return AgentHistoryToolMark(glyph: .letter("X"), red: 0.13, green: 0.50, blue: 0.40)
        case .cursor: return AgentHistoryToolMark(glyph: .symbol("cursorarrow"), red: 0.30, green: 0.33, blue: 0.42)
        case .antigravity: return AgentHistoryToolMark(glyph: .letter("A"), red: 0.33, green: 0.38, blue: 0.85)
        }
    }
}

/// 工具标记画出来的样子（`AgentHistoryToolMark`）。
struct AgentHistoryToolBadge: View {
    let tool: AgentHistoryTool
    var size: CGFloat = 16

    var body: some View {
        let mark = AgentHistoryToolMark.of(tool)
        RoundedRectangle(cornerRadius: size * 0.28, style: .continuous)
            .fill(mark.color)
            .frame(width: size, height: size)
            .overlay {
                switch mark.glyph {
                case .letter(let letter):
                    Text(verbatim: letter)
                        .font(.system(size: size * 0.62, weight: .bold, design: .rounded))
                        .foregroundStyle(.white)
                case .symbol(let name):
                    Image(systemName: name)
                        .font(.system(size: size * 0.56, weight: .bold))
                        .foregroundStyle(.white)
                }
            }
            .help(Text(verbatim: tool.displayName))
            .accessibilityElement()
            .accessibilityLabel(Text(verbatim: tool.displayName))
    }
}
