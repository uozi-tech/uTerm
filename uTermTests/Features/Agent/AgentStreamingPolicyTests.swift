import XCTest
@testable import uTerm

@MainActor
final class AgentStreamingPolicyTests: XCTestCase {
    func testStreamingBufferPublishesTailWithoutAnotherEvent() async {
        let tailPublished = expectation(description: "buffered tail published by timer")
        var publications: [String] = []
        let buffer = StreamingTextBuffer(publishInterval: .milliseconds(20)) { text in
            publications.append(text)
            if publications.count == 2 { tailPublished.fulfill() }
        }

        buffer.append("A")
        buffer.append("B")
        buffer.append("C")

        XCTAssertEqual(publications, ["A"])
        await fulfillment(of: [tailPublished], timeout: 1)
        XCTAssertEqual(publications, ["A", "BC"])
    }

    func testStreamingBufferManualFlushCancelsScheduledPublication() async throws {
        var publications: [String] = []
        let buffer = StreamingTextBuffer(publishInterval: .milliseconds(40)) {
            publications.append($0)
        }

        buffer.append("first")
        buffer.append(" tail")
        buffer.flush()
        try await Task.sleep(for: .milliseconds(80))

        XCTAssertEqual(publications, ["first", " tail"])
    }

    func testCancelledStreamingBufferDiscardsScheduledTail() async throws {
        var publications: [String] = []
        let buffer = StreamingTextBuffer(publishInterval: .milliseconds(20)) {
            publications.append($0)
        }
        buffer.append("first")
        buffer.append("obsolete tail")
        buffer.cancel()
        try await Task.sleep(for: .milliseconds(60))
        buffer.flush()
        XCTAssertEqual(publications, ["first"])
    }

    func testMarkdownRendererUsesLatestSourceAtThrottleDeadline() async throws {
        let renderer = StreamingMarkdownRenderer(reparseDelay: .milliseconds(20))
        renderer.renderImmediately("A")

        renderer.update("AB", isStreaming: true)
        renderer.update("ABC", isStreaming: true)
        try await Task.sleep(for: .milliseconds(50))

        XCTAssertEqual(renderer.renderedSource, "ABC")
    }

    /// iOS 打开的两个选项：按长度放大的节流间隔（8KB 一档、最多 5 倍），落定后走缓存。
    func testMarkdownRendererScaledDelayAndSettledCache() async throws {
        let base = Duration.milliseconds(100)
        XCTAssertEqual(StreamingMarkdownRenderer.scaledDelay(base: base, bytes: 0), .milliseconds(100))
        XCTAssertEqual(StreamingMarkdownRenderer.scaledDelay(base: base, bytes: 8_192), .milliseconds(200))
        XCTAssertEqual(StreamingMarkdownRenderer.scaledDelay(base: base, bytes: 1_000_000), .milliseconds(500))

        let cache = MarkdownDocumentCache(capacity: 2)
        let renderer = StreamingMarkdownRenderer(reparseDelay: .milliseconds(20),
                                                 scalesDelayWithLength: true, settledCache: cache)
        renderer.renderImmediately("A", isStreaming: true)
        renderer.update("AB", isStreaming: true)
        renderer.update("ABC", isStreaming: true)
        try await Task.sleep(for: .milliseconds(60))
        XCTAssertEqual(renderer.renderedSource, "ABC", "节流窗口到点解析的是最新文本")

        renderer.update("**done**", isStreaming: false)
        XCTAssertEqual(renderer.renderedSource, "**done**")
        XCTAssertEqual(renderer.document.format(), cache.document(for: "**done**").format())
    }

    // MARK: - 贴底滚动合并器

    func testTailScrollCoalescerFiresOncePerWindow() async throws {
        let coalescer = TailScrollCoalescer(delay: 0.02)
        var fired = 0
        coalescer.schedule { fired += 1 }
        coalescer.schedule { fired += 100 }   // 窗口里已有一次：合并掉
        XCTAssertTrue(coalescer.isPending)
        try await Task.sleep(for: .milliseconds(80))
        XCTAssertEqual(fired, 1)
        XCTAssertFalse(coalescer.isPending)
        coalescer.schedule { fired += 1 }     // 窗口过了，下一次照常排
        try await Task.sleep(for: .milliseconds(80))
        XCTAssertEqual(fired, 2)
    }

    func testTailScrollCoalescerRestartDebouncesAndCancelDrops() async throws {
        let coalescer = TailScrollCoalescer(delay: 0.03)
        var log: [String] = []
        coalescer.restart { log.append("first") }
        coalescer.restart { log.append("second") }   // 重新计时，只留最后一次
        try await Task.sleep(for: .milliseconds(100))
        XCTAssertEqual(log, ["second"])
        coalescer.schedule { log.append("dropped") }
        coalescer.cancel()
        try await Task.sleep(for: .milliseconds(80))
        XCTAssertEqual(log, ["second"])
    }

