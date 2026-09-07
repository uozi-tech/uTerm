import AppKit
import SwiftData
import SwiftUI
import UDesignKit
import XCTest
@testable import uTerm

/// 单主机端口转发窗口列表（`PortForwardListView` + `TunnelRow`）的渲染开销探针。
///
/// 改前的形态：`ScrollView + VStack + ForEach(visible)` **非 lazy**；`TunnelRow` 每行
/// 2 个图标 `Button`（编辑 / 删除）+ `UDToggle`（也是 `Button`）+ **4 处 `.help`** +
/// `onHover` + 双击手势；失败行还要多画一条原因条（再一个 `Button`）。
///
/// 规模来源：单台主机的规则数（`@Query` 按 `serverID` 过滤，**无上限**）。
/// 真实档 8 条（一台机器上手工建的转发通常个位数）；极端档 200 条。
///
/// 两臂同轮交替：`production` 与保留改前容器形状的 `legacyNonLazyList`。
@MainActor
final class PortForwardListCostTests: XCTestCase {

    private var windows: [NSWindow] = []

    private func closeAllWindows() {
        for window in windows {
            window.contentView = NSView()
            window.orderOut(nil)
        }
        windows.removeAll()
    }

    private func closeWindows() async {
        closeAllWindows()
        try? await Task.sleep(for: .milliseconds(200))
    }

    private static let size = NSSize(width: 820, height: 640)

    private enum Arm: String {
        case production
        /// 改前的容器形状：非 lazy `VStack + ForEach`（行组件仍是产线的 `TunnelRow`）。
        case legacyNonLazyList
    }

    private struct Seeded {
        let container: ModelContainer
        let coordinator: ForwardingCoordinator
        let server: ServerProfile
        let rules: [ForwardingRule]
    }

    private func seed(rules count: Int) throws -> Seeded {
        let s = try ForwardingProbeFixture.seed(hosts: 1, rulesPerHost: count)
        return Seeded(container: s.container, coordinator: s.coordinator,
                      server: s.profiles[0], rules: s.rules)
    }

    private func rootView(_ arm: Arm, _ seeded: Seeded) -> AnyView {
        let relay = HostKeyChallengeRelay()
        let inner: AnyView
        switch arm {
        case .production:
            inner = AnyView(PortForwardListView(server: seeded.server,
                                                rules: seeded.rules,
                                                hostKeyRelay: relay))
        case .legacyNonLazyList:
            inner = AnyView(LegacyTunnelRowList(rules: seeded.rules))
        }
        return AnyView(
            inner
                .environment(seeded.coordinator)
                .modelContainer(seeded.container)
        )
    }

    private func measure(_ arm: Arm, _ seeded: Seeded, rows: Int)
        async throws -> ForwardingProbeReading {
        let mounted = try ForwardingProbeFixture.mount(rootView(arm, seeded),
                                                       size: Self.size,
                                                       windows: &windows)
        var reading = await ForwardingProbeFixture.measure(
            label: "\(arm.rawValue)/\(rows)", rows: rows, mounted: mounted)
        reading.label = "\(arm.rawValue)/\(rows)"
        print("[pfwd] \(reading.label) \(reading.oneLine)")
        print("[pfwd-views] \(reading.label) \(reading.histogram)")
        await closeWindows()
        return reading
    }

    /// 真实档 8 条与极端档 200 条，两臂同轮交替（轮内顺序反转一次）。
    ///
    /// 数据一次造完再挂窗 —— `ModelContext.save()` 的通知会打死还没散掉的
    /// `@Query` 观察者（见 `GlobalForwardingListCostTests` 的同一条注释）。
    func testSingleHostForwardListScale() async throws {
        defer { closeAllWindows() }

        let plan: [(Arm, Int)] = [
            (.production, 8),
            (.legacyNonLazyList, 8),
            (.legacyNonLazyList, 200),
            (.production, 200),
        ]
        let seeds = try plan.map { try seed(rules: $0.1) }

        var readings: [String: ForwardingProbeReading] = [:]
        for (index, (arm, rows)) in plan.enumerated() {
            let r = try await measure(arm, seeds[index], rows: rows)
            readings[r.label] = r
        }

        let smallProd = try XCTUnwrap(readings["production/8"])
        let bigProd = try XCTUnwrap(readings["production/200"])
        let bigLegacy = try XCTUnwrap(readings["legacyNonLazyList/200"])

        // ① 真的画出来了、真的能滚。
        XCTAssertGreaterThan(smallProd.views, 20, "8 条档必须真的建出视图，不能是空壳")
        XCTAssertGreaterThan(bigProd.scrollableHeight, 0, "200 条必须超过一屏")
        // ② 平台视图数不跟着行数长（非 lazy 时 200 行会全实例化）。
        XCTAssertLessThan(Double(bigProd.views), Double(smallProd.views) * 4,
                          "200 条的 NSView 数不该跟着行数长："
                          + "8 条 \(smallProd.views) vs 200 条 \(bigProd.views)"
                          + "（同轮改前臂 \(bigLegacy.views)）")
        // ③ hitTest 不随规模涨。
        XCTAssertLessThan(bigProd.hitP50, max(600, smallProd.hitP50 * 4),
                          "hitTest 不该随行数涨：8 条 \(smallProd.hitP50)µs vs "
                          + "200 条 \(bigProd.hitP50)µs（同轮改前臂 \(bigLegacy.hitP50)µs）")
    }
}

// MARK: - 改前臂：非 lazy 的一列 TunnelRow

/// **改前的容器形状**，只留作同轮对照臂 —— 产线代码已换掉，别再照它写新界面。
/// 与改前的 `PortForwardListView.list` 一字对应。
private struct LegacyTunnelRowList: View {
    let rules: [ForwardingRule]
    @Environment(ForwardingCoordinator.self) private var coordinator

    var body: some View {
        ScrollView {
            VStack(spacing: 0) {
                ForEach(Array(rules.enumerated()), id: \.element.id) { idx, rule in
                    TunnelRow(rule: rule,
                              status: coordinator.status(rule.id),
                              recentIssue: coordinator.connectionIssue(rule.id)?.reason,
                              isLast: idx == rules.count - 1,
                              onToggle: {}, onRetry: {}, onChangePort: {},
                              onEdit: {}, onDelete: {})
                }
            }
            .background(UD.bg)
            .clipShape(RoundedRectangle(cornerRadius: 9))
            .overlay(RoundedRectangle(cornerRadius: 9).strokeBorder(UD.border, lineWidth: 1))
        }
        .padding(.horizontal, 16)
        .padding(.top, 8)
        .padding(.bottom, 16)
    }
}
