import AppKit
import SwiftData
import SwiftUI
import UAppKitBridge
import UDesignKit
import XCTest
@testable import uTerm

// 「滚动的时候不要去计算 hover」这条产品级判断的量尺 + 闸门。
//
// 之前每一轮滚动探针都把用户的真光标挡在窗外（`ProbeWindow.blindsRealMouse`），
// 理由是「光标停在探针窗口上会让读数随鼠标位置漂」。挡对了 —— 但它同时把
// **用户真实姿势下的那笔账挡掉了**：用户是用手滚的轮，滚的时候光标必然就压在
// 列表上。于是每一行经过指针都触发一次 `.onHover` enter / exit，行里「悬停才
// 建真控件」的东西被反复建拆。
//
// 这个文件用 `ProbeWindow.Placement.transparentOnScreen(cursorAt:)`
// 谎报一个**固定在内容区里**的合成光标，把那笔账量出来，然后同轮对照闸门
// （`UAppKitBridge/ScrollHoverGate.swift`）关掉它之后的读数。
//
// 判据（结构 / 相对，绝对毫秒只打印）：
// 1. 自证：闸门关掉时，「光标在内」必须真的产生大量 hover 转发 —— 否则整份读数
//    都是「合成光标没生效」的假 0。
// 2. 闸门开时，滚动 200 步期间只剩「进滚动时把亮着的行灭掉」那一次转发
//    （`ScrollHoverGateBehaviourTests` 用逐步断言把「一行都没亮」钉得更死）。
// 3. 闸门开时，「光标在内」这一档的单帧 p50 必须比同轮改前真的降下来；
//    滚动期间的 NSView 波动不得变大。
// 4. 停下 200ms 后光标所在行的 hover 必须恢复成 true。
//
// **原本想立的判据是「in/out 比值 < 1.2」，实测立不住**（三处分别落在
// 1.37 / 1.53 / 2.56）。剩下那一截不在 SwiftUI 这一层：光标在窗内时 AppKit
// 每帧仍要重算整窗的 `NSTrackingArea` 并把 enter / exit 派进 hosting view，
// 我们只是不再往下转发。见 `assertHoverGateContract` 判据 ⑥。

// MARK: - 读数

struct HoverGateReading {
    let label: String
    /// 合成光标是不是按在列表上。
    let cursorInside: Bool
    /// 闸门是否生效（false = 改前的行为）。
    let gated: Bool
    let rows: Int
    let mountMS: Double
    let frameP50: Double
    let frameP95: Double
    let frameMax: Double
    let overBudget: Double
    /// 200 步滚动期间 `hoverGated` 真正转发给行的 enter / exit 次数。
    /// **这就是「滚动时还在不在算 hover」的那个数。**
    let hoverForwarded: Int
    /// 同期被闸门吃掉的次数（闸门关时恒 0）。
    let hoverSuppressed: Int
    /// 滚动期间抽样到的平台视图数的最小 / 最大 / 收尾值。
    /// 「悬停才建真控件」的行被反复建拆时，最大与最小之间会张开一条缝。
    let viewsMin: Int
    let viewsMax: Int
    let viewsEnd: Int
    let hitP50: Double

    var oneLine: String {
        String(format: """
            cursor=%@ gate=%@ rows=%d mount=%.2fms frame-p50=%.3fms p95=%.3fms max=%.3fms \
            over-8.33=%.1f%% hover-forwarded=%d hover-suppressed=%d views=%d..%d(end %d) \
            hit-p50=%.1fus
            """,
            cursorInside ? "inside" : "outside", gated ? "on" : "off",
            rows, mountMS, frameP50, frameP95, frameMax, overBudget,
            hoverForwarded, hoverSuppressed, viewsMin, viewsMax, viewsEnd, hitP50)
    }
}

// MARK: - 共用量尺

/// 建窗（可带合成光标）+ 扫掠 + 200 步往返 + hitTest。
@MainActor
final class ScrollHoverProbeRig {

    struct Fixture {
        let window: ProbeWindow.Unconstrained
        let host: NSHostingView<AnyView>
        let scroll: NSScrollView
        let document: NSView
        let mountMS: Double
    }

    private(set) var windows: [NSWindow] = []

    func closeAllWindows() {
        for window in windows {
            window.contentView = NSView()
            window.orderOut(nil)
        }
        windows.removeAll()
    }

