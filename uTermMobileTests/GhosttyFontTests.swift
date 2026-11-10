import CoreText
import GhosttyTerminal
import UIKit
import XCTest
@testable import uTermMobile

/// 终端字体：回退链是「系统等宽 → Menlo → 苹方」（`GhosttyTerminalBridge.fontFamilies`）。读画面的墨量来核：
/// - 拉丁字符是系统等宽、常规字重（不是 Menlo，也不是 Light）；
/// - 汉字落在苹方的常规字重；
/// - 同一份配置新建两个 controller 各渲染一遍，中文行的墨量一致（靠自动回退时字重每次运行不一定一样）；
/// - 全角左引号「的墨迹在它那两格的右半边（落到苹方的 UI Text 变体时会贴左）。
///
/// 墨量 = 一块区域里每个像素比底色暗了多少的总和（浅色配色、白底深字）。和 CoreText 直接画的参照比的是总量，
/// 不比形状：两边的抗锯齿不一样，逐像素对不上，但同一个字体同一个字号的总量接近，不同字重差两成以上。
@MainActor
final class GhosttyFontTests: XCTestCase {
    private static let latin = "MWmw@#8Bg0Oo1lI"
    private static let han = "漏洞视图停留继续流动默认"
    private static let points: CGFloat = 11

    private struct Rendering {
        let image: CGImage
        /// 图里每点多少像素。
        let scale: CGFloat
        /// 格子尺寸（点）。
        let cell: CGSize
        /// 截图里底色的亮度（浅色下整张截图不是纯白）。
        let paper: Double

        /// 第 `row` 行、从 `column` 起 `columns` 格的墨量。
        func ink(row: Int, column: Int, columns: Int) -> Double {
            let rect = CGRect(x: CGFloat(column) * cell.width * scale, y: CGFloat(row) * cell.height * scale,
                              width: CGFloat(columns) * cell.width * scale, height: cell.height * scale).integral
            return GhosttyFontTests.ink(of: image, in: rect, paper: paper)
        }
    }

    /// 一块区域里比底色暗的总量（按底色归一，1 = 一个全黑像素）。
    private nonisolated static func ink(of image: CGImage, in rect: CGRect, paper: Double) -> Double {
        let width = Int(rect.width), height = Int(rect.height)
        guard width > 0, height > 0 else { return 0 }
        var pixels = [UInt8](repeating: 0, count: width * height)
        let context = CGContext(data: &pixels, width: width, height: height, bitsPerComponent: 8, bytesPerRow: width,
                                space: CGColorSpaceCreateDeviceGray(), bitmapInfo: CGImageAlphaInfo.none.rawValue)!
        // CGContext 原点在左下：把图挪到让 rect 落在位图里。
        context.draw(image, in: CGRect(x: -rect.minX, y: -(CGFloat(image.height) - rect.maxY),
                                       width: CGFloat(image.width), height: CGFloat(image.height)))
        return pixels.reduce(0.0) { $0 + max(0, paper - Double($1)) / paper }
    }

    private static func paperLevel(of image: CGImage) -> Double {
        // 右下角一小块（没有字）。
        var pixels = [UInt8](repeating: 0, count: 16)
        let context = CGContext(data: &pixels, width: 4, height: 4, bitsPerComponent: 8, bytesPerRow: 4,
                                space: CGColorSpaceCreateDeviceGray(), bitmapInfo: CGImageAlphaInfo.none.rawValue)!
        context.draw(image, in: CGRect(x: -CGFloat(image.width - 4), y: 0, width: CGFloat(image.width), height: CGFloat(image.height)))
        return Double(pixels.reduce(0) { $0 + Int($1) }) / 16
    }

