import GhosttyTerminal
import IOSurface
import QuartzCore
import UIKit
import XCTest
@testable import uTermMobile

/// 切回一个终端标签时，用户看到的第一帧就该是对的：不是空白（只有底色）、不是内容先在别处再挪回来、不是先旧后新。
/// 逐显示帧记录真正上屏的东西（视图 frame、surface 的行高调整、层的 contents 和里面墨迹的行范围），
/// 三种情况：(a) 藏一下马上回来、期间没输出；(b) 藏着期间来了输出；(c) 藏到 surface 被放掉再回来。
/// 每种再分「同一个容器切回」和「换一个新容器接走视图」（SwiftUI 重建表示层）。
@MainActor
final class TerminalSwitchBackFlickerTests: MTerminalContainerTestCase {
    struct Sample: Equatable, CustomStringConvertible {
        var frameY: Double
        var hasSurface: Bool
        var adjustment: Int
        var layerContents: Bool
        var inkRows: Int
        var firstInk: Int
        var lastInk: Int
        var text: Bool
    var covered = false
    var hash: UInt64 = 0
    var cellPx: Int = 0
    var layerID: Int = 0
        var description: String {
            "cover=\(covered) y=\(frameY) surface=\(hasSurface) adj=\(adjustment) contents=\(layerContents) ink=\(inkRows)[\(firstInk)...\(lastInk)] hash=\(hash % 100000) cell=\(cellPx) layer=\(layerID)"
        }
    }

    final class Recorder {
        var log: [(ms: Double, sample: Sample)] = []
        private var link: CADisplayLink?
        private var start = CACurrentMediaTime()
        var read: (() -> Sample)?
        private var observer: CFRunLoopObserver?
        func begin() {
            start = CACurrentMediaTime()
            log = []
            link = CADisplayLink(target: self, selector: #selector(tick))
            link?.add(to: .main, forMode: .common)
            nonisolated(unsafe) let me = self
            observer = CFRunLoopObserverCreateWithHandler(nil, CFRunLoopActivity.afterWaiting.rawValue | CFRunLoopActivity.beforeWaiting.rawValue, true, 0) { _, _ in
                MainActor.assumeIsolated { me.tick() }
            }
            CFRunLoopAddObserver(CFRunLoopGetMain(), observer, .commonModes)
            tick()
        }
        func end() {
            link?.invalidate(); link = nil
            if let observer { CFRunLoopRemoveObserver(CFRunLoopGetMain(), observer, .commonModes) }
            observer = nil
        }
        @objc func tick() {
            guard let sample = read?() else { return }
            if log.last?.sample != sample { log.append(((CACurrentMediaTime() - start) * 1000, sample)) }
        }
    }

    private var inkCache: (key: UInt32, value: (rows: Int, first: Int, last: Int, has: Bool, hash: UInt64))?

    private func ink(_ layer: CALayer?) -> (rows: Int, first: Int, last: Int, has: Bool, hash: UInt64) {
        guard let layer, let contents = layer.contents, CFGetTypeID(contents as CFTypeRef) == IOSurfaceGetTypeID() else {
            return (0, -1, -1, false, 0)
        }
        let surface = unsafeBitCast(contents as AnyObject, to: IOSurfaceRef.self)
        // 同一张 IOSurface 在同一个 seed 下不重读。
        let key = IOSurfaceGetID(surface) &* 31 &+ IOSurfaceGetSeed(surface)
        if let cache = inkCache, cache.key == key { return cache.value }
        IOSurfaceLock(surface, .readOnly, nil)
        defer { IOSurfaceUnlock(surface, .readOnly, nil) }
        let w = IOSurfaceGetWidth(surface), h = IOSurfaceGetHeight(surface), stride = IOSurfaceGetBytesPerRow(surface)
        let base = IOSurfaceGetBaseAddress(surface).assumingMemoryBound(to: UInt8.self)
        func px(_ x: Int, _ y: Int) -> UInt32 { UnsafeRawPointer(base + y * stride + x * 4).loadUnaligned(as: UInt32.self) }
        let bg = px(w - 1, 0)
        var rows = 0, first = -1, last = -1
        var hash: UInt64 = 1469598103934665603
        for y in 0..<h {
            var has = false
            var x = 0
            while x < w - 1 {
                let v = px(x, y)
                if v != bg { has = true; hash = (hash ^ UInt64(v) ^ UInt64(x &* 7 &+ y)) &* 1099511628211 }
                x += 2
            }
            if has { rows += 1; if first < 0 { first = y }; last = y }
        }
        let result = (rows: rows, first: first, last: last, has: true, hash: hash)
        inkCache = (key, result)
        return result
    }

