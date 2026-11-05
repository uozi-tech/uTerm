import AppKit
import SwiftData
import SwiftUI
import UAppKitBridge
import UDesignKit
import XCTest
@testable import uTerm

// 「整表一个 tracking area，按行高算命中行」这一轮的量尺 + 闸门。
//
// 上一轮（`ScrollHoverGateProbeTests`）把「滚动期间不转发 hover」做掉了，但只挡在
// SwiftUI 这一层：光标停在列表内滚动仍比停在列表外贵 1.35~2.31×。
//
// **去之前的病因假设是错的，这份探针第一件事就是把它推翻了。** 原以为「SwiftUI 的
// 每一个 `.onHover` 都是 hosting view 上的一块 `NSTrackingArea`」，光标在窗内时
// AppKit 每帧重算整窗追踪区，按行数收费。实测：2000 行的列表整棵树上**自始至终
// 只有 1~3 块**追踪区（`tracking-areas=` 那一栏），跟行数一点关系都没有 ——
// SwiftUI 自己就是「一块追踪区 + 内部按区域派发」。逐行的账在它内部那张 hover
// 区域表上：区域越多，每次鼠标位置 / 几何变化要过的表越长，命中之后还要把
// `@State` 写回、让那一行重求 body。
//
// 换句话说：**这一轮做的事跟原计划一样（整表一个跟踪层 + 按行几何算行号），
// 省掉的却不是 AppKit 的追踪区，而是 SwiftUI 的那张区域表**。
//
// 四臂：光标在外 / 在内 × 跟踪器关 / 开，**滚动闸门四臂全开**（它已经是产线形态，
// 这一轮的分母就是「上一轮之后的现状」）。
//
// 判据（结构 / 相对，绝对毫秒只打印）：
// 1. **结构闸门**：滚动 200 步期间的行级 hover 事件数（`hover-suppressed`）——
//    改前几百次、改后必须是 0。它同样是结构量、对机器负载免疫，而且直接对应
//    「行里还有没有 `.onHover`」。追踪区数只打印，不做闸门（见上）。
// 2. 合成光标自证：跟踪器关 + 光标在内，200 步滚动必须真的产生大量 hover 事件 ——
//    读到 0 说明合成光标没生效，整轮作废。
// 3. 时间（有前提）：改前「光标在内」确实比「在外」贵出 20% 以上时，改后
//    ① 必须真的更便宜，② in/out 比值必须落进 1.2 以内 —— 后者正是上一轮
//    立不住、这一轮才有资格立的那条。

// MARK: - 四臂

struct RowHoverArm: Equatable {
    let cursorInside: Bool
    /// 整表跟踪器是否生效（false = 上一轮之后、这一轮之前的形态：逐行 `.onHover`）。
    let tracked: Bool
    var key: String { "\(cursorInside ? "in" : "out")-\(tracked ? "on" : "off")" }

    /// 两遍：正序一遍、逆序一遍（抵消机器温度漂移），共 8 次建窗。
    static let plan: [RowHoverArm] = {
        let forward = [RowHoverArm(cursorInside: false, tracked: false),
                       RowHoverArm(cursorInside: true, tracked: false),
                       RowHoverArm(cursorInside: true, tracked: true),
                       RowHoverArm(cursorInside: false, tracked: true)]
        return forward + forward.reversed()
    }()
}

