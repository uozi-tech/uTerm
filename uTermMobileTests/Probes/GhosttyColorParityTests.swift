import GhosttyTerminal
import UIKit
import XCTest
@testable import uTermMobile

/// M16 第二轮的取色探针：一段覆盖 16 色 / 粗体 / dim / 256 色 / 真彩 / 反显的语料喂给 GhosttyKit，逐格取字形的前景色
///（与段底色），打印成 `PARITY …` 行。
///
/// 来历：换引擎之前同一段语料同时喂两个引擎、逐格比对，列出不一致的格子（着色规则——`palette-generate`、
/// `bold-color`、`alpha-blending`、`faint-opacity`、最低对比度——就是照那份清单定下来的，结论在 docs/ghostty-eval/）。
/// 旧引擎的视图类删掉之后没有对照组了，这里只留 Ghostty 这一列的读数；能直接从 uTerm 配色（`TerminalColorScheme`）
/// 算出期望值的两项——默认底色、默认前景——和配色比，其余的格子只列颜色（要比就和文档里上一轮的读数比）。
///
/// 取色：每个用例写 `M#W` 三格；格子位置不靠估算，先用真彩红底空格在 (1,0)/(1,56)/(25,0) 标定格宽格高与原点。
/// 不用第 0 行（留着和历史读数同一套坐标；当时是因为旧引擎的 UIScrollView 顶部有 scroll edge effect）。
/// 每格取离底色最远的那 8% 像素的中位数当前景（抗锯齿边缘不进来），格子左上角内缩 1px 的像素当底色。
/// 截图按 sRGB（`preferredRange = .standard`），用 `drawHierarchy`（IOSurface 只有它截得到）。
/// 挂在 `UTERM_MEASURE=1` 后面。
@MainActor
final class GhosttyColorParityTests: XCTestCase {
    override func setUp() async throws {
        guard ProcessInfo.processInfo.environment["UTERM_MEASURE"] == "1" else {
            throw XCTSkip("测量门探针：设 UTERM_MEASURE=1 才跑")
        }
    }

    private struct Case { let name: String; let sgr: String }

    private static let cases: [Case] = {
        var out: [Case] = []
        let names = ["black", "red", "green", "yellow", "blue", "magenta", "cyan", "white"]
        for (style, prefix) in [("", ""), ("bold ", "1;"), ("dim ", "2;")] {
            for (i, n) in names.enumerated() { out.append(Case(name: "\(style)\(n)", sgr: "\(prefix)\(30 + i)")) }
            for (i, n) in names.enumerated() { out.append(Case(name: "\(style)bright-\(n)", sgr: "\(prefix)\(90 + i)")) }
        }
        for (style, sgr) in [("default", "0"), ("bold default", "1"), ("dim default", "2")] { out.append(Case(name: style, sgr: sgr)) }
        for fg in [103, 39, 76, 178, 196, 244, 254] {
            out.append(Case(name: "fg\(fg)", sgr: "38;5;\(fg)"))
            for bg in [236, 238, 240] { out.append(Case(name: "fg\(fg)/bg\(bg)", sgr: "38;5;\(fg);48;5;\(bg)")) }
        }
        out.append(Case(name: "bold fg39/bg240", sgr: "1;38;5;39;48;5;240"))
        for (name, rgb) in [("tc-claude", "215;119;87"), ("tc-8787af", "135;135;175"), ("tc-646464", "100;100;100")] {
            out.append(Case(name: name, sgr: "38;2;\(rgb)"))
            out.append(Case(name: "\(name)/bg3a3a3a", sgr: "38;2;\(rgb);48;2;58;58;58"))
        }
        out.append(Case(name: "reverse", sgr: "7"))
        out.append(Case(name: "reverse red", sgr: "7;31"))
        out.append(Case(name: "reverse fg103/bg236", sgr: "7;38;5;103;48;5;236"))
        return out
    }()

    private static let perRow = 7
    private static func position(_ index: Int) -> (row: Int, col: Int) { (3 + index / perRow, (index % perRow) * 8) }