    static func allSurfaceLayers(_ root: CALayer) -> [CALayer] {
        var out: [CALayer] = []
        if NSStringFromClass(type(of: root)).contains("IOSurface") { out.append(root) }
        for sub in root.sublayers ?? [] { out += allSurfaceLayers(sub) }
        return out
    }

    private func sampler(_ bridge: GhosttyTerminalBridge) -> () -> Sample {
        { [weak bridge] in
            guard let bridge else { return Sample(frameY: 0, hasSurface: false, adjustment: 0, layerContents: false, inkRows: 0, firstInk: -1, lastInk: -1, text: false) }
            let view = bridge.view
            let layers = Self.allSurfaceLayers(view.layer)
            // 用户看到的：盖着旧帧（`GhosttySwitchBackCover`）就是它，否则是最新的 surface 层。
            let cover = view.layer.sublayers?.first { $0.name == GhosttySwitchBackCover.layerName }
            let info = self.ink(cover ?? layers.last)
            return Sample(frameY: Double(view.frame.minY), hasSurface: view.surface != nil && !view.uTermIsSurfaceReleased,
                          adjustment: view.uTermCellHeightAdjustment, layerContents: info.has, inkRows: info.rows,
                          firstInk: info.first, lastInk: info.last, text: false, covered: cover != nil, hash: info.hash,
                          cellPx: Int(bridge.session.surfaceGrid?.cellHeightPixels ?? 0),
                          layerID: layers.count * 1000 + (layers.last.map { abs(ObjectIdentifier($0).hashValue) % 1000 } ?? 0))
        }
    }

    enum Case: String { case quick, tail, released, releasedTail }

    private func run(_ kase: Case, newContainer: Bool) async throws {
        let (bridge, container) = try await hostedInWindow()
        // 容器高度除不尽一行：按行填满有下移量。
        await settleAll(bridge)
        guard let natural = bridge.session.surfaceGrid.map({ Int($0.cellHeightPixels) - bridge.view.uTermCellHeightAdjustment }) else { return XCTFail("没有网格") }
        let scale = bridge.view.uTermScaleFactor
        lay(container, CGSize(width: 400, height: CGFloat((Double(natural * 8 + natural - 2) + 0.25) / scale)))
        for i in 0..<60 { bridge.feed(Data("line \(i) abcdefghijklmnopqrstuvwxyz 0123456789\r\n".utf8)) }
        await settleAll(bridge)
        let offsetBefore = bridge.link.rowFillOffset
        print("SWITCHBACK[\(kase.rawValue) new=\(newContainer)] 前置 offset=\(offsetBefore) adj=\(bridge.view.uTermCellHeightAdjustment) frameY=\(bridge.view.frame.minY)")

        if kase == .released || kase == .releasedTail { bridge.hiddenReleaseDelay = .milliseconds(100) }
        container.isOnScreen = false
        try await Task.sleep(for: .milliseconds((kase == .released || kase == .releasedTail) ? 500 : 300))
        if kase == .tail || kase == .releasedTail { for i in 0..<20 { bridge.feed(Data("tail \(i) new output\r\n".utf8)) } }
        if kase == .released || kase == .releasedTail { XCTAssertTrue(bridge.view.uTermIsSurfaceReleased, "自证：surface 放掉了") }
        try await Task.sleep(for: .milliseconds(100))

        let recorder = Recorder()
        recorder.read = sampler(bridge)
        recorder.begin()
        var live = container
        if newContainer {
            live = MTerminalContainerView(terminal: bridge, fontSize: 11, isOnScreen: true)
            try mount(live)
            lay(live, container.bounds.size)
        } else {
            container.isOnScreen = true
        }
        _ = live
        try await Task.sleep(for: .milliseconds(900))
        recorder.end()
        for (ms, sample) in recorder.log { print("SWITCHBACK[\(kase.rawValue) new=\(newContainer)] +\(Int(ms))ms \(sample)") }
        let verdict = analyze(recorder.log.map(\.sample), offset: offsetBefore)
        print("SWITCHBACK[\(kase.rawValue) new=\(newContainer)] 判定 \(verdict)")
        assertNoFlicker(verdict, kase: kase)
    }

