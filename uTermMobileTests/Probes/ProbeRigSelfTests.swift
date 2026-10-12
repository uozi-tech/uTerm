import SwiftUI
import UIKit
import XCTest

/// `MobileProbeRig` / `MobileProbeWindow` 的自证 —— **也不评判任何产品视图**。
///
/// `ProbeSmokeTests` 证的是「链路通不通」；这个类证的是「尺准不准」：
///
/// 1. **三档 A/B**：同一份 fixture 在 `.offScreen` / `.transparentOnScreen` /
///    `.visibleOnScreen` 三档各量一遍。结构读数必须完全一致，像素读数按实测记账。
///    桌面那份（`ProbeWindow` 顶部）的结论是「离屏会让计时读数崩塌」，
///    iOS 的结论要靠这条用例给，不能照抄。
/// 2. **滚动驱动都真的能推动视图**：`setContentOffset` / `scrollRectToVisible` /
///    `ScrollViewReader.scrollTo` / 按刷新率节拍的「模拟手指」四条路。
///    这条回答的是「`.transparentOnScreen` 档下还能不能驱动滚动」。
/// 3. **反向自证**：故意做一档滚不动的 fixture，确认 `scrollable == 0` 会**判红**
///    而不是安安静静给出一串漂亮的静止读数。这是整套夹具最重要的一条 ——
///    一把量不出问题的尺比没有尺更糟。
/// 4. **拆窗真的拆干净**：`closeAll()` 之后探针窗口归零，被压过的宿主窗口层级复原。
@MainActor
final class ProbeRigSelfTests: XCTestCase {

    private static let size = CGSize(width: 390, height: 700)
    /// 与 `ProbeSmokeTests.rowHeight` 同值。写字面量而不是引用它：
    /// 那边是 `@MainActor` 类的静态成员，静态属性的初始化式跑在 actor 之外。
    private static let rowHeight: CGFloat = 22

    // MARK: - ① 三档 A/B

    /// 三档各量一遍，读数进日志。**闸门只守结构判据**（`UIView` 数、可滚动余量、
    /// 内容高度三档必须一致）；毫秒与墨迹只打印，供 README 那张表复量。
    func testPlacementABIsRecorded() async throws {
        defer { MobileProbeWindow.closeAll() }
        XCTAssertNil(MobileProbeWindow.forcedPlacement,
                     "这条用例要自己控摆法，跑它的时候别开 UTERM_MOBILE_PROBE_PLACEMENT")

        var byPlacement: [MobileProbeWindow.Placement:
                            (MobileProbeRig.Heartbeat,
                             MobileProbeRig.ScrollReading,
                             MobileProbeRig.Snapshot)] = [:]

        for placement in MobileProbeWindow.Placement.allCases {
            let rig = MobileProbeRig(label: "ab-\(placement.short)",
                                     size: Self.size,
                                     placement: placement)
            rig.mount(ProbeSmokeTests.rowList(1000))
            let beat = try await rig.heartbeat(seconds: 1)
            let scroll = try await rig.measureScroll(steps: 60)
            let shot = await rig.snapshot(hitSamples: 30)
            rig.report(scroll, shot, beat)
            attachProbePNG(shot.png, name: "ab-\(placement.short)")
            // 记账：系统给这一档的滚动视图挂了多少滚动边缘效果（iOS 27 起只挂给可见窗口；
            // `views` 不数它们，见 `UIView.recursiveViewCount`）。
            print("[ab-\(placement.short)-chrome] scroll-edge-effect views="
                  + "\(rig.hostView?.scrollEdgeEffectViewCount() ?? -1)")
            byPlacement[placement] = (beat, scroll, shot)
            await rig.close()
        }

        let offScreen = try XCTUnwrap(byPlacement[.offScreen])
        let transparent = try XCTUnwrap(byPlacement[.transparentOnScreen])
        let visible = try XCTUnwrap(byPlacement[.visibleOnScreen])

        // 结构判据：三档必须给出同一棵树、同一份几何。做不到就说明「摆法」偷偷
        // 改变了被测对象，那三档就不能互相当对照组了。
        for (name, reading) in [("transparent", transparent), ("visible", visible)] {
            XCTAssertEqual(reading.2.views, offScreen.2.views,
                           "\(name) 档的 UIView 数与 offScreen 不一致："
                           + "\(reading.2.views) vs \(offScreen.2.views)")
            XCTAssertEqual(reading.1.contentHeight, offScreen.1.contentHeight, accuracy: 1,
                           "\(name) 档的内容高度与 offScreen 不一致")
            XCTAssertEqual(reading.1.scrollable, offScreen.1.scrollable, accuracy: 1,
                           "\(name) 档的可滚动余量与 offScreen 不一致")
        }
        // 三档都得真的滚起来了。
        for (name, reading) in [("offscreen", offScreen), ("transparent", transparent),
                                ("visible", visible)] {
            XCTAssertGreaterThan(reading.1.travelled, reading.1.amplitude,
                                 "\(name) 档没滚动：travelled=\(reading.1.travelled)")
        }
        // 像素：这条是**记账**不是假设 —— 哪档取得到像素以这里的输出为准。
        print(String(format: "[ab-pixels] offscreen ink=%.4f(avail=%@) "
                     + "transparent ink=%.4f(avail=%@) visible ink=%.4f(avail=%@)",
                     offScreen.2.ink, offScreen.2.pixelsAvailable ? "yes" : "no",
                     transparent.2.ink, transparent.2.pixelsAvailable ? "yes" : "no",
                     visible.2.ink, visible.2.pixelsAvailable ? "yes" : "no"))
        // 只硬断言一条：**默认档（计时探针档）必须取得到像素**。
        // 取不到的话「像素判据」这把尺在默认档上就是废的，探针会集体假绿。
        XCTAssertTrue(transparent.2.pixelsAvailable,
                      "`.transparentOnScreen`（默认档）取不到像素，ink=\(transparent.2.ink)")
        print(String(format: "[ab-timing] offscreen p50=%.3f ticks=%.2f | "
                     + "transparent p50=%.3f ticks=%.2f | visible p50=%.3f ticks=%.2f",
                     offScreen.1.p50, offScreen.0.displayRatio,
                     transparent.1.p50, transparent.0.displayRatio,
                     visible.1.p50, visible.0.displayRatio))
    }

