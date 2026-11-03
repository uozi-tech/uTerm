//
//  TerminalSnapshot.swift
//  SwiftTerm (uTerm vendored patch — see UTERM-PATCHES.md)
//
//  Serializes a terminal's state into a VT byte sequence: feeding it to a fresh
//  terminal of the same size reproduces the same screen cell-for-cell, plus the
//  scrollback, the screen under an alternate-screen app, and every mode that
//  affects how later bytes render or how input is encoded. uTerm uses it to
//  attach a mirror (another device) to a live session: send the snapshot, then
//  tee the raw byte stream that follows.
//
//  Lives inside the module because most of that state is internal (and three
//  fields had to be relaxed from `private`; see UTERM-PATCHES.md).
//
//  Every rule in `writeLines` / `restoreState` came out of a failing
//  cut-point in `TerminalSnapshotTests` — read the comment before simplifying.
//
import Foundation

extension Terminal {

    /// True when a snapshot taken now can be followed by the next raw bytes:
    /// the parser is in the ground state (not inside an escape sequence) and no
    /// partial UTF-8 character is held over from the previous `feed`.
    /// Bytes after a cut taken anywhere else would be misparsed by the mirror.
    public var isAtSnapshotBoundary: Bool {
        parser.currentState == .ground && readingBuffer.putbackBuffer.isEmpty
    }

    /// Replays the current state as a VT byte sequence (starts with RIS).
    ///
    /// - Parameter scrollbackLimit: how many history lines of the normal buffer
    ///   to include. The receiver must have at least this much scrollback.
    /// - Precondition: `isAtSnapshotBoundary` (otherwise the bytes that follow
    ///   the snapshot will not line up).
    public func snapshotSequence(scrollbackLimit: Int = 1000) -> [UInt8] {
        var out = SnapshotWriter()
        out.raw("\u{1b}c")
        if isCurrentBufferAlternate {
            writeLines(normalBuffer, includeScrollback: true, scrollbackLimit: scrollbackLimit, &out)
            writeTabStops(normalBuffer, &out)
            out.cup(normalBuffer.y, normalBuffer.x)
            out.raw("\u{1b}[?1049h\u{1b}[H")
            writeLines(altBuffer, includeScrollback: false, scrollbackLimit: 0, &out)
        } else {
            // The inactive alternate buffer keeps its own tab stops, and RIS
            // does not reset them: a terminal created wider than 80 columns
            // starts with alternate-buffer stops only up to column 72. The
            // receiver may be such a terminal, so always set them explicitly,
            // visiting the buffer with 1047 (no cursor save, cleared on exit).
            // 1047 does not save the cursor: home it again on the way back,
            // or the first line starts where the last tab stop was set.
            out.raw("\u{1b}[?1047h")
            writeTabStops(altBuffer, &out)
            out.raw("\u{1b}[?1047l\u{1b}[H")
            writeLines(normalBuffer, includeScrollback: true, scrollbackLimit: scrollbackLimit, &out)
        }
        restoreState(&out)
        return out.bytes
    }

    // MARK: - Content

    private func writeLines(_ b: Buffer, includeScrollback: Bool, scrollbackLimit: Int,
                            _ out: inout SnapshotWriter) {
        let lines = b.lines
        let screenStart = b.yBase
        let first = includeScrollback ? max(0, screenStart - scrollbackLimit) : screenStart
        let last = min(lines.count, screenStart + rows)
        out.attr = CharData.defaultAttr
        out.raw("\u{1b}[0m")
        // First line is a continuation of one that already scrolled away (the
        // alternate screen keeps no history): pad a full-width line so it wraps
        // naturally. Writing every row afterwards scrolls the pad off screen.
        if !includeScrollback && first < last && lines[first].isWrapped {
            out.raw(String(repeating: " ", count: cols))
        }
        for i in first..<last {
            let line = lines[i]
            if i > first && !line.isWrapped {
                // Reset the pen before the newline: a newline at the bottom
                // scrolls, and the new line is filled with the current
                // background (BCE), dragging the previous cell's color along.
                out.setAttr(CharData.defaultAttr)
                out.raw("\r\n")
            }
            let nextWrapped = i + 1 < last && lines[i + 1].isWrapped
            writeCells(line, nextWrapped: nextWrapped, continuesPrevious: i > first && line.isWrapped, &out)
        }
    }

