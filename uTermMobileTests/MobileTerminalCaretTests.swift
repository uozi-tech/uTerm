import GhosttyTerminal
import UIKit
import XCTest
@testable import uTermMobile

/// 收起键盘后用户还在看同一个终端：光标要继续是实心块，不能变成表示失焦的空心框。Claude Code 用的就是终端真光标，
/// 所以这里看的是真实画出来的像素（真 surface、整窗截图）。
///
/// 换引擎之前靠旧引擎的 `caretViewTracksFocus = false`（b7d5d391）。GhosttyKit 按 surface 的焦点画光标、失焦一律空心，
/// 所以 iOS 让 surface 一直是聚焦的（本地包 `uTermKeepsSurfaceFocused`，见 `UTERM-PATCHES.md` 第 14 条），
/// 「终端有没有焦点」只用来给开了 DEC 1004 的程序报 focus in / out，由宿主照旧引擎的规则发。
@MainActor
final class MobileTerminalCaretTests: XCTestCase {
    private var window: UIWindow?
    /// 固定稳定的块光标（不闪烁），不读测试宿主里存的光标偏好。
    private static let controller = GhosttyTerminalBridge.makeController(
        fontSize: GhosttyTerminalBridge.ghosttyFontSize(points: 11),
        cursor: TerminalCursorLook(shape: .block, blink: false))
    /// 设置里开了闪烁。
    private static let blinkingController = GhosttyTerminalBridge.makeController(
        fontSize: GhosttyTerminalBridge.ghosttyFontSize(points: 11),
        cursor: TerminalCursorLook(shape: .block, blink: true))
    private let scheme = TerminalColorScheme.resolve(dark: true)

    override func tearDown() async throws {
        window?.subviews.forEach { $0.removeFromSuperview() }
        window?.isHidden = true
        window = nil
    }

    func testCaretStaysSolidAfterTheKeyboardCollapses() async throws {
        let window = try makeWindow()
        let bridge = try await hostedTerminal(in: window, frame: window.bounds)

        XCTAssertTrue(bridge.view.becomeFirstResponder())
        let focused = try await caretBox(of: bridge.view, in: window)
        XCTAssertTrue(focused.isFilled, "聚焦时是实心块：中心 \(focused.center)")

        // 收起键盘 = 终端放弃第一响应者（`MobileTerminalController.collapseKeyboard`）。
        XCTAssertTrue(bridge.view.resignFirstResponder())
        XCTAssertFalse(bridge.view.isFirstResponder)
        let collapsed = try await sample(focused.box, of: bridge.view, in: window)
        XCTAssertTrue(collapsed.isFilled, "收起键盘后仍是实心块：中心 \(collapsed.center)")
    }

    /// 分屏：焦点移到另一格之后，原来那格的光标也还是实心（当前格由焦点框标出，同换引擎之前）。
    func testCaretInTheInactiveSplitPaneStaysSolid() async throws {
        let window = try makeWindow()
        let half = window.bounds.width / 2
        let left = try await hostedTerminal(in: window, frame: CGRect(x: 0, y: 0, width: half - 4,
                                                                      height: window.bounds.height))
        let right = try await hostedTerminal(in: window, frame: CGRect(x: half + 4, y: 0, width: half - 4,
                                                                       height: window.bounds.height))

        XCTAssertTrue(left.view.becomeFirstResponder())
        let leftFocused = try await caretBox(of: left.view, in: window)
        XCTAssertTrue(leftFocused.isFilled, "左格聚焦时是实心块")
        XCTAssertTrue(right.view.becomeFirstResponder())
        XCTAssertFalse(left.view.isFirstResponder)

        let leftInactive = try await sample(leftFocused.box, of: left.view, in: window)
        XCTAssertTrue(leftInactive.isFilled, "焦点移到右格后，左格仍是实心块：中心 \(leftInactive.center)")
        let rightFocused = try await caretBox(of: right.view, in: window)
        XCTAssertTrue(rightFocused.isFilled, "右格聚焦时是实心块")
    }

