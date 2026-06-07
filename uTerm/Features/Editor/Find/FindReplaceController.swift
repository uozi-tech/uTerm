// uTerm/Editor/Find/FindReplaceController.swift
import Foundation
import Observation

/// 与 NSView 解耦的 find/replace 状态机。
/// text 通过闭包注入；外部副作用（替换、undo group、emphasis、滚动）也用闭包注入 ——
/// 单测里全部 mock 掉。
@MainActor
@Observable
final class FindReplaceController {

    // MARK: 输入
    var query: String = "" { didSet { search() } }
    var replacement: String = ""
    var options: FindMatcher.Options = .init(caseSensitive: false, regex: false, wholeWord: false) {
        didSet { search() }
    }
    var isReplaceShown: Bool = false

    // MARK: 输出
    private(set) var matches: [NSRange] = []
    private(set) var activeIndex: Int = 0
    private(set) var errorMessage: String?

    // MARK: 注入的副作用
    private let text: () -> String
    var onReplace: ((NSRange, String) -> Void)?
    var onApplyEmphases: (() -> Void)?
    var onScrollToActive: (() -> Void)?
    var onBeginUndoGroup: (() -> Void)?
    var onEndUndoGroup: (() -> Void)?

    init(text: @escaping () -> String) {
        self.text = text
    }

    func search() {
        do {
            matches = try FindMatcher.find(in: text(), query: query, options: options)
            errorMessage = nil
        } catch FindMatcher.FindError.invalidRegex(let msg) {
            matches = []
            errorMessage = "Invalid regex: \(msg)"
        } catch {
            matches = []
            errorMessage = error.localizedDescription
        }
        activeIndex = matches.isEmpty ? 0 : min(activeIndex, matches.count - 1)
        onApplyEmphases?()
        onScrollToActive?()
    }

    func next() {
        guard !matches.isEmpty else { return }
        activeIndex = (activeIndex + 1) % matches.count
        onApplyEmphases?()
        onScrollToActive?()
    }

    func previous() {
        guard !matches.isEmpty else { return }
        activeIndex = (activeIndex - 1 + matches.count) % matches.count
        onApplyEmphases?()
        onScrollToActive?()
    }

    func replaceCurrent() {
        guard !matches.isEmpty else { return }
        let range = matches[activeIndex]
        onReplace?(range, replacement)
        // 重新 search —— text 变了，offsets 都失效
        search()
    }

    func replaceAll() {
        guard !matches.isEmpty else { return }
        onBeginUndoGroup?()
        // 从后往前替换，避免前面的替换打乱后面的 offsets
        for range in matches.reversed() {
            onReplace?(range, replacement)
        }
        onEndUndoGroup?()
        search()
    }
}