    /// - Parameter continuesPrevious: this line is the wrapped continuation of
    ///   the one just written, so the cursor sits in the pending-wrap state and
    ///   only a printed character makes the wrap happen. Cursor movement (CUF)
    ///   does not, so a continuation that starts blank, or is blank altogether
    ///   (zsh's PROMPT_SP filler after a narrowing reflow), must still print
    ///   its first cell, or the line is lost and everything below shifts up.
    private func writeCells(_ line: BufferLine, nextWrapped: Bool, continuesPrevious: Bool,
                            _ out: inout SnapshotWriter) {
        // An orphan is the right half of a wide character whose left half got
        // overwritten: width 0, not preceded by a wide cell. The renderer paints
        // it on its own (inverted default background), so it has to be
        // reproduced, and the only way is to replay how it was made.
        func isOrphan(_ c: Int) -> Bool {
            c > 0 && c < line.count && line[c].width == 0 && line[c].code == 0
                && line[c - 1].width != 2 && !(c == cols - 1 && nextWrapped)
        }
        let end = nextWrapped ? cols : max(contentEnd(line), continuesPrevious ? 1 : 0)
        var col = 0
        while col < end {
            let cell = line[col]
            if isOrphan(col) {
                out.raw("\u{1b}[C")
                col += 1
                continue
            }
            // Right half of a wide character: written with it.
            if cell.width == 0 && col > 0 && line[col - 1].width == 2 {
                col += 1
                continue
            }
            // Placeholder left when a wide character did not fit in the last
            // column: let the next line's wide character wrap the same way.
            if cell.width == 0 && cell.code == 0 && col == cols - 1 && nextWrapped {
                col += 1
                continue
            }
            let width = max(1, Int(cell.width))
            if isOrphan(col + width) {
                // Put a wide character where the orphan's lost left half was,
                // then come back and overwrite that half with this cell.
                out.setAttr(CharData.defaultAttr)
                out.raw("\u{1b}[\(col + width)G\u{4E2D}\u{1b}[\(col + 1)G")
                out.writeCell(cell, self)
                col += width
                continue
            }
            if col == 0 && continuesPrevious && cell.code == 0 && cell.attribute == CharData.defaultAttr {
                out.setAttr(CharData.defaultAttr)
                out.raw(" ")
                col += 1
                continue
            }
            if cell.code == 0 && cell.attribute == CharData.defaultAttr {
                var run = 1
                while col + run < end, line[col + run].code == 0,
                      line[col + run].attribute == CharData.defaultAttr {
                    run += 1
                }
                if nextWrapped && col + run == cols {
                    // The next line continues this one: the row must really be
                    // filled so the cursor enters the pending-wrap state. CUF
                    // stops at the last column and never gets there.
                    out.setAttr(CharData.defaultAttr)
                    out.raw(String(repeating: " ", count: run))
                } else {
                    // Skip empty cells instead of writing spaces, keeping them empty.
                    out.raw("\u{1b}[\(run)C")
                }
                col += run
                continue
            }
            out.writeCell(cell, self)
            col += width
        }
    }

    /// Column after the last visible cell: one with a character, or with a
    /// non-default attribute (a colored blank).
    private func contentEnd(_ line: BufferLine) -> Int {
        var end = min(cols, line.count)
        while end > 0 {
            let cell = line[end - 1]
            if cell.code != 0 && cell.code != 32 { break }
            if cell.attribute != CharData.defaultAttr { break }
            end -= 1
        }
        return end
    }

    /// Tab stops belong to each buffer; leaving an alternate-screen app
    /// switches back to the normal buffer's set. Written unconditionally: the
    /// receiver's own stops are not necessarily the defaults (see above).
    private func writeTabStops(_ b: Buffer, _ out: inout SnapshotWriter) {
        out.raw("\u{1b}[3g")
        for (index, isStop) in b.tabStops.enumerated() where isStop && index < cols {
            out.cup(0, index)
            out.raw("\u{1b}H")
        }
    }

