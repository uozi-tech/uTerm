import GhosttyTerminal
import UIKit

/// 照 UIKit 流式听写改写识别结果的做法驱动一个 `UITextInput`（iOS 27.2 反汇编所得）：
///
/// - `-[UIDictationController _updateLastHypothesis:WithNewHypothesis:]` 从选区末尾往前数上一版的长度取一段，
///   `text(in:)` 读出来必须是上一版（读不出就打日志「Could not find the last hypothesis」并取消听写，这里返回 false），
///   再交给 `UIKBInputDelegateManager` 把这一段换成新的一版。
/// - 交之前同步发 `UIDictationWillInsertHypothesisNotification`（输入视图靠它认出接下来那次上屏是听写，见 `TerminalDictationInput`）。
/// - `-[UIKBInputDelegateManager replaceRange:oldText:withText:forReplaceAction:]` 的听写分支：范围是空的
///  （第一版落在光标处）就调 `insertText(_:)`，不调 `replace(_:withText:)`。上一版的模拟一律走 `replace`，
///   真机上第一版走的却是 `insertText`，测试全过、真机还是只剩第一个字。
///
/// 模拟器跑不了真听写，只能这样核文档那一侧。
@MainActor
struct DictationSimulator {
    let input: UITextInput
    private(set) var lastHypothesis = ""

    init(_ input: UITextInput) { self.input = input }

    /// 交一版新结果。返回 false = 真机上听写会在这里被取消。
    @discardableResult
    mutating func hypothesis(_ next: String) -> Bool {
        guard let selection = input.selectedTextRange else { return false }
        let start = input.position(from: selection.end, offset: -lastHypothesis.utf16.count) ?? input.beginningOfDocument
        guard let range = input.textRange(from: start, to: selection.end),
              (input.text(in: range) ?? "") == lastHypothesis
        else { return false }
        Self.announceHypothesis()
        if range.isEmpty {
            input.insertText(next)
        } else {
            input.replace(range, withText: next)
        }
        lastHypothesis = next
        return true
    }

    /// 照 UIKit 发「要插一版识别结果了」的通知。
    static func announceHypothesis() {
        NotificationCenter.default.post(name: TerminalDictationInput.willInsertHypothesis, object: nil)
    }

    /// 清掉没被认领的标记。用到模拟器的测试在 setUp / tearDown 里调：标记是全进程的。
    static func reset() {
        _ = TerminalDictationInput.claimHypothesis()
    }
}
