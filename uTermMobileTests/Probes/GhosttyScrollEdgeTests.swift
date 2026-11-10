import GhosttyTerminal
import QuartzCore
import UIKit
import XCTest
@testable import uTermMobile

/// Ghostty 终端滚到回滚顶部 / 活动区底部之后，画面有没有回到和「从没滚动过」完全相同的像素位置。
///
/// 起因：user 在 iPhone Duo 上滚到顶之后，第一行上方多出一截空白和一条细线、最后一行被切。根因是本地滚动补丁
/// 拿滚动条行号判「到顶」：行号到 0 时引擎还差半行（0023 的小数行偏移），那时就进回弹，真正的第一行永远拉不下来，
/// 松手后停在「第一行被切、底下多露半行」的位置上。修法与镜像的规则见 `UITerminalView+Scroll.swift`。
///
/// 量法：每一行铺一条整行宽的底色（27 种循环，相邻行必不同），截整扇窗口的合成结果（回弹平移的是宿主层，
/// 只有窗口截图带得上），读一列像素还原出「每个像素行属于第几行文字」。网格原点、相邻行露出的残条、
/// 最后一行被切、回弹没归零都是同一张表上的事，差 1 px 也看得见。
/// 手势按真机的规则分路（见 `Rig`）：有回滚的普通屏，单指归系统滚动——直接操作 GhosttyKit 借来的那个 UIScrollView
/// 并调它的代理方法（`EdgeSystemFinger`）；没有回滚、备用屏时落回自写的拖动——伪造 `UIPanGestureRecognizer` 调
/// `handleTouchScrollGesture:`。
/// 每一步之间隔一帧（真手指也是一帧一个事件，引擎的滚动条回报要一帧才到，旧 bug 正出在这一帧上）。
///
/// 这一组原来每条都按两条路径各跑一遍（`.own` 自写单指拖动 / 惯性 / 回弹，`.system` 系统滚动）。本地包里那套自写滚动物理
/// 连同它的开关都已经删掉，单指滚回滚区恒走系统滚动，所以只留系统那一半，断言原样；去掉的那一半见
/// `testOwnPhysicsAndFreeRendererVariantsAreGone`。
@MainActor
final class GhosttyScrollEdgeTests: XCTestCase {
    /// 三种视图：竖屏手机那种、高度正好整除行高（余 0）、Duo 内屏横放那种又宽又矮的（890×504 pt，和 user 截图里终端那一块差不多大）。
    /// 行高以引擎实报为准（模拟器 39 px，Duo 真机 37 px），所以「余 0」那一档现算：48 行高。
    /// 实测余量：模拟器 6 / 0 / 30 px，Duo 真机见 docs/ghostty-eval/measure-ios.md 第九轮。
    private func probeSizes() async throws -> [CGSize] {
        if let cached = Self.cachedSizes { return cached }
        let probe = try await makeRig(size: CGSize(width: 440, height: 600), lines: 1)
        defer { probe.host.close() }
        let sizes = [CGSize(width: 440, height: 600),
                     CGSize(width: 440, height: CGFloat(probe.cellPx * 48) / probe.scale),
                     CGSize(width: 890, height: 504)]
        Self.cachedSizes = sizes
        return sizes
    }

    private static var cachedSizes: [CGSize]?

    override func setUp() async throws {
        UIApplication.shared.isIdleTimerDisabled = true
        // 宿主刚起来时窗口场景可能还没连上（单跑这一组用例时撞见过），等它。
        let deadline = CACurrentMediaTime() + 10
        while CACurrentMediaTime() < deadline,
              !UIApplication.shared.connectedScenes.contains(where: { $0 is UIWindowScene }) {
            try await Task.sleep(for: .milliseconds(50))
        }
    }

    // MARK: 语料与读图

    /// 第 `number` 行（从 1 起）的底色：三个通道各取 3 档，27 行一循环，相邻两行红色通道一定不同。
    nonisolated static func tint(_ number: Int) -> (r: Int, g: Int, b: Int) {
        (60 + 60 * (number % 3), 60 + 60 * ((number / 3) % 3), 60 + 60 * ((number / 9) % 3))
    }

    /// 一行带底色的编号行，空格垫到 `cols - 1` 列（不靠「擦到行尾带底色」）。
    nonisolated static func line(_ number: Int, cols: Int) -> String {
        let c = tint(number)
        let text = "\(number)"
        return "\u{1B}[48;2;\(c.r);\(c.g);\(c.b)m\(text)\(String(repeating: " ", count: max(0, cols - 1 - text.count)))\u{1B}[K\u{1B}[0m"
    }

    /// `range` 里的每一行，最后跟一行没有底色的提示符（和真实终端停在底部时一样）。
    nonisolated static func corpus(_ range: ClosedRange<Int>, cols: Int, hidesCursor: Bool = true) -> String {
        (hidesCursor ? "\u{1B}[?25l" : "") + range.map { line($0, cols: cols) + "\r\n" }.joined() + "$ "
    }

    /// 正好一屏、不滚动：第 1 … `rows` 行，最后一行后面不换行。它就是「滚到顶」该有的样子。
    nonisolated static func screenful(rows: Int, cols: Int) -> String {
        "\u{1B}[?25l" + (1...rows).map { line($0, cols: cols) }.joined(separator: "\r\n")
    }

    /// 一段连续的像素行：`key` 是按底色认出的行号（mod 27；-1 = 终端底色，-2 = 认不出的混色），
    /// `top` / `bottom` 是物理像素（含 top、不含 bottom）。
    struct Band: Equatable, CustomStringConvertible {
        var key: Int
        var top: Int
        var bottom: Int
        var height: Int { bottom - top }
        var description: String { "\(key == -1 ? "bg" : key == -2 ? "mix" : "#\(key)")[\(top)..<\(bottom)]" }
    }

    struct Shot {
        let bands: [Band]
        let image: CGImage
        /// 读图那一列每个像素行的颜色（排查混色用）。
        let column: [(r: Int, g: Int, b: Int)]

        /// 某条行带前后各两像素行的颜色。
        func colors(around band: Band) -> String {
            (max(0, band.top - 2)..<min(column.count, band.bottom + 2)).map { y in
                let c = column[y]; return "\(y):\(c.r),\(c.g),\(c.b)"
            }.joined(separator: " ")
        }
    }

    /// 像素色 → 行号 mod 27；终端底色（深色方案近黑、浅色方案近白）记 -1，哪一档都对不上的（两行交界的混色）记 -2。
    nonisolated static func classify(r: Int, g: Int, b: Int) -> Int {
        func level(_ v: Int) -> Int? {
            for (index, want) in [60, 120, 180].enumerated() where abs(v - want) <= 22 { return index }
            return nil
        }
        if max(r, g, b) < 30 || min(r, g, b) > 238 { return -1 }
        guard let lr = level(r), let lg = level(g), let lb = level(b) else { return -2 }
        return lr + 3 * lg + 9 * lb
    }

    /// 一张截图 60% 宽处那一列像素 → 行带（行号数字只占最左边几格，那一列全是底色）。
    nonisolated static func bands(of cg: CGImage) throws -> [Band] { try read(cg).bands }

