import SwiftUI
import UIKit
import XCTest
@testable import uTermMobile

/// iOS 探针链路的自证用例 —— **这里不评判任何 uTermMobile 视图**。
///
/// 被测对象是夹具本身：`MobileProbeWindow` / `MobileProbeRig` / `DisplayLinkCounter` /
/// `ProbeMetrics` / `VisionTextProbe` 五件零件，在 `uTermMobile.app` 这个测试宿主里
/// 是不是真的能跑通「建窗 → 上屏 → 挂 SwiftUI → 滚 → 量 → 截图」这一整条链路。
/// 后面每个屏幕的评估任务直接抄这个类的形状，不必再验一遍地基。
///
/// 夹具刻意只用**纯 Text 行**（`ScrollView + LazyVStack + ForEach`）：
/// 没有 Button、没有 TextField，也就没有平台视图。于是「`UIView` 数不随行数涨」
/// 是一条**结构判据**而非性能判据 —— 它对机器负载免疫，可以当硬断言；
/// 绝对毫秒只打印（playbook §一）。
///
/// 隔离：`uTermMobileTests` 的 `SWIFT_DEFAULT_ACTOR_ISOLATION` 与 `uTermTests`
/// 对齐取 `nonisolated`（宿主 `uTermMobile` 是 `MainActor`），所以这里显式
/// `@MainActor`，且**不覆写 `tearDown()`**（父类那个是 `nonisolated`，
/// 覆写不能改隔离），改用每条用例开头 `defer { MobileProbeWindow.closeAll() }`。
@MainActor
final class ProbeSmokeTests: XCTestCase {

    // MARK: - 被测夹具

    /// 行高写死，几何判据（内容高度、滚到第几行）才算得准。
    static let rowHeight: CGFloat = 22
    /// 尺寸写死而不用屏幕尺寸：iPhone 与 iPad 的可视行数差三倍，
    /// 写死才能让同一份读数在两台模拟器之间可比。
    static let size = CGSize(width: 390, height: 700)

    /// 纯 `Text` 行的懒栈。`anchor` 非 nil 时外面包一层 `ScrollViewReader`，
    /// 用来验证 SwiftUI 自己的滚动 API 在探针窗口里也灵。
    @ViewBuilder
    static func rowList(_ rows: Int, anchor: ProbeScrollAnchor? = nil) -> some View {
        let list = ScrollView {
            LazyVStack(alignment: .leading, spacing: 0) {
                ForEach(0..<rows, id: \.self) { index in
                    Text(String(format: "row_%04d", index))
                        .font(.system(size: 13, weight: .regular, design: .monospaced))
                        .foregroundStyle(Color.black)
                        .frame(height: rowHeight, alignment: .leading)
                        .padding(.horizontal, 14)
                        .id(index)
                }
            }
        }
        .background(Color.white)

        if let anchor {
            ProbeScrollReaderBox(anchor: anchor) { list }
        } else {
            list
        }
    }

    // MARK: - 用例

    /// ① `@testable import uTermMobile` 真的引到了产品类型。
    ///
    /// 单独一条用例：它失败说明 `TEST_HOST` / `BUNDLE_LOADER` 接错了，
    /// 与下面那条量读数的用例是两码事，混在一起会让「链路没通」看着像「探针跑挂了」。
    func testHostSymbolsAreVisible() throws {
        // `MTab` 是 uTermMobile/Shell/MobileStore.swift 里的产品类型（主标签枚举）。
        // 挑它是因为它没有任何 SwiftData / CloudKit 依赖，构造它不会连带唤起容器。
        XCTAssertEqual(MTab.allCases.count, 5, "主标签共 5 个：主机/终端/文件/命令/设置")
        XCTAssertEqual(MTab.hosts.label, "主机")
        XCTAssertEqual(MTab(rawValue: "settings"), .settings)
        print("[probe-smoke-host] MTab.allCases = \(MTab.allCases.map(\.rawValue))")
    }