    /// 新建一个 controller（一份全新的字体缓存）渲染三行：拉丁、汉字、带全角引号的一行。光标藏掉。
    /// `overrides`：在生产配置上再改几项（做对照用）。
    private func render(
        _ overrides: @escaping (inout GhosttyTerminal.TerminalConfiguration.Builder) -> Void = { _ in }
    ) async throws -> Rendering {
        let size = CGSize(width: 393, height: 200)
        // 这个类排在最前面跑时宿主 App 的 scene 可能还没连上。
        _ = await MobileFakeTerminal.waitUntil(timeout: .seconds(10)) {
            UIApplication.shared.connectedScenes.contains { $0 is UIWindowScene }
        }
        let window = try makeSpikeWindow(size: size)
        window.overrideUserInterfaceStyle = .light
        defer { window.isHidden = true }
        let controller = GhosttyTerminalBridge.makeController(
            fontSize: GhosttyTerminalBridge.ghosttyFontSize(points: Self.points), overrides: overrides)
        let bridge = GhosttyTerminalBridge(controller: controller, frame: CGRect(origin: .zero, size: size))
        window.addSubview(bridge.view)
        defer { bridge.view.removeFromSuperview() }
        let ready = await MobileFakeTerminal.waitUntil(timeout: .seconds(5)) {
            bridge.isSurfaceReady && bridge.outputPump.isFeedingSurface
        }
        XCTAssertTrue(ready, "surface 没就绪")
        GhosttyPresentLog.installIfPossible()
        // 每轮第一次渲染常常还没出帧：等喂进去之后确实交了帧、再多等一会儿让字形图集补齐，才读画面。
        GhosttyPresentLog.reset()
        bridge.feed(Data("\u{1B}[?25l\u{1B}[2J\u{1B}[H\(Self.latin)\r\n\(Self.han)\r\n「引号」\r\n".utf8))
        bridge.session.waitForPendingOutput()
        let presented = await MobileFakeTerminal.waitUntil(timeout: .seconds(5)) { !GhosttyPresentLog.read().times.isEmpty }
        XCTAssertTrue(presented, "喂完之后没出帧")
        try await Task.sleep(for: .milliseconds(600))
        XCTAssertNil(controller.lastConfigurationIssue, "配置有问题：\(controller.lastConfigurationIssue ?? "")")

        let renderer = UIGraphicsImageRenderer(bounds: window.bounds)
        let image = renderer.image { _ in window.drawHierarchy(in: window.bounds, afterScreenUpdates: true) }
        let cg = try XCTUnwrap(image.cgImage)
        let scale = CGFloat(cg.width) / size.width
        let cellPixels = try XCTUnwrap(bridge.view.uTermCellPixels)
        let cell = CGSize(width: CGFloat(cellPixels.width) / scale, height: CGFloat(cellPixels.height) / scale)
        return Rendering(image: cg, scale: scale, cell: cell, paper: Self.paperLevel(of: cg))
    }

    private var latinColumns: Int { Self.latin.count }
    private var hanColumns: Int { Self.han.count * 2 }

    /// 只留给定的字体族（`font-family = ""` 清空回退链，再逐个加）。
    private func only(_ families: [String]) -> (inout GhosttyTerminal.TerminalConfiguration.Builder) -> Void {
        { builder in
            builder.withCustom("font-family", "")
            for family in families { builder.withFontFamily(family) }
        }
    }

    /// 拉丁字符落在系统等宽、汉字落在苹方。不和别的渲染器比（UIKit 画同一个字体的墨量比 Ghostty 多两成多，
    /// 两边抗锯齿不同），而是在 Ghostty 里换配置做对照：只留某一个字体族时，对应那一行的墨量和生产配置一模一样；
    /// 换成回退链里的下一个，墨量就变。
    func testLatinComesFromSystemMonospacedAndHanFromPingFang() async throws {
        let production = try await render()
        let systemOnly = try await render(only([GhosttyTerminalBridge.fontFamilies[0]]))
        let menloOnly = try await render(only(["Menlo"]))
        let pingFangOnly = try await render(only(["PingFang SC"]))
        XCTAssertEqual(GhosttyTerminalBridge.fontFamilies, [GhosttyTerminalBridge.fontFamilies[0], "Menlo", "PingFang SC"],
                       "回退链的顺序：系统等宽 → Menlo → 苹方")

        let latin = production.ink(row: 0, column: 0, columns: latinColumns)
        let latinSystem = systemOnly.ink(row: 0, column: 0, columns: latinColumns)
        let latinMenlo = menloOnly.ink(row: 0, column: 0, columns: latinColumns)
        let latinPingFang = pingFangOnly.ink(row: 0, column: 0, columns: latinColumns)
        print("FONT latin production=\(Int(latin)) system-only=\(Int(latinSystem)) menlo-only=\(Int(latinMenlo)) pingfang-only=\(Int(latinPingFang)) cell=\(production.cell)")
        XCTAssertGreaterThan(latin, 100, "自证：读到了拉丁字符的墨迹")
        XCTAssertEqual(latin, latinSystem, accuracy: latin * 0.005, "拉丁字符不是系统等宽画的")
        XCTAssertGreaterThan(abs(latinMenlo - latin), latin * 0.03, "自证：Menlo 画出来和系统等宽分得开")
        XCTAssertGreaterThan(abs(latinPingFang - latin), latin * 0.03, "自证：苹方画拉丁字符和系统等宽分得开")

        let han = production.ink(row: 1, column: 0, columns: hanColumns)
        let hanPingFang = pingFangOnly.ink(row: 1, column: 0, columns: hanColumns)
        let hanAuto = systemOnly.ink(row: 1, column: 0, columns: hanColumns)
        print("FONT han production=\(Int(han)) pingfang-only=\(Int(hanPingFang)) auto-fallback=\(Int(hanAuto)) quote-auto left=\(Int(systemOnly.ink(row: 2, column: 0, columns: 1))) right=\(Int(systemOnly.ink(row: 2, column: 1, columns: 1)))")
        XCTAssertGreaterThan(han, 100, "自证：读到了汉字的墨迹")
        XCTAssertEqual(han, hanPingFang, accuracy: han * 0.005, "汉字不是苹方（PingFang SC）画的")
        // 汉字之后是空的：没有画出格。
        XCTAssertLessThan(production.ink(row: 1, column: hanColumns + 1, columns: 4), han * 0.005)
    }

