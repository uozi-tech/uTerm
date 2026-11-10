import XCTest
@testable import uTerm

/// 原来核的是 `TerminalFlushPacing` / `TerminalFlushPacer` 的算法：旧引擎那条路径上，输出在主线程按拍喂进视图，
/// 每拍喂多少（预算 32 KiB 起、有积压且解析得快就翻倍到 512 KiB、解析慢就减半）、拍与拍之间隔多久（有积压时
/// 短间隔追赶、追久了退回正常节拍、后台不追赶）由它算。
///
/// 这两个类型随旧引擎一起删了，节拍和预算的概念不存在了：解析不在主线程上（输出泵的入站任务 + Ghostty 自己的
/// IO 线程），不需要「每拍只喂一点、别把主线程占满」；出帧由 Ghostty 的渲染线程按显示节拍做。对应的东西只有一样——
/// 画面解析不过来时不无限堆积：输出泵的闸门（高 / 低水位），核在 `TerminalOutputPumpTests`
/// （`testBacklogPausesIngressUntilTheSurfaceCatchesUp`、`testBacklogIsIgnoredWhileOnlyTheShadowIsFed`、
/// `testResetReleasesAnIngressParkedAtTheGate`）。
///
/// 下面逐条保留原来的用例名、标跳过；另加一条核闸门的常数。
final class TerminalFlushPacingTests: XCTestCase {
    private func skipPacing(_ what: String) throws {
        throw XCTSkip("TerminalFlushPacing 随旧引擎删除，没有「\(what)」这个概念了；对应物是输出泵的背压，见 TerminalOutputPumpTests")
    }

    func testDoublesWhileBacklogFeedsWellUnderTarget() throws { try skipPacing("有积压时预算翻倍") }
    func testHalvesWhenFeedExceedsTarget() throws { try skipPacing("解析慢时预算减半") }
    func testStaysPutWithoutBacklog() throws { try skipPacing("没有积压时预算不变") }
    func testStaysPutBetweenHalfTargetAndTarget() throws { try skipPacing("预算的保持区间") }
    func testBudgetIsClampedToBaseAndMax() throws { try skipPacing("预算的上下限") }
    func testTrickleIsNotBacklog() throws { try skipPacing("小流量不算积压") }
    func testBacklogUsesShortDelayAndIdleUsesInterval() throws { try skipPacing("积压时的短间隔") }
    func testLongBacklogFallsBackToInterval() throws { try skipPacing("追赶窗口") }
    func testNewBacklogRestartsCatchUpWindow() throws { try skipPacing("追赶窗口重新计时") }
    func testSlowFeedDoesNotCatchUp() throws { try skipPacing("解析慢时不追赶") }
    func testBackgroundNeverCatchesUp() throws { try skipPacing("后台节拍") }
    func testSwitchingPacingResetsBudget() throws { try skipPacing("换节拍重置预算") }

    /// 闸门的常数要自洽：低水位在高水位之下（否则一放行又立刻停）；切片不比低水位大（否则落回低水位后喂一片就又到
    /// 高水位）；高水位不大于 surface 自己「没建好时最多缓 1 MiB」的上限。
    func testBackpressureWaterMarksAreConsistent() {
        XCTAssertLessThan(TerminalOutputPump.lowWater, TerminalOutputPump.highWater)
        XCTAssertLessThanOrEqual(TerminalOutputPump.sliceBytes, TerminalOutputPump.lowWater)
        XCTAssertLessThanOrEqual(TerminalOutputPump.highWater, 1 << 20)
        XCTAssertGreaterThanOrEqual(TerminalOutputPump.sliceBytes, 16 << 10, "切得太碎每片的锁开销就显出来了")
    }
}