    private static var corpus: String {
        var s = "\u{1B}[?25l\u{1B}[2J"
        let red = "\u{1B}[48;2;255;0;0m \u{1B}[0m"
        s += "\u{1B}[2;1H" + red + "\u{1B}[2;57H" + red + "\u{1B}[26;1H" + red
        for (i, c) in cases.enumerated() {
            let p = position(i)
            s += "\u{1B}[\(p.row + 1);\(p.col + 1)H\u{1B}[\(c.sgr)mM#W\u{1B}[0m"
        }
        return s
    }

    private struct Raster {
        let pixels: [UInt8]
        let width: Int
        let height: Int
        init(_ image: CGImage) {
            width = image.width; height = image.height
            var buffer = [UInt8](repeating: 0, count: width * height * 4)
            let context = CGContext(data: &buffer, width: width, height: height, bitsPerComponent: 8, bytesPerRow: width * 4,
                                    space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                    bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
            context.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
            pixels = buffer
        }
        func at(_ x: Int, _ y: Int) -> (Int, Int, Int) {
            let i = (min(max(y, 0), height - 1) * width + min(max(x, 0), width - 1)) * 4
            return (Int(pixels[i]), Int(pixels[i + 1]), Int(pixels[i + 2]))
        }
    }

    /// 由红底标定格出格子几何（像素）。纯红前景字（fg196）也是红的，所以只认：最上面那一簇（标定行）、
    /// 和第 0 列里最下面那一簇（第 25 行，在所有用例行之下）。
    private func calibrate(_ r: Raster) -> (x0: Double, y0: Double, w: Double, h: Double)? {
        func isRed(_ p: (Int, Int, Int)) -> Bool { p.0 > 120 && p.1 < 40 && p.2 < 40 }
        var reds: [(Int, Int)] = []
        for y in 0..<r.height { for x in 0..<r.width where isRed(r.at(x, y)) { reds.append((x, y)) } }
        guard let y1 = reds.map(\.1).min() else { return nil }
        let top = reds.filter { $0.1 < y1 + 20 }
        let x0 = Double(top.map(\.0).min() ?? 0)
        guard let rightStart = top.filter({ Double($0.0) > x0 + 100 }).map(\.0).min() else { return nil }
        let column0 = reds.filter { $0.0 < 10 }
        guard let maxY = column0.map(\.1).max(),
              let bottomStart = column0.filter({ $0.1 > maxY - 60 }).map(\.1).min() else { return nil }
        let h = Double(bottomStart - y1) / 24
        return (x0, Double(y1) - h, (Double(rightStart) - x0) / 56, h)
    }

    private func sample(_ r: Raster, geo: (x0: Double, y0: Double, w: Double, h: Double), row: Int, col: Int)
        -> (fg: (Int, Int, Int), bg: (Int, Int, Int)) {
        let x0 = Int(geo.x0 + Double(col) * geo.w), y0 = Int(geo.y0 + Double(row) * geo.h)
        let bg = r.at(x0 + 1, y0 + 1)
        guard geo.w >= 4, geo.h >= 4 else { return (bg, bg) }
        var px: [(d: Int, c: (Int, Int, Int))] = []
        for y in (y0 + 1)..<(y0 + Int(geo.h) - 1) {
            for x in (x0 + 1)..<(x0 + Int(geo.w * 3) - 1) {
                let c = r.at(x, y)
                px.append((abs(c.0 - bg.0) + abs(c.1 - bg.1) + abs(c.2 - bg.2), c))
            }
        }
        px.sort { $0.d > $1.d }
        let top = px.prefix(max(3, px.count * 8 / 100)).map(\.c)
        func median(_ v: [Int]) -> Int { v.sorted()[v.count / 2] }
        return ((median(top.map(\.0)), median(top.map(\.1)), median(top.map(\.2))), bg)
    }

    private static func hex(_ c: (Int, Int, Int)) -> String { String(format: "#%02X%02X%02X", c.0, c.1, c.2) }

