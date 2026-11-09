import GhosttyTerminal
import QuartzCore
import SwiftTerm
import UIKit
import XCTest
@testable import uTermMobile

/// 「Ghostty 试用」滚到回滚顶部 / 活动区底部之后，画面有没有回到和「从没滚动过」完全相同的像素位置。
///
/// 起因：user 在 iPhone Duo 上滚到顶之后，第一行上方多出一截空白和一条细线、最后一行被切。根因是本地滚动补丁
/// 拿滚动条行号判「到顶」：行号到 0 时引擎还差半行（0023 的小数行偏移），那时就进回弹，真正的第一行永远拉不下来，
/// 松手后停在「第一行被切、底下多露半行」的位置上。修法与镜像的规则见 `UITerminalView+Scroll.swift`。
///
/// 量法：每一行铺一条整行宽的底色（27 种循环，相邻行必不同），截整扇窗口的合成结果（回弹平移的是宿主层，
/// 只有窗口截图带得上），读一列像素还原出「每个像素行属于第几行文字」。网格原点、相邻行露出的残条、
/// 最后一行被切、回弹没归零都是同一张表上的事，差 1 px 也看得见。
/// 手势走和手指相同的入口：伪造 `UIPanGestureRecognizer` 直接调 GhosttyKit 的 `handleTouchScrollGesture:`，
/// 每个 changed 之间隔一帧（真手指也是一帧一个事件，引擎的滚动条回报要一帧才到，旧 bug 正出在这一帧上）。
@MainActor
final class GhosttyScrollEdgeTests: XCTestCase {
    /// 三种视图：竖屏手机（网格余 6 px）、行高整除（余 0）、Duo 内屏横放那种又宽又矮的（余 30 px）。
    private static let sizes = [CGSize(width: 440, height: 600), CGSize(width: 440, height: 598), CGSize(width: 890, height: 504)]

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