    struct Verdict: CustomStringConvertible {
        var blankFrames = 0
        var yJumps = 0
        var adjustmentJumps = 0
        var inkShifts = 0
        var description: String { "空白帧=\(blankFrames) frame.y 跳变=\(yJumps) 行高调整跳变=\(adjustmentJumps) 内容位移=\(inkShifts)" }
    }

    /// 用户看到的帧序列：只允许「旧画面 → 最终画面」，中间不能有第三种（空终端、半截回放）、不能回到旧画面；
    /// 没被盖住的帧里行高调整、frame.y 不能偏离最终值。
    private func analyze(_ samples: [Sample], offset: CGFloat) -> Verdict {
        var verdict = Verdict()
        guard let first = samples.first, let final = samples.last else { return verdict }
        var reachedFinal = false
        for s in samples {
            if s.inkRows == 0 { verdict.blankFrames += 1 }
            if s.hash == final.hash { reachedFinal = true }
            else if s.hash != first.hash { verdict.inkShifts += 1 }
            else if reachedFinal { verdict.inkShifts += 1 }
            if s.frameY != final.frameY { verdict.yJumps += 1 }
            if !s.covered, s.hasSurface, s.adjustment != final.adjustment { verdict.adjustmentJumps += 1 }
        }
        return verdict
    }

    private func assertNoFlicker(_ v: Verdict, kase: Case) {
        XCTAssertEqual(v.blankFrames, 0, "出现空白帧")
        XCTAssertEqual(v.yJumps, 0, "frame.y 先到别处再回来")
        XCTAssertEqual(v.adjustmentJumps, 0, "行高调整先按别的值画再改")
        XCTAssertEqual(v.inkShifts, 0, "上屏了旧画面和最终画面之外的帧")
    }

    private func settleAll(_ bridge: GhosttyTerminalBridge) async {
        try? await Task.sleep(for: .milliseconds(600))
        _ = await reported(bridge)
        try? await Task.sleep(for: .milliseconds(300))
    }

    func testQuickSameContainer() async throws { try await run(.quick, newContainer: false) }
    func testQuickNewContainer() async throws { try await run(.quick, newContainer: true) }
    func testTailSameContainer() async throws { try await run(.tail, newContainer: false) }
    func testTailNewContainer() async throws { try await run(.tail, newContainer: true) }
    func testReleasedTailSameContainer() async throws { try await run(.releasedTail, newContainer: false) }
    func testReleasedTailNewContainer() async throws { try await run(.releasedTail, newContainer: true) }
    func testReleasedSameContainer() async throws { try await run(.released, newContainer: false) }
    func testReleasedNewContainer() async throws { try await run(.released, newContainer: true) }

    /// 新容器接走视图、尺寸还没停稳（hold）的那段时间里，视图留在按行填满的下移位置，不先跳到 0 再回来。
    func testHoldKeepsRowFillOffset() async throws {
        let (bridge, container) = try await hostedInWindow()
        await settleAll(bridge)
        guard let natural = bridge.session.surfaceGrid.map({ Int($0.cellHeightPixels) - bridge.view.uTermCellHeightAdjustment }) else { return XCTFail("没有网格") }
        let scale = bridge.view.uTermScaleFactor
        let size = CGSize(width: 400, height: CGFloat((Double(natural * 8 + natural - 2) + 0.25) / scale))
        lay(container, size)
        await settleAll(bridge)
        let offset = bridge.link.rowFillOffset
        XCTAssertGreaterThan(offset, 0, "用例前提：有下移量")
        let live = MTerminalContainerView(terminal: bridge, fontSize: 11)
        try mount(live)
        lay(live, CGSize(width: size.width, height: size.height + 40))
        XCTAssertEqual(bridge.view.frame.minY, offset, accuracy: 0.001, "等停稳期间视图不能跳离下移位置")
    }
}
