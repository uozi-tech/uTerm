import XCTest
import SwiftData
@testable import uTerm

@MainActor
final class AssistantModelTests: XCTestCase {
    private func makeProvider() -> AIProvider {
        AIProvider(name: "Test", kind: .anthropic,
                    baseURL: ProviderPreset.anthropicBaseURL,
                    model: "claude-opus-4-7")
    }

    private func makeInMemoryContext() throws -> ModelContext {
        let config = ModelConfiguration(isStoredInMemoryOnly: true)
        let container = try ModelContainer(
            for: ChatSession.self, ChatMessageRecord.self,
            configurations: config)
        let context = ModelContext(container)
        context.autosaveEnabled = false
        return context
    }

    func testSendAppendsUserAndAssistantMessages() async {
        let backend = MockLLMClient(deltas: ["Hi", " there"])
        let model = AssistantModel(client: backend, provider: makeProvider(), apiKey: "sk-test")
        model.input = "hello"
        await model.send(serverContext: "server: cluster-main")
        XCTAssertEqual(model.messages.count, 2)
        XCTAssertEqual(model.messages[0].role, .user)
        XCTAssertEqual(model.messages[0].text, "hello")
        XCTAssertEqual(model.messages[1].role, .assistant)
    }

    func testStreamedDeltasConcatenateIntoAssistantMessage() async {
        let backend = MockLLMClient(deltas: ["Hi", " there"])
        let model = AssistantModel(client: backend, provider: makeProvider(), apiKey: "sk-test")
        model.input = "hello"
        await model.send(serverContext: "")
        XCTAssertEqual(model.messages.last?.text, "Hi there")
        XCTAssertEqual(model.state, .idle)
    }

    func testInputIsClearedOnSend() async {
        let backend = MockLLMClient(deltas: ["x"])
        let model = AssistantModel(client: backend, provider: makeProvider(), apiKey: "sk-test")
        model.input = "hello"
        await model.send(serverContext: "")
        XCTAssertEqual(model.input, "")
    }

    func testEmptyInputDoesNothing() async {
        let backend = MockLLMClient(deltas: ["x"])
        let model = AssistantModel(client: backend, provider: makeProvider(), apiKey: "sk-test")
        model.input = "   "
        await model.send(serverContext: "")
        XCTAssertTrue(model.messages.isEmpty)
    }

    func testBackendErrorReachesFailed() async {
        let backend = MockLLMClient(deltas: [], failWith: LLMClientError.invalidResponse)
        let model = AssistantModel(client: backend, provider: makeProvider(), apiKey: "sk-test")
        model.input = "hello"
        await model.send(serverContext: "")
        guard case .failed = model.state else { return XCTFail("应为 .failed") }
    }

    func testServerContextGoesIntoSystemPrompt() async {
        let backend = MockLLMClient(deltas: ["x"])
        let model = AssistantModel(client: backend, provider: makeProvider(), apiKey: "sk-test")
        model.input = "hello"
        await model.send(serverContext: "server: cluster-main")
        XCTAssertTrue(backend.captured.system.contains("cluster-main"))
    }

    func testSecondSubmitWhileStreamingIsQueued() async {
        let model = AssistantModel(client: BlockingLLMClient(),
                                   provider: makeProvider(), apiKey: "sk-test")
        model.input = "first"
        let task = Task { await model.send(serverContext: "") }
        while model.state != .streaming { await Task.yield() }
        model.input = "second"
        await model.submit(serverContext: "")
        // 入队后不进 messages（仍只有 first 用户 + 空 assistant），队列里有 second。
        XCTAssertEqual(model.messages.count, 2)
        XCTAssertEqual(model.messages[0].text, "first")
        XCTAssertEqual(model.queuedMessages.map(\.text), ["second"])
        XCTAssertEqual(model.input, "")
        task.cancel()
        _ = await task.value
    }

