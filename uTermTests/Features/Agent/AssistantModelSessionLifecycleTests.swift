import AgentKit
import Foundation
import SwiftData
import XCTest
@testable import uTerm

@MainActor
final class AssistantModelSessionLifecycleTests: XCTestCase {
    private enum Failure: Error { case expected, timedOut }

    private func model(_ client: SessionLLMClient, persisted: Bool = false) throws -> AssistantModel {
        let model = AssistantModel(client: client, provider: AIProvider(
            name: "Test", kind: .openai, baseURL: "https://example.invalid", model: "original"), apiKey: "test")
        if persisted {
            let container = try ModelContainer(for: ChatSession.self, ChatMessageRecord.self,
                                               configurations: ModelConfiguration(isStoredInMemoryOnly: true))
            let context = ModelContext(container)
            context.autosaveEnabled = false
            model.attach(context: context)
        }
        return model
    }

    private func waitUntil(_ condition: () -> Bool) async throws {
        let deadline = ContinuousClock.now + .seconds(5)
        while !condition() {
            if ContinuousClock.now >= deadline { XCTFail("Condition did not become true"); throw Failure.timedOut }
            await Task.yield()
        }
    }

    func testStopPreservesPartialReplyAndAllowsNewTurnWithoutDrainingQueue() async throws {
        let client = SessionLLMClient()
        let model = try model(client)
        let send = Task { await model.submit(text: "first", serverContext: "") }
        try await waitUntil { client.count == 1 }
        client.yield(0, events: [.text("partial")])
        try await waitUntil { model.messages.last?.text == "partial" }
        await model.submit(text: "queued", serverContext: "")
        model.stop()
        client.finish(0, events: [.text("late")])
        await send.value
        XCTAssertEqual(model.messages.last?.text, "partial")
        XCTAssertTrue(model.queuedMessages.isEmpty)
        XCTAssertEqual(model.state, .idle)
        XCTAssertFalse(model.canStop)
        XCTAssertTrue(model.turnWasStopped)
        let next = Task { await model.submit(text: "new", serverContext: "") }
        try await waitUntil { client.count == 2 }
        client.finish(1, events: [.text("new answer")])
        await next.value
        XCTAssertEqual(model.messages.last?.text, "new answer")
        XCTAssertFalse(model.turnWasStopped)
    }