    // MARK: - State

    private func restoreState(_ out: inout SnapshotWriter) {
        let b = buffer
        writeTabStops(b, &out)
        if b.scrollTop != 0 || b.scrollBottom != rows - 1 {
            out.raw("\u{1b}[\(b.scrollTop + 1);\(b.scrollBottom + 1)r")
        }
        // DECSLRM only parses while DECLRMM is on (otherwise CSI s is "save
        // cursor"), so switch it on to set non-default margins, then put it back.
        let customMargins = b.marginLeft != 0 || b.marginRight != cols - 1
        if marginMode || customMargins {
            out.raw("\u{1b}[?69h")
            if customMargins {
                out.raw("\u{1b}[\(b.marginLeft + 1);\(b.marginRight + 1)s")
            }
            if !marginMode {
                out.raw("\u{1b}[?69l")
            }
        }
        let savedX = min(max(0, b.savedX), cols - 1), savedY = min(max(0, b.savedY), rows - 1)
        if savedX != 0 || savedY != 0 || b.savedAttr != CharData.defaultAttr {
            out.cup(savedY, savedX)
            out.setAttr(b.savedAttr, force: true)
            out.raw("\u{1b}7")
        }
        writeModes(&out)

        // x == cols is the pending-wrap state, which CUP cannot express:
        // rewrite the cell at the end of the row to get there. If the last two
        // columns hold a wide character, rewrite all of it — rewriting only the
        // last column would turn its right half into a plain space.
        let originShift = originMode ? b.scrollTop : 0
        if b.x >= cols {
            let line = b.lines[b.yBase + b.y]
            let lastCol = (line[cols - 1].width == 0 && line[cols - 2].width == 2) ? cols - 2 : cols - 1
            out.cup(b.y - originShift, lastCol)
            out.writeCell(line[lastCol], self)
        } else {
            out.cup(b.y - originShift, b.x)
        }
        out.setAttr(currentAttribute, force: true)

        // Character sets last: everything above was written as final glyphs,
        // and a designation in effect would remap the ASCII among them.
        for (slot, set) in gCharsets.enumerated() {
            let initial = slot == 0 ? CharSets.defaultCharset : nil
            guard set != initial else { continue }
            let designator = set.flatMap { set in CharSets.all.first { $0.value == set }?.key } ?? UInt8(ascii: "B")
            out.bytes += [0x1b, [0x28, 0x29, 0x2a, 0x2b][slot], designator]
        }
        if gLevel == 1 {
            out.bytes.append(0x0e)
        }
    }

    private func writeModes(_ out: inout SnapshotWriter) {
        if applicationCursor { out.raw("\u{1b}[?1h") }
        if bracketedPasteMode { out.raw("\u{1b}[?2004h") }
        switch mouseMode {
        case .off: break
        case .x10: out.raw("\u{1b}[?9h")
        case .vt200: out.raw("\u{1b}[?1000h")
        case .buttonEventTracking: out.raw("\u{1b}[?1002h")
        case .anyEvent: out.raw("\u{1b}[?1003h")
        }
        switch mouseProtocol {
        case .x10: break
        case .utf8: out.raw("\u{1b}[?1005h")
        case .sgr: out.raw("\u{1b}[?1006h")
        case .urxvt: out.raw("\u{1b}[?1015h")
        case .sgrPixel: out.raw("\u{1b}[?1016h")
        }
        let cursorStyles: [CursorStyle: Int] = [.blinkBlock: 1, .steadyBlock: 2, .blinkUnderline: 3,
                                                .steadyUnderline: 4, .blinkBar: 5, .steadyBar: 6]
        if options.cursorStyle != TerminalOptions.default.cursorStyle, let n = cursorStyles[options.cursorStyle] {
            out.raw("\u{1b}[\(n) q")
        }
        // Only the active entry of the kitty keyboard stack is restored, not its depth.
        if keyboardEnhancementFlags.rawValue != 0 { out.raw("\u{1b}[=\(keyboardEnhancementFlags.rawValue);1u") }
        if cursorHidden { out.raw("\u{1b}[?25l") }
        if applicationKeypad { out.raw("\u{1b}=") }
        if insertMode { out.raw("\u{1b}[4h") }
        if !wraparound { out.raw("\u{1b}[?7l") }
        if reverseWraparound { out.raw("\u{1b}[?45h") }
        if lineFeedMode { out.raw("\u{1b}[20h") }
        if sendFocus { out.raw("\u{1b}[?1004h") }
        if !terminalTitle.isEmpty { out.raw("\u{1b}]2;\(terminalTitle)\u{7}") }
        if originMode { out.raw("\u{1b}[?6h") }
        if synchronizedOutputActive { out.raw("\u{1b}[?2026h") }
    }