    func closeWindowsAndSettle() async {
        closeAllWindows()
        try? await Task.sleep(for: .milliseconds(200))
    }

    /// - Parameter cursor: 合成光标在**窗口坐标系**里的落点；nil = 老行为（谎报在窗外）。
    func mount(_ view: some View, size: NSSize, cursor: NSPoint?) throws -> Fixture {
        let root = AnyView(view.frame(width: size.width, height: size.height))
        let host = NSHostingView(rootView: root)
        host.frame = NSRect(origin: .zero, size: size)
        let window = ProbeWindow.make(contentRect: NSRect(origin: .zero, size: size),
                                      styleMask: [.titled],
                                      contentView: host,
                                      key: true,
                                      placement: .transparentOnScreen(cursorAt: cursor))
        windows.append(window)
        ProbeWindow.isolateHostWindows(keeping: windows)
        window.appearance = NSAppearance(named: .aqua)
        let start = CFAbsoluteTimeGetCurrent()
        host.layoutSubtreeIfNeeded()
        host.displayIfNeeded()
        let mountMS = (CFAbsoluteTimeGetCurrent() - start) * 1000
        let scroll = try XCTUnwrap(host.firstScrollView(), "夹具里必须有 NSScrollView")
        let document = try XCTUnwrap(scroll.documentView, "NSScrollView 必须有 documentView")
        let unconstrained = try XCTUnwrap(window as? ProbeWindow.Unconstrained)
        // 两档都必须是**合成**光标：要么挡在窗外，要么按在指定点。真光标一旦
        // 参与，读数就取决于这轮跑测试时鼠标停在哪块屏（见 `ProbeWindow` 顶部）。
        XCTAssertTrue(ProbeWindow.reportsSyntheticCursor(unconstrained),
                      "探针窗口必须谎报鼠标位置，不能让用户真光标参与")
        if let cursor {
            XCTAssertEqual(unconstrained.mouseLocationOutsideOfEventStream, cursor,
                           "带光标那一档必须真的把合成光标按在指定点上")
        }
        return Fixture(window: unconstrained, host: host, scroll: scroll,
                       document: document, mountMS: mountMS)
    }

    /// 扫掠一遍（把懒行全部实例化）→ 归零计数 → 200 步往返 → hitTest。
    func measure(_ fixture: Fixture, label: String, rows: Int,
                 cursorInside: Bool, gated: Bool) async throws -> HoverGateReading {
        let scroll = fixture.scroll
        let document = fixture.document
        let host = fixture.host

        let viewport = scroll.contentSize.height
        let maxOffset = max(0, document.frame.height - viewport)
        let amplitude = min(maxOffset, viewport * 3)

        func scrollTo(_ y: CGFloat) {
            scroll.contentView.scroll(to: NSPoint(x: 0, y: min(maxOffset, max(0, y))))
            scroll.reflectScrolledClipView(scroll.contentView)
        }
        func layout() { host.layoutSubtreeIfNeeded(); host.displayIfNeeded() }

        var visited: CGFloat = 0
        while visited < amplitude {
            scrollTo(visited)
            layout()
            try await Task.sleep(for: .milliseconds(8))
            visited += max(1, viewport * 0.8)
        }
        scrollTo(0)
        layout()
        // 闸门的静默期是 150ms —— 扫掠之后必须等它归位，否则 200 步那一段的
        // 第一批读数会落在「上一段滚动还没停」的窗口里。
        try await Task.sleep(for: .milliseconds(300))

        HoverGateStats.reset()
        var frames: [Double] = []
        var viewSamples: [Int] = []
        for step in 0..<200 {
            let wave = 0.5 * (1 - cos(Double(step % 80) / 80 * 2 * .pi))
            let start = CFAbsoluteTimeGetCurrent()
            scrollTo(amplitude * wave)
            layout()
            frames.append((CFAbsoluteTimeGetCurrent() - start) * 1000)
            if step % 10 == 0 { viewSamples.append(Self.viewCount(in: host)) }
            try await Task.sleep(for: .milliseconds(8))
        }
        let forwarded = HoverGateStats.forwarded
        let suppressed = HoverGateStats.suppressed

        var hits: [Double] = []
        let scrollFrame = scroll.convert(scroll.bounds, to: host)
        for fraction in [0.02, 0.5, 0.98] {
            scrollTo(amplitude * fraction)
            layout()
            try await Task.sleep(for: .milliseconds(120))
            for i in 0..<100 {
                let point = NSPoint(x: scrollFrame.minX + CGFloat(20 + (i % 9) * 30),
                                    y: scrollFrame.minY + CGFloat(20 + (i % 11) * 30))
                let start = CFAbsoluteTimeGetCurrent()
                _ = host.hitTest(point)
                hits.append((CFAbsoluteTimeGetCurrent() - start) * 1_000_000)
            }
        }

        let reading = HoverGateReading(
            label: label,
            cursorInside: cursorInside,
            gated: gated,
            rows: rows,
            mountMS: fixture.mountMS,
            frameP50: ProbeMetrics.percentile(frames, 0.5),
            frameP95: ProbeMetrics.percentile(frames, 0.95),
            frameMax: frames.max() ?? 0,
            overBudget: Double(frames.filter { $0 > 8.33 }.count) / Double(frames.count) * 100,
            hoverForwarded: forwarded,
            hoverSuppressed: suppressed,
            viewsMin: viewSamples.min() ?? 0,
            viewsMax: viewSamples.max() ?? 0,
            viewsEnd: Self.viewCount(in: host),
            hitP50: ProbeMetrics.percentile(hits, 0.5))
        print("[hover-gate] \(label) \(reading.oneLine)")
        return reading
    }