/// 四臂共用的断言。
@MainActor
func assertRowHoverTrackerContract(_ readings: [String: HoverGateReading],
                                   view: String,
                                   file: StaticString = #filePath,
                                   line: UInt = #line) throws {
    let outOff = try XCTUnwrap(readings["out-off"])
    let inOff = try XCTUnwrap(readings["in-off"])
    let inOn = try XCTUnwrap(readings["in-on"])
    let outOn = try XCTUnwrap(readings["out-on"])
    for r in [outOff, inOff, inOn, outOn] {
        print("[row-hover-avg] \(view) \(r.oneLine)")
    }

    let ratioOff = inOff.frameP50 / max(outOff.frameP50, 1e-9)
    let ratioOn = inOn.frameP50 / max(outOn.frameP50, 1e-9)
    print(String(format: """
        [row-hover-ratio] %@ 光标在内 p50 %.3f → %.3fms（%.0f%%）；\
        in/out 比值 跟踪器关 %.2f× → 开 %.2f×；超预算 %.1f%% → %.1f%%；\
        追踪区 %d → %d；NSView 波动 %d → %d
        """, view, inOff.frameP50, inOn.frameP50,
        (inOn.frameP50 / max(inOff.frameP50, 1e-9) - 1) * 100,
        ratioOff, ratioOn, inOff.overBudget, inOn.overBudget,
        inOff.trackingAreas, inOn.trackingAreas,
        inOff.viewsMax - inOff.viewsMin, inOn.viewsMax - inOn.viewsMin))

    // ① **结构闸门**：滚动 200 步期间行级 hover 事件数。
    //
    // 原本想立的是「追踪区个数」：以为 SwiftUI 的每个 `.onHover` 各占 hosting view
    // 上一块 `NSTrackingArea`。**实测推翻了**：2000 行的合成列表整棵树上自始至终
    // 只有 1 块 —— SwiftUI 自己就是「一块追踪区 + 内部按区域派发」，逐行的账在它
    // 内部那张 hover 区域表上，不在 AppKit 的追踪区上。所以追踪区数只打印
    // （`tracking-areas=` 那一栏），闸门改用**行级 hover 事件数**：它同样是结构量、
    // 同样对机器负载免疫，而且直接对应「行里还有没有 `.onHover`」。
    XCTAssertEqual(inOn.trackingAreas, outOn.trackingAreas,
                   "\(view)：追踪区数不该随光标位置变", file: file, line: line)

    // ② 合成光标自证：改前臂必须真的在滚动中产生 hover 事件（闸门吃掉的那些）。
    //    读到 0 只能说明「谎报的光标没被 AppKit 采纳」，下面的时间对比全是假的。
    XCTAssertGreaterThan(inOff.hoverSuppressed, 20,
                         "\(view)：光标在列表中央 + 逐行 `.onHover`，200 步滚动必须产生大量 "
                         + "hover 事件（被闸门吃掉）；实测 \(inOff.hoverSuppressed)",
                         file: file, line: line)
    // 光标在窗外时 hover 流量必须低一个数量级。
    //
    // **不是恒 0**：SFTP 真实档（500 条）实测在光标被挡在窗外的臂上仍抓到 5~64 次
    // `.onHover` 回调（转发 0~1 次，也就是一行都没真的亮起来）。没有归因 ——
    // 疑似 `LazyVStack` 新建行时 SwiftUI 为登记 hover 区域补发的初值，或上一臂
    // 的窗口拆除时的收尾回调落进了这一臂的计数窗口。极端档（20000 条）恒 0。
    // 判据因此写成比值：够钉住「合成光标真的在起作用」，又不会被这点噪声打红。
    XCTAssertLessThan(outOff.hoverSuppressed * 4, inOff.hoverSuppressed,
                      "\(view)：光标在窗外的 hover 流量必须远低于光标在内 —— "
                      + "窗外 \(outOff.hoverSuppressed)、窗内 \(inOff.hoverSuppressed)",
                      file: file, line: line)
    XCTAssertLessThanOrEqual(outOff.hoverForwarded, 1,
                             "\(view)：光标在窗外不该有行真的亮起来（转发 "
                             + "\(outOff.hoverForwarded) 次）", file: file, line: line)

    // ③ 改后行里一个 `.onHover` 都没有：闸门那条路必须彻底静默。
    XCTAssertEqual(inOn.hoverSuppressed, 0,
                   "\(view)：跟踪器接管之后行里不该还有 `.onHover`（`hoverGated` 仍在吃事件："
                   + "\(inOn.hoverSuppressed) 次）", file: file, line: line)

    // ④ 时间判据**有前提**（同 `assertHoverGateContract`）：这一轮 hover 那笔账
    //    得先显出来。机器一忙它就淹没在噪声里，那时只留结构判据。
    let hoverCostOff = inOff.frameP50 - outOff.frameP50
    if hoverCostOff > outOff.frameP50 * 0.2 {
        XCTAssertLessThan(inOn.frameP50, inOff.frameP50 * 0.97,
                          "\(view)：整表一个追踪区之后「光标在列表上」的单帧 p50 必须真的降下来 —— "
                          + String(format: "改前 %.3fms → 改后 %.3fms", inOff.frameP50, inOn.frameP50),
                          file: file, line: line)
        // 本轮的目标线：光标在内 / 在外只许差两成。上一轮这条立不住（1.37 /
        // 1.53 / 2.56），因为剩下的那一截就在「每行一块追踪区」这个形态里。
        XCTAssertLessThanOrEqual(ratioOn, 1.2,
                                 "\(view)：整表一个追踪区之后 in/out 比值必须落进 1.2 —— "
                                 + String(format: "实测 %.2f×（同轮改前 %.2f×）", ratioOn, ratioOff),
                                 file: file, line: line)
    } else {
        print(String(format: "[row-hover-ratio] %@ 这一轮 hover 的账没冒头（改前 in/out %.2f×），"
                     + "只留结构判据", view, ratioOff))
    }

    // ⑤ 滚动期间的 NSView 波动不得变大（「悬停才建真控件」被建了又拆的直接判据）。
    XCTAssertLessThanOrEqual(inOn.viewsMax - inOn.viewsMin, inOff.viewsMax - inOff.viewsMin,
                             "\(view)：跟踪器接管之后滚动期间的 NSView 波动不该变大 —— "
                             + "改前 \(inOff.viewsMin)..\(inOff.viewsMax) → "
                             + "改后 \(inOn.viewsMin)..\(inOn.viewsMax)",
                             file: file, line: line)
}

