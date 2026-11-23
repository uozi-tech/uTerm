import Foundation

/// Antigravity 自己记着的会话信息里，列表要用的几样。`brain/` 下的记录里没有工作区（打开的是哪个文件夹），
/// 标题也只有一部分会话有（`annotations/`），这些都在数据目录的 `conversation_summaries.db`（SQLite）里。
nonisolated struct AntigravityConversationInfo: Equatable, Sendable {
    var title: String?
    /// 第一个工作区的目录（`workspace_uris` 的第一个 `file://` 换成路径）；没有打开文件夹的会话为 nil。
    var workspace: String?
    var lastModified: Date?
    /// 由哪个会话派出来的（`parent_conversation_id`）；顶层的为 nil。
    var parentID: String?

    init(title: String? = nil, workspace: String? = nil, lastModified: Date? = nil, parentID: String? = nil) {
        self.title = title
        self.workspace = workspace
        self.lastModified = lastModified
        self.parentID = parentID
    }

    /// `workspace_uris` 列的原文（`["file:///Users/a/proj","file:///…"]`，没有工作区时是空串或 `[]`）→ 第一个目录。
    static func workspace(fromURIsJSON text: String) -> String? {
        guard let data = text.data(using: .utf8),
              let uris = (try? JSONSerialization.jsonObject(with: data)) as? [Any] else { return nil }
        for case let uri as String in uris {
            if let path = path(fromFileURI: uri) { return path }
        }
        return nil
    }

    /// `last_modified_time` 的文本（`2026-11-20 10:00:00.123456+08:00`，小数位数不定，也可能没有）→ 时间。
    static func date(fromSQLiteText text: String) -> Date? {
        ClaudeTimestamp.parse(text.trimmingCharacters(in: .whitespaces).replacingOccurrences(of: " ", with: "T"))
    }

    /// `file:///a/b%20c` → `/a/b c`。不是本机文件的 URI（`vscode-remote://…`）为 nil。
    static func path(fromFileURI uri: String) -> String? {
        guard let url = URL(string: uri), url.scheme == "file", url.host == nil || url.host == "" || url.host == "localhost"
        else { return nil }
        let path = url.path(percentEncoded: false)
        guard path.hasPrefix("/") else { return nil }
        return path.count > 1 && path.hasSuffix("/") ? String(path.dropLast()) : path
    }
}

/// 按会话 ID 查 Antigravity 记着的信息。数据源在没有它的时候照样能用（标题取第一句你说的话，工作区归到「没有工作区」），
/// 有了它列表才能按工作区分组。
///
/// 一份实现读 `<数据目录>/conversation_summaries.db`（只读：不能留下 `-shm` / `-wal`）：
///
///     SELECT conversation_id, title, workspace_uris, last_modified_time, parent_conversation_id
///     FROM conversation_summaries
///
/// - `title`：`NOT NULL DEFAULT ""`，空串当没有。
/// - `workspace_uris`：`text NOT NULL`，交给 `AntigravityConversationInfo.workspace(fromURIsJSON:)`。
/// - `last_modified_time`：`datetime`，存的是文本 `2026-11-20 10:00:00.123456+08:00`（Go 的写法，小数位数不定）。
/// - `parent_conversation_id`：空串当没有；另有一张表 `conversation_parents(conversation_id, parent_id)` 记着同样的关系。
///
/// 读不出来（没有这个库、不是 SQLite、表结构变了）就抛错或返回空：数据源当作没有这份信息。
nonisolated protocol AntigravityConversationIndex: Sendable {
    /// `root`：数据目录（`~/.gemini/antigravity`）。返回会话 ID → 信息。
    func conversations(root: String, provider: any SFTPProviding) async throws -> [String: AntigravityConversationInfo]
}

/// 什么都不知道：只靠 `brain/` 下的记录。
nonisolated struct AntigravityNoConversationIndex: AntigravityConversationIndex {
    func conversations(root: String, provider: any SFTPProviding) async throws -> [String: AntigravityConversationInfo] {
        [:]
    }
}

