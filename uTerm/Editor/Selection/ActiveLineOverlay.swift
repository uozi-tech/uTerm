// uTerm/Editor/Selection/ActiveLineOverlay.swift
import AppKit
import CodeEditTextView

/// 在 TextView 上叠一层 CALayer，跟随光标行高亮整行底色。
/// 与 EmphasisManager 隔离 —— active line 不参与 emphasis 的 z-order 抢占。
///
/// API 注：`textView.layoutManager.textLineForOffset(_:)` 返回
/// `TextLineStorage<TextLine>.TextLinePosition?`，其 `.yPos` 和 `.height`
/// 直接在 position struct 上，不在 TextLine 本身。
@MainActor
final class ActiveLineOverlay {
    private weak var textView: TextView?
    private let layer: CAShapeLayer

    init(textView: TextView) {
        self.textView = textView
        self.layer = CAShapeLayer()
        layer.fillColor = EditorTheme.activeLineBg.cgColor
        layer.zPosition = -1  // 在文字下方、selection 之下
        // TextView.init 已设置 wantsLayer = true，layer 必然存在
        textView.layer?.insertSublayer(layer, at: 0)
    }

    /// 选中变化时调。光标行 = 选区起点所在的 line。
    func update(selection: NSRange) {
        guard let textView else {
            layer.path = nil
            return
        }
        // textLineForOffset 返回 TextLineStorage<TextLine>.TextLinePosition?
        // .yPos / .height 是 position struct 上的属性
        guard let linePos = textView.layoutManager.textLineForOffset(selection.location) else {
            layer.path = nil
            return
        }
        let rect = CGRect(x: 0, y: linePos.yPos, width: textView.bounds.width, height: linePos.height)
        layer.path = CGPath(rect: rect, transform: nil)
    }
}