// MARK: - 欢迎页服务器列表

@MainActor
final class WelcomeServerListRowHoverTests: XCTestCase {

    private let rig = ScrollHoverProbeRig()
    private static let size = NSSize(width: 980, height: 640)
    /// 列表列在左侧（右侧是选中后滑入的 `HostDetailPanel`），所以光标按在左 1/4 处。
    private static let cursor = NSPoint(x: size.width * 0.25, y: size.height * 0.5)
    /// 真实档 100 台 / 10 组、极端档 2000 台 / 60 组（与 `WelcomeServerListCostTests` 同档）。
    func testExtremeScale() async throws {
        try await run(rows: 2000, groups: 60)
    }

    func testRealisticScale() async throws {
        try await run(rows: 100, groups: 10)
    }

    private func run(rows: Int, groups: Int) async throws {
        defer {
            RowHoverState.isEnabledByDefault = true
            rig.closeAllWindows()
        }
        var results: [String: [HoverGateReading]] = [:]
        for arm in RowHoverArm.plan {
            RowHoverState.isEnabledByDefault = arm.tracked
            let profiles = WelcomeServerListCostTests.makeProfiles(count: rows, groups: groups)
            let fixture = try rig.mount(
                TrackerProbeServerListHost(profiles: profiles, groups: groups),
                size: Self.size,
                cursor: arm.cursorInside ? Self.cursor : nil)
            let reading = try await rig.measure(fixture, label: "welcome-\(rows)/\(arm.key)",
                                                rows: rows,
                                                cursorInside: arm.cursorInside, gated: arm.tracked)
            results[arm.key, default: []].append(reading)
            await rig.closeWindowsAndSettle()
        }
        try assertRowHoverTrackerContract(results.mapValues(ScrollHoverProbeRig.average),
                                          view: "欢迎页服务器列表 \(rows) 台")
    }
}

/// 产线 `ServerList` 的最小宿主（只补它要的两个 `@Binding`）。
private struct TrackerProbeServerListHost: View {
    let profiles: [ServerProfile]
    let groups: Int
    @State private var selectedID: UUID?
    @State private var draggingID: UUID?

    var body: some View {
        ServerList(profiles: profiles,
                   query: "",
                   selectedID: $selectedID,
                   draggingProfileID: $draggingID,
                   onOpen: { _ in },
                   onContextAction: { _, _ in },
                   existingGroups: WelcomeServerListCostTests.groupNames(groups),
                   groupColors: WelcomeServerListCostTests.groupColors(groups))
    }
}

// MARK: - SFTP 文件表

@MainActor
final class SFTPFileTableRowHoverTests: XCTestCase {

