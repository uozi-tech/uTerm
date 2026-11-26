import XCTest
@testable import uTerm

/// 三家记录里的用量换算成 `AgentTurnUsage`（字段照本机真实记录的形状，2026-11）。用量是不画的条目，标题块取最后一条。
final class AgentTurnUsageTests: XCTestCase {
    private func usages(_ items: [AgentTranscriptItem]) -> [AgentTurnUsage] {
        items.compactMap { if case .usage(let usage) = $0.kind { return usage } else { return nil } }
    }

    // MARK: Claude Code

    /// 上下文 = 输入 + 缓存写入 + 缓存读取；不知道窗口（同一个模型有两种），不算百分比；放在这一行最后，前面的 ID 不变。
    func testClaudeAssistantLineCarriesUsage() {
        let line = #"{"type":"assistant","isSidechain":false,"timestamp":"2026-11-26T08:00:00.000Z","message":{"model":"claude-opus-5-5","role":"assistant","content":[{"type":"text","text":"好"}],"usage":{"input_tokens":15243,"cache_creation_input_tokens":57057,"cache_read_input_tokens":418189,"output_tokens":508}}}"#
        let items = ClaudeTranscriptParser.items(fromJSON: Data(line.utf8), idPrefix: "7")
        XCTAssertEqual(items.map(\.id), ["7.0", "7.1"])
        XCTAssertEqual(usages(items), [AgentTurnUsage(model: "claude-opus-5-5", contextTokens: 490_489, outputTokens: 508)])
        XCTAssertNil(usages(items).first?.contextFraction)
        XCTAssertFalse(items[1].isDisplayed)
    }

    /// 出错时 Claude Code 自己补的回答（`<synthetic>`）不算用量。
    func testClaudeSyntheticReplyHasNoUsage() {
        let line = #"{"type":"assistant","message":{"model":"<synthetic>","role":"assistant","content":[{"type":"text","text":"API Error"}],"usage":{"input_tokens":0,"output_tokens":0}}}"#
        XCTAssertTrue(usages(ClaudeTranscriptParser.items(fromJSON: Data(line.utf8), idPrefix: "1")).isEmpty)
    }

    // MARK: Codex

    /// `token_count`：这一次的用量、窗口大小与账号额度都在；行首判断要放它进来。
    func testCodexTokenCountCarriesWindowAndRateLimits() throws {
        let line = #"{"timestamp":"2026-11-15T14:04:46.083Z","ordinal":22,"type":"event_msg","payload":{"type":"token_count","info":{"total_token_usage":{"input_tokens":1239663,"output_tokens":6764},"last_token_usage":{"input_tokens":78591,"cached_input_tokens":76288,"output_tokens":225,"total_tokens":78816},"model_context_window":828400},"rate_limits":{"primary":{"used_percent":22.0,"window_minutes":10080,"resets_at":1795203304},"secondary":null,"plan_type":"prolite"}}}"#
        XCTAssertTrue(CodexTranscriptParser.isMessageCandidate(head: Data(line.utf8)))
        let usage = try XCTUnwrap(usages(CodexTranscriptParser.items(fromJSON: Data(line.utf8), idPrefix: "3")).first)
        XCTAssertEqual(usage.contextTokens, 78591)
        XCTAssertEqual(usage.outputTokens, 225)
        XCTAssertEqual(usage.contextWindow, 828_400)
        XCTAssertEqual(try XCTUnwrap(usage.contextFraction), 78591.0 / 828_400, accuracy: 1e-9)
        let limits = try XCTUnwrap(usage.rateLimits)
        XCTAssertEqual(limits.plan, "prolite")
        XCTAssertEqual(limits.windows, [AgentRateLimits.Window(usedPercent: 22, windowMinutes: 10080,
                                                               resetsAt: Date(timeIntervalSince1970: 1_795_203_304))])
        XCTAssertNil(limits.secondary)
    }

    /// 别的 `event_msg` 照旧不显示（一句话不出现两次）。
    func testCodexOtherEventsStayHidden() {
        let line = #"{"timestamp":"2026-11-15T14:04:46.083Z","ordinal":23,"type":"event_msg","payload":{"type":"agent_message","message":"好"}}"#
        XCTAssertFalse(CodexTranscriptParser.isMessageCandidate(head: Data(line.utf8)))
    }

    // MARK: Antigravity

    /// 模型的一步：输入 + 缓存读取（没有缓存写入）；模型名照记录。
    func testAntigravityPlannerStepCarriesUsage() {
        let line = #"{"step_index":69,"source":"MODEL","type":"PLANNER_RESPONSE","status":"DONE","created_at":"2026-11-20T10:00:00Z","content":"好了","model":"gemini-4-carbon-high","input_tokens":2770,"cache_read_tokens":229236,"output_tokens":2365}"#
        let items = AntigravityTranscriptParser.items(fromJSON: Data(line.utf8), idPrefix: "9")
        XCTAssertEqual(usages(items), [AgentTurnUsage(model: "gemini-4-carbon-high", contextTokens: 232_006, outputTokens: 2365)])
    }

    // MARK: 排版

    /// 用量不排成一行，也不算「换了说话的一方」。
    func testLayoutSkipsUsage() {
        let usage = AgentTranscriptItem(id: "a.1", kind: .usage(AgentTurnUsage(model: nil, contextTokens: 10, outputTokens: 1)))
        let layout = AgentTranscriptLayout(items: [AgentTranscriptItem(id: "a.0", kind: .assistantText("好")), usage,
                                                   AgentTranscriptItem(id: "b.0", kind: .assistantText("再"))])
        XCTAssertEqual(layout.rows.map(\.id), ["a.0", "b.0"])
        XCTAssertEqual(layout.rows.filter(\.startsRun).map(\.id), ["a.0"])
    }
}
