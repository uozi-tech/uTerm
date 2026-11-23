import CryptoKit
import Foundation
@testable import uTerm

/// 写 protobuf 线格式（测试里现拼 Cursor 的 blob）。
struct ProtoWriter {
    private(set) var data = Data()

    init(_ build: (inout ProtoWriter) -> Void = { _ in }) { build(&self) }

    private mutating func raw(_ value: UInt64) {
        var value = value
        while value >= 0x80 {
            data.append(UInt8(value & 0x7F) | 0x80)
            value >>= 7
        }
        data.append(UInt8(value))
    }

    mutating func varint(_ field: Int, _ value: UInt64) {
        raw(UInt64(field) << 3)
        raw(value)
    }

    mutating func bytes(_ field: Int, _ value: Data) {
        raw(UInt64(field) << 3 | 2)
        raw(UInt64(value.count))
        data.append(value)
    }

    mutating func string(_ field: Int, _ value: String) { bytes(field, Data(value.utf8)) }
    mutating func message(_ field: Int, _ value: ProtoWriter) { bytes(field, value.data) }
}

/// 手写的假会话。字段号照 `cursor-agent` 2025.11 的 `agent.v1.*`（只取结构，内容全是编的）。
enum CursorFixture {
    static let home = "/home/user"
    static let chatsRoot = home + "/.cursor/chats"
    static let workspace = "/home/user/projects/demo"
    /// `md5("/home/user/projects/demo")`，用 Python 的 hashlib 另算的，核对产品里的 MD5。
    static let workspaceHash = "e1e1f140b746c569be2daa533d62ee33"
    static let otherWorkspace = "/home/user/work/api"
    static let otherHash = "848098181b4dbcfb65c0add3d08f3060"
    static let sessionID = "5d2c8a10-3b4e-4f60-9a7b-1c2d3e4f5a6b"
    static let otherSessionID = "0a1b2c3d-4e5f-4a6b-8c7d-9e0f1a2b3c4d"
    static let createdAt = Date(timeIntervalSince1970: 1_800_000_000)

    static func storePath(hash: String = workspaceHash, session: String = sessionID, root: String = chatsRoot) -> String {
        "\(root)/\(hash)/\(session)/store.db"
    }

    // MARK: 一步

    static func assistant(_ text: String) -> Data {
        ProtoWriter { $0.message(1, ProtoWriter { $0.string(1, text) }) }.data
    }

    static func thinking(_ text: String, milliseconds: UInt64 = 1200) -> Data {
        ProtoWriter { $0.message(3, ProtoWriter { $0.string(1, text); $0.varint(2, milliseconds) }) }.data
    }

    /// 工具调用：`tool` 是 `ToolCall` 的 oneof 字段号，`args` / `result` 是那种工具自己的消息。
    static func tool(_ tool: Int, args: ProtoWriter, result: ProtoWriter? = nil) -> Data {
        ProtoWriter { step in
            step.message(2, ProtoWriter { call in
                call.message(tool, ProtoWriter { body in
                    body.message(1, args)
                    if let result { body.message(2, result) }
                })
            })
        }.data
    }

    static func shell(_ command: String, stdout: String? = nil, exitCode: UInt64 = 0, failed: Bool = false) -> Data {
        let args = ProtoWriter { $0.string(1, command); $0.string(4, "call_1") }
        guard let stdout else { return tool(1, args: args) }
        let outcome = ProtoWriter { $0.string(1, command); $0.varint(3, exitCode); $0.string(5, stdout) }
        return tool(1, args: args, result: ProtoWriter { $0.message(failed ? 2 : 1, outcome) })
    }

    static func read(_ path: String, content: String) -> Data {
        tool(8, args: ProtoWriter { $0.string(1, path) },
             result: ProtoWriter { $0.message(1, ProtoWriter { $0.string(1, content); $0.varint(4, 3) }) })
    }

    static func readNotFound(_ path: String) -> Data {
        tool(8, args: ProtoWriter { $0.string(1, path) },
             result: ProtoWriter { $0.message(2, ProtoWriter { $0.string(1, "文件不存在") }) })
    }

    static func edit(_ path: String, diff: String) -> Data {
        tool(12, args: ProtoWriter { $0.string(1, path) },
             result: ProtoWriter { $0.message(1, ProtoWriter {
                 $0.string(1, path); $0.string(5, diff); $0.string(7, String(repeating: "整个文件的内容\n", count: 50))
             }) })
    }

    static func grep(_ pattern: String, file: String, line: Int, content: String) -> Data {
        let match = ProtoWriter { $0.varint(1, UInt64(line)); $0.string(2, content) }
        let fileMatch = ProtoWriter { $0.string(1, file); $0.message(2, match) }
        let union = ProtoWriter { $0.message(3, ProtoWriter { $0.message(1, fileMatch) }) }
        let entry = ProtoWriter { $0.string(1, workspace); $0.message(2, union) }
        return tool(5, args: ProtoWriter { $0.string(1, pattern) },
                    result: ProtoWriter { $0.message(1, ProtoWriter { $0.string(1, pattern); $0.message(4, entry) }) })
    }