    private let rig = ScrollHoverProbeRig()
    private static let size = NSSize(width: 1200, height: 780)
    private static let cursor = NSPoint(x: size.width * 0.4, y: size.height * 0.5)

    /// 真实档 500 条、极端档 20000 条（与 `FileBrowserScrollCostTests` 同档）。
    func testExtremeScale() async throws {
        try await run(rows: FileBrowserProbeFixture.extreme)
    }

    func testRealisticScale() async throws {
        try await run(rows: FileBrowserProbeFixture.realistic)
    }

    private func run(rows: Int) async throws {
        defer {
            RowHoverState.isEnabledByDefault = true
            rig.closeAllWindows()
        }
        var results: [String: [HoverGateReading]] = [:]
        for arm in RowHoverArm.plan {
            RowHoverState.isEnabledByDefault = arm.tracked
            let model = await FileBrowserProbeFixture.model(rows)
            let fixture = try rig.mount(
                SFTPBrowserView(model: model, server: ServerProfile(), openWorkspace: {}),
                size: Self.size,
                cursor: arm.cursorInside ? Self.cursor : nil)
            let reading = try await rig.measure(fixture, label: "sftp-\(rows)/\(arm.key)", rows: rows,
                                                cursorInside: arm.cursorInside, gated: arm.tracked)
            results[arm.key, default: []].append(reading)
            await rig.closeWindowsAndSettle()
        }
        try assertRowHoverTrackerContract(results.mapValues(ScrollHoverProbeRig.average),
                                          view: "SFTP 文件表 \(rows) 条")
    }
}

// MARK: - 全局端口转发

@MainActor
final class GlobalForwardingRowHoverTests: XCTestCase {

    private let rig = ScrollHoverProbeRig()
    private static let size = NSSize(width: 900, height: 700)
    private static let cursor = NSPoint(x: size.width * 0.4, y: size.height * 0.45)

    /// 真实档 10 主机 × 5 条 = 50 行、极端档 50 × 20 = 1000 行
    /// （与 `GlobalForwardingListCostTests` 同档）。
    func testExtremeScale() async throws {
        try await run(hosts: 50, rulesPerHost: 20)
    }

    func testRealisticScale() async throws {
        try await run(hosts: 10, rulesPerHost: 5)
    }

    private func run(hosts: Int, rulesPerHost: Int) async throws {
        defer {
            RowHoverState.isEnabledByDefault = true
            rig.closeAllWindows()
        }
        // 见 `GlobalForwardingListCostTests`：**所有 SwiftData 容器必须在挂第一个
        // 窗口之前建好** —— 上一档的 `@Query` 观察者还没散时给下一档存盘会在通知
        // 回调里把测试宿主打没。
        let seeds = try RowHoverArm.plan.map { _ in
            try ForwardingProbeFixture.seed(hosts: hosts, rulesPerHost: rulesPerHost)
        }
        var results: [String: [HoverGateReading]] = [:]
        for (index, arm) in RowHoverArm.plan.enumerated() {
            RowHoverState.isEnabledByDefault = arm.tracked
            let seed = seeds[index]
            let root = AnyView(
                GlobalForwardingWindowView()
                    .environment(seed.coordinator)
                    .environment(GlobalForwardingModel())
                    .environment(HostKeyChallengeRelay())
                    .modelContainer(seed.container))
            let fixture = try rig.mount(root, size: Self.size,
                                        cursor: arm.cursorInside ? Self.cursor : nil)
            let reading = try await rig.measure(fixture,
                                                label: "gfwd-\(hosts)x\(rulesPerHost)/\(arm.key)",
                                                rows: hosts * rulesPerHost,
                                                cursorInside: arm.cursorInside, gated: arm.tracked)
            results[arm.key, default: []].append(reading)
            await rig.closeWindowsAndSettle()
        }
        try assertRowHoverTrackerContract(results.mapValues(ScrollHoverProbeRig.average),
                                          view: "全局端口转发 \(hosts * rulesPerHost) 行")
    }
}

// MARK: - 行为（合成列表，判据是行为不是时间）