    // MARK: - ② 四条滚动驱动

    /// 四条驱动都得真的把 `contentOffset` 推动。
    ///
    /// 这条回答的是「`.transparentOnScreen`（alpha=0）档下滚动还灵不灵」——
    /// 灵，因为我们推的是 `contentOffset` 属性，不走触摸路径。
    func testScrollDriversAllMove() async throws {
        defer { MobileProbeWindow.closeAll() }

        // 前三条：contentOffset / scrollRectToVisible / fingerDrag。
        for driver in MobileProbeRig.ScrollDriver.allCases {
            let rig = MobileProbeRig(label: "driver-\(driver.short)", size: Self.size)
            rig.mount(ProbeSmokeTests.rowList(1000))
            let reading = try await rig.measureScroll(steps: 60, driver: driver)
            rig.report(reading, nil)
            XCTAssertGreaterThan(reading.travelled, reading.amplitude,
                                 "\(driver.short) 驱动没把视图推动："
                                 + "travelled=\(reading.travelled) amp=\(reading.amplitude)")
            XCTAssertFalse(reading.frames.isEmpty, "\(driver.short) 驱动一帧都没记到")
            if driver == .fingerDrag {
                // 「模拟手指」挂在 CADisplayLink 上，拍数得接近要求的步数 ——
                // 差太多说明 link 停摆（没加 `.common` mode 那个坑）。
                XCTAssertGreaterThan(Double(reading.ticks) / Double(reading.idealTicks), 0.5,
                                     "fingerDrag 只收到 \(reading.ticks)/\(reading.idealTicks) 拍，"
                                     + "CADisplayLink 很可能停摆了")
            }
            await rig.close()
        }

        // 第四条：SwiftUI 自己的 `ScrollViewReader`。
        let anchor = ProbeScrollAnchor()
        let rig = MobileProbeRig(label: "driver-scrollviewreader", size: Self.size)
        rig.mount(ProbeSmokeTests.rowList(1000, anchor: anchor))
        try rig.requireScrollable()
        try await Task.sleep(for: .milliseconds(120))
        XCTAssertTrue(anchor.isBound, "ProbeScrollReaderBox 没把 ScrollViewProxy 交出来")

        let before = try rig.requireScrollView().contentOffset.y
        rig.scrollViaReader(anchor, to: 600)
        try await Task.sleep(for: .milliseconds(200))
        rig.layout()
        let after = try rig.requireScrollView().contentOffset.y
        print(String(format: "[driver-scrollviewreader] offset %.0f → %.0f (target row 600 ≈ %.0f)",
                     before, after, CGFloat(600) * Self.rowHeight))
        XCTAssertGreaterThan(after, before + Self.size.height,
                             "ScrollViewReader.scrollTo 在探针窗口里没生效："
                             + "offset \(before) → \(after)")
        await rig.close()
    }

