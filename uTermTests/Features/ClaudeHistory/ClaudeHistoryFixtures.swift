import Foundation
@testable import uTerm

/// 手写的假记录行。字段名与键的先后照 Claude Code 2.1.x 的真实文件（只取结构，内容全是编的）。
enum ClaudeFixture {
    static let sessionID = "0b0e5f3a-1c2d-4e5f-8a9b-0c1d2e3f4a5b"
    static let cwd = "/home/user/projects/demo"

    /// 任意字符串编成 JSON 字符串字面量（带引号）。
    static func json(_ value: String) -> String {
        let data = try! JSONSerialization.data(withJSONObject: value, options: [.fragmentsAllowed])
        return String(data: data, encoding: .utf8)!
    }

    static func meta(entrypoint: String?, cwd: String) -> String {
        let entry = entrypoint.map { #","entrypoint":"\#($0)""# } ?? ""
        return #""timestamp":"2026-11-20T10:00:00.000Z","cwd":"\#(cwd)","sessionId":"\#(sessionID)","version":"2.1.330","gitBranch":"main""#
            + entry
    }

    /// `user` 行，`content` 是已经编好的 JSON（字符串字面量或块数组）。
    static func user(content: String, uuid: String = "u-1", entrypoint: String? = "cli", cwd: String = cwd,
                     flags: String = "") -> String {
        #"{"parentUuid":null,"isSidechain":false,"promptId":"p-1","type":"user","message":{"role":"user","content":\#(content)},"uuid":"\#(uuid)",\#(meta(entrypoint: entrypoint, cwd: cwd))\#(flags)}"#
    }

    static func userText(_ text: String, uuid: String = "u-1", entrypoint: String? = "cli", cwd: String = cwd) -> String {
        user(content: json(text), uuid: uuid, entrypoint: entrypoint, cwd: cwd)
    }

    /// `assistant` 行，`blocks` 是逗号分隔的块。
    static func assistant(_ blocks: String, uuid: String = "a-1", entrypoint: String? = "cli", cwd: String = cwd,
                          sidechain: Bool = false) -> String {
        #"{"parentUuid":"u-1","isSidechain":\#(sidechain),"message":{"model":"test-model","id":"msg_1","type":"message","role":"assistant","content":[\#(blocks)]},"type":"assistant","uuid":"\#(uuid)",\#(meta(entrypoint: entrypoint, cwd: cwd))}"#
    }

    static func textBlock(_ text: String) -> String { #"{"type":"text","text":\#(json(text))}"# }
    static func thinkingBlock(_ text: String) -> String { #"{"type":"thinking","thinking":\#(json(text)),"signature":"sig"}"# }
    static func toolUse(id: String, name: String, input: String) -> String {
        #"{"type":"tool_use","id":"\#(id)","name":"\#(name)","input":\#(input)}"#
    }
    static func toolResult(id: String, text: String, isError: Bool = false) -> String {
        user(content: #"[{"tool_use_id":"\#(id)","type":"tool_result","content":\#(json(text)),"is_error":\#(isError)}]"#)
    }

    // MARK: 子代理

    /// 派子代理的调用（`Agent`；旧版本 `Task`）。
    static func spawn(id: String, description: String, type: String? = "general-purpose", name: String = "Agent") -> String {
        let typeField = type.map { #","subagent_type":\#(json($0))"# } ?? ""
        return toolUse(id: id, name: name,
                       input: #"{"description":\#(json(description)),"prompt":"按说明去做"\#(typeField)}"#)
    }

    /// 派子代理那次调用的结果；`agentID` 不为 nil 时行顶层带 `toolUseResult.agentId`（2.1.x 的写法）。
    static func spawnResult(id: String, agentID: String?, text: String = "子代理做完了") -> String {
        let flags = agentID.map { #","toolUseResult":{"status":"completed","agentId":"\#($0)","prompt":"按说明去做"}"# } ?? ""
        return user(content: #"[{"tool_use_id":"\#(id)","type":"tool_result","content":[{"type":"text","text":\#(json(text))}]}]"#,
                    uuid: "r-\(id)", flags: flags)
    }

    /// 子代理自己的记录里的行：`isSidechain: true`，多一个 `agentId`。
    static func sidechainUser(_ text: String, agentID: String, uuid: String = "s-u-1") -> String {
        #"{"parentUuid":null,"isSidechain":true,"agentId":"\#(agentID)","type":"user","message":{"role":"user","content":\#(json(text))},"uuid":"\#(uuid)",\#(meta(entrypoint: "cli", cwd: cwd))}"#
    }

    static func sidechainAssistant(_ blocks: String, agentID: String, uuid: String = "s-a-1") -> String {
        #"{"parentUuid":"s-u-1","isSidechain":true,"agentId":"\#(agentID)","message":{"model":"test-model","id":"msg_s","type":"message","role":"assistant","content":[\#(blocks)]},"type":"assistant","uuid":"\#(uuid)",\#(meta(entrypoint: "cli", cwd: cwd))}"#
    }

    /// `agent-<ID>.meta.json` 的内容。
    static func subagentMeta(toolUseID: String, type: String = "general-purpose", description: String, depth: Int = 1) -> Data {
        Data(#"{"agentType":\#(json(type)),"description":\#(json(description)),"spawnDepth":\#(depth),"toolUseId":"\#(toolUseID)"}"#.utf8)
    }

    static func aiTitle(_ title: String) -> String { #"{"type":"ai-title","aiTitle":\#(json(title)),"sessionId":"\#(sessionID)"}"# }
    static func customTitle(_ title: String) -> String {
        #"{"type":"custom-title","customTitle":\#(json(title)),"sessionId":"\#(sessionID)"}"#
    }
    static func lastPrompt(_ text: String) -> String {
        #"{"type":"last-prompt","lastPrompt":\#(json(text)),"leafUuid":"a-1","sessionId":"\#(sessionID)"}"#
    }
    static func noise(_ index: Int) -> String {
        #"{"type":"file-history-snapshot","messageId":"m-\#(index)","snapshot":{"trackedFileBackups":{}},"isSnapshotUpdate":false}"#
    }

    static func file(_ lines: [String]) -> Data {
        Data((lines.joined(separator: "\n") + "\n").utf8)
    }

    static func entry(_ name: String, directory: Bool = false, size: UInt64 = 0, mtime: Date = Date()) -> RemoteEntry {
        RemoteEntry(name: name, posixPermissions: directory ? 0o040755 : 0o100644, size: directory ? nil : size,
                    modifiedAt: mtime)
    }
}
