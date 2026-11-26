import XCTest
@testable import uTerm

/// 状态栏转接：装到主机上的几个文件、传给 `--settings` 的 JSON、起会话的命令、两家状态栏数据的解析，以及脚本本身
/// （存一份、原样交给你自己的状态栏命令、没配就不输出）。
@MainActor
final class AgentStatusLineBridgeTests: XCTestCase {
    private typealias B = AgentStatusLineBridge
    private let home = "/home/user"

    // MARK: 装

    /// 你配了状态栏：记下你的命令，`--settings` 里换成转接脚本、照抄 padding；你的 settings.json 不动。
    func testInstallKeepsTheUserCommand() async throws {
        let sftp = MockSFTP()
        let user = Data(#"{"model":"opus","statusLine":{"type":"command","command":"~/.claude/statusline.sh","padding":1}}"#.utf8)
        await sftp.setFile(home + "/.claude/settings.json", data: user, mtime: Date())
        let path = try await B.install(.claude, provider: sftp, home: home)
        XCTAssertEqual(path, home + "/.local/share/uterm/statusline/claude.settings.json")

        let script = try await sftp.download(remotePath: B.scriptPath(home: home))
        XCTAssertEqual(String(decoding: script, as: UTF8.self), B.script)
        let original = try await sftp.download(remotePath: B.originalPath(.claude, home: home))
        XCTAssertEqual(String(decoding: original, as: UTF8.self), "~/.claude/statusline.sh")
        let written = try await sftp.download(remotePath: path)
        let settings = try XCTUnwrap(try JSONSerialization.jsonObject(with: written) as? [String: Any])
        let line = try XCTUnwrap(settings["statusLine"] as? [String: Any])
        XCTAssertEqual(line["command"] as? String, "sh '\(B.scriptPath(home: home))' claude")
        XCTAssertEqual(line["padding"] as? Int, 1)
        XCTAssertEqual(settings.count, 1, "只带状态栏，别的设置照你自己的")
        let userAfter = try await sftp.download(remotePath: home + "/.claude/settings.json")
        XCTAssertEqual(userAfter, user)
    }

    /// 没配状态栏：不留你原来的命令（脚本什么都不输出）；Antigravity 叠在自带的那一行下面，看到的还是自带的。
    func testInstallWithoutUserStatusLine() async throws {
        let sftp = MockSFTP()
        let path = try await B.install(.antigravity, provider: sftp, home: home)
        let removed = await sftp.removedFiles
        XCTAssertEqual(removed, [B.originalPath(.antigravity, home: home)])
        let written = try await sftp.download(remotePath: path)
        let settings = try XCTUnwrap(try JSONSerialization.jsonObject(with: written) as? [String: Any])
        let line = try XCTUnwrap(settings["statusLine"] as? [String: Any])
        XCTAssertEqual(line["stack_with_default"] as? Bool, true)
        XCTAssertEqual(line["command"] as? String, "sh '\(B.scriptPath(home: home))' antigravity")
    }

    /// 关掉了的（`enabled: false`）、空命令都当没配。
    func testUserStatusLineParsing() {
        XCTAssertNil(B.UserStatusLine(settings: Data(#"{"model":"x"}"#.utf8)))
        XCTAssertNil(B.UserStatusLine(settings: Data(#"{"statusLine":{"command":"a","enabled":false}}"#.utf8))?.command)
        XCTAssertNil(B.UserStatusLine(settings: Data(#"{"statusLine":{"command":"  "}}"#.utf8))?.command)
        let line = B.UserStatusLine(settings: Data(#"{"statusLine":{"command":"x.sh","stack_with_default":true}}"#.utf8))
        XCTAssertEqual(line?.command, "x.sh")
        XCTAssertEqual(line?.stacksWithDefault, true)
    }

    // MARK: 命令

    func testCommandsCarrySettingsOnlyWhenInstalled() {
        let id = "0f1e2d3c-4b5a-6978-8a9b-0c1d2e3f4a5b"
        XCTAssertEqual(ClaudeResumeCommand.make(sessionID: id, directory: "/srv/app"), "cd -- '/srv/app' && claude --resume \(id)")
        XCTAssertEqual(ClaudeResumeCommand.make(sessionID: id, directory: "/srv/app", settings: "/home/u/.local/share/uterm/statusline/claude.settings.json"),
                       "cd -- '/srv/app' && claude --settings '/home/u/.local/share/uterm/statusline/claude.settings.json' --resume \(id)")
        XCTAssertEqual(ClaudeResumeCommand.makeNew(directory: "/srv/app", settings: "/h/s.json"),
                       "cd -- '/srv/app' && claude --settings '/h/s.json'")
        XCTAssertEqual(AntigravityResumeCommand.resume(sessionID: id, directory: "/srv/app", settings: "/h/a.json"),
                       "cd -- '/srv/app' && agy --settings '/h/a.json' --conversation \(id)")
        XCTAssertEqual(AntigravityResumeCommand.newSession(directory: "/srv/app", settings: nil), "cd -- '/srv/app' && agy")
    }

    // MARK: 数据

    /// Claude Code 状态栏：5 小时与每周两个时间窗（用了几成、几时重置），上下文窗口多大。
    func testClaudeSnapshot() throws {
        let json = #"{"session_id":"ABC","model":{"id":"claude-opus-5-5"},"context_window":{"context_window_size":1000000,"used_percentage":23},"rate_limits":{"five_hour":{"used_percentage":12.5,"resets_at":1795203304},"seven_day":{"used_percentage":40,"resets_at":1795600000}}}"#
        let snapshot = try XCTUnwrap(AgentStatusLineSnapshot.parse(Data(json.utf8), at: nil))
        XCTAssertEqual(snapshot.sessionID, "abc")
        XCTAssertEqual(snapshot.contextWindow, 1_000_000)
        XCTAssertEqual(snapshot.rateLimits?.windows, [
            AgentRateLimits.Window(usedPercent: 12.5, windowMinutes: 300, resetsAt: Date(timeIntervalSince1970: 1_795_203_304)),
            AgentRateLimits.Window(usedPercent: 40, windowMinutes: 10080, resetsAt: Date(timeIntervalSince1970: 1_795_600_000)),
        ])
    }

    /// 不是订阅账号（没有 `rate_limits`）：没有额度，窗口照样有；窗口 0 当不知道。
    func testClaudeSnapshotWithoutRateLimits() throws {
        let json = #"{"session_id":"a","context_window":{"context_window_size":0}}"#
        let snapshot = try XCTUnwrap(AgentStatusLineSnapshot.parse(Data(json.utf8), at: nil))
        XCTAssertNil(snapshot.rateLimits)
        XCTAssertNil(snapshot.contextWindow)
    }

    /// Antigravity 状态栏：每个 bucket 一个时间窗，剩几成换算成用了几成，bucket 名当名字；关掉的、只给剩余数量的不算。
    func testAntigravitySnapshot() throws {
        let json = #"{"conversation_id":"c-1","plan_tier":"pro","quota":{"gemini-weekly":{"remaining_fraction":0.9378,"reset_time":"2026-11-30T00:00:00Z","reset_in_seconds":100},"claude-5h":{"remaining_fraction":0.25,"reset_time":"2026-11-26T15:00:00Z"},"off":{"remaining_fraction":1,"disabled":true},"credits":{"remaining_amount":12}}}"#
        let snapshot = try XCTUnwrap(AgentStatusLineSnapshot.parse(Data(json.utf8), at: nil))
        XCTAssertEqual(snapshot.sessionID, "c-1")
        let limits = try XCTUnwrap(snapshot.rateLimits)
        XCTAssertEqual(limits.plan, "pro")
        XCTAssertEqual(limits.windows.map(\.label), ["claude-5h", "gemini-weekly"])
        XCTAssertEqual(limits.windows[0].usedPercent, 75, accuracy: 1e-9)
        XCTAssertEqual(limits.windows[1].usedPercent, 6.22, accuracy: 1e-9)
        XCTAssertEqual(limits.windows[1].resetsAt, ClaudeTimestamp.parse("2026-11-30T00:00:00Z"))
        XCTAssertEqual(AgentHistoryText.rateLimitWindow(limits.windows[1]), "gemini-weekly")
    }
}