    static func viewCount(in root: NSView) -> Int {
        var n = 0
        func walk(_ view: NSView) { n += 1; for sub in view.subviews { walk(sub) } }
        walk(root)
        return n
    }

    /// 同一档的多次读数取均值（计数取和的均值，视图数取极值）。
    static func average(_ readings: [HoverGateReading]) -> HoverGateReading {
        let n = Double(readings.count)
        let first = readings[0]
        return HoverGateReading(
            label: first.label,
            cursorInside: first.cursorInside,
            gated: first.gated,
            rows: first.rows,
            mountMS: readings.map(\.mountMS).reduce(0, +) / n,
            frameP50: readings.map(\.frameP50).reduce(0, +) / n,
            frameP95: readings.map(\.frameP95).reduce(0, +) / n,
            frameMax: readings.map(\.frameMax).max() ?? 0,
            overBudget: readings.map(\.overBudget).reduce(0, +) / n,
            hoverForwarded: readings.map(\.hoverForwarded).reduce(0, +) / readings.count,
            hoverSuppressed: readings.map(\.hoverSuppressed).reduce(0, +) / readings.count,
            viewsMin: readings.map(\.viewsMin).min() ?? 0,
            viewsMax: readings.map(\.viewsMax).max() ?? 0,
            viewsEnd: readings.map(\.viewsEnd).max() ?? 0,
            hitP50: readings.map(\.hitP50).reduce(0, +) / n)
    }
}

/// 一个视图的四臂（光标在内 / 在外 × 闸门开 / 关）。
struct HoverGateArm: Equatable {
    let cursorInside: Bool
    let gated: Bool
    var key: String { "\(cursorInside ? "in" : "out")-\(gated ? "on" : "off")" }

    /// 两遍：正序一遍、逆序一遍（抵消机器温度漂移），共 8 次建窗。
    static let plan: [HoverGateArm] = {
        let forward = [HoverGateArm(cursorInside: false, gated: false),
                       HoverGateArm(cursorInside: true, gated: false),
                       HoverGateArm(cursorInside: true, gated: true),
                       HoverGateArm(cursorInside: false, gated: true)]
        return forward + forward.reversed()
    }()
}

