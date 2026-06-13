import SwiftUI

/// 自动换行的流式布局（chip / 气泡）。`alignment` 控制每行的水平对齐：
/// `.leading`（左对齐）或 `.center`（每行居中）。macOS 13+ `Layout`。
///
/// 与 `Features/Keys` 里的局部 `FlowLayout`（仅左对齐）区分：这个可居中、可复用，
/// 供 Agent 空状态示例（居中）与「猜你想问」追问气泡（左对齐）等场景共用。
struct WrapLayout: Layout {
    enum Align { case leading, center }

    var spacing: CGFloat = 8
    var lineSpacing: CGFloat = 8
    var alignment: Align = .leading

    private struct Row {
        var indices: [Int] = []
        var width: CGFloat = 0
        var height: CGFloat = 0
    }

    /// 按 maxWidth 贪心地把子视图打包成若干行。
    private func rows(maxWidth: CGFloat, _ subviews: Subviews) -> [Row] {
        var rows: [Row] = []
        var cur = Row()
        for i in subviews.indices {
            let s = subviews[i].sizeThatFits(.unspecified)
            let prospective = cur.indices.isEmpty ? s.width : cur.width + spacing + s.width
            if !cur.indices.isEmpty, prospective > maxWidth {
                rows.append(cur)
                cur = Row()
            }
            if cur.indices.isEmpty {
                cur.indices = [i]; cur.width = s.width; cur.height = s.height
            } else {
                cur.indices.append(i)
                cur.width += spacing + s.width
                cur.height = max(cur.height, s.height)
            }
        }
        if !cur.indices.isEmpty { rows.append(cur) }
        return rows
    }

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let maxWidth = proposal.width ?? .infinity
        let rs = rows(maxWidth: maxWidth, subviews)
        let height = rs.map(\.height).reduce(0, +) + lineSpacing * CGFloat(max(0, rs.count - 1))
        let width = maxWidth.isFinite ? maxWidth : (rs.map(\.width).max() ?? 0)
        return CGSize(width: width, height: height)
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        let rs = rows(maxWidth: bounds.width, subviews)
        var y = bounds.minY
        for row in rs {
            var x = alignment == .center
                ? bounds.minX + (bounds.width - row.width) / 2
                : bounds.minX
            for i in row.indices {
                let s = subviews[i].sizeThatFits(.unspecified)
                subviews[i].place(at: CGPoint(x: x, y: y), proposal: ProposedViewSize(s))
                x += s.width + spacing
            }
            y += row.height + lineSpacing
        }
    }
}
