import Foundation

/// 在主机上跑的命令：一批记录的开头字段（列表用）、搜索的两段。只用 `sh`、`printf`、`head`、`grep`、`awk`，压缩过的
/// 记录再加 `zstd`（主机上没有就不碰那些记录，输出里带一行 `nozstdMarker`）。只读，不建任何文件。
///
/// 拼命令、编码参数（防注入，各种登录 shell 都只看到同一串字节）、开始 / 结束标记、读输出，全用
/// `ClaudeSearchCommand` 那一套（标记行也是同一个），这里只有脚本本身。
nonisolated enum CodexHostCommand {
    /// 主机上没有 `zstd`：压缩过的记录这一轮没读 / 没搜。
    static let nozstdMarker = "uterm-codex:nozstd"
    /// 一份记录开头最多读这么多（`session_meta` 里要的字段都在前 1110 字节里）。
    static let headerBytes = 4096

    // MARK: 列表：开头字段

    /// `$2` 记录根目录，之后是相对根目录的文件。每份回一行：
    /// `<第几个>\t<id>\t<cwd>\t<originator>\t<source>\t<thread_source>\t<parent_thread_id>\t<agent_path>\t<forked_from_id>`
    /// （值是 JSON 字符串引号里的原样，转义没解；JSON 里的制表符一定是转义过的，所以拿它分隔不会错位）。
    /// `source` 是对象时写 `{thread_spawn` 或 `{subagent`。读不了 / 不是 `session_meta` 回 `<第几个> -`，
    /// 压缩过的而主机上没有 `zstd` 回 `<第几个> ?`。
    static let headersScript = #"""
        exec 2>/dev/null
        LC_ALL=C; export LC_ALL
        echo uterm-claude-search:begin
        cd "$(printf %b "$2")" || { echo "uterm-claude-search:end 200"; exit 0; }
        shift 2
        if command -v zstd >/dev/null 2>&1; then Z=1; else Z=0; echo uterm-codex:nozstd; fi
        I=0
        for a; do
          case $a in *\\*) a=$(printf %b "$a");; esac
          I=$((I + 1))
          printf '\n@@uterm %d\n' "$I"
          case $a in
            *.zst) if [ $Z = 1 ]; then zstd -dcq -- "$a" | head -c 4096; else printf '?'; fi ;;
            *) head -c 4096 -- "$a" ;;
          esac
        done | awk '
        function f(k,   p, i, c, n, v) {
          p = index(h, "\"" k "\":\"")
          if (p == 0) return ""
          i = p + length(k) + 4; n = length(h); v = ""
          while (i <= n) {
            c = substr(h, i, 1)
            if (c == "\\") { v = v substr(h, i, 2); i += 2; continue }
            if (c == "\"") return v
            v = v c; i++
          }
          return ""
        }
        /^@@uterm [0-9]+$/ { if (w) print i " -"; i = substr($0, 9) + 0; w = 1; next }
        !w { next }
        {
          w = 0
          if ($0 == "?") { print i " ?"; next }
          h = $0
          b = index(h, "\"base_instructions\"")
          if (b > 0) h = substr(h, 1, b - 1)
          if (index(h, "\"type\":\"session_meta\"") == 0) { print i " -"; next }
          s = f("source")
          if (s == "" && index(h, "\"source\":{")) { if (index(h, "\"thread_spawn\":")) s = "{thread_spawn"; else s = "{subagent" }
          print i "\t" f("id") "\t" f("cwd") "\t" f("originator") "\t" s "\t" f("thread_source") "\t" f("parent_thread_id") "\t" f("agent_path") "\t" f("forked_from_id")
        }
        END { if (w) print i " -" }'
        echo "uterm-claude-search:end 0"
        exit 0
        """#

    static func headers(root: String, names: [String]) -> String {
        ClaudeSearchCommand.command(script: headersScript, arguments: [root] + names)
    }

    /// 一行回报 → (第几个, 开头字段)。`header == nil` 是主机上读不了（`-`）或没有 `zstd`（`missingZstd`）。
    nonisolated struct HeaderLine: Equatable, Sendable {
        let index: Int
        let header: CodexSessionHeader?
        let missingZstd: Bool
    }

    static func headerLines(_ lines: [Substring]) -> [HeaderLine] {
        lines.compactMap { line -> HeaderLine? in
            if !line.contains("\t"), line.hasSuffix(" ?") || line.hasSuffix(" -"), let index = Int(line.dropLast(2)) {
                return HeaderLine(index: index, header: nil, missingZstd: line.hasSuffix(" ?"))
            }
            let fields = line.split(separator: "\t", omittingEmptySubsequences: false).map(String.init)
            guard fields.count >= 9, let index = Int(fields[0]), let id = decode(fields[1]), !id.isEmpty else { return nil }
            func value(_ index: Int) -> String? { decode(fields[index]).flatMap { $0.isEmpty ? nil : $0 } }
            let source: CodexSessionHeader.Source
            switch fields[4] {
            case "": source = .unknown
            case "{thread_spawn": source = .threadSpawn
            case "{subagent": source = .otherSubagent
            default: source = value(4).map(CodexSessionHeader.Source.named) ?? .unknown
            }
            return HeaderLine(index: index, header: CodexSessionHeader(
                id: id, cwd: value(2), originator: value(3), source: source, threadSource: value(5),
                parentThreadID: value(6), agentPath: value(7), forkedFromID: value(8)), missingZstd: false)
        }
    }

    /// JSON 字符串引号里的原样 → 字符串。
    private static func decode(_ raw: String) -> String? {
        guard raw.contains("\\") else { return raw }
        return (try? JSONSerialization.jsonObject(with: Data(("\"" + raw + "\"").utf8), options: [.fragmentsAllowed])) as? String
    }

    // MARK: 搜索第一段：哪些文件里有这串字

    /// `$2` 搜索串，`$3` 记录根目录，之后是文件。回：每行一个有这串字的文件名。压缩过的解开了找。
    static let filesScript = #"""
        exec 2>/dev/null
        LC_ALL=C; export LC_ALL
        t=$(printf %b "$2")
        echo uterm-claude-search:begin
        cd "$(printf %b "$3")" || { echo "uterm-claude-search:end 200"; exit 0; }
        shift 3
        if command -v zstd >/dev/null 2>&1; then Z=1; else Z=0; echo uterm-codex:nozstd; fi
        r=0
        for a; do
          case $a in *\\*) a=$(printf %b "$a");; esac
          case $a in
            *.zst) if [ $Z = 1 ]; then zstd -dcq -- "$a" | grep -q -i -F -e "$t" && printf '%s\n' "$a"; fi ;;
            *) grep -q -s -i -F -e "$t" -- "$a"; c=$?
               case $c in 0) printf '%s\n' "$a";; 1) ;; *) r=$c;; esac ;;
          esac
        done
        echo "uterm-claude-search:end $r"
        exit 0
        """#

    static func filesContaining(_ needle: String, root: String, names: [String]) -> String {
        ClaudeSearchCommand.command(script: filesScript, arguments: [needle, root] + names)
    }

    // MARK: 搜索第二段：命中行的位置

    /// `$2` 搜索串，`$3` 根目录，`$4` 每份最多几行，`$5` 行的字节上限，`$6` 压缩过的记录把那一行原样带回来的单行上限，
    /// `$7` 一条命令带回来的行加起来的上限，之后是文件。回：每行 `<第几个文件> <行首偏移> <行长>`（压缩过的是解开后的位置）；
    /// 压缩过的记录（本机没法按位置读回来）在它后面跟一行 `> <那一行原样>`，超了上限的不带。
    ///
    /// 只报可能有可显示文字的行：`response_item` 里的 `message`（不是 `developer` 的）和几种工具调用。最后由本机解析确认。
    static let linesScript = #"""
        exec 2>/dev/null
        LC_ALL=C; export LC_ALL
        T=$(printf %b "$2"); export T
        echo uterm-claude-search:begin
        cd "$(printf %b "$3")" || { echo "uterm-claude-search:end 200"; exit 0; }
        M=$4; X=$5; C=$6; B=$7; export M X C B
        shift 7
        if command -v zstd >/dev/null 2>&1; then Z=1; else Z=0; echo uterm-codex:nozstd; fi
        A='
        BEGIN { t = tolower(ENVIRON["T"]); m = ENVIRON["M"] + 0; x = ENVIRON["X"] + 0; c = ENVIRON["C"] + 0; b = ENVIRON["B"] + 0; p = ENVIRON["P"] + 0; o = 0; n = 0; u = 0 }
        {
          l = length($0); s = o; o += l + 1
          if (l > x) next
          h = substr($0, 1, 512)
          if (index(h, "\"type\":\"response_item\"") == 0) next
          if (index(h, "\"role\":\"developer\"")) next
          if (index(h, "\"payload\":{\"type\":\"message\"") == 0 && index(h, "\"payload\":{\"type\":\"function_call\"") == 0 && index(h, "\"payload\":{\"type\":\"custom_tool_call\"") == 0 && index(h, "\"payload\":{\"type\":\"local_shell_call\"") == 0 && index(h, "\"payload\":{\"type\":\"web_search_call\"") == 0) next
          if (index(tolower($0), t) == 0) next
          print ENVIRON["I"], s, l
          if (p && l <= c && u + l <= b) { print "> " $0; u += l }
          n++
          if (n >= m) exit
        }'
        I=0; s=0
        for a; do
          case $a in *\\*) a=$(printf %b "$a");; esac
          I=$((I + 1)); export I
          case $a in
            *.zst) [ $Z = 1 ] || continue; P=1; export P; zstd -dcq -- "$a" | awk "$A" ;;
            *) P=0; export P; awk "$A" "$a" ;;
          esac
          r=$?
          case $r in 0) ;; *) s=$r;; esac
        done
        echo "uterm-claude-search:end $s"
        exit 0
        """#

    static func matchingLines(_ needle: String, root: String, maxLines: Int, maxLineBytes: Int,
                              inlineLineBytes: Int, inlineTotalBytes: Int, names: [String]) -> String {
        ClaudeSearchCommand.command(script: linesScript, arguments: [needle, root, String(maxLines), String(maxLineBytes),
                                                                     String(inlineLineBytes), String(inlineTotalBytes)] + names)
    }

    /// 第二段的输出：位置，压缩过的记录还带着那一行。
    nonisolated struct LineReference: Equatable, Sendable {
        let file: Int
        let offset: UInt64
        let length: Int
        var inline: Data?
    }

    static func lineReferences(_ lines: [Substring]) -> [LineReference] {
        var result: [LineReference] = []
        for line in lines {
            if line.hasPrefix("> ") {
                guard !result.isEmpty, result[result.count - 1].inline == nil else { continue }
                let content = Data(line.dropFirst(2).utf8)
                if content.count == result[result.count - 1].length { result[result.count - 1].inline = content }
                continue
            }
            let parts = line.split(separator: " ")
            guard parts.count == 3, let file = Int(parts[0]), let offset = UInt64(parts[1]), let length = Int(parts[2]),
                  file >= 1, length >= 0 else { continue }
            result.append(LineReference(file: file, offset: offset, length: length))
        }
        return result
    }

    static func hasNozstdMarker(_ output: String) -> Bool {
        output.split(whereSeparator: { $0 == "\n" || $0 == "\r\n" })
            .contains { $0.trimmingCharacters(in: .whitespaces) == nozstdMarker }
    }
}