    // MARK: - Fingerprint

    /// Everything a snapshot must reproduce, as comparable strings: each cell
    /// (character, width, colors, style, underline), wrap flags, cursor, pen,
    /// margins, saved cursor, every mode, tab stops, character sets, the screen
    /// under an alternate-screen app, and the last `historyLines` of history.
    /// The reference that `TerminalSnapshotTests` compares against.
    public func snapshotFingerprint(historyLines: Int = 1000) -> TerminalSnapshotFingerprint {
        let b = buffer
        var categories: [String: [String]] = [:]
        categories["screen"] = screenRows(b)
        categories["cursor"] = ["\(b.x),\(b.y)"]
        categories["pen"] = [Self.attributeKey(currentAttribute)]
        categories["margins"] = ["\(b.scrollTop)-\(b.scrollBottom)", "\(b.marginLeft)-\(b.marginRight)"]
        // As DECRC sees it: the saved position can go out of range after a
        // resize (upstream adjusts savedY without a lower bound), and DECRC
        // clamps it, so the clamped value is what can be observed.
        let savedX = min(max(0, b.savedX), cols - 1), savedY = min(max(0, b.savedY), rows - 1)
        categories["savedCursor"] = ["\(savedX),\(savedY),\(Self.attributeKey(b.savedAttr))"]
        categories["modes"] = [
            "alternate=\(isCurrentBufferAlternate)", "applicationCursor=\(applicationCursor)",
            "bracketedPaste=\(bracketedPasteMode)", "mouseMode=\(mouseMode)", "mouseProtocol=\(mouseProtocol)",
            "cursorStyle=\(options.cursorStyle)", "kittyFlags=\(keyboardEnhancementFlags.rawValue)",
            "cursorHidden=\(cursorHidden)", "applicationKeypad=\(applicationKeypad)", "insert=\(insertMode)",
            "wraparound=\(wraparound)", "reverseWraparound=\(reverseWraparound)", "lineFeed=\(lineFeedMode)",
            "sendFocus=\(sendFocus)", "origin=\(originMode)", "marginMode=\(marginMode)",
            "title=\(terminalTitle)", "synchronizedOutput=\(synchronizedOutputActive)",
        ]
        categories["tabStops"] = [tabStopsKey(normalBuffer), tabStopsKey(altBuffer)]
        categories["charsets"] = gCharsets.map { set in String(describing: set?.sorted { $0.key < $1.key }) } + ["level=\(gLevel)"]
        if isCurrentBufferAlternate {
            categories["normalScreen"] = screenRows(normalBuffer)
            categories["normalCursor"] = ["\(normalBuffer.x),\(normalBuffer.y)"]
        }
        let history = (0..<normalBuffer.yBase).map { encodeLine(normalBuffer.lines[$0]) }
        categories["history"] = Array(history.suffix(historyLines))
        return TerminalSnapshotFingerprint(categories: categories)
    }

    private func screenRows(_ b: Buffer) -> [String] {
        (0..<rows).map { encodeLine(b.lines[b.yBase + $0]) }
    }

    private func encodeLine(_ line: BufferLine) -> String {
        var s = line.isWrapped ? "W|" : "-|"
        for c in 0..<min(cols, line.count) {
            let cell = line[c]
            // An empty cell and a space look the same; do not tell them apart.
            let ch = (cell.code == 0 || cell.code == 32) ? " " : String(getCharacter(for: cell))
            s += "\(ch)\u{1}\(cell.width)\u{1}\(Self.attributeKey(cell.attribute))\u{2}"
        }
        return s
    }