    func testUnauthorizedErrorGivesAnthropicHint() async {
        let backend = MockLLMClient(deltas: [],
                                     failWith: LLMClientError.httpError(status: 401, body: "{}"))
        let model = AssistantModel(client: backend, provider: makeProvider(), apiKey: "sk-test")
        model.input = "hello"
        await model.send(serverContext: "")
        guard case .failed(let message) = model.state else { return XCTFail("应为 .failed") }
        XCTAssertTrue(message.contains("Anthropic"))
    }

    func testUnauthorizedErrorGivesOpenAIHint() async {
        let openaiProvider = AIProvider(name: "X", kind: .openai,
                                          baseURL: ProviderPreset.openAIBaseURL,
                                          model: "gpt-5")
        let backend = MockLLMClient(deltas: [],
                                     failWith: LLMClientError.httpError(status: 401, body: "{}"))
        let model = AssistantModel(client: backend, provider: openaiProvider, apiKey: "sk-test")
        model.input = "hello"
        await model.send(serverContext: "")
        guard case .failed(let message) = model.state else { return XCTFail("应为 .failed") }
        XCTAssertTrue(message.contains("OpenAI"))
    }

    func testBackendReceivesOnlyRealMessagesNotEmptyAssistant() async {
        let backend = MockLLMClient(deltas: ["x"])
        let model = AssistantModel(client: backend, provider: makeProvider(), apiKey: "sk-test")
        model.input = "hello"
        await model.send(serverContext: "")
        XCTAssertEqual(backend.captured.messages.count, 1)
        XCTAssertEqual(backend.captured.messages[0].role, .user)
    }

    func testNoProvidersResultsInFailedState() async {
        let model = AssistantModel()
        model.input = "hello"
        await model.send(serverContext: "")
        guard case .failed(let m) = model.state else { return XCTFail("应为 .failed") }
        XCTAssertTrue(m.contains("provider"))
    }

    func testActiveProviderFallbackToLowestSortOrder() {
        let model = AssistantModel()
        let a = AIProvider(name: "A", kind: .anthropic, baseURL: "", model: "", sortOrder: 5)
        let b = AIProvider(name: "B", kind: .openai, baseURL: "", model: "", sortOrder: 1)
        model.providers = [a, b]
        model.activeProviderID = nil
        XCTAssertEqual(model.activeProvider?.id, b.id)
    }

    // MARK: - 会话历史

    func testDeriveTitleTrimsAndTruncates() {
        XCTAssertEqual(AssistantModel.deriveTitle(from: "  hello  "), "hello")
        XCTAssertEqual(AssistantModel.deriveTitle(from: "line1\nline2"), "line1")
        let long = String(repeating: "字", count: 40)
        let title = AssistantModel.deriveTitle(from: long)
        XCTAssertEqual(title.count, 25) // 24 字 + 省略号
        XCTAssertTrue(title.hasSuffix("…"))
    }

    func testSendPersistsSessionWithMessages() async throws {
        let context = try makeInMemoryContext()
        let model = AssistantModel(client: MockLLMClient(deltas: ["Hi", " there"]),
                                    provider: makeProvider(), apiKey: "sk-test")
        model.attach(context: context)
        model.input = "诊断 nginx 502"
        await model.send(serverContext: "")

        let sessions = try context.fetch(FetchDescriptor<ChatSession>())
        XCTAssertEqual(sessions.count, 1)
        let session = try XCTUnwrap(sessions.first)
        XCTAssertEqual(session.title, "诊断 nginx 502")
        XCTAssertEqual(model.currentSession?.id, session.id)

        let ordered = session.orderedMessages
        XCTAssertEqual(ordered.count, 2)
        XCTAssertEqual(ordered[0].role, .user)
        XCTAssertEqual(ordered[0].text, "诊断 nginx 502")
        XCTAssertEqual(ordered[1].role, .assistant)
        XCTAssertEqual(ordered[1].text, "Hi there")
    }

