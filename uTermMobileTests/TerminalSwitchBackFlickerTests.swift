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
        /// 用户看到的那张画面的几何：行距（相邻文字带起点的中位数，像素）、文字带高、墨迹右缘（像素）、
        /// 层在视图里的矩形（点）、层的像素宽高，以及视图当前字号。
        var pitch: Int = 0
        var bandH: Int = 0
        var inkRight: Int = 0
        var layerRect = ""
        var pixels = ""
        var fontSize: Double = 0
        /// 用户实际看到的尺度（点）：行距、文字带高、墨迹右缘。contents 被拉伸（gravity = resize）时按层的矩形折算。
        var pitchPt: Double = 0
        var bandHPt: Double = 0
        var rightPt: Double = 0
        var gravity = ""
        var bands = 0
        var description: String {
            "cover=\(covered) y=\(frameY) surface=\(hasSurface) adj=\(adjustment) contents=\(layerContents) ink=\(inkRows)[\(firstInk)...\(lastInk)] hash=\(hash % 100000) cell=\(cellPx) pitch=\(pitch) bandH=\(bandH) right=\(inkRight) rect=\(layerRect) px=\(pixels) font=\(fontSize) pt=[pitch \(String(format: "%.2f", pitchPt)) band \(String(format: "%.2f", bandHPt)) right \(String(format: "%.1f", rightPt))] gravity=\(gravity) bands=\(bands) layer=\(layerID)"
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

    typealias Ink = (rows: Int, first: Int, last: Int, has: Bool, hash: UInt64, pitch: Int, bandH: Int, right: Int, w: Int, h: Int, bands: Int)
    private var inkCache: (key: UInt32, value: Ink)?

    private func ink(_ layer: CALayer?) -> Ink {
        guard let layer, let contents = layer.contents, CFGetTypeID(contents as CFTypeRef) == IOSurfaceGetTypeID() else {
            return (0, -1, -1, false, 0, 0, 0, 0, 0, 0, 0)
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
        var starts: [Int] = [], heights: [Int] = []
        var run = 0
        var right = 0
        for y in 0..<h {
            var has = false
            var x = 0
            while x < w - 1 {
                let v = px(x, y)
                if v != bg { has = true; right = max(right, x); hash = (hash ^ UInt64(v) ^ UInt64(x &* 7 &+ y)) &* 1099511628211 }
                x += 1
            }
            if has { rows += 1; if first < 0 { first = y }; last = y }
            if has { if run == 0 { starts.append(y) }; run += 1 } else if run > 0 { heights.append(run); run = 0 }
        }
        if run > 0 { heights.append(run) }
        // 众数：光标那一行（整块高）和被截的行是少数，不该带偏读数。
        func mode(_ a: [Int]) -> Int {
            var counts: [Int: Int] = [:]
            for v in a { counts[v, default: 0] += 1 }
            return counts.max { ($0.value, -$0.key) < ($1.value, -$1.key) }?.key ?? 0
        }
        let diffs = zip(starts.dropFirst(), starts).map { $0 - $1 }
        let result: Ink = (rows: rows, first: first, last: last, has: true, hash: hash, pitch: mode(diffs),
                           bandH: mode(heights), right: right, w: w, h: h, bands: starts.count)
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
            let host = view.layer
            // 盖子里旧帧在它的子层上（盖子随视图挪位置时旧帧要留在屏上原处）。
            let cover = host.sublayers?.first { $0.name == GhosttySwitchBackCover.layerName }.map { $0.sublayers?.first ?? $0 }
            let shown = cover ?? layers.last
            let info = self.ink(shown)
            let rect = shown.map { host.convert($0.bounds, from: $0) } ?? .zero
            let gravity = shown?.contentsGravity.rawValue ?? ""
            // 每个像素在屏上占多少点：gravity = resize 时 contents 被拉到整个层，其余按 contentsScale 原样铺。
            let ptPerPxY = (gravity == "resize" && info.h > 0) ? Double(rect.height) / Double(info.h) : 1 / Double(shown?.contentsScale ?? 3)
            let ptPerPxX = (gravity == "resize" && info.w > 0) ? Double(rect.width) / Double(info.w) : 1 / Double(shown?.contentsScale ?? 3)
            return Sample(frameY: Double(view.frame.minY), hasSurface: view.surface != nil && !view.uTermIsSurfaceReleased,
                          adjustment: view.uTermCellHeightAdjustment, layerContents: info.has, inkRows: info.rows,
                          firstInk: info.first, lastInk: info.last, text: false, covered: cover != nil, hash: info.hash,
                          cellPx: Int(bridge.session.surfaceGrid?.cellHeightPixels ?? 0),
                          layerID: layers.count * 1000 + (layers.last.map { abs(ObjectIdentifier($0).hashValue) % 1000 } ?? 0),
                          pitch: info.pitch, bandH: info.bandH, inkRight: info.right,
                          layerRect: String(format: "%.2f,%.2f,%.2fx%.2f", rect.minX, rect.minY, rect.width, rect.height),
                          pixels: "\(info.w)x\(info.h)", fontSize: Double(view.terminalFontSize),
                          pitchPt: Double(info.pitch) * ptPerPxY, bandHPt: Double(info.bandH) * ptPerPxY,
                          rightPt: Double(info.right) * ptPerPxX, gravity: gravity, bands: info.bands)

        }
    }

    enum Case: String { case quick, tail, released, releasedTail }

    /// 藏着期间容器变了：键盘升起（矮一截）、变窄（字号跟着宽度变小）。切回来时终端要按新的尺寸 / 字号重排。
    enum Change: String { case none, keyboard, narrower }

    private func run(_ kase: Case, newContainer: Bool, fontSize: CGFloat = 11, change: Change = .none) async throws {
        let (bridge, container) = try await hostedInWindow(fontSize: fontSize)
        // 容器高度除不尽一行：按行填满有下移量。
        await settleAll(bridge)
        guard let natural = bridge.session.surfaceGrid.map({ Int($0.cellHeightPixels) - bridge.view.uTermCellHeightAdjustment }) else { return XCTFail("没有网格") }
        let scale = bridge.view.uTermScaleFactor
        lay(container, CGSize(width: 400, height: CGFloat((Double(natural * 12 + natural - 2) + 0.25) / scale)))
        for i in 0..<60 { bridge.feed(Data("line \(i) abcdefghijklmnopqrstuvwxyz 0123456789\r\n".utf8)) }
        await settleAll(bridge)
        let offsetBefore = bridge.link.rowFillOffset
        print("SWITCHBACK[\(kase.rawValue) new=\(newContainer)] 前置 offset=\(offsetBefore) adj=\(bridge.view.uTermCellHeightAdjustment) frameY=\(bridge.view.frame.minY)")

        if kase == .released || kase == .releasedTail { bridge.hiddenReleaseDelay = .milliseconds(100) }
        container.isOnScreen = false
        try await Task.sleep(for: .milliseconds((kase == .released || kase == .releasedTail) ? 500 : 300))
        if kase == .tail || kase == .releasedTail { for i in 0..<20 { bridge.feed(Data("tail \(i) abcdefghijklmnopqrstuvwxyz 0123456789\r\n".utf8)) } }
        if kase == .released || kase == .releasedTail { XCTAssertTrue(bridge.view.uTermIsSurfaceReleased, "自证：surface 放掉了") }
        try await Task.sleep(for: .milliseconds(100))

        let recorder = Recorder()
        recorder.read = sampler(bridge)
        // 前提：切回前，藏着的终端留在视图上的旧画面是有内容的。并行跑（负载高）时偶尔读成纯底色，那是切回之前就有的状态，
        // 不是这条用例要查的切回过程，等一等；等不到就跳过，别当成切回出了空白帧。
        let hadPicture = await MobileFakeTerminal.waitUntil(timeout: .seconds(2)) { recorder.read?().inkRows ?? 0 > 0 }
        try XCTSkipUnless(hadPicture, "切回前旧层已是空白（并行负载下偶发）")
        recorder.begin()
        var newSize = container.bounds.size
        var newFont = fontSize
        switch change {
        case .none: break
        case .keyboard: newSize.height -= 70
        case .narrower: newSize.width = 340; newFont = 9.6
        }
        var live = container
        if newContainer {
            live = MTerminalContainerView(terminal: bridge, fontSize: newFont, isOnScreen: true)
            try mount(live)
            lay(live, newSize)
        } else {
            lay(container, newSize)
            container.setFontSize(newFont)
            container.isOnScreen = true
        }
        _ = live
        try await Task.sleep(for: .milliseconds(900))
        recorder.end()
        for (ms, sample) in recorder.log { print("SWITCHBACK[\(kase.rawValue) new=\(newContainer)] +\(Int(ms))ms \(sample)") }
        let samples = recorder.log.map(\.sample)
        if change == .none {
            let verdict = analyze(samples, offset: offsetBefore)
            print("SWITCHBACK[\(kase.rawValue) new=\(newContainer)] 判定 \(verdict)")
            assertNoFlicker(verdict, kase: kase)
        }
        // 盖子期间：旧帧原样（不被裁、不被拉）——层矩形就是切回前那张活层的矩形。
        if let live = samples.first, !live.covered {
            for c in samples where c.covered { XCTAssertEqual(c.layerRect, live.layerRect, "盖子被裁 / 拉伸 / 挪位") }
        }
        let states = geometryStates(samples)
        print("SWITCHBACK[\(kase.rawValue) new=\(newContainer) \(change.rawValue)] 用户看到的几何 \(states.count) 种：\(states)")
        XCTAssertLessThanOrEqual(states.count, 2, "用户看到的行距 / 字形尺寸出现了旧画面和最终画面之外的第三种：\(states)")
        XCTAssertEqual(samples.filter { $0.inkRows == 0 }.count, 0, "出现空白帧")
    }

    /// 用户看到的几何（行距、字形高、墨迹右缘，单位点，取到 0.1）依次出现了哪几种（连续相同的合并）。
    private func geometryStates(_ samples: [Sample]) -> [String] {
        var out: [String] = []
        for s in samples where s.inkRows > 0 {
            let key = String(format: "pitch %.1f band %.1f right %.1f", s.pitchPt, s.bandHPt, s.rightPt)
            if out.last != key { out.append(key) }
        }
        return out
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

    /// 生产里字号随宽度走（390pt 以下按比例，不是整数），和 ghostty 控制器启动时的 11 不一样。
    func testReleasedFractionalFontSameContainer() async throws { try await run(.released, newContainer: false, fontSize: 10.63) }
    func testReleasedFractionalFontNewContainer() async throws { try await run(.released, newContainer: true, fontSize: 10.63) }
    func testQuickFractionalFont() async throws { try await run(.quick, newContainer: false, fontSize: 10.63) }

    func testQuickKeyboardSame() async throws { try await run(.quick, newContainer: false, fontSize: 10.63, change: .keyboard) }
    func testQuickKeyboardNew() async throws { try await run(.quick, newContainer: true, fontSize: 10.63, change: .keyboard) }
    func testQuickNarrowerSame() async throws { try await run(.quick, newContainer: false, fontSize: 10.63, change: .narrower) }
    func testQuickNarrowerNew() async throws { try await run(.quick, newContainer: true, fontSize: 10.63, change: .narrower) }
    func testReleasedKeyboardSame() async throws { try await run(.released, newContainer: false, fontSize: 10.63, change: .keyboard) }
    func testReleasedKeyboardNew() async throws { try await run(.released, newContainer: true, fontSize: 10.63, change: .keyboard) }
    func testReleasedNarrowerSame() async throws { try await run(.released, newContainer: false, fontSize: 10.63, change: .narrower) }
    func testReleasedNarrowerNew() async throws { try await run(.released, newContainer: true, fontSize: 10.63, change: .narrower) }
    func testReleasedTailKeyboardSame() async throws { try await run(.releasedTail, newContainer: false, fontSize: 10.63, change: .keyboard) }
    func testReleasedTailKeyboardNew() async throws { try await run(.releasedTail, newContainer: true, fontSize: 10.63, change: .keyboard) }
    func testReleasedTailNarrowerSame() async throws { try await run(.releasedTail, newContainer: false, fontSize: 10.63, change: .narrower) }
    func testReleasedTailNarrowerNew() async throws { try await run(.releasedTail, newContainer: true, fontSize: 10.63, change: .narrower) }

    func testQuickSameContainer() async throws { try await run(.quick, newContainer: false) }
    func testQuickNewContainer() async throws { try await run(.quick, newContainer: true) }
    func testTailSameContainer() async throws { try await run(.tail, newContainer: false) }
    func testTailNewContainer() async throws { try await run(.tail, newContainer: true) }
    func testReleasedTailSameContainer() async throws { try await run(.releasedTail, newContainer: false) }
    func testReleasedTailNewContainer() async throws { try await run(.releasedTail, newContainer: true) }
    func testReleasedSameContainer() async throws { try await run(.released, newContainer: false) }
    func testReleasedNewContainer() async throws { try await run(.released, newContainer: true) }

    // MARK: 键盘升降（终端一直在屏上）

    /// 键盘升起：等停稳期间终端按旧尺寸往上挪着放（提示符留在屏上），提交时挪回来。引擎交出新帧之前，层上还是旧帧——
    /// 它不能跟着视图挪回去、按顶边对齐露出旧内容的顶部（实机录屏：按键条上方闪一帧旧内容）。
    func testKeyboardRiseDoesNotFlashTheOldTop() async throws { try await runKeyboard(rise: true) }

    /// 键盘收起：内容铺满、上面有回滚时，提交后引擎从回滚往下拉行、内容贴底；等停稳期间就贴底跟着走，
    /// 不先留在顶上（和按键条之间空一截）、提交时再整段往下跳。
    func testKeyboardDropKeepsTheContentAnchored() async throws { try await runKeyboard(rise: false) }

    private func runKeyboard(rise: Bool) async throws {
        let (bridge, container) = try await hostedInWindow(fontSize: 10.63)
        let tall = CGSize(width: 400, height: 620), short = CGSize(width: 400, height: 380)
        lay(container, rise ? tall : short)
        await settleAll(bridge)
        for i in 0..<120 { bridge.feed(Data("line \(i) abcdefghijklmnopqrstuvwxyz 0123456789\r\n".utf8)) }
        bridge.feed(Data("$ ".utf8))
        await settleAll(bridge)
        if !rise { XCTAssertTrue(bridge.growsFromScrollback, "用例前提：内容铺满、有回滚") }

        let recorder = Recorder()
        recorder.read = sampler(bridge)
        recorder.begin()
        // 键盘动画：约 0.3 秒里一点点改高度，每步一个显示帧。
        let from = rise ? tall : short, to = rise ? short : tall
        for step in 1...20 {
            let t = CGFloat(step) / 20
            lay(container, CGSize(width: 400, height: (from.height + (to.height - from.height) * t).rounded()))
            try await Task.sleep(for: .milliseconds(16))
        }
        try await Task.sleep(for: .milliseconds(900))
        recorder.end()
        let samples = recorder.log.map(\.sample)
        for (ms, sample) in recorder.log { print("KEYBOARD[rise=\(rise)] +\(Int(ms))ms \(sample)") }
        guard let first = samples.first, let final = samples.last else { return XCTFail("没有采样") }
        XCTAssertEqual(samples.filter { $0.inkRows == 0 }.count, 0, "出现空白帧")

        // 旧画面（和第一帧同一张）在屏上的位置：等停稳期间跟着容器走，提交后不能再换位置。
        func screenTop(_ s: Sample) -> Double {
            Double(s.layerRect.split(separator: ",")[1]).map { $0 + s.frameY } ?? .nan
        }
        // 提交：视图挪到最终位置、尺寸换成最终尺寸的那一帧（引擎的新帧可能还没到）。
        let committed = samples.lastIndex { $0.frameY != final.frameY || !$0.layerRect.hasSuffix(final.layerRect.split(separator: ",").last.map(String.init) ?? "") }
            .map { $0 + 1 } ?? 0
        let lastHeld = samples[..<committed].last { $0.hash == first.hash }
        for s in samples[committed...] where s.hash == first.hash {
            XCTAssertEqual(screenTop(s), lastHeld.map(screenTop) ?? screenTop(s), accuracy: 0.5,
                           "提交后旧画面换了位置（闪一下）：\(s)")
        }
        if !rise, let held = lastHeld {
            // 贴底：提交前最后一帧（键盘已经收完）里旧画面的底边贴着容器底边（差不超过按行填满的零头）。
            let height = Double(held.layerRect.split(separator: ",")[2].split(separator: "x")[1]) ?? 0
            XCTAssertLessThan(Double(container.bounds.height) - (screenTop(held) + height), 12, "等停稳期间内容没贴底：\(held)")
        }
    }

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
