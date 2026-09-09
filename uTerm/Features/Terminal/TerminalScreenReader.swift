import Foundation

/// 终端读屏的**纯函数**层：只吃「已经渲染成文本的行数组」，不碰 SwiftTerm、不碰 AppKit，
/// 因此可以脱离窗口与运行时单测（`TerminalScreenReaderTests`）。
///
/// 取行那一半（越界探测反推缓冲区末行 + `translateToString`）在
/// `TerminalSession.snapshotScreen(lines:maxBytes:)` 里 —— 它必须在 MainActor 上跑，
/// 这里则完全无隔离。两处的分界就是「谁需要 SwiftTerm」。
///
/// 裁剪顺序是有讲究的，不要随手换：
/// 1. **先**去掉尾部连续空行 —— 光标常停在半屏，尾部整屏空白会把 `maxLines` 白白吃光；
/// 2. 再取尾部 `maxLines` 行；
/// 3. 最后按 UTF-8 字节从尾部往前收口，总字节（含行间换行符）不超过 `maxBytes`。
nonisolated enum TerminalScreenReader {

    /// 裁剪结果。`truncated == true` 表示**上面还有内容没给出**（被行数或字节上限削掉），
    /// 与 `ControlScreenSnapshot.truncated` 同义。
    struct Result: Equatable, Sendable {
        var lines: [String]
        var truncated: Bool

        init(lines: [String], truncated: Bool) {
            self.lines = lines
            self.truncated = truncated
        }
    }

    /// 把整段行数组裁成「最近 `maxLines` 行、总计不超过 `maxBytes` 字节」。
    ///
    /// - Parameters:
    ///   - lines: 从旧到新的行文本（右侧空白应已由调用方 `trimRight` 掉）。
    ///   - maxLines: 最多返回多少行；`<= 0` 返回空。
    ///   - maxBytes: UTF-8 字节上限，含每行之后的一个换行符；`<= 0` 返回空。
    static func trim(lines: [String], maxLines: Int, maxBytes: Int) -> Result {
        guard maxLines > 0, maxBytes > 0 else {
            return Result(lines: [], truncated: !lines.isEmpty)
        }

        // 1. 去掉尾部连续空行（不算截断 —— 那本来就是没有内容的屏幕空白）。
        var body = lines
        while let last = body.last, last.isEmpty { body.removeLast() }
        guard !body.isEmpty else { return Result(lines: [], truncated: false) }

        // 2. 取尾部 maxLines 行。
        var truncated = false
        if body.count > maxLines {
            body.removeFirst(body.count - maxLines)
            truncated = true
        }

        // 3. 字节收口：从最新一行往回收，装不下就停（并标截断）。
        var budget = maxBytes
        var kept: [String] = []
        kept.reserveCapacity(body.count)
        for line in body.reversed() {
            let cost = line.utf8.count + 1  // +1 = 行间换行符
            if cost <= budget {
                budget -= cost
                kept.append(line)
                continue
            }
            // 一行都装不下：只有在还没收到任何行时才切半行，否则整行丢弃并收工。
            // （切半行是为了「最后一行是一条超长日志」时仍能返回点东西。）
            if kept.isEmpty, budget > 1 {
                kept.append(utf8Prefix(line, maxBytes: budget - 1))
            }
            truncated = true
            break
        }

        return Result(lines: kept.reversed(), truncated: truncated)
    }

    /// 按 UTF-8 字节数截断字符串，且**不切碎字素簇** —— 逐个 `Character` 累加，
    /// 避免 `Data` 前缀切法产生 U+FFFD 替换符（CJK / emoji 一刀两断）。
    static func utf8Prefix(_ text: String, maxBytes: Int) -> String {
        guard maxBytes > 0 else { return "" }
        guard text.utf8.count > maxBytes else { return text }
        var out = ""
        var used = 0
        for character in text {
            let cost = String(character).utf8.count
            if used + cost > maxBytes { break }
            used += cost
            out.append(character)
        }
        return out
    }
}