    /// 一行带底色的编号行，空格垫到 `cols - 1` 列（不靠「擦到行尾带底色」，SwiftTerm 那边也能铺满）。
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
    nonisolated static func bands(of cg: CGImage) throws -> [Band] {
        let width = cg.width, height = cg.height
        var pixels = [UInt8](repeating: 0, count: width * height * 4)
        let context = try XCTUnwrap(CGContext(data: &pixels, width: width, height: height, bitsPerComponent: 8,
                                              bytesPerRow: width * 4, space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                              bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
        context.draw(cg, in: CGRect(x: 0, y: 0, width: width, height: height))
        let x = width * 6 / 10
        var bands: [Band] = []
        for y in 0..<height {
            let i = (y * width + x) * 4
            let key = classify(r: Int(pixels[i]), g: Int(pixels[i + 1]), b: Int(pixels[i + 2]))
            if let last = bands.last, last.key == key {
                bands[bands.count - 1].bottom = y + 1
            } else {
                bands.append(Band(key: key, top: y, bottom: y + 1))
            }
        }
        return bands
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

        init(host: GhosttyProbeHost, scale: CGFloat, cellPx: Int) {
            self.host = host; self.scale = scale; self.cellPx = cellPx
            rows = host.grid.rows; cols = host.grid.cols
        }

        var view: MGhosttyTerminalView { host.view }
        var bar: TerminalScrollbar? { host.scrollbar }
        var barText: String { bar.map { "\($0.offset)/\($0.total)/\($0.len)" } ?? "-" }
        var translation: CGFloat { view.layer.sublayerTransform.m42 }
        var isIdentity: Bool { CATransform3DIsIdentity(view.layer.sublayerTransform) }
        var atTop: Bool { bar.map { $0.offset == 0 } ?? true }
        var atBottom: Bool { bar.map { $0.offset + $0.len >= $0.total } ?? true }
        var hasScrollback: Bool { bar.map { $0.total > $0.len } ?? false }

        func send(_ state: UIGestureRecognizer.State, dy: CGFloat = 0, velocity: CGFloat = 0) {
            pan.fakeState = state
            pan.fakeTranslation = CGPoint(x: 0, y: dy)
            pan.fakeVelocity = CGPoint(x: 0, y: velocity)
            hasScrolled = true
            _ = view.perform(NSSelectorFromString("handleTouchScrollGesture:"), with: pan)
        }

        /// 在提示符那一行上接着输出几行（再跟一个新的提示符）。
        func feed(_ range: ClosedRange<Int>) {
            host.feedAndWait("\r\u{1B}[2K" + GhosttyScrollEdgeTests.corpus(range, cols: cols, hidesCursor: false))
        }

        func shot() throws -> Shot {
            let image = try GhosttyScrollEdgeTests.windowImage(host.window)
            return Shot(bands: try GhosttyScrollEdgeTests.bands(of: image), image: image)
        }
    }

    /// `size` 的终端；`feed` 拿到行列数后给出要喂的内容。等它画稳。
    private func makeRig(size: CGSize, feed: (_ rows: Int, _ cols: Int) -> String) async throws -> Rig {
        let host = try GhosttyProbeHost(size: size)
        // 配色跟着视图的日夜走；钉成深色，读图时底色和 27 档行色才分得开（模拟器默认浅色）。
        host.window.overrideUserInterfaceStyle = .dark
        try await host.waitUntilReady()
        XCTAssertTrue(host.view.responds(to: NSSelectorFromString("handleTouchScrollGesture:")), "GhosttyKit 的拖动处理 selector 变了")
        host.feedAndWait(feed(host.grid.rows, host.grid.cols))
        try await Task.sleep(for: .milliseconds(300))
        let scale = host.view.window?.screen.nativeScale ?? 3
        let cell = try XCTUnwrap(host.view.uTermCellPixels)
        let rig = Rig(host: host, scale: scale, cellPx: Int(cell.height))
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
        return "EDGE \(label): bar=\(rig.barText) model=\(state.row)+\(state.fractionPixels)px over=\(Int(state.overscrollPixels)) "
            + "ty=\(String(format: "%.2f", rig.translation))pt bands=\(shot.bands.count) head=\(head) tail=\(tail)"
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
        let cell = rig.cellPx
        let gridBottom = rig.rows * cell
        XCTAssertFalse(shot.bands.contains { $0.key == -2 }, "有混色残条（相邻行露出一丝，或画面停在半个像素上）— \(context)", file: file, line: line)
        for band in shot.bands where band.key >= 0 {
            XCTAssertEqual(band.top % cell, 0, "行带 \(band) 的上沿不在格子线上 — \(context)", file: file, line: line)
            // 最后一行可以连着网格下面那条余量（底色顺延）；别的行必须正好一行高。
            if band.bottom < gridBottom || band.bottom % cell == 0 {
                XCTAssertEqual(band.height, cell, "行带 \(band) 不是一行高（被切或露出半行）— \(context)", file: file, line: line)
            } else {
                XCTAssertEqual(band.top, gridBottom - cell, "只有最后一行能伸进余量 — \(context)", file: file, line: line)
                XCTAssertEqual(band.bottom, shot.image.height, "最后一行的底色顺延应当铺满余量 — \(context)", file: file, line: line)
            }
        }
        for (upper, lower) in zip(shot.bands, shot.bands.dropFirst()) where upper.key >= 0 && lower.key >= 0 {
            XCTAssertEqual(lower.key, (upper.key + 1) % 27, "行号不连续：\(upper) 后面是 \(lower) — \(context)", file: file, line: line)
        }
    }

    // MARK: 动作

    /// 手指慢拖：每帧 `stepPt`，直到 `until` 成立后再拖 `extra` 步（越过边缘进回弹），最多 `limit` 步。不松手。
    private func drag(_ rig: Rig, stepPt: CGFloat, extra: Int, limit: Int = 900, until: () -> Bool) async throws {
        rig.send(.began)
        var remaining: Int?
        for _ in 0..<limit {
            rig.send(.changed, dy: stepPt)
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
        rig.send(.began)
        rig.send(.changed, dy: leadPt)
        try await Task.sleep(for: .milliseconds(16))
        rig.send(.ended, velocity: velocity)
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
        for size in Self.sizes {
            let top = try await topBaseline(size: size)
            let rig = try await makeRig(size: size, lines: 300)
            defer { rig.host.close() }
            let tag = "\(Int(size.width))x\(Int(size.height))"
            let bottom = try await settle(rig)
            print("EDGE rig \(tag) scale=\(rig.scale) cellPx=\(rig.cellPx) grid=\(rig.cols)x\(rig.rows) leftoverPx=\(bottom.image.height - rig.rows * rig.cellPx)")
            print(describe("\(tag) never-scrolled", rig, bottom))
            assertAtRest(rig, bottom, "\(tag) never-scrolled")
            XCTAssertTrue(rig.atBottom)

            func expectTop(_ label: String) async throws {
                let shot = try await settle(rig)
                print(describe("\(tag) \(label)", rig, shot))
                assertAtRest(rig, shot, "\(tag) \(label)")
                XCTAssertTrue(rig.atTop, "\(tag) \(label)：没到顶 bar=\(rig.barText)")
                XCTAssertEqual(shot.bands, top, "\(tag) \(label)：到顶之后和「只有一屏、从没滚动过」的画面不一样")
                if shot.bands != top { attach(shot, "\(tag)-\(label)") }
            }
            func expectBottom(_ label: String) async throws {
                let shot = try await settle(rig)
                print(describe("\(tag) \(label)", rig, shot))
                assertAtRest(rig, shot, "\(tag) \(label)")
                XCTAssertTrue(rig.atBottom, "\(tag) \(label)：没回到底 bar=\(rig.barText)")
                XCTAssertEqual(shot.bands, bottom.bands, "\(tag) \(label)：回到底之后和滚动之前的画面不一样")
                if shot.bands != bottom.bands { attach(shot, "\(tag)-\(label)") }
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
                let firstRow = try XCTUnwrap(held.bands.first { $0.key >= 0 })
                XCTAssertEqual(firstRow.key, 1, "\(tag) 回弹里最上面一条应当是第 1 行，实际 \(firstRow)（上一行露出一丝？）")
                XCTAssertEqual(firstRow.height, rig.cellPx, "\(tag) 回弹里第 1 行被切了：\(firstRow)")
                XCTAssertEqual(CGFloat(firstRow.top), rig.translation * rig.scale, accuracy: 1, "\(tag) 第 1 行应当紧贴回弹露出的空白")
                XCTAssertFalse(held.bands.contains { $0.key == -2 }, "\(tag) 回弹途中画面发虚（平移没落在整像素上）：\(held.bands.prefix(6))")
                rig.send(.ended, velocity: 0)
                try await expectTop("slow-to-top step=\(step)")
            }

            // 慢拖，行号刚到 0 就松手（引擎多半还差半行）：吸附到最近的整行，落在第 0 行还是第 1 行都要在格子上。
            try await jump(rig, toRow: 6)
            try await drag(rig, stepPt: 5, extra: 0) { rig.atTop }
            rig.send(.ended, velocity: 0)
            let nearTop = try await settle(rig)
            print(describe("\(tag) release-at-row-0", rig, nearTop))
            assertAtRest(rig, nearTop, "\(tag) release-at-row-0")

            // 甩到顶（带冲出回弹）。
            try await jump(rig, toRow: 40)
            try await fling(rig, leadPt: 6, velocity: 4000)
            try await expectTop("fling-to-top")

            // 到顶后继续下拉再松手。
            rig.send(.began)
            for _ in 0..<12 { rig.send(.changed, dy: 9); try await Task.sleep(for: .milliseconds(16)) }
            XCTAssertGreaterThan(rig.translation, 0)
            rig.send(.ended, velocity: 0)
            try await expectTop("pull-past-top")

            // 下拉途中手势被系统打断（cancelled）。
            rig.send(.began)
            for _ in 0..<6 { rig.send(.changed, dy: 9); try await Task.sleep(for: .milliseconds(16)) }
            rig.send(.cancelled)
            try await expectTop("pull-past-top cancelled")

            // 从顶甩回底。
            try await flingToBottom(rig)
            try await expectBottom("fling-to-bottom")

            // 到底后继续上推再松手。
            rig.send(.began)
            for _ in 0..<12 { rig.send(.changed, dy: -9); try await Task.sleep(for: .milliseconds(16)) }
            XCTAssertLessThan(rig.translation, 0)
            rig.send(.ended, velocity: 0)
            try await expectBottom("push-past-bottom")

            // 慢拖到底再越过去。
            for step in [-7.0, -(4.0 + 1.0 / 3)] {
                try await jump(rig, toRow: 300 - rig.rows - 5)
                try await drag(rig, stepPt: CGFloat(step), extra: 10) { rig.view.uTermScrollState.overscrollPixels < 0 }
                rig.send(.ended, velocity: 0)
                try await expectBottom("slow-to-bottom step=\(step)")
            }

            // 上推到一半（回弹里）来了新输出，松手；回弹途中又来一批。网格位置不能变。
            rig.send(.began)
            for _ in 0..<10 { rig.send(.changed, dy: -9); try await Task.sleep(for: .milliseconds(16)) }
            rig.feed(301...304)
            rig.send(.ended, velocity: 0)
            try await Task.sleep(for: .milliseconds(120))
            rig.feed(305...307)
            let grown = try await settle(rig)
            print(describe("\(tag) output-during-bounce", rig, grown))
            assertAtRest(rig, grown, "\(tag) output-during-bounce")
            XCTAssertTrue(rig.atBottom)
            XCTAssertEqual(grown.bands.map { [$0.top, $0.bottom] }, bottom.bands.map { [$0.top, $0.bottom] },
                           "\(tag) 停在底部时来新输出：网格位置变了")
        }
    }

    /// 到顶 / 到底停稳之后再接着滚：第一步走多少像素，画面就挪多少，不跳。
    func testScrollingAgainFromAnEdgeDoesNotJump() async throws {
        let rig = try await makeRig(size: Self.sizes[0], lines: 300)
        defer { rig.host.close() }
        let cell = rig.cellPx
        // 到顶：慢拖越过去、松手。
        try await jump(rig, toRow: 4)
        try await drag(rig, stepPt: 7, extra: 8) { rig.view.uTermScrollState.overscrollPixels > 0 }
        rig.send(.ended, velocity: 0)
        _ = try await settle(rig)
        // 往活动区方向拖 5 px：第 1 行应当正好被切掉 5 px，后面的行整行不变。
        rig.send(.began)
        rig.send(.changed, dy: -5 / rig.scale)
        try await Task.sleep(for: .milliseconds(120))
        var held = try rig.shot()
        print(describe("from-top −5px", rig, held))
        XCTAssertEqual(held.bands.first, Band(key: 1, top: 0, bottom: cell - 5), "到顶后往下滚 5 px，第一行应当正好少 5 px")
        XCTAssertEqual(held.bands.dropFirst().first, Band(key: 2, top: cell - 5, bottom: 2 * cell - 5))
        // 再拖回 5 px 并多拉 9 px：先回到顶，多出来的才进回弹。
        rig.send(.changed, dy: 5 / rig.scale)
        rig.send(.changed, dy: 9 / rig.scale)
        try await Task.sleep(for: .milliseconds(120))
        held = try rig.shot()
        print(describe("from-top back +14px", rig, held))
        XCTAssertEqual(rig.view.uTermScrollState.overscrollPixels, 9, "回到顶之后多拉的 9 px 才算回弹")
        XCTAssertEqual(held.bands.first { $0.key >= 0 }?.height, cell, "回弹里第 1 行应当完整")
        rig.send(.ended, velocity: 0)
        let top = try await settle(rig)
        assertAtRest(rig, top, "from-top settled")

        // 到底：甩回去。
        try await flingToBottom(rig)
        let bottom = try await settle(rig)
        // 往回滚方向拖 5 px：上面多露出上一行的 5 px，其余整体下移 5 px。
        rig.send(.began)
        rig.send(.changed, dy: 5 / rig.scale)
        try await Task.sleep(for: .milliseconds(120))
        held = try rig.shot()
        print(describe("from-bottom +5px", rig, held))
        let firstKey = try XCTUnwrap(bottom.bands.first?.key)
        XCTAssertEqual(held.bands.first, Band(key: (firstKey + 26) % 27, top: 0, bottom: 5), "到底后往上滚 5 px，顶上应当正好露出上一行的 5 px")
        XCTAssertEqual(held.bands.dropFirst().first, Band(key: firstKey, top: 5, bottom: 5 + cell))
        rig.send(.changed, dy: -5 / rig.scale)
        rig.send(.ended, velocity: 0)
        let back = try await settle(rig)
        assertAtRest(rig, back, "from-bottom settled")
        XCTAssertEqual(back.bands, bottom.bands)
    }

    /// 内容不满一屏、刚好一屏（都没有回滚）、多出一两行：上下拖、甩、松手之后都在格子上；没有回滚时不回弹。
    func testShortContentStaysOnTheGrid() async throws {
        let size = Self.sizes[0]
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
                rig.send(.began)
                for _ in 0..<10 { rig.send(.changed, dy: CGFloat(dy)); try await Task.sleep(for: .milliseconds(16)) }
                let held = try rig.shot()
                if !rig.hasScrollback {
                    XCTAssertTrue(rig.isIdentity, "short(\(lines)) \(label)：没有回滚可滚时不该回弹")
                    XCTAssertEqual(held.bands, rest.bands, "short(\(lines)) \(label)：没有回滚可滚，画面不该动")
                }
                rig.send(.ended, velocity: dy > 0 ? 800 : -800)
                let done = try await settle(rig)
                print(describe("short(\(lines)) \(label) settled", rig, done))
                assertAtRest(rig, done, "short(\(lines)) \(label)")
            }
            // 最后回到底：和一开始一样。
            try await flingToBottom(rig)
            let back = try await settle(rig)
            XCTAssertEqual(back.bands, rest.bands, "short(\(lines))：回到底之后和一开始不一样")
        }
    }

    /// 备用屏（less、vim 没抓鼠标时）：拖动由引擎换成方向键发给程序。旧实现把它当「没有回滚、已经到头」吃进了回弹，
    /// 程序一个键也收不到。
    func testAlternateScreenDragReachesTheProgram() async throws {
        let rig = try await makeRig(size: Self.sizes[0], lines: 20)
        defer { rig.host.close() }
        rig.host.feedAndWait("\u{1B}[?1049h\u{1B}[2J\u{1B}[Halt screen\r\nline 2\r\n")
        try await Task.sleep(for: .milliseconds(200))
        rig.host.bridge.inputLog = []
        rig.send(.began)
        for _ in 0..<12 { rig.send(.changed, dy: 9); try await Task.sleep(for: .milliseconds(16)) }
        rig.send(.ended, velocity: 0)
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
        let rig = try await makeRig(size: Self.sizes[0], lines: 300)
        defer { rig.host.close() }
        for attempt in 0..<5 {
            try await jump(rig, toRow: 150)
            try await fling(rig, leadPt: 6, velocity: 1500)
            try await Task.sleep(for: .milliseconds(150 + attempt * 37))
            XCTAssertTrue(rig.view.uTermScrollState.isGliding, "这时惯性应当还在跑")
            rig.view.uTermTouchDownDuringMomentum()
            let stopped = rig.view.uTermScrollState
            let done = try await settle(rig)
            print(describe("tap-stop#\(attempt) stopped-at=\(stopped.row)+\(stopped.fractionPixels)px", rig, done))
            assertAtRest(rig, done, "tap-stop#\(attempt)")
        }
        // 点住之后接着拖：从停住的位置接着走，不先吸附。
        try await jump(rig, toRow: 150)
        try await fling(rig, leadPt: 6, velocity: 1500)
        try await Task.sleep(for: .milliseconds(200))
        rig.view.uTermTouchDownDuringMomentum()
        let before = rig.view.uTermScrollState
        rig.send(.began)
        rig.send(.changed, dy: 4 / rig.scale)
        let after = rig.view.uTermScrollState
        let cell = rig.cellPx
        XCTAssertEqual(before.row * cell + before.fractionPixels - 4, after.row * cell + after.fractionPixels,
                       "点住后接着拖 4 px，视口应当正好走 4 px（\(before) → \(after)）")
        rig.send(.ended, velocity: 0)
        assertAtRest(rig, try await settle(rig), "tap-then-drag")
    }

    /// 滚轮 / 触控板走的是另一个入口（`handleScrollWheelGesture:`，不回弹、不吸附）：它滚过之后镜像也要跟得上，
    /// 接着用手指拖到顶照样落在真正的顶上。
    func testWheelScrollKeepsTheMirrorInStep() async throws {
        let size = Self.sizes[0]
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
        // 往回滚方向滚 7 步、每步 4⅓ pt（13 px）= 91 px = 2 行 + 13 px。滚轮不吸附，停在半行上。
        wheel(.began)
        for _ in 0..<7 { wheel(.changed, dy: 4 + 1.0 / 3); try await Task.sleep(for: .milliseconds(16)) }
        wheel(.ended)
        try await Task.sleep(for: .milliseconds(400))
        var shot = try rig.shot()
        let state = rig.view.uTermScrollState
        print(describe("wheel +91px", rig, shot))
        XCTAssertEqual(state.row * cell + state.fractionPixels, 9 * cell - 91, "滚轮滚了 91 px，镜像应当正好少 91 px")
        XCTAssertEqual(state.row, Int(rig.bar?.offset ?? 0), "镜像行号和引擎报的不一致")
        XCTAssertEqual(shot.bands.first?.height, cell - state.fractionPixels, "画面上第一行露出的高度应当等于镜像算出来的")
        // 接着手指慢拖到顶、越过去、松手。
        try await drag(rig, stepPt: 5, extra: 8) { rig.view.uTermScrollState.overscrollPixels > 0 }
        rig.send(.ended, velocity: 0)
        shot = try await settle(rig)
        print(describe("wheel then finger to top", rig, shot))
        assertAtRest(rig, shot, "wheel then finger to top")
        XCTAssertTrue(rig.atTop)
        XCTAssertEqual(shot.bands, top)
    }

    /// 乱序的拖、甩、点停、越界、打断、来新输出，每次停稳都查一遍：镜像没和引擎走散，画面在格子上。
    func testRandomGesturesStayInStepWithTheEngine() async throws {
        for (round, size) in [Self.sizes[0], Self.sizes[2]].enumerated() {
            let top = try await topBaseline(size: size)
            let rig = try await makeRig(size: size, lines: 160)
            defer { rig.host.close() }
            var random = EdgeRandom(seed: 20261109 + UInt64(round))
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
                    rig.send(.began)
                    for _ in 0..<count { rig.send(.changed, dy: stepPt); try await Task.sleep(for: .milliseconds(12)) }
                    rig.send(.ended, velocity: velocity)
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
                    if rig.view.uTermScrollState.isGliding { rig.view.uTermTouchDownDuringMomentum() }
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
                    rig.send(.began)
                    for _ in 0..<9 { rig.send(.changed, dy: stepPt); try await Task.sleep(for: .milliseconds(12)) }
                    rig.send(.cancelled)
                }
                let shot = try await settle(rig)
                print(describe(label, rig, shot))
                assertAtRest(rig, shot, label)
                if rig.atTop { XCTAssertEqual(shot.bands, top, "\(label)：到顶的画面和从没滚动过的不一样") }
                if rig.atBottom {
                    XCTAssertEqual(shot.bands.last?.key, -1, "\(label)：到底之后最下面应当是提示符那一行和余量（底色）")
                    XCTAssertEqual(shot.bands.last?.top, (rig.rows - 1) * rig.cellPx, "\(label)：到底之后提示符不在最后一行")
                }
            }
        }
    }

    /// 输出一直在涨的时候从底部一路甩到顶（滚动条回报最不准的时候）：停下来、输出也停了之后，照样在格子上、能到真正的顶。
    func testFlingToTopWhileOutputStreams() async throws {
        let size = Self.sizes[0]
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
        rig.send(.ended, velocity: 0)
        shot = try await settle(rig)
        print(describe("stream then top", rig, shot))
        assertAtRest(rig, shot, "stream then top")
        XCTAssertTrue(rig.atTop)
        XCTAssertEqual(shot.bands, top)
    }

    /// 网格不能整除视图高度时余量放哪边：Ghostty 试用和 SwiftTerm 标签各自的排法（只记录，不强求一致）。
    /// Ghostty 这边钉死现状：网格从视图顶边排起，余量全在底下。
    func testLeftoverPlacementVersusSwiftTerm() async throws {
        for size in [Self.sizes[0], Self.sizes[2]] {
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

                let swiftTerm = try SwiftTermProbeHost(size: size)
                swiftTerm.view.feed(text: Self.corpus(1...lines, cols: swiftTerm.grid.cols))
                try await Task.sleep(for: .milliseconds(600))
                let image = try Self.windowImage(swiftTerm.window, afterScreenUpdates: true)
                let bands = try Self.bands(of: image)
                let rowBands = bands.filter { $0.key >= 0 }
                print("EDGE layout swiftterm \(tag) \(label): rows=\(swiftTerm.grid.rows) rowPx≈\(rowBands.dropFirst().first?.height ?? 0) "
                    + "firstRowTop=\(rowBands.first?.top ?? -1)px lastRowBottom=\(rowBands.last?.bottom ?? -1)px viewPx=\(image.height) "
                    + "contentOffset=\(swiftTerm.view.contentOffset.y)pt contentSize=\(swiftTerm.view.contentSize.height)pt "
                    + "head=\(bands.prefix(3)) tail=\(bands.suffix(3))")
                let attachment = XCTAttachment(image: UIImage(cgImage: image))
                attachment.name = "swiftterm-\(tag)-\(label)"; attachment.lifetime = .keepAlways
                add(attachment)
                // 滚到顶再看一次。
                if lines > swiftTerm.grid.rows {
                    swiftTerm.view.setContentOffset(.zero, animated: false)
                    try await Task.sleep(for: .milliseconds(400))
                    let topBands = try Self.bands(of: Self.windowImage(swiftTerm.window, afterScreenUpdates: true))
                    let topRows = topBands.filter { $0.key >= 0 }
                    print("EDGE layout swiftterm \(tag) at-top: firstRowTop=\(topRows.first?.top ?? -1)px lastRowBottom=\(topRows.last?.bottom ?? -1)px "
                        + "head=\(topBands.prefix(3)) tail=\(topBands.suffix(3))")
                }
                swiftTerm.close()
            }
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