/// 每一行把 enter / exit 记在这里。
@MainActor
final class TrackerHoverLedger {
    private(set) var hovering: Set<Int> = []
    private(set) var events = 0
    var step = 0
    private(set) var trace: [String] = []

    func record(index: Int, hovering isHovering: Bool) {
        // 只统计**真的换了**的那些：`LazyVStack` 滚动中新建一行时行自己会带一个
        // 初始 false，那不是一次悬停变化。
        let changed = isHovering ? hovering.insert(index).inserted : hovering.remove(index) != nil
        guard changed else { return }
        events += 1
        if trace.count < 40 { trace.append("step\(step):row\(index)=\(isHovering)") }
    }

    func reset() {
        events = 0
        trace.removeAll()
    }
}

private struct TrackerProbeRow: View {
    let index: Int
    let ledger: TrackerHoverLedger
    let state: RowHoverState
    @State private var hover = false

    var body: some View {
        Text("row-\(index)")
            .font(.system(size: 12))
            .frame(maxWidth: .infinity, alignment: .leading)
            .frame(height: 28)
            .background(hover ? Color.gray.opacity(0.25) : Color.clear)
            .contentShape(Rectangle())
            .rowHover(state, id: index) { hovering in
                hover = hovering
                ledger.record(index: index, hovering: hovering)
            }
    }
}

private struct TrackerProbeList: View {
    let ledger: TrackerHoverLedger
    let rows: Int
    @State private var state = RowHoverState()

    var body: some View {
        ScrollView {
            LazyVStack(spacing: 0) {
                ForEach(0..<rows, id: \.self) { TrackerProbeRow(index: $0, ledger: ledger,
                                                               state: state) }
            }
            .rowHoverTracker(state, geometry: .fixedHeight(rowHeight: 28, rowCount: rows) {
                $0.map { AnyHashable($0) }
            })
            .scrollHoverGate()
        }
        .background(Color.white)
    }
}

@MainActor
final class RowHoverTrackerBehaviourTests: XCTestCase {

    private let rig = ScrollHoverProbeRig()
    private static let size = NSSize(width: 420, height: 420)
    private static let cursor = NSPoint(x: 200, y: 200)

    /// 契约：静止时光标底下正好一行亮 → 滚动中一行都不亮 → 停下之后**换到新的
    /// 那一行**亮起来。
    ///
    /// 最后一段是这一轮的关键：光标一动没动，但内容在它底下滚过去了，底下已经
    /// 换了一行 —— 而整块可视区只有一个追踪区，「在不在里面」自始至终没变，
    /// AppKit 不会为此发任何事件。所以停下之后必须由跟踪器自己按
    /// `window.mouseLocationOutsideOfEventStream` 补算一次。
    func testTrackerSuspendsDuringScrollAndRecomputesAfterQuiet() async throws {
        defer {
            ScrollHoverGate.isEnabledByDefault = true
            RowHoverState.isEnabledByDefault = true
            rig.closeAllWindows()
        }
        ScrollHoverGate.isEnabledByDefault = true
        RowHoverState.isEnabledByDefault = true
        let ledger = TrackerHoverLedger()
        let fixture = try rig.mount(TrackerProbeList(ledger: ledger, rows: 2000),
                                    size: Self.size, cursor: Self.cursor)
        let scroll = fixture.scroll
        let host = fixture.host
        func layout() { host.layoutSubtreeIfNeeded(); host.displayIfNeeded() }
        func scrollTo(_ y: CGFloat) {
            scroll.contentView.scroll(to: NSPoint(x: 0, y: max(0, y)))
            scroll.reflectScrolledClipView(scroll.contentView)
        }

        // 整块列表只有一块追踪区（改前是 2000 行各一块）。
        let areas = ScrollHoverProbeRig.trackingAreaCount(in: host)
        XCTAssertLessThanOrEqual(areas, 2,
                                 "整表跟踪器装上之后追踪区应当塌成常数，实测 \(areas)")

        // 静置：跟踪器要按合成光标补算出光标底下那一行。
        layout()
        try await Task.sleep(for: .milliseconds(400))
        layout()
        try await Task.sleep(for: .milliseconds(300))
        XCTAssertEqual(ledger.hovering.count, 1,
                       "静止时合成光标底下必须正好有一行是 hover 的，实测 \(ledger.hovering)")
        let restingRow = try XCTUnwrap(ledger.hovering.first)

        // 滚 200 步：期间一行都不该亮。
        ledger.reset()
        RowHoverStats.reset()
        for step in 1...200 {
            ledger.step = step
            scrollTo(CGFloat(step) * 6)
            layout()
            try await Task.sleep(for: .milliseconds(8))
            XCTAssertTrue(ledger.hovering.isEmpty,
                          "滚动第 \(step) 步还有行亮着：\(ledger.hovering)")
        }
        print("[row-hover-behaviour] 滚动 200 步：转发 \(ledger.events) 次；静止行 \(restingRow)；"
              + "轨迹 \(ledger.trace)")
        XCTAssertLessThanOrEqual(ledger.events, 1,
                                 "滚动期间最多只该有「进滚动时把那一行灭掉」这一次，"
                                 + "实测 \(ledger.events)")

        // 停下：必须补算出**新的**那一行（内容滚过去了 1200pt ≈ 42 行）。
        try await Task.sleep(for: .milliseconds(300))
        layout()
        try await Task.sleep(for: .milliseconds(120))
        layout()
        XCTAssertEqual(ledger.hovering.count, 1,
                       "停下之后光标底下那一行必须亮起来，实测 \(ledger.hovering)")
        let settledRow = try XCTUnwrap(ledger.hovering.first)
        XCTAssertNotEqual(settledRow, restingRow,
                          "内容滚过去了 1200pt，光标底下已经换了一行 —— 补算必须给出新行"
                          + "（滚前 \(restingRow)、滚后 \(settledRow)）")
        await rig.closeWindowsAndSettle()
    }

