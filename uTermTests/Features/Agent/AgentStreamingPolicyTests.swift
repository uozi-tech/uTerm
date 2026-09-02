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
