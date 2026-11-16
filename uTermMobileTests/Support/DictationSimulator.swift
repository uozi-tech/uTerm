import UIKit

/// 照 UIKit 流式听写改写识别结果的做法驱动一个 `UITextInput`
///（iOS 27.2 的 `-[UIDictationController _updateLastHypothesis:WithNewHypothesis:]`，反汇编所得）：
/// 第一版在选区上 `replace`；之后从选区末尾往前数上一版的长度取一段，`text(in:)` 读出来必须是上一版，
/// 再把这一段 `replace` 成新的一版。读不出上一版时 UIKit 打日志「Could not find the last hypothesis」并取消听写，
/// 这里返回 false。模拟器跑不了真听写，只能这样核文档那一侧。
@MainActor
struct DictationSimulator {
    let input: UITextInput
    private(set) var lastHypothesis = ""

    init(_ input: UITextInput) { self.input = input }

    /// 交一版新结果。返回 false = 真机上听写会在这里被取消。
    @discardableResult
    mutating func hypothesis(_ next: String) -> Bool {
        guard let selection = input.selectedTextRange else { return false }
        guard !lastHypothesis.isEmpty else {
            input.replace(selection, withText: next)
            lastHypothesis = next
            return true
        }
        let start = input.position(from: selection.end, offset: -lastHypothesis.utf16.count) ?? input.beginningOfDocument
        guard let range = input.textRange(from: start, to: selection.end), input.text(in: range) == lastHypothesis else {
            return false
        }
        input.replace(range, withText: next)
        lastHypothesis = next
        return true
    }
}
