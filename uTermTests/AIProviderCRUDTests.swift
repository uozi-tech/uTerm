import XCTest
import SwiftData
@testable import uTerm

@MainActor
final class AIProviderCRUDTests: XCTestCase {
    private func makeContainer() throws -> ModelContainer {
        let config = ModelConfiguration(isStoredInMemoryOnly: true)
        return try ModelContainer(for: AIProvider.self, configurations: config)
    }

    func testInsertAndFetch() throws {
        let container = try makeContainer()
        let ctx = container.mainContext
        let p = AIProvider(name: "Claude", kind: .anthropic,
                            baseURL: ProviderPreset.anthropicBaseURL,
                            model: "claude-opus-4-7")
        ctx.insert(p)
        try ctx.save()
        let fetched = try ctx.fetch(FetchDescriptor<AIProvider>())
        XCTAssertEqual(fetched.count, 1)
        XCTAssertEqual(fetched.first?.name, "Claude")
        XCTAssertEqual(fetched.first?.kindRaw, ProviderKind.anthropic.rawValue)
    }

    func testDeleteRemovesEntry() throws {
        let container = try makeContainer()
        let ctx = container.mainContext
        let p = AIProvider(name: "X", kind: .openai,
                            baseURL: ProviderPreset.openAIBaseURL,
                            model: "gpt-5")
        ctx.insert(p)
        try ctx.save()
        ctx.delete(p)
        try ctx.save()
        let fetched = try ctx.fetch(FetchDescriptor<AIProvider>())
        XCTAssertTrue(fetched.isEmpty)
    }

    func testSortIndexOrdering() throws {
        let container = try makeContainer()
        let ctx = container.mainContext
        let a = AIProvider(name: "A", kind: .anthropic,
                            baseURL: "", model: "", sortOrder: 2)
        let b = AIProvider(name: "B", kind: .openai,
                            baseURL: "", model: "", sortOrder: 0)
        let c = AIProvider(name: "C", kind: .openai,
                            baseURL: "", model: "", sortOrder: 1)
        ctx.insert(a); ctx.insert(b); ctx.insert(c)
        try ctx.save()
        let fetched = try ctx.fetch(FetchDescriptor<AIProvider>(
            sortBy: [SortDescriptor(\.sortOrder)]))
        XCTAssertEqual(fetched.map(\.name), ["B", "C", "A"])
    }
}
