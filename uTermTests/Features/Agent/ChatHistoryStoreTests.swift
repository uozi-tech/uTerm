import AgentKit
import SwiftData
import XCTest
@testable import uTerm

/// 会话滚动清理。执行日志一直有 30 天窗口，聊天历史此前**从不清理**——
/// 本地库和 iCloud 配额都会无界增长。这里钉住窗口边界与「0 = 不清理」。
@MainActor
final class ChatHistoryStoreTests: XCTestCase {
    private func makeContext() throws -> ModelContext {
        let config = ModelConfiguration(isStoredInMemoryOnly: true, cloudKitDatabase: .none)
        let container = try ModelContainer(for: ChatSession.self, ChatMessageRecord.self,
                                           configurations: config)
        return ModelContext(container)
    }

    @discardableResult
    private func session(in context: ModelContext, updatedDaysAgo days: Double,
                         messages: Int = 0) -> ChatSession {
        let session = ChatSession()
        session.title = "对话"
        session.updatedAt = Date().addingTimeInterval(-days * 86_400)
        context.insert(session)
        for i in 0..<messages {
            let message = ChatMessageRecord()
            message.text = "m\(i)"
            message.session = session
            context.insert(message)
        }
        return session
    }

    private func sessionCount(_ context: ModelContext) throws -> Int {
        try context.fetch(FetchDescriptor<ChatSession>()).count
    }

    func testPrunesSessionsOlderThanTheWindow() throws {
        let context = try makeContext()
        session(in: context, updatedDaysAgo: 200)
        session(in: context, updatedDaysAgo: 10)

        let removed = ChatHistoryStore(context: context).pruneExpiredSessions(days: 180)

        XCTAssertEqual(removed, 1)
        XCTAssertEqual(try sessionCount(context), 1)
    }

    /// 边界：正好落在窗口内的那条不能删。
    func testKeepsASessionJustInsideTheWindow() throws {
        let context = try makeContext()
        session(in: context, updatedDaysAgo: 179.9)

        let removed = ChatHistoryStore(context: context).pruneExpiredSessions(days: 180)

        XCTAssertEqual(removed, 0)
        XCTAssertEqual(try sessionCount(context), 1)
    }

    func testZeroDaysMeansNeverPrune() throws {
        let context = try makeContext()
        session(in: context, updatedDaysAgo: 10_000)

        let removed = ChatHistoryStore(context: context).pruneExpiredSessions(days: 0)

        XCTAssertEqual(removed, 0)
        XCTAssertEqual(try sessionCount(context), 1)
    }

    /// 删会话要把其中的消息一并带走（`@Relationship(deleteRule: .cascade)`）。
    func testDeletingASessionAlsoRemovesItsMessages() throws {
        let context = try makeContext()
        session(in: context, updatedDaysAgo: 400, messages: 5)

        ChatHistoryStore(context: context).pruneExpiredSessions(days: 180)

        XCTAssertEqual(try sessionCount(context), 0)
        XCTAssertEqual(try context.fetch(FetchDescriptor<ChatMessageRecord>()).count, 0)
    }

    func testPruneIsIdempotent() throws {
        let context = try makeContext()
        session(in: context, updatedDaysAgo: 400)
        let store = ChatHistoryStore(context: context)

        XCTAssertEqual(store.pruneExpiredSessions(days: 180), 1)
        XCTAssertEqual(store.pruneExpiredSessions(days: 180), 0)
    }

    func testRetentionDaysFallsBackToTheDefault() {
        let defaults = UserDefaults(suiteName: "chat-retention-\(UUID().uuidString)")!
        XCTAssertEqual(ChatHistoryStore.retentionDays(defaults: defaults),
                       ChatHistoryStore.defaultRetentionDays)

        defaults.set(30, forKey: ChatHistoryStore.retentionDaysKey)
        XCTAssertEqual(ChatHistoryStore.retentionDays(defaults: defaults), 30)
    }
}
