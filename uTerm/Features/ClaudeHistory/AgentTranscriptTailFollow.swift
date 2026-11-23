import SwiftUI

/// 实时跟随时对话的滚动（两端共用）：停在底部就跟着新内容滚到底；往上翻了就不动，由模型亮出「有新消息」。
/// 用户滚动停下来时报一次在不在底部（`AgentScrollPolicy` 的容差，同 Agent 对话）；新内容排版后把底部挤出视口时补滚一次。
struct AgentTranscriptTailFollow: ViewModifier {
    let transcript: AgentTranscriptModel
    let proxy: ScrollViewProxy
    let bottomID: String
    @State private var tailScroll = TailScrollCoalescer()

    func body(content: Content) -> some View {
        content
            .onScrollPhaseChange { _, phase, context in
                if phase == .tracking || phase == .interacting {
                    transcript.setFollowsTail(false)
                    tailScroll.cancel()
                } else if phase == .idle {
                    transcript.setFollowsTail(AgentScrollPolicy.isNearBottom(
                        visibleMaxY: context.geometry.visibleRect.maxY,
                        contentHeight: context.geometry.contentSize.height))
                }
            }
            .onScrollGeometryChange(for: AgentScrollPolicy.TailGeometry.self) { geometry in
                AgentScrollPolicy.TailGeometry(contentHeight: geometry.contentSize.height,
                                               containerHeight: geometry.containerSize.height,
                                               visibleMaxY: geometry.visibleRect.maxY)
            } action: { old, new in
                if transcript.followsTail, transcript.appendGeneration > 0, AgentScrollPolicy.needsRepin(from: old, to: new) {
                    scrollToBottom()
                }
            }
            .onChange(of: transcript.appendGeneration) { _, _ in
                if transcript.followsTail { scrollToBottom() }
            }
            .onDisappear { tailScroll.cancel() }
    }

    private func scrollToBottom() {
        tailScroll.schedule { proxy.scrollTo(bottomID, anchor: .bottom) }
    }
}
