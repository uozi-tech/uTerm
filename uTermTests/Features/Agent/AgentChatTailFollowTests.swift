import AgentKit
import AppKit
import SwiftData
import SwiftUI
import XCTest
@testable import uTerm

/// Agent 对话「贴底跟随」的几何回归：把 `AssistantView`（工作区面板）与
/// `TerminalAgentView`（终端窗口）真挂进屏外窗口，喂一段受控的流式回复，量
/// 「文档底边 − 视口底边」的距离。
///
/// 盯住的是用户截图里的现场：Agent 处理中、刚发的消息 / 排队条带露出半截，
/// 聊天区没滚到底。判据是几何（离底多少 pt），不是时间，所以窗口摆屏外。
///
/// 「手动上滚后不被拽回」这里测不了：合成的带相位 `CGEvent` 滚轮（直投 `scrollWheel(with:)`
/// 或经 `NSWindow.sendEvent`）都推不动 SwiftUI 的 `HostingScrollView`，也不触发
/// `onScrollPhaseChange`。那一半靠视图里的 `onScrollPhaseChange` 门控（本次未改），
/// 容差带判定由 `AgentScrollPolicy` 的单测守。
@MainActor
final class AgentChatTailFollowTests: XCTestCase {

    private var windows: [NSWindow] = []

    /// 拆窗不走 `tearDown()`（见 `ProbeSmokeTests` 顶部注释）。
    private func closeAllWindows() {
        for window in windows {
            window.contentView = NSView()
            window.orderOut(nil)
        }
        windows.removeAll()
    }

    private static let size = NSSize(width: 460, height: 620)
    /// 贴底的容差：1pt 的锚点 + 舍入。真正的失败是一整个气泡（几十 pt）没滚进来。
    private static let tolerance: CGFloat = 4

    private enum Surface { case panel, terminal }

    private struct Fixture {
        let host: NSHostingView<AnyView>
        let model: AssistantModel
        let client: ControlledStreamClient
        let container: ModelContainer
    }

    private func makeFixture(_ surface: Surface) throws -> Fixture {
        let container = try ModelContainer(
            for: ChatSession.self, ChatMessageRecord.self,
            configurations: ModelConfiguration(isStoredInMemoryOnly: true, cloudKitDatabase: .none))
        let context = ModelContext(container)
        context.autosaveEnabled = false
        let provider = AIProvider(name: "Probe", kind: .anthropic,
                                  baseURL: ProviderPreset.anthropicBaseURL,
                                  model: "probe-model")
        let client = ControlledStreamClient()
        let model = AssistantModel(client: client, provider: provider, apiKey: "sk-probe")
        model.attach(context: context)
        seedHistory(model, context: context)

        let content: AnyView
        switch surface {
        case .panel:
            content = AnyView(AssistantView(serverContext: "probe", serverName: "node-probe",
                                            model: model,
                                            activeProviderIDString: .constant(provider.id.uuidString)))
        case .terminal:
            content = AnyView(TerminalAgentView(model: model, host: "node-probe",
                                                serverContext: "probe",
                                                safety: .constant(.confirm),
                                                activeProviderIDString: .constant(provider.id.uuidString),
                                                onOpenSettings: {}))
        }
        let size = Self.size
        let root = AnyView(content.modelContainer(container)
            .frame(width: size.width, height: size.height))
        let host = NSHostingView(rootView: root)
        host.frame = NSRect(origin: .zero, size: size)
        let window = ProbeWindow.make(contentRect: NSRect(origin: .zero, size: size),
                                      styleMask: [.titled], contentView: host)
        windows.append(window)
        ProbeWindow.isolateHostWindows(keeping: windows)
        window.appearance = NSAppearance(named: .aqua)
        host.layoutSubtreeIfNeeded()
        return Fixture(host: host, model: model, client: client, container: container)
    }

    /// 走真实载入路径铺一段比视口高的历史，让「贴底」有意义。
    private func seedHistory(_ model: AssistantModel, context: ModelContext) {
        let session = ChatSession(title: "probe")
        context.insert(session)
        var records: [ChatMessageRecord] = []
        for i in 0..<8 {
            let text = i % 2 == 0
                ? "第 \(i) 轮：看一下 node-\(i) 的负载。"
                : (0..<6).map { "第 \(i) 条回复的第 \($0) 段，写长一些让它换行占高度。" }
                    .joined(separator: "\n\n")
            let record = ChatMessageRecord(roleRaw: i % 2 == 0 ? "user" : "assistant",
                                           text: text, orderIndex: i)
            record.session = session
            context.insert(record)
            records.append(record)
        }
        session.messages = records
        model.load(session)
    }

    // MARK: - 尺

    private func settle(_ fixture: Fixture, ms: Int = 450) async {
        // 两段等待中间各排一次布局：100ms 合并贴底 + 100ms Markdown 重解析都要走完。
        for _ in 0..<(ms / 50) {
            try? await Task.sleep(for: .milliseconds(50))
            fixture.host.layoutSubtreeIfNeeded()
        }
    }

    /// 文档底边到视口底边的距离（pt）；0 = 贴底。
    private func bottomGap(_ fixture: Fixture) throws -> CGFloat {
        let scroll = try XCTUnwrap(fixture.host.firstScrollView(), "对话区必须有 NSScrollView")
        let document = try XCTUnwrap(scroll.documentView)
        let visible = scroll.documentVisibleRect
        return document.isFlipped
            ? document.bounds.height - visible.maxY
            : visible.minY - document.bounds.minY
    }