    func testNearBottomPolicyAllowsShortContentAndToleranceBand() {
        XCTAssertTrue(AgentScrollPolicy.isNearBottom(
            visibleMaxY: 400, contentHeight: 300))
        XCTAssertTrue(AgentScrollPolicy.isNearBottom(
            visibleMaxY: 910, contentHeight: 1_000))
        XCTAssertFalse(AgentScrollPolicy.isNearBottom(
            visibleMaxY: 800, contentHeight: 1_000))
    }

    func testNearBottomPolicyRejectsInvalidGeometry() {
        XCTAssertFalse(AgentScrollPolicy.isNearBottom(
            visibleMaxY: .nan, contentHeight: 1_000))
        XCTAssertFalse(AgentScrollPolicy.isNearBottom(
            visibleMaxY: 1_000, contentHeight: .infinity))
    }

    private typealias Tail = AgentScrollPolicy.TailGeometry

    func testTailGeometryMeasuresContentBeyondViewport() {
        let pinned = Tail(contentHeight: 1_000, containerHeight: 600, visibleMaxY: 1_000)
        XCTAssertEqual(pinned.scrollableHeight, 400)
        XCTAssertTrue(pinned.isNearBottom)
        let short = Tail(contentHeight: 300, containerHeight: 600, visibleMaxY: 600)
        XCTAssertEqual(short.scrollableHeight, 0)
        XCTAssertEqual(Tail(contentHeight: .nan, containerHeight: 600, visibleMaxY: 600).scrollableHeight, 0)
    }

    func testRepinWhenPinnedContentGrows() {
        // Markdown 重排把内容撑高 120pt：视口还停在旧底边。
        let before = Tail(contentHeight: 1_000, containerHeight: 600, visibleMaxY: 1_000)
        let after = Tail(contentHeight: 1_120, containerHeight: 600, visibleMaxY: 1_000)
        XCTAssertTrue(AgentScrollPolicy.needsRepin(from: before, to: after))
    }

    func testRepinWhenQueueStripShrinksViewport() {
        // 排队条带出现把视口挤矮 40pt：内容一点没变，底边照样被挤出去。
        let before = Tail(contentHeight: 1_000, containerHeight: 600, visibleMaxY: 1_000)
        let after = Tail(contentHeight: 1_000, containerHeight: 560, visibleMaxY: 960)
        XCTAssertTrue(AgentScrollPolicy.needsRepin(from: before, to: after))
    }

    func testNoRepinWhenViewportWasAwayFromBottom() {
        // 拖滚动条停在中段（没有手势相位，followsTail 仍是 true）：懒栈重估行高
        // 把内容撑高也不能拽回底部。
        let before = Tail(contentHeight: 3_000, containerHeight: 600, visibleMaxY: 1_400)
        let after = Tail(contentHeight: 3_400, containerHeight: 600, visibleMaxY: 1_400)
        XCTAssertFalse(AgentScrollPolicy.needsRepin(from: before, to: after))
    }

    func testNoRepinWhenScrollableHeightHoldsOrShrinks() {
        let pinned = Tail(contentHeight: 1_000, containerHeight: 600, visibleMaxY: 1_000)
        XCTAssertFalse(AgentScrollPolicy.needsRepin(
            from: pinned, to: Tail(contentHeight: 1_000.3, containerHeight: 600, visibleMaxY: 1_000)))
        XCTAssertFalse(AgentScrollPolicy.needsRepin(
            from: pinned, to: Tail(contentHeight: 900, containerHeight: 600, visibleMaxY: 900)))
    }

    func testWorkspaceAssistantAlignsShortConversationToTop() throws {
        let source = try String(contentsOf: repoRoot.appendingPathComponent(
            "uTerm/Features/Agent/Views/AssistantView.swift"),
                                encoding: .utf8)

        XCTAssertTrue(source.contains(".defaultScrollAnchor(.bottom)"))
        XCTAssertTrue(
            source.contains(".defaultScrollAnchor(.top, for: .alignment)"),
            "Short assistant conversations must align to the top without losing tail following.")
    }

    func testWorkspaceAssistantDoesNotRenderSettledEmptyMessageAsEllipsis() throws {
        let source = try String(contentsOf: repoRoot.appendingPathComponent(
            "uTerm/Features/Agent/Views/AssistantView.swift"),
                                encoding: .utf8)

        XCTAssertTrue(source.contains("if !message.text.isEmpty || isStreamingTail"))
        XCTAssertFalse(source.contains("Text(\"…\")"))
    }

    private var repoRoot: URL {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
    }
}
