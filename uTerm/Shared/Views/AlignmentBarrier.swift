import SwiftUI

/// 原样摆放唯一的子视图，但不向外报告任何显式对齐参考线。
///
/// 栈要知道子视图的 `.leading` / `.top` 参考线在哪，就得先把子视图量一遍、排一遍；
/// Agent 聊天行里是整棵 Markdown，`LazyVStack(alignment: .leading)` 问一次就是一次文字重排。
/// 行本身铺满宽度、靠前对齐，外层用不上内部的参考线，在这里截断即可。
/// 实测：一次挂满 1000 条（点过几次「显示更早」）时流式主线程心跳再 +10%（943 → 1036/1500）。
///
/// 自定义 `Layout` 不实现 `explicitAlignment` 时默认会合并子视图的参考线，
/// 所以两个方向都显式返回 nil。
struct AlignmentBarrier: Layout {
    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        subviews.first?.sizeThatFits(proposal) ?? .zero
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        // 原样转交量尺寸时的提议：换成 bounds 的确定尺寸会让子视图的尺寸缓存不命中，
        // 整棵 Markdown 再排一遍。
        subviews.first?.place(at: bounds.origin, proposal: proposal)
    }

    func explicitAlignment(of guide: HorizontalAlignment, in bounds: CGRect, proposal: ProposedViewSize,
                           subviews: Subviews, cache: inout ()) -> CGFloat? {
        nil
    }

    func explicitAlignment(of guide: VerticalAlignment, in bounds: CGRect, proposal: ProposedViewSize,
                           subviews: Subviews, cache: inout ()) -> CGFloat? {
        nil
    }
}