    private static func attributeKey(_ a: Attribute) -> String {
        "\(a.fg)/\(a.bg)/\(a.style.rawValue)/\(a.underlineStyle.rawValue)/\(String(describing: a.underlineColor))"
    }

    /// Only where the stops are within the visible width; the backing array's
    /// length is an implementation detail that does not change where a tab lands.
    private func tabStopsKey(_ b: Buffer) -> String {
        b.tabStops.indices.filter { $0 < cols && b.tabStops[$0] }.map(String.init).joined(separator: ",")
    }
}

/// See `Terminal.snapshotFingerprint(historyLines:)`.
public struct TerminalSnapshotFingerprint: Equatable {
    public let categories: [String: [String]]

    /// Categories that differ, each with a readable description of the first difference.
    public func differences(from other: TerminalSnapshotFingerprint) -> [String: String] {
        var result: [String: String] = [:]
        for key in Set(categories.keys).union(other.categories.keys) {
            let mine = categories[key] ?? [], theirs = other.categories[key] ?? []
            guard mine != theirs else { continue }
            if mine.count != theirs.count {
                result[key] = "entry count \(mine.count) vs \(theirs.count)"
                continue
            }
            for (index, (a, b)) in zip(mine, theirs).enumerated() where a != b {
                result[key] = "#\(index): \(Self.readable(a)) ≠ \(Self.readable(b))"
                break
            }
        }
        return result
    }

    private static func readable(_ entry: String) -> String {
        guard entry.contains("\u{2}") else { return entry }
        let cells = entry.dropFirst(2).split(separator: "\u{2}")
        let text = cells.map { $0.split(separator: "\u{1}").first.map(String.init) ?? "" }.joined()
        return "\(entry.prefix(1))\(text.prefix(80))"
    }
}

/// Accumulates the snapshot bytes and tracks the pen so SGR is only emitted on change.
struct SnapshotWriter {
    var bytes: [UInt8] = []
    var attr = CharData.defaultAttr

    mutating func raw(_ s: String) {
        bytes.append(contentsOf: Array(s.utf8))
    }

    mutating func cup(_ y: Int, _ x: Int) {
        raw("\u{1b}[\(y + 1);\(x + 1)H")
    }

    mutating func writeCell(_ cell: CharData, _ terminal: Terminal) {
        setAttr(cell.attribute)
        raw(cell.code == 0 ? " " : String(terminal.getCharacter(for: cell)))
    }

    mutating func setAttr(_ a: Attribute, force: Bool = false) {
        guard force || a != attr else { return }
        attr = a
        raw(Self.sgr(a))
    }

    static func sgr(_ a: Attribute) -> String {
        var params = ["0"]
        let s = a.style
        if s.contains(.bold) { params.append("1") }
        if s.contains(.dim) { params.append("2") }
        if s.contains(.italic) { params.append("3") }
        if s.contains(.underline) {
            switch a.underlineStyle {
            case .none, .single: params.append("4")
            case .double: params.append("4:2")
            case .curly: params.append("4:3")
            case .dotted: params.append("4:4")
            case .dashed: params.append("4:5")
            }
        }
        if s.contains(.blink) { params.append("5") }
        if s.contains(.inverse) { params.append("7") }
        if s.contains(.invisible) { params.append("8") }
        if s.contains(.crossedOut) { params.append("9") }
        if let c = color(a.fg, 38) { params.append(c) }
        if let c = color(a.bg, 48) { params.append(c) }
        if let u = a.underlineColor, let c = color(u, 58) { params.append(c) }
        return "\u{1b}[" + params.joined(separator: ";") + "m"
    }

    private static func color(_ c: Attribute.Color, _ base: Int) -> String? {
        switch c {
        case .ansi256(let n): return "\(base);5;\(n)"
        case .trueColor(let r, let g, let b): return "\(base);2;\(r);\(g);\(b)"
        case .defaultColor, .defaultInvertedColor: return nil
        }
    }
}
