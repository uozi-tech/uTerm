import Foundation
@testable import uTerm

/// 假主机上的「Claude 历史会话」搜索命令：把 `ClaudeSearchCommand` 生成的命令解回来（`decode`），照它的意思在内存里的
/// 文件上现算输出——第一段同 `LC_ALL=C grep -l -i -F`，第二段逐行报 `<第几个文件> <偏移> <长度>`，带同样的行过滤。
/// 真的命令在真 shell / 真 sshd 的用例里核（`ClaudeHistorySearchShellTests`、`ClaudeHistoryLiveSSHTests`），这里只给
/// 界面、模型的用例与画廊一个会答话的主机。iOS 测试里有同样的一份（两个测试 target 不共用源码）。
enum ClaudeSearchHostEmulator {
    static func respond(to command: String, read: (String) async -> Data?) async -> String {
        guard let request = ClaudeSearchCommand.decode(command) else { return "sh: unsupported command\n" }
        var output = ClaudeSearchCommand.beginMarker + "\n"
        switch request {
        case .files(let needle, let root, let names):
            var any = false
            for name in names {
                guard let data = await read(path(root, name)), contains(Array(data), Array(needle.utf8)) else { continue }
                output += name + "\n"
                any = true
            }
            output += "\(ClaudeSearchCommand.endMarker) \(any ? 0 : 1)\n"
        case .lines(let needle, let root, let maxLines, let maxLineBytes, let names):
            for (index, name) in names.enumerated() {
                guard let data = await read(path(root, name)) else { continue }
                var offset = 0
                var found = 0
                for line in Array(data).split(separator: 0x0A, omittingEmptySubsequences: false) {
                    let start = offset
                    offset += line.count + 1
                    guard start < data.count, line.count <= maxLineBytes, isCandidate(Array(line)),
                          contains(Array(line), Array(needle.utf8)) else { continue }
                    output += "\(index + 1) \(start) \(line.count)\n"
                    found += 1
                    if found >= maxLines { break }
                }
            }
            output += "\(ClaudeSearchCommand.endMarker) 0\n"
        }
        return output
    }

    private static func path(_ root: String, _ name: String) -> String {
        root + "/" + (name.hasPrefix("./") ? String(name.dropFirst(2)) : name)
    }

    /// 同 `linesScript` 里 awk 的行过滤。
    private static func isCandidate(_ line: [UInt8]) -> Bool {
        let text = String(decoding: line, as: UTF8.self)
        let head = String(decoding: line.prefix(1024), as: UTF8.self)
        if head.hasPrefix(#"{"type":""#) {
            let rest = head.dropFirst(9)
            guard rest.hasPrefix(#"user""#) || rest.hasPrefix(#"assistant""#) else { return false }
        } else if ![#""type":"user""#, #""type":"assistant""#, #""role":"user""#, #""role":"assistant""#]
            .contains(where: head.contains) {
            return false
        }
        if text.contains(#""isSidechain":true"#) || text.contains(#""isMeta":true"#) || text.contains(#""isCompactSummary":true"#) {
            return false
        }
        if !text.contains(#""type":"text""#) {
            if text.contains(#""type":"tool_result""#) { return false }
            if text.contains(#""type":"thinking""#), !text.contains(#""type":"tool_use""#) { return false }
        }
        return true
    }

    /// 只折叠 ASCII 字母的大小写（同 `LC_ALL=C` 的 `grep -i` / awk 的 `tolower`）。
    static func contains(_ haystack: [UInt8], _ needle: [UInt8]) -> Bool {
        func fold(_ byte: UInt8) -> UInt8 { (0x41...0x5A).contains(byte) ? byte + 0x20 : byte }
        let needle = needle.map(fold)
        guard !needle.isEmpty, haystack.count >= needle.count else { return needle.isEmpty }
        for start in 0...(haystack.count - needle.count) {
            var index = 0
            while index < needle.count, fold(haystack[start + index]) == needle[index] { index += 1 }
            if index == needle.count { return true }
        }
        return false
    }
}

extension MockSFTP {
    /// 让这个替身像一台能跑搜索命令的主机那样答 `exec`。
    func answersClaudeSearch() {
        setExecHandler { [weak self] command in
            await ClaudeSearchHostEmulator.respond(to: command) { path in await self?.fileData(path) }
        }
    }
}
