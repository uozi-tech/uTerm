import Foundation

/// 用户往上翻着看历史时，视口停在哪里。标签切走（或 App 进后台、surface 被放掉）之前记下，surface 整屏回放之后
/// （回放开头的复位会把视口带回底部）用它找回原处。两端共用。
///
/// 按「内容」找，不按行号：视口里落在回滚区的几行文字记下来，回放后在影子终端的整屏里从原来的行号往上找同样的几行。
/// - 期间来的输出只往底部加行，原来看的那几行行号不变——当场就对上。
/// - 回滚满了、最早的行被挤掉时，那几行整体上移了被挤掉的行数——往上找到的第一处就是。按「距底部的行数」记的话，
///   期间来多少行就错多少行；按行号记，挤掉多少行就错多少行。
/// - 那几行本身也被挤掉了：停在回滚最顶上（离原处最近的内容）。网格宽度变了（折行不同，文字对不上）时退回原行号。
///
/// 活动区（屏幕底部那一屏）的行不拿来比：程序会改写它们，回放时可能已经不是当时的样子。
nonisolated struct TerminalViewportMark: Sendable, Equatable {
    /// 视口首行在整屏（含回滚）里的行号（0 = 回滚最早的一行），即引擎滚动条的 `offset`。
    let offset: Int
    /// 一屏几行、整屏一共几行（记下时）。
    let rows: Int
    let total: Int
    /// 往上最多找这么多行（每行一次读影子；回滚设得很大时不至于卡太久）。
    static let searchLimit = 50_000
    /// 记下时的列数：宽度变了，折行就变了，文字比不上。
    let columns: Int
    /// 视口里落在回滚区的那几行文字，自上而下，行尾空白已去掉。
    let anchor: [String]

    /// 按引擎的滚动条和 surface 读到的视口文字（一行一段）记一个位置。在底部（跟随输出）或者量不到时返回 nil：
    /// 回放后本来就在底部，不用动。
    static func capture(offset: Int, rows: Int, total: Int, columns: Int, viewportText: String?) -> TerminalViewportMark? {
        guard rows > 0, total > 0, offset >= 0, offset + rows < total else { return nil }
        let historyRows = total - rows
        let lines = (viewportText ?? "").components(separatedBy: "\n")
        let count = min(rows, historyRows - offset, lines.count)
        let anchor = lines.prefix(max(0, count)).map(Self.trimmed)
        return TerminalViewportMark(offset: offset, rows: rows, total: total, columns: columns, anchor: Array(anchor))
    }

    /// 回放之后视口该滚到第几行（`scroll_to_row`）。返回 nil = 留在底部（原处已经落进了活动区）。
    /// `rowText`：整屏第几行的文字（影子终端的 `screenRowText`）；`totalRows` / `rows` / `columns`：现在的整屏行数、一屏行数、列数。
    func targetRow(totalRows: Int, rows: Int, columns: Int, rowText: (Int) -> String?) -> Int? {
        let maxTop = totalRows - rows
        guard maxTop > 0 else { return nil }
        let anchorHasText = anchor.contains { !$0.isEmpty }
        if anchorHasText, columns == self.columns {
            var row = min(offset, maxTop)
            let lowest = max(0, row - Self.searchLimit)
            while row >= lowest {
                if matches(at: row, rowText: rowText) { return clamp(row, maxTop: maxTop) }
                row -= 1
            }
            // 原来看的那几行已经被挤出回滚：停在最顶上。
            return 0
        }
        return clamp(offset, maxTop: maxTop)
    }

    private func matches(at row: Int, rowText: (Int) -> String?) -> Bool {
        for (index, line) in anchor.enumerated() {
            guard let text = rowText(row + index), Self.trimmed(text) == line else { return false }
        }
        return true
    }

    private static func trimmed(_ line: String) -> String {
        var end = line.endIndex
        while end > line.startIndex, line[line.index(before: end)].isWhitespace { end = line.index(before: end) }
        return String(line[..<end])
    }

    private func clamp(_ row: Int, maxTop: Int) -> Int? {
        row >= maxTop ? nil : max(0, row)
    }
}
