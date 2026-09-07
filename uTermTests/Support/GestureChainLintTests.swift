import Foundation
import XCTest

/// 全仓源码 lint：手势链与「选中态盖掉显式颜色」两类形态。
///
/// 纯文本扫描，不建窗、不 import uTerm —— 跑一次 < 100ms，可以放在任何一层跑。
///
/// ## 为什么要 lint 而不是靠 review
///
/// 「双击 + 单击挂在同一条修饰链上」这件事**编译得过、看着也对**，
/// 但 SwiftUI 会为了分辨双击而把单击**延后到双击判定窗口之后**才派发
/// （AppKit 的 `NSEvent.doubleClickInterval`，默认 0.5s）。用户的感受是
/// 「点一下要等半秒才有反应」。这个形态一旦被复制到新的行视图里就会再犯，
/// 而且没有任何编译期信号 —— 只能靠 lint 钉。
///
/// 修法不在本 lint 的职责范围内（通常是把单击换成 `TapGesture` 的
/// `.exclusively(before:)` / `simultaneousGesture`，或干脆把双击语义挪到
/// 别处），lint 只负责让它不能悄悄再长出来。
final class GestureChainLintTests: XCTestCase {

    // MARK: - 已知待修允许清单

    /// **临时清单，合并后清空。**
    ///
    /// 这三个文件（`FileBrowserView` 里两处）在写这条 lint 的同时正被另一位同事
    /// 改掉（单击延迟那一条）。为了不让本分支和那条改动互相挡路，先把它们放行；
    /// 两边合并之后**必须把这个数组清成 `[]`**，否则 lint 等于没开。
    ///
    /// 清单按**文件名**匹配，不是路径 —— 新增同名文件也会被误放行，
    /// 所以它只该短期存在。
    private static let knownPendingFiles: Set<String> = [
        "ServerRow.swift",         // 欢迎页主机行：onTap + onTapGesture(count: 2)
        "FileBrowserView.swift",   // SFTP 文件浏览：两处
        "SFTPFileTable.swift",     // SFTP 表格行
    ]

    // MARK: - 闸门

    func testNoSingleAndDoubleTapOnTheSameModifierChain() throws {
        var offenders: [String] = []
        var waived: [String] = []

        for file in try Self.swiftFiles() {
            let source = try String(contentsOf: file, encoding: .utf8)
            for chain in Self.modifierChains(in: source) {
                guard Self.hasDoubleTap(chain.text), Self.hasSingleTap(chain.text) else { continue }
                let where_ = "\(Self.relative(file)):\(chain.line)"
                if Self.knownPendingFiles.contains(file.lastPathComponent) {
                    waived.append(where_)
                } else {
                    offenders.append(where_)
                }
            }
        }

        if !waived.isEmpty {
            print("[gesture-lint] 已知待修（允许清单放行 \(waived.count) 处，合并后清空清单）：")
            for w in waived { print("[gesture-lint]   - \(w)") }
        }
        for o in offenders { print("[gesture-lint] 命中：\(o)") }

        XCTAssertTrue(offenders.isEmpty, """
            同一条修饰链上既有双击又有单击（\(offenders.count) 处）：
            \(offenders.joined(separator: "\n"))
            SwiftUI 会把单击推迟到双击判定窗口之后才派发（默认 0.5s），
            用户感受就是「点一下半天没反应」。
            要么用 `TapGesture(count: 2).exclusively(before: TapGesture())` 明确优先级，
            要么把双击语义挪走。确实要暂时放行，加进 `knownPendingFiles` 并写清原因。
            """)
    }