    func testStartNewSessionThenSendCreatesSecondSession() async throws {
        let context = try makeInMemoryContext()
        let model = AssistantModel(client: MockLLMClient(deltas: ["a"]),
                                    provider: makeProvider(), apiKey: "sk-test")
        model.attach(context: context)
        model.input = "first"
        await model.send(serverContext: "")

        model.startNewSession()
        XCTAssertNil(model.currentSession)
        XCTAssertTrue(model.messages.isEmpty)

        model.input = "second"
        await model.send(serverContext: "")

        let sessions = try context.fetch(FetchDescriptor<ChatSession>())
        XCTAssertEqual(sessions.count, 2)
    }

    func testLoadSessionRestoresMessages() async throws {
        let context = try makeInMemoryContext()
        let model = AssistantModel(client: MockLLMClient(deltas: ["reply"]),
                                    provider: makeProvider(), apiKey: "sk-test")
        model.attach(context: context)
        model.input = "remember me"
        await model.send(serverContext: "")
        let session = try XCTUnwrap(model.currentSession)

        model.startNewSession()
        XCTAssertTrue(model.messages.isEmpty)

        model.load(session)
        XCTAssertEqual(model.currentSession?.id, session.id)
        XCTAssertEqual(model.messages.count, 2)
        XCTAssertEqual(model.messages[0].text, "remember me")
        XCTAssertEqual(model.messages[1].text, "reply")
    }

    func testRestoreSnapshotBeforeAttachLoadsCurrentSessionAndDraft() throws {
        let context = try makeInMemoryContext()
        let sessionID = UUID()
        let session = ChatSession(title: "saved agent session", id: sessionID)
        let user = ChatMessageRecord(role: .user, text: "remember agent",
                                     createdAt: Date(timeIntervalSince1970: 1))
        let assistant = ChatMessageRecord(role: .assistant, text: "restored",
                                          createdAt: Date(timeIntervalSince1970: 2))
        context.insert(session)
        user.session = session
        assistant.session = session
        context.insert(user)
        context.insert(assistant)
        try context.save()

        let model = AssistantModel(client: MockLLMClient(deltas: []),
                                   provider: makeProvider(), apiKey: "sk-test")
        model.restore(from: AgentSnapshot(currentSessionID: sessionID,
                                          input: "draft command"))

        XCTAssertNil(model.currentSession)
        model.attach(context: context)

        XCTAssertEqual(model.input, "draft command")
        XCTAssertEqual(model.currentSession?.id, sessionID)
        XCTAssertEqual(model.messages.map(\.text), ["remember agent", "restored"])
    }

    func testNoContextKeepsInMemoryOnly() async throws {
        let context = try makeInMemoryContext()
        let model = AssistantModel(client: MockLLMClient(deltas: ["x"]),
                                    provider: makeProvider(), apiKey: "sk-test")
        // 不 attach context
        model.input = "hello"
        await model.send(serverContext: "")
        XCTAssertEqual(model.messages.count, 2)
        XCTAssertNil(model.currentSession)
        let sessions = try context.fetch(FetchDescriptor<ChatSession>())
        XCTAssertTrue(sessions.isEmpty)
    }

    // MARK: - 队列：数据层

    private func queueModel() -> AssistantModel {
        AssistantModel(client: MockLLMClient(deltas: []),
                       provider: makeProvider(), apiKey: "sk-test")
    }

    func testEnqueueTrimsAndIgnoresEmpty() {
        let model = queueModel()
        model.enqueue("  hi  ")
        model.enqueue("   ")
        XCTAssertEqual(model.queuedMessages.map(\.text), ["hi"])
    }

    func testRemoveQueuedDropsMatchingItem() {
        let model = queueModel()
        model.enqueue("a"); model.enqueue("b")
        let firstID = model.queuedMessages[0].id
        model.removeQueued(id: firstID)
        XCTAssertEqual(model.queuedMessages.map(\.text), ["b"])
    }

    func testLoadQueuedForEditingMovesTextToEmptyInput() {
        let model = queueModel()
        model.enqueue("draft msg")
        let id = model.queuedMessages[0].id
        model.loadQueuedForEditing(id: id)
        XCTAssertEqual(model.input, "draft msg")
        XCTAssertTrue(model.queuedMessages.isEmpty)
    }