    /// 字重是常规，不是 Light：按族名取系统等宽，CoreText 默认给的 face 在 Mac 上是 Light，iOS 上实际核一次。
    /// 做法同上：显式写 `font-style = Regular` 的墨量和不写的一样，写 Light 的明显更少。
    func testDefaultWeightIsRegularNotLight() async throws {
        let production = try await render()
        let regular = try await render { $0.withCustom("font-style", "Regular") }
        let light = try await render { $0.withCustom("font-style", "Light") }
        for (name, row, columns) in [("latin", 0, latinColumns), ("han", 1, hanColumns)] {
            let ink = production.ink(row: row, column: 0, columns: columns)
            let asRegular = regular.ink(row: row, column: 0, columns: columns)
            let asLight = light.ink(row: row, column: 0, columns: columns)
            print("FONT weight \(name) production=\(Int(ink)) regular=\(Int(asRegular)) light=\(Int(asLight))")
            XCTAssertEqual(ink, asRegular, accuracy: ink * 0.005, "\(name)：默认取到的不是常规字重")
            XCTAssertLessThan(asLight, ink * 0.95, "\(name)：自证——Light 的墨量应当明显更少")
        }
    }

    func testChineseInkIsTheSameAcrossFreshControllers() async throws {
        let first = try await render()
        let second = try await render()
        let columns = Self.han.count * 2
        let a = first.ink(row: 1, column: 0, columns: columns)
        let b = second.ink(row: 1, column: 0, columns: columns)
        print("FONT stability han ink first=\(Int(a)) second=\(Int(b))")
        XCTAssertGreaterThan(a, 100, "自证：读到了汉字的墨迹")
        XCTAssertEqual(a, b, accuracy: a * 0.02, "两次运行中文的墨量不一样：字重不稳定")
    }

    func testFullWidthLeftQuoteSitsInTheRightHalfOfItsCells() async throws {
        let shot = try await render()
        let left = shot.ink(row: 2, column: 0, columns: 1)
        let right = shot.ink(row: 2, column: 1, columns: 1)
        // 行尾的右引号「」」在它那两格的左半边（第 6、7 格：「=0-1、引=2-3、号=4-5、」=6-7）。
        let closeLeft = shot.ink(row: 2, column: 6, columns: 1)
        let closeRight = shot.ink(row: 2, column: 7, columns: 1)
        print("FONT quote open left=\(Int(left)) right=\(Int(right)) close left=\(Int(closeLeft)) right=\(Int(closeRight))")
        XCTAssertGreaterThan(right, 10, "自证：读到了左引号的墨迹")
        XCTAssertGreaterThan(right, left * 3, "全角左引号「没有靠右")
        XCTAssertGreaterThan(closeLeft, closeRight * 3, "全角右引号」没有靠左")
    }
}