/// 四臂共用的断言。
@MainActor
func assertHoverGateContract(_ readings: [String: HoverGateReading],
                             view: String,
                             file: StaticString = #filePath,
                             line: UInt = #line) throws {
    let outOff = try XCTUnwrap(readings["out-off"])
    let inOff = try XCTUnwrap(readings["in-off"])
    let inOn = try XCTUnwrap(readings["in-on"])
    let outOn = try XCTUnwrap(readings["out-on"])
    for r in [outOff, inOff, inOn, outOn] {
        print("[hover-gate-avg] \(view) \(r.oneLine)")
    }

    // ① **自证**：合成光标必须真的点亮 hover。这一条不成立的话，下面所有
    //    「滚动时 hover 是 0」都是假 0（谎报的光标没被 AppKit 采纳），整轮作废。
    XCTAssertGreaterThan(inOff.hoverForwarded, 20,
                         "\(view)：光标在列表中央 + 闸门关，200 步滚动必须产生大量 hover 转发；"
                         + "读到 0 说明合成光标没生效，这一轮读数不算数",
                         file: file, line: line)
    // ② 光标在外时本来就不该有 hover —— 这是「以前的探针为什么量不到这笔账」。
    XCTAssertEqual(outOff.hoverForwarded, 0,
                   "\(view)：光标在窗外不该有任何 hover", file: file, line: line)

    // ③ 闸门开：滚动期间只剩「进滚动的那一下把亮着的行灭掉」。
    //    那一下是**必须**的（不灭掉的话，滚动全程会有一行僵在亮态），
    //    每个挂了 `hoverGated` 的元件各一次，所以上限取 2 而不是 0：
    //    一行上可能同时有行级 hover 与 `hoverBackground` 两个门控点。
    //    真正的判据是「滚动中不再有 enter」——`ScrollHoverGateBehaviourTests`
    //    用逐步断言（每一步都没有行亮着）把它钉得更死。
    XCTAssertLessThanOrEqual(inOn.hoverForwarded, 2,
                             "\(view)：闸门开时滚动期间只该剩「灭掉当前行」那一两次转发，"
                             + "实测 \(inOn.hoverForwarded)（同轮闸门关 \(inOff.hoverForwarded)）",
                             file: file, line: line)
    XCTAssertLessThan(inOn.hoverForwarded * 8, inOff.hoverForwarded,
                      "\(view)：闸门至少要把 hover 转发压到改前的 1/8 以下 —— "
                      + "改前 \(inOff.hoverForwarded) → 改后 \(inOn.hoverForwarded)",
                      file: file, line: line)
    XCTAssertGreaterThan(inOn.hoverSuppressed, 0,
                         "\(view)：闸门开时必须真的吃掉了 hover（否则是没滚 / 没光标）",
                         file: file, line: line)

    // ④ 相对判据（同轮）：闸门开之后，「光标在列表上」这一档必须真的变便宜。
    let ratioOff = inOff.frameP50 / max(outOff.frameP50, 1e-9)
    let ratioOn = inOn.frameP50 / max(outOn.frameP50, 1e-9)
    print(String(format: """
        [hover-gate-ratio] %@ 光标在内 p50 %.3f → %.3fms（%.0f%%）；\
        in/out 比值 闸门关 %.2f× → 闸门开 %.2f×；超预算 %.1f%% → %.1f%%；\
        NSView 波动 %d → %d
        """, view, inOff.frameP50, inOn.frameP50,
        (inOn.frameP50 / max(inOff.frameP50, 1e-9) - 1) * 100,
        ratioOff, ratioOn, inOff.overBudget, inOn.overBudget,
        inOff.viewsMax - inOff.viewsMin, inOn.viewsMax - inOn.viewsMin))

    // 时间判据**有前提**：这一轮 hover 那笔账得先显出来。
    //
    // 全量里踩到过：SFTP 那一档单跑时 in/out 是 1.61×（改前 4.474ms），
    // 整套跑时变成 1.01×（改前 2.815ms）—— hover 的开销根本没冒头，
    // 「改后必须更便宜」于是在噪声里翻面（2.995 vs 2.815）。三处里
    // 只有 SFTP 会这样：它的行里只有一个纯颜色切换的 `hoverBackground`，
    // 本来就便宜（单跑也只有 -5%），机器一忙就淹没。
    //
    // 所以先看「改前 in 比 out 贵了多少」，贵出 20% 以上才比时间；
    // 否则这一轮没有可比的东西，只留结构判据（那几条对机器负载免疫）。
    let hoverCostOff = inOff.frameP50 - outOff.frameP50
    if hoverCostOff > outOff.frameP50 * 0.2 {
        XCTAssertLessThan(inOn.frameP50, inOff.frameP50 * 0.97,
                          "\(view)：闸门开之后「光标在列表上」的单帧 p50 必须真的降下来 —— "
                          + String(format: "改前 %.3fms → 改后 %.3fms",
                                   inOff.frameP50, inOn.frameP50),
                          file: file, line: line)
    } else {
        print(String(format: "[hover-gate-ratio] %@ 这一轮 hover 的账没冒头（改前 in/out %.2f×），"
                     + "只留结构判据", view, ratioOff))
    }

    // ⑤ 「活行被建了又拆」的直接判据：滚动期间平台视图数的波动不能比改前大。
    XCTAssertLessThanOrEqual(inOn.viewsMax - inOn.viewsMin, inOff.viewsMax - inOff.viewsMin,
                             "\(view)：闸门开之后滚动期间的 NSView 波动不该变大 —— "
                             + "改前 \(inOff.viewsMin)..\(inOff.viewsMax) → "
                             + "改后 \(inOn.viewsMin)..\(inOn.viewsMax)",
                             file: file, line: line)

    // ⑥ 回归绊线（**不是目标**）：闸门开之后 in/out 比值不该再涨回去。
    //    目标本来定在 1.2×，实测三处都到不了（1.37 / 1.53 / 2.56）——
    //    剩下的那一截**不在我们这一层**：AppKit 每帧仍要为「光标在窗内」重算
    //    整窗的 `NSTrackingArea` 并把 enter / exit 派进 SwiftUI 的 hosting view，
    //    只是我们不再往下转发。要动它得把每行一个 `.onHover` 换成整表一个
    //    tracking area + 按行高算命中行（与点击层 / 拖放层同一套算术），
    //    那是另一轮的事。绊线取 3.0：够松，不会因机器负载假红；够紧，
    //    形态一退回（比如某处 `hoverGated` 被改回 `.onHover`）就会红。
    XCTAssertLessThan(ratioOn, 3.0,
                      "\(view)：闸门开后 in/out 比值 " + String(format: "%.2f×", ratioOn)
                      + " 越过绊线（同轮闸门关 " + String(format: "%.2f×", ratioOff) + "）",
                      file: file, line: line)
}

