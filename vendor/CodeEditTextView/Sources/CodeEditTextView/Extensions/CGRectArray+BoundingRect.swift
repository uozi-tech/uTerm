//
//  File.swift
//  CodeEditTextView
//
//  Created by Khan Winter on 7/17/25.
//

import AppKit

extension Array where Element == CGRect {
    /// Returns a rect object that contains all of the rects in this array.
    /// Returns `.zero` if the array is empty.
    /// - Returns: The minimum rectangle that contains all rectangles in this array.
    func boundingRect() -> CGRect {
        guard !self.isEmpty else { return .zero }
        let minX = self.min(by: { $0.origin.x < $1.origin.x })?.origin.x ?? 0
        let minY = self.min(by: { $0.origin.y < $1.origin.y })?.origin.y ?? 0
        // uTerm 补丁 #3：上游宽度取的是「maxY 最大那个 rect」的 maxX，而不是所有 rect
        // 里最大的 maxX —— 只要各行右缘不齐，包围盒就会被算窄。上游各行选区恒等宽
        // （都填到同一右缘），这个 bug 一直不可见；补丁 #2 把右缘改成参差之后就暴露了。
        // 消费方：TextView+ReplaceCharacters.swift 的「要不要滚动到选区」判据、
        // TextView+Accessibility.swift 的 accessibilityFrame。
        let maxX = self.map(\.maxX).max() ?? 0
        let maxY = self.map(\.maxY).max() ?? 0
        let origin = CGPoint(x: minX, y: minY)
        let size = CGSize(width: maxX - minX, height: maxY - minY)
        return CGRect(origin: origin, size: size)
    }
}
