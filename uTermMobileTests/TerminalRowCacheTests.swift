import XCTest
@testable import uTermMobile

/// 换引擎之前：按行缓存排版结果（SwiftTerm 补丁 #20）不能画出旧内容——视图 A 经历一连串变化、每步之间都画一次，
/// 视图 B 是全新视图、喂同样的字节只画一次，两张截图必须逐字节相同（原地改写、滚动与回滚行复用、换调色板、
/// 进出备用屏、行对象互换、选区变化七种情形）。
///
/// 这份缓存是 SwiftTerm 主线程 CoreText 绘制里的东西，随引擎一起删了。GhosttyKit 的渲染器每帧从终端状态重建
/// 要画的格子（GPU 上只缓存字形图集，不缓存「某一行排好的结果」），没有「缓存没失效画出旧行」这类问题可测。
/// 新引擎上「画面和终端状态一致」由这些用例核：`GhosttyBackgroundTests`（回放后 surface 与影子逐行一致）、
/// `TerminalHiddenRenderingTests`（重建 surface 后一致）、`GhosttyScrollEdgeTests`（滚动后的画面落在整行）。
@MainActor
final class TerminalRowCacheTests: XCTestCase {
    func testRowLayoutCacheIsGoneWithSwiftTerm() throws {
        throw XCTSkip("SwiftTerm 的按行排版缓存（补丁 #20）随引擎一起删了，GhosttyKit 没有对应的缓存可测")
    }
}