    func testStopSkipsEveryPendingToolWithoutContinuing() async throws {
        let client = SessionLLMClient()
        let model = try model(client)
        let executor = SessionCommandExecutor()
        model.executor = executor
        let send = Task { await model.submit(text: "commands", serverContext: "") }
        try await waitUntil { client.count == 1 }
        client.finish(0, events: ["a", "b"].map {
            .toolCall(LLMToolCall(id: $0, name: "run_command", argumentsJSON: #"{"command":"ls"}"#))
        })
        await send.value
        model.stop()
        XCTAssertEqual(model.messages.last?.toolCalls.map(\.status), [.skipped, .skipped])
        XCTAssertEqual(model.state, .idle)
        await model.approveAndRun(id: "a")
        XCTAssertEqual(executor.count, 0)
        XCTAssertEqual(client.count, 1)
    }

    func testStopDuringCommandKeepsResultButPreventsAutomaticContinuation() async throws {
        let client = SessionLLMClient()
        let model = try model(client)
        let executor = SessionCommandExecutor()
        let driver = try await beginCommand(model, client, executor)
        model.stop()
        XCTAssertEqual(model.state, .running)
        XCTAssertFalse(model.canStop)
        executor.finish(.success(CommandResult(output: "actual result", exitCode: 0)))
        await driver.value
        XCTAssertEqual(model.messages.last?.toolCalls.first?.output, "actual result")
        XCTAssertEqual(model.messages.last?.toolCalls.first?.status, .done)
        XCTAssertEqual(model.state, .idle)
        XCTAssertEqual(client.count, 1)
    }

    private func beginCommand(_ model: AssistantModel, _ client: SessionLLMClient,
                              _ executor: SessionCommandExecutor) async throws -> Task<Void, Never> {
        model.executor = executor
        let send = Task { await model.submit(text: "old command", serverContext: "old server") }
        try await waitUntil { client.count == 1 }
        client.finish(0, events: [.toolCall(LLMToolCall(
            id: "call", name: "run_command", argumentsJSON: #"{"command":"mock-command"}"#))])
        await send.value
        XCTAssertEqual(model.state, .awaitingApproval)
        let command = Task { await model.approveAndRun(id: "call") }
        try await waitUntil { executor.count == 1 }
        XCTAssertEqual(model.state, .running)
        return command
    }

    func testNewSessionCancelsOldStreamAndImmediatelySends() async throws {
        let client = SessionLLMClient()
        let model = try model(client)
        let first = Task { await model.submit(text: "first", serverContext: "A") }
        try await waitUntil { client.count == 1 }
        model.startNewSession()
        XCTAssertEqual(model.state, .idle)
        let second = Task { await model.submit(text: "second", serverContext: "B") }
        try await waitUntil { client.count == 2 && client.cancelled.contains(0) }
        client.finish(0, events: [.text("obsolete")], error: Failure.expected)
        XCTAssertEqual(model.state, .streaming)
        XCTAssertEqual(model.messages.map(\.text), ["second", ""])
        client.finish(1, events: [.text("new reply")])
        await first.value
        await second.value
        XCTAssertEqual(model.messages.map(\.text), ["second", "new reply"])
        XCTAssertEqual(model.state, .idle)
        XCTAssertTrue(model.queuedMessages.isEmpty)
    }

    func testSwitchPersistsPartialReplyAndDoesNotReviveStreamWhenReturning() async throws {
        let client = SessionLLMClient()
        let model = try model(client, persisted: true)
        let first = Task { await model.submit(text: "first", serverContext: "A") }
        try await waitUntil { client.count == 1 }
        let session = try XCTUnwrap(model.currentSession)
        client.yield(0, events: [.text("partial")])
        try await waitUntil { model.messages.last?.text == "partial" }
        model.startNewSession()
        model.load(session)
        client.finish(0, events: [.text("late")])
        await first.value
        XCTAssertEqual(session.orderedMessages.last?.text, "partial")
        XCTAssertEqual(model.messages.last?.text, "partial")
        XCTAssertEqual(model.state, .idle)
        XCTAssertEqual(client.count, 1)
    }

    func testIdlePublicationAlreadyHasPersistedReply() async throws {
        let client = SessionLLMClient()
        let model = try model(client, persisted: true)
        let first = Task { await model.submit(text: "first", serverContext: "") }
        try await waitUntil { client.count == 1 }
        let session = try XCTUnwrap(model.currentSession)
        client.finish(0, events: [.text("completed")])
        // React as soon as the UI observes idle, without first waiting for the send driver.
        try await waitUntil { model.state == .idle }
        XCTAssertEqual(session.orderedMessages.last?.text, "completed")
        model.startNewSession()
        await first.value
        XCTAssertEqual(session.orderedMessages.last?.text, "completed")
    }

    func testLateCommandSuccessPersistsOnlyToOriginalSession() async throws {
        try await assertLateCommand(.success(CommandResult(output: "old result", exitCode: 0)))
    }

    func testLateCommandFailurePersistsOnlyToOriginalSession() async throws {
        try await assertLateCommand(.failure(Failure.expected))
    }

    private func assertLateCommand(_ result: Result<CommandResult, Error>) async throws {
        let client = SessionLLMClient()
        let model = try model(client, persisted: true)
        let executor = SessionCommandExecutor()
        var refreshes = 0
        model.onCommandExecutionFinished = { refreshes += 1 }
        let command = try await beginCommand(model, client, executor)
        let original = try XCTUnwrap(model.currentSession)
        XCTAssertEqual(original.orderedMessages.last?.toolCalls.first?.status, .running)
        model.startNewSession()
        let next = Task { await model.submit(text: "new prompt", serverContext: "new server") }
        try await waitUntil { client.count == 2 }
        await model.submit(text: "queued in new session", serverContext: "new server")
        executor.finish(result)
        await command.value
        XCTAssertEqual(refreshes, 1)
        XCTAssertEqual(model.state, .streaming)
        XCTAssertEqual(model.messages.map(\.text), ["new prompt", ""])
        XCTAssertEqual(model.queuedMessages.map(\.text), ["queued in new session"])
        XCTAssertEqual(client.count, 2)
        let call = try XCTUnwrap(original.orderedMessages.last?.toolCalls.first)
        switch result {
        case .success: XCTAssertEqual(call.status, .done); XCTAssertEqual(call.output, "old result")
        case .failure: XCTAssertEqual(call.status, .failed)
        }
        // The new turn alone may drain its queue.
        client.finish(1, events: [.text("new reply")])
        try await waitUntil { client.count == 3 }
        XCTAssertEqual(client.system(at: 2), client.system(at: 1))
        client.finish(2, events: [.text("queued reply")])
        await next.value
        XCTAssertEqual(model.messages.map(\.text), ["new prompt", "new reply", "queued in new session", "queued reply"])
    }

    func testSwitchToHistoryWithSameToolIDDoesNotMutateIt() async throws {
        let client = SessionLLMClient()
        let model = try model(client, persisted: true)
        let executor = SessionCommandExecutor()
        let command = try await beginCommand(model, client, executor)
        let context = try XCTUnwrap(model.modelContext)
        let other = ChatSession(title: "other")
        context.insert(other)
        let message = ChatMessageRecord(roleRaw: "assistant", text: "other reply",
                                        toolCallsJSON: ChatMessageRecord.encode([
                                            ToolCallState(id: "call", name: "run_command", command: "other-command")]))
        message.session = other
        context.insert(message)
        try context.save()
        model.load(other)
        executor.finish(.success(CommandResult(output: "wrong session", exitCode: 0)))
        await command.value
        XCTAssertEqual(model.messages.last?.text, "other reply")
        XCTAssertEqual(model.messages.last?.toolCalls.first?.status, .pending)
        XCTAssertEqual(model.state, .awaitingApproval)
        XCTAssertEqual(client.count, 1)
    }

    func testReturnToRunningCommandShowsResultWithoutAutoContinuationOrDuplicateExecution() async throws {
        let client = SessionLLMClient()
        let model = try model(client, persisted: true)
        let executor = SessionCommandExecutor()
        let command = try await beginCommand(model, client, executor)
        let original = try XCTUnwrap(model.currentSession)
        model.startNewSession()
        model.load(original)
        XCTAssertEqual(model.state, .running)
        await model.approveAndRun(id: "call")
        XCTAssertEqual(executor.count, 1)
        executor.finish(.success(CommandResult(output: "done", exitCode: 0)))
        await command.value
        XCTAssertEqual(model.messages.last?.toolCalls.first?.output, "done")
        XCTAssertEqual(model.state, .idle)
        XCTAssertEqual(client.count, 1)
    }

    func testDeletedSessionIsNotRecreatedByCommandCompletion() async throws {
        try await assertDeletedSession(saveDeletion: true)
    }

    func testPendingDeletionIsNotResurrectedByCommandCompletion() async throws {
        try await assertDeletedSession(saveDeletion: false)
    }

    private func assertDeletedSession(saveDeletion: Bool) async throws {
        let client = SessionLLMClient()
        let model = try model(client, persisted: true)
        let executor = SessionCommandExecutor()
        let command = try await beginCommand(model, client, executor)
        let context = try XCTUnwrap(model.modelContext)
        let original = try XCTUnwrap(model.currentSession)
        model.startNewSession()
        context.delete(original)
        if saveDeletion { try context.save() }
        executor.finish(.success(CommandResult(output: "done", exitCode: 0)))
        await command.value
        XCTAssertEqual(try context.fetchCount(FetchDescriptor<ChatSession>()), 0)
        XCTAssertEqual(try context.fetchCount(FetchDescriptor<ChatMessageRecord>()), 0)
        XCTAssertTrue(model.messages.isEmpty)
        XCTAssertEqual(model.state, .idle)
    }

    func testRestoreDuringCommandSuppressesOldRefreshAndContinuation() async throws {
        let client = SessionLLMClient()
        let model = try model(client)
        let executor = SessionCommandExecutor()
        var refreshes = 0
        model.onCommandExecutionFinished = { refreshes += 1 }
        let command = try await beginCommand(model, client, executor)
        model.restore(from: AgentSnapshot(currentSessionID: nil, input: "restored draft"))
        executor.finish(.success(CommandResult(output: "done", exitCode: 0)))
        await command.value
        XCTAssertEqual(refreshes, 0)
        XCTAssertEqual(model.input, "restored draft")
        XCTAssertEqual(model.state, .idle)
        XCTAssertTrue(model.messages.isEmpty)
    }

    func testDisposeStopsStreamAndRejectsFurtherSubmission() async throws {
        let client = SessionLLMClient()
        let model = try model(client)
        let first = Task { await model.submit(text: "first", serverContext: "") }
        try await waitUntil { client.count == 1 }
        model.dispose()
        try await waitUntil { client.cancelled.contains(0) }
        await first.value
        let before = model.messages
        await model.submit(text: "not sent", serverContext: "")
        XCTAssertEqual(client.count, 1)
        XCTAssertEqual(model.messages, before)
        XCTAssertEqual(model.state, .idle)
    }

    func testDisposePreservesRemoteCommandResultWithoutRefreshingOrContinuing() async throws {
        let client = SessionLLMClient()
        let model = try model(client, persisted: true)
        let executor = SessionCommandExecutor()
        var refreshes = 0
        model.onCommandExecutionFinished = { refreshes += 1 }
        let command = try await beginCommand(model, client, executor)
        let original = try XCTUnwrap(model.currentSession)
        model.dispose()
        command.cancel()
        executor.finish(.success(CommandResult(output: "remote completed", exitCode: 0)))
        await command.value
        XCTAssertEqual(original.orderedMessages.last?.toolCalls.first?.output, "remote completed")
        XCTAssertEqual(refreshes, 0)
        XCTAssertEqual(client.count, 1)
        XCTAssertEqual(model.state, .idle)
    }

    func testSwitchDuringFileRefreshDoesNotStartOldToolContinuation() async throws {
        let client = SessionLLMClient()
        let model = try model(client)
        let executor = SessionCommandExecutor()
        model.onCommandExecutionFinished = { model.startNewSession() }
        let command = try await beginCommand(model, client, executor)
        executor.finish(.success(CommandResult(output: "done", exitCode: 0)))
        await command.value
        XCTAssertEqual(client.count, 1)
        XCTAssertTrue(model.messages.isEmpty)
        XCTAssertEqual(model.state, .idle)
    }

    func testProviderMutationDoesNotRetargetToolContinuation() async throws {
        let client = SessionLLMClient()
        let model = try model(client)
        let executor = SessionCommandExecutor()
        let command = try await beginCommand(model, client, executor)
        model.activeProvider?.model = "changed"
        executor.finish(.success(CommandResult(output: "done", exitCode: 0)))
        try await waitUntil { client.count == 2 }
        XCTAssertEqual(client.model(at: 1), "original")
        XCTAssertEqual(client.system(at: 1), client.system(at: 0))
        client.finish(1, events: [.text("done")])
        await command.value
    }

    func testExecutorReplacementSuppressesOldRefreshAndContinuation() async throws {
        let client = SessionLLMClient()
        let model = try model(client)
        let executor = SessionCommandExecutor()
        var refreshes = 0
        model.onCommandExecutionFinished = { refreshes += 1 }
        let command = try await beginCommand(model, client, executor)
        model.executor = SessionCommandExecutor()
        executor.finish(.success(CommandResult(output: "done", exitCode: 0)))
        await command.value
        XCTAssertEqual(model.messages.last?.toolCalls.first?.output, "done")
        XCTAssertEqual(model.state, .idle)
        XCTAssertEqual(refreshes, 0)
        XCTAssertEqual(client.count, 1)
    }

    func testOrphanedRunningRecordBecomesUnknownWithoutRerunning() async throws {
        let client = SessionLLMClient()
        let model = try model(client, persisted: true)
        let context = try XCTUnwrap(model.modelContext)
        let session = ChatSession(title: "interrupted")
        context.insert(session)
        let message = ChatMessageRecord(roleRaw: "assistant", text: "", toolCallsJSON: ChatMessageRecord.encode([
            ToolCallState(id: "old", name: "run_command", command: "old command", status: .running)]))
        message.session = session
        context.insert(message)
        try context.save()
        model.load(session)
        XCTAssertEqual(model.state, .idle)
        XCTAssertEqual(model.messages.last?.toolCalls.first?.status, .failed)
        XCTAssertTrue(model.messages.last?.toolCalls.first?.output?.contains("结果未知") == true)
        XCTAssertEqual(client.count, 0)
    }

    func testOpeningRunningSessionInAnotherModelDoesNotOverwriteDurableStatus() async throws {
        let client = SessionLLMClient()
        let originalModel = try model(client, persisted: true)
        let executor = SessionCommandExecutor()
        let command = try await beginCommand(originalModel, client, executor)
        let session = try XCTUnwrap(originalModel.currentSession)
        let otherModel = try model(SessionLLMClient())
        otherModel.attach(context: try XCTUnwrap(originalModel.modelContext))
        otherModel.load(session)
        XCTAssertEqual(session.orderedMessages.last?.toolCalls.first?.status, .running)
        originalModel.startNewSession()
        executor.finish(.success(CommandResult(output: "actual result", exitCode: 0)))
        await command.value
        XCTAssertEqual(session.orderedMessages.last?.toolCalls.first?.status, .done)
        XCTAssertEqual(session.orderedMessages.last?.toolCalls.first?.output, "actual result")
        otherModel.startNewSession()
        otherModel.load(session)
        XCTAssertEqual(otherModel.messages.last?.toolCalls.first?.output, "actual result")
    }
}

private final class SessionLLMClient: LLMClient, @unchecked Sendable {
    private let lock = NSLock()
    private var streams: [AsyncThrowingStream<LLMEvent, Error>.Continuation] = []
    private var systems: [String] = []
    private var configs: [LLMRequestConfig] = []
    private var cancellations: Set<Int> = []
    var count: Int { lock.withLock { streams.count } }
    var cancelled: Set<Int> { lock.withLock { cancellations } }
    func system(at index: Int) -> String { lock.withLock { systems[index] } }
    @MainActor func model(at index: Int) -> String { lock.withLock { configs[index] }.model }

    func stream(messages: [ChatMessage], system: String, config: LLMRequestConfig) -> AsyncThrowingStream<LLMEvent, Error> {
        AsyncThrowingStream { continuation in
            let index = lock.withLock {
                let index = streams.count
                streams.append(continuation)
                systems.append(system)
                configs.append(config)
                return index
            }
            continuation.onTermination = { [weak self] reason in
                if case .cancelled = reason { _ = self?.lock.withLock { self?.cancellations.insert(index) } }
            }
        }
    }

    func yield(_ index: Int, events: [LLMEvent]) {
        let continuation = lock.withLock { streams[index] }
        for event in events { continuation.yield(event) }
    }

    func finish(_ index: Int, events: [LLMEvent] = [], error: Error? = nil) {
        yield(index, events: events)
        let continuation = lock.withLock { streams[index] }
        if let error { continuation.finish(throwing: error) } else { continuation.finish() }
    }
}

private final class SessionCommandExecutor: CommandExecutor, @unchecked Sendable {
    private let lock = NSLock()
    private var continuation: CheckedContinuation<CommandResult, Error>?
    private var calls = 0
    var count: Int { lock.withLock { calls } }
    func run(_ command: String) async throws -> CommandResult {
        try await withCheckedThrowingContinuation { continuation in
            lock.withLock { self.continuation = continuation; calls += 1 }
        }
    }
    func finish(_ result: Result<CommandResult, Error>) {
        let continuation = lock.withLock {
            let continuation = self.continuation
            self.continuation = nil
            return continuation
        }
        continuation?.resume(with: result)
    }
}