// MARK: - 欢迎页服务器列表

@MainActor
final class WelcomeServerListHoverGateTests: XCTestCase {

    private let rig = ScrollHoverProbeRig()
    private static let size = NSSize(width: 980, height: 640)
    /// 列表列在左侧（右侧是选中后滑入的 `HostDetailPanel`），所以光标按在左 1/4 处。
    private static let cursor = NSPoint(x: size.width * 0.25, y: size.height * 0.5)
    private static let rows = 2000
    private static let groups = 60

    func testHoverDuringScrollIsGated() async throws {
        defer {
            ScrollHoverGate.isEnabledByDefault = true
            rig.closeAllWindows()
        }
        var results: [String: [HoverGateReading]] = [:]
        for arm in HoverGateArm.plan {
            ScrollHoverGate.isEnabledByDefault = arm.gated
            let profiles = WelcomeServerListCostTests.makeProfiles(count: Self.rows,
                                                                  groups: Self.groups)
            let fixture = try rig.mount(
                ProbeServerListHost(profiles: profiles, groups: Self.groups),
                size: Self.size,
                cursor: arm.cursorInside ? Self.cursor : nil)
            let reading = try await rig.measure(fixture, label: "welcome/\(arm.key)",
                                                rows: Self.rows,
                                                cursorInside: arm.cursorInside, gated: arm.gated)
            results[arm.key, default: []].append(reading)
            await rig.closeWindowsAndSettle()
        }
        try assertHoverGateContract(results.mapValues(ScrollHoverProbeRig.average),
                                    view: "欢迎页服务器列表 \(Self.rows) 台")
    }
}

/// 产线 `ServerList` 的最小宿主（只补它要的两个 `@Binding`）。
private struct ProbeServerListHost: View {
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
                   groupColorHexes: WelcomeServerListCostTests.groupColorHexes(groups))
    }
}

// MARK: - SFTP 文件表

@MainActor
final class SFTPFileTableHoverGateTests: XCTestCase {

    private let rig = ScrollHoverProbeRig()
    private static let size = NSSize(width: 1200, height: 780)
    private static let cursor = NSPoint(x: size.width * 0.4, y: size.height * 0.5)

    func testHoverDuringScrollIsGated() async throws {
        defer {
            ScrollHoverGate.isEnabledByDefault = true
            rig.closeAllWindows()
        }
        let rows = FileBrowserProbeFixture.extreme
        var results: [String: [HoverGateReading]] = [:]
        for arm in HoverGateArm.plan {
            ScrollHoverGate.isEnabledByDefault = arm.gated
            let model = await FileBrowserProbeFixture.model(rows)
            let fixture = try rig.mount(
                SFTPBrowserView(model: model, server: ServerProfile(), openWorkspace: {}),
                size: Self.size,
                cursor: arm.cursorInside ? Self.cursor : nil)
            let reading = try await rig.measure(fixture, label: "sftp/\(arm.key)", rows: rows,
                                                cursorInside: arm.cursorInside, gated: arm.gated)
            results[arm.key, default: []].append(reading)
            await rig.closeWindowsAndSettle()
        }
        try assertHoverGateContract(results.mapValues(ScrollHoverProbeRig.average),
                                    view: "SFTP 文件表 \(rows) 条")
    }
}