    static func task(_ description: String, answer: String) -> Data {
        let steps = ProtoWriter { success in
            success.bytes(1, thinking("子代理在想"))
            success.bytes(1, assistant(answer))
            success.string(2, "agent-1")
        }
        return tool(19, args: ProtoWriter { $0.string(1, description); $0.string(2, "去查一下"); $0.string(3, "explore") },
                    result: ProtoWriter { $0.message(1, steps) })
    }

    static func todos(_ items: [String]) -> Data {
        tool(9, args: ProtoWriter { args in
            for (index, item) in items.enumerated() {
                args.message(1, ProtoWriter { $0.string(1, "t\(index)"); $0.string(2, item); $0.varint(3, 1) })
            }
        })
    }

    // MARK: 一轮

    enum Turn {
        case agent(user: String, steps: [Data])
        case shell(command: String, stdout: String, stderr: String)
    }

    /// 一个会话的库。`workspaceURI`：根上的 `previous_workspace_uris`；`promptWorkspace`：提示里 `<user_info>` 那段写的目录
    /// （带「Workspace Path:」）。`legacy`：旧版本的 `turns_old`。
    final class Chat {
        let database: SQLiteFixtureDatabase
        var name: String
        var turns: [Turn] = []
        var workspaceURI: String?
        var promptWorkspace: String?
        var legacy = false

        init(name: String = "New Agent", workspaceURI: String? = nil, promptWorkspace: String? = CursorFixture.workspace) throws {
            database = try SQLiteFixtureDatabase()
            self.name = name
            self.workspaceURI = workspaceURI
            self.promptWorkspace = promptWorkspace
            try database.exec("CREATE TABLE blobs (id TEXT PRIMARY KEY, data BLOB)")
            try database.exec("CREATE TABLE meta (key TEXT PRIMARY KEY, value TEXT)")
        }

        @discardableResult
        private func blob(_ data: Data) throws -> Data {
            let id = Data(SHA256.hash(data: data))
            try database.run("INSERT OR REPLACE INTO blobs (id, data) VALUES (?, ?)", [CursorHex.encode(id), data])
            return id
        }

        private func turnBlob(_ turn: Turn, index: Int) throws -> Data {
            switch turn {
            case .agent(let user, let steps):
                let userID = try blob(ProtoWriter { $0.string(1, user); $0.string(2, "m-\(index)") }.data)
                let stepIDs = try steps.map { try blob($0) }
                let structure = ProtoWriter { agent in
                    agent.bytes(1, userID)
                    for id in stepIDs { agent.bytes(2, id) }
                }
                return try blob(legacy ? structure.data : ProtoWriter { $0.message(1, structure) }.data)
            case .shell(let command, let stdout, let stderr):
                let commandID = try blob(ProtoWriter { $0.string(1, command) }.data)
                let outputID = try blob(ProtoWriter { $0.string(1, stdout); $0.string(2, stderr) }.data)
                return try blob(ProtoWriter { $0.message(2, ProtoWriter { $0.bytes(1, commandID); $0.bytes(2, outputID) }) }.data)
            }
        }

        /// 照现在的 `turns` 写一个新的根，`meta` 指向它（同 `cursor-agent` 每次存档：旧的 blob 留着）。
        func save(emptyRoot: Bool = false) throws {
            var rootID = Data()
            if !emptyRoot {
                let system = try blob(Data(#"{"role":"system","content":"你是一个编程助手。"}"#.utf8))
                var prompt = "<user_info>\nOS Version: linux\nShell: bash\n"
                if let promptWorkspace { prompt += "Workspace Path: \(promptWorkspace)\n" }
                prompt += "</user_info>\n<rules>写测试</rules>"
                let promptJSON = try JSONSerialization.data(withJSONObject: ["role": "user", "content": prompt])
                let userPrompt = try blob(promptJSON)
                let turnIDs = try turns.enumerated().map { try turnBlob($1, index: $0) }
                let root = ProtoWriter { root in
                    root.bytes(1, system)
                    root.bytes(1, userPrompt)
                    for id in turnIDs { root.bytes(self.legacy ? 2 : 8, id) }
                    if let uri = self.workspaceURI { root.string(9, uri) }
                }
                rootID = try blob(root.data)
            }
            let meta: [String: Any] = ["agentId": CursorFixture.sessionID, "latestRootBlobId": CursorHex.encode(rootID),
                                       "name": name, "mode": "default",
                                       "createdAt": Int(CursorFixture.createdAt.timeIntervalSince1970 * 1000)]
            let json = try JSONSerialization.data(withJSONObject: meta)
            try database.run("INSERT OR REPLACE INTO meta (key, value) VALUES (?, ?)", ["0", CursorHex.encode(json)])
        }

        func snapshot() throws -> SQLiteFixtureSnapshot { try database.snapshot() }
    }
}
