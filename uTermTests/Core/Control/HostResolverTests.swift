import XCTest
@testable import uTerm

/// 主机名解析的三级规则 + 歧义 + UUID 直达。CloudKit 同步下同名主机是常态，
/// 「匹配到多条就报歧义并附候选」是这套规则的核心，绝不能退化成「猜第一条」——
/// 猜错就是把命令发到别的机器上。
final class HostResolverTests: XCTestCase {

    private let webA = HostResolver.Candidate(id: UUID(), name: "prod-web")
    private let webB = HostResolver.Candidate(id: UUID(), name: "prod-web")
    private let db = HostResolver.Candidate(id: UUID(), name: "Prod-DB")
    private let staging = HostResolver.Candidate(id: UUID(), name: "staging")

    private var all: [HostResolver.Candidate] { [webA, db, staging] }

    func testUUIDResolvesDirectly() {
        XCTAssertEqual(HostResolver.resolve(db.id.uuidString, in: all), .matched(db.id))
    }

    /// UUID 直达必须先于名字匹配，且在同名主机里也不歧义 —— 技能文档教模型歧义时改用 UUID，
    /// 这条就是那个出口。
    func testUUIDResolvesEvenWhenNamesCollide() {
        let candidates = [webA, webB, db]
        XCTAssertEqual(HostResolver.resolve(webB.id.uuidString, in: candidates), .matched(webB.id))
    }

    func testExactNameMatches() {
        XCTAssertEqual(HostResolver.resolve("prod-web", in: all), .matched(webA.id))
    }

    func testCaseInsensitiveNameMatches() {
        XCTAssertEqual(HostResolver.resolve("PROD-db", in: all), .matched(db.id))
    }

    func testUniquePrefixMatches() {
        XCTAssertEqual(HostResolver.resolve("stag", in: all), .matched(staging.id))
        // 前缀也忽略大小写。
        XCTAssertEqual(HostResolver.resolve("prod-d", in: all), .matched(db.id))
    }

    func testDuplicateExactNamesAreAmbiguousWithCandidates() {
        guard case .ambiguous(let matches) = HostResolver.resolve("prod-web", in: [webA, webB, db]) else {
            return XCTFail("同名两台必须报歧义，而不是挑一台")
        }
        XCTAssertEqual(Set(matches.map(\.id)), [webA.id, webB.id])
    }

    func testAmbiguousPrefixReturnsEveryCandidate() {
        guard case .ambiguous(let matches) = HostResolver.resolve("prod", in: all) else {
            return XCTFail("prod 同时命中 prod-web 与 Prod-DB，应报歧义")
        }
        XCTAssertEqual(Set(matches.map(\.id)), [webA.id, db.id])
    }

    /// 精确命中优先于前缀：`stag` 是 `staging` 的前缀，但完整名字存在时不该被前缀规则干扰。
    func testExactMatchWinsOverLongerPrefixNeighbours() {
        let short = HostResolver.Candidate(id: UUID(), name: "web")
        let long = HostResolver.Candidate(id: UUID(), name: "web-2")
        XCTAssertEqual(HostResolver.resolve("web", in: [short, long]), .matched(short.id))
    }

    func testNotFound() {
        XCTAssertEqual(HostResolver.resolve("nope", in: all), .notFound)
    }

    func testEmptyNeedleIsNotFound() {
        XCTAssertEqual(HostResolver.resolve("   ", in: all), .notFound)
        XCTAssertEqual(HostResolver.resolve("prod-web", in: []), .notFound)
    }

    func testNeedleIsTrimmed() {
        XCTAssertEqual(HostResolver.resolve("  staging \n", in: all), .matched(staging.id))
    }
}