/// `annotations/<会话 ID>.pbtxt`：桌面版给会话起的标题，protobuf 文本格式的一行
/// `title:"…" last_user_view_time:{seconds:… nanos:…}`。不解 protobuf，只取 `title` 那个字符串。
nonisolated enum AntigravityAnnotation {
    static func title(in data: Data) -> String? {
        guard let text = String(data: data, encoding: .utf8) else { return nil }
        let scalars = Array(text.unicodeScalars)
        var index = 0
        // 顶层的 `title:`（或 `title: `），后面是一个带引号的字符串。
        while index < scalars.count {
            if scalars[index] == "\"" || scalars[index] == "'" {
                index = skipString(scalars, from: index)
                continue
            }
            if matches("title", scalars, at: index), index == 0 || !isIdentifier(scalars[index - 1]) {
                var cursor = index + 5
                while cursor < scalars.count, scalars[cursor] == " " { cursor += 1 }
                guard cursor < scalars.count, scalars[cursor] == ":" else { index += 5; continue }
                cursor += 1
                while cursor < scalars.count, scalars[cursor] == " " { cursor += 1 }
                guard cursor < scalars.count, scalars[cursor] == "\"" || scalars[cursor] == "'" else { return nil }
                guard let value = decodeString(scalars, from: cursor) else { return nil }
                let line = ClaudeSessionScan.singleLine(value)
                return line.isEmpty ? nil : line
            }
            index += 1
        }
        return nil
    }

    private static func matches(_ word: String, _ scalars: [Unicode.Scalar], at index: Int) -> Bool {
        let word = Array(word.unicodeScalars)
        guard index + word.count <= scalars.count else { return false }
        return Array(scalars[index..<(index + word.count)]) == word
    }

    private static func isIdentifier(_ scalar: Unicode.Scalar) -> Bool {
        scalar == "_" || scalar.properties.isAlphabetic || ("0"..."9").contains(scalar)
    }

    /// 跳过从 `start`（引号）起的一个字符串，返回它后面的位置。
    private static func skipString(_ scalars: [Unicode.Scalar], from start: Int) -> Int {
        let quote = scalars[start]
        var index = start + 1
        while index < scalars.count, scalars[index] != quote {
            index += scalars[index] == "\\" ? 2 : 1
        }
        return index + 1
    }

    /// protobuf 文本格式的字符串：C 风格转义（`\n`、`\"`、`\\`、三位八进制 `\345` 表示一个字节、`\x..`）。
    /// 八进制写出来的是 UTF-8 字节，攒成字节再解码。
    private static func decodeString(_ scalars: [Unicode.Scalar], from start: Int) -> String? {
        let quote = scalars[start]
        var bytes: [UInt8] = []
        var index = start + 1
        func append(_ scalar: Unicode.Scalar) { bytes.append(contentsOf: Array(String(scalar).utf8)) }
        while index < scalars.count {
            let scalar = scalars[index]
            if scalar == quote { return String(bytes: bytes, encoding: .utf8) }
            guard scalar == "\\" else {
                append(scalar)
                index += 1
                continue
            }
            guard index + 1 < scalars.count else { return nil }
            let next = scalars[index + 1]
            switch next {
            case "n": bytes.append(0x0A); index += 2
            case "t": bytes.append(0x09); index += 2
            case "r": bytes.append(0x0D); index += 2
            case "0"..."7":
                var value = 0
                var digits = 0
                while digits < 3, index + 1 + digits < scalars.count, ("0"..."7").contains(scalars[index + 1 + digits]) {
                    value = value * 8 + Int(scalars[index + 1 + digits].value - 0x30)
                    digits += 1
                }
                bytes.append(UInt8(truncatingIfNeeded: value))
                index += 1 + digits
            case "x":
                var value = 0
                var digits = 0
                while digits < 2, index + 2 + digits < scalars.count, scalars[index + 2 + digits].properties.isASCIIHexDigit {
                    value = value * 16 + Int(String(scalars[index + 2 + digits]), radix: 16)!
                    digits += 1
                }
                guard digits > 0 else { return nil }
                bytes.append(UInt8(value))
                index += 2 + digits
            default:
                // `\"`、`\'`、`\\`、`\?` 之类：就是那个字符本身。
                append(next)
                index += 2
            }
        }
        return nil
    }
}
