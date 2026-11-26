import XCTest
@testable import uTerm

/// 侧栏底部的账号额度：列表读每份 Codex 记录时顺带记下最后一次 `token_count` 里的额度与时间。
final class CodexRateLimitsMetadataTests: XCTestCase {
    private typealias F = CodexFixture

    private func tokenCount(used: Double, resetsAt: Int, ordinal: Int, time: String) -> String {
        F.line("event_msg", #"{"type":"token_count","info":{"last_token_usage":{"input_tokens":1000,"output_tokens":10},"model_context_window":200000},"rate_limits":{"primary":{"used_percent":\#(used),"window_minutes":300,"resets_at":\#(resetsAt)},"secondary":{"used_percent":7.5,"window_minutes":10080,"resets_at":\#(resetsAt + 86_400)},"plan_type":"plus"}}"#,
               ordinal: ordinal, time: time)
    }

    func testMetadataKeepsTheLastRateLimits() async throws {
        let lines = [F.meta(), F.user("帮我看看"), tokenCount(used: 10, resetsAt: 1_795_000_000, ordinal: 3, time: "2026-11-20T10:00:03.000Z"),
                     F.assistant("好", ordinal: 4, time: "2026-11-20T10:00:04.000Z"),
                     tokenCount(used: 41, resetsAt: 1_795_000_000, ordinal: 5, time: "2026-11-20T10:00:05.000Z")]
        let sftp = await F.host([(F.path(id: F.threadID), F.file(lines), Date(timeIntervalSince1970: 5_000))])
        let source = CodexHistorySource(provider: sftp)
        let projects = try await source.projects()
        let project = try XCTUnwrap(projects.first)
        let sessions = try await source.sessions(in: project)
        let session = try XCTUnwrap(sessions.first)
        let metadata = try await source.metadata(for: session)
        let limits = try XCTUnwrap(metadata.rateLimits)
        XCTAssertEqual(limits.primary?.usedPercent, 41)
        XCTAssertEqual(limits.primary?.windowMinutes, 300)
        XCTAssertEqual(limits.secondary?.usedPercent, 7.5)
        XCTAssertEqual(limits.plan, "plus")
        XCTAssertEqual(metadata.rateLimitsAt, ClaudeTimestamp.parse("2026-11-20T10:00:05.000Z"))
        // 用量行不算对话：标题、列不列照旧。
        XCTAssertEqual(metadata.title, "帮我看看")
    }
}