    nonisolated static func read(_ cg: CGImage) throws -> (bands: [Band], column: [(r: Int, g: Int, b: Int)]) {
        let width = cg.width, height = cg.height
        var pixels = [UInt8](repeating: 0, count: width * height * 4)
        let context = try XCTUnwrap(CGContext(data: &pixels, width: width, height: height, bitsPerComponent: 8,
                                              bytesPerRow: width * 4, space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                              bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
        context.draw(cg, in: CGRect(x: 0, y: 0, width: width, height: height))
        let x = width * 6 / 10
        var bands: [Band] = []
        var column: [(r: Int, g: Int, b: Int)] = []
        for y in 0..<height {
            let i = (y * width + x) * 4
            let c = (r: Int(pixels[i]), g: Int(pixels[i + 1]), b: Int(pixels[i + 2]))
            column.append(c)
            let key = classify(r: c.r, g: c.g, b: c.b)
            if let last = bands.last, last.key == key {
                bands[bands.count - 1].bottom = y + 1
            } else {
                bands.append(Band(key: key, top: y, bottom: y + 1))
            }
        }
        return (bands, column)
    }

    /// 整扇窗口的合成结果（带上宿主层的回弹平移）。
    static func windowImage(_ window: UIWindow, afterScreenUpdates: Bool = false) throws -> CGImage {
        let format = UIGraphicsImageRendererFormat()
        format.scale = window.screen.nativeScale
        format.opaque = true
        let renderer = UIGraphicsImageRenderer(bounds: window.bounds, format: format)
        let image = renderer.image { _ in window.drawHierarchy(in: window.bounds, afterScreenUpdates: afterScreenUpdates) }
        return try XCTUnwrap(image.cgImage)
    }

    // MARK: 夹具

    /// 读数行里的路径标签。原来有「自写」「系统」两条路径各跑一遍，现在只剩系统滚动；标签留着，新旧日志对得上。
    nonisolated static let pathLabel = "系统"

    @MainActor
    final class Rig {
        let host: GhosttyProbeHost
        let pan = EdgeFakePan()
        let scale: CGFloat
        let cellPx: Int
        let rows: Int
        let cols: Int
        /// 手势处理函数被调过没有（没调过时镜像还没和引擎对过，不核它的行号）。
        private(set) var hasScrolled = false
        /// 正在进行的这一下手势归系统滚动（UIScrollView）还是自写路径。
        private var systemGesture = false
        /// 系统滚动那一半的手指（见 `EdgeSystemFinger`）。
        let finger: EdgeSystemFinger

        init(host: GhosttyProbeHost, scale: CGFloat, cellPx: Int) throws {
            self.host = host; self.scale = scale; self.cellPx = cellPx
            rows = host.grid.rows; cols = host.grid.cols
            finger = try EdgeSystemFinger(view: host.view)
        }

        var scrollView: UIScrollView? { view.uTermSystemScrollView }
        /// 代替 UIKit 的减速 / 回弹的那个（见 `EdgeSystemFinger.decelerator`）。
        var decelerator: EdgeDecelerator { finger.decelerator }

        // MARK: 手势
        //
        // 归不归系统滚动按真实规则判（`uTermSystemPanWouldBegin`）：有回滚的普通屏归系统，没有回滚、备用屏时和真机一样
        // 落回自写路径。
        // 自写路径：伪造 UIPanGestureRecognizer 调 `handleTouchScrollGesture:`。
        // 系统路径：`EdgeSystemFinger`（按 UIKit 会做的事直接操作 UIScrollView 并调它的代理方法）。

        func begin() {
            hasScrolled = true
            // 手指按下来：上一次松手的减速 / 回弹到此为止（UIKit 在按下时也是这样停的）。
            if decelerator.isRunning { touchDown() }
            if view.uTermSystemPanWouldBegin {
                systemGesture = true
                finger.begin()
            } else {
                systemGesture = false
                send(.began)
            }
        }

        /// 手指挪 `dy` pt（正 = 往下，内容跟着下移）。
        func move(_ dy: CGFloat) {
            if systemGesture { finger.move(dy) } else { send(.changed, dy: dy) }
        }

        /// 抬手，`velocity` pt/s（正 = 往下甩）。
        func end(velocity: CGFloat) {
            if systemGesture { finger.end(velocity: velocity) } else { send(.ended, velocity: velocity) }
        }

        /// 手势被系统打断。
        func cancel() {
            if systemGesture { finger.cancel() } else { send(.cancelled) }
        }

        /// 惯性 / 减速途中手指落下（不拖）。
        func touchDown() { finger.touchDown() }

        /// 读图的像素容差：nativeScale 不是整数的屏（Duo 内屏 2.807）上，窗口截图是重采样出来的，画面层差着零点几像素，
        /// 行界糊成一到两像素的混色（实测 591:153,74,60 592:72,112,59 这种两行渐变）；整数倍率的屏上一像素都不让。
        /// 像素级的精确判定靠模拟器那一跑；真机这一跑核的是镜像、回弹和整行对齐。
        var tolerance: Int { scale.rounded() == scale ? 0 : 2 }
        /// 行带表去掉重采样造成的 1 px 混色线（夹在两条带之间、不到容差那么高的并入上一条）。
        func cleaned(_ bands: [Band]) -> [Band] {
            guard tolerance > 0 else { return bands }
            var out: [Band] = []
            for band in bands {
                if band.height <= tolerance, var last = out.popLast() {
                    last.bottom = band.bottom
                    out.append(last)
                } else if let last = out.last, last.key == band.key {
                    out[out.count - 1].bottom = band.bottom
                } else {
                    out.append(band)
                }
            }
            return out
        }
        /// 两张行带表一样（行号一致、边界差不过容差）。
        func same(_ a: [Band], _ b: [Band]) -> Bool {
            let x = cleaned(a), y = cleaned(b)
            guard x.count == y.count else { return false }
            return zip(x, y).allSatisfy { $0.key == $1.key && abs($0.top - $1.top) <= tolerance && abs($0.bottom - $1.bottom) <= tolerance }
        }
        /// 两张行带表的格子位置一样（行号可以不同：来了新输出之后比）。
        func sameGeometry(_ a: [Band], _ b: [Band]) -> Bool {
            let x = cleaned(a), y = cleaned(b)
            guard x.count == y.count else { return false }
            return zip(x, y).allSatisfy { abs($0.top - $1.top) <= tolerance && abs($0.bottom - $1.bottom) <= tolerance }
        }

        var view: MGhosttyTerminalView { host.view }
        var bar: TerminalScrollbar? { host.scrollbar }
        var barText: String { bar.map { "\($0.offset)/\($0.total)/\($0.len)" } ?? "-" }
        var translation: CGFloat { view.layer.sublayerTransform.m42 }
        var isIdentity: Bool { CATransform3DIsIdentity(view.layer.sublayerTransform) }
        var atTop: Bool { bar.map { $0.offset == 0 } ?? true }
        var atBottom: Bool { bar.map { $0.offset + $0.len >= $0.total } ?? true }
        var hasScrollback: Bool { bar.map { $0.total > $0.len } ?? false }

        private func send(_ state: UIGestureRecognizer.State, dy: CGFloat = 0, velocity: CGFloat = 0) {
            pan.fakeState = state
            pan.fakeTranslation = CGPoint(x: 0, y: dy)
            pan.fakeVelocity = CGPoint(x: 0, y: velocity)
            _ = view.perform(NSSelectorFromString("handleTouchScrollGesture:"), with: pan)
        }

        /// 在提示符那一行上接着输出几行（再跟一个新的提示符）。
        func feed(_ range: ClosedRange<Int>) {
            host.feedAndWait("\r\u{1B}[2K" + GhosttyScrollEdgeTests.corpus(range, cols: cols, hidesCursor: false))
        }

        func shot() throws -> Shot {
            let image = try GhosttyScrollEdgeTests.windowImage(host.window)
            let read = try GhosttyScrollEdgeTests.read(image)
            return Shot(bands: read.bands, image: image, column: read.column)
        }
    }

    /// `size` 的终端；`feed` 拿到行列数后给出要喂的内容。等它画稳。
    private func makeRig(size requested: CGSize, feed: (_ rows: Int, _ cols: Int) -> String) async throws -> Rig {
        // 视图尺寸对到物理像素格上。Duo 内屏的 nativeScale 是 2.807（不是 3），600 pt 是 1684.3 px，截图会被重采样成 1685 px，
        // 每条行界都糊成一像素的混色，什么都量不准；宽高取成整数像素就没这回事。
        let nativeScale = UIApplication.shared.connectedScenes.compactMap { ($0 as? UIWindowScene)?.screen.nativeScale }.first ?? 3
        let size = CGSize(width: (requested.width * nativeScale).rounded() / nativeScale,
                          height: (requested.height * nativeScale).rounded() / nativeScale)
        let host = try GhosttyProbeHost(size: size)
        // 配色跟着视图的日夜走；钉成深色，读图时底色和 27 档行色才分得开（模拟器默认浅色）。
        host.window.overrideUserInterfaceStyle = .dark
        try await host.waitUntilReady()
        XCTAssertTrue(host.view.responds(to: NSSelectorFromString("handleTouchScrollGesture:")), "GhosttyKit 的拖动处理 selector 变了")
        host.feedAndWait(feed(host.grid.rows, host.grid.cols))
        try await Task.sleep(for: .milliseconds(300))
        let scale = host.view.window?.screen.nativeScale ?? 3
        let cell = try XCTUnwrap(host.view.uTermCellPixels)
        let rig = try Rig(host: host, scale: scale, cellPx: Int(cell.height))
        rig.pan.fakeLocation = CGPoint(x: size.width / 2, y: size.height / 2)
        return rig
    }

    private func makeRig(size: CGSize, lines: Int) async throws -> Rig {
        try await makeRig(size: size) { _, cols in Self.corpus(1...lines, cols: cols) }
    }

    /// 「滚到顶」该有的行带：同尺寸的终端只喂正好一屏、从没滚动过。
    private func topBaseline(size: CGSize) async throws -> [Band] {
        let rig = try await makeRig(size: size) { rows, cols in Self.screenful(rows: rows, cols: cols) }
        defer { rig.host.close() }
        return try await settle(rig).bands
    }

    /// 等画面停稳：没有惯性 / 回弹 / 吸附在跑，0.35 s 内行带不再变。返回停稳时的画面。
    private func settle(_ rig: Rig, timeout: Double = 8) async throws -> Shot {
        let deadline = CACurrentMediaTime() + timeout
        var last = try rig.shot()
        var stableSince = CACurrentMediaTime()
        while CACurrentMediaTime() < deadline {
            try await Task.sleep(for: .milliseconds(50))
            let now = try rig.shot()
            if now.bands != last.bands || !rig.view.uTermScrollState.isAtRest { stableSince = CACurrentMediaTime() }
            last = now
            if CACurrentMediaTime() - stableSince > 0.35 { break }
        }
        return last
    }

    private func describe(_ label: String, _ rig: Rig, _ shot: Shot) -> String {
        let state = rig.view.uTermScrollState
        let head = shot.bands.prefix(3).map(\.description).joined(separator: " ")
        let tail = shot.bands.suffix(3).map(\.description).joined(separator: " ")
        let mixes = shot.bands.filter { $0.key == -2 }.prefix(2).map { "\($0)<\(shot.colors(around: $0))>" }.joined(separator: " ")
        return "EDGE [\(Self.pathLabel)] \(label): bar=\(rig.barText) model=\(state.row)+\(state.fractionPixels)px over=\(Int(state.overscrollPixels)) "
            + "ty=\(String(format: "%.2f", rig.translation))pt bands=\(shot.bands.count) head=\(head) tail=\(tail)"
            + (mixes.isEmpty ? "" : " mix=\(mixes)")
    }

    private func attach(_ shot: Shot, _ name: String) {
        let attachment = XCTAttachment(image: UIImage(cgImage: shot.image))
        attachment.name = name
        attachment.lifetime = .keepAlways
        add(attachment)
    }

    // MARK: 判定

    /// 停稳之后必须成立的事：回弹归零、镜像在整行上且和滚动条一致、每条行带都落在格子线上、没有混色残条、行号连续。
    private func assertAtRest(_ rig: Rig, _ shot: Shot, _ label: String, file: StaticString = #filePath, line: UInt = #line) {
        let state = rig.view.uTermScrollState
        let context = describe(label, rig, shot)
        XCTAssertTrue(rig.isIdentity, "回弹平移没归零 — \(context)", file: file, line: line)
        XCTAssertTrue(state.isAtRest, "还有惯性 / 回弹 / 半行偏移 — \(context)", file: file, line: line)
        if rig.hasScrolled, let bar = rig.bar, bar.total > bar.len {
            XCTAssertEqual(state.row, Int(bar.offset), "镜像行号和引擎报的不一致 — \(context)", file: file, line: line)
        }
        if rig.hasScrollback, let scrollView = rig.scrollView {
            let offsetPx = scrollView.contentOffset.y * rig.scale
            XCTAssertEqual(Double(offsetPx), Double(state.row * rig.cellPx + state.fractionPixels), accuracy: rig.tolerance > 0 ? 0.5 : 0.01,
                           "UIScrollView 的 contentOffset 和镜像对不上 — \(context)", file: file, line: line)
            let maxRows = Double((rig.bar?.total ?? 0) - (rig.bar?.len ?? 0))
            XCTAssertEqual(Double(scrollView.contentSize.height), Double(scrollView.bounds.height) + maxRows * Double(rig.cellPx) / Double(rig.scale),
                           accuracy: 0.01, "UIScrollView 的 contentSize 没跟上回滚行数 — \(context)", file: file, line: line)
            XCTAssertFalse(scrollView.isDecelerating, "UIScrollView 还在减速 — \(context)", file: file, line: line)
        }
        let cell = rig.cellPx, tol = rig.tolerance
        let gridBottom = rig.rows * cell
        let bands = rig.cleaned(shot.bands)
        XCTAssertFalse(bands.contains { $0.key == -2 }, "有混色残条（相邻行露出一丝，或画面停在半个像素上）— \(context)", file: file, line: line)
        func onGrid(_ y: Int) -> Bool { min(y % cell, cell - y % cell) <= tol }
        for band in bands where band.key >= 0 {
            XCTAssertTrue(onGrid(band.top), "行带 \(band) 的上沿不在格子线上 — \(context)", file: file, line: line)
            // 最后一行可以连着网格下面那条余量（底色顺延）；别的行必须正好一行高。
            if band.bottom < gridBottom - tol || onGrid(band.bottom) {
                XCTAssertEqual(band.height, cell, accuracy: tol, "行带 \(band) 不是一行高（被切或露出半行）— \(context)", file: file, line: line)
            } else {
                XCTAssertEqual(band.top, gridBottom - cell, accuracy: tol, "只有最后一行能伸进余量 — \(context)", file: file, line: line)
                XCTAssertEqual(band.bottom, shot.image.height, accuracy: tol, "最后一行的底色顺延应当铺满余量 — \(context)", file: file, line: line)
            }
        }
        for (upper, lower) in zip(bands, bands.dropFirst()) where upper.key >= 0 && lower.key >= 0 {
            XCTAssertEqual(lower.key, (upper.key + 1) % 27, "行号不连续：\(upper) 后面是 \(lower) — \(context)", file: file, line: line)
        }
    }

    // MARK: 动作

    /// 手指慢拖：每帧 `stepPt`，直到 `until` 成立后再拖 `extra` 步（越过边缘进回弹），最多 `limit` 步。不松手。
    private func drag(_ rig: Rig, stepPt: CGFloat, extra: Int, limit: Int = 900, until: () -> Bool) async throws {
        rig.begin()
        var remaining: Int?
        for _ in 0..<limit {
            rig.move(stepPt)
            try await Task.sleep(for: .milliseconds(16))
            if let left = remaining {
                if left <= 1 { break }
                remaining = left - 1
            } else if until() {
                if extra == 0 { break }
                remaining = extra
            }
        }
    }

    private func fling(_ rig: Rig, leadPt: CGFloat, velocity: CGFloat) async throws {
        rig.begin()
        rig.move(leadPt)
        try await Task.sleep(for: .milliseconds(16))
        rig.end(velocity: velocity)
    }

    private func jump(_ rig: Rig, toRow row: Int) async throws {
        _ = rig.view.surface?.scrollToRow(UInt(max(0, row)))
        try await Task.sleep(for: .milliseconds(250))
    }

    /// 连甩回活动区底部并停稳。
    private func flingToBottom(_ rig: Rig) async throws {
        for _ in 0..<10 where !(rig.atBottom && rig.view.uTermScrollState.isAtRest) {
            try await fling(rig, leadPt: -6, velocity: -7000)
            _ = try await settle(rig)
        }
    }

    // MARK: 用例

    /// 远超一屏的内容：到顶 / 到底的每一种走法停稳之后，都和从没滚动过的画面逐像素行一致。
    func testEdgesSettleOnTheSameGridAsNeverScrolled() async throws {
        try await runEdgesSettleOnTheSameGridAsNeverScrolled()
    }

    private func runEdgesSettleOnTheSameGridAsNeverScrolled() async throws {
        let sizes = try await probeSizes()
        for (sizeIndex, size) in sizes.enumerated() {
            let top = try await topBaseline(size: size)
            let rig = try await makeRig(size: size, lines: 300)
            defer { rig.host.close() }
            let tag = "\(Int(size.width))x\(Int(size.height))"
            let bottom = try await settle(rig)
            let leftover = bottom.image.height - rig.rows * rig.cellPx
            print("EDGE rig \(tag) scale=\(rig.scale) cellPx=\(rig.cellPx) grid=\(rig.cols)x\(rig.rows) viewPx=\(bottom.image.height) leftoverPx=\(leftover)")
            if sizeIndex == 1 { XCTAssertEqual(leftover, 0, accuracy: rig.tolerance, "这一档的高度应当正好整除行高") }
            print(describe("\(tag) never-scrolled", rig, bottom))
            assertAtRest(rig, bottom, "\(tag) never-scrolled")
            XCTAssertTrue(rig.atBottom)

            func expectTop(_ label: String) async throws {
                let shot = try await settle(rig)
                print(describe("\(tag) \(label)", rig, shot))
                assertAtRest(rig, shot, "\(tag) \(label)")
                XCTAssertTrue(rig.atTop, "\(tag) \(label)：没到顶 bar=\(rig.barText)")
                XCTAssertTrue(rig.same(shot.bands, top), "\(tag) \(label)：到顶之后和「只有一屏、从没滚动过」的画面不一样")
                if !rig.same(shot.bands, top) { attach(shot, "\(tag)-\(label)") }
            }
            func expectBottom(_ label: String) async throws {
                let shot = try await settle(rig)
                print(describe("\(tag) \(label)", rig, shot))
                assertAtRest(rig, shot, "\(tag) \(label)")
                XCTAssertTrue(rig.atBottom, "\(tag) \(label)：没回到底 bar=\(rig.barText)")
                XCTAssertTrue(rig.same(shot.bands, bottom.bands), "\(tag) \(label)：回到底之后和滚动之前的画面不一样")
                if !rig.same(shot.bands, bottom.bands) { attach(shot, "\(tag)-\(label)") }
            }

            // 慢拖到顶再越过去：几种步长（整像素、带 1/3 pt 零头、很慢、很快），起点离顶的行数也不同，撞顶时的半行各不一样。
            for (index, step) in [7.0, 4.0 + 1.0 / 3, 1.5, 11.25].enumerated() {
                try await jump(rig, toRow: 5 + index)
                try await drag(rig, stepPt: CGFloat(step), extra: 12) { rig.view.uTermScrollState.overscrollPixels > 0 }
                try await Task.sleep(for: .milliseconds(80))
                let held = try rig.shot()
                print(describe("\(tag) slow-to-top step=\(step) held", rig, held))
                // 手还按着：引擎已经正好在顶上，整张画面只是被回弹平移了一段；第一行完整、上面没有别的行露出来。
                XCTAssertGreaterThan(rig.translation, 0, "\(tag) 越过顶之后应当在回弹里")
                let heldBands = rig.cleaned(held.bands)
                let firstRow = try XCTUnwrap(heldBands.first { $0.key >= 0 })
                XCTAssertEqual(firstRow.key, 1, "\(tag) 回弹里最上面一条应当是第 1 行，实际 \(firstRow)（上一行露出一丝？）")
                XCTAssertEqual(firstRow.height, rig.cellPx, accuracy: rig.tolerance, "\(tag) 回弹里第 1 行被切了：\(firstRow)")
                XCTAssertEqual(CGFloat(firstRow.top), rig.translation * rig.scale, accuracy: 1 + CGFloat(rig.tolerance), "\(tag) 第 1 行应当紧贴回弹露出的空白")
                XCTAssertFalse(heldBands.contains { $0.key == -2 }, "\(tag) 回弹途中画面发虚（平移没落在整像素上）：\(heldBands.prefix(6))")
                rig.end(velocity: 0)
                try await expectTop("slow-to-top step=\(step)")
            }

            // 慢拖，行号刚到 0 就松手（引擎多半还差半行）：吸附到最近的整行，落在第 0 行还是第 1 行都要在格子上。
            try await jump(rig, toRow: 6)
            try await drag(rig, stepPt: 5, extra: 0) { rig.atTop }
            rig.end(velocity: 0)
            let nearTop = try await settle(rig)
            print(describe("\(tag) release-at-row-0", rig, nearTop))
            assertAtRest(rig, nearTop, "\(tag) release-at-row-0")

            // 甩到顶（带冲出回弹）。
            try await jump(rig, toRow: 40)
            try await fling(rig, leadPt: 6, velocity: 4000)
            try await expectTop("fling-to-top")

            // 到顶后继续下拉再松手。
            rig.begin()
            for _ in 0..<12 { rig.move(9); try await Task.sleep(for: .milliseconds(16)) }
            XCTAssertGreaterThan(rig.translation, 0)
            rig.end(velocity: 0)
            try await expectTop("pull-past-top")

            // 下拉途中手势被系统打断（cancelled）。
            rig.begin()
            for _ in 0..<6 { rig.move(9); try await Task.sleep(for: .milliseconds(16)) }
            rig.cancel()
            try await expectTop("pull-past-top cancelled")

            // 从顶甩回底。
            try await flingToBottom(rig)
            try await expectBottom("fling-to-bottom")

            // 到底后继续上推再松手。
            rig.begin()
            for _ in 0..<12 { rig.move(-9); try await Task.sleep(for: .milliseconds(16)) }
            XCTAssertLessThan(rig.translation, 0)
            rig.end(velocity: 0)
            try await expectBottom("push-past-bottom")

            // 慢拖到底再越过去。
            for step in [-7.0, -(4.0 + 1.0 / 3)] {
                try await jump(rig, toRow: 300 - rig.rows - 5)
                try await drag(rig, stepPt: CGFloat(step), extra: 10) { rig.view.uTermScrollState.overscrollPixels < 0 }
                rig.end(velocity: 0)
                try await expectBottom("slow-to-bottom step=\(step)")
            }

            // 上推到一半（回弹里）来了新输出，松手；回弹途中又来一批。网格位置不能变。
            rig.begin()
            for _ in 0..<10 { rig.move(-9); try await Task.sleep(for: .milliseconds(16)) }
            rig.feed(301...304)
            rig.end(velocity: 0)
            try await Task.sleep(for: .milliseconds(120))
            rig.feed(305...307)
            let grown = try await settle(rig)
            print(describe("\(tag) output-during-bounce", rig, grown))
            assertAtRest(rig, grown, "\(tag) output-during-bounce")
            XCTAssertTrue(rig.atBottom)
            XCTAssertTrue(rig.sameGeometry(grown.bands, bottom.bands), "\(tag) 停在底部时来新输出：网格位置变了")
        }
    }

    /// 到顶 / 到底停稳之后再接着滚：第一步走多少像素，画面就挪多少，不跳。
    func testScrollingAgainFromAnEdgeDoesNotJump() async throws {
        try await runScrollingAgainFromAnEdgeDoesNotJump()
    }

    private func runScrollingAgainFromAnEdgeDoesNotJump() async throws {
        let sizes = try await probeSizes()
        let rig = try await makeRig(size: sizes[0], lines: 300)
        defer { rig.host.close() }
        let cell = rig.cellPx
        // 到顶：慢拖越过去、松手。
        try await jump(rig, toRow: 4)
        try await drag(rig, stepPt: 7, extra: 8) { rig.view.uTermScrollState.overscrollPixels > 0 }
        rig.end(velocity: 0)
        _ = try await settle(rig)
        // 往活动区方向拖 5 px：第 1 行应当正好被切掉 5 px，后面的行整行不变。
        rig.begin()
        rig.move(-5 / rig.scale)
        try await Task.sleep(for: .milliseconds(120))
        var held = try rig.shot()
        print(describe("from-top −5px", rig, held))
        let first = try XCTUnwrap(rig.cleaned(held.bands).first)
        XCTAssertEqual(first.key, 1)
        XCTAssertEqual(first.top, 0, accuracy: rig.tolerance)
        XCTAssertEqual(first.bottom, cell - 5, accuracy: rig.tolerance, "到顶后往下滚 5 px，第一行应当正好少 5 px")
        XCTAssertEqual(rig.cleaned(held.bands).dropFirst().first?.key, 2)
        // 再拖回 5 px 并多拉 9 px：先回到顶，多出来的才进回弹。
        rig.move(5 / rig.scale)
        rig.move(9 / rig.scale)
        try await Task.sleep(for: .milliseconds(120))
        held = try rig.shot()
        print(describe("from-top back +14px", rig, held))
        // 系统路径：UIKit 把 contentOffset 取整到 1/UIScreen.scale pt，Duo 内屏（UIScreen.scale 3、nativeScale 2.807）上会差到 0.47 px。
        XCTAssertEqual(rig.view.uTermScrollState.overscrollPixels, 9, accuracy: rig.tolerance > 0 ? 0.5 : 0.01, "回到顶之后多拉的 9 px 才算回弹")
        XCTAssertEqual(try XCTUnwrap(rig.cleaned(held.bands).first { $0.key >= 0 }).height, cell, accuracy: rig.tolerance, "回弹里第 1 行应当完整")
        rig.end(velocity: 0)
        let top = try await settle(rig)
        assertAtRest(rig, top, "from-top settled")

        // 到底：甩回去。
        try await flingToBottom(rig)
        let bottom = try await settle(rig)
        // 往回滚方向拖 5 px：上面多露出上一行的 5 px，其余整体下移 5 px。
        rig.begin()
        rig.move(5 / rig.scale)
        try await Task.sleep(for: .milliseconds(120))
        held = try rig.shot()
        print(describe("from-bottom +5px", rig, held))
        let firstKey = try XCTUnwrap(bottom.bands.first?.key)
        let peek = try XCTUnwrap(rig.cleaned(held.bands).first)
        XCTAssertEqual(peek.key, (firstKey + 26) % 27, "到底后往上滚 5 px，顶上应当正好露出上一行的 5 px")
        XCTAssertEqual(peek.bottom, 5, accuracy: rig.tolerance)
        XCTAssertEqual(rig.cleaned(held.bands).dropFirst().first?.key, firstKey)
        rig.move(-5 / rig.scale)
        rig.end(velocity: 0)
        let back = try await settle(rig)
        assertAtRest(rig, back, "from-bottom settled")
        XCTAssertTrue(rig.same(back.bands, bottom.bands))
    }

    /// 内容不满一屏、刚好一屏（都没有回滚）、多出一两行：上下拖、甩、松手之后都在格子上；没有回滚时不回弹。
    func testShortContentStaysOnTheGrid() async throws {
        try await runShortContentStaysOnTheGrid()
    }

    private func runShortContentStaysOnTheGrid() async throws {
        let sizes = try await probeSizes()
        let size = sizes[0]
        let probe = try await makeRig(size: size, lines: 1)
        let rows = probe.rows
        probe.host.close()
        for lines in [10, rows - 1, rows, rows + 1, rows + 6] {
            let rig = try await makeRig(size: size, lines: lines)
            defer { rig.host.close() }
            let rest = try await settle(rig)
            print(describe("short(\(lines)) rest", rig, rest))
            assertAtRest(rig, rest, "short(\(lines)) rest")
            for (label, dy) in [("pull", 9.0), ("push", -9.0)] {
                rig.begin()
                for _ in 0..<10 { rig.move(CGFloat(dy)); try await Task.sleep(for: .milliseconds(16)) }
                let held = try rig.shot()
                if !rig.hasScrollback {
                    XCTAssertTrue(rig.isIdentity, "short(\(lines)) \(label)：没有回滚可滚时不该回弹")
                    XCTAssertTrue(rig.same(held.bands, rest.bands), "short(\(lines)) \(label)：没有回滚可滚，画面不该动")
                }
                rig.end(velocity: dy > 0 ? 800 : -800)
                let done = try await settle(rig)
                print(describe("short(\(lines)) \(label) settled", rig, done))
                assertAtRest(rig, done, "short(\(lines)) \(label)")
            }
            // 最后回到底：和一开始一样。
            try await flingToBottom(rig)
            let back = try await settle(rig)
            XCTAssertTrue(rig.same(back.bands, rest.bands), "short(\(lines))：回到底之后和一开始不一样")
        }
    }

    /// 备用屏（less、vim 没抓鼠标时）：拖动由引擎换成方向键发给程序。旧实现把它当「没有回滚、已经到头」吃进了回弹，
    /// 程序一个键也收不到。
    func testAlternateScreenDragReachesTheProgram() async throws {
        try await runAlternateScreenDragReachesTheProgram()
    }

    private func runAlternateScreenDragReachesTheProgram() async throws {
        let sizes = try await probeSizes()
        let rig = try await makeRig(size: sizes[0], lines: 20)
        defer { rig.host.close() }
        rig.host.feedAndWait("\u{1B}[?1049h\u{1B}[2J\u{1B}[Halt screen\r\nline 2\r\n")
        try await Task.sleep(for: .milliseconds(200))
        rig.host.bridge.inputLog = []
        rig.begin()
        for _ in 0..<12 { rig.move(9); try await Task.sleep(for: .milliseconds(16)) }
        rig.end(velocity: 0)
        try await Task.sleep(for: .milliseconds(500))
        let input = (rig.host.bridge.inputLog ?? []).map { String(decoding: $0, as: UTF8.self) }.joined()
        let arrows = input.components(separatedBy: "\u{1B}[A").count - 1
        let expected = Int(12 * 9 * rig.scale) / rig.cellPx
        print("EDGE alt-screen drag 108pt → \(input.debugDescription)（\(arrows) 个上箭头，按行高算 \(expected) 个）")
        XCTAssertTrue(rig.isIdentity, "备用屏里拖动不该回弹")
        XCTAssertGreaterThanOrEqual(arrows, expected - 1, "备用屏里拖动没有变成方向键发给程序")
    }

    /// 惯性途中手指点一下把它停住（不拖）：原地停一下，然后回到整行上。旧实现就停在半行。
    func testTapDuringFlingLandsOnAWholeRow() async throws {
        try await runTapDuringFlingLandsOnAWholeRow()
    }

    private func runTapDuringFlingLandsOnAWholeRow() async throws {
        let sizes = try await probeSizes()
        let rig = try await makeRig(size: sizes[0], lines: 300)
        defer { rig.host.close() }
        for attempt in 0..<5 {
            try await jump(rig, toRow: 150)
            try await fling(rig, leadPt: 6, velocity: 1500)
            try await Task.sleep(for: .milliseconds(150 + attempt * 37))
            XCTAssertTrue(rig.view.uTermScrollState.isGliding, "这时惯性应当还在跑")
            rig.touchDown()
            let stopped = rig.view.uTermScrollState
            let done = try await settle(rig)
            print(describe("tap-stop#\(attempt) stopped-at=\(stopped.row)+\(stopped.fractionPixels)px", rig, done))
            assertAtRest(rig, done, "tap-stop#\(attempt)")
        }
        // 点住之后接着拖：从停住的位置接着走，不先吸附。
        try await jump(rig, toRow: 150)
        try await fling(rig, leadPt: 6, velocity: 1500)
        try await Task.sleep(for: .milliseconds(200))
        rig.touchDown()
        let before = rig.view.uTermScrollState
        rig.begin()
        rig.move(4 / rig.scale)
        let after = rig.view.uTermScrollState
        let cell = rig.cellPx
        // 系统路径上 UIKit 把 contentOffset 取整到 1/UIScreen.scale pt：倍率不是整数的屏（Duo 内屏 2.807，一格 0.94 px）上，
        // 要 4 px 实际走 3.74 px，引擎那边的整像素位移是 3 到 5。整数倍率的屏一像素都不让。
        let slack: Double = rig.tolerance > 0 ? 1 : 0
        XCTAssertEqual(Double(before.row * cell + before.fractionPixels - 4), Double(after.row * cell + after.fractionPixels), accuracy: slack,
                       "点住后接着拖 4 px，视口应当正好走 4 px（\(before) → \(after)）")
        rig.end(velocity: 0)
        assertAtRest(rig, try await settle(rig), "tap-then-drag")
    }

    /// 主线程卡一下（0.1 s 以上）再接着滚：手里的滚动条回报还是卡住之前的旧行号（新的在引擎的信箱里，要主线程 tick 才取出来），
    /// 镜像不能照它改。旧实现只看「停手 0.1 s 以上」就信回报：镜像错开几行，系统路径上这个差还会被当成位移发给引擎，
    /// 画面跳几行（Duo 实测：镜像 97 行、引擎 96 行）。三处都卡一下：拖动途中、松手对齐之前、减速途中。
    func testMainThreadStallDoesNotMoveTheViewport() async throws {
        try await runMainThreadStallDoesNotMoveTheViewport()
    }

    /// 把主线程原地卡住这么久（同步睡，不让出：排在主队列里的 tick、display link 都得等）。
    private func stallMainThread(_ seconds: Double) { Thread.sleep(forTimeInterval: seconds) }

    private func runMainThreadStallDoesNotMoveTheViewport() async throws {
        let sizes = try await probeSizes()
        let rig = try await makeRig(size: sizes[0], lines: 300)
        defer { rig.host.close() }
        let cell = rig.cellPx
        func position() -> Int {
            let state = rig.view.uTermScrollState
            return state.row * cell + state.fractionPixels
        }
        // 系统路径上每一步都可能被 UIKit 取整掉不到 1 px（见上一个用例）。
        let slack: Double = rig.tolerance > 0 ? 1 : 0

        for round in 0..<3 {
            try await jump(rig, toRow: 150)
            rig.begin()
            // 先走一步、等回报到齐：镜像和引擎从同一处出发。
            rig.move(2 / rig.scale)
            try await Task.sleep(for: .milliseconds(200))
            // 连着四步、每步跨一行多，中间不让出主线程：这几步的回报都还没处理。
            for _ in 0..<4 { rig.move(CGFloat(cell + 1) / rig.scale) }
            let before = position()
            stallMainThread(0.15)
            rig.move(4 / rig.scale)
            let after = position()
            XCTAssertEqual(Double(before - after), 4, accuracy: slack,
                           "\(Self.pathLabel) #\(round)：卡了 0.15 s 之后拖 4 px，镜像应当只走 4 px（\(before) → \(after)）")
            // 松手前再卡一次：对齐那一步也不能照旧回报改镜像。
            stallMainThread(0.15)
            rig.end(velocity: 0)
            let shot = try await settle(rig)
            assertAtRest(rig, shot, "\(Self.pathLabel) stall-drag#\(round)")
            // 一共拖了 4 行零 10 px（2 + 4 × (行高 + 1) + 4），对齐后正好退 4 行。引擎多走了几行就说明旧回报被当成了位移。
            XCTAssertEqual(rig.bar.map { Int($0.offset) }, 146,
                           "\(Self.pathLabel) #\(round)：从第 150 行拖 4 行零 10 px 再松手，引擎应当停在第 146 行 — \(describe("stall-drag", rig, shot))")
        }

        // 减速途中卡一下。系统路径上落点是松手时定的（滚动视图坐标），引擎必须停在它对应的那一行。
        for round in 0..<3 {
            try await jump(rig, toRow: 150)
            try await fling(rig, leadPt: 6, velocity: 1500)
            let landing = rig.decelerator.target.map { Int(($0 * rig.scale / CGFloat(cell)).rounded()) }
            try await Task.sleep(for: .milliseconds(120 + round * 30))
            XCTAssertTrue(rig.view.uTermScrollState.isGliding, "这时惯性应当还在跑")
            stallMainThread(0.15)
            let shot = try await settle(rig)
            assertAtRest(rig, shot, "\(Self.pathLabel) stall-glide#\(round)")
            if let landing {
                XCTAssertEqual(rig.bar.map { Int($0.offset) }, landing,
                               "\(Self.pathLabel) #\(round)：减速途中卡了 0.15 s，引擎应当停在松手时定的那一行 — \(describe("stall-glide", rig, shot))")
            }
        }
    }

    /// 滚轮 / 触控板走的是另一个入口（`handleScrollWheelGesture:`，不回弹、不吸附）：它滚过之后镜像也要跟得上，
    /// 接着用手指拖到顶照样落在真正的顶上。
    func testWheelScrollKeepsTheMirrorInStep() async throws {
        try await runWheelScrollKeepsTheMirrorInStep()
    }

    private func runWheelScrollKeepsTheMirrorInStep() async throws {
        let sizes = try await probeSizes()
        let size = sizes[0]
        let top = try await topBaseline(size: size)
        let rig = try await makeRig(size: size, lines: 300)
        defer { rig.host.close() }
        let cell = rig.cellPx
        try await jump(rig, toRow: 9)
        func wheel(_ state: UIGestureRecognizer.State, dy: CGFloat = 0) {
            rig.pan.fakeState = state
            rig.pan.fakeTranslation = CGPoint(x: 0, y: dy)
            _ = rig.view.perform(NSSelectorFromString("handleScrollWheelGesture:"), with: rig.pan)
        }
        // 往回滚方向滚 7 步、每步 4⅓ pt（3x 屏上 13 px，共 91 px = 2 行 + 13 px；别的倍率按实际像素算）。滚轮不吸附，停在半行上。
        let stepPt: CGFloat = 4 + 1.0 / 3
        wheel(.began)
        for _ in 0..<7 { wheel(.changed, dy: stepPt); try await Task.sleep(for: .milliseconds(16)) }
        wheel(.ended)
        try await Task.sleep(for: .milliseconds(400))
        var shot = try rig.shot()
        let state = rig.view.uTermScrollState
        let wheeled = Int((7 * stepPt * rig.scale).rounded())
        print(describe("wheel +\(wheeled)px", rig, shot))
        XCTAssertEqual(state.row * cell + state.fractionPixels, 9 * cell - wheeled, accuracy: 1, "滚轮滚了 \(wheeled) px，镜像应当正好少这么多")
        XCTAssertEqual(state.row, Int(rig.bar?.offset ?? 0), "镜像行号和引擎报的不一致")
        XCTAssertEqual(try XCTUnwrap(rig.cleaned(shot.bands).first).height, cell - state.fractionPixels, accuracy: rig.tolerance, "画面上第一行露出的高度应当等于镜像算出来的")
        // 接着手指慢拖到顶、越过去、松手。
        try await drag(rig, stepPt: 5, extra: 8) { rig.view.uTermScrollState.overscrollPixels > 0 }
        rig.end(velocity: 0)
        shot = try await settle(rig)
        print(describe("wheel then finger to top", rig, shot))
        assertAtRest(rig, shot, "wheel then finger to top")
        XCTAssertTrue(rig.atTop)
        XCTAssertTrue(rig.same(shot.bands, top))
    }

    /// 乱序的拖、甩、点停、越界、打断、来新输出，每次停稳都查一遍：镜像没和引擎走散，画面在格子上。
    func testRandomGesturesStayInStepWithTheEngine() async throws {
        try await runRandomGesturesStayInStepWithTheEngine()
    }

    private func runRandomGesturesStayInStepWithTheEngine() async throws {
        let sizes = try await probeSizes()
        for (round, size) in [sizes[0], sizes[2]].enumerated() {
            let top = try await topBaseline(size: size)
            let rig = try await makeRig(size: size, lines: 160)
            defer { rig.host.close() }
            // 种子里的 +100 是原来系统路径那一半用的，留着：同一串动作，和以前的读数对得上。
            var random = EdgeRandom(seed: 20261109 + UInt64(round) + 100)
            var nextLine = 161
            for step in 0..<28 {
                var label = "fuzz#\(round).\(step) "
                switch random.next(6) {
                case 0, 1:
                    // 拖一段（带小数的步长），松手速度随机。
                    let direction: CGFloat = random.next(2) == 0 ? 1 : -1
                    let stepPt = direction * (CGFloat(random.next(40)) / 3 + 0.4)
                    let count = 4 + random.next(40)
                    let speed: CGFloat = [0, 0, 300, 1500, 4000][random.next(5)]
                    let velocity = speed * (random.next(4) == 0 ? -direction : direction)
                    label += "drag \(String(format: "%.2f", stepPt))pt×\(count) v=\(Int(velocity))"
                    rig.begin()
                    for _ in 0..<count { rig.move(stepPt); try await Task.sleep(for: .milliseconds(12)) }
                    rig.end(velocity: velocity)
                case 2:
                    let velocity = CGFloat(random.next(2) == 0 ? 1 : -1) * CGFloat(600 + random.next(7000))
                    label += "fling v=\(Int(velocity))"
                    try await fling(rig, leadPt: velocity > 0 ? 5 : -5, velocity: velocity)
                case 3:
                    let velocity = CGFloat(random.next(2) == 0 ? 1 : -1) * CGFloat(900 + random.next(3000))
                    let wait = 60 + random.next(300)
                    label += "fling v=\(Int(velocity)) tap@\(wait)ms"
                    try await fling(rig, leadPt: velocity > 0 ? 5 : -5, velocity: velocity)
                    try await Task.sleep(for: .milliseconds(wait))
                    if rig.view.uTermScrollState.isGliding { rig.touchDown() }
                case 4:
                    // 甩出去，途中来新输出。
                    let velocity = CGFloat(random.next(2) == 0 ? 1 : -1) * CGFloat(1500 + random.next(5000))
                    label += "fling v=\(Int(velocity)) + output"
                    try await fling(rig, leadPt: velocity > 0 ? 5 : -5, velocity: velocity)
                    for _ in 0..<3 {
                        try await Task.sleep(for: .milliseconds(40))
                        rig.feed(nextLine...(nextLine + 1)); nextLine += 2
                    }
                default:
                    // 拖到一半被打断。
                    let stepPt = CGFloat(random.next(2) == 0 ? 1 : -1) * (CGFloat(random.next(30)) / 3 + 1)
                    label += "drag \(String(format: "%.2f", stepPt))pt×9 cancelled"
                    rig.begin()
                    for _ in 0..<9 { rig.move(stepPt); try await Task.sleep(for: .milliseconds(12)) }
                    rig.cancel()
                }
                let shot = try await settle(rig)
                print(describe(label, rig, shot))
                assertAtRest(rig, shot, label)
                if rig.atTop { XCTAssertTrue(rig.same(shot.bands, top), "\(label)：到顶的画面和从没滚动过的不一样") }
                if rig.atBottom {
                    let last = try XCTUnwrap(rig.cleaned(shot.bands).last)
                    XCTAssertEqual(last.key, -1, "\(label)：到底之后最下面应当是提示符那一行和余量（底色）")
                    XCTAssertEqual(last.top, (rig.rows - 1) * rig.cellPx, accuracy: rig.tolerance, "\(label)：到底之后提示符不在最后一行")
                }
            }
        }
    }

    /// 输出一直在涨的时候从底部一路甩到顶（滚动条回报最不准的时候）：停下来、输出也停了之后，照样在格子上、能到真正的顶。
    func testFlingToTopWhileOutputStreams() async throws {
        try await runFlingToTopWhileOutputStreams()
    }

    private func runFlingToTopWhileOutputStreams() async throws {
        let sizes = try await probeSizes()
        let size = sizes[0]
        let top = try await topBaseline(size: size)
        let rig = try await makeRig(size: size, lines: 120)
        defer { rig.host.close() }
        let cols = rig.cols
        let bridge = rig.host.bridge
        let feeder = Task.detached {
            for number in stride(from: 121, to: 121 + 240, by: 2) {
                bridge.feed(Data(("\r\u{1B}[2K" + GhosttyScrollEdgeTests.corpus(number...(number + 1), cols: cols, hidesCursor: false)).utf8))
                try? await Task.sleep(for: .milliseconds(8))
            }
        }
        // 输出开始之后立刻往上甩，连甩到顶。
        try await Task.sleep(for: .milliseconds(60))
        for _ in 0..<12 {
            try await fling(rig, leadPt: 5, velocity: 9000)
            try await Task.sleep(for: .milliseconds(350))
            if rig.view.uTermScrollState.row == 0, !rig.view.uTermScrollState.isGliding { break }
        }
        await feeder.value
        rig.host.bridge.session.waitForPendingOutput()
        var shot = try await settle(rig)
        print(describe("stream fling-to-top", rig, shot))
        assertAtRest(rig, shot, "stream fling-to-top")
        // 输出停了之后再拉一把：必须能到真正的顶，画面和从没滚动过的一样。
        for _ in 0..<6 where !(rig.atTop && rig.view.uTermScrollState.isAtRest) {
            try await fling(rig, leadPt: 5, velocity: 9000)
            _ = try await settle(rig)
        }
        try await drag(rig, stepPt: 6, extra: 6) { rig.view.uTermScrollState.overscrollPixels > 0 }
        rig.end(velocity: 0)
        shot = try await settle(rig)
        print(describe("stream then top", rig, shot))
        assertAtRest(rig, shot, "stream then top")
        XCTAssertTrue(rig.atTop)
        XCTAssertTrue(rig.same(shot.bands, top))
    }

    /// 系统滚动的接线：有回滚、普通屏时单指拖动归 UIScrollView 的 pan（自写的 pan 让位）；没有回滚、备用屏、
    /// 有选区时归自写路径。滚动视图本身不接触摸、读屏看不到。
    ///（原来还核一条「自写物理开关打开时也归自写路径」：那个开关已经从本地包里拿掉，这一句随之去掉。）
    func testSystemScrollWiring() async throws {
        let sizes = try await probeSizes()
        let rig = try await makeRig(size: sizes[0], lines: 300)
        defer { rig.host.close() }
        let scrollView = try XCTUnwrap(rig.scrollView, "终端视图里没有借来的 UIScrollView")
        XCTAssertTrue(rig.view.gestureRecognizers?.contains { $0 === scrollView.panGestureRecognizer } == true,
                      "UIScrollView 的 pan 应当挂在终端视图上")
        XCTAssertNil(scrollView.hitTest(CGPoint(x: 10, y: 10), with: nil), "滚动视图不该接触摸（点按、长按、选区手柄要落到终端视图上）")
        XCTAssertTrue(scrollView.accessibilityElementsHidden)
        XCTAssertFalse(scrollView.showsVerticalScrollIndicator)
        XCTAssertEqual(scrollView.contentInsetAdjustmentBehavior, .never)
        XCTAssertTrue(rig.view.uTermSystemPanWouldBegin, "有回滚的普通屏：单指拖动应当归系统滚动")
        // contentSize = 视图高 + 回滚行数 × 行高；停在底部时 contentOffset 在最底下。
        let bar = try XCTUnwrap(rig.bar)
        XCTAssertEqual(Double(scrollView.contentSize.height),
                       Double(scrollView.bounds.height) + Double(bar.total - bar.len) * Double(rig.cellPx) / Double(rig.scale), accuracy: 0.01)
        XCTAssertEqual(Double(scrollView.contentOffset.y * rig.scale), Double(Int(bar.total - bar.len) * rig.cellPx), accuracy: 0.51)

        rig.host.feedAndWait("\u{1B}[?1049h\u{1B}[2J\u{1B}[Halt screen\r\n")
        try await Task.sleep(for: .milliseconds(300))
        XCTAssertFalse(rig.view.uTermSystemPanWouldBegin, "备用屏没有回滚：拖动要交给引擎换成方向键，不该归系统滚动")
        rig.host.feedAndWait("\u{1B}[?1049l")
        try await Task.sleep(for: .milliseconds(300))
        XCTAssertTrue(rig.view.uTermSystemPanWouldBegin, "回到普通屏又该归系统滚动")

        let short = try await makeRig(size: sizes[0], lines: 5)
        defer { short.host.close() }
        XCTAssertFalse(short.view.uTermSystemPanWouldBegin, "内容不满一屏、没有回滚：不该归系统滚动")
    }

    /// 又宽又矮的那一档（Duo 内屏横放）：甩到顶、甩回底、来输出，停稳后都在格子上。
    ///
    /// 原来叫 `testAllFourSwitchCombinations`，按两个开关（「渲染不同步」× 自写滚动物理）的四种组合各跑一遍。两个开关都已经
    /// 从本地包里拿掉，只剩 iOS 现在的这一种：引擎 wakeup 在主线程同步重画（`UTermScrollTrace.wakeupDrawsSynchronously`）
    /// + 系统滚动。断言原样。
    func testFlingBothWaysThenOutputLandsOnTheGrid() async throws {
        let sizes = try await probeSizes()
        XCTAssertTrue(UTermScrollTrace.wakeupDrawsSynchronously, "iOS 上引擎 wakeup 应当在主线程同步重画（这条用例的读数按它验收的）")
        let top = try await topBaseline(size: sizes[2])
        let rig = try await makeRig(size: sizes[2], lines: 200)
        defer { rig.host.close() }
        let label = "combo 同步重画+\(Self.pathLabel)"
        let bottom = try await settle(rig)
        for _ in 0..<8 where !(rig.atTop && rig.view.uTermScrollState.isAtRest) {
            try await fling(rig, leadPt: 6, velocity: 9000)
            _ = try await settle(rig)
        }
        var shot = try await settle(rig)
        print(describe("\(label) top", rig, shot))
        assertAtRest(rig, shot, "\(label) top")
        XCTAssertTrue(rig.same(shot.bands, top), "\(label)：到顶的画面不对")
        try await flingToBottom(rig)
        rig.feed(201...203)
        shot = try await settle(rig)
        print(describe("\(label) bottom+output", rig, shot))
        assertAtRest(rig, shot, "\(label) bottom+output")
        XCTAssertTrue(rig.atBottom, "\(label)：没回到底")
        XCTAssertTrue(rig.sameGeometry(shot.bands, bottom.bands), "\(label)：回到底之后网格位置变了")
    }

    /// 这一组里随两个开关一起去掉的那几半，留一条跳过的用例把账记在测试结果里：
    /// - 每条用例的 `.own` 那一半（自写的单指拖动 / 惯性 / 回弹 / 吸附，在有回滚的普通屏上）：
    ///   `testEdgesSettleOnTheSameGridAsNeverScrolled`、`testScrollingAgainFromAnEdgeDoesNotJump`、`testShortContentStaysOnTheGrid`、
    ///   `testAlternateScreenDragReachesTheProgram`、`testTapDuringFlingLandsOnAWholeRow`、`testMainThreadStallDoesNotMoveTheViewport`、
    ///   `testWheelScrollKeepsTheMirrorInStep`、`testRandomGesturesStayInStepWithTheEngine`、`testFlingToTopWhileOutputStreams`；
    /// - `testSystemScrollWiring` 里「自写物理开关打开时不归系统滚动」那一句；
    /// - 四种组合里的另外三种（渲染不同步 + 系统、同步重画 + 自写、渲染不同步 + 自写）。
    ///
    /// 自写的滚动物理（到顶 / 到底的橡皮筋与弹簧、落点惯性、自写的吸附）已经从本地包里整套删掉。留下的自写拖动只在这几种
    /// 情况才走：程序抓着鼠标（`GhosttyCapturedMomentumTests`）、备用屏、没有回滚（这两种本组用例按真实规则照样落到它上面，
    /// 见 `Rig.begin()`）、选区拖动、双指。它们的位移原样交给引擎，没有回弹、没有落点。
    func testOwnPhysicsAndFreeRendererVariantsAreGone() throws {
        throw XCTSkip("自写单指滚动物理（.own）连同它的开关、以及「渲染不同步」的 A/B 开关都已从本地包里删掉："
            + "单指滚回滚区恒走系统 UIScrollView，引擎 wakeup 在 iOS 上恒为主线程同步重画。"
            + "自写拖动只剩程序抓鼠标 / 备用屏 / 没有回滚 / 选区拖动 / 双指时才走；这一组只留系统滚动 + 同步重画那一半。")
    }

    /// 网格不能整除视图高度时余量放哪边。钉死现状：网格从视图顶边排起，余量全在底下、不到一行。
    ///（原来这条同时把换引擎之前那种终端视图的排法打印出来对照、不设断言，用例名也带着「对照旧引擎」；
    /// 旧引擎已经从 App 里拿掉，对照那一半去掉了，名字跟着改。）
    func testLeftoverStaysBelowTheGrid() async throws {
        let sizes = try await probeSizes()
        for size in [sizes[0], sizes[2]] {
            let tag = "\(Int(size.width))x\(Int(size.height))"
            for (label, lines) in [("short", 10), ("scrollback", 300)] {
                let rig = try await makeRig(size: size, lines: lines)
                let shot = try await settle(rig)
                let cell = rig.cellPx, height = shot.image.height
                let rowsTop = shot.bands.first { $0.key >= 0 }?.top ?? -1
                print("EDGE layout ghostty \(tag) \(label): cellPx=\(cell) rows=\(rig.rows) gridTop=\(rowsTop)px leftover=\(height - rig.rows * cell)px（全在底下） head=\(shot.bands.prefix(2)) tail=\(shot.bands.suffix(2))")
                XCTAssertEqual(rowsTop, 0, "Ghostty 的网格应当从视图顶边排起")
                XCTAssertLessThan(height - rig.rows * cell, cell, "余量应当不到一行")
                rig.host.close()
            }
        }
    }
}

/// 按 UIKit 会做的事驱动 GhosttyKit 借来的 UIScrollView（单指滚回滚区的那条系统滚动路径）。
///
/// UIKit 的跟踪、减速、回弹没法伪造触摸来驱动，这里直接操作滚动视图并调它的代理方法：拖动 = 改 contentOffset
///（didScroll 照常来）、松手 = willEndDragging 算落点 + didEndDragging、减速和回弹由 `EdgeDecelerator` 每帧写 contentOffset
/// 代替（UIKit 减速也是这样写的），走完报 didEndDecelerating。量不到 UIKit 的物理本身，量的是 GhosttyKit 这一侧：
/// contentOffset → 引擎位置的映射、越界平移、到头、落点取整与对齐。
@MainActor
final class EdgeSystemFinger {
    let view: MGhosttyTerminalView
    let scrollView: UIScrollView
    let decelerator = EdgeDecelerator()

    /// 甩动的减速走多久（秒）：三次缓出的初速度 = 3 × 距离 ÷ 时长，距离 = 速度 × 0.998 / 0.002 ms（`.normal` 减速率的投影），
    /// 让初速度等于抬手速度的时长就是这个数，和速度无关。
    nonisolated static let flingSeconds = 3 * 0.998 / 0.002 / 1000

    init(view: MGhosttyTerminalView) throws {
        self.view = view
        scrollView = try XCTUnwrap(view.uTermSystemScrollView, "终端视图里没有借来的 UIScrollView")
    }

    var maxOffset: CGFloat { max(0, scrollView.contentSize.height - scrollView.bounds.height) }
    var isOutOfRange: Bool { scrollView.contentOffset.y < 0 || scrollView.contentOffset.y > maxOffset }

    /// 手指按下并拖起来。上一次松手的减速 / 回弹到此为止（UIKit 在按下时也是这样停的）。
    func begin() {
        if decelerator.isRunning { touchDown() }
        view.scrollViewWillBeginDragging(scrollView)
    }

    /// 手指挪 `dy` pt（正 = 往下，内容跟着下移）。
    func move(_ dy: CGFloat) {
        scrollView.contentOffset.y -= dy
    }

    /// 抬手，`velocity` pt/s（正 = 往下甩）。有速度或停在界外就「减速」`seconds` 秒到落点（落点由 GhosttyKit 取整到行）。
    func end(velocity: CGFloat, seconds: Double = 0.35) {
        let current = scrollView.contentOffset.y
        let outOfRange = isOutOfRange
        // UIKit 的投影（.normal 减速率，每毫秒 0.998）：落点 = 现在的位置 − 速度 × 0.998 / 0.002，再夹进范围。
        let projected = velocity / 1000 * 0.998 / 0.002
        var target = CGPoint(x: 0, y: min(max(0, current - projected), maxOffset))
        view.scrollViewWillEndDragging(scrollView, withVelocity: CGPoint(x: 0, y: -velocity / 1000), targetContentOffset: &target)
        let decelerates = abs(velocity) > 0 || outOfRange
        view.scrollViewDidEndDragging(scrollView, willDecelerate: decelerates)
        if decelerates {
            decelerator.run(scrollView, to: target.y, seconds: seconds) { [view, scrollView] in view.scrollViewDidEndDecelerating(scrollView) }
        }
    }

    /// 手势被系统打断。
    func cancel() {
        let outOfRange = isOutOfRange
        view.scrollViewDidEndDragging(scrollView, willDecelerate: outOfRange)
        if outOfRange {
            decelerator.run(scrollView, to: min(max(0, scrollView.contentOffset.y), maxOffset)) { [view, scrollView] in
                view.scrollViewDidEndDecelerating(scrollView)
            }
        }
    }

    /// 减速途中手指落下（不拖）。
    func touchDown() {
        decelerator.stop()
        view.uTermTouchDownDuringMomentum()
    }
}

/// 松手后的减速 / 回弹：display link 每帧按三次缓出写 contentOffset，`seconds`（默认 0.35 s）走完调 `done`。
/// 新的一次会顶掉上一次（手指又按下来时测试会先 begin()，那时它也该停：`stop()`）。
@MainActor
final class EdgeDecelerator: NSObject {
    /// 这一次减速的每一帧：回调的时刻、这一帧瞄准的 vsync、写 contentOffset 花了多久（GhosttyKit 的 didScroll 就在里面跑），
    /// 以及这一帧想写的位置和写完读回来的位置（pt）。两个位置不一样：UIKit 把 contentOffset 取整到 1/UIScreen.scale pt。
    struct Frame {
        let time: Double
        let target: Double
        let writeMS: Double
        let requested: CGFloat
        let offset: CGFloat
    }

    /// 这一次减速开始前的位置（pt，已经是 UIKit 取整过的）。
    private(set) var origin: CGFloat = 0

    private(set) var frames: [Frame] = []
    private var link: CADisplayLink?
    private weak var scrollView: UIScrollView?
    private var from: CGFloat = 0
    private var to: CGFloat = 0
    private var start: CFTimeInterval = 0
    private var seconds = 0.35
    private var done: (() -> Void)?

    func run(_ scrollView: UIScrollView, to target: CGFloat, seconds: Double = 0.35, done: @escaping () -> Void) {
        stop()
        self.scrollView = scrollView
        from = scrollView.contentOffset.y
        origin = from
        to = target
        start = 0
        self.seconds = seconds
        self.done = done
        frames.removeAll()
        let link = CADisplayLink(target: self, selector: #selector(frame(_:)))
        link.preferredFrameRateRange = CAFrameRateRange(minimum: 80, maximum: 120, preferred: 120)
        link.add(to: .main, forMode: .common)
        self.link = link
    }

    var isRunning: Bool { link != nil }
    /// 正在往哪走（pt）；没在跑时是 nil。
    var target: CGFloat? { link == nil ? nil : to }

    func stop() {
        link?.invalidate()
        link = nil
        done = nil
    }

    @objc private func frame(_ link: CADisplayLink) {
        guard let scrollView else { stop(); return }
        if start == 0 { start = link.timestamp }
        let u = min(1, CGFloat(link.targetTimestamp - start) / CGFloat(seconds))
        let began = CACurrentMediaTime()
        let requested = from + (to - from) * (1 - pow(1 - u, 3))
        scrollView.contentOffset.y = requested
        frames.append(Frame(time: began, target: link.targetTimestamp, writeMS: (CACurrentMediaTime() - began) * 1000,
                            requested: requested, offset: scrollView.contentOffset.y))
        if u >= 1 {
            let finish = done
            stop()
            finish?()
        }
    }
}

/// 固定种子的随机数（SplitMix64），乱序用例每次跑同一串动作。
struct EdgeRandom {
    private var state: UInt64
    init(seed: UInt64) { state = seed }

    mutating func next(_ bound: Int) -> Int {
        state &+= 0x9E37_79B9_7F4A_7C15
        var z = state
        z = (z ^ (z >> 30)) &* 0xBF58_476D_1CE4_E5B9
        z = (z ^ (z >> 27)) &* 0x94D0_49BB_1331_11EB
        return Int((z ^ (z >> 31)) % UInt64(bound))
    }
}

/// 能由测试摆布状态、位移、速度的拖动手势（只给 `handleTouchScrollGesture:` 读）。
final class EdgeFakePan: UIPanGestureRecognizer {
    var fakeState: UIGestureRecognizer.State = .possible
    var fakeTranslation: CGPoint = .zero
    var fakeVelocity: CGPoint = .zero
    var fakeLocation: CGPoint = .zero

    override var state: UIGestureRecognizer.State {
        get { fakeState }
        set { fakeState = newValue }
    }
    override var numberOfTouches: Int { 1 }
    override func translation(in view: UIView?) -> CGPoint { fakeTranslation }
    override func setTranslation(_ translation: CGPoint, in view: UIView?) { fakeTranslation = translation }
    override func velocity(in view: UIView?) -> CGPoint { fakeVelocity }
    override func location(in view: UIView?) -> CGPoint { fakeLocation }
}
