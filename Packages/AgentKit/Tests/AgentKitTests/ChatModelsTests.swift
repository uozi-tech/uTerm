import Foundation
import SwiftData
import XCTest
@testable import AgentKit

@MainActor
final class ChatModelsTests: XCTestCase {

    private func makeContext() throws -> ModelContext {
        let schema = Schema([ChatSession.self, ChatMessageRecord.self])
        let config = ModelConfiguration(schema: schema, isStoredInMemoryOnly: true, cloudKitDatabase: .none)
        let container = try ModelContainer(for: schema, configurations: [config])
        return ModelContext(container)
    }

    func testOrderedMessagesSortsByOrderIndexThenCreatedAt() throws {
        let context = try makeContext()
        let session = ChatSession(title: "s")
        context.insert(session)

        // Out-of-order inserts, explicit orderIndex (uTable-style).
        let third = ChatMessageRecord(roleRaw: "assistant", text: "third", orderIndex: 2)
        let first = ChatMessageRecord(roleRaw: "user", text: "first", orderIndex: 0)
        let second = ChatMessageRecord(roleRaw: "assistant", text: "second", orderIndex: 1)
        for record in [third, first, second] {
            record.session = session
            context.insert(record)
        }
        try context.save()

        XCTAssertEqual(session.orderedMessages.map(\.text), ["first", "second", "third"])
    }

    func testOrderedMessagesDegradesToCreatedAtWhenOrderIndexIsAllZero() throws {
        // uTerm never sets orderIndex (always the default 0), so ordering
        // must fall back to createdAt exactly as it did before this field
        // existed.
        let context = try makeContext()
        let session = ChatSession(title: "s")
        context.insert(session)

        let older = ChatMessageRecord(roleRaw: "user", text: "older", createdAt: Date(timeIntervalSince1970: 1))
        let newer = ChatMessageRecord(roleRaw: "assistant", text: "newer", createdAt: Date(timeIntervalSince1970: 2))
        newer.session = session
        older.session = session
        context.insert(newer)
        context.insert(older)
        try context.save()

        XCTAssertEqual(session.orderedMessages.map(\.text), ["older", "newer"])
    }

    func testPreviewPrefersDisplayTextOverRawText() throws {
        let context = try makeContext()
        let session = ChatSession(title: "s")
        context.insert(session)

        let record = ChatMessageRecord(roleRaw: "user", text: "expanded prompt body", displayText: "/explain", orderIndex: 0)
        record.session = session
        context.insert(record)
        try context.save()

        XCTAssertEqual(session.preview, "/explain")
    }

    func testPreviewFallsBackToTextWhenNoDisplayAlias() throws {
        let context = try makeContext()
        let session = ChatSession(title: "s")
        context.insert(session)

        let record = ChatMessageRecord(roleRaw: "user", text: "plain question", orderIndex: 0)
        record.session = session
        context.insert(record)
        try context.save()

        XCTAssertEqual(session.preview, "plain question")
    }

    func testScopeIDFiltersIndependentlyOfHistoryOrdering() throws {
        let context = try makeContext()
        let scopeA = UUID()
        let scopeB = UUID()
        let inScope = ChatSession(title: "a", scopeID: scopeA)
        let outOfScope = ChatSession(title: "b", scopeID: scopeB)
        let unscoped = ChatSession(title: "c") // uTerm-style: scopeID stays nil
        context.insert(inScope)
        context.insert(outOfScope)
        context.insert(unscoped)
        try context.save()

        let sessions = try context.fetch(FetchDescriptor<ChatSession>(
            predicate: #Predicate { $0.scopeID == scopeA }
        ))
        XCTAssertEqual(sessions.map(\.id), [inScope.id])
        XCTAssertNil(unscoped.scopeID)
    }

    func testCascadeDeleteRemovesMessages() throws {
        let context = try makeContext()
        let session = ChatSession(title: "to delete")
        context.insert(session)
        let record = ChatMessageRecord(roleRaw: "user", text: "x")
        record.session = session
        context.insert(record)
        try context.save()

        context.delete(session)
        try context.save()

        XCTAssertTrue(try context.fetch(FetchDescriptor<ChatSession>()).isEmpty)
        XCTAssertTrue(try context.fetch(FetchDescriptor<ChatMessageRecord>()).isEmpty)
    }
}