    private func submit(_ fixture: Fixture, _ text: String) {
        let model = fixture.model
        Task { await model.submit(text: text, serverContext: "probe") }
    }

    private static func paragraph(_ i: Int) -> String {
        "\n\n第 \(i) 段流式输出：检查 `journalctl -u app` 的报错，再确认磁盘与连接数，"
        + "这一段写得足够长，保证在窄面板里换成两三行。"
    }

    // MARK: - 用例

    /// 发消息 → 流式 → 忙碌时排队 → 首轮结束后队列派发：每个节点都必须贴底。
    private func runConversation(_ surface: Surface) async throws {
        defer { closeAllWindows() }
        let fixture = try makeFixture(surface)
        await settle(fixture)
        XCTAssertLessThanOrEqual(try bottomGap(fixture), Self.tolerance, "\(surface) 首屏应贴底")

        submit(fixture, "第一条：帮我看下 nginx 为什么 502")
        await settle(fixture)
        let afterSubmit = try bottomGap(fixture)

        var worstWhileStreaming: CGFloat = 0
        for i in 0..<12 {
            fixture.client.yield(0, .text(Self.paragraph(i)))
            try await Task.sleep(for: .milliseconds(60))
            fixture.host.layoutSubtreeIfNeeded()
            worstWhileStreaming = max(worstWhileStreaming, try bottomGap(fixture))
        }
        await settle(fixture)
        let afterStreamBurst = try bottomGap(fixture)

        XCTAssertTrue(fixture.model.isBusy)
        submit(fixture, "排队的第二条：顺便看下磁盘")
        await settle(fixture)
        XCTAssertEqual(fixture.model.queuedMessages.map(\.text), ["排队的第二条：顺便看下磁盘"])
        let afterQueue = try bottomGap(fixture)
        let queueStripVisible = Self.hasAccessibilityElement(in: fixture.host,
                                                             labelPrefix: "排队消息")

        fixture.client.finish(0)
        await settle(fixture)
        // 首轮结算回 idle 后，排队消息应作为第二轮派发出去。
        XCTAssertTrue(fixture.model.queuedMessages.isEmpty, "\(surface) 空闲后应派发排队消息")
        XCTAssertEqual(fixture.client.count, 2, "\(surface) 排队消息应起第二轮流式")
        fixture.client.finish(1, .text(Self.paragraph(99)))
        await settle(fixture)
        let afterDrain = try bottomGap(fixture)

        print(String(format: """
            [agent-tail] surface=%@ submit=%.1f stream-worst=%.1f stream-settled=%.1f \
            queue=%.1f drain=%.1f queue-strip=%@
            """, "\(surface)", afterSubmit, worstWhileStreaming, afterStreamBurst,
                     afterQueue, afterDrain, queueStripVisible ? "yes" : "no"))

        XCTAssertLessThanOrEqual(afterSubmit, Self.tolerance, "\(surface) 发出后新消息应滚进视口")
        XCTAssertLessThanOrEqual(afterStreamBurst, Self.tolerance, "\(surface) 流式停下后应贴底")
        XCTAssertLessThanOrEqual(afterQueue, Self.tolerance, "\(surface) 排队条带出现后仍应贴底")
        XCTAssertLessThanOrEqual(afterDrain, Self.tolerance, "\(surface) 派发排队消息后应贴底")
        XCTAssertTrue(queueStripVisible, "\(surface) 忙碌时排队的消息必须在输入区上方列出")
    }

    func testPanelFollowsTailThroughStreamingAndQueue() async throws {
        try await runConversation(.panel)
    }

    func testTerminalFollowsTailThroughStreamingAndQueue() async throws {
        try await runConversation(.terminal)
    }

    // MARK: - 工具

    private static func hasAccessibilityElement(in root: NSView, labelPrefix: String) -> Bool {
        // SwiftUI 的 AX 节点不一定正式声明 `NSAccessibilityProtocol`，按 ObjC 动态派发问。
        var stack: [AnyObject] = [root]
        var visited = 0
        while let element = stack.popLast(), visited < 20_000 {
            visited += 1
            if let label = element.accessibilityLabel?(), label.hasPrefix(labelPrefix) { return true }
            let children = element.accessibilityChildren?() ?? nil
            stack.append(contentsOf: (children ?? []).map { $0 as AnyObject })
        }
        return false
    }
}

/// 每次 `stream` 调用开一条由测试手动推进的流：`yield` 推事件，`finish` 收尾。
private final class ControlledStreamClient: LLMClient, @unchecked Sendable {
    private let lock = NSLock()
    private var streams: [AsyncThrowingStream<LLMEvent, Error>.Continuation] = []
    var count: Int { lock.withLock { streams.count } }

    func stream(messages: [ChatMessage], system: String,
                config: LLMRequestConfig) -> AsyncThrowingStream<LLMEvent, Error> {
        AsyncThrowingStream { continuation in
            lock.withLock { streams.append(continuation) }
        }
    }

    func yield(_ index: Int, _ events: LLMEvent...) {
        let continuation = lock.withLock { streams[index] }
        for event in events { continuation.yield(event) }
    }

    func finish(_ index: Int, _ events: LLMEvent...) {
        let continuation = lock.withLock { streams[index] }
        for event in events { continuation.yield(event) }
        continuation.finish()
    }
}
