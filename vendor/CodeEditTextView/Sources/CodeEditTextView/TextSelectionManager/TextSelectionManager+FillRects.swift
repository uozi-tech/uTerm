//
//  TextSelectionManager+FillRects.swift
//  CodeEditTextView
//
//  Created by Khan Winter on 10/22/23.
//

import AppKit

extension TextSelectionManager {
    /// Calculate a set of rects for a text selection suitable for filling with the selection color to indicate a
    /// multi-line selection. The returned rects surround all selected line fragments for the given selection,
    /// following the available text layout space, rather than the available selection layout space.
    ///
    /// - Parameters:
    ///   - rect: The bounding rect of available draw space.
    ///   - textSelection: The selection to use.
    /// - Returns: An array of rects that the selection overlaps.
    func getFillRects(in rect: NSRect, for textSelection: TextSelection) -> [CGRect] {
        guard let layoutManager,
              let range = textSelection.range.intersection(delegate?.visibleTextRange ?? .zero) else {
            return []
        }

        var fillRects: [CGRect] = []

        let textWidth = if layoutManager.maxLineLayoutWidth == .greatestFiniteMagnitude {
            layoutManager.maxLineWidth
        } else {
            layoutManager.maxLineLayoutWidth
        }
        // uTerm 补丁 #2：整行被选中的行不再填到这个上界，只拿它兜底裁剪。额外加一个换行符
        // 方块的宽度，否则最长那一行的方块会被函数末尾那次 intersection 削掉。
        let lineBreakFillWidth = lineBreakFillWidth()
        let maxWidth = max(textWidth, layoutManager.wrapLinesWidth) + lineBreakFillWidth
        let validTextDrawingRect = CGRect(
            x: layoutManager.edgeInsets.left,
            y: rect.minY,
            width: maxWidth,
            height: rect.height
        ).intersection(rect)

        for linePosition in layoutManager.linesInRange(range) {
            fillRects.append(
                contentsOf: getFillRects(
                    in: validTextDrawingRect,
                    selectionRange: range,
                    forPosition: linePosition,
                    lineBreakFillWidth: lineBreakFillWidth
                )
            )
        }

        // Pixel align these to avoid aliasing on the edges of each rect that should be a solid box.
        return fillRects.map { $0.intersection(validTextDrawingRect).pixelAligned }
    }

    /// Find fill rects for a specific line position.
    /// - Parameters:
    ///   - rect: The bounding rect of the overall view.
    ///   - range: The selected range to create fill rects for.
    ///   - linePosition: The line position to use.
    /// - Returns: An array of rects that the selection overlaps.
    private func getFillRects(
        in rect: NSRect,
        selectionRange range: NSRange,
        forPosition linePosition: TextLineStorage<TextLine>.TextLinePosition,
        lineBreakFillWidth: CGFloat
    ) -> [CGRect] {
        guard let layoutManager else { return [] }
        var fillRects: [CGRect] = []

        // The selected range contains some portion of the line
        for fragmentPosition in linePosition.data.lineFragments {
            guard let fragmentRange = fragmentPosition
                .range
                .shifted(by: linePosition.range.location),
                  let intersectionRange = fragmentRange.intersection(range),
                  let minRect = layoutManager.rectForOffset(intersectionRange.location) else {
                continue
            }

            let maxRect: CGRect
            let endOfLine = fragmentRange.max <= range.max || range.contains(fragmentRange.max)
            let endOfDocument = intersectionRange.max == layoutManager.lineStorage.length
            let emptyLine = linePosition.range.isEmpty

            // If the selection is at the end of the line, or contains the end of the fragment, and is not the end
            // of the document, we select the entire line to the right of the selection point.
            // true, !true = false, false
            // true, !true = false, true
            // uTerm 补丁 #2 附加守卫：只有「本 fragment 是该行最后一个 fragment」时才
            // 算真正的行尾。uTerm 恒为 wrapLines=false（一行一个 fragment），该条件恒真；
            // 若将来开折行，没有这个守卫的话中间 fragment 也会被补上换行方块。
            let isLastFragmentOfLine = fragmentRange.max >= linePosition.range.max
            if endOfLine && isLastFragmentOfLine && !(endOfDocument && !emptyLine) {
                // uTerm 补丁 #2：上游把「选区盖到行尾」的行一路填到 rect.maxX
                // （= edgeInsets.left + max(最长行宽, 视口宽)），⌘A 于是糊成一整块横跨
                // 视口的蓝色，空行也整行铺满。改成只包住本行自己的文本，行尾补一个约等于
                // 空格宽的小方块代表被选中的换行符（VSCode 行为）。详见 UTERM-PATCHES.md。
                let lineEndX = layoutManager.edgeInsets.left
                    + fragmentPosition.data.width
                    + lineBreakFillWidth
                maxRect = CGRect(
                    x: max(minRect.minX, min(rect.maxX, lineEndX)),
                    y: fragmentPosition.yPos + linePosition.yPos,
                    width: 0,
                    height: fragmentPosition.height
                )
            } else if let maxFragmentRect = layoutManager.rectForOffset(intersectionRange.max) {
                maxRect = maxFragmentRect
            } else {
                continue
            }

            fillRects.append(CGRect(
                x: minRect.origin.x,
                y: minRect.origin.y,
                width: maxRect.minX - minRect.minX,
                height: max(minRect.height, maxRect.height)
            ))
        }

        return fillRects
    }

    /// uTerm 补丁 #2：整行被选中时行尾补的小方块宽度（≈ 一个空格），代表被选中的换行符。
    /// 按 font + kern 记忆化 —— 否则每个选区每帧都要量一次，列选择下是 O(选中行数)/帧。
    private func lineBreakFillWidth() -> CGFloat {
        guard let textView else { return 0 }
        let font = textView.font
        let kern = textView.kern
        if let cached = cachedLineBreakFill, cached.font == font, cached.kern == kern {
            return cached.width
        }
        let width = (" " as NSString).size(
            withAttributes: [.font: font, .kern: kern]
        ).width
        cachedLineBreakFill = (font, kern, width)
        return width
    }
}
