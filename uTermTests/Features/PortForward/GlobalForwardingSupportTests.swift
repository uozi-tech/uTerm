import XCTest
import SwiftData
@testable import uTerm

/// 全局端口转发的纯逻辑单测：分组 / 过程态映射 / 汇总计数 + `launchAtAppStart` 模型往返。
/// 纯函数喂值类型断言（仿 `PortConflictCheckerTests`）；模型测试用内存容器。
@MainActor
final class GlobalForwardingSupportTests: XCTestCase {

    private func err() -> TunnelStatus {
        .error(ForwardingError(kind: .unreachable, message: "目标不可达"))
    }

    // MARK: - gfGroupByHost

    private struct H { let id: UUID }
    private struct R: Equatable { let id: UUID; let serverID: UUID }

    func testGroupByHostFollowsHostOrderAndSkipsEmpty() {
        let h1 = H(id: UUID()), h2 = H(id: UUID()), h3 = H(id: UUID())
        let r1a = R(id: UUID(), serverID: h1.id)
        let r1b = R(id: UUID(), serverID: h1.id)
        let r3 = R(id: UUID(), serverID: h3.id)
        let orphan = R(id: UUID(), serverID: UUID())   // 主机外键对不上 → 丢弃

        let groups = gfGroupByHost(
            hosts: [h1, h2, h3],
            rules: [r3, r1a, orphan, r1b],   // 故意乱序
            hostID: { $0.id }, ruleServerID: { $0.serverID })

        // h2 无规则被跳过；组顺序按 hosts（h1 在 h3 前）。
        XCTAssertEqual(groups.map(\.host.id), [h1.id, h3.id])
        // 组内规则保持入参相对顺序（r1a 先于 r1b）。
        XCTAssertEqual(groups[0].rules, [r1a, r1b])
        XCTAssertEqual(groups[1].rules, [r3])
    }

    func testGroupByHostEmptyWhenNoRules() {
        let h1 = H(id: UUID())
        let groups = gfGroupByHost(hosts: [h1], rules: [R](),
                                   hostID: { $0.id }, ruleServerID: { $0.serverID })
        XCTAssertTrue(groups.isEmpty)
    }

    // MARK: - gfSummary

    func testSummaryCounts() {
        let statuses: [TunnelStatus] = [.active, .inactive, err(), .active]
        let launch = [true, true, true, false]
        let s = gfSummary(statuses: statuses, launchFlags: launch)
        XCTAssertEqual(s.ruleTotal, 4)
        XCTAssertEqual(s.activeTotal, 2)   // 索引 0、3
        XCTAssertEqual(s.launchTotal, 3)   // 索引 0、1、2
        XCTAssertEqual(s.upCount, 1)       // 自启 & active → 索引 0
        XCTAssertEqual(s.failCount, 1)     // 自启 & error → 索引 2
    }

    func testSummaryAllInactive() {
        let s = gfSummary(statuses: [.inactive, .inactive], launchFlags: [false, false])
        XCTAssertEqual(s, GFSummary(ruleTotal: 2, activeTotal: 0, launchTotal: 0,
                                    upCount: 0, failCount: 0))
    }

    // MARK: - gfFormatBytes / gfFormatRate（流量格式化，二进制 1024 进制）

    func testFormatBytes() {
        XCTAssertEqual(gfFormatBytes(0), "0 B")
        XCTAssertEqual(gfFormatBytes(512), "512 B")
        XCTAssertEqual(gfFormatBytes(1023), "1023 B")
        XCTAssertEqual(gfFormatBytes(1024), "1.0 KB")
        XCTAssertEqual(gfFormatBytes(1536), "1.5 KB")
        XCTAssertEqual(gfFormatBytes(1024 * 1024), "1.0 MB")
        XCTAssertEqual(gfFormatBytes(3 * 1024 * 1024 * 1024), "3.0 GB")
        // 边界进位：1048527 = 1023.999… KB，%.1f 会进位 → 应提档成「1.0 MB」而非「1024.0 KB」。
        XCTAssertEqual(gfFormatBytes(1_048_527), "1.0 MB")
    }

    func testFormatRate() {
        XCTAssertEqual(gfFormatRate(0), "0 B/s")
        XCTAssertEqual(gfFormatRate(2048), "2.0 KB/s")
    }

    // MARK: - launchAtAppStart 模型往返（与 autostart 互不干扰）

    private func makeContext() throws -> ModelContext {
        let config = ModelConfiguration(isStoredInMemoryOnly: true)
        return ModelContext(try ModelContainer(for: ForwardingRule.self, configurations: config))
    }

    func testLaunchAtAppStartPersistsIndependentlyFromAutostart() throws {
        let ctx = try makeContext()
        let sid = UUID()
        let rule = ForwardingRule(serverID: sid, name: "db", kind: .local,
                                  listenHost: "127.0.0.1", listenPort: 5432,
                                  destHost: "10.0.1.5", destPort: 5432,
                                  destLabel: nil, autostart: false, sortOrder: 0,
                                  launchAtAppStart: true)
        ctx.insert(rule)
        try ctx.save()

        let fetched = try ctx.fetch(FetchDescriptor<ForwardingRule>()).first
        XCTAssertEqual(fetched?.launchAtAppStart, true)
        XCTAssertEqual(fetched?.autostart, false)   // 两个标志独立
    }

    func testLaunchAtAppStartDefaultsFalse() throws {
        let ctx = try makeContext()
        let rule = ForwardingRule(serverID: UUID(), name: "x", kind: .dynamic,
                                  listenHost: "127.0.0.1", listenPort: 1080,
                                  destHost: nil, destPort: 0,
                                  destLabel: nil, autostart: true, sortOrder: 0)
        ctx.insert(rule)
        try ctx.save()
        let fetched = try ctx.fetch(FetchDescriptor<ForwardingRule>()).first
        XCTAssertEqual(fetched?.launchAtAppStart, false)   // 未传 → 默认 false
        XCTAssertEqual(fetched?.autostart, true)
    }
}