    /// 逐格读出 Ghostty 画出来的颜色；默认底色 / 默认前景和 uTerm 的配色比。
    func testCellColorsReadout() async throws {
        let size = CGSize(width: 440, height: 600)
        let controller = GhosttyTerminalBridge.makeController(fontSize: GhosttyTerminalBridge.ghosttyFontSize(points: 11))
        var totalMismatch = 0
        for dark in [true, false] {
            let mode = dark ? "dark" : "light"
            let scheme = TerminalColorScheme.resolve(dark: dark)
            let format = UIGraphicsImageRendererFormat()
            format.preferredRange = .standard
            format.scale = 3

            let window = try makeSpikeWindow(size: size)
            window.overrideUserInterfaceStyle = dark ? .dark : .light
            let bridge = GhosttyTerminalBridge(controller: controller, frame: CGRect(origin: .zero, size: size))
            window.addSubview(bridge.view)
            // 等 surface 建好、网格到位、画面接上实时字节：在那之前喂的只进影子，要等回放才上屏。
            let ready = await MobileFakeTerminal.waitUntil(timeout: .seconds(5)) {
                bridge.view.surface != nil && bridge.grid != nil && bridge.isSurfaceReady && bridge.router.isFeedingSurface
            }
            XCTAssertTrue(ready, "\(mode)：surface 没就绪")
            // 第一次报上来的网格可能还是建 surface 那一刻的尺寸，等它停稳再喂，不然内容会按旧宽度折行。
            var lastGrid = "\(String(describing: bridge.grid))", stableSince = CACurrentMediaTime()
            while CACurrentMediaTime() - stableSince < 0.4 {
                try await Task.sleep(for: .milliseconds(20))
                let now = "\(String(describing: bridge.grid))"
                if now != lastGrid { lastGrid = now; stableSince = CACurrentMediaTime() }
            }
            print("PARITY \(mode) grid ghostty=\(lastGrid)")
            bridge.feed(Data(Self.corpus.utf8))
            bridge.session.waitForPendingOutput()
            try await Task.sleep(for: .milliseconds(600))
            let image = UIGraphicsImageRenderer(bounds: bridge.view.bounds, format: format).image { _ in
                bridge.view.drawHierarchy(in: bridge.view.bounds, afterScreenUpdates: false)
            }
            let attachment = XCTAttachment(image: image)
            attachment.name = "parity-\(mode)-ghostty"
            attachment.lifetime = .keepAlways
            add(attachment)

            let raster = Raster(try XCTUnwrap(image.cgImage))
            let geo = try XCTUnwrap(calibrate(raster), "\(mode)：标定失败")
            print(String(format: "PARITY %@ geometry ghostty cell=%.2fx%.2f origin=(%.0f,%.0f)", mode, geo.w, geo.h, geo.x0, geo.y0))
            // 期望值：能直接从配色读出来的只有默认底色和默认前景。
            func triple(_ color: UIColor) -> (Int, Int, Int) {
                let rgb = GhosttyPalette.rgb(color)
                return (Int(rgb.0), Int(rgb.1), Int(rgb.2))
            }
            func distance(_ a: (Int, Int, Int), _ b: (Int, Int, Int)) -> Int { max(abs(a.0 - b.0), abs(a.1 - b.1), abs(a.2 - b.2)) }
            let wantBg = triple(scheme.backgroundColor), wantFg = triple(scheme.foregroundColor)
            print("PARITY \(mode) scheme bg=\(Self.hex(wantBg)) fg=\(Self.hex(wantFg))")
            var mismatches = 0
            for (i, c) in Self.cases.enumerated() {
                let p = Self.position(i)
                let got = sample(raster, geo: geo, row: p.row, col: p.col)
                // 没写底色、没反显的用例：段底色就是终端底色。`default`：前景就是终端前景。
                let plainBackground = !c.sgr.contains("48;") && !c.sgr.split(separator: ";").contains("7")
                var notes: [String] = []
                if plainBackground {
                    let d = distance(got.bg, wantBg)
                    notes.append("bg-vs-scheme Δ\(d)")
                    if d > 8 { mismatches += 1; notes.append("DIFF") }
                }
                if c.name == "default" {
                    let d = distance(got.fg, wantFg)
                    notes.append("fg-vs-scheme Δ\(d)")
                    if d > 24 { mismatches += 1; notes.append("DIFF") }
                }
                print("PARITY \(mode) \(c.name.padding(toLength: 22, withPad: " ", startingAt: 0)) "
                      + "fg=\(Self.hex(got.fg)) bg=\(Self.hex(got.bg)) \(notes.joined(separator: " "))")
            }
            print("PARITY \(mode) summary scheme-mismatches=\(mismatches)")
            totalMismatch += mismatches
            bridge.view.removeFromSuperview()
            window.isHidden = true
        }
        print("PARITY total scheme-mismatches=\(totalMismatch)")
    }
}
