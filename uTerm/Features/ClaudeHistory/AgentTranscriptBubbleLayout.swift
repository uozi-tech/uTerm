import SwiftUI

/// 用户消息的气泡（两端共用）：宽度贴着内容，最宽不超过给的宽度——同 Claude Code Desktop 里靠右的那一块。
///
/// Markdown 的排版会把自己撑满给的宽度（`MarkdownBlocks` 是 `maxWidth: .infinity`），直接放进靠右的 HStack
/// 就永远是整行宽。这里先按不限宽量出内容自己要多宽，再取它和给的宽度里小的那个去排。
///
/// 不限宽量一遍要把每段排成一整行，长消息（贴进来的日志）这一遍很贵、而且反正会撑满：`hugs` 为 false 时直接用给的宽度。
struct AgentHuggingWidth: Layout {
    var hugs = true

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        guard let subview = subviews.first else { return .zero }
        let width = fittedWidth(proposal, subview)
        return subview.sizeThatFits(ProposedViewSize(width: width, height: proposal.height))
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        subviews.first?.place(at: bounds.origin, proposal: ProposedViewSize(width: bounds.width, height: bounds.height))
    }

    private func fittedWidth(_ proposal: ProposedViewSize, _ subview: LayoutSubview) -> CGFloat? {
        guard hugs, let width = proposal.width, width.isFinite else { return proposal.width }
        let ideal = subview.sizeThatFits(.unspecified).width
        return min(ideal.rounded(.up), width)
    }
}
