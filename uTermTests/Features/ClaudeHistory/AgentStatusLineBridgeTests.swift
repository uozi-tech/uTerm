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

    /// 有哪几个列哪几个：只管某个模型的每周额度（`seven_day_fable`）认；认不出前缀的照原样当名字。没给 5 小时的就没有
    /// 5 小时（不补一个 0：没给不等于重置了，实测是那个会话的数据旧了）。
    func testClaudeSnapshotWithModelLimitsAndNoFiveHour() throws {
        let json = #"{"rate_limits":{"seven_day":{"used_percentage":30,"resets_at":1795600000},"seven_day_fable":{"used_percentage":92,"resets_at":1795600000},"monthly_extra":{"used_percentage":5}}}"#
        let windows = try XCTUnwrap(AgentStatusLineSnapshot.parse(Data(json.utf8), at: nil)?.rateLimits?.windows)
        XCTAssertEqual(windows.map(\.windowMinutes), [nil, 10080, 10080])
        XCTAssertEqual(windows.map(\.scope), [nil, nil, "Fable"])
        XCTAssertEqual(windows.map(AgentHistoryText.rateLimitWindow), ["monthly_extra", "每周", "每周 · Fable"])
        // 最紧的在前。
        XCTAssertEqual(AgentRateLimits.tightestFirst(windows).map(\.usedPercent), [92, 30, 5])
    }

    /// 侧栏底部：每种工具取最后一次记下的；过了重置时间的按用了 0 算、标「已重置」，不藏起来；最紧的在前。
    func testAccountLimitsKeepResetWindowsAndSortTightestFirst() async throws {
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        let claude = AgentHistoryFakeSource(tool: .claude, sessions: [])
        await claude.setStatusLine(AgentStatusLineSnapshot(rateLimits: AgentRateLimits(
            primary: .init(usedPercent: 18, windowMinutes: 300, resetsAt: now.addingTimeInterval(3600)),
            secondary: .init(usedPercent: 87, windowMinutes: 10080, resetsAt: now.addingTimeInterval(86_400)),
            plan: nil), at: now))
        let antigravity = AgentHistoryFakeSource(tool: .antigravity, sessions: [])
        await antigravity.setStatusLine(AgentStatusLineSnapshot(rateLimits: AgentRateLimits(
            primary: .init(usedPercent: 40, windowMinutes: 10080, resetsAt: now.addingTimeInterval(-60)), secondary: nil,
            plan: nil), at: now.addingTimeInterval(-86_400)))
        let model = AgentHistoryModel(source: AgentHistoryCompositeSource([claude, antigravity]), preferredDirectory: nil)
        await model.prepareStatusLines()
        let rows = model.accountLimits(now: now)
        XCTAssertEqual(rows.map(\.tool), [.claude, .antigravity])
        XCTAssertEqual(rows[0].windows.map(\.usedPercent), [87, 18])
        XCTAssertEqual(rows[1].windows.map(\.usedPercent), [0])
        XCTAssertEqual(rows[1].windows.map(\.didReset), [true])
        XCTAssertNil(rows[1].windows[0].resetsAt)
    }

    /// 每个模型最近一次报的窗口：文件名同脚本（去掉 `[1m]`、小写、别的字符换成 `_`），内容是窗口大小。
    func testModelWindows() async throws {
        XCTAssertEqual(B.modelKey("claude-opus-5-5"), "claude-opus-5-5")
        XCTAssertEqual(B.modelKey("Claude-Fable-5-2[1m]"), "claude-fable-5-2")
        XCTAssertEqual(B.modelKey("Gemini 4 Argon (Medium)"), "gemini_4_argon__medium_")
        let dir = B.modelWindowsPath(.claude, home: home)
        let sftp = MockSFTP(tree: [dir: [ClaudeFixture.entry("claude-opus-5-5", size: 8, mtime: Date()),
                                         ClaudeFixture.entry("broken", size: 3, mtime: Date())]])
        await sftp.setFile(dir + "/claude-opus-5-5", data: Data("1000000\n".utf8), mtime: Date())
        await sftp.setFile(dir + "/broken", data: Data("x\n".utf8), mtime: Date())
        let read = await B.readSnapshot(.claude, provider: sftp, home: home)
        let snapshot = try XCTUnwrap(read)
        XCTAssertEqual(snapshot.modelWindows, ["claude-opus-5-5": 1_000_000])
        XCTAssertNil(snapshot.rateLimits, "只有窗口、还没有状态栏数据")
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

/// 用量的程度（蓝 / 黄 / 红）：额度与上下文共用。
@MainActor
final class AgentUsageLevelTests: XCTestCase {
    private let now = Date(timeIntervalSince1970: 1_800_000_000)

    func testPercentThresholds() {
        XCTAssertEqual(AgentUsageLevel.of(percent: 74.9), .normal)
        XCTAssertEqual(AgentUsageLevel.of(percent: 75), .warning)
        XCTAssertEqual(AgentUsageLevel.of(percent: 89.9), .warning)
        XCTAssertEqual(AgentUsageLevel.of(percent: 90), .critical)
    }

    /// 每周额度只过了两成就用了一半：照这个速度重置前会用完，提前变黄；过了八成才用一半的不黄。
    func testWindowOnPaceToRunOutIsWarning() {
        let week = 7 * 24 * 60
        let early = AgentRateLimits.Window(usedPercent: 50, windowMinutes: week,
                                           resetsAt: now.addingTimeInterval(Double(week) * 60 * 0.8))
        XCTAssertEqual(AgentUsageLevel.of(early, now: now), .warning)
        let late = AgentRateLimits.Window(usedPercent: 50, windowMinutes: week,
                                          resetsAt: now.addingTimeInterval(Double(week) * 60 * 0.2))
        XCTAssertEqual(AgentUsageLevel.of(late, now: now), .normal)
        // 刚开头（窗口过了不到一成）、用得太少（不到 20%）都算不出速度。
        let justStarted = AgentRateLimits.Window(usedPercent: 30, windowMinutes: week,
                                                 resetsAt: now.addingTimeInterval(Double(week) * 60 * 0.95))
        XCTAssertEqual(AgentUsageLevel.of(justStarted, now: now), .normal)
        let little = AgentRateLimits.Window(usedPercent: 15, windowMinutes: week,
                                            resetsAt: now.addingTimeInterval(Double(week) * 60 * 0.9))
        XCTAssertEqual(AgentUsageLevel.of(little, now: now), .normal)
        // 用了九成：不管速度，红。
        XCTAssertEqual(AgentUsageLevel.of(.init(usedPercent: 92, windowMinutes: 300, resetsAt: nil), now: now), .critical)
    }

    /// 窄的地方只放最接近 100% 的那一个。
    func testHeadlineIsTheTightestWindow() {
        let row = AgentAccountLimits(tool: .claude, limits: AgentRateLimits(primary: nil, secondary: nil, plan: nil),
                                     windows: AgentRateLimits.tightestFirst([
                                         .init(usedPercent: 18, windowMinutes: 300, resetsAt: nil),
                                         .init(usedPercent: 87, windowMinutes: 10080, resetsAt: nil),
                                     ]), at: nil)
        XCTAssertEqual(row.headline?.usedPercent, 87)
        // 侧栏底部那一行 5 小时在前。
        XCTAssertEqual(row.compact.map(\.windowMinutes), [300, 10080])
    }

    /// Claude 的 5 小时、每周、只管 Fable 的每周都放上（5 小时在前、管全部的每周在 Fable 前）；更多时只放最紧的三个。
    func testCompactKeepsTheThreeTightestInReadingOrder() {
        let claude = AgentRateLimits.tightestFirst([
            .init(usedPercent: 3, windowMinutes: 300, resetsAt: nil),
            .init(usedPercent: 93, windowMinutes: 10080, resetsAt: nil),
            .init(usedPercent: 24, windowMinutes: 10080, resetsAt: nil, scope: "Fable"),
        ])
        let row = AgentAccountLimits(tool: .claude, limits: AgentRateLimits(primary: nil, secondary: nil, plan: nil),
                                     windows: claude, at: nil)
        XCTAssertEqual(row.compact.map(\.usedPercent), [3, 93, 24])
        XCTAssertEqual(row.compact.map(AgentHistoryText.rateLimitShortName), ["5 小时", "每周", "Fable"])
        let many = AgentAccountLimits(tool: .antigravity, limits: AgentRateLimits(primary: nil, secondary: nil, plan: nil),
                                      windows: AgentRateLimits.tightestFirst([
                                          .init(usedPercent: 10, windowMinutes: nil, resetsAt: nil, label: "a"),
                                          .init(usedPercent: 60, windowMinutes: nil, resetsAt: nil, label: "b"),
                                          .init(usedPercent: 95, windowMinutes: nil, resetsAt: nil, label: "c"),
                                          .init(usedPercent: 40, windowMinutes: nil, resetsAt: nil, label: "d"),
                                      ]), at: nil)
        XCTAssertEqual(many.compact.map(\.label), ["c", "b", "d"])
    }
}

/// Claude Code 自己缓存的 `/usage`（`~/.claude.json` 的 `cachedUsageUtilization`）：5 小时、每周、只管 Fable 的每周；
/// 和状态栏合在一起时按时间新旧取。
@MainActor
final class ClaudeUsageCacheTests: XCTestCase {
    private let json = #"{"numStartups":3,"cachedUsageUtilization":{"fetchedAtMs":1795739758050,"utilization":{"five_hour":{"utilization":3,"resets_at":"2026-11-27T05:10:00.083166+00:00"},"seven_day":{"utilization":93,"resets_at":"2026-11-27T14:00:00.083186+00:00"},"limits":[{"kind":"session","group":"session","percent":3,"severity":"normal","resets_at":"2026-11-27T05:10:00.083166+00:00","scope":null},{"kind":"weekly_all","group":"weekly","percent":93,"severity":"critical","resets_at":"2026-11-27T14:00:00.083186+00:00","scope":null},{"kind":"weekly_scoped","group":"weekly","percent":24,"resets_at":"2026-11-27T14:00:00.083330+00:00","scope":{"model":{"id":null,"display_name":"Fable"},"surface":null}}]}}}"#

    func testParsesSessionWeeklyAndModelScopedLimits() throws {
        let (limits, at) = try XCTUnwrap(ClaudeUsageCache.parse(Data(json.utf8)))
        XCTAssertEqual(at, Date(timeIntervalSince1970: 1_795_739_758.05))
        XCTAssertEqual(limits.windows.map(\.usedPercent), [3, 93, 24])
        XCTAssertEqual(limits.windows.map(\.windowMinutes), [300, 10080, 10080])
        XCTAssertEqual(limits.windows.map(\.scope), [nil, nil, "Fable"])
        XCTAssertEqual(limits.windows.map(AgentHistoryText.rateLimitWindow), ["5 小时", "每周", "每周 · Fable"])
        XCTAssertEqual(limits.windows[0].resetsAt, ClaudeTimestamp.parse("2026-11-27T05:10:00.083166+00:00"))
    }

    /// Mac 侧栏底部那一行悬停看全部：额度按 5 小时、每周、Fable 的顺序，最后是上下文。
    func testSummaryListsEverything() throws {
        let (limits, _) = try XCTUnwrap(ClaudeUsageCache.parse(Data(json.utf8)))
        let row = AgentAccountLimits(tool: .claude, limits: limits, windows: AgentRateLimits.tightestFirst(limits.windows),
                                     at: nil)
        let context = AgentTurnUsage(model: nil, contextTokens: 850_000, outputTokens: 0, contextWindow: 1_000_000)
        XCTAssertEqual(AgentHistoryText.accountLimitsSummary([row], context: context),
                       "5 小时 3% · 每周 93% · Fable 24% · 上下文 85%")
    }

    /// 没有缓存的（没登录订阅账号、老版本）为 nil。
    func testWithoutCache() {
        XCTAssertNil(ClaudeUsageCache.parse(Data(#"{"numStartups":3}"#.utf8)))
    }

    /// 有缓存就只用缓存的，状态栏文件更新也不用（它的额度是那个会话最后一次 API 回应带的，可能早就旧了）。
    func testMergeWithStatusLine() throws {
        let cache = try XCTUnwrap(ClaudeUsageCache.parse(Data(json.utf8)))
        let cacheAt = try XCTUnwrap(cache.at)
        var status = AgentStatusLineSnapshot(rateLimits: AgentRateLimits(
            primary: .init(usedPercent: 10, windowMinutes: 300, resetsAt: nil),
            secondary: .init(usedPercent: 95, windowMinutes: 10080, resetsAt: nil), plan: nil),
            at: cacheAt.addingTimeInterval(-60))
        XCTAssertEqual(status.merging(usageCache: cache).rateLimits?.windows.map(\.usedPercent), [3, 93, 24])
        status.at = cacheAt.addingTimeInterval(60)
        XCTAssertEqual(status.merging(usageCache: cache).rateLimits?.windows.map(\.usedPercent), [3, 93, 24])
        XCTAssertEqual(status.merging(usageCache: cache).at, cacheAt)
        // 没有缓存：用状态栏的。
        XCTAssertEqual(status.merging(usageCache: nil).rateLimits?.windows.map(\.usedPercent), [10, 95])
    }

    /// 状态栏没给 5 小时的：不补一个「0% 已重置」（实测那时 5 小时其实用了 6%），没有就不显示。
    func testStatusLineWithoutFiveHourDoesNotInventOne() throws {
        let json = #"{"rate_limits":{"seven_day":{"used_percentage":91,"resets_at":1795788000}}}"#
        let windows = try XCTUnwrap(AgentStatusLineSnapshot.parse(Data(json.utf8), at: nil)?.rateLimits?.windows)
        XCTAssertEqual(windows.map(\.windowMinutes), [10080])
    }
}

/// 正露着一个跑着的会话、它的记录没开着（iOS 镜像 Mac 正跑着的会话）：上下文照样有，单独读它记录的末尾。
@MainActor
final class AgentContextUsageFocusTests: XCTestCase {
    func testFocusedSessionWithoutOpenRecordStillHasContext() async throws {
        let usage = AgentTurnUsage(model: "claude-opus-5-5", contextTokens: 841_000, outputTokens: 10)
        let claude = AgentHistoryFakeSource(tool: .claude, sessions: [
            .init(id: "s-run", projectID: "-p", resumeDirectory: "/p", title: "跑着的", modifiedAt: Date(),
                  items: [AgentTranscriptItem(id: "a.0", kind: .assistantText("好")),
                          AgentTranscriptItem(id: "a.1", kind: .usage(usage))]),
        ])
        await claude.setStatusLine(AgentStatusLineSnapshot(modelWindows: ["claude-opus-5-5": 1_000_000]))
        let model = AgentHistoryModel(source: claude, preferredDirectory: nil)
        await model.start()
        await model.prepareStatusLines()
        let file = try XCTUnwrap(model.files.first)
        XCTAssertNil(model.transcript)
        XCTAssertNil(model.currentContextUsage)

        model.contextSessionPath = file.path
        await model.refreshContextUsage()
        XCTAssertNil(model.transcript, "不替它打开记录")
        XCTAssertEqual(model.currentContextUsage?.contextTokens, 841_000)
        XCTAssertEqual(model.currentContextUsage?.contextWindow, 1_000_000, "窗口按状态栏记下的模型窗口补上")

        // 不看了：没有上下文。
        model.contextSessionPath = nil
        XCTAssertNil(model.currentContextUsage)
    }
}
