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
        // 记住重搜前当前活动匹配的起点，重搜后选「离它最近」的匹配
        // —— 比单纯 clamp 到末尾更贴近用户视觉位置（#36）。
        let priorOffset = matches.indices.contains(activeIndex) ? matches[activeIndex].location : nil
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
        activeIndex = matches.isEmpty ? 0 : nearestMatchIndex(toOffset: priorOffset)
        onApplyEmphases?()
        onScrollToActive?()
    }

    /// 在 `matches` 里找离 `offset` 最近的匹配下标。`offset == nil`（无历史活动匹配）
    /// 或没有匹配时返回 0。`matches` 由 `FindMatcher` 产出，已按起点升序。
    private func nearestMatchIndex(toOffset offset: Int?) -> Int {
        guard !matches.isEmpty else { return 0 }
        guard let offset else { return 0 }
        var best = 0
        var bestDistance = Int.max
        for (idx, range) in matches.enumerated() {
            let distance = abs(range.location - offset)
            if distance < bestDistance {
                bestDistance = distance
                best = idx
            }
        }
        return best
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
        guard matches.indices.contains(activeIndex) else { return }
        let range = matches[activeIndex]
        // regex 模式下展开 $1 等捕获组；literal 模式按字面写入。
        let expanded = FindMatcher.replacement(for: range, in: text(),
                                               query: query, template: replacement,
                                               options: options)
        onReplace?(range, expanded)
        // 替换文本写入后，下一个活动匹配应落在「插入文本末尾」之后 —— 否则当替换串
        // 本身仍匹配 query 时（如把 "foo" 换成 "foofoo"），刚插入的那段会被重新选中，
        // Replace 原地打转、文档无限增长（#34）。
        let replacementEnd = range.location + (expanded as NSString).length
        // 重新 search —— text 变了，offsets 都失效
        search()
        guard !matches.isEmpty else { return }
        if let next = matches.firstIndex(where: { $0.location >= replacementEnd }) {
            activeIndex = next
        } else {
            // 替换点之后再无匹配 —— 回绕到第一个（与 next() 的环绕语义一致）。
            activeIndex = 0
        }
        onApplyEmphases?()
        onScrollToActive?()
    }

    func replaceAll() {
        guard !matches.isEmpty else { return }
        let currentText = text()
        // 先把每个匹配的展开替换串算好（regex 模式展开 $1；literal 模式即字面）。
        // 必须在任何替换发生前用「原始 text」计算，否则 offsets 与捕获组都会错位。
        let edits: [(NSRange, String)] = matches.map { range in
            (range, FindMatcher.replacement(for: range, in: currentText,
                                            query: query, template: replacement,
                                            options: options))
        }
        onBeginUndoGroup?()
        // 从后往前替换，避免前面的替换打乱后面的 offsets
        for (range, expanded) in edits.reversed() {
            onReplace?(range, expanded)
        }
        onEndUndoGroup?()
        search()
    }
}
