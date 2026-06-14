import XCTest
@testable import uTerm

/// `AssistantModel` 的两个 `nonisolated static` 纯函数（「猜你想问」追问）单测：
/// `parseJSONArray`（抠模型输出里的 JSON 字符串数组）与
/// `heuristicFollowUps`（关键词 + 工具卡状态路由到追问池）。
/// 二者均无副作用、无需 `@MainActor`、无需构造 `AssistantModel` 实例。
final class AssistantModelFollowUpsTests: XCTestCase {

    /// 关键词/工具卡都未命中时恒定追加的兜底池（顺序敏感）。
    private let fallback = ["当前服务器健康度", "列出最近的告警", "生成一份巡检报告"]

    // MARK: helpers

    private func user(_ text: String) -> ChatMessage {
        ChatMessage(role: .user, text: text)
    }

    private func assistant(_ text: String, tools: [ToolCallState] = []) -> ChatMessage {
        ChatMessage(role: .assistant, text: text, toolCalls: tools)
    }

    private func tool(command: String = "echo ok", explanation: String? = nil,
                      status: ToolCallState.Status = .pending, id: String = "tc") -> ToolCallState {
        ToolCallState(id: id, name: "run_command", command: command,
                      explanation: explanation, status: status)
    }

    // MARK: - parseJSONArray

