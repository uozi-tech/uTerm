// uTerm/Editor/Selection/ActiveLineOverlay.swift
import AppKit
import CodeEditTextView

/// 当前光标所在行的整行底色。覆盖 gutter 区域，且在 text 选择期间也保持
/// 可见（VSCode 行为）—— CodeEditTextView 自带的 `highlightSelectedLine` 是
/// `if textSelection.range.isEmpty` 才绘，drag-select 时整条带消失，是个回归。
/// 这里走 CAShapeLayer 自绘，与内置完全独立、不打架。
///
/// 用法：`init(textView:)` 一次性挂为 textView 的子 layer；
///       `update(selection:)` 在选中变化时调，传"选区起点所在行"作为活动行。
@MainActor
final class ActiveLineOverlay {
    private weak var textView: TextView?
    private let shapeLayer: CAShapeLayer

    init(textView: TextView) {
        self.textView = textView
        self.shapeLayer = CAShapeLayer()
        shapeLayer.fillColor = EditorTheme.activeLineBg.cgColor
        shapeLayer.zPosition = -1  // 在文字下、selection 之下，gutter 之上的层级由 textView 排
        textView.layer?.insertSublayer(shapeLayer, at: 0)
    }

    /// 根据选区起点定位活动行，画整行底色横跨 textView 全宽（含 gutter 区）。
    /// layout 还没跑、找不到行就把 path 清掉避免画在错误位置。
    func update(selection: NSRange) {
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
    }

    /// 隐藏（textView 释放或 attach 切换时调）。
    func clear() {
        shapeLayer.path = nil
    }
}
