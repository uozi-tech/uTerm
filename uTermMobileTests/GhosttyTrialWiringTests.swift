#if DEBUG
import GhosttyTerminal
import UIKit
import XCTest
@testable import uTermMobile

/// M16「Ghostty 试用」入口的接线（不点界面）：开关打开后新建的控制器走 GhosttyKit，
/// 后端输出进 Ghostty、软键盘输入与键盘条按键回到后端、粘滞 Ctrl 状态同步到控制器。
@MainActor
final class GhosttyTrialWiringTests: XCTestCase {
    func testTrialControllerRoutesThroughGhostty() async throws {
        let defaults = UserDefaults.standard
        let previous = defaults.object(forKey: DefaultsKey.debugGhosttyTrial)
        defaults.set(true, forKey: DefaultsKey.debugGhosttyTrial)
        // 测试宿主与装机版共用偏好：用完原样放回，别把用户的开关改掉。
        defer {
            if let previous { defaults.set(previous, forKey: DefaultsKey.debugGhosttyTrial) }
            else { defaults.removeObject(forKey: DefaultsKey.debugGhosttyTrial) }
        }

        let container = try MobileFixtures.modelContainer(seed: .smoke)
        let host = try XCTUnwrap(MobileFixtures.firstServer(in: container))
        let (controller, handles) = MobileFakeTerminal.controller(.idle)
        let bridge = try XCTUnwrap(controller.ghostty, "开关打开后新控制器应当带 Ghostty bridge")
        XCTAssertNil(controller.terminalView)

        let window = try makeSpikeWindow(size: CGSize(width: 393, height: 600))
        defer { bridge.view.removeFromSuperview(); window.isHidden = true }
        bridge.view.frame = window.bounds
        window.addSubview(bridge.view)
        window.makeKey()
        controller.start(profile: host, container: container, relay: HostKeyChallengeRelay())
        let connected = await MobileFakeTerminal.waitUntilConnected(controller)
        XCTAssertTrue(connected)
        let ready = await MobileFakeTerminal.waitUntil(timeout: .seconds(5)) { bridge.view.surface != nil && bridge.grid != nil }
        XCTAssertTrue(ready, "Ghostty surface 没建起来")

        controller.ownsKeyboard = true
        controller.focusKeyboard()
        XCTAssertTrue(bridge.view.isFirstResponder, "控制器聚焦应当落到 Ghostty 视图")
        XCTAssertTrue(controller.keyboardShown, "Ghostty 视图的焦点变化要同步回控制器")

        // 软键盘落字 → 后端（假后端原样回显）→ Ghostty 屏上。
        bridge.view.insertText("e")
        bridge.view.insertText("c")
        let echoed = await MobileFakeTerminal.waitUntil(timeout: .seconds(3)) {
            bridge.session.readViewportText()?.contains("ec") == true
        }
        XCTAssertTrue(echoed, "回显没上 Ghostty 屏：\(String((bridge.session.readViewportText() ?? "").prefix(80)))")

        // 键盘条：Esc 走终端按键编码。
        let before = await handles.latest?.writtenBytes ?? 0
        controller.sendKey(TerminalKeyCatalog.escape)
        try await Task.sleep(for: .milliseconds(200))
        let after = await handles.latest?.writtenBytes ?? 0
        XCTAssertEqual(after - before, 1, "键盘条 Esc 应当发 1 个字节")

        // 粘滞 Ctrl：上膛后控制器亮起，下一个字符用掉后复位。
        controller.toggleControl()
        XCTAssertTrue(controller.controlArmed)
        bridge.view.insertText("c")
        try await Task.sleep(for: .milliseconds(200))
        XCTAssertFalse(controller.controlArmed, "Ctrl 用掉后应当复位")
        let writes = await handles.latest?.writes ?? []
        XCTAssertEqual(writes.last.map { [UInt8]($0) }, [0x03], "Ctrl+c 应当发 0x03")

        controller.close()
    }