    func testLoadQueuedForEditingPrependsToExistingDraft() {
        let model = queueModel()
        model.input = "current"
        model.enqueue("queued")
        let id = model.queuedMessages[0].id
        model.loadQueuedForEditing(id: id)
        XCTAssertEqual(model.input, "queued\n\ncurrent")
        XCTAssertTrue(model.queuedMessages.isEmpty)
    }

    func testStartNewSessionClearsQueueAndEditing() {
        let model = queueModel()
        model.enqueue("a")
        model.editingMessageID = UUID()
        model.startNewSession()
        XCTAssertTrue(model.queuedMessages.isEmpty)
        XCTAssertNil(model.editingMessageID)
    }

    func testLoadSessionClearsQueueAndEditing() {
        let model = queueModel()
        let session = ChatSession(title: "s")
        model.enqueue("queued")
        model.editingMessageID = UUID()
        model.load(session)
        XCTAssertTrue(model.queuedMessages.isEmpty)
        XCTAssertNil(model.editingMessageID)
    }

    func testSubmitWhileIdleSendsImmediately() async {
        let model = AssistantModel(client: MockLLMClient(deltas: ["ok"]),
                                   provider: makeProvider(), apiKey: "sk-test")
        model.input = "hi"
        await model.submit(serverContext: "")
        XCTAssertEqual(model.messages.count, 2)
        XCTAssertEqual(model.messages[0].text, "hi")
        XCTAssertTrue(model.queuedMessages.isEmpty)
        XCTAssertEqual(model.state, .idle)
    }

    func testQueuedMessagesDrainOneAtATimeInOrder() async {
        // 预置队列后发首条；首轮结算回 idle 即逐条冲完。
        let client = MockLLMClient(scripts: [[.text("r0")], [.text("rA")], [.text("rB")]])
        let model = AssistantModel(client: client, provider: makeProvider(), apiKey: "sk-test")
        model.enqueue("A")
        model.enqueue("B")
        model.input = "start"
        await model.send(serverContext: "")
        XCTAssertTrue(model.queuedMessages.isEmpty)
        XCTAssertEqual(client.captured.callCount, 3)
        XCTAssertEqual(model.messages.map(\.text),
                       ["start", "r0", "A", "rA", "B", "rB"])
        XCTAssertEqual(model.messages.map(\.role),
                       [.user, .assistant, .user, .assistant, .user, .assistant])
        XCTAssertEqual(model.state, .idle)
    }

    // MARK: - 编辑 + 分叉重生

    func testEditAndResendForksFromEditedMessage() async {
        let client = MockLLMClient(scripts: [[.text("first reply")], [.text("second reply")]])
        let model = AssistantModel(client: client, provider: makeProvider(), apiKey: "sk-test")
        model.input = "original"
        await model.send(serverContext: "")
        XCTAssertEqual(model.messages.count, 2)
        let userID = model.messages[0].id

        await model.editAndResend(id: userID, newText: "edited", serverContext: "")
        XCTAssertEqual(model.messages.count, 2)
        XCTAssertEqual(model.messages[0].role, .user)
        XCTAssertEqual(model.messages[0].text, "edited")
        XCTAssertEqual(model.messages[0].id, userID)     // 保留原 id
        XCTAssertEqual(model.messages[1].text, "second reply")
        XCTAssertEqual(model.state, .idle)
    }

    func testEditTruncatesAllLaterMessages() async {
        let client = MockLLMClient(scripts: [[.text("r1")], [.text("r2")], [.text("r-edited")]])
        let model = AssistantModel(client: client, provider: makeProvider(), apiKey: "sk-test")
        model.input = "msg1"; await model.send(serverContext: "")
        model.input = "msg2"; await model.send(serverContext: "")
        XCTAssertEqual(model.messages.count, 4)          // u1,a1,u2,a2
        let firstUserID = model.messages[0].id

        await model.editAndResend(id: firstUserID, newText: "msg1-edited", serverContext: "")
        XCTAssertEqual(model.messages.map(\.text), ["msg1-edited", "r-edited"])
    }