    // MARK: - ③ 反向自证：滚不动就得判红

    /// 故意做一档**滚不动**的 fixture（3 行，内容远低于视口），确认夹具当场判红。
    ///
    /// 为什么这条最重要：一个滚不动的档，它的单帧 p50、拍数、hitTest 全都是
    /// 「静止画面」的读数 —— 又快又稳又好看，但什么都没测到。要是夹具不拦，
    /// 后面每一份「A（保持）」的判定都可能是这么来的。
    func testNonScrollableFixtureIsRejected() async throws {
        defer { MobileProbeWindow.closeAll() }

        let rig = MobileProbeRig(label: "negative-3rows", size: Self.size)
        rig.mount(ProbeSmokeTests.rowList(3))
        let scroll = try rig.requireScrollView()
        rig.layout()
        let slack = scroll.contentSize.height - scroll.bounds.height
        print(String(format: "[negative] content=%.0f viewport=%.0f scrollable=%.0f",
                     scroll.contentSize.height, scroll.bounds.height, slack))
        XCTAssertLessThanOrEqual(slack, 0.5, "3 行 × \(Self.rowHeight)pt 不该超过一屏")

        // 闸门一：`requireScrollable()` 抛。
        XCTAssertThrowsError(try rig.requireScrollable()) { error in
            guard case MobileProbeRig.ProbeRigError.notScrollable = error else {
                return XCTFail("期望 .notScrollable，实际 \(error)")
            }
            print("[negative-throw] \(error)")
        }

        // 闸门二：`measureScroll()` 自己也要抛 —— 探针作者忘了先 require 也拦得住。
        do {
            let reading = try await rig.measureScroll(steps: 10)
            XCTFail("滚不动的 fixture 竟然量出了读数："
                    + "p50=\(reading.p50)ms scrollable=\(reading.scrollable)")
        } catch let error as MobileProbeRig.ProbeRigError {
            guard case .notScrollable = error else { return XCTFail("期望 .notScrollable，实际 \(error)") }
            print("[negative-throw-measure] \(error)")
        }

        // 对照组：同一个 rig 换成 2000 行就必须过 —— 证明上面判红是因为「滚不动」，
        // 不是因为夹具本身坏了。
        await rig.close()
        let ok = MobileProbeRig(label: "negative-control-2000", size: Self.size)
        ok.mount(ProbeSmokeTests.rowList(2000))
        let slackOK = try ok.requireScrollable()
        XCTAssertGreaterThan(slackOK, 0)
        let reading = try await ok.measureScroll(steps: 20)
        XCTAssertGreaterThan(reading.travelled, 0)
        print(String(format: "[negative-control] scrollable=%.0f travelled=%.0f", slackOK,
                     reading.travelled))
        await ok.close()
    }

    /// 没 mount 就量 → 抛 `.notMounted`；视图里没有滚动视图 → 抛 `.noScrollView`。
    /// 两条都是「探针写错了」的早期判红，不是产品问题。
    func testMissingPreconditionsAreRejected() async throws {
        defer { MobileProbeWindow.closeAll() }

        let bare = MobileProbeRig(label: "no-mount", size: Self.size)
        XCTAssertThrowsError(try bare.requireScrollView()) { error in
            guard case MobileProbeRig.ProbeRigError.notMounted = error else {
                return XCTFail("期望 .notMounted，实际 \(error)")
            }
        }

        let noScroll = MobileProbeRig(label: "no-scrollview", size: Self.size)
        noScroll.mount(Text("一个不滚的静态视图").frame(maxWidth: .infinity, maxHeight: .infinity))
        XCTAssertThrowsError(try noScroll.requireScrollView()) { error in
            guard case MobileProbeRig.ProbeRigError.noScrollView = error else {
                return XCTFail("期望 .noScrollView，实际 \(error)")
            }
            print("[negative-noscroll] \(error)")
        }
        await noScroll.close()
    }

    // MARK: - ④ OCR

