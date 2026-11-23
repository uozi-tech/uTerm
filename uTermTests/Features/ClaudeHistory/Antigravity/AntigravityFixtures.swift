import Foundation
@testable import uTerm

/// 手写的假 Antigravity 记录行。字段名、键的先后、外层的标签照 2026-11 桌面版的真实文件（只取结构，内容全是编的）。
enum AntigravityFixture {
    static let home = "/home/user"
    static var appRoot: String { home + "/.gemini/antigravity" }
    static var cliRoot: String { home + "/.gemini/antigravity-cli" }
    static let workspace = "/home/user/projects/demo"

    static func sessionID(_ index: Int) -> String { String(format: "%08x-aaaa-4bbb-8ccc-%012x", index, index) }

    static func logs(_ index: Int, root: String = appRoot) -> String {
        "\(root)/brain/\(sessionID(index))/.system_generated/logs"
    }

    static func transcriptPath(_ index: Int, root: String = appRoot, name: String = "transcript_full.jsonl") -> String {
        logs(index, root: root) + "/" + name
    }

    static func json(_ value: String) -> String { ClaudeFixture.json(value) }

    static func time(_ step: Int) -> String {
        String(format: "2026-11-20T10:%02d:%02dZ", (step / 60) % 60, step % 60)
    }

