import SwiftTerm
import SwiftUI
import UIKit
import XCTest
@testable import uTermMobile

/// 收起键盘后用户还在看同一个终端：光标要继续是实心块，不能变成 SwiftTerm 表示失焦的空心框。
/// Claude Code 用的就是终端真光标，所以这里看的是真实画出来的像素。
@MainActor
final class MobileTerminalCaretTests: XCTestCase {
    func testCaretStaysSolidAfterTheKeyboardCollapses() async throws {
        defer { MobileProbeWindow.closeAll() }
        let container = try MobileFixtures.modelContainer(seed: .smoke)
        let host = try XCTUnwrap(MobileFixtures.firstServer(in: container))
        let (controller, _) = MobileFakeTerminal.controller(.idle)
        _ = MobileProbeWindow.make(
            size: CGSize(width: 390, height: 844),
            placement: .visibleOnScreen,
            isolateHost: true,
            rootView: SwiftTermView(controller: controller, autoFocus: false)
                .frame(width: 390, height: 500)
        )
        try await Task.sleep(for: .milliseconds(300))
        controller.start(profile: host, container: container, relay: HostKeyChallengeRelay())
        let connected = await MobileFakeTerminal.waitUntilConnected(controller)
        XCTAssertTrue(connected)
        let terminal = try XCTUnwrap(controller.terminalView)

        controller.ownsKeyboard = true
        controller.focusKeyboard()
        XCTAssertTrue(terminal.isFirstResponder)
        try await Task.sleep(for: .milliseconds(200))
        XCTAssertTrue(caretCenterIsFilled(in: terminal), "聚焦时是实心块")

        controller.collapseKeyboard()
        XCTAssertFalse(terminal.isFirstResponder)
        try await Task.sleep(for: .milliseconds(200))
        XCTAssertTrue(caretCenterIsFilled(in: terminal), "收起键盘后仍是实心块")

        controller.close()
    }

    /// 实心块的中心是光标色；空心框只描边，中心露出终端底色。
    private func caretCenterIsFilled(in terminal: SwiftTerm.TerminalView) -> Bool {
        guard let caret = terminal.textInputCaretFrame else {
            XCTFail("光标没有显示")
            return false
        }
        let center = CGPoint(x: caret.midX, y: caret.midY)
        let pixel = renderedPixel(of: terminal, at: center)
        let traits = terminal.traitCollection
        let toCaret = distance(pixel, terminal.caretColor.resolvedColor(with: traits))
        let toBackground = distance(pixel, terminal.nativeBackgroundColor.resolvedColor(with: traits))
        return toCaret < toBackground
    }

    private func renderedPixel(of view: UIView, at point: CGPoint) -> [CGFloat] {
        var bytes = [UInt8](repeating: 0, count: 4)
        let colorSpace = CGColorSpace(name: CGColorSpace.sRGB)!
        bytes.withUnsafeMutableBytes { buffer in
            let context = CGContext(
                data: buffer.baseAddress,
                width: 1,
                height: 1,
                bitsPerComponent: 8,
                bytesPerRow: 4,
                space: colorSpace,
                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
            )!
            // 把目标点移到这 1×1 位图上，并翻到 UIKit 的左上原点。终端是滚动视图，图层按 bounds 原点偏移。
            context.translateBy(x: view.bounds.minX - point.x, y: point.y - view.bounds.minY + 1)
            context.scaleBy(x: 1, y: -1)
            view.layer.render(in: context)
        }
        return bytes.prefix(3).map { CGFloat($0) / 255 }
    }

    private func distance(_ pixel: [CGFloat], _ color: UIColor) -> CGFloat {
        let srgb = color.cgColor.converted(
            to: CGColorSpace(name: CGColorSpace.sRGB)!,
            intent: .defaultIntent,
            options: nil
        )
        let components = srgb?.components ?? [0, 0, 0]
        return zip(pixel, components).reduce(0) { $0 + abs($1.0 - $1.1) }
    }
}
