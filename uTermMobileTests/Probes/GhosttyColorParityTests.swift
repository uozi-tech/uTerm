import GhosttyTerminal
import UIKit
import XCTest
@testable import uTermMobile

/// M16 第二轮：同一段语料同时喂 SwiftTerm 和 GhosttyKit，逐格取字形的前景色（与段底色）比对，列出不一致的格子。
///
/// 取色：每个用例写 `M#W` 三格；格子位置不靠估算，先用真彩红底空格在 (1,0)/(1,56)/(25,0) 标定格宽格高与原点。
/// 不用第 0 行：iOS 26 的 UIScrollView 顶部有 scroll edge effect，SwiftTerm（UIScrollView）第一行会被压暗。
/// 每格取离底色最远的那 8% 像素的中位数当前景（抗锯齿边缘不进来），格子左上角内缩 1px 的像素当底色。
/// 截图都按 sRGB（`preferredRange = .standard`）：SwiftTerm 用 `layer.render`（它在 `draw(_:)` 里画，CPU 栅格，
/// `drawHierarchy` 截它会糊），Ghostty 用 `snapshotImage()`（IOSurface 只有 `drawHierarchy` 截得到）。
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
    /// 和第 0 列里最下面那一簇（第 25 行，在所有用例行之下）。SwiftTerm 顶部两行被 scroll edge effect 压暗，红阈值放宽。
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

    func testCellColorsMatchSwiftTerm() async throws {
        let size = CGSize(width: 440, height: 600)
        let controller = GhosttyTerminalBridge.makeController(fontSize: GhosttyTerminalBridge.ghosttyFontSize(points: 11))
        var totalMismatch = 0
        for dark in [true, false] {
            let scheme = TerminalColorScheme.resolve(dark: dark)
            let format = UIGraphicsImageRendererFormat()
            format.preferredRange = .standard
            format.scale = 3

            // SwiftTerm
            let stWindow = try makeSpikeWindow(size: size)
            stWindow.overrideUserInterfaceStyle = dark ? .dark : .light
            let stView = MTerminalView(frame: .zero, font: .monospacedSystemFont(ofSize: 11, weight: .regular))
            stView.contentInsetAdjustmentBehavior = .never
            TerminalAppearance.applyColors(to: stView, scheme: scheme)
            stView.backgroundColor = scheme.backgroundColor
            let stContainer = MTerminalContainerView(terminalView: stView, fontSize: 11)
            stContainer.frame = CGRect(origin: .zero, size: size)
            stWindow.addSubview(stContainer)
            stContainer.layoutIfNeeded()
            stView.feed(text: Self.corpus)
            stView.flushPendingDisplay()
            try await Task.sleep(for: .milliseconds(300))
            let stImage = UIGraphicsImageRenderer(bounds: stView.bounds, format: format).image { ctx in
                stView.layer.render(in: ctx.cgContext)
            }

            // Ghostty
            let ghWindow = try makeSpikeWindow(size: size)
            ghWindow.overrideUserInterfaceStyle = dark ? .dark : .light
            let bridge = GhosttyTerminalBridge(controller: controller, frame: CGRect(origin: .zero, size: size))
            ghWindow.addSubview(bridge.view)
            let ready = await MobileFakeTerminal.waitUntil(timeout: .seconds(5)) { bridge.view.surface != nil && bridge.grid != nil }
            XCTAssertTrue(ready)
            // 第一次报上来的网格可能还是建 surface 那一刻的尺寸，等它停稳再喂，不然内容会按旧宽度折行。
            var lastGrid = "\(String(describing: bridge.grid))", stableSince = CACurrentMediaTime()
            while CACurrentMediaTime() - stableSince < 0.4 {
                try await Task.sleep(for: .milliseconds(20))
                let now = "\(String(describing: bridge.grid))"
                if now != lastGrid { lastGrid = now; stableSince = CACurrentMediaTime() }
            }
            print("PARITY \(dark ? "dark" : "light") grid swiftterm=\(stView.getTerminal().cols)x\(stView.getTerminal().rows) ghostty=\(lastGrid)")
            bridge.feed(Data(Self.corpus.utf8))
            bridge.session.waitForPendingOutput()
            try await Task.sleep(for: .milliseconds(600))
            let ghImage = UIGraphicsImageRenderer(bounds: bridge.view.bounds, format: format).image { _ in
                bridge.view.drawHierarchy(in: bridge.view.bounds, afterScreenUpdates: false)
            }
            for (name, image) in [("swiftterm", stImage), ("ghostty", ghImage)] {
                let attachment = XCTAttachment(image: image)
                attachment.name = "parity-\(dark ? "dark" : "light")-\(name)"
                attachment.lifetime = .keepAlways
                add(attachment)
            }

            let st = Raster(try XCTUnwrap(stImage.cgImage)), gh = Raster(try XCTUnwrap(ghImage.cgImage))
            let stGeo = try XCTUnwrap(calibrate(st), "SwiftTerm 标定失败"), ghGeo = try XCTUnwrap(calibrate(gh), "Ghostty 标定失败")
            print(String(format: "PARITY %@ geometry swiftterm cell=%.2fx%.2f origin=(%.0f,%.0f) | ghostty cell=%.2fx%.2f origin=(%.0f,%.0f)",
                         dark ? "dark" : "light", stGeo.w, stGeo.h, stGeo.x0, stGeo.y0, ghGeo.w, ghGeo.h, ghGeo.x0, ghGeo.y0))
            var mismatches = 0
            for (i, c) in Self.cases.enumerated() {
                let p = Self.position(i)
                let a = sample(st, geo: stGeo, row: p.row, col: p.col)
                let b = sample(gh, geo: ghGeo, row: p.row, col: p.col)
                let dFg = max(abs(a.fg.0 - b.fg.0), abs(a.fg.1 - b.fg.1), abs(a.fg.2 - b.fg.2))
                let dBg = max(abs(a.bg.0 - b.bg.0), abs(a.bg.1 - b.bg.1), abs(a.bg.2 - b.bg.2))
                let bad = dFg > 24 || dBg > 8
                if bad { mismatches += 1 }
                print("PARITY \(dark ? "dark" : "light") \(bad ? "DIFF" : "same") \(c.name.padding(toLength: 22, withPad: " ", startingAt: 0)) "
                      + "fg st=\(Self.hex(a.fg)) gh=\(Self.hex(b.fg)) Δ\(dFg) | bg st=\(Self.hex(a.bg)) gh=\(Self.hex(b.bg)) Δ\(dBg)")
            }
            print("PARITY \(dark ? "dark" : "light") summary mismatches=\(mismatches)/\(Self.cases.count)")
            totalMismatch += mismatches
            stContainer.removeFromSuperview(); bridge.view.removeFromSuperview()
            stWindow.isHidden = true; ghWindow.isHidden = true
        }
        print("PARITY total mismatches=\(totalMismatch)")
    }
}
