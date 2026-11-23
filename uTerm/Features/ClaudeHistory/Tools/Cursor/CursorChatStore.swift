import CryptoKit
import Foundation

/// Cursor 命令行（`cursor-agent`）一个会话的库（`~/.cursor/chats/<工作目录的 MD5>/<会话 ID>/store.db`）里有什么。
/// 格式没有公开规格，按 `cursor-agent` 2025.11 的源码与本机记录（只看结构）写的：
///
/// - 两张表：`meta(key, value)` 只有一行，键 `0`，值是一段 JSON 的 UTF-8 字节再转成十六进制：
///   `agentId`（= 会话目录名）、`latestRootBlobId`（根 blob 的 ID，十六进制）、`name`（会话名，没起过是 `New Agent`）、
///   `createdAt`（毫秒）、`mode`、`lastUsedModel`。
///   `blobs(id, data)` 按内容寻址：`id` 是 `data` 的 SHA-256（十六进制），`data` 是 protobuf（`agent.v1.*`）或 JSON。
/// - 根 blob 是 `ConversationStateStructure`：8 `turns`（每轮一个 blob ID）、2 `turns_old`（旧版本，直接是
///   `AgentConversationTurnStructure` 的 blob ID）、1 `root_prompt_messages_json`（发给模型的整段提示，JSON，含系统提示）、
///   9 `previous_workspace_uris`（较新的版本才有，`file://` 开头）。
/// - 一轮（`ConversationTurnStructure`）：1 = 和 Agent 的一轮（`user_message` 一个 blob ID + `steps` 若干个），
///   2 = 用户自己敲的 shell 命令（`shell_command` / `shell_output` 各一个 blob ID）。
/// - 一步（`ConversationStep`）：1 回答、2 工具调用、3 思考。
///
/// 没有时间戳（只有会话的 `createdAt`）。
nonisolated enum CursorChatStore {
    /// 没起过名的会话的默认名。
    static let defaultName = "New Agent"

    nonisolated struct Meta: Equatable, Sendable {
        var agentID: String?
        /// 根 blob 的 ID（十六进制，小写）；还没说过话的会话为空。
        var rootBlobID: String
        var name: String?
        var createdAt: Date?
        var mode: String?

        /// 起过名的才算标题。
        var title: String? {
            guard let name else { return nil }
            let line = ClaudeSessionScan.singleLine(name)
            return line.isEmpty || line == CursorChatStore.defaultName ? nil : line
        }
    }

    /// 列表一行要的：只读元信息、根和第一轮的用户消息，不解析每一步。
    nonisolated struct Summary: Equatable, Sendable {
        var meta: Meta
        var turnCount: Int
        var firstUserText: String?
        /// 记录里提到的工作目录（还没核对过：要和目录名的 MD5 对上才算数，见 `CursorWorkspace`）。
        var workspaceCandidates: [String]
    }

    static func meta(in database: SQLiteMemoryDatabase) throws -> Meta? {
        guard try hasTable("meta", in: database) else { return nil }
        var raw: String?
        try database.query("SELECT value FROM meta WHERE key = '0'") { row in raw = row.text(0) }
        guard let raw, let bytes = CursorHex.decode(raw),
              let object = (try? JSONSerialization.jsonObject(with: bytes)) as? [String: Any] else { return nil }
        let created = (object["createdAt"] as? NSNumber).map { Date(timeIntervalSince1970: $0.doubleValue / 1000) }
        return Meta(agentID: object["agentId"] as? String,
                    rootBlobID: (object["latestRootBlobId"] as? String ?? "").lowercased(),
                    name: object["name"] as? String, createdAt: created, mode: object["mode"] as? String)
    }

    static func hasTable(_ name: String, in database: SQLiteMemoryDatabase) throws -> Bool {
        var found = false
        try database.query("SELECT 1 FROM sqlite_master WHERE type = 'table' AND name = ?", [.text(name)]) { _ in found = true }
        return found
    }

    /// 按 ID 取 blob。
    nonisolated final class Blobs {
        private let statement: SQLiteStatement?

        init(_ database: SQLiteMemoryDatabase) throws {
            statement = try CursorChatStore.hasTable("blobs", in: database)
                ? database.prepare("SELECT data FROM blobs WHERE id = ?") : nil
        }

        func data(_ id: Data) throws -> Data? { try data(hex: CursorHex.encode(id)) }

        func data(hex: String) throws -> Data? {
            guard let statement, !hex.isEmpty else { return nil }
            return try statement.firstData([.text(hex)])
        }

        func message(_ id: Data) throws -> CursorProtobufMessage? {
            try data(id).flatMap { try? CursorProtobufMessage($0) }
        }
    }

    /// 一轮：解出来的结构，还没变成条目。
    nonisolated enum Turn {
        case agent(user: CursorProtobufMessage?, steps: [CursorProtobufMessage?])
        case shell(command: CursorProtobufMessage?, output: CursorProtobufMessage?)
    }

    /// 根 blob 里的各轮。新版本在 8 `turns`（外面包一层 oneof），没有就退回旧版本的 2 `turns_old`。
    static func turnReferences(_ root: CursorProtobufMessage) -> [Data] {
        let turns = root.allBytes(8)
        return turns.isEmpty ? root.allBytes(2) : turns
    }

    static func usesLegacyTurns(_ root: CursorProtobufMessage) -> Bool { root.allBytes(8).isEmpty }

    /// 一轮的结构；`steps` 为 false 时只取用户消息（列表用）。坏的 blob 当它不存在。
    static func turn(_ id: Data, legacy: Bool, blobs: Blobs, steps includeSteps: Bool = true) throws -> Turn? {
        guard let structure = try blobs.message(id) else { return nil }
        let agent: CursorProtobufMessage?
        if legacy {
            agent = structure
        } else if let shell = structure.message(2) {
            return .shell(command: try shell.bytes(1).flatMap(blobs.message),
                          output: try shell.bytes(2).flatMap(blobs.message))
        } else {
            agent = structure.message(1)
        }
        guard let agent else { return nil }
        let user = try agent.bytes(1).flatMap(blobs.message)
        let steps = includeSteps ? try agent.allBytes(2).map { try blobs.message($0) } : []
        return .agent(user: user, steps: steps)
    }

    static func load(_ database: SQLiteMemoryDatabase) throws -> (meta: Meta, root: CursorProtobufMessage?, blobs: Blobs)? {
        guard let meta = try meta(in: database) else { return nil }
        let blobs = try Blobs(database)
        let root = try blobs.data(hex: meta.rootBlobID).flatMap { try? CursorProtobufMessage($0) }
        return (meta, root, blobs)
    }

    static func summary(in database: SQLiteMemoryDatabase) throws -> Summary? {
        guard let loaded = try load(database) else { return nil }
        let meta = loaded.meta, blobs = loaded.blobs
        guard let root = loaded.root else { return Summary(meta: meta, turnCount: 0, firstUserText: nil, workspaceCandidates: []) }
        let references = turnReferences(root)
        let legacy = usesLegacyTurns(root)
        var firstUserText: String?
        for reference in references.prefix(8) {
            if case .agent(let user, _)? = try turn(reference, legacy: legacy, blobs: blobs, steps: false),
               let text = user?.text(1), !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                firstUserText = text
                break
            }
        }
        return Summary(meta: meta, turnCount: references.count, firstUserText: firstUserText,
                       workspaceCandidates: try CursorWorkspace.candidates(root: root, blobs: blobs))
    }
}