    func testEditLastUserMessageRegeneratesOnlyThatTurn() async {
        let client = MockLLMClient(scripts: [[.text("a1")], [.text("a2")], [.text("a2-new")]])
        let model = AssistantModel(client: client, provider: makeProvider(), apiKey: "sk-test")
        model.input = "u1"; await model.send(serverContext: "")
        model.input = "u2"; await model.send(serverContext: "")
        XCTAssertEqual(model.messages.map(\.text), ["u1", "a1", "u2", "a2"])
        let u2id = model.messages[2].id
        await model.editAndResend(id: u2id, newText: "u2-edited", serverContext: "")
        XCTAssertEqual(model.messages.map(\.text), ["u1", "a1", "u2-edited", "a2-new"])
        XCTAssertEqual(model.messages[2].id, u2id)   // 保留原 id
        XCTAssertEqual(model.state, .idle)
    }

    func testEditDeletesOrphanedRecords() async throws {
        let context = try makeInMemoryContext()
        let client = MockLLMClient(scripts: [[.text("r1")], [.text("r2")], [.text("r-edit")]])
        let model = AssistantModel(client: client, provider: makeProvider(), apiKey: "sk-test")
        model.attach(context: context)
        model.input = "m1"; await model.send(serverContext: "")
        model.input = "m2"; await model.send(serverContext: "")
        let session = try XCTUnwrap(model.currentSession)
        XCTAssertEqual(session.orderedMessages.count, 4)
        let firstUserID = model.messages[0].id

        await model.editAndResend(id: firstUserID, newText: "m1-edited", serverContext: "")
        let ordered = session.orderedMessages
        XCTAssertEqual(ordered.count, 2)
        XCTAssertEqual(ordered[0].role, .user)
        XCTAssertEqual(ordered[0].text, "m1-edited")
        XCTAssertEqual(ordered[1].text, "r-edit")
        XCTAssertEqual(session.title, "m1-edited")       // 首条改了 → 标题重派生
    }

    func testEditIgnoredWhileBusy() async {
        let model = AssistantModel(client: BlockingLLMClient(),
                                   provider: makeProvider(), apiKey: "sk-test")
        model.input = "first"
        let task = Task { await model.send(serverContext: "") }
        while model.state != .streaming { await Task.yield() }
        let userID = model.messages[0].id
        await model.editAndResend(id: userID, newText: "nope", serverContext: "")
        XCTAssertEqual(model.messages[0].text, "first")  // 未改
        task.cancel()
        _ = await task.value
    }

    func testEditNonUserMessageIsNoOp() async {
        let client = MockLLMClient(deltas: ["reply"])
        let model = AssistantModel(client: client, provider: makeProvider(), apiKey: "sk-test")
        model.input = "hi"; await model.send(serverContext: "")
        let assistantID = model.messages[1].id
        await model.editAndResend(id: assistantID, newText: "x", serverContext: "")
        XCTAssertEqual(model.messages.map(\.text), ["hi", "reply"])   // 不变
    }

    func testRestoreNilClearsQueueAndEditing() {
        let model = queueModel()
        model.enqueue("q")
        model.editingMessageID = UUID()
        model.restore(from: nil)
        XCTAssertTrue(model.queuedMessages.isEmpty)
        XCTAssertNil(model.editingMessageID)
    }

    func testRestoreSnapshotClearsQueueAndEditing() {
        let model = queueModel()
        model.enqueue("q")
        model.editingMessageID = UUID()
        model.restore(from: AgentSnapshot(currentSessionID: nil, input: "draft"))
        XCTAssertTrue(model.queuedMessages.isEmpty)
        XCTAssertNil(model.editingMessageID)
        XCTAssertEqual(model.input, "draft")
    }
}