    /// 关掉跟踪器（探针的改前臂）时同一份夹具必须退回逐行 `.onHover` 并照常亮 ——
    /// 没有这条，上面那些「0」随时可能是「跟踪器压根没接上」的假绿。
    func testDisabledTrackerFallsBackToPerRowHover() async throws {
        defer {
            ScrollHoverGate.isEnabledByDefault = true
            RowHoverState.isEnabledByDefault = true
            rig.closeAllWindows()
        }
        ScrollHoverGate.isEnabledByDefault = true
        RowHoverState.isEnabledByDefault = false
        let ledger = TrackerHoverLedger()
        let fixture = try rig.mount(TrackerProbeList(ledger: ledger, rows: 2000),
                                    size: Self.size, cursor: Self.cursor)
        let host = fixture.host
        host.layoutSubtreeIfNeeded()
        host.displayIfNeeded()
        try await Task.sleep(for: .milliseconds(400))
        let areas = ScrollHoverProbeRig.trackingAreaCount(in: host)
        XCTAssertEqual(ledger.hovering.count, 1,
                       "退回逐行 `.onHover` 之后光标底下那一行照样要亮，实测 \(ledger.hovering)")

        // 滚一段，看逐行 `.onHover` 是不是真的在发（被滚动闸门吃掉的那些）。
        // 这是「跟踪器开着时 0 次」那条断言的对照臂：没有它，那个 0 随时可能是
        // 「合成光标压根没生效」的假绿。
        HoverGateStats.reset()
        let scroll = fixture.scroll
        for step in 1...60 {
            scroll.contentView.scroll(to: NSPoint(x: 0, y: CGFloat(step) * 6))
            scroll.reflectScrolledClipView(scroll.contentView)
            host.layoutSubtreeIfNeeded()
            host.displayIfNeeded()
            try await Task.sleep(for: .milliseconds(8))
        }
        let suppressed = HoverGateStats.suppressed
        print("[row-hover-behaviour] 跟踪器关：追踪区 \(areas) 块、hover \(ledger.hovering)、"
              + "滚 60 步逐行 hover 事件 \(suppressed) 次")
        XCTAssertGreaterThan(suppressed, 20,
                             "跟踪器关掉时行各自装着 `.onHover`，滚动必须产生大量 hover 事件；"
                             + "实测 \(suppressed) —— 说明开关没生效，改前臂的读数不算数")
        await rig.closeWindowsAndSettle()
    }
}