    /// `VisionTextProbe` 的 iOS 版真的认得出行文本。
    ///
    /// 桌面那份是探针判读截图的主力；移动端默认**不开**（模拟器上 Vision 走宿主 Mac 的
    /// CPU，首次请求要好几秒），所以要单独有一条用例证明这条路是通的，
    /// 否则等到某个屏幕探针第一次 `ocr: true` 才发现移植没生效。
    ///
    /// **识别器超时不判红**：超时不是被测视图的问题（桌面那份顶部有整段教训）。
    /// 超时就退回墨迹判据，与 `VisionTextProbe.lines` 的契约一致。
    func testVisionTextProbeReadsRowLabels() async throws {
        defer { MobileProbeWindow.closeAll() }

        let rig = MobileProbeRig(label: "ocr", size: Self.size)
        rig.mount(ProbeSmokeTests.rowList(2000))
        try rig.requireScrollable()
        let targetRow = 300
        rig.scrollTo(CGFloat(targetRow) * Self.rowHeight)
        rig.layout()
        try await Task.sleep(for: .milliseconds(250))

        let started = Date()
        let shot = await rig.snapshot(ocr: true, hitSamples: 10)
        let elapsed = Date().timeIntervalSince(started)
        attachProbePNG(shot.png, name: "ocr-rows")

        guard let text = shot.ocrText else {
            // 兜底路径也要有断言，否则「识别器罢工」会变成一条什么都没证的绿。
            XCTAssertGreaterThan(shot.ink, 0.005,
                                 "OCR 超时且截图是空壳 —— 这不是识别器的问题")
            print(String(format: "[ocr] 识别器超时（%.1fs），退回墨迹判据 ink=%.4f", elapsed, shot.ink))
            return
        }
        let lines = text.split(separator: "\n").map(String.init)
        // 大小写不敏感：等宽小写 `row_` 常被 Vision 认成 `rOW_`（实测）。
        let rowLines = lines.filter { $0.lowercased().contains("row") }
        print(String(format: "[ocr] %.1fs lines=%d row-like=%d head=%@",
                     elapsed, lines.count, rowLines.count,
                     lines.prefix(3).joined(separator: " | ")))
        XCTAssertGreaterThan(lines.count, 5,
                             "一屏 \(Int(Self.size.height / Self.rowHeight)) 行只认出 \(lines.count) 行：\(text)")
        XCTAssertGreaterThan(rowLines.count, 0,
                             "一行 `row_XXXX` 都没认出来，识别到的是：\(lines.prefix(5))")
        // 截图必须是「滚到 targetRow 的那一屏」，不是 snapshot 里 hitTest 扫到的末尾那屏。
        // 认出来的行号落在 [targetRow, targetRow + 一屏行数] 里才算对得上号。
        let numbers = rowLines.compactMap { Int($0.filter(\.isNumber)) }
        let visibleRows = Int(Self.size.height / Self.rowHeight) + 2
        XCTAssertTrue(numbers.contains { $0 >= targetRow && $0 <= targetRow + visibleRows },
                      "截图不是第 \(targetRow) 行那一屏 —— 认出的行号是 \(numbers.prefix(6))")
        await rig.close()
    }

    // MARK: - ⑤ 拆窗

