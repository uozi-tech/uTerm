import CoreGraphics
import Foundation

/// Agent 对话滚动的共享策略。流式文本与 Markdown 排版都按批次刷新，自动贴底也必须
/// 合并，否则每个 SSE 碎片都会启动一次 SwiftUI LazyVStack 布局事务。
nonisolated enum AgentScrollPolicy {
    static let coalescingDelay: Double = 0.10
    static let bottomTolerance: CGFloat = 96

    static func isNearBottom(
        visibleMaxY: CGFloat,
        contentHeight: CGFloat,
        tolerance: CGFloat = bottomTolerance
    ) -> Bool {
        guard visibleMaxY.isFinite, contentHeight.isFinite else { return false }
        return visibleMaxY >= max(0, contentHeight - tolerance)
    }

    /// 贴底跟随要盯的布局量：可滚高度（内容高 − 视口高），以及视口此刻是否在底部容差带里。
    /// 只在这两者变化时才回调，滚动途中的每一帧偏移不会触发。
    nonisolated struct TailGeometry: Equatable, Sendable {
        var scrollableHeight: CGFloat
        var isNearBottom: Bool

        init(contentHeight: CGFloat, containerHeight: CGFloat, visibleMaxY: CGFloat) {
            scrollableHeight = contentHeight.isFinite && containerHeight.isFinite
                ? max(0, contentHeight - containerHeight) : 0
            isNearBottom = AgentScrollPolicy.isNearBottom(visibleMaxY: visibleMaxY,
                                                          contentHeight: contentHeight)
        }
    }

    /// 原本在底部、而可滚高度变大 = 底边被挤出了视口，跟随中就得补滚一次。
    ///
    /// 只听消息模型（文本长度 / 工具卡 / 条数）不够：流式 Markdown 每 100ms 才重解析
    /// 一次（`StreamingMarkdownRenderer.reparseDelay`），与贴底合并窗口等长且晚一步启动，
    /// 于是贴底总滚到「旧底部」，最后一批重排把内容撑高后再没有人补滚 —— 停在最新输出上方
    /// 一两段。排队条带出现把视口挤矮，消息模型根本没变。两者都只体现在可滚高度上。
    ///
    /// 「原本在底部」这一条防的是没有手势相位的滚动（拖滚动条、程序滚动）：
    /// `onScrollPhaseChange` 不一定把它们报成交互，`followsTail` 还是 true；
    /// 懒栈在新位置重估行高也会改可滚高度，不加这条就会把人拽回底部。
    static func needsRepin(from old: TailGeometry, to new: TailGeometry) -> Bool {
        old.isNearBottom && new.scrollableHeight > old.scrollableHeight + 0.5
    }
}

/// 贴底滚动的合并器：一个合并窗口里只发一次滚动，与流式 Markdown 的重解析节奏对齐，
/// 避免逐 token / 逐批输出各起一次 LazyVStack 布局事务。Agent 对话（两端）、并行执行的
/// AI 汇报与 Shell 输出都用它。视图用 `@State` 持有（引用类型，跨 body 重算保持同一个）。
@MainActor
final class TailScrollCoalescer {
    private let delay: Double
    private var pending: DispatchWorkItem?

    init(delay: Double = AgentScrollPolicy.coalescingDelay) {
        self.delay = delay
    }

    /// 窗口里已有一次排着就不再排（合并）；否则 `delay` 之后执行 `action`。
    /// `action` 执行时读到的是那一刻的视图状态，窗口里新来的内容也滚得到。
    func schedule(_ action: @escaping @MainActor () -> Void) {
        guard pending == nil else { return }
        arm(action)
    }

    /// 取消在排的那次，从现在重新计时（去抖：一阵输出停下来之后只发一次）。
    func restart(_ action: @escaping @MainActor () -> Void) {
        cancel()
        arm(action)
    }

    func cancel() {
        pending?.cancel()
        pending = nil
    }

    var isPending: Bool { pending != nil }

    private func arm(_ action: @escaping @MainActor () -> Void) {
        let work = DispatchWorkItem { [weak self] in
            MainActor.assumeIsolated {
                self?.pending = nil
                action()
            }
        }
        pending = work
        DispatchQueue.main.asyncAfter(deadline: .now() + delay, execute: work)
    }
}