    func testParsePlainStringArray() {
        XCTAssertEqual(AssistantModel.parseJSONArray(#"["a","b"]"#), ["a", "b"])
    }

    func testParseExtractsFromCodeFence() {
        let raw = """
        ```json
        ["重启 Nginx", "查看磁盘"]
        ```
        """
        XCTAssertEqual(AssistantModel.parseJSONArray(raw), ["重启 Nginx", "查看磁盘"])
    }

    func testParseExtractsFromSurroundingProse() {
        let raw = "好的，建议如下：[\"扩容磁盘\", \"重启服务\"]。如有需要再说。"
        XCTAssertEqual(AssistantModel.parseJSONArray(raw), ["扩容磁盘", "重启服务"])
    }

    /// 数组里混入非字符串元素时，compactMap 只保留字符串项。
    func testParseFiltersOutNonStringElements() {
        let raw = #"["保留", 42, "保留2", true, null]"#
        XCTAssertEqual(AssistantModel.parseJSONArray(raw), ["保留", "保留2"])
    }

    func testParseReturnsNilWhenNoBrackets() {
        XCTAssertNil(AssistantModel.parseJSONArray("这里没有任何数组，只是纯文本"))
    }

    /// 只有 `[` 没有 `]`：lastIndex(of:"]") 为 nil → nil。
    func testParseReturnsNilWhenNoClosingBracket() {
        XCTAssertNil(AssistantModel.parseJSONArray(#"好的：["建议一", "建议二""#))
    }

    /// `]` 出现在 `[` 之前：start < end 不成立 → nil。
    func testParseReturnsNilWhenClosingBracketBeforeOpening() {
        XCTAssertNil(AssistantModel.parseJSONArray("]错位的括号["))
    }

    /// 元素首尾空白被 trim；trim 后为空串的元素被滤掉。
    func testParseTrimsElementsAndDropsBlanks() {
        let raw = #"["  trimmed  ", "", "  keep  "]"#
        XCTAssertEqual(AssistantModel.parseJSONArray(raw), ["trimmed", "keep"])
    }

    /// 合法但空的数组 → 过滤后无内容 → nil。
    func testParseReturnsNilForEmptyArray() {
        XCTAssertNil(AssistantModel.parseJSONArray("[]"))
    }

    /// 全是空白串的数组 → trim 后全空被滤掉 → nil。
    func testParseReturnsNilWhenAllElementsBlank() {
        XCTAssertNil(AssistantModel.parseJSONArray(#"["   ", "  ", ""]"#))
    }

    // MARK: - heuristicFollowUps：关键词路由

    func testDiskKeywordRoutesToDiskPool() {
        let out = AssistantModel.heuristicFollowUps([user("磁盘快满了，帮我清理一下")])
        XCTAssertEqual(out, ["还有哪些大文件", "清理后还剩多少空间", "设置磁盘告警阈值"])
    }

    /// 「日志」是磁盘正则的别名之一，应路由到磁盘池。
    func testLogKeywordAliasesToDiskPool() {
        let out = AssistantModel.heuristicFollowUps([user("帮我查看一下日志")])
        XCTAssertTrue(out.contains("还有哪些大文件"), "日志关键词应命中磁盘池，实际：\(out)")
    }

    func testMemoryKeywordRoutesToMemoryPool() {
        let out = AssistantModel.heuristicFollowUps([user("内存告警了")])
        XCTAssertTrue(out.contains("哪个进程最吃内存"), "内存关键词应命中内存池，实际：\(out)")
    }

    func testCpuKeywordRoutesToCpuPool() {
        let out = AssistantModel.heuristicFollowUps([user("CPU 负载很高")])
        XCTAssertTrue(out.contains("看看是哪个进程"), "CPU/负载关键词应命中 CPU 池，实际：\(out)")
    }

    func testNginxKeywordRoutesToNginxPool() {
        let out = AssistantModel.heuristicFollowUps([user("nginx 报 502 了")])
        XCTAssertTrue(out.contains("看 nginx 错误日志"), "nginx 关键词应命中 nginx 池，实际：\(out)")
    }

    func testRestartKeywordRoutesToRestartPool() {
        let out = AssistantModel.heuristicFollowUps([user("帮我重启一下服务")])
        XCTAssertTrue(out.contains("确认服务已起来"), "重启关键词应命中部署池，实际：\(out)")
    }

    // MARK: - heuristicFollowUps：工具卡状态路由

    /// pending 工具调用 → 追加「先看看会影响什么 / 执行后怎么验证」并居前。
    func testPendingToolCallSurfacesImpactPrompts() {
        let out = AssistantModel.heuristicFollowUps([assistant("", tools: [tool(status: .pending)])])
        XCTAssertEqual(out.first, "先看看会影响什么")
        XCTAssertTrue(out.contains("执行后怎么验证"), "pending 应带出验证类追问，实际：\(out)")
        XCTAssertEqual(out.count, 3)
    }

    /// done 工具调用 → 追加「解释下这段输出 / 导出结果到文件」并居前。
    func testDoneToolCallSurfacesExplainPrompts() {
        let out = AssistantModel.heuristicFollowUps([assistant("", tools: [tool(status: .done)])])
        XCTAssertEqual(out.first, "解释下这段输出")
        XCTAssertTrue(out.contains("导出结果到文件"), "done 应带出导出类追问，实际：\(out)")
        XCTAssertEqual(out.count, 3)
    }

    /// 文本为空时改读工具卡的 explanation + command 做关键词路由；
    /// 且 .running 既非 pending 也非 done，不应触发那两个池。
    func testEmptyTextMessageRoutesViaToolCommandAndExplanation() {
        let msg = assistant("", tools: [
            tool(command: "df -h /var/log", explanation: "检查磁盘占用", status: .running),
        ])
        let out = AssistantModel.heuristicFollowUps([msg])
        XCTAssertEqual(out, ["还有哪些大文件", "清理后还剩多少空间", "设置磁盘告警阈值"])
        XCTAssertFalse(out.contains("先看看会影响什么"), ".running 不应触发 pending 池")
        XCTAssertFalse(out.contains("解释下这段输出"), ".running 不应触发 done 池")
    }

    // MARK: - heuristicFollowUps：兜底 / 取前 3 / 去重 / 窗口

    /// 空对话回退到兜底池，且恰好 3 条。
    func testEmptyConversationFallsBackToDefaults() {
        let out = AssistantModel.heuristicFollowUps([])
        XCTAssertEqual(out, fallback)
        XCTAssertEqual(out.count, 3)
        XCTAssertLessThanOrEqual(out.count, 3)
    }

    /// 多池同时命中：截到前 3、无重复，并验证池的优先级顺序（pending > done > 关键词）。
    func testResultIsCappedAtThreeAndDeduplicated() {
        let msg = assistant("磁盘和内存都告警", tools: [
            tool(status: .pending, id: "a"),
            tool(status: .done, id: "b"),
        ])
        let out = AssistantModel.heuristicFollowUps([msg])
        XCTAssertEqual(out.count, 3)
        XCTAssertEqual(Set(out).count, out.count, "结果不应有重复项")
        XCTAssertEqual(out, ["先看看会影响什么", "执行后怎么验证", "解释下这段输出"])
    }

    /// 只读最近 4 条：更早消息里的关键词不参与路由。
    func testOnlyLastFourMessagesConsidered() {
        let msgs = [
            user("磁盘满了"),        // 第 5 条之外，应被 suffix(4) 丢弃
            user("早上好"),
            assistant("收到"),
            user("谢谢"),
            assistant("没问题"),
        ]
        let out = AssistantModel.heuristicFollowUps(msgs)
        XCTAssertEqual(out, fallback)
        XCTAssertFalse(out.contains("还有哪些大文件"), "窗口外的「磁盘」不应触发磁盘池，实际：\(out)")
    }
}