    /// ② 整条量测链路跑一遍，断言只用结构判据；绝对毫秒只打印。
    ///
    /// 改用 `MobileProbeRig` 之后这条用例只剩十几行 —— 这正是这套夹具存在的理由。
    /// 读数与旧版手写循环一致（同样是 3s 双心跳 + 200 步往返 + 3×100 次 hitTest）。
    func testProbeChainMeasuresLazyRowList() async throws {
        defer { MobileProbeWindow.closeAll() }

        func measure(rows: Int) async throws
            -> (beat: MobileProbeRig.Heartbeat,
                scroll: MobileProbeRig.ScrollReading,
                shot: MobileProbeRig.Snapshot) {
            let rig = MobileProbeRig(label: "smoke-\(rows)", size: Self.size)
            rig.mount(Self.rowList(rows))
            try rig.requireScrollable()
            try await rig.sweepLazyRows(amplitude: rig.scrollView.map {
                min(max(0, $0.contentSize.height - $0.bounds.height), $0.bounds.height * 3)
            } ?? 0)
            let beat = try await rig.heartbeat(seconds: 3)
            let scroll = try await rig.measureScroll(steps: 200, sweepFirst: false)
            let shot = await rig.snapshot()
            rig.report(scroll, shot, beat)
            await rig.close()
            return (beat, scroll, shot)
        }

        let small = try await measure(rows: 200)
        let large = try await measure(rows: 2000)

        // 懒栈真的懒：纯 Text 行不生成平台视图，UIView 数与行数无关。
        XCTAssertLessThanOrEqual(abs(large.shot.views - small.shot.views), 2,
                                 "纯 Text 的 LazyVStack 不该随行数长出 UIView："
                                 + "200 行 \(small.shot.views) vs 2000 行 \(large.shot.views)")
        // 夹具真的能滚 —— 没有滚动余量的话上面所有滚动读数都是假的。
        XCTAssertGreaterThan(small.scroll.scrollable, 0, "200 行也必须超过一屏")
        XCTAssertGreaterThan(large.scroll.scrollable, small.scroll.scrollable,
                             "2000 行的可滚动高度必须比 200 行大")
        // 驱动真的把视图推动了（不是「设了个属性但没生效」）。
        XCTAssertGreaterThan(large.scroll.travelled, large.scroll.amplitude,
                             "200 步往返的总里程必须超过一次单程")
        // 内容高度对得上行高 × 行数（懒栈会先估后修，留 20% 余量）。
        XCTAssertGreaterThan(large.scroll.contentHeight,
                             CGFloat(2000) * Self.rowHeight * 0.8,
                             "内容高度必须与 2000 行 × \(Self.rowHeight)pt 同一量级")
        // 两种心跳都确实在跑（拍数是相对尺，只挡「主线程被占死 / 渲染循环停摆」这种硬故障）。
        XCTAssertGreaterThan(large.beat.sleepBeats, 30, "3 秒 8ms 心跳一拍都收不到 = 主线程被占死")
        XCTAssertGreaterThan(large.beat.displayRatio, 0.1,
                             "3 秒 CADisplayLink 拍数不到理想的 10% = 渲染循环没在跑，"
                             + "窗口很可能没真上屏（\(large.beat.displayTicks)/"
                             + "\(large.beat.idealDisplayTicks)）")
        // 三把尺本身有输出。
        XCTAssertGreaterThan(large.shot.footprintMB, 0)
        XCTAssertGreaterThan(large.shot.cpuSeconds, 0)
        XCTAssertEqual(ProbeMetrics.percentile([1, 2, 3, 4], 0.5), 3, accuracy: 0.0001,
                       "分位数口径：sorted[min(count-1, Int(count*q))]")
        // hitTest 不随规模涨（结构判据：闸门守比值，不守绝对微秒）。
        XCTAssertLessThan(large.shot.hitP50, max(small.shot.hitP50 * 4, 40),
                          "hitTest 随行数涨了 4 倍以上：200 行 \(small.shot.hitP50)us vs "
                          + "2000 行 \(large.shot.hitP50)us")
    }

    /// ③ 窗口真的上了屏 —— 渲染出来的像素不是空壳。
    ///
    /// 墨迹判据走 `VisionTextProbe.inkFraction`（**非众数颜色**占比，与桌面同一口径），
    /// 不再是旧版写死的「非白像素」—— 写死白在深色主题下会把整块背景算成墨迹。
    /// OCR 默认关：模拟器上 Vision 走宿主 Mac 的 CPU，首次请求好几秒，
    /// 而「空壳」这种硬故障墨迹就能挡住。要认字的探针自己传 `ocr: true`。
    func testRenderedRowsAreNotBlank() async throws {
        defer { MobileProbeWindow.closeAll() }

        let rig = MobileProbeRig(label: "smoke-ink", size: Self.size)
        rig.mount(Self.rowList(2000))
        try rig.requireScrollable()
        rig.scrollTo(CGFloat(120) * Self.rowHeight)
        rig.layout()
        try await Task.sleep(for: .milliseconds(250))

        let shot = await rig.snapshot(hitSamples: 20)
        rig.report(nil, shot)
        let path = attachProbePNG(shot.png, name: "probe-smoke-rows")
        print("[probe-smoke-png] \(path ?? "<nil>") bytes=\(shot.png?.count ?? 0) "
              + "ink=\(String(format: "%.4f", shot.ink))")

        XCTAssertTrue(shot.pixelsAvailable, "`.transparentOnScreen` 档必须取得到像素")
        XCTAssertGreaterThan(shot.ink, 0.005, "截图是空壳：非背景色像素只占 \(shot.ink * 100)%")
        await rig.close()
    }
}