    /// 没有焦点时光标闪不闪照设置与程序（DECSCUSR），不是失焦一律不闪：设置开了闪烁，收起键盘后照样一亮一灭；
    /// 程序设了稳定块（`CSI 2 q`）就一直亮着。
    func testCaretBlinkFollowsTheSettingAndTheProgramWithoutFocus() async throws {
        let window = try makeWindow()
        let bridge = try await hostedTerminal(in: window, frame: window.bounds, controller: Self.blinkingController)
        XCTAssertTrue(bridge.view.becomeFirstResponder())
        bridge.feed(Data("\u{1B}[2 q".utf8))
        bridge.session.waitForPendingOutput()
        let steady = try await caretBox(of: bridge.view, in: window)
        XCTAssertTrue(steady.isFilled, "程序设了稳定块：聚焦时实心")
        XCTAssertTrue(bridge.view.resignFirstResponder())

        let steadyStates = try await caretStates(at: steady.box, in: window, count: 6)
        XCTAssertEqual(Set(steadyStates), [true], "程序设了稳定块：收起键盘后一直是实心块")

        bridge.feed(Data("\u{1B}[0 q".utf8))   // 回到设置里的样式（闪烁的块）
        bridge.session.waitForPendingOutput()
        let blinkingStates = try await caretStates(at: steady.box, in: window, count: 8)
        XCTAssertEqual(Set(blinkingStates), [true, false], "设置开了闪烁：收起键盘后照样一亮一灭（读到 \(blinkingStates)）")
    }

    /// 开了 DEC 1004 的程序收到的 focus in / out 和换引擎之前一样（旧引擎 iOS 视图的规则）：
    /// - 成为第一响应者发 `CSI I`、放弃发 `CSI O`；没开 1004 什么都不发；
    /// - 程序开 1004 时当场报一次当前状态（xterm 的做法）：之前放弃过第一响应者就是 `CSI O`；
    /// - 进出后台、标签藏起来（以及藏久了放掉 surface、露出来重建回放）都不发——旧引擎这些时候不动第一响应者。
    /// 每一步只发一次，引擎和宿主不重复。
    func testFocusReportsFollowTheOldRules() async throws {
        let window = try makeWindow()
        let bridge = try await hostedTerminal(in: window, frame: window.bounds)
        bridge.inputLog = []
        var seen = 0

        func expect(_ wanted: [String], _ step: String, file: StaticString = #filePath, line: UInt = #line) async throws {
            try await Task.sleep(for: .milliseconds(300))
            bridge.session.waitForPendingOutput()
            try await Task.sleep(for: .milliseconds(100))
            let log = bridge.inputLog ?? []
            let got = log[seen...].map { Self.describe($0) }
            seen = log.count
            XCTAssertEqual(got, wanted, step, file: file, line: line)
        }

        XCTAssertTrue(bridge.view.becomeFirstResponder())
        try await expect([], "没开 1004 时聚焦不报")
        bridge.feed(Data("\u{1B}[?1004h".utf8))
        try await expect(["CSI I"], "开 1004 当场报一次当前状态（聚焦）")
        XCTAssertTrue(bridge.view.resignFirstResponder())
        try await expect(["CSI O"], "收起键盘")
        XCTAssertTrue(bridge.view.becomeFirstResponder())
        try await expect(["CSI I"], "弹出键盘")
        XCTAssertTrue(bridge.view.resignFirstResponder())
        try await expect(["CSI O"], "再收起")
        bridge.feed(Data("\u{1B}[?1004l\u{1B}[?1004h".utf8))
        try await expect(["CSI O"], "没有焦点时开 1004，报失焦")
        XCTAssertTrue(bridge.view.becomeFirstResponder())
        try await expect(["CSI I"], "再弹出")

        bridge.setAppInBackground(true)
        try await expect([], "进后台不报")
        bridge.setAppInBackground(false)
        try await expect([], "回前台不报")

        bridge.hiddenReleaseDelay = .milliseconds(100)
        bridge.setOnScreen(false)
        let released = await MobileFakeTerminal.waitUntil(timeout: .seconds(3)) { bridge.view.uTermIsSurfaceReleased }
        XCTAssertTrue(released, "藏起来的标签到时没放掉 surface")
        try await expect([], "标签藏起来、放掉 surface 不报")
        bridge.setOnScreen(true)
        try await waitUntilFed(bridge)
        try await expect([], "露出来重建、回放不报")

        XCTAssertTrue(bridge.view.resignFirstResponder())
        try await expect(["CSI O"], "重建之后收起键盘")
        bridge.feed(Data("\u{1B}[?1004l".utf8))
        XCTAssertTrue(bridge.view.becomeFirstResponder())
        XCTAssertTrue(bridge.view.resignFirstResponder())
        try await expect([], "关了 1004 之后不报")
    }