    /// 提示性扫描（**只打印，不判红**）：显式颜色被选中态整个盖掉的三元式，
    /// 形如 `selected ? UD.accent : (groupColor ?? UD.text3)` ——
    /// 选中行会丢掉分组彩色 / 状态色这类**信息性**着色，只剩一个 accent。
    /// 有时是设计要的（选中行统一反白），有时是抄行视图时顺手带过来的 bug，
    /// 机器分不出来，所以只列清单给人看，绝不判红。
    ///
    /// 两档：严格档是任务点名的那个形状；宽松档是同一族（同一行里既有
    /// `? UD.<色>` 又有 `??` 兜底）。两档都空也照样打印 0，好让人知道扫过了。
    func testReportSelectionOverridesExplicitColor() throws {
        // 严格：`… ? UD.<色> : (… ?? …)` —— false 支是「显式颜色，没有就退默认」，
        // 被 true 支整个盖掉。
        let strict = try NSRegularExpression(
            pattern: #"\?\s*UD\.[A-Za-z0-9_]+\s*:\s*\(?[^)\n]*\?\?"#)
        // 宽松：同一行里既有 `? UD.<色>` 又有 `??`。
        let loose = try NSRegularExpression(pattern: #"\?\s*UD\.[A-Za-z0-9_]+"#)

        var strictHits: [String] = []
        var looseHits: [String] = []
        for file in try Self.swiftFiles() {
            let source = try String(contentsOf: file, encoding: .utf8)
            for (i, line) in source.components(separatedBy: "\n").enumerated() {
                let range = NSRange(line.startIndex..<line.endIndex, in: line)
                let where_ = "\(Self.relative(file)):\(i + 1)  "
                    + line.trimmingCharacters(in: .whitespaces)
                if strict.firstMatch(in: line, range: range) != nil {
                    strictHits.append(where_)
                } else if line.contains("??"), loose.firstMatch(in: line, range: range) != nil {
                    looseHits.append(where_)
                }
            }
        }

        print("[color-lint] 严格形态 `? UD.x : (… ?? …)`：\(strictHits.count) 处（仅提示）")
        for h in strictHits { print("[color-lint]   - \(h)") }
        print("[color-lint] 同族（同行有 `? UD.x` 且有 `??`）：\(looseHits.count) 处（仅提示）")
        for h in looseHits { print("[color-lint]   - \(h)") }
    }

    // MARK: - 扫描

    private static var repoRoot: URL {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()   // Support
            .deletingLastPathComponent()   // uTermTests
            .deletingLastPathComponent()   // repo
    }

    /// 只留仓库内相对路径。不能用 `repoRoot.path` 前缀相减：`#filePath` 里记的是
    /// 编译时那份路径（`/tmp/…`），而 `FileManager` 枚举出来的是解过符号链接的
    /// `/private/tmp/…`，相减会剩下半截 `/private`。直接从 `/uTerm/` 切。
    private static func relative(_ url: URL) -> String {
        guard let r = url.path.range(of: "/uTerm/") else { return url.path }
        return String(url.path[r.lowerBound...].dropFirst())
    }

    /// `uTerm/` 下的全部 .swift（产品代码；不扫测试、不扫 vendor）。
    private static func swiftFiles() throws -> [URL] {
        let root = repoRoot.appendingPathComponent("uTerm")
        var out: [URL] = []
        guard let e = FileManager.default.enumerator(at: root,
                                                     includingPropertiesForKeys: [.isRegularFileKey]) else {
            return []
        }
        for case let url as URL in e where url.pathExtension == "swift" {
            out.append(url)
        }
        XCTAssertGreaterThan(out.count, 100, "夹具失效：uTerm/ 下应该有上百个 .swift")
        return out.sorted { $0.path < $1.path }
    }

    struct Chain {
        let line: Int      // 1-based，链的第一行
        let text: String
    }

    /// 把源码切成「修饰链」。
    ///
    /// 一条链 = 以某一行的 `.foo` 开头，一直吃到括号 / 花括号都闭合、
    /// 且下一行不再以 `.` 开头为止。多行的修饰体（`.onTapGesture { … }`、
    /// `.contextMenu { … }`）因此会整个留在同一条链里 —— 这正是我们要的
    /// 「同一个视图的修饰链」粒度。
    ///
    /// 粗糙但足够：它宁可把相邻的两条链并成一条（多报），也不会把一条链切开（漏报）。
    static func modifierChains(in source: String) -> [Chain] {
        let lines = source.components(separatedBy: "\n")
        var chains: [Chain] = []
        var i = 0
        while i < lines.count {
            guard lines[i].trimmingCharacters(in: .whitespaces).hasPrefix(".") else {
                i += 1
                continue
            }
            let start = i
            var depth = 0
            var buf = ""
            repeat {
                buf += lines[i] + "\n"
                depth += delta(lines[i])
                i += 1
            } while i < lines.count
                && (depth > 0 || lines[i].trimmingCharacters(in: .whitespaces).hasPrefix("."))
            chains.append(Chain(line: start + 1, text: buf))
        }
        return chains
    }

    /// 一行里「开」比「关」多多少（忽略字符串字面量与行注释里的括号）。
    private static func delta(_ line: String) -> Int {
        var n = 0
        var inString = false
        var escaped = false
        var previous: Character?
        for ch in line {
            if escaped { escaped = false; previous = ch; continue }
            if ch == "\\" && inString { escaped = true; previous = ch; continue }
            if ch == "\"" { inString.toggle(); previous = ch; continue }
            if !inString {
                if ch == "/" && previous == "/" { break }   // 行注释，后面不算
                if ch == "(" || ch == "{" || ch == "[" { n += 1 }
                if ch == ")" || ch == "}" || ch == "]" { n -= 1 }
            }
            previous = ch
        }
        return n
    }

    /// 双击：`.onTapGesture(count: 2)` 或 `TapGesture(count: 2)`
    /// （后者覆盖 `simultaneousGesture(TapGesture(count: 2)…)` / `.gesture(…)`）。
    static func hasDoubleTap(_ text: String) -> Bool {
        let compact = text.replacingOccurrences(of: " ", with: "")
        return compact.contains(".onTapGesture(count:2)") || compact.contains("TapGesture(count:2)")
    }

    /// 单击：`.onTapGesture {` / `.onTapGesture(perform:` / 显式 `count: 1`。
    static func hasSingleTap(_ text: String) -> Bool {
        let compact = text.replacingOccurrences(of: " ", with: "")
        return compact.contains(".onTapGesture{")
            || compact.contains(".onTapGesture(perform:")
            || compact.contains(".onTapGesture(count:1)")
            || compact.contains("TapGesture(count:1)")
    }
}
