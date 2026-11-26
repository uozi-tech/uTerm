//
//  UITerminalView+FloatingCursor.swift
//  libghostty-spm
//
//  uTerm 本地补丁：键盘当触控板（长按空格键、长按键盘）挪光标。
//

import CoreGraphics

/// 键盘当触控板的那一次拖动：手指从起点挪了几格，就该让光标走几格。
///
/// 终端里的光标归程序管，挪它只能发方向键：横着每过一个格宽发一个 ← / →，竖着每过一个行高发一个 ↑ / ↓
/// （Claude Code 的多行输入框里是换行；shell 里 ↑ / ↓ 是翻历史，和系统文本框里竖着挪也会换行一个意思）。
/// 累计的是「从起点算该走到第几格」，不是每次的增量，所以手指来回抖不会多发、慢慢挪也不会因为每步不够一格而一直不动。
struct TerminalFloatingCursorTracker: Equatable {
    let origin: CGPoint
    private(set) var columns = 0
    private(set) var rows = 0

    init(at point: CGPoint) {
        origin = point
    }

    /// 手指到了 `point`：返回这一下要补发的格数（正 = 向右 / 向下）。
    mutating func move(to point: CGPoint, cellSize: CGSize) -> (columns: Int, rows: Int) {
        guard cellSize.width > 0, cellSize.height > 0 else { return (0, 0) }
        let targetColumns = Int(((point.x - origin.x) / cellSize.width).rounded(.towardZero))
        let targetRows = Int(((point.y - origin.y) / cellSize.height).rounded(.towardZero))
        defer { columns = targetColumns; rows = targetRows }
        return (targetColumns - columns, targetRows - rows)
    }
}

#if canImport(UIKit)
    import UIKit

    extension UITerminalView {
        // UIKit 在键盘变成触控板时调这三个（UITextInput 的可选方法）。没实现时它改去动 `selectedTextRange`，
        // 而终端的输入文档只有正在组的字（平时是空的），光标一格都挪不动。

        @objc open func beginFloatingCursor(at point: CGPoint) {
            floatingCursor = inputHandler.hasMarkedText ? nil : TerminalFloatingCursorTracker(at: point)
        }

        @objc open func updateFloatingCursor(at point: CGPoint) {
            guard var tracker = floatingCursor, let size = floatingCursorCellSize else { return }
            let step = tracker.move(to: point, cellSize: size)
            floatingCursor = tracker
            sendFloatingCursorSteps(step.columns, negative: .arrowLeft, positive: .arrowRight)
            sendFloatingCursorSteps(step.rows, negative: .arrowUp, positive: .arrowDown)
        }

        @objc open func endFloatingCursor() {
            floatingCursor = nil
        }

        /// 一格的大小（点）。
        private var floatingCursorCellSize: CGSize? {
            guard let metrics = surface?.size() else { return nil }
            let scale = resolvedDisplayScale()
            return CGSize(width: CGFloat(metrics.cellWidthPixels) / scale, height: CGFloat(metrics.cellHeightPixels) / scale)
        }

        /// 走 `sendInputKey`：不用掉键盘条上按着的粘滞修饰键（那是给下一个键的）。
        private func sendFloatingCursorSteps(_ count: Int, negative: TerminalKey, positive: TerminalKey) {
            guard count != 0 else { return }
            let press = TerminalKeyPress(count < 0 ? negative : positive)
            for _ in 0 ..< abs(count) {
                _ = sendInputKey(press)
            }
        }
    }
#endif