    // MARK: - 夹具

    private func makeWindow() throws -> UIWindow {
        let window = try makeSpikeWindow(size: CGSize(width: 400, height: 500))
        window.overrideUserInterfaceStyle = .dark
        window.makeKey()
        self.window = window
        return window
    }

    /// 挂在真窗口里、surface 已就绪并接上字节的一条终端，清屏后光标停在第 3 行第 5 列。
    private func hostedTerminal(in window: UIWindow, frame: CGRect,
                                controller: GhosttyTerminal.TerminalController = MobileTerminalCaretTests.controller) async throws -> GhosttyTerminalBridge {
        let bridge = GhosttyTerminalBridge(controller: controller, frame: frame)
        window.addSubview(bridge.view)
        try await waitUntilFed(bridge)
        bridge.feed(Data("\u{1B}[2J\u{1B}[3;5H".utf8))
        bridge.session.waitForPendingOutput()
        return bridge
    }

    private func waitUntilFed(_ bridge: GhosttyTerminalBridge) async throws {
        let ready = await MobileFakeTerminal.waitUntil(timeout: .seconds(5)) {
            bridge.isSurfaceReady && bridge.outputPump.isFeedingSurface
        }
        XCTAssertTrue(ready, "surface 没就绪：ready=\(bridge.isSurfaceReady) feeding=\(bridge.outputPump.isFeedingSurface)")
    }

    private static func describe(_ data: Data) -> String {
        switch [UInt8](data) {
        case [0x1B, 0x5B, 0x49]: "CSI I"
        case [0x1B, 0x5B, 0x4F]: "CSI O"
        default: data.map { String(format: "%02X", $0) }.joined(separator: " ")
        }
    }

    // MARK: - 读像素

    private struct NoCaret: Error {}

    private struct Caret {
        var box: CGRect
        var center: (UInt8, UInt8, UInt8)
        var isFilled: Bool
    }

    /// 在这片终端里找光标：光标色的像素围成的框（实心块、空心框的外框一样大）。
    private func caretBox(of view: UIView, in window: UIWindow) async throws -> Caret {
        let image = try await capture(window)
        let region = view.frame
        let cursor = rgb(scheme.cursorColor)
        var minX = CGFloat.infinity, minY = CGFloat.infinity, maxX = -CGFloat.infinity, maxY = -CGFloat.infinity
        var y = region.minY + 0.5
        while y < region.maxY {
            var x = region.minX + 0.5
            while x < region.maxX {
                if distance(image.pixel(CGPoint(x: x, y: y)), cursor) < 60 {
                    minX = min(minX, x); minY = min(minY, y); maxX = max(maxX, x); maxY = max(maxY, y)
                }
                x += 0.5
            }
            y += 0.5
        }
        guard minX.isFinite else {
            let attachment = XCTAttachment(image: image.image)
            attachment.name = "no-caret"
            attachment.lifetime = .keepAlways
            add(attachment)
            XCTFail("终端里没找到光标色的像素（光标没画出来）")
            throw NoCaret()
        }
        let box = CGRect(x: minX, y: minY, width: maxX - minX, height: maxY - minY)
        return judge(box, in: image)
    }