/// 会话属于哪个工作目录。库所在的目录名是 `cursor-agent` 启动时 `process.cwd()` 的 MD5（十六进制），`--resume`
/// 也按「当前目录的 MD5」去找会话——所以继续会话必须回到 MD5 对得上的那个目录。记录里提到的目录只是候选，
/// 对上了才用：
/// - 根 blob 的 9 `previous_workspace_uris`（`file://` 开头，较新的版本才有）；
/// - 发给模型的第一条用户消息里 `<user_info>` 那段的 `Workspace Path: …` / `Current working directory: …`
///   （版本不同写法不同，这里不认措辞：那段里每一行冒号后面以 `/` 开头的都算候选）。
nonisolated enum CursorWorkspace {
    /// 提示里最多看前几条消息（第一条是系统提示，第二条是带 `<user_info>` 的用户消息）。
    static let promptMessagesScanned = 6

    static func hash(of directory: String) -> String {
        Insecure.MD5.hash(data: Data(directory.utf8)).map { String(format: "%02x", $0) }.joined()
    }

    /// 目录名像不像 `cursor-agent` 的工作目录哈希：32 个小写十六进制字符。
    static func isHashName(_ name: String) -> Bool {
        name.utf8.count == 32 && name.utf8.allSatisfy { (0x30...0x39).contains($0) || (0x61...0x66).contains($0) }
    }

    /// 候选里 MD5 对得上 `hash` 的那个。
    static func verified(_ candidates: [String], hash expected: String) -> String? {
        candidates.first { hash(of: $0) == expected }
    }

    static func candidates(root: CursorProtobufMessage, blobs: CursorChatStore.Blobs) throws -> [String] {
        var output: [String] = []
        for uri in root.strings(9) {
            if let path = path(fromURI: uri) { output.append(path) }
        }
        for reference in root.allBytes(1).prefix(promptMessagesScanned) {
            guard let data = try blobs.data(reference),
                  let message = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
                  message["role"] as? String == "user" else { continue }
            for text in texts(of: message["content"]) {
                output.append(contentsOf: candidates(inPrompt: text))
            }
        }
        var seen = Set<String>()
        return output.filter { seen.insert($0).inserted }
    }

    static func path(fromURI uri: String) -> String? {
        if uri.hasPrefix("/") { return uri }
        guard let url = URL(string: uri), url.isFileURL else { return nil }
        let path = url.path(percentEncoded: false)
        return path.hasPrefix("/") ? path : nil
    }

    /// 一段提示里 `<user_info>…</user_info>` 中每一行「…: /路径」的路径。
    static func candidates(inPrompt text: String) -> [String] {
        let blocks = ClaudeUserText.removing(tag: "user_info", from: text).inner
        var output: [String] = []
        for block in blocks {
            for line in block.split(whereSeparator: \.isNewline) {
                guard let colon = line.range(of: ": ") else { continue }
                let value = line[colon.upperBound...].trimmingCharacters(in: .whitespaces)
                if value.hasPrefix("/"), !value.contains("\0") { output.append(value) }
            }
        }
        return output
    }

    private static func texts(of content: Any?) -> [String] {
        if let string = content as? String { return [string] }
        guard let parts = content as? [Any] else { return [] }
        return parts.compactMap { ($0 as? [String: Any])?["text"] as? String }
    }
}

