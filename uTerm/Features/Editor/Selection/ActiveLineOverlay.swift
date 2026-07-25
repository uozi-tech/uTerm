// uTerm/Editor/Selection/ActiveLineOverlay.swift
import AppKit
import CodeEditTextView

/// 当前光标所在行的整行底色。覆盖 gutter 区域。
///
/// **仅在选区为空（只有光标）时绘制** —— 与 VSCode 一致：
/// `currentLineHighlight.ts` 的 `_shouldRenderInContent()` 要求 `selectionIsEmpty`。
/// 早期注释写反了，说「选择期间保持可见才是 VSCode 行为」，实际相反；而且选区填充
/// 是 `TextView.draw(_:)` 画进宿主 layer 的 contents，任何子 layer（哪怕 zPosition
/// 为负）都合成在它**之上**，所以拖选时这条带会从参差的选区右侧露出来。
///
/// 用法：`init(textView:)` 一次性挂为 textView 的子 layer；
///       `update(selection:)` 在选中变化时调；横滚 / 尺寸变化时调 `refresh()`
///       （文档宽度会随排版到更长的行而增长，路径宽度是快照，不刷新就会半路截断）。
@MainActor
final class ActiveLineOverlay {
    private weak var textView: TextView?
    private let shapeLayer: CAShapeLayer
    /// 最近一次的选区，供 refresh() 在滚动 / resize 时按新文档宽度重画。
    private var lastSelection = NSRange(location: 0, length: 0)

    init(textView: TextView) {
        self.textView = textView
        self.shapeLayer = CAShapeLayer()
        // 负 zPosition 只把它压在其它**子 layer** 之下；宿主自身 draw 的内容（正文与
        // 选区填充）永远更靠下，压不到。留负值仅为排在缩进线之下。
        shapeLayer.zPosition = -1
        textView.layer?.insertSublayer(shapeLayer, at: 0)
        applyFillColor()
    }

    /// 当前行底色随外观重解析。CAShapeLayer 持 CGColor 快照、不像普通 NSView 那样
    /// 在外观变化时自动重算动态色，故在 init + 每次 update 时按 textView 的
    /// effectiveAppearance 重设（切主题后下次光标移动即纠正；底色很淡，可接受）。
    private func applyFillColor() {
        guard let textView else { return }
        textView.effectiveAppearance.performAsCurrentDrawingAppearance {
            shapeLayer.fillColor = EditorTheme.activeLineBg.cgColor
        }
    }

    /// 按当前文档宽度重画最近一次的活动行。滚动 / 尺寸变化时调 ——
    /// 不折行时 `textView.bounds.width` 会随排版到更长的行而增长，
    /// 而 path 里的宽度是写死的快照，不重画就会在半路截断。
    func refresh() {
        update(selection: lastSelection)
    }

    /// 根据选区起点定位活动行，画整行底色横跨 textView 全宽（含 gutter 区）。
    /// 选区非空时不画（VSCode 行为，见类型注释）。
    /// layout 还没跑、找不到行就把 path 清掉避免画在错误位置。
    func update(selection: NSRange) {
        lastSelection = selection
        guard selection.length == 0 else {
            shapeLayer.path = nil
            return
        }
        guard let textView,
              let linePos = textView.layoutManager.textLineForOffset(selection.location) else {
            shapeLayer.path = nil
            return
        }
        // textView.bounds.width = 完整文档宽（含 gutter 内嵌区）—— 让带子横跨
        // gutter strip 与 VSCode 一致；自家 selectionManager 的
        // highlightSelectedLine 被关，不会与我们抢色叠加。
        let rect = CGRect(x: 0, y: linePos.yPos,
                          width: textView.bounds.width,
                          height: linePos.height)
        shapeLayer.path = CGPath(rect: rect, transform: nil)
        applyFillColor()
    }

    /// 隐藏（textView 释放或 attach 切换时调）。
    func clear() {
        shapeLayer.path = nil
    }
}