    /// 按之前找到的框再截一次，看框中心是什么颜色。
    private func sample(_ box: CGRect, of view: UIView, in window: UIWindow) async throws -> Caret {
        judge(box, in: try await capture(window))
    }

    /// 隔 0.25 s 截一次（Ghostty 闪烁周期 0.6 s），每次框中心是不是光标色。
    private func caretStates(at box: CGRect, in window: UIWindow, count: Int) async throws -> [Bool] {
        var states: [Bool] = []
        for _ in 0..<count {
            try await Task.sleep(for: .milliseconds(250))
            states.append(judge(box, in: try await capture(window, settle: false)).isFilled)
        }
        return states
    }

    /// 实心块的中心是光标色；空心框只描边，中心露出终端底色。
    private func judge(_ box: CGRect, in image: Snapshot) -> Caret {
        let center = image.pixel(CGPoint(x: box.midX, y: box.midY))
        let toCaret = distance(center, rgb(scheme.cursorColor))
        let toBackground = distance(center, rgb(scheme.backgroundColor))
        print("CARET box=\(box) center=\(center) toCaret=\(toCaret) toBackground=\(toBackground)")
        return Caret(box: box, center: center, isFilled: toCaret < toBackground)
    }

    /// 整窗截图解成 sRGB 的 RGBA 字节，按点坐标取像素。
    private struct Snapshot {
        let image: UIImage
        let bytes: [UInt8]
        let width: Int
        let height: Int
        let scale: CGFloat

        init(image: UIImage, pointWidth: CGFloat) throws {
            let cg = try XCTUnwrap(image.cgImage)
            self.image = image
            width = cg.width
            height = cg.height
            scale = CGFloat(cg.width) / pointWidth
            var bytes = [UInt8](repeating: 0, count: width * height * 4)
            let context = try XCTUnwrap(CGContext(data: &bytes, width: width, height: height, bitsPerComponent: 8,
                                                  bytesPerRow: width * 4, space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                                  bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
            context.draw(cg, in: CGRect(x: 0, y: 0, width: width, height: height))
            self.bytes = bytes
        }

        func pixel(_ point: CGPoint) -> (UInt8, UInt8, UInt8) {
            let x = min(max(Int(point.x * scale), 0), width - 1)
            let y = min(max(Int(point.y * scale), 0), height - 1)
            let i = (y * width + x) * 4
            return (bytes[i], bytes[i + 1], bytes[i + 2])
        }
    }

    private func capture(_ window: UIWindow, settle: Bool = true) async throws -> Snapshot {
        // 等引擎把这次焦点 / 输出画出来（交帧按 vsync）。
        if settle { try await Task.sleep(for: .milliseconds(400)) }
        let renderer = UIGraphicsImageRenderer(bounds: window.bounds)
        let image = renderer.image { _ in window.drawHierarchy(in: window.bounds, afterScreenUpdates: false) }
        return try Snapshot(image: image, pointWidth: window.bounds.width)
    }

    private func rgb(_ color: UIColor) -> (UInt8, UInt8, UInt8) {
        let resolved = color.resolvedColor(with: UITraitCollection(userInterfaceStyle: .dark))
        var r: CGFloat = 0, g: CGFloat = 0, b: CGFloat = 0, a: CGFloat = 0
        resolved.getRed(&r, green: &g, blue: &b, alpha: &a)
        return (UInt8(clamping: Int(r * 255 + 0.5)), UInt8(clamping: Int(g * 255 + 0.5)), UInt8(clamping: Int(b * 255 + 0.5)))
    }

    private func distance(_ a: (UInt8, UInt8, UInt8), _ b: (UInt8, UInt8, UInt8)) -> Int {
        abs(Int(a.0) - Int(b.0)) + abs(Int(a.1) - Int(b.1)) + abs(Int(a.2) - Int(b.2))
    }
}
