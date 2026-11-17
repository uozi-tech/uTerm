import Foundation

/// uTerm 本地补丁：已经发给终端、但系统还可能回头改写的那段字（iOS 听写的识别结果）。
///
/// 流式听写每出一版新结果，UIKit 都要先在文档里找到上一版、再整段换成新的
///（`-[UIDictationController _updateLastHypothesis:WithNewHypothesis:]`：从选区末尾往前数上一版的长度，
/// `text(in:)` 读出来找上一版，找不到就取消听写）。终端的文档原来只装组字，字一上屏就清掉，
/// 第二版结果永远找不到第一版，所以听写每说一个词就停。
///
/// 这一段只由 `replace(_:withText:)`（听写第一版结果就是从这里进来的）开头，之后的上屏接在后面；
/// 普通打字不会开头，键盘看到的前文和以前一样是空的（「双空格变句号」这类按前文起作用的功能不会多出来）。
/// 改写落在这一段里时换成按键：先退格删掉新旧不同的部分，再补打新字。别的按键、粘贴、失焦都清掉它——
/// 那之后终端那一行已经不是这一段说的样子了。
///
/// 公开是给 uTerm 的远程桌面键盘用：它的文档同样只装组字，听写同样每个词就停。
public struct TerminalCommittedTail {
    /// 留多长（UTF-16）。听写一句话的上一版必须整段留在里面；超出只留尾部。
    public static let limit = 4096

    public private(set) var text = ""

    public init() {}

    public var length: Int { text.utf16.count }
    public var isEmpty: Bool { text.isEmpty }

    /// 把一段文字换进来，要发给终端的按键。
    public struct Edit: Equatable, Sendable {
        /// 先退格几次（按字符算）。
        public var deletions: Int
        /// 再打哪些字。
        public var typed: String

        public init(deletions: Int, typed: String) {
            self.deletions = deletions
            self.typed = typed
        }
    }

    public mutating func append(_ string: String) {
        text += string
        trim()
    }

    public mutating func clear() {
        text = ""
    }

    /// 退格删掉最后一个字符。空的时候返回 false。
    @discardableResult
    public mutating func removeLast() -> Bool {
        guard !text.isEmpty else { return false }
        text.removeLast()
        return true
    }

    public func text(in range: NSRange) -> String? {
        let nsText = text as NSString
        guard range.location >= 0, range.length >= 0, range.location + range.length <= nsText.length else { return nil }
        return nsText.substring(with: range)
    }

    /// 把 `range`（这一段里的 UTF-16 偏移）换成 `replacement`，返回要发给终端的按键。
    /// 终端的光标在这一段末尾：range 之后的字要先退掉、再原样打回去；新旧相同的开头不动。
    public mutating func replace(_ range: NSRange, with replacement: String) -> Edit {
        let nsText = text as NSString
        let start = min(max(range.location, 0), nsText.length)
        let end = min(max(range.location + range.length, start), nsText.length)
        let removed = nsText.substring(from: start)
        let retyped = replacement + nsText.substring(from: end)
        let common = zip(removed, retyped).prefix { $0 == $1 }.count
        text = nsText.substring(to: start) + retyped
        trim()
        return Edit(deletions: removed.count - common, typed: String(retyped.dropFirst(common)))
    }

    private mutating func trim() {
        guard text.utf16.count > Self.limit else { return }
        var start = text.endIndex
        var kept = 0
        while start > text.startIndex {
            let previous = text.index(before: start)
            let size = text[previous ..< start].utf16.count
            guard kept + size <= Self.limit else { break }
            kept += size
            start = previous
        }
        text = String(text[start...])
    }
}