// MARK: - 全局端口转发

@MainActor
final class GlobalForwardingHoverGateTests: XCTestCase {

    private let rig = ScrollHoverProbeRig()
    private static let size = NSSize(width: 900, height: 700)
    private static let cursor = NSPoint(x: size.width * 0.4, y: size.height * 0.45)

    func testHoverDuringScrollIsGated() async throws {
        defer {
            ScrollHoverGate.isEnabledByDefault = true
            rig.closeAllWindows()
        }
        // 见 `GlobalForwardingListCostTests`：**所有 SwiftData 容器必须在挂第一个
        // 窗口之前建好** —— 上一档的 `@Query` 观察者还没散时给下一档存盘会
        // 在通知回调里把测试宿主打没。
        let seeds = try HoverGateArm.plan.map { _ in
            try ForwardingProbeFixture.seed(hosts: 50, rulesPerHost: 20)
        }
        var results: [String: [HoverGateReading]] = [:]
        for (index, arm) in HoverGateArm.plan.enumerated() {
            ScrollHoverGate.isEnabledByDefault = arm.gated
            let seed = seeds[index]
            let root = AnyView(
                GlobalForwardingWindowView()
                    .environment(seed.coordinator)
                    .environment(GlobalForwardingModel())
                    .environment(HostKeyChallengeRelay())
                    .modelContainer(seed.container))
            let fixture = try rig.mount(root, size: Self.size,
                                        cursor: arm.cursorInside ? Self.cursor : nil)
            let reading = try await rig.measure(fixture, label: "gfwd/\(arm.key)",
                                                rows: 1000,
                                                cursorInside: arm.cursorInside, gated: arm.gated)
            results[arm.key, default: []].append(reading)
            await rig.closeWindowsAndSettle()
        }
        try assertHoverGateContract(results.mapValues(ScrollHoverProbeRig.average),
                                    view: "全局端口转发 1000 行")
    }
}

// MARK: - 闸门行为（合成列表，判据是行为不是时间）

/// 每一行把 enter / exit 记在这里 —— 谁在亮、一共发生了几次。
@MainActor
final class HoverLedger {
    private(set) var hovering: Set<Int> = []
    private(set) var events = 0
    /// 出问题时用来看「到底是谁在第几步被转发了」。测试循环负责推进 `step`。
    var step = 0
    private(set) var trace: [String] = []

    func record(index: Int, hovering isHovering: Bool) {
        events += 1
        if trace.count < 40 { trace.append("step\(step):row\(index)=\(isHovering)") }
        if isHovering { hovering.insert(index) } else { hovering.remove(index) }
    }

    func reset() {
        events = 0
        trace.removeAll()
    }
}

private struct ProbeHoverRow: View {
    let index: Int
    let ledger: HoverLedger
    @State private var hover = false

    var body: some View {
        Text("row-\(index)")
            .font(.system(size: 12))
            .frame(maxWidth: .infinity, alignment: .leading)
            .frame(height: 28)
            .background(hover ? Color.gray.opacity(0.25) : Color.clear)
            .contentShape(Rectangle())
            .hoverGated { hovering in
                hover = hovering
                ledger.record(index: index, hovering: hovering)
            }
    }
}

private struct ProbeHoverList: View {
    let ledger: HoverLedger
    let rows: Int

    var body: some View {
        ScrollView {
            LazyVStack(spacing: 0) {
                ForEach(0..<rows, id: \.self) { ProbeHoverRow(index: $0, ledger: ledger) }
            }
            .scrollHoverGate()
        }
        .background(Color.white)
    }
}

@MainActor
final class ScrollHoverGateBehaviourTests: XCTestCase {

    private let rig = ScrollHoverProbeRig()
    private static let size = NSSize(width: 420, height: 420)
    private static let cursor = NSPoint(x: 200, y: 200)

