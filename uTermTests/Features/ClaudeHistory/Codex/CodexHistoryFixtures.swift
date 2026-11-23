import Foundation
@testable import uTerm

/// 手写的假 Codex 记录行。字段名、键的先后、`type` / `role` 的取值照 codex-cli 0.16x 的真实文件（只取结构，内容全是编的）。
enum CodexFixture {
    static let threadID = "019a0000-1111-7222-8333-444455556666"
    static let cwd = "/home/user/projects/demo"
    static let home = "/home/user"
    static let root = "/home/user/.codex/sessions"

    static func json(_ value: Any) -> String {
        let data = try! JSONSerialization.data(withJSONObject: value, options: [.fragmentsAllowed, .withoutEscapingSlashes, .sortedKeys])
        return String(data: data, encoding: .utf8)!
    }

    /// 一行：`{"timestamp":…,"ordinal":…,"type":…,"payload":…}`，`payload` 是编好的 JSON。
    static func line(_ type: String, _ payload: String, ordinal: Int = 1, time: String = "2026-11-20T10:00:01.000Z") -> String {
        #"{"timestamp":"\#(time)","ordinal":\#(ordinal),"type":"\#(type)","payload":\#(payload)}"#
    }

    /// 第一行。`source` 是编好的 JSON（字符串或对象）。系统提示词放一大段，真实文件里它把行撑到 20 KB 上下。
    static func meta(id: String = threadID, cwd: String = cwd, originator: String = "codex-tui",
                     source: String = #""vscode""#, threadSource: String? = "user", parent: String? = nil,
                     branch: String? = "main", instructionsBytes: Int = 6000) -> String {
        var fields = [#""session_id":"\#(parent ?? id)""#, #""id":"\#(id)""#]
        if let parent { fields.append(#""parent_thread_id":"\#(parent)""#) }
        fields += [#""timestamp":"2026-11-20T10:00:00.000Z""#, #""cwd":\#(json(cwd))"#, #""originator":"\#(originator)""#,
                   #""cli_version":"0.169.0""#, #""source":\#(source)"#]
        if let threadSource { fields.append(#""thread_source":"\#(threadSource)""#) }
        // 提示词里故意写着像键的字（转义过的引号），不能被当成字段。
        let instructions = "You are a coding agent. \"cwd\":\"/fake\" \"originator\":\"x\" " + String(repeating: "规则。", count: instructionsBytes / 9)
        fields.append(#""base_instructions":{"text":\#(json(instructions))}"#)
        fields.append(#""history_mode":"paginated""#)
        if let branch { fields.append(#""git":{"branch":"\#(branch)","commit_hash":"abc123"}"#) }
        return #"{"timestamp":"2026-11-20T10:00:00.000Z","ordinal":0,"type":"session_meta","payload":{\#(fields.joined(separator: ","))}}"#
    }

    static func spawnSource(parent: String, path: String) -> String {
        #"{"subagent":{"thread_spawn":{"parent_thread_id":"\#(parent)","depth":1,"agent_path":"\#(path)","agent_nickname":"Ada","agent_role":null}}}"#
    }

    static func message(role: String, blocks: [String], ordinal: Int = 1, time: String = "2026-11-20T10:00:01.000Z") -> String {
        line("response_item", #"{"type":"message","role":"\#(role)","content":[\#(blocks.joined(separator: ","))]}"#,
             ordinal: ordinal, time: time)
    }

    static func inputText(_ text: String) -> String { #"{"type":"input_text","text":\#(json(text))}"# }
    static func outputText(_ text: String) -> String { #"{"type":"output_text","text":\#(json(text))}"# }

    static func user(_ text: String, ordinal: Int = 1, time: String = "2026-11-20T10:00:01.000Z") -> String {
        message(role: "user", blocks: [inputText(text)], ordinal: ordinal, time: time)
    }

    static func assistant(_ text: String, ordinal: Int = 2, time: String = "2026-11-20T10:00:02.000Z") -> String {
        line("response_item", #"{"type":"message","role":"assistant","content":[\#(outputText(text))],"phase":"final_answer"}"#,
             ordinal: ordinal, time: time)
    }

    static func developer(_ text: String) -> String { message(role: "developer", blocks: [inputText(text)]) }

    /// 注入的那一条：AGENTS.md 与环境说明，各一块。
    static let injected = message(role: "user", blocks: [
        inputText("# AGENTS.md instructions for /home/user/projects/demo\n\n<INSTRUCTIONS>\n用中文回答\n</INSTRUCTIONS>"),
        inputText("<environment_context>\n  <cwd>/home/user/projects/demo</cwd>\n  <shell>zsh</shell>\n</environment_context>"),
    ])

    static func reasoning(_ summary: String) -> String {
        line("response_item", #"{"type":"reasoning","summary":[{"type":"summary_text","text":\#(json(summary))}],"content":null,"encrypted_content":"gAAAA"}"#)
    }

    static func functionCall(_ name: String, arguments: [String: Any], callID: String, namespace: String? = nil) -> String {
        let ns = namespace.map { #","namespace":"\#($0)""# } ?? ""
        return line("response_item", #"{"type":"function_call","name":"\#(name)"\#(ns),"arguments":\#(json(json(arguments))),"call_id":"\#(callID)"}"#)
    }

    static func functionOutput(callID: String, output: String) -> String {
        line("response_item", #"{"type":"function_call_output","call_id":"\#(callID)","output":\#(json(output))}"#)
    }

    static func customCall(_ name: String, input: String, callID: String) -> String {
        line("response_item", #"{"type":"custom_tool_call","status":"completed","call_id":"\#(callID)","name":"\#(name)","input":\#(json(input))}"#)
    }

    static func customOutput(callID: String, text: String) -> String {
        line("response_item", #"{"type":"custom_tool_call_output","call_id":"\#(callID)","output":[{"type":"input_text","text":\#(json(text))}]}"#)
    }

    static func compacted(_ summary: String) -> String {
        line("compacted", #"{"message":\#(json(summary)),"replacement_history":[]}"#)
    }

    static func turnContext(cwd: String, time: String = "2026-11-20T10:00:03.000Z") -> String {
        line("turn_context", #"{"turn_id":"t-1","cwd":\#(json(cwd)),"approval_policy":"never","model":"test-model"}"#, time: time)
    }

    /// 给界面的重复记录：不该显示第二遍。
    static func eventUserMessage(_ text: String) -> String {
        line("event_msg", #"{"type":"user_message","message":\#(json(text)),"images":[]}"#)
    }

    static func noise(_ index: Int) -> String {
        line("event_msg", #"{"type":"token_count","info":null,"rate_limits":null}"#, ordinal: index)
    }

    static func file(_ lines: [String]) -> Data { Data((lines.joined(separator: "\n") + "\n").utf8) }

    /// 一份命令行起的普通会话。
    static func session(id: String = threadID, cwd: String = cwd, originator: String = "codex-tui",
                        prompt: String = "帮我修复登录页", answer: String = "已经修好了。") -> Data {
        file([meta(id: id, cwd: cwd, originator: originator), developer("<permissions instructions>只读</permissions instructions>"),
              injected, user(prompt), eventUserMessage(prompt), reasoning("**看一下登录逻辑**"),
              functionCall("exec_command", arguments: ["cmd": "rg login", "workdir": cwd], callID: "call_1"),
              functionOutput(callID: "call_1", output: "src/login.ts:3: login()"),
              assistant(answer), turnContext(cwd: cwd + "/src")])
    }

    /// `~/.codex/sessions/2026/11/20/rollout-2026-11-20T10-00-00-<ID>.jsonl`
    static func path(id: String, day: String = "20", compressed: Bool = false) -> String {
        "\(root)/2026/11/\(day)/rollout-2026-11-\(day)T10-00-00-\(id).jsonl" + (compressed ? ".zst" : "")
    }

    static func entry(_ name: String, directory: Bool = false, size: UInt64 = 0, mtime: Date = Date()) -> RemoteEntry {
        RemoteEntry(name: name, posixPermissions: directory ? 0o040755 : 0o100644, size: directory ? nil : size, modifiedAt: mtime)
    }

    /// 一棵假的 `~/.codex/sessions`：给的每份记录按路径摆进去，目录一层层补上。
    static func host(_ files: [(path: String, data: Data, mtime: Date)], extra: [String: [RemoteEntry]] = [:]) async -> MockSFTP {
        var tree: [String: [RemoteEntry]] = [:]
        func add(_ entry: RemoteEntry, to directory: String) {
            if !(tree[directory] ?? []).contains(where: { $0.name == entry.name }) { tree[directory, default: []].append(entry) }
        }
        for file in files {
            var directory = (file.path as NSString).deletingLastPathComponent
            add(entry((file.path as NSString).lastPathComponent, size: UInt64(file.data.count), mtime: file.mtime), to: directory)
            while directory != root, directory.count > root.count {
                let parent = (directory as NSString).deletingLastPathComponent
                add(entry((directory as NSString).lastPathComponent, directory: true), to: parent)
                directory = parent
            }
        }
        for (key, value) in extra { tree[key, default: []].append(contentsOf: value) }
        let sftp = MockSFTP(tree: tree)
        for file in files { await sftp.setFile(file.path, data: file.data, mtime: file.mtime) }
        return sftp
    }
}