    /// `closeAll()` 之后：探针窗口归零，被 `isolateHost` 压过的宿主窗口层级复原。
    ///
    /// 拆不干净的后果是下一档的 footprint 带着上一档的账，而 footprint 恰恰是
    /// 「换懒栈到底省没省内存」这类结论的唯一依据。
    ///
    /// 断言口径是「**mount 前量到的值**，挂完再拆之后必须一模一样」——
    /// 不写死 `.normal`、也不拿 `hostLevel` 反推。这条用例本身曾经是跨用例污染的
    /// 受害者：`MobileFixturesTests` 逐扇 `close(_:)` 拆窗、从不复原宿主，
    /// 于是它量到的「mount 前」是上一条用例留下的 -100，而 `closeAll()` 把窗口
    /// 恢复成了真正的原值 0，两边打架（见 README「夹具跨用例契约」）。
    func testCloseAllTearsDownAndRestoresHost() async throws {
        let scene = try XCTUnwrap(MobileProbeWindow.activeScene(), "测试宿主必须有一个前台 scene")
        let hostWindows = scene.windows
        XCTAssertFalse(hostWindows.isEmpty, "宿主 uTermMobile.app 必须已经建好窗口")
        // mount 前的层级 —— 前面每条用例都复原过，这里量到的必然是进程原值。
        let before = hostWindows.map(\.windowLevel)
        for host in hostWindows {
            XCTAssertNotEqual(host.windowLevel, MobileProbeWindow.hostLevel,
                              "进这条用例时宿主不该还压着 —— 说明前面某条用例漏了 closeAll()")
        }

        let rig = MobileProbeRig(label: "teardown", size: Self.size)
        rig.mount(ProbeSmokeTests.rowList(50))
        XCTAssertEqual(MobileProbeWindow.openWindowCount, 1)
        let window = try XCTUnwrap(rig.window)
        XCTAssertGreaterThan(window.windowLevel.rawValue, MobileProbeWindow.hostLevel.rawValue,
                             "探针窗口必须压在宿主之上")
        for (host, level) in zip(hostWindows, before) {
            XCTAssertEqual(host.windowLevel, MobileProbeWindow.hostLevel,
                           "isolateHost 应该把宿主窗口压到 hostLevel")
            XCTAssertEqual(MobileProbeWindow.originalHostLevel(of: host), level,
                           "记下来的「原值」必须是 mount 前那个值，不是被谁压过的残值")
        }

        MobileProbeWindow.closeAll()
        XCTAssertEqual(MobileProbeWindow.openWindowCount, 0, "closeAll 之后不该还有探针窗口")
        XCTAssertNil(window.rootViewController, "拆窗必须显式置空 rootViewController")
        for (host, level) in zip(hostWindows, before) {
            XCTAssertEqual(host.windowLevel, level, "宿主窗口的 windowLevel 必须复原")
        }
        print("[teardown] host-windows=\(hostWindows.count) "
              + "levels=\(before.map { $0.rawValue }) restored=yes")
    }

    /// 连跑两轮 isolate / close，宿主层级不漂移。
    ///
    /// 这是上一条用例的**根因守卫**，两条性质一起守：
    ///
    /// 1. **逐扇 `close(_:)` 也算一条合法退出路径**（`MobileProbeRig.close()`、
    ///    夹具自证用例走的就是它），拆掉最后一扇之后宿主必须已经抬回去 ——
    ///    老实现只有 `closeAll()` 负责复原，这一步会把宿主留在 -100。
    /// 2. **原值只记一次**：第二轮再压再拆，落点必须与第一轮一模一样。老实现每轮
    ///    重记一次「压之前的层级」，第一轮的残值 -100 会被第二轮当成原值，从此回不去。
    ///
    /// 所以两轮分别走两条退出路径：第 0 轮逐扇 `close(_:)`，第 1 轮 `closeAll()`。
    func testRepeatedIsolateCloseDoesNotDriftHostLevel() async throws {
        defer { MobileProbeWindow.closeAll() }
        let scene = try XCTUnwrap(MobileProbeWindow.activeScene(), "测试宿主必须有一个前台 scene")
        let hostWindows = scene.windows
        let original = hostWindows.map(\.windowLevel)

        var afterEachRound: [[UIWindow.Level]] = []
        for round in 0..<2 {
            let rig = MobileProbeRig(label: "drift-\(round)", size: Self.size)
            rig.mount(ProbeSmokeTests.rowList(30))
            for host in hostWindows {
                XCTAssertEqual(host.windowLevel, MobileProbeWindow.hostLevel,
                               "第 \(round) 轮：isolateHost 应该把宿主压下去")
            }
            if round == 0 {
                // 逐扇拆：拆掉最后一扇时也必须复原。
                MobileProbeWindow.close(try XCTUnwrap(rig.window))
            } else {
                MobileProbeWindow.closeAll()
            }
            XCTAssertEqual(MobileProbeWindow.openWindowCount, 0, "第 \(round) 轮：窗口该拆光了")
            afterEachRound.append(hostWindows.map(\.windowLevel))
        }

        XCTAssertEqual(afterEachRound[0], original, "第 1 轮（逐扇 close）拆完必须回到原值")
        XCTAssertEqual(afterEachRound[1], original, "第 2 轮（closeAll）必须回到同一个原值（不漂移）")
        print("[drift] original=\(original.map { $0.rawValue }) "
              + "round1=\(afterEachRound[0].map { $0.rawValue }) "
              + "round2=\(afterEachRound[1].map { $0.rawValue })")
    }
}