    /// 滚动中一次都不转发；停下 200ms 之后光标所在的那一行必须重新亮起来。
    func testGateSuspendsHoverAndRestoresAfterQuiet() async throws {
        defer {
            ScrollHoverGate.isEnabledByDefault = true
            rig.closeAllWindows()
        }
        ScrollHoverGate.isEnabledByDefault = true
        let ledger = HoverLedger()
        let fixture = try rig.mount(ProbeHoverList(ledger: ledger, rows: 2000),
                                    size: Self.size, cursor: Self.cursor)
        let scroll = fixture.scroll
        let host = fixture.host
        func layout() { host.layoutSubtreeIfNeeded(); host.displayIfNeeded() }
        func scrollTo(_ y: CGFloat) {
            scroll.contentView.scroll(to: NSPoint(x: 0, y: max(0, y)))
            scroll.reflectScrolledClipView(scroll.contentView)
        }

        // 先静置，让光标底下那一行亮起来（证明夹具真的会 hover）。
        layout()
        try await Task.sleep(for: .milliseconds(400))
        layout()
        try await Task.sleep(for: .milliseconds(200))
        XCTAssertEqual(ledger.hovering.count, 1,
                       "静止时合成光标底下必须正好有一行是 hover 的，实测 \(ledger.hovering)")
        let restingRow = try XCTUnwrap(ledger.hovering.first)

        // 滚 200 步：期间不该有任何一行亮着，转发次数只该有「进滚动时灭掉一行」那一次。
        ledger.reset()
        HoverGateStats.reset()
        for step in 1...200 {
            ledger.step = step
            scrollTo(CGFloat(step) * 6)
            layout()
            try await Task.sleep(for: .milliseconds(8))
            XCTAssertTrue(ledger.hovering.isEmpty,
                          "滚动第 \(step) 步还有行亮着：\(ledger.hovering)")
        }
        let duringScroll = ledger.events
        let suppressed = HoverGateStats.suppressed
        print("[hover-gate-behaviour] 滚动 200 步：转发 \(duringScroll) 次、抑制 \(suppressed) 次；"
              + "静止行 \(restingRow)；轨迹 \(ledger.trace)")
        XCTAssertLessThanOrEqual(duringScroll, 1,
                                 "滚动期间最多只该有「进滚动时把那一行灭掉」这一次转发，"
                                 + "实测 \(duringScroll)")
        XCTAssertGreaterThan(suppressed, 0, "滚动期间必须真的有 hover 被吃掉（否则夹具没在滚）")

        // 停 200ms（> 150ms 静默期）之后，光标所在行必须恢复。
        try await Task.sleep(for: .milliseconds(200))
        layout()
        try await Task.sleep(for: .milliseconds(50))
        layout()
        XCTAssertEqual(ledger.hovering.count, 1,
                       "停下之后光标所在行必须恢复 hover，实测 \(ledger.hovering)")
        await rig.closeWindowsAndSettle()
    }

    /// 闸门关掉时同一份夹具必须**大量**转发 —— 这是上一条断言的对照，
    /// 保证「滚动期间 0 次」不是因为夹具根本不 hover。
    func testUngatedControlArmDoesHoverDuringScroll() async throws {
        defer {
            ScrollHoverGate.isEnabledByDefault = true
            rig.closeAllWindows()
        }
        ScrollHoverGate.isEnabledByDefault = false
        let ledger = HoverLedger()
        let fixture = try rig.mount(ProbeHoverList(ledger: ledger, rows: 2000),
                                    size: Self.size, cursor: Self.cursor)
        let scroll = fixture.scroll
        let host = fixture.host
        func layout() { host.layoutSubtreeIfNeeded(); host.displayIfNeeded() }
        layout()
        try await Task.sleep(for: .milliseconds(400))
        ledger.reset()
        for step in 1...200 {
            scroll.contentView.scroll(to: NSPoint(x: 0, y: CGFloat(step) * 6))
            scroll.reflectScrolledClipView(scroll.contentView)
            layout()
            try await Task.sleep(for: .milliseconds(8))
        }
        print("[hover-gate-behaviour] 闸门关：滚动 200 步转发 \(ledger.events) 次")
        XCTAssertGreaterThan(ledger.events, 20,
                             "闸门关掉时滚动必须产生大量 hover 转发（每行经过指针一进一出）；"
                             + "实测 \(ledger.events) —— 太少说明合成光标没生效")
        await rig.closeWindowsAndSettle()
    }
}
