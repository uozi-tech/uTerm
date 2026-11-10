import GhosttyTerminal
import UIKit
import XCTest
@testable import uTermMobile

/// 会话控制器与终端的接线（不点界面）：后端输出进终端、软键盘输入与键盘条按键回到后端、粘滞 Ctrl 状态同步到控制器，
/// 键盘条的键由终端按当前模式编码。类名沿用评估期的（那时终端引擎要靠「Ghostty 试用」开关才走得到，现在只有这一条路径）。
@MainActor
final class GhosttyTrialWiringTests: XCTestCase {
    func testTrialControllerRoutesThroughGhostty() async throws {
        let container = try MobileFixtures.modelContainer(seed: .smoke)
        let host = try XCTUnwrap(MobileFixtures.firstServer(in: container))
        let (controller, handles) = MobileFakeTerminal.controller(.idle)
        let bridge = controller.terminal

        let window = try makeSpikeWindow(size: CGSize(width: 393, height: 600))
        defer { bridge.view.removeFromSuperview(); window.isHidden = true }
        bridge.view.frame = window.bounds
        window.addSubview(bridge.view)
        window.makeKey()
        controller.start(profile: host, container: container, relay: HostKeyChallengeRelay())
        let connected = await MobileFakeTerminal.waitUntilConnected(controller)
        XCTAssertTrue(connected)
        let ready = await MobileFakeTerminal.waitUntil(timeout: .seconds(5)) {
            bridge.isSurfaceReady && bridge.outputPump.isFeedingSurface
        }
        XCTAssertTrue(ready, "surface 没建起来或没接上字节")

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

    /// 键盘条的方向键由终端按当前模式编码：普通模式 `ESC [ D`，程序开了应用光标键（DECCKM：vim、less、htop）发 `ESC O D`。
    /// 换引擎之前键盘条固定发 `ESC [ D`，在这些程序里方向键不认。上膛的 Ctrl 作用在键盘条的键上（Ctrl+←）并用完复位。
    func testKeyBarArrowsFollowCursorKeyModeAndStickyControl() async throws {
        let container = try MobileFixtures.modelContainer(seed: .smoke)
        let host = try XCTUnwrap(MobileFixtures.firstServer(in: container))
        // 不回显：发出去的按键不要再被当成输出喂回来。
        let (controller, handles) = MobileFakeTerminal.controller(
            MobileFakeTerminalScript(linesPerSecond: 0, seconds: 0, corpus: .plain, echoesInput: false))
        let bridge = controller.terminal
        let window = try makeSpikeWindow(size: CGSize(width: 393, height: 600))
        defer { bridge.view.removeFromSuperview(); window.isHidden = true }
        bridge.view.frame = window.bounds
        window.addSubview(bridge.view)
        controller.start(profile: host, container: container, relay: HostKeyChallengeRelay())
        let connected = await MobileFakeTerminal.waitUntilConnected(controller)
        XCTAssertTrue(connected)
        let ready = await MobileFakeTerminal.waitUntil(timeout: .seconds(5)) {
            bridge.isSurfaceReady && bridge.outputPump.isFeedingSurface
        }
        XCTAssertTrue(ready, "surface 没建起来或没接上字节")
        let transport = try XCTUnwrap(handles.latest)
        let left = try XCTUnwrap(TerminalKeyCatalog.arrows.first { $0.label == "←" })
        let up = try XCTUnwrap(TerminalKeyCatalog.arrows.first { $0.label == "↑" })

        /// 发一个键，返回后端因此多收到的字节。
        func bytes(of key: uTermMobile.TerminalKey) async throws -> [UInt8] {
            let before = await transport.writes.count
            controller.sendKey(key)
            for _ in 0..<100 {
                if await transport.writes.count > before { break }
                try await Task.sleep(for: .milliseconds(20))
            }
            try await Task.sleep(for: .milliseconds(100))
            return await transport.writes.dropFirst(before).flatMap { [UInt8]($0) }
        }

        let normalLeft = try await bytes(of: left)
        XCTAssertEqual(normalLeft, Array("\u{1b}[D".utf8), "普通模式方向键发 CSI")

        // 程序开应用光标键。
        bridge.feed(Data("\u{1b}[?1h".utf8))
        bridge.session.waitForPendingOutput()
        let appLeft = try await bytes(of: left)
        XCTAssertEqual(appLeft, Array("\u{1b}OD".utf8), "应用光标键下方向键发 SS3")
        let appUp = try await bytes(of: up)
        XCTAssertEqual(appUp, Array("\u{1b}OA".utf8))

        // 关掉之后回到 CSI。
        bridge.feed(Data("\u{1b}[?1l".utf8))
        bridge.session.waitForPendingOutput()
        let backToNormal = try await bytes(of: up)
        XCTAssertEqual(backToNormal, Array("\u{1b}[A".utf8))

        // Ctrl 上膛后点 ←：发 Ctrl+←（xterm 的修饰键编码），用完复位。
        controller.toggleControl()
        XCTAssertTrue(controller.controlArmed)
        let controlLeft = try await bytes(of: left)
        XCTAssertEqual(controlLeft, Array("\u{1b}[1;5D".utf8), "Ctrl 上膛后点 ← 发 Ctrl+←")
        XCTAssertFalse(controller.controlArmed, "Ctrl 被键盘条的键用掉后应当复位")

        // 发提示词前清掉上膛的修饰键：不落到之后的字符上。
        controller.toggleAlt()
        XCTAssertTrue(controller.altArmed)
        controller.clearStickyModifiers()
        XCTAssertFalse(controller.altArmed)

        controller.close()
    }

    /// 远控标签（手机是主控端）：Mac 发来的整屏二进制快照经输出泵还原进本地影子、回放进画面，之后的实时字节接着它。
    /// 协议那一段（握手带引擎版本、47 号消息拼段）在共享层，用例在 Mac 的 `TerminalMirrorSnapshotTests`；这里核 iOS 的终端接得住。
    func testRemoteSnapshotRestoresTheShadowAndTheSurface() async throws {
        // 被控端那一侧：另一个影子终端，带回滚、带备用屏之外的普通内容。
        let source = ShadowTerminal(cols: 60, rows: 20, options: GhosttyTerminalBridge.scrollback.shadowOptions)
        for index in 0..<50 { source.feed(Data("mac line \(index)\r\n".utf8)) }
        source.feed(Data("\u{1B}]2;from the mac\u{07}$ ".utf8))
        let snapshot = try source.snapshot()

        let bridge = GhosttyTerminalBridge(controller: GhosttyProbeHost.controller)
        var titles: [String] = []
        bridge.onEvent = { if case .titleChanged(let title) = $0 { titles.append(title) } }
        let window = try makeSpikeWindow(size: CGSize(width: 393, height: 600))
        defer { bridge.view.removeFromSuperview(); window.isHidden = true }
        bridge.view.frame = window.bounds
        window.addSubview(bridge.view)
        let ready = await MobileFakeTerminal.waitUntil(timeout: .seconds(5)) {
            bridge.isSurfaceReady && bridge.outputPump.isFeedingSurface
        }
        XCTAssertTrue(ready)
        bridge.feed(Data("local junk that the snapshot replaces\r\n".utf8))

        bridge.outputPump.start(AsyncStream<TerminalOutputItem> { continuation in
            continuation.yield(.snapshot(snapshot))
            continuation.yield(.bytes(Data("live after snapshot".utf8)))
            continuation.finish()
        })
        let applied = await MobileFakeTerminal.waitUntil(timeout: .seconds(3)) {
            bridge.shadow.viewportText().contains("live after snapshot")
        }
        XCTAssertTrue(applied, "快照和后面的字节没进影子：\(bridge.shadow.viewportText().suffix(120))")
        bridge.outputPump.waitForCatchUp()
        bridge.session.waitForPendingOutput()

        XCTAssertEqual(bridge.outputPump.currentStats.rejectedSnapshots, 0)
        XCTAssertEqual(bridge.shadow.title, "from the mac")
        let titled = await MobileFakeTerminal.waitUntil(timeout: .seconds(2)) { titles.last == "from the mac" }
        XCTAssertTrue(titled, "快照里的标题没报给会话：\(titles)")
        XCTAssertFalse(bridge.shadow.viewportText().contains("local junk"), "快照是整屏替换")
        XCTAssertGreaterThan(bridge.shadow.totalRows, 40, "回滚也跟着快照过来")
        let surface = bridge.session.readViewportText() ?? ""
        XCTAssertTrue(surface.contains("mac line 49") && surface.contains("live after snapshot"),
                      "画面没跟上：\(surface.suffix(160))")
        XCTAssertFalse(surface.contains("local junk"))
        print("WIRING remote-snapshot titles=\(titles) shadow-size=\(bridge.shadow.size) grid=\(String(describing: bridge.grid))")
    }

    /// 终端的配色 / 留白和 uTerm 的终端底色对得上（M16 反馈过：底色、光标颜色不对，左右露出两条）。
    /// 照 `TerminalSessionBody` 的排法：外层 8pt 左右边距铺 uTerm 终端底色，里面是终端视图；深 / 浅各截一张整窗图
    ///（上半是纯 UIView 铺的底色当参照，终端在下半），并核终端区角上与留白条的像素都等于参照。
    func testTerminalColorsAndInsetsMatchTheSurroundingSurface() async throws {
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

            // 上半：纯 UIView 铺终端底色，当参照。
            let reference = UIView(frame: CGRect(x: 0, y: 0, width: size.width, height: half))
            reference.backgroundColor = scheme.backgroundColor
            window.addSubview(reference)

            // 下半：终端（和生产同一份 controller 配置）。
            let ghBack = UIView(frame: CGRect(x: 0, y: half, width: size.width, height: half))
            ghBack.backgroundColor = scheme.backgroundColor
            window.addSubview(ghBack)
            let bridge = GhosttyTerminalBridge(controller: controller,
                                               frame: CGRect(x: inset, y: half, width: size.width - inset * 2, height: half))
            window.addSubview(bridge.view)
            let ready = await MobileFakeTerminal.waitUntil(timeout: .seconds(5)) {
                bridge.isSurfaceReady && bridge.outputPump.isFeedingSurface
            }
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
            // 参照取同一张图里纯 UIView 铺的底色（上半），不拿配色常量比：浅色下整张截图
            // 实测是 #F9F9F9 而不是 #FFFFFF（纯 UIView 也一样，是截图这一步的偏差）。
            let want = pixel(CGPoint(x: size.width - inset / 2, y: half / 2))
            var r: CGFloat = 0, g: CGFloat = 0, b: CGFloat = 0, a: CGFloat = 0
            scheme.backgroundColor.getRed(&r, green: &g, blue: &b, alpha: &a)
            print("MEASURE m16 \(dark ? "dark" : "light") scheme-bg=#\(String(format: "%02X%02X%02X", Int(r * 255 + 0.5), Int(g * 255 + 0.5), Int(b * 255 + 0.5))) captured-reference=#\(String(format: "%02X%02X%02X", want.0, want.1, want.2))")
            let probes: [(String, CGPoint)] = [
                ("ghostty 右下角", CGPoint(x: size.width - inset - 4, y: size.height - 4)),
                ("ghostty 左留白", CGPoint(x: inset / 2, y: half + half / 2)),
                ("ghostty 右留白", CGPoint(x: size.width - inset / 2, y: half + half / 2)),
                ("ghostty 终端区中下", CGPoint(x: size.width / 2, y: size.height - 30)),
            ]
            for (name, point) in probes {
                let got = pixel(point)
                print("MEASURE m16 \(dark ? "dark" : "light") \(name) got=#\(String(format: "%02X%02X%02X", got.0, got.1, got.2)) want=#\(String(format: "%02X%02X%02X", want.0, want.1, want.2))")
                XCTAssertTrue(abs(Int(got.0) - Int(want.0)) <= 2 && abs(Int(got.1) - Int(want.1)) <= 2 && abs(Int(got.2) - Int(want.2)) <= 2,
                              "\(dark ? "深" : "浅")色 \(name) 不是终端底色：\(got) vs \(want)")
            }
            print("MEASURE m16 \(dark ? "dark" : "light") grid ghostty=\(String(describing: bridge.grid)) issue=\(controller.lastConfigurationIssue ?? "-")")
            bridge.view.removeFromSuperview()
            reference.removeFromSuperview()
        }
    }
}