    /// 试用入口的配色 / 字体 / 留白和 SwiftTerm 标签一致（M16 反馈：底色、光标颜色不对，左右露出两条）。
    /// 照 `TerminalSessionBody` 的排法：外层 8pt 左右边距铺 uTerm 终端底色，里面是终端视图；深 / 浅各截一张整窗图
    ///（SwiftTerm 在上半、Ghostty 在下半），并核终端区角上与留白条的像素都等于 uTerm 的底色。
    func testTrialColorsAndInsetsMatchSwiftTerm() async throws {
        let size = CGSize(width: 440, height: 760)
        let half = size.height / 2
        let inset = TerminalSessionBody.terminalInset.horizontal
        let sample = "\u{1B}[2J\u{1B}[H$ ls --color\r\n\u{1B}[34mdocs\u{1B}[0m  \u{1B}[32mrun.sh\u{1B}[0m  \u{1B}[31merr.log\u{1B}[0m  0Oo1lIi 中文\r\n"
            + "\u{1B}[1;33mwarning\u{1B}[0m: \u{1B}[2mdim\u{1B}[0m \u{1B}[7mreverse\u{1B}[0m\r\n$ "
        let controller = GhosttyTerminalBridge.makeController(fontSize: GhosttyTerminalBridge.ghosttyFontSize(points: 11))
        for dark in [true, false] {
            let scheme = TerminalColorScheme.resolve(dark: dark)
            let window = try makeSpikeWindow(size: size)
            window.overrideUserInterfaceStyle = dark ? .dark : .light
            window.backgroundColor = .magenta   // 哪里没铺到一眼可见
            defer { window.isHidden = true }

            // 上半：SwiftTerm（与 SwiftTermView 同样装配）。
            let stBack = UIView(frame: CGRect(x: 0, y: 0, width: size.width, height: half))
            stBack.backgroundColor = scheme.backgroundColor
            window.addSubview(stBack)
            let stView = MTerminalView(frame: .zero, font: .monospacedSystemFont(ofSize: 11, weight: .regular))
            stView.contentInsetAdjustmentBehavior = .never
            TerminalAppearance.applyColors(to: stView, scheme: scheme)
            TerminalAppearance.applyCursor(to: stView, scheme: scheme, shape: .block, blink: false)
            stView.backgroundColor = scheme.backgroundColor
            let stContainer = MTerminalContainerView(terminalView: stView, fontSize: 11)
            stContainer.frame = CGRect(x: inset, y: 0, width: size.width - inset * 2, height: half)
            window.addSubview(stContainer)
            stContainer.layoutIfNeeded()
            stView.feed(text: sample)

            // 下半：Ghostty（试用入口同一个 controller 配置）。
            let ghBack = UIView(frame: CGRect(x: 0, y: half, width: size.width, height: half))
            ghBack.backgroundColor = scheme.backgroundColor
            window.addSubview(ghBack)
            let bridge = GhosttyTerminalBridge(controller: controller,
                                               frame: CGRect(x: inset, y: half, width: size.width - inset * 2, height: half))
            window.addSubview(bridge.view)
            let ready = await MobileFakeTerminal.waitUntil(timeout: .seconds(5)) { bridge.view.surface != nil && bridge.grid != nil }
            XCTAssertTrue(ready)
            bridge.feed(Data(sample.utf8))
            bridge.session.waitForPendingOutput()
            try await Task.sleep(for: .milliseconds(800))

            let renderer = UIGraphicsImageRenderer(bounds: window.bounds)
            let image = renderer.image { _ in window.drawHierarchy(in: window.bounds, afterScreenUpdates: false) }
            let attachment = XCTAttachment(image: image)
            attachment.name = "m16-trial-\(dark ? "dark" : "light")"
            attachment.lifetime = .keepAlways
            add(attachment)

            // 像素：Ghostty 终端区右下角（没字的地方）与左右留白条都应是 uTerm 底色。
            let cg = try XCTUnwrap(image.cgImage)
            let scale = CGFloat(cg.width) / size.width
            func pixel(_ point: CGPoint) -> (UInt8, UInt8, UInt8) {
                var buffer = [UInt8](repeating: 0, count: 4)
                let context = CGContext(data: &buffer, width: 1, height: 1, bitsPerComponent: 8, bytesPerRow: 4,
                                        space: CGColorSpaceCreateDeviceRGB(),
                                        bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
                context.draw(cg, in: CGRect(x: -point.x * scale, y: -(CGFloat(cg.height) - point.y * scale),
                                            width: CGFloat(cg.width), height: CGFloat(cg.height)))
                return (buffer[0], buffer[1], buffer[2])
            }
            // 参照取同一张图里纯 UIView 铺的底色（上半右侧没字的地方），不拿配色常量比：浅色下整张截图
            // 实测是 #F9F9F9 而不是 #FFFFFF（SwiftTerm、纯 UIView 都一样，是截图这一步的偏差）。
            let want = pixel(CGPoint(x: size.width - inset / 2, y: half / 2))
            var r: CGFloat = 0, g: CGFloat = 0, b: CGFloat = 0, a: CGFloat = 0
            scheme.backgroundColor.getRed(&r, green: &g, blue: &b, alpha: &a)
            print("MEASURE m16 \(dark ? "dark" : "light") scheme-bg=#\(String(format: "%02X%02X%02X", Int(r * 255 + 0.5), Int(g * 255 + 0.5), Int(b * 255 + 0.5))) captured-reference=#\(String(format: "%02X%02X%02X", want.0, want.1, want.2))")
            let probes: [(String, CGPoint)] = [
                ("ghostty 右下角", CGPoint(x: size.width - inset - 4, y: size.height - 4)),
                ("ghostty 左留白", CGPoint(x: inset / 2, y: half + half / 2)),
                ("ghostty 右留白", CGPoint(x: size.width - inset / 2, y: half + half / 2)),
                ("ghostty 终端区中下", CGPoint(x: size.width / 2, y: size.height - 30)),
                ("swiftterm 右下角", CGPoint(x: size.width - inset - 4, y: half - 4)),
            ]
            for (name, point) in probes {
                let got = pixel(point)
                print("MEASURE m16 \(dark ? "dark" : "light") \(name) got=#\(String(format: "%02X%02X%02X", got.0, got.1, got.2)) want=#\(String(format: "%02X%02X%02X", want.0, want.1, want.2))")
                XCTAssertTrue(abs(Int(got.0) - Int(want.0)) <= 2 && abs(Int(got.1) - Int(want.1)) <= 2 && abs(Int(got.2) - Int(want.2)) <= 2,
                              "\(dark ? "深" : "浅")色 \(name) 不是终端底色：\(got) vs \(want)")
            }
            print("MEASURE m16 \(dark ? "dark" : "light") grid swiftterm=\(stView.getTerminal().cols)x\(stView.getTerminal().rows) ghostty=\(String(describing: bridge.grid)) issue=\(controller.lastConfigurationIssue ?? "-")")
            bridge.view.removeFromSuperview()
            stContainer.removeFromSuperview()
        }
    }
}
#endif