/// 十六进制编解码（blob ID 在库里是十六进制文本）。不做成 `Data` 的扩展，免得在整个模块里多出一个名字。
nonisolated enum CursorHex {
    private static let digits = Array("0123456789abcdef")

    /// 小写十六进制。
    static func encode(_ data: Data) -> String {
        var output = ""
        output.reserveCapacity(data.count * 2)
        for byte in data {
            output.append(digits[Int(byte >> 4)])
            output.append(digits[Int(byte & 0x0F)])
        }
        return output
    }

    /// 大小写都行；长度为奇数或有别的字符为 nil。
    static func decode(_ text: String) -> Data? {
        let utf8 = Array(text.utf8)
        guard utf8.count % 2 == 0 else { return nil }
        func value(_ c: UInt8) -> UInt8? {
            switch c {
            case 0x30...0x39: return c - 0x30
            case 0x61...0x66: return c - 0x61 + 10
            case 0x41...0x46: return c - 0x41 + 10
            default: return nil
            }
        }
        var bytes = [UInt8]()
        bytes.reserveCapacity(utf8.count / 2)
        var index = 0
        while index < utf8.count {
            guard let high = value(utf8[index]), let low = value(utf8[index + 1]) else { return nil }
            bytes.append(high << 4 | low)
            index += 2
        }
        return Data(bytes)
    }
}