    private static func head(_ step: Int, source: String, type: String, status: String = "DONE", error: String? = nil) -> String {
        let errorField = error.map { #","error":\#(json($0))"# } ?? ""
        return #"{"step_index":\#(step),"source":"\#(source)","type":"\#(type)","status":"\#(status)"\#(errorField),"created_at":"\#(time(step))""#
    }

    /// 你说的话：`<USER_REQUEST>` 外面带着系统附上的 `<ADDITIONAL_METADATA>`，换了模型时还有 `<USER_SETTINGS_CHANGE>`。
    static func userInput(_ step: Int, _ request: String, settingsChange: String? = nil,
                          metadata: String = "The current local time is: 2026-11-20T18:00:00+08:00.") -> String {
        var content = "<USER_REQUEST>\n\(request)\n</USER_REQUEST>\n<ADDITIONAL_METADATA>\n\(metadata)\n</ADDITIONAL_METADATA>"
        if let settingsChange { content += "\n<USER_SETTINGS_CHANGE>\n\(settingsChange)\n</USER_SETTINGS_CHANGE>" }
        return head(step, source: "USER_EXPLICIT", type: "USER_INPUT") + #","content":\#(json(content))}"#
    }

    /// 模型的一步。`calls` 的参数是写好的 JSON 对象。
    static func planner(_ step: Int, thinking: String? = nil, content: String? = nil,
                        calls: [(name: String, args: String)] = []) -> String {
        var line = head(step, source: "MODEL", type: "PLANNER_RESPONSE")
            + #","model":"test-model","input_tokens":10,"cache_read_tokens":0,"output_tokens":5"#
        if let content { line += #","content":\#(json(content))"# }
        if let thinking { line += #","thinking":\#(json(thinking))"# }
        if !calls.isEmpty {
            line += #","tool_calls":["# + calls.map { #"{"name":"\#($0.name)","args":\#($0.args)}"# }.joined(separator: ",") + "]"
        }
        return line + "}"
    }

    static func command(_ commandLine: String) -> (name: String, args: String) {
        ("run_command", #"{"CommandLine":\#(json(commandLine)),"WaitMsBeforeAsync":500,"toolSummary":"run a thing"}"#)
    }

    static func readFile(_ path: String) -> (name: String, args: String) {
        ("read_file", #"{"Path":\#(json(path)),"StartLine":1,"EndLine":20}"#)
    }

    /// 一次工具调用的结果，开头是这一步的起止时间。
    static func generic(_ step: Int, _ output: String, status: String = "DONE", error: String? = nil, media: Int = 0) -> String {
        let content = "Created At: 2026-11-20T18:00:00+08:00\nCompleted At: 2026-11-20T18:00:01+08:00\n" + output
        var line = head(step, source: "MODEL", type: "GENERIC", status: status, error: error) + #","content":\#(json(content))"#
        if media > 0 {
            line += #","media":["# + (0..<media).map { #"{"mime_type":"image/png","uri":"file:///tmp/m\#($0).png"}"# }
                .joined(separator: ",") + "]"
        }
        return line + "}"
    }

    static func systemMessage(_ step: Int, _ text: String) -> String {
        let content = "The following is a <SYSTEM_MESSAGE> not actually sent by the user. It is provided by the system as important information to pay attention to.\n\n<SYSTEM_MESSAGE>\n[Message] timestamp=2026-11-20T10:00:00Z sender=0000/task-1 priority=MESSAGE_PRIORITY_LOW content=\(text)\n</SYSTEM_MESSAGE>"
        return head(step, source: "SYSTEM", type: "SYSTEM_MESSAGE") + #","content":\#(json(content))}"#
    }

    static func checkpoint(_ step: Int, _ summary: String) -> String {
        head(step, source: "SYSTEM", type: "CHECKPOINT") + #","input_tokens":1,"cache_read_tokens":0,"output_tokens":1,"content":\#(json(summary))}"#
    }

    static func errorMessage(_ step: Int, _ error: String) -> String {
        head(step, source: "SYSTEM", type: "ERROR_MESSAGE", error: error) + "}"
    }

    static func file(_ lines: [String]) -> Data { ClaudeFixture.file(lines) }

    static func annotation(_ title: String) -> Data {
        Data(#"title:\#(json(title)) last_user_view_time:{seconds:1763600000 nanos:5}"#.utf8)
    }

    /// 一个会话：编号、记录内容、多久以前、在哪个数据目录。
    struct Session {
        var index: Int
        var data: Data
        var age: TimeInterval = 60
        var root: String = AntigravityFixture.appRoot
        var name: String = "transcript_full.jsonl"
        var annotation: String? = nil
    }

    /// 在 `MockSFTP` 里摆好 `brain/`、每个会话的 `logs/`、`annotations/`。
    static func host(_ sessions: [Session]) async -> MockSFTP {
        let now = Date()
        var tree: [String: [RemoteEntry]] = [:]
        for root in Set(sessions.map(\.root)) {
            tree[root + "/brain"] = sessions.filter { $0.root == root }.map {
                ClaudeFixture.entry(sessionID($0.index), directory: true, mtime: now.addingTimeInterval(-$0.age))
            } + [ClaudeFixture.entry(".DS_Store", size: 6)]
        }
        for session in sessions {
            tree[logs(session.index, root: session.root)] = [
                ClaudeFixture.entry("chunks", directory: true, mtime: now),
                ClaudeFixture.entry(session.name, size: UInt64(session.data.count), mtime: now.addingTimeInterval(-session.age)),
            ]
        }
        let sftp = MockSFTP(tree: tree)
        for session in sessions {
            await sftp.setFile(transcriptPath(session.index, root: session.root, name: session.name), data: session.data,
                               mtime: now.addingTimeInterval(-session.age))
            if let annotation = session.annotation {
                await sftp.setFile("\(session.root)/annotations/\(sessionID(session.index)).pbtxt",
                                   data: AntigravityFixture.annotation(annotation), mtime: now)
            }
        }
        return sftp
    }

    /// 一段普通的对话：一问、一步带两个调用、两个结果、一句回答。
    static func conversation(_ request: String, answer: String = "做完了") -> [String] {
        [
            userInput(0, request),
            planner(1, thinking: "先看看文件", calls: [readFile("/home/user/projects/demo/a.txt"), command("ls -la")]),
            generic(2, "Showing lines 1-2 of 2\n1: alpha\n2: beta"),
            generic(3, "Command exited with code 0.\n\nCommand output:\nfile.txt"),
            planner(4, content: answer),
        ]
    }
}

/// 按会话 ID 答的假索引（SQLite 那一份汇合时才接上）。
struct FakeAntigravityIndex: AntigravityConversationIndex {
    var byRoot: [String: [String: AntigravityConversationInfo]]

    func conversations(root: String, provider: any SFTPProviding) async throws -> [String: AntigravityConversationInfo] {
        byRoot[root] ?? [:]
    }
}

struct FailingAntigravityIndex: AntigravityConversationIndex {
    func conversations(root: String, provider: any SFTPProviding) async throws -> [String: AntigravityConversationInfo] {
        throw NSError(domain: "FakeIndex", code: 1)
    }
}
